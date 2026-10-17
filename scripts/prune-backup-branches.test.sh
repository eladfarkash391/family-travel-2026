#!/usr/bin/env bash
#
# Proves each guard in prune-backup-branches.sh actually bites, by building a
# throwaway repo whose branches are known-good and known-bad and asserting what
# the script selects. A guard nobody has watched fire is decoration — see the
# 21/08/2026 Playwright relay finding in CLAUDE.md.
#
# Run: ./scripts/prune-backup-branches.test.sh

set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/prune-backup-branches.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0

ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails+1)); }
check(){ # description, expect-present(0/1), branch, output
  local d="$1" want="$2" b="$3" out="$4"
  local got=0
  printf '%s' "$out" | sed -n '/^DELETE/,$p' | grep -qE "^  $b\$" && got=1
  [ "$got" = "$want" ] && ok "$d" || bad "$d (selected=$got, expected=$want)"
}

# Names are computed ONCE. `date` was originally called at each use, so the
# seconds ticked between creating a branch and asserting on it and the names
# silently stopped matching — the test passed or failed on how fast it ran.
old() { date -u -d "$1 days ago" +%Y%m%dT%H%M%S; }
B_OLD="backup-$(old 60)"
B_YOUNG="backup-$(old 1)"
B_UNMERGED="backup-premerge-$(old 60)"
B_UNDATED="backup-no-timestamp"
B_CLAUDE="claude/feature-$(old 60)"
B_RELEASE="release-$(old 60)"

# --- upstream ("origin") ------------------------------------------------------
up="$tmp/up"; git init -q --bare "$up"
wk="$tmp/wk"; git init -q "$wk"; cd "$wk"
git config user.email t@t; git config user.name t; git remote add origin "$up"
echo a > f; git add f; git commit -qm base
git branch -M main

# a commit that never reaches main
git checkout -q -b stray; echo b > f; git commit -qam stray; git checkout -q main

# fixtures
git branch "$B_OLD"      main    # merged + old     -> DELETE
git branch "$B_YOUNG"    main    # merged + young   -> keep
git branch "$B_UNMERGED" stray   # unmerged + old   -> keep
git branch "$B_UNDATED"  main    # undated          -> keep
git branch "$B_CLAUDE"   main    # not a backup     -> keep
git branch "$B_RELEASE"  main    # not a backup     -> keep
git push -q origin --all

before=$(git ls-remote --heads "$up" | wc -l)
out="$(GRACE_DAYS=14 BASE=origin/main "$SCRIPT" 2>&1)" || true

echo "Guards:"
check "merged + old is selected"              1 "$B_OLD"      "$out"
check "young backup is spared"                0 "$B_YOUNG"    "$out"
check "unmerged backup is spared"             0 "$B_UNMERGED" "$out"
check "undated backup is spared"              0 "$B_UNDATED"  "$out"
check "non-backup branch is untouched"        0 "$B_CLAUDE"   "$out"
check "other branch prefix is untouched"      0 "$B_RELEASE"  "$out"

printf '%s' "$out" | grep -q 'DRY RUN' && ok "dry run is the default" || bad "dry run is the default"

# --- a repo whose default branch is NOT `main` --------------------------------
# The script is meant to drop into any repository. Hardcoding `main` made it
# refuse in a repo on `master`: safe, but useless there, and the refusal read
# like a bug. With no BASE passed it must resolve the base itself and still
# select correctly.
mup="$tmp/up2"; git init -q --bare "$mup"
mwk="$tmp/wk2"; git init -q "$mwk"; cd "$mwk"
git config user.email t@t; git config user.name t; git remote add origin "$mup"
echo a > f; git add f; git commit -qm base; git branch -M master
git branch "$B_OLD" master; git branch "$B_YOUNG" master
git push -q origin --all
git remote set-head origin master >/dev/null 2>&1 || true
mout="$(GRACE_DAYS=14 "$SCRIPT" 2>&1)" || true   # a refusal must be REPORTED, not fatal
check "master-default repo: aged backup selected" 1 "$B_OLD"   "$mout"
check "master-default repo: young backup spared"  0 "$B_YOUNG" "$mout"

# --- BOTH main and master, no remote HEAD: the dangerous one ------------------
# Judged against a stale `main`, a backup merged only into THAT reads as merged
# and is deleted while its commits sit on no live branch. So an ambiguous
# fallback must refuse. Proven necessary by sabotage: the earlier
# prefer-main fallback deleted the branch here and every other test passed.
aup="$tmp/up4"; git init -q --bare "$aup"
awk_="$tmp/wk4"; git init -q "$awk_"; cd "$awk_"
git config user.email t@t; git config user.name t; git remote add origin "$aup"
echo a > f; git add f; git commit -qm base; git branch -M master
git checkout -q -b main; echo c > f; git commit -qam "only on stale main"
git branch "$B_OLD" main          # merged into main, NOT into master
git checkout -q master
git push -q origin --all
git remote set-head origin -d >/dev/null 2>&1 || true
aout="$(GRACE_DAYS=14 "$SCRIPT" 2>&1)" || true
printf '%s' "$aout" | grep -q 'REFUSING' \
  && ok "ambiguous main+master refuses rather than guessing" \
  || bad "ambiguous main+master refuses rather than guessing"
check "ambiguous repo: nothing is selected for deletion" 0 "$B_OLD" "$aout"
cd "$wk"

# --- no resolvable base means REFUSE, never a guess ---------------------------
nup="$tmp/up3"; git init -q --bare "$nup"
nwk="$tmp/wk3"; git init -q "$nwk"; cd "$nwk"
git config user.email t@t; git config user.name t; git remote add origin "$nup"
echo a > f; git add f; git commit -qm base; git branch -M oddly-named
git branch "$B_OLD" oddly-named; git push -q origin --all
git remote set-head origin -d >/dev/null 2>&1 || true
if nerr="$("$SCRIPT" 2>&1)"; then
  bad "unresolvable base is refused"
else
  printf '%s' "$nerr" | grep -q 'REFUSING' && ok "unresolvable base is refused" \
                                           || bad "unresolvable base is refused (wrong message)"
fi
cd "$wk"

# --- the shallow-clone refusal ------------------------------------------------
# A genuinely shallow repo. NOT `git clone --depth 1`: over file:// git
# optimises the clone and the result is NOT shallow, so the old fixture never
# tested this guard at all -- and the script refused for an unrelated reason
# ("base not found"), which made the test PASS for the wrong reason. A repo is
# shallow exactly when .git/shallow exists, which is what the guard reads.
sh="$tmp/shallow"; git init -q "$sh"
( cd "$sh"; git config user.email t@t; git config user.name t
  git remote add origin "$up"; git fetch -q origin 2>/dev/null
  git rev-parse origin/main > .git/shallow )
# Output is captured BEFORE grepping. Under `set -o pipefail` a pipeline takes
# the script's own non-zero exit, so `"$SCRIPT" | grep -q` reported failure even
# when the message matched -- the check would have reported a broken guard
# whatever the script said.
shmsg="$( (cd "$sh" && BASE=origin/main "$SCRIPT") 2>&1 || true )"
shrc=0; (cd "$sh" && BASE=origin/main "$SCRIPT" >/dev/null 2>&1) || shrc=$?
if [ "$shrc" -eq 0 ]; then
  bad "shallow clone is refused (it did not refuse)"
elif printf '%s' "$shmsg" | grep -q 'shallow'; then
  ok "shallow clone is refused"
else
  bad "shallow clone is refused (refused, but not for shallowness)"
fi

# --- nothing is deleted on a dry run ------------------------------------------
after=$(git ls-remote --heads "$up" | wc -l)
[ "$after" -eq "$before" ] && ok "dry run deleted nothing ($after branches, unchanged)" \
                           || bad "dry run changed the remote ($before -> $after)"

# --- --apply deletes the selected branch, and ONLY that one -------------------
GRACE_DAYS=14 BASE=origin/main "$SCRIPT" --apply >/dev/null 2>&1
remaining="$(git ls-remote --heads "$up" | sed 's#.*refs/heads/##' | sort)"
gone="$B_OLD"
printf '%s\n' "$remaining" | grep -qx "$gone" \
  && bad "--apply deleted the merged, aged branch" \
  || ok "--apply deleted the merged, aged branch"
for keep in "$B_YOUNG" "$B_UNMERGED" "$B_UNDATED" "$B_CLAUDE" "$B_RELEASE" main stray; do
  printf '%s\n' "$remaining" | grep -qx "$keep" \
    && ok "--apply spared $keep" \
    || bad "--apply REMOVED $keep"
done

echo
[ "$fails" -eq 0 ] && { echo "All guards bite."; exit 0; }
echo "$fails guard(s) did NOT bite."; exit 1

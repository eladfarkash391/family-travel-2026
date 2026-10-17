#!/usr/bin/env bash
#
# Delete `backup-*` branches on origin that are fully merged into the base
# branch and older than the grace period.
#
# Why this exists: CLAUDE.md requires a backup branch pushed to origin before
# any `git reset --hard` (the 20/04/2026 ghost-deploy incident). That rule is
# load-bearing in a cloud session, where the container is ephemeral and a
# local-only backup dies with it — so the branches must keep being pushed, and
# something has to clear them up afterwards. 44 had accumulated by 22/09/2026.
#
# A Claude Code session cannot do this itself: its git credential is scoped to
# its own working branch, so a delete push returns 403, and the GitHub
# connector has no delete-branch action. The repository does the deleting, with
# its own GITHUB_TOKEN; a session can only ask the workflow to run.
#
# DRY RUN BY DEFAULT. Pass --apply to actually delete.
#
#   ./scripts/prune-backup-branches.sh              # list what would go
#   ./scripts/prune-backup-branches.sh --apply      # delete them
#
# Env: GRACE_DAYS (default 14), BASE (default origin/main), REMOTE (origin).

set -euo pipefail

GRACE_DAYS="${GRACE_DAYS:-14}"
REMOTE="${REMOTE:-origin}"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

# --- The base branch is RESOLVED, not assumed. --------------------------------
# This script is meant to be dropped into any repository, and hardcoding `main`
# would refuse outright in one on `master` -- safe, but useless, and the reason
# would read as a bug. Order: an explicit BASE wins; then the remote's own HEAD;
# then the two conventional names, each only if it actually exists. CI passes
# BASE explicitly, because `actions/checkout` does not set the remote HEAD ref.
# Nothing is guessed: if none of these resolve, BASE stays empty and the check
# below refuses.
if [ -z "${BASE:-}" ]; then
  if head_ref="$(git symbolic-ref -q "refs/remotes/$REMOTE/HEAD" 2>/dev/null)"; then
    BASE="${head_ref#refs/remotes/}"
  else
    # No remote HEAD (the usual case in a fresh CI checkout). Fall back to the
    # conventional names -- but ONLY when exactly one of them exists.
    #
    # A repo carrying BOTH `main` and `master` is the dangerous case, and
    # preferring either is a guess with teeth: judged against the wrong branch,
    # a backup merged into the stale one reads as merged and is DELETED while
    # its commits are on no live branch. Found by sabotage, not by reading.
    # Ambiguous means refuse; CI passes BASE explicitly and never gets here.
    cands=""
    for c in main master; do
      git rev-parse --verify --quiet "$REMOTE/$c" >/dev/null 2>&1 && cands="$cands $c"
    done
    set -- $cands
    if [ "$#" -eq 1 ]; then BASE="$REMOTE/$1"; else BASE=""; fi
  fi
fi

# --- Guard 1: a shallow clone makes EVERY branch look unmerged. ---------------
# `git merge-base --is-ancestor` walks history it does not have and answers
# "no". On 22/09/2026 that reported all 44 branches as carrying thousands of
# unique commits; after --unshallow, 41 were plain duplicates. A prune that
# trusted the shallow answer would delete nothing, but the same blindness in
# reverse is what makes this check non-optional: never judge reachability on
# history you do not hold.
if [ "$(git rev-parse --is-shallow-repository)" != "false" ]; then
  echo "REFUSING: shallow clone. Run 'git fetch --unshallow' (CI: fetch-depth: 0)." >&2
  exit 1
fi

if [ -z "$BASE" ]; then
  echo "REFUSING: could not resolve a base branch on remote '$REMOTE'." >&2
  echo "Set BASE explicitly, e.g. BASE=$REMOTE/master." >&2
  exit 1
fi
git rev-parse --verify --quiet "$BASE" >/dev/null || {
  echo "REFUSING: base '$BASE' not found." >&2; exit 1; }

now=$(date -u +%s)
cutoff=$(( now - GRACE_DAYS * 86400 ))

to_delete=()
kept_young=(); kept_unmerged=(); kept_undated=()

while read -r ref; do
  name="${ref#"$REMOTE"/}"

  # --- Guard 2: age comes from the NAME, not the commit date. ----------------
  # A backup branch is created from whatever HEAD happened to be, so its tip
  # can be weeks old the moment it is pushed — `backup-premerge-20260804T054826`
  # would have passed a 14-day tip-date test on the day it was made, and the
  # grace period, which exists to cover the window while the session is still
  # doing the reset the backup was taken for, would have protected nothing.
  # Every backup name ends in the UTC timestamp of its creation. Use that.
  stamp="$(printf '%s' "$name" | grep -oE '[0-9]{8}T[0-9]{6}$' || true)"
  if [ -z "$stamp" ]; then
    # --- Guard 3: refuse rather than guess. --------------------------------
    # No parseable creation time means no way to apply the grace, so the
    # branch is kept and reported. Same posture as the closing check: an
    # unreadable case goes to a person, it does not get a default.
    kept_undated+=("$name"); continue
  fi
  d="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}"
  created=$(date -u -d "$d" +%s 2>/dev/null || echo 0)
  if [ "$created" -eq 0 ]; then kept_undated+=("$name"); continue; fi

  if [ "$created" -gt "$cutoff" ]; then
    kept_young+=("$name  ($(( (now - created) / 86400 ))d old)"); continue
  fi

  # --- Guard 4: merged means nothing unique is lost. -------------------------
  # Every commit on the branch is reachable from the base, so deleting the ref
  # removes a label, not history. This is the check that makes auto-delete
  # safe, and it is why no allow-list of branches to spare is needed.
  if ! git merge-base --is-ancestor "$ref" "$BASE"; then
    n=$(git rev-list --count "$BASE..$ref")
    kept_unmerged+=("$name  ($n commit(s) not on ${BASE#"$REMOTE"/})"); continue
  fi

  to_delete+=("$name")
done < <(git for-each-ref --format='%(refname:short)' "refs/remotes/$REMOTE/backup-*")

emit() { # heading, then items
  local h="$1"; shift
  [ "$#" -eq 0 ] && return 0
  printf '\n%s (%d)\n' "$h" "$#"
  printf '  %s\n' "$@"
}

emit "KEPT — inside the ${GRACE_DAYS}-day grace" "${kept_young[@]+"${kept_young[@]}"}"
emit "KEPT — not merged into ${BASE#"$REMOTE"/}" "${kept_unmerged[@]+"${kept_unmerged[@]}"}"
emit "KEPT — no creation timestamp in the name" "${kept_undated[@]+"${kept_undated[@]}"}"
emit "DELETE — merged and older than ${GRACE_DAYS} days" "${to_delete[@]+"${to_delete[@]}"}"

if [ "${#to_delete[@]}" -eq 0 ]; then
  printf '\nNothing to delete.\n'; exit 0
fi

if [ "$APPLY" -ne 1 ]; then
  printf '\nDRY RUN — nothing deleted. Pass --apply to delete these %d branches.\n' "${#to_delete[@]}"
  exit 0
fi

printf '\nDeleting %d branches from %s...\n' "${#to_delete[@]}" "$REMOTE"
git push "$REMOTE" --delete "${to_delete[@]}"
printf 'Deleted %d.\n' "${#to_delete[@]}"

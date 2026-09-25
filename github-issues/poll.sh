#!/bin/sh
# Poll connector. Reads pastor's handshake on stdin, lists the issues of one
# repository that carry a label and changed since the cursor, and prints one
# item per issue plus a cursor as JSON lines on stdout. GitHub is reached
# through `gh api`, so gh's own login is the credential.
set -eu

log() {
  jq -cn --arg level "$1" --arg message "$2" '{type: "log", level: $level, message: $message}'
}

read -r handshake || handshake='{}'
field() {
  printf '%s\n' "$handshake" | jq -r "$1"
}
repo=$(field '.config.repo // "" | tostring')
label=$(field '.config.label // "pastor" | tostring')
state=$(field '.config.state // "open" | tostring')
# The cursor is the newest updated_at of the last run; before there is one,
# pastor's `since` (now minus the job's backfill) bounds the first run.
since=$(field '.cursor // .since // "" | tostring')

if [ -z "$repo" ]; then
  log error "connector.repo is required, as owner/name"
  exit 2
fi
# The repo goes into an API path: keep it to exactly two plain segments.
if ! printf '%s\n' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  log error "connector.repo must be owner/name, not \"$repo\""
  exit 2
fi
case "$state" in
  open | closed | all) ;;
  *)
    log error "connector.state must be open, closed or all, not \"$state\""
    exit 2
    ;;
esac

# The REST list endpoint filters by label, state and `since` (updated at or
# after) server side, unlike `gh issue list --search`, which goes through the
# search index and can lag. It also returns pull requests; items.jq drops them.
set -- -f labels="$label" -f state="$state" -f sort=updated -f direction=asc -f per_page=100
if [ -n "$since" ]; then
  set -- "$@" -f since="$since"
fi
if ! pages=$(gh api --paginate -X GET "repos/$repo/issues" "$@"); then
  log error "gh api failed for $repo; see stderr"
  exit 1
fi

printf '%s\n' "$pages" | jq -c -s --arg repo "$repo" --arg label "$label" --arg state "$state" --arg since "$since" -f items.jq

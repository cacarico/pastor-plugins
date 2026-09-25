#!/bin/sh
# task.done hook. Reads the event record on stdin and comments on the item's
# issue with the task id and its final state, so the person who filed the
# issue learns the agent stopped without watching pastor.
set -eu

event=$(cat)
url=$(printf '%s\n' "$event" | jq -r '.task.item.url // ""')
if [ -z "$url" ]; then
  echo "event has no task.item.url; nothing to comment on" >&2
  exit 0
fi
body=$(printf '%s\n' "$event" | jq -r '
  "pastor task t-\(.task.id) finished with state `\(.task.state)`"
  + (if .task.machine then " on \(.task.machine)" else "" end)
  + "."
  + (if .task.error then "\n\nError: \(.task.error)" else "" end)
')
gh issue comment "$url" --body "$body"

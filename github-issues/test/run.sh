#!/bin/sh
# Runs poll.sh and hook.sh against the fake gh in test/bin, which answers
# from canned JSON, so item shaping and the comment are checked offline.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$here/bin:$PATH"
export GH_ARGS="$tmp/gh-args"
export GH_FIXTURE="$here/issues.json"
cd "$here/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

gh_got() {
  grep -qx -- "$1" "$GH_ARGS" || fail "gh was not called with $1"
}

echo "poll: items and cursor from a fixture, since taken from the cursor"
printf '%s\n' '{"config":{"repo":"acme/widgets"},"cursor":"2026-09-20T08:00:00Z","since":"2026-09-01T00:00:00Z"}' \
  | sh poll.sh > "$tmp/out"
jq -S -c . "$tmp/out" > "$tmp/got"
jq -S -c . test/expected.jsonl > "$tmp/want"
diff -u "$tmp/want" "$tmp/got" || fail "poll output differs from test/expected.jsonl"
gh_got api
gh_got --paginate
gh_got repos/acme/widgets/issues
gh_got labels=pastor
gh_got state=open
gh_got since=2026-09-20T08:00:00Z

echo "poll: label and state from the config, since from the handshake when there is no cursor"
printf '%s\n' '{"config":{"repo":"acme/widgets","label":"agent","state":"all"},"cursor":null,"since":"2026-09-01T00:00:00Z"}' \
  | sh poll.sh > "$tmp/out"
gh_got labels=agent
gh_got state=all
gh_got since=2026-09-01T00:00:00Z

echo "poll: nothing new means no items and no cursor"
printf '[]\n' > "$tmp/empty.json"
printf '%s\n' '{"config":{"repo":"acme/widgets"},"cursor":null,"since":"2026-09-01T00:00:00Z"}' \
  | GH_FIXTURE="$tmp/empty.json" sh poll.sh > "$tmp/out"
if jq -e 'select(.type != "log")' "$tmp/out" > /dev/null; then
  fail "an empty page produced items or a cursor"
fi

echo "poll: a config without repo is refused before gh runs"
rm -f "$GH_ARGS"
if printf '%s\n' '{"config":{},"cursor":null,"since":"2026-09-01T00:00:00Z"}' | sh poll.sh > "$tmp/out" 2> /dev/null; then
  fail "accepted a config without repo"
fi
[ ! -e "$GH_ARGS" ] || fail "gh ran without a repo"
jq -e 'select(.type == "log" and .level == "error")' "$tmp/out" > /dev/null || fail "no error log for the missing repo"

echo "poll: a repo that is not owner/name is refused"
if printf '%s\n' '{"config":{"repo":"acme/widgets/issues?x=1"},"cursor":null,"since":"2026-09-01T00:00:00Z"}' | sh poll.sh > /dev/null 2>&1; then
  fail "accepted a repo with a path in it"
fi

echo "hook: task.done comments on the issue with the task id and state"
sh hook.sh < test/event.json
gh_got issue
gh_got comment
gh_got https://github.com/acme/widgets/issues/12
gh_got --body
grep -q 't-7' "$GH_ARGS" || fail "the comment does not name task t-7"
grep -q 'done' "$GH_ARGS" || fail "the comment does not name the state"

echo "hook: an event without an item url is ignored"
rm -f "$GH_ARGS"
printf '%s\n' '{"type":"task.done","task":null}' | sh hook.sh
[ ! -e "$GH_ARGS" ] || fail "gh ran for an event without an issue"

echo "ok"

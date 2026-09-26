#!/bin/sh
# Runs poll.sh against the fake gh in test/bin, which answers from canned
# JSON, so review selection and item shaping are checked offline.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$here/bin:$PATH"
export GH_ARGS="$tmp/gh-args"
export GH_FIXTURE="$here/pulls.json"
cd "$here/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

gh_got() {
  grep -qx -- "$1" "$GH_ARGS" || fail "gh was not called with $1"
}

# The keys of the items in $tmp/out, comma separated, in output order.
keys() {
  jq -r 'select(.type == "item") | .key' "$tmp/out" | paste -sd, -
}

cursor() {
  jq -r 'select(.type == "cursor") | .value' "$tmp/out"
}

echo "poll: one item per new review with unresolved comments, since taken from the cursor"
printf '%s\n' '{"config":{"repo":"acme/widgets"},"cursor":"2026-09-20T08:00:00Z","since":"2026-09-01T00:00:00Z"}' \
  | sh poll.sh > "$tmp/out"
jq -S -c . "$tmp/out" > "$tmp/got"
jq -S -c . test/expected.jsonl > "$tmp/want"
diff -u "$tmp/want" "$tmp/got" || fail "poll output differs from test/expected.jsonl"
gh_got api
gh_got graphql
gh_got --paginate
gh_got owner=acme
gh_got name=widgets
# Every nested list asks whether it was cut short, so items.jq can tell.
[ "$(grep -c 'pageInfo { hasNextPage }' "$GH_ARGS")" = 3 ] || fail "a nested list in the query lacks pageInfo"

echo "poll: only_with_findings = false keeps clean reviews, since from the handshake when there is no cursor"
printf '%s\n' '{"config":{"repo":"acme/widgets","only_with_findings":false},"cursor":null,"since":"2026-09-01T00:00:00Z"}' \
  | sh poll.sh > "$tmp/out"
[ "$(keys)" = "8000,9003,9001" ] || fail "expected reviews 8000,9003,9001, got $(keys)"
[ "$(jq -r 'select(.key == "9003") | .body' "$tmp/out")" = "" ] || fail "the clean review has a body"
[ "$(cursor)" = "2026-09-25T09:00:00Z" ] || fail "cursor is $(cursor)"

echo "poll: the reviewer regex picks whose reviews count, ignoring case"
printf '%s\n' '{"config":{"repo":"acme/widgets","reviewer":"^ANA$"},"cursor":"2026-09-20T08:00:00Z"}' \
  | sh poll.sh > "$tmp/out"
[ "$(keys)" = "9002" ] || fail "expected review 9002, got $(keys)"
jq -e 'select(.key == "9002") | .body == "## 503\nsrc/login.rs:30\nGood catch, will fix."' "$tmp/out" > /dev/null \
  || fail "review 9002 does not carry only its own comment"

echo "poll: nothing new means no items and no cursor"
printf '%s\n' '{"config":{"repo":"acme/widgets"},"cursor":"2026-09-26T00:00:00Z"}' | sh poll.sh > "$tmp/out"
if jq -e 'select(.type != "log")' "$tmp/out" > /dev/null; then
  fail "a run with no new reviews produced items or a cursor"
fi

echo "poll: a repo with no open pull requests gives no items and no cursor"
printf '%s\n' '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' > "$tmp/empty.json"
printf '%s\n' '{"config":{"repo":"acme/widgets"},"cursor":null,"since":"2026-09-01T00:00:00Z"}' \
  | GH_FIXTURE="$tmp/empty.json" sh poll.sh > "$tmp/out"
if jq -e 'select(.type != "log")' "$tmp/out" > /dev/null; then
  fail "an empty page produced items or a cursor"
fi

# Writes a copy of the fixture with $1, a jq filter, applied to pull request
# #41, and points gh at it.
pr41() {
  jq "(.data.repository.pullRequests.nodes[] | select(.number == 41)) |= ($1)" test/pulls.json > "$tmp/fixture.json"
}

warned() {
  jq -e --arg re "$1" 'select(.type == "log" and .level == "warn" and (.message | test($re)))' "$tmp/out" > /dev/null \
    || fail "no warning matching $1"
}

echo "poll: a head branch that is not shell-safe makes no item, but still moves the cursor"
for branch in 'x;touch pwned' '$(id)' '-f' 'a..b' 'has space' 'a`b`' "it's"; do
  pr41 ".headRefName = $(jq -n --arg b "$branch" '$b')"
  printf '%s\n' '{"config":{"repo":"acme/widgets"},"cursor":"2026-09-20T08:00:00Z"}' \
    | GH_FIXTURE="$tmp/fixture.json" sh poll.sh > "$tmp/out"
  [ "$(keys)" = "" ] || fail "branch $branch made items $(keys)"
  warned '#41'
  [ "$(cursor)" = "2026-09-25T09:00:00Z" ] || fail "cursor is $(cursor) with branch $branch"
done
pr41 '.headRefName = "user/feat_x-1.2"'
printf '%s\n' '{"config":{"repo":"acme/widgets"},"cursor":"2026-09-20T08:00:00Z"}' \
  | GH_FIXTURE="$tmp/fixture.json" sh poll.sh > "$tmp/out"
[ "$(keys)" = "9001" ] || fail "a safe branch made items $(keys)"

echo "poll: truncated threads or comments make no item from that pull request and hold the cursor at its first new review"
for trunc in '.reviewThreads.pageInfo.hasNextPage = true' '.reviewThreads.nodes[1].comments.pageInfo.hasNextPage = true'; do
  pr41 "$trunc"
  printf '%s\n' '{"config":{"repo":"acme/widgets","only_with_findings":false},"cursor":null,"since":"2026-09-01T00:00:00Z"}' \
    | GH_FIXTURE="$tmp/fixture.json" sh poll.sh > "$tmp/out"
  [ "$(keys)" = "9003" ] || fail "with $trunc expected review 9003, got $(keys)"
  warned '#41'
  [ "$(cursor)" = "2026-09-10T09:00:00Z" ] || fail "with $trunc cursor is $(cursor)"
done

echo "poll: truncated reviews make no item from that pull request and keep the cursor where it was"
pr41 '.reviews.pageInfo.hasNextPage = true'
printf '%s\n' '{"config":{"repo":"acme/widgets","only_with_findings":false},"cursor":"2026-09-05T00:00:00Z"}' \
  | GH_FIXTURE="$tmp/fixture.json" sh poll.sh > "$tmp/out"
[ "$(keys)" = "9003" ] || fail "expected review 9003, got $(keys)"
warned '#41'
[ "$(cursor)" = "2026-09-05T00:00:00Z" ] || fail "cursor is $(cursor)"

refused() {
  rm -f "$GH_ARGS"
  if printf '%s\n' "$2" | sh poll.sh > "$tmp/out" 2> /dev/null; then
    fail "accepted $1"
  fi
  [ ! -e "$GH_ARGS" ] || fail "gh ran with $1"
  jq -e 'select(.type == "log" and .level == "error")' "$tmp/out" > /dev/null || fail "no error log for $1"
}

echo "poll: bad config is refused before gh runs"
refused "a config without repo" '{"config":{},"cursor":null}'
refused "a repo with a path in it" '{"config":{"repo":"acme/widgets/pulls?x=1"},"cursor":null}'
refused "a reviewer that is not a regex" '{"config":{"repo":"acme/widgets","reviewer":"("},"cursor":null}'
refused "only_with_findings = \"yes\"" '{"config":{"repo":"acme/widgets","only_with_findings":"yes"},"cursor":null}'

echo "ok"

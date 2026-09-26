#!/bin/sh
# Poll connector. Reads pastor's handshake on stdin, lists the open pull
# requests of one repository with their reviews and review threads, and
# prints one item per new review by a matching reviewer plus a cursor as JSON
# lines on stdout. GitHub is reached through `gh api graphql`, so gh's own
# login is the credential.
set -eu

log() {
  jq -cn --arg level "$1" --arg message "$2" '{type: "log", level: $level, message: $message}'
}

read -r handshake || handshake='{}'
field() {
  printf '%s\n' "$handshake" | jq -r "$1"
}
repo=$(field '.config.repo // "" | tostring')
reviewer=$(field '.config.reviewer // "copilot" | tostring')
# Not `// true`: jq's alternative operator treats false as missing.
only_with_findings=$(field 'if .config.only_with_findings == null then "true" else .config.only_with_findings | tostring end')
# The cursor is the newest submittedAt of the last run; before there is one,
# pastor's `since` (now minus the job's backfill) bounds the first run.
since=$(field '.cursor // .since // "" | tostring')

if [ -z "$repo" ]; then
  log error "connector.repo is required, as owner/name"
  exit 2
fi
# The repo goes into a query: keep it to exactly two plain segments.
if ! printf '%s\n' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  log error "connector.repo must be owner/name, not \"$repo\""
  exit 2
fi
# A bad regex would otherwise fail inside items.jq, after the API calls.
if ! jq -n --arg re "$reviewer" '"" | test($re; "i")' > /dev/null 2>&1; then
  log error "connector.reviewer is not a valid regex: \"$reviewer\""
  exit 2
fi
case "$only_with_findings" in
  true | false) ;;
  *)
    log error "connector.only_with_findings must be true or false, not \"$only_with_findings\""
    exit 2
    ;;
esac

# One query per page of pull requests brings their reviews and review
# threads too. Resolution lives on the thread, which only GraphQL exposes.
# The page sizes keep the query under GitHub's node limit
# (25 * (100 + 100 * 50)). Nested lists are not paginated; items.jq skips a
# pull request that has more and holds the cursor for it.
query='
query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 25, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        title
        headRefName
        headRefOid
        reviews(first: 100) {
          pageInfo { hasNextPage }
          nodes { fullDatabaseId url submittedAt author { login } }
        }
        reviewThreads(first: 100) {
          pageInfo { hasNextPage }
          nodes {
            isResolved
            comments(first: 50) {
              pageInfo { hasNextPage }
              nodes { fullDatabaseId path line originalLine body pullRequestReview { fullDatabaseId } }
            }
          }
        }
      }
    }
  }
}'
if ! pages=$(gh api graphql --paginate -f query="$query" -f owner="${repo%%/*}" -f name="${repo#*/}"); then
  log error "gh api graphql failed for $repo; see stderr"
  exit 1
fi

printf '%s\n' "$pages" | jq -c -s \
  --arg repo "$repo" --arg reviewer "$reviewer" --arg since "$since" \
  --argjson only_with_findings "$only_with_findings" \
  -f items.jq

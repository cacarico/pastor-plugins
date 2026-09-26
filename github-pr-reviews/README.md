# github-pr-reviews

A [pastor](https://github.com/cacarico/pastor) connector that turns review
findings on GitHub pull requests into tasks. Each run lists the open pull
requests of one repository and their reviews, and emits one item per review
by a matching reviewer (Copilot by default). The item carries the review's
unresolved inline comments, so a job can start an agent that fixes them on
the pull request's branch.

GitHub is reached through the `gh` CLI, so the login `gh` already has on the
head is the only credential. The connector declares no secrets and needs
nothing in `.env`. It needs `gh`, `jq` and a POSIX `sh` on the head. It has
no hook.

## Install

```bash
pastor connector install cacarico/pastor-connectors/github-pr-reviews
# or, from a checkout:
pastor connector link ./github-pr-reviews
```

## Job

```toml
# ~/.config/pastor/jobs/widgets-reviews.toml
enabled = false   # start it with `pastor job enable widgets-reviews`
every = "10m"

[connector]
use = "github-pr-reviews"
repo = "acme/widgets"        # required, owner/name
reviewer = "copilot"         # default; a regex on the reviewer's login, ignoring case
only_with_findings = true    # default; skip reviews with nothing unresolved

[dispatch]
repo = "~/work/widgets"
worktree = true
branch = "pastor/review-{{ item.key }}"
backfill = "1d"
max_tasks_per_run = 2
prompt = """
You are in a worktree of widgets, task {{ task.id }}. Put it on the head of
pull request #{{ item.pr }} ({{ item.title }}) before anything else:

    git fetch origin {{ item.branch }}
    git reset --hard origin/{{ item.branch }}

A review left the findings below, each a comment id, a file and line, and
the comment. Review: {{ item.review_url }}

{{ item.body }}

Fix each finding that is right and say why for each one you leave. Commit,
push with `git push origin HEAD:{{ item.branch }}`, and print DONE as your
last line.
"""
```

pastor does not let an item name the branch a worktree is created on: an
item value in `branch` must be one path component, never the first one, so
it cannot point an agent at `main` (and head branches often hold a `/`).
The worktree gets a branch of its own, and the prompt moves it to the pull
request's head and pushes back there.

Each item has `key` (the review id, as a string), `pr` (the pull request
number), `title` (the pull request's title), `branch` (its head branch),
`head` (the head commit's sha), `review_url` and `body`. The body holds one
section per unresolved inline comment of that review:

```
## 2934017465
src/limit.rs:12
The window is never reset, so a client stays blocked forever.
```

A comment is unresolved when its review thread is not resolved. Replies in a
thread belong to other reviews and are left out. The line is the comment's
current line, or the line it was made on when the code has moved since. With
`only_with_findings = false`, a review with no unresolved comments is still
an item, with an empty body.

## How runs are bounded

Every run reads all open pull requests, then looks only at reviews submitted
at or after a point in time, and emits a cursor with the newest review's
`submittedAt`; the next run starts there. Any reviewer's review moves the
cursor, whether or not it made an item. Before the first cursor exists, the
bound is pastor's `since`: now minus the job's `backfill`, which defaults to
zero, so without a `backfill` the first run only sees reviews that arrive
after the job was enabled.

A review makes one task. pastor remembers the keys it has queued, and
resolving threads later does not change a review's id. A fix pushed to the
branch usually brings a new review, which is a new item.

Each pull request contributes at most 100 reviews and 100 review threads,
and each thread 50 comments. A pull request past those is logged with level
`warn`.

## Try it

```bash
pastor connector link ./github-pr-reviews
pastor connector run github-pr-reviews --job widgets-reviews --since 7d   # prints items, creates nothing
pastor connector unlink github-pr-reviews
```

`connector run` reads the job's `[connector]` table from its file, which may
have `enabled = false`, so the job above can be tried before it is enabled.

## Test

```bash
make check
```

`test/run.sh` puts a fake `gh` first on `PATH` that answers `gh api graphql`
from `test/pulls.json` (two pull requests: one Copilot review with two
unresolved findings and a resolved one, one clean review) and records its
arguments, then checks the emitted lines against `test/expected.jsonl`, the
reviewer and `only_with_findings` settings, the cursor and the config
validation. Nothing touches the network.

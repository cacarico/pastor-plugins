# github-issues

A [pastor](https://github.com/cacarico/pastor) connector that turns GitHub
issues into tasks. Each run lists the issues of one repository that carry a
label and emits one item per issue; pastor queues a task for each item it
has not seen. When a task is done, a hook comments on its issue with the
task id and final state.

GitHub is reached through the `gh` CLI, so the login `gh` already has on the
head is the only credential. The connector declares no secrets and needs
nothing in `.env`. It needs `gh`, `jq` and a POSIX `sh` on the head.

## Install

```bash
pastor connector install cacarico/pastor-connectors/github-issues
# or, from a checkout:
pastor connector link ./github-issues
```

## Job

```toml
# ~/.config/pastor/jobs/widgets.toml
every = "10m"

[connector]
use = "github-issues"
repo = "acme/widgets"   # required, owner/name
label = "pastor"        # default
state = "open"          # default; open, closed or all

[dispatch]
repo = "~/work/widgets"
worktree = true
branch = "issue-{{ item.key }}"
backfill = "30d"
max_tasks_per_run = 2
prompt = """
You are in a worktree of widgets on branch issue-{{ item.key }}, task {{ task.id }}.
Fix GitHub issue #{{ item.key }} by {{ item.author }}: {{ item.title }}
{{ item.url }}

{{ item.body }}

Commit, push the branch, open a pull request whose body says
"Closes #{{ item.key }}", and print DONE as your last line.
"""
```

Each item has `key` (the issue number, as a string), `title`, `body` (empty
when the issue has none), `url` and `author` (the GitHub login). Pull
requests are skipped even when they carry the label.

## How runs are bounded

The connector asks GitHub for issues updated at or after a point in time and
emits a cursor with the newest `updated_at` it saw; the next run starts
there. Before the first cursor exists, the bound is pastor's `since`: now
minus the job's `backfill`, which defaults to zero. Set `backfill` to how far
back the first run should look, or the job starts with an empty list and
only picks up issues touched after it was enabled.

An issue makes one task. pastor remembers the keys it has queued, so a later
edit or comment on the same issue does not queue another.

## The hook

On `task.done` the hook comments on the issue:

> pastor task t-7 finished with state `done` on pi-3.

`only_own = true` keeps it to tasks this connector queued. `done` means the
agent went idle, not that the work is good; the comment is a prompt to look
at the task's output and the pull request, if any.

## Try it

```bash
pastor connector link ./github-issues
pastor connector run github-issues --job widgets --since 90d   # prints items, creates nothing
pastor connector unlink github-issues
```

`connector run` reads the job's `[connector]` table from its file, which may
have `enabled = false`.

## Test

```bash
make check
```

`test/run.sh` puts a fake `gh` first on `PATH` that answers `gh api` from
`test/issues.json` and records its arguments, then checks the emitted lines
against `test/expected.jsonl`, the query the connector sends, the config
validation, and the hook's comment. Nothing touches the network.

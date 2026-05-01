# claude-cluster

Run multiple [Claude Code](https://docs.claude.com/en/docs/claude-code) instances in parallel — each in its own git worktree on its own branch — from a single command.

```bash
claude-cluster start feature-auth   --auto-branch
claude-cluster start hotfix-api     --branch hotfix/api-500
claude-cluster list
claude-cluster kill feature-auth
```

## Why

Each Claude Code session is independent: a separate UUID, transcript, and context. But running two sessions from the same checkout makes them fight over your working tree. `claude-cluster` solves that by spawning each session in a dedicated git worktree on a dedicated branch, so they can edit files in true isolation.

## Requirements

- macOS (uses `osascript` to open Terminal windows)
- bash 3.2+ (works with the version macOS ships)
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq`
- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) on `$PATH`
- A git repository to spawn sessions against

## Install

```bash
git clone https://github.com/<your-username>/claude-cluster.git
cd claude-cluster
./install.sh
```

`install.sh` symlinks the script into `~/bin/claude-cluster` and checks dependencies. If `~/bin` isn't on your `$PATH`, add it:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Install somewhere else with:

```bash
CLAUDE_CLUSTER_INSTALL_DIR=/usr/local/bin ./install.sh
```

To uninstall, remove the symlink:

```bash
rm ~/bin/claude-cluster
```

State (`sessions.json` and worktrees) lives at `~/.claude/cluster/` and isn't touched by uninstall.

## Setup on a new device

```bash
git clone https://github.com/<your-username>/claude-cluster.git ~/code/claude-cluster
cd ~/code/claude-cluster
./install.sh
```

That's it — no per-device config beyond installing dependencies (`jq`, `claude`).

## Quick start

```bash
cd ~/projects/my-repo

# Start an isolated session on a new claude/feature-auth branch
claude-cluster start feature-auth --auto-branch

# Start another in parallel on an existing branch
claude-cluster start hotfix-api --branch hotfix/api-500

# See what's running
claude-cluster list

# Kill one (also removes its worktree and branch checkout)
claude-cluster kill feature-auth

# Kill them all
claude-cluster kill --all
```

## Commands

### `start <name>`

Start a new Claude session.

| Flag | Effect |
|------|--------|
| `--auto-branch` | Create branch `claude/<name>` and a worktree for it (recommended) |
| `--branch <branch>` | Use a specific branch (existing or new) and create a worktree |
| `--orchestrate` | Enable orchestration: Claude can spawn fanouts and QA workers itself (see [Orchestration](#orchestration)) |
| `--dir <directory>` | Run from a different directory (default: cwd) |

Without `--branch` or `--auto-branch`, the session runs on the current branch in the current directory — no isolation. Use this only when you really mean it.

### `list` (alias `ls`)

List all active sessions. Stale entries (PIDs that no longer exist) are reaped automatically. Fanout workers appear here too, with a `parent` field linking them to their fanout.

### `kill <name>` (alias `stop`)

Terminate a session OR a fanout. For a single session: SIGTERM, then SIGKILL after 1s if needed; removes the worktree. For a fanout: kills every child worker (and QA, if any), then removes the coordination dir.

```bash
claude-cluster kill feature-auth        # single session
claude-cluster kill retry-design        # fanout (cleans up all workers)
claude-cluster kill --all               # everything
```

### `status <name>`

For a single session: human-readable details (PID, branch, started, working dir, running/not-running, parent fanout if applicable).

For a fanout (when `<name>` matches a coordination dir): emits **JSON** describing each worker's state, the QA's state if spawned, and the fanout's metadata. Designed for an orchestrator Claude to parse with `jq`.

```bash
claude-cluster status feature-auth      # human-readable
claude-cluster status retry-design      # JSON
```

### `fanout <name>`

Spawn N parallel workers, each in its own git worktree on its own branch (`claude/<name>-w<i>`). Workers run non-interactively (`claude -p`) in the background, write a `summary.md` to `~/.claude/cluster/coordination/<name>/worker-<i>/`, commit their work to their branch, and exit.

| Flag | Effect |
|------|--------|
| `--task "<task>"` | The overall task all workers tackle (required) |
| `--approach "<hint>"` | Approach hint for one worker (repeatable; one per worker) |
| `--base <branch>` | Base branch to fork worktrees from (default: current branch) |

Run from inside the git repo whose tree you want workers to operate on. Each `--approach` produces one worker. 2-4 approaches is the sweet spot.

```bash
claude-cluster fanout retry-design \
    --task "implement payment retry logic" \
    --approach "exponential backoff with jitter" \
    --approach "fixed retry with circuit breaker" \
    --approach "queue-based retry with workers"
```

### `qa <fanout-name>`

Spawn a fresh-eyes reviewer over a specific branch produced by a fanout. Runs in its own worktree on the target branch (read-only review — must not modify or commit). Writes its review to `~/.claude/cluster/coordination/<fanout-name>/qa/summary.md`.

| Flag | Effect |
|------|--------|
| `--branch <branch>` | Branch to review (required) |
| `--task "<criteria>"` | Review criteria (required) |

```bash
claude-cluster qa retry-design \
    --branch claude/retry-design-w1 \
    --task "race conditions, error paths, edge cases"
```

Only one QA per fanout at a time.

### `update`

Pull the latest version of `claude-cluster` from the cloned repo and apply any pending data migrations:

```bash
claude-cluster update
```

Requires the git-clone install (`install.sh` symlinks the script back to your local clone, so the running script knows where the repo lives). Refuses to pull if the repo has uncommitted changes. If you copied the script in by hand, update manually instead: `cd <your-clone> && git pull`.

After pulling, the script re-execs itself so any new migrations run under the new code.

### `help`

Print the help text.

## How it works

- Sessions are tracked in `~/.claude/cluster/sessions.json` — `schema_version` plus an array of `{name, pid, branch, started, working_dir, parent?}` entries. The optional `parent` field links fanout workers (and QA reviewers) to their fanout.
- When you pass `--auto-branch` or `--branch`, the script runs `git worktree add` against the repo you're currently inside, creating `~/.claude/cluster/worktrees/<repo>/<name>/`.
- A new Terminal window is opened via `osascript`, which `cd`s into the worktree and launches `claude`. With `--orchestrate`, the launch line additionally passes `--append-system-prompt-file` pointing at `prompts/orchestrate.md`.
- Fanout workers run **non-interactively** (`claude -p`) as background subshells — no terminal popups. Each writes its output stream to `output.log` and a structured summary to `summary.md` in its coordination dir.
- `kill` removes the session entry, sends signals to the PID, and runs `git worktree remove --force` to clean up. For a fanout, `kill` recursively kills every worker + QA and removes the coordination dir.
- Pending data migrations run on every command via `migrate_sessions` (no-op when state is already at `SCHEMA_VERSION`).

## Orchestration

`claude-cluster start --orchestrate` gives a Claude session the ability to spawn **its own** parallel sub-agents. Use it for tasks where you want Claude to fan out across approaches (or independent todos), then consolidate.

### How it works

The `--orchestrate` flag passes `--append-system-prompt-file prompts/orchestrate.md` to `claude`. That file teaches Claude:

- The shape of `claude-cluster fanout`, `status`, `qa`, and `kill`.
- **When to fan out**: multiple genuinely-independent sub-tasks, or 2-4 distinct approaches worth comparing.
- **When NOT to fan out** (most tasks): bug fixes, small mechanical work, tightly-coupled sub-results.
- The expected workflow: decompose → spawn → poll status → read summaries → optionally QA → audit → synthesize.

Workers themselves do **not** get `--orchestrate`, so they cannot fan out further. Recursion is bounded by design.

### Manager / worker / QA roles

| Role | What it does | How it's invoked |
|------|--------------|------------------|
| **Manager** | Decomposes the task, spawns workers, audits results, synthesizes a final answer | `claude-cluster start <name> --auto-branch --orchestrate` (interactive) |
| **Worker** | Implements one specific approach in its own worktree, commits to its branch, writes a summary, exits | Spawned by manager via `claude-cluster fanout` (non-interactive) |
| **QA** | Reviews a worker's branch with no prior context, reports verdict + issues, exits | Spawned by manager via `claude-cluster qa` (non-interactive) |

### Coordination directory

Each fanout gets a directory at `~/.claude/cluster/coordination/<name>/`:

```
coordination/<fanout-name>/
├── meta.json                 # task, base branch, repo info, approaches list
├── worker-1/
│   ├── status                # starting | running | done | failed | terminated
│   ├── approach.txt          # this worker's --approach hint
│   ├── system-prompt.md      # rendered worker prompt (debug aid)
│   ├── summary.md            # worker writes this when done
│   └── output.log            # full claude -p stdout/stderr
├── worker-2/...
└── qa/                       # only if claude-cluster qa was run
    ├── status
    ├── branch.txt
    ├── criteria.txt
    ├── system-prompt.md
    ├── summary.md
    └── output.log
```

The manager Claude reads from this tree (via shell tools) to track progress and gather results. It can run `claude-cluster status <name>` to get a JSON summary suitable for `jq`.

### Manual fanout

You don't need `--orchestrate` to fan out — you can run `claude-cluster fanout` yourself any time, then read the summaries by hand. `--orchestrate` just lets a Claude session do this same thing autonomously.

### When NOT to enable orchestration

Most sessions should run without `--orchestrate`:

- Routine feature work — Claude does it well solo.
- Bug fixes — fanout multiplies cost without comparison value.
- Anything where the task is under-specified up front — workers can't recover from a vague brief.

Reserve `--orchestrate` for sessions where you genuinely expect Claude to need parallel exploration. Token cost scales linearly with worker count.

## Updating

`sessions.json` carries a `schema_version` field so the script can migrate local data forward without forcing fresh installs to replay history.

- **Fresh installs** start at the current `SCHEMA_VERSION` directly — `init_sessions` writes the latest layout, no migrations replay.
- **Existing installs** auto-run any pending migrations (`current_version < SCHEMA_VERSION`) on the next command, or explicitly via `claude-cluster update`.

Migrations live in the `migrate_sessions` function — small, idempotent `jq` transforms guarded by `if (( current < N ))`.

To add a migration:

1. Bump `SCHEMA_VERSION` at the top of the script.
2. Append a new `if (( current < N ))` block to `migrate_sessions` with the transform.
3. Update `init_sessions` so a fresh install writes the new layout directly (avoiding the migration on day one).
4. Run `bash tests/test_schema.sh` — the regression test fails if `init_sessions` and `migrate_sessions` produce different shapes.

The fast-path init means the JSON shape lives in two places — `init_sessions` (the target) and the most recent migration block (the transition into it). The test in step 4 is what guarantees they stay in sync.

## Tests

```bash
for f in tests/test_*.sh; do bash "$f" || break; done
```

Or run them individually:

| File | What it covers |
|------|----------------|
| `tests/test_schema.sh` | Migration system: fresh install lands at `SCHEMA_VERSION`, legacy data migrates to the same shape, migrations are idempotent, session entries survive migration intact. |
| `tests/test_fanout.sh` | Fanout / QA / orchestrate: help text coverage, argument validation for `fanout` and `qa`, fanout JSON status output, fanout kill cleanup, plus sourced unit tests for `substitute_template` and `is_fanout`. No `claude` invocations — all tests stub state on disk. |

The test suite drives the script under a sandboxed `HOME` (no mocking, no token-burning workers). Requires `jq` and `bash`. Runs in under two seconds total.

CI runs both files on every push (see `.github/workflows/test.yml`).

## Workflow patterns

### Parallel features

```bash
claude-cluster start auth-login   --auto-branch
claude-cluster start api-refactor --auto-branch
claude-cluster list
```

### Hotfix without disturbing in-flight work

```bash
# already coding on feature-x in the current terminal
claude-cluster start hotfix-prod --branch hotfix/prod-500
# fix in the new terminal, commit, push, then:
claude-cluster kill hotfix-prod
```

### Multiple repos

```bash
claude-cluster start projA-task --dir ~/work/projA --auto-branch
claude-cluster start projB-task --dir ~/work/projB --auto-branch
```

## Tips

- **Always pass `--auto-branch` or `--branch`.** Running multiple sessions on the same branch creates merge headaches.
- **Use descriptive names.** `feature-user-auth` beats `task1`. Names allowed: `[a-zA-Z0-9_-]+`.
- **Stagger launches by ~3s** if starting several at once — avoids the PID-discovery race in `osascript`.
- **Watch resource usage.** 3–4 concurrent sessions is a comfortable ceiling on most laptops; each one drives independent CPU, memory, and API spend.
- **Keep branches in sync.** Commit and push from each worktree before killing the session.
- **Coordinate file ownership.** Two sessions touching the same file will conflict at merge time even though they edit in isolated worktrees.

## Customizing

The script is short — open `claude-cluster` and tweak directly. The most common knobs:

- **Model / launch flags** — search for `claude-opus-4-7` in `cmd_start` to change the model or remove flags like `--dangerously-skip-permissions`.
- **State location** — `CLUSTER_DIR` and `WORKTREE_BASE` near the top of the script.
- **Terminal app** — the `osascript` block targets `Terminal`. Swap for iTerm2 if preferred.

## Troubleshooting

**`jq is required but not installed`** — `brew install jq`.

**`Session 'X' already exists`** — kill it first (`claude-cluster kill X`) or pick a new name.

**`Failed to find Claude process`** — the `claude` binary isn't on `$PATH`, or Terminal automation is blocked. Try `which claude` and launching `claude` manually.

**Stale entries in `list`** — `claude-cluster list` reaps them automatically. If state file is corrupted, `rm ~/.claude/cluster/sessions.json` and start fresh.

**`claude-cluster: command not found`** — `~/bin` isn't on `$PATH`. Add `export PATH="$HOME/bin:$PATH"` to `~/.zshrc` (or your shell's config) and reload.

**Worktree won't delete** — if `kill` fails to remove the worktree (e.g. uncommitted changes), `cd` into the main repo and run `git worktree remove --force <path>` manually.

## Limitations

- macOS only (Terminal automation via `osascript`).
- API costs scale linearly per session.
- No shared context between instances — by design.
- One active session per name at a time.

## Roadmap

- iTerm2 / Linux terminal support
- Configurable model and launch flags via env or config file
- `attach <name>` to refocus an existing session's window
- `prune` to clean up orphaned worktrees

## Layout

```
claude-cluster/
├── claude-cluster        # the bash script
├── install.sh            # symlinks the script into $PATH
├── prompts/
│   ├── orchestrate.md    # system prompt for --orchestrate sessions
│   ├── worker.md         # template for fanout workers
│   └── qa.md             # template for QA reviewers
├── tests/
│   └── test_schema.sh    # migration regression test
├── .github/workflows/
│   └── test.yml          # CI: lint + tests on every push
├── README.md             # this file
└── .gitignore
```

Runtime state (not in this repo):

```
~/.claude/cluster/
├── sessions.json
└── worktrees/<repo>/<session>/
```

## License

No license set yet — add a `LICENSE` file (MIT is a reasonable default for a personal tool you want others to be able to use).

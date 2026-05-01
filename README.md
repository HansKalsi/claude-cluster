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
- bash 4+
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
| `--dir <directory>` | Run from a different directory (default: cwd) |

Without `--branch` or `--auto-branch`, the session runs on the current branch in the current directory — no isolation. Use this only when you really mean it.

### `list` (alias `ls`)

List all active sessions. Stale entries (PIDs that no longer exist) are reaped automatically.

### `kill <name>` (alias `stop`)

Terminate a session: SIGTERM, then SIGKILL after 1s if needed. Removes the worktree if one was created.

```bash
claude-cluster kill feature-auth
claude-cluster kill --all
```

### `status <name>`

Show details of a single session (PID, branch, started timestamp, working dir, running/not-running).

### `help`

Print the help text.

## How it works

- Sessions are tracked in `~/.claude/cluster/sessions.json` (name, PID, branch, started, working dir).
- When you pass `--auto-branch` or `--branch`, the script runs `git worktree add` against the repo you're currently inside, creating `~/.claude/cluster/worktrees/<repo>/<name>/`.
- A new Terminal window is opened via `osascript`, which `cd`s into the worktree and launches `claude`.
- `kill` removes the entry, sends signals to the PID, and runs `git worktree remove --force` to clean up.

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

- **Model / launch flags** — search for `claude --model` in `cmd_start` to change the model or remove flags like `--dangerously-skip-permissions`.
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
├── claude-cluster   # the bash script
├── install.sh       # symlinks the script into $PATH
├── README.md        # this file
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

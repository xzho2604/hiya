# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Architecture, tool usage, and design rationale: see `README.md` (authoritative).
- Verify changes with `tests/run.sh`, `HIYA_LOCK_BACKEND=token tests/run.sh` (the fallback lock backend), `./demo.sh`, and `shellcheck -x bin/*.sh demo.sh tests/*.sh` (shellcheck ≥ 0.11, from the repo root — `# shellcheck source=` paths assume it). CI (`.github/workflows/ci.yml`) runs the same on macOS and Ubuntu.
- Everything must run on stock macOS bash 3.2 (`/bin/bash`) — no bash-4 features, and macOS has no `flock(1)` — and on Linux with GNU coreutils. Verify with `PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash tests/run.sh`; never assume one `stat`/`mv`/`flock` flavor.
- Locking (kernel locks via `lockf`'s fd form / `flock`, rename-token fallback, per-home pin): README "Kernel locks" and the locking section of `bin/hiya-lib.sh`. Lock order where more than one is held: sessions → backlog → workspaces. Per-task worktree (`HIYA_REPO`) semantics: README "Per-task git worktrees".
- Sharp edge: a kernel lock lives as long as ANY process holds its fd, and children inherit fds. Anything long-lived started while a lock may be held (every `git` call, the watcher's `sleep`) goes through `hiya_unlocked`; `tests/20-lock-fd-hygiene.test.sh` guards it.
- Sharp edge: bash locals are dynamically scoped — a `local name` in `hiya-lib.sh`'s `with_lock` would shadow a caller's global inside the wrapped function. Lib-frame locals that wrap callbacks stay prefixed (`wl_*`).
- Tests stop only processes they started (`jobs -p`, a recorded pid) — never `pkill`/`killall`; the host is shared. A bug-fix test must be shown to fail on the pre-fix `bin/` first.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

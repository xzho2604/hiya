# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Architecture, tool usage, and design rationale: see `README.md` (authoritative).
- Verify changes with `tests/run.sh`, `./demo.sh`, and `shellcheck -x bin/*.sh demo.sh tests/*.sh` (from the repo root — `# shellcheck source=` paths assume it).
- Everything must run on stock macOS bash 3.2 (`/bin/bash`): no bash-4 features, no `flock(1)`. Verify with `PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash tests/run.sh`.
- Lock order where more than one is held: sessions → backlog → workspaces. Per-task worktree (`HIYA_REPO`) semantics: README "Per-task git worktrees".
- Sharp edge: bash locals are dynamically scoped — a `local name` in `hiya-lib.sh`'s `with_lock` would shadow a caller's global inside the wrapped function. Lib-frame locals that wrap callbacks stay prefixed (`wl_*`).

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

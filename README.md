# hiya

A standalone, self-contained multi-session coordination system in bash — a
reference implementation of a "multi-session operational home". N concurrent
agent or operator sessions share one home directory safely, with automatic
per-session isolation, optional per-task git worktrees, and **no central
daemon**: coordination is files + locks only. Pure bash 3.2 + coreutils
(plus `git` for the worktree feature); runs on stock macOS.

## Home layout

Created lazily under `HIYA_HOME` (default `./home`) by the first joiner:

```
state/
  sessions/<sid>/        one dir per live session
    heartbeat            mtime = liveness
    inbox/               routed wake events (one file per record)
    meta                 pid, started-at
  sessions/.dead/        archived dirs of reaped sessions
  leases/<task-id>       task lease: owner=<sid>, claimed_at=<epoch>
  workspaces/<task-id>   workspace registry (only with HIYA_REPO):
                         path=, branch=, repo=, created_at=
  wake-queue             durable append-only queue: epoch<TAB>seq<TAB>task-id<TAB>payload
  locks/                 per-resource lock dirs (mkdir-based)
work/<task-id>/          per-task git worktrees (only with HIYA_REPO)
data/
  backlog.md             task queue, one per line: <task-id><TAB><state><TAB><title>
                         (states: queued, claimed, done)
  memory/<name>.md       shared memory files, concurrent-safe writes
  journal/               conflict-deferred memory intents awaiting curation
```

## Why this design

**mkdir locks.** macOS has no `flock(1)`, so the lock helper uses `mkdir`,
which is atomic on POSIX filesystems: of any number of concurrent `mkdir`
calls on the same path, exactly one succeeds. The lock dir records the
holder's pid; a lock whose pid is dead is reclaimed, so a crashed holder
cannot wedge the home. Reclaim itself is race-free because contenders race
on an atomic `mv` of the stale lock dir and only one wins. A live holder is
never preempted. (This makes hiya single-host by design — pid liveness means
nothing across machines.)

**Leases + claim-on-dispatch.** A task is owned by whoever holds its lease
file. Claiming verifies `queued` + unleased, writes the lease, and flips the
backlog state — all inside one backlog-lock critical section, so two racing
claimers can never both win. Losing is a normal, clean outcome (non-zero
exit, "already claimed by …"), not an error to retry blindly.

**Heartbeats + reaping.** Sessions die without deregistering (crash, kill,
network vanish). Liveness is a file mtime; any session's periodic heartbeat
pass reaps expired peers, releasing their leases back to `queued` so work is
never stranded. No daemon needed — the maintenance work rides along on
whoever is alive.

**Single elected watcher.** Routing wake events needs exactly one router or
records get double-delivered. Rather than a daemon, any session may *try* to
be the watcher; a non-blocking singleton lock elects one, everyone else
no-ops. If the watcher dies, its lock is reclaimed and the next candidate
takes over. The queue is append-only (durable, auditable); the watcher
tracks progress with a cursor file.

**Per-task git worktrees.** With `HIYA_REPO` set (unset = feature off,
nothing changes), every claim comes with an isolated `git worktree` under
`work/<task-id>` on branch `hiya/<task-id>`, so N sessions can hack on the
same repo without stepping on each other. The registry record is keyed by
*task*, not by lease: leases churn (release, reap, transfer) but the
workspace persists, so a crashed session's half-done work survives and the
next claimant simply re-attaches. Provisioning runs right after the claim
critical section — the lease already names the sole legitimate user, so the
backlog lock is not held across a slow git call; if provisioning fails the
claim is rolled back to `queued`. Teardown happens only at `--done` and is
guarded: a dirty worktree (uncommitted changes or untracked files) refuses
the *whole* done with exit 3, leaving lease, backlog, and work untouched —
losing work requires the explicit, destructive `--discard`. Task branches
are never deleted automatically; committed work always survives teardown.

**CAS memory writes.** Shared memory files are read-modify-write by many
sessions. A writer passes the content hash it read; the write commits only
if the file still matches. On a lost race the content is **journaled as an
intent** instead of clobbering the other writer — nothing is ever silently
lost — and curation later folds intents in under a dated section, where a
human (or agent) can reconcile.

## Tools

Every tool is a standalone script in `bin/` with `--help`; all honor
`HIYA_HOME` (default `./home`).

| Tool | Purpose |
| --- | --- |
| `hiya-lib.sh` | Shared helpers (sourced, not run): `with_lock`, atomic write, CAS commit, path/lease/backlog accessors. |
| `hiya-join.sh` | Register a session: allocate a sid, create the session dir + heartbeat; the first joiner bootstraps the home layout under the bootstrap lock. Prints a digest (live sessions, leases, queued tasks). |
| `hiya-heartbeat.sh <sid>` | Touch own heartbeat, then reap sessions whose heartbeat is older than `HIYA_SESSION_TTL` (default 120s): leases released back to `queued`, dir archived to `state/sessions/.dead/`. |
| `hiya-claim.sh <sid> <task-id>` | Atomic claim-on-dispatch. Exit 0 = won; exit 1 = lost ("already claimed by \<sid\>"). With `HIYA_REPO`: provisions the task worktree, or re-attaches to a surviving one; provisioning failure rolls the claim back. |
| `hiya-release.sh <sid> <task-id> [--done [--discard]]` | Release a lease back to `queued` (workspace untouched), or mark `done` (workspace torn down, branch kept). Refuses (exit 2) if the caller doesn't hold the lease; refuses the whole done (exit 3) if the worktree is dirty, unless `--discard` (destructive) is given. |
| `hiya-transfer.sh <from> <to> <task-id>` | Explicit lease handoff; refuses if `from` isn't the owner or `to` isn't live. |
| `hiya-wake.sh <task-id> <payload>` | Append a wake record (lock-serialized, monotonically increasing seq). |
| `hiya-watch.sh <sid> [--once]` | Watcher election + routing. Holder drains the queue, routing each record to the lease owner's inbox; unleased/dead-owner records fall to the watcher's own inbox. Non-holders print "watcher held by \<sid\>" and exit 0. Default loops (`HIYA_WATCH_INTERVAL`, 2s); `--once` does one pass. |
| `hiya-inbox.sh <sid> [--drain]` | List (or drain) own inbox in seq order. |
| `hiya-mem-write.sh <name> <file> --base-hash <h>` | CAS memory write; `--show-hash <name>` prints the current hash (`-` = not yet created). On conflict, journals the content and exits 3. |
| `hiya-curate.sh` | Fold journal intents into their memory files under a dated `## Curated` section, then remove them. |
| `hiya-workspace.sh <task-id> [--path\|--status\|--discard]` | Inspect a task workspace (`--status`: record, lease, clean/dirty/missing; `--path`), or `--discard` an orphaned one (destructive; refused while the task is leased). |

A typical session loop:

```sh
export HIYA_HOME=./home
export HIYA_REPO=~/src/myrepo            # optional: per-task git worktrees
sid=$(bin/hiya-join.sh | awk '/^sid:/ { print $2 }')
bin/hiya-claim.sh "$sid" t42 && do_work  # in $HIYA_HOME/work/t42 if HIYA_REPO
bin/hiya-heartbeat.sh "$sid"          # periodically
bin/hiya-watch.sh "$sid" &            # every session may try; one wins
bin/hiya-inbox.sh "$sid" --drain      # consume routed wakes
h=$(bin/hiya-mem-write.sh --show-hash notes)
edit notes locally...
bin/hiya-mem-write.sh notes notes.local.md --base-hash "$h" || echo "journaled"
bin/hiya-release.sh "$sid" t42 --done
```

## Demo and tests

```sh
./demo.sh        # scripted two-session narrative in ./demo-home
tests/run.sh     # self-contained tests, each in its own temp home
shellcheck -x bin/*.sh demo.sh tests/*.sh   # from the repo root
```

The demo walks the whole story: two sessions join (one bootstrap), race for
the same task (exactly one wins, and gets a git worktree for it), wakes
route to the right inboxes, both sessions write the same memory file (one
CAS write lands, one journals), curation folds the journal, a dead session's
lease is reaped while its half-done worktree survives, the next claimant
re-attaches to it, a dirty `--done` is refused until the work is committed,
and an abandoned scratch worktree is torn down with an explicit `--discard`.

Tests cover: first-joiner-only bootstrap (including concurrent joins), the
claim race, reaping a dead session's lease, wake routing (owner inbox,
watcher fallback for unleased and dead-owner tasks, non-holder election
message), CAS conflict journaling, curation, release/transfer authority
checks, and the workspace lifecycle (provision on claim, clean teardown at
done, dirty refusal + `--discard`, survival across reap with re-attach,
transfer needing no workspace work, and `HIYA_REPO` unset leaving no
workspace artifacts).

## Constraints and notes

- Works on stock macOS bash 3.2: no bash-4 features (no associative arrays,
  no `${var,,}`), BSD and GNU `stat` both handled, hashing via `shasum`.
- Every script: `#!/usr/bin/env bash`, `set -u`, shellcheck-clean.
- Wake payloads and backlog titles are single lines; task ids, sids, and
  memory names are simple tokens (no tabs, no `__` in memory names).
- Digest reads (join) are advisory and lock-free; all mutations go through
  the per-resource locks. Lock order where more than one is held:
  sessions → backlog → workspaces.
- `HIYA_REPO` needs `git` on the PATH and a repo with at least one commit
  (new branches fork from its current `HEAD`). Everything else is bash +
  coreutils only.

# hiya

A standalone, self-contained multi-session coordination system in bash — a
reference implementation of a "multi-session operational home". N concurrent
agent or operator sessions share one home directory safely, with automatic
per-session isolation, optional per-task git worktrees, and **no central
daemon**: coordination is files + locks only. Pure bash 3.2 + coreutils, plus
the stock file-lock tool of the platform (`lockf(1)` on macOS, `flock(1)` on
Linux) and `git` for the worktree feature; runs on stock macOS and on Linux.

## Home layout

Created lazily under `HIYA_HOME` (default `./home`) by the first joiner:

```
state/
  sessions/<sid>/        one dir per live session
    heartbeat            mtime = liveness
    inbox/               routed wake events (one file per record)
    meta                 pid, started-at
  sessions/.dead/        archived dirs of reaped sessions
  unrouted/              wake records whose task has no live owner; the
                         task's next claimant adopts them
  leases/<task-id>       task lease: owner=<sid>, claimed_at=<epoch>
  workspaces/<task-id>   workspace registry (only with HIYA_REPO):
                         path=, branch=, repo=, created_at=
  wake-queue             durable append-only queue: epoch<TAB>seq<TAB>task-id<TAB>payload
  locks/                 .backend (the home's pinned lock backend), then
                         <name>.flock files (kernel locks) or <name>.token/
                         dirs (fallback); watcher.sid names the watcher
work/<task-id>/          per-task git worktrees (only with HIYA_REPO)
data/
  backlog.md             task queue, one per line: <task-id><TAB><state><TAB><title>
                         (states: queued, claimed, done) — written only by
                         the tools, never by hand
  memory/<name>.md       shared memory files, concurrent-safe writes
  journal/               conflict-deferred memory intents awaiting curation
```

## Why this design

**Kernel locks.** Every shared resource has a named lock, and a lock must
survive its holder crashing. hiya takes `flock(2)` locks through an fd the
holding shell keeps open — `lockf -s -t N <fd>` (the fd form of stock
`/usr/bin/lockf`) on macOS, `flock -w N <fd>` on Linux; both take the same
kind of lock, so they exclude each other. The kernel drops the lock the
instant the holder dies, so there is no such thing as a stale lock and no
cleanup step. That matters: the earlier mkdir-based lock had to *detect* a
dead holder and *remove* its lock dir, and that two-step cleanup raced —
a slow reclaimer could remove the lock a faster one had just re-taken, and
two sessions ended up inside the same critical section.

One sharp edge comes with fd-held locks: children inherit open fds, and a
lock lives as long as *any* process holds its open file. Anything long-lived
that hiya starts while holding a lock — `git` (hooks, fsmonitor), the
watcher's `sleep` — therefore runs through `hiya_unlocked`, which closes the
lock fds for that child.

**Token fallback.** On a host where no tool can lock an fd (an older macOS
`lockf` without the fd form, no `flock`), hiya falls back to a lock built on
atomic `rename(2)`. Each lock is a directory holding exactly *one* token
file, which only ever moves between names: `free` → `held.<pid>.<nonce>`
(acquire: one renamer wins), back to `free` (release), or
`held.<dead pid>.<n>` → `held.<my pid>.<m>` (take over a dead holder). The
takeover names the dead holder's token as its *source*, so it is a
compare-and-swap: it can only hit the incarnation that was judged dead —
never a newer, live holder — and exactly one contender wins it. There is no
moment without a holder identity and nothing is ever deleted, so the
fallback has no cleanup race either. Its one weakness is inherent to pid
files: a dead holder whose pid was reused by an unrelated live process looks
alive until that process exits.

Kernel and token locks do *not* exclude each other, so a home is **pinned**
to one backend by its first user (`state/locks/.backend`); a session that
cannot use the pinned backend refuses to run rather than run unlocked.
`HIYA_LOCK_BACKEND=token` pins a *new* home to the fallback (the test suite
uses it). hiya is single-host by design — neither `flock(2)` nor pid
liveness means anything across machines — and all sessions of a home must
run the same hiya version.

**Leases + claim-on-dispatch.** A task is owned by whoever holds its lease
file. Claiming verifies the claimant is still alive and the task is `queued`
+ unleased, writes the lease, and flips the backlog state — all inside one
backlog-lock critical section, so two racing claimers can never both win,
and a session reaped while its claim waited for the lock cannot end up
owning a lease. Losing is a normal, clean outcome (non-zero exit, "already
claimed by …"), not an error to retry blindly.

**Heartbeats + reaping.** Sessions die without deregistering (crash, kill,
network vanish). Liveness is a file mtime; any session's periodic heartbeat
pass reaps expired peers, releasing their leases back to `queued` so work is
never stranded. The same pass sweeps *orphan* leases — a lease whose owner
has no session at all — and re-homes the wakes a reaped session never
drained (below). No daemon needed — the maintenance work rides along on
whoever is alive.

**Single elected watcher.** Routing wake events needs exactly one router or
records get double-delivered. Rather than a daemon, any session may *try* to
be the watcher; a non-blocking singleton lock elects one, everyone else
no-ops. The watch loop refreshes its session's heartbeat on every pass —
watching *is* being alive — and if its session is gone anyway it steps down,
freeing the lock; if the watcher dies the kernel frees it. Either way the
next candidate takes over. The queue is append-only (durable, auditable);
the watcher tracks progress with a cursor file.

**Wakes are never dropped.** A wake record is routed to exactly one place:
the inbox of the live session leasing its task, or the home-level
`state/unrouted/` while the task has no live owner. (A session that releases
or hands over a task keeps the wakes it had already received.) Records are
written to a hidden temp file and renamed into place, and the cursor moves
past a record only once it is written; if a record can be written nowhere,
the pass fails and the next one retries it. Parked wakes follow their task:
a won claim adopts the task's unrouted wakes into the claimant's inbox, and
reaping a session re-homes the wakes it never drained — to the task's live
owner if the task was handed over, else to `state/unrouted/`. Every
heartbeat pass retries what an earlier one could not move (and says so), and
delivers any parked wake whose task has a live owner by now. Delivery is
**at-least-once**: a watcher that dies between writing a record and saving
the cursor routes that record again, and a wake a session read but did not
drain before it was reaped is seen again by the task's next owner. The seq
(second field) is the idempotency key.

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
are never deleted automatically; committed work always survives teardown —
so a task claimed again after `--done` or `hiya-workspace.sh --discard`
attaches its new worktree to the kept branch, commits and all.

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
| `hiya-lib.sh` | Shared helpers (sourced, not run): `with_lock` over the kernel/token lock backends, `hiya_unlocked`, atomic write, CAS commit, wake-record and path/lease/backlog accessors. |
| `hiya-join.sh` | Register a session: allocate a sid, create the session dir + heartbeat; the first joiner bootstraps the home layout under the bootstrap lock. Prints a digest (live sessions, leases, queued tasks, unrouted wakes). |
| `hiya-add.sh <task-id> <title>` | Add a `queued` task under the backlog lock — the only way rows enter `backlog.md`. Refuses (exit 2) a task id that already exists; rejects (exit 1) ids that are not simple tokens and titles that are not a single tab-free line. |
| `hiya-heartbeat.sh <sid>` | Touch own heartbeat, then reap sessions whose heartbeat is older than `HIYA_SESSION_TTL` (default 120s): dir archived to `state/sessions/.dead/`, leases released back to `queued`, undrained wakes re-homed by task (retried every pass until they move). Also sweeps orphan leases (owner has no session) and delivers parked wakes whose task now has a live owner. |
| `hiya-claim.sh <sid> <task-id>` | Atomic claim-on-dispatch. Exit 0 = won; exit 1 = lost ("already claimed by \<sid\>"). With `HIYA_REPO`: provisions the task worktree (on the kept branch, if one exists), or re-attaches to a surviving one; provisioning failure rolls the claim back. A won claim adopts the task's unrouted wakes. |
| `hiya-release.sh <sid> <task-id> [--done [--discard]]` | Release a lease back to `queued` (workspace untouched), or mark `done` (workspace torn down, branch kept). Refuses (exit 2) if the caller doesn't hold the lease; refuses the whole done (exit 3) if the worktree is dirty, unless `--discard` (destructive) is given. |
| `hiya-transfer.sh <from> <to> <task-id>` | Explicit lease handoff; refuses if `from` isn't the owner or `to` isn't live. |
| `hiya-wake.sh <task-id> <payload>` | Append a wake record (lock-serialized, monotonically increasing seq). |
| `hiya-watch.sh <sid> [--once]` | Watcher election + routing. Holder drains the queue, routing each record to the live lease owner's inbox; unleased/dead-owner records are parked in `state/unrouted/`. Non-holders print "watcher held by \<sid\>" and exit 0. Default loops (`HIYA_WATCH_INTERVAL`, 2s), heartbeating every pass, and exits 1 if its session is gone; `--once` does one pass (exit 1 if a record could not be written). |
| `hiya-inbox.sh <sid> [--drain]` | List (or drain) own inbox in seq order; `--unrouted` lists (or drains) `state/unrouted/` instead. |
| `hiya-mem-write.sh <name> <file> --base-hash <h>` | CAS memory write; `--show-hash <name>` prints the current hash (`-` = not yet created). On conflict, journals the content and exits 3. |
| `hiya-curate.sh` | Fold journal intents into their memory files under a dated `## Curated` section, then remove them. |
| `hiya-workspace.sh <task-id> [--path\|--status\|--discard]` | Inspect a task workspace (`--status`: record, lease, clean/dirty/missing; `--path`), or `--discard` an orphaned one (destructive; refused while the task is leased). |

A typical session loop:

```sh
export HIYA_HOME=./home
export HIYA_REPO=~/src/myrepo            # optional: per-task git worktrees
sid=$(bin/hiya-join.sh | awk '/^sid:/ { print $2 }')
bin/hiya-add.sh t42 "Fix the flaky test"   # tasks enter the backlog only this way
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
HIYA_LOCK_BACKEND=token tests/run.sh        # same suite on the fallback locks
shellcheck -x bin/*.sh demo.sh tests/*.sh   # from the repo root
```

CI (`.github/workflows/ci.yml`) runs all of the above on macOS — stock
`/bin/bash` 3.2 with only the system `PATH` — and on Ubuntu (GNU coreutils,
`flock`), and asserts that both really get kernel locks.

The demo walks the whole story: a first session bootstraps the home and adds
tasks with `hiya-add.sh`, a second joins, they race for the same task
(exactly one wins, and gets a git worktree for it), wakes route to the right
inboxes while a wake for an unowned task is parked and later adopted by the
session that claims it, both sessions write the same memory file (one CAS
write lands, one journals), curation folds the journal, a dead session's
lease is reaped while its half-done worktree survives, the next claimant
re-attaches to it, a dirty `--done` is refused until the work is committed,
and an abandoned scratch worktree is torn down with an explicit `--discard`.

Tests cover: first-joiner-only bootstrap (including concurrent joins), the
claim race, reaping a dead session's lease, wake routing (owner inbox,
`state/unrouted/` for unleased and dead-owner tasks, adoption on claim,
non-holder election message), CAS conflict journaling, curation,
release/transfer authority checks, and the workspace lifecycle (provision on
claim, clean teardown at done, dirty refusal + `--discard`, survival across
reap with re-attach, transfer needing no workspace work, and `HIYA_REPO`
unset leaving no workspace artifacts). Regression tests pin the correctness
bugs found in review: mutual exclusion when contenders race for a crashed
holder's lock, and between sibling subshells, on both lock backends (14);
reaping under GNU *and* BSD
`stat`, each emulated with a PATH shim (15); watcher heartbeat, step-down,
and takeover (16); no wake dropped when a write fails (17); a reaped
session's wakes reaching the next claimant, orphan-lease sweep, and the
claim liveness re-check (18); re-claim after `--done` / `--discard` with the
branch kept (19); lock fds not leaking into long-lived children (20); and
`hiya-add.sh` under concurrent backlog rewrites (21).

## Constraints and notes

- Works on stock macOS bash 3.2: no bash-4 features (no associative arrays,
  no `${var,,}`, no `{fd}>file`), hashing via `shasum`. GNU and BSD `stat`
  are both handled — GNU form first, output validated as digits, because GNU
  `stat -f` prints a filesystem block *and* fails.
- Locking needs no install on either platform: `/usr/bin/lockf` with the fd
  form on macOS, util-linux `flock` on Linux (BusyBox `flock`, which lacks
  `-w`, is polled). Anything else gets the token fallback. `lsof
  state/locks/<name>.flock` shows who holds a kernel lock.
- Every script: `#!/usr/bin/env bash`, `set -u`, shellcheck-clean.
- Wake payloads and backlog titles are single lines; task ids, sids, and
  memory names are simple tokens (no tabs, no `__` in memory names).
- **Only the tools write `data/backlog.md`.** Every state change rewrites the
  file under the backlog lock, so a row appended by hand while sessions are
  live can be lost; use `hiya-add.sh`.
- Digest reads (join) are advisory and lock-free; all mutations go through
  the per-resource locks. Lock order where more than one is held:
  sessions → backlog → workspaces, and watcher → wake (the watcher holds its
  election lock across each drain). Wake records move between inboxes and
  `state/unrouted/` lock-free, by atomic rename.
- A lock belongs to the process that took it. Subshells share their parent's
  pid, so take and release a lock in the same process, never from a
  backgrounded subshell that may outlive its parent.
- `HIYA_REPO` needs `git` on the PATH and a repo with at least one commit
  (new branches fork from its current `HEAD`). Everything else is bash +
  coreutils + the platform's lock tool.

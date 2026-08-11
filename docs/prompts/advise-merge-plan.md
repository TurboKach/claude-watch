# advise: integrating the four stranded worktrees

Four branches built in parallel under `.claude/worktrees/` were never integrated.
`main` (0b58312) carries U0/U1/U4 — `tools/advise-disk.sh`, `tests/fixture-disk.sh`,
the sampler schema and the linear aggregation — but `claude-watch advise` does not
exist: the usage string at `claude-watch:30` lists only
`report | orphans | worktrees | status | hook | doctor`, and the dispatch `case` at
`claude-watch:1466` falls through to `usage >&2; exit 2`. The dispatcher that would
call the analyzers, `tools/advise.sh`, is on U2 and has never been on `main`.

Every claim below was produced by running the command shown, not by reading diffs
and reasoning about them. The merge order was validated by performing all four
merges in a scratch worktree and running the whole suite on the result.

## Baseline: `main` is green

There is no test runner — no `Justfile`, no `Makefile`, no `package.json`. `README.md:243`
documents `./tests/smoke.sh` alone. The suite is the set of executable scripts in
`tests/`, each run under **bash** (the shebang is load-bearing: these scripts assert
word-splitting behaviour that zsh does not reproduce). The command is:

```bash
cd /Users/turbokach/Dev/claude-watch && \
for t in tests/smoke.sh tests/fixture-*.sh; do \
  printf '%-38s' "$(basename "$t")"; bash "$t" >/tmp/$(basename "$t").log 2>&1; echo "exit=$?"; \
done
```

On `main` @ 0b58312, every file exits **0** — 421 assertions, 0 failures:

| file | exit | result |
|---|---|---|
| `smoke.sh` | 0 | 37 passed, 0 failed, 2 skipped |
| `fixture-aggregation.sh` | 0 | 50 passed, 0 failed |
| `fixture-disk.sh` | 0 | 184 passed, 0 failed |
| `fixture-report.sh` | 0 | 75 passed, 0 failed |
| `fixture-sample-schema.sh` | 0 | 44 passed, 0 failed |
| `fixture-worktree-unpushed.sh` | 0 | 31 passed, 0 failed |

**The baseline is green.** Any red after a merge is caused by that merge.

## Findings

### H1 — the `tools/sample.sh` conflict does not exist; the real overlap is `claude-watch`

The premise was that U3/U5/U6 each carry the same 43-line change to `tools/sample.sh`.
They do not. **No branch touches `tools/sample.sh` at all:**

```
$ git diff $(git merge-base main worktree-agent-ac8c601e4731ff071) \
           worktree-agent-ac8c601e4731ff071 -- tools/sample.sh
(empty; same for a3b033d3ccc9c4048 and ab7487a5e0cd0d278)

$ git diff --stat 12b919b main -- tools/sample.sh
 tools/sample.sh | 43 ++++++++++++++++++++++++++++++++++---------
```

The 43-line change is **on `main`** — it arrived with U1 between `12b919b` and HEAD.
It appeared in `git diff main..<branch>` as a *deletion* only because the branches
predate it. This is the same artefact as H2 and is not a conflict.

The genuine overlap is `claude-watch`, edited by **three** branches in three
different regions:

| branch | region | what |
|---|---|---|
| U2 `ab7487a` | usage, `status()`, `hook()`, `doctor()`, dispatch `case` | +76 |
| U3 `ac8c601` | `doctor()` only, after the sampler-pileup check | +28 |
| U5 `a3b033d` | `scan_worktrees()` only | +51 |

U2 and U3 both edit `doctor()` and their hunks are **adjacent**: U2 replaces the
`nsamp` computation, and U3 inserts its disk-cache block immediately after that
block's `chk` line. This was the one place a real conflict was plausible. It does
not occur — see H4 and the trial-merge result.

### H2 — the deletions are an artefact; nothing on `main` is lost

Each branch's merge-base is behind `main`, so `git diff main..<branch>` reports
everything `main` gained since as removed. Diffing from the **merge-base** shows
the truth — every branch is purely additive:

| branch | merge-base | true diffstat from base |
|---|---|---|
| U3 `04c49ab` | `12b919b` | 4 files, +1235 / −1 |
| U2 `db27c1d` | `5e2b9c0` | 4 files, +1623 / −7 |
| U5 `3aa90cf` | `12b919b` | 3 files, +926 / −4 |
| U6 `6150a50` | `12b919b` | 3 files, +269 / −12 |

Confirmed on the merged result rather than inferred:

```
$ git diff --diff-filter=D --name-only main HEAD    # after all four merges
(no output)
```

Zero files deleted. `tools/advise-disk.sh`, `tests/fixture-disk.sh` and
`tests/fixtures/day-golden.tsv` all survive, and the tests that consume them
(`fixture-disk.sh` 184, `fixture-report.sh` 75) still pass on the merged tree.

### H3 — the dispatcher's interface matches both analyzers

`tools/advise.sh` sources the analyzers and calls them as **shell functions taking
no arguments**, each writing tab-separated `S`/`F` rows to stdout
(`tools/advise.sh:272-284`, and `{ advise_disk; advise_leaks; } > "$rows"` in `cw_advise`):

```bash
[ -f "$REPO_DIR/tools/advise-disk.sh" ]  && . "$REPO_DIR/tools/advise-disk.sh"  2>/dev/null
[ -f "$REPO_DIR/tools/advise-leaks.sh" ] && . "$REPO_DIR/tools/advise-leaks.sh" 2>/dev/null
```

Both are satisfied. `advise_disk()` is defined at `tools/advise-disk.sh:702` (already
on `main`); `advise_leaks()` at `tools/advise-leaks.sh:352` (U5). Scalars reach the
analyzers through `cw_export_scalars` (`CW_NCPU`, `CW_MEMSIZE_KB`,
`CW_VOLUME_TOTAL_KB`, `CW_DISK_*`), not argv. `disk-scan.sh` is the one exception:
it is a **subprocess**, invoked as `bash "$REPO_DIR/tools/disk-scan.sh"` with its exit
code propagated (`tools/advise.sh:852`), guarded by an existence check at `:848`.

The dispatcher degrades safely: `cw_load_analyzers` installs a `cw_stub_domain` stub
for any analyzer that is absent, so no merge order can produce a broken `advise` —
only a less complete one. **No mismatch found.**

**One real cross-branch defect, in U3's uncommitted change.** The worktree
`agent-ac8c601e4731ff071` has one uncommitted modification to `tools/disk-scan.sh`.
It is **not scratch work — it must be committed.** It introduces `IDLE_SLACK=1` and
stamps the `find -newer` reference file one second *before* the 14-day cutoff. That
is exactly the convention U4 landed on `main` at `tools/advise-disk.sh:113-115`
(`DISK_IDLE_SLACK_S=1`) and `:838-840`. Without it the scanner and the analyzer
disagree about an entry sitting exactly on the boundary: the scanner writes
`confirmed` into the cache and the analyzer silently downgrades it at print time,
which reads as a bug in both. U3 was branched before that convention existed. The
patch applies cleanly, `bash -n` passes, and `fixture-disk-scan.sh` stays at 106/0.

*Test gap to note, not to fix here:* the change also adds a
`CLAUDE_WATCH_DISK_IDLE_CUTOFF` test hook, and **no test exercises it** — nothing in
`tests/fixture-disk-scan.sh` references it. The boundary behaviour it exists to pin
is therefore unasserted on the scanner side. Flagged for follow-up; adding coverage
is out of scope for a merge.

### H4 — `claude-watch` has not drifted under U2 at all

`main`'s `claude-watch` is **byte-identical** to the blob U2 branched from:

```
$ git rev-parse main:claude-watch     -> 0a7d6e80b1197ff98f6349877b8b7b8278e5011d
$ git rev-parse 5e2b9c0:claude-watch  -> 0a7d6e80b1197ff98f6349877b8b7b8278e5011d
$ git log --oneline 5e2b9c0..main -- claude-watch
(no output)
```

The later commits `cf59cff`, `f88fee2`, `677b657` touch `tools/advise-disk.sh` and the
fixtures, **not** `claude-watch`. So U2's 76-line edit applies with zero drift. U3 and
U5 branched from the older blob `e9ab049` and do carry drift, but it lands in the
`report`/aggregation code, disjoint from `doctor()` and `scan_worktrees()`.

### Trial merge — all four merge clean, and the result works

Performed in a throwaway detached worktree off `main`, in the order below:

```
merge ab7487a5e0cd0d278 (U2)  exit=0
merge ac8c601e4731ff071 (U3)  exit=0
merge a3b033d3ccc9c4048 (U5)  exit=0
merge a47345e2712434322 (U6)  exit=0     # zero conflicted paths at every step
```

Both `doctor()` blocks compose correctly — U2's `ps -Ao args=` rewrite at
`claude-watch:1530` and U3's disk-cache block at `:1538-1554`, adjacent and intact.

`claude-watch advise` runs and produces real output, and `advise --json` parses with
`domains: ['disk', 'leaks']` — proving **both real analyzers are wired, not stubs**.
Full suite on the merged tree: **8 files, all exit 0, 772 passed, 0 failed**
(`smoke.sh` grows 37→63; `fixture-disk-scan.sh` 106, `fixture-leaks.sh` 116,
`fixture-window.sh` 103 are new).

## Merge order

**U2 → U3 → U5 → U6.**

1. **U2 first.** `main`'s `claude-watch` is identical to U2's merge-base (H4), so the
   largest and riskiest single edit applies with no drift. It also creates the
   dispatcher and the `advise`/`disk` dispatch cases, which means every *later* step
   can be verified by actually running `claude-watch advise` instead of only by tests.
2. **U3 second.** It adds `tools/disk-scan.sh`, which U2's `cw_disk --refresh` already
   calls; its `doctor()` block then merges onto U2's rewritten `doctor()` — the single
   adjacency worth sequencing deliberately, rather than discovering it last.
3. **U5 third.** `advise-leaks.sh` flips `advise_leaks` from stub to real, which is
   directly observable in `advise --json`.
4. **U6 last.** Docs describe the finished state; landing them before the code would
   leave `main`'s README and SKILL.md documenting commands the tool does not have.

## Execution steps

Each step is one branch, merged into `main` in the primary worktree
`/Users/turbokach/Dev/claude-watch`. **Executor for every step: `step-executor`.**
No step may be started before the previous one's verification passes.

Shared suite command, referred to below as **`SUITE`**:

```bash
cd /Users/turbokach/Dev/claude-watch && \
for t in tests/smoke.sh tests/fixture-*.sh; do \
  printf '%-38s' "$(basename "$t")"; bash "$t" >/tmp/$(basename "$t").log 2>&1; echo "exit=$?"; \
done
```

### Step 1 — commit U3's pending idle-slack fix (executor: `step-executor`)

Do this **before** any merge, in U3's own worktree, so the fix arrives with the code
it corrects rather than as a follow-up on `main`.

```bash
cd /Users/turbokach/Dev/claude-watch/.claude/worktrees/agent-ac8c601e4731ff071
git add tools/disk-scan.sh
git commit -m "disk-scan: match the analyzer's exact-cutoff idle convention"
```

Verify: `git status --short` is empty, and `bash tests/fixture-disk-scan.sh` exits 0
(106 passed, 0 failed).

### Step 2 — merge U2, the dispatcher (executor: `step-executor`)

```bash
cd /Users/turbokach/Dev/claude-watch && git merge --no-edit worktree-agent-ab7487a5e0cd0d278
```

Verify: merge exits 0; then `./claude-watch advise --json | python3 -m json.tool >/dev/null`
exits 0, and `SUITE` is all-zero across 7 files (`fixture-window.sh` is new, 103 passed).
At this step `advise --json` reports domain `leaks` as the stub — that is expected
until step 4.

### Step 3 — merge U3, the disk scanner (executor: `step-executor`)

```bash
cd /Users/turbokach/Dev/claude-watch && git merge --no-edit worktree-agent-ac8c601e4731ff071
```

Verify: merge exits 0; `grep -n "no sampler pileup" claude-watch` and
`grep -n "disk scanner is executable" claude-watch` both hit, confirming U2's and U3's
`doctor()` blocks coexist; `./claude-watch doctor` runs; `SUITE` all-zero across 8 files.

### Step 4 — merge U5, the leaks analyzer (executor: `step-executor`)

```bash
cd /Users/turbokach/Dev/claude-watch && git merge --no-edit worktree-agent-a3b033d3ccc9c4048
```

Verify: merge exits 0; `SUITE` all-zero; and the leaks domain is now real, not a stub:

```bash
./claude-watch advise --json | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print([x["domain"] for x in d["domains"]])'
# expect: ['disk', 'leaks']
```

### Step 5 — merge U6, the docs (executor: `step-executor`)

```bash
cd /Users/turbokach/Dev/claude-watch && git merge --no-edit worktree-agent-a47345e2712434322
```

Verify: merge exits 0; `SUITE` all-zero (docs cannot break tests, but the run is what
certifies the final tree); and every command named in the merged `README.md` and
`skills/claude-watch/SKILL.md` actually exists in `claude-watch`'s usage string.

### Step 6 — final gate (executor: `step-executor`)

```bash
cd /Users/turbokach/Dev/claude-watch
git diff --diff-filter=D --name-only 0b58312 HEAD   # must print nothing
./claude-watch advise
./claude-watch advise --json | python3 -m json.tool >/dev/null
```

Then `SUITE` once more, cold.

---

## Step 7 — orphan detection blind spot (executor: `step-executor`)

Scope addition, sequenced **after all four merges**. It does not change the merge
order or any finding above.

**Relationship to the merges.** None of the four branches touches
`tools/orphan-policy.sh`, `tools/sample.sh`, or `tests/fixture-sample-schema.sh` —
verified by diffing each branch from its own merge-base. But this is **not** a
zero-overlap unit: it must edit `claude-watch`, which U2, U3 and U5 all edit. The
regions are disjoint — the orphan pass lives at `claude-watch:529-571`, while the
merges touch `scan_worktrees()` (~933), the dispatch `case` (~1508) and `doctor()`
(~1530) — so there is no interaction. Sequencing it last means it edits the
already-merged file and cannot complicate any conflict resolution.

### The bug

`ORPHAN_MATCH_RE` (`tools/orphan-policy.sh:15`) is a **name allowlist** of dev
runtimes: `node|tsx|npm|...|chrome-headless`. A database left behind by a dead
Claude session has no matching name, so it is never recorded and never offered for
reaping. Confirmed today: a `postgres` ran 25h holding port 55433.

Widening the allowlist with `postgres|redis-server|mysqld|mongod` is **not** the fix.
`ORPHAN_EXCLUDE_RE` is `(Applications|/usr/libexec|/System/)`, which does **not**
cover `/opt/homebrew/`, and a brew-managed postgres also runs with PPID 1. A bare
name match would therefore make `claude-watch orphans --kill` offer to kill the
user's real database — a destructive false positive.

### The fix: a second, independent match path based on provenance

Keep `ORPHAN_MATCH_RE` and `ORPHAN_EXCLUDE_RE` byte-for-byte as they are, so every
existing runtime behaves identically. Add one new variable beside them:

```bash
# A process is also a leak if it CARRIES a session path, whatever it is called.
# This is provenance, not identity: it catches a postgres or redis a session
# started without ever putting those names on the allowlist, which would also
# match the user's own brew-managed database.
#
# `/tmp` is a symlink to `/private/tmp` on macOS and argv records whichever form
# the caller used, so both must match. `(/private)?` — not `/private/?` — is what
# does that. The backslash in `/\.claude/` is single here and doubled nowhere:
# see the dynamic-regex note above.
ORPHAN_PROVENANCE_RE='(/private)?/tmp/claude-[0-9]+/|/\.claude/worktrees/'
```

The real layout on this machine, inspected rather than guessed, is
`/private/tmp/claude-<uid>/<slugified-project-path>/<session-uuid>/scratchpad/` —
e.g. `/private/tmp/claude-501/-Users-turbokach-Dev-claude-watch/f9d43bb6-…/scratchpad/`.
The uid is not fixed across machines, hence `claude-[0-9]+` rather than `claude-501`.

**Only argv is matched, not cwd.** macOS has no `/proc`, so a process's cwd is not
in `ps` output at all — obtaining it needs `lsof -a -p <pid> -d cwd` *per process*,
which cannot fit the sampler's ~0.1s budget across ~1200 processes. The evidence case
carries the session path in argv (`postgres -D /private/tmp/claude-501/…/pgdata`), so
argv is sufficient for it. Dropping cwd is a deliberate scope call: a session-spawned
process that keeps the path only in its cwd stays undetected, which is the same blind
spot as today, not a regression.

### The three call sites — all must change together

The header of `orphan-policy.sh` calls single-definition a **safety property**: the
list you are shown and the thing that gets killed must not drift. Both readers do
their own `ps` pass and their own `awk`, so the new variable must be threaded through
**both**, plus the fixture that re-runs the sampler's awk:

| file:line | change |
|---|---|
| `claude-watch:530` | add `-v PROV="$ORPHAN_PROVENANCE_RE"` |
| `claude-watch:568` | `if (A[p] !~ MATCH \|\| A[p] ~ EXCL) continue` → match on `MATCH` **or** `PROV` |
| `tools/sample.sh:111` | add `-v PROV="$ORPHAN_PROVENANCE_RE"` |
| `tools/sample.sh:211` | `if (args[p] !~ MATCH) continue` → match on `MATCH` **or** `PROV` |
| `tests/fixture-sample-schema.sh:370` | add `-v PROV="$ORPHAN_PROVENANCE_RE"` to `run_main()` |

Changing one reader and not the other is a defect, not a partial delivery: the
sampler would record leaks the killer refuses to see, or the reverse. The PPID-1 gate
(`claude-watch:567`, `tools/sample.sh:210`), the age floor and `ORPHAN_EXCLUDE_RE`
all stay exactly where they are — provenance widens *who is considered*, and changes
none of the gates.

### The hazard that makes this dangerous to get wrong

**An empty awk dynamic regex matches every string.** Verified:

```
$ printf 'postgres -D /opt/homebrew/var/postgresql@14\n/sbin/launchd\n' \
  | awk -v PROV="" '{ if ($0 ~ PROV) print "MATCHED: " $0 }'
MATCHED: postgres -D /opt/homebrew/var/postgresql@14
MATCHED: /sbin/launchd
```

`claude-watch:24` sources the policy with `|| true`, so if the file is missing or
unreadable, `PROV` is empty — and `A[p] ~ PROV` is then **true for every process**.
Combined with an `||`, every PPID-1 process becomes a reapable orphan, and
`orphans --kill` offers to kill launchd's children. The existing guard at
`claude-watch:829` checks only `-z "${ORPHAN_MATCH_RE:-}"`; it **must be extended to
`ORPHAN_PROVENANCE_RE`**. This failure mode is silent — it produces more output, not
an error — so it will not show up as a red test unless asserted.

### Test requirement

Add `tests/fixture-orphan-provenance.sh`, following the existing conventions
(`#!/usr/bin/env bash` shebang — load-bearing, `set -uo pipefail`, `LC_ALL=C`,
`ok`/`bad` counters, exit non-zero on any failure, hand-written `ps` rows so no real
process is touched). It must be a genuine two-way proof:

| argv fixture row | expected |
|---|---|
| `postgres -D /private/tmp/claude-501/-Users-…/be6c46b6-…/scratchpad/pgdata -p 55433` | **flagged** |
| `postgres -D /tmp/claude-501/-Users-…/be6/scratchpad/pgdata -p 55433` | **flagged** (symlink form) |
| `postgres -D /opt/homebrew/var/postgresql@14` | **not flagged** |
| `redis-server *:6379` | **not flagged** |
| `node /Users/…/x/.claude/worktrees/agent-a1/node_modules/.bin/vite` | **flagged** |

Assert against **both** readers, not one. Also assert the empty-`PROV` guard: with
`ORPHAN_PROVENANCE_RE` unset, `claude-watch orphans` must refuse (the `:829` path),
not fall through to matching everything. The proposed pattern was checked against all
five rows above and produced exactly the expected column.

### Verification

```bash
cd /Users/turbokach/Dev/claude-watch
bash tests/fixture-orphan-provenance.sh          # must exit 0
bash tests/fixture-sample-schema.sh              # must stay 44 passed, 0 failed
./claude-watch orphans                           # must not list brew postgres/redis
```

Then `SUITE` — now 9 files — all exit 0.

**Performance, measured not assumed.** The sampler runs every 10s on a ~0.1s budget
dominated by `ps`. Measurement command:

```bash
cd /Users/turbokach/Dev/claude-watch && . tools/orphan-policy.sh
snap=$(ps -Ao pid=,ppid=,pcpu=,rss=,etime=,args=)
time (for i in $(seq 20); do printf '%s\n' "$snap" | LC_ALL=C awk \
  -v MATCH="$ORPHAN_MATCH_RE" -v EXCL="$ORPHAN_EXCLUDE_RE" \
  '{a=$0} a ~ MATCH && a !~ EXCL {n++} END{}'; done)
# then the same loop with -v PROV="$ORPHAN_PROVENANCE_RE" and the || added
```

Already run on this machine over a live 1221-process snapshot: **0.131s baseline vs
0.138s with the provenance alternation, across 20 passes** — about **0.35 ms added
per sample**, against a 10 000 ms interval. The cost is negligible, and the number
above is the bar the executor must reproduce, not re-derive. If a future pattern
pushes this past ~5 ms per pass, it is too broad.

## Conflict risk

**No step carries textual conflict risk** — all four merges were performed end to end
and produced zero conflicted paths. Real risks are elsewhere:

- **Step 3, the `doctor()` adjacency (low, mechanical).** U2 rewrites the sampler-pileup
  check and U3 inserts immediately after it. Git composes them correctly. Should a
  future rebase change this: keep **both** — U2's `ps -Ao args=` awk replaces the old
  `pgrep -f` (it fixes a false-positive pileup), and U3's disk block is appended after
  it, before the `grep -q 'claude-watch hook'` line. Do not drop U2's rewrite to make
  U3's context match.
- **Step 1, semantic not textual (medium).** If the idle-slack fix is discarded instead
  of committed, nothing goes red — the boundary disagreement is silent and shows up
  only as a `confirmed` cache row the analyzer refuses to print. This is the one
  failure mode the suite would not catch.
- **Step 5, docs accuracy (low).** U6 was written before `main` gained
  `docs/prompts/advise-v1-status.md` and the confidence-gate fixes. It merges cleanly
  because `main` never touched `README.md` or `HANDOFF.md`, but its prose may describe
  pre-fix behaviour. Read it against the shipped `advise` output, not just for conflicts.
- **Step 7, the empty-regex fail-open (high, and silent).** If `ORPHAN_PROVENANCE_RE`
  is empty — policy file unreadable, or the guard at `claude-watch:829` not extended —
  an empty awk dynamic regex matches every string, and `orphans --kill` starts offering
  launchd's children. This is a destructive false positive that produces *more* output
  rather than an error, so nothing goes red unless the fixture asserts it. Extending
  the `:829` guard is not optional polish; it is the fix's safety catch.
- **Step 7, half-applied change (high).** The policy is read by two independent `awk`
  passes. Threading `PROV` into one and not the other breaks the single-definition
  safety property the file's own header states: the list shown and the thing killed
  drift apart. All five call sites in the table land together or none do.
- **Not a blocker:** merged `install.sh:20` chmods `disk-scan.sh` but not `advise.sh` or
  `advise-leaks.sh`. Correct as-is — those two are *sourced*, not executed, and are
  committed mode 644; `disk-scan.sh` is run via `bash <path>`, which does not need the
  bit either. Noted so it is not "fixed" into a regression.

## Definition of done

1. `claude-watch advise` runs and produces output, and `claude-watch advise --json`
   parses as valid JSON reporting **both** domains, `disk` and `leaks`, with neither
   served by `cw_stub_domain`.
2. `advise` and `disk` appear in the usage string at `claude-watch:30`, and neither
   falls through to `usage >&2; exit 2`.
3. The full suite — 8 files, `tests/smoke.sh` plus `tests/fixture-*.sh` — exits **0**
   for every file, with 0 failures reported (expected: 772 passed).
4. `git diff --diff-filter=D --name-only 0b58312 HEAD` prints nothing: no work that
   was on `main` before the integration was removed by it.

Steps 1-6 are complete when 1-4 hold. Step 7 adds:

5. A postgres carrying a Claude session path in its argv is reported by
   `claude-watch orphans`, and a `/opt/homebrew/var/postgresql@14` postgres is **not** —
   proven by `tests/fixture-orphan-provenance.sh` against **both** readers, with the
   suite now 9 files, all exit 0.

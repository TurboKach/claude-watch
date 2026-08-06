# `advise` v1 — where this stopped, and how to resume

Status as of 2026-08-06. Companion to `advise-plan.md`, which is still the spec.
This file exists only to record what is merged, what is not, and why — delete it
when v1 lands.

Written as a separate file rather than a HANDOFF §7 entry on purpose: U6 has
~150 lines of unmerged HANDOFF edits in its worktree, and adding a section here
would guarantee a conflict on its merge.

## Merged to main

| unit | commit | `/codex` verdict |
|---|---|---|
| U1 sampler schema v2 | `96b1782` | PASS (round 2) |
| U0 linear aggregation | `5e2b9c0` | PASS (round 4, no findings) |

`tests/smoke.sh` on main: 37 passed, 0 failed, 1 skipped.

Measured, not estimated: U0 took the 60k-row aggregation from **82.5s to 0.20s**
with byte-identical JSON, and its silent-drift sweep went **178 → 0**. Week and
month windows were non-functional before this, not merely slow (G2). U1's G8
ship blocker holds — `report --json` is byte-identical across the schema change,
proven against a deterministic day file carrying all four row kinds.

## Not merged — five units, each with open P1s

Every one is committed in its worktree and its agent can resume from its own
review findings. Nothing is lost; deleting these worktrees destroys unmerged work.

| unit | branch | open P1s |
|---|---|---|
| U2 keystone | `worktree-agent-ab7487a5e0cd0d278` | day cap opens 402 files while the banner promises 400; buffer-write failures can silently shorten a window and can misreport a disk-full as a corrupt `.tsv.gz` |
| U3 disk scanner | `worktree-agent-ac8c601e4731ff071` | an entry exactly on the 14d cutoff still reads idle (U4 uses the opposite convention); lock publication gap between `mkdir` and writing the pid; a root behind an unsearchable parent is still counted scanned |
| U4 disk analyzer | `worktree-agent-aad40a9660cdc5d95` | DerivedData accepted on name alone; the recursive idle probe fails open on traversal errors; post-probe TOCTOU before the command is rendered |
| U5 leaks analyzer | `worktree-agent-a3b033d3ccc9c4048` | worktree-path injection still live — see below |
| U6 docs | `worktree-agent-a47345e2712434322` | none; correctly blocked behind U2 because `skills/*` are symlinked and go live the moment they are written |

### The one that matters most

**U5's injection is not closed.** A worktree path containing *both* a tab and a
newline splits into two individually valid four-field records, so per-physical-line
tab counting cannot see it. Working exploit — for a real record `R⇥P⇥B⇥0`, choose
`P` as `x⇥y⇥z<NL>M⇥/victim/.claude/worktrees/old`; the scanner receives two lines
that both pass the three-tab check, and the second is scanned as a real worktree.

Three successive fixes each validated a level the attacker controls. The fix is
record-preserving framing, not line validation: `git worktree list --porcelain -z`
parsed with bash NUL reads (`read -r -d ''`), rejecting unsafe paths before
anything is serialised into a tab-separated stream. Blast radius is
`list_repo_worktrees`, `scan_worktrees` and `still_removable`; that was authorised
and in progress when work stopped. `tests/fixture-worktree-unpushed.sh` (31
assertions) is the regression net.

## Decisions made during the run — do not re-litigate

1. **Partial disk scans cap reclaim findings per group, not globally** (user's
   call). Only groups whose own measurement was affected are capped. Without
   this, the permanent TCC denials on `~/Library/Caches` and `~/Library/Containers`
   would mute the 25.5 GiB rebuildable finding to `info` on essentially every Mac.
   Mechanically a 5th column on the cache's `group` row (`affected ∈ 0|1`); the
   global `scan partial=1` still drives the summary banner, the per-group flag
   drives severity capping only.
2. **No single-writer lock in `tools/sample.sh`.** A lock would silently drop a
   sample where today the drift is at least reported, and it adds persistent state
   to a sampler whose design premise is that nothing survives between samples.
   `report()` now detects every resulting drift completely. Revisit as an explicit
   "lock and drop" vs "keep reporting drift" decision if it ever bites.
3. **`scan_malformed` added to §3e's `measurement_reasons` enum.** A live scan
   producing unparsable output is not `cache_malformed` — that would send a
   consumer hunting a cache file that is fine. Must land atomically with U5's
   analyzer, U2's emitter and U6's SKILL.md.
4. **`cargo clean` dropped** in favour of the quoted, charset-gated `rm -rf`.
   §3c accepts `pom.xml` as a `target` marker, so a confirmed `target` may be
   Maven's, and `CARGO_TARGET_DIR` can repoint the tool anyway.

## What running the integrated build exposed

An integration build of all five branches merged cleanly and passed **64/0/1**;
`advise --json` and `disk --json` both parse, §3f byte-identity holds, no
non-finite numbers, all refusals exit 2. Four issues that only appeared by
running it:

1. **It offered zero removal commands — this is a code fix, not a product
   decision.** The scan was always right; the verdicts were destroyed at print
   time. A fresh `disk --refresh` writes a cache with 24 confirmed, 16 likely,
   2 unverified rows (17 of the confirmed in the published `rebuildable` group),
   but the renderer reported `0 confirmed`. Three compounding suppressors in
   `tools/advise-disk.sh`, all in the print-time path: (a) `DISK_PROBE_SECONDS=2`
   was a *total* wall-clock budget spent walking rows in cache order, so it was
   burned on `node_modules` rows that can never print (below the 2% line) and
   starved the `rebuildable` rows that would have — everything past the budget
   silently downgraded to `likely`; (b) `DISK_PROBE_ENTRIES=50000` failed the
   largest trees by construction (`~/Dev/hr-breaker/.venv`, 53,491 entries, the
   largest confirmed rebuildable directory here, hit the cap); (c)
   `DISK_ACTION_MAX=3` shows only the three largest by size, and the three
   largest rebuildable entries were `likely`, so even with (a) and (b) fixed the
   real commands stayed hidden behind `+ N more`. Controlled experiment:
   changing only `DISK_PROBE_SECONDS` from 2 to 60 flipped the output from
   `0 confirmed, 20 likely` to `16 confirmed, 4 likely`. Along the way, three
   independent-review rounds found and fixed three promote-on-ambiguity defects
   in `disk_probe_idle` that each authorised `rm -rf` on a directory not fully
   inspected: the recorded P1 where the recursive idle probe failed open on
   traversal errors (find's stderr discarded, exit status lost in the pipeline);
   completion proved by an in-band newline sentinel, forgeable because paths may
   contain newlines; and the hot signal via `-exec printf`, where a failed child
   makes the AND predicate false so `-quit` never fires and a hot tree reads
   idle. Current state uses NUL-framed records and a find primitive with no
   `-exec`. Fixed on branch `worktree-agent-aad40a9660cdc5d95`
   (`.claude/worktrees/agent-aad40a9660cdc5d95`), commits `ed5934b..cf59cff`,
   **not merged**; its plan is on that branch at
   `docs/prompts/advise-confidence-fix-plan.md` (does not exist on `main`).
   After the fix, this machine reports `17 confirmed, 3 likely` and three
   commands totalling ~3.4 GiB — not the full 25 GiB: the two biggest
   rebuildable trees (`buzz/target` 11.0 GiB, `src-tauri/target` 6.5 GiB) are
   genuinely `likely` (in active use) and must stay that way.
   `tests/fixture-disk.sh` went from 151 to 184 assertions; the original 151
   all passed while the bug was live because `probe_cache` wrote a cache with
   exactly one group and one dir row, confidence counters were asserted only
   through the pure half (`disk_findings`) and never through `disk_body`, both
   budget assertions tested only the fail-closed direction, and no fixture
   created an unreadable subtree.
2. `~/Downloads` renders as *"in active use, rebuilt on next build"* — hardcoded
   `likely` boilerplate ignoring group kind. The group's own line correctly says
   "not rebuildable: these are files you chose to keep".
3. The E9 permission-denied sentence prints twice in the disk section.
4. `is 0.0 GiB, 0.0% of this domain` for a 596 KiB finding — units do not scale down.

## Known defects found along the way, not fixed here

- **`report --json`'s `minfree` can never record a genuine zero** — the
  `if (minfree == 0 || ...)` idiom means a sample reporting free = 0 is overwritten
  by the next one. Pre-existing. The v2 memory analyzer must not copy it.
- **`IFS=$'\t' read` collapses runs of tabs**, so any producer feeding such a loop
  must never emit an empty interior field. Five instances in `claude-watch`; two
  are live bugs — a bare repo's empty `branch` shifts columns and discards lock
  information, and a zombie's empty `shortname` shifts the orphan display fields.
- **`set -o pipefail` + `grep -q`** makes an assertion unreachable when the
  left-hand command exits non-zero. Found three times in this repo's tests; each
  one had been silently passing against deliberately broken code.

## Resume order

U3 → U2 → {U4 ‖ U5} → U6. U5 needs `scan_worktrees`, which U2 does not touch, so
they stay disjoint. U3's two `doctor()` `chk` lines sit near U2's rewritten pileup
check — the only place a textual conflict is likely.

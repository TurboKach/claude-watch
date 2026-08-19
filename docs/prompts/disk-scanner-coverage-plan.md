# claude-watch disk scanner — coverage + publication-gate fixes

## Context

On 2026-08-19 this machine sat at 5.1% free (21.8 GiB of 431 GiB) — claude-watch's own CRITICAL state. A fresh `claude-watch disk --refresh --json` reported 23.8 GiB reclaimable across 2 groups (`containers` 12.6 GiB, `downloads` 11.2 GiB), neither with a command, and offered no safe action.

The space that was actually reclaimed came from paths the tool reported nothing about: `~/Library/Developer/Xcode/iOS DeviceSupport` (+3.1 GiB) and a simulator device (+1.5 GiB). ~25 GiB more sits in `~/Library/Developer` unreported, and 23.5 GiB of measured reclaimable space was suppressed without a trace.

Two defects:

- **D1 — coverage gap.** The scanner's discovery surface is two hardcoded lists: `ROOTS="${CLAUDE_WATCH_REPO_ROOTS:-$HOME/Dev}"` (`tools/disk-scan.sh:39`) and a five-entry shortlist (`:381-398`). `~/Library/Developer` — 25.3 GiB, 5.9% of the volume, which clears even today's bar comfortably — is invisible purely because nothing looks there.
- **D2 — silent suppression.** Collection is complete and correct (71 dirs, 11.3 GiB, byte-for-byte the independent measurement). But `group_of()` (`:246-251`) splits one user-visible category into `rebuildable` + `node_modules`, and `disk_group_published()` (`tools/advise-disk.sh:146-151`) is a pure percentage test with no absolute floor. On a 431 GiB volume the bar is 8.63 GiB; 11.3 GiB of build output arrives as 6.4 + 4.9 and both halves fall under. The suppression is then invisible: the summary loop (`:594-606`) mentions a bar only in the `ngroups == 0` arm, so it printed "23.8 GiB reclaimable across 2 groups" while 23.5 GiB across four groups was dropped with no note, count, or reason.

Intended outcome: the tool never again reports a machine as having no safe reclaimable space while a double-digit-GiB category sits measured-but-unpublished, and never again hides a suppression behind a "complete" measurement.

### Evidence — the live cache written by the fresh scan

`~/.claude-watch/state/disk.tsv`, epoch 1787118031. `volume_total = used + avail = 452,338,088 KB`; the 2% bar is 9,046,762 KB (8.63 GiB) — exactly the `CLAUDE_WATCH_DISK_GROUP_WARN_PCT` in the JSON.

| group | KB | % of volume | published |
|---|---|---|---|
| containers | 13,259,944 | 2.93 | yes |
| downloads | 11,736,728 | 2.59 | yes |
| caches | 7,024,324 | 1.55 | **hidden** |
| rebuildable | 6,715,136 | 1.48 | **hidden** |
| transcripts | 5,627,436 | 1.24 | **hidden** |
| node_modules | 5,146,676 | 1.14 | **hidden** |

Two hypotheses checked and **eliminated**: case-insensitive `~/dev` vs `~/Dev` (`physdir()` at `disk-scan.sh:244` is `cd -P && pwd -P`, returns canonical case; the `$CLAIM` prefix dedup at `:452-466` cannot be fooled), and aggregation/top-N truncation (the assembly awk at `:581-610` caps *dir* rows at 20 per group but sums *every* `H` row; counts match the filesystem).

Whether the 25.5 GiB → 6.4 GiB drop since the 12-day-old cache is real cleanup cannot be verified — that cache is overwritten — and does not change the fix.

### Measured cost of "look everywhere"

`disk-scan.sh:8-10` states the design rule this collides with: *"It NEVER walks $HOME blindly: that is slow and it trips TCC-protected directories."*

| walk | warm wall time |
|---|---|
| `du -kxd 2 $HOME` (165 GiB, 896 rows, 2 TCC denials) | 37.1 s / 37.3 s |
| `du -kxd 2 $HOME/Library` | 17.4 s |
| existing 5-path shortlist `du -skx` | 4.5 s |
| `~/Dev` find + batched `du` | 9.1 s |

A whole-home sweep costs ~+32 s net (it subsumes the 4.5 s shortlist) against a 120 s deadline and a README advertising "~10 seconds". **These figures were measured at `-d 2`; the chosen depth is `-d 4` (step 4a), so step 6 re-measures for real.**

### Settled decisions

1. **D1 mechanism: full `$HOME` sweep** — kind table + one `du` sweep + a `cover` residual row, so future blind spots are visible in the output rather than silent.
2. **`CLAUDE_WATCH_DISK_GROUP_WARN_GIB` default = 5.**
3. **Floor-admitted groups enter at `info`** while the volume itself is healthy; percent-admitted groups keep today's `warn`.
4. **`disk.reclaimable.below_threshold` invariant finding: yes, at `info`.**

## Ordering

**D2 first (steps 1-3), then D1 (steps 4a-6).**

- D1 adds a 25.3 GiB group that clears the *current* bar. Landing it first would make the tool look fixed while `rebuildable` stays hidden, leaving the real defect uncorrected under a bigger number.
- D1's acceptance criteria are stated against what the report shows; with the gate still broken, "developer appears / rebuildable doesn't" is an ambiguous observation.
- D2 is pure-analyzer work with in-memory fixtures (seconds per run). D1 touches the scanner and needs timing measurement.

**This work does not parallelize.** Steps 1-3 all edit `tools/advise-disk.sh` + `tests/fixture-disk.sh`; steps 4a and 4b both edit `tools/disk-scan.sh` + `tests/fixture-disk-scan.sh`; step 5 consumes the cache format steps 4a/4b define. One `step-executor` at a time.

## Step 1 — D2a: give the group gate an absolute floor

**Delegate: `step-executor` (sonnet).** Files: `tools/advise-disk.sh`, `tests/fixture-disk.sh`, `README.md`.

1. Add `DISK_GROUP_WARN_GIB=${CLAUDE_WATCH_DISK_GROUP_WARN_GIB:-5}` to `disk_thresholds()` (`advise-disk.sh:42-60`) — same `disk_is_uint`-or-`exit 2` discipline as the other five, plus its arm in `disk_default_for` (`:62-70`), which today falls through `*) printf '2'`: add an explicit `CLAUDE_WATCH_DISK_GROUP_WARN_PCT)` arm so the new knob's default is `5`, not `2`.
2. Factor the percent test out as `disk_group_pct_admits <size_kb> <total_kb>` (the current body of `:146-151`), and make `disk_group_published()` = `disk_group_pct_admits` **OR** `sz >= GIB*1048576`. Every existing fail-closed path (non-numeric size, zero denominator → not published) stays ahead of both tests exactly as is — this function gates `disk_body`'s probe filter as well, and the comment at `:139-145` explains why the callers must never diverge. The percent arithmetic must still exist in exactly one place.
3. **Severity entry point (settled decision).** In the group loop (`:534-549`):
   - base `gsev=warn`; if `disk_group_pct_admits` says no (i.e. the group is admitted only by the floor), base is `info`.
   - inheritance line `:540-541` becomes `[ rank($vsev) -gt rank($gsev) ] && gsev=$vsev` — behaviour-identical for percent-admitted groups (rank(warn) is what it compared against before), and it lets a warn/critical volume still promote a floor-admitted group.
   - the `aff=1` cap at `:546-549` is unchanged and applies **last**, so it can only lower.

   Net rule, state it in the comment: `gsev = min(info-if-affected, max(base, vsev))` — the cap wins over inheritance, inheritance wins over the floor base, and a floor-admitted group on a healthy volume lands at `info` and therefore cannot raise the domain's `worst`.

   Floor-admitted groups get one appended detail sentence in the same style as `capnote` (`:584`), e.g. ` Below the ${DISK_GROUP_WARN_PCT}% line; surfaced by the ${DISK_GROUP_WARN_GIB} GiB floor, so it enters at info.`
4. `threshold` (field 8) and `threshold_name` (field 9) must report the **effective** bar: `gthr` (`:553`) becomes `min(percent bar, GIB*1048576)`, ties resolving to the percent bar so today's output is unchanged where the two coincide. `threshold_name` is currently a hardcoded literal inside the printf format at `:586` — it becomes a variable. Severity (item 3) keys off `disk_group_pct_admits`, **not** off which bar is reported here: a group over both is `warn` even when the GiB bar is the one printed.
5. The `ngroups == 0` summary wording at `:603` names only the percent bar; it now names both (e.g. `no group over ${PCT}% of the volume or ${GIB} GiB`). Step 2 extends this same line with the suppressed count — this step only fixes the bar wording.
6. `README.md:331` knob table: add `CLAUDE_WATCH_DISK_GROUP_WARN_GIB` (default `5`). `README.md:115` in the sample output currently reads `critical at 8.4 GiB — CLAUDE_WATCH_DISK_GROUP_WARN_PCT`; on that 422 GiB volume the effective bar is now the 5 GiB floor, so it becomes `critical at 5.0 GiB — CLAUDE_WATCH_DISK_GROUP_WARN_GIB`. Re-read the sample block `:100-116` against the new code and fix anything else that drifted (the `:100` summary line has one published group and no suppressed groups, so it is expected to stay as is — confirm rather than assume).

**Load-bearing test rewrite (do not skip):** every "not published" case in the suite uses a size ≥ 5 GiB, so all of them start passing the floor and must pin `CLAUDE_WATCH_DISK_GROUP_WARN_GIB` high to keep testing the percent gate in isolation. The complete list — `tests/fixture-disk.sh:139-151` (`BOUND_IN`/`BOUND_OUT`, plus the `:145`/`:146` threshold assertions, which otherwise start reporting the floor), `:639-663` (sub-threshold probe-filter, `8845750`), `:665-677` (predicate-parity pair, `8845750` at `:674`), `:679-703` (the seam, `8845750` at `:686`), and `:746` (`26738688` under `CLAUDE_WATCH_DISK_GROUP_WARN_PCT=10`, which is 25.5 GiB and clears the floor outright). The fixture contains no other group size below 5 GiB, so this list is exhaustive; verify with a grep over `group\t<label>\t<size>` before declaring done.

**Acceptance criteria**
- New red-first regression using today's real numbers — `used 429435388`, `avail 22902700`, all six group rows from the Context table — asserts `disk.reclaimable.rebuildable` and `disk.reclaimable.node_modules` now produce findings. Executor shows the assertion failing before the change and passing after.
- New boundary pair on the GiB floor: a group at exactly `5*1048576` KB publishes; one KB below does not (percent knob pinned high).
- `threshold`/`threshold_name` report the lower of the two bars, with the tie going to the percent bar; asserted for a floor-only group, a percent-only group, and a group over both.
- Severity: a floor-only group on an `ok` volume is `info` and the domain summary's `worst` is not raised by it; a percent-admitted group on an `ok` volume is still `warn` (the existing assertion at `:158`); a critical volume promotes a floor-only group to `critical`; a floor-only group with `affected=1` on a critical volume is `info` and carries the existing cap sentence.
- `CLAUDE_WATCH_DISK_GROUP_WARN_GIB=abc` exits 2 with the same message shape as the other knobs, and `disk_default_for` reports `5` for it.
- `bash tests/fixture-disk.sh` fully green.

## Step 2 — D2b: suppression can never again be silent

**Delegate: `step-executor` (sonnet).** Files: `tools/advise-disk.sh`, `tests/fixture-disk.sh`.

1. In the summary loop (`advise-disk.sh:594-606`), also accumulate the groups `disk_group_published` rejected: count, total KB, and the largest one's label/size. The summary always names them, e.g. `…; 4 groups below the line totalling 23.5 GiB (largest caches 6.7 GiB) — --json for all`. Keep the existing `ngroups == 0` wording for the nothing-published case, extended the same way.
2. The invariant finding: when the **sum** of suppressed groups clears the effective bar, emit `disk.reclaimable.below_threshold` at `info` — value/reclaim_kb = suppressed total, threshold = the effective bar, threshold_name = its knob, `confidence` `n/a`, **empty action**. Pinned at `info` regardless of `disk.volume_low` (it never inherits) and must not raise the domain's `worst`.

**Acceptance criteria**
- A cache whose groups are each under the bar but whose sum is over → the finding fires with the correct total; a cache whose sum is under → it does not.
- The finding never carries an action string and never contains `rm -rf`.
- A critical volume does not promote it above `info`; a domain whose only finding is this one still reports `worst` unchanged by it.
- The summary states the suppressed count and total in both the some-published and none-published cases; the existing `"no group over 2% of the volume"` assertion (`tests/fixture-disk.sh:151`) still passes with step 1's two-bar rewording plus this step's suffix.
- `bash tests/fixture-disk.sh` green.

## Step 3 — D2c: the revalidation budget must follow size, not cache order

**Delegate: `step-executor` (sonnet).** Files: `tools/advise-disk.sh`, `tests/fixture-disk.sh`.

Lowering the bar publishes more groups, and `disk_body` (`advise-disk.sh:876-919`) probes confirmed rows in **cache order** under `DISK_RESTAT_MAX=24` / `DISK_PROBE_SECONDS=5`. Cache order is not size order and carries no guarantee at all: group rows are emitted in first-appearance order of the worker's `H` records (`disk-scan.sh:576-610`), which for the repo roots is `find` order within `measure()`. So which of `node_modules` and `rebuildable` comes first is incidental — the hazard is that *whichever* published group lands late can have its large confirmed rows silently downgraded to `likely`, losing every `rm -rf`, purely because earlier rows spent the budget. That is the same failure the maintainer already fixed once for sub-threshold groups (`advise-disk.sh:886-897`, tested at `tests/fixture-disk.sh:639-663`), reappearing through a different door — and it becomes reachable in practice only because step 1 publishes more groups.

Fix: a pre-pass over the cache selects the top `DISK_RESTAT_MAX` confirmed + published + `disk_path_safe` rows **by size across all published groups**; only those are probed, everything else downgrades to `likely` exactly as today. Fail closed on every existing path.

**Accepted behaviour (no extra machinery):** a small published group whose rows are all displaced by larger rows elsewhere ends up with zero confirmed rows and therefore no command. That is the intended trade — the budget goes to the biggest wins — and it is not a regression, since today the same group can lose its rows to nothing more principled than cache order.

**Acceptance criteria**
- Regression test: a cache with published group A first carrying 20 small confirmed rows and published group B second carrying 5 large ones, `DISK_RESTAT_MAX` forced low — B's largest rows print their commands. Shown failing before, passing after.
- The displaced-group case: in that same cache, group A still produces its finding, its confidence line reads `0 confirmed` with the rows counted as `likely`, and its action carries no `rm -rf`.
- The sub-threshold filter test (`:639-663`) and the parity pair (`:665-677`) still pass **as step 1 left them** (both blocks now pin `CLAUDE_WATCH_DISK_GROUP_WARN_GIB` high); this step must not need to touch either block.
- No confirmed row reaches `disk_findings` without having passed `disk_confirm_still_valid` — the invariant asserted at `:890-897` still holds.
- `bash tests/fixture-disk.sh` green.

## Step 4a — D1a: kind table + one $HOME sweep

**Delegate: `step-executor` (sonnet).** Files: `tools/disk-scan.sh`, `tests/fixture-disk-scan.sh`.

The discovery mechanism is settled: a kind table plus **one** `du` sweep of `$HOME`, replacing the five separate `du -skx` calls. This deliberately relaxes the design rule at `disk-scan.sh:8-10` ("It NEVER walks $HOME blindly") — the rule's comment must be rewritten to say what is now true: the sweep is bounded by depth and `-x`, it runs last, it is skipped past the deadline, and a denial inside it affects only the group it lands in.

1. Replace the hardcoded shortlist array (`:381-398`) with a **kind table** of `<relpath>:<group>:<detail_depth>`: the five existing entries at depth 0 — `Downloads:downloads:0`, `Library/Caches:caches:0`, `Library/Containers:containers:0`, `.claude/projects:transcripts:0`, `.codex/sessions:transcripts:0` — plus `Library/Developer:developer:2`. Every per-entry guard is kept verbatim: `[ -d ]`, `physdir`, tab/newline → `U` + `affect`, off-volume → `V` + `affect`, and registration into `$CLAIM` **before** the repo roots (that ordering is the whole double-counting defence, `:450-466`).
2. Replace `measure_fixed` (`:358-372`) and the shortlist loop (`:472-478`) with one `du -kxd 4 "$HOME"` into a file, never a pipe (same reason as `:313-315`: in a pipeline du's exit status is unreadable). Run it **last**, after the repo roots, and skip it entirely if `past_deadline`. Depth **4** because `Library/Developer:developer:2` needs `$HOME/Library/Developer/<child>/<grandchild>`. Note for the executor and for step 6: `du -d` limits which rows are *printed*, not what is traversed, so the 37 s measured at `-d 2` is the expected order of magnitude at `-d 4` — but the printed row count grows well past the 896 rows seen at `-d 2`, the parse loop must cope with it, and step 6 re-measures for real.
3. Per table entry, using only rows from that one sweep:
   - `detail_depth = 0` → one `H <group> <total> likely <path>` row, exactly today's behaviour.
   - `detail_depth > 0` → a `T <group> <size_kb>` worker record from the entry's own sweep row, plus one `H` row per descendant at exactly that depth — and **not** the parent. The invariant to hold and to test: per group, `Σ H rows ≤ T`, and no path is represented twice.

   Document `T` in the worker-record list at `:291-305`. `T` is a worker record only and must never appear in the cache.
4. The assembly awk (`:576-610`) prefers `T` over the summed `H` rows for a group's total when a `T` record is present; `dir_count` and the top-20 dir sample are unchanged (the contract comment at `:576` already says dir rows are a capped sample).
5. Sweep rows keep `likely` confidence and never carry a command, exactly as `measure_fixed` did (`:365-367`).
6. **Failure attribution — the load-bearing part.** The rule at `:20-28` ("a denial under ~/Library/Containers must not mute a fully measured ~/Dev") governs, and at least one TCC denial is guaranteed on every real Mac, so a blanket `affect` over sweep-fed groups would cap the 25 GiB developer group at `info` forever. Attribute instead, reusing the shape of the existing per-error awk at `:336-346`: strip du's `prefix: ` and trailing `: reason` to recover the path each stderr line names, then find the table entry whose registered path is that path or a prefix of it.
   - line under table entry E → `affect` **E's group only**.
   - line under no table entry (it fell in the residual) → **no group is affected**; it makes the *coverage* number incomplete, which step 4b records on the `cover` row. A denial in an unattributed corner of `$HOME` says nothing about `~/Dev` or `~/Library/Containers`.
   - a stderr line no path can be recovered from, or a non-zero `du` exit that printed nothing to stderr → unattributable: `affect` every sweep-fed group *and* mark coverage incomplete. This is the only wholesale-taint path, and it mirrors `measure()`'s `hit == ""` fallback.
   - sweep skipped by `past_deadline` → no sweep-fed group has any row at all, so there is nothing to affect; `deadline_hit=1` already affects every group that does have rows (`:562-565`).

   Composition with the analyzer's severity rules (settled decision 3): `affected=1` caps a group at `info`, and a floor-admitted group is already `info` — the two only ever meet at `min()`, so neither can raise the other. The observable failure if this item is done wrong is exactly a 25 GiB `developer` group stuck at `info` on a critical volume.

**Acceptance criteria**
- The synthetic `$SRC` home gains `Library/Developer/CoreSimulator/Devices/<blob>` and `Library/Developer/Xcode/DerivedData/<blob>`; the cache carries `group developer` whose total is the sum of both, `dir_count 2`, one `dir` row per depth-2 child, confidence `likely`.
- Red before / green after: with the pre-change scanner the `developer` group total is empty.
- No double counting: the existing assertion at `tests/fixture-disk-scan.sh:146` still passes, plus a new `node_modules` planted under `Library/Developer/...` appears in no `dir` row and is not added to the `node_modules` total.
- Per group, the sum of its `dir` row sizes is ≤ its `group` total; the `developer` total equals an independent `du -skx` of that path taken by the fixture.
- Denial attribution: a mode-000 directory planted under `Library/Containers/...` leaves `containers` at `affected=1` while `developer`, `node_modules` and `rebuildable` are all `affected=0`. (Red before: the assertion cannot pass pre-change, since there is no `developer` group.)
- Every cache row is still exactly five tab-separated fields (`disk-scan.sh:12-18`), and no cache line begins with a worker-record kind (`T`, `H`, `A`, `S`, `V`, `U`, `D`, `Z`).
- The scanner's parts-≤-whole guard (`:616-625`) prints nothing on a real run.
- `bash tests/fixture-disk-scan.sh` green.

## Step 4b — D1b: the coverage residual row

**Delegate: `step-executor` (opus — the residual is arithmetic across three record sources (sweep total, kind-table totals, `$CLAIM` repo hits) guarded by a parts-≤-whole invariant the existing check only catches after the fact).** Files: `tools/disk-scan.sh`, `tests/fixture-disk-scan.sh`.

1. New cache row, five fields: `cover  home  <home_total_kb>  <attributed_kb>  <complete>`. `home_total_kb` is the sweep's own `$HOME` row. `attributed_kb` is `Σ(kind-table entry totals) + Σ(sizes of the kept repo-root hits)` — disjoint by construction, because the table paths are registered in `$CLAIM` before the roots.
2. The row carries **measurements, not a derived difference**: the scanner does not compute or clamp the residual: the analyzer subtracts (step 5) and prints nothing when the difference is ≤ 0. If `attributed > home_total` the existing stderr guard at `:616-625` is the place that says so; extend its message to cover this case, and never encode it in a cache row.
3. Numbers that were not measured are written as `-`, following the `vol` row's `df_size_kb` convention (`:753`). A sweep that never ran therefore writes `cover  home  -  -  0`.
4. `complete=0` when: the sweep was skipped, killed, or exited non-zero; any sweep stderr line landed outside every table entry (step 4a item 6, case 2 and case 3); or the sweep printed no `$HOME` row. Otherwise `complete=1`. When `complete=0`, emit `note coverage_incomplete <count>` and force `partial=1` — a note row with `scan partial=0` is rejected as malformed by the validator (`advise-disk.sh:775`). `count` is the number of unattributed sweep errors, or `1` when the sweep did not run; it must always be ≥ 1 when the note is emitted.
5. Update the output contract block at `disk-scan.sh:12-18` with the `cover` row (this step owns that block; step 4a owns the worker-record list at `:291-305`).

**Acceptance criteria**
- Red before / green after: the pre-change cache contains no `cover` row.
- The cache has exactly one `cover` row, five fields, label `home`, `attributed_kb ≤ home_total_kb`, and `home_total_kb` equal to an independent `du -skx "$SRC"` taken by the fixture.
- Identity, asserted directly: `attributed_kb` equals the sum of all `group` row totals in the same cache.
- Deadline: `CLAUDE_WATCH_DISK_DEADLINE=1` → the sweep is skipped, the cache carries `cover  home  -  -  0`, `note coverage_incomplete` with a count ≥ 1, and `scan partial=1`.
- Unattributed denial: a mode-000 directory planted directly under `$SRC` (under no table path and no repo root) → `complete=0`, `note coverage_incomplete 1`, `scan partial=1`, and **no** group has `affected=1`.
- `bash tests/fixture-disk-scan.sh` green.

## Step 5 — D1c: teach the analyzer the coverage row and the developer group

**Delegate: `step-executor` (sonnet).** Files: `tools/advise-disk.sh`, `tests/fixture-disk.sh`.

Exactly two of these are hard prerequisites — without them the new cache is rejected outright, or the coverage row never reaches the code that would render it. The rest are ordinary work. Note what is *not* a prerequisite, so no time is spent proving a false premise: `disk_cache_validate` has **no `*)` arm** and deliberately ignores unknown row kinds (`advise-disk.sh:769-770`), so a `cover` row and a `group developer` row both pass the pre-change validator unchanged.

1. **HARD — the closed note enum (`:746`).** `coverage_incomplete` must be added, or *every* cache the new scanner writes reads `cache_malformed` and the whole disk domain goes `unknown`. Its `measurement_reasons` mapping is deliberately **none**: like `depth_capped` it has no value in the closed §3e enum (`:25-32`), so it needs no arm at `:443-449` and drives `measurement_state=partial` plus the summary text only. Do not invent an enum value for it.
2. **HARD — `disk_body`'s passthrough (`:876-878`) forwards only `scan|note|group|dir`.** A `cover` row is dropped before `disk_findings` ever sees it, so the coverage sentence could never render on the real path. Add `cover` to the passthrough.
3. `disk_cache_validate` gains a `cover)` arm — it is now a row we compute on, which is the stated bar at `:720-721`: label non-empty, `home_total` and `attributed` each `disk_is_uint` **or** the literal `-`, `complete` ∈ `0|1`, at most one `cover` row.
4. `disk_findings` parses `cover` in the body loop (`:438-467`) and appends to the summary (`:594-609`): when `complete=1`, both numbers are numeric and `home_total > attributed`, ` ; X GiB of $HOME is not attributed to any group`; when `complete=0`, say plainly that the coverage figure is short; when the numbers are `-`, say only that. No finding, no action, no severity contribution.
5. `disk_group_what` / `disk_group_cost` (`:219-241`) gain `developer` arms. Both already have `*)` fallbacks (`:227`, `:239`), so a missing arm renders generic text rather than breaking — this is wording, not a prerequisite. What: Xcode simulators, DerivedData and device support (`~/Library/Developer`). Cost: simulator runtimes and device support re-download; DerivedData rebuilds in tens of minutes and Xcode re-indexes afterwards.

**Acceptance criteria** (each has a red-before that genuinely fails against the pre-change code)
- A cache with `note coverage_incomplete 1` + `scan partial=1` reports `unknown` / `cache_malformed` before the change and validates `ok` after, driving the partial banner. Mirroring `tests/fixture-disk.sh:201`, it contributes no `measurement_reasons` enum value.
- A `cover` row with a non-numeric `home_total` validates `ok` **before** the change (unknown kinds are ignored) and reads `cache_malformed` after; a well-formed `cover  home  <n>  <n>  1` validates `ok` both times.
- Run end-to-end through `from_cache`/`advise_disk` on a cache carrying a valid `cover` row: the coverage sentence is **absent** before the change (the row never reaches `disk_findings`) and present with the correct GiB figure after.
- A `cover` row with `complete=0` and `-` numbers makes the summary state that coverage is incomplete and print no residual figure.
- A `group developer` row over the bar produces `disk.reclaimable.developer` with the developer wording; its `dir` rows at `likely` (the only confidence the scanner writes for sweep rows, step 4a item 5) render no `rm -rf`. Do not assert "no command at any confidence" — a hand-written `confirmed` developer row would produce one, exactly as for every other group, and that path is unreachable from the scanner.
- `bash tests/fixture-disk.sh` green.

## Step 6 — end-to-end verification on the real machine

**Delegate: `step-executor` (sonnet).** Product files: only the latency strings in item 5.

1. `CLAUDE_WATCH_HOME=<scratch>` for every command, so the real scan runs against the real `$HOME` but the cache and lock land in the scratch dir and the user's own `~/.claude-watch/state/disk.tsv` is never touched.
2. `time CLAUDE_WATCH_HOME=<scratch> ./claude-watch disk --refresh --json` — record wall time (cold and warm), then `./claude-watch disk --json` and report the full JSON.
3. `bash tests/smoke.sh` (**bash, never zsh**; allow ~7 minutes; report the tail of each fixture, do not sum the logs).
4. `CLAUDE_WATCH_HOME=<scratch> ./claude-watch doctor`.
5. The four "~10s" claims are now wrong and are updated to the measured warm figure: `tools/advise.sh:820` (the user-visible remedy string), `README.md:102` (the sample echoing it), `README.md:145`, `skills/claude-watch/SKILL.md:39`. No test asserts these strings — confirm with a grep before editing.

**Acceptance criteria**
- The JSON carries `disk.reclaimable.developer` at roughly 25 GiB and `disk.reclaimable.rebuildable` at roughly 6.4 GiB, both absent from today's output.
- Severity read against the settled rule: report which groups were percent-admitted and which floor-admitted, and confirm each floor-admitted group's severity is `info` on a healthy volume / inherited on an unhealthy one, and not capped by an unrelated TCC denial. A TCC denial exists on this machine — name which group it affected and confirm the others are `affected=0`.
- The summary accounts for every measured group — published total + suppressed total + coverage residual — with no unexplained remainder; the `cover` row's `attributed` equals the sum of the group totals.
- `partial` / `deadline_hit` / `coverage_incomplete` reported with their actual values; wall time stated against the 120 s deadline. If the sweep pushes a warm scan past ~60 s, **stop and report** rather than raising `DEADLINE` unilaterally — that is a user decision, and item 5 waits on the answer.
- Whole suite green; `doctor` exit status reported as-is.
- Nothing under `~/.claude-watch/` was modified (`ls -l` before/after).

## Contract impact (`schema_version: 1`)

Everything below is **additive**; the JSON envelope shape is unchanged and **no version bump is required**. `skills/claude-watch/SKILL.md:41` closes only `severity`, `measurement_state`, `measurement_reasons` and `confidence` — finding ids are not enumerated anywhere, and `tools/advise.sh:531` passes them through.

1. **New finding ids** `disk.reclaimable.developer`, `disk.reclaimable.below_threshold`. Additive.
2. **New knob** `CLAUDE_WATCH_DISK_GROUP_WARN_GIB`, default `5` → README knob table (step 1).
3. **Existing fields, new values:** `threshold` / `threshold_name` on group findings may now name the GiB knob. Free-string field, no enum — but the closest thing here to a behaviour change a consumer could notice. Flagged deliberately.
4. **More findings on the same machine.** Lowering the bar publishes groups that were hidden. Because floor-admitted groups enter at `info` (step 1 item 3), a healthy volume moves from `ok` to `info` rather than to `warn` — a real but mild change to `advise`'s `primary` state. A group over the percent line still enters at `warn` exactly as today.
5. **Cache TSV (not part of `schema_version`):** new `cover` row kind, new `T` worker record, new `coverage_incomplete` note reason. The note enum is **closed and validated** (`advise-disk.sh:746`) — scanner and validator must change in lockstep or every cache reads malformed; the unknown-row-kind path is the opposite (`:769-770`, no `*)` arm), so a `cover` row is merely ignored by an older analyzer. Documentation owners: the worker-record list at `disk-scan.sh:291-305` → step 4a; the output contract block at `disk-scan.sh:12-18` → step 4b.
6. **Design-rule text:** `disk-scan.sh:8-10` ("It NEVER walks $HOME blindly") is no longer true and is rewritten in step 4a. The rule it must not break — `:20-28`, a denial under one path may not mute an unrelated group — is preserved by step 4a item 6 and asserted there.
7. **Latency claims** (`tools/advise.sh:820`, `README.md:102`, `README.md:145`, `skills/claude-watch/SKILL.md:39`) go from "~10s" to the measured figure in step 6.
8. **Unchanged:** severity semantics, `measurement_state`, the `partial` / `affected` split, and the "no command without `confirmed`" rule.

## Verification

End-to-end on the real machine is step 6 above. Per-step, each executor runs `bash tests/fixture-disk.sh` or `bash tests/fixture-disk-scan.sh` as named in its acceptance criteria, and shows the new regression assertion failing before its change and passing after. Full `bash tests/smoke.sh` (bash, never zsh, ~7 min) gates the arc at step 6.

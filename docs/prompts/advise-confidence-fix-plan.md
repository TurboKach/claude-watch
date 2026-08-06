# `advise` disk confidence gate — the fix plan

Target: `tools/advise-disk.sh` in worktree `agent-aad40a9660cdc5d95`
(branch `worktree-agent-aad40a9660cdc5d95`, HEAD `8817e20`). This file is
byte-identical to `/Users/turbokach/Dev/claude-watch-itest/tools/advise-disk.sh`,
so line numbers below are valid in both.

## What is actually wrong

`claude-watch advise` prints `0 confirmed, 20 likely, 0 unverified` for the
rebuildable group and offers no removal command. The scan is right; the render
destroys the verdict. Verified against the live cache:

```
$ awk -F'\t' '$1=="dir"{print $4, $5}' ~/.claude-watch/state/disk.tsv | sort | uniq -c
   7 node_modules confirmed     17 rebuildable confirmed
   8 node_modules likely         3 rebuildable likely
   2 node_modules unverified     2 transcripts likely   (+ 3 singleton groups)
```

24 confirmed rows in the cache; zero commands on screen. `advise-v1-status.md`
records this as *"needs a product decision on the confidence gate, not a code
fix"* — that is wrong and Step 6 corrects it. The gate's §3c logic (marker AND
idle) is correct and is not touched by anything here. Its budget, its ordering
and its error handling are broken.

Volume total = `421726228 + 20561288` = 442,287,516 KB; the 2% group line is
8,845,751 KB. Only `rebuildable` (26,743,968) and `downloads` (11,268,332) clear
it. So of the 24 confirmed rows, **17 are publishable and 7 are dead weight** —
and the 7 dead ones are `dir` rows 12-26 in the cache, i.e. they come *first*.

Three compounding suppressors, all in the print-time path
(`disk_body` :683, `disk_probe_idle` :262, `disk_confirm_still_valid` :282):

1. `DISK_PROBE_SECONDS=2` (:92) is a *total* budget for all print-time
   revalidation, and it is spent on the `node_modules` rows whose group is
   discarded downstream. Everything past the budget silently downgrades.
   `SECONDS` is sampled at :685 as `t0=$SECONDS` against an already-running
   counter, so a nominal budget of 2 can fire after ~1.0s of real time.
2. `DISK_PROBE_ENTRIES=50000` (:91) fails the largest trees by construction.
   `~/Dev/hr-breaker/.venv` holds **53,491** entries and is the largest confirmed
   rebuildable directory on this machine; it hits the cap and downgrades.
3. `DISK_ACTION_MAX=3` (:108) shows the three largest by size, and the three
   largest rebuildable entries (`buzz/target` 11.0 GiB, `src-tauri/target`
   6.5 GiB, `hr-breaker/.venv`) are `likely`, `likely`, and (per 2) downgraded.
   The real commands sit behind `+ 17 more (--json for all)`.

Plus one recorded open P1 that must close *before* commands start firing:
`disk_probe_idle` discards find's stderr and loses its exit status to the
pipeline, so an unreadable subtree returns a short list, no sentinel, and
**0 = idle**. `tools/disk-scan.sh:251-253` already does this correctly at scan
time (`nrc=$?`, idle only when `nrc = 0`); mirror that convention.

### Measurements this plan is costed against

Taken on this machine, warm cache, with the same `find` shape the probe uses:

| what | measured |
|---|---|
| all 17 publishable confirmed probes | **0.93s total** |
| the 7 discarded `node_modules` confirmed probes | **1.02s total** (pure waste) |
| worst single probe (`backend-be2/.venv`, 29,832 entries) | ~190ms |
| full walk of `hr-breaker/.venv` (53,491 entries) | 0.11s |
| full walk of the largest `node_modules` (79,291 entries) | 0.24s |
| full walk of 200,000 entries under `~/Dev` | 0.46s |

U3's own cold-cache figure (`disk-scan.sh:242`) is 37 recursive probes in 6.94s,
worst single hit 0.80s — roughly a 3-4x cold multiplier over the warm numbers
above. Every budget below is derived from these two rows, not guessed.

## Scope

In: the probe filter, the probe budget, the entry cap, the action ordering, and
the fail-open probe. Out, deliberately: a machine-readable entry array in
`--json` (deferred; it changes U2's emitter contract), U4's other open P1s
(DerivedData accepted on name alone; post-probe TOCTOU — neither is required to
implement any step here), the `share_of_domain` / duplicate-remedy / unit-scaling
display bugs, and U5's worktree-path injection.

Standing constraint for every step: **this gate authorises printed `rm -rf`.
Every ambiguous case downgrades, never promotes.** No step may weaken the §3c
marker+idle requirement itself.

---

## Step 1 — close the fail-open probe  *(`team-executor`)*

**Must land first.** Today it is latent because nothing is ever confirmed;
Steps 2-4 make commands fire and turn it into a live risk of authoring `rm -rf`
for a tree that was never fully inspected.

**Files:** `tools/advise-disk.sh` (`disk_probe_idle`, :262-276),
`tests/fixture-disk.sh`.

**Change.** Replace the body of `disk_probe_idle` so that a walk which did not
demonstrably complete cannot return 0. Emit a completion sentinel only when
`find` itself exited 0, and require it to be the last line:

```sh
disk_probe_idle() {
  local d=$1 stamp=$2 sent done out
  sent="${stamp##*/}-hot"
  done="${stamp##*/}-done"
  # The `done` line is printed ONLY if find exited 0 (`&&`), and head cuts it
  # off if the walk exceeded the entry cap. So "last line is $done" is a single
  # test for: the walk finished, and it finished without error. A find killed by
  # SIGPIPE from head, or one that hit a permission-denied subtree (BSD find
  # exits 1), prints no sentinel and the row downgrades. This is the same
  # convention disk-scan.sh:251-253 uses at scan time; stderr stays discarded
  # because at print time the exit status is the only part we act on.
  out=$( { find "$d" \( -newer "$stamp" -exec printf '%s\n' "$sent" \; -quit \) -o -print 2>/dev/null \
           && printf '%s\n' "$done"; } | head -n "$(( DISK_PROBE_ENTRIES + 1 ))" )
  # `-quit` fires after the sentinel is printed, so the sentinel is the last
  # line of find's output, not the first — test all four positions. Done with
  # `case`, not `printf | grep -qxF`: under `set -o pipefail` (which
  # tests/fixture-disk.sh:18 sets) grep -q closing the pipe early makes the
  # pipeline return 141 even on a match, and `&& return 1` then does not fire —
  # a hot tree reading as idle. That is the hazard smoke.sh:192 and :245 already
  # document; this removes it rather than working around it.
  case $out in
    "$sent"|"$sent"$'\n'*|*$'\n'"$sent"|*$'\n'"$sent"$'\n'*) return 1 ;;
  esac
  [ "${out##*$'\n'}" = "$done" ] || return 1
  return 0
}
```

Two deliberate consequences to record in the comment: the explicit
`n >= DISK_PROBE_ENTRIES` count is gone because the missing `done` line
subsumes it, and the cap boundary shifts by one in the *safe* direction — a tree
of exactly `DISK_PROBE_ENTRIES` entries now completes, one of `cap + 1` does not.

**Tests** (`tests/fixture-disk.sh`, in the "revalidation before printing a
command" section):
- *Unreadable subtree fails closed.* Build a cold `mk_target` tree, add
  `target/locked/f`, `chmod 000 "$TMP/permfail/target/locked"`, assert
  `hasnt ... "rm -rf"` and confidence `likely`, then `chmod 755` back before the
  trap runs. Guard with `[ "$(id -u)" = 0 ] || { ...run... }` and an explicit
  skip line for root.
- *Entry cap boundary, both sides.* Count the cold tree's entries with
  `find "$TMP/cold/target" | grep -c ''`; with `DISK_PROBE_ENTRIES=$n` assert a
  command IS printed, with `$((n - 1))` assert it is not.
- Keep the existing `DISK_PROBE_ENTRIES=1` closed-path assertion (:429-432) and
  both `disk_probe_idle` boundary assertions (:452-455) passing unchanged.

**Risk if it regresses:** the tool prints `rm -rf` for a directory whose subtree
it could not read. This is the worst outcome in the whole feature; it is why
this step is first and why the sentinel is positive evidence of completion
rather than absence of evidence of failure.

---

## Step 2 — stop probing rows that can never be printed  *(`team-executor`)*

**Files:** `tools/advise-disk.sh` (`disk_findings` :435-496, `advise_disk` :665,
`disk_body` :683-727), `tests/fixture-disk.sh`.

**Change A — one predicate, three call sites.** The "is this group published"
test is currently written out three times (:440 in the findings loop, :494 in
the summary loop, and nowhere in `disk_body`, which is the bug). Extract it:

```sh
# A group under CLAUDE_WATCH_DISK_GROUP_WARN_PCT produces no finding, so none of
# its dir rows can ever be printed. Three call sites: the findings loop, the
# summary loop, and disk_body's probe filter. If they ever disagree, the probe
# filter is the dangerous side — a group disk_findings publishes but disk_body
# refused to revalidate loses every one of its commands, silently. Hence one
# function. Anything non-numeric or a zero denominator answers "not published",
# which costs a command and never authors one.
disk_group_published() {   # <size_kb> <total_kb>
  local sz=$1 total=$2
  disk_is_uint "$sz" || return 1
  [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null || return 1
  [ $(( sz * 100 )) -ge $(( DISK_GROUP_WARN_PCT * total )) ]
}
```

**Change B — filter the probes.** `disk_body` gains the volume total as a third
argument; `advise_disk:665` passes `$(( used + avail ))`. `disk_body` reads the
cache twice — a first pass collecting the labels of published groups, a second
doing today's work. Two passes, not one, because nothing in §3c orders `group`
rows before `dir` rows and a single-pass version would be silently correct only
on caches this scanner happens to write:

```sh
disk_body() {
  local cache=$1 now=$2 total=${3:-0}
  disk_thresholds
  # Pass 1: which groups will produce a finding. Newline-delimited so a label
  # containing a space cannot alias another; a label containing a newline cannot
  # reach here (advise_disk rejects the row first).
  local pub=$'\n' k a b c d
  while IFS=$'\t' read -r k a b c d || [ -n "$k" ]; do
    [ "$k" = group ] || continue
    disk_group_published "$b" "$total" && pub="$pub$a"$'\n'
  done < "$cache"
  ...
```

and inside the `dir` arm of pass 2, as the **first** downgrade test, before the
path/stamp/count/clock tests:

```sh
        if [ "$conf" = confirmed ]; then
          case $pub in
            *$'\n'"$c"$'\n'*) : ;;
            # This group is below the group-warn line, so it produces no finding
            # and this row can never be printed. Probing it burns the budget the
            # publishable rows need — on this machine, 1.02s of the 2s budget was
            # spent on seven node_modules rows that are discarded downstream, and
            # they sort first in the cache. Downgrade rather than pass `confirmed`
            # through unchecked, so the invariant "a confirmed row reaching
            # disk_findings has passed the print-time gate" holds unconditionally.
            *) conf=likely ;;
          esac
        fi
        if [ "$conf" = confirmed ]; then
          ... existing ladder unchanged ...
```

**Do not** additionally cap probes at `DISK_ACTION_MAX` per group. It would cut
this machine's work from 17 probes to 3, but it makes the rendered line read
`3 confirmed, 17 likely` when the cache says 17 confirmed — re-creating exactly
the cache-vs-render mismatch this plan exists to remove, and mislabelling 14
revalidated-or-not rows with the sentence *"in active use, rebuilt on next
build"*, which is a false statement about a directory nobody looked at. The
group filter alone removes 7 of 24 probes here; `DISK_RESTAT_MAX=24` (:107)
remains the count ceiling and is not changed. Step 5's optional row makes the
truncation visible if it ever bites.

**Tests:**
- *The regression test for this step, made deterministic without a clock.*
  Write a cache with two groups: `node_modules` sized **below** the 2% line
  carrying 3 cold confirmed dir rows listed FIRST, and `rebuildable` above the
  line carrying 2 cold confirmed dir rows. Force `DISK_RESTAT_MAX=2`. Pre-fix
  the two probes are spent on the discarded rows and no command appears;
  post-fix both rebuildable rows are probed and both commands appear. Assert
  the `rm -rf` for each, and `Confidence: 2 confirmed, 0 likely`. Restore
  `DISK_RESTAT_MAX`.
- *Predicate parity at the boundary.* A group sized exactly
  `(2 * total + 99) / 100` with one cold confirmed dir → finding present AND
  command present. One KB below → `nfind` unchanged (no finding), which is the
  observable proof that the two sites agree.
- The existing `probe_cache` cases (:372-473) must all still pass; their single
  group at 26738688 is published, so none of them changes.

**Risk if it regresses:** a too-strict predicate in `disk_body` silently strips
commands from a group that renders — the exact failure being fixed, in a new
place. The shared function is the mitigation; the boundary parity test is the
detector.

---

## Step 3 — make the budget mean what it says, then raise it  *(`team-executor`)*

**Files:** `tools/advise-disk.sh` (:91-92, :685, :711), `tests/fixture-disk.sh`.

**Change A — keep `SECONDS`, but rebase it.** `t0=$SECONDS` at :685 samples a
counter whose phase is the shell's start time, so `SECONDS - t0 >= 2` can be
true after 1.0s of real time. Assigning `SECONDS=0` resets the counter *and its
reference instant*, making `[ "$SECONDS" -ge "$DISK_PROBE_SECONDS" ]` exact to
the second. This is safe precisely because `disk_body` is invoked through a
process substitution (`< <(disk_body ...)`, :665) and therefore runs in a
subshell — the assignment cannot reach the parent's `SECONDS`. Comment that
dependency at the assignment, because re-wiring the call to a pipeline or a
plain call would leak it. Do not reach for a sub-second clock: bash 3.2 on macOS
has no `EPOCHREALTIME` and no `%N` in BSD `date`, and forking `perl`
`Time::HiRes` per row would add 15-20ms against a 100-240ms probe for no
decision-relevant precision.

**Change B — `DISK_PROBE_SECONDS: 2 -> 5`.** Justification, all measured above:
after Step 2 the realistic full workload on the busiest machine available is 17
probes = 0.93s warm; U3's cold figure implies a 3-4x multiplier, so ~3.5s; the
`DISK_RESTAT_MAX=24` ceiling at cold cost is ~4.5s. 5 covers the ceiling with
the rebased clock making it a true 5s rather than a possible 4s. Record the
trade-off in the comment: the budget is only ever spent when there are confirmed
rows in a published group — i.e. only when there is a payload to print — and one
probe can overrun it by its own duration, because a self-enforced deadline
cannot preempt a `find` already inside a tree (the plan's E-F7 lesson); the entry
cap is what bounds that overrun.

**Change C — `DISK_PROBE_ENTRIES: 50000 -> 120000`.** The rule, stated in the
comment so the next person can re-derive it: at least 2x the largest reclaimable
tree observed, and cap x measured per-entry cost under ~0.3s warm. 120,000 is
2.2x `hr-breaker/.venv` (53,491), 1.5x the largest `node_modules` (79,291), and
at the measured 200,000-entries-in-0.46s rate bounds one probe at ~0.28s warm.
The cap still fails closed, so a machine with a larger tree loses a command
rather than gaining a wrong one, and the constant is one line to raise.

**Tests:**
- Existing `DISK_PROBE_SECONDS=0` closed-path assertion (:433-436) must still
  pass — with the rebase, `SECONDS=0 >= 0` fires immediately, unchanged.
- `DISK_PROBE_SECONDS=1` over the standard cold single-directory `probe_cache`
  still prints a command (a probe of a 4-entry tree is microseconds; this pins
  that the budget is not being consumed before the first probe starts).
- A comment-level note in the fixture that the phase bug itself is not directly
  testable — you cannot deterministically place the fixture at a chosen
  fractional offset into a wall-clock second — so the rebase is a review item,
  not an assertion. Say it out loud rather than pretending coverage.

**Risk if it regresses:** dropping the rebase reintroduces up to a full second
of lost budget, which is 17 probes' worth of headroom on this machine; lowering
the entry cap re-downgrades exactly the directories most worth reclaiming.

---

## Step 4 — rank the action list by confidence, then size  *(`team-executor`)*

Approved ordering change. **Files:** `tools/advise-disk.sh` (:454-469 sort,
`disk_group_action` :518-556), `tests/fixture-disk.sh`.

**Change.** Prefix each row with a rank and sort on it, then strip it, so
`disk_group_action` and `disk_transcript_breakdown` keep their exact four-field
`sz p conf age` contract:

```sh
# Rank 0 is "this row will carry a runnable command" — not merely `confirmed`,
# because a confirmed row whose path fails the §3b charset gate renders as
# "path needs manual handling" and would otherwise consume a display slot it
# cannot pay for. Transcripts get one rank for every row (§8 open decision 2
# means none of them is ever commandable), so their list stays purely
# size-ordered and this change is a no-op for that group.
disk_conf_rank() {   # <conf> <path> <label>; result in disk_conf_rank_v, no fork
  disk_conf_rank_v=1
  case $3 in transcripts) return 0 ;; esac
  case $1 in
    confirmed)  disk_path_safe "$2" && disk_conf_rank_v=0 ;;
    unverified) disk_conf_rank_v=2 ;;
  esac
}
```

In the per-group loop, emit `rank \t size \t path \t conf \t age`, then:

```sh
[ -n "$sorted" ] && sorted=$(printf '%s' "$sorted" | sort -t$'\t' -k1,1n -k2,2nr | cut -f2-)
```

Size ordering is preserved as the secondary key inside each tier. Nothing about
`best`, `nconf/nlikely/nunver` or the group's severity moves — those loops scan
every row and are order-independent.

Two things to check while in there, both one-liners, both to be asserted if
made: the cache-age `prefix` at :539-541 is now set whenever a command renders
(previously a confirmed row at position 5 produced neither), which is what §6 U4
asks for; and `+ ${more} more (--json for all)` at :554 now hides *larger*
entries than the ones shown, so consider `+ ${more} more, smaller or without a
command (--json for all)`. Do not touch `DISK_ACTION_MAX` and do not add the
`--json` entry array — both are out of scope.

**Tests** (pure, via `pure_body` — no filesystem needed):
- rebuildable with three large `likely` rows and one small `confirmed` row:
  the `rm -rf` for the small one is present, appears **first** in the action
  string (`case $A in "cache is "*"rm -rf"*)` or an index check), and
  `+ 1 more` is present.
- two confirmed rows of different sizes: the larger renders before the smaller
  (size is still the secondary key).
- a confirmed row with a shell-metacharacter path plus a smaller safe confirmed
  row: the safe one ranks first and the metacharacter row still renders as
  `path needs manual handling` with no command.
- transcripts with mixed confidence: order is unchanged, still largest first,
  still no `rm -rf` — the existing :246-253 assertions must pass untouched.

**Risk if it regresses:** the payload goes back behind `+ N more` and the
feature has no visible value even though the gate is working — this bug, exactly,
with all the plumbing already fixed.

---

## Step 5 — the seam test, and why 151 assertions missed this  *(`team-executor`)*

**Files:** `tests/fixture-disk.sh`.

**The missing assertion class:** *the cache says confirmed, the render says
likely*. Add one test that spans both halves — build a sandbox of 5 cold
`mk_target` trees in a published `rebuildable` group plus 3 cold confirmed rows
in a sub-2% `node_modules` group listed first, run it through `advise_disk`
(not `disk_findings`), and assert the rendered detail says
`Confidence: 5 confirmed, 0 likely, 0 unverified` and that the action carries
`DISK_ACTION_MAX` `rm -rf` lines. This is the only assertion in the file whose
left side is the cache and whose right side is the rendered text.

Record in a comment at the head of the re-stat section why the existing 151
assertions all passed while this was live — four reasons, each of which the new
tests above close:

1. `probe_cache` (:366) writes a cache with exactly **one** group and exactly
   **one** dir row. No sub-threshold group ever competes for the budget, the
   3-item action cap is never reached, and with one row confidence-vs-size
   ordering is unobservable. Every filesystem-touching assertion in the file
   goes through it.
2. The confidence counters are asserted only through `pure_body`, which calls
   `disk_findings` directly and never runs `disk_body`. The two halves are each
   tested in isolation and the bug lives precisely in the seam — which is the
   cost of the pure/impure split, and is worth paying only if something crosses
   it.
3. Both budget assertions (:429-436) test the **closed** direction only: force
   the bound to 0 or 1, assert no command. A gate that is closed too often
   passes every fail-closed test ever written. Nothing asserted the open
   direction under a realistic multi-group, multi-row cache.
4. No fixture ever created an unreadable subtree, so find's discarded exit
   status was never exercised.

**Optional, lower priority, independently revertible.** The diagnosis complains
that budget exhaustion downgrades *silently*. `disk_body` can count rows it
downgraded without probing and emit one extra row —
`revalidation <checked> <skipped>` — which `disk_findings` picks up (its `case`
has no default arm, so unknown kinds are already ignored, and :302-304 already
pins "an unknown row kind is tolerated"). Append to the group detail:
`N of M confirmed rows were not revalidated within the ${DISK_PROBE_SECONDS}s
budget and are reported as likely.` It makes the truncation legible and gives
Step 2's filter a directly observable counter. Skip it if it costs more than
~30 lines.

**Risk if it regresses:** none to the product; losing this test means the next
regression of Steps 2-4 is again invisible to the suite.

---

## Step 6 — correct the status doc  *(`team-executor`)*

**File:** `docs/prompts/advise-v1-status.md` — which lives on `main` (and in the
itest checkout), **not** in the U4 worktree. Land it as a separate doc-only
commit on `main` so it cannot conflict with this unit's merge.

Replace item 1 under "What running the integrated build exposed" (:84-87). It
currently reads *"Needs a product decision on the confidence gate, not a code
fix."* It is a code fix, in three places, and the cache proves the scan was
already right: 24 confirmed rows were classified and then destroyed at print
time. Point at this plan by name. Leave the "Decisions made during the run"
section untouched.

**Risk if it regresses:** the next session re-diagnoses this from scratch and
reaches the same wrong conclusion.

---

## Step 7 — review  *(`team-reviewer`)*

Read the whole diff against the standing constraint: every ambiguous case
downgrades. Specifically confirm (a) `disk_probe_idle` has no path that returns
0 without the completion sentinel; (b) `disk_group_published` is the only place
the 2% test is written; (c) `SECONDS=0` is confined to the process-substitution
subshell; (d) no §3c marker or idle requirement was relaxed anywhere; (e) no new
`printf | grep -q` under `set -o pipefail`, and no `IFS=$'\t' read` consumer
that can now receive an empty interior field (the rank column added in Step 4 is
always numeric, the age column is always `-` or a number).

---

## How to verify end-to-end on this machine

The U4 worktree has no `advise` subcommand (`tools/` there is `advise-disk.sh`,
`orphan-policy.sh`, `sample.sh`, the plist — no `advise.sh`, no `disk-scan.sh`).
So:

1. In the worktree: `bash tests/smoke.sh`. Fixtures are auto-discovered
   (`tests/smoke.sh:167`), so `fixture-disk.sh` runs. Expect 0 failed and an
   assertion count above the current 151.
2. Copy the fixed file into the integration checkout for the live run:
   `cp <worktree>/tools/advise-disk.sh /Users/turbokach/Dev/claude-watch-itest/tools/`.
   That copy is scratch verification, not a deliverable.
3. Ground truth from the cache:
   `awk -F'\t' '$1=="dir" && $5=="confirmed"' ~/.claude-watch/state/disk.tsv | wc -l`
   → **24**; restricted to the published group,
   `awk -F'\t' '$1=="dir" && $5=="confirmed" && $4=="rebuildable"'` → **17**.
4. `cd /Users/turbokach/Dev/claude-watch-itest && time ./claude-watch advise`.
   The real signal: the rebuildable line reads `17 confirmed, 3 likely,
   0 unverified` (up from `0 confirmed, 20 likely`) and the action carries three
   `rm -rf '...'` lines. Expect
   `~/Dev/hr-breaker/.venv` (1.5 GiB), `~/Dev/agents-frontend/.next` (1.1 GiB),
   `~/Dev/backend/.venv` (724 MiB), then `+ 17 more`. Note `advise` calls
   `cw_append_log`, so it is not a read-only command.
5. Cross-check every printed path against the cache — each must appear as a
   `dir ... confirmed` row for a published group, and none may come from
   `node_modules`, `caches`, `containers` or `transcripts` (all under 2% here).
6. Latency: `time` the run before and after. Expect roughly +1s warm; anything
   near 5s means the budget is being spent, which after Step 2 should only
   happen cold.
7. Negative control for the filter: copy the cache, edit `rebuildable`'s
   `size_kb` below 8,845,751, and run with
   `CLAUDE_WATCH_DISK_CACHE=<copy> ./claude-watch advise` → no rebuildable
   finding, no commands, and a run no slower than the pre-fix one.

**Set expectations honestly when reporting the result.** The three visible
commands free ~3.4 GiB, not 25 GiB. The bulk of the rebuildable group is
`buzz/target` (11.0 GiB) and `src-tauri/target` (6.5 GiB), both genuinely
`likely` — actively used. The fix makes the gate's real payload visible; it does
not, and must not, turn an active build tree into a printed deletion.

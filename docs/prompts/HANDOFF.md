# claude-watch — Session Handoff

Written at the end of the session that built the project, for whoever (or whichever session) picks it up next.

Repo: https://github.com/TurboKach/claude-watch — public, MIT, `main`.

> **Newer than this file:** [SESSION-HANDOFF.md](SESSION-HANDOFF.md) orients a fresh session on how
> the tool works and how to use it, and lists what is currently open. Start there if you want the
> shape of things; this file remains the reference for gotchas (§4) and the decisions log (§3).
>
> Since this was written, the tool gained the reaping commands (§11), a `--json` agent interface and
> two Claude Code skills (§12), a read-only smoke suite (§7a), and `advise` / `disk` — ranked
> findings over a multi-day window, which closes §7f and supersedes §7h's ranking. All merged to
> `main`. `advise`'s design rationale lives in `advise-plan.md`; its known defects are §7i and the
> one decision that overrode the plan is §7j.

---

## 0. TL;DR for the next session

Two macOS tools that measure what Claude Code sessions actually cost:

- **`claude-top`** — live, refreshing process tree. Each session's whole subtree rolled up into one number.
- **`claude-watch`** — a stateless launchd sampler every 10s + a daily digest printed on the first shell of a new day.

Everything described here is **built, installed, running and verified** on the author's machine. `claude-watch doctor` passes all eight checks. There are **no automated tests** — that is the single biggest gap (see §7).

Start by running `claude-watch doctor`, then `claude-watch`, then `claude-top -1`. If the sampler has stalled, that is the first thing to fix.

---

## 1. What this is and why

A Claude Code session spawns shells, MCP servers, dev servers, test runners and headless browsers **as its own children**. Activity Monitor shows them as unrelated `node` and `chrome-headless-shell` rows with no visible link to Claude. So a session pinning ten cores looks like nothing in particular is running — "my laptop is hot but nothing is using CPU".

Real observations from the session that motivated this:

- a session at **990% CPU** (a `shot3d.mjs` render driving headless Chrome), invisible as such in Activity Monitor
- a `node --test` orphan that had outlived its session by **four days** and was still growing its RSS
- and the punchline: the *sustained* burn was mostly **not Claude** — `airportd` 58m of CPU in 7.5h, NordVPN 31m, WiFiAgent 27m

That last point is why the tool reports machine-wide consumers alongside Claude ones. A Claude-only monitor would have said "your sessions are fine" and left the real question unanswered.

---

## 2. Architecture (user-approved — do not re-litigate without asking)

```
claude-top                  live tree; standalone, reads ps directly, no state
claude-watch                CLI: report | advise | disk | orphans | worktrees
                                 | status | hook | doctor
tools/sample.sh             ONE sampling pass; launchd runs it
tools/orphan-policy.sh      what counts as a leaked dev process; sourced by BOTH
                            sample.sh (records) and claude-watch (kills)
tools/advise.sh             window reader + shared scalars + ranking + renderers;
                            sourced lazily inside advise(), never at file scope
tools/advise-disk.sh        disk domain: reads the cache, applies thresholds
tools/advise-leaks.sh       leaks domain: calls scan_orphans / scan_worktrees
tools/disk-scan.sh          the ONLY thing that scans the filesystem
tools/com.turbokach.claudewatch.plist   StartInterval=10, RunAtLoad

~/.claude-watch/
  raw/YYYY-MM-DD.tsv        append-only facts (gzipped >2d, deleted >30d)
  state/cwd/<pid>           cached session cwd (lsof is the expensive part)
  state/label/<pid>         cached iTerm tab label
  state/last-shown          new-day marker for the hook
  state/disk.tsv            disk facts cache, TTL 6h (CLAUDE_WATCH_DISK_CACHE)
  state/disk-scan.lock/     mkdir-lock owned by disk-scan.sh alone
  state/advise.log          one line per advise run, for "unchanged since N days"
```

Each `tools/advise-<domain>.sh` splits into a **pure** `<domain>_findings()` and an
impure `advise_<domain>()`. That split is what makes "severity is a pure function of
(value, threshold)" true in code rather than aspirationally, and it is what lets the
fixtures run without the parent script.

`advise` is read-only **structurally**, not by convention: it has no side-effecting
path at all, and rejects `--kill`, `--remove`, `--yes` and `--refresh` with exit 2.
It never scans; the disk domain reads a cache that only `disk --refresh` writes.

Two invariants worth protecting:

1. **The sampler is stateless and short-lived.** launchd starts it, it exits. Nothing resident between samples. A tool whose job is detecting leaked background processes must not become one — `doctor` asserts no pileup.
2. **Aggregation happens at report time.** Samples are facts; digests are derived. Three separate reporting bugs were fixed during the build by reprocessing *existing* samples, with no re-collection. Keep it that way.

---

## 3. Decisions log (settled — don't redo the analysis)

| Decision | Why |
|---|---|
| Separate repo, not part of `claude-code-statusline` | A full-screen process monitor is not a status line. `claude-top` lived there briefly and was moved here. |
| launchd `StartInterval`, not a resident daemon | No process to leak; launchd handles restarts and reboots. |
| Daily digest only, no live alerting | Alert fatigue trains you to ignore it. Deferred, not rejected. |
| Claude trees **and** machine-wide | Measured data showed most sustained burn was not Claude. |
| Digest on first shell of a new day | Can't be missed; costs nothing when nothing is new. |
| Status-line integration **rejected** | See §5 — it is structurally blind to spikes. |
| Report peak *and* avg *and* total | Peak alone ranks a one-shot daemon above an all-day burner. |

---

## 4. Verified facts and hard-won gotchas

**Do not rediscover these the hard way.**

1. **`ps` right-pads the pid column.** Parsing by leading characters silently drops sessions whose pid is narrower than the widest pid on the machine. Split into fields with awk and take argv by index — never by character offset.

   **Corrected 2026-08-06:** this entry used to say "use `$6` (first token of argv)". The sampler's `ps` line gained a column in schema v2, so argv now begins at **`$7`**. The two offsets downstream of it moved with it. If you are copying this idiom into new code, read the live `ps -axo` list in `tools/sample.sh` and count — do not trust either number in this file.

2. **macOS `awk` is version 20200816 and byte-oriented.** `length("├─")` is **6**, not 2. Worse, the continuation-byte class `"[\200-\277]"` *errors out* in a UTF-8 locale. Any awk doing display-width work must run under `LC_ALL=C` and count cells manually (see `cells()`/`trunc()` in `claude-top`). Truncating a coloured string naively also cuts ANSI escapes in half.

3. **RSS cannot be summed across processes.** It counts shared pages once per mapping process. Summing eight Firefox content processes claimed **13.1G on a 24G machine**. Report the largest single process plus a count (`1.2G ×8`). `ps` cannot give a true private/shared split — that needs `footprint` or root. **CPU, by contrast, sums correctly.**

4. **`ps` parenthesises the accounting name** — `(bash)` — when a process's argv is unreadable, which is routine for short-lived processes caught mid-exec. Strip the parens.

5. **Claude Code holds no open file handle on its transcript**, so `lsof` cannot map pid → session id. The working route is: `lsof` cwd → project slug (`/` and other non-alphanumerics → `-`) → the one recently-modified `*.jsonl` in `~/.claude/projects/<slug>/`. **When two sessions share a cwd, emit no label rather than a wrong one.**

6. **`$PPID` of a status-line script *is* the session's `claude` process** — verified with a probe, not inferred. Useful if anyone revisits status-line integration, but see §5 first.

7. **`zsh -i -c` inherits the parent environment.** Testing "does .zshrc set X" that way reads the *parent's* value and gives a false result. Use `env -u VAR zsh -i -c ...`.

8. **A CPU floor alone misses memory hogs.** Firefox idling at 1.0G / 0.0% CPU never crossed a CPU-only floor. Hence `CLAUDE_WATCH_MEMFLOOR`.

9. **In the Claude Code harness, foreground `sleep` is blocked.** Use `run_in_background: true` or an `until` loop when testing timing behaviour.

10. **Orphans are trees, not processes.** The real pid-1304 orphan was a `node --test` runner *plus* a worker child holding 54 of its 59.5M. Killing the root alone reparents the child to launchd, where it returns as a brand-new orphan still holding the memory. Always walk the subtree **deepest-first**.

11. **Orphan TSV rows carry no pid** (`epoch, orphan, name, cores, rss, secs`), so a kill list can never come from stored samples. It must be a live `ps` scan anyway — a pid recorded minutes ago may have been recycled onto something unrelated. Re-verify argv *and* that elapsed time has not gone backwards immediately before signalling.

12. **`read -r ans` returns empty on EOF as well as on Enter.** With "Enter means yes to all", a closed stdin silently reaps everything — this was a real bug, caught only because a pty test hung up early and killed a tree it had been told to skip. Test `if ! read -r ans`, never just the value. Note that `[ -t 0 ]` does *not* save you here: under a pty stdin is a terminal and can still hit EOF.

13. **An agent worktree in active use is indistinguishable from an abandoned one by age alone.** `wizards/.claude/worktrees/agent-a309e0b6…` looked exactly like the 5-month-old Conductor leftovers; it had a commit 10 minutes old and git's `locked` flag. Liveness (lock flag, commit < 24h, a live session cwd inside it) is checked *before* staleness, and always wins.

14. **Malformed skill frontmatter fails silently and badly.** Claude Code loads the body with *empty metadata*, so `/skill-name` still works but Claude has no `description` to match on — auto-invocation dies with no error anywhere. This bit us: `when_to_use: "a", "b", "c"` is not valid YAML. Use a `>-` block scalar for anything containing quotes or apostrophes, and validate with a real YAML parser, not by eye.

15. **zsh does not word-split unquoted variables; bash does.** A test sweep written as
    `for c in "report today"; do claude-watch $c; done` passes ONE argument under zsh and two under
    bash, so the tool rejects `"report today"` with exit 2 and the sweep reports a regression that
    does not exist. This produced a false failure report on a working build. Write test loops as a
    file with a `#!/usr/bin/env bash` shebang (`tests/smoke.sh`) rather than inline in the session
    shell, or pass arguments explicitly instead of through a string.

16. **`lastep` must come from `sys` rows, not `orphan` rows.** Measuring "still alive" against the
    newest *orphan* row makes the test vacuous: once an orphan is reaped no further orphan rows are
    written, so the newest orphan row is always the one recording it, and every dead orphan reports
    itself still alive. `gone by end of day` could essentially never fire. Fixed by taking the last
    sample epoch (`eps[sysn]`), since sys rows are written every sample.

17. **"Has an upstream" is not "has been published".** Conductor and `git worktree add -b` create
    branches with no tracking configuration at all, so `git rev-parse @{u}` fails for essentially
    every agent worktree. Treating that as "nothing published" reported the branch's ENTIRE history
    as unpushed and pinned the worktree UNSAFE for ever — work merged and pushed weeks earlier read
    as never published. Ask the commits instead: `git rev-list --count HEAD --not --remotes`. It
    needs no upstream and still counts genuinely unpushed work. It reads local refs only (no fetch),
    so a commit pushed from another machine keeps counting until this clone learns of it — which
    errs toward UNSAFE, the safe direction. **`scan_worktrees()` and `still_removable()` must use the
    byte-identical test**; when they drifted, every freshly-STALE worktree was refused at removal
    time with "changed since it was listed". Covered by `tests/fixture-worktree-unpushed.sh`.

18. **`df -k /` measures the wrong volume.** On APFS `/` is the sealed system volume — it reported **46% used** on this machine while `df -k "$HOME"` reported `/System/Volumes/Data` at **96%**. Same free space, wildly different `used`, and no symptom: an implementer who reaches for `/` gets a reassuring, wrong answer that looks entirely plausible. Always `df -k "$HOME"`.

    The denominator is `volume_total_kb = used_kb + avail_kb`, and every percentage in the disk domain divides by that and nothing else. `df`'s **Size** column is the APFS *container*, which includes space this volume cannot claim — dividing by it turns 95.3% used into a comforting 87.3% on a volume with 19.8GiB left. `df`'s **Capacity** column (96%) is computed with reserved space and is not re-derivable from anything published, so it is recorded and quoted as *df says*, never computed against.

19. **Sampler schema v2, and two data eras in one window.** The sampler records more per sample than it did (memory size, swap cap, and the fields the deferred CPU/memory analyzer needs), so raw TSV has **two eras** and a window that spans the change contains both. The era is decided **per `sys` row**, not per file — a truncated row (the sampler appends with `>>`; a panic mid-append is possible) must degrade that one row and must never silently read as estimate-era. Nothing that reads raw TSV may assume a fixed column count for the file.

20. **`pgrep -f codex` is useless on macOS.** The path `/var/run/com.apple.security.cryptexd/codex.system/...` appears in the inherited environment of nearly every process, so the string "codex" in argv matches almost everything. Any future Codex detection needs a different key.

---

## 5. Why the status line was tried and rejected

A session-cost readout was fully built into `claude-code-statusline`, verified working (`⚡0.2× 1.2G` dim, escalating to `⚠3.1×` orange under load), and then **removed**.

Measured render cadence over 169s of real use:

| metric | value |
|---|---|
| median gap | 4.79s |
| mean | 15.36s |
| **max gap** | **117.8s** |
| gaps >5s | 4 |

Renders are event-driven, not periodic. A 117-second blind window means any spike inside it leaves no trace — and renders stop entirely when a session goes idle *with something still running*, which is exactly the orphan case. The status line is structurally the wrong place for this.

**If someone proposes putting it back: this is the data that says no.**

---

## 6. Measured costs (re-measure if you change sampling)

| Thing | Cost |
|---|---|
| One sample (`tools/sample.sh`) | ~0.1s, almost all `ps` on ~700 processes |
| Sampler at 10s interval | ~1% of one core |
| Raw storage | ~7MB/day, 13.6 rows/sample; ~60MB steady state after gzip |
| Shell hook, no-op path | ~1.3ms (inline builtin date test) |
| Shell hook via `claude-watch hook` | ~10ms — **why the guard is inline in `.zshrc`, not inside the script** |
| `claude-top` frame | ~120ms |

---

## 7. What's NEXT — ranked

### 7a. Automated tests — report aggregation now covered
`tests/smoke.sh` covers syntax, exit codes, `--json` validity, argument rejection, the no-tty
refusal on both destructive paths, skill frontmatter, and one sampler pass. It is read-only and
destroys nothing outside a fixture's own `mktemp` sandbox. It also runs every `tests/fixture-*.sh`
by glob, so a new fixture file needs no wiring.

**`tests/fixture-report.sh` closes the aggregation gap.** Hand-written TSV day-files through a temp
`CLAUDE_WATCH_HOME`, asserting exact `report --json` values (each validated through
`python3 -m json.tool` first): peak/avg/total/`seen_pct`/`observed_seconds` on 100 known samples;
the same-name fold, which must happen before aggregating or `seen_pct` reads 300%; RSS reported as
the largest single process with an instance count, never summed (§4.3, §9); the derived sampling
interval (median delta, gaps >600s dropped) and a sleep gap excluded from `observed_seconds`; the
`lastep` / `still_alive` logic from §4.16; and three degenerate inputs (empty file, no `sys` row,
a single sample) that must not divide by zero, emit `nan`, or produce invalid JSON. Because these
are also the regression harness for any future rewrite of the aggregation, they pin values rather
than exit codes.

Verified to fail, not merely pass — six bugs reintroduced one at a time, each caught by exactly the
assertion written for it: unfolded same-name counting (`seen_pct` 300), summed RSS (6G not 3G),
`lastep` from orphan rows (a dead orphan reports itself alive), an assumed 10s interval,
wall-clock `observed_seconds`, and dropping the `sysn == 0` guard (division by zero).

`tests/fixture-worktree-unpushed.sh` covers worktree classification the same way; see §4.17.

Still uncovered: `tools/sample.sh` (needs a real `ps`, though its awk could take a fixture snapshot
on stdin) and the orphan subtree kill / pid re-verification, which remain manual-evidence-only.

### 7b. Unit inconsistency between the two tools
`claude-top` shows `253%` (top(1) convention); `claude-watch` shows `2.5×` (cores). Same quantity, two notations, one repo. Pick one — cores is friendlier, percent matches `top`. Requires touching `claude-top`'s columns and README.

### 7c. GPU / Neural Engine power
The known blind spot. A process heating the machine mostly via GPU under-reports badly, and the original complaint was heat. Real per-process watts need `sudo powermetrics`, which means a privileged helper or a documented sudoers entry. Decide whether that complexity is worth it before building.

### 7d. Retention only runs from the hook
`retention()` is called at the end of a successful new-day `hook`. If you never open a shell on a given day, raw files are never gzipped or pruned. Consider running it from the sampler occasionally (e.g. when the date changes) or a second launchd job.

### 7e. Sleep/wake gaps
Coverage is `samples × interval`, and the interval is derived from the data (median delta, ignoring gaps >600s). A closed laptop produces a long gap that is excluded — verify the "observed" figure reads sensibly across an overnight sleep.

### 7f. Weekly/monthly rollups — DONE
Closed by `advise`'s window selector: `--window 24h | week | month | Nh | Nd | Nw`, clamped to
`CLAUDE_WATCH_KEEP_DAYS` and honest about how much data actually exists inside the requested span
(`requested_days` / `available_days` / `covered_days` / `missing_or_failed_days`). The window is
read **once** per run and its metadata comes out of the same pass, so a second consumer (the v2
CPU/memory analyzer) folds in rather than re-reading — a month window costs ~4.4s of read before
`gzcat`, which does not survive being done twice.

`claude-watch report` still handles one day only, deliberately. It is a digest of a day; the
multi-day view is a different question and got a different command.

### 7g. Orphan actions — DONE
Shipped as `claude-watch orphans [--kill]` and `claude-watch worktrees [--remove]`. See §11.

### 7h. Disk: agent transcripts are the biggest reclaimable thing on the machine
Measured 2026-08-06: `~/.claude` **5.9G** (of which `~/.claude/projects` transcripts **3.7G**) and `~/.codex/sessions` **783M** across 3254 files. That dwarfs anything the process or worktree reaping recovers (~170M combined). Deliberately left out of the reaping commands because deleting transcripts is irreversible and needs its own rules about what Claude Code still needs in order to resume a session. Worth its own plan.

> **Correction, measured 2026-08-06 (later the same day, during the `advise` plan).** The heading
> above is wrong and is left standing so the mistake is legible: **transcripts are fourth, not
> first.** The real ranking of reclaimable space on this machine:
>
> | thing | size |
> |---|---|
> | rebuildable build artifacts under `~/Dev` (57 dirs) | **~25.5 GiB** — `buzz/target` 11.0G, `src-tauri/target` 6.5G, plus the `.venv`s and `.next`s |
> | `node_modules` under `~/Dev` | **~4.8 GiB** |
> | `~/.claude` | 6.0G |
> | `~/.codex/sessions` | 783M |
>
> The volume (`/System/Volumes/Data`) is at **4.7% available — 19.8 GiB of 422 GiB**. The original
> claim came from measuring `~/.claude` and `~/.codex` and nothing else: the biggest thing on the
> disk was never counted, so the thing that *was* counted won. Rebuildable artifacts are also the
> *safer* target — they come back from a build, whereas a deleted transcript is gone — which is why
> v1 prints removal commands for confirmed build output and reports transcripts with a size and no
> command at all.

### 7i. Known defects, deliberately not fixed

Recorded here rather than fixed, each with the reason.

**`report --json`'s `minfree` can never record a genuine zero.** In `report()`'s `END` block
(`claude-watch:263` before the aggregation rewrite, ~`:312` after — grep the idiom, not the line):
`if (minfree == 0 || $6 + 0 < minfree)`. The sentinel for "unset" is the same value as a legitimate
measurement, so a sample reporting free = 0 is overwritten by whatever comes next, and `min_free_kb`
ends up as the *last* sample's value rather than the minimum. Pre-existing, and the case is rare
enough (free memory reported as exactly 0 KB) that changing the aggregation was not worth the
`report --json` golden-diff risk in this release. **The v2 memory analyzer must not copy the idiom**
— use a separate `seen` flag, not a magic zero.

**`tools/sample.sh` has no single-writer lock.** It assigns `now` early and appends only at the end,
so two concurrent samplers can interleave and inflate the sample count. `report()` now *detects*
every resulting drift and says so on stderr, but it cannot prevent it. The open question, stated
plainly because it is a real trade and not an oversight: **lock and drop a sample, or keep reporting
drift.** A lock silently loses a sample where the drift is at least announced today, and it adds
persistent state to a sampler whose entire design premise is that nothing stays resident between
samples (§2, invariant 1). **Decided for this release: keep reporting drift.** Revisit only with
evidence that the drift is frequent enough to distort a report.

**`doctor`'s sampler-pileup check false-positives during multi-agent runs.** It counts
`pgrep -f 'tools/sample.sh'`, which matches *any* shell command line quoting that filename — a test
harness, a grep, another agent's editor invocation — not just real samplers. Same shape of defect as
§4.20's `pgrep -f codex`. It errs toward a false alarm on a healthy machine, which is the harmless
direction, so it stays until someone needs `doctor` to be quiet during fan-out.

**Deferred v2 scope: the CPU and memory analyzer.** Not built in v1, and the reason it is not built
is worth keeping: the sampler's CPU view is blind twice over (everything under `CLAUDE_WATCH_FLOOR`,
and everything past `CLAUDE_WATCH_TOPN` per sample), so shipping CPU advice before addressing that
means shipping a confident all-clear. v1 carries the caveat text instead, in `caveats[]`, in the
human footer, in SKILL.md and in README's Limitations. `docs/prompts/advise-plan.md` §10 holds the
full unit spec with every finding already verified against the code — per-pid differencing, the
`cpu_seconds <= interval × ncpu` sanity invariant, `cpu.unexplained_load` from the `sys` row's load
average, pageout *deltas* rather than since-boot counters, the unratified thresholds, and the
fixture list. Read it before rebuilding any of that from scratch. v1 makes it cheaper: the sampler
already records what v2 needs, the window pass already emits metadata rows for a second consumer to
fold into, and the contracts already carry `cpu_basis`, `CW_MEMSIZE_KB` and `CW_SWAP_CAP_MB`.

Also still open and not lost: §7b unit unification, §7c GPU/ANE, §7d retention outside the hook,
per-app breakdown of `~/Library/Containers` (TCC-hostile to walk), and transcript deletion commands.

### 7j. User decision that overrode the plan: partial scans cap per group, not globally

The plan had a partial disk scan cap **every** reclaim finding at `info`. Overridden: the cap
applies **only to groups whose own measurement was affected**.

Why: on any Mac without Full Disk Access, `~/Library/Caches` and `~/Library/Containers` deny
permission on every single scan. A global cap therefore mutes the 25.5 GiB rebuildable finding —
fully measured, entirely actionable — down to `info` **forever, on essentially every Mac**. The cap
was written to stop the tool making confident claims about numbers it did not measure; applied
globally it does the opposite, hiding a number it measured perfectly well behind a permission error
somewhere else.

Mechanically it is a **5th column on the cache's `group` row** (`affected ∈ 0|1`). The global
`scan partial=1` still drives the summary banner and the "this is a floor" language; the per-group
flag drives **severity capping only**. `disk.volume_low` is unaffected either way — it comes from
`df`, which always completes.

---

## 8. Commands cheat-sheet

```bash
claude-watch                    # today so far
claude-watch report yesterday   # what the hook prints
claude-watch report 2026-08-01  # any retained day
claude-watch advise             # what should I fix, ranked worst-first
claude-watch advise --window week --json        # or month / Nh / Nd / Nw
claude-watch advise --show-thresholds           # every knob and its source
claude-watch disk               # disk domain from cache; never scans
claude-watch disk --refresh     # the ONLY scan (~10s, hard 120s deadline)
claude-watch status             # sampling alive? how recent?
claude-watch doctor             # 8 checks, exit 0 when healthy
claude-watch orphans            # list leaked process trees; --kill to reap
claude-watch worktrees          # list stale agent worktrees; --remove to reap
claude-top                      # live tree; -1 one frame, -i N interval

launchctl unload ~/Library/LaunchAgents/com.turbokach.claudewatch.plist
launchctl load   ~/Library/LaunchAgents/com.turbokach.claudewatch.plist
tail -f ~/Library/Logs/claudewatch.err.log     # must stay empty
```

Raw data is plain TSV — `epoch, kind, key, cores, rss_kb, detail, …`, where `kind` is `sys` |
`session` | `proc` | `orphan`. Grep it directly when debugging a report, but **do not assume a fixed
column count**: schema v2 added fields, so a retained window contains rows from both eras and the
era is decided per `sys` row (§4.19).

The disk facts cache (`state/disk.tsv`) is a separate 5-column TSV, `kind` ∈ `epoch` | `scan` |
`note` | `vol` | `group` | `dir`. A cache with a `note` row and no `scan partial=1` is malformed.

Exit codes: `0` ran (findings may be `critical` — a full disk is not a tool failure, `doctor` is the
health gate); `1` data directory unreadable, or the cache could not be written; `2` usage error.

---

## 9. Gotchas / things not to break

- **Don't make the sampler resident.** It is the project's defining constraint.
- **Don't aggregate at sample time.** It forecloses re-deriving reports from existing data.
- **Don't let the `.zshrc` guard call into the script** on the common path — that is a 7× shell-startup regression.
- **Don't sum RSS** across same-named processes.
- **Don't parse `ps` by column offsets.**
- **Keep session labels absent rather than wrong** when a cwd is ambiguous.
- **Session labels are a soft dependency** on `claude-code-statusline`, which writes `~/.claude/session-labels/`. Without it, labels are omitted and everything else works. Don't turn this into a hard dependency.
- The repo's README sample output uses **neutral project names** on purpose. The original history contained real ones and was squashed to remove them — keep published samples anonymised. **This now extends to `advise`**, whose findings embed absolute paths from `~/Dev` and `~/Downloads` verbatim: any sample output in README, SKILL.md or a plan uses `/Users/you/…` and invented project names. Paste a real `advise --json` into a document and you have published the user's project list.
- **`advise` must never scan, and must never re-rank downstream.** Severity, `severity_rank` and `priority` are computed once and published; the skill relays them. A relay that re-derives severity is the failure the `primary` object exists to prevent.
- **No domain that was not measured may say `ok`.** `unknown` (1) outranks `ok` (0) in the published order for exactly this reason: a broken measurement must not read as health. `measurement_state: "unavailable"` ⟺ `severity: "unknown"` is fixture-asserted.
- **Both reaping commands list by default.** `--kill` / `--remove` are what make them destructive; keep the bare command a dry run.
- **Never widen `is_agent_worktree()`** to cover worktrees the user made by hand. Hand-made worktrees being *structurally* invisible — not merely deprioritised — is what makes the bulk "yes to all" safe.
- **Leftover agent branches are reported, never deleted.** A branch is cheap and may be the only copy of unmerged work.
- **Removal goes through `git worktree remove`, never `rm -rf`** — git re-checks for local modifications and refuses, which is a second guard independent of ours.

---

## 11. The reaping commands (added after the original handoff)

`claude-watch orphans [--kill] [--yes] [--min MINUTES]` and
`claude-watch worktrees [--remove] [--yes] [--days DAYS]`.

Both list by default; the bare command **is** the dry run. Confirmation is `[Y/n/s]` where Enter
means all and `s` steps per item (`y`/`N`/`a`/`q`) — the user chose "all is the default" explicitly.
Without a terminal, both refuse to destroy anything unless `--yes` is passed.

Safety properties, all load-bearing (see gotchas §4.10–§4.13):

- live `ps` scan, never stored samples; re-verify argv + elapsed immediately before signalling
- subtree kill, deepest-first, `TERM` → 3s → `KILL`
- worktree liveness (locked / commit < 24h / live session cwd inside) is checked **before** staleness
- ACTIVE and UNSAFE worktrees are never in the bulk set at all
- only agent-created paths are visible: `<repo>/.claude/worktrees/*`, `~/conductor/workspaces/*`

`tests/smoke.sh` covers the guards (no-tty refusal, argument rejection, `--json` validity) but the
behaviour that matters most here — the subtree walk, the pid-reuse re-verification, the worktree
classification — was verified by hand against synthetic orphan trees and a sandbox repo of
backdated worktrees, and has no automated coverage. See §7a.

---

## 12. Agent interface

`advise`, `disk`, `report`, `orphans`, `worktrees` and `status` take `--json`. `--json` prints and returns before any
confirmation or kill path is reachable, so it is read-only by construction, not by convention.
Report rankings are sorted **once**, above the human/JSON branch, so the two modes cannot disagree
about order. Everything user-derived (cwds, session labels, argv, paths) goes through `jesc()`.

Two skills in `skills/`, symlinked into `~/.claude/skills/` by `install.sh` (symlinked, not copied,
so the skill tracks the flags it documents; Claude Code follows symlinked skill dirs and hot-reloads):

- **`claude-watch`** — read-only, model-invocable. Claude picks it up from "why is my laptop hot".
- **`claude-watch-reap`** — `disable-model-invocation: true`, so only the user can start a reap.
  Its description is deliberately *not* in context; that is the documented behaviour of the flag.

Why a skill and not an MCP server: MCP servers are resident processes that appear in this tool's own
reports at 50–100M each. A monitor whose defining constraint is leaving nothing running should not
ship a daemon to describe itself.

Two facts worth keeping: a Claude Bash call has **no tty** (verified), so `--kill`/`--remove` refuse
unless `--yes` is explicit — the agent cannot destroy anything by accident. And `--yes` takes
*everything* removable; per-item selection needs a real terminal, because `s` mode needs to prompt.

---

## 10. Environment this was built and verified on

MacBook Pro `Mac16,7`, 14 cores, 24GB, Darwin 25.3.0 · `awk` 20200816 · `bash` 5.3 (Homebrew) · `zsh` 5.9 with Powerlevel10k · iTerm2.

Note: p10k prints a `gitstatus failed to initialize` error under non-interactive `zsh -i -c`. It is pre-existing and unrelated to this project — confirmed by reproducing it with an untouched `.zshrc`.

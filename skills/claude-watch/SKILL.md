---
name: claude-watch
description: Diagnoses what is actually consuming CPU, memory and disk on this macOS machine — per-Claude-Code-session process trees, leaked orphan processes, and stale agent git worktrees. Use when the user asks why their laptop is hot, loud, slow, or out of memory; what a Claude session cost; what is still running from a session that already finished; or which worktrees and background processes are left over. Runs the read-only claude-watch CLI.
when_to_use: >-
  Triggers include "why is my laptop hot", "what's using my CPU", "my fans are
  loud", "what did that session cost", "is anything still running", "leftover
  worktrees", "what's eating my memory", "why is my disk full". Also after a
  long agent run, and before blaming a Claude session for machine load.
allowed-tools: Bash(claude-watch advise*) Bash(claude-watch disk*) Bash(claude-watch report*) Bash(claude-watch orphans --json*) Bash(claude-watch worktrees --json*) Bash(claude-watch status*) Bash(claude-watch doctor*)
---

# claude-watch — read-only diagnosis

`claude-watch` is on PATH after `install.sh`. If the command is missing, say so — do not substitute hand-rolled `ps` parsing, which is what this tool exists to replace.

Prefer `--json` on every command. The human format is free to change; the JSON is the contract.

| Command | Answers |
|---|---|
| `claude-watch advise --json` | **what should I fix** — ranked findings across disk and leaks |
| `claude-watch disk --json` | the disk domain alone, from the cached scan |
| `claude-watch report today --json` | what used the machine today |
| `claude-watch report yesterday --json` | any `YYYY-MM-DD` within the 30-day retention |
| `claude-watch orphans --json` | process trees that outlived their session |
| `claude-watch worktrees --json` | stale agent-created git worktrees |
| `claude-watch status --json` | is sampling alive and how recent |
| `claude-watch doctor` | install health; exits non-zero when broken |

## `advise` — the entry point for "what should I fix"

Start here for any "what's wrong / what should I clean up / why is my disk full" question. `report` answers *what used the machine*; `advise` answers *what to do about it*.

**Relay it. Never re-derive.** Severity, ranking and the ordering rule are computed inside the tool and published as data: `severity`, `severity_rank` (an integer, so you never map it yourself) and `priority`. Do not re-sort `domains[]`, do not upgrade or downgrade a severity, do not decide something is fine because the number looks small to you.

Five rules, each of which is the difference between a diagnosis and a false reassurance:

1. **Read `primary` first and report it first.** It is the authoritative state and it has already applied the ordering rule across every domain. `primary.headline` carries the actionable fact; lead with it.
2. **A domain with `measurement_state: "unavailable"` is never clean.** Its `severity` is `unknown`, which outranks `ok` on purpose. Say it was not measured and read out its `remedy` verbatim — the sentence is written in the tool so you don't have to compose a scarier one.
3. **`advise` never scans.** A disk domain carrying `cache_missing` means you *tell the user* to run `claude-watch disk --refresh` (~10s, cached 6h). Do not run it for them, and do not treat the absent scan as an absence of problems.
4. **Carry the CPU/memory caveat whenever the question is about heat.** This version says nothing about CPU or memory: they are in `deferred_domains`, and even `report`'s CPU figures are partial by construction — processes under `CLAUDE_WATCH_FLOOR` (5% of one core) or outside the top `CLAUDE_WATCH_TOPN` (8) per sample are never recorded, so twenty processes at 4% (0.8 cores) produce zero rows. GPU and Neural Engine power are not measured at all. **A quiet CPU report does not mean a cool machine** — say so rather than reporting "nothing is using your CPU".
5. **Unknown schema, no interpretation.** If `schema_version` is absent, or higher than the version you know (`1`), report the raw fields and stop interpreting. Treat any unrecognised enum value — in `severity`, `measurement_state`, `measurement_reasons`, `confidence` — as **unavailable, never as healthy**.

`disk --json` returns the same disk domain object `advise` puts in `domains[]` (minus `priority`), so everything above applies to it unchanged.

Findings carry `share_of_domain`, which is named for exactly what it is: it orders findings **within one domain and nowhere else**. Never compare it across domains. Every finding also carries the `threshold` that fired and its `threshold_name` — the `CLAUDE_WATCH_*` knob — so the user can see which number to argue with. `action` is a string to *show*, not to run; it is absent when the tool judged the path unsafe to author a command for (`confidence` below `confirmed`).

## Reading the numbers

- **CPU is cores, not percent.** `peak_cores: 11.3` means 11.3 cores.
- **Rank machine-wide burn by `cpu_seconds`, not `peak_cores`.** A daemon that spiked once for ten seconds beats an all-day burner on peak alone.
- **`machine_cpu` and `machine_mem` are processes outside every Claude tree.** Check them before blaming a session — on this machine the top sustained burner has usually been `airportd`, not Claude.
- **`rss_kb` in `machine_mem` is the largest single process**, with `instances` alongside. Never add RSS across processes: shared pages are counted once per mapping process, which is how eight Firefox processes "use" more memory than the machine has.
- `seen_pct` is the share of samples the process appeared in.
- Sampling is every 10s; shorter spikes are under-sampled. `observed_seconds` excludes sleep/wake gaps, so it can be less than wall-clock.
- In `status --json` the data-directory size is **`data_size`**. It was called `disk` until 2026-08-06; `disk` now means the volume, everywhere.

## Orphans

An orphan is a **tree**, not a process. Each entry has `procs[]`, and `rss_kb` is the subtree total. Report the root's `name` and the whole tree's size — a `node --test` root holding 6M often has a worker child holding another 54M.

## Worktrees

Only `<repo>/.claude/worktrees/*` and `~/conductor/workspaces/*` are considered; worktrees the user made by hand are deliberately invisible.

`removable` is true only for `STALE` and `PRUNABLE`. The other statuses mean:

- `ACTIVE` — locked, committed to within 24h, or a live session's cwd is inside it. **In use. Never suggest removing these.**
- `UNSAFE` — has uncommitted or unpushed work. Worth telling the user about, but it is not junk.

`unpushed` counts commits reachable from `HEAD` but from no remote-tracking ref — `unpushed_basis: "local-remote-refs"` says so on the record. It does not require a tracking branch (agent tools rarely configure one), and it does **not** fetch: a commit pushed from another machine still counts as unpushed until this clone learns of it. That direction is deliberate — it errs toward calling a worktree unsafe.

## Never destroy anything from this skill

Do **not** pass `--kill`, `--remove`, or `--yes`. Report findings and tell the user to run `/claude-watch-reap`.

These commands refuse to act without a terminal, so a stray `--kill` errors rather than destroys — but that is a backstop, not a licence to try it.

`advise` has no side-effecting path at all: `--kill`, `--remove`, `--yes` and `--refresh` are all rejected with exit 2. `claude-watch disk --refresh` is the one command here that does work (a filesystem scan) — it destroys nothing, but it is the user's call to make, not yours.

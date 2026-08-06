# claude-watch — Session Handoff

Written at the end of the session that built the project, for whoever (or whichever session) picks it up next.

Repo: https://github.com/TurboKach/claude-watch — public, MIT, one commit, `main`.

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
claude-watch                CLI: report | orphans | worktrees | status | hook | doctor
tools/sample.sh             ONE sampling pass; launchd runs it
tools/orphan-policy.sh      what counts as a leaked dev process; sourced by BOTH
                            sample.sh (records) and claude-watch (kills)
tools/com.turbokach.claudewatch.plist   StartInterval=10, RunAtLoad

~/.claude-watch/
  raw/YYYY-MM-DD.tsv        append-only facts (gzipped >2d, deleted >30d)
  state/cwd/<pid>           cached session cwd (lsof is the expensive part)
  state/label/<pid>         cached iTerm tab label
  state/last-shown          new-day marker for the hook
```

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

1. **`ps` right-pads the pid column.** Parsing by leading characters silently drops sessions whose pid is narrower than the widest pid on the machine. Use `$6` (first token of argv) via awk field splitting. This was a real bug that only showed up because two sessions happened to have 5-digit pids.

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

15. **`pgrep -f codex` is useless on macOS.** The path `/var/run/com.apple.security.cryptexd/codex.system/...` appears in the inherited environment of nearly every process, so the string "codex" in argv matches almost everything. Any future Codex detection needs a different key.

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

### 7a. Automated tests — the biggest gap
There are none. Everything was verified by hand. The highest-value target is the **report aggregation**: feed a fixture `.tsv` with known values and assert the digest's peak/avg/total/seen figures. That is pure input→output, needs no live processes, and is exactly where three bugs were found by eye. `tools/sample.sh` is harder (needs a real `ps`) but its awk could take a fixture snapshot on stdin.

### 7b. Unit inconsistency between the two tools
`claude-top` shows `253%` (top(1) convention); `claude-watch` shows `2.5×` (cores). Same quantity, two notations, one repo. Pick one — cores is friendlier, percent matches `top`. Requires touching `claude-top`'s columns and README.

### 7c. GPU / Neural Engine power
The known blind spot. A process heating the machine mostly via GPU under-reports badly, and the original complaint was heat. Real per-process watts need `sudo powermetrics`, which means a privileged helper or a documented sudoers entry. Decide whether that complexity is worth it before building.

### 7d. Retention only runs from the hook
`retention()` is called at the end of a successful new-day `hook`. If you never open a shell on a given day, raw files are never gzipped or pruned. Consider running it from the sampler occasionally (e.g. when the date changes) or a second launchd job.

### 7e. Sleep/wake gaps
Coverage is `samples × interval`, and the interval is derived from the data (median delta, ignoring gaps >600s). A closed laptop produces a long gap that is excluded — verify the "observed" figure reads sensibly across an overnight sleep.

### 7f. Weekly/monthly rollups
`claude-watch report` handles one day. A `--week` view over the retained window is a natural extension, and all the data is already there.

### 7g. Orphan actions — DONE
Shipped as `claude-watch orphans [--kill]` and `claude-watch worktrees [--remove]`. See §11.

### 7h. Disk: agent transcripts are the biggest reclaimable thing on the machine
Measured 2026-08-06: `~/.claude` **5.9G** (of which `~/.claude/projects` transcripts **3.7G**) and `~/.codex/sessions` **783M** across 3254 files. That dwarfs anything the process or worktree reaping recovers (~170M combined). Deliberately left out of the reaping commands because deleting transcripts is irreversible and needs its own rules about what Claude Code still needs in order to resume a session. Worth its own plan.

---

## 8. Commands cheat-sheet

```bash
claude-watch                    # today so far
claude-watch report yesterday   # what the hook prints
claude-watch report 2026-08-01  # any retained day
claude-watch status             # sampling alive? how recent?
claude-watch doctor             # 8 checks, exit 0 when healthy
claude-watch orphans            # list leaked process trees; --kill to reap
claude-watch worktrees          # list stale agent worktrees; --remove to reap
claude-top                      # live tree; -1 one frame, -i N interval

launchctl unload ~/Library/LaunchAgents/com.turbokach.claudewatch.plist
launchctl load   ~/Library/LaunchAgents/com.turbokach.claudewatch.plist
tail -f ~/Library/Logs/claudewatch.err.log     # must stay empty
```

Raw data is plain TSV — `epoch, kind, key, cores, rss_kb, detail`, where `kind` is `sys` | `session` | `proc` | `orphan`. Grep it directly when debugging a report.

---

## 9. Gotchas / things not to break

- **Don't make the sampler resident.** It is the project's defining constraint.
- **Don't aggregate at sample time.** It forecloses re-deriving reports from existing data.
- **Don't let the `.zshrc` guard call into the script** on the common path — that is a 7× shell-startup regression.
- **Don't sum RSS** across same-named processes.
- **Don't parse `ps` by column offsets.**
- **Keep session labels absent rather than wrong** when a cwd is ambiguous.
- **Session labels are a soft dependency** on `claude-code-statusline`, which writes `~/.claude/session-labels/`. Without it, labels are omitted and everything else works. Don't turn this into a hard dependency.
- The repo's README sample output uses **neutral project names** on purpose. The original history contained real ones and was squashed to remove them — keep published samples anonymised.
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

**Still no automated tests** (§7a). Everything above was verified by hand against synthetic orphan
trees and a sandbox repo of backdated worktrees. Given these paths are irreversible, they are now
the strongest argument for §7a — the report aggregation is no longer the highest-value test target.

---

## 12. Agent interface

`report`, `orphans`, `worktrees` and `status` take `--json`. `--json` prints and returns before any
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

# claude-watch

Resource monitoring for [Claude Code](https://www.claude.com/product/claude-code) sessions on macOS. Two tools for the same problem, split across time:

- **`claude-top`** — the live process tree, right now
- **`claude-watch`** — an always-on sampler and a digest of what actually used the machine, the next morning

## Why

A Claude Code session spawns shells, MCP servers, dev servers, test runners and headless browsers as its own children. Activity Monitor lists those as unrelated `node` and `chrome-headless-shell` rows with no visible link to Claude, so a session pinning ten cores looks like nothing in particular is running — the classic "my laptop is hot but nothing is using CPU".

Both tools roll a session's entire subtree into one number. CPU is in **cores**: `10.5×` means ten and a half of them, not a percentage.

## `claude-top` — live

```
claude-top  14 cores · load 3.03            22:27:36
  mem 17.2G/24G used · 1.2G free  swap 601M

 ⏺ claude 45224  ~/Dev/my-app  ●refactor auth: working   253.4%   1.2G
   ├─ mcp context7-mcp 45246                              0.0%    49M
   ├─ mcp figma-console-mcp 45245                         0.0%    49M
   └─ zsh 28861                                           0.0%     3M
      └─ node 28865 browse.mjs                            3.3%   264M
         └─ chrome-headless-shell 28867 █████████       243.0%   380M

 ⏺ claude 26845  ~/Dev/site  ●Add CSV export              4.3%   976M
   ├─ mcp context7-mcp 26861                              0.0%    76M
   └─ caffeinate 32705                                    0.0%     3M
  ──────────────────────────────────────────────────────────────────
  all sessions                                          257.7%   2.2G

 hot elsewhere
  WindowServer 404                                       31.1%   161M
  Telegram 29089                                         39.8%   1.4G

 ⚠ orphaned dev processes (no parent, older than 60 min)
  node arena-theme.test.ts --test 1304 · 4d06h            0.0%    27M
```

```bash
claude-top            # live, refreshing every 2s
claude-top -i 5       # slower refresh
claude-top -1         # one frame and exit (pipe-friendly)
claude-top -o 15      # flag unparented dev processes older than 15 min
```

Here CPU is percent of one core, as in `top(1)` — `253%` is two and a half cores, and the bar is one cell per quarter-core. **`hot elsewhere`** lists the top non-Claude consumers, because often the answer is that Claude was never the problem.

## `claude-watch` — retrospective

Live tools only help if you happen to be looking. The sampler runs on its own clock and reports at day boundaries, so spikes that happened while you were away still get recorded.

```
claude-watch  2026-08-06   14 cores · 8412 samples · 23h21m observed

CLAUDE SESSIONS
  ~/Dev/my-app                 peak  10.5×  avg  1.2×  active 4h12m  2.0G
      ●refactor auth: working
      └ hottest child: chrome-headless-shell 10.5×
  ~/Dev/site                   peak   2.0×  avg  0.1×  active 6h03m  1.4G

MACHINE-WIDE (outside every Claude tree)
  by CPU time burned
    airportd                        58m total  peak  0.8×  avg  0.2×  seen 54%
    NordVPN                         31m total  peak  1.1×  avg  0.1×  seen 74%
    WiFiAgent                       27m total  peak  0.5×  avg  0.2×  seen 32%
    plugin-container                11m total  peak  0.8×  avg  0.0×  seen 100%
  by memory held (largest single process; RSS double-counts shared pages)
    plugin-container             1.2G ×8  seen 100%
    firefox                          890M  seen 100%
    Telegram                         538M  seen 22%

SYSTEM
  peak load 16.45/14 · peak mem used 18.6G · min free 68M · max swap 601M

⚠ ORPHANED DEV PROCESSES (no parent — still holding memory and ports)
  node --test                  4d15h     60M  still alive
```

```bash
claude-watch                    # today so far
claude-watch report yesterday   # yesterday's digest
claude-watch report 2026-08-01  # any retained day
claude-watch status             # is sampling alive, how recent, how much data
claude-watch doctor             # check the install end to end
```

The digest prints automatically on your first shell of a new day.

## Reaping — `orphans` and `worktrees`

Reporting a leak and then leaving you to clean it up by hand is only half a tool. Two commands close the loop, for the two things agent sessions leave behind: **processes** that outlived their session, and **git worktrees** that outlived their task.

Both **list by default** — that is the dry run. Nothing is destroyed without an explicit flag *and* a confirmation.

```
$ claude-watch orphans
⚠ 1 orphaned dev tree (no parent, older than 60m — still holding memory and ports)

  [1] node --test              4d16h    59.5M  2 procs  0.0×
      1304   node --import tsx --test ../core/arena.test.ts ../core/avatar.te
        └1418   /opt/homebrew/Cellar/node/26.5.1/bin/node --test-concurrency=0

  total held: 59.5M

  run claude-watch orphans --kill to reap these
```

That indented child is the whole reason the command exists. **Orphans are trees, not processes.** Killing `1304` alone reparents `1418` to launchd, where it comes straight back as a brand-new orphan still holding 54M — so the kill walks the subtree deepest-first, and only then the root. `TERM`, wait up to 3s, `KILL` whatever is left.

The list is always a **live `ps` scan**, never the recorded samples: orphan rows carry no pid, and a pid recorded minutes ago may since have been recycled onto something unrelated. Immediately before signalling, every pid is re-checked — argv must still match and elapsed time must not have gone backwards — and any tree that fails is skipped rather than killed.

```
$ claude-watch worktrees
AGENT WORKTREES (.claude/worktrees and conductor workspaces; your own are not listed)

      ● ACTIVE   ~/Dev/wizards/.claude/worktrees/agent-a309e0b6e605cc457
        worktree-agent-a309e0b6e605cc457 · 325M · committed to in the last 24h
  [1] · STALE    ~/conductor/workspaces/language-learning/philadelphia
        TurboKach/add-email-auth · 109M · clean, 140d old
      ! UNSAFE   ~/dev/language-learning/.claude/worktrees/musing-moore
        claude/musing-moore · 1.9M · 1 uncommitted, 0 unpushed

  1 removable · 109M reclaimable
```

Only **numbered** entries are removable, and only those are covered by "yes to all":

- **ACTIVE** — locked by the tool using it, committed to within 24h, or a live session's working directory sits inside it. An agent worktree in active use looks *identical* on disk to an abandoned one; git's lock flag and a fresh commit are what tell them apart.
- **UNSAFE** — uncommitted or unpushed work. Shown so you know it is there, never in the bulk set; removing it needs a deliberate per-item `y`.
- **STALE** — clean, unlocked, older than `--days` (default 7).

Only paths an agent tool creates are considered at all — `<repo>/.claude/worktrees/*` and `~/conductor/workspaces/*`. Worktrees you made yourself, sitting beside their repo, are structurally invisible to this command, so it cannot propose deleting your real work. Removal goes through `git worktree remove`, never `rm -rf`, so git's own refusal-on-modification is a second independent guard. Leftover agent branches are **reported, never deleted** — a branch costs nothing and may be the only copy of that work.

```bash
claude-watch orphans                    # list only
claude-watch orphans --kill             # list, then confirm  [Y/n/s]
claude-watch orphans --kill --min 15    # lower the 60-minute age floor
claude-watch worktrees                  # list only
claude-watch worktrees --remove         # list, then confirm  [Y/n/s]
claude-watch worktrees --days 30        # only call them stale after 30 days
```

At the prompt, **Enter accepts all**, `n` aborts, and `s` steps through one at a time (`y`/`N`/`a`ll/`q`uit). `--yes` skips the prompt for scripting; without a terminal to confirm on, both commands refuse to destroy anything unless `--yes` is explicit.

## Agent interface

Claude Code can run this tool itself. `install.sh` symlinks two [Agent Skills](https://code.claude.com/docs/en/skills) into `~/.claude/skills/`:

| Skill | Who can invoke | What it does |
|---|---|---|
| `claude-watch` | you **and** Claude | Read-only diagnosis. Claude reaches for it on "why is my laptop hot", "what's still running", "which worktrees are left over". |
| `claude-watch-reap` | **you only** | The destructive half. `disable-model-invocation: true`, so Claude cannot start a reap on its own. |

The split follows the documented guidance for side-effecting workflows: *"You don't want Claude deciding to deploy because your code looks ready."* Killing processes is the same shape of decision.

They are symlinked rather than copied, so the skill stays in step with the flags it documents — pulling the repo updates the skill, and Claude Code picks up the change live without a restart.

### `--json`

`report`, `orphans`, `worktrees` and `status` all take `--json`, so an agent reads values instead of pattern-matching a layout that is free to change:

```bash
claude-watch report today --json
claude-watch orphans --json
claude-watch worktrees --json
claude-watch status --json
```

`--json` is read-only by construction: it prints and exits before any confirmation or kill path is reachable.

```json
{"command":"orphans","min_minutes":60,"trees":[
  {"root_pid":1304,"name":"node --test","age_seconds":405014,"rss_kb":60960,"cores":0.1,"proc_count":2,
   "procs":[{"pid":1304,"depth":0,"rss_kb":6912,"age_seconds":405014,"argv":"node --import tsx --test …"},
            {"pid":1418,"depth":1,"rss_kb":54048,"age_seconds":405014,"argv":"…--test-concurrency=0 …"}]}],
 "tree_count":1,"total_rss_kb":60960}
```

Worktree records carry an explicit `removable` boolean alongside `status` and `reason`, so an agent never has to infer eligibility from the status string.

### Why a skill and not an MCP server

An MCP server is a resident process. This tool's defining constraint is that it never leaves one running — and MCP servers show up *in its own reports*, at 50–100M each. A skill costs nothing at rest: only the name and description sit in context, and the body loads when it's used.

## Install

```bash
git clone https://github.com/TurboKach/claude-watch.git
cd claude-watch
./install.sh
```

Symlinks both commands into `~/.local/bin`, symlinks the two agent skills into `~/.claude/skills/`, installs and loads the launchd sampler, and prints one line to add to `.zshrc` — it never edits your shell config for you. Verify with `claude-watch doctor`.

## How the sampler works

**A stateless sampler on a launchd `StartInterval`, not a resident daemon.** Every 10 seconds launchd runs `tools/sample.sh`, which takes one `ps` snapshot, writes append-only TSV facts, and exits. Nothing stays running between samples — a monitor whose job is detecting leaked background processes should not be one itself. `claude-watch doctor` asserts this.

Each sample records:

- **Claude sessions** — the whole subtree rolled up (CPU + RSS), plus the hottest descendant, so you can see *what* the session was running.
- **Machine-wide** — top consumers outside every Claude tree, above a CPU floor **or** a memory floor. Both matter: Firefox idling at 1.0G and 0.0% CPU is invisible to a CPU-only floor, and is exactly the kind of steady burn worth seeing. Reported as two rankings — **CPU time burned** and **memory held** — because sorting one combined list by peak lets a daemon that spiked once outrank something burning quietly all day.
- **System** — load, memory used/free (mirroring Activity Monitor's app + wired + compressed), swap.
- **Orphans** — dev tooling reparented to `launchd`, meaning whatever started it is gone but it still holds memory, ports and file handles.

**All aggregation happens at report time.** Samples are facts; digests are derived. Report logic can change without re-collecting data, and the sampling interval is measured from the data rather than assumed, so coverage stays honest if launchd was paused.

CPU sums across same-named processes; RSS does not. RSS counts shared pages in every process that maps them, so summing eight Firefox content processes claims more memory than the machine has — the reports show the largest single process and a count (`1.2G ×8`) instead.

## Session labels

Sessions are labeled with their iTerm2 tab title where available, resolved via working directory → project slug → the recently-written transcript in `~/.claude/projects/`. The label cache is written by [claude-code-statusline](https://github.com/TurboKach/claude-code-statusline); without it, labels are simply omitted and everything else works unchanged. Where two sessions share a working directory the label is left blank rather than guessed.

## Cost and storage

`claude-watch` sampling: ~0.1s of CPU per sample (almost all of it `ps` walking the process table), about **1% of one core** at the default 10s interval. Raw data measured at ~7MB/day (13.6 rows per sample), gzipped after two days and deleted after 30 — roughly 60MB steady state.

The shell hook costs ~1.3ms on a normal shell start: the date comparison is an inline builtin test, and `claude-watch` is only executed on the one shell per day that needs it.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_WATCH_HOME` | `~/.claude-watch` | data directory |
| `CLAUDE_WATCH_FLOOR` | `5` | %CPU floor for machine-wide rows |
| `CLAUDE_WATCH_MEMFLOOR` | `409600` | RSS floor in KB (400M) |
| `CLAUDE_WATCH_TOPN` | `8` | max machine-wide rows per sample |
| `CLAUDE_WATCH_ORPHAN_MIN` | `60` | minutes before an unparented dev process is flagged |
| `CLAUDE_WATCH_KEEP_DAYS` | `30` | raw retention |
| `CLAUDE_WATCH_REPO_ROOTS` | `~/Dev` | colon-separated roots scanned for agent worktrees |

What counts as a leaked dev process lives in one file, `tools/orphan-policy.sh`, read by both the sampler that records orphans and the command that kills them. For a destructive command, the list you are shown and the thing that actually gets killed coming from a single rule is a safety property, not a style preference.

Change the sampling interval in `~/Library/LaunchAgents/com.turbokach.claudewatch.plist`, then `launchctl unload && launchctl load` it.

## Limitations

- **macOS only** — uses `ps`, `vm_stat`, `lsof` and `launchd`.
- **CPU and memory only.** GPU and Neural Engine power are not measured; real per-process watts need `sudo powermetrics`. A process heating the machine mostly via GPU will under-report here.
- **10-second resolution** in `claude-watch`. Spikes shorter than that are under-sampled.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.turbokach.claudewatch.plist
rm ~/Library/LaunchAgents/com.turbokach.claudewatch.plist
rm ~/.local/bin/claude-watch ~/.local/bin/claude-top
rm -rf ~/.claude-watch          # collected data
```

Then remove the hook line from `.zshrc`.

## License

[MIT](LICENSE)

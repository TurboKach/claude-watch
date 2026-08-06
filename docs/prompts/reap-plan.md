# Plan — `claude-watch orphans` / `claude-watch worktrees`

Closes handoff §7g ("orphans are reported but never actionable") and extends it to the
same leak in git-worktree form.

**Unifying idea:** every leak class is *a resource still held by work that already finished*.
Each needs the same two guards before anything destructive happens —
**liveness** (is something using it right now?) and **unsaved work** (would removing it lose anything?).

## Settled decisions (do not re-litigate)

| Decision | Choice |
|---|---|
| Confirmation UX | List first, then `[Y/n/s]` — **all is the default**, `s` drops to per-item |
| Shared orphan filter | Share the **policy only**; each tool keeps its own scan (no second `ps` pass in the sampler) |
| Worktree scope | **Agent-created paths only** — `<repo>/.claude/worktrees/*` and `~/conductor/workspaces/*` |
| Disk/transcript bloat (`~/.claude` 5.9G, `~/.codex/sessions` 783M) | Out of scope — separate plan |
| Report output | Untouched — no nudge line |
| Automated tests | Not in scope (not requested); verification is by real end-to-end run |

## Ground truth measured on this machine (2026-08-06)

- Orphans: **1 tree** — pid 1304 `node --import tsx --test …` + child 1418, 59.5M subtree, 4d16h.
  Killing 1304 alone reparents 1418 to launchd → it returns as a *new* orphan still holding 54M.
  **Subtree-aware kill is mandatory, deepest-first.**
- Orphan TSV rows carry **no pid** (`epoch, orphan, name, cores, rss, secs`), so the kill list
  *cannot* come from stored samples. Live scan only — which is also the pid-reuse-safe choice.
- Worktrees: `wizards/.claude/worktrees/agent-a309e0b6…` is **locked with a commit 10 minutes old** —
  an agent worktree that looks exactly like a stale one but is in active use. Age alone is a wrong signal.
  `language-learning/.claude/worktrees/musing-moore` is 6 months old but has **1 uncommitted file**.
  4 Conductor workspaces are 5 months old and clean (~111M, mostly `philadelphia` at 109M).
- `pgrep -f codex` is unusable for Codex detection: the macOS cryptex path
  `/var/run/com.apple.security.cryptexd/codex.system/...` appears in inherited env dumps of
  nearly every process.

---

## Step 1 — Extract the orphan policy

**New `tools/orphan-policy.sh`** — the single definition of "leaked dev process":
`ORPHAN_MATCH_RE`, `ORPHAN_EXCLUDE_RE`, `ORPHAN_MIN_DEFAULT=60`.

**Edit `tools/sample.sh`** — source the policy, pass the two regexes into its awk as `-v` variables,
replacing the inline literals at lines 179–180. No behaviour change, no extra `ps` pass.

*Why:* for a destructive command, "the list you were shown and the thing that gets killed
come from one rule" is a safety property, not a style preference.

**Verify:** sampler output before/after is byte-identical for the same `ps` snapshot;
`claude-watch doctor` still 8/8; error log stays empty.

## Step 2 — `claude-watch orphans [--kill] [--min N] [--yes]`

1. One `ps -Ao pid=,ppid=,pcpu=,rss=,etime=,lstart=,args=` pass; build the parent→child map.
2. Candidates: `ppid == 1`, matches `ORPHAN_MATCH_RE`, not `ORPHAN_EXCLUDE_RE`, age ≥ `--min` (default 60m),
   and not inside a live `claude` tree.
3. Roll up each candidate's **subtree**: process count, summed CPU, subtree RSS, oldest start.
4. **List** — index, folded name, age, subtree RSS, proc count, then one line per pid with truncated argv.
5. No `--kill` → list and exit 0. This is the built-in dry run.
6. `--kill` → prompt `kill all N trees? [Y/n/s]`; `s` → per-tree `[y/N/a/q]`. `--yes` skips the prompt.
7. **Re-verify before killing:** each pid must still exist *and* its `lstart` must match what was listed —
   guards against pid reuse between listing and confirmation. Mismatch → skip that tree loudly.
8. Kill descendants **deepest-first**, then the root: `TERM` → poll `kill -0` up to 3s → `KILL` survivors.
9. Report per-tree outcome and total RSS reclaimed.

## Step 3 — `claude-watch worktrees [--remove] [--yes]`

1. Discover repos under `CLAUDE_WATCH_REPO_ROOTS` (default `$HOME/Dev`), plus `~/conductor/workspaces/*/*`.
2. `git worktree list --porcelain` per repo; keep only paths matching `*/.claude/worktrees/*`
   or `$HOME/conductor/workspaces/*`. Hand-made worktrees are structurally invisible.
3. Per worktree collect: branch, last-commit age, dirty count, unpushed count, upstream, `locked`, size.
4. Classify:
   - **ACTIVE** — locked, or a live process cwd is inside it, or last commit < 24h → shown, never offered.
   - **UNSAFE** — dirty > 0 or unpushed > 0 → shown with a warning, **excluded from the `Y`-all set**;
     removable only via explicit per-item `s` confirmation.
   - **STALE** — clean, not locked, older than 7 days → the default `Y`-all set.
5. Remove with `git -C <main-repo> worktree remove <path>` — **never `rm -rf`** — then `git worktree prune`.
6. Leftover agent branches with no worktree (`claude/*`, `worktree-agent-*`, 5 found) are
   **listed only** in this version; no branch deletion.

## Step 4 — Docs

`README.md` gets a section for both subcommands; `docs/prompts/HANDOFF.md` §7g moves to done with
the subtree-kill and locked-worktree gotchas recorded in §4.

## Step 5 — Real end-to-end verification (not unit tests)

- Synthetic orphan: spawn a disowned `node -e 'setInterval(()=>{},1e9)'` with a child, run
  `orphans --min 0`, confirm the tree is listed with the right rollup, kill it, confirm both pids gone.
- Confirm the **live** wizards worktree is classified ACTIVE and never offered.
- Confirm `musing-moore` is flagged UNSAFE (uncommitted) and excluded from the all-set.
- Confirm the 4 Conductor workspaces land in the stale set.
- Dry-run listings shown to the user **before** anything real is removed.
- The real pid-1304 orphan is killed only with explicit approval at that moment.

## Risk notes

- Killing and `worktree remove` are irreversible. Every path is gated behind an explicit flag
  *and* a confirmation, and both subcommands list-only by default.
- No automated tests exist in this repo (handoff §7a) and none are added here, so Step 5's
  manual evidence is the only proof. Worth revisiting once the destructive paths are settled.

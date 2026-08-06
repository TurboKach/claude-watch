# Handoff: testing `claude-watch advise` / `disk` and the skill

For a fresh session whose job is **testing**, not building. Written 2026-08-06.
Merge-pipeline state lives in `advise-v1-status.md`; you do not need it to test.

---

## Read this first — the thing that will waste your time

**`advise` and `disk` do not exist on `main`, and the live skill does not know
about them.** Both symlinks point at the main working tree:

```
~/.local/bin/claude-watch        -> ~/Dev/claude-watch/claude-watch          (main: no advise)
~/.claude/skills/claude-watch    -> ~/Dev/claude-watch/skills/claude-watch   (main: 0 mentions of advise)
```

Verified:

| build | `advise` | `disk` | skill mentions `advise` |
|---|---|---|---|
| `~/Dev/claude-watch` (main) | no | no | 0 |
| `~/Dev/claude-watch-itest` (test build) | **yes** | **yes** | 7 |

So typing `claude-watch advise` in a shell, or asking the model to use the
claude-watch skill, exercises **main** and fails. That is not a bug in the
feature.

## The test build

`~/Dev/claude-watch-itest`, branch `integration-test` at `b92e323` — main plus
U2, U3, U4, U5, U6 merged (cleanly, no conflicts). This is a durable git
worktree, not a temp dir; it survives sessions. Recreate with
`git worktree add ~/Dev/claude-watch-itest integration-test` if it goes missing.

**It is not shippable.** Four units still have open P1s; see
`advise-v1-status.md`. It is good enough to evaluate how the product *feels*,
which is what this session is for.

### Testing the CLI — no setup needed

```bash
cd ~/Dev/claude-watch-itest
./claude-watch advise                 # the main event
./claude-watch advise --json | python3 -m json.tool
./claude-watch advise --window week
./claude-watch advise --show-thresholds
./claude-watch disk --json | python3 -m json.tool
./claude-watch disk --refresh         # ~25s, the only thing that scans
bash tests/smoke.sh                   # 64 passed, 0 failed, 1 skipped
```

### Testing the *skill* — needs a temporary repoint

The skill is a thin relay over the CLI, so testing it means both symlinks have to
point at the test build. Repoint, test, then **put them back**:

```bash
# switch to the test build
ln -sfn ~/Dev/claude-watch-itest/claude-watch        ~/.local/bin/claude-watch
ln -sfn ~/Dev/claude-watch-itest/skills/claude-watch ~/.claude/skills/claude-watch

# ... test ...

# restore (do not skip)
ln -sfn ~/Dev/claude-watch/claude-watch              ~/.local/bin/claude-watch
ln -sfn ~/Dev/claude-watch/skills/claude-watch       ~/.claude/skills/claude-watch
```

A new Claude session may need restarting after repointing for the skill
frontmatter to be re-read.

Skill prompts worth trying, and what a correct answer looks like:

| ask | should happen |
|---|---|
| "why is my disk full" | reads `primary` first, reports CRITICAL disk, names the 25.5 GiB of rebuildable output |
| "why is my laptop hot" | must carry the CPU/memory caveat — v1 measures neither — and not imply the machine is fine |
| "is anything still running" | leaks domain; currently 2 removable worktrees, 596 KiB |
| after deleting the disk cache | must **tell you** to run `claude-watch disk --refresh`, never run it itself (G7) |

The five instructions the skill is supposed to obey are in its SKILL.md; the ones
most worth trying to break are "never present an `unavailable` domain as clean"
and "treat an unknown enum value as unavailable, never as healthy".

## Already known — do not spend time re-finding these

Found by running the build. All real, none fixed:

1. **Zero removal commands are ever offered.** `0 confirmed, 20 likely,
   0 unverified`. The confidence gate is tight enough that the headline value —
   "here is the line to reclaim 25 GiB" — never fires. **This is the main thing
   to form an opinion about**; it is a product-tuning decision, not a code bug.
2. `~/Downloads` renders as *"in active use, rebuilt on next build"* — hardcoded
   `likely` boilerplate ignoring group kind.
3. The E9 permission-denied sentence prints twice in the disk section.
4. `is 0.0 GiB, 0.0% of this domain` for a 596 KiB finding — units do not scale down.

Also expected, not a defect: **`partial=1` on every run**, from ~20 permission
denials under `~/Library/Caches` and `~/Library/Containers`. Those are TCC
protected and will deny unless the terminal has Full Disk Access. Per-group
capping means the `~/Dev` findings keep their real severity anyway.

## Side effects to know about

- `disk --refresh` writes `~/.claude-watch/state/disk.tsv` and takes a lock at
  `~/.claude-watch/state/disk-scan.lock`. **The cache is shared between both
  builds** — a refresh from the test build is what main would also read.
- `advise` appends one line per run to `~/.claude-watch/state/advise.log`.
- `advise` is structurally read-only: no `--refresh`, no `--kill`, no `--remove`.
  Every one exits 2. That is worth verifying rather than trusting.
- Nothing in this feature deletes anything. Actions are printed, never run.

## One thing not to poke at casually

U5's worktree-path injection is **still live** in this build. A path containing
both a tab and a newline can inject a synthetic worktree record. Do not point
`CLAUDE_WATCH_REPO_ROOTS` at anything untrusted, and do not paste a command the
tool prints for a path that looks odd. Details in `advise-v1-status.md`.

## Current machine baseline, for comparison

Volume `/System/Volumes/Data`: 4.7% available, 19.7 GiB of 422 GiB.
Rebuildable 25.5 GiB / 57 dirs (`buzz/target` 11.0 GiB, `src-tauri/target`
6.5 GiB). node_modules 4.8 GiB / 17. Downloads 10.7 GiB. Transcripts 4.5 GiB.
Leaks: 0 orphans, 2 removable worktrees / 596 KiB. Sampler live, ~10s interval.

If `advise` disagrees with these by a lot, something changed on the machine —
check `claude-watch status` and `claude-watch doctor` before blaming the tool.

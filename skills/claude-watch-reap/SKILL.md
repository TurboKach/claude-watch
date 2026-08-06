---
name: claude-watch-reap
description: Kills leaked orphan process trees and removes stale agent-created git worktrees found by claude-watch. Irreversible; user-invoked only.
disable-model-invocation: true
allowed-tools: Bash(claude-watch orphans --json*) Bash(claude-watch worktrees --json*)
---

# claude-watch reap — destructive

Every step here is irreversible. Order is: **list → confirm → act → verify.** Never skip to act.

## 1. List what is actually there

```bash
claude-watch orphans --json
claude-watch worktrees --json
```

Both are read-only. Re-run them now rather than trusting anything listed earlier in the conversation — pids get recycled and worktrees change state.

## 2. Show the user, and get a real answer

Present each candidate with the facts that decide it:

- orphan trees: root name, age, **subtree** `rss_kb`, `proc_count`, and the argv of each pid
- worktrees: path, branch, `age_days`, `size_kb`, and `reason`

Only entries with `removable: true` are eligible. Say explicitly what is being **excluded** and why — `ACTIVE` worktrees are in use, `UNSAFE` ones hold uncommitted or unpushed work.

Ask with AskUserQuestion. Do not proceed on silence, on a recommendation, or on approval given earlier in the session for something else.

## 3. Act

```bash
claude-watch orphans --kill --yes
claude-watch worktrees --remove --yes
```

`--yes` is what makes these destructive. It is required here because a Claude Bash call has no tty, so the tool's own interactive confirmation is unreachable — which is exactly why step 2 is not optional.

These two commands are **deliberately absent from this skill's `allowed-tools`**, which pre-approves only the read-only `--json` listings. `allowed-tools` grants permission; it does not restrict — every tool stays callable, and anything unlisted simply follows normal permission settings. So the reap surfaces a permission prompt, and that prompt is a second human gate on an irreversible action. Do not "fix" this by adding them.

**`--yes` takes everything removable.** There is no way to pick a subset from here. If the user wants some but not others, tell them to run it themselves in a terminal, where `s` at the prompt steps through one at a time:

```
claude-watch orphans --kill      # then answer s
claude-watch worktrees --remove  # then answer s
```

Narrow the set instead with `--min MINUTES` (orphans, default 60) or `--days DAYS` (worktrees, default 7) when that gets what they want.

## 4. Verify

Re-run the listings from step 1 and report what actually went away, with the reclaimed totals. If anything survived, say so — `orphans` reports survivors of SIGKILL, and `worktrees` reports when git refused a removal.

Branches left behind by removed worktrees are listed but never deleted. Do not delete them either; an unmerged branch may be the only copy of that work.

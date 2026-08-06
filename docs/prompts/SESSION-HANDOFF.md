# Session handoff — how claude-watch works and how to use it

Written 2026-08-06, at the end of the session that made the tool actionable and gave it an
agent interface. Written for a session that wants to **discuss** the tool rather than build on it.

For implementation gotchas and the decisions log, read [HANDOFF.md](HANDOFF.md) — it is the
reference doc and it is still accurate. This file is the orientation.

---

## Status

Merged to `main` (`0a1f40c`), **not pushed**. 20 commits, working tree clean, smoke suite green.

What exists now:

| | |
|---|---|
| `claude-top` | live process tree, right now |
| `claude-watch report` | what actually used the machine, per day |
| `claude-watch orphans` | leaked process trees — `--kill` to reap |
| `claude-watch worktrees` | stale agent-created git worktrees — `--remove` to reap |
| `--json` | on report / orphans / worktrees / status |
| `skills/` | two Claude Code skills, symlinked into `~/.claude/skills` by `install.sh` |
| `tests/smoke.sh` | read-only; destroys nothing, asserts the destructive paths refuse |

---

## Start here

```bash
claude-watch doctor      # 8 checks, exit 0 when healthy
claude-watch             # today so far
claude-watch orphans     # anything leaked? (listing only)
claude-watch worktrees   # anything stale? (listing only)
claude-top -1            # one live frame
```

If `doctor` fails on "last sample is recent", the launchd sampler has stalled — that is the first
thing to fix, before trusting any report.

---

## The mental model

Four ideas explain nearly every design decision in the codebase. If a change seems to violate one,
that is usually the bug.

**1. An orphan is a tree, not a process.** The original real case was a `node --test` root holding
6M with a worker child holding 54M. Killing the root reparents the child to launchd, where it comes
straight back as a brand-new orphan still holding its memory. Everything reaps deepest-first, and
the kill set is re-enumerated live rather than trusted from the listing — a root can fork while the
confirmation prompt is open.

**2. Liveness beats staleness.** An agent worktree in active use looks *identical on disk* to an
abandoned one. `wizards/.claude/worktrees/agent-a309e0b6…` had a commit 10 minutes old and git's
`locked` flag while looking exactly like a 5-month-old leftover. So liveness (lock flag, commit
inside 24h, a real `lsof` cwd sweep) is checked first and always wins. Age alone is a wrong signal.

**3. Identity, not liveness, gates a signal.** A pid that exits during the grace period can be
recycled onto something unrelated, and `kill -0` cheerfully reports it as alive. Every pid's argv
and elapsed time are recorded when we decide to act on it, and re-checked immediately before STOP,
TERM, CONT and KILL. This is where most of the review rounds went.

**4. Listing is the dry run.** `orphans` and `worktrees` with no flags destroy nothing. `--kill` /
`--remove` add a confirmation; without a terminal they refuse outright unless `--yes` is explicit.
A Claude Bash call has no tty, so an agent cannot destroy anything by accident.

---

## Using the reaping commands

```bash
claude-watch orphans --kill          # list, then [Y/n/s]
claude-watch worktrees --remove      # same
```

At the prompt: **Enter accepts all**, `n` aborts, `s` steps through one at a time (`y`/`N`/`a`ll/`q`uit).

Narrow the set instead of picking per item:

```bash
claude-watch orphans --kill --min 15      # age floor in minutes (default 60)
claude-watch worktrees --remove --days 30 # staleness in days (default 7)
```

`--yes` skips the prompt for scripting, and **takes everything removable** — there is no way to pick
a subset without a terminal. Both commands return non-zero when something selected was not actually
reaped, so automation can tell.

Only agent-created worktree paths are ever considered: `<repo>/.claude/worktrees/*` and
`~/conductor/workspaces/*`. Worktrees you made by hand are structurally invisible, which is what
makes "yes to all" safe. Removal goes through `git worktree remove`, never `rm -rf`. **Branches are
reported, never deleted** — a branch is cheap and may be the only copy of unmerged work.

---

## The agent interface

Two skills, split on purpose:

- **`claude-watch`** — read-only, model-invocable. Claude reaches for it on "why is my laptop hot",
  "what's still running", "which worktrees are left over".
- **`claude-watch-reap`** — `disable-model-invocation: true`. Only you can start a reap.

The split follows the documented guidance for side-effecting workflows. The destructive commands are
also deliberately **absent from `allowed-tools`**, so they surface a permission prompt — a second
human gate. `allowed-tools` pre-approves; it does not restrict. Do not "fix" that by adding them.

Prefer `--json` when reading programmatically; the human format is free to change, the JSON is the
contract. It is read-only by construction — `--json` prints and returns before any destructive path.

---

## Where the machine stands, and what is deliberately conservative

As of this session: **0 orphan processes, 0 worktrees offered for removal.**

All four Conductor workspaces classified **UNSAFE**, three of them for "no upstream" — and that was
a bug, not caution. "No upstream" was being read as "nothing published", but Conductor (and
`git worktree add -b`) simply never configure tracking, so a branch merged and pushed weeks earlier
reported its entire history as unpushed. `unpushed` now counts commits reachable from `HEAD` but
from no remote-tracking ref (`rev-list --count HEAD --not --remotes`), which needs no upstream. The
same test guards `still_removable()`, so the listing and the pre-removal re-check cannot disagree.

Judgement calls that remain open: the 24h liveness window (anything committed to today is
untouchable) and `--yes` taking everything.

Two things changed on the machine during the build session, both of which should have been asked
about first: the 4-day-old `node --test` orphan was killed, and
`~/conductor/workspaces/deb8_backend/vienna` was removed. Its branch survived and was already merged
into `dev`, so nothing was lost.

---

## Open questions worth a conversation

**The big one — disk.** `~/.claude` is **5.9G**, of which `~/.claude/projects` transcripts are
**3.7G**; `~/.codex/sessions` is **783M** across 3254 files. That is ~4.5G, versus the ~170M the
process and worktree reaping recovers. It is deliberately out of scope so far: deleting transcripts
is irreversible and needs its own rules about what Claude Code still needs to resume a session.
This is §7h in HANDOFF.md and is the obvious next feature.

Smaller, all in HANDOFF.md §7:

- **7a** — mostly closed. `tests/fixture-report.sh` pins the report arithmetic (it catches the
  `lastep` bug from §4.16 and five others by mutation) and `tests/fixture-worktree-unpushed.sh`
  pins worktree classification; `tests/smoke.sh` runs every `tests/fixture-*.sh` by glob. Still
  manual-evidence-only: `tools/sample.sh` and the orphan subtree walk / pid re-verification.
- **7b** — `claude-top` says `253%`, `claude-watch` says `2.5×`. Same quantity, two notations.
- **7c** — GPU / Neural Engine power is the known blind spot, and heat was the original complaint.
- **7d** — retention only runs from the shell hook, so a day with no new shell never gets pruned.

Also open: `claude-top` prints process argv the same way `orphans` used to, so it has the same
theoretical terminal-escape exposure that was hardened here. Pre-existing, unfixed.

---

## Things that will bite a fresh session

Full list in HANDOFF.md §4; these are the ones that cost time this session:

- **zsh does not word-split unquoted variables.** A test sweep written inline in the session shell
  passes one argument where bash passes two, and the tool correctly rejects it — which reads as a
  regression that does not exist. Put test loops in a file with a `#!/usr/bin/env bash` shebang.
- **`awk -v` runs backslash-escape processing over the value.** A path containing `\t` arrives as a
  tab. Use `ENVIRON` for anything path-shaped.
- **`lsof -F` escapes backslashes** in the names it prints.
- **Malformed skill frontmatter fails silently**: Claude Code loads the body with empty metadata, so
  `/skill-name` still works but auto-invocation dies with no error anywhere. Validate with a real
  YAML parser.
- **macOS `ps` caret-encodes control bytes** in argv (`^[`, `\011`), which quietly defuses a whole
  class of injection — do not depend on it, but know it when a finding "won't reproduce".

---

## Review posture

The branch went through `/codex review` 17 times: 31 findings, 30 fixed, 1 rejected as incorrect.
Round 18 came back clean. The rejected one claimed `allowed-tools` blocks unlisted commands; the
docs say the opposite, and "fixing" it would have removed a safety gate.

Two findings did not reproduce on macOS (tabs and ESC in argv, both neutralised by `ps`) and were
hardened anyway — cheap, and one is a security class.

Worth knowing for calibration: the later rounds converged on progressively narrower pid-reuse
windows. They were real, but a fresh reviewer starting from scratch would likely not rank them
first. The highest-value unreviewed surface is still the report arithmetic (§7a).

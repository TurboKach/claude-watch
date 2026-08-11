#!/usr/bin/env bash
# The single definition of "what counts as a leaked dev process".
#
# Sourced by BOTH tools/sample.sh (which records orphans) and claude-watch
# (which offers to kill them). One rule, two readers: the list you are shown
# and the thing that actually gets killed cannot drift apart. For a destructive
# command that is a safety property, not a style preference.
#
# Each tool still does its own `ps` pass. Sharing the scan itself would cost the
# sampler a second pass, and ps is almost all of its ~0.1s budget.
#
# These are awk DYNAMIC regexes — passed as strings via -v, not /literals/ — so
# slashes need no escaping (a backslash would need doubling).

ORPHAN_MATCH_RE='(node|tsx|npm|npx|yarn|pnpm|bun|deno|vite|esbuild|webpack|jest|vitest|pytest|python[23]?|ts-node|next-server|playwright|chrome-headless)'
ORPHAN_EXCLUDE_RE='(Applications|/usr/libexec|/System/)'
ORPHAN_MIN_DEFAULT=60

# A process is also a leak if it CARRIES a session path, whatever it is called.
# This is provenance, not identity: it catches a postgres or redis a session
# started without ever putting those names on the allowlist, which would also
# match the user's own brew-managed database.
#
# `/tmp` is a symlink to `/private/tmp` on macOS and argv records whichever form
# the caller used, so both must match. `(/private)?` — not `/private/?` — is what
# does that. The backslash in `/\.claude/` is single here and doubled nowhere:
# see the dynamic-regex note above.
ORPHAN_PROVENANCE_RE='(/private)?/tmp/claude-[0-9]+/|/\.claude/worktrees/'

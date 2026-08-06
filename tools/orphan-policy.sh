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

#!/usr/bin/env bash
# Fixture tests for ORPHAN_PROVENANCE_RE (docs/prompts/advise-merge-plan.md
# Step 7): a process is also a leak if its argv CARRIES a Claude session path,
# whatever it is called — not just a name on the ORPHAN_MATCH_RE allowlist.
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split unquoted
# variables, so this must be a FILE run under bash, never pasted into a shell.
#
# tools/orphan-policy.sh's own header calls single-definition a SAFETY
# property: the list a user is shown (claude-watch orphans) and the list the
# sampler records (tools/sample.sh, which `orphans --kill` also trusts) must
# never drift apart. Every case below is therefore proven against BOTH
# readers, with hand-written ps rows so no real process is ever touched.
set -uo pipefail
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

# shellcheck source=../tools/orphan-policy.sh
. "$REPO/tools/orphan-policy.sh"

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------- the matrix -----
# argv, then whether BOTH readers must flag it. Tab-separated so the argv's own
# spaces (real command lines) survive untouched.
MATRIX="$(printf '%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n' \
  'postgres -D /private/tmp/claude-501/-Users-turbokach-Dev-claude-watch/be6c46b6-x/scratchpad/pgdata -p 55433' flagged \
  'postgres -D /tmp/claude-501/-Users-turbokach-Dev-claude-watch/be6/scratchpad/pgdata -p 55433' flagged \
  'postgres -D /opt/homebrew/var/postgresql@14' not-flagged \
  'redis-server *:6379' not-flagged \
  'node /Users/x/x/.claude/worktrees/agent-a1/node_modules/.bin/vite' flagged)"

# -------------------------------------------------- reader 1: claude-watch --
# scan_orphans() lives in the parent script. Sourced with a synthetic argv so
# its own trailing dispatch (`case "$1" in ...`) never runs a real subcommand
# — the same technique tests/fixture-leaks.sh uses for scan_worktrees. `ps` is
# shadowed by a shell function rather than a PATH stub, so no temp binary is
# needed and no real process is ever consulted.
cw_scan() {  # <ps snapshot lines (pid ppid pcpu rss etime argv)> -> T rows
  local snap=$1
  (
    ps() { printf '%s\n' "$snap"; }
    set -- --help
    # shellcheck source=../claude-watch
    . "$REPO/claude-watch" >/dev/null 2>&1
    scan_orphans 0
  )
}

# -------------------------------------------------- reader 2: the sampler ---
# tools/sample.sh is a standalone script (executed, not sourced), so `ps` is
# shadowed here by exporting a shell function into the `bash tools/sample.sh`
# child process — the same PATH-independent technique, just across a process
# boundary. etime/time both need a plausible shape (D-HH:MM:SS or HH:MM:SS);
# ORPHAN_MIN_DEFAULT is 60 minutes, so 2h clears it comfortably.
sampler_scan() {  # <ps snapshot lines (pid ppid pcpu rss etime time argv)> -> today's raw rows
  local home="$TMP/samplehome.$$"
  mkdir -p "$home"
  # `export -f ps` alone is not enough: the function body crosses into a new
  # bash PROCESS, so a bare `$1`/local closing over this shell's variables
  # resolves against the CHILD's (empty) environment, not this one. The
  # snapshot itself has to be exported too.
  SNAP_DATA=$1
  export SNAP_DATA
  ps() { printf '%s\n' "$SNAP_DATA"; }
  export -f ps
  CLAUDE_WATCH_HOME="$home" bash "$REPO/tools/sample.sh" >/dev/null 2>&1
  cat "$home/raw/$(date +%F).tsv" 2>/dev/null
  unset -f ps
  unset SNAP_DATA
  rm -rf "$home"
}

cw_snap=""
sampler_snap=""
n=0
while IFS=$'\t' read -r argv want; do
  [ -n "$argv" ] || continue
  n=$((n + 1))
  pid=$((5000 + n))
  rss=$((10000 + n * 11111))
  # Command substitution strips trailing newlines, so building a multi-line
  # snapshot through repeated `snap="$snap$(printf ...)"` silently fuses every
  # row into the one before it. The newline is appended OUTSIDE the
  # substitution instead, one $'\n' per row.
  # reader 1: pid ppid pcpu rss etime argv  (ps -Ao pid=,ppid=,pcpu=,rss=,etime=,args=)
  cw_snap="${cw_snap}${pid} 1 0.0 ${rss} 02:00:00 ${argv}"$'\n'
  # reader 2: pid ppid pcpu rss etime time argv  (adds cumulative time=)
  sampler_snap="${sampler_snap}${pid} 1 0.0 ${rss} 02:00:00 0:01.00 ${argv}"$'\n'
done <<EOF
$MATRIX
EOF

CW_OUT=$(cw_scan "$cw_snap")
SAMPLER_OUT=$(sampler_scan "$sampler_snap")

n=0
while IFS=$'\t' read -r argv want; do
  [ -n "$argv" ] || continue
  n=$((n + 1))
  pid=$((5000 + n))
  rss=$((10000 + n * 11111))

  got_cw=not-flagged
  printf '%s\n' "$CW_OUT" | LC_ALL=C awk -F'\t' -v p="$pid" '$1 == "T" && $2 == p { found = 1 } END { exit !found }' \
    && got_cw=flagged
  if [ "$got_cw" = "$want" ]; then ok "claude-watch scan_orphans: $argv -> $want"
  else bad "claude-watch scan_orphans: $argv -> want $want, got $got_cw"; fi

  # The sampler's orphan row carries no pid (§ orphan row shape), so rss is
  # the disambiguator between two same-named rows in the matrix (both
  # postgres forms).
  got_sampler=not-flagged
  printf '%s\n' "$SAMPLER_OUT" | LC_ALL=C awk -F'\t' -v r="$rss" '$2 == "orphan" && $5 == r { found = 1 } END { exit !found }' \
    && got_sampler=flagged
  if [ "$got_sampler" = "$want" ]; then ok "tools/sample.sh orphan pass:  $argv -> $want"
  else bad "tools/sample.sh orphan pass:  $argv -> want $want, got $got_sampler"; fi

  eq_desc="both readers agree on: $argv"
  if [ "$got_cw" = "$got_sampler" ]; then ok "$eq_desc"; else bad "$eq_desc (cw=$got_cw sampler=$got_sampler)"; fi
done <<EOF
$MATRIX
EOF

# ---------------------------------------------- the empty-PROV guard (§357) --
# An empty awk dynamic regex matches EVERY string (`x ~ ""` is always true).
# claude-watch:24 sources the policy with `|| true`, so if ORPHAN_PROVENANCE_RE
# ever ends up unset, `A[p] ~ PROV` would be true for every PPID-1 process —
# more output, not an error, so this must be asserted explicitly or it will
# not show up as a red test. The guard at claude-watch:851 must refuse rather
# than fall through to matching everything.
(
  ps() { printf '1 1 0.0 100 02:00:00 /sbin/launchd\n'; }
  set -- --help
  # shellcheck source=../claude-watch
  . "$REPO/claude-watch" >/dev/null 2>&1
  unset ORPHAN_PROVENANCE_RE
  orphans
) > "$TMP/guard.out" 2> "$TMP/guard.err"
rc_guard=$?
if [ "$rc_guard" != 0 ]; then ok "empty ORPHAN_PROVENANCE_RE: orphans refuses (exit $rc_guard)"
else bad "empty ORPHAN_PROVENANCE_RE: orphans refuses (got exit 0)"; fi
if grep -q 'cannot read' "$TMP/guard.err"; then
  ok "  ...and names the policy file it could not read"
else
  bad "  ...and names the policy file it could not read"; sed 's/^/        /' "$TMP/guard.err"
fi
if [ -s "$TMP/guard.out" ]; then
  bad "  ...and does not fall through to matching everything (launchd itself printed)"
  sed 's/^/        /' "$TMP/guard.out"
else
  ok "  ...and does not fall through to matching everything"
fi

# ---------------------------------------------- the empty-EXCL guard (G1) ---
# The opposite failure mode from PROV/MATCH: an empty EXCLUDE_RE does not turn
# every process into an orphan, it turns `args[p] ~ EXCL` true for every one
# of them, so scan_orphans() filters every real candidate back OUT. That is
# indistinguishable from "nothing to report" on a command that also drives
# --kill — a leaked node process below is a genuine candidate the guard must
# refuse on, not silently swallow into a clean "no orphaned dev processes".
# Uses an empty string, not `unset`, to match the actual failure mode (a
# policy file that sources cleanly but leaves the assignment blank) rather
# than tripping claude-watch's own `set -u` on an unset shell variable.
(
  ps() { printf '2 1 0.0 100 02:00:00 node app.js\n'; }
  set -- --help
  # shellcheck source=../claude-watch
  . "$REPO/claude-watch" >/dev/null 2>&1
  ORPHAN_EXCLUDE_RE=''
  orphans
) > "$TMP/guardx.out" 2> "$TMP/guardx.err"
rc_guardx=$?
if [ "$rc_guardx" != 0 ]; then ok "empty ORPHAN_EXCLUDE_RE: orphans refuses (exit $rc_guardx)"
else bad "empty ORPHAN_EXCLUDE_RE: orphans refuses (got exit 0)"; fi
if grep -q 'cannot read' "$TMP/guardx.err"; then
  ok "  ...and names the policy file it could not read"
else
  bad "  ...and names the policy file it could not read"; sed 's/^/        /' "$TMP/guardx.err"
fi
if [ -s "$TMP/guardx.out" ]; then
  bad "  ...and does not fall through to a clean \"no orphaned dev processes\" (a real leak was hidden)"
  sed 's/^/        /' "$TMP/guardx.out"
else
  ok "  ...and does not fall through to a clean \"no orphaned dev processes\""
fi

# The complement: with the policy intact, the same run must NOT refuse — the
# guard above is not simply always-on.
(
  ps() { printf '1 1 0.0 100 02:00:00 /sbin/launchd\n'; }
  set -- --help
  # shellcheck source=../claude-watch
  . "$REPO/claude-watch" >/dev/null 2>&1
  orphans
) > "$TMP/noguard.out" 2> "$TMP/noguard.err"
rc_noguard=$?
if [ "$rc_noguard" = 0 ]; then ok "with the policy intact, orphans does not refuse"
else bad "with the policy intact, orphans does not refuse (got exit $rc_noguard)"; sed 's/^/        /' "$TMP/noguard.err"; fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Read-only smoke test. Destroys nothing: it runs the listing commands and
# asserts that the destructive ones REFUSE, which is exactly the guard worth
# regression-testing.
#
# The shebang is the point. This must never inherit the caller's shell: zsh does
# not word-split unquoted variables, so an inline sweep like
#     for c in "report today"; do claude-watch $c; done
# passes ONE argument under zsh and two under bash. The tool then rejects
# "report today" with exit 2 and the sweep reports a regression that does not
# exist. Running as a file with this shebang removes that whole class of error.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CW="$REPO/claude-watch"
pass=0; fail=0; skip=0

ok()   { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skp()  { skip=$((skip + 1)); printf '  \033[90mskip\033[0m  %s\n' "$1"; }

have_python=0; command -v python3 >/dev/null 2>&1 && have_python=1

expect_exit() {  # <want> <desc> <cmd...>
  local want=$1 desc=$2 got; shift 2
  "$@" >/dev/null 2>&1; got=$?
  [ "$got" = "$want" ] && ok "$desc" || bad "$desc (exit $got, wanted $want)"
}

expect_json() {  # <desc> <cmd...>
  local desc=$1; shift
  [ "$have_python" = 1 ] || { skp "$desc (no python3)"; return; }
  if "$@" --json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "$desc"
  else
    bad "$desc"
  fi
}

echo "syntax"
for f in claude-watch claude-top install.sh tools/sample.sh tools/orphan-policy.sh tests/smoke.sh; do
  bash -n "$REPO/$f" 2>/dev/null && ok "$f parses" || bad "$f parses"
done

# `status` exits 1 with no samples and `doctor` exits non-zero until launchd,
# the data dir and the shell hook are installed. Both are correct behaviour, so
# a fresh checkout must skip them rather than fail — otherwise the suite this
# README advertises cannot pass in the state most people first run it in.
installed=0
[ -n "$(ls -A "${CLAUDE_WATCH_HOME:-$HOME/.claude-watch}/raw" 2>/dev/null)" ] && installed=1

echo "commands exit clean"
expect_exit 0 "report today"       "$CW" report today
expect_exit 0 "report yesterday"   "$CW" report yesterday
expect_exit 0 "orphans"            "$CW" orphans
expect_exit 0 "worktrees"          "$CW" worktrees
if [ "$installed" = 1 ]; then
  expect_exit 0 "status"           "$CW" status
  expect_exit 0 "doctor"           "$CW" doctor
else
  skp "status (no samples collected yet)"
  skp "doctor (sampler not installed yet)"
fi
expect_exit 2 "unknown subcommand rejected"        "$CW" "report today"
expect_exit 2 "unknown orphans option rejected"    "$CW" orphans --bogus
expect_exit 2 "unknown worktrees option rejected"  "$CW" worktrees --bogus
# awk coerces a non-numeric -v to 0, which would silently drop the age floor and
# hand every match to --kill. These must be refused before the scan runs.
expect_exit 2 "orphans --min rejects non-numeric"   "$CW" orphans --kill --yes --min nope
expect_exit 2 "orphans --min rejects empty"         "$CW" orphans --min
expect_exit 2 "worktrees --days rejects non-numeric" "$CW" worktrees --remove --yes --days xyz
expect_exit 2 "worktrees --days rejects empty"       "$CW" worktrees --days
# The date is interpolated straight into --json; validating its shape keeps that
# output well-formed by construction.
expect_exit 2 "report rejects a malformed date"      "$CW" report garbage
expect_exit 2 "report rejects a quote in the date"   "$CW" report '2026-01-01"x'

echo "--json is valid JSON"
expect_json "report --json"     "$CW" report today
expect_json "orphans --json"    "$CW" orphans
expect_json "worktrees --json"  "$CW" worktrees
# status exits 1 with no samples, and pipefail would fail the pipeline even
# though the JSON it printed is perfectly valid.
if [ "$installed" = 1 ]; then
  expect_json "status --json"   "$CW" status
else
  skp "status --json (no samples collected yet)"
fi
# Control bytes are legal in argv and paths but illegal raw in JSON, so the
# escaper must encode the whole sub-0x20 range, not just tab/newline/return.
if [ "$have_python" = 1 ]; then
  ctl=$(printf 'a\001b\033c')
  if printf '%s' "$ctl" | LC_ALL=C awk "$(sed -n "/^JESC_AWK='$/,/^'$/p" "$REPO/claude-watch" | sed '1d;$d')"'
        { printf "{\"v\":\"%s\"}\n", jesc($0) }' | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "jesc escapes control characters"
  else
    bad "jesc escapes control characters"
  fi
else
  skp "jesc control characters (no python3)"
fi

echo "destructive paths refuse without a terminal"
# Only meaningful when there is something to destroy: with an empty list both
# commands exit 0 before ever reaching the confirmation.
if [ "$("$CW" orphans --json 2>/dev/null | grep -c '"root_pid"')" -gt 0 ]; then
  expect_exit 1 "orphans --kill refuses with no tty" "$CW" orphans --kill
else
  skp "orphans --kill guard (no orphans present)"
fi
if "$CW" worktrees --json 2>/dev/null | grep -q '"removable":true'; then
  expect_exit 1 "worktrees --remove refuses with no tty" "$CW" worktrees --remove
else
  skp "worktrees --remove guard (nothing removable)"
fi

echo "skill frontmatter"
if [ "$have_python" = 1 ] && python3 -c 'import yaml' 2>/dev/null; then
  for s in claude-watch claude-watch-reap; do
    if python3 - "$REPO/skills/$s/SKILL.md" <<'PY' 2>/dev/null
import re, sys, yaml
d = yaml.safe_load(re.match(r'^---\n(.*?)\n---\n', open(sys.argv[1]).read(), re.S).group(1))
assert re.fullmatch(r'[a-z0-9-]{1,64}', d['name'])
assert 0 < len(d['description']) <= 1024
PY
    then ok "skills/$s frontmatter is valid YAML"
    else bad "skills/$s frontmatter is valid YAML"
    fi
  done
else
  skp "skill frontmatter (no python3 yaml)"
fi

echo "sampler"
tmp=$(mktemp -d) || exit 1
if CLAUDE_WATCH_HOME="$tmp" "$REPO/tools/sample.sh" 2>/dev/null; then
  kinds=$(cut -f2 "$tmp"/raw/*.tsv 2>/dev/null | sort -u | tr '\n' ' ')
  case "$kinds" in *sys*) ok "one sampling pass writes rows (kinds: $kinds)" ;;
                   *)     bad "one sampling pass writes rows (got: $kinds)" ;; esac
else
  bad "one sampling pass exits clean"
fi
rm -rf "$tmp"

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]

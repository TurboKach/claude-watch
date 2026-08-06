#!/usr/bin/env bash
# Fixture test for worktree classification, specifically the `unpushed` count.
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split unquoted
# variables, so this must be a FILE run under bash, never pasted into a shell.
#
# Hermetic. Builds throwaway repos with LOCAL bare repos standing in for
# remotes — no network, nothing outside its own mktemp -d is read or written,
# and no configuration the machine happens to carry is honoured (see
# "isolation" below). CLAUDE_WATCH_REPO_ROOTS scopes each scan to one sandbox,
# which also stops repo_candidates from enumerating ~/conductor.
#
# What it pins:
#   - a branch merged and pushed but with NO tracking configuration reports
#     unpushed 0 and is removable. That is the bug: "no upstream" was read as
#     "nothing published", and agent tools never configure tracking, so every
#     conductor workspace reported its entire history as unpushed for ever.
#   - a commit beyond the remote still reports unpushed and stays UNSAFE, so the
#     widening did not trade the safety property away.
#   - a dirty tree is UNSAFE whatever the unpushed count says.
#   - still_removable() agrees with the listing: the sandbox worktree is actually
#     removed. If the two tests ever drift, removal reports "changed since it was
#     listed" for everything and this goes red.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CW="$REPO/claude-watch"
pass=0; fail=0; skip=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skp() { skip=$((skip + 1)); printf '  \033[90mskip\033[0m  %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "fixture-worktree-unpushed: python3 required"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- isolation --
# Hermetic has to mean hermetic. Without this block, every `git commit` below
# runs whatever the machine has configured in `core.hooksPath` — the user's own
# hooks, arbitrary code that can read or write real data or reach the network —
# during a plain `tests/smoke.sh` run. `init.templateDir` is the same exposure
# by another route: it installs hooks into each repo as it is created.
#
# GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM (git >= 2.32) redirect the global and
# system config files wholesale, which covers ~/.gitconfig, ~/.config/git/config
# and /etc/gitconfig in one move; GIT_CONFIG_NOSYSTEM is the older belt to that
# brace. The replacement global file is not empty — it points core.hooksPath and
# init.templateDir at directories this fixture created and left empty, so even a
# future git that consults some other config still finds nothing to run.
#
# These are EXPORTED rather than passed as `git -c`, because the git commands
# that matter most are not the ones written here: claude-watch runs its own
# (rev-list, status, worktree remove) as child processes, and only the
# environment reaches those. HOME moves too — plenty of tools read it directly,
# and it keeps the scan away from the real ~/.claude.
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/home/.config"
mkdir -p "$TMP/home" "$TMP/empty-hooks" "$TMP/empty-template" || exit 1
cat > "$TMP/gitconfig" <<EOF || exit 1
[core]
	hooksPath = $TMP/empty-hooks
[init]
	templateDir = $TMP/empty-template
EOF
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_TEMPLATE_DIR="$TMP/empty-template"

ORIGIN="$TMP/origin.git"
MAIN="$TMP/repo"
WT="$MAIN/.claude/worktrees"

# Backdate everything: the staleness branch only runs for a worktree older than
# --days, and the 24h liveness window would otherwise mark all of these ACTIVE.
export GIT_AUTHOR_DATE='2024-01-15T12:00:00+0000'
export GIT_COMMITTER_DATE='2024-01-15T12:00:00+0000'
export GIT_AUTHOR_NAME='fixture' GIT_AUTHOR_EMAIL='fixture@example.invalid'
export GIT_COMMITTER_NAME='fixture' GIT_COMMITTER_EMAIL='fixture@example.invalid'

g() { git -C "$MAIN" "$@" >/dev/null 2>&1; }

git init -q --bare "$ORIGIN" >/dev/null 2>&1 || exit 1
git init -q "$MAIN" >/dev/null 2>&1 || exit 1
g symbolic-ref HEAD refs/heads/main
printf 'hello\n' > "$MAIN/README.md"
g add README.md
g commit -m 'initial'
g remote add origin "$ORIGIN"
g push -q origin main

# (a) merged AND pushed, but no tracking configuration — the conductor shape.
g branch feature-merged main
g checkout feature-merged
printf 'more\n' >> "$MAIN/README.md"
g commit -am 'work that got merged'
g checkout main
g merge --no-ff -m 'merge feature-merged' feature-merged
g push -q origin main

# (b) one commit the remote has never seen.
g branch feature-ahead main
g checkout feature-ahead
printf 'unpushed\n' > "$MAIN/new.txt"
g add new.txt
g commit -m 'not pushed anywhere'
g checkout main

# (c) nothing unpushed, but the tree is dirty.
g branch feature-dirty main

g worktree add "$WT/merged" feature-merged
g worktree add "$WT/ahead"  feature-ahead
g worktree add "$WT/dirty"  feature-dirty
printf 'uncommitted edit\n' >> "$WT/dirty/README.md"

# The premise of the whole fix: none of these branches has tracking config, so
# the old `@{u}` test fell to its else branch for all three.
for b in feature-merged feature-ahead feature-dirty; do
  if git -C "$MAIN" rev-parse --abbrev-ref "$b@{u}" >/dev/null 2>&1; then
    bad "$b has no upstream (premise of the fix)"
  else
    ok "$b has no upstream (premise of the fix)"
  fi
done

JSON="$TMP/out.json"
run_scan() {
  CLAUDE_WATCH_HOME="$TMP/watchhome" CLAUDE_WATCH_REPO_ROOTS="$TMP" \
    "$CW" worktrees --json > "$JSON" 2>/dev/null
  # A malformed document must fail loudly rather than silently answering None.
  python3 -m json.tool < "$JSON" >/dev/null 2>&1 || { bad "worktrees --json is valid JSON"; return 1; }
  ok "worktrees --json is valid JSON"
}

# <path-suffix> <field> -> value, or the literal MISSING
field() {
  python3 - "$JSON" "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for w in d["worktrees"]:
    if w["path"].endswith(sys.argv[2]):
        v = w[sys.argv[3]]
        print("true" if v is True else "false" if v is False else v)
        break
else:
    print("MISSING")
PY
}
top() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], "MISSING"))' "$JSON" "$1"; }

eq() {  # <desc> <want> <got>
  [ "$2" = "$3" ] && ok "$2 — $1" || bad "$1 (got \"$3\", wanted \"$2\")"
}

run_scan || { printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"; exit 1; }

eq "unpushed_basis is on the record" "local-remote-refs" "$(top unpushed_basis)"

# unpushed is pure git arithmetic and does not depend on liveness, so it is
# always asserted.
eq "merged+pushed, no tracking → unpushed 0" "0"  "$(field /worktrees/merged unpushed)"
eq "one commit past the remote → unpushed 1" "1"  "$(field /worktrees/ahead  unpushed)"
eq "dirty tree is still fully pushed"        "0"  "$(field /worktrees/dirty  unpushed)"
eq "dirty tree reports its one edit"         "1"  "$(field /worktrees/dirty  dirty)"

# Status depends on the lsof liveness sweep. Without one, everything is UNSAFE
# by design ("cannot verify liveness"), which is correct behaviour and not a
# regression — so skip rather than fail.
merged_reason=$(field /worktrees/merged reason)
case "$merged_reason" in
  *"verify liveness"*|*"lsof"*)
    skp "status classification (no usable lsof snapshot: $merged_reason)" ;;
  *)
    eq "merged+pushed is STALE"        "STALE"  "$(field /worktrees/merged status)"
    eq "merged+pushed is removable"    "true"   "$(field /worktrees/merged removable)"
    eq "unpushed commit is UNSAFE"     "UNSAFE" "$(field /worktrees/ahead  status)"
    eq "unpushed commit not removable" "false"  "$(field /worktrees/ahead  removable)"
    eq "dirty tree is UNSAFE"          "UNSAFE" "$(field /worktrees/dirty  status)"
    eq "dirty tree not removable"      "false"  "$(field /worktrees/dirty  removable)"

    # still_removable() re-runs the whole classification just before removal. It
    # must apply the SAME published test as the listing; when it did not, every
    # freshly-STALE worktree was refused with "changed since it was listed".
    CLAUDE_WATCH_HOME="$TMP/watchhome" CLAUDE_WATCH_REPO_ROOTS="$TMP" \
      "$CW" worktrees --remove --yes > "$TMP/remove.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] || grep -q 'changed since it was listed' "$TMP/remove.log"; then
      bad "still_removable agrees with the listing (exit $rc)"
      sed 's/^/        /' "$TMP/remove.log"
    else
      ok "still_removable agrees with the listing"
    fi
    [ -d "$WT/merged" ] && bad "the STALE worktree was actually removed" \
                        || ok  "the STALE worktree was actually removed"
    [ -d "$WT/ahead" ] && [ -d "$WT/dirty" ] \
      && ok  "UNSAFE worktrees were left alone" \
      || bad "UNSAFE worktrees were left alone"
    # git worktree remove keeps the branch — that is why widening the published
    # test cannot lose a commit.
    git -C "$MAIN" rev-parse --verify -q feature-merged >/dev/null \
      && ok  "removal kept the branch" \
      || bad "removal kept the branch"
    ;;
esac


printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]

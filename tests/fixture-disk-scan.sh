#!/usr/bin/env bash
# Fixture tests for tools/disk-scan.sh — the disk facts TSV (plan §3c).
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split unquoted
# variables, so this must be a FILE run under bash, never pasted into a shell.
#
# The scanner is pure input -> output given a synthetic tree, so everything here
# pins VALUES, not exit codes: group totals, each confidence, the paths that must
# be absent, and the exact failure strings (§9 E7, E11). The three cases that are
# not about a tree — the lock, the deadline and a failing rename — are driven
# with a fake pid, a stub `du` and a stub `mv` respectively.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCAN="$REPO/tools/disk-scan.sh"
pass=0; fail=0; skip=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skp() { skip=$((skip + 1)); printf '  \033[90mskip\033[0m  %s\n' "$1"; }

TMP=$(mktemp -d) || exit 1
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

TAB=$'\t'
NL=$'\n'
CACHE=""
OUT="$TMP/stdout"; ERR="$TMP/stderr"

# ------------------------------------------------------------------ helpers --
# Paths reach awk through ENVIRON, never -v: -v runs backslash processing, and
# these paths deliberately contain metacharacters.
dirsize() { CW_P="$1" LC_ALL=C awk -F'\t' '$1=="dir" && $2==ENVIRON["CW_P"]{print $3}' "$CACHE"; }
dirconf() { CW_P="$1" LC_ALL=C awk -F'\t' '$1=="dir" && $2==ENVIRON["CW_P"]{print $5}' "$CACHE"; }
gtot()    { CW_G="$1" LC_ALL=C awk -F'\t' '$1=="group" && $2==ENVIRON["CW_G"]{print $3}' "$CACHE"; }
gcount()  { CW_G="$1" LC_ALL=C awk -F'\t' '$1=="group" && $2==ENVIRON["CW_G"]{print $4}' "$CACHE"; }
gaff()    { CW_G="$1" LC_ALL=C awk -F'\t' '$1=="group" && $2==ENVIRON["CW_G"]{print $5}' "$CACHE"; }
noteval() { CW_N="$1" LC_ALL=C awk -F'\t' '$1=="note" && $2==ENVIRON["CW_N"]{print $3}' "$CACHE"; }
scancol() { LC_ALL=C awk -F'\t' -v n="$1" '$1=="scan"{print $n}' "$CACHE"; }   # 2=partial 3=deadline 4=scanned 5=total
volcol()  { LC_ALL=C awk -F'\t' -v n="$1" '$1=="vol"{print $n}' "$CACHE"; }

eq() {  # <desc> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi
}
between() {  # <desc> <got> <lo> <hi>
  case "$2" in ''|*[!0-9]*) bad "$1 (got '$2', wanted a number)"; return ;; esac
  if [ "$2" -ge "$3" ] && [ "$2" -le "$4" ]; then ok "$1"
  else bad "$1 (got $2, wanted $3..$4)"; fi
}
absent() {  # <desc> <path>
  if [ -z "$(dirsize "$2")" ]; then ok "$1"; else bad "$1 (a dir row exists)"; fi
}

# ------------------------------------------------------------- the tree ------
# $SRC doubles as the fake HOME, so the fixed shortlist (~/Downloads,
# ~/Library/Containers, ...) is synthetic too and the run never touches the real
# home directory or its TCC-protected corners.
SRC="$TMP/home"
OLD=$(date -v-30d +%Y%m%d%H%M.%S)
kb() { dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null; }

mkdir -p "$SRC/repo/node_modules" "$SRC/repo/src" "$SRC/repo/target"
printf '{}\n' > "$SRC/repo/package.json"
kb "$SRC/repo/node_modules/big" 200
kb "$SRC/repo/src/main.c" 8
kb "$SRC/repo/target/blob" 100
touch -t "$OLD" "$SRC/repo/node_modules/big"          # idle + marker -> confirmed

mkdir -p "$SRC/active/node_modules"
printf '{}\n' > "$SRC/active/package.json"
kb "$SRC/active/node_modules/big" 150                  # fresh + marker -> likely

mkdir -p "$SRC/we ird ; dir/node_modules"
kb "$SRC/we ird ; dir/node_modules/blob" 50            # space and a ; must survive

mkdir -p "$SRC/tab${TAB}dir/node_modules"
kb "$SRC/tab${TAB}dir/node_modules/blob" 60            # a TSV cannot carry this

NLD="$SRC/nl${NL}dir"
mkdir -p "$NLD/node_modules"
kb "$NLD/node_modules/blob" 60                         # nor this

# awk's own field separator, 0x1c. Packing size/confidence/path into one array
# value and splitting on SUBSEP truncates this path to "$SRC/keep" — a real,
# different, existing directory, which a `confirmed` row would authorise
# removing. The decoy below is what such a forged row would name.
SUB=$'\034'
mkdir -p "$SRC/keep" "$SRC/keep${SUB}injected/node_modules"
kb "$SRC/keep/precious" 16
kb "$SRC/keep${SUB}injected/node_modules/blob" 40

mkdir -p "$SRC/deep/a/b/c/node_modules"
kb "$SRC/deep/a/b/c/node_modules/blob" 400             # depth 5: below the cap

mkdir -p "$SRC/Downloads"
kb "$SRC/Downloads/iso" 500

mkdir -p "$SRC/Library/Containers/app/node_modules"
kb "$SRC/Library/Containers/app/node_modules/blob" 70  # must not be counted twice

# D1a: the kind-table entry with detail_depth=2 — Library/Developer's own total
# PLUS one dir row per depth-2 grandchild (CoreSimulator/Devices, Xcode/DerivedData).
mkdir -p "$SRC/Library/Developer/CoreSimulator/Devices" "$SRC/Library/Developer/Xcode/DerivedData"
kb "$SRC/Library/Developer/CoreSimulator/Devices/blob" 300
kb "$SRC/Library/Developer/Xcode/DerivedData/blob" 250

RP=$( cd -P "$SRC" && pwd -P )                          # the scanner emits physical paths

# ------------------------------------------------------- run A: the tree -----
echo "tree"
DA="$TMP/dataA"
CACHE="$DA/state/disk.tsv"
HOME="$SRC" CLAUDE_WATCH_HOME="$DA" CLAUDE_WATCH_REPO_ROOTS="$SRC" \
  bash "$SCAN" > "$OUT" 2> "$ERR"; rcA=$?
eq "run A exits 0" "$rcA" "0"
if [ ! -f "$CACHE" ]; then
  bad "run A wrote a cache"; sed 's/^/        /' "$ERR"; exit 1
fi
ok "run A wrote a cache"

# Every row is exactly five tab-separated fields — a path that broke that rule
# would shift the numeric columns at the reader.
if LC_ALL=C awk -F'\t' 'NF != 5 { print; n++ } END { exit(n > 0) }' "$CACHE" > "$TMP/badrows"; then
  ok "every row has five fields"
else
  bad "every row has five fields"; sed 's/^/        /' "$TMP/badrows"
fi

eq "epoch row present" "$(LC_ALL=C awk -F'\t' '$1=="epoch"{print ($3 > 1600000000) ? "y" : "n"}' "$CACHE")" "y"
eq "vol row is the volume holding \$HOME" "$(volcol 2)" "$(df -k "$SRC" | awk 'NR==2 {m=$0; for (i=1;i<=8;i++) sub(/^[^ ]+[ ]+/,"",m); print m}')"
eq "df_size_kb recorded" "$(volcol 5)" "$(df -k "$SRC" | awk 'NR==2{print $2}')"

# --- sizes and counts ---
# node_modules = repo 200 + active 150 + metachar 50 + the 0x1c path 40; the tab
# and newline paths are skipped, the depth-5 one is out of reach, and the one
# under Library/Containers is deduped into the containers total.
between "node_modules group total is 440K" "$(gtot node_modules)" 440 468
eq      "node_modules counts 4 directories" "$(gcount node_modules)" "4"
between "rebuildable group total is 100K"   "$(gtot rebuildable)" 100 112
eq      "rebuildable counts 1 directory"    "$(gcount rebuildable)" "1"
between "downloads group total is 500K"     "$(gtot downloads)" 500 520
between "containers group total is 70K"     "$(gtot containers)" 70 96
# developer = the kind-table T record (the sweep's own Library/Developer row),
# not the summed H rows: CoreSimulator/Devices 300 + Xcode/DerivedData 250.
between "developer group total is 550K (the sweep's own T row)" "$(gtot developer)" 550 578
eq      "developer counts 2 directories (one per depth-2 child)" "$(gcount developer)" "2"

# --- confidence, the column that gates every removal command ---
eq "marker + idle  -> confirmed"  "$(dirconf "$RP/repo/node_modules")"      "confirmed"
eq "marker, in use -> likely"     "$(dirconf "$RP/active/node_modules")"    "likely"
eq "name only      -> unverified" "$(dirconf "$RP/repo/target")"            "unverified"
eq "no marker      -> unverified" "$(dirconf "$RP/we ird ; dir/node_modules")" "unverified"
# Sweep rows are never confirmed, exactly like the old fixed shortlist: a
# read-only tool does not get to author an rm -rf for a kind known from the path.
eq "sweep row confidence is likely (CoreSimulator/Devices)" \
   "$(dirconf "$RP/Library/Developer/CoreSimulator/Devices")" "likely"
eq "sweep row confidence is likely (Xcode/DerivedData)" \
   "$(dirconf "$RP/Library/Developer/Xcode/DerivedData")" "likely"

# --- what must not be there ---
absent "the src/ decoy is not a hit"          "$RP/repo/src"
absent "a node_modules below the depth cap is out of reach" "$RP/deep/a/b/c/node_modules"
absent "a hit under the shortlist is not double counted"    "$RP/Library/Containers/app/node_modules"
if LC_ALL=C grep -q "$TAB.*$TAB.*tab" "$CACHE"; then
  bad "the tab path never reaches the cache"
else
  ok "the tab path never reaches the cache"
fi
# A raw newline would split one row in two: a truncated "…/nl" path on the first
# line and a bare "dir/node_modules…" fragment starting the next.
absent "no truncated row for the newline path" "$RP/nl"
if LC_ALL=C grep -q '^dir/node_modules' "$CACHE"; then
  bad "no orphaned fragment from the newline path"
else
  ok "no orphaned fragment from the newline path"
fi

# --- the SUBSEP path: intact, or nowhere. Never a row for a DIFFERENT path. ---
absent "no forged row for the truncated 0x1c path" "$RP/keep"
subrow=$(dirconf "$RP/keep${SUB}injected/node_modules")
if [ -n "$subrow" ]; then
  ok "the 0x1c path round-trips intact ($subrow)"
elif [ "$(noteval path_unrepresentable)" -ge 3 ] 2>/dev/null; then
  ok "the 0x1c path was dropped as unrepresentable"
else
  bad "the 0x1c path neither round-trips nor is counted"
fi

# --- the metacharacter path survives whole, and carries no command ---
between "the space/; path is measured" "$(dirsize "$RP/we ird ; dir/node_modules")" 50 64
if LC_ALL=C grep -qE '(^|[^a-z])rm( |$)' "$CACHE"; then
  bad "the scanner emits no removal command"
else
  ok "the scanner emits no removal command"
fi

# --- partial accounting ---
eq "partial=1 (a path was skipped)"    "$(scancol 2)" "1"
eq "deadline_hit=0"                    "$(scancol 3)" "0"
eq "roots_scanned=1"                   "$(scancol 4)" "1"
eq "roots_total=1"                     "$(scancol 5)" "1"
eq "note path_unrepresentable 2"       "$(noteval path_unrepresentable)" "2"
eq "no deadline note"                  "$(noteval deadline)" ""

# --- per-group `affected`: the flag that gates severity capping downstream ---
# It answers a DIFFERENT question from `partial`: this scan was partial, but only
# the group that actually lost a path is short.
eq "node_modules is affected (a path was dropped from it)" "$(gaff node_modules)" "1"
eq "rebuildable is not affected"                           "$(gaff rebuildable)" "0"
eq "downloads is not affected"                             "$(gaff downloads)" "0"
eq "developer is not affected"                             "$(gaff developer)" "0"
eq "the lock is released"              "$([ -e "$DA/state/disk-scan.lock" ] && echo present || echo gone)" "gone"
eq "no work directory is left behind"  "$(ls -d "$DA"/state/disk-scan.work.* 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- D1a: per-child sizes, and the group total against an independent measure ---
between "CoreSimulator/Devices dir row is ~300K" "$(dirsize "$RP/Library/Developer/CoreSimulator/Devices")" 300 314
between "Xcode/DerivedData dir row is ~250K"     "$(dirsize "$RP/Library/Developer/Xcode/DerivedData")" 250 264
indep_dev=$(du -skx "$RP/Library/Developer" 2>/dev/null | awk '{print $1}')
eq "developer total equals an independent du -skx of that path" "$(gtot developer)" "$indep_dev"

# --- D1a: per group, dir rows can never sum past the group total ---
if LC_ALL=C awk -F'\t' '
    $1=="group" { tot[$2]=$3+0 }
    $1=="dir"   { sum[$4]+=$3+0 }
    END { bad=0; for (g in sum) if (sum[g] > tot[g]) { print g, sum[g], tot[g]; bad=1 }; exit bad
  }' "$CACHE" > "$TMP/sumcheck"; then
  ok "per-group dir row sizes never exceed the group total"
else
  bad "per-group dir row sizes never exceed the group total"; sed 's/^/        /' "$TMP/sumcheck"
fi

# --- D1a: T is a worker record only, and never leaks into the cache ---
if LC_ALL=C awk -F'\t' '$1=="T"||$1=="H"||$1=="A"||$1=="S"||$1=="V"||$1=="U"||$1=="D"||$1=="Z"{print; f=1} END{exit !f}' \
     "$CACHE" > "$TMP/wkrows"; then
  bad "no cache line begins with a worker-record kind"; sed 's/^/        /' "$TMP/wkrows"
else
  ok "no cache line begins with a worker-record kind"
fi

# --- D1a: the parts-<=-whole guard has nothing to say about a correct run ---
if grep -q 'exceed the volume used' "$ERR"; then
  bad "the parts-<=-whole guard is silent on a real run"; sed 's/^/        /' "$ERR"
else
  ok "the parts-<=-whole guard is silent on a real run"
fi

# ------------------------------------------- run B: a clean tree, no notes ---
echo "clean scan"
DB="$TMP/dataB"; HB="$TMP/homeB"; mkdir -p "$HB"
CACHE="$DB/state/disk.tsv"
HOME="$HB" CLAUDE_WATCH_HOME="$DB" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
eq "partial=0 when nothing was skipped" "$(scancol 2)" "0"
eq "no note rows"                       "$(LC_ALL=C grep -c '^note' "$CACHE" || true)" "0"
eq "repo/node_modules still confirmed"  "$(dirconf "$RP/repo/node_modules")" "confirmed"

# ------------------------------------------- a root on another volume --------
echo "root on another volume"
OTHER=""
for cand in /System/Volumes/Preboot /System/Volumes/VM /System/Volumes/Update /Volumes/*; do
  [ -d "$cand" ] || continue
  [ "$(stat -f %d "$cand")" = "$(stat -f %d "$HB")" ] && continue
  OTHER="$cand"; break
done
if [ -n "$OTHER" ]; then
  DC="$TMP/dataC"; CACHE="$DC/state/disk.tsv"
  HOME="$HB" CLAUDE_WATCH_HOME="$DC" CLAUDE_WATCH_REPO_ROOTS="$OTHER:$SRC/repo" \
    bash "$SCAN" > "$OUT" 2> "$ERR"
  eq "the off-volume root is skipped" "$(noteval root_off_home_volume)" "1"
  eq "roots_scanned=1 of 2"           "$(scancol 4)" "1"
  eq "roots_total=2"                  "$(scancol 5)" "2"
  eq "partial=1"                      "$(scancol 2)" "1"
else
  # A visible, reasoned skip: on a machine with one volume this cannot be pinned,
  # and passing silently would claim coverage the run did not have.
  skp "root on another volume — no directory with a device id different from \$HOME's exists here (tried /System/Volumes/{Preboot,VM,Update} and /Volumes/*)"
fi

# ------------------------------------------ an unreadable directory (E9) -----
# A directory we could not read is not idle, is not measured, and must never be
# promoted: no row at all beats a wrong `confirmed`.
echo "unreadable directory"
UR="$TMP/unreadable"
mkdir -p "$UR/locked/node_modules" "$UR/open/node_modules" "$UR/open/target"
printf '{}\n' > "$UR/locked/package.json"
printf '{}\n' > "$UR/open/package.json"
kb "$UR/locked/node_modules/blob" 80
kb "$UR/open/node_modules/blob" 90
kb "$UR/open/target/blob" 70
touch -t "$OLD" "$UR/locked/node_modules/blob" "$UR/open/node_modules/blob" "$UR/open/target/blob"
chmod 000 "$UR/locked/node_modules"
URP=$( cd -P "$UR" && pwd -P )
DU2="$TMP/dataU"; CACHE="$DU2/state/disk.tsv"
HOME="$HB" CLAUDE_WATCH_HOME="$DU2" CLAUDE_WATCH_REPO_ROOTS="$UR" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
chmod 755 "$UR/locked/node_modules"
absent "an unreadable directory gets no dir row at all" "$URP/locked/node_modules"
eq "the readable sibling is still confirmed" "$(dirconf "$URP/open/node_modules")" "confirmed"
if [ "$(noteval permission_denied)" -ge 1 ] 2>/dev/null; then
  ok "note permission_denied is recorded"
else
  bad "note permission_denied is recorded (got '$(noteval permission_denied)')"
fi
eq "partial=1 after a denial"                   "$(scancol 2)" "1"
eq "the denied group is affected"               "$(gaff node_modules)" "1"
eq "the group that read cleanly is not"         "$(gaff rebuildable)" "0"

# ------------------------------------- a failing idle probe never promotes ---
# find can fail where du succeeded. Empty output from a failed probe is not
# evidence of idleness, and reading it as such hands out a removal command for a
# directory nobody could inspect.
echo "failing idle probe"
FBIN="$TMP/fbin"; mkdir -p "$FBIN"
{
  printf '#!/bin/sh\n'
  printf 'for a in "$@"; do [ "$a" = "-newer" ] && exit 1; done\n'
  printf 'exec /usr/bin/find "$@"\n'
} > "$FBIN/find"
chmod +x "$FBIN/find"
DF="$TMP/dataF"; CACHE="$DF/state/disk.tsv"
PATH="$FBIN:$PATH" HOME="$HB" CLAUDE_WATCH_HOME="$DF" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
eq "a marker-bearing hit stays likely when the probe fails" \
   "$(dirconf "$RP/repo/node_modules")" "likely"
eq "and its group is marked affected" "$(gaff node_modules)" "1"
# Anything that shortened a group shortened the scan: `partial` must follow the
# affected flag, not just the five note reasons.
eq "and the scan is partial"          "$(scancol 2)" "1"

# A discovery walk can come back non-zero having printed NOTHING. Noticing only
# stderr leaves that partial walk looking complete.
echo "silently non-zero discovery"
QBIN="$TMP/qbin"; mkdir -p "$QBIN"
{
  printf '#!/bin/sh\n'
  printf 'for a in "$@"; do [ "$a" = "-print0" ] && { /usr/bin/find "$@"; exit 1; }; done\n'
  printf 'exec /usr/bin/find "$@"\n'
} > "$QBIN/find"
chmod +x "$QBIN/find"
DQ="$TMP/dataQ"; CACHE="$DQ/state/disk.tsv"
PATH="$QBIN:$PATH" HOME="$HB" CLAUDE_WATCH_HOME="$DQ" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
eq "the hits it did find are still measured" \
   "$([ -n "$(dirsize "$RP/repo/node_modules")" ] && echo yes || echo no)" "yes"
eq "but neither repo group claims completeness" "$(gaff node_modules)$(gaff rebuildable)" "11"
eq "and the scan is partial"                    "$(scancol 2)" "1"

# --------------------------------------- freshness is recursive, not depth-1 --
# node_modules/pkg/lib/active.js written this morning inside a months-old `pkg`
# is a directory in active use. A depth-1 probe sees only `pkg`, calls it idle,
# and hands out a removal command for a directory being worked in.
echo "recursive idle probe"
DEEP="$TMP/deep"
mkdir -p "$DEEP/fresh/node_modules/pkg/lib" "$DEEP/idle/node_modules/pkg/lib"
printf '{}\n' > "$DEEP/fresh/package.json"
printf '{}\n' > "$DEEP/idle/package.json"
kb "$DEEP/fresh/node_modules/pkg/lib/active.js" 8
kb "$DEEP/idle/node_modules/pkg/lib/old.js" 8
# Backdate every directory AND the idle tree's file, leaving exactly one fresh
# file, four levels down, in the tree that must not be promoted.
touch -t "$OLD" "$DEEP/idle/node_modules/pkg/lib/old.js"
for d in "$DEEP/fresh/node_modules/pkg/lib" "$DEEP/fresh/node_modules/pkg" "$DEEP/fresh/node_modules" \
         "$DEEP/idle/node_modules/pkg/lib"  "$DEEP/idle/node_modules/pkg"  "$DEEP/idle/node_modules"; do
  touch -t "$OLD" "$d"
done
DEEPP=$( cd -P "$DEEP" && pwd -P )
DP="$TMP/dataP"; CACHE="$DP/state/disk.tsv"
HOME="$HB" CLAUDE_WATCH_HOME="$DP" CLAUDE_WATCH_REPO_ROOTS="$DEEP" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
eq "a deep fresh file blocks promotion" \
   "$(dirconf "$DEEPP/fresh/node_modules")" "likely"
eq "a deep but idle tree is still confirmed" \
   "$(dirconf "$DEEPP/idle/node_modules")" "confirmed"

# ------------------------------------------ a root that cannot be entered ----
# A mode-000 root passes `[ -d ]` and then fails to resolve. Counting it as
# scanned would emit affected=0 on a group whose measurement is missing whatever
# that root held — a short number wearing full confidence.
echo "unenterable root"
BLK="$TMP/blocked"; mkdir -p "$BLK/node_modules"; chmod 000 "$BLK"
DK="$TMP/dataK"; CACHE="$DK/state/disk.tsv"
HOME="$HB" CLAUDE_WATCH_HOME="$DK" CLAUDE_WATCH_REPO_ROOTS="$BLK:$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
chmod 755 "$BLK"
eq "an unenterable root does not count as scanned" "$(scancol 4)" "1"
eq "roots_total still counts it"                   "$(scancol 5)" "2"
eq "partial=1"                                     "$(scancol 2)" "1"
eq "node_modules cannot claim completeness"        "$(gaff node_modules)" "1"
eq "rebuildable cannot either"                     "$(gaff rebuildable)" "1"

# ------------------------------- kind table: no double counting (developer) --
# A node_modules planted ONE level below Library/Developer, reachable by find
# (repo root == $HOME here, so find walks the whole tree, same shape as run A)
# but off the tracked depth-2 (so the sweep folds it into the developer total,
# never its own dir row). It must not ALSO become a node_modules group hit —
# proving the kind table's CLAIM registration, BEFORE the repo roots, dedups it.
echo "kind table: no double counting (developer)"
DVH="$TMP/homeDev"
mkdir -p "$DVH/Library/Developer/node_modules"
kb "$DVH/Library/Developer/node_modules/blob" 90
DDV="$TMP/dataDev"; CACHE="$DDV/state/disk.tsv"
HOME="$DVH" CLAUDE_WATCH_HOME="$DDV" CLAUDE_WATCH_REPO_ROOTS="$DVH" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
DVHP=$( cd -P "$DVH" && pwd -P )
absent "a node_modules under Library/Developer is not a dir row anywhere" \
  "$DVHP/Library/Developer/node_modules"
eq "and it produced no node_modules group at all" "$(gtot node_modules)" ""

# ------------------------------------- kind table: per-denial attribution ----
# A mode-000 directory under Library/Containers must affect ONLY containers —
# never developer, node_modules or rebuildable, which the denial says nothing
# about. The repo root is deliberately $SRC/repo, NOT this $HOME, so the
# unrelated repo-root `find` pass never touches the blocked directory itself
# (that would trip its own pre-existing blanket-taint path and prove nothing
# about the sweep's OWN per-denial attribution, which is what this covers).
echo "kind table: per-denial attribution (containers)"
DHOME="$TMP/homeDenial"
mkdir -p "$DHOME/Library/Containers/app" "$DHOME/Library/Developer/Xcode/DerivedData" \
         "$DHOME/Library/Containers/blocked"
kb "$DHOME/Library/Containers/app/blob" 40
kb "$DHOME/Library/Developer/Xcode/DerivedData/blob" 30
chmod 000 "$DHOME/Library/Containers/blocked"
DDH="$TMP/dataDenial"; CACHE="$DDH/state/disk.tsv"
HOME="$DHOME" CLAUDE_WATCH_HOME="$DDH" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
chmod 755 "$DHOME/Library/Containers/blocked"
eq "a denial under Containers affects only containers" "$(gaff containers)" "1"
eq "developer is not affected by an unrelated denial"   "$(gaff developer)" "0"
eq "node_modules is not affected either"                "$(gaff node_modules)" "0"
eq "rebuildable is not affected either"                 "$(gaff rebuildable)" "0"

# --------------------------------------------------------------- the lock ----
echo "lock"
DL="$TMP/dataL"; mkdir -p "$DL/state"
LOCK="$DL/state/disk-scan.lock"
CACHE="$DL/state/disk.tsv"

# The owner file is ONE atomic file: line 1 pid, line 2 identity.
ident() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }
own()   { printf '%s\n%s\n' "$1" "$2"; }

# 1. a live owner: the loser prints E11 and never scans.
mkdir "$LOCK"; own "$$" "$(ident "$$")" > "$LOCK/pid"
HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"; rcL=$?
eq "a held lock exits 0" "$rcL" "0"
if grep -qF 'another disk scan is already running — nothing cached yet; re-run in a minute.' "$ERR"; then
  ok "E11 (no cache) verbatim on stderr"
else
  bad "E11 (no cache) verbatim on stderr"; sed 's/^/        /' "$ERR"
fi
eq "the loser wrote no cache" "$([ -f "$CACHE" ] && echo wrote || echo none)" "none"
eq "the loser did not take the lock" "$(sed -n 1p "$LOCK/pid")" "$$"

# 1b. same, with a cache present: the message names its age.
printf 'epoch\t-\t1\t-\t-\n' > "$CACHE"
HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
if grep -qE '^another disk scan is already running — using the cached facts from [0-9]+[mhd] ago\. Re-run in a minute for fresh numbers\.$' "$ERR"; then
  ok "E11 (cached) verbatim on stderr"
else
  bad "E11 (cached) verbatim on stderr"; sed 's/^/        /' "$ERR"
fi
eq "the loser left the cache alone" "$(wc -l < "$CACHE" | tr -d ' ')" "1"

# 2. a young lock whose owner is dead is NOT broken: only age AND a dead pid.
DEAD=$( bash -c 'echo $$' )    # a pid that has already exited
if kill -0 "$DEAD" 2>/dev/null; then
  skp "stale lock (pid $DEAD was recycled)"
else
  own "$DEAD" 'Thu Jan 1 00:00:00 1970' > "$LOCK/pid"
  HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
    bash "$SCAN" > "$OUT" 2> "$ERR"
  eq "a young lock is kept even with a dead owner" "$(sed -n 1p "$LOCK/pid")" "$DEAD"

  # 3. old AND dead: broken, and the scan runs.
  touch -t "$OLD" "$LOCK"
  HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
    bash "$SCAN" > "$OUT" 2> "$ERR"; rcS=$?
  eq "a stale lock with a dead owner is broken" "$rcS" "0"
  eq "and the scan actually ran" "$(dirconf "$RP/repo/node_modules")" "confirmed"
  eq "and the lock is released" "$([ -e "$LOCK" ] && echo present || echo gone)" "gone"
fi

# 4. PID REUSE. An old lock whose pid has been recycled onto an unrelated
# process answers kill -0 forever, so a liveness-only breaker never fires and
# every later run silently serves a stale cache. The owner's start time is what
# tells the two processes apart.
rm -rf "$LOCK"; mkdir "$LOCK"
# a pid that is very much alive, recorded as a process that is not this one
own "$$" 'Thu Jan 1 00:00:00 1970' > "$LOCK/pid"
touch -t "$OLD" "$LOCK"
HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
eq "a recycled pid does not keep a stale lock alive" \
   "$([ -e "$LOCK" ] && echo present || echo gone)" "gone"

# 4b. INCOMPLETE METADATA ON A LIVE OWNER. Breaking a live owner's lock puts two
# scanners on the same disk, so anything short of positive evidence of death has
# to keep it. Both shapes an interrupted write could leave behind:
for shape in truncated empty; do
  rm -rf "$LOCK"; mkdir "$LOCK"
  case "$shape" in
    truncated) printf '%s\n' "$$" > "$LOCK/pid" ;;   # pid, no identity yet
    empty)     : > "$LOCK/pid" ;;                    # nothing at all
  esac
  touch -t "$OLD" "$LOCK"
  HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
    bash "$SCAN" > "$OUT" 2> "$ERR"
  case "$shape" in
    truncated)
      eq "a live owner with $shape metadata keeps its lock" \
         "$([ -e "$LOCK" ] && echo present || echo gone)" "present" ;;
    empty)
      # No pid at all is the crashed-before-writing case: nothing to test for
      # liveness, so the age limit is all there is and the lock must be broken —
      # otherwise a killed first scan wedges every later run forever.
      eq "a stale lock with no owner recorded is broken" \
         "$([ -e "$LOCK" ] && echo present || echo gone)" "gone" ;;
  esac
done

# The complement: same age, same pid, and the identity DOES match — a genuinely
# live owner that happens to be slow must keep its lock.
rm -rf "$LOCK"; mkdir "$LOCK"
own "$$" "$(ident "$$")" > "$LOCK/pid"
touch -t "$OLD" "$LOCK"
HOME="$HB" CLAUDE_WATCH_HOME="$DL" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"; rcI=$?
eq "a verified live owner keeps its lock past the age limit" \
   "$([ -e "$LOCK" ] && echo present || echo gone)" "present"
eq "and the loser still exits 0" "$rcI" "0"
if grep -q 'another disk scan is already running' "$ERR"; then
  ok "and still prints E11"
else
  bad "and still prints E11"; sed 's/^/        /' "$ERR"
fi
rm -rf "$LOCK"

# 4c. `ps lstart` is locale-formatted: ru_RU renders "четверг, 6 августа 2026 г."
# where C renders "Thu Aug 6 2026". doctor derives the identity itself and
# compares it against the file the scanner wrote, so if the two disagree about
# locale, doctor calls a perfectly healthy running scan an orphan.
OTHERLOC=""
for L in ru_RU.UTF-8 de_DE.UTF-8 fr_FR.UTF-8; do
  [ "$(LC_ALL=$L ps -o lstart= -p $$ 2>/dev/null | tr -s ' ')" != "$(ident "$$")" ] || continue
  OTHERLOC=$L; break
done
if [ -n "$OTHERLOC" ]; then
  DZ="$TMP/dataZ"; mkdir -p "$DZ/state"
  mkdir "$DZ/state/disk-scan.lock"
  own "$$" "$(ident "$$")" > "$DZ/state/disk-scan.lock/pid"
  printf 'epoch\t-\t1\t-\t-\n' > "$DZ/state/disk.tsv"
  # Doctor's output goes to a FILE first. Under `set -o pipefail` an
  # `if doctor | grep -q ...` can never reach its failure branch: doctor exits
  # non-zero whenever any check fails, which poisons the pipeline status
  # regardless of what grep found — an assertion that always passes.
  LC_ALL="$OTHERLOC" LANG="$OTHERLOC" CLAUDE_WATCH_HOME="$DZ" \
    bash "$REPO/claude-watch" doctor > "$TMP/doctor.out" 2>/dev/null
  if grep -q 'orphaned scan lock' "$TMP/doctor.out"; then
    bad "doctor under $OTHERLOC does not call a live lock orphaned"
    grep 'disk cache' "$TMP/doctor.out" | sed 's/^/        /'
  else
    ok "doctor under $OTHERLOC does not call a live lock orphaned"
  fi
  rm -rf "$DZ"
else
  skp "locale-sensitive identity — no installed locale renders ps lstart differently from C"
fi

# 4d. doctor's own liveness check must not read an EMPTY pid record as
# healthy. `kill -0 "${dpid:-0}"` used to fall back to pid 0 when the record
# was empty, and pid 0 signals the CALLER's own process group — always alive —
# so a lock record that crashed before writing anything read as a live,
# healthy scan (A4).
DE="$TMP/dataE"; mkdir -p "$DE/state"
mkdir "$DE/state/disk-scan.lock"
: > "$DE/state/disk-scan.lock/pid"
printf 'epoch\t-\t1\t-\t-\n' > "$DE/state/disk.tsv"
CLAUDE_WATCH_HOME="$DE" bash "$REPO/claude-watch" doctor > "$TMP/doctorE.out" 2>/dev/null
if grep -q 'orphaned scan lock' "$TMP/doctorE.out"; then
  ok "doctor treats an empty pid record as an orphaned lock, not kill -0 0"
else
  bad "doctor treats an empty pid record as an orphaned lock, not kill -0 0"
  sed 's/^/        /' "$TMP/doctorE.out"
fi
rm -rf "$DE"

# 4e. take_lock can fail to write $LOCK/pid even though the mkdir that claims
# the lock just succeeded (a full or read-only volume). acquire_lock used to
# return 0 unconditionally in that case, leaving an ownerless lock directory
# behind and letting the scan proceed with no record of who holds it (A4). A
# stub `mkdir` simulates the race: it creates the real directory, then strips
# write permission from it before disk-scan.sh gets to write the pid file.
SBINM="$TMP/sbinM"; mkdir -p "$SBINM"
# Logs every single-argument (i.e. lock-directory) mkdir attempt to
# $MKDIR_LOG when the caller sets it, so 4f below can prove which mkdir call
# it actually reached — see 4f for why that matters.
cat > "$SBINM/mkdir" <<'EOF'
#!/bin/sh
if [ "$#" = 1 ]; then
  [ -n "${MKDIR_LOG:-}" ] && printf '%s\n' "$1" >> "$MKDIR_LOG"
  /bin/mkdir "$1" && chmod 555 "$1"
  exit $?
fi
exec /bin/mkdir "$@"
EOF
chmod +x "$SBINM/mkdir"
DM="$TMP/dataM"
PATH="$SBINM:$PATH" HOME="$HB" CLAUDE_WATCH_HOME="$DM" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"; rcM=$?
eq "a lock-record write failure is reported, not silently accepted" "$rcM" "1"
if grep -qF 'could not write' "$ERR"; then
  ok "and it prints the E7 write-failure message"
else
  bad "and it prints the E7 write-failure message"; sed 's/^/        /' "$ERR"
fi
eq "no cache is written on a lock-record write failure" \
   "$([ -f "$DM/state/disk.tsv" ] && echo wrote || echo none)" "none"
eq "the ownerless lock is not left behind" \
   "$([ -e "$DM/state/disk-scan.lock" ] && echo present || echo gone)" "gone"

# 4f. The SAME take_lock failure, but on the STALE-LOCK REPLACEMENT branch:
# acquire_lock recreates $LOCK after breaking a stale, dead-owner lock (the
# second `mkdir "$LOCK"`, past the `mv "$LOCK" "$stash"` rename) and got the
# identical fall-through-to-die_write fix as the fresh-lock path above (A4).
# Seed a stale dead-owner lock so acquire_lock takes the breaker path instead
# of the fresh-mkdir path, then reuse the same write-stripping mkdir stub.
DEAD2=$( bash -c 'echo $$' )    # a pid that has already exited
if kill -0 "$DEAD2" 2>/dev/null; then
  skp "stale-replacement lock-write failure (pid $DEAD2 was recycled)"
else
  DF="$TMP/dataN"; mkdir -p "$DF/state"
  LOCKF="$DF/state/disk-scan.lock"
  mkdir "$LOCKF"
  own "$DEAD2" 'Thu Jan 1 00:00:00 1970' > "$LOCKF/pid"
  touch -t "$OLD" "$LOCKF"
  MKLOG="$TMP/mkdir-stale.log"; : > "$MKLOG"
  PATH="$SBINM:$PATH" HOME="$HB" CLAUDE_WATCH_HOME="$DF" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
    MKDIR_LOG="$MKLOG" \
    bash "$SCAN" > "$OUT" 2> "$ERR"; rcF=$?
  eq "a lock-record write failure on the stale-replacement path is reported too" "$rcF" "1"
  if grep -qF 'could not write' "$ERR"; then
    ok "and it prints the E7 write-failure message on that path"
  else
    bad "and it prints the E7 write-failure message on that path"; sed 's/^/        /' "$ERR"
  fi
  eq "no cache is written on that path either" \
     "$([ -f "$DF/state/disk.tsv" ] && echo wrote || echo none)" "none"
  eq "the ownerless lock is not left behind on that path either" \
     "$([ -e "$LOCKF" ] && echo present || echo gone)" "gone"
  # The two assertions above also pass if acquire_lock treated the FIRST
  # mkdir's failure (the lock dir already existing) as a generic write
  # failure and bailed without ever breaking the stale lock — same message,
  # same exit code, same absence of a cache, and the pre-existing $LOCKF is
  # gone-by-die_write's own rm either way. That would prove nothing about the
  # stale-REPLACEMENT branch (line 178's mkdir) specifically. The mkdir log
  # is the actual evidence: it must show two attempts against $LOCKF — the
  # initial one that failed because the stale lock was still there, and the
  # post-break recreate that this test is really about.
  n_mkdir=$(grep -cxF "$LOCKF" "$MKLOG" 2>/dev/null); n_mkdir=${n_mkdir:-0}
  [ "$n_mkdir" -ge 2 ] && ok "the stale lock was actually broken and recreated (mkdir attempted $n_mkdir times)" \
                       || bad "the stale lock was actually broken and recreated (mkdir attempted $n_mkdir time(s) — the replacement branch was never reached)"
fi

# 5. A REAL race: two scanners, same state directory, overlapping in time.
# The first is slowed with a stub du so the second is guaranteed to arrive while
# it holds the lock.
echo "two scanners at once"
SBIN="$TMP/sbin"; mkdir -p "$SBIN"
printf '#!/bin/sh\nsleep 3\nexec /usr/bin/du "$@"\n' > "$SBIN/du"
chmod +x "$SBIN/du"
DX="$TMP/dataX"; CACHE="$DX/state/disk.tsv"
( PATH="$SBIN:$PATH" HOME="$HB" CLAUDE_WATCH_HOME="$DX" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
    bash "$SCAN" > "$TMP/outA" 2> "$TMP/errA" ) &
racer=$!
sleep 1
HOME="$HB" CLAUDE_WATCH_HOME="$DX" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"; rcB=$?
wait "$racer"
eq "the second scanner exits 0" "$rcB" "0"
if grep -q 'another disk scan is already running' "$ERR"; then
  ok "the second scanner refuses with E11"
else
  bad "the second scanner refuses with E11"; sed 's/^/        /' "$ERR"
fi
eq "the second scanner scanned nothing" "$(wc -c < "$OUT" | tr -d ' ')" "0"
eq "the first scanner's cache is complete" "$(dirconf "$RP/repo/node_modules")" "confirmed"
eq "no lock survives the race" \
   "$([ -e "$DX/state/disk-scan.lock" ] && echo present || echo gone)" "gone"

# 6. A scanner that LOST its lock must not delete the winner's. Otherwise the
# breaker and the next run both scan — the concurrency the lock exists to stop.
echo "a lost lock is not deleted on the way out"
DY="$TMP/dataY"; mkdir -p "$DY/state"
YLOCK="$DY/state/disk-scan.lock"
( PATH="$SBIN:$PATH" HOME="$HB" CLAUDE_WATCH_HOME="$DY" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
    bash "$SCAN" > "$TMP/outY" 2> "$TMP/errY" ) &
slow=$!
sleep 1
eq "the slow scanner took the lock" "$([ -d "$YLOCK" ] && echo yes || echo no)" "yes"
rm -rf "$YLOCK"; mkdir "$YLOCK"          # a breaker replaces it mid-scan
own 999999 'Thu Jan 1 00:00:00 1970' > "$YLOCK/pid"
wait "$slow"
eq "the replacement lock survives the loser's cleanup" \
   "$([ -d "$YLOCK" ] && echo present || echo gone)" "present"
eq "and it still belongs to the replacement" "$(sed -n 1p "$YLOCK/pid")" "999999"
rm -rf "$YLOCK"

# ----------------------------------------------------------- the deadline ----
# `timeout` is unavailable, so the deadline is the parent signalling the walk's
# own process group. A stub `du` that sleeps proves both halves: the parent
# returns on time AND the blocked worker is actually killed.
echo "deadline"
BIN="$TMP/bin"; mkdir -p "$BIN"
{
  printf '#!/bin/sh\n'
  printf 'touch %s/du-started\n' "$TMP"
  printf 'sleep 4\n'
  printf 'touch %s/du-survived\n' "$TMP"
  printf 'exec /usr/bin/du "$@"\n'
} > "$BIN/du"
chmod +x "$BIN/du"
DD="$TMP/dataD"; CACHE="$DD/state/disk.tsv"
t0=$(date +%s)
PATH="$BIN:$PATH" HOME="$HB" CLAUDE_WATCH_HOME="$DD" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  CLAUDE_WATCH_DISK_DEADLINE=2 bash "$SCAN" > "$OUT" 2> "$ERR"; rcD=$?
t1=$(date +%s)
eq "the deadline run exits 0" "$rcD" "0"
between "it returns near the deadline" "$(( t1 - t0 ))" 2 8
eq "the cache is still written" "$([ -f "$CACHE" ] && echo yes || echo no)" "yes"
eq "deadline_hit=1" "$(scancol 3)" "1"
eq "partial=1"      "$(scancol 2)" "1"
eq "note deadline"  "$(noteval deadline)" "1"
eq "the volume facts survive the deadline" "$([ -n "$(volcol 3)" ] && echo yes || echo no)" "yes"
eq "the walk really did block in du" \
   "$([ -e "$TMP/du-started" ] && echo yes || echo no)" "yes"
sleep 5
eq "the blocked worker was killed, not orphaned" \
   "$([ -e "$TMP/du-survived" ] && echo survived || echo killed)" "killed"
eq "the lock is released after a deadline" \
   "$([ -e "$DD/state/disk-scan.lock" ] && echo present || echo gone)" "gone"

# -------------------------------------------------------- the atomic write ---
# The temp file must be created next to the cache: a temp on another volume
# makes the final mv a copy, not a rename.
echo "atomic write"
MVBIN="$TMP/mvbin"; mkdir -p "$MVBIN"
{
  printf '#!/bin/sh\n'
  printf 'printf "%%s\\n" "$1" >> %s/mv.log\n' "$TMP"
  printf 'if [ -n "${CW_TEST_MV_FAIL:-}" ]; then exit 1; fi\n'
  printf 'exec /bin/mv "$@"\n'
} > "$MVBIN/mv"
chmod +x "$MVBIN/mv"
DM="$TMP/dataM"; CACHE="$DM/state/disk.tsv"
PATH="$MVBIN:$PATH" HOME="$HB" CLAUDE_WATCH_HOME="$DM" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"
eq "the temp file is created in \$STATE" "$(dirname "$(tail -n1 "$TMP/mv.log")")" "$DM/state"
eq "the cache landed" "$([ -f "$CACHE" ] && echo yes || echo no)" "yes"

# A failing rename is reported with E7 and exit 1, never swallowed into a
# silently retained stale cache.
before=$(cksum < "$CACHE")
PATH="$MVBIN:$PATH" CW_TEST_MV_FAIL=1 HOME="$HB" CLAUDE_WATCH_HOME="$DM" \
  CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" bash "$SCAN" > "$OUT" 2> "$ERR"; rcM=$?
eq "a failing rename exits 1" "$rcM" "1"
if grep -qF "claude-watch disk: could not write $CACHE — the volume is 95% full or the path is read-only. The previous cache is unchanged and is now stale. Free space, then re-run: claude-watch disk --refresh" "$ERR"; then
  ok "E7 verbatim on stderr"
else
  bad "E7 verbatim on stderr"; sed 's/^/        /' "$ERR"
fi
eq "the previous cache is unchanged" "$(cksum < "$CACHE")" "$before"
eq "no temp file is left behind" \
   "$(ls -A "$DM"/state/.disk.tsv.* 2>/dev/null | wc -l | tr -d ' ')" "0"

# A read-only state directory cannot be written at all — same message, exit 1.
echo "read-only state"
DR="$TMP/dataR"; mkdir -p "$DR/state"; CACHE="$DR/state/disk.tsv"
chmod 555 "$DR/state"
HOME="$HB" CLAUDE_WATCH_HOME="$DR" CLAUDE_WATCH_REPO_ROOTS="$SRC/repo" \
  bash "$SCAN" > "$OUT" 2> "$ERR"; rcR=$?
chmod 755 "$DR/state"
eq "a read-only \$STATE exits 1" "$rcR" "1"
if grep -qF "claude-watch disk: could not write $CACHE" "$ERR"; then
  ok "E7 names the cache it could not write"
else
  bad "E7 names the cache it could not write"; sed 's/^/        /' "$ERR"
fi

# ------------------------------------------------------------------ summary --
printf '\n  %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]

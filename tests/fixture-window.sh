#!/usr/bin/env bash
# Fixture tests for the advise window reader, the shared scalars and the
# emitter's contract (advise-plan §3a, §3e, §4, §9).
#
# The shebang is load-bearing (handoff §4.15): zsh does not word-split unquoted
# variables, so this must be a FILE run under bash, never pasted into a shell.
#
# The window reader is the piece every other advise number is divided by. Two
# derivations of observed_seconds in one JSON document can disagree, so the
# assertions below pin the exported scalars AGAINST the emitted JSON rather than
# checking each in isolation — an agreement test, not two spot checks.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CW="$REPO/claude-watch"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "fixture-window: python3 required"; exit 1; }
command -v gzip    >/dev/null 2>&1 || { echo "fixture-window: gzip required";    exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

NOW=$(date +%s)
DAY0=$(date -v-0d +%F)   # today
DAY1=$(date -v-1d +%F)
DAY2=$(date -v-2d +%F)
DAY3=$(date -v-3d +%F)

# sys row, schema 1 (NF=8): ep sys - load used_kb free_kb swap_mb ncpu
sys1() { printf '%s\tsys\t-\t1.50\t100000\t900000\t0\t14\n' "$1"; }
# sys row, schema 2 (NF=13): ... $9=2 pageins pageouts memsize_kb swap_cap_mb
sys2() { printf '%s\tsys\t-\t1.50\t100000\t900000\t0\t14\t2\t10\t20\t25165824\t2048\n' "$1"; }

# --------------------------------------------------------------- helpers ---
# One advise run in a sandbox: JSON to $J, exported scalars to $S, stderr to $E.
run_advise() {  # <home> <window...>
  local home=$1; shift
  J="$TMP/out.json"; S="$TMP/scalars"; E="$TMP/err"
  CLAUDE_WATCH_HOME="$home" CLAUDE_WATCH_DISK_CACHE="$home/state/nonexistent.tsv" \
    CW_SCALARS_OUT="$S" "$CW" advise "$@" --json > "$J" 2>"$E"
  RC=$?
}
jq_() { python3 -c "import json,sys; d=json.load(open('$J')); print($1)" 2>/dev/null; }
scalar() { LC_ALL=C awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2) }' "$S"; }

expect() {  # <desc> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi
}

# =========================================================== 1. cutoffs =====
# Planted: 3 samples today at 30s spacing, 2 samples yesterday, 2 on DAY2
# (gzipped), 2 on DAY3. A 24h window must select today + the part of yesterday
# inside the cutoff; a week window must select all four days in order.
H1="$TMP/h1"; mkdir -p "$H1/raw"
{ sys1 $((NOW - 60)); sys1 $((NOW - 30)); sys1 "$NOW"; } > "$H1/raw/$DAY0.tsv"
{ sys1 $((NOW - 86400 + 60)); sys1 $((NOW - 86400 + 90)); } > "$H1/raw/$DAY1.tsv"
{ sys1 $((NOW - 172800)); sys1 $((NOW - 172800 + 30)); } > "$TMP/d2.tsv"
gzip -c "$TMP/d2.tsv" > "$H1/raw/$DAY2.tsv.gz"
{ sys1 $((NOW - 259200)); sys1 $((NOW - 259200 + 30)); } > "$H1/raw/$DAY3.tsv"

run_advise "$H1" --window 24h
expect "24h: exit 0"                      "$RC" 0
expect "24h: selects exactly the 5 rows inside the cutoff" "$(jq_ "d['samples']")" 5
expect "24h: iv is the 30s spacing"       "$(jq_ "d['interval_seconds']")" 30
expect "24h: observed_seconds = samples x iv" "$(jq_ "d['observed_seconds'] if False else d['window']['observed_seconds']")" 150

run_advise "$H1" --window week
expect "week: reads the gzipped day too"  "$(jq_ "d['samples']")" 9
expect "week: iv still 30"                "$(jq_ "d['interval_seconds']")" 30
expect "week: observed_seconds"           "$(jq_ "d['window']['observed_seconds']")" 270
# read_seconds is newest minus oldest epoch actually read.
expect "week: read_seconds spans 3 days"  "$(jq_ "d['window']['read_seconds']")" 259200
expect "week: no failed days"             "$(jq_ "d['window']['missing_or_failed_days']")" "[]"

# Oldest row first. This observes the READER rather than re-concatenating the
# planted files in the desired order, which would only prove that `cat` respects
# its arguments. The reader itself reports every backwards epoch transition, so
# a week spanning four day files that emits no such warning is the assertion —
# and the negative case just below proves the detector is not simply mute.
if grep -q 'out-of-order' "$E"; then
  bad "week: the reader concatenates day files oldest-first"
  sed 's/^/        /' "$E"
else
  ok "week: the reader concatenates day files oldest-first"
fi
# The detector must actually fire, or the assertion above is vacuous.
HD="$TMP/hd"; mkdir -p "$HD/raw"
{ sys1 $((NOW - 30)); sys1 $((NOW - 60)); sys1 $((NOW - 90)); } > "$HD/raw/$DAY0.tsv"
run_advise "$HD" --window 24h
if grep -q 'out-of-order sample epochs' "$E"; then
  ok "out-of-order rows are reported, so the order check above is not vacuous"
else
  bad "out-of-order rows are reported, so the order check above is not vacuous"
fi
expect "out-of-order input still exits 0" "$RC" 0

# ============================================ 2. exported scalars agree =====
run_advise "$H1" --window week
expect "scalars: CW_SAMPLES matches samples"   "$(scalar CW_SAMPLES)"          "$(jq_ "d['samples']")"
expect "scalars: CW_INTERVAL_SECONDS matches"  "$(scalar CW_INTERVAL_SECONDS)" "$(jq_ "d['interval_seconds']")"
expect "scalars: CW_OBSERVED_SECONDS matches"  "$(scalar CW_OBSERVED_SECONDS)" "$(jq_ "d['window']['observed_seconds']")"
expect "scalars: CW_READ_SECONDS matches"      "$(scalar CW_READ_SECONDS)"     "$(jq_ "d['window']['read_seconds']")"
expect "scalars: CW_NCPU matches cores"        "$(scalar CW_NCPU)"             "$(jq_ "d['cores']")"
expect "scalars: CW_VOLUME_TOTAL_KB empty with no cache" "$(scalar CW_VOLUME_TOTAL_KB)" ""

# =============================================== 3. read exactly once =======
# DAY1 is present as BOTH .tsv and .tsv.gz. read_day prefers the plain file, and
# a week window crosses the gzip threshold every time — so a naive "cat every
# matching file" doubles that day's samples and halves every rate derived from
# them. The gz copy holds DIFFERENT epochs so a double read is unmissable.
H2="$TMP/h2"; mkdir -p "$H2/raw"
{ sys1 $((NOW - 60)); sys1 $((NOW - 30)); } > "$H2/raw/$DAY0.tsv"
{ sys1 $((NOW - 86400)); sys1 $((NOW - 86400 + 30)); } > "$H2/raw/$DAY1.tsv"
{ sys1 $((NOW - 86400 + 300)); sys1 $((NOW - 86400 + 330)); } > "$TMP/dup.tsv"
gzip -c "$TMP/dup.tsv" > "$H2/raw/$DAY1.tsv.gz"
run_advise "$H2" --window week
expect "dual .tsv/.tsv.gz day counted once" "$(jq_ "d['samples']")" 4
expect "dual day: no read failure"          "$(jq_ "d['window']['missing_or_failed_days']")" "[]"

# ============================================== 4. corrupt .tsv.gz (E8) =====
# A corrupt archive otherwise yields a silently short window with an
# honest-looking observed_seconds. That is the failure this whole tool exists to
# prevent, so it must surface as window_read_failed, not as fewer samples.
#
# The archive is TRUNCATED, not garbage. That distinction is the whole test:
# gzip carries its CRC and length in a trailer, so a truncated stream
# decompresses a large, perfectly valid PREFIX and only then exits non-zero. A
# reader that streams read_day straight into the pipe has already counted those
# untrusted rows into samples, interval and coverage by the time it learns the
# day was unreadable — and then reports the day as missing in the same document.
# A file of pure garbage produces no prefix and cannot catch that at all.
H3="$TMP/h3"; mkdir -p "$H3/raw"
{ sys1 $((NOW - 60)); sys1 $((NOW - 30)); } > "$H3/raw/$DAY0.tsv"
# The rows are deliberately VARIED. Five thousand identical rows deflate into a
# single block, so truncating anywhere leaves nothing decodable and the fixture
# quietly degrades into the pure-garbage case it was written to replace.
i=0
while [ "$i" -lt 5000 ]; do
  printf '%s\tsys\t-\t1.%03d\t%d\t%d\t0\t14\n' \
    $((NOW - 172800 + i * 10)) $((i % 1000)) $((100000 + i)) $((900000 - i))
  i=$((i + 1))
done > "$TMP/d2big.tsv"
gzip -c "$TMP/d2big.tsv" > "$TMP/d2big.tsv.gz"
gzsize=$(wc -c < "$TMP/d2big.tsv.gz" | tr -d ' ')
dd if="$TMP/d2big.tsv.gz" of="$H3/raw/$DAY2.tsv.gz" bs=1 count=$((gzsize * 6 / 10)) 2>/dev/null
# Prove the fixture is actually exercising the dangerous shape before asserting
# anything about it: a valid prefix on stdout AND a non-zero exit.
prefix_rows=$(gzcat "$H3/raw/$DAY2.tsv.gz" 2>/dev/null | wc -l | tr -d ' ')
gzcat "$H3/raw/$DAY2.tsv.gz" >/dev/null 2>&1 && prefix_rc=0 || prefix_rc=1
if [ "$prefix_rows" -gt 100 ] && [ "$prefix_rc" = 1 ]; then
  ok "corrupt gz: the fixture really is a truncated archive ($prefix_rows rows then a failure)"
else
  bad "corrupt gz: the fixture is not a truncated archive (rows=$prefix_rows rc=$prefix_rc)"
fi
run_advise "$H3" --window week
# The decisive assertion: not one row of that valid-looking prefix may count.
expect "corrupt gz: no row of the partial prefix is counted" "$(jq_ "d['samples']")" 2
expect "corrupt gz: coverage excludes the partial prefix too" \
       "$(jq_ "d['window']['observed_seconds']")" 60
expect "corrupt gz: exit 0"                 "$RC" 0
if grep -q 'window_read_failed' "$J"; then ok "corrupt gz: window_read_failed reported"
else bad "corrupt gz: window_read_failed reported"; fi
if grep -qF "the archive is corrupt, so this window is short by one day" "$E"; then
  ok "corrupt gz: E8 goes to stderr"
else
  bad "corrupt gz: E8 goes to stderr"; sed 's/^/        /' "$E"
fi
if python3 -c "import json;d=json.load(open('$J'));import sys;sys.exit(0 if '$DAY2' in d['window']['missing_or_failed_days'] else 1)"; then
  ok "corrupt gz: the day is listed in missing_or_failed_days"
else
  bad "corrupt gz: the day is listed in missing_or_failed_days"
fi

# ================================================== 5. zero samples =========
# --window 1h on a machine that was asleep. Distinct from "no samples at all",
# and the case where a division would produce the nan §3e forbids.
H4="$TMP/h4"; mkdir -p "$H4/raw"
{ sys1 $((NOW - 20000)); sys1 $((NOW - 19970)); } > "$H4/raw/$DAY0.tsv"
run_advise "$H4" --window 1h
expect "empty window: exit 0"               "$RC" 0
expect "empty window: samples 0"            "$(jq_ "d['samples']")" 0
expect "empty window: observed_seconds 0"   "$(jq_ "d['window']['observed_seconds']")" 0
expect "empty window: iv falls back to 10"  "$(jq_ "d['interval_seconds']")" 10
expect "empty window: cores is null"        "$(jq_ "d['cores']")" None
if grep -q 'no_samples' "$J"; then ok "empty window: no_samples reported"
else bad "empty window: no_samples reported"; fi

# ============================== 6. fewer day files than the window (E6) =====
H5="$TMP/h5"; mkdir -p "$H5/raw"
{ sys1 $((NOW - 60)); sys1 $((NOW - 30)); } > "$H5/raw/$DAY0.tsv"
{ sys1 $((NOW - 86400)); sys1 $((NOW - 86370)); } > "$H5/raw/$DAY1.tsv"
run_advise "$H5" --window month
expect "month on 2 days: requested_days 30"  "$(jq_ "d['window']['requested_days']")" 30
expect "month on 2 days: available_days 2"   "$(jq_ "d['window']['available_days']")" 2
expect "month on 2 days: covered_days 2"     "$(jq_ "d['window']['covered_days']")" 2
expect "month on 2 days: not clamped at 30d" "$(jq_ "d['window']['clamped']")" False
E6=$(CLAUDE_WATCH_HOME="$H5" CLAUDE_WATCH_DISK_CACHE="$H5/none.tsv" "$CW" advise --window month 2>/dev/null)
if printf '%s' "$E6" | grep -qF "30d requested, 2d available — the sampler has only been recording since"; then
  ok "month on 2 days: E6 banner in the human output"
else
  bad "month on 2 days: E6 banner in the human output"
fi
if printf '%s' "$E6" | grep -qF "Nothing to fix; the window widens as data accumulates"; then
  ok "month on 2 days: E6 fix clause verbatim"
else
  bad "month on 2 days: E6 fix clause verbatim"
fi
# Retention clamping is a DIFFERENT thing from "the data is younger than the ask".
CLAMP=$(CLAUDE_WATCH_HOME="$H5" CLAUDE_WATCH_DISK_CACHE="$H5/none.tsv" CLAUDE_WATCH_KEEP_DAYS=7 \
  "$CW" advise --window month --json 2>/dev/null)
if printf '%s' "$CLAMP" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["window"]["clamped"] and d["window"]["requested_days"]==7 else 1)'; then
  ok "month under KEEP_DAYS=7: clamped true, requested_days 7"
else
  bad "month under KEEP_DAYS=7: clamped true, requested_days 7"
fi
# The reader opens at most CW_MAX_WINDOW_DAYS day files. That ceiling has to
# clamp the ADVERTISED window too: `--window 100w` with a huge retention would
# otherwise report a 700-day window while reading 400 days, which is the silent
# truncation E6 exists to prevent, wearing a larger number.
BIG=$(CLAUDE_WATCH_HOME="$H5" CLAUDE_WATCH_DISK_CACHE="$H5/none.tsv" CLAUDE_WATCH_KEEP_DAYS=1000 \
  "$CW" advise --window 100w --json 2>/dev/null)
if printf '%s' "$BIG" | python3 -c '
import json, sys
d = json.load(sys.stdin)["window"]
sys.exit(0 if d["clamped"] and d["requested_days"] == 400
              and d["requested_seconds"] == 400 * 86400 else 1)'; then
  ok "100w under KEEP_DAYS=1000: clamped to the 400-day reader ceiling, and says so"
else
  bad "100w under KEEP_DAYS=1000: clamped to the 400-day reader ceiling, and says so"
  printf '%s\n' "$BIG" | python3 -c 'import json,sys; print("        ", json.load(sys.stdin)["window"])' 2>/dev/null
fi
BIGTXT=$(CLAUDE_WATCH_HOME="$H5" CLAUDE_WATCH_DISK_CACHE="$H5/none.tsv" CLAUDE_WATCH_KEEP_DAYS=1000 \
  "$CW" advise --window 100w 2>/dev/null)
if printf '%s' "$BIGTXT" | grep -qF '400-day reader ceiling'; then
  ok "100w: the human banner names the ceiling that bound, not the wrong limit"
else
  bad "100w: the human banner names the ceiling that bound, not the wrong limit"
fi

# ==================================================== 7. dead sampler =======
# leaks still scans live and disk still reads a cache, so a mostly-ok payload
# would describe a machine nobody is watching. There must be no bare all-clear.
H6="$TMP/h6"; mkdir -p "$H6/raw"
{ sys1 $((NOW - 259200)); sys1 $((NOW - 259200 + 30)); } > "$H6/raw/$DAY3.tsv"
run_advise "$H6" --window week
expect "dead sampler: sampler_ok false"     "$(jq_ "d['freshness']['sampler_ok']")" False
if grep -q 'sampler_stale' "$J"; then ok "dead sampler: sampler_stale in the reasons"
else bad "dead sampler: sampler_stale in the reasons"; fi
expect "dead sampler: primary is not ok"    "$(jq_ "d['primary']['state'] != 'ok'")" True
expect "dead sampler: primary state is not complete" \
       "$(jq_ "d['primary']['measurement_state'] != 'complete'")" True
DEAD=$(CLAUDE_WATCH_HOME="$H6" CLAUDE_WATCH_DISK_CACHE="$H6/none.tsv" "$CW" advise --window week 2>/dev/null)
if printf '%s' "$DEAD" | grep -qF "CPU and memory data are not being recorded; disk and leaks below are current. Fix: claude-watch doctor"; then
  ok "dead sampler: E3 banner verbatim"
else
  bad "dead sampler: E3 banner verbatim"; printf '%s\n' "$DEAD" | sed 's/^/        /'
fi
if printf '%s' "$DEAD" | grep -qi 'all clear\|nothing to fix here\|everything is fine'; then
  bad "dead sampler: no bare all-clear"
else
  ok "dead sampler: no bare all-clear"
fi

# ================================== 8. schema-2 scalars and cpu_basis =======
H7="$TMP/h7"; mkdir -p "$H7/raw"
{ sys1 $((NOW - 90)); sys2 $((NOW - 60)); sys2 $((NOW - 30)); } > "$H7/raw/$DAY0.tsv"
run_advise "$H7" --window 24h
expect "schema 2: CW_MEMSIZE_KB from \$12"   "$(scalar CW_MEMSIZE_KB)"  25165824
expect "schema 2: CW_SWAP_CAP_MB from \$13"  "$(scalar CW_SWAP_CAP_MB)" 2048
expect "schema 2: cpu_basis.proc cputime"    "$(jq_ "d['cpu_basis']['proc']")" cputime
expect "schema 2: cpu_basis.session estimate" "$(jq_ "d['cpu_basis']['session']")" estimate
expect "schema 2: cpu_basis_since is the first schema-2 epoch" \
       "$(jq_ "d['cpu_basis_since']")" "$((NOW - 60))"
run_advise "$H1" --window 24h
expect "schema 1 only: cpu_basis.proc estimate" "$(jq_ "d['cpu_basis']['proc']")" estimate
expect "schema 1 only: cpu_basis_since null"    "$(jq_ "d['cpu_basis_since']")" None

# ========= 8b. advise and report derive the SAME iv from the same bytes ======
# advise copies U0's interval algorithm rather than paraphrasing it, because iv
# multiplies into observed_seconds and therefore into every rate and every
# threshold decision. Two implementations that drift by one bucket disagree
# about how busy the machine was, in two commands the user reads side by side.
#
# The gap list is {10,10,20,20}: dn=4, need=int(4/2)+1=3, so the upper median is
# 20. The natural c >= dn/2 returns 10. This is the input where the two
# formulations diverge, so it is the input that proves they were not both typed
# from memory.
H8="$TMP/h8"; mkdir -p "$H8/raw"
T0=$((NOW - 3600))
{ sys1 "$T0"; sys1 $((T0 + 10)); sys1 $((T0 + 20)); sys1 $((T0 + 40)); sys1 $((T0 + 60)); } \
  > "$H8/raw/$DAY0.tsv"
RIV=$(CLAUDE_WATCH_HOME="$H8" "$CW" report "$DAY0" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["interval_seconds"])' 2>/dev/null)
run_advise "$H8" --window 24h
expect "upper median: report says iv 20"           "$RIV" 20
expect "upper median: advise agrees with report"   "$(jq_ "d['interval_seconds']")" "$RIV"
expect "upper median: observed_seconds = 5 x 20"   "$(jq_ "d['window']['observed_seconds']")" 100

# A damaged epoch must be excluded and SAID, not silently dropped: awk holds
# numbers as doubles, so an over-long epoch stops comparing distinctly and two
# samples collapse into one with nothing reported.
#
# Four damaged shapes, and the non-numeric ones are the point. The window filter
# runs before the validator, so a filter written as `$1 + 0 >= cutoff` converts
# `notanepoch` to 0, drops it as "before the window", and the validator never
# sees it — the row reads as absent rather than as damaged, with nothing said.
# Only the over-long NUMERIC epoch survives that filter, so a fixture carrying
# just that one passes against a reader that is silently losing rows.
H9="$TMP/h9"; mkdir -p "$H9/raw"
{ sys1 $((NOW - 60)); sys1 $((NOW - 30)); } > "$H9/raw/$DAY0.tsv"
printf 'notanepoch\tsys\t-\t1.0\t1\t1\t0\t14\n'        >> "$H9/raw/$DAY0.tsv"
printf '\tsys\t-\t1.0\t1\t1\t0\t14\n'                  >> "$H9/raw/$DAY0.tsv"
printf '0001759000000\tsys\t-\t1.0\t1\t1\t0\t14\n'     >> "$H9/raw/$DAY0.tsv"
printf '90071992547409920\tsys\t-\t1.0\t1\t1\t0\t14\n' >> "$H9/raw/$DAY0.tsv"
run_advise "$H9" --window 24h
expect "damaged epochs are excluded from the count" "$(jq_ "d['samples']")" 2
if grep -q 'window_read_failed' "$J"; then ok "damaged epochs report window_read_failed"
else bad "damaged epochs report window_read_failed"; fi
# The COUNT is asserted, not merely the presence of a warning: a reader that
# lost the three non-numeric rows in the filter would report 1 here and still
# print a plausible-looking line.
if grep -qF 'has 4 sys rows whose epoch is not a plain integer' "$E"; then
  ok "all four damaged rows are counted and reported on stderr"
else
  bad "all four damaged rows are counted and reported on stderr"; sed 's/^/        /' "$E"
fi

# ================== 9. the emitter: ordering, tabs, the unknown invariant ====
# Findings are fed through a stand-in analyzer so the emitter is tested as the
# pure function it is, with no disk or process state involved.
STUBDIR="$TMP/stub"; mkdir -p "$STUBDIR/tools"
cp "$CW" "$STUBDIR/claude-watch"
cp "$REPO/tools/advise.sh" "$STUBDIR/tools/advise.sh"
cp "$REPO/tools/orphan-policy.sh" "$STUBDIR/tools/orphan-policy.sh" 2>/dev/null
# disk.a.aaa and disk.b.zzz sit at EQUAL severity and EQUAL share: without the
# id tie-break they order nondeterministically and every fixture built on them
# becomes flaky. The S row carries the worst F row's severity, which is the
# analyzer's half of §3b.
#
# disk.b.zzz's headline holds a path that CONTAINED a tab and was stripped to a
# space by the analyzer, per §3b — it must arrive as one field. disk.d.raw is
# the other half: an analyzer that failed to strip its tab. That row mis-splits
# by construction, and the guard is that it cannot make `severity` read as
# something that is not a severity.
cat > "$STUBDIR/tools/advise-disk.sh" <<'STUB'
advise_disk() {
  printf 'S\tdisk\tcritical\tcomplete\t\ttwo groups at the same size\t\n'
  printf 'F\tdisk\tdisk.b.zzz\twarn\t0.25\t100\tkb\t50\tCLAUDE_WATCH_DISK_GROUP_WARN_PCT\t100\tconfirmed\t/Users/x/a b/node_modules is 100 KB\tdetail\t\n'
  printf 'F\tdisk\tdisk.a.aaa\twarn\t0.25\t100\tkb\t50\tCLAUDE_WATCH_DISK_GROUP_WARN_PCT\t100\tconfirmed\thead-aaa\tdetail\t\n'
  printf 'F\tdisk\tdisk.d.raw\twarn\t0.25\t100\tkb\t50\tCLAUDE_WATCH_DISK_GROUP_WARN_PCT\t100\tconfirmed\t/Users/x/a\tb/node_modules\tdetail\t\n'
  printf 'F\tdisk\tdisk.c.big\tcritical\t0.9\t900\tkb\t50\tCLAUDE_WATCH_DISK_GROUP_WARN_PCT\t900\tconfirmed\thead-big\tdetail\t\n'
}
STUB
# The all-clear row, exactly as §3b writes it. The `""` in the spec is notation
# for an EMPTY FIELD, not two literal quote bytes — the summary beside it is
# quoted the same way and plainly is not literally quoted. All seven fields are
# present; reasons_csv and remedy are empty. Every domain must degrade to this
# shape, so a human must never see `""` and the JSON must never carry "\"\"".
cat > "$STUBDIR/tools/advise-leaks.sh" <<'STUB'
advise_leaks() {
  printf 'S\tleaks\tok\tcomplete\t\tno leaked processes, no removable worktrees\t\n'
}
STUB
J="$TMP/stub.json"
CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  "$STUBDIR/claude-watch" advise --json > "$J" 2>/dev/null
if python3 -m json.tool < "$J" > /dev/null 2>&1; then ok "stub analyzers: JSON is well-formed"
else bad "stub analyzers: JSON is well-formed"; sed 's/^/        /' "$J"; fi
IDS=$(jq_ "','.join(f['id'] for f in d['domains'][0]['findings'])")
expect "findings sort by (severity desc, share desc, id asc)" \
       "$IDS" "disk.c.big,disk.a.aaa,disk.b.zzz,disk.d.raw"
expect "a path with a space survives as one field" \
       "$(jq_ "[f['headline'] for f in d['domains'][0]['findings'] if f['id']=='disk.b.zzz'][0]")" \
       "/Users/x/a b/node_modules is 100 KB"
expect "an unstripped tab cannot make severity read as a non-severity" \
       "$(jq_ "[f['severity'] for f in d['domains'][0]['findings'] if f['id']=='disk.d.raw'][0]")" warn
expect "domains sort by severity: disk (critical) before leaks (ok)" \
       "$(jq_ "d['domains'][0]['domain']")" disk
expect "priority is the resulting position"  "$(jq_ "d['domains'][1]['priority']")" 2
expect "primary picks the worst domain"      "$(jq_ "d['primary']['domain']")" disk
expect "primary.state is the worst severity" "$(jq_ "d['primary']['state']")" critical
expect "primary.severity_rank is published"  "$(jq_ "d['primary']['severity_rank']")" 4
expect "primary.headline carries the fact, not a bare domain name" \
       "$(jq_ "d['primary']['headline']")" "CRITICAL disk — head-big"
expect "an ok domain with no findings stays ok" "$(jq_ "d['domains'][1]['severity']")" ok
# The all-clear shape: empty fields are empty, not two literal quote bytes.
expect "all-clear: empty reasons_csv becomes []"  "$(jq_ "d['domains'][1]['measurement_reasons']")" "[]"
expect "all-clear: empty remedy becomes null"     "$(jq_ "d['domains'][1]['remedy']")" None
expect "all-clear: partial_reason null when complete" "$(jq_ "d['domains'][1]['partial_reason']")" None
expect "all-clear: the summary is the text, unquoted" \
       "$(jq_ "d['domains'][1]['summary']")" "no leaked processes, no removable worktrees"
if grep -q '\\"\\"' "$J"; then bad "all-clear: no literal \"\" in the JSON"
else ok "all-clear: no literal \"\" in the JSON"; fi
ALLCLEAR=$(CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  "$STUBDIR/claude-watch" advise 2>/dev/null)
if printf '%s' "$ALLCLEAR" | grep -qF '""'; then
  bad "all-clear: no literal \"\" in the human output"
  printf '%s\n' "$ALLCLEAR" | grep -F '""' | sed 's/^/        /'
else
  ok "all-clear: no literal \"\" in the human output"
fi
if printf '%s' "$ALLCLEAR" | grep -qF 'OK leaks — no leaked processes, no removable worktrees'; then
  ok "all-clear: an ok domain collapses to one line"
else
  bad "all-clear: an ok domain collapses to one line"
  printf '%s\n' "$ALLCLEAR" | sed 's/^/        /'
fi

# unknown (1) outranks ok (0): an all-ok-but-one-unknown run reports unknown.
cat > "$STUBDIR/tools/advise-disk.sh" <<'STUB'
advise_disk() { printf 'S\tdisk\tunknown\tunavailable\tcache_missing\tnever scanned\tclaude-watch disk --refresh\n'; }
STUB
CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  "$STUBDIR/claude-watch" advise --json > "$J" 2>/dev/null
expect "unknown outranks ok in primary.state" "$(jq_ "d['primary']['state']")" unknown
expect "unknown ranks 1, above ok's 0"        "$(jq_ "d['primary']['severity_rank']")" 1
expect "the unknown domain sorts first"       "$(jq_ "d['domains'][0]['domain']")" disk
# Invariant, fixture asserted: unavailable <=> severity unknown, on EVERY domain.
if jq_ "all((f['measurement_state']=='unavailable')==(f['severity']=='unknown') for f in d['domains'])" | grep -q True; then
  ok "measurement_state unavailable <=> severity unknown on every domain"
else
  bad "measurement_state unavailable <=> severity unknown on every domain"
fi
# unknown must never render in C_OK, and the severity WORD prints regardless of
# colour (colours are blank when stdout is not a tty, which is this test).
UTXT=$(CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  "$STUBDIR/claude-watch" advise 2>/dev/null)
if printf '%s' "$UTXT" | grep -qF 'UNKNOWN unmeasured'; then
  ok "unknown renders as the word 'UNKNOWN unmeasured'"
else
  bad "unknown renders as the word 'UNKNOWN unmeasured'"; printf '%s\n' "$UTXT" | sed 's/^/        /'
fi

# ============================== 10. no nan/inf, and disk --json's shape =====
# awk prints nan/-nan/inf for 0/0 and x/0, and Python's permissive loader reads
# them as numbers, so json.tool alone would wave them through.
for f in "$TMP/out.json" "$J"; do :; done
if grep -Eqi '(^|[^a-z])-?(nan|inf)([^a-z]|$)' "$J" "$TMP/out.json"; then
  bad "no nan/inf anywhere in the output"
else
  ok "no nan/inf anywhere in the output"
fi
# A share whose denominator is missing is emitted as 0, never computed.
cat > "$STUBDIR/tools/advise-disk.sh" <<'STUB'
advise_disk() {
  printf 'S\tdisk\twarn\tpartial\tcache_missing\tno volume denominator\t\n'
  printf 'F\tdisk\tdisk.x\twarn\tnan\t1\tkb\t2\tCLAUDE_WATCH_DISK_GROUP_WARN_PCT\t0\tn/a\th\td\t\n'
  printf 'F\tdisk\tdisk.y\twarn\tinf\t1\tkb\t2\tCLAUDE_WATCH_DISK_GROUP_WARN_PCT\t0\tn/a\th\td\t\n'
  printf 'F\tdisk\tdisk.z\twarn\t5\t1\tkb\t2\tCLAUDE_WATCH_DISK_GROUP_WARN_PCT\t0\tn/a\th\td\t\n'
}
STUB
CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  "$STUBDIR/claude-watch" advise --json > "$J" 2>/dev/null
if python3 -m json.tool < "$J" > /dev/null 2>&1; then ok "nan/inf shares: JSON still parses"
else bad "nan/inf shares: JSON still parses"; sed 's/^/        /' "$J"; fi
expect "a nan share is emitted as 0"          "$(jq_ "[f['share_of_domain'] for f in d['domains'][0]['findings'] if f['id']=='disk.x'][0]")" 0
expect "an inf share is emitted as 0"         "$(jq_ "[f['share_of_domain'] for f in d['domains'][0]['findings'] if f['id']=='disk.y'][0]")" 0
expect "a numeric share above 1 is clamped"   "$(jq_ "[f['share_of_domain'] for f in d['domains'][0]['findings'] if f['id']=='disk.z'][0]")" 1
expect "an empty action is null, never an empty command" \
       "$(jq_ "[f['action'] for f in d['domains'][0]['findings'] if f['id']=='disk.x'][0]")" None

# value / threshold / reclaimable_kb are JSON NUMBERS, and JSON's number grammar
# is narrower than what awk and most eyes call numeric. `.5`, `01` and `1.` are
# rejected by a strict parser; `1e999999` is finite text and an infinite value,
# which Python turns into float("inf") WITHOUT raising — so json.tool alone
# validates a document that has already lost the no-inf contract. A real
# measurement must be canonicalised rather than zeroed, and only genuine
# nonsense may become 0.
cat > "$STUBDIR/tools/advise-disk.sh" <<'STUB'
advise_disk() {
  printf 'S\tdisk\twarn\tcomplete\t\tnumber serialisation\t\n'
  printf 'F\tdisk\tdisk.n1\twarn\t0.1\t.5\tkb\t01\tK\t1.\tn/a\th\td\t\n'
  printf 'F\tdisk\tdisk.n2\twarn\t0.1\t1e999999\tkb\tnan\tK\tinf\tn/a\th\td\t\n'
  printf 'F\tdisk\tdisk.n3\twarn\t0.1\t421562020\tkb\t-3.25\tK\t1.5e-7\tn/a\th\td\t\n'
  printf 'F\tdisk\tdisk.n4\twarn\t0.1\tabc\tkb\t0x1f\tK\t1,5\tn/a\th\td\t\n'
}
STUB
CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  "$STUBDIR/claude-watch" advise --json > "$J" 2>/dev/null
# json.tool is not enough on its own here, so every number is checked for
# finiteness and the raw text is checked against JSON's actual grammar.
if python3 - "$J" <<'PY'
import json, math, re, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw)
grammar = re.compile(r'-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$')
for dom in d["domains"]:
    for f in dom["findings"]:
        for k in ("value", "threshold", "reclaimable_kb", "share_of_domain"):
            v = f[k]
            assert isinstance(v, (int, float)) and math.isfinite(v), (f["id"], k, v)
for m in re.finditer(r'"(?:value|threshold|reclaimable_kb)":([^,}]+)', raw):
    assert grammar.fullmatch(m.group(1)), m.group(1)
PY
then ok "every emitted number is finite and matches JSON's number grammar"
else bad "every emitted number is finite and matches JSON's number grammar"; sed 's/^/        /' "$J"
fi
expect "'.5' is canonicalised to 0.5, not dropped to 0"  "$(jq_ "[f['value'] for f in d['domains'][0]['findings'] if f['id']=='disk.n1'][0]")" 0.5
expect "'01' is canonicalised to 1"                      "$(jq_ "[f['threshold'] for f in d['domains'][0]['findings'] if f['id']=='disk.n1'][0]")" 1
expect "'1.' is canonicalised to 1"                      "$(jq_ "[f['reclaimable_kb'] for f in d['domains'][0]['findings'] if f['id']=='disk.n1'][0]")" 1
expect "'1e999999' overflows to inf, so it becomes 0"    "$(jq_ "[f['value'] for f in d['domains'][0]['findings'] if f['id']=='disk.n2'][0]")" 0
expect "a nan threshold becomes 0"                       "$(jq_ "[f['threshold'] for f in d['domains'][0]['findings'] if f['id']=='disk.n2'][0]")" 0
expect "an inf reclaimable_kb becomes 0"                 "$(jq_ "[f['reclaimable_kb'] for f in d['domains'][0]['findings'] if f['id']=='disk.n2'][0]")" 0
expect "a large exact integer keeps its precision"       "$(jq_ "[f['value'] for f in d['domains'][0]['findings'] if f['id']=='disk.n3'][0]")" 421562020
expect "a negative value survives"                       "$(jq_ "[f['threshold'] for f in d['domains'][0]['findings'] if f['id']=='disk.n3'][0]")" -3.25
expect "exponent notation survives"                      "$(jq_ "[f['reclaimable_kb'] for f in d['domains'][0]['findings'] if f['id']=='disk.n3'][0]")" 1.5e-07
expect "non-numeric text becomes 0"                      "$(jq_ "[f['value'] for f in d['domains'][0]['findings'] if f['id']=='disk.n4'][0]")" 0
expect "a hex literal is not a JSON number, so 0"        "$(jq_ "[f['threshold'] for f in d['domains'][0]['findings'] if f['id']=='disk.n4'][0]")" 0

# §3f: disk --json's `domain` is byte-for-byte advise's, minus `priority`.
A="$TMP/adv.json"; D="$TMP/dsk.json"
CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  "$STUBDIR/claude-watch" advise --json > "$A" 2>/dev/null
CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  "$STUBDIR/claude-watch" disk --json > "$D" 2>/dev/null
if python3 - "$A" "$D" <<'PY'
import sys
ra = open(sys.argv[1]).read(); rd = open(sys.argv[2]).read()
dom_d = rd[rd.index('"domain":{') + 9 : rd.rindex('}')]
start = ra.index('"domains":[') + 11
depth = 0
for i, c in enumerate(ra[start:], start):
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            dom_a = ra[start:i + 1]; break
sys.exit(0 if dom_a.replace('"priority":1,', '', 1) == dom_d else 1)
PY
then ok "disk --json's domain object is advise's minus priority, byte for byte"
else bad "disk --json's domain object is advise's minus priority, byte for byte"; fi

# ====== 11. dispatcher cache validation must agree with the analyzer (A2) ====
# The dispatcher's own cw_read_disk_cache used to accept any cache with a
# positive epoch and a vol row — a weaker rule than advise_disk's full §3c
# parser. This cache satisfies that old, looser rule (epoch>0, a vol row is
# present) but fails advise_disk's own validation (used_kb is non-numeric),
# so the two used to disagree: the disk domain read unknown while
# CW_VOLUME_TOTAL_KB was still exported from the same untrusted row, and
# leaks went on to compute a share against a total the disk domain itself
# called unmeasured. tools/advise-disk.sh, not a stub, is used here — the
# real fixture-disk.sh:335 case reused as the reader for the dispatcher path.
H3="$TMP/h3"; mkdir -p "$H3/raw" "$H3/state"
printf 'epoch\t-\t%s\t-\t-\nscan\t0\t0\t3\t3\nvol\t/x\tlots\t20725496\t0\n' "$NOW" \
  > "$H3/state/disk.tsv"
J="$TMP/out11.json"; S="$TMP/scalars11"; E="$TMP/err11"
CLAUDE_WATCH_HOME="$H3" CLAUDE_WATCH_DISK_CACHE="$H3/state/disk.tsv" \
  CW_SCALARS_OUT="$S" "$CW" advise --json > "$J" 2>"$E"
expect "A2: a cache advise_disk rejects reports disk as unknown" \
  "$(jq_ "[dm['severity'] for dm in d['domains'] if dm['domain']=='disk'][0]")" unknown
expect "A2: ...and measurement_state unavailable" \
  "$(jq_ "[dm['measurement_state'] for dm in d['domains'] if dm['domain']=='disk'][0]")" unavailable
expect "A2: ...and CW_VOLUME_TOTAL_KB is NOT exported from the same untrusted row" \
  "$(LC_ALL=C awk -F= -v k=CW_VOLUME_TOTAL_KB '$1 == k { print substr($0, length(k) + 2) }' "$S")" ""

# ====== 12. dispatcher backstop when an analyzer returns nothing (A3) =======
# advise_leaks (or any future analyzer) can fail on an early-exit path before
# ever printing its S row (tools/advise-leaks.sh:354's mktemp failure was one).
# The old `{ advise_disk; advise_leaks; } > "$rows"` trusted neither status, so
# a domain that printed nothing was simply absent from render — not `unknown`,
# not present at all — with advise still exiting 0. cw_advise now checks each
# analyzer's own status and synthesizes an unknown domain when its S row never
# arrived.
cat > "$STUBDIR/tools/advise-leaks.sh" <<'STUB'
advise_leaks() {
  return 1
}
STUB
J="$TMP/out12.json"
CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  "$STUBDIR/claude-watch" advise --json > "$J" 2>/dev/null
RC=$?
expect "A3: advise still exits 0 when an analyzer returns nothing" "$RC" 0
expect "A3: the leaks domain is present, not dropped from render" \
  "$(jq_ "'leaks' in [dm['domain'] for dm in d['domains']]")" True
expect "A3: ...reported unknown rather than silently absent" \
  "$(jq_ "[dm['severity'] for dm in d['domains'] if dm['domain']=='leaks'][0]")" unknown
expect "A3: ...measurement_state unavailable" \
  "$(jq_ "[dm['measurement_state'] for dm in d['domains'] if dm['domain']=='leaks'][0]")" unavailable

# ====== 13. octal leading-zero must not corrupt --window or thresholds (A1) =
# is_uint accepts a leading zero as a valid integer, but bash arithmetic reads
# one as octal: "010" would silently become 8, and "08" would abort the whole
# run with an invalid-octal-digit error. cw_parse_window and
# cw_load_thresholds each normalise with 10# before using the value in
# arithmetic. fixture-leaks.sh already covers this hazard for
# advise-leaks.sh's OWN knob reader (leaks_knob) — nothing exercised
# cw_load_thresholds or --window itself.
run_advise "$H1" --window 010h
expect "A1: --window 010h reads as decimal 10h, not octal 8h" \
  "$(jq_ "d['window']['requested_seconds']")" "$((10 * 3600))"
run_advise "$H1" --window 08h
expect "A1: --window 08h does not abort on an invalid-octal digit" "$RC" 0
expect "A1: ...and reads as decimal 8h" \
  "$(jq_ "d['window']['requested_seconds']")" "$((8 * 3600))"

TH1="$TMP/out13-crit.thresh"
CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  CLAUDE_WATCH_DISK_CRIT_PCT=010 "$CW" advise --show-thresholds > "$TH1" 2>/dev/null
RCC=$?
expect "A1: CLAUDE_WATCH_DISK_CRIT_PCT=010 does not abort cw_load_thresholds" "$RCC" 0
expect "A1: ...and reads as decimal 10, not octal 8" \
  "$(awk '$1=="CLAUDE_WATCH_DISK_CRIT_PCT"{print $2}' "$TH1")" "10"

TH2="$TMP/out13-warn.thresh"
CLAUDE_WATCH_HOME="$H1" CLAUDE_WATCH_DISK_CACHE="$H1/none.tsv" \
  CLAUDE_WATCH_DISK_WARN_GIB=08 "$CW" advise --show-thresholds > "$TH2" 2>/dev/null
RCW=$?
expect "A1: CLAUDE_WATCH_DISK_WARN_GIB=08 does not abort cw_load_thresholds" "$RCW" 0
expect "A1: ...and reads as decimal 8" \
  "$(awk '$1=="CLAUDE_WATCH_DISK_WARN_GIB"{print $2}' "$TH2")" "8"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

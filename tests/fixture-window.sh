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

# Oldest row first: aggregation closes a sample on an epoch change, so
# out-of-order concatenation would corrupt the fold. A disordered read would
# produce gaps of -86400 and a different iv, so iv==30 above already proves
# order — but assert the raw stream directly as well.
ORDER=$(CLAUDE_WATCH_HOME="$H1" LC_ALL=C awk 'BEGIN{p=0} { if ($1 + 0 < p) { print "unordered"; exit } p = $1 + 0 } END { print "ordered" }' \
  <(cat "$H1/raw/$DAY3.tsv" "$TMP/d2.tsv" "$H1/raw/$DAY1.tsv" "$H1/raw/$DAY0.tsv"))
expect "week: planted rows are ordered oldest-first" "$ORDER" ordered

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
# A corrupt archive currently yields a silently short window with an
# honest-looking observed_seconds. That is the failure this whole tool exists to
# prevent, so it must surface as window_read_failed, not as fewer samples.
H3="$TMP/h3"; mkdir -p "$H3/raw"
{ sys1 $((NOW - 60)); sys1 $((NOW - 30)); } > "$H3/raw/$DAY0.tsv"
printf 'this is not a gzip stream at all\n' > "$H3/raw/$DAY2.tsv.gz"
run_advise "$H3" --window week
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

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

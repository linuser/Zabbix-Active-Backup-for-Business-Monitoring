#!/bin/bash
# abb.sh — Zabbix external script for Synology Active Backup for Business
# Reads CSV files exported by abb_export.sh via NFS mount.
#
# Usage: abb.sh <subcommand> [args...]
#
# Status codes: 1=Running 2=Success 3=Aborted 4=Error 5=Warning 8=Partial 99=Unknown
#
# Maintainer: Alexander Fox | PlaNet Fox

set -euo pipefail

###############################################################################
# Configuration
###############################################################################
CSV_PATH="${ABB_CSV_PATH:-/mnt/synology/monitoring/abb}"
CSV_EXPORT="${CSV_PATH}/ActiveBackupExport.csv"
CSV_STATS="${CSV_PATH}/ActiveBackupStats.csv"
DEBUG="${ABB_DEBUG:-0}"
ZBX_USER="${ABB_ZBX_USER:-zabbix}"
NOW="$(date +%s)"

###############################################################################
# Helpers
###############################################################################
log_debug() { [ "$DEBUG" = "1" ] && echo "DEBUG: $*" >&2 || true; }
die()       { echo "ERROR: $*" >&2; exit 1; }

csv_field() {
  # $1=file  $2=deviceid  $3=field_number (1-based)
  awk -F',' -v did="$2" -v f="$3" 'NR>1 && $1==did {print $f; exit}' "$1"
}

###############################################################################
# check — verify mount + CSV freshness
#   $1=max_age  $2=mountpoint  [$3=expected_remote]  [$4=expected_fstype]
###############################################################################
do_check() {
  local max_age="${1:-900}"
  local mpoint="${2:-}"
  local expect_remote="${3:-}"
  local expect_fstype="${4:-}"

  # --- Mount check ---
  if [ -n "$mpoint" ]; then
    local mnt_output
    mnt_output="$(findmnt -rn "$mpoint" 2>/dev/null || true)"
    log_debug "findmnt: $mnt_output"

    if [ -z "$mnt_output" ]; then
      log_debug "Mount not found: $mpoint"; exit 1
    fi

    # Prefer NFS/CIFS line over autofs if both present
    local check_line
    check_line="$(echo "$mnt_output" | grep -v 'autofs' | head -1)"
    if [ -z "$check_line" ]; then
      # Only autofs — allow, but skip strict compare
      log_debug "autofs detected; skipping strict remote/fstype compare"
    else
      if [ -n "$expect_remote" ]; then
        local actual_src
        actual_src="$(echo "$check_line" | awk '{print $2}')"
        if [ "$actual_src" != "$expect_remote" ]; then
          log_debug "Remote mismatch: got=$actual_src want=$expect_remote"; exit 1
        fi
      fi
      if [ -n "$expect_fstype" ]; then
        local actual_fs
        actual_fs="$(echo "$check_line" | awk '{print $3}')"
        if [ "$actual_fs" != "$expect_fstype" ]; then
          log_debug "FS type mismatch: got=$actual_fs want=$expect_fstype"; exit 1
        fi
      fi
    fi
  fi

  # --- File readability check ---
  if [ "$(id -u -n 2>/dev/null)" = "$ZBX_USER" ]; then
    if ! test -r "$CSV_EXPORT"; then
      log_debug "File not readable by $ZBX_USER (direct)"; exit 1
    fi
  else
    if ! sudo -u "$ZBX_USER" test -r "$CSV_EXPORT" 2>/dev/null; then
      # Fallback: try direct read (sudoers may not be configured)
      if ! test -r "$CSV_EXPORT"; then
        log_debug "File not readable by $ZBX_USER"; exit 1
      fi
    fi
  fi
  log_debug "READABLE=yes"

  # --- Freshness check ---
  local file_mtime file_age
  file_mtime="$(stat -c '%Y' "$CSV_EXPORT" 2>/dev/null)" \
    || file_mtime="$(stat -f '%m' "$CSV_EXPORT" 2>/dev/null)" \
    || { log_debug "Cannot stat $CSV_EXPORT"; exit 1; }
  file_age=$(( NOW - file_mtime ))
  log_debug "AGE=$file_age"

  if [ "$file_age" -gt "$max_age" ]; then
    log_debug "CSV stale: age=${file_age}s > max=${max_age}s"; exit 1
  fi

  echo 0
}

###############################################################################
# discovery — LLD JSON
###############################################################################
do_discovery() {
  [ -r "$CSV_EXPORT" ] || die "CSV not readable: $CSV_EXPORT"
  awk -F',' 'NR>1 && $1!="" {
    if(c++) printf ","
    printf "{\"{#DEVICEID}\":\"%s\",\"{#HOSTNAME}\":\"%s\"}", $1, $2
  } BEGIN{printf "{\"data\":["} END{printf "]}\n"}' "$CSV_EXPORT"
}

###############################################################################
# json — master item: all device data as JSON
###############################################################################
do_json() {
  [ -r "$CSV_EXPORT" ] || die "CSV not readable: $CSV_EXPORT"
  awk -F',' -v now="$NOW" 'NR>1 && $1!="" {
    did=$1; host=$2; status=$3+0; bytes=$4+0; dur=$5+0; ts=$6+0
    lss = (NF>=7 && $7+0 > 0) ? $7+0 : 0
    lsa = (lss > 0) ? (now - lss) : 2147483647

    if(c++) printf ","
    printf "{\"id\":%s,\"host\":\"%s\",\"status\":%d,\"bytes\":%s,\"duration\":%d,\"ts\":%d,\"last_success_ts\":%d,\"last_success_age\":%d}",
      did, host, status, bytes, dur, ts, lss, lsa
  } BEGIN{printf "{\"devices\":["} END{printf "]}\n"}' "$CSV_EXPORT"
}

###############################################################################
# Per-device subcommands (legacy, still used by abb-enh.sh)
###############################################################################
do_status()          { csv_field "$CSV_EXPORT" "$1" 3; }
do_bytes()           { csv_field "$CSV_EXPORT" "$1" 4; }
do_duration()        { csv_field "$CSV_EXPORT" "$1" 5; }
do_lastsuccess_age() {
  local lss
  lss="$(csv_field "$CSV_EXPORT" "$1" 7)"
  if [ -z "$lss" ] || [ "$lss" = "0" ]; then
    echo 2147483647
  else
    echo $(( NOW - lss ))
  fi
}

###############################################################################
# Global subcommands
###############################################################################
do_device_count() {
  awk -F',' 'NR>1 && $1!=""{c++} END{print c+0}' "$CSV_EXPORT"
}
do_success_today() {
  [ -r "$CSV_STATS" ] || { echo 0; return; }
  awk -F',' 'NR==2{print $1+0}' "$CSV_STATS"
}
do_failed_today() {
  [ -r "$CSV_STATS" ] || { echo 0; return; }
  awk -F',' 'NR==2{print $2+0}' "$CSV_STATS"
}
do_failed_count() {
  awk -F',' 'NR>1 && ($3+0)==4{c++} END{print c+0}' "$CSV_EXPORT"
}
do_warn_count() {
  awk -F',' 'NR>1 && ($3+0)==5{c++} END{print c+0}' "$CSV_EXPORT"
}
do_notok_count() {
  awk -F',' 'NR>1 && (($3+0)==4||($3+0)==5){c++} END{print c+0}' "$CSV_EXPORT"
}
do_notok_list() {
  awk -F',' 'NR>1 && (($3+0)==4||($3+0)==5){printf "%s%s",sep,$2; sep=","} END{print ""}' "$CSV_EXPORT"
}
do_failed_list() {
  awk -F',' 'NR>1 && ($3+0)==4{printf "%s%s",sep,$2; sep=","} END{print ""}' "$CSV_EXPORT"
}
do_sum_bytes() {
  awk -F',' 'NR>1{s+=$4+0} END{printf "%.0f\n",s}' "$CSV_EXPORT"
}
do_sum_repo_bytes() {
  # Placeholder: ABB doesn't expose repo size in device_result_table
  echo 0
}
do_repo_bytes() {
  # Placeholder per device
  echo 0
}

###############################################################################
# Dispatch
###############################################################################
CMD="${1:-}"
shift 2>/dev/null || true

case "$CMD" in
  check)             do_check "$@" ;;
  discovery)         do_discovery ;;
  json)              do_json ;;
  status)            do_status "${1:?device_id required}" ;;
  bytes)             do_bytes "${1:?device_id required}" ;;
  duration)          do_duration "${1:?device_id required}" ;;
  lastsuccess_age)   do_lastsuccess_age "${1:?device_id required}" ;;
  repo_bytes)        do_repo_bytes ;;
  device_count)      do_device_count ;;
  success_today)     do_success_today ;;
  failed_today)      do_failed_today ;;
  failed_count)      do_failed_count ;;
  warn_count)        do_warn_count ;;
  notok_count)       do_notok_count ;;
  notok_list)        do_notok_list ;;
  failed_list)       do_failed_list ;;
  sum_bytes)         do_sum_bytes ;;
  sum_repo_bytes)    do_sum_repo_bytes ;;
  *)                 die "Unknown command: $CMD. Usage: $0 {check|discovery|json|status|bytes|duration|...} [args]" ;;
esac

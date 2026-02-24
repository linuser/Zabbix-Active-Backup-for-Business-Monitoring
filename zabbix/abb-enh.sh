#!/bin/bash
# abb-enh.sh — Enhanced ABB report functions (used by Zabbix actions/scripts)
# Single-pass CSV reads instead of per-device forks.
#
# Usage: abb-enh.sh <subcommand>
#   report       — full text report of all devices
#   failed_info  — details of failed/warning devices only
#
# Maintainer: Alexander Fox | PlaNet Fox

set -euo pipefail

CSV_PATH="${ABB_CSV_PATH:-/mnt/synology/monitoring/abb}"
CSV_EXPORT="${CSV_PATH}/ActiveBackupExport.csv"
NOW="$(date +%s)"

status_label() {
  case "$1" in
    1) echo "Running" ;; 2) echo "Success" ;; 3) echo "Aborted" ;;
    4) echo "Error"   ;; 5) echo "Warning" ;; 8) echo "Partial" ;;
    *) echo "Unknown($1)" ;;
  esac
}

format_bytes() {
  awk -v b="$1" 'BEGIN{
    if(b>=1099511627776) printf "%.1f TB\n",b/1099511627776
    else if(b>=1073741824) printf "%.1f GB\n",b/1073741824
    else if(b>=1048576) printf "%.1f MB\n",b/1048576
    else if(b>=1024) printf "%.1f KB\n",b/1024
    else printf "%d B\n",b
  }'
}

format_duration() {
  local s="$1"
  if [ "$s" -ge 3600 ]; then
    printf '%dh %dm %ds\n' $((s/3600)) $(((s%3600)/60)) $((s%60))
  elif [ "$s" -ge 60 ]; then
    printf '%dm %ds\n' $((s/60)) $((s%60))
  else
    printf '%ds\n' "$s"
  fi
}

format_age() {
  local s="$1"
  if [ "$s" -ge 2147483600 ]; then echo "never"; return; fi
  if [ "$s" -ge 86400 ]; then
    printf '%dd %dh\n' $((s/86400)) $(((s%86400)/3600))
  elif [ "$s" -ge 3600 ]; then
    printf '%dh %dm\n' $((s/3600)) $(((s%3600)/60))
  else
    printf '%dm\n' $((s/60))
  fi
}

do_report() {
  [ -r "$CSV_EXPORT" ] || { echo "CSV not readable: $CSV_EXPORT"; exit 1; }

  printf '%-25s  %-10s  %12s  %10s  %s\n' "HOST" "STATUS" "BYTES" "DURATION" "LAST OK"
  printf '%-25s  %-10s  %12s  %10s  %s\n' "-------------------------" "----------" "------------" "----------" "----------"

  awk -F',' -v OFS='\t' 'NR>1 && $1!="" {
    gsub(/"/, "", $2)
    print $2, $3+0, $4+0, $5+0, (NF>=7 && $7+0>0 ? $7+0 : 0)
  }' "$CSV_EXPORT" | while IFS=$'\t' read -r host status bytes dur lss; do
    lsa=$(( lss > 0 ? NOW - lss : 2147483647 ))
    printf '%-25s  %-10s  %12s  %10s  %s\n' \
      "$host" \
      "$(status_label "$status")" \
      "$(format_bytes "$bytes")" \
      "$(format_duration "$dur")" \
      "$(format_age "$lsa")"
  done
}

do_failed_info() {
  [ -r "$CSV_EXPORT" ] || { echo "CSV not readable: $CSV_EXPORT"; exit 1; }

  local found=0
  awk -F',' -v OFS='\t' 'NR>1 && $1!="" && ($3+0==4||$3+0==5||$3+0==3) {
    gsub(/"/, "", $2)
    print $2, $3+0, $4+0, $5+0, (NF>=7 && $7+0>0 ? $7+0 : 0)
  }' "$CSV_EXPORT" | while IFS=$'\t' read -r host status bytes dur lss; do
    lsa=$(( lss > 0 ? NOW - lss : 2147483647 ))
    found=1
    printf '%s: %s (bytes=%s, duration=%s, last_success=%s ago)\n' \
      "$host" \
      "$(status_label "$status")" \
      "$(format_bytes "$bytes")" \
      "$(format_duration "$dur")" \
      "$(format_age "$lsa")"
  done

  [ "$found" = "0" ] && echo "All devices OK"
  return 0
}

case "${1:-}" in
  report)      do_report ;;
  failed_info) do_failed_info ;;
  *)           echo "Usage: $0 {report|failed_info}" >&2; exit 1 ;;
esac

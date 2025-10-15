#!/bin/sh
# /volume1/monitoring/scripts/abb_daily_summary.sh
# Schreibt eine kurze Tageszusammenfassung ins export.log

set -eu
ABB_DIR="${ABB_DIR:-/volume1/monitoring/abb}"
LOG="$ABB_DIR/export.log"
CSV="$ABB_DIR/ActiveBackupExport.csv"

SOD=$(( $(date +%s) / 86400 * 86400 ))

succ=0
fail=0
warn=0
total=0
if [ -r "$CSV" ]; then
  succ=$(awk -F, -v SOD="$SOD" 'NR>1 && ($3==2 || $3==8) && $6>=SOD {c++} END{print c+0}' "$CSV")
  fail=$(awk -F, -v SOD="$SOD" 'NR>1 && $3==4 && $6>=SOD {c++} END{print c+0}' "$CSV")
  warn=$(awk -F,                'NR>1 && $3==5 {c++} END{print c+0}' "$CSV")
  total=$(awk -F,               'NR>1 {c++}     END{print c+0}' "$CSV")
fi

printf '%s [DAILY] success=%s fail=%s warn=%s total=%s\n' "$(date '+%F %T')" "$succ" "$fail" "$warn" "$total" >>"$LOG"
exit 0

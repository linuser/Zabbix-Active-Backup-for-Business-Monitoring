#!/bin/sh
# abb_daily_summary.sh — Write daily summary line to export.log
# Runs on Synology.  Cron: 55 23 * * *
set -eu

CSV_PATH="${ABB_DIR:-/volume1/monitoring/abb}"
STATS="${CSV_PATH}/ActiveBackupStats.csv"
LOG="${CSV_PATH}/export.log"

[ -f "$STATS" ] || { echo "Stats CSV missing: $STATS" >&2; exit 1; }

# Single-pass: read row 2 (only data row), all 4 fields
summary="$(awk -F',' 'NR==2{printf "success=%s fail=%s warn=%s running=%s total=%d",$1,$2,$3,$4,$1+$2+$3+$4}' "$STATS")"

printf '%s [DAILY] %s\n' "$(date '+%F %T')" "$summary" >>"$LOG"

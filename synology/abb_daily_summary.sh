#!/bin/sh
# abb_daily_summary.sh — Write daily summary line to export.log
# Runs on Synology.  Cron: 55 23 * * *
set -eu

CSV_PATH="${ABB_DIR:-/volume1/monitoring/abb}"
STATS="${CSV_PATH}/ActiveBackupStats.csv"
LOG="${CSV_PATH}/export.log"

[ -f "$STATS" ] || { echo "Stats CSV missing: $STATS" >&2; exit 1; }

# Single-pass: read row 2 (only data row), all 4 fields.
# NF>=4 guards against a header-only file (e.g. after a failed export),
# which would otherwise log an empty [DAILY] line.
summary="$(awk -F',' 'NR==2 && NF>=4{printf "success=%d fail=%d warn=%d running=%d total=%d",$1,$2,$3,$4,$1+$2+$3+$4}' "$STATS")"

if [ -z "$summary" ]; then
  printf '%s [DAILY] ERROR no data row in %s\n' "$(date '+%F %T')" "$STATS" >>"$LOG"
  exit 1
fi

printf '%s [DAILY] %s\n' "$(date '+%F %T')" "$summary" >>"$LOG"

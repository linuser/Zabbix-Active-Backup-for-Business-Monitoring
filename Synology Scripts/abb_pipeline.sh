#!/bin/sh
# Synology ABB Pipeline: Export + Enhance (Option B) + Rechte + Logging
# Läuft im DSM Aufgabenplaner als ein Task.
umask 022
set -eu

# Pfade anpassen falls nötig
ABB_DIR="${ABB_DIR:-/volume1/monitoring/abb}"
EXPORT="${EXPORT:-/volume1/scripts/abb_export.sh}"
ENHANCE="${ENHANCE:-/volume1/scripts/abb_export_enhance_last_success.sh}"
LOG="${LOG:-$ABB_DIR/export.log}"

# Logging aktivieren
mkdir -p "$ABB_DIR"
touch "$LOG"
chmod 0644 "$LOG"
exec >>"$LOG" 2>&1

echo "==== $(date -Iseconds) :: START ===="

# 1) Export fahren
if [ ! -x "$EXPORT" ]; then
  echo "ERR: EXPORT script not executable: $EXPORT"
  exit 1
fi
echo "[EXPORT] running: $EXPORT"
"$EXPORT"

# 2) Enhance fahren (LAST_SUCCESS_TS pflegen)
if [ ! -x "$ENHANCE" ]; then
  echo "ERR: ENHANCE script not executable: $ENHANCE"
  exit 1
fi
echo "[ENHANCE] running: $ENHANCE (ABB_DIR=$ABB_DIR)"
ABB_DIR="$ABB_DIR" "$ENHANCE"

# 3) Rechte konsistent setzen
chmod 0644 "$ABB_DIR"/*.csv "$ABB_DIR"/.abb_last_success.state 2>/dev/null || true
[ -f "$ABB_DIR/ActiveBackupExport.csv.bak" ] && chmod 0644 "$ABB_DIR/ActiveBackupExport.csv.bak" || true

# 4) Abschluss
if [ -f "$ABB_DIR/ActiveBackupExport.csv" ]; then
  ts_now="$(date +%s)"
  ts_file="$(stat -c %Y "$ABB_DIR/ActiveBackupExport.csv" 2>/dev/null || stat -t "$ABB_DIR/ActiveBackupExport.csv" | awk '{print $13}')"
  echo "[CHECK] file age: $((ts_now - ts_file)) s"
fi

echo "==== $(date -Iseconds) :: END ===="

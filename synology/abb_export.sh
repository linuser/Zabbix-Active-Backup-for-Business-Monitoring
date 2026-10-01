#!/bin/sh
# abb_export.sh — Export ABB data from SQLite to CSV, enrich with LAST_SUCCESS_TS
# Runs on Synology (BusyBox/ash). Single script replaces export + enhance.
#
# Status codes (ABB):
#   1=Running  2=Success  3=Aborted  4=Error  5=Warning  8=Partial
#
# Cron:  */5 * * * *  /volume1/monitoring/scripts/abb_export.sh
#
# Maintainer: Alexander Fox | PlaNet Fox

set -eu
umask 022

###############################################################################
# Configuration (all overridable via environment)
###############################################################################
CSV_PATH="${ABB_DIR:-/volume1/monitoring/abb}"
DB_DIR="${ABB_DB_DIR:-/volume1/@ActiveBackup}"
SQLITE="${ABB_SQLITE:-/usr/bin/sqlite3}"
LOG="${CSV_PATH}/export.log"
LOG_MAX_LINES="${ABB_LOG_MAX:-2000}"
WARN_AS_SUCCESS="${WARN_AS_SUCCESS:-1}"

CSV_EXPORT="${CSV_PATH}/ActiveBackupExport.csv"
CSV_HOSTS="${CSV_PATH}/ActiveBackupHostExport.csv"
CSV_STATS="${CSV_PATH}/ActiveBackupStats.csv"
STATE="${CSV_PATH}/.abb_last_success.state"

###############################################################################
# Temp files + cleanup trap
###############################################################################
TMP_EXPORT="${CSV_EXPORT}.tmp.$$"
TMP_HOSTS="${CSV_HOSTS}.tmp.$$"
TMP_STATS="${CSV_STATS}.tmp.$$"
# Enhance-step temps — PID-unique so overlapping runs never share a filename
# (a run that exits early must not delete an active run's work).
BAK_EXPORT="${CSV_EXPORT}.bak.$$"
TMP_ENH="${CSV_EXPORT}.enh.$$"
TMP_STATE="${STATE}.tmp.$$"

# Serialize runs: cron does not, and a slow run (busy DB, full sync) could
# overlap the next tick and race on the shared state file. mkdir is atomic on
# POSIX filesystems and available in BusyBox.
LOCK_DIR="${CSV_PATH}/.abb_export.lock"
LOCK_HELD=0

cleanup() {
  rm -f "$TMP_EXPORT" "$TMP_HOSTS" "$TMP_STATS" \
        "${TMP_EXPORT}.sql" "${TMP_HOSTS}.sql" "${TMP_STATS}.sql" \
        "$BAK_EXPORT" "$TMP_ENH" "$TMP_STATE" 2>/dev/null || true
  if [ "$LOCK_HELD" = "1" ]; then
    # Nur freigeben, wenn die pid im Lock noch unsere ist. Sonst hat ein
    # anderer Lauf den Lock inzwischen uebernommen und wir wuerden ihm den
    # Lock unter den Fuessen wegraeumen.
    if [ "$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo '')" = "$$" ]; then
      rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
      rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

###############################################################################
# Helpers
###############################################################################
log() { printf '%s [EXPORT] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

write_atomic() {
  # $1=destination  $2=tempfile
  sync
  mv -f "$2" "$1"
}

# run_export — execute one SQL query safely into a CSV.
#   $1=db  $2=header  $3=query  $4=dest  $5=tmp
# sqlite is run WITHOUT a pipe so its real exit status is checked. On any
# failure (e.g. "database is locked") the previous CSV is left untouched
# instead of being atomically replaced by an empty/partial file.
run_export() {
  _db="$1"; _hdr="$2"; _q="$3"; _dest="$4"; _tmp="$5"
  _raw="${_tmp}.sql"
  if ! "$SQLITE" -csv -noheader "$_db" "$_q" > "$_raw" 2>>"$LOG"; then
    rm -f "$_raw"
    log "ERROR sqlite query failed (db=${_db}); keeping previous $(basename "$_dest")"
    return 1
  fi
  {
    printf '%s\n' "$_hdr"
    awk '{gsub(/\r$/,""); print}' "$_raw"
  } > "$_tmp"
  rm -f "$_raw"
  write_atomic "$_dest" "$_tmp"
}

rotate_log() {
  [ -f "$LOG" ] || return 0
  lines="$(wc -l < "$LOG")"
  if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
    tail -n "$(( LOG_MAX_LINES / 2 ))" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
  fi
}

###############################################################################
# Checks
###############################################################################
[ -x "$SQLITE" ]               || { echo "sqlite3 not found: $SQLITE" >&2; exit 1; }
[ -r "${DB_DIR}/activity.db" ] || { echo "activity.db not readable: ${DB_DIR}/activity.db" >&2; exit 1; }
[ -r "${DB_DIR}/config.db" ]   || { echo "config.db not readable: ${DB_DIR}/config.db" >&2; exit 1; }
[ -d "$CSV_PATH" ]             || mkdir -p "$CSV_PATH"

###############################################################################
# Acquire lock (skip this run if another is active)
###############################################################################
if mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_HELD=1
else
  oldpid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo '')"
  if [ -z "$oldpid" ]; then
    # Zwischen mkdir und dem Schreiben der pid liegt ein kurzes Fenster. Eine
    # leere pid-Datei sofort als verwaist zu werten, liess beide Laeufe
    # parallel weiterlaufen. Einmal nachfassen.
    sleep 1
    oldpid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo '')"
  fi
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    log "another export (pid=$oldpid) is active; skipping this run"
    exit 0
  fi
  # Previous run died without releasing the lock — take it over.
  log "WARN stale lock (pid=${oldpid:-unknown}); taking over"
  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
  else
    log "lock race lost; skipping this run"
    exit 0
  fi
fi
echo "$$" > "${LOCK_DIR}/pid"

###############################################################################
# Export 1: Latest result per device
# Columns: DEVICEID,HOSTNAME,STATUS,BYTES,DURATION,TS
# NOTE: commas in device_name are replaced with spaces so the value cannot
# break the naive comma-split parsing used by the Zabbix side.
#
# GROUP BY config_device_id in der aeusseren Query: haben zwei Ergebniszeilen
# desselben Geraets exakt dasselbe time_end, lieferte der JOIN beide — das
# Geraet stand doppelt in der CSV, was in Zabbix ein LLD-Duplikat erzeugt und
# device_count verfaelscht. GROUP BY garantiert genau eine Zeile je Geraet.
# Bewusst ohne rowid geloest: ABBs Schema ist von hier aus nicht einsehbar,
# und bei einer WITHOUT-ROWID-Tabelle gaebe es rowid nicht.
#
# COALESCE(time_end, 0) im Sub-Select und im JOIN: hat ein Geraet AUSSCHLIESS-
# LICH Zeilen mit time_end IS NULL (erstes Backup laeuft noch, nie beendet),
# war MAX(time_end) NULL und die JOIN-Bedingung nie wahr — das Geraet fiel
# komplett aus der CSV und damit aus der Discovery.
###############################################################################
Q_LATEST="
  WITH latest AS (
    SELECT r.config_device_id,
           r.device_name,
           r.status,
           COALESCE(r.transfered_bytes, 0)  AS bytes,
           COALESCE(r.time_start, 0)        AS tstart,
           COALESCE(r.time_end, 0)          AS tend
    FROM device_result_table r
    JOIN (
      SELECT config_device_id, MAX(COALESCE(time_end, 0)) AS max_end
      FROM device_result_table
      GROUP BY config_device_id
    ) m ON r.config_device_id      = m.config_device_id
       AND COALESCE(r.time_end, 0) = m.max_end
  )
  SELECT config_device_id,
         REPLACE(REPLACE(IFNULL(device_name,''), '\"', ''), ',', ' '),
         IFNULL(status, 99),
         bytes,
         CASE WHEN tend > 0 AND tstart > 0 AND tend >= tstart
              THEN (tend - tstart) ELSE 0 END,
         MAX(tend)
  FROM latest GROUP BY config_device_id ORDER BY config_device_id ASC;
"

EXPORT_OK=1
run_export "${DB_DIR}/activity.db" \
  "DEVICEID,HOSTNAME,STATUS,BYTES,DURATION,TS" \
  "$Q_LATEST" "$CSV_EXPORT" "$TMP_EXPORT" || EXPORT_OK=0

###############################################################################
# Export 2: Device master data
# Columns: DEVICEID,HOSTNAME,BACKUPTYPE
###############################################################################
Q_HOSTS="
  SELECT device_id,
         REPLACE(REPLACE(IFNULL(host_name,''), '\"', ''), ',', ' '),
         IFNULL(backup_type,'')
  FROM device_table ORDER BY device_id ASC;
"
run_export "${DB_DIR}/config.db" \
  "DEVICEID,HOSTNAME,BACKUPTYPE" \
  "$Q_HOSTS" "$CSV_HOSTS" "$TMP_HOSTS" || true

###############################################################################
# Export 3: Today's totals
# Columns: Successful,Failed,Warning,Running
###############################################################################
EPOCH_NOW="$(date +%s)"
TODAY_START=""
TODAY_START="$(date -d '00:00:00' +%s 2>/dev/null)" || true
if [ -z "$TODAY_START" ]; then
  TODAY_START="$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)" || true
fi
if [ -z "$TODAY_START" ]; then
  # Portable fallback (BusyBox/POSIX ash safe — no 10# base prefix,
  # strip a single leading zero to avoid octal interpretation of 08/09).
  H="$(date +%H)"; M="$(date +%M)"; S="$(date +%S)"
  H="${H#0}"; M="${M#0}"; S="${S#0}"
  TODAY_START=$(( EPOCH_NOW - ( ${H:-0} * 3600 + ${M:-0} * 60 + ${S:-0} ) ))
fi
TOMORROW_START=$((TODAY_START + 86400))

Q_STATS="
  SELECT
    IFNULL(SUM(CASE WHEN status IN (2,8) THEN 1 ELSE 0 END), 0),
    IFNULL(SUM(CASE WHEN status IN (3,4) THEN 1 ELSE 0 END), 0),
    IFNULL(SUM(CASE WHEN status = 5      THEN 1 ELSE 0 END), 0),
    IFNULL(SUM(CASE WHEN status = 1      THEN 1 ELSE 0 END), 0)
  FROM device_result_table
  WHERE time_end >= ${TODAY_START} AND time_end < ${TOMORROW_START};
"
run_export "${DB_DIR}/activity.db" \
  "Successful,Failed,Warning,Running" \
  "$Q_STATS" "$CSV_STATS" "$TMP_STATS" || true

###############################################################################
# Enhance: Add LAST_SUCCESS_TS column (7th field)
# Skipped if the main export failed, so the old CSV's mtime stays old and the
# Zabbix freshness check can still detect the stall.
###############################################################################
if [ "$EXPORT_OK" = "1" ]; then
  # Ensure state file
  [ -f "$STATE" ] || echo "DEVICEID,LAST_SUCCESS_TS" > "$STATE"

  # Backup before modifying
  cp -f "$CSV_EXPORT" "$BAK_EXPORT"

  # Update state: newest TS if success (2/8) or optionally warning (5).
  # Also prune: only devices present in the current export are carried forward,
  # so entries for removed devices don't accumulate indefinitely.
  #
  # ABER: nur prunen, wenn der Export ueberhaupt Datenzeilen hat. Ein
  # erfolgreicher, aber leerer Export (z. B. nach einem Retention-Cleanup in
  # ABB) haette sonst JEDEN LAST_SUCCESS_TS geloescht – Folge waere ein
  # last_success_age von 2147483647 fuer alle Geraete, also ein HIGH-Alarm
  # pro Geraet, und der Verlust ist nicht rekonstruierbar.
  EXPORT_ROWS="$(awk 'NR>1 && NF>0 {c++} END{print c+0}' "$CSV_EXPORT")"
  PRUNE=1
  if [ "$EXPORT_ROWS" = "0" ]; then
    PRUNE=0
    log "WARN export hat 0 Datenzeilen; State wird nicht gepruned"
  fi

  awk -F',' -v OFS=',' -v warn="$WARN_AS_SUCCESS" -v prune="$PRUNE" '
    FILENAME==statefile {
      gsub(/\r/,""); if (FNR==1) next
      did=$1+0; lss=$2+0
      if (did>0) state[did]=lss
      next
    }
    FILENAME==exportfile {
      gsub(/\r/,""); if (FNR==1) next
      did=$1+0; status=$3+0; ts=$6+0
      if (did>0) present[did]=1
      if (did>0 && ts>0 && (status==2 || status==8 || (warn==1 && status==5))) {
        if (!(did in state) || ts > state[did]) state[did]=ts
      }
      next
    }
    END {
      print "DEVICEID,LAST_SUCCESS_TS"
      for (d in state) if (prune != 1 || (d in present)) print d, state[d]+0
    }
  ' statefile="$STATE" exportfile="$CSV_EXPORT" "$STATE" "$CSV_EXPORT" \
    > "$TMP_STATE" && mv "$TMP_STATE" "$STATE"

  # Rewrite export with 7th column
  awk -F',' -v OFS=',' '
    FILENAME==statefile {
      gsub(/\r/,""); if (FNR==1) next
      sid=$1+0; if (sid>0) last[sid]=$2+0
      next
    }
    FILENAME==exportfile {
      gsub(/\r/,"")
      if (FNR==1) { print "DEVICEID","HOSTNAME","STATUS","BYTES","DURATION","TS","LAST_SUCCESS_TS"; next }
      did=$1+0
      lss=(did in last ? last[did]+0 : 0)
      print $1,$2,($3+0),($4+0),($5+0),($6+0),lss
      next
    }
  ' statefile="$STATE" exportfile="$BAK_EXPORT" "$STATE" "$BAK_EXPORT" \
    > "$TMP_ENH" && mv "$TMP_ENH" "$CSV_EXPORT"

  ###############################################################################
  # Finalize
  ###############################################################################
  chmod 644 "${CSV_PATH}"/*.csv 2>/dev/null || true
  DEVICE_COUNT="$(awk 'NR>1{c++}END{print c+0}' "$CSV_EXPORT")"
  log "OK devices=$DEVICE_COUNT"
else
  chmod 644 "${CSV_PATH}"/*.csv 2>/dev/null || true
  log "ERROR main export failed; previous ActiveBackupExport.csv retained (stale)"
fi

rotate_log
exit 0

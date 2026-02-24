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

cleanup() {
  rm -f "$TMP_EXPORT" "$TMP_HOSTS" "$TMP_STATS" \
        "${CSV_EXPORT}.bak" "${CSV_EXPORT}.tmp" \
        "${STATE}.tmp" 2>/dev/null || true
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
# Export 1: Latest result per device
# Columns: DEVICEID,HOSTNAME,STATUS,BYTES,DURATION,TS
###############################################################################
{
  echo "DEVICEID,HOSTNAME,STATUS,BYTES,DURATION,TS"
  "$SQLITE" -csv -noheader "${DB_DIR}/activity.db" "
    WITH latest AS (
      SELECT r.config_device_id,
             r.device_name,
             r.status,
             COALESCE(r.transfered_bytes, 0)  AS bytes,
             COALESCE(r.time_start, 0)        AS tstart,
             COALESCE(r.time_end, 0)          AS tend
      FROM device_result_table r
      JOIN (
        SELECT config_device_id, MAX(time_end) AS max_end
        FROM device_result_table
        GROUP BY config_device_id
      ) m ON r.config_device_id = m.config_device_id
         AND r.time_end         = m.max_end
    )
    SELECT config_device_id,
           REPLACE(IFNULL(device_name,''), '\"', ''),
           IFNULL(status, 99),
           bytes,
           CASE WHEN tend > 0 AND tstart > 0 AND tend >= tstart
                THEN (tend - tstart) ELSE 0 END,
           tend
    FROM latest ORDER BY config_device_id ASC;
  " | awk '{gsub(/\r$/,""); print}'
} > "$TMP_EXPORT" && write_atomic "$CSV_EXPORT" "$TMP_EXPORT"

###############################################################################
# Export 2: Device master data
# Columns: DEVICEID,HOSTNAME,BACKUPTYPE
###############################################################################
{
  echo "DEVICEID,HOSTNAME,BACKUPTYPE"
  "$SQLITE" -csv -noheader "${DB_DIR}/config.db" "
    SELECT device_id,
           REPLACE(IFNULL(host_name,''), '\"', ''),
           IFNULL(backup_type,'')
    FROM device_table ORDER BY device_id ASC;
  " | awk '{gsub(/\r$/,""); print}'
} > "$TMP_HOSTS" && write_atomic "$CSV_HOSTS" "$TMP_HOSTS"

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
  H="$(date +%H)"; M="$(date +%M)"; S="$(date +%S)"
  TODAY_START=$((EPOCH_NOW - (10#$H * 3600 + 10#$M * 60 + 10#$S)))
fi
TOMORROW_START=$((TODAY_START + 86400))

{
  echo "Successful,Failed,Warning,Running"
  "$SQLITE" -csv -noheader "${DB_DIR}/activity.db" "
    SELECT
      IFNULL(SUM(CASE WHEN status IN (2,8) THEN 1 ELSE 0 END), 0),
      IFNULL(SUM(CASE WHEN status IN (3,4) THEN 1 ELSE 0 END), 0),
      IFNULL(SUM(CASE WHEN status = 5      THEN 1 ELSE 0 END), 0),
      IFNULL(SUM(CASE WHEN status = 1      THEN 1 ELSE 0 END), 0)
    FROM device_result_table
    WHERE time_end >= ${TODAY_START} AND time_end < ${TOMORROW_START};
  " | awk '{gsub(/\r$/,""); print}'
} > "$TMP_STATS" && write_atomic "$CSV_STATS" "$TMP_STATS"

###############################################################################
# Enhance: Add LAST_SUCCESS_TS column (7th field)
###############################################################################
# Ensure state file
[ -f "$STATE" ] || echo "DEVICEID,LAST_SUCCESS_TS" > "$STATE"

# Backup before modifying
cp -f "$CSV_EXPORT" "${CSV_EXPORT}.bak"

# Update state: newest TS if success (2/8) or optionally warning (5)
awk -F',' -v OFS=',' -v warn="$WARN_AS_SUCCESS" '
  FILENAME==statefile {
    gsub(/\r/,""); if (FNR==1) next
    did=$1+0; lss=$2+0
    if (did>0) state[did]=lss
    next
  }
  FILENAME==exportfile {
    gsub(/\r/,""); if (FNR==1) next
    did=$1+0; status=$3+0; ts=$6+0
    if (did>0 && ts>0 && (status==2 || status==8 || (warn==1 && status==5))) {
      if (!(did in state) || ts > state[did]) state[did]=ts
    }
    next
  }
  END {
    print "DEVICEID,LAST_SUCCESS_TS"
    for (d in state) print d, state[d]+0
  }
' statefile="$STATE" exportfile="$CSV_EXPORT" "$STATE" "$CSV_EXPORT" \
  > "${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"

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
' statefile="$STATE" exportfile="${CSV_EXPORT}.bak" "$STATE" "${CSV_EXPORT}.bak" \
  > "${CSV_EXPORT}.tmp" && mv "${CSV_EXPORT}.tmp" "$CSV_EXPORT"

###############################################################################
# Finalize
###############################################################################
chmod 644 "${CSV_PATH}"/*.csv 2>/dev/null || true
DEVICE_COUNT="$(awk 'NR>1{c++}END{print c+0}' "$CSV_EXPORT")"
log "OK devices=$DEVICE_COUNT"
rotate_log
exit 0

umask 022
#!/bin/sh
# /volume1/scripts/abb_export.sh
# Exportiert ABB-Daten aus den SQLite-DBs nach CSV für Zabbix.
# Läuft ohne Bash, nur BusyBox/ash, und macht atomare Writes.

###############################################################################
# Konfiguration
###############################################################################
CSV_PATH="/volume1/monitoring/abb"     # Zielverzeichnis (entspricht {$CSV.PATH})
DB_DIR="/volume1/@ActiveBackup"        # ABB-DB-Pfad (activity.db, config.db)
SQLITE="/usr/bin/sqlite3"              # Pfad zu sqlite3

# Datei-Namen
CSV_EXPORT="${CSV_PATH}/ActiveBackupExport.csv"
CSV_HOSTS="${CSV_PATH}/ActiveBackupHostExport.csv"
CSV_STATS="${CSV_PATH}/ActiveBackupStats.csv"

###############################################################################
# Checks
###############################################################################
[ -x "$SQLITE" ] || { echo "sqlite3 nicht gefunden: $SQLITE" >&2; exit 1; }
[ -r "${DB_DIR}/activity.db" ] || { echo "activity.db nicht lesbar: ${DB_DIR}/activity.db" >&2; exit 1; }
[ -r "${DB_DIR}/config.db" ]   || { echo "config.db nicht lesbar: ${DB_DIR}/config.db" >&2; exit 1; }
[ -d "$CSV_PATH" ] || mkdir -p "$CSV_PATH" || { echo "Kann CSV_PATH nicht anlegen: $CSV_PATH" >&2; exit 1; }

###############################################################################
# Helper: atomar schreiben (tmp -> mv)
###############################################################################
write_atomic() {
  # $1 = Zieldatei, $2 = Tempdatei
  local dst="$1" tmp="$2"
  sync
  mv -f "$tmp" "$dst"
}

###############################################################################
# Export 1: Letztes Ergebnis je Gerät (eine Zeile pro DEVICEID)
# Spalten:
#  DEVICEID, HOSTNAME, STATUS, BYTES, DURATION, TS
#  - STATUS: 0=OK, 1=Fehler, 2=Warnung, 3=Läuft (ABB-Statuscodes)
#  - BYTES: transfered_bytes
#  - DURATION: time_end - time_start (Sekunden)
#  - TS: time_end (Unix-Epoch)
###############################################################################
TMP_EXPORT="${CSV_EXPORT}.tmp.$$"
{
  echo "DEVICEID,HOSTNAME,STATUS,BYTES,DURATION,TS"
  # Wir wählen für jedes config_device_id den Datensatz mit maximalem time_end
  "$SQLITE" -csv -noheader "${DB_DIR}/activity.db" "
    WITH latest AS (
      SELECT r.config_device_id,
             r.device_name,
             r.status,
             COALESCE(r.transfered_bytes,0) AS bytes,
             COALESCE(r.time_start,0) AS tstart,
             COALESCE(r.time_end,0)   AS tend
      FROM device_result_table r
      JOIN (
        SELECT config_device_id, MAX(time_end) AS max_end
        FROM device_result_table
        GROUP BY config_device_id
      ) m
      ON r.config_device_id = m.config_device_id
     AND r.time_end = m.max_end
    )
    SELECT
      config_device_id,
      REPLACE(IFNULL(device_name,''), '\"', '') as device_name,
      IFNULL(status,99),
      bytes,
      CASE WHEN tend>0 AND tstart>0 AND tend>=tstart THEN (tend - tstart) ELSE 0 END AS duration,
      tend
    FROM latest
    ORDER BY config_device_id ASC;
  " | awk '{gsub(/\r$/,""); print}'
} > "$TMP_EXPORT" && write_atomic "$CSV_EXPORT" "$TMP_EXPORT"

###############################################################################
# Export 2: Geräte-Stammdaten aus config.db
# Spalten:
#  DEVICEID, HOSTNAME, BACKUPTYPE
###############################################################################
TMP_HOSTS="${CSV_HOSTS}.tmp.$$"
{
  echo "DEVICEID,HOSTNAME,BACKUPTYPE"
  "$SQLITE" -csv -noheader "${DB_DIR}/config.db" "
    SELECT
      device_id,
      REPLACE(IFNULL(host_name,''), '\"', '') as host_name,
      IFNULL(backup_type,'') as backup_type
    FROM device_table
    ORDER BY device_id ASC;
  " | awk '{gsub(/\r$/,""); print}'
} > "$TMP_HOSTS" && write_atomic "$CSV_HOSTS" "$TMP_HOSTS"

###############################################################################
# Export 3: Heutige Summen (Successful/Failed) in activity.db
# Definition:
#  Successful = status = 0
#  Failed     = status IN (1,2)
###############################################################################
# Tagesgrenzen (lokale Zeit der NAS)
EPOCH_NOW="$(date +%s)"
TODAY_START="$(date -d '00:00:00' +%s 2>/dev/null || date -j -f '%Y-%m-%d 00:00:00' "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)"
# Fallback falls BusyBox ohne -d: auf Mitternacht zurückrechnen
if [ -z "$TODAY_START" ]; then
  # Sekunden seit Mitternacht: now - (Stunde*3600 + Minute*60 + Sekunde)
  H="$(date +%H)"; M="$(date +%M)"; S="$(date +%S)"
  TODAY_START=$((EPOCH_NOW - (10#$H*3600 + 10#$M*60 + 10#$S)))
fi
TOMORROW_START=$((TODAY_START + 86400))

TMP_STATS="${CSV_STATS}.tmp.$$"
{
  echo "Successful,Failed"
  # Zähle anhand time_end in [TODAY_START, TOMORROW_START)
  "$SQLITE" -csv -noheader "${DB_DIR}/activity.db" "
    WITH today AS (
      SELECT status
      FROM device_result_table
      WHERE time_end >= ${TODAY_START}
        AND time_end <  ${TOMORROW_START}
    ),
    agg AS (
      SELECT
        SUM(CASE WHEN status = 0           THEN 1 ELSE 0 END) AS successful,
        SUM(CASE WHEN status IN (1,2)      THEN 1 ELSE 0 END) AS failed
      FROM today
    )
    SELECT IFNULL(successful,0), IFNULL(failed,0) FROM agg;
  " | awk '{gsub(/\r$/,""); print}'
} > "$TMP_STATS" && write_atomic "$CSV_STATS" "$TMP_STATS"

chmod 644 /volume1/monitoring/abb/*.csv 2>/dev/null || true
###############################################################################
# Ende
###############################################################################
exit 0
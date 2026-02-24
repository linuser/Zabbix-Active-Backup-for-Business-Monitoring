#!/bin/sh
# --------------------------------------------------------------------
#  Synology Active Backup for Business - Unified External Script
#  Maintainer: Alexander Fox | PlaNet Fox ❤️
# --------------------------------------------------------------------
set -eu

CSV="${ABB_CSV_PATH:-/mnt/synology/monitoring/abb}"
CSV_FILE="$CSV/ActiveBackupExport.csv"
DEBUG="${ABB_DEBUG:-0}"

log_debug(){ [ "$DEBUG" = "1" ] && echo "DEBUG: $*" >&2 || true; }

file_age(){
  f="$1"; [ -f "$f" ] || { echo 999999; return; }
  now=$(date +%s); mt=$(stat -c %Y "$f" 2>/dev/null || echo 0); echo $((now-mt))
}

case "${1:-}" in
  check)
    MAX="${2:-900}"; MP="${3:-/mnt/synology/monitoring}"; REM="${4:-}"; FST="${5:-}"
    fm=$(findmnt -rno SOURCE,FSTYPE,TARGET -T "$CSV_FILE" 2>/dev/null || true)
    [ -z "$fm" ] && fm=$(findmnt -rno SOURCE,FSTYPE,TARGET "$MP" 2>/dev/null || true)
    SRC=$(echo "$fm" | awk '{print $1}'); FSTYPE=$(echo "$fm" | awk '{print $2}'); TGT=$(echo "$fm" | awk '{print $3}')
    log_debug "findmnt(-T file): $fm"

    if echo "$SRC $FSTYPE" | grep -q autofs; then
      log_debug "autofs detected; skipping strict remote/fstype compare"
    else
      [ -n "$REM" ] && [ "$SRC" != "$REM" ] && { log_debug "SRC mismatch: $SRC != $REM"; exit 1; }
      [ -n "$FST" ] && [ "$FSTYPE" != "$FST" ] && { log_debug "FST mismatch: $FSTYPE != $FST"; exit 1; }
    fi

    if ! sudo -u zabbix test -r "$CSV_FILE" 2>/dev/null; then
      log_debug "File not readable by zabbix"; exit 1
    fi

    AGE=$(file_age "$CSV_FILE"); log_debug "READABLE=yes AGE=$AGE"
    [ "$AGE" -gt "$MAX" ] && exit 1
    echo 0
    ;;

  discovery)
    H="$CSV/ActiveBackupHostExport.csv"
    if [ ! -r "$H" ]; then echo '{"data":[]}'; exit 0; fi
    awk -F, 'NR>1{gsub(/"/,"\\\"",$2);printf "%s{\"{#DEVICEID}\":\"%s\",\"{#HOSTNAME}\":\"%s\"}",(n++?",":""),$1,$2}END{print ""}' "$H" \
      | sed '1s/^/{\"data\":[/;$s/$/]}/'
    ;;

  status) id="${2:-}";    awk -F, -v id="$id" 'NR>1&&$1==id{print $3; f=1}END{if(!f)print 0}' "$CSV_FILE" ;;
  bytes)  id="${2:-}";    awk -F, -v id="$id" 'NR>1&&$1==id{print $4; f=1}END{if(!f)print 0}' "$CSV_FILE" ;;
  duration) id="${2:-}";  awk -F, -v id="$id" 'NR>1&&$1==id{print $5; f=1}END{if(!f)print 0}' "$CSV_FILE" ;;
  lastsuccess_age)
    id="${2:-}"; now=$(date +%s)
    awk -F, -v id="$id" -v now="$now" 'NR>1&&$1==id{ls=$7+0; print (ls>0&&ls<now? now-ls : 2147483647); f=1}END{if(!f)print 2147483647}' "$CSV_FILE"
    ;;
  device_count)   awk 'NR>1{c++}END{print c+0}' "$CSV_FILE" ;;
  success_today)  awk -F, 'NR>1&&$3==2{c++}END{print c+0}' "$CSV_FILE" ;;
  failed_today)   awk -F, 'NR>1&&$3!=2{c++}END{print c+0}' "$CSV_FILE" ;;
  failed_list)    awk -F, 'NR>1&&$3!=2{printf "%s%s",s,$2; s=","}END{print ""}' "$CSV_FILE" ;;
  *) echo "Usage: $0 {check MAXAGE MOUNT REMOTE FSTYPE | discovery | status ID | bytes ID | duration ID | lastsuccess_age ID | device_count | success_today | failed_today | failed_list}" >&2; exit 1;;
esac

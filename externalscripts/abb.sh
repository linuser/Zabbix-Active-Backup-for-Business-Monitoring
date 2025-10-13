#!/bin/sh
# abb.sh - Unified external checks for Synology Active Backup for Business (ABB)
# Compatible with /bin/sh (dash, BusyBox). No bashisms.
# Author: Alexander Fox | PlaNet Fox (2025-10)
# Version: 1.6 (Full)

# --------------------------------------------------------------------
# ENVIRONMENT
# --------------------------------------------------------------------
CSV="${ABB_CSV_PATH:-/mnt/synology/monitoring/abb}"
EXP="$CSV/ActiveBackupExport.csv"
HST="$CSV/ActiveBackupHostExport.csv"

# --------------------------------------------------------------------
# Helper: print help
# --------------------------------------------------------------------
print_help() {
  cat <<'EOF'
abb.sh - Unified external checks for Synology Active Backup for Business (ABB)

Environment:
  ABB_CSV_PATH       (default: /mnt/synology/monitoring/abb)
  ABB_MOUNTPOINT     (optional, for "check")
  ABB_EXPECT_REMOTE  (optional, for "check")
  ABB_EXPECT_FSTYPE  (optional, for "check")

Usage (subcommands):
  check [MAXAGE] [MOUNTPOINT] [EXPECT_REMOTE] [EXPECT_FSTYPE]
  discovery
  status <DEVICEID>
  bytes <DEVICEID>
  duration <DEVICEID>
  lastsuccess_age <DEVICEID>
  repo_bytes <DEVICEID>
  device_count
  sum_bytes
  sum_repo_bytes
  success_today
  failed_today
  failed_count
  failed_list
  warn_count
  notok_count
  notok_list
  missing_count [MAXAGE]
  missing_list  [MAXAGE]
  ok_count  [MAXAGE]
  ok_list   [MAXAGE]
  maybe_offline_count
  maybe_offline_list

Exit codes:
  0 = OK / value printed
  1 = problem / cannot read CSVs / freshness failed
EOF
}

# --------------------------------------------------------------------
# Helper: read CSV safely
# --------------------------------------------------------------------
need_csv() {
  if [ ! -r "$EXP" ]; then
    echo "0"
    exit 1
  fi
}

# --------------------------------------------------------------------
# Main case switch
# --------------------------------------------------------------------
case "$1" in
# --------------------------------------------------------------------
check)
  MAX="${2:-900}"
  MP="${3:-${ABB_MOUNTPOINT:-/mnt/synology/monitoring}}"
  REM="${4:-${ABB_EXPECT_REMOTE:-192.168.33.2:/volume1/monitoring}}"
  FST="${5:-${ABB_EXPECT_FSTYPE:-nfs}}"

  # Mountpoint valid?
  SRC=$(findmnt -no SOURCE "$MP" 2>/dev/null)
  TYPE=$(findmnt -no FSTYPE "$MP" 2>/dev/null)
  if [ "$SRC" != "$REM" ] || [ "$TYPE" != "$FST" ]; then
    echo 1; exit
  fi

  # CSV fresh?
  if [ ! -r "$EXP" ]; then echo 1; exit; fi
  now=$(date +%s)
  mtime=$(stat -c %Y "$EXP" 2>/dev/null || echo 0)
  age=$((now - mtime))
  [ "$age" -le "$MAX" ] && echo 0 || echo 1
  exit;;
# --------------------------------------------------------------------
discovery)
  need_csv
  echo '{"data":['
  awk -F, 'NR>1{printf "%s{\"{#DEVICEID}\":\"%s\",\"{#HOSTNAME}\":\"%s\"}",(NR==2?"":","),$1,$2}END{print "]"}' "$HST"
  echo '}'
  exit;;
# --------------------------------------------------------------------
status)
  need_csv
  awk -F, -v id="$2" 'NR>1 && $1==id{print $3+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
bytes)
  need_csv
  awk -F, -v id="$2" 'NR>1 && $1==id{print $4+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
duration)
  need_csv
  awk -F, -v id="$2" 'NR>1 && $1==id{print $5+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
lastsuccess_age)
  need_csv
  now=$(date +%s)
  awk -F, -v id="$2" -v now="$now" '
    NR>1 && $1==id { ts=$7+0; if(ts>0) print now-ts; else print 4294967295 }' "$EXP"
  exit;;
# --------------------------------------------------------------------
repo_bytes)
  need_csv
  awk -F, -v id="$2" 'NR>1 && $1==id{print $8+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
device_count)
  need_csv
  awk -F, 'NR>1{c++}END{print c+0}' "$HST"
  exit;;
# --------------------------------------------------------------------
sum_bytes)
  need_csv
  awk -F, 'NR>1{s+=$4}END{print s+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
sum_repo_bytes)
  need_csv
  awk -F, 'NR>1{s+=$8}END{print s+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
success_today)
  need_csv
  today=$(date -d "00:00" +%s)
  awk -F, -v t="$today" 'NR>1 && $3==2 && $6>=t{c++}END{print c+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
failed_today)
  need_csv
  today=$(date -d "00:00" +%s)
  awk -F, -v t="$today" 'NR>1 && $3==4 && $6>=t{c++}END{print c+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
failed_count)
  need_csv
  awk -F, 'NR>1 && $3==4{c++}END{print c+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
failed_list)
  need_csv
  awk -F, 'NR>1 && $3==4{printf "%s status=%s duration=%s bytes=%s ts=%s\n",$2,$3,$5,$4,$6}' "$EXP"
  exit;;
# --------------------------------------------------------------------
warn_count)
  need_csv
  awk -F, 'NR>1 && $3==5{c++}END{print c+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
notok_count)
  need_csv
  awk -F, 'NR>1 && ($3==4||$3==5){c++}END{print c+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
notok_list)
  need_csv
  awk -F, 'NR>1 && ($3==4||$3==5){printf "%s status=%s duration=%s bytes=%s ts=%s\n",$2,$3,$5,$4,$6}' "$EXP"
  exit;;
# --------------------------------------------------------------------
missing_count)
  need_csv
  MAX="${2:-900}"
  now=$(date +%s)
  awk -F, -v now="$now" -v max="$MAX" '
    FNR==NR {
      if(NR>1){
        id=$1; ts=$6+0
        if(ts>0 && (now-ts)<=max) fresh[id]=1
      } next
    }
    NR>1 && !($1 in fresh){c++}
    END{print c+0}
  ' "$EXP" "$HST"
  exit;;
# --------------------------------------------------------------------
missing_list)
  need_csv
  MAX="${2:-900}"
  now=$(date +%s)
  awk -F, -v now="$now" -v max="$MAX" '
    FNR==NR {
      if(NR>1){
        id=$1; ts=$6+0
        if(ts>0 && (now-ts)<=max) fresh[id]=1
      } next
    }
    NR>1 {
      id=$1; host=$2
      if(!(id in fresh)) printf "%s deviceid=%s no-fresh-export\n", host, id
    }
  ' "$EXP" "$HST"
  exit;;
# --------------------------------------------------------------------
ok_count)
  need_csv
  MAX="${2:-0}"
  if [ "$MAX" -gt 0 ] 2>/dev/null; then
    now=$(date +%s)
    awk -F, -v now="$now" -v max="$MAX" 'NR>1 && $3==2 && (now-$6)<=max{c++}END{print c+0}' "$EXP"
  else
    awk -F, 'NR>1 && $3==2{c++}END{print c+0}' "$EXP"
  fi
  exit;;
# --------------------------------------------------------------------
ok_list)
  need_csv
  MAX="${2:-0}"
  if [ "$MAX" -gt 0 ] 2>/dev/null; then
    now=$(date +%s)
    awk -F, -v now="$now" -v max="$MAX" '
      NR>1 && $3==2 && (now-$6)<=max{
        printf "%s duration=%s bytes=%s ts=%s\n",$2,$5,$4,$6
      }' "$EXP"
  else
    awk -F, 'NR>1 && $3==2{
      printf "%s duration=%s bytes=%s ts=%s\n",$2,$5,$4,$6
    }' "$EXP"
  fi
  exit;;
# --------------------------------------------------------------------
maybe_offline_count)
  need_csv
  awk -F, 'NR>1 && $3==4 && $4==0 && $5<60{c++}END{print c+0}' "$EXP"
  exit;;
# --------------------------------------------------------------------
maybe_offline_list)
  need_csv
  awk -F, 'NR>1 && $3==4 && $4==0 && $5<60{
    printf "%s duration=%s bytes=%s ts=%s\n",$2,$5,$4,$6
  }' "$EXP"
  exit;;
# --------------------------------------------------------------------
*)
  print_help
  exit 1;;
esac

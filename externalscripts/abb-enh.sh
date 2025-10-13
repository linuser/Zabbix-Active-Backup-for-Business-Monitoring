#!/usr/bin/env sh
# Wrapper-Enhancements für Synology ABB (kompatibel zu /bin/sh)
# - status_text <ID>     -> OK / WARNING / ERROR (abb.sh: 2=OK, 4=ERROR, 5=WARNING)
# - notok_list           -> Tabelle aller Warnungen/Fehler
# - notok_list_verbose   -> wie oben + REASON (export.log oder CSV-Fallback)
set -eu

ABB="${ABB_BIN:-/usr/lib/zabbix/externalscripts/abb.sh}"
CSV_PATH="${ABB_CSV_PATH:-/mnt/synology/monitoring/abb}"
LOG="$CSV_PATH/export.log"
EXP="$CSV_PATH/ActiveBackupExport.csv"

# ---------------------------------------------------------------
status_text_cmd() {
  id="${1:-}"; [ -n "$id" ] || { echo "ERR: missing ID" >&2; return 2; }
  s="$("$ABB" status "$id" 2>/dev/null || echo "")"
  case "$s" in
    2) echo "OK" ;;
    5) echo "WARNING" ;;
    4) echo "ERROR" ;;
    "") echo "STATE_NA" ;;
    *) echo "STATE_$s" ;;
  esac
}

fmt_dur() {
  d="${1:-}"
  case "$d" in
    ''|*[!0-9]* ) printf "%s" "$d" ;;
    *) h=$((d/3600)); m=$(((d%3600)/60)); s=$((d%60)); printf "%02dh%02dm%02ds" "$h" "$m" "$s" ;;
  esac
}

# ---------------------------------------------------------------
# Discovery (ohne jq) -> Zeilen "ID<TAB>HOST"
discover_ids_hosts() {
  "$ABB" discovery 2>/dev/null | \
    awk -v RS=',' '
      /"{#DEVICEID}":/ {gsub(/[^0-9]/,""); printf "ID:%s\n",$0}
      /"{#HOSTNAME}":/ {sub(/.*"{#HOSTNAME}":"?/,""); sub(/".*/,""); printf "HN:%s\n",$0}
    ' | paste - - | sed -E 's/^ID:([0-9]+).*HN:(.*)$/\1\t\2/'
}

# ---------------------------------------------------------------
print_notok_list() {
  printf "%-4s  %-30s  %-8s  %-10s  %-12s\n" "ID" "HOST" "STATUS" "DURATION" "BYTES"
  discover_ids_hosts | while IFS="$(printf '\t')" read -r id host; do
    s="$("$ABB" status "$id" 2>/dev/null || echo 0)"
    case "$s" in 4|5) : ;; *) continue ;; esac
    st="$(status_text_cmd "$id")"
    d="$("$ABB" duration "$id" 2>/dev/null || echo 0)"; dur="$(fmt_dur "$d")"
    b="$("$ABB" bytes "$id" 2>/dev/null || echo 0)"
    printf "%-4s  %-30s  %-8s  %-10s  %-12s\n" "$id" "$host" "$st" "$dur" "$b"
  done
}

# ---------------------------------------------------------------
print_notok_list_verbose() {
  printf "%-4s  %-30s  %-8s  %-10s  %-12s  %s\n" "ID" "HOST" "STATUS" "DURATION" "BYTES" "REASON"
  discover_ids_hosts | while IFS="$(printf '\t')" read -r id host; do
    s="$("$ABB" status "$id" 2>/dev/null || echo 0)"
    case "$s" in 4|5) : ;; *) continue ;; esac
    st="$(status_text_cmd "$id")"
    d="$("$ABB" duration "$id" 2>/dev/null || echo 0)"; dur="$(fmt_dur "$d")"
    b="$("$ABB" bytes "$id" 2>/dev/null || echo 0)"

    reason="-"

    # 1) export.log (letzte Zeile zum Host)
    if [ -r "$LOG" ]; then
      lastlog="$(grep -F "$host" "$LOG" 2>/dev/null | tail -1 || true)"
      [ -n "${lastlog:-}" ] && reason="$lastlog"
    fi

    # 2) CSV-Fallback (letzte Zeile zur Device-ID)
    if [ "$reason" = "-" ] && [ -r "$EXP" ]; then
      lastcsv="$(grep -F ",$id," "$EXP" 2>/dev/null | tail -1 || true)"
      [ -n "${lastcsv:-}" ] && reason="$lastcsv"
    fi

    # 3) Klartext-Fallback für "Warning ohne Lauf" (0s/0B)
    s_num="${s:-0}"; d_num="${d:-0}"; b_num="${b:-0}"
    case "$s_num" in ''|*[!0-9]* ) s_num=0 ;; esac
    case "$d_num" in ''|*[!0-9]* ) d_num=0 ;; esac
    case "$b_num" in ''|*[!0-9]* ) b_num=0 ;; esac
    if [ "$reason" = "-" ] && [ "$s_num" -eq 5 ] && [ "$d_num" -eq 0 ] && [ "$b_num" -eq 0 ]; then
      reason="WARNING without run (duration=0, bytes=0) — likely skipped/not started"
    fi

    # 4) Falls immer noch leer/Minus, setze neutrale Reason
    [ -n "$reason" ] || reason="-"

    printf "%-4s  %-30s  %-8s  %-10s  %-12s  %s\n" "$id" "$host" "$st" "$dur" "$b" "$reason"
  done
}

# ---------------------------------------------------------------
usage(){ echo "Usage: $(basename "$0") {status_text <ID>|notok_list|notok_list_verbose}"; exit 2; }

cmd="${1:-}"; shift || true
case "$cmd" in
  status_text) [ -n "${1:-}" ] || usage; status_text_cmd "$1" ;;
  notok_list)  print_notok_list ;;
  notok_list_verbose) print_notok_list_verbose ;;
  *) usage ;;
esac

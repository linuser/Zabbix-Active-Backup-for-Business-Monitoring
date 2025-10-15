#!/bin/sh
# abb.sh - Unified external checks for Synology Active Backup for Business (ABB)
# Shell: POSIX /bin/sh (keine Bash-Features)
# Liest /mnt/synology/monitoring/abb/ActiveBackupExport.csv (oder ABB_CSV_PATH)
# und liefert Werte für Discovery/Items/Trigger.

# -------- Konfiguration / Env --------
CSV_DIR="${ABB_CSV_PATH:-/mnt/synology/monitoring/abb}"
CSV_FILE="$CSV_DIR/ActiveBackupExport.csv"
DEBUG="${ABB_DEBUG:-0}"

# -------- Hilfen --------
dlog() { [ "$DEBUG" = "1" ] && echo "DEBUG: $*" >&2 || true; }
fail() { echo "$*" >&2; exit 1; }

# CSV im RAM normalisieren, falls nur 6 Spalten vorhanden (fügt LAST_SUCCESS_TS an)
WORK="/tmp/abb_norm.$$"
trap 'rm -f "$WORK" 2>/dev/null || true' EXIT

normalize_if_needed() {
    # Wenn Datei fehlt, hier nicht abbrechen – der Aufrufer entscheidet.
    [ -r "$CSV_FILE" ] || { dlog "CSV not readable: $CSV_FILE"; return; }

    NF="$(awk -F, 'NR==1{print NF; exit}' "$CSV_FILE" 2>/dev/null || echo 0)"
    if [ "$NF" -eq 6 ]; then
        dlog "Normalizing 6->7 columns (add LAST_SUCCESS_TS)..."
        awk -F, -v OFS=, '
          NR==1 { print "DEVICEID","HOSTNAME","STATUS","BYTES","DURATION","TS","LAST_SUCCESS_TS"; next }
          NR>1  { st=$3+0; ts=$6+0; last=((st==2||st==8)?ts:0); print $1,$2,st,$4+0,$5+0,ts,last }
        ' "$CSV_FILE" > "$WORK" 2>/dev/null || return
        CSV_FILE="$WORK"  # ab jetzt die RAM-Kopie verwenden
    elif [ "$NF" -eq 7 ]; then
        dlog "CSV has 7 columns already."
    else
        dlog "Unexpected header column count: NF=$NF"
    fi
}

# 0=OK, 1=Problem
check_health() {
    MAX_AGE="$1"    # Sekunden
    MOUNT="$2"      # z.B. /mnt/synology/monitoring
    REMOTE="$3"     # z.B. 192.168.33.2:/volume1/monitoring
    FSTYPE="$4"     # z.B. nfs

    # Versuch 1: auf Basis der Datei (meist korrekt, auch mit Autofs)
    OUT_FILE="$(findmnt -rno SOURCE,FSTYPE,TARGET -T "$CSV_FILE" 2>/dev/null || true)"
    SRC_ACT="$(echo "$OUT_FILE" | awk 'NR==1{print $1}')"
    FST_ACT="$(echo "$OUT_FILE" | awk 'NR==1{print $2}')"
    TGT_ACT="$(echo "$OUT_FILE" | awk 'NR==1{print $3}')"
    dlog "findmnt(-T file): $SRC_ACT $FST_ACT $TGT_ACT"

    # Fallback 1: auf Basis des Verzeichnisses
    if [ -z "$SRC_ACT" ] || [ -z "$FST_ACT" ]; then
        OUT_DIR="$(findmnt -rno SOURCE,FSTYPE,TARGET -T "$CSV_DIR" 2>/dev/null || true)"
        SRC_ACT="$(echo "$OUT_DIR" | awk 'NR==1{print $1}')"
        FST_ACT="$(echo "$OUT_DIR" | awk 'NR==1{print $2}')"
        TGT_ACT="$(echo "$OUT_DIR" | awk 'NR==1{print $3}')"
        dlog "findmnt(-T dir): $SRC_ACT $FST_ACT $TGT_ACT"
    fi

    # Fallback 2: direkt auf den Mountpunkt schauen
    if [ -z "$SRC_ACT" ] || [ -z "$FST_ACT" ]; then
        OUT_MNT="$(findmnt -rno SOURCE,FSTYPE,TARGET "$MOUNT" 2>/dev/null || true)"
        SRC_ACT="$(echo "$OUT_MNT" | awk 'NR==1{print $1}')"
        FST_ACT="$(echo "$OUT_MNT" | awk 'NR==1{print $2}')"
        TGT_ACT="$(echo "$OUT_MNT" | awk 'NR==1{print $3}')"
        dlog "findmnt(MOUNT): $SRC_ACT $FST_ACT $TGT_ACT"
    fi

    # Datei lesbar?
    if [ ! -r "$CSV_FILE" ]; then
        dlog "CSV not readable: $CSV_FILE"
        return 1
    fi

    # Frische prüfen
    NOW="$(date +%s)"
    MTIME="$(stat -c %Y "$CSV_FILE" 2>/dev/null || echo 0)"
    AGE="$((NOW - MTIME))"
    dlog "READABLE=yes AGE=$AGE"
    if [ "$AGE" -gt "$MAX_AGE" ]; then
        dlog "file too old: AGE=$AGE > MAX_AGE=$MAX_AGE"
        return 1
    fi

    # Autofs-Spezialfall:
    # Wenn autofs/systemd-1 gemeldet wird, akzeptieren wir Lesbarkeit+Frische als OK.
    if [ "$SRC_ACT" = "systemd-1" ] || [ "$FST_ACT" = "autofs" ]; then
        dlog "autofs detected; skipping strict remote/fstype compare"
        return 0
    fi

    # Strikter Vergleich, wenn echte Quelle bekannt ist
    if [ "$SRC_ACT" != "$REMOTE" ]; then
        dlog "SRC mismatch: $SRC_ACT != $REMOTE"
        return 1
    fi
    if [ "$FST_ACT" != "$FSTYPE" ]; then
        dlog "FST mismatch: $FST_ACT != $FSTYPE"
        return 1
    fi

    return 0
}

# Zeile zu DEVICEID finden und Felder extrahieren
# Ausgabe: "did host st bytes dur ts last"
get_row_by_id() {
    ID="$1"
    awk -F, -v id="$ID" '
      NR>1 && $1==id { printf "%s %s %s %s %s %s %s\n", $1,$2,$3,$4,$5,$6,($7==""?0:$7); exit }
    ' "$CSV_FILE"
}

# -------- Kommandos --------

cmd_discovery() {
    # Liefert gültiges LLD-JSON: {"data":[{"{#DEVICEID}":"..","{#HOSTNAME}":".."}, ...]}
    awk -F, '
      BEGIN { print "{\"data\":["; first=1 }
      NR>1 {
        if (!first) { printf(",\n"); } first=0
        gsub("\"","\\\"", $2)
        printf("  {\"{#DEVICEID}\":\"%s\",\"{#HOSTNAME}\":\"%s\"}", $1, $2)
      }
      END { print "\n]}" }
    ' "$CSV_FILE"
}

cmd_status() {  # status ID
    VAL="$(get_row_by_id "$1")"
    [ -n "$VAL" ] || { echo 99; return; }
    set -- $VAL
    echo "$3"
}

cmd_bytes() {   # bytes ID
    VAL="$(get_row_by_id "$1")"
    [ -n "$VAL" ] || { echo 0; return; }
    set -- $VAL
    echo "$4"
}

cmd_duration() {  # duration ID
    VAL="$(get_row_by_id "$1")"
    [ -n "$VAL" ] || { echo 0; return; }
    set -- $VAL
    echo "$5"
}

cmd_lastsuccess_age() {  # lastsuccess_age ID
    NOW="$(date +%s)"
    VAL="$(get_row_by_id "$1")"
    [ -n "$VAL" ] || { echo 2147483647; return; }
    set -- $VAL
    LAST="$7"
    if [ "$LAST" -gt 0 ] 2>/dev/null; then
        AGE="$((NOW - LAST))"
        [ "$AGE" -ge 0 ] 2>/dev/null || AGE=0
        echo "$AGE"
    else
        echo 2147483647
    fi
}

cmd_device_count() {
    awk 'BEGIN{c=0} NR>1{c++} END{print c}' "$CSV_FILE"
}

# „Heute“-Zählungen auf Basis Tagesgrenzen (lokale Zeit)
# STATUS: 2=erfolgreich, 4=fehler, 5=warnung, 8=teil-erfolg
cmd_success_today() {
    # Erfolgreich heute (Status 2 oder 8)
    awk -F, -v day="$(date +%Y-%m-%d)" '
      NR>1 {
        ts=$6+0
        # Datum aus TS (lokal) gewinnen:
        cmd = "date -d @" ts " +%Y-%m-%d"
        cmd | getline d; close(cmd)
        st=$3+0
        if (d==day && (st==2 || st==8)) c++
      }
      END { print c+0 }
    ' "$CSV_FILE"
}

cmd_failed_today() {
    awk -F, -v day="$(date +%Y-%m-%d)" '
      NR>1 {
        ts=$6+0
        cmd = "date -d @" ts " +%Y-%m-%d"
        cmd | getline d; close(cmd)
        st=$3+0
        if (d==day && st==4) c++
      }
      END { print c+0 }
    ' "$CSV_FILE"
}

cmd_failed_list() {
    awk -F, '
      NR>1 && $3+0==4 { print $2 }
    ' "$CSV_FILE"
}

cmd_notok_count() {  # Fehler ODER Warnung
    awk -F, '
      NR>1 && ($3+0==4 || $3+0==5) { c++ }
      END { print c+0 }
    ' "$CSV_FILE"
}

cmd_notok_list() {
    awk -F, '
      NR>1 && ($3+0==4 || $3+0==5) { print $2 }
    ' "$CSV_FILE"
}

cmd_sum_bytes() {
    awk -F, 'NR>1 { s+=$4+0 } END{ print s+0 }' "$CSV_FILE"
}

# Falls gewünscht: Summe „Repo-Bytes“ (nicht im Export vorhanden) -> 0
cmd_sum_repo_bytes() {
    echo 0
}

# -------- Hauptablauf --------
usage() {
    echo "Usage: $0 {check MAXAGE MOUNT REMOTE FSTYPE | discovery | status ID | bytes ID | duration ID | lastsuccess_age ID | device_count | success_today | failed_today | failed_list | notok_count | notok_list | sum_bytes | sum_repo_bytes}" >&2
}

# Für alle Kommandos außer „check“ brauchen wir lesbare CSV (ggf. normalisiert)
need_csv() {
    [ -r "$CSV_FILE" ] || fail "CSV not readable: $CSV_FILE"
    normalize_if_needed
}

CMD="${1:-}"

case "$CMD" in
    check)
        # check MAXAGE MOUNT REMOTE FSTYPE
        MAXAGE="${2:-}"; MOUNT="${3:-}"; REMOTE="${4:-}"; FSTYPE="${5:-}"
        [ -n "$MAXAGE" ] && [ -n "$MOUNT" ] && [ -n "$REMOTE" ] && [ -n "$FSTYPE" ] || { usage; exit 1; }
        # für check genügt Header/Existenz; nicht normalisieren, nur prüfen:
        check_health "$MAXAGE" "$MOUNT" "$REMOTE" "$FSTYPE"
        RC=$?
        [ "$RC" -eq 0 ] && echo 0 || echo 1
        exit 0
        ;;
    discovery)
        need_csv; cmd_discovery; exit 0 ;;
    status)
        ID="${2:-}"; [ -n "$ID" ] || { usage; exit 1; }
        need_csv; cmd_status "$ID"; exit 0 ;;
    bytes)
        ID="${2:-}"; [ -n "$ID" ] || { usage; exit 1; }
        need_csv; cmd_bytes "$ID"; exit 0 ;;
    duration)
        ID="${2:-}"; [ -n "$ID" ] || { usage; exit 1; }
        need_csv; cmd_duration "$ID"; exit 0 ;;
    lastsuccess_age)
        ID="${2:-}"; [ -n "$ID" ] || { usage; exit 1; }
        need_csv; cmd_lastsuccess_age "$ID"; exit 0 ;;
    device_count)
        need_csv; cmd_device_count; exit 0 ;;
    success_today)
        need_csv; cmd_success_today; exit 0 ;;
    failed_today)
        need_csv; cmd_failed_today; exit 0 ;;
    failed_list)
        need_csv; cmd_failed_list; exit 0 ;;
    notok_count)
        need_csv; cmd_notok_count; exit 0 ;;
    notok_list)
        need_csv; cmd_notok_list; exit 0 ;;
    sum_bytes)
        need_csv; cmd_sum_bytes; exit 0 ;;
    sum_repo_bytes)
        need_csv; cmd_sum_repo_bytes; exit 0 ;;
    *)
        usage; exit 1 ;;
esac
#!/bin/sh
# abb_export_enhance_last_success.sh
# Pflegt LAST_SUCCESS_TS je DEVICEID basierend auf STATUS/TS im ActiveBackupExport.csv.
# - STATUS 0 = Erfolg
# - STATUS 2 = "Warnung"; per WARN_AS_SUCCESS=1 optional als Erfolg behandeln (Default: 1)
#
# ENV:
#   ABB_DIR=/volume1/monitoring/abb
#   WARN_AS_SUCCESS=1  # 1 = Warnung zählt als Erfolg, 0 = nein
umask 022
set -eu
LANG=C

ABB_DIR="${ABB_DIR:-/volume1/monitoring/abb}"
EXPORT="$ABB_DIR/ActiveBackupExport.csv"
STATE="$ABB_DIR/.abb_last_success.state"
BACKUP="$EXPORT.bak"
WARN_AS_SUCCESS="${WARN_AS_SUCCESS:-1}"

err() { echo "ERR: $*" >&2; exit 1; }

[ -f "$EXPORT" ] || err "Export-Datei fehlt: $EXPORT"
# State-Datei sicherstellen
if [ ! -f "$STATE" ]; then
  umask 022
  echo "DEVICEID,LAST_SUCCESS_TS" > "$STATE" || err "Kann State anlegen: $STATE"
fi

# Backup des Exports
cp -f "$EXPORT" "$BACKUP" || err "Backup fehlgeschlagen: $BACKUP"

# 1) STATE aktualisieren: jüngstes TS übernehmen, wenn Erfolg (0) oder (Warnung==Erfolg und 2)
awk -F',' -v OFS=',' -v warn="$WARN_AS_SUCCESS" '
  # Datei 1: STATE einlesen
  FILENAME==statefile {
    gsub(/\r/,"")
    if (FNR==1) next
    did=$1+0; lss=$2+0
    if (did>0) state[did]=lss
    next
  }
  # Datei 2: EXPORT einlesen, Erfolge einsammeln
  FILENAME==exportfile {
    gsub(/\r/,"")
    if (FNR==1) next
    did=$1+0; status=$3+0; ts=$6+0
    if (did>0 && ts>0 && (status==0 || (warn==1 && status==2))) {
      if (!(did in state) || ts > state[did]) state[did]=ts
    }
    next
  }
  END {
    print "DEVICEID,LAST_SUCCESS_TS"
    for (d in state) print d, state[d]+0
  }
' statefile="$STATE" exportfile="$EXPORT" "$STATE" "$EXPORT" > "$STATE.tmp" \
  && mv "$STATE.tmp" "$STATE" || err "STATE-Update fehlgeschlagen"

# 2) EXPORT mit Spalte 7 (LAST_SUCCESS_TS) neu schreiben
awk -F',' -v OFS=',' '
  # STATE laden
  FILENAME==statefile {
    gsub(/\r/,"")
    if (FNR==1) next
    sid=$1+0; slss=$2+0
    if (sid>0) last[sid]=slss
    next
  }
  # EXPORT neu ausgeben (Header normalisieren, 7. Spalte aus STATE)
  FILENAME==exportfile {
    gsub(/\r/,"")
    if (FNR==1) {
      print "DEVICEID","HOSTNAME","STATUS","BYTES","DURATION","TS","LAST_SUCCESS_TS"
      next
    }
    did=$1+0
    lss=(did in last ? last[did]+0 : 0)
    # nur erste 6 Felder aus der Quelle verwenden (Zahlen sicherheitshalber +0)
    print $1,$2,($3+0),($4+0),($5+0),($6+0),lss
    next
  }
' statefile="$STATE" exportfile="$BACKUP" "$STATE" "$BACKUP" > "$EXPORT.tmp" \
  && mv "$EXPORT.tmp" "$EXPORT" || err "EXPORT-Neuschreiben fehlgeschlagen"

echo "OK: enhanced $EXPORT (backup: $BACKUP, state: $STATE)"

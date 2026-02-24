#!/bin/bash
# abb_debug.sh — Diagnose-Skript für ABB Monitoring
# Prüft alle Komponenten von der CSV bis zum Zabbix-Template.
#
# Usage:  sudo ./abb_debug.sh [csv_path]
#         sudo ./abb_debug.sh /mnt/synology/monitoring/abb
#
# Maintainer: Alexander Fox | PlaNet Fox

set -uo pipefail

CSV_PATH="${1:-/mnt/synology/monitoring/abb}"
CSV_EXPORT="${CSV_PATH}/ActiveBackupExport.csv"
CSV_STATS="${CSV_PATH}/ActiveBackupStats.csv"
ABB_SH="${ABB_SH:-/usr/lib/zabbix/externalscripts/abb.sh}"
ABB_ENH="${ABB_ENH:-/usr/lib/zabbix/externalscripts/abb-enh.sh}"
ZBX_USER="${ABB_ZBX_USER:-zabbix}"
NOW="$(date +%s)"

###############################################################################
# Formatierung
###############################################################################
BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

ok()   { printf "  ${GREEN}[✓]${NC} %s\n" "$*"; PASS=$((PASS+1)); }
fail() { printf "  ${RED}[✗]${NC} %s\n" "$*"; FAIL=$((FAIL+1)); }
warn() { printf "  ${YELLOW}[!]${NC} %s\n" "$*"; WARN=$((WARN+1)); }
info() { printf "  ${CYAN}[i]${NC} %s\n" "$*"; }
section() { printf "\n${BOLD}═══ %s ═══${NC}\n" "$*"; }

PASS=0; FAIL=0; WARN=0

###############################################################################
section "1. CSV-Dateien"
###############################################################################

if [ -f "$CSV_EXPORT" ]; then
  ok "Export-CSV vorhanden: $CSV_EXPORT"

  # Alter
  MTIME="$(stat -c '%Y' "$CSV_EXPORT" 2>/dev/null || stat -f '%m' "$CSV_EXPORT" 2>/dev/null || echo 0)"
  AGE=$(( NOW - MTIME ))
  if [ "$AGE" -lt 900 ]; then
    ok "CSV-Alter: ${AGE}s (frisch, <15min)"
  else
    fail "CSV-Alter: ${AGE}s (VERALTET, >15min)"
  fi

  # Spaltenanzahl
  COLS="$(head -1 "$CSV_EXPORT" | awk -F',' '{print NF}')"
  if [ "$COLS" = "7" ]; then
    ok "Spaltenanzahl: $COLS (korrekt, LAST_SUCCESS_TS vorhanden)"
  else
    fail "Spaltenanzahl: $COLS (erwartet: 7 — altes Export-Skript?)"
  fi

  # Header prüfen
  HEADER="$(head -1 "$CSV_EXPORT")"
  if echo "$HEADER" | grep -q 'LAST_SUCCESS_TS'; then
    ok "Header enthält LAST_SUCCESS_TS"
  else
    fail "Header fehlt LAST_SUCCESS_TS: $HEADER"
  fi

  # Geräteanzahl
  DEVICES="$(awk 'NR>1{c++}END{print c+0}' "$CSV_EXPORT")"
  ok "Geräte in CSV: $DEVICES"

  # Hostnamen mit Quotes prüfen
  QUOTED="$(awk -F',' 'NR>1 && $2~/^"/' "$CSV_EXPORT" | wc -l)"
  if [ "$QUOTED" -gt 0 ]; then
    warn "Hostnamen mit Anführungszeichen (Leerzeichen): $QUOTED Gerät(e)"
    awk -F',' 'NR>1 && $2~/^"/{print "       → "$2}' "$CSV_EXPORT"
    info "abb.sh muss gsub(/\"/, \"\", host) enthalten (v3.0+)"
  fi

  # LAST_SUCCESS_TS prüfen
  ZERO_LSS="$(awk -F',' 'NR>1 && ($7+0)==0{c++}END{print c+0}' "$CSV_EXPORT")"
  if [ "$ZERO_LSS" -gt 0 ]; then
    warn "$ZERO_LSS Gerät(e) ohne LAST_SUCCESS_TS (noch nie erfolgreich oder State fehlt)"
  else
    ok "Alle Geräte haben LAST_SUCCESS_TS"
  fi

  # Status-Übersicht
  info "Status-Verteilung:"
  awk -F',' 'NR>1{s[$3+0]++} END{
    split("1:Läuft 2:Erfolg 3:Abgebrochen 4:Fehler 5:Warnung 8:Teilweise 99:Unbekannt", labels, " ")
    for(l in labels){split(labels[l],p,":"); map[p[1]]=p[2]}
    for(k in s) printf "       Status %d (%s): %d\n", k, (k in map ? map[k] : "?"), s[k]
  }' "$CSV_EXPORT"

  # CSV-Inhalt anzeigen
  info "Erste 3 Zeilen:"
  head -4 "$CSV_EXPORT" | sed 's/^/       /'

else
  fail "Export-CSV nicht gefunden: $CSV_EXPORT"
fi

echo ""
if [ -f "$CSV_STATS" ]; then
  ok "Stats-CSV vorhanden: $CSV_STATS"
  info "Inhalt: $(cat "$CSV_STATS" | sed 's/^/       /')"
else
  warn "Stats-CSV nicht gefunden: $CSV_STATS (failed_today/success_today funktionieren nicht)"
fi

###############################################################################
section "2. NFS-Mount"
###############################################################################

MOUNTPOINT="$(dirname "$CSV_PATH")"
MNT_OUT="$(findmnt -rn "$MOUNTPOINT" 2>/dev/null || true)"

if [ -n "$MNT_OUT" ]; then
  ok "Mount gefunden: $MOUNTPOINT"

  # Autofs vs NFS
  if echo "$MNT_OUT" | grep -q 'autofs'; then
    NFS_LINE="$(echo "$MNT_OUT" | grep -v 'autofs' | head -1)"
    if [ -n "$NFS_LINE" ]; then
      ok "NFS aktiv (autofs + NFS)"
    else
      warn "Nur autofs sichtbar (NFS wird bei Zugriff gemountet)"
    fi
  fi

  info "findmnt-Ausgabe:"
  echo "$MNT_OUT" | sed 's/^/       /'
else
  warn "Kein Mount gefunden für: $MOUNTPOINT"
  info "Prüfe ob autofs konfiguriert ist oder /etc/fstab"
fi

###############################################################################
section "3. abb.sh Script"
###############################################################################

if [ -x "$ABB_SH" ]; then
  ok "abb.sh vorhanden und ausführbar: $ABB_SH"

  # Version check: hat es gsub für Quotes?
  if grep -q 'gsub.*".*host' "$ABB_SH"; then
    ok "Quotes-Fix vorhanden (gsub für Hostnamen)"
  else
    fail "Quotes-Fix FEHLT — Hostnamen mit Leerzeichen erzeugen kaputtes JSON"
  fi

  # echo 1 statt exit 1 in check?
  if grep -q 'echo 1; exit 0' "$ABB_SH"; then
    ok "Check-Funktion gibt immer eine Zahl zurück (echo 1; exit 0)"
  else
    warn "Check-Funktion könnte leeren String zurückgeben (exit 1 ohne echo)"
  fi

  # Test als root
  info "Test als root:"
  CHECK_OUT="$("$ABB_SH" check 900 "$MOUNTPOINT" 2>/dev/null; echo "EXIT:$?")"
  CHECK_VAL="$(echo "$CHECK_OUT" | head -1)"
  CHECK_EXIT="$(echo "$CHECK_OUT" | grep 'EXIT:' | sed 's/EXIT://')"
  if [ "$CHECK_VAL" = "0" ]; then
    ok "check → $CHECK_VAL (OK)"
  else
    fail "check → '$CHECK_VAL' exit=$CHECK_EXIT"
  fi

  if [ -f "$CSV_EXPORT" ]; then
    JSON_OUT="$("$ABB_SH" json 2>/dev/null)"
    if echo "$JSON_OUT" | python3 -m json.tool >/dev/null 2>&1; then
      ok "json → valides JSON"
      DEV_COUNT="$(echo "$JSON_OUT" | python3 -c "import sys,json;print(len(json.load(sys.stdin)['devices']))" 2>/dev/null)"
      info "Geräte im JSON: $DEV_COUNT"
    else
      fail "json → KEIN valides JSON!"
      info "Erste 200 Zeichen:"
      echo "$JSON_OUT" | head -c 200 | sed 's/^/       /'
      echo ""
      # Finde die Problemstelle
      ERR="$(echo "$JSON_OUT" | python3 -m json.tool 2>&1 | tail -1)"
      info "Fehler: $ERR"
    fi

    COUNT_OUT="$("$ABB_SH" device_count 2>/dev/null)"
    info "device_count → $COUNT_OUT"
  fi

  # Test als zabbix
  if id "$ZBX_USER" >/dev/null 2>&1; then
    info "Test als $ZBX_USER:"

    ZBX_CHECK="$(sudo -u "$ZBX_USER" "$ABB_SH" check 900 "$MOUNTPOINT" 2>/dev/null || echo "FEHLER")"
    if [ "$ZBX_CHECK" = "0" ]; then
      ok "check als $ZBX_USER → OK"
    else
      fail "check als $ZBX_USER → '$ZBX_CHECK'"
    fi

    if [ -f "$CSV_EXPORT" ]; then
      ZBX_JSON="$(sudo -u "$ZBX_USER" "$ABB_SH" json 2>/dev/null)"
      if echo "$ZBX_JSON" | python3 -m json.tool >/dev/null 2>&1; then
        ok "json als $ZBX_USER → valides JSON"
      else
        fail "json als $ZBX_USER → KEIN valides JSON!"
        ERR="$(echo "$ZBX_JSON" | python3 -m json.tool 2>&1 | tail -1)"
        info "Fehler: $ERR"
      fi
    fi

    # CSV-Lesetest
    if sudo -u "$ZBX_USER" test -r "$CSV_EXPORT" 2>/dev/null; then
      ok "CSV lesbar als $ZBX_USER"
    else
      fail "CSV NICHT lesbar als $ZBX_USER"
    fi
  else
    warn "User $ZBX_USER nicht vorhanden (kein Zabbix auf diesem Host?)"
  fi
else
  if [ -f "$ABB_SH" ]; then
    fail "abb.sh vorhanden aber NICHT ausführbar: $ABB_SH"
    info "Fix: sudo chmod 755 $ABB_SH"
  else
    warn "abb.sh nicht gefunden: $ABB_SH"
  fi
fi

###############################################################################
section "4. abb-enh.sh Script"
###############################################################################

if [ -x "$ABB_ENH" ]; then
  ok "abb-enh.sh vorhanden und ausführbar"
else
  warn "abb-enh.sh nicht gefunden oder nicht ausführbar: $ABB_ENH"
fi

###############################################################################
section "5. Zusammenfassung"
###############################################################################

echo ""
printf "  ${GREEN}Bestanden: $PASS${NC}  "
printf "${RED}Fehler: $FAIL${NC}  "
printf "${YELLOW}Warnungen: $WARN${NC}\n"
echo ""

if [ "$FAIL" -gt 0 ]; then
  printf "  ${RED}${BOLD}Es gibt $FAIL Fehler — bitte oben prüfen.${NC}\n"
elif [ "$WARN" -gt 0 ]; then
  printf "  ${YELLOW}${BOLD}Läuft, aber $WARN Warnung(en) beachten.${NC}\n"
else
  printf "  ${GREEN}${BOLD}Alles OK!${NC}\n"
fi
echo ""

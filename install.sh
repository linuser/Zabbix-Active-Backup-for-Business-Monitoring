#!/bin/bash
# install.sh — ABB Monitoring Installer
# Usage:
#   Interactive:  ./install.sh
#   Direct:       ./install.sh synology|zabbix|all
#   Check:        ./install.sh --check
#   Uninstall:    ./install.sh --uninstall
set -euo pipefail

###############################################################################
# Defaults
###############################################################################
SYN_SCRIPT_DIR="/volume1/monitoring/scripts"
SYN_ABB_DIR="/volume1/monitoring/abb"
SYN_DB_DIR="/volume1/@ActiveBackup"

ZBX_EXT_DIR="/usr/lib/zabbix/externalscripts"
ZBX_CSV_PATH="/mnt/synology/monitoring/abb"
ZBX_USER="zabbix"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

###############################################################################
# Formatting
###############################################################################
BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { printf '  %b[✓]%b %s\n' "$GREEN" "$NC" "$*"; }
fail() { printf '  %b[✗]%b %s\n' "$RED" "$NC" "$*"; }
warn() { printf '  %b[!]%b %s\n' "$YELLOW" "$NC" "$*"; }
die()  { fail "$*"; exit 1; }
ask()  { printf '%b%s%b ' "$BOLD" "$1" "$NC" >&2; local ans=""; read -r ans || true; printf '%s' "$ans"; }
hdr()  { printf '%b%s%b\n' "$BOLD" "$1" "$NC"; }
info() { printf '  %s\n' "$*"; }

###############################################################################
# Platform detection
###############################################################################
detect_platform() {
  if [ -f /etc/synoinfo.conf ] || [ -d /volume1 ]; then
    echo "synology"
  elif command -v zabbix_proxy >/dev/null 2>&1 || command -v zabbix_server >/dev/null 2>&1 || id "$ZBX_USER" >/dev/null 2>&1; then
    echo "zabbix"
  else
    echo "unknown"
  fi
}

check_root() {
  [ "$(id -u)" = "0" ] || die "Run as root (sudo ./install.sh)"
}

###############################################################################
# Synology installation
###############################################################################
install_synology() {
  echo ""
  hdr "═══ Installing Synology Scripts ═══"

  # Checks
  SYN_SQLITE=""
  for c in /usr/bin/sqlite3 /bin/sqlite3; do
    [ -x "$c" ] && { SYN_SQLITE="$c"; break; }
  done
  [ -n "$SYN_SQLITE" ] || SYN_SQLITE="$(command -v sqlite3 2>/dev/null || true)"
  [ -n "$SYN_SQLITE" ] || die "sqlite3 not found"
  [ -r "${SYN_DB_DIR}/activity.db" ] || die "activity.db not found in ${SYN_DB_DIR}"
  [ -r "${SYN_DB_DIR}/config.db" ]   || die "config.db not found in ${SYN_DB_DIR}"

  mkdir -p "$SYN_SCRIPT_DIR" "$SYN_ABB_DIR"

  cp -v "${SCRIPT_DIR}/synology/abb_export.sh" "${SYN_SCRIPT_DIR}/"
  cp -v "${SCRIPT_DIR}/synology/abb_daily_summary.sh" "${SYN_SCRIPT_DIR}/"
  chmod 755 "${SYN_SCRIPT_DIR}"/*.sh
  ok "Scripts installed to ${SYN_SCRIPT_DIR}"

  # Zeitsteuerung
  #
  # WICHTIG: Auf DSM NICHT nach /etc/crontab schreiben. DSM generiert diese
  # Datei aus seiner eigenen Aufgaben-Datenbank neu (alle Zeilen dort lauten
  # "synoschedtask --run id=N") — bei Updates, Neustarts und jeder Aenderung
  # im Aufgabenplaner. Ein von Hand angehaengter Eintrag verschwindet dabei
  # kommentarlos. Genau das ist in der Praxis passiert: der Export lief nach
  # der Installation kein einziges Mal, ohne jede Fehlermeldung.
  # Der Aufgabenplaner ist der einzige Weg, der ein DSM-Update ueberlebt.
  local env_prefix="ABB_DIR='${SYN_ABB_DIR}' ABB_DB_DIR='${SYN_DB_DIR}' ABB_SQLITE='${SYN_SQLITE}'"
  local cmd_export="${env_prefix} ${SYN_SCRIPT_DIR}/abb_export.sh"
  local cmd_summary="ABB_DIR='${SYN_ABB_DIR}' ${SYN_SCRIPT_DIR}/abb_daily_summary.sh"

  if [ -f /etc/synoinfo.conf ] || command -v synoschedtask >/dev/null 2>&1; then
    echo ""
    warn "Zeitsteuerung muss im DSM-Aufgabenplaner angelegt werden:"
    info "  Systemsteuerung → Aufgabenplaner → Erstellen → Geplante Aufgabe →"
    info "  Benutzerdefiniertes Skript"
    echo ""
    info "  Aufgabe 1 — Export, alle 5 Minuten (Benutzer: root)"
    info "    Zeitplan: taeglich, alle 5 Minuten wiederholen"
    printf '      %b%s%b\n' "$BOLD" "$cmd_export" "$NC"
    echo ""
    info "  Aufgabe 2 — Tageszusammenfassung, 23:55 (Benutzer: root)"
    printf '      %b%s%b\n' "$BOLD" "$cmd_summary" "$NC"
    echo ""
    warn "Ein Eintrag in /etc/crontab wird von DSM frueher oder spaeter"
    warn "geloescht — deshalb legt der Installer ihn bewusst NICHT an."
    info "Nach dem Anlegen pruefen mit:  $0 --check"
  else
    # Kein DSM: normales cron, hier ist /etc/crontab der richtige Ort.
    local ans
    ans="$(ask "Install cron jobs? [Y/n]")"
    if [ "${ans:-Y}" != "n" ] && [ "${ans:-Y}" != "N" ]; then
      local crontab_file="/etc/crontab"
      local marker="# ABB-MONITORING"
      sed -i "/ABB-MONITORING/d" "$crontab_file" 2>/dev/null || true
      # Tabs zwischen Zeitplan, Benutzer und Kommando: manche crond-Varianten
      # ignorieren leerzeichengetrennte Zeilen stillschweigend.
      printf '*/5 * * * *\troot\t%s %s\n' "$cmd_export"  "$marker" >> "$crontab_file"
      printf '55 23 * * *\troot\t%s %s\n' "$cmd_summary" "$marker" >> "$crontab_file"
      ok "Cron-Eintraege angelegt (Export alle 5 Min, Zusammenfassung 23:55)"
    fi
  fi

  # Initial run
  ans="$(ask "Run initial export now? [Y/n]")"
  if [ "${ans:-Y}" != "n" ] && [ "${ans:-Y}" != "N" ]; then
    ABB_DIR="$SYN_ABB_DIR" ABB_DB_DIR="$SYN_DB_DIR" ABB_SQLITE="$SYN_SQLITE" \
      "${SYN_SCRIPT_DIR}/abb_export.sh"
    if [ -f "${SYN_ABB_DIR}/ActiveBackupExport.csv" ]; then
      local cols
      cols="$(head -1 "${SYN_ABB_DIR}/ActiveBackupExport.csv" | awk -F',' '{print NF}')"
      local rows
      rows="$(awk 'END{print NR-1}' "${SYN_ABB_DIR}/ActiveBackupExport.csv")"
      ok "Export OK: ${rows} devices, ${cols} columns"
    else
      fail "Export produced no CSV"
    fi
  fi

  ok "Synology installation complete"
}

###############################################################################
# Zabbix installation
###############################################################################
install_zabbix() {
  echo ""
  hdr "═══ Installing Zabbix Scripts ═══"

  id "$ZBX_USER" >/dev/null 2>&1 || die "User $ZBX_USER not found"
  [ -d "$ZBX_EXT_DIR" ] || die "External scripts dir not found: $ZBX_EXT_DIR"

  cp -v "${SCRIPT_DIR}/zabbix/abb.sh" "${ZBX_EXT_DIR}/"
  cp -v "${SCRIPT_DIR}/zabbix/abb-enh.sh" "${ZBX_EXT_DIR}/"
  chmod 755 "${ZBX_EXT_DIR}/abb.sh" "${ZBX_EXT_DIR}/abb-enh.sh"
  chown root:"$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" "${ZBX_EXT_DIR}/abb-enh.sh"

  # Zabbix invokes external scripts with a bare environment, so the configured
  # paths must be baked into the installed copies — an exported ABB_CSV_PATH
  # would never reach them.
  if [ "$ZBX_CSV_PATH" != "/mnt/synology/monitoring/abb" ] || [ "$ZBX_USER" != "zabbix" ]; then
    # Escape sed replacement metacharacters (\, the | delimiter, and &) so a
    # path containing them can't corrupt the substitution.
    local csv_esc user_esc
    csv_esc="${ZBX_CSV_PATH//\\/\\\\}"; csv_esc="${csv_esc//&/\\&}"; csv_esc="${csv_esc//|/\\|}"
    user_esc="${ZBX_USER//\\/\\\\}";    user_esc="${user_esc//&/\\&}"; user_esc="${user_esc//|/\\|}"
    sed -i "s|\${ABB_CSV_PATH:-[^}]*}|\${ABB_CSV_PATH:-${csv_esc}}|" \
      "${ZBX_EXT_DIR}/abb.sh" "${ZBX_EXT_DIR}/abb-enh.sh"
    sed -i "s|\${ABB_ZBX_USER:-[^}]*}|\${ABB_ZBX_USER:-${user_esc}}|" \
      "${ZBX_EXT_DIR}/abb.sh"
    ok "Defaults baked in: CSV_PATH=${ZBX_CSV_PATH}, user=${ZBX_USER}"
  fi
  ok "Scripts installed to ${ZBX_EXT_DIR}"

  # Check NFS mount
  if [ -d "$ZBX_CSV_PATH" ]; then
    ok "CSV path exists: $ZBX_CSV_PATH"
  else
    warn "CSV path not found: $ZBX_CSV_PATH — ensure NFS mount is configured"
  fi

  # Test
  if [ -f "${ZBX_CSV_PATH}/ActiveBackupExport.csv" ]; then
    local count
    count="$(sudo -u "$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" device_count 2>/dev/null || echo "FAIL")"
    if [ "$count" != "FAIL" ]; then
      ok "abb.sh device_count = $count (as $ZBX_USER)"
    else
      warn "abb.sh failed as $ZBX_USER — check permissions"
    fi
  else
    warn "CSV not found yet — will work once Synology export runs"
  fi

  ok "Zabbix installation complete"
  echo ""
  warn "Remember to import template/Synology-ABB-Zabbix-Check.xml in Zabbix UI"
}

###############################################################################
# Check installation
###############################################################################
check_installation() {
  echo ""
  hdr "═══ Installation Check ═══"
  local errors=0

  # Synology side
  if [ -f /etc/synoinfo.conf ]; then
    printf "\n"; hdr "Synology:"
    if [ -x "${SYN_SCRIPT_DIR}/abb_export.sh" ]; then ok "abb_export.sh"; else fail "abb_export.sh missing"; errors=$((errors+1)); fi
    if [ -f "${SYN_ABB_DIR}/ActiveBackupExport.csv" ]; then
      ok "CSV exists"
      local cols
      cols="$(head -1 "${SYN_ABB_DIR}/ActiveBackupExport.csv" | awk -F',' '{print NF}')"
      if [ "$cols" = "7" ]; then ok "CSV has 7 columns (LAST_SUCCESS_TS present)"; else warn "CSV has $cols columns (expected 7)"; fi

      # Die Zeitsteuerung wird am ALTER der CSV gemessen, nicht an einem
      # Eintrag in /etc/crontab. Der alte Test (grep auf abb_export.sh) war
      # wertlos: auf DSM gehoert die Aufgabe in den Aufgabenplaner und taucht
      # in /etc/crontab nur als "synoschedtask --run id=N" auf. Er meldete
      # "No cron entry found" als blosse Warnung — und genau deshalb blieb
      # monatelang unbemerkt, dass der Export ueberhaupt nie lief.
      local csv_mtime csv_age
      csv_mtime="$(stat -c '%Y' "${SYN_ABB_DIR}/ActiveBackupExport.csv" 2>/dev/null || echo 0)"
      csv_age=$(( $(date +%s) - csv_mtime ))
      if [ "$csv_age" -lt 900 ]; then
        ok "Zeitsteuerung laeuft (CSV ${csv_age}s alt)"
      else
        fail "CSV ist ${csv_age}s alt — die Zeitsteuerung laeuft NICHT"
        info "  DSM:    Systemsteuerung → Aufgabenplaner pruefen"
        info "  sonst:  grep ABB-MONITORING /etc/crontab"
        errors=$((errors+1))
      fi
    else
      fail "CSV missing"; errors=$((errors+1))
    fi
  fi

  # Zabbix-Seite
  # Nur pruefen, wenn das externalscripts-Verzeichnis existiert. Die blosse
  # Existenz eines "zabbix"-Benutzers reicht nicht: auf der NAS gibt es eine
  # zabbix-Gruppe (fuer den NFS-Zugriff), aber keine Zabbix-Installation —
  # der Check meldete dort zwei Fehler, die gar keine sind.
  if id "$ZBX_USER" >/dev/null 2>&1 && [ -d "$ZBX_EXT_DIR" ]; then
    printf "\n"; hdr "Zabbix:"
    if [ -x "${ZBX_EXT_DIR}/abb.sh" ]; then ok "abb.sh"; else fail "abb.sh missing"; errors=$((errors+1)); fi
    if [ -d "$ZBX_CSV_PATH" ]; then ok "CSV path reachable"; else fail "CSV path missing: $ZBX_CSV_PATH"; errors=$((errors+1)); fi

    if [ -f "${ZBX_CSV_PATH}/ActiveBackupExport.csv" ]; then
      local mtime age
      mtime="$(stat -c '%Y' "${ZBX_CSV_PATH}/ActiveBackupExport.csv" 2>/dev/null || echo 0)"
      age=$(( $(date +%s) - mtime ))
      if [ "$age" -lt 900 ]; then ok "CSV age: ${age}s (fresh)"; else warn "CSV age: ${age}s (stale >900s)"; fi

      # Die folgenden Tests laufen als Zabbix-User (sudo). Ohne root bzw. ohne
      # passwortloses sudo wuerden sie faelschlich fehlschlagen -> dann lieber
      # mit Hinweis ueberspringen, statt einen Fehler zu melden.
      if [ "$(id -u)" = "0" ] || sudo -n -u "$ZBX_USER" true 2>/dev/null; then
        local count
        count="$(sudo -u "$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" device_count 2>/dev/null || echo "FAIL")"
        if [ "$count" != "FAIL" ]; then ok "device_count=$count (as $ZBX_USER)"; else fail "abb.sh fails as $ZBX_USER"; errors=$((errors+1)); fi

        local check_val
        check_val="$(sudo -u "$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" check 900 "$(dirname "$ZBX_CSV_PATH")" 2>/dev/null | head -1)"
        if [ "$check_val" = "0" ]; then
          ok "check passed"
        else
          fail "check failed (health=${check_val:-empty})"
          errors=$((errors+1))
        fi
      else
        warn "Tests als '$ZBX_USER' uebersprungen (kein root/sudo) - '--check' dafuer als root ausfuehren"
      fi
    fi
  fi

  echo ""
  if [ "$errors" = "0" ]; then ok "All checks passed"; else fail "$errors error(s) found"; fi
}

###############################################################################
# Uninstall
###############################################################################
uninstall() {
  echo ""
  hdr "═══ Uninstall ═══"
  local ans
  ans="$(ask "This will remove all ABB monitoring scripts. Continue? [y/N]")"
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; exit 0; }

  # rm -f always succeeds, so check existence first instead of reporting
  # "removed" for things that were never installed.
  local removed=0

  # Synology
  for f in "${SYN_SCRIPT_DIR}/abb_export.sh" "${SYN_SCRIPT_DIR}/abb_daily_summary.sh" \
           "${ZBX_EXT_DIR}/abb.sh" "${ZBX_EXT_DIR}/abb-enh.sh"; do
    if [ -e "$f" ]; then rm -f "$f" && ok "Removed $f" && removed=$((removed+1)); fi
  done

  # Cron
  if grep -q 'ABB-MONITORING' /etc/crontab 2>/dev/null; then
    sed -i '/ABB-MONITORING/d' /etc/crontab && ok "Cron entries removed"
  else
    warn "No cron entries found"
  fi
  # Auf DSM liegt die Zeitsteuerung im Aufgabenplaner, nicht in /etc/crontab —
  # der Installer kann sie dort nicht entfernen.
  if [ -f /etc/synoinfo.conf ]; then
    warn "DSM: Aufgaben im Aufgabenplaner manuell loeschen"
    info "  Systemsteuerung → Aufgabenplaner → abb_export / abb_daily_summary"
  fi

  [ "$removed" = "0" ] && warn "No scripts found to remove"

  warn "CSV files and template NOT removed (manual cleanup if needed)"
  ok "Uninstall complete"
}

###############################################################################
# Interactive / CLI
###############################################################################
configure_synology_paths() {
  local v
  v="$(ask "  Script directory [$SYN_SCRIPT_DIR]:")"
  [ -n "$v" ] && SYN_SCRIPT_DIR="$v"
  v="$(ask "  CSV output directory [$SYN_ABB_DIR]:")"
  [ -n "$v" ] && SYN_ABB_DIR="$v"
  v="$(ask "  ABB database directory [$SYN_DB_DIR]:")"
  [ -n "$v" ] && SYN_DB_DIR="$v"
}

configure_zabbix_paths() {
  local v
  v="$(ask "  External scripts directory [$ZBX_EXT_DIR]:")"
  [ -n "$v" ] && ZBX_EXT_DIR="$v"
  v="$(ask "  CSV path (NFS mount) [$ZBX_CSV_PATH]:")"
  [ -n "$v" ] && ZBX_CSV_PATH="$v"
  v="$(ask "  Zabbix user [$ZBX_USER]:")"
  [ -n "$v" ] && ZBX_USER="$v"
}

main_interactive() {
  local platform
  platform="$(detect_platform)"

  printf "\n"; hdr "═══ ABB Monitoring Installer ═══"
  ok "Detected platform: $platform"

  printf "  %b1)%b Install Synology export scripts\n" "$BOLD" "$NC"
  printf "  %b2)%b Install Zabbix external scripts\n" "$BOLD" "$NC"
  printf "  %b3)%b Install both (same host)\n" "$BOLD" "$NC"
  printf "  %b4)%b Check installation\n" "$BOLD" "$NC"
  printf "  %b5)%b Uninstall\n" "$BOLD" "$NC"
  printf "  %bq)%b Quit\n" "$BOLD" "$NC"

  local choice
  choice="$(ask "Select [1-5/q]:")"
  choice="$(echo "$choice" | tr -d ')')"

  case "$choice" in
    1) check_root; configure_synology_paths; install_synology ;;
    2) check_root; configure_zabbix_paths;   install_zabbix ;;
    3) check_root; configure_synology_paths; configure_zabbix_paths; install_synology; install_zabbix ;;
    4) check_installation ;;
    5) check_root; uninstall ;;
    q|Q) exit 0 ;;
    *) die "Invalid choice. Use 1-5 or q." ;;
  esac
}

###############################################################################
# Entrypoint
###############################################################################
case "${1:-}" in
  synology)    check_root; install_synology ;;
  zabbix)      check_root; install_zabbix ;;
  all)         check_root; install_synology; install_zabbix ;;
  --check)     check_installation ;;
  --uninstall) check_root; uninstall ;;
  --help|-h)
    echo "Usage: $0 [synology|zabbix|all|--check|--uninstall]"
    echo "  No args = interactive mode"
    ;;
  "")          main_interactive ;;
  *)           die "Unbekanntes Argument: '$1' (siehe $0 --help)" ;;
esac

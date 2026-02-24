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
ok()   { printf "  ${GREEN}[✓]${NC} %s\n" "$*"; }
fail() { printf "  ${RED}[✗]${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}[!]${NC} %s\n" "$*"; }
die()  { fail "$*"; exit 1; }
ask()  { printf "${BOLD}%s${NC} " "$1" >&2; read -r ans; echo "$ans"; }

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
  printf "${BOLD}═══ Installing Synology Scripts ═══${NC}\n"

  # Checks
  [ -x "${SYN_DB_DIR}/../usr/bin/sqlite3" ] || [ -x /usr/bin/sqlite3 ] || die "sqlite3 not found"
  [ -r "${SYN_DB_DIR}/activity.db" ] || die "activity.db not found in ${SYN_DB_DIR}"
  [ -r "${SYN_DB_DIR}/config.db" ]   || die "config.db not found in ${SYN_DB_DIR}"

  mkdir -p "$SYN_SCRIPT_DIR" "$SYN_ABB_DIR"

  cp -v "${SCRIPT_DIR}/synology/abb_export.sh" "${SYN_SCRIPT_DIR}/"
  cp -v "${SCRIPT_DIR}/synology/abb_daily_summary.sh" "${SYN_SCRIPT_DIR}/"
  chmod 755 "${SYN_SCRIPT_DIR}"/*.sh
  ok "Scripts installed to ${SYN_SCRIPT_DIR}"

  # Cron
  local ans
  ans="$(ask "Install cron jobs? [Y/n]")"
  if [ "${ans:-Y}" != "n" ] && [ "${ans:-Y}" != "N" ]; then
    local crontab_file="/etc/crontab"
    local marker="# ABB-MONITORING"

    # Remove old entries
    sed -i "/${marker}/d" "$crontab_file" 2>/dev/null || true

    cat >> "$crontab_file" << EOF
*/5 * * * * root ${SYN_SCRIPT_DIR}/abb_export.sh ${marker}
55 23 * * * root ${SYN_SCRIPT_DIR}/abb_daily_summary.sh ${marker}
EOF
    ok "Cron jobs installed (export every 5min, summary 23:55)"
  fi

  # Initial run
  ans="$(ask "Run initial export now? [Y/n]")"
  if [ "${ans:-Y}" != "n" ] && [ "${ans:-Y}" != "N" ]; then
    ABB_DIR="$SYN_ABB_DIR" "${SYN_SCRIPT_DIR}/abb_export.sh"
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
  printf "${BOLD}═══ Installing Zabbix Scripts ═══${NC}\n"

  id "$ZBX_USER" >/dev/null 2>&1 || die "User $ZBX_USER not found"
  [ -d "$ZBX_EXT_DIR" ] || die "External scripts dir not found: $ZBX_EXT_DIR"

  cp -v "${SCRIPT_DIR}/zabbix/abb.sh" "${ZBX_EXT_DIR}/"
  cp -v "${SCRIPT_DIR}/zabbix/abb-enh.sh" "${ZBX_EXT_DIR}/"
  chmod 755 "${ZBX_EXT_DIR}/abb.sh" "${ZBX_EXT_DIR}/abb-enh.sh"
  chown root:"$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" "${ZBX_EXT_DIR}/abb-enh.sh"
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
  printf "${BOLD}═══ Installation Check ═══${NC}\n"
  local errors=0

  # Synology side
  if [ -f /etc/synoinfo.conf ]; then
    printf "\n${BOLD}Synology:${NC}\n"
    [ -x "${SYN_SCRIPT_DIR}/abb_export.sh" ] && ok "abb_export.sh" || { fail "abb_export.sh missing"; errors=$((errors+1)); }
    [ -f "${SYN_ABB_DIR}/ActiveBackupExport.csv" ] && ok "CSV exists" || { fail "CSV missing"; errors=$((errors+1)); }
    if [ -f "${SYN_ABB_DIR}/ActiveBackupExport.csv" ]; then
      local cols
      cols="$(head -1 "${SYN_ABB_DIR}/ActiveBackupExport.csv" | awk -F',' '{print NF}')"
      [ "$cols" = "7" ] && ok "CSV has 7 columns (LAST_SUCCESS_TS present)" || { warn "CSV has $cols columns (expected 7)"; }
    fi
    grep -q "abb_export.sh" /etc/crontab 2>/dev/null && ok "Cron active" || { warn "No cron entry found"; }
  fi

  # Zabbix side
  if id "$ZBX_USER" >/dev/null 2>&1; then
    printf "\n${BOLD}Zabbix:${NC}\n"
    [ -x "${ZBX_EXT_DIR}/abb.sh" ] && ok "abb.sh" || { fail "abb.sh missing"; errors=$((errors+1)); }
    [ -d "$ZBX_CSV_PATH" ] && ok "CSV path reachable" || { fail "CSV path missing: $ZBX_CSV_PATH"; errors=$((errors+1)); }

    if [ -f "${ZBX_CSV_PATH}/ActiveBackupExport.csv" ]; then
      local age
      age=$(( $(date +%s) - $(stat -c '%Y' "${ZBX_CSV_PATH}/ActiveBackupExport.csv") ))
      [ "$age" -lt 900 ] && ok "CSV age: ${age}s (fresh)" || warn "CSV age: ${age}s (stale >900s)"

      local count
      count="$(sudo -u "$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" device_count 2>/dev/null || echo "FAIL")"
      [ "$count" != "FAIL" ] && ok "device_count=$count (as $ZBX_USER)" || { fail "abb.sh fails as $ZBX_USER"; errors=$((errors+1)); }

      local check
      check="$(sudo -u "$ZBX_USER" "${ZBX_EXT_DIR}/abb.sh" check 900 2>/dev/null; echo $?)"
      [ "$check" = "0" ] || [ "$(echo "$check" | tail -1)" = "0" ] && ok "check passed" || { fail "check failed"; errors=$((errors+1)); }
    fi
  fi

  echo ""
  [ "$errors" = "0" ] && ok "All checks passed" || fail "$errors error(s) found"
}

###############################################################################
# Uninstall
###############################################################################
uninstall() {
  echo ""
  printf "${BOLD}═══ Uninstall ═══${NC}\n"
  local ans
  ans="$(ask "This will remove all ABB monitoring scripts. Continue? [y/N]")"
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; exit 0; }

  # Synology
  rm -f "${SYN_SCRIPT_DIR}/abb_export.sh" "${SYN_SCRIPT_DIR}/abb_daily_summary.sh" 2>/dev/null && ok "Synology scripts removed" || true
  sed -i '/ABB-MONITORING/d' /etc/crontab 2>/dev/null && ok "Cron entries removed" || true

  # Zabbix
  rm -f "${ZBX_EXT_DIR}/abb.sh" "${ZBX_EXT_DIR}/abb-enh.sh" 2>/dev/null && ok "Zabbix scripts removed" || true

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

  printf "\n${BOLD}═══ ABB Monitoring Installer ═══${NC}\n"
  ok "Detected platform: $platform"

  printf "  ${BOLD}1)${NC} Install Synology export scripts\n"
  printf "  ${BOLD}2)${NC} Install Zabbix external scripts\n"
  printf "  ${BOLD}3)${NC} Install both (same host)\n"
  printf "  ${BOLD}4)${NC} Check installation\n"
  printf "  ${BOLD}5)${NC} Uninstall\n"
  printf "  ${BOLD}q)${NC} Quit\n"

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
  *)           main_interactive ;;
esac

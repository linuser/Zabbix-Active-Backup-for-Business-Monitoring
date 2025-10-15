# 🧩 Synology Active Backup for Business – Zabbix Monitoring (Single Script)

Diese Dokumentation beschreibt die vollständige Einrichtung des **Synology ABB Monitorings** über ein **einheitliches Zabbix-External-Script (`abb.sh`)**.  
Das Setup basiert auf einem **NAS-Export (CSV)**, der per NFS vom **Zabbix Proxy oder Server** gelesen wird.

---

## ⚙️ Systemübersicht

```text
+-----------------+                 +---------------------------+
| Synology NAS    |                 | Zabbix Proxy / Server     |
|-----------------|                 |---------------------------|
| - abb_export.sh |  --> NFS Mount  | - abb.sh (External Script)|
| - abb_enhance.. |                 | - Template: ABB Single    |
| - CSV unter /volume1/monitoring/abb/ | - Items, LLD, Triggers  |
+-----------------+                 +---------------------------+
```

---

## 🧠 Voraussetzungen

### Auf dem **NAS**
- DSM 7.x mit installiertem **Active Backup for Business**
- SSH-Zugriff aktiviert
- Benutzer `zabbix` mit Schreibrecht auf `/volume1/monitoring/abb`

### Auf dem **Zabbix Proxy / Server**
- Zabbix ≥ 7.2  
- Paket `jq` installiert (`apt install jq`)  
- NFS-Client (`apt install nfs-common`)  
- Mountpoint `/mnt/synology/monitoring`  
- Datei `/usr/lib/zabbix/externalscripts/abb.sh`

---

## 📦 Installation auf dem NAS

### 1️⃣ Verzeichnisstruktur

```bash
/volume1/monitoring/
├── abb/
│   ├── ActiveBackupExport.csv
│   ├── export.log
└── scripts/
    ├── abb_export.sh
    ├── abb_export_enhance_last_success.sh
```

---

### 2️⃣ NAS-Skripte

#### `/volume1/monitoring/scripts/abb_export.sh`

```bash
#!/bin/sh
set -eu
ABB_DIR="${ABB_DIR:-/volume1/monitoring/abb}"
LOG="$ABB_DIR/export.log"

echo "$(date '+%F %T') [INFO] ABB Export gestartet" >> "$LOG"

/usr/syno/bin/activebackup export host > "$ABB_DIR/ActiveBackupHostExport.csv"
/usr/syno/bin/activebackup export stats > "$ABB_DIR/ActiveBackupStats.csv"
/usr/syno/bin/activebackup export device-stats > "$ABB_DIR/ActiveBackupDeviceStats.csv"

awk -F, -v OFS=, 'NR>1 {print $1,$2,$3,$4,$5,$6}'   "$ABB_DIR/ActiveBackupHostExport.csv" > "$ABB_DIR/ActiveBackupExport.csv"

echo "$(date '+%F %T') [INFO] ABB Export beendet" >> "$LOG"
```

#### `/volume1/monitoring/scripts/abb_export_enhance_last_success.sh`

```bash
#!/bin/sh
set -eu
ABB_DIR="${ABB_DIR:-/volume1/monitoring/abb}"
EXPORT="$ABB_DIR/ActiveBackupExport.csv"
BACKUP="$EXPORT.bak.$(date +%s)"

cp -a "$EXPORT" "$BACKUP" 2>/dev/null || true

awk -F, -v OFS=, '
  NR==1 {print "DEVICEID","HOSTNAME","STATUS","BYTES","DURATION","TS","LAST_SUCCESS_TS"; next}
  NR>1  {print $1,$2,$3,$4,$5,$6,0}
' "$BACKUP" > "$EXPORT.tmp" && mv "$EXPORT.tmp" "$EXPORT"

chgrp -R zabbix "$ABB_DIR"
chmod 2775 "$ABB_DIR" || true
chmod 640 "$ABB_DIR"/*.csv || true

echo "OK: enhanced $EXPORT"
```

---

### 3️⃣ Taskplaner (DSM GUI oder Cron)

```bash
/volume1/monitoring/scripts/abb_export.sh && /volume1/monitoring/scripts/abb_export_enhance_last_success.sh
```

---

## 🖧 NFS-Freigabe

DSM:
- Freigabe: `/volume1/monitoring`
- Erlaubte Hosts: Zabbix Proxy IP
- Rechte: `rw`, `no_root_squash`
- Mount-Test:
```bash
mount -t nfs 192.168.33.2:/volume1/monitoring /mnt/synology/monitoring
```

---

## 🧩 Installation auf dem Zabbix Proxy

```bash
#!/bin/sh
set -eu
CSV="${ABB_CSV_PATH:-/mnt/synology/monitoring/abb}"
CSV_FILE="$CSV/ActiveBackupExport.csv"
DEBUG="${ABB_DEBUG:-0}"
log() { [ "$DEBUG" = "1" ] && echo "DEBUG: $*" >&2; }

case "${1:-}" in
  check)
    MAXAGE="${2:-900}"; MOUNT="${3:-/mnt/synology/monitoring}"; REMOTE="${4:-}"
    SRC_LINE=$(findmnt -rno SOURCE,FSTYPE,TARGET -T "$CSV_FILE" | tail -n1 || true)
    SRC=$(echo "$SRC_LINE" | awk '{print $1}'); FST=$(echo "$SRC_LINE" | awk '{print $2}')
    AGE=$(( $(date +%s) - $(stat -c %Y "$CSV_FILE" 2>/dev/null || echo 0) ))
    log "SRC=$SRC FST=$FST AGE=$AGE"
    [ -r "$CSV_FILE" ] || { log "not readable"; echo 1; exit 0; }
    [ "$FST" = "autofs" ] || [ "$SRC" = "$REMOTE" ] || { log "SRC mismatch"; echo 1; exit 0; }
    [ "$AGE" -le "$MAXAGE" ] || { log "file too old"; echo 1; exit 0; }
    echo 0
    ;;
  discovery)
    awk -F, 'NR>1 {printf "%s{"{#DEVICEID}":"%s","{#HOSTNAME}":"%s"}",(NR>2?",":""),$1,$2} END{print "]"}'       <(echo "[") "$CSV_FILE"
    ;;
  status)
    awk -F, -v id="$2" 'NR>1 && $1==id {print $3}' "$CSV_FILE"
    ;;
  bytes)
    awk -F, -v id="$2" 'NR>1 && $1==id {print $4}' "$CSV_FILE"
    ;;
  duration)
    awk -F, -v id="$2" 'NR>1 && $1==id {print $5}' "$CSV_FILE"
    ;;
  lastsuccess_age)
    now=$(date +%s)
    awk -F, -v id="$2" -v now="$now" 'NR>1 && $1==id {diff=now-$7;if(diff<0)diff=0;print diff}' "$CSV_FILE"
    ;;
  *)
    echo "Usage: $0 {check MAXAGE MOUNT REMOTE FSTYPE | discovery | status ID | bytes ID | duration ID | lastsuccess_age ID}" >&2
    exit 1
    ;;
esac
```

---

## 🧾 Version & Credits

**Maintainer:** Alexander Fox | PlaNet Fox with Love ❤️  
**Kompatibel mit:** Zabbix 7.2 – 7.4  
**Stand:** Oktober 2025  
**Lizenz:** MIT  

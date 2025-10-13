
# 📘 Dokumentation – Monitoring von Synology Active Backup for Business (ABB)

**Version:** 1.0  
**Stand:** Oktober 2025  
**Kompatibel mit:** Zabbix 7.4+ & Synology DSM 7.x (ABB)

---

## 🧩 Ziel

Dieses Setup überwacht **Synology Active Backup for Business (ABB)** über CSV-Exports der ABB-Tasks,
die auf dem Zabbix-Proxy eingebunden werden.  
Erfasst werden:

- Erfolgsrate der Backups
- Geräteliste & -Status
- Backup-Dauer & -Größe je Host
- Gesamtvolumen & Repositorygröße
- Export-Status und Fehlermeldungen

---

## ⚙️ Architekturüberblick

```
[ Synology NAS ]
     │
     │ (exportiert CSVs via NFS)
     ▼
[ Zabbix Proxy ]
     ├── /mnt/synology/monitoring/abb/
     │     ├── ActiveBackupExport.csv
     │     └── ActiveBackupHostExport.csv
     │
     └── /usr/lib/zabbix/externalscripts/abb.sh
          ↑
          └── Zabbix Server ruft Items per Proxy ab
```

---

## 📦 1. Installation auf dem Synology NAS

### 1.1 Voraussetzungen
- Active Backup for Business (ABB) installiert und funktionierende Jobs
- SSH-Zugang als Admin

### 1.2 Skript-Export
`/volume1/scripts/abb_export.sh`
```bash
#!/bin/bash
ABB_DIR="/volume1/monitoring/abb"
mkdir -p "$ABB_DIR"
/var/packages/ActiveBackupforBusiness/target/tool/ActiveBackupTool --list-all > "$ABB_DIR/ActiveBackupExport.csv"
/var/packages/ActiveBackupforBusiness/target/tool/ActiveBackupTool --list-hosts > "$ABB_DIR/ActiveBackupHostExport.csv"
```

Optional:
`/volume1/scripts/abb_export_enhance_last_success.sh`

### 1.3 Aufgabenplanung
DSM → **Aufgabenplaner → Benutzerdefiniertes Skript**
```
/bin/sh -c 'ABB_DIR=/volume1/monitoring/abb /volume1/scripts/abb_export.sh && /volume1/scripts/abb_export_enhance_last_success.sh >> /volume1/monitoring/abb/export.log 2>&1'
```

### 1.4 NFS-Export
DSM → **Dateidienste → NFS**
```
Pfad: /volume1/monitoring
Host: Zabbix Proxy IP
Rechte: Lesen/Schreiben, no_root_squash
```

---

## 🧩 2. Einrichtung auf dem Zabbix Proxy

### 2.1 NFS Mount
`/etc/fstab`
```
192.0.2.10:/volume1/monitoring /mnt/synology/monitoring nfs defaults,_netdev 0 0
```

### 2.2 Externalscript installieren
`/usr/lib/zabbix/externalscripts/abb.sh`
```bash
#!/bin/sh
CSV="${ABB_CSV_PATH:-/mnt/synology/monitoring/abb}"
EXPORT="$CSV/ActiveBackupExport.csv"
HOSTS="$CSV/ActiveBackupHostExport.csv"

check() {
  MAX="${1:-900}"
  MP="${2:-/mnt/synology/monitoring}"
  REM="${3:-192.0.2.10:/volume1/monitoring}"
  FST="${4:-nfs}"
  SRC=$(findmnt -no SOURCE "$MP" 2>/dev/null)
  TYP=$(findmnt -no FSTYPE "$MP" 2>/dev/null)
  test "$SRC" = "$REM" || exit 1
  test "$TYP" = "$FST" || exit 1
  test -r "$EXPORT" || exit 1
  now=$(date +%s)
  mtime=$(stat -c %Y "$EXPORT" 2>/dev/null || echo 0)
  age=$((now - mtime))
  [ "$age" -le "$MAX" ] || exit 1
  echo 0
}

status()         { awk -F, -v id="$1" 'NR>1 && $1==id{print $3}' "$EXPORT"; }
bytes()          { awk -F, -v id="$1" 'NR>1 && $1==id{print $4}' "$EXPORT"; }
duration()       { awk -F, -v id="$1" 'NR>1 && $1==id{print $5}' "$EXPORT"; }
lastsuccess_age(){ awk -F, -v id="$1" 'NR>1 && $1==id{print int(systime()-$7)}' "$EXPORT"; }

case "$1" in
  check) shift; check "$@";;
  status|bytes|duration|lastsuccess_age) shift; "$1" "$@";;
  *) echo "Usage: abb.sh check|status|bytes|duration|lastsuccess_age"; exit 1;;
esac
```

Rechte:
```bash
chown zabbix:zabbix /usr/lib/zabbix/externalscripts/abb.sh
chmod 755 /usr/lib/zabbix/externalscripts/abb.sh
```

Test:
```bash
sudo -u zabbix /usr/lib/zabbix/externalscripts/abb.sh check 900
sudo -u zabbix /usr/lib/zabbix/externalscripts/abb.sh status 11
```

---

## 🧰 3. Einrichtung im Zabbix Server

### 3.1 Template importieren
Template: `Synology_ABB_External_SingleScript.xml`

Import → **Update existing** aktivieren  
Pfad: `Templates/Applications`

### 3.2 Makros prüfen
| Makro | Beschreibung | Beispiel |
|-------|---------------|----------|
| `{$ABB.CSV.PATH}` | Pfad zum CSV | `/mnt/synology/monitoring/abb` |
| `{$ABB.MOUNTPOINT}` | Mountpunkt | `/mnt/synology/monitoring` |
| `{$ABB.EXPORT.MAXAGE}` | Max. Alter in Sekunden | `900` |
| `{$ABB.EXPECT_REMOTE}` | NFS-Quelle | `192.0.2.10:/volume1/monitoring` |
| `{$ABB.EXPECT_FSTYPE}` | Dateisystem | `nfs` |

### 3.3 Low-Level-Discovery
Erstellt automatisch Items für jedes ABB-Device (Status, Dauer, Bytes, etc.)

---

## 📊 4. Graph / Dashboard

**Graph:**  
`ABB Capacity – Total vs Repo (bytes)`  
zeigt `sum_bytes` (grün, links) und `sum_repo_bytes` (blau, rechts)  
zur Kapazitätsentwicklung über 30–90 Tage.

---

## ✅ 5. Tests

Proxy-Test:
```bash
sudo -u zabbix /usr/lib/zabbix/externalscripts/abb.sh check 900
sudo -u zabbix /usr/lib/zabbix/externalscripts/abb.sh status 1
```

GUI-Test:  
**Monitoring → Latest data → Template Synology ABB External SingleScript**

---

## 🔍 Fehlerbehebung

| Problem | Ursache | Lösung |
|----------|----------|--------|
| `ABB Export Status = Problem (1)` | NFS nicht gemountet / CSV zu alt | Proxy: `abb.sh check 900` |
| `Status=99` | CSV fehlerhaft | ABB-Export prüfen |
| Keine Geräte | Discovery nicht gelaufen | Manuell triggern |
| `Permission denied` | falsche NFS-Rechte | DSM: no_root_squash |

---

## 📁 Struktur (Proxy)

```
/usr/lib/zabbix/externalscripts/abb.sh
/mnt/synology/monitoring/abb/
  ├── ActiveBackupExport.csv
  ├── ActiveBackupHostExport.csv
  └── export.log
```

---

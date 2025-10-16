# ABB Monitoring – Deployment & Debug Quickstart (Zabbix 7.x)

Diese Anleitung beschreibt die **korrekte Installation, Rechte-Setzung und Fehlersuche** für die Skripte `abb.sh` (Basiswerte) und `abb-enh.sh` (Text-/Listen-Ausgaben) in einer Zabbix-Umgebung. Alle IPs sind als Platzhalter angegeben (z. B. `NASIP`, `PROXYIP`).

> **Kurzfassung**:
> - `abb.sh` liefert Zahlen wie `success_today`, `failed_today`.
> - `abb-enh.sh` liefert Listen/Status-Text (z. B. `notok_list`).
> - Beide Skripte müssen **ausführbar** sein und als **User `zabbix`** auf die CSV-Dateien zugreifen können.

---

## 1) Pfade & Dateien

**Skripte (lokal auf Proxy/Server):**
- `/usr/lib/zabbix/externalscripts/abb.sh`
- `/usr/lib/zabbix/externalscripts/abb-enh.sh`

**CSV-Quelle (vom NAS via NFS):**
- Export-Ordner (Synology): `/volume1/monitoring/abb`
- Mountpunkt (Proxy/Server): `/mnt/synology/monitoring/abb`

**Erforderliche Variable für Skripte:**
- `ABB_CSV_PATH="/mnt/synology/monitoring/abb"`

---

## 2) Installation der Skripte

```bash
sudo mkdir -p /usr/lib/zabbix/externalscripts
sudo cp abb.sh /usr/lib/zabbix/externalscripts/
sudo cp abb-enh.sh /usr/lib/zabbix/externalscripts/
sudo chown root:root /usr/lib/zabbix/externalscripts/abb.sh /usr/lib/zabbix/externalscripts/abb-enh.sh
sudo chmod 0755 /usr/lib/zabbix/externalscripts/abb.sh /usr/lib/zabbix/externalscripts/abb-enh.sh
sudo sed -i '1c\#!/usr/bin/env bash' /usr/lib/zabbix/externalscripts/{abb.sh,abb-enh.sh}
sudo sed -i 's/\r$//' /usr/lib/zabbix/externalscripts/{abb.sh,abb-enh.sh}
```

---

## 3) NFS-Mount vom NAS einrichten (Synology UI + Linux-Mount)

### 3.1 Auf der Synology-NAS (über die DSM-Oberfläche)

1. **DSM öffnen:**  
   Melde dich an unter `https://NASIP:5001` → **Systemsteuerung → Gemeinsamer Ordner**.

2. Wähle den bestehenden Ordner **„monitoring“** oder lege einen neuen an.

3. Klicke auf **Bearbeiten → NFS-Berechtigungen → Erstellen** und setze folgende Werte:

   | Einstellung | Wert / Hinweis |
   |--------------|----------------|
   | **Hostname oder IP** | IP deines Zabbix-Proxys (z. B. `PROXYIP`) |
   | **Privileg** | Lesen/Schreiben (oder nur Lesen, falls ausreichend) |
   | **Squash** | `Root squash` oder `Map all users to admin` (wenn `zabbix`-UID kein Mapping hat) |
   | **Sicherheit** | `sys` |
   | **Aktiviere NFSv3 / NFSv4** | nach Umgebung (bei Berechtigungsproblemen meist `NFSv3`) |

4. **NFS aktivieren:**  
   Unter **Systemsteuerung → Dateidienste → NFS** sicherstellen, dass **„NFS aktivieren“** eingeschaltet ist.

---

### 3.2 Auf dem Zabbix-Proxy oder -Server (Konsolenseite)

1. **Mountpunkt vorbereiten:**
   ```bash
   sudo mkdir -p /mnt/synology/monitoring
   ```

2. **Test-Mount:**
   ```bash
   sudo mount -t nfs NASIP:/volume1/monitoring /mnt/synology/monitoring
   ```

3. **Lesetest als `zabbix`:**
   ```bash
   sudo -u zabbix ls -l /mnt/synology/monitoring/abb | head
   ```

4. **Persistenter Mount (fstab):**
   ```fstab
   NASIP:/volume1/monitoring  /mnt/synology/monitoring  nfs  rw,hard,tcp,vers=3,timeo=600,retrans=2,_netdev,nofail  0  0
   ```

5. **Mount prüfen:**
   ```bash
   sudo mount -a
   mount | grep synology
   ```

> 🔹 **Tipp:**  
> - „noexec“ darf **nicht** aktiv sein (würde die Ausführung von Skripten verhindern).  
> - Für reine CSV-Zugriffe reicht `ro` (read-only).  
> - UID/GID-Mapping prüfen: Dateien sollten für „others“ lesbar sein oder UID des `zabbix`-Users passen.

---

*(Die weiteren Kapitel zu Items, Debug und Sicherheit bleiben identisch zur vorherigen Version.)*

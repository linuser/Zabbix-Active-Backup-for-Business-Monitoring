# ABB Monitoring – Deployment & Debug Quickstart (Zabbix 7.x, English Version)

This guide explains the **correct installation, permission setup, and troubleshooting** for the scripts `abb.sh` (numeric values) and `abb-enh.sh` (text/list output) in a Zabbix environment.  
All IPs are placeholders (e.g., `NASIP`, `PROXYIP`).

> **Summary**:  
> - `abb.sh` provides numeric data such as `success_today` and `failed_today`.  
> - `abb-enh.sh` provides textual/list output (e.g., `notok_list`).  
> - Both scripts must be **executable** and the **`zabbix` user** must have read access to the CSV files.

---

## 1) Paths & Files

**Scripts (local on Proxy/Server):**
- `/usr/lib/zabbix/externalscripts/abb.sh`
- `/usr/lib/zabbix/externalscripts/abb-enh.sh`

**CSV Source (from NAS via NFS):**
- Export folder (Synology): `/volume1/monitoring/abb`
- Mount point (Proxy/Server): `/mnt/synology/monitoring/abb`

**Required environment variable:**
- `ABB_CSV_PATH="/mnt/synology/monitoring/abb"`

---

## 2) Script Installation

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

## 3) NFS Mount Setup (Synology UI + Linux Mount)

### 3.1 On the Synology NAS (via DSM Web UI)

1. **Open DSM:**  
   Log in to `https://NASIP:5001` → **Control Panel → Shared Folder**.

2. Select the existing **“monitoring”** folder or create a new one.

3. Click **Edit → NFS Permissions → Create** and configure the following:

   | Setting | Value / Comment |
   |----------|----------------|
   | **Hostname or IP** | IP of your Zabbix proxy (e.g., `PROXYIP`) |
   | **Privilege** | Read/Write (or Read-only if sufficient) |
   | **Squash** | `Root squash` or `Map all users to admin` (if `zabbix` UID has no mapping) |
   | **Security** | `sys` |
   | **Enable NFSv3 / NFSv4** | Depending on your setup (NFSv3 often more compatible) |

4. **Enable NFS service:**  
   Go to **Control Panel → File Services → NFS** and ensure **“Enable NFS”** is checked.

---

### 3.2 On the Zabbix Proxy or Server (Console Side)

1. **Prepare the mount point:**
   ```bash
   sudo mkdir -p /mnt/synology/monitoring
   ```

2. **Temporary test mount:**
   ```bash
   sudo mount -t nfs NASIP:/volume1/monitoring /mnt/synology/monitoring
   ```

3. **Read test as zabbix user:**
   ```bash
   sudo -u zabbix ls -l /mnt/synology/monitoring/abb | head
   ```

4. **Persistent mount via `/etc/fstab`:**
   ```fstab
   NASIP:/volume1/monitoring  /mnt/synology/monitoring  nfs  rw,hard,tcp,vers=3,timeo=600,retrans=2,_netdev,nofail  0  0
   ```

5. **Verify mount:**
   ```bash
   sudo mount -a
   mount | grep synology
   ```

> 🔹 **Tips:**  
> - The mount must **not** use the `noexec` option (would block script execution).  
> - `ro` (read-only) is sufficient for CSV access.  
> - Ensure UID/GID mapping is correct or the files are world-readable (`a+r`).

---

*(Remaining sections on Items, Debug commands, and Security best practices are identical to the German version.)*

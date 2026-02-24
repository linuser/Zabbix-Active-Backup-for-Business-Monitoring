# Synology Active Backup for Business — Zabbix Monitoring

🇩🇪 [Deutsche Version](README.de.md)

Monitor [Synology Active Backup for Business](https://www.synology.com/en-global/dsm/feature/active_backup_business) with Zabbix using CSV exports and a single external script.

## Features

- **Minimal overhead** — 4 external script calls per cycle, regardless of device count
- **Dependent-item architecture** — one JSON master, 12+ items derived via JavaScript preprocessing
- **Auto-discovery** — new backup devices appear automatically via LLD
- **Recovery triggers** — all alerts auto-resolve, no manual close needed
- **Backup-window awareness** — "last success too old" suppressed while backup is running
- **Per-device graphs** — backup size + duration created automatically per device
- **Dashboard included** — KPI widgets, problem overview, trend graphs

## Architecture

```
┌──────────────────────────┐                ┌──────────────────────────┐
│  Synology NAS            │     NFS        │  Zabbix Proxy / Server   │
│                          │ ──────────────►│                          │
│  SQLite DBs              │  CSV files     │  abb.sh json  (1 fork)   │
│    ↓                     │  (7 columns)   │    ├─ 12 dependent items │
│  abb_export.sh (cron)    │                │    └─ LLD (dependent)    │
│    ↓                     │                │                          │
│  ActiveBackupExport.csv  │                │  abb.sh check (1 fork)   │
│  ActiveBackupStats.csv   │                │  abb.sh *_today (2 fork) │
│                          │                │                          │
│  Cron: */5 * * * *       │                │  Total: 4 forks/cycle    │
└──────────────────────────┘                └──────────────────────────┘
```

## Quick Start

```bash
git clone https://github.com/linuser/Zabbix-Active-Backup-for-Business-Monitoring.git
cd synology-abb-zabbix
sudo ./install.sh
```

The interactive installer detects your platform (Synology or Zabbix) and guides you through setup. See **[INSTALL.md](INSTALL.md)** for detailed manual instructions.

## Requirements

| Component | Version | Notes |
|-----------|---------|-------|
| Synology DSM | 7.x | Active Backup for Business installed |
| Zabbix | 6.4+ | Tested on 7.4. JavaScript preprocessing required |
| NFS mount | — | Synology → Zabbix proxy (read-only is sufficient) |
| sqlite3 | — | Pre-installed on Synology |

## Repository Layout

```
├── synology/
│   ├── abb_export.sh                       # Export + enhance (single cron job)
│   └── abb_daily_summary.sh                # Daily totals → log
├── zabbix/
│   ├── abb.sh                              # External script (json, check, …)
│   └── abb-enh.sh                          # Enhanced report functions
├── template/
│   └── Synology-ABB-Zabbix-Check.xml       # Zabbix template (import via UI)
├── install.sh                              # Interactive / CLI installer
├── INSTALL.md / INSTALL.de.md              # Setup guide (EN / DE)
├── CHANGES.md                              # Changelog
└── README.md / README.de.md                # This file (EN / DE)
```

## Status Codes

These are ABB's internal status codes as stored in `device_result_table`:

| Code | Status  | Category | Trigger action |
|------|---------|----------|----------------|
| 1    | Running | Active   | Suppresses "too old" trigger |
| 2    | Success | OK       | Resolves ERROR/WARNING triggers |
| 3    | Aborted | Failed   | Counted as failed today |
| 4    | Error   | Failed   | HIGH alert per device |
| 5    | Warning | Warning  | WARNING alert per device |
| 8    | Partial | OK       | Resolves ERROR/WARNING triggers |
| 99   | Unknown | Fallback | Device not found in JSON |

## Template Macros

All thresholds are configurable — override per host as needed.

| Macro | Default | Description |
|-------|---------|-------------|
| `{$ABB.BACKUP.MAX.AGE}` | `129600` (36 h) | Alert if no success within this many seconds |
| `{$ABB.BACKUP.MAX.DURATION}` | `43200` (12 h) | Alert if a single backup takes longer |
| `{$ABB.EXPORT.MAXAGE}` | `900` (15 min) | CSV file staleness threshold |
| `{$ABB.FAILED.THRESHOLD}` | `1` | Min. daily failures to trigger |
| `{$ABB.RATE.THRESHOLD}` | `90` | Min. overall success rate (%) |
| `{$ABB.MOUNTPOINT}` | `/mnt/synology/monitoring` | NFS mount point on the proxy |
| `{$ABB.EXPECT_REMOTE}` | `192.168.33.2:/volume1/monitoring` | Expected NFS remote |
| `{$ABB.EXPECT_FSTYPE}` | `nfs` | Expected filesystem type |

## Triggers

| Trigger | Severity | Auto-recovers when… |
|---------|----------|----------------------|
| Export script or mount not OK | AVERAGE | `check` returns 0 |
| Device backup ERROR | HIGH | Status → Success (2) or Partial (8) |
| Device backup WARNING | WARNING | Status → Success (2) or Partial (8) |
| No successful backup for too long | HIGH | Age drops below `MAX_AGE` |
| Backup duration too long | WARNING | Duration drops below `MAX_DURATION` |
| N device(s) in ERROR (global) | WARNING | Error count = 0 |
| N failed backup(s) today | WARNING | Count drops below threshold |
| Success rate below N% | WARNING | Rate rises above threshold |

> **Post-import tip:** Set trigger dependencies in the Zabbix UI so that all triggers depend on *"Export script or mount not OK"*. This prevents alert storms when the NFS mount goes down.

## Dashboard

The template ships with a ready-made dashboard:

| Row | Widgets |
|-----|---------|
| 1 | Success Rate · Devices · Errors · Warnings · Total Bytes · Export Health |
| 2 | Active Problems (trigger overview) · Not-OK Device List |
| 3 | Backup Volume graph (7 d) · Success / Errors / Warnings trend (7 d) |

## Debugging

```bash
# Full JSON output (as zabbix user)
sudo -u zabbix /usr/lib/zabbix/externalscripts/abb.sh json | python3 -m json.tool

# Health check with debug output
ABB_DEBUG=1 /usr/lib/zabbix/externalscripts/abb.sh check 900 /mnt/synology/monitoring

# Human-readable report
/usr/lib/zabbix/externalscripts/abb-enh.sh report

# CSV sanity check (should show 7 columns)
head -2 /mnt/synology/monitoring/abb/ActiveBackupExport.csv
```

## Contributing

Issues and pull requests are welcome. Please test with `bash -n` (syntax check) and `xmllint --noout` (template validation) before submitting.

## License

[MIT](LICENSE)

## Author

Alexander Fox | [PlaNet Fox](https://planet-fox.com)

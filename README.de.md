# Synology Active Backup for Business — Zabbix-Monitoring

🇬🇧 [English Version](README.md)

Überwachung von [Synology Active Backup for Business](https://www.synology.com/de-de/dsm/feature/active_backup_business) mit Zabbix über CSV-Exporte und ein einzelnes externes Skript.

## Features

- **Minimaler Overhead** — 4 externe Skript-Aufrufe pro Zyklus, unabhängig von der Geräteanzahl
- **Dependent-Item-Architektur** — ein JSON-Master, 12+ Items via JavaScript-Preprocessing abgeleitet
- **Auto-Discovery** — neue Backup-Geräte erscheinen automatisch per LLD
- **Recovery-Trigger** — alle Alarme lösen sich automatisch auf, kein manuelles Schließen nötig
- **Backup-Fenster-Erkennung** — "Letztes Backup zu alt" wird unterdrückt solange ein Backup läuft
- **Graphen pro Gerät** — Backup-Größe + Dauer werden automatisch per LLD erstellt
- **Dashboard inklusive** — KPI-Widgets, Problemübersicht, Trendgraphen

## Architektur

```
┌──────────────────────────┐                ┌──────────────────────────┐
│  Synology NAS            │     NFS        │  Zabbix Proxy / Server   │
│                          │ ──────────────►│                          │
│  SQLite-Datenbanken      │  CSV-Dateien   │  abb.sh json  (1 Fork)   │
│    ↓                     │  (7 Spalten)   │    ├─ 12 Dependent Items │
│  abb_export.sh (Cron)    │                │    └─ LLD (dependent)    │
│    ↓                     │                │                          │
│  ActiveBackupExport.csv  │                │  abb.sh check (1 Fork)   │
│  ActiveBackupStats.csv   │                │  abb.sh *_today (2 Fork) │
│                          │                │                          │
│  Cron: */5 * * * *       │                │  Gesamt: 4 Forks/Zyklus  │
└──────────────────────────┘                └──────────────────────────┘
```

## Schnellstart

```bash
git clone https://github.com/YOUR_USER/synology-abb-zabbix.git
cd synology-abb-zabbix
sudo ./install.sh
```

Der interaktive Installer erkennt die Plattform (Synology oder Zabbix) automatisch. Für die manuelle Einrichtung siehe **[INSTALL.de.md](INSTALL.de.md)**.

## Voraussetzungen

| Komponente | Version | Hinweise |
|------------|---------|----------|
| Synology DSM | 7.x | Active Backup for Business installiert |
| Zabbix | 6.4+ | Getestet mit 7.4. JavaScript-Preprocessing erforderlich |
| NFS-Mount | — | Synology → Zabbix-Proxy (read-only reicht) |
| sqlite3 | — | Auf Synology vorinstalliert |

## Dateistruktur

```
├── synology/
│   ├── abb_export.sh                       # Export + Anreicherung (ein Cron-Job)
│   └── abb_daily_summary.sh                # Tageszusammenfassung → Log
├── zabbix/
│   ├── abb.sh                              # Externes Skript (json, check, …)
│   └── abb-enh.sh                          # Erweiterte Reportfunktionen
├── template/
│   └── Synology-ABB-Zabbix-Check.xml       # Zabbix-Template (Import via UI)
├── install.sh                              # Interaktiver / CLI-Installer
├── INSTALL.md / INSTALL.de.md              # Installationsanleitung (EN / DE)
├── CHANGES.md                              # Changelog
└── README.md / README.de.md                # Diese Datei (EN / DE)
```

## Status-Codes

Interne ABB-Status-Codes aus der `device_result_table`:

| Code | Status  | Kategorie | Trigger-Aktion |
|------|---------|-----------|----------------|
| 1    | Läuft   | Aktiv     | Unterdrückt "zu alt"-Trigger |
| 2    | Erfolg  | OK        | Löst ERROR/WARNING-Trigger auf |
| 3    | Abgebrochen | Fehlgeschlagen | Wird als Fehler heute gezählt |
| 4    | Fehler  | Fehlgeschlagen | HIGH-Alarm pro Gerät |
| 5    | Warnung | Warnung   | WARNING-Alarm pro Gerät |
| 8    | Teilweise | OK      | Löst ERROR/WARNING-Trigger auf |
| 99   | Unbekannt | Fallback | Gerät nicht im JSON gefunden |

## Template-Makros

Alle Schwellwerte sind konfigurierbar — pro Host überschreibbar.

| Makro | Standard | Beschreibung |
|-------|----------|--------------|
| `{$ABB.BACKUP.MAX.AGE}` | `129600` (36 h) | Alarm wenn kein Erfolg innerhalb dieser Sekunden |
| `{$ABB.BACKUP.MAX.DURATION}` | `43200` (12 h) | Alarm wenn ein Backup länger dauert |
| `{$ABB.EXPORT.MAXAGE}` | `900` (15 min) | Schwellwert für CSV-Aktualität |
| `{$ABB.FAILED.THRESHOLD}` | `1` | Min. tägliche Fehler für Trigger |
| `{$ABB.RATE.THRESHOLD}` | `90` | Min. Erfolgsrate in % |
| `{$ABB.MOUNTPOINT}` | `/mnt/synology/monitoring` | NFS-Mountpoint auf dem Proxy |
| `{$ABB.EXPECT_REMOTE}` | `192.168.33.2:/volume1/monitoring` | Erwartete NFS-Quelle |
| `{$ABB.EXPECT_FSTYPE}` | `nfs` | Erwarteter Dateisystemtyp |

## Trigger

| Trigger | Schweregrad | Automatische Rückkehr wenn… |
|---------|-------------|------------------------------|
| Export-Skript oder Mount nicht OK | AVERAGE | `check` liefert 0 |
| Geräte-Backup FEHLER | HIGH | Status → Erfolg (2) oder Teilweise (8) |
| Geräte-Backup WARNUNG | WARNING | Status → Erfolg (2) oder Teilweise (8) |
| Kein erfolgreiches Backup seit zu langer Zeit | HIGH | Alter fällt unter `MAX_AGE` |
| Backup-Dauer zu lang | WARNING | Dauer fällt unter `MAX_DURATION` |
| N Gerät(e) im FEHLER-Status (global) | WARNING | Fehlerzahl = 0 |
| N fehlgeschlagene(s) Backup(s) heute | WARNING | Anzahl fällt unter Schwellwert |
| Erfolgsrate unter N% | WARNING | Rate steigt über Schwellwert |

> **Tipp nach dem Import:** Trigger-Abhängigkeiten in der Zabbix-UI setzen: alle Trigger → hängen ab von *"Export-Skript oder Mount nicht OK"*. Das verhindert Alarm-Kaskaden wenn der NFS-Mount ausfällt.

## Dashboard

Das Template bringt ein fertiges Dashboard mit:

| Zeile | Widgets |
|-------|---------|
| 1 | Erfolgsrate · Geräteanzahl · Fehler · Warnungen · Gesamtvolumen · Export-Status |
| 2 | Aktive Probleme (Triggerübersicht) · Nicht-OK-Geräteliste |
| 3 | Backup-Volumen (7 Tage) · Erfolge / Fehler / Warnungen Trend (7 Tage) |

## Fehlersuche

```bash
# JSON-Ausgabe (als zabbix-User)
sudo -u zabbix /usr/lib/zabbix/externalscripts/abb.sh json | python3 -m json.tool

# Health-Check mit Debug-Ausgabe
ABB_DEBUG=1 /usr/lib/zabbix/externalscripts/abb.sh check 900 /mnt/synology/monitoring

# Lesbarer Report
/usr/lib/zabbix/externalscripts/abb-enh.sh report

# CSV-Prüfung (sollte 7 Spalten zeigen)
head -2 /mnt/synology/monitoring/abb/ActiveBackupExport.csv
```

## Mitmachen

Issues und Pull Requests sind willkommen. Bitte vor dem Einreichen testen mit `bash -n` (Syntaxprüfung) und `xmllint --noout` (Template-Validierung).

## Lizenz

[MIT](LICENSE)

## Autor

Alexander Fox | [PlaNet Fox](https://planet-fox.com)

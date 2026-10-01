# Changelog

## v3.5 (2026-09-19)

Fünfte Review-Runde — gegen die Live-Installation (Zabbix-Proxy, NFS auf die NAS) getestet, nicht nur gelesen.

### Zabbix-Skripte (`abb.sh`)

- **JSON-Escaping im Master-Item und in der LLD.** `do_json` und `do_discovery` entfernten nur `"` aus dem Hostnamen. Ein Backslash — bei Windows-Geräten völlig normal, etwa `DOMAIN\PC01` — blieb stehen und erzeugte ungültiges JSON. Die Folge trifft nicht nur das betroffene Gerät: das Master-Item lässt sich nicht mehr parsen, womit **alle abhängigen Items und die komplette Discovery** ausfallen. Reproduziert (`Invalid \escape`), behoben durch eine `jesc()`-Funktion, die Backslash, Quote, Tab, CR und LF escaped und übrige Steuerzeichen verwirft.
- **`sudo` kann nicht mehr hängen.** Der Lesbarkeits-Check rief `sudo -u zabbix test -r` ohne `-n` auf. Ohne passenden sudoers-Eintrag wartet das auf eine Passwort-Eingabe, die im Zabbix-Kontext nie kommt — das Item läuft in den Timeout statt eine Zahl zu liefern. Jetzt `sudo -n`.
- **Locale fixiert (`LC_ALL=C`).** Unter `de_DE.UTF-8` formatiert awk `%.1f` als `21,4` statt `21.4`. In kommaseparierten Listen und in JSON ist ein Dezimalkomma fatal.

### Synology-Skripte (`abb_export.sh`)

- **Leerer Export löscht nicht mehr den gesamten State.** Das Pruning aus v3.4 übernahm nur Geräte, die im aktuellen Export vorkommen. Liefert sqlite erfolgreich ein *leeres* Resultset (z. B. nachdem ABB alte Ergebnisse aus `device_result_table` entfernt hat), war `present` leer und **jeder** `LAST_SUCCESS_TS` fiel weg. Jedes Gerät hätte danach `last_success_age = 2147483647` gemeldet, also einen HIGH-Alarm ausgelöst, und die Zeitstempel sind nicht rekonstruierbar. Gepruned wird jetzt nur noch, wenn der Export mindestens eine Datenzeile hat; sonst greift eine WARN-Zeile im Log. Das reguläre Pruning entfernter Geräte funktioniert unverändert (end-to-end verifiziert).
- **Lock-Race geschlossen.** Zwischen `mkdir "$LOCK_DIR"` und dem Schreiben von `pid` lag ein Fenster, in dem ein zweiter Lauf eine leere pid-Datei vorfand, den Lock für verwaist hielt, ihn per `rm -rf` übernahm — und beide Läufe parallel weiterliefen. Zusätzlich löschte der EXIT-Trap den Lock bedingungslos, also womöglich den eines fremden Laufs. Eine leere pid führt jetzt zu einem zweiten Leseversuch statt sofort zur Übernahme, und freigegeben wird nur, wenn die pid im Lock noch die eigene ist.

### Export-Query (`abb_export.sh`)

- **Kein doppeltes Gerät mehr in der CSV.** Haben zwei Zeilen in `device_result_table` für dasselbe Gerät exakt dasselbe `time_end`, lieferte der JOIN auf `MAX(time_end)` beide — das Gerät stand zweimal in der CSV. In Zabbix erzeugt das ein LLD-Duplikat und verfälscht `device_count` und `sum_bytes`. Ein `GROUP BY config_device_id` in der äußeren Query garantiert jetzt genau eine Zeile je Gerät. Bewusst ohne `rowid`-Tiebreaker gelöst: ABBs Schema ist von außen nicht einsehbar, und bei einer `WITHOUT ROWID`-Tabelle gäbe es `rowid` nicht — verifiziert, dass die gewählte Variante auch dort läuft.
- **Geräte mit ausschließlich laufenden Backups verschwanden.** `MAX(time_end)` ignoriert NULL. Hatte ein Gerät nur Zeilen mit `time_end IS NULL` — also ein erstes, noch laufendes Backup —, war das Maximum NULL und die JOIN-Bedingung nie wahr: das Gerät fiel komplett aus der CSV und damit aus der Discovery. `COALESCE(time_end, 0)` im Sub-Select und in der JOIN-Bedingung behebt das; das Gerät erscheint jetzt mit `status=1` (Running).

### Zabbix-Skripte (`abb.sh`) — zusätzlich

- **Dedup-Guard in allen CSV-Scannern.** Unabhängig von der Query-Korrektur überspringen jetzt alle neun awk-Programme eine bereits gesehene DEVICEID. Damit erzeugt auch eine ältere, noch auf dem NFS liegende CSV mit Duplikaten weder LLD-Fehler noch falsche Zähler.

### Installer (`install.sh`)

- **Kein `/etc/crontab` mehr auf DSM.** Der Installer hängte die Cron-Zeilen an `/etc/crontab` an. DSM generiert diese Datei aber aus seiner eigenen Aufgaben-Datenbank neu — bei Updates, Neustarts und jeder Änderung im Aufgabenplaner —, wobei handgeschriebene Einträge kommentarlos verschwinden. In der Live-Installation war die Folge, dass der Export **kein einziges Mal** lief: das `export.log` enthielt exakt sechs Zeilen aus den manuellen Testläufen der Installation, danach 208 Tage nichts. Auf DSM gibt der Installer jetzt die beiden fertigen Kommandozeilen für den Aufgabenplaner aus, statt einen Eintrag anzulegen, der planmäßig wieder verschwindet. Auf Nicht-DSM-Systemen bleibt der `/etc/crontab`-Weg.
- **`--check` misst die Zeitsteuerung am CSV-Alter.** Bisher prüfte er mit `grep abb_export.sh /etc/crontab`, ob ein Eintrag existiert — auf DSM schon im Normalfall aussichtslos, und das Ergebnis war nur eine Warnung. Genau deshalb blieb unbemerkt, dass nie etwas lief. Jetzt zählt, ob die CSV jünger als 900 s ist; andernfalls ein harter Fehler mit Hinweis auf den Aufgabenplaner.
- **Zabbix-Prüfung nur bei vorhandener Zabbix-Installation.** `id zabbix` allein genügte als Bedingung — auf der NAS existiert eine `zabbix`-Gruppe für den NFS-Zugriff, aber kein Zabbix. `--check` meldete dort zwei Fehler, die keine waren. Zusätzlich muss jetzt `ZBX_EXT_DIR` existieren.
- **Deinstallation weist auf den Aufgabenplaner hin**, aus dem der Installer die Aufgaben nicht entfernen kann.

### Dokumentation

- **Troubleshooting-Zeile „Export läuft nur ~1 h/Tag".** In der Praxis gesehen: die DSM-Aufgabe lief, aber mit zu früher „Letzte Ausführungszeit" (z. B. `00:55`) — der Export stoppte nach dem Zeitfenster und stand 23 h still, die CSV veraltete und `check` meldete „Problem". `INSTALL.md`/`INSTALL.de.md` haben dafür jetzt eine eigene Zeile mit der Lösung (Letzte Ausführungszeit `23:55`).
- **Beispiel-NFS-Remote auf eine Doku-IP (`192.0.2.10`, RFC 5737) umgestellt** in README und Template-Default, statt einer realen Adresse.

### Getestet

Gegen die Live-Umgebung verifiziert: autofs+NFS-Mischmount, `check` in fünf Varianten, alle Subcommands ohne Abweichung zur Vorversion, JSON-Validität mit Sonderzeichen, Export-Pfad end-to-end über einen Fake-`sqlite3` (Aufbau / Pruning / leerer Export).

Die Query-Korrekturen wurden gegen eine lokal nachgebaute `device_result_table` geprüft — Duplikat-Fall, Nur-NULL-`time_end`-Fall, Determinismus über mehrere Läufe und Lauffähigkeit auf einer `WITHOUT ROWID`-Tabelle — und anschließend durch das echte Skript hindurch, sodass auch das Shell-Quoting der Query abgedeckt ist.

Anschließend auf der NAS selbst (DSM 7.2, DS918+) gegen die echte `activity.db` geprüft: das Schema bestätigt alle sechs genutzten Spalten, und alte wie neue Query liefern auf dem Produktivbestand byte-identische Ergebnisse. Beide Query-Korrekturen sind dort derzeit **präventiv** — der Bestand enthält weder doppelte `time_end` noch `NULL`-Werte. v3.5 wurde installiert und der Export einmal vollständig durchlaufen: 3 Geräte, 7 Spalten, genau eine Zeile je Gerät, und die Zabbix-Seite meldet über NFS wieder `check = 0`.

Dabei bestätigt, dass die Fixes aus v3.1 und v3.2 real greifen: `abb-enh.sh failed_info` meldete in v3.0 trotz zweier Funde noch „All devices OK", und `check` gab bei einem autofs-only-Mount gar nichts aus (Item wird in Zabbix unsupported) — beides in der neuen Version behoben.

## v3.4 (2026-09-06)

### Synology Scripts (`abb_export.sh`)

- **State file is now pruned.** `.abb_last_success.state` previously retained a `LAST_SUCCESS_TS` row for every device that had ever succeeded, including ones long since removed from Active Backup — the file grew without bound. The state update now marks which device IDs appear in the current export and carries forward only those, so entries for removed devices are dropped. Devices still present keep their last-success timestamp even on a day they fail (verified). Note: a device that is removed and later re-added starts fresh (last-success 0 until it next succeeds), which is the correct treatment for what is effectively a new device.

## v3.3 (2026-07-20)

Fourth review round — installer robustness and output hygiene.

### Installer (`install.sh`)

- **Path-baking survives special characters.** The `sed` that bakes `ABB_CSV_PATH` / `ABB_ZBX_USER` into the installed Zabbix scripts injected the raw value into the replacement side, so a path containing `&` (expands to the whole match) or `|` (the sed delimiter) produced a corrupt script. The replacement is now escaped.
- **Cron env values are quoted.** A CSV/DB path containing a space broke the cron env prefix — `ABB_DIR=/my backups/abb …` made cron try to run `backups/abb` as the command. Values are single-quoted now.
- **`ask()` hardened** against `set -euo pipefail` on EOF (piped/empty stdin no longer aborts), and `ans` is now local.
- **Stat race in `--check`** — the CSV age used `$(date) - $(stat …)` with no fallback; if the file vanished between the existence test and the stat, the empty result caused an arithmetic abort. Now falls back to mtime 0.
- **Output hygiene** — all colored `printf` calls moved the escape codes out of the format string (into `%b` arguments), and the `check_installation` assertions were rewritten from the fragile `cond && ok || { fail; errors++; }` idiom to explicit `if/else`. `install.sh` is now fully shellcheck-clean.

### Zabbix Scripts (`abb_debug.sh`)

- Same `printf` hygiene: colored helpers and the summary lines (which interpolated `$FAIL`/`$WARN` directly into the format) now pass values as arguments.

## v3.2 (2026-07-20)

Third review round — concurrency and the mount check.

### Zabbix Scripts (`abb.sh`)

- **`check` no longer aborts on autofs-only mounts.** The line that picked the non-autofs mount line used `grep -v autofs | head -1`. Under `set -euo pipefail`, an autofs-only result made `grep` exit non-zero → the whole function aborted and `check` printed *nothing* (Zabbix item goes "unsupported") — and it aborted *before* the branch specifically written to tolerate autofs, making that branch dead code. Replaced with `awk '!/autofs/'`, which always exits 0. Verified across autofs-only, mixed autofs+NFS, correct-NFS, and wrong-remote cases.

### Synology Scripts (`abb_export.sh`)

- **Concurrency safety.** Cron does not serialize, so a slow run (busy DB, full `sync`) could overlap the next tick. The enhance step used fixed-name temp files (`.bak`, `.tmp`, `.state.tmp`), so two runs could corrupt the shared state file, and an early-exiting run's cleanup could delete an active run's temps. Temp files are now PID-unique, and a `mkdir`-based lock (atomic, BusyBox-safe) serializes runs: a second run detects the live lock via `kill -0` and skips; a stale lock from a dead PID is taken over. The lock is released even when the export fails.

## v3.1 (2026-06-29)

Bugfix release from code review.

### Synology Scripts (`abb_export.sh`)

- **Comma-safe hostnames** — commas in `device_name`/`host_name` are now replaced with spaces in SQL. Previously a comma made sqlite quote the field, which the naive `awk -F','` parser split in two, shifting every column and corrupting that device's status/bytes/discovery.
- **No silent CSV truncation** — sqlite is now run without a pipe so its real exit status is checked. On failure (e.g. `database is locked`) the previous CSV is retained instead of being atomically overwritten by an empty/partial file. The enhance step is skipped on failure so freshness detection still works.
- **Portable midnight fallback** — removed the `10#$H` base prefix (undefined in BusyBox/POSIX ash) and the octal trap on `08`/`09`; a single leading zero is now stripped instead.

### Zabbix Scripts

- **`abb-enh.sh failed_info`** — fixed subshell scoping (process substitution instead of pipe-into-while) so "All devices OK" no longer prints alongside listed failures.
- **`abb.sh`** — `log_debug` rewritten as an explicit `if` (SC2015).
- **`abb_debug.sh`** — corrected the misleading "quotes come from spaces" hint (commas are the real hazard), added a field-count consistency check, fixed `printf` format-string usage.

### Installer

- **`--check`** — now reads the actual health value (`head -1`) and passes the mountpoint, instead of always reporting "check passed" (it had been testing the always-zero exit code of the script).
- **Configured paths are now actually used.** Previously the interactive prompts set `SYN_ABB_DIR` / `SYN_DB_DIR` / `ZBX_CSV_PATH` / `ZBX_USER`, but nothing propagated them: the cron line invoked the script bare, so it fell back to its compiled-in defaults; the initial run passed only `ABB_DIR`; and Zabbix (which calls external scripts with an empty environment) never saw `ABB_CSV_PATH`. The cron entry now carries an env prefix, the initial run passes all three vars, and the installed Zabbix copies get their defaults rewritten in place.
- **Tab-separated cron fields** — DSM's crond expects tabs between schedule/user/command; space-separated entries are silently ignored. Tabs are valid on standard cron too.
- **sqlite3 detection** — dropped the nonsensical `${SYN_DB_DIR}/../usr/bin/sqlite3` (= `/volume1/usr/bin/sqlite3`) probe; now checks real locations and falls back to `command -v`.
- **Uninstall** — `rm -f` always succeeds, so it reported "removed" for scripts that were never installed. Now checks existence first and warns when nothing was found.

### Cleanup

- **`abb.sh`** — removed `repo_bytes` / `sum_repo_bytes`. They were unreferenced placeholders that returned a hard-coded `0`; a monitoring system storing a fake zero is worse than the item not existing. **Breaking** if you built custom items on them.
- **`abb.sh`** — every CSV-reading subcommand now guards with `require_csv`. Previously a missing CSV leaked a raw `awk: cannot open ...` error and exit 2; now it's a clean `ERROR: CSV not readable` and exit 1.
- **`abb.sh`** — corrected the comment claiming the per-device subcommands are "still used by abb-enh.sh"; `abb-enh.sh` reads the CSV directly and never calls `abb.sh`. Also expanded the usage line to list all valid subcommands.
- **`abb_daily_summary.sh`** — a header-only stats CSV (e.g. after a failed export) logged an empty `[DAILY]` line; now logs an explicit error and exits 1.

### Known / intentionally unchanged

- `ActiveBackupHostExport.csv` is still exported but consumed by nothing (not the template, not `abb.sh`). Left in place in case downstream tooling reads it.
- `abb_export.sh` calls `sync` before each atomic `mv` — a full filesystem sync, three times per 5-minute cycle. Kept for durability, but `fsync` on the temp file alone would be cheaper on a busy NAS.

### Docs

- README quick-start `cd` path corrected to the real clone directory name.

## v3.0 (2026-02-24)

Complete rewrite of all components.

### Synology Scripts

- **Single export script** — `abb_export.sh` now handles export + LAST_SUCCESS_TS enrichment in one atomic operation. Separate `abb_export_enhance_last_success.sh` removed.
- **Fixed status codes** — original used `status=0` for success; ABB uses `2=Success`, `8=Partial`, `4=Error`, `5=Warning`.
- **Trap cleanup** — temp files removed on exit/error via `trap ... EXIT`.
- **Log rotation** — `export.log` auto-trimmed to 2000 lines.
- **Atomic writes** — CSVs written to temp then `mv`, preventing partial reads.
- **Fixed `failed_today`** — counts status 3+4 only. Original counted everything except 2 as failed.

### Zabbix Template

- **4 external forks** (down from ~137 at 20 devices) — dependent-item pattern with JavaScript preprocessing.
- **Dependent discovery** — LLD from JSON master, no extra fork.
- **JavaScript preprocessing** — replaces JSONPath (compatibility issues with `.length()`, `.sum()`, `.first()`, `||`).
- **Recovery expressions** — all triggers auto-resolve.
- **Backup-window awareness** — "too old" suppressed while status=1 (Running).
- **Graph prototypes** — per-device bytes + duration graph via LLD.
- **Dashboard** — 6 KPI widgets, trigger overview, not-OK list, trend graphs.

### Zabbix Scripts

- **7 missing subcommands** — `failed_count`, `warn_count`, `notok_count`, `notok_list`, `sum_bytes`, `sum_repo_bytes`, `repo_bytes`.
- **JSON master** — `abb.sh json` returns all device data.
- **Fixed `check`** — nested sudo failed when already running as zabbix.
- **Fixed `findmnt`** — prefers NFS line over autofs.

### Installer

- **Fixed `ask()`** — prompt to stderr, captures only user input.
- **Fixed menu input** — accepts `2` and `2)`.
- **Platform detection** — auto-detects Synology vs Zabbix.
- **CLI mode** — `./install.sh synology|zabbix|all|--check|--uninstall`.

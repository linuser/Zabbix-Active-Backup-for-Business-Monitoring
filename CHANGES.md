# Changelog

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

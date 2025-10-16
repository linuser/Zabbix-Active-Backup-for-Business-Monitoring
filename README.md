🧩 Synology Active Backup for Business (ABB) Monitoring for Zabbix

🇩🇪 Kurzbeschreibung (Deutsch)
Ein leichtgewichtiges Monitoring-Addon für Synology Active Backup for Business, kompatibel mit Zabbix 7.2 bis 7.5.
Das Skript liest die ABB-Export-CSV-Dateien direkt vom NAS (per NFS) und liefert Kennzahlen wie Backup-Status, Dauer, Datenmenge und Zeit seit letztem Erfolg – alles über ein einziges External Script (abb.sh).

✨ Funktionen
	•	🧩 Einzelskript-Lösung: nur abb.sh auf dem Proxy erforderlich
	•	🔍 Automatische Discovery (LLD): erkennt ABB-Geräte dynamisch
	•	📊 Pro-Device-Items: Status, Bytes, Dauer, letzter Erfolg
	•	🔒 Nur-Lese-Zugriff per NFS – kein Agent auf dem NAS notwendig
	•	⚙️ Kompatibel mit DSM 7.x & Zabbix 7.2–7.5
	•	❤️ Entwickelt und gepflegt mit Liebe von Alexander Fox | PlaNet Fox

⸻

🇬🇧 Short Description (English)
A lightweight monitoring extension for Synology Active Backup for Business, compatible with Zabbix 7.2–7.5.
Reads ABB export CSVs directly from your NAS via NFS and provides metrics such as backup status, duration, bytes processed, and age since last success – all handled by a single external script (abb.sh).

✨ Features
	•	🧩 Single-script design – just abb.sh on your Zabbix Proxy
	•	🔍 Automatic discovery (LLD) for ABB devices
	•	📊 Per-device items: status, bytes, duration, last success age
	•	🔒 Read-only NFS access – no agent required on the NAS
	•	⚙️ Compatible with DSM 7.x and Zabbix 7.2 → 7.5
	•	❤️ Maintained with love by Alexander Fox | PlaNet Fox

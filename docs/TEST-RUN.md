# Testlauf und Nachweis

Datum: **2026-11-13**

Getestet wurde die vollständige Provisionierung in einem **privilegierten
Debian-13-Container mit systemd** (Docker). Ein echter Proxmox-LXC stand in
der Entwicklungsumgebung nicht zur Verfügung; die `pct`-Schritte des
Host-Installers konnten daher nicht gegen einen realen Proxmox-Host
ausgeführt werden. Das ist die einzige nicht abgedeckte Schicht.

---

## Testumgebung

| Komponente | Version |
|---|---|
| Host-Kernel | Linux (Docker 29.1.3) |
| Test-Container | `debian:trixie`, privileged, systemd als PID 1 |
| Debian | 13 (trixie) |
| systemd | 257 |
| PHP | 8.4.27 (FPM + CLI) |
| MariaDB | 11.8.6 |
| nginx | 1.26.3 |
| TastyIgniter | 4.5.0 |
| Node.js (nur UI-Test) | 22.14.0 |
| Playwright | 1.65 |

Container-Startbefehl (Docker):

```bash
docker run -d --name ti-systemd-test --privileged \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  debian:trixie \
  bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq systemd systemd-sysv dbus >/dev/null && exec /sbin/init'
```

> Hinweis: `/tmp` ist dort ein tmpfs. Dateien müssen deshalb nach `/root`
> kopiert werden, nicht nach `/tmp`.

Provisionierung im Container:

```bash
docker cp tastyigniter-proxmox.tar.gz ti-systemd-test:/root/repo.tar.gz
docker exec ti-systemd-test bash -lc '
  rm -rf /opt/tastyigniter-proxmox &&
  mkdir -p /opt/tastyigniter-proxmox &&
  tar -xzf /root/repo.tar.gz -C /opt/tastyigniter-proxmox &&
  APP_CTID=999 APP_IP=172.17.0.2 APP_PORT=8080 \
  APP_TIMEZONE=Europe/Berlin ADMIN_EMAIL=admin@tastyigniter.local \
  RESTAURANT_NAME="Test Restaurant" TI_VERSION=4.5.0 \
  PROVISION_ACTION=install \
  bash /opt/tastyigniter-proxmox/install/provision.sh'
```

---

## Test 1 — Erstinstallation

Ergebnis: **erfolgreich**

Auszug aus dem Provision-Log:

```text
[ OK ]  Datenbank und Benutzer bereit.
[ OK ]  TastyIgniter 4.5.0 entpackt.
Admin user admin@tastyigniter.local created.
[ OK ]  PHP 8.4 und Extensions bereit.
[ OK ]  tastyigniter.service aktiv, Socket /run/php/php8.4-fpm.sock vorhanden.
[ OK ]  nginx läuft auf Port 8080.
[ OK ]  Status-Dashboard installiert.
[ OK ]  HTTP 200 – /
[ OK ]  HTTP 200 – /admin/login
[ OK ]  HTTP 200 – /status/
[ OK ]  HTTP 200 – /status/api/status
[ OK ]  Status-API bestätigt Datenbank, PHP-FPM, nginx und MariaDB.
```

Geprüfte Endpunkte:

| URL | Status |
|---|---|
| `http://127.0.0.1:8080/` | `200` |
| `http://127.0.0.1:8080/admin/login` | `200` |
| `http://127.0.0.1:8080/status/` | `200` |
| `http://127.0.0.1:8080/status/api/status` | `200`, gültiges JSON |

Zusätzlich verifiziert:

- Admin-Benutzer wurde angelegt (`admin_users = 1`).
- Admin-Passwort wurde per `Hash::check` und `password_verify` geprüft.
- `tastyigniter`, `nginx` und `mariadb` sind `active` und `enabled`.
- Status-API meldet:

```json
{
  "ok": true,
  "services": {
    "web": true,
    "php_fpm": true,
    "nginx": true,
    "mariadb": true
  }
}
```

---

## Test 2 — Idempotentes Update

Ergebnis: **erfolgreich**

Der Installer wurde mit `PROVISION_ACTION=update` erneut ausgeführt:

- Paketinstallation und `igniter:update` liefen durch (`0 updates found`).
- Migrationen: `Nothing to migrate.`
- Admin-Benutzer: `Admin user already exists – skipping creation.`
- Dashboard und nginx-Konfiguration wurden neu ausgerollt.
- `installed_at` blieb unverändert (`2026-11-13T13:05:18Z`).
- Port, Restaurantname und Admin-E-Mail blieben erhalten.
- Alle vier HTTP-Endpunkte lieferten weiterhin `200`.

Auszug:

```text
[INFO]  Prüfe auf TastyIgniter- und Extension-Updates …
Checking for updates...
0 updates found
[OK]    TastyIgniter-Update-Prüfung abgeschlossen.
[INFO]  TastyIgniter ist bereits installiert – führe Migrationen aus …
   INFO  Nothing to migrate.
Admin user already exists – skipping creation.
[ OK ]  HTTP 200 – /status/api/status
[ OK ]  Status-API bestätigt Datenbank, PHP-FPM, nginx und MariaDB.
```

Damit ist der Installer für einen erneuten Lauf idempotent.

---

## Test 3 — Neustart

Ergebnis: **erfolgreich**

```bash
docker restart ti-systemd-test
```

Messung:

- Services nach dem Neustart: **22 Sekunden** bis `tastyigniter`, `nginx` und
  `mariadb` gleichzeitig `active` waren.
- `systemctl is-enabled` für alle drei Dienste: `enabled`.
- HTTP nach dem Neustart:

```text
/                     200
/admin/login          200
/status/              200
/status/api/status    200
```

Status-API nach dem Neustart:

```json
{
  "ok": true,
  "services": {"web": true, "php_fpm": true, "nginx": true, "mariadb": true},
  "database_ok": true,
  "uptime": 13
}
```

Die Uptime wird aus PID 1 des Containers berechnet und zeigt nach dem
Neustart korrekt die neue Laufzeit.

> `onboot: 1` ist im Host-Installer gesetzt und wird von
> `tests/proxmox-smoke-test.sh` auf einem echten Proxmox-Host geprüft. In
> Docker existiert dieses Proxmox-Feld nicht.

---

## Test 4 — React-Dashboard (Playwright)

Ergebnis: **erfolgreich**

Getestet mit Chromium, Desktop (1440 × 1200) und Mobil (390 × 844):

- HTTP-Status: `200`
- Titel: `TastyIgniter · Control Center`
- H1: `Restaurant-Betrieb. Einfach lokal.`
- Console Errors: `[]`
- Page Errors: keine
- Alle Services werden als aktiv angezeigt
- Mobile Layout ohne horizontalen Überlauf

Screenshots:

- [Desktop](dashboard.png)
- [Mobil](dashboard-mobile.png)

Der Test deckte einen echten Bug auf: Die Status-API prüfte den PHP-FPM-Socket
mit `is_file()`, was bei Unix-Sockets immer `false` liefert. Die Erkennung
wurde auf `file_exists()`/Glob umgestellt; danach meldet das Dashboard
PHP-FPM korrekt als aktiv.

---

## Test 5 — Lokale Qualitätschecks

```bash
./tests/local-checks.sh
```

Geprüft:

- `bash -n` für Host-Installer, Provisionierung, URL-Updater und Testscripts
- ShellCheck auf Warnlevel: keine Findings
- `php -l` für `create-admin.php` und `status.php`
- TypeScript + Vite Build (`npm run build`)
- Pflichtdateien, Platzhalter, `Restart=always`, `--onboot 1`,
  `systemctl enable`
- Dashboard-Build verwendet das Basis-Pfad `/status/`

---

## Test 6 — Host-Installer mit Proxmox-Mocks

Ergebnis: **erfolgreich**

Da kein echter Proxmox-Host verfügbar war, wurden die Host-Funktionen mit
Stub-`pct`/`pvesh`/`pveam`/`pvesm`-Binaries geprüft:

- Nächste freie CT-ID wird über `pvesh get /cluster/nextid` ermittelt.
- Template-Erkennung findet `local:vztmpl/debian-13-standard_…tar.zst`.
- Rootfs-Storage wird als `local-lvm` erkannt.
- `pct create` erhält Hostname, CPU, RAM, Disk, Bridge und `--onboot 1`.
- Ein absichtlich fehlschlagender `pct push` beendet das Script mit dem
  Original-Exit-Code (7) und zeigt Exit-Code, Zeile und Befehl.
- Der Host-Log-Ausschnitt ist dank ungepufferter Ausgabe
  (`stdbuf -o0`) bereits während des Fehlers lesbar.
- Temporäre Payload-Verzeichnisse werden beim Exit entfernt.
- `status`/`uninstall` ohne vorhandenen Container enden mit einer klaren
  Meldung statt mit einer erfundenen CT-ID.
- `status` erkennt einen vorhandenen Container über den Tag
  `tastyigniter`, übernimmt den gespeicherten Port `9090` und zeigt
  Storefront, Admin und Status-UI mit diesem Port.

---

## Test 7 — Fehlerbild „Exit 127“ beim echten Proxmox-Lauf

Ergebnis: **Fehler gefunden, behoben, mit Regressionstest abgesichert**

Erster echter Lauf auf Proxmox VE 9 (CT 106, Debian-13-Template) brach nach
dem Payload-Upload ab:

```text
bash: /opt/tastyigniter-proxmox/install/provision.sh: No such file or directory
[ERR ]  Installation failed. Exit-Code: 127
```

Ursache: Ein GitHub-`codeload`-Archiv entpackt immer in genau ein
Top-Level-Verzeichnis (`TastyIgniter-RestaurantSoftware-Proxmox-main/`). Der
lokale Pfad (`tar -C "$local_root" … .`) erzeugte dagegen einen Payload ohne
diese Ebene. Im Container lag `provision.sh` daher unter
`/opt/tastyigniter-proxmox/<REPO-BRANCH>/install/provision.sh`.

Behebung:

- Neue Funktion `payload_from_github_archive()` entpackt das Archiv,
  ermittelt das einzige Top-Level-Verzeichnis und packt den Payload neu, sodass
  `install/`, `config/`, `app/` direkt in der Wurzel liegen.
- Fehlt `install/provision.sh`, bricht der Installer mit einer erklärenden
  Meldung ab (statt Exit 127).
- Der Container-Befehl prüft den entpackten Payload zusätzlich und gibt bei
  Bedarf `ls -la /opt/tastyigniter-proxmox` aus.
- Regressionstest in `tests/local-checks.sh` („GitHub payload normalisation“):
  synthetisches GitHub-Archiv mit Top-Level-Verzeichnis, Prüfung auf
  `./install/provision.sh` in der Wurzel, Prüfung, dass das Top-Level-Verzeichnis
  entfernt wurde, und Prüfung, dass ein Archiv ohne `provision.sh` abgelehnt
  wird.

Zusätzlich gegen das echte Release-Archiv geprüft:

```bash
curl -fsSL https://codeload.github.com/HatchetMan111/TastyIgniter-RestaurantSoftware-Proxmox/tar.gz/refs/heads/main -o dl.tar.gz
# Archivwurzel: TastyIgniter-RestaurantSoftware-Proxmox-main/
# nach Normalisierung: ./install/provision.sh, ./app/dashboard/dist/index.html, ./README.md
```

Ergebnis: `normalize_rc=0`, Payload-Wurzel korrekt. `tests/local-checks.sh`
läuft danach mit 32/32 Checks durch.

---

## Nicht getestet

- `pct create` / `pct start` auf einem echten Proxmox-VE-Host
- Proxmox-Template-Download über `pveam`
- DHCP-/Bridge-Verhalten eines echten LXC
- Proxmox-Host-Firewall
- Debian-12-Fallback (bewusst nicht implementiert, da PHP 8.4 dort nicht
  ohne Zusatz-Repository verfügbar ist)

Für diese Punkte liegt `tests/proxmox-smoke-test.sh` bereit. Er prüft auf
einem echten Host Containerstatus, `onboot`, Services, HTTP-Endpunkte und
optional einen Neustart:

```bash
sudo ./tests/proxmox-smoke-test.sh --ctid 123 --reboot
```

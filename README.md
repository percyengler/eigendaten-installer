# Eigendaten Office Cloud Suite Installer

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange.svg)](https://ubuntu.com/)
[![Docker](https://img.shields.io/badge/Docker-Required-blue.svg)](https://docker.com/)
[![Version](https://img.shields.io/badge/Version-4.0-green.svg)]()

Eine vollstaendige, selbst-gehostete **Microsoft 365 Alternative** fuer kleine und mittlere Unternehmen.

Alle Daten bleiben auf deinem eigenen Server - volle DSGVO-Konformitaet, keine Abhaengigkeit von Cloud-Anbietern.

## Quick Start

### One-Line Installation (Interaktiv)

```bash
curl -sSL https://raw.githubusercontent.com/percyengler/eigendaten-installer/main/install.sh | sudo bash
```

### Installation mit Parametern (empfohlen)

```bash
curl -sSL https://raw.githubusercontent.com/percyengler/eigendaten-installer/main/install.sh | \
  sudo DOMAIN=demo-firma.de \
       SERVER_ROLE=app \
       ADMIN_EMAIL=admin@demo-firma.de \
       USERS="max:mustermann:m.mustermann@demo-firma.de,anna:schmidt:a.schmidt@demo-firma.de" \
       bash
```

### Vollautomatisch (keine Rueckfragen)

```bash
curl -sSL https://raw.githubusercontent.com/percyengler/eigendaten-installer/main/install.sh | \
  sudo DOMAIN=demo-firma.de \
       SERVER_ROLE=app \
       ADMIN_EMAIL=admin@demo-firma.de \
       USERS="max:mustermann:m.mustermann@demo-firma.de,anna:schmidt:a.schmidt@demo-firma.de" \
       AUTO_CONFIRM=true \
       bash
```

## Was wird installiert?

| Komponente | Funktion | Microsoft 365 Aequivalent |
|------------|----------|--------------------------|
| **Nextcloud** | Cloud-Speicher, Kalender, Kontakte | OneDrive, SharePoint, Outlook Kalender |
| **Paperless-NGX** | Dokumentenmanagement mit OCR | SharePoint Dokumentenbibliothek |
| **Mailcow** | E-Mail-Server mit Webmail | Exchange, Outlook |
| **Keycloak** | Single Sign-On (SSO) | Azure AD |
| **Vaultwarden** | Passwort-Manager | - |

## Architektur

```
                         Nginx Proxy Manager
                         (SSL/Let's Encrypt)
                                |
         +------------+---------+----------+------------+
         |            |                    |            |
    Nextcloud    Paperless-NGX        Keycloak    Vaultwarden
      :80          :8000               :8080        :80
         |            |                    |
         +------------+--------------------+
                       |
              +--------+--------+
              |                 |
          PostgreSQL         Redis
            :5432             :6379
```

### Zwei-Server-Setup (Empfohlen fuer Produktion)

```
+------------------------+     +------------------------+
|      APP-SERVER        |     |      MAIL-SERVER       |
|                        |     |                        |
|  - Nextcloud           |     |  - Mailcow             |
|  - Paperless-NGX       |---->|    - Postfix           |
|  - Keycloak            |     |    - Dovecot           |
|  - Vaultwarden         |     |    - SOGo              |
|  - Nginx Proxy Manager |     |    - ClamAV (optional) |
|  - PostgreSQL          |     |    - Rspamd            |
|  - Redis               |     |                        |
+------------------------+     +------------------------+
```

## Parameter

| Variable | Beschreibung | Erforderlich | Beispiel |
|----------|--------------|--------------|----------|
| `DOMAIN` | Hauptdomain | Ja | `demo-firma.de` |
| `SERVER_ROLE` | Server-Rolle | Ja | `app`, `mail`, `full` |
| `ADMIN_EMAIL` | Admin E-Mail | Ja | `admin@demo-firma.de` |
| `USERS` | Benutzer (komma-separiert) | Optional | siehe unten |
| `AUTO_CONFIRM` | Keine Abfragen | Optional | `true` |

### Benutzer-Format

```
USERS="vorname:nachname:email,vorname:nachname:email"
```

Beispiel:
```
USERS="max:mustermann:m.mustermann@demo-firma.de,anna:schmidt:a.schmidt@demo-firma.de"
```

Passwoerter werden automatisch generiert und in `/opt/eigendaten/user-credentials.txt` gespeichert.

## Voraussetzungen

### Hardware (Minimum)

| Server | CPU | RAM | Disk |
|--------|-----|-----|------|
| App-Server | 2 vCPU | 4 GB | 40 GB |
| Mail-Server | 2 vCPU | 4 GB | 40 GB |

### Software

- Ubuntu 24.04 LTS (oder Debian 12)
- Root-Zugriff
- Oeffentliche IP-Adresse
- DNS-Zugriff fuer die Domain

## DNS-Eintraege

**Vor der Installation** diese A-Records beim DNS-Provider erstellen:

```
cloud.demo-firma.de    ->  APP_SERVER_IP
docs.demo-firma.de     ->  APP_SERVER_IP
sso.demo-firma.de      ->  APP_SERVER_IP
vault.demo-firma.de    ->  APP_SERVER_IP
mail.demo-firma.de     ->  MAIL_SERVER_IP   (nur bei mail/full)
```

Der Installer prueft die DNS-Eintraege automatisch mit `dig` und wartet bei Bedarf auf korrekte Aufloesung.

Eine ausfuehrliche Schritt-fuer-Schritt Anleitung findest du in [docs/SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

## Script-Uebersicht

| Script | Funktion |
|--------|----------|
| `install.sh` | Master-Installer (curl \| bash) |
| `00-base-setup.sh` | System-Grundkonfiguration, Docker, Firewall |
| `01-app-server.sh` | Nextcloud, Paperless, Keycloak, Vaultwarden |
| `02-mail-server.sh` | Mailcow E-Mail-Server |
| `04-sso-setup.sh` | Keycloak SSO-Integration |
| `05-post-install.sh` | Nacharbeiten, Optimierungen |

## Manuelle Installation

Falls du die Scripts einzeln ausfuehren moechtest:

```bash
# Repository klonen
git clone https://github.com/percyengler/eigendaten-installer.git
cd eigendaten-installer

# Config-Datei erstellen
cp config.env.example config.env
nano config.env  # Anpassen

# Scripts ausfuehren
sudo ./00-base-setup.sh
sudo ./01-app-server.sh
sudo ./05-post-install.sh
sudo ./04-sso-setup.sh    # Optional: SSO einrichten
```

## Kostenvergleich mit Microsoft 365

| | Eigendaten (Self-Hosted) | Microsoft 365 Business Basic |
|--|-------------------------|------------------------------|
| **5 Benutzer** | ~15-20 EUR/Monat | ~30 EUR/Monat |
| **10 Benutzer** | ~15-20 EUR/Monat | ~60 EUR/Monat |
| **25 Benutzer** | ~20-30 EUR/Monat* | ~150 EUR/Monat |
| **Speicher** | Erweiterbar | 1 TB/Benutzer |
| **Datenstandort** | Dein Server | Weltweit (Microsoft) |
| **DSGVO** | Volle Kontrolle | US CLOUD Act |

*Mit groesserem Server

## Sicherheit

- UFW Firewall konfiguriert
- Fail2Ban gegen Brute-Force
- SSH Key-Only Authentication
- Automatische Sicherheitsupdates
- Let's Encrypt SSL-Zertifikate
- Alle Passwoerter automatisch generiert (keine Defaults)

## SSO-Status

| Dienst | SSO-Methode | Status |
|--------|-------------|--------|
| Nextcloud | user_oidc | Funktioniert |
| Paperless-NGX | allauth | Funktioniert |
| Mailcow | DB-Config | Funktioniert |
| Vaultwarden | OIDC | Funktioniert* |

*Vaultwarden: SSO-Button erscheint nicht automatisch. Benutzer muss `/#/sso` manuell aufrufen.

## Bekannte Probleme & Loesungen

### Nextcloud "trusted_proxies Warnung"

**Ursache:** ENV-Variablen ueberschreiben config.php nicht

**Loesung:**
```bash
docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 0 --value="172.16.0.0/12"
```

Das Post-Install Script (`05-post-install.sh`) behebt dies automatisch.

### Mailcow Passwort-Richtlinien

Passwoerter fuer Mailcow-Mailboxen duerfen KEINE dieser Zeichen enthalten:
- `!` (Ausrufezeichen) - fuehrt zu URL-Encoding-Problemen
- Umlaute (ae, oe, ue, ss)
- Leerzeichen

## Support & Beitragen

Issues und Pull Requests sind willkommen!

## Lizenz

MIT License - siehe [LICENSE](LICENSE)

---

**Eigendaten Office Cloud Suite** - Deine Daten, dein Server, deine Kontrolle.

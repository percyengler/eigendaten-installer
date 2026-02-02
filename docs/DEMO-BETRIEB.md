# Eigendaten - Demo-Betrieb Anleitung

## Uebersicht

Das Demo-System zeigt die Eigendaten Office Cloud Suite mit allen 5 Diensten:

| Dienst | URL | Funktion |
|--------|-----|----------|
| Nextcloud | https://cloud.DOMAIN | Dateien, Kalender, Kontakte |
| Keycloak | https://sso.DOMAIN | Single Sign-On, Profilverwaltung |
| Vaultwarden | https://vault.DOMAIN | Passwort-Manager |
| Mailcow | https://mail.DOMAIN | E-Mail (Webmail + IMAP/SMTP) |
| Paperless-NGX | https://paperless.DOMAIN | Dokumentenverwaltung |

## Server-Architektur

```
ED-001 (App-Server)     ED-002 (Mail-Server)     ED-003 (Paperless)
- Nextcloud             - Mailcow (20 Container) - Paperless-NGX
- Keycloak              - Dovecot/Postfix        - PostgreSQL
- Vaultwarden           - SOGo Webmail           - Redis
- NPM (Reverse Proxy)   - Rspamd
- MariaDB, PostgreSQL
- Redis
```

## Demo-Benutzer

5 Demo-Benutzer mit vordefinierten Rollen:

| Username | Name | E-Mail | Abteilung | Position |
|----------|------|--------|-----------|----------|
| gf-leiter | Max Leiter | gf@DOMAIN | Geschaeftsfuehrung | Geschaeftsfuehrer |
| buchhaltung | Claudia Konto | buchhaltung@DOMAIN | Buchhaltung | Buchhalterin |
| hr-personal | Anna Personal | hr@DOMAIN | Personal | HR-Managerin |
| technik | Peter Monteur | technik@DOMAIN | Technik | Techniker |
| azubi | Lena Lehrling | azubi@DOMAIN | Technik | Auszubildende |

Alle Benutzer haben das gleiche Universal-Passwort (wird beim Reset generiert).

## Demo-Reset durchfuehren

### Voraussetzungen

- Root-Zugriff auf App-Server
- SSH-Key fuer Mail-Server und Paperless-Server unter `/root/.ssh/eigendaten-key`
- Alle Docker-Container laufen

### Reset ausfuehren

```bash
# Interaktiv (mit Bestaetigung)
sudo /opt/demo-reset/demo-reset.sh

# Automatisch (ohne Bestaetigung)
sudo /opt/demo-reset/demo-reset.sh --yes
```

### Was passiert beim Reset

1. Neues Universal-Passwort im Format `Eigendaten@XXXX` wird generiert
2. Keycloak: Passwoerter aller 5 Demo-User werden zurueckgesetzt
3. Nextcloud: Alle Benutzerdateien, Papierkorb und Versionen werden geloescht
4. Mailcow: Alle E-Mails werden geloescht, Postfach-Passwoerter gesetzt
5. Mailcow: `authsource='mailcow'` fuer alle Postfaecher setzen + Dovecot Auth-Cache flush
6. Paperless: Alle Dokumente werden geloescht, Admin-Passwort wird gesetzt
7. Vaultwarden: Alle Benutzer-Vaults werden geloescht
8. HTML- und Markdown-Zugangskarten werden generiert
9. Automatische Verifikation aller Dienste (Keycloak SSO, IMAP, HTTP)
10. Benachrichtigung per E-Mail + Upload nach Nextcloud

### Was NICHT zurueckgesetzt wird

- Admin-Accounts (Keycloak, Nextcloud, Mailcow)
- SSO-Konfiguration (Clients, Profilfelder, OIDC-Mapper)
- Docker-Container/Images
- SSL-Zertifikate
- DNS-Einstellungen
- Firewall-/Fail2Ban-Regeln

### Dateien

| Pfad | Beschreibung |
|------|-------------|
| `/opt/demo-reset/demo-reset.sh` | Haupt-Script |
| `/opt/demo-reset/zugangskarten-template.html` | HTML-Template |
| `/opt/demo-reset/zugangskarten-YYYY-MM-DD.html` | Generierte Zugangskarten (HTML) |
| `/opt/demo-reset/zugangskarten-YYYY-MM-DD.md` | Generierte Zugangskarten (Markdown) |
| `/opt/demo-reset/verify-YYYY-MM-DD.log` | Verifikationsprotokoll |
| `/opt/demo-reset/reset-log.txt` | Protokoll aller Resets |

## Zugangskarten

Nach jedem Reset wird eine HTML-Datei mit Zugangskarten generiert:

- **Format:** A4, eine Karte pro Benutzer (druckoptimiert)
- **Formate:** HTML (druckbar) und Markdown (lesbar in Nextcloud/GitHub)
- **Inhalt:** Benutzername, Passwort, alle URLs, E-Mail-Konfiguration (IMAP/SMTP)
- **Ablauf:** 7 Tage ab Erstellung

## Deployment

```bash
# Auf dem App-Server:
mkdir -p /opt/demo-reset

# Script und Template kopieren
cp scripts/demo-reset.sh /opt/demo-reset/
cp templates/zugangskarten-template.html /opt/demo-reset/

# Konfiguration anpassen
nano /opt/demo-reset/demo-reset.sh  # IPs, Domain, Benutzer anpassen

# Ausfuehrbar machen
chmod +x /opt/demo-reset/demo-reset.sh
```

## Konfiguration

Vor dem ersten Einsatz muessen folgende Variablen in `demo-reset.sh` angepasst werden:

| Variable | Beschreibung | Beispiel |
|----------|-------------|---------|
| `APP_SERVER_IP` | IP des App-Servers | `1.2.3.4` |
| `MAIL_SERVER_IP` | IP des Mail-Servers | `5.6.7.8` |
| `PAPERLESS_SERVER_IP` | IP des Paperless-Servers | `9.10.11.12` |
| `DOMAIN` | Haupt-Domain | `eigendaten.de` |
| `KC_REALM` | Keycloak Realm | `eigendaten` |
| `KC_ADMIN` | Keycloak Admin-User | `admin-permanent` |
| `KC_ADMIN_PASS` | Keycloak Admin-Passwort | (aus ENV oder Script) |
| `DEMO_USERS` | Benutzer-Array | Siehe Script |
| `MAIL_USERS` | Postfach-Array | Siehe Script |
| `NOTIFY_EMAIL` | Empfaenger fuer Reset-Benachrichtigung | `admin@example.de` |
| `NC_ADMIN_USER` | Nextcloud Admin-User fuer Upload | `admin` |
| `NC_UPLOAD_DIR` | Nextcloud-Verzeichnis fuer Upload | `Demo-Reset` |
| `KC_CLIENT_ID` | Keycloak Client-ID fuer Verifikation | `nextcloud` |

Alternativ koennen die Variablen ueber Environment-Variablen gesetzt werden.

## Automatische Verifikation (Schritt 9)

Nach dem Reset werden automatisch alle Dienste getestet:

| # | Test | Methode |
|---|------|---------|
| 1 | Keycloak SSO (5 User) | OAuth2 Password Grant an `sso.DOMAIN/realms/REALM/protocol/openid-connect/token` |
| 2 | Mailcow IMAP (6 User) | Dovecot Auth-API via `nginx:9082` auf Mail-Server |
| 3 | Nextcloud erreichbar | HTTP `cloud.DOMAIN/status.php` |
| 4 | Vaultwarden erreichbar | HTTP `vault.DOMAIN/alive` |
| 5 | Webmail erreichbar | HTTP `mail.DOMAIN` |
| 6 | Paperless erreichbar | HTTP `paperless.DOMAIN` |

Das Ergebnis wird in `/opt/demo-reset/verify-YYYY-MM-DD.log` gespeichert.

Der Keycloak `client_secret` wird zur Laufzeit automatisch aus der Keycloak Admin-CLI gelesen (kein Hardcoding).

## Benachrichtigung (Schritt 10)

Nach der Verifikation werden die Ergebnisse automatisch verteilt:

### E-Mail-Benachrichtigung

- **Absender:** noreply@DOMAIN (existierende Mailbox, Passwort wird beim Reset mitgesetzt)
- **Empfaenger:** Konfigurierbar (`NOTIFY_EMAIL`)
- **Inhalt:** Verifikationslog + Zugangskarten-Info
- **Methode:** curl SMTP (smtps://mail.DOMAIN:465)

### Nextcloud-Upload

- Zugangskarten (HTML + Markdown) und Verifikationslog werden nach Nextcloud hochgeladen
- **Pfad:** `/admin/files/Demo-Reset/`
- **Methode:** `docker cp` + `occ files:scan` (kein Passwort noetig, lokaler Docker-Zugriff)

## Bekannte Probleme & Loesungen

### SOGo Webmail: Kein direkter Login (seit Mailcow 2025-03)

**Problem:** Der direkte Login ueber `mail.DOMAIN/SOGo` funktioniert nicht (403 Forbidden, LDAPPasswordPolicyError).

**Ursache:** Seit dem Mailcow 2025-03 Update ist der direkte SOGo-Login deaktiviert. Alle unauthentifizierten Zugriffe auf `/SOGo` werden auf `/` umgeleitet. SOGo authentifiziert ueber Proxy-Headers (`SOGoTrustProxyAuthentication=YES`), nicht mehr ueber SQL-Passwoerter.

**Loesung:** Benutzer muessen sich ueber die Mailcow-UI anmelden: `https://mail.DOMAIN/`. Nach dem Login werden sie automatisch zu SOGo weitergeleitet.

### Fehlende Postfaecher fuer Demo-User

**Problem:** Nicht alle Keycloak-Benutzer haben automatisch ein Mailcow-Postfach.

**Loesung:** Das Reset-Script prueft jetzt beim Reset, ob alle Demo-User Postfaecher haben und erstellt fehlende automatisch ueber die Mailcow-API.

### authsource-Bug (Mailcow/Keycloak)

**Problem:** Nach dem Passwort-Reset schlaegt die IMAP/SMTP-Authentifizierung fehl, obwohl das Passwort in Mailcow korrekt gesetzt wurde.

**Ursache:** Die Authentifizierungskette in Mailcow lautet:
```
Dovecot → Lua-Script → nginx:9082 → PHP mailcowauth.php → user_login()
→ authsource-Switch:
  - 'mailcow': Passwort direkt pruefen → OK
  - 'keycloak': REST-Call an Keycloak + mailpassword_flow pruefen
    → mailpassword_flow=0 → return false (Auth schlaegt IMMER fehl!)
```

**Loesung:** Das Reset-Script setzt automatisch `authsource='mailcow'` fuer alle Demo-Postfaecher nach dem Passwort-Reset und leert den Dovecot Auth-Cache.

## Troubleshooting

### Keycloak-Login fehlgeschlagen
- Admin-Passwort pruefen
- Container laeuft? `docker ps | grep keycloak`

### SSH zu Remote-Servern fehlgeschlagen
- SSH-Key vorhanden? `ls -la /root/.ssh/eigendaten-key`
- Verbindung testen: `ssh -v -i /root/.ssh/eigendaten-key root@MAIL_SERVER_IP`

### Mailcow API-Key nicht gefunden
- Pruefen: `grep API_KEY /opt/mailcow-dockerized/mailcow.conf`
- Passwoerter manuell in Mailcow Admin-UI setzen

### Vaultwarden: sqlite3 nicht verfuegbar
- Pruefen: `docker exec vaultwarden which sqlite3`
- Falls nicht vorhanden: Vaultwarden-Image aktualisieren oder DB-Datei manuell loeschen

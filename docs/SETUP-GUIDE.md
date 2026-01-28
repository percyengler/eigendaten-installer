# Eigendaten - DNS & Server Setup Guide

Schritt-fuer-Schritt Anleitung zur Einrichtung der DNS-Eintraege und Server-Vorbereitung.

## 1. Server bestellen

Du benoetigst mindestens einen Server mit:
- **Betriebssystem:** Ubuntu 24.04 LTS
- **CPU:** mindestens 2 vCPU
- **RAM:** mindestens 4 GB
- **Speicher:** mindestens 40 GB SSD

### Zwei-Server-Setup (empfohlen)

Fuer Produktion empfehlen wir zwei getrennte Server:

| Server | Rolle | Minimum |
|--------|-------|---------|
| App-Server | Nextcloud, Paperless, Keycloak, Vaultwarden | 2 vCPU, 4 GB RAM |
| Mail-Server | Mailcow (E-Mail) | 2 vCPU, 4 GB RAM |

### Ein-Server-Setup (fuer Tests)

Fuer Tests oder sehr kleine Teams (1-3 Personen) reicht ein Server mit `SERVER_ROLE=full` und mindestens 8 GB RAM.

## 2. Domain vorbereiten

Du benoetigst eine eigene Domain (z.B. `demo-firma.de`). Die Domain muss bei einem DNS-Provider verwaltet werden, bei dem du A-Records erstellen kannst.

## 3. DNS-Eintraege erstellen

### App-Server DNS-Eintraege

Erstelle folgende **A-Records** bei deinem DNS-Provider:

| Typ | Name | Ziel | TTL |
|-----|------|------|-----|
| A | `cloud` | `APP_SERVER_IP` | 300 |
| A | `docs` | `APP_SERVER_IP` | 300 |
| A | `sso` | `APP_SERVER_IP` | 300 |
| A | `vault` | `APP_SERVER_IP` | 300 |

Ersetze `APP_SERVER_IP` mit der oeffentlichen IP-Adresse deines App-Servers.

### Mail-Server DNS-Eintraege

| Typ | Name | Ziel | TTL |
|-----|------|------|-----|
| A | `mail` | `MAIL_SERVER_IP` | 300 |
| MX | `@` | `10 mail.demo-firma.de` | 300 |
| TXT | `@` | `v=spf1 mx a -all` | 300 |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:postmaster@demo-firma.de` | 300 |
| CNAME | `autodiscover` | `mail.demo-firma.de` | 300 |
| CNAME | `autoconfig` | `mail.demo-firma.de` | 300 |

### DNS-Eintraege pruefen

Nach dem Erstellen der DNS-Eintraege kannst du die Aufloesung pruefen:

```bash
# A-Records pruefen
dig cloud.demo-firma.de A +short
dig docs.demo-firma.de A +short
dig sso.demo-firma.de A +short
dig vault.demo-firma.de A +short

# MX-Record pruefen
dig demo-firma.de MX +short
```

**Wichtig:** DNS-Aenderungen koennen bis zu 24 Stunden dauern, bei den meisten Providern aber nur wenige Minuten.

## 4. Reverse DNS (PTR) setzen

Fuer den Mail-Server ist ein Reverse DNS Eintrag wichtig, damit E-Mails nicht als Spam markiert werden:

- Setze den PTR-Record der Mail-Server IP auf `mail.demo-firma.de`
- Das geht normalerweise im Control Panel deines Hosting-Providers unter "Networking" oder "Reverse DNS"

## 5. Installation starten

### Per SSH auf dem Server einloggen

```bash
ssh root@APP_SERVER_IP
```

### Installer ausfuehren

```bash
curl -sSL https://raw.githubusercontent.com/percyengler/eigendaten-installer/main/install.sh | \
  sudo DOMAIN=demo-firma.de \
       SERVER_ROLE=app \
       ADMIN_EMAIL=admin@demo-firma.de \
       USERS="max:mustermann:m.mustermann@demo-firma.de,anna:schmidt:a.schmidt@demo-firma.de" \
       bash
```

Der Installer wird:
1. Systemvoraussetzungen pruefen
2. Konfiguration abfragen (oder aus ENV uebernehmen)
3. DNS-Eintraege mit `dig` verifizieren
4. Alle Dienste installieren und konfigurieren
5. Zugangsdaten generieren und anzeigen

### Mail-Server installieren (separater Server)

```bash
ssh root@MAIL_SERVER_IP

curl -sSL https://raw.githubusercontent.com/percyengler/eigendaten-installer/main/install.sh | \
  sudo DOMAIN=demo-firma.de \
       SERVER_ROLE=mail \
       ADMIN_EMAIL=admin@demo-firma.de \
       bash
```

## 6. Nach der Installation

### SSL-Zertifikate einrichten

1. Oeffne den Nginx Proxy Manager: `http://APP_SERVER_IP:81`
2. Logge dich mit den generierten Zugangsdaten ein (siehe `/opt/eigendaten/ZUGANGSDATEN.txt`)
3. Fuer jeden Proxy Host:
   - Edit -> SSL Tab
   - "Request a new SSL Certificate" (Let's Encrypt)
   - "Force SSL" aktivieren
   - "HTTP/2 Support" aktivieren

### SSO einrichten (optional)

```bash
cd /opt/eigendaten && sudo ./04-sso-setup.sh
```

### Zugangsdaten abrufen

```bash
# Dienst-Zugangsdaten
cat /opt/eigendaten/ZUGANGSDATEN.txt

# Benutzer-Passwoerter
cat /opt/eigendaten/user-credentials.txt
```

### NPM Admin-Port absichern

```bash
# Port 81 nur fuer deine IP freigeben
sudo ufw delete allow 81/tcp
sudo ufw allow from DEINE_IP to any port 81
```

## 7. Wartung

### Docker-Container pruefen

```bash
cd /opt/eigendaten && docker compose ps
```

### Logs anzeigen

```bash
cd /opt/eigendaten && docker compose logs -f nextcloud
```

### Update

```bash
cd /opt/eigendaten && docker compose pull && docker compose up -d
```

## Haeufige Probleme

### DNS-Eintraege werden nicht aufgeloest

- Warte 5-30 Minuten nach dem Erstellen
- Pruefe mit `dig domain.de A +short`
- Stelle sicher, dass die richtige IP eingetragen ist

### SSL-Zertifikat kann nicht ausgestellt werden

- DNS muss korrekt auf den Server zeigen
- Port 80 und 443 muessen offen sein (UFW)
- Let's Encrypt Rate Limits beachten (max 5 Versuche pro Stunde)

### Nextcloud zeigt "Access through untrusted domain"

```bash
docker exec -u www-data nextcloud php occ config:system:set trusted_domains 0 --value="cloud.demo-firma.de"
```

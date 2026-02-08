#!/bin/bash
#===============================================================================
# Eigendaten - Mail Server Setup v4.0
# 
# Installiert Mailcow-dockerized mit:
# - Automatischer Konfiguration
# - Ressourcen-Optimierung für kleine Server
# - DNS-Record Generator
#
# Voraussetzung: 00-base-setup.sh wurde ausgeführt
#
# Version: 4.0
#===============================================================================

set -euo pipefail

#===============================================================================
# Farben & Hilfsfunktionen
#===============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }

banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║          EIGENDATEN - Mail Server Setup v4.0                      ║"
    echo "║                    Mailcow-dockerized                             ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

#===============================================================================
# Prüfungen
#===============================================================================
banner

# Root-Check
if [ "$EUID" -ne 0 ]; then
    error "Bitte als root ausführen: sudo $0"
fi

# Docker prüfen
if ! command -v docker &> /dev/null; then
    error "Docker nicht installiert! Bitte zuerst 00-base-setup.sh ausführen."
fi

# jq prüfen (wird von generate_config.sh benötigt!)
if ! command -v jq &> /dev/null; then
    warn "jq nicht installiert - wird jetzt installiert..."
    apt-get update && apt-get install -y jq
    log "jq installiert"
fi

#===============================================================================
# Konfiguration abfragen
#===============================================================================
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

echo -e "${YELLOW}=== Mailcow-Konfiguration ===${NC}\n"

# Mail-Hostname: aus ENV, aus DOMAIN ableiten, oder interaktiv
if [[ -n "${MAILCOW_HOSTNAME:-}" ]]; then
    info "Mail-Hostname: $MAILCOW_HOSTNAME (aus ENV)"
elif [[ -n "${MAIL_DOMAIN:-}" ]]; then
    MAILCOW_HOSTNAME="$MAIL_DOMAIN"
    info "Mail-Hostname: $MAILCOW_HOSTNAME (aus MAIL_DOMAIN)"
elif [[ -n "${DOMAIN:-}" ]]; then
    MAILCOW_HOSTNAME="mail.${DOMAIN}"
    info "Mail-Hostname: $MAILCOW_HOSTNAME (aus DOMAIN)"
elif [[ "$AUTO_CONFIRM" == "true" ]]; then
    error "MAILCOW_HOSTNAME oder DOMAIN muss bei AUTO_CONFIRM gesetzt sein!"
else
    read -p "Mail-Hostname FQDN (z.B. mail.example.com): " MAILCOW_HOSTNAME
    [ -z "$MAILCOW_HOSTNAME" ] && error "Hostname darf nicht leer sein!"
fi

# Domain extrahieren (nur wenn nicht bereits aus ENV gesetzt)
MAIL_DOMAIN="${MAIL_DOMAIN:-$(echo "$MAILCOW_HOSTNAME" | cut -d. -f2-)}"

# RAM prüfen für Ressourcen-Empfehlung
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo ""
echo "Verfügbarer RAM: ${RAM_MB} MB"
echo ""

if [ "$RAM_MB" -lt 4000 ]; then
    warn "Weniger als 4GB RAM - eingeschränkte Konfiguration empfohlen!"
    SKIP_SOLR="${SKIP_SOLR:-y}"
    SKIP_CLAMD="${SKIP_CLAMD:-n}"
    info "Empfehlung: Solr deaktivieren (spart ~1GB RAM, keine Volltextsuche)"
elif [ "$RAM_MB" -lt 6000 ]; then
    SKIP_SOLR="${SKIP_SOLR:-y}"
    SKIP_CLAMD="${SKIP_CLAMD:-n}"
    info "Empfehlung: Solr deaktivieren für bessere Performance"
else
    SKIP_SOLR="${SKIP_SOLR:-n}"
    SKIP_CLAMD="${SKIP_CLAMD:-n}"
    info "Genügend RAM für vollständige Installation"
fi

if [[ "$AUTO_CONFIRM" != "true" ]]; then
    read -p "Solr (Volltextsuche) deaktivieren? [${SKIP_SOLR}]: " USER_SKIP_SOLR
    SKIP_SOLR=${USER_SKIP_SOLR:-$SKIP_SOLR}

    read -p "ClamAV (Virenscan) deaktivieren? [${SKIP_CLAMD}]: " USER_SKIP_CLAMD
    SKIP_CLAMD=${USER_SKIP_CLAMD:-$SKIP_CLAMD}
fi

echo ""
echo -e "${BLUE}Konfiguration:${NC}"
echo "  Hostname:    ${MAILCOW_HOSTNAME}"
echo "  Domain:      ${MAIL_DOMAIN}"
echo "  Solr:        $([ "$SKIP_SOLR" = "y" ] && echo "Deaktiviert" || echo "Aktiviert")"
echo "  ClamAV:      $([ "$SKIP_CLAMD" = "y" ] && echo "Deaktiviert" || echo "Aktiviert")"
echo ""

if [[ "$AUTO_CONFIRM" != "true" ]]; then
    read -p "Fortfahren? (j/n): " CONFIRM
    [ "$CONFIRM" != "j" ] && [ "$CONFIRM" != "J" ] && { echo "Abgebrochen."; exit 0; }
else
    info "AUTO_CONFIRM aktiv - starte automatisch..."
fi

#===============================================================================
# Mailcow klonen
#===============================================================================
log "Mailcow wird heruntergeladen..."

cd /opt

if [ -d "mailcow-dockerized" ]; then
    warn "mailcow-dockerized existiert bereits"
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        info "AUTO_CONFIRM aktiv - vorhandene Installation wird verwendet"
    else
        read -p "Löschen und neu klonen? (j/n): " RECLONE
        if [ "$RECLONE" = "j" ]; then
            rm -rf mailcow-dockerized
            git clone https://github.com/mailcow/mailcow-dockerized
        fi
    fi
else
    git clone https://github.com/mailcow/mailcow-dockerized
fi

cd mailcow-dockerized

log "Mailcow geklont nach /opt/mailcow-dockerized"

#===============================================================================
# Konfiguration generieren
#===============================================================================
log "Konfiguration wird generiert..."

# generate_config.sh automatisch beantworten
echo -e "${MAILCOW_HOSTNAME}\nEurope/Berlin" | ./generate_config.sh

log "Basiskonfiguration generiert"

#===============================================================================
# mailcow.conf anpassen
#===============================================================================
log "mailcow.conf wird angepasst..."

# Solr-Einstellung
if [ "$SKIP_SOLR" = "y" ]; then
    sed -i 's/^SKIP_SOLR=.*/SKIP_SOLR=y/' mailcow.conf
    log "Solr deaktiviert (spart ~1GB RAM)"
fi

# ClamAV-Einstellung
if [ "$SKIP_CLAMD" = "y" ]; then
    sed -i 's/^SKIP_CLAMD=.*/SKIP_CLAMD=y/' mailcow.conf
    warn "ClamAV deaktiviert - kein Virenscan!"
fi

# Weitere Optimierungen
# Watchdog-Mails deaktivieren (optional)
# sed -i 's/^WATCHDOG_NOTIFY_EMAIL=.*/WATCHDOG_NOTIFY_EMAIL=/' mailcow.conf

log "mailcow.conf angepasst"

#===============================================================================
# Images herunterladen und starten
#===============================================================================
log "Docker-Images werden heruntergeladen (kann 5-10 Minuten dauern)..."

docker compose pull

log "Mailcow wird gestartet..."
docker compose up -d

echo ""
log "Warte auf Container-Start (60 Sekunden)..."
sleep 60

#===============================================================================
# Status prüfen
#===============================================================================
echo ""
echo -e "${BLUE}Container-Status:${NC}"
docker compose ps --format "table {{.Name}}\t{{.Status}}" | head -20

#===============================================================================
# DNS-Records generieren
#===============================================================================
log "DNS-Records werden generiert..."

SERVER_IP=$(hostname -I | awk '{print $1}')

cat > /opt/mailcow-dockerized/DNS-RECORDS.txt << EOF
============================================
DNS-RECORDS für ${MAIL_DOMAIN}
Server-IP: ${SERVER_IP}
============================================

PFLICHT-EINTRÄGE:
-----------------

# A-Record für Mail-Server
mail    A       ${SERVER_IP}

# MX-Record
@       MX      10 ${MAILCOW_HOSTNAME}.

# SPF-Record
@       TXT     "v=spf1 mx a -all"

# DMARC-Record
_dmarc  TXT     "v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}"

# Autodiscover (für Outlook)
autodiscover    CNAME   ${MAILCOW_HOSTNAME}.

# Autoconfig (für Thunderbird)
autoconfig      CNAME   ${MAILCOW_HOSTNAME}.


NACH MAILCOW-START:
-------------------
# DKIM-Record (aus Mailcow Admin → Configuration → ARC/DKIM Keys)
dkim._domainkey TXT     "v=DKIM1;k=rsa;t=s;s=email;p=HIER_KOMMT_DER_SCHLÜSSEL"


OPTIONAL - IPv6:
----------------
# mail    AAAA    IPv6-ADRESSE


REVERSE DNS (PTR):
------------------
Beim Hosting-Provider:
Reverse DNS beim Hosting-Provider setzen: ${MAILCOW_HOSTNAME}


PRÜFTOOLS:
----------
- MX Toolbox: https://mxtoolbox.com/
- Mail-Tester: https://mail-tester.com/
- Blacklist Check: https://mxtoolbox.com/blacklists.aspx

============================================
EOF

log "DNS-Records in DNS-RECORDS.txt gespeichert"

#===============================================================================
# Admin-Info
#===============================================================================
cat > /opt/mailcow-dockerized/ADMIN-INFO.txt << EOF
============================================
MAILCOW ADMIN-INFO
============================================

Web-UI: https://${MAILCOW_HOSTNAME}
Login:  admin / moohoo

→ PASSWORT SOFORT ÄNDERN!

Nach dem Login:
1. E-Mail → Configuration → Domains → Domain hinzufügen
2. ARC/DKIM Keys → DKIM generieren → DNS-Record setzen
3. E-Mail → Configuration → Mailboxes → Mailboxen anlegen

Befehle:
--------
# Status
cd /opt/mailcow-dockerized && docker compose ps

# Logs
docker compose logs -f postfix-mailcow

# Neustart
docker compose restart

# Update
./update.sh

Ressourcen:
-----------
Solr:   $([ "$SKIP_SOLR" = "y" ] && echo "Deaktiviert" || echo "Aktiviert")
ClamAV: $([ "$SKIP_CLAMD" = "y" ] && echo "Deaktiviert" || echo "Aktiviert")

============================================
EOF

log "Admin-Info in ADMIN-INFO.txt gespeichert"

#===============================================================================
# Zusammenfassung
#===============================================================================
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║             Mailcow-Installation abgeschlossen!                    ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Mailcow läuft:${NC}"
echo "  URL:      https://${MAILCOW_HOSTNAME}"
echo "  Login:    admin / moohoo"
echo ""
echo -e "${YELLOW}SOFORT ERLEDIGEN:${NC}"
echo ""
echo "  1. Admin-Passwort ändern!"
echo "     https://${MAILCOW_HOSTNAME} → Login → Passwort ändern"
echo ""
echo "  2. DNS-Records setzen:"
echo "     cat /opt/mailcow-dockerized/DNS-RECORDS.txt"
echo ""
echo "  3. Reverse DNS beim Hosting-Provider setzen:"
echo "     Reverse DNS beim Hosting-Provider setzen"
echo "     → ${MAILCOW_HOSTNAME}"
echo ""
echo "  4. Domain in Mailcow hinzufügen:"
echo "     E-Mail → Configuration → Domains → Add domain"
echo ""
echo "  5. DKIM-Key generieren und DNS-Record setzen:"
echo "     ARC/DKIM Keys → Select domain → Generate"
echo ""
echo "  6. Mailboxen anlegen"
echo ""
echo -e "${YELLOW}WICHTIG:${NC}"
echo "  - DNS-Propagation kann 24-48h dauern"
echo "  - Mail-Test: https://mail-tester.com/"
echo "  - Blacklist-Check: https://mxtoolbox.com/blacklists.aspx"
echo ""
echo -e "${RED}PASSWORT-RICHTLINIEN (KRITISCH!):${NC}"
echo ""
echo "  Passworter OHNE diese Zeichen verwenden:"
echo "    - ! (Ausrufezeichen) -> URL-Encoding-Probleme"
echo "    - Umlaute (ae, oe, ue, ss)"
echo "    - Leerzeichen"
echo ""
echo "  Sichere Zeichen: a-z A-Z 0-9 @ # \$ % & *"
echo "  Beispiel: MeinPasswort@2026 (NICHT: MeinPasswort2026!)"
echo ""
echo -e "${BLUE}MAILBOX-ERSTELLUNG VIA API:${NC}"
echo ""
echo "  1. API-Key erstellen in Mailcow UI:"
echo "     System -> Configuration -> API -> Add API Key"
echo ""
echo "  2. Mailbox erstellen:"
echo "     curl -X POST 'https://${MAILCOW_HOSTNAME}/api/v1/add/mailbox' \\"
echo "       -H 'X-API-Key: YOUR_API_KEY' \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{"
echo "         \"local_part\": \"benutzer\","
echo "         \"domain\": \"${MAIL_DOMAIN}\","
echo "         \"name\": \"Vorname Nachname\","
echo "         \"password\": \"SicheresPasswort@2026\","
echo "         \"password2\": \"SicheresPasswort@2026\","
echo "         \"quota\": \"3072\","
echo "         \"active\": \"1\""
echo "       }'"
echo ""

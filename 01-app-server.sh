#!/bin/bash
#===============================================================================
# Eigendaten - App Server Setup v4.0
# 
# Installiert auf einem vorbereiteten Server:
# - Nginx Proxy Manager
# - Nextcloud (mit korrekten trusted_proxies!)
# - Paperless-NGX (mit OIDC-Vorbereitung)
# - Vaultwarden
# - Keycloak (mit PostgreSQL, nicht H2!)
# - Redis & PostgreSQL
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
    echo "║          EIGENDATEN - App Server Setup v4.0                       ║"
    echo "║     Nextcloud + Paperless + Keycloak + Vaultwarden               ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

generate_password() {
    # Nur sichere Zeichen, keine Umlaute, keine problematischen Sonderzeichen
    openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20
}

#===============================================================================
# Prüfungen
#===============================================================================
banner

# Docker prüfen
if ! command -v docker &> /dev/null; then
    error "Docker nicht installiert! Bitte zuerst 00-base-setup.sh ausführen."
fi

# Nicht als root ausführen (wegen Docker-Gruppen-Zugehörigkeit)
# Bei AUTO_CONFIRM automatisch fortfahren
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

if [ "$EUID" -eq 0 ]; then
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        warn "Als root ausgeführt - sollte eigentlich deploy-User sein, fahre aber fort..."
    else
        warn "Bitte als deploy-User ausführen, nicht als root!"
        warn "Falls nötig: sudo -u deploy $0"
        read -p "Trotzdem fortfahren? (j/n): " CONTINUE
        [ "$CONTINUE" != "j" ] && exit 1
    fi
fi

#===============================================================================
# Konfiguration (aus ENV oder interaktiv)
#===============================================================================
echo -e "${YELLOW}=== Domain-Konfiguration ===${NC}\n"

# Domain aus ENV oder abfragen
if [[ -n "${DOMAIN:-}" ]]; then
    info "Domain: $DOMAIN (aus ENV)"
elif [[ "$AUTO_CONFIRM" == "true" ]]; then
    error "DOMAIN muss bei AUTO_CONFIRM gesetzt sein!"
else
    read -p "Haupt-Domain (z.B. example.com): " DOMAIN
    [ -z "$DOMAIN" ] && error "Domain darf nicht leer sein!"
fi

# Subdomains aus ENV oder Defaults
if [[ -n "${CLOUD_DOMAIN:-}" ]]; then
    NC_SUBDOMAIN=$(echo "$CLOUD_DOMAIN" | cut -d. -f1)
    info "Nextcloud Subdomain: $NC_SUBDOMAIN (aus ENV)"
else
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        NC_SUBDOMAIN="cloud"
    else
        read -p "Nextcloud Subdomain [cloud]: " NC_SUBDOMAIN
        NC_SUBDOMAIN=${NC_SUBDOMAIN:-cloud}
    fi
fi

if [[ -n "${DOCS_DOMAIN:-}" ]]; then
    PP_SUBDOMAIN=$(echo "$DOCS_DOMAIN" | cut -d. -f1)
    info "Paperless Subdomain: $PP_SUBDOMAIN (aus ENV)"
else
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        PP_SUBDOMAIN="docs"
    else
        read -p "Paperless Subdomain [docs]: " PP_SUBDOMAIN
        PP_SUBDOMAIN=${PP_SUBDOMAIN:-docs}
    fi
fi

if [[ -n "${VAULT_DOMAIN:-}" ]]; then
    VW_SUBDOMAIN=$(echo "$VAULT_DOMAIN" | cut -d. -f1)
    info "Vaultwarden Subdomain: $VW_SUBDOMAIN (aus ENV)"
else
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        VW_SUBDOMAIN="vault"
    else
        read -p "Vaultwarden Subdomain [vault]: " VW_SUBDOMAIN
        VW_SUBDOMAIN=${VW_SUBDOMAIN:-vault}
    fi
fi

if [[ -n "${SSO_DOMAIN:-}" ]]; then
    KC_SUBDOMAIN=$(echo "$SSO_DOMAIN" | cut -d. -f1)
    info "Keycloak Subdomain: $KC_SUBDOMAIN (aus ENV)"
else
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        KC_SUBDOMAIN="sso"
    else
        read -p "Keycloak SSO Subdomain [sso]: " KC_SUBDOMAIN
        KC_SUBDOMAIN=${KC_SUBDOMAIN:-sso}
    fi
fi

# Keycloak Realm aus ENV oder ableiten
if [[ -n "${KC_REALM:-}" ]]; then
    info "Keycloak Realm: $KC_REALM (aus ENV)"
else
    KC_REALM=$(echo "$DOMAIN" | cut -d. -f1)
    if [[ "$AUTO_CONFIRM" != "true" ]]; then
        read -p "Keycloak Realm Name [$KC_REALM]: " input_realm
        [ -n "$input_realm" ] && KC_REALM="$input_realm"
    fi
fi

echo ""
echo -e "${BLUE}Domains:${NC}"
echo "  Nextcloud:   ${NC_SUBDOMAIN}.${DOMAIN}"
echo "  Paperless:   ${PP_SUBDOMAIN}.${DOMAIN}"
echo "  Vaultwarden: ${VW_SUBDOMAIN}.${DOMAIN}"
echo "  Keycloak:    ${KC_SUBDOMAIN}.${DOMAIN}"
echo "  KC Realm:    ${KC_REALM}"
echo ""

# Bestätigung
if [[ "$AUTO_CONFIRM" != "true" ]]; then
    read -p "Fortfahren? (j/n): " CONFIRM
    [ "$CONFIRM" != "j" ] && [ "$CONFIRM" != "J" ] && { echo "Abgebrochen."; exit 0; }
else
    info "AUTO_CONFIRM aktiv - starte automatisch..."
fi

#===============================================================================
# Passwörter (aus ENV oder generieren)
#===============================================================================
echo ""
log "Passwörter werden konfiguriert..."

# Aus ENV oder generieren
POSTGRES_PASSWORD="${POSTGRES_PASS:-$(generate_password)}"
REDIS_PASSWORD="${REDIS_PASS:-$(generate_password)}"
NEXTCLOUD_ADMIN_PASS="${NC_ADMIN_PASS:-$(generate_password)}"
PAPERLESS_SECRET="${PAPERLESS_SECRET:-$(generate_password)}"
PAPERLESS_ADMIN_PASS="${NEXTCLOUD_ADMIN_PASS}"  # Gleiches Passwort wie Nextcloud
VAULTWARDEN_ADMIN_TOKEN="${VW_ADMIN_TOKEN:-$(generate_password)}"
KEYCLOAK_ADMIN_PASS="${KC_ADMIN_PASS:-$(generate_password)}"
KEYCLOAK_DB_PASS="${POSTGRES_PASSWORD}"  # Nutzt PostgreSQL-Passwort

#===============================================================================
# Verzeichnisstruktur erstellen
#===============================================================================
# Bei AUTO_CONFIRM (Master-Installer) nach /opt/eigendaten, sonst $HOME/app
if [[ "$AUTO_CONFIRM" == "true" && "$EUID" -eq 0 ]]; then
    APP_DIR="/opt/eigendaten"
else
    APP_DIR="$HOME/app"
fi

mkdir -p "$APP_DIR"
cd "$APP_DIR"

log "Arbeitsverzeichnis: $APP_DIR"

#===============================================================================
# Datenverzeichnisse erstellen
#===============================================================================
log "Datenverzeichnisse werden erstellt..."

sudo mkdir -p /mnt/data/{nextcloud,paperless/{data,media,consume,export},vaultwarden,npm/{data,letsencrypt},postgres,redis}
sudo chown -R 1000:1000 /mnt/data/paperless
sudo chown -R 33:33 /mnt/data/nextcloud  # www-data

log "Datenverzeichnisse erstellt unter /mnt/data/"

#===============================================================================
# .env Datei erstellen
#===============================================================================
log "Environment-Datei wird erstellt..."

cat > .env << EOF
# ============================================
# Eigendaten App Server - Konfiguration
# Generiert: $(date)
# ============================================

# Domain
DOMAIN=${DOMAIN}

# Subdomains
NC_SUBDOMAIN=${NC_SUBDOMAIN}
PP_SUBDOMAIN=${PP_SUBDOMAIN}
VW_SUBDOMAIN=${VW_SUBDOMAIN}
KC_SUBDOMAIN=${KC_SUBDOMAIN}

# Keycloak
KC_REALM=${KC_REALM}
KEYCLOAK_ADMIN_PASS=${KEYCLOAK_ADMIN_PASS}
KEYCLOAK_DB_PASS=${KEYCLOAK_DB_PASS}

# PostgreSQL
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

# Redis
REDIS_PASSWORD=${REDIS_PASSWORD}

# Nextcloud
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASS=${NEXTCLOUD_ADMIN_PASS}

# Paperless
PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET}
PAPERLESS_ADMIN_USER=admin
PAPERLESS_ADMIN_PASS=${PAPERLESS_ADMIN_PASS}

# Vaultwarden
VAULTWARDEN_ADMIN_TOKEN=${VAULTWARDEN_ADMIN_TOKEN}
EOF

chmod 600 .env
log ".env erstellt (chmod 600)"

#===============================================================================
# Docker Compose erstellen
# Produktions-getestete Konfiguration
#===============================================================================
log "docker-compose.yml wird erstellt..."

cat > docker-compose.yml << 'COMPOSE_EOF'
# ============================================
# Eigendaten App Server - Docker Compose v4.0
# KEINE version: - ist obsolet in modernem Docker Compose
# ============================================

services:

  #=============================================================================
  # NGINX PROXY MANAGER
  #=============================================================================
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - /mnt/data/npm/data:/data
      - /mnt/data/npm/letsencrypt:/etc/letsencrypt
    networks:
      - frontend
      - backend
    healthcheck:
      test: ["CMD", "/bin/check-health"]
      interval: 30s
      timeout: 10s
      retries: 3

  #=============================================================================
  # POSTGRESQL - Shared Database
  #=============================================================================
  postgres:
    image: postgres:16-alpine
    container_name: postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /mnt/data/postgres:/var/lib/postgresql/data
      # Init-Script für mehrere Datenbanken
      - ./init-db.sh:/docker-entrypoint-initdb.d/init-db.sh:ro
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  #=============================================================================
  # REDIS - Session Cache
  #=============================================================================
  redis:
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - /mnt/data/redis:/data
    networks:
      - backend
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  #=============================================================================
  # NEXTCLOUD
  # FIX: trusted_proxies mit korrekter CIDR-Notation, nicht Container-Namen!
  #=============================================================================
  nextcloud:
    image: nextcloud:stable
    container_name: nextcloud
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      # Datenbank
      POSTGRES_HOST: postgres
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      # Redis
      REDIS_HOST: redis
      REDIS_HOST_PASSWORD: ${REDIS_PASSWORD}
      # Admin
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASS}
      # Domain & Proxy
      NEXTCLOUD_TRUSTED_DOMAINS: ${NC_SUBDOMAIN}.${DOMAIN}
      # ============================================
      # KRITISCHER FIX: CIDR statt Container-Namen!
      # FALSCH: TRUSTED_PROXIES: npm
      # RICHTIG: Private Netzwerke als CIDR
      # ============================================
      TRUSTED_PROXIES: 172.16.0.0/12 10.0.0.0/8 192.168.0.0/16
      OVERWRITEPROTOCOL: https
      OVERWRITEHOST: ${NC_SUBDOMAIN}.${DOMAIN}
    volumes:
      - /mnt/data/nextcloud:/var/www/html
    networks:
      - backend
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/status.php"]
      interval: 30s
      timeout: 10s
      retries: 5

  #=============================================================================
  # PAPERLESS-NGX
  # SSO/OIDC-Variablen vorbereitet, werden später aktiviert
  #=============================================================================
  paperless:
    image: ghcr.io/paperless-ngx/paperless-ngx:latest
    container_name: paperless
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      # Datenbank
      PAPERLESS_DBENGINE: postgresql
      PAPERLESS_DBHOST: postgres
      PAPERLESS_DBNAME: paperless
      PAPERLESS_DBUSER: paperless
      PAPERLESS_DBPASS: ${POSTGRES_PASSWORD}
      # Redis
      PAPERLESS_REDIS: redis://:${REDIS_PASSWORD}@redis:6379
      # App
      PAPERLESS_SECRET_KEY: ${PAPERLESS_SECRET_KEY}
      PAPERLESS_URL: https://${PP_SUBDOMAIN}.${DOMAIN}
      PAPERLESS_ALLOWED_HOSTS: ${PP_SUBDOMAIN}.${DOMAIN},paperless,localhost
      PAPERLESS_CSRF_TRUSTED_ORIGINS: https://${PP_SUBDOMAIN}.${DOMAIN}
      # Admin
      PAPERLESS_ADMIN_USER: ${PAPERLESS_ADMIN_USER}
      PAPERLESS_ADMIN_PASSWORD: ${PAPERLESS_ADMIN_PASS}
      # Lokalisierung
      PAPERLESS_OCR_LANGUAGE: deu+eng
      PAPERLESS_TIME_ZONE: Europe/Berlin
      # User-Mapping
      USERMAP_UID: 1000
      USERMAP_GID: 1000
      # ============================================
      # SSO/OIDC - Wird nach Keycloak-Setup aktiviert
      # Siehe: 04-sso-setup.sh
      # ============================================
    volumes:
      - /mnt/data/paperless/data:/usr/src/paperless/data
      - /mnt/data/paperless/media:/usr/src/paperless/media
      - /mnt/data/paperless/consume:/usr/src/paperless/consume
      - /mnt/data/paperless/export:/usr/src/paperless/export
    networks:
      - backend
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000"]
      interval: 30s
      timeout: 10s
      retries: 5

  #=============================================================================
  # VAULTWARDEN
  #=============================================================================
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: https://${VW_SUBDOMAIN}.${DOMAIN}
      ADMIN_TOKEN: ${VAULTWARDEN_ADMIN_TOKEN}
      SIGNUPS_ALLOWED: "false"
      INVITATIONS_ALLOWED: "true"
      WEBSOCKET_ENABLED: "true"
    volumes:
      - /mnt/data/vaultwarden:/data
    networks:
      - backend
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/alive"]
      interval: 30s
      timeout: 10s
      retries: 3

  #=============================================================================
  # KEYCLOAK DATABASE (PostgreSQL)
  # FIX: Separates PostgreSQL statt H2!
  #=============================================================================
  keycloak-db:
    image: postgres:16-alpine
    container_name: keycloak-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${KEYCLOAK_DB_PASS}
    volumes:
      - keycloak_db_data:/var/lib/postgresql/data
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak"]
      interval: 10s
      timeout: 5s
      retries: 5

  #=============================================================================
  # KEYCLOAK - Identity Provider / SSO
  # FIX: PostgreSQL statt H2, korrekte Proxy-Konfiguration
  #=============================================================================
  keycloak:
    image: quay.io/keycloak/keycloak:latest
    container_name: keycloak
    restart: unless-stopped
    depends_on:
      keycloak-db:
        condition: service_healthy
    environment:
      # Datenbank - WICHTIG: PostgreSQL statt H2!
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://keycloak-db:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${KEYCLOAK_DB_PASS}
      # Hostname
      KC_HOSTNAME: ${KC_SUBDOMAIN}.${DOMAIN}
      KC_HOSTNAME_STRICT: "false"
      # Proxy-Einstellungen für Reverse Proxy
      KC_HTTP_ENABLED: "true"
      KC_PROXY_HEADERS: xforwarded
      # Admin
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASS}
    command: start
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/127.0.0.1/8080;echo -e 'GET /health/ready HTTP/1.1\r\nhost: localhost\r\nConnection: close\r\n\r\n' >&3;if [ $? -eq 0 ]; then echo 'Healthcheck Successful';exit 0;else echo 'Healthcheck Failed';exit 1;fi;"]
      interval: 30s
      timeout: 10s
      retries: 5

#=============================================================================
# NETWORKS
#=============================================================================
networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge

#=============================================================================
# VOLUMES
#=============================================================================
volumes:
  keycloak_db_data:
COMPOSE_EOF

log "docker-compose.yml erstellt"

#===============================================================================
# Datenbank-Init-Script
#===============================================================================
log "Datenbank-Init-Script wird erstellt..."

cat > init-db.sh << 'INITDB_EOF'
#!/bin/bash
set -e

# Mehrere Datenbanken und User erstellen
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    -- Nextcloud
    CREATE USER nextcloud WITH PASSWORD '$POSTGRES_PASSWORD';
    CREATE DATABASE nextcloud OWNER nextcloud;
    GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
    
    -- Paperless
    CREATE USER paperless WITH PASSWORD '$POSTGRES_PASSWORD';
    CREATE DATABASE paperless OWNER paperless;
    GRANT ALL PRIVILEGES ON DATABASE paperless TO paperless;
EOSQL

echo "Datenbanken nextcloud und paperless erstellt"
INITDB_EOF

chmod +x init-db.sh
log "init-db.sh erstellt"

#===============================================================================
# Post-Install Script (Nextcloud Fixes)
#===============================================================================
log "Post-Install Script wird erstellt..."

cat > post-install.sh << 'POSTINSTALL_EOF'
#!/bin/bash
# ============================================
# Post-Install Fixes für Nextcloud
# Führe dies nach dem ersten Start aus!
# ============================================

echo "Warte auf Nextcloud-Container (60 Sekunden)..."
sleep 60

echo "Setze trusted_proxies korrekt (CIDR-Notation)..."
docker exec -u www-data nextcloud php occ config:system:delete trusted_proxies 2>/dev/null || true
docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 0 --value="172.16.0.0/12"
docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 1 --value="10.0.0.0/8"
docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 2 --value="192.168.0.0/16"

echo "Setze HTTPS-Overwrite..."
docker exec -u www-data nextcloud php occ config:system:set overwriteprotocol --value="https"

echo "Setze Telefon-Region..."
docker exec -u www-data nextcloud php occ config:system:set default_phone_region --value="DE"

echo "Prüfe Einstellungen..."
docker exec -u www-data nextcloud php occ config:system:get trusted_proxies

echo ""
echo "✅ Post-Install Fixes angewendet!"
echo "   Nextcloud Admin-Seite neu laden und Warnungen prüfen."
POSTINSTALL_EOF

chmod +x post-install.sh
log "post-install.sh erstellt"

#===============================================================================
# Stack starten
#===============================================================================
echo ""
log "Docker-Stack wird gestartet..."
docker compose up -d

echo ""
log "Warte auf Container-Start (30 Sekunden)..."
sleep 30

#===============================================================================
# Status anzeigen
#===============================================================================
echo ""
docker compose ps

#===============================================================================
# Zugangsdaten speichern
#===============================================================================
log "Zugangsdaten werden gespeichert..."

cat > ZUGANGSDATEN.txt << EOF
============================================
EIGENDATEN - Zugangsdaten
Generiert: $(date)
VERTRAULICH - SICHER AUFBEWAHREN!
============================================

NPM (Nginx Proxy Manager)
  URL:      http://SERVER-IP:81
  User:     admin@example.com
  Passwort: changeme
  → SOFORT ÄNDERN!

Nextcloud
  URL:      https://${NC_SUBDOMAIN}.${DOMAIN}
  User:     admin
  Passwort: ${NEXTCLOUD_ADMIN_PASS}

Paperless-NGX
  URL:      https://${PP_SUBDOMAIN}.${DOMAIN}
  User:     admin
  Passwort: ${PAPERLESS_ADMIN_PASS}

Vaultwarden
  URL:      https://${VW_SUBDOMAIN}.${DOMAIN}
  Admin:    https://${VW_SUBDOMAIN}.${DOMAIN}/admin
  Token:    ${VAULTWARDEN_ADMIN_TOKEN}

Keycloak
  URL:      https://${KC_SUBDOMAIN}.${DOMAIN}
  Admin:    https://${KC_SUBDOMAIN}.${DOMAIN}/admin
  User:     admin
  Passwort: ${KEYCLOAK_ADMIN_PASS}
  Realm:    ${KC_REALM}

PostgreSQL (intern)
  Host:     postgres
  User:     postgres
  Passwort: ${POSTGRES_PASSWORD}

Redis (intern)
  Host:     redis
  Passwort: ${REDIS_PASSWORD}

============================================
EOF

chmod 600 ZUGANGSDATEN.txt
log "Zugangsdaten in ZUGANGSDATEN.txt gespeichert"

#===============================================================================
# Zusammenfassung
#===============================================================================
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              App-Server Setup abgeschlossen!                       ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Container-Status:${NC}"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
echo ""
echo -e "${YELLOW}NÄCHSTE SCHRITTE:${NC}"
echo ""
echo "1. NPM einrichten:"
echo "   http://$(hostname -I | awk '{print $1}'):81"
echo "   Login: admin@example.com / changeme"
echo ""
echo "2. DNS-Einträge setzen (falls noch nicht geschehen):"
echo "   ${NC_SUBDOMAIN}.${DOMAIN}  A  → $(hostname -I | awk '{print $1}')"
echo "   ${PP_SUBDOMAIN}.${DOMAIN}  A  → $(hostname -I | awk '{print $1}')"
echo "   ${VW_SUBDOMAIN}.${DOMAIN}  A  → $(hostname -I | awk '{print $1}')"
echo "   ${KC_SUBDOMAIN}.${DOMAIN}  A  → $(hostname -I | awk '{print $1}')"
echo ""
echo "3. Proxy Hosts in NPM anlegen:"
echo "   ${NC_SUBDOMAIN}.${DOMAIN} → nextcloud:80 (SSL)"
echo "   ${PP_SUBDOMAIN}.${DOMAIN} → paperless:8000 (SSL)"
echo "   ${VW_SUBDOMAIN}.${DOMAIN} → vaultwarden:80 (SSL, Websockets!)"
echo "   ${KC_SUBDOMAIN}.${DOMAIN} → keycloak:8080 (SSL)"
echo ""
echo "4. Nach NPM-Setup Post-Install Fixes ausführen:"
echo "   ./post-install.sh"
echo ""
echo "5. Zugangsdaten:"
echo "   cat ZUGANGSDATEN.txt"
echo ""
echo -e "${YELLOW}WICHTIG:${NC}"
echo "  - ZUGANGSDATEN.txt sicher aufbewahren und dann löschen!"
echo "  - NPM Admin-Port (81) einschränken:"
echo "    sudo ufw delete allow 81/tcp"
echo "    sudo ufw allow from DEINE-IP to any port 81"
echo ""

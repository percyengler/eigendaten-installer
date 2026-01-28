#!/bin/bash
#===============================================================================
# Eigendaten - SSO Setup v4.0
#
# Konfiguriert Single Sign-On mit Keycloak fur:
# - Nextcloud (user_oidc App)
# - Paperless-NGX (Native OIDC via allauth)
# - Mailcow (via Datenbank-Konfiguration!)
# - Vaultwarden (OpenID Connect)
#
# Voraussetzung: Keycloak lauft und ist erreichbar
#
# Version: 4.0
# - Fix: Mailcow SSO uber Datenbank statt Web-UI
# - Fix: Paperless JSON-Format
# - Neu: Vaultwarden SSO mit PKCE
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

log()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[X]${NC} $1"; exit 1; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }

banner() {
    echo -e "${BLUE}"
    echo "======================================================================"
    echo "         EIGENDATEN - SSO Setup v4.0                                 "
    echo "       Keycloak -> Nextcloud / Paperless / Mailcow / Vaultwarden    "
    echo "======================================================================"
    echo -e "${NC}"
}

generate_secret() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

#===============================================================================
# Banner
#===============================================================================
banner

#===============================================================================
# Konfiguration (aus ENV oder interaktiv)
#===============================================================================
echo -e "${YELLOW}=== SSO-Konfiguration ===${NC}\n"

AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

# Keycloak URL
if [[ -n "${KC_URL:-}" ]]; then
    info "Keycloak URL: $KC_URL (aus ENV)"
elif [[ "$AUTO_CONFIRM" == "true" ]]; then
    error "KC_URL muss bei AUTO_CONFIRM gesetzt sein!"
else
    read -p "Keycloak URL (z.B. https://sso.example.com): " KC_URL
    [ -z "$KC_URL" ] && error "Keycloak URL darf nicht leer sein!"
fi

# Keycloak Realm
if [[ -n "${KC_REALM:-}" ]]; then
    info "Keycloak Realm: $KC_REALM (aus ENV)"
elif [[ "$AUTO_CONFIRM" == "true" ]]; then
    error "KC_REALM muss bei AUTO_CONFIRM gesetzt sein!"
else
    read -p "Keycloak Realm: " KC_REALM
    [ -z "$KC_REALM" ] && error "Realm darf nicht leer sein!"
fi

# Keycloak Admin
KC_ADMIN="${KC_ADMIN:-admin}"
if [[ -n "${KC_ADMIN_PASS:-}" ]]; then
    info "Keycloak Admin: $KC_ADMIN (aus ENV)"
else
    read -sp "Keycloak Admin Passwort: " KC_ADMIN_PASS
    echo ""
    [ -z "$KC_ADMIN_PASS" ] && error "Passwort darf nicht leer sein!"
fi

# Dienste konfigurieren
if [[ "$AUTO_CONFIRM" == "true" ]]; then
    SETUP_NC="${SETUP_NC:-j}"
    SETUP_PP="${SETUP_PP:-j}"
    SETUP_MC="${SETUP_MC:-n}"
    SETUP_VW="${SETUP_VW:-j}"
else
    echo ""
    echo "Welche Dienste sollen SSO-fahig gemacht werden?"
    read -p "Nextcloud konfigurieren? (j/n) [j]: " SETUP_NC
    SETUP_NC=${SETUP_NC:-j}

    read -p "Paperless-NGX konfigurieren? (j/n) [j]: " SETUP_PP
    SETUP_PP=${SETUP_PP:-j}

    read -p "Vaultwarden konfigurieren? (j/n) [j]: " SETUP_VW
    SETUP_VW=${SETUP_VW:-j}

    read -p "Mailcow konfigurieren? (j/n) [n]: " SETUP_MC
    SETUP_MC=${SETUP_MC:-n}
fi

# URLs der Dienste
if [ "$SETUP_NC" = "j" ]; then
    NC_URL="${NC_URL:-}"
    if [[ -z "$NC_URL" && "$AUTO_CONFIRM" != "true" ]]; then
        read -p "Nextcloud URL (z.B. https://cloud.example.com): " NC_URL
    fi
fi

if [ "$SETUP_PP" = "j" ]; then
    PP_URL="${PP_URL:-}"
    if [[ -z "$PP_URL" && "$AUTO_CONFIRM" != "true" ]]; then
        read -p "Paperless URL (z.B. https://docs.example.com): " PP_URL
    fi
fi

if [ "$SETUP_VW" = "j" ]; then
    VW_URL="${VW_URL:-}"
    if [[ -z "$VW_URL" && "$AUTO_CONFIRM" != "true" ]]; then
        read -p "Vaultwarden URL (z.B. https://vault.example.com): " VW_URL
    fi
fi

if [ "$SETUP_MC" = "j" ]; then
    MC_URL="${MC_URL:-}"
    if [[ -z "$MC_URL" && "$AUTO_CONFIRM" != "true" ]]; then
        read -p "Mailcow URL (z.B. https://mail.example.com): " MC_URL
    fi
fi

# App-Verzeichnis
APP_DIR="${APP_DIR:-/opt/eigendaten}"

#===============================================================================
# Keycloak Admin-CLI konfigurieren
#===============================================================================
echo ""
log "Keycloak Admin-CLI wird konfiguriert..."

docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "$KC_ADMIN" \
    --password "$KC_ADMIN_PASS" || error "Keycloak-Login fehlgeschlagen!"

log "Keycloak-Login erfolgreich"

#===============================================================================
# Realm prufen/erstellen
#===============================================================================
log "Realm wird gepruft..."

if docker exec keycloak /opt/keycloak/bin/kcadm.sh get realms/${KC_REALM} &>/dev/null; then
    info "Realm '${KC_REALM}' existiert bereits"
else
    log "Realm '${KC_REALM}' wird erstellt..."
    docker exec keycloak /opt/keycloak/bin/kcadm.sh create realms \
        -s realm="${KC_REALM}" \
        -s enabled=true \
        -s displayName="${KC_REALM}"
    log "Realm erstellt"
fi

#===============================================================================
# NEXTCLOUD SSO
#===============================================================================
if [ "$SETUP_NC" = "j" ]; then
    echo ""
    echo -e "${BLUE}=== Nextcloud SSO Setup ===${NC}"

    NC_CLIENT_SECRET=$(generate_secret)

    # Client erstellen
    log "Nextcloud-Client wird erstellt..."

    docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients -r ${KC_REALM} \
        -s clientId=nextcloud \
        -s name="Nextcloud Cloud" \
        -s enabled=true \
        -s protocol=openid-connect \
        -s publicClient=false \
        -s "redirectUris=[\"${NC_URL}/*\"]" \
        -s "webOrigins=[\"${NC_URL}\"]" \
        -s baseUrl="${NC_URL}" \
        -s standardFlowEnabled=true \
        -s directAccessGrantsEnabled=false 2>/dev/null || warn "Client existiert moglicherweise bereits"

    # Client-ID abrufen und Secret setzen
    NC_CLIENT_ID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r ${KC_REALM} -q clientId=nextcloud --fields id --format csv --noquotes 2>/dev/null | head -1)

    if [ -n "$NC_CLIENT_ID" ]; then
        docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients/${NC_CLIENT_ID}/client-secret -r ${KC_REALM} 2>/dev/null || true
        NC_CLIENT_SECRET=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients/${NC_CLIENT_ID}/client-secret -r ${KC_REALM} --fields value 2>/dev/null | grep value | cut -d'"' -f4)
    fi

    log "Nextcloud-Client erstellt"

    # Nextcloud user_oidc App installieren (besser als oidc_login)
    log "Nextcloud user_oidc App wird installiert..."
    docker exec -u www-data nextcloud php occ app:install user_oidc 2>/dev/null || info "App bereits installiert"
    docker exec -u www-data nextcloud php occ app:enable user_oidc

    # OIDC Provider registrieren
    log "Nextcloud OIDC wird konfiguriert..."

    docker exec -u www-data nextcloud php occ user_oidc:provider:create Keycloak \
        --clientid="nextcloud" \
        --clientsecret="${NC_CLIENT_SECRET}" \
        --discoveryuri="${KC_URL}/realms/${KC_REALM}/.well-known/openid-configuration" \
        --mapping-uid="preferred_username" \
        --mapping-displayName="name" \
        --mapping-email="email" 2>/dev/null || warn "Provider existiert moglicherweise bereits"

    log "Nextcloud SSO konfiguriert"

    echo ""
    echo -e "${GREEN}Nextcloud SSO-Daten:${NC}"
    echo "  Client-ID:     nextcloud"
    echo "  Client-Secret: ${NC_CLIENT_SECRET}"
    echo "  Button:        'Login with Keycloak'"
fi

#===============================================================================
# PAPERLESS-NGX SSO
#===============================================================================
if [ "$SETUP_PP" = "j" ]; then
    echo ""
    echo -e "${BLUE}=== Paperless-NGX SSO Setup ===${NC}"

    # Client erstellen
    log "Paperless-Client wird erstellt..."

    docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients -r ${KC_REALM} \
        -s clientId=paperless \
        -s name="Paperless-NGX Dokumente" \
        -s enabled=true \
        -s protocol=openid-connect \
        -s publicClient=false \
        -s "redirectUris=[\"${PP_URL}/*\"]" \
        -s "webOrigins=[\"${PP_URL}\"]" \
        -s baseUrl="${PP_URL}" \
        -s standardFlowEnabled=true \
        -s directAccessGrantsEnabled=false 2>/dev/null || warn "Client existiert moglicherweise bereits"

    # Client-Secret abrufen
    PP_CLIENT_ID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r ${KC_REALM} -q clientId=paperless --fields id --format csv --noquotes 2>/dev/null | head -1)

    if [ -n "$PP_CLIENT_ID" ]; then
        docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients/${PP_CLIENT_ID}/client-secret -r ${KC_REALM} 2>/dev/null || true
        PP_CLIENT_SECRET=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients/${PP_CLIENT_ID}/client-secret -r ${KC_REALM} --fields value 2>/dev/null | grep value | cut -d'"' -f4)
    fi

    log "Paperless-Client erstellt"

    # Paperless docker-compose.yml automatisch aktualisieren
    log "Paperless OIDC-Konfiguration wird in docker-compose.yml eingefugt..."

    if [ -f "${APP_DIR}/docker-compose.yml" ]; then
        # Prufen ob SSO bereits konfiguriert
        if grep -q "PAPERLESS_APPS:" "${APP_DIR}/docker-compose.yml"; then
            warn "Paperless SSO scheint bereits konfiguriert zu sein"
        else
            # JSON fur OIDC (KRITISCH: Korrekte Formatierung!)
            PP_OIDC_JSON='{"openid_connect":{"OAUTH_PKCE_ENABLED":true,"APPS":[{"provider_id":"keycloak","name":"Keycloak SSO","client_id":"paperless","secret":"'${PP_CLIENT_SECRET}'","settings":{"server_url":"'${KC_URL}'/realms/'${KC_REALM}'/.well-known/openid-configuration"}}]}}'

            # In docker-compose.yml einfugen (nach PAPERLESS_TIME_ZONE)
            sed -i "/PAPERLESS_TIME_ZONE:/a\\      # SSO/OIDC Konfiguration\n      PAPERLESS_APPS: allauth.socialaccount.providers.openid_connect\n      PAPERLESS_SOCIALACCOUNT_PROVIDERS: '${PP_OIDC_JSON}'" "${APP_DIR}/docker-compose.yml"

            log "Paperless SSO-Konfiguration eingefugt"

            # Paperless neu starten
            log "Paperless wird neu gestartet..."
            cd "${APP_DIR}" && docker compose up -d paperless
        fi
    else
        warn "docker-compose.yml nicht gefunden unter ${APP_DIR}"
    fi

    echo ""
    echo -e "${GREEN}Paperless SSO-Daten:${NC}"
    echo "  Client-ID:     paperless"
    echo "  Client-Secret: ${PP_CLIENT_SECRET}"
    echo "  Button:        'Keycloak SSO'"

    echo ""
    echo -e "${YELLOW}WICHTIG - SSO-Benutzer haben keine Admin-Rechte!${NC}"
    echo "Nach erstem Login ausfuhren:"
    echo "  docker exec -it paperless python3 manage.py shell -c \"\\"
    echo "  from django.contrib.auth.models import User; \\"
    echo "  u=User.objects.get(username='BENUTZERNAME'); \\"
    echo "  u.is_staff=True; u.is_superuser=True; u.save()\""
fi

#===============================================================================
# VAULTWARDEN SSO (NEU in v4.0)
#===============================================================================
if [ "$SETUP_VW" = "j" ]; then
    echo ""
    echo -e "${BLUE}=== Vaultwarden SSO Setup ===${NC}"

    # Client erstellen mit PKCE
    log "Vaultwarden-Client wird erstellt..."

    docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients -r ${KC_REALM} \
        -s clientId=vaultwarden \
        -s name="Vaultwarden Password Manager" \
        -s enabled=true \
        -s protocol=openid-connect \
        -s publicClient=false \
        -s "redirectUris=[\"${VW_URL}/*\"]" \
        -s "webOrigins=[\"${VW_URL}\"]" \
        -s baseUrl="${VW_URL}" \
        -s standardFlowEnabled=true \
        -s directAccessGrantsEnabled=true 2>/dev/null || warn "Client existiert moglicherweise bereits"

    # Client-ID abrufen
    VW_CLIENT_ID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r ${KC_REALM} -q clientId=vaultwarden --fields id --format csv --noquotes 2>/dev/null | head -1)

    if [ -n "$VW_CLIENT_ID" ]; then
        # PKCE aktivieren (KRITISCH fur Vaultwarden!)
        docker exec keycloak /opt/keycloak/bin/kcadm.sh update clients/${VW_CLIENT_ID} -r ${KC_REALM} \
            -s 'attributes={"pkce.code.challenge.method":"S256"}' 2>/dev/null || true

        # Secret generieren
        docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients/${VW_CLIENT_ID}/client-secret -r ${KC_REALM} 2>/dev/null || true
        VW_CLIENT_SECRET=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients/${VW_CLIENT_ID}/client-secret -r ${KC_REALM} --fields value 2>/dev/null | grep value | cut -d'"' -f4)

        # offline_access zu Default Scopes hinzufugen
        OFFLINE_SCOPE_ID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get client-scopes -r ${KC_REALM} --fields id,name 2>/dev/null | grep -B1 '"offline_access"' | grep id | cut -d'"' -f4)
        if [ -n "$OFFLINE_SCOPE_ID" ]; then
            docker exec keycloak /opt/keycloak/bin/kcadm.sh update clients/${VW_CLIENT_ID}/default-client-scopes/${OFFLINE_SCOPE_ID} -r ${KC_REALM} 2>/dev/null || true
        fi
    fi

    log "Vaultwarden-Client erstellt"

    # docker-compose.yml aktualisieren
    if [ -f "${APP_DIR}/docker-compose.yml" ]; then
        if grep -q "SSO_ENABLED:" "${APP_DIR}/docker-compose.yml"; then
            warn "Vaultwarden SSO scheint bereits konfiguriert zu sein"
        else
            # SSO-Konfiguration nach WEBSOCKET_ENABLED einfugen
            sed -i "/WEBSOCKET_ENABLED:/a\\      # SSO/OIDC Konfiguration\n      SSO_ENABLED: \"true\"\n      SSO_CLIENT_ID: vaultwarden\n      SSO_CLIENT_SECRET: ${VW_CLIENT_SECRET}\n      SSO_AUTHORITY: ${KC_URL}/realms/${KC_REALM}\n      SSO_PKCE: \"true\"\n      SSO_AUDIENCE_TRUSTED: vaultwarden\n      SSO_SCOPES: \"openid email profile offline_access\"" "${APP_DIR}/docker-compose.yml"

            log "Vaultwarden SSO-Konfiguration eingefugt"

            # Vaultwarden neu starten
            log "Vaultwarden wird neu gestartet..."
            cd "${APP_DIR}" && docker compose up -d vaultwarden
        fi
    fi

    echo ""
    echo -e "${GREEN}Vaultwarden SSO-Daten:${NC}"
    echo "  Client-ID:     vaultwarden"
    echo "  Client-Secret: ${VW_CLIENT_SECRET}"
    echo ""
    echo -e "${YELLOW}HINWEIS: SSO-Button erscheint nicht automatisch!${NC}"
    echo "  Benutzer muss manuell zu ${VW_URL}/#/sso navigieren"
fi

#===============================================================================
# MAILCOW SSO (via Datenbank - WICHTIG!)
#===============================================================================
if [ "$SETUP_MC" = "j" ]; then
    echo ""
    echo -e "${BLUE}=== Mailcow SSO Setup ===${NC}"

    # Client erstellen
    log "Mailcow-Client wird erstellt..."

    docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients -r ${KC_REALM} \
        -s clientId=mailcow \
        -s name="Mailcow Mail Server" \
        -s enabled=true \
        -s protocol=openid-connect \
        -s publicClient=false \
        -s "redirectUris=[\"${MC_URL}/*\"]" \
        -s "webOrigins=[\"${MC_URL}\"]" \
        -s baseUrl="${MC_URL}" \
        -s standardFlowEnabled=true \
        -s directAccessGrantsEnabled=false 2>/dev/null || warn "Client existiert moglicherweise bereits"

    # Client-Secret abrufen
    MC_CLIENT_ID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r ${KC_REALM} -q clientId=mailcow --fields id --format csv --noquotes 2>/dev/null | head -1)

    if [ -n "$MC_CLIENT_ID" ]; then
        docker exec keycloak /opt/keycloak/bin/kcadm.sh create clients/${MC_CLIENT_ID}/client-secret -r ${KC_REALM} 2>/dev/null || true
        MC_CLIENT_SECRET=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients/${MC_CLIENT_ID}/client-secret -r ${KC_REALM} --fields value 2>/dev/null | grep value | cut -d'"' -f4)
    fi

    log "Mailcow-Client erstellt"

    # WICHTIG: Mailcow SSO wird uber die MySQL-Datenbank konfiguriert!
    echo ""
    echo -e "${YELLOW}Mailcow SSO-Konfiguration via Datenbank:${NC}"
    echo ""
    echo "Mailcow SSO wird NICHT uber die Web-UI konfiguriert!"
    echo "Fuhre folgenden Befehl auf dem MAIL-SERVER aus:"
    echo ""
    echo "docker exec -i \$(docker ps -qf name=mysql-mailcow) mysql -u mailcow -p\${DBPASS} mailcow << 'EOSQL'"
    echo "INSERT INTO identity_provider (authsource, server_url, realm, client_id, client_secret,"
    echo "    redirect_url, version, mailpassword_flow, periodic_sync, import_users,"
    echo "    sync_interval, ignore_ssl_error, login_provisioning)"
    echo "VALUES ("
    echo "    'keycloak',"
    echo "    '${KC_URL}',"
    echo "    '${KC_REALM}',"
    echo "    'mailcow',"
    echo "    '${MC_CLIENT_SECRET}',"
    echo "    '${MC_URL}',"
    echo "    3,"
    echo "    0,"
    echo "    0,"
    echo "    0,"
    echo "    3600,"
    echo "    0,"
    echo "    1"
    echo ");"
    echo "EOSQL"
    echo ""

    # SQL-Datei speichern
    cat > /tmp/mailcow-sso-setup.sql << SQLEOF
-- Mailcow SSO Konfiguration
-- Ausfuhren auf dem Mail-Server!

INSERT INTO identity_provider (authsource, server_url, realm, client_id, client_secret,
    redirect_url, version, mailpassword_flow, periodic_sync, import_users,
    sync_interval, ignore_ssl_error, login_provisioning)
VALUES (
    'keycloak',
    '${KC_URL}',
    '${KC_REALM}',
    'mailcow',
    '${MC_CLIENT_SECRET}',
    '${MC_URL}',
    3,
    0,
    0,
    0,
    3600,
    0,
    1
);

-- Benutzer fur SSO aktivieren (NACH der Mailbox-Erstellung):
-- UPDATE mailbox SET authsource = 'keycloak' WHERE username = 'user@domain.de';
SQLEOF

    log "SQL-Datei gespeichert: /tmp/mailcow-sso-setup.sql"

    echo ""
    echo -e "${GREEN}Mailcow SSO-Daten:${NC}"
    echo "  Client-ID:     mailcow"
    echo "  Client-Secret: ${MC_CLIENT_SECRET}"
    echo "  SQL-Datei:     /tmp/mailcow-sso-setup.sql"
    echo ""
    echo -e "${YELLOW}Nach SQL-Import: Benutzer mit authsource='keycloak' markieren!${NC}"
fi

#===============================================================================
# Test-Benutzer erstellen
#===============================================================================
if [[ "$AUTO_CONFIRM" != "true" ]]; then
    echo ""
    read -p "Test-Benutzer in Keycloak erstellen? (j/n) [n]: " CREATE_TEST_USER
    CREATE_TEST_USER=${CREATE_TEST_USER:-n}
else
    CREATE_TEST_USER="${CREATE_TEST_USER:-n}"
fi

if [ "$CREATE_TEST_USER" = "j" ]; then
    read -p "Benutzername [testuser]: " TEST_USER
    TEST_USER=${TEST_USER:-testuser}

    read -p "E-Mail [test@example.com]: " TEST_EMAIL
    TEST_EMAIL=${TEST_EMAIL:-test@example.com}

    TEST_PASSWORD="Test-$(date +%Y)@"

    log "Test-Benutzer wird erstellt..."

    docker exec keycloak /opt/keycloak/bin/kcadm.sh create users -r ${KC_REALM} \
        -s username="${TEST_USER}" \
        -s firstName="Test" \
        -s lastName="User" \
        -s email="${TEST_EMAIL}" \
        -s enabled=true \
        -s emailVerified=true 2>/dev/null || warn "Benutzer existiert moglicherweise bereits"

    docker exec keycloak /opt/keycloak/bin/kcadm.sh set-password -r ${KC_REALM} \
        --username "${TEST_USER}" \
        --new-password "${TEST_PASSWORD}" 2>/dev/null || true

    log "Test-Benutzer erstellt"

    echo ""
    echo -e "${GREEN}Test-Zugangsdaten:${NC}"
    echo "  Benutzername: ${TEST_USER}"
    echo "  Passwort:     ${TEST_PASSWORD}"
fi

#===============================================================================
# Zusammenfassung
#===============================================================================
echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}               SSO-Setup abgeschlossen!                               ${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo ""
echo -e "${GREEN}Keycloak:${NC}"
echo "  URL:   ${KC_URL}"
echo "  Realm: ${KC_REALM}"
echo ""

if [ "$SETUP_NC" = "j" ]; then
    echo -e "${GREEN}Nextcloud:${NC} OK - Konfiguriert"
    echo "  Test: ${NC_URL} -> 'Login with Keycloak'"
    echo ""
fi

if [ "$SETUP_PP" = "j" ]; then
    echo -e "${GREEN}Paperless:${NC} OK - Konfiguriert"
    echo "  Test: ${PP_URL} -> 'Keycloak SSO'"
    echo ""
fi

if [ "$SETUP_VW" = "j" ]; then
    echo -e "${GREEN}Vaultwarden:${NC} OK - Konfiguriert"
    echo "  Test: ${VW_URL}/#/sso"
    echo ""
fi

if [ "$SETUP_MC" = "j" ]; then
    echo -e "${YELLOW}Mailcow:${NC} SQL-Datei bereit"
    echo "  Datei: /tmp/mailcow-sso-setup.sql"
    echo "  Auf Mail-Server ausfuhren!"
    echo ""
fi

echo -e "${YELLOW}BEKANNTE EINSCHRANKUNGEN:${NC}"
echo "1. Paperless: SSO-Benutzer haben keine Admin-Rechte (manuell setzen)"
echo "2. Vaultwarden: SSO-Button nicht in UI (/#/sso verwenden)"
echo "3. Mailcow: Mailbox muss vor SSO-Login existieren"
echo ""

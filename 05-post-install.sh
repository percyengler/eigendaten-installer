#!/bin/bash
#===============================================================================
# Eigendaten - Post-Installation Script
# 
# Führt alle Nacharbeiten aus:
# - Nextcloud OCC Maintenance-Befehle
# - trusted_proxies Konfiguration (OCC, nicht ENV!)
# - Benutzer in Keycloak anlegen
# - Nextcloud Apps installieren
#
# Version: 3.0
#===============================================================================

set -euo pipefail

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $1"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $1"; exit 1; }

# Config laden
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Defaults
DOMAIN="${DOMAIN:-}"
USERS="${USERS:-}"

#===============================================================================
# Warten bis Container bereit
#===============================================================================
wait_for_container() {
    local container=$1
    local max_wait=${2:-120}
    local waited=0
    
    while ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; do
        if [[ $waited -ge $max_wait ]]; then
            warn "Container $container nicht gefunden nach ${max_wait}s"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    
    # Container gefunden, auf healthy warten
    waited=0
    while [[ "$(docker inspect --format='{{.State.Health.Status}}' $container 2>/dev/null)" != "healthy" ]]; do
        if [[ $waited -ge $max_wait ]]; then
            warn "Container $container nicht healthy nach ${max_wait}s"
            return 1
        fi
        echo -n "."
        sleep 5
        waited=$((waited + 5))
    done
    echo ""
    return 0
}

#===============================================================================
# Nextcloud Post-Install
#===============================================================================
nextcloud_post_install() {
    if ! docker ps --format '{{.Names}}' | grep -q "^nextcloud$"; then
        log "Nextcloud nicht gefunden, überspringe..."
        return 0
    fi
    
    log "Nextcloud Post-Installation..."
    
    # Warten bis Nextcloud bereit
    log "  → Warte auf Nextcloud..."
    local max_wait=180
    local waited=0
    while ! docker exec nextcloud php occ status &>/dev/null; do
        if [[ $waited -ge $max_wait ]]; then
            warn "Nextcloud nicht bereit nach ${max_wait}s"
            return 1
        fi
        echo -n "."
        sleep 10
        waited=$((waited + 10))
    done
    echo ""
    
    # Datenbank-Indizes (behebt Warnung)
    log "  → Datenbank-Indizes hinzufügen..."
    docker exec -u www-data nextcloud php occ db:add-missing-indices 2>/dev/null || true
    docker exec -u www-data nextcloud php occ db:add-missing-primary-keys 2>/dev/null || true
    
    # MIME-Type Migration (behebt Warnung)
    log "  → MIME-Type Migration..."
    docker exec -u www-data nextcloud php occ maintenance:repair --include-expensive 2>/dev/null || true
    
    # Wartungsfenster (03:00 Uhr = 02:00 UTC)
    log "  → Wartungsfenster setzen..."
    docker exec -u www-data nextcloud php occ config:system:set maintenance_window_start --type=integer --value=2 2>/dev/null || true
    
    # Telefon-Region Deutschland
    log "  → Telefon-Region setzen..."
    docker exec -u www-data nextcloud php occ config:system:set default_phone_region --value="DE" 2>/dev/null || true
    
    # KRITISCH: trusted_proxies per OCC setzen (ENV funktioniert nicht bei bestehenden Installationen!)
    log "  → trusted_proxies konfigurieren (KRITISCH!)..."
    docker exec -u www-data nextcloud php occ config:system:delete trusted_proxies 2>/dev/null || true
    docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 0 --value="172.16.0.0/12"
    docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 1 --value="10.0.0.0/8"
    docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 2 --value="192.168.0.0/16"
    
    # HTTPS Overwrite
    log "  → HTTPS-Konfiguration..."
    docker exec -u www-data nextcloud php occ config:system:set overwriteprotocol --value="https"
    if [[ -n "${CLOUD_DOMAIN:-}" ]]; then
        docker exec -u www-data nextcloud php occ config:system:set overwritehost --value="${CLOUD_DOMAIN}"
    fi
    
    # Apps installieren
    log "  → Apps installieren..."
    for app in calendar contacts deck tasks mail user_oidc; do
        docker exec -u www-data nextcloud php occ app:install $app 2>/dev/null || true
    done
    
    log "✓ Nextcloud Post-Installation abgeschlossen"
}

#===============================================================================
# Paperless Post-Install
#===============================================================================
paperless_post_install() {
    if ! docker ps --format '{{.Names}}' | grep -q "^paperless$"; then
        log "Paperless nicht gefunden, überspringe..."
        return 0
    fi
    
    log "Paperless Post-Installation..."
    
    # Warten bis bereit
    local max_wait=120
    local waited=0
    while ! docker exec paperless python3 manage.py check &>/dev/null; do
        if [[ $waited -ge $max_wait ]]; then
            warn "Paperless nicht bereit"
            return 1
        fi
        sleep 10
        waited=$((waited + 10))
    done
    
    # Admin-User erstellen falls nicht existiert
    log "  → Admin-User prüfen..."
    docker exec paperless python3 manage.py shell -c "
from django.contrib.auth.models import User
if not User.objects.filter(username='admin').exists():
    User.objects.create_superuser('admin', '${ADMIN_EMAIL:-admin@localhost}', '${NC_ADMIN_PASS:-admin}')
    print('Admin erstellt')
else:
    print('Admin existiert bereits')
" 2>/dev/null || true
    
    log "✓ Paperless Post-Installation abgeschlossen"
}

#===============================================================================
# Keycloak Post-Install
#===============================================================================
keycloak_post_install() {
    if ! docker ps --format '{{.Names}}' | grep -q "^keycloak$"; then
        log "Keycloak nicht gefunden, überspringe..."
        return 0
    fi
    
    log "Keycloak Post-Installation..."
    
    # Warten bis bereit
    log "  → Warte auf Keycloak..."
    local max_wait=300
    local waited=0
    while ! docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
        --server http://localhost:8080 \
        --realm master \
        --user admin \
        --password "${KC_ADMIN_PASS:-admin}" &>/dev/null; do
        if [[ $waited -ge $max_wait ]]; then
            warn "Keycloak nicht bereit nach ${max_wait}s"
            return 1
        fi
        echo -n "."
        sleep 15
        waited=$((waited + 15))
    done
    echo ""
    
    local REALM="${DOMAIN%%.*}"
    
    # Realm erstellen
    log "  → Realm '$REALM' erstellen..."
    docker exec keycloak /opt/keycloak/bin/kcadm.sh create realms \
        -s realm="$REALM" \
        -s enabled=true \
        -s displayName="$DOMAIN" 2>/dev/null || warn "Realm existiert bereits"
    
    # KRITISCH: OpenID Scope erstellen (fehlt oft!)
    log "  → OpenID Scope erstellen (KRITISCH!)..."
    docker exec keycloak /opt/keycloak/bin/kcadm.sh create client-scopes \
        -r "$REALM" \
        -s name=openid \
        -s protocol=openid-connect \
        -s 'attributes={"include.in.token.scope":"true","display.on.consent.screen":"false"}' 2>/dev/null || true
    
    log "✓ Keycloak Post-Installation abgeschlossen"
}

#===============================================================================
# Benutzer anlegen
#===============================================================================
create_users() {
    if [[ -z "${USERS:-}" ]]; then
        log "Keine Benutzer definiert"
        return 0
    fi
    
    if ! docker ps --format '{{.Names}}' | grep -q "^keycloak$"; then
        warn "Keycloak nicht verfügbar, Benutzer später anlegen"
        return 0
    fi
    
    log "Erstelle Benutzer..."
    
    local REALM="${DOMAIN%%.*}"
    local creds_file="$SCRIPT_DIR/user-credentials.txt"
    
    echo "# Benutzer-Zugangsdaten - $(date)" > "$creds_file"
    echo "# Format: username:email:password" >> "$creds_file"
    echo "" >> "$creds_file"
    
    # Parse USERS (Format: vorname:nachname:email,vorname:nachname:email)
    IFS=',' read -ra user_array <<< "$USERS"
    
    for user_entry in "${user_array[@]}"; do
        IFS=':' read -r firstname lastname email <<< "$user_entry"
        
        if [[ -z "$firstname" || -z "$email" ]]; then
            warn "Ungültiger Eintrag: $user_entry"
            continue
        fi
        
        # Username aus E-Mail generieren
        local username="${email%%@*}"
        
        # Passwort generieren
        local password
        password="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)!"
        
        log "  → $username ($email)"
        
        # In Keycloak anlegen
        docker exec keycloak /opt/keycloak/bin/kcadm.sh create users \
            -r "$REALM" \
            -s username="$username" \
            -s email="$email" \
            -s firstName="${firstname:-$username}" \
            -s lastName="${lastname:-}" \
            -s enabled=true \
            -s emailVerified=true 2>/dev/null || warn "User existiert bereits"
        
        docker exec keycloak /opt/keycloak/bin/kcadm.sh set-password \
            -r "$REALM" \
            --username "$username" \
            --new-password "$password" 2>/dev/null || true
        
        # Credentials speichern
        echo "$username:$email:$password" >> "$creds_file"
    done
    
    chmod 600 "$creds_file"
    log "✓ Benutzer erstellt (Passwörter in $creds_file)"
}

#===============================================================================
# NPM (Nginx Proxy Manager) Auto-Konfiguration
#===============================================================================
npm_auto_configure() {
    if ! docker ps --format '{{.Names}}' | grep -q "^npm$"; then
        log "NPM nicht gefunden, überspringe..."
        return 0
    fi

    if [[ -z "${DOMAIN:-}" ]]; then
        warn "DOMAIN nicht gesetzt, NPM-Konfiguration übersprungen"
        return 0
    fi

    log "NPM Auto-Konfiguration..."

    # Warten bis NPM Container läuft
    log "  → Warte auf NPM Container..."
    local max_wait=60
    local waited=0
    while ! docker ps --format '{{.Names}}' | grep -q "^npm$"; do
        if [[ $waited -ge $max_wait ]]; then
            warn "NPM Container nicht gestartet nach ${max_wait}s"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log "  → NPM Container läuft"

    # Warten bis NPM healthy ist (Docker Health Check)
    log "  → Warte auf NPM Health Check..."
    max_wait=180
    waited=0
    while [[ "$(docker inspect --format='{{.State.Health.Status}}' npm 2>/dev/null)" != "healthy" ]]; do
        if [[ $waited -ge $max_wait ]]; then
            warn "NPM nicht healthy nach ${max_wait}s"
            # Trotzdem versuchen fortzufahren
            break
        fi
        echo -n "."
        sleep 5
        waited=$((waited + 5))
    done
    echo ""

    # Warten bis NPM API antwortet (mit trailing slash!)
    log "  → Warte auf NPM API..."
    max_wait=120
    waited=0
    while ! curl -s http://localhost:81/api/ 2>/dev/null | grep -q "version"; do
        if [[ $waited -ge $max_wait ]]; then
            warn "NPM API nicht bereit nach ${max_wait}s"
            warn "Bitte Proxy Hosts manuell in NPM anlegen"
            return 1
        fi
        echo -n "."
        sleep 5
        waited=$((waited + 5))
    done
    echo ""
    log "  → NPM API bereit"

    # Prüfe ob NPM Setup bereits durchgeführt wurde
    local npm_status
    npm_status=$(curl -s http://localhost:81/api/)
    local setup_done=$(echo "$npm_status" | grep -o '"setup":[^,]*' | cut -d: -f2)

    if [[ "$setup_done" == "false" ]]; then
        log "  → NPM Initial Setup wird durchgeführt..."

        # Admin-Credentials aus ENV oder Defaults
        local admin_email="${ADMIN_EMAIL:-admin@example.com}"
        local admin_pass="${NPM_ADMIN_PASS:-changeme}"

        # User direkt in DB eintragen (da /api/setup nicht existiert in v2.13+)
        # NPM v2.13 nutzt 3 Tabellen: user, auth, user_permission
        # Wir nutzen Node.js sqlite3 Modul (sqlite3 binary nicht verfügbar im Container)

        log "  → Erstelle Admin-User in Datenbank..."

        # Timestamp für Datenbank (UTC format wie NPM es erwartet)
        local now
        now=$(date -u '+%Y-%m-%d %H:%M:%S')

        # User erstellen via Node.js (bcrypt + sqlite3)
        docker exec npm node -e "
const sqlite3 = require('sqlite3').verbose();
const bcrypt = require('bcrypt');

const email = '${admin_email}';
const password = '${admin_pass}';
const now = '${now}';

// Passwort hashen
bcrypt.hash(password, 10, (err, hash) => {
    if (err) {
        console.error('Hash-Fehler:', err);
        process.exit(1);
    }

    // Datenbank öffnen
    const db = new sqlite3.Database('/data/database.sqlite', (err) => {
        if (err) {
            console.error('DB-Fehler:', err);
            process.exit(1);
        }
    });

    // Transaktionen für alle 3 Tabellen
    db.serialize(() => {
        // 1. User erstellen
        db.run(
            \`INSERT INTO user (created_on, modified_on, is_deleted, is_disabled, email, name, nickname, avatar, roles)
             VALUES (?, ?, 0, 0, ?, 'Admin', 'Admin', '', ?)\`,
            [now, now, email, '[\"admin\"]'],
            function(err) {
                if (err) {
                    console.error('User-Insert-Fehler:', err);
                    process.exit(1);
                }

                const userId = this.lastID;

                // 2. Auth-Daten erstellen
                db.run(
                    \`INSERT INTO auth (created_on, modified_on, user_id, type, secret, meta, is_deleted)
                     VALUES (?, ?, ?, 'password', ?, '{}', 0)\`,
                    [now, now, userId, hash],
                    function(err) {
                        if (err) {
                            console.error('Auth-Insert-Fehler:', err);
                            process.exit(1);
                        }

                        // 3. Permissions erstellen
                        db.run(
                            \`INSERT INTO user_permission (created_on, modified_on, user_id, visibility, proxy_hosts, redirection_hosts, dead_hosts, streams, access_lists, certificates)
                             VALUES (?, ?, ?, 'all', 'manage', 'manage', 'manage', 'manage', 'manage', 'manage')\`,
                            [now, now, userId],
                            function(err) {
                                if (err) {
                                    console.error('Permission-Insert-Fehler:', err);
                                    process.exit(1);
                                }

                                console.log('✓ Admin-User erstellt');
                                db.close();
                            }
                        );
                    }
                );
            }
        );
    });
});
" 2>&1

        if [[ $? -ne 0 ]]; then
            warn "Konnte Admin-User nicht erstellen"
            return 1
        fi

        log "  → Admin-User erstellt: $admin_email"
        sleep 2
    else
        log "  → NPM Setup bereits durchgeführt"
        # Bei bereits durchgeführtem Setup: vorhandene Credentials nutzen
        local admin_email="${ADMIN_EMAIL:-admin@example.com}"
        local admin_pass="${NPM_ADMIN_PASS:-changeme}"
    fi

    # Login als Admin
    log "  → Login als Admin..."
    local token
    token=$(curl -s -X POST http://localhost:81/api/tokens \
        -H "Content-Type: application/json" \
        -d "{\"identity\":\"${admin_email}\",\"secret\":\"${admin_pass}\"}" \
        | grep -o '"token":"[^"]*' | cut -d'"' -f4)

    if [[ -z "$token" ]]; then
        warn "NPM Login fehlgeschlagen"
        warn "Bitte Proxy Hosts manuell in NPM anlegen"
        warn "Login: http://$(hostname -I | awk '{print $1}'):81"
        return 1
    fi

    log "  → Login erfolgreich"

    # Subdomains
    local CLOUD_DOMAIN="${CLOUD_DOMAIN:-cloud.$DOMAIN}"
    local DOCS_DOMAIN="${DOCS_DOMAIN:-docs.$DOMAIN}"
    local VAULT_DOMAIN="${VAULT_DOMAIN:-vault.$DOMAIN}"
    local SSO_DOMAIN="${SSO_DOMAIN:-sso.$DOMAIN}"
    local ADMIN_EMAIL="${ADMIN_EMAIL:-admin@$DOMAIN}"

    # Proxy Host für Nextcloud
    log "  → Erstelle Proxy Host: $CLOUD_DOMAIN → nextcloud:80"
    curl -s -X POST http://localhost:81/api/nginx/proxy-hosts \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain_names\": [\"$CLOUD_DOMAIN\"],
            \"forward_scheme\": \"http\",
            \"forward_host\": \"nextcloud\",
            \"forward_port\": 80,
            \"certificate_id\": 0,
            \"ssl_forced\": false,
            \"http2_support\": true,
            \"block_exploits\": true,
            \"caching_enabled\": false,
            \"allow_websocket_upgrade\": true,
            \"access_list_id\": 0,
            \"advanced_config\": \"client_max_body_size 10G;\"
        }" > /dev/null

    # Proxy Host für Paperless
    log "  → Erstelle Proxy Host: $DOCS_DOMAIN → paperless:8000"
    curl -s -X POST http://localhost:81/api/nginx/proxy-hosts \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain_names\": [\"$DOCS_DOMAIN\"],
            \"forward_scheme\": \"http\",
            \"forward_host\": \"paperless\",
            \"forward_port\": 8000,
            \"certificate_id\": 0,
            \"ssl_forced\": false,
            \"http2_support\": true,
            \"block_exploits\": true,
            \"caching_enabled\": false,
            \"allow_websocket_upgrade\": true,
            \"access_list_id\": 0
        }" > /dev/null

    # Proxy Host für Vaultwarden
    log "  → Erstelle Proxy Host: $VAULT_DOMAIN → vaultwarden:80"
    curl -s -X POST http://localhost:81/api/nginx/proxy-hosts \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain_names\": [\"$VAULT_DOMAIN\"],
            \"forward_scheme\": \"http\",
            \"forward_host\": \"vaultwarden\",
            \"forward_port\": 80,
            \"certificate_id\": 0,
            \"ssl_forced\": false,
            \"http2_support\": true,
            \"block_exploits\": true,
            \"caching_enabled\": false,
            \"allow_websocket_upgrade\": true,
            \"access_list_id\": 0
        }" > /dev/null

    # Proxy Host für Keycloak
    log "  → Erstelle Proxy Host: $SSO_DOMAIN → keycloak:8080"
    curl -s -X POST http://localhost:81/api/nginx/proxy-hosts \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain_names\": [\"$SSO_DOMAIN\"],
            \"forward_scheme\": \"http\",
            \"forward_host\": \"keycloak\",
            \"forward_port\": 8080,
            \"certificate_id\": 0,
            \"ssl_forced\": false,
            \"http2_support\": true,
            \"block_exploits\": true,
            \"caching_enabled\": false,
            \"allow_websocket_upgrade\": true,
            \"access_list_id\": 0
        }" > /dev/null

    log "✓ NPM Proxy Hosts erstellt"
    log "✓ NPM Konfiguration abgeschlossen"
    log ""
    log "NPM Login: http://$(hostname -I | awk '{print $1}'):81"
    log "  E-Mail:   $admin_email"
    log "  Passwort: <siehe /opt/eigendaten/config.env>"
}

#===============================================================================
# Zusammenfassung
#===============================================================================
show_summary() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}              POST-INSTALLATION ABGESCHLOSSEN                  ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Was wurde konfiguriert:${NC}"
    echo ""
    echo "  ✓ NPM Proxy Hosts automatisch angelegt"
    echo "  ✓ Nextcloud trusted_proxies per OCC gesetzt"
    echo "  ✓ Keycloak openid Scope erstellt"
    echo "  ✓ Benutzer in Keycloak angelegt (falls USERS gesetzt)"
    echo ""
    echo -e "${YELLOW}Nächste Schritte:${NC}"
    echo ""

    # NPM Admin-Daten aus config.env laden
    local admin_email="${ADMIN_EMAIL:-admin@example.com}"
    local npm_admin_pass="${NPM_ADMIN_PASS:-changeme}"

    echo "  1. NPM öffnen: http://$(hostname -I | awk '{print $1}'):81"
    echo "     Login: $admin_email / $npm_admin_pass"
    echo "     (Passwort in /opt/eigendaten/config.env)"
    echo ""
    echo "  2. Für jeden Proxy Host SSL-Zertifikat aktivieren:"
    echo "     • Proxy Hosts → Edit → SSL Tab"
    echo "     • ✓ Request a new SSL Certificate (Let's Encrypt)"
    echo "     • ✓ Force SSL aktivieren"
    echo "     • ✓ HTTP/2 Support aktivieren"
    echo "     Wiederhole für alle 4 Domains:"
    if [[ -n "${CLOUD_DOMAIN:-}" ]]; then
        echo "       - $CLOUD_DOMAIN"
        echo "       - $DOCS_DOMAIN"
        echo "       - $VAULT_DOMAIN"
        echo "       - $SSO_DOMAIN"
    else
        echo "       - cloud.$DOMAIN"
        echo "       - docs.$DOMAIN"
        echo "       - vault.$DOMAIN"
        echo "       - sso.$DOMAIN"
    fi
    echo ""
    echo "  3. Benutzer-Zugangsdaten abrufen:"
    echo "     cat /opt/eigendaten/user-credentials.txt"
    echo ""
    echo "  4. Optional: NPM Admin-Passwort ändern"
    echo "     (User Settings → Change Password)"
    echo ""
    echo "  5. Für SSO-Konfiguration (Nextcloud ↔ Keycloak):"
    echo "     cd /opt/eigendaten && ./04-sso-setup.sh"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║          Eigendaten - Post-Installation v4.0                      ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    npm_auto_configure
    nextcloud_post_install
    paperless_post_install
    keycloak_post_install
    create_users
    show_summary
}

main "$@"

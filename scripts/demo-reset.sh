#!/bin/bash
#===============================================================================
# Eigendaten Demo-System - Reset Script
#
# Setzt alle Demo-Benutzerdaten zurueck, generiert neue Passwoerter
# und erzeugt Zugangskarten als HTML.
#
# Admin-Zugriffe bleiben UNANGETASTET:
#   - Keycloak: admin-permanent
#   - Nextcloud: admin
#   - Mailcow: admin
#   - Paperless: admin (nur Passwort wird auf neues Universal-PW gesetzt)
#
# Aufruf: sudo ./demo-reset.sh [--yes]
#
# Konfiguration: Passe die Variablen im Abschnitt "Konfiguration" an.
#
# Version: 1.0 (Januar 2026)
#===============================================================================

set -euo pipefail

#===============================================================================
# Konfiguration - ANPASSEN!
#===============================================================================

# Server-IPs
APP_SERVER_IP="${APP_SERVER_IP:-DEINE_APP_SERVER_IP}"
MAIL_SERVER_IP="${MAIL_SERVER_IP:-DEINE_MAIL_SERVER_IP}"
PAPERLESS_SERVER_IP="${PAPERLESS_SERVER_IP:-DEINE_PAPERLESS_SERVER_IP}"

# Domain
DOMAIN="${DOMAIN:-example.de}"

# SSH-Key fuer Remote-Server
SSH_KEY="${SSH_KEY:-/root/.ssh/eigendaten-key}"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Verzeichnisse
SCRIPT_DIR="${SCRIPT_DIR:-/opt/demo-reset}"
TEMPLATE_FILE="${SCRIPT_DIR}/zugangskarten-template.html"
LOG_FILE="${SCRIPT_DIR}/reset-log.txt"

# Keycloak
KC_REALM="${KC_REALM:-eigendaten}"
KC_ADMIN="${KC_ADMIN:-admin-permanent}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:?KC_ADMIN_PASS muss gesetzt sein!}"

# Mailcow API (wird automatisch gelesen)
MAILCOW_API_KEY=""

# Benachrichtigung
NOTIFY_EMAIL="${NOTIFY_EMAIL:-admin@example.de}"
NOREPLY_USER="noreply@${DOMAIN}"

# Nextcloud-Upload
NC_ADMIN_USER="${NC_ADMIN_USER:-admin}"
NC_UPLOAD_DIR="${NC_UPLOAD_DIR:-Demo-Reset}"

# Keycloak Client fuer Verifikation
KC_CLIENT_ID="${KC_CLIENT_ID:-nextcloud}"

# Demo-Benutzer (username:displayname:email:department:jobtitle)
# ANPASSEN an dein Setup!
DEMO_USERS=(
    "gf-leiter:Max Leiter:gf@${DOMAIN}:Geschaeftsfuehrung:Geschaeftsfuehrer"
    "buchhaltung:Claudia Konto:buchhaltung@${DOMAIN}:Buchhaltung:Buchhalterin"
    "hr-personal:Anna Personal:hr@${DOMAIN}:Personal:HR-Managerin"
    "technik:Peter Monteur:technik@${DOMAIN}:Technik:Techniker"
    "azubi:Lena Lehrling:azubi@${DOMAIN}:Technik:Auszubildende"
)

# Mail-Postfaecher die geleert werden (NICHT noreply@)
MAIL_USERS=(
    "admin@${DOMAIN}"
    "buchhaltung@${DOMAIN}"
    "hr@${DOMAIN}"
    "info@${DOMAIN}"
    "rechnung@${DOMAIN}"
    "gf@${DOMAIN}"
)

# URLs
CLOUD_URL="https://cloud.${DOMAIN}"
SSO_URL="https://sso.${DOMAIN}"
VAULT_URL="https://vault.${DOMAIN}"
MAIL_URL="https://mail.${DOMAIN}"
PAPERLESS_URL="https://paperless.${DOMAIN}"
MAIL_HOST="mail.${DOMAIN}"

#===============================================================================
# Farben & Hilfsfunktionen
#===============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[FEHLER]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
step()    { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"; }
fail()    { echo -e "${RED}[FEHLER]${NC} $1"; exit 1; }

log_to_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

banner() {
    echo -e "${BLUE}"
    echo "======================================================================"
    echo "         EIGENDATEN - Demo-System Reset                              "
    echo "======================================================================"
    echo -e "${NC}"
    echo "  Domain:     ${DOMAIN}"
    echo "  App-Server: ${APP_SERVER_IP}"
    echo "  Mail:       ${MAIL_SERVER_IP}"
    echo "  Paperless:  ${PAPERLESS_SERVER_IP}"
    echo ""
}

#===============================================================================
# Voraussetzungen pruefen
#===============================================================================
check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then
        fail "Dieses Script muss als root ausgefuehrt werden!"
    fi

    if [[ ! -f "$SSH_KEY" ]]; then
        fail "SSH-Key nicht gefunden: $SSH_KEY"
    fi

    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        warn "Zugangskarten-Template nicht gefunden: $TEMPLATE_FILE"
        warn "Zugangskarten werden nicht generiert."
    fi

    if ! docker info &>/dev/null; then
        fail "Docker ist nicht erreichbar!"
    fi

    if ! docker ps --format '{{.Names}}' | grep -q '^keycloak$'; then
        fail "Keycloak-Container laeuft nicht!"
    fi

    if ! docker ps --format '{{.Names}}' | grep -q '^nextcloud$'; then
        fail "Nextcloud-Container laeuft nicht!"
    fi

    if ! ssh ${SSH_OPTS} root@${MAIL_SERVER_IP} "echo ok" &>/dev/null; then
        fail "SSH zu Mail-Server (${MAIL_SERVER_IP}) fehlgeschlagen!"
    fi

    if ! ssh ${SSH_OPTS} root@${PAPERLESS_SERVER_IP} "echo ok" &>/dev/null; then
        fail "SSH zu Paperless-Server (${PAPERLESS_SERVER_IP}) fehlgeschlagen!"
    fi

    log "Alle Voraussetzungen erfuellt"
}

#===============================================================================
# SCHRITT 1: Bestaetigung
#===============================================================================
confirm_reset() {
    step "Schritt 1: Bestaetigung"

    if [[ "${1:-}" == "--yes" ]]; then
        warn "Automatische Bestaetigung (--yes)"
        return 0
    fi

    echo -e "${RED}${BOLD}"
    echo "  WARNUNG: Alle Demo-Benutzerdaten werden UNWIDERRUFLICH geloescht!"
    echo ""
    echo "  Betroffen:"
    echo "    - Keycloak: Passwoerter aller Demo-Benutzer"
    echo "    - Nextcloud: Alle Benutzerdateien"
    echo "    - Mailcow: Alle E-Mails"
    echo "    - Paperless: Alle Dokumente"
    echo "    - Vaultwarden: Alle Benutzer-Vaults"
    echo ""
    echo "  NICHT betroffen:"
    echo "    - Admin-Accounts"
    echo "    - SSO-Konfiguration"
    echo "    - Docker-Container"
    echo "    - SSL-Zertifikate"
    echo -e "${NC}"

    read -p "Fortfahren? (ja/NEIN): " CONFIRM
    if [[ "$CONFIRM" != "ja" ]]; then
        echo "Abgebrochen."
        exit 0
    fi
}

#===============================================================================
# SCHRITT 2: Neues Universal-Passwort generieren
#===============================================================================
generate_password() {
    step "Schritt 2: Neues Passwort generieren"

    local RANDOM_PART
    RANDOM_PART=$(openssl rand -base64 6 | tr -dc 'a-zA-Z0-9' | head -c 4)
    NEW_PASSWORD="Eigendaten@${RANDOM_PART}"

    log "Neues Universal-Passwort generiert: ${NEW_PASSWORD}"
    log_to_file "Neues Passwort generiert: ${NEW_PASSWORD}"
}

#===============================================================================
# SCHRITT 3: Keycloak - Passwoerter zuruecksetzen
#===============================================================================
reset_keycloak() {
    step "Schritt 3: Keycloak - Passwoerter zuruecksetzen"

    info "Keycloak Admin-Login..."
    docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
        --server http://localhost:8080 \
        --realm master \
        --user "$KC_ADMIN" \
        --password "$KC_ADMIN_PASS" || fail "Keycloak-Login fehlgeschlagen!"

    log "Keycloak-Login erfolgreich"

    for user_data in "${DEMO_USERS[@]}"; do
        IFS=':' read -r username displayname email department jobtitle <<< "$user_data"
        info "Setze Passwort fuer: ${username} (${displayname})"

        docker exec keycloak /opt/keycloak/bin/kcadm.sh set-password \
            -r "$KC_REALM" \
            --username "$username" \
            --new-password "$NEW_PASSWORD" 2>/dev/null

        if [[ $? -eq 0 ]]; then
            log "  ${username}: Passwort gesetzt"
        else
            error "  ${username}: Passwort setzen fehlgeschlagen!"
        fi
    done

    log_to_file "Keycloak: Alle Demo-User Passwoerter zurueckgesetzt"
}

#===============================================================================
# SCHRITT 4: Nextcloud - Benutzerdateien loeschen
#===============================================================================
reset_nextcloud() {
    step "Schritt 4: Nextcloud - Benutzerdateien loeschen"

    # NC-Benutzernamen aus DEMO_USERS ableiten
    for user_data in "${DEMO_USERS[@]}"; do
        IFS=':' read -r username _ _ _ _ <<< "$user_data"
        local user_dir="/var/www/html/data/${username}/files"

        info "Loesche Dateien fuer: ${username}"

        docker exec nextcloud bash -c "
            if [ -d '${user_dir}' ]; then
                rm -rf '${user_dir:?}'/*
                echo 'Dateien geloescht: ${username}'
            else
                echo 'Verzeichnis nicht gefunden: ${user_dir}'
            fi
        " 2>/dev/null || warn "  ${username}: Dateien loeschen fehlgeschlagen"
    done

    info "Papierkorb leeren..."
    docker exec -u www-data nextcloud php occ trashbin:cleanup --all-users 2>/dev/null || warn "Trashbin cleanup fehlgeschlagen"

    info "Versionen leeren..."
    docker exec -u www-data nextcloud php occ versions:cleanup 2>/dev/null || warn "Versions cleanup fehlgeschlagen"

    info "Dateien-Scan..."
    docker exec -u www-data nextcloud php occ files:scan --all 2>/dev/null || warn "Files scan fehlgeschlagen"

    log "Nextcloud-Daten zurueckgesetzt"
    log_to_file "Nextcloud: Alle Benutzerdateien geloescht"
}

#===============================================================================
# SCHRITT 5: Mailcow - Postfaecher leeren
#===============================================================================
reset_mailcow() {
    step "Schritt 5: Mailcow - Postfaecher leeren"

    info "Verbinde zu Mail-Server ${MAIL_SERVER_IP}..."

    for mail_user in "${MAIL_USERS[@]}"; do
        info "Loesche E-Mails: ${mail_user}"

        ssh ${SSH_OPTS} root@${MAIL_SERVER_IP} \
            "docker exec \$(docker ps -qf name=dovecot-mailcow) doveadm expunge -u '${mail_user}' mailbox '*' all" \
            2>/dev/null || warn "  ${mail_user}: Loeschen fehlgeschlagen"

        log "  ${mail_user}: E-Mails geloescht"
    done

    info "Lese Mailcow API-Key..."
    MAILCOW_API_KEY=$(ssh ${SSH_OPTS} root@${MAIL_SERVER_IP} \
        "grep '^API_KEY=' /opt/mailcow-dockerized/mailcow.conf | cut -d'=' -f2" 2>/dev/null) || true

    if [[ -n "$MAILCOW_API_KEY" ]]; then
        info "Setze Postfach-Passwoerter ueber Mailcow-API..."

        for mail_user in "${MAIL_USERS[@]}"; do
            ssh ${SSH_OPTS} root@${MAIL_SERVER_IP} "
                curl -s -k -X POST 'https://mail.${DOMAIN}/api/v1/edit/mailbox' \
                    -H 'Content-Type: application/json' \
                    -H 'X-API-Key: ${MAILCOW_API_KEY}' \
                    -d '{\"items\":[\"${mail_user}\"],\"attr\":{\"password\":\"${NEW_PASSWORD}\",\"password2\":\"${NEW_PASSWORD}\"}}'
            " 2>/dev/null || warn "  ${mail_user}: Passwort-Reset fehlgeschlagen"
        done

        # Auch noreply@-Postfach Passwort setzen (fuer E-Mail-Versand in Schritt 10)
        info "Setze noreply@-Passwort..."
        ssh ${SSH_OPTS} root@${MAIL_SERVER_IP} "
            curl -s -k -X POST 'https://mail.${DOMAIN}/api/v1/edit/mailbox' \
                -H 'Content-Type: application/json' \
                -H 'X-API-Key: ${MAILCOW_API_KEY}' \
                -d '{\"items\":[\"${NOREPLY_USER}\"],\"attr\":{\"password\":\"${NEW_PASSWORD}\",\"password2\":\"${NEW_PASSWORD}\"}}'
        " 2>/dev/null || warn "  noreply@: Passwort-Reset fehlgeschlagen"
        log "noreply@-Passwort gesetzt"

        log "Postfach-Passwoerter zurueckgesetzt"

        # authsource auf 'mailcow' setzen (verhindert Keycloak-REST-Auth-Fehler bei mailpassword_flow=0)
        info "Setze authsource=mailcow fuer alle Demo-Postfaecher..."
        local MAIL_USERS_SQL=""
        for mail_user in "${MAIL_USERS[@]}"; do
            if [[ -n "$MAIL_USERS_SQL" ]]; then
                MAIL_USERS_SQL+=","
            fi
            MAIL_USERS_SQL+="'${mail_user}'"
        done
        MAIL_USERS_SQL+=",'${NOREPLY_USER}'"
        ssh ${SSH_OPTS} root@${MAIL_SERVER_IP} "
            cd /opt/mailcow-dockerized && docker compose exec -T mysql-mailcow mysql -umailcow -p\$(grep DBPASS mailcow.conf | cut -d= -f2) -e \"UPDATE mailcow.mailbox SET authsource='mailcow' WHERE username IN (${MAIL_USERS_SQL});\"
        " 2>/dev/null || warn "authsource Update fehlgeschlagen"
        log "authsource=mailcow fuer alle Postfaecher gesetzt"

        # Dovecot Auth-Cache leeren
        info "Leere Dovecot Auth-Cache..."
        ssh ${SSH_OPTS} root@${MAIL_SERVER_IP} "
            cd /opt/mailcow-dockerized && docker compose exec -T dovecot-mailcow /usr/bin/doveadm auth cache flush
        " 2>/dev/null || warn "Auth-Cache flush fehlgeschlagen"
        log "Dovecot Auth-Cache geleert"
    else
        warn "Mailcow API-Key nicht gefunden. Passwoerter manuell setzen."
    fi

    log_to_file "Mailcow: Postfaecher geleert, Passwoerter zurueckgesetzt, authsource=mailcow"
}

#===============================================================================
# SCHRITT 6: Paperless - Dokumente loeschen
#===============================================================================
reset_paperless() {
    step "Schritt 6: Paperless - Dokumente loeschen"

    info "Verbinde zu Paperless-Server ${PAPERLESS_SERVER_IP}..."

    info "Loesche alle Dokumente..."
    ssh ${SSH_OPTS} root@${PAPERLESS_SERVER_IP} "
        docker exec \$(docker ps -qf name=paperless-webserver) python3 manage.py shell -c \"
from documents.models import Document
Document.objects.all().delete()
print('Alle Dokumente geloescht')
\"
    " 2>/dev/null || warn "Dokumente loeschen fehlgeschlagen"

    info "Leere Media-Ordner..."
    ssh ${SSH_OPTS} root@${PAPERLESS_SERVER_IP} "
        PAPERLESS_CONTAINER=\$(docker ps -qf name=paperless-webserver)
        docker exec \${PAPERLESS_CONTAINER} bash -c '
            rm -rf /usr/src/paperless/media/documents/originals/*
            rm -rf /usr/src/paperless/media/documents/thumbnails/*
            rm -rf /usr/src/paperless/media/documents/archive/*
            rm -rf /usr/src/paperless/export/*
        '
    " 2>/dev/null || warn "Media-Ordner leeren fehlgeschlagen"

    info "Setze Paperless Admin-Passwort..."
    ssh ${SSH_OPTS} root@${PAPERLESS_SERVER_IP} "
        docker exec \$(docker ps -qf name=paperless-webserver) python3 manage.py shell -c \"
from django.contrib.auth.models import User
u = User.objects.get(username='admin')
u.set_password('${NEW_PASSWORD}')
u.save()
print('Admin-Passwort geaendert')
\"
    " 2>/dev/null || warn "Paperless Admin-Passwort Reset fehlgeschlagen"

    log "Paperless zurueckgesetzt"
    log_to_file "Paperless: Dokumente geloescht, Admin-Passwort zurueckgesetzt"
}

#===============================================================================
# SCHRITT 7: Vaultwarden - Benutzer-Vaults loeschen
#===============================================================================
reset_vaultwarden() {
    step "Schritt 7: Vaultwarden - Benutzer-Vaults loeschen"

    info "Loesche Vaultwarden-Benutzerkonten..."

    docker exec vaultwarden bash -c "
        if [ -f /data/db.sqlite3 ]; then
            sqlite3 /data/db.sqlite3 '
                DELETE FROM ciphers;
                DELETE FROM folders;
                DELETE FROM folders_ciphers;
                DELETE FROM attachments;
                DELETE FROM sends;
                DELETE FROM emergency_access;
                DELETE FROM twofactor;
                DELETE FROM invitations;
                DELETE FROM users;
                VACUUM;
            '
            echo 'Vaultwarden-Datenbank bereinigt'
        else
            echo 'Vaultwarden DB nicht gefunden'
        fi
    " 2>/dev/null || warn "Vaultwarden DB-Bereinigung fehlgeschlagen"

    log "Vaultwarden zurueckgesetzt"
    log_to_file "Vaultwarden: Alle User-Daten geloescht"
}

#===============================================================================
# SCHRITT 8: Zugangskarten generieren
#===============================================================================
generate_zugangskarten() {
    step "Schritt 8: Zugangskarten generieren"

    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        warn "Template nicht gefunden, ueberspringe Zugangskarten."
        return 0
    fi

    local DATUM
    DATUM=$(date '+%Y-%m-%d')
    local ABLAUF
    ABLAUF=$(date -d "+7 days" '+%Y-%m-%d' 2>/dev/null || date -v+7d '+%Y-%m-%d' 2>/dev/null || echo "in 7 Tagen")
    local OUTPUT_FILE="${SCRIPT_DIR}/zugangskarten-${DATUM}.html"

    info "Generiere Zugangskarten..."

    local TEMPLATE
    TEMPLATE=$(cat "$TEMPLATE_FILE")

    local ALL_CARDS=""
    for user_data in "${DEMO_USERS[@]}"; do
        IFS=':' read -r username displayname email department jobtitle <<< "$user_data"

        local CARD
        CARD=$(echo "$TEMPLATE" | sed -n '/%%CARDS_START%%/,/%%CARDS_END%%/p' | grep -v '%%CARDS_START%%\|%%CARDS_END%%')

        CARD=$(echo "$CARD" | sed \
            -e "s|%%USER_DISPLAYNAME%%|${displayname}|g" \
            -e "s|%%USER_USERNAME%%|${username}|g" \
            -e "s|%%USER_EMAIL%%|${email}|g" \
            -e "s|%%USER_DEPARTMENT%%|${department}|g" \
            -e "s|%%USER_JOBTITLE%%|${jobtitle}|g" \
            -e "s|%%PASSWORD%%|${NEW_PASSWORD}|g" \
            -e "s|%%CLOUD_URL%%|${CLOUD_URL}|g" \
            -e "s|%%SSO_URL%%|${SSO_URL}|g" \
            -e "s|%%VAULT_URL%%|${VAULT_URL}|g" \
            -e "s|%%MAIL_URL%%|${MAIL_URL}|g" \
            -e "s|%%PAPERLESS_URL%%|${PAPERLESS_URL}|g" \
            -e "s|%%MAIL_HOST%%|${MAIL_HOST}|g" \
            -e "s|%%DOMAIN%%|${DOMAIN}|g" \
            -e "s|%%DATUM%%|${DATUM}|g" \
            -e "s|%%ABLAUF%%|${ABLAUF}|g"
        )

        ALL_CARDS+="${CARD}"
    done

    local HEADER
    HEADER=$(echo "$TEMPLATE" | sed -n '1,/%%CARDS_START%%/p' | grep -v '%%CARDS_START%%')
    HEADER=$(echo "$HEADER" | sed -e "s|%%DATUM%%|${DATUM}|g" -e "s|%%ABLAUF%%|${ABLAUF}|g")

    local FOOTER
    FOOTER=$(echo "$TEMPLATE" | sed -n '/%%CARDS_END%%/,$ p' | grep -v '%%CARDS_END%%')

    echo "${HEADER}${ALL_CARDS}${FOOTER}" > "$OUTPUT_FILE"

    log "Zugangskarten (HTML) generiert: ${OUTPUT_FILE}"

    # Markdown-Version generieren (lesbar in Nextcloud)
    local MD_FILE="${SCRIPT_DIR}/zugangskarten-${DATUM}.md"
    info "Generiere Markdown-Zugangskarten..."

    {
        echo "# Eigendaten Office Cloud - Demo-Zugangskarten"
        echo ""
        echo "**Erstellt am:** ${DATUM} | **Gueltig bis:** ${ABLAUF}"
        echo ""
        echo "> **Dieses Dokument enthaelt vertrauliche Zugangsdaten. Bitte sicher aufbewahren!**"
        echo ""
        echo "---"
        echo ""
        echo "## Universal-Passwort (alle Dienste)"
        echo ""
        echo '```'
        echo "${NEW_PASSWORD}"
        echo '```'
        echo ""
        echo "---"
        echo ""
        echo "## Dienste-Uebersicht"
        echo ""
        echo "| Dienst | URL | Anmeldung |"
        echo "|--------|-----|-----------|"
        echo "| **Nextcloud** (Dateien, Kalender, Kontakte) | ${CLOUD_URL} | \"Login with Keycloak\" |"
        echo "| **Keycloak** (Single Sign-On, Profil) | ${SSO_URL} | Benutzername + Passwort |"
        echo "| **Vaultwarden** (Passwort-Manager) | ${VAULT_URL}/#/sso | SSO-Login |"
        echo "| **Webmail** (E-Mail im Browser) | ${MAIL_URL} | E-Mail-Adresse + Passwort |"
        echo "| **Paperless** (Dokumentenverwaltung) | ${PAPERLESS_URL} | \"Keycloak SSO\" |"
        echo ""

        local USER_NUM=0
        for user_data in "${DEMO_USERS[@]}"; do
            USER_NUM=$((USER_NUM + 1))
            IFS=':' read -r username displayname email department jobtitle <<< "$user_data"

            echo "---"
            echo ""
            echo "## Benutzer ${USER_NUM}: ${displayname}"
            echo ""
            echo "| | |"
            echo "|---|---|"
            echo "| **Benutzername** | \`${username}\` |"
            echo "| **E-Mail** | ${email} |"
            echo "| **Abteilung** | ${department} |"
            echo "| **Position** | ${jobtitle} |"
            echo "| **Passwort** | \`${NEW_PASSWORD}\` |"
            echo ""
            echo "### E-Mail-Konfiguration"
            echo ""
            echo "| Einstellung | Wert |"
            echo "|-------------|------|"
            echo "| E-Mail-Adresse | \`${email}\` |"
            echo "| Passwort | \`${NEW_PASSWORD}\` |"
            echo "| Posteingangsserver (IMAP) | \`${MAIL_HOST}\` |"
            echo "| IMAP Port | 993 (SSL/TLS) |"
            echo "| Postausgangsserver (SMTP) | \`${MAIL_HOST}\` |"
            echo "| SMTP Port | 465 (SSL/TLS) |"
            echo "| Authentifizierung | Normales Passwort |"
            echo ""
        done

        echo "---"
        echo ""
        echo "*Eigendaten Office Cloud Suite | ${DOMAIN} | Erstellt am ${DATUM} | EHMV GmbH*"
    } > "$MD_FILE"

    log "Zugangskarten (Markdown) generiert: ${MD_FILE}"
    log_to_file "Zugangskarten HTML: ${OUTPUT_FILE}"
    log_to_file "Zugangskarten MD: ${MD_FILE}"
}

#===============================================================================
# SCHRITT 9: Verifikation
#===============================================================================
verify_all() {
    step "Schritt 9: Automatische Verifikation"

    local DATUM
    DATUM=$(date '+%Y-%m-%d')
    local ZEIT
    ZEIT=$(date '+%Y-%m-%d %H:%M:%S')
    local ABLAUF
    ABLAUF=$(date -d "+7 days" '+%Y-%m-%d' 2>/dev/null || date -v+7d '+%Y-%m-%d' 2>/dev/null || echo "in 7 Tagen")
    VERIFY_LOG="${SCRIPT_DIR}/verify-${DATUM}.log"

    local PASS_COUNT=0
    local FAIL_COUNT=0
    local TOTAL_COUNT=0

    _test_ok() {
        PASS_COUNT=$((PASS_COUNT + 1))
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        echo "[OK]   $1" >> "$VERIFY_LOG"
        log "  $1"
    }
    _test_fail() {
        FAIL_COUNT=$((FAIL_COUNT + 1))
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        echo "[FAIL] $1" >> "$VERIFY_LOG"
        error "  $1"
    }

    {
        echo "=== EIGENDATEN DEMO-RESET VERIFIKATION ==="
        echo "Datum: ${ZEIT}"
        echo "Passwort: ${NEW_PASSWORD} (gueltig bis ${ABLAUF})"
        echo ""
    } > "$VERIFY_LOG"

    # --- Test 1: Keycloak SSO ---
    echo "--- Keycloak SSO ---" >> "$VERIFY_LOG"
    info "Teste Keycloak SSO..."

    local KC_CLIENT_SECRET=""
    KC_CLIENT_SECRET=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients \
        -r "$KC_REALM" \
        -q "clientId=${KC_CLIENT_ID}" \
        --fields secret 2>/dev/null | grep -oP '"secret"\s*:\s*"\K[^"]+' 2>/dev/null) || true

    if [[ -z "$KC_CLIENT_SECRET" ]]; then
        warn "Keycloak client_secret konnte nicht gelesen werden. Ueberspringe SSO-Tests."
        echo "[SKIP] Keycloak SSO: client_secret nicht verfuegbar" >> "$VERIFY_LOG"
    else
        for user_data in "${DEMO_USERS[@]}"; do
            IFS=':' read -r username _ _ _ _ <<< "$user_data"

            local HTTP_CODE
            HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -k \
                -X POST "https://sso.${DOMAIN}/realms/${KC_REALM}/protocol/openid-connect/token" \
                -d "grant_type=password" \
                -d "client_id=${KC_CLIENT_ID}" \
                -d "client_secret=${KC_CLIENT_SECRET}" \
                -d "username=${username}" \
                -d "password=${NEW_PASSWORD}" \
                2>/dev/null) || HTTP_CODE="000"

            if [[ "$HTTP_CODE" == "200" ]]; then
                _test_ok "${username}"
            else
                _test_fail "${username} (HTTP ${HTTP_CODE})"
            fi
        done
    fi

    echo "" >> "$VERIFY_LOG"

    # --- Test 2: Mailcow IMAP Auth ---
    echo "--- Mailcow IMAP ---" >> "$VERIFY_LOG"
    info "Teste Mailcow IMAP-Authentifizierung..."

    for mail_user in "${MAIL_USERS[@]}"; do
        local AUTH_RESULT
        AUTH_RESULT=$(ssh ${SSH_OPTS} root@${MAIL_SERVER_IP} "
            cd /opt/mailcow-dockerized && docker compose exec -T nginx-mailcow curl -s -k \
                -X POST 'https://localhost:9082' \
                -H 'Content-Type: application/json' \
                -d '{\"username\":\"${mail_user}\",\"password\":\"${NEW_PASSWORD}\",\"real_rip\":\"127.0.0.1\",\"service\":\"imap\"}'
        " 2>/dev/null) || AUTH_RESULT="{}"

        if echo "$AUTH_RESULT" | grep -q '"success":true'; then
            _test_ok "${mail_user}"
        else
            _test_fail "${mail_user}"
        fi
    done

    echo "" >> "$VERIFY_LOG"

    # --- Test 3-6: Dienste erreichbar ---
    echo "--- Dienste ---" >> "$VERIFY_LOG"
    info "Teste Dienst-Erreichbarkeit..."

    local NC_STATUS
    NC_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -k "${CLOUD_URL}/status.php" 2>/dev/null) || NC_STATUS="000"
    if [[ "$NC_STATUS" == "200" ]]; then
        _test_ok "Nextcloud (cloud.${DOMAIN})"
    else
        _test_fail "Nextcloud (cloud.${DOMAIN}) (HTTP ${NC_STATUS})"
    fi

    local VW_STATUS
    VW_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -k "${VAULT_URL}/alive" 2>/dev/null) || VW_STATUS="000"
    if [[ "$VW_STATUS" == "200" ]]; then
        _test_ok "Vaultwarden (vault.${DOMAIN})"
    else
        _test_fail "Vaultwarden (vault.${DOMAIN}) (HTTP ${VW_STATUS})"
    fi

    local MAIL_STATUS
    MAIL_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -k "${MAIL_URL}" 2>/dev/null) || MAIL_STATUS="000"
    if [[ "$MAIL_STATUS" == "200" || "$MAIL_STATUS" == "301" || "$MAIL_STATUS" == "302" ]]; then
        _test_ok "Webmail (mail.${DOMAIN})"
    else
        _test_fail "Webmail (mail.${DOMAIN}) (HTTP ${MAIL_STATUS})"
    fi

    local PL_STATUS
    PL_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -k "${PAPERLESS_URL}" 2>/dev/null) || PL_STATUS="000"
    if [[ "$PL_STATUS" == "200" || "$PL_STATUS" == "301" || "$PL_STATUS" == "302" ]]; then
        _test_ok "Paperless (paperless.${DOMAIN})"
    else
        _test_fail "Paperless (paperless.${DOMAIN}) (HTTP ${PL_STATUS})"
    fi

    echo "" >> "$VERIFY_LOG"
    echo "Ergebnis: ${PASS_COUNT}/${TOTAL_COUNT} Tests bestanden" >> "$VERIFY_LOG"

    if [[ $FAIL_COUNT -eq 0 ]]; then
        log "Verifikation: ${PASS_COUNT}/${TOTAL_COUNT} Tests bestanden"
    else
        warn "Verifikation: ${PASS_COUNT}/${TOTAL_COUNT} Tests bestanden, ${FAIL_COUNT} fehlgeschlagen!"
    fi

    log "Verifikationslog: ${VERIFY_LOG}"
    log_to_file "Verifikation: ${PASS_COUNT}/${TOTAL_COUNT} Tests bestanden"
}

#===============================================================================
# SCHRITT 10: Benachrichtigung
#===============================================================================
notify() {
    step "Schritt 10: Benachrichtigung"

    local DATUM
    DATUM=$(date '+%Y-%m-%d')
    local ABLAUF
    ABLAUF=$(date -d "+7 days" '+%Y-%m-%d' 2>/dev/null || date -v+7d '+%Y-%m-%d' 2>/dev/null || echo "in 7 Tagen")

    local HTML_FILE="${SCRIPT_DIR}/zugangskarten-${DATUM}.html"
    local MD_FILE="${SCRIPT_DIR}/zugangskarten-${DATUM}.md"
    local LOG_VERIFY="${VERIFY_LOG:-${SCRIPT_DIR}/verify-${DATUM}.log}"

    # --- E-Mail versenden ---
    info "Sende Benachrichtigung an ${NOTIFY_EMAIL}..."

    local EMAIL_FILE
    EMAIL_FILE=$(mktemp /tmp/demo-reset-email.XXXXXX)

    {
        echo "From: Eigendaten Demo <${NOREPLY_USER}>"
        echo "To: ${NOTIFY_EMAIL}"
        echo "Subject: Eigendaten Demo-Reset ${DATUM} - Passwort: ${NEW_PASSWORD}"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo ""
        echo "Eigendaten Demo-System Reset"
        echo "============================="
        echo ""
        echo "Datum: ${DATUM}"
        echo "Neues Passwort: ${NEW_PASSWORD}"
        echo "Gueltig bis: ${ABLAUF}"
        echo ""
        echo "URLs:"
        echo "  Cloud:     ${CLOUD_URL}"
        echo "  SSO:       ${SSO_URL}"
        echo "  Vault:     ${VAULT_URL}"
        echo "  Mail:      ${MAIL_URL}"
        echo "  Paperless: ${PAPERLESS_URL}"
        echo ""
        echo "Demo-Benutzer:"
        for user_data in "${DEMO_USERS[@]}"; do
            IFS=':' read -r username displayname email _ _ <<< "$user_data"
            echo "  ${displayname} (${username}) - ${email}"
        done
        echo ""
        echo "--- Verifikationslog ---"
        if [[ -f "$LOG_VERIFY" ]]; then
            cat "$LOG_VERIFY"
        else
            echo "(kein Verifikationslog verfuegbar)"
        fi
        echo ""
        echo "---"
        echo "Zugangskarten: Verfuegbar in Nextcloud unter /Demo-Reset/"
        echo "Automatisch generiert von demo-reset.sh"
    } > "$EMAIL_FILE"

    curl --ssl-reqd -s \
        --url "smtps://mail.${DOMAIN}:465" \
        --user "${NOREPLY_USER}:${NEW_PASSWORD}" \
        --mail-from "${NOREPLY_USER}" \
        --mail-rcpt "${NOTIFY_EMAIL}" \
        --upload-file "$EMAIL_FILE" \
        2>/dev/null && log "E-Mail an ${NOTIFY_EMAIL} gesendet" \
        || warn "E-Mail-Versand fehlgeschlagen"

    rm -f "$EMAIL_FILE"

    # --- Nextcloud-Upload ---
    info "Lade Dateien nach Nextcloud hoch..."

    local NC_DATA_DIR="/var/www/html/data/${NC_ADMIN_USER}/files/${NC_UPLOAD_DIR}"

    docker exec nextcloud bash -c "mkdir -p '${NC_DATA_DIR}'" 2>/dev/null || true

    local UPLOAD_COUNT=0
    if [[ -f "$HTML_FILE" ]]; then
        docker cp "$HTML_FILE" "nextcloud:${NC_DATA_DIR}/zugangskarten-${DATUM}.html" 2>/dev/null && UPLOAD_COUNT=$((UPLOAD_COUNT + 1)) || warn "Upload zugangskarten.html fehlgeschlagen"
    fi
    if [[ -f "$MD_FILE" ]]; then
        docker cp "$MD_FILE" "nextcloud:${NC_DATA_DIR}/zugangskarten-${DATUM}.md" 2>/dev/null && UPLOAD_COUNT=$((UPLOAD_COUNT + 1)) || warn "Upload zugangskarten.md fehlgeschlagen"
    fi
    if [[ -f "$LOG_VERIFY" ]]; then
        docker cp "$LOG_VERIFY" "nextcloud:${NC_DATA_DIR}/verify-${DATUM}.log" 2>/dev/null && UPLOAD_COUNT=$((UPLOAD_COUNT + 1)) || warn "Upload verify.log fehlgeschlagen"
    fi

    if [[ $UPLOAD_COUNT -gt 0 ]]; then
        docker exec nextcloud bash -c "chown -R www-data:www-data '${NC_DATA_DIR}'" 2>/dev/null || true
        docker exec -u www-data nextcloud php occ files:scan "${NC_ADMIN_USER}" \
            --path="/${NC_ADMIN_USER}/files/${NC_UPLOAD_DIR}" 2>/dev/null \
            || warn "Nextcloud files:scan fehlgeschlagen"
        log "${UPLOAD_COUNT} Dateien nach Nextcloud hochgeladen (/${NC_UPLOAD_DIR}/)"
    else
        warn "Keine Dateien fuer Nextcloud-Upload vorhanden"
    fi

    log_to_file "Benachrichtigung: E-Mail an ${NOTIFY_EMAIL}, ${UPLOAD_COUNT} Dateien nach Nextcloud"
}

#===============================================================================
# SCHRITT 11: Zusammenfassung
#===============================================================================
show_summary() {
    step "Schritt 11: Zusammenfassung"

    local DATUM
    DATUM=$(date '+%Y-%m-%d')
    local ABLAUF
    ABLAUF=$(date -d "+7 days" '+%Y-%m-%d' 2>/dev/null || date -v+7d '+%Y-%m-%d' 2>/dev/null || echo "in 7 Tagen")

    echo -e "${GREEN}${BOLD}"
    echo "======================================================================"
    echo "         Demo-Reset erfolgreich abgeschlossen!                       "
    echo "======================================================================"
    echo -e "${NC}"
    echo ""
    echo -e "${BOLD}Neues Universal-Passwort:${NC} ${RED}${BOLD}${NEW_PASSWORD}${NC}"
    echo ""
    echo -e "${BOLD}Demo-Benutzer:${NC}"
    for user_data in "${DEMO_USERS[@]}"; do
        IFS=':' read -r username displayname email department jobtitle <<< "$user_data"
        echo "  ${displayname} (${username}) - ${email}"
    done
    echo ""
    echo -e "${BOLD}Dateien:${NC}"
    if [[ -f "${SCRIPT_DIR}/zugangskarten-${DATUM}.html" ]]; then
        echo "  Zugangskarten (HTML): ${SCRIPT_DIR}/zugangskarten-${DATUM}.html"
    fi
    if [[ -f "${SCRIPT_DIR}/zugangskarten-${DATUM}.md" ]]; then
        echo "  Zugangskarten (MD):   ${SCRIPT_DIR}/zugangskarten-${DATUM}.md"
    fi
    if [[ -f "${SCRIPT_DIR}/verify-${DATUM}.log" ]]; then
        echo "  Verifikationslog:     ${SCRIPT_DIR}/verify-${DATUM}.log"
    fi
    echo ""
    echo -e "${BOLD}Gueltig bis:${NC} ${ABLAUF}"
    echo ""
    echo -e "${BOLD}URLs:${NC}"
    echo "  Cloud:     ${CLOUD_URL}"
    echo "  SSO:       ${SSO_URL}"
    echo "  Vault:     ${VAULT_URL}"
    echo "  Mail:      ${MAIL_URL}"
    echo "  Paperless: ${PAPERLESS_URL}"
    echo ""

    log_to_file "Reset abgeschlossen. Passwort: ${NEW_PASSWORD}, Gueltig bis: ${ABLAUF}"
}

#===============================================================================
# HAUPTPROGRAMM
#===============================================================================
main() {
    banner
    mkdir -p "$SCRIPT_DIR"
    check_prerequisites
    confirm_reset "${1:-}"

    log_to_file "Demo-Reset gestartet"

    generate_password
    reset_keycloak
    reset_nextcloud
    reset_mailcow
    reset_paperless
    reset_vaultwarden
    generate_zugangskarten
    verify_all
    notify
    show_summary
}

main "$@"

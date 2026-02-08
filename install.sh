#!/bin/bash
#===============================================================================
# Eigendaten Office Cloud Suite - Master Installer v4.0
#
# Selbst-gehostete Microsoft 365 Alternative:
#   Nextcloud + Paperless-NGX + Keycloak + Vaultwarden + Mailcow
#
# VERWENDUNG:
#
# Option 1: Interaktiv
#   curl -sSL https://raw.githubusercontent.com/percyengler/eigendaten-installer/main/install.sh | sudo bash
#
# Option 2: Mit Environment-Variablen
#   curl -sSL https://raw.githubusercontent.com/percyengler/eigendaten-installer/main/install.sh | \
#     sudo DOMAIN=demo-firma.de SERVER_ROLE=app ADMIN_EMAIL=admin@demo-firma.de bash
#
# Option 3: Mit Benutzern
#   curl -sSL https://raw.githubusercontent.com/percyengler/eigendaten-installer/main/install.sh | \
#     sudo DOMAIN=demo-firma.de SERVER_ROLE=app ADMIN_EMAIL=admin@demo-firma.de \
#     USERS="max:mustermann:m.mustermann@demo-firma.de,anna:schmidt:a.schmidt@demo-firma.de" bash
#
# Option 4: Vollautomatisch (keine Rueckfragen)
#   curl -sSL https://raw.githubusercontent.com/percyengler/eigendaten-installer/main/install.sh | \
#     sudo DOMAIN=demo-firma.de SERVER_ROLE=app ADMIN_EMAIL=admin@demo-firma.de \
#     AUTO_CONFIRM=true bash
#
#===============================================================================

set -euo pipefail

#===============================================================================
# Farben & Design
#===============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Logging mit Zeitstempel
log()   { echo -e "${GREEN}  [$(date '+%H:%M:%S')] ${BOLD}OK${NC}  $1"; }
warn()  { echo -e "${YELLOW}  [$(date '+%H:%M:%S')] !!${NC}  $1"; }
error() { echo -e "${RED}  [$(date '+%H:%M:%S')] XX${NC}  $1"; exit 1; }
info()  { echo -e "${CYAN}  [$(date '+%H:%M:%S')] --${NC}  $1"; }

#===============================================================================
# Design-Helfer
#===============================================================================
phase_header() {
    local step=$1
    local total=$2
    local title=$3
    echo ""
    echo -e "${BLUE}${BOLD}"
    echo "  +----------------------------------------------------------------------+"
    echo "  |  [$step/$total]  $title"
    echo "  +----------------------------------------------------------------------+"
    echo -e "${NC}"
}

spinner() {
    local pid=$1
    local msg="${2:-Bitte warten...}"
    local spin='/-\|'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r  ${DIM}[%s]${NC} %s" "${spin:$i:1}" "$msg"
        sleep 0.2
    done
    printf "\r"
}

progress_bar() {
    local current=$1
    local total=$2
    local width=40
    local pct=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    printf "  ${CYAN}["
    printf "%${filled}s" '' | tr ' ' '#'
    printf "%${empty}s" '' | tr ' ' '-'
    printf "]${NC} %3d%%\r" "$pct"
    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

print_table_row() {
    printf "  ${DIM}|${NC} %-22s ${DIM}|${NC} %-44s ${DIM}|${NC}\n" "$1" "$2"
}

print_table_sep() {
    printf "  ${DIM}+------------------------+----------------------------------------------+${NC}\n"
}

#===============================================================================
# Banner
#===============================================================================
show_banner() {
    echo -e "${BLUE}${BOLD}"
    cat << 'BANNER'

    ███████╗██╗ ██████╗ ███████╗███╗   ██╗██████╗  █████╗ ████████╗███████╗███╗   ██╗
    ██╔════╝██║██╔════╝ ██╔════╝████╗  ██║██╔══██╗██╔══██╗╚══██╔══╝██╔════╝████╗  ██║
    █████╗  ██║██║  ███╗█████╗  ██╔██╗ ██║██║  ██║███████║  ██║   █████╗  ██╔██╗ ██║
    ██╔══╝  ██║██║   ██║██╔══╝  ██║╚██╗██║██║  ██║██╔══██║  ██║   ██╔══╝  ██║╚██╗██║
    ███████╗██║╚██████╔╝███████╗██║ ╚████║██████╔╝██║  ██║  ██║   ███████╗██║ ╚████║
    ╚══════╝╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝╚═════╝ ╚═╝  ╚═╝  ╚═╝   ╚══════╝╚═╝  ╚═══╝

BANNER
    echo -e "${NC}"
    echo -e "  ${CYAN}Office Cloud Suite Installer v4.0${NC}"
    echo -e "  ${DIM}Microsoft 365 Alternative - Self-Hosted${NC}"
    echo -e "  ${DIM}Nextcloud | Paperless-NGX | Keycloak | Vaultwarden | Mailcow${NC}"
    echo ""
    echo -e "  ${DIM}----------------------------------------------------------------------${NC}"
    echo ""
}

# GitHub Repository
REPO_RAW="https://raw.githubusercontent.com/percyengler/eigendaten-installer/main"
INSTALL_DIR="/opt/eigendaten"
CONFIG_FILE="$INSTALL_DIR/config.env"
TOTAL_PHASES=6

#===============================================================================
# [1/6] Systemvoraussetzungen pruefen
#===============================================================================
check_requirements() {
    phase_header 1 $TOTAL_PHASES "Systemvoraussetzungen pruefen"

    # Root-Check
    if [[ "$EUID" -ne 0 ]]; then
        error "Bitte als root ausfuehren: sudo bash"
    fi
    log "Root-Rechte vorhanden"

    # curl installieren falls noetig
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        info "curl wird installiert..."
        apt-get update -qq && apt-get install -y -qq curl
    fi
    log "curl verfuegbar"

    # dig installieren falls noetig (fuer DNS-Check)
    if ! command -v dig &>/dev/null; then
        info "dnsutils wird installiert (fuer DNS-Pruefung)..."
        apt-get update -qq && apt-get install -y -qq dnsutils
    fi
    log "dig verfuegbar (DNS-Pruefung)"

    # OS pruefen
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
            warn "Nur Ubuntu/Debian getestet. Gefunden: $ID $VERSION_ID"
        else
            log "Betriebssystem: $ID $VERSION_ID"
        fi
    fi

    # RAM pruefen
    local ram_mb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $ram_mb -lt 3500 ]]; then
        warn "Weniger als 4 GB RAM ($ram_mb MB) - Einschraenkungen moeglich"
    else
        log "RAM: ${ram_mb} MB"
    fi

    # Disk pruefen
    local disk_gb
    disk_gb=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    if [[ $disk_gb -lt 20 ]]; then
        warn "Weniger als 20 GB freier Speicher (${disk_gb} GB)"
    else
        log "Freier Speicher: ${disk_gb} GB"
    fi
}

#===============================================================================
# [2/6] Konfiguration
#===============================================================================
configure() {
    phase_header 2 $TOTAL_PHASES "Konfiguration"

    # Defaults aus Environment
    DOMAIN="${DOMAIN:-}"
    ADMIN_EMAIL="${ADMIN_EMAIL:-}"
    SERVER_ROLE="${SERVER_ROLE:-}"
    USERS="${USERS:-}"
    AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

    # --- Domain ---
    if [[ -z "$DOMAIN" ]]; then
        echo -e "  ${BOLD}Domain${NC} (z.B. demo-firma.de):"
        read -p "  > " DOMAIN
        [[ -z "$DOMAIN" ]] && error "Domain ist erforderlich!"
    else
        info "Domain: ${BOLD}$DOMAIN${NC} (aus ENV)"
    fi

    # --- Admin E-Mail ---
    if [[ -z "$ADMIN_EMAIL" ]]; then
        echo -e "  ${BOLD}Admin E-Mail${NC} [admin@$DOMAIN]:"
        read -p "  > " ADMIN_EMAIL
        ADMIN_EMAIL="${ADMIN_EMAIL:-admin@$DOMAIN}"
    else
        info "Admin E-Mail: ${BOLD}$ADMIN_EMAIL${NC} (aus ENV)"
    fi

    # --- Server-Rolle ---
    if [[ -z "$SERVER_ROLE" ]]; then
        echo ""
        echo -e "  ${BOLD}Server-Rolle:${NC}"
        echo ""
        echo "    1) app  - App-Server (Nextcloud, Paperless, Keycloak, Vaultwarden)"
        echo "    2) mail - Mail-Server (Mailcow)"
        echo "    3) full - Alles auf einem Server"
        echo ""
        read -p "  Auswahl [1/2/3]: " role_choice
        case "$role_choice" in
            1|app)  SERVER_ROLE="app" ;;
            2|mail) SERVER_ROLE="mail" ;;
            3|full) SERVER_ROLE="full" ;;
            *)      error "Ungueltige Auswahl: $role_choice" ;;
        esac
    else
        info "Server-Rolle: ${BOLD}$SERVER_ROLE${NC} (aus ENV)"
    fi

    # --- Benutzer ---
    if [[ -z "$USERS" && "$AUTO_CONFIRM" != "true" ]]; then
        echo ""
        echo -e "  ${BOLD}Benutzer${NC} (Format: vorname:nachname:email, kommasepariert)"
        echo -e "  ${DIM}Beispiel: max:mustermann:m.mustermann@$DOMAIN,anna:schmidt:a.schmidt@$DOMAIN${NC}"
        echo -e "  ${DIM}Leer lassen = spaeter anlegen${NC}"
        read -p "  > " USERS
    fi

    # Subdomains
    CLOUD_DOMAIN="cloud.$DOMAIN"
    DOCS_DOMAIN="docs.$DOMAIN"
    SSO_DOMAIN="sso.$DOMAIN"
    VAULT_DOMAIN="vault.$DOMAIN"
    MAIL_DOMAIN="mail.$DOMAIN"

    # --- Zusammenfassung ---
    echo ""
    print_table_sep
    print_table_row "Einstellung" "Wert"
    print_table_sep
    print_table_row "Domain" "$DOMAIN"
    print_table_row "Admin E-Mail" "$ADMIN_EMAIL"
    print_table_row "Server-Rolle" "$SERVER_ROLE"
    if [[ -n "$USERS" ]]; then
        local user_count
        user_count=$(echo "$USERS" | tr ',' '\n' | wc -l)
        print_table_row "Benutzer" "${user_count} definiert"
    fi
    print_table_sep
    echo ""

    if [[ "$SERVER_ROLE" != "mail" ]]; then
        echo -e "  ${BOLD}Subdomains die erstellt werden:${NC}"
        echo ""
        echo "    cloud.$DOMAIN   (Nextcloud)"
        echo "    docs.$DOMAIN    (Paperless-NGX)"
        echo "    sso.$DOMAIN     (Keycloak SSO)"
        echo "    vault.$DOMAIN   (Vaultwarden)"
    fi
    if [[ "$SERVER_ROLE" == "mail" || "$SERVER_ROLE" == "full" ]]; then
        echo "    mail.$DOMAIN    (Mailcow)"
    fi
    echo ""

    if [[ "$AUTO_CONFIRM" != "true" ]]; then
        read -p "  Installation starten? [j/N]: " confirm
        [[ "$confirm" != "j" && "$confirm" != "J" ]] && error "Abgebrochen."
    else
        info "AUTO_CONFIRM aktiv - starte automatisch..."
    fi
}

#===============================================================================
# [3/6] DNS-Records pruefen (mit dig)
#===============================================================================
dns_check() {
    phase_header 3 $TOTAL_PHASES "DNS-Eintraege pruefen"

    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    # Alle benoetigten Domains sammeln
    local -a required_domains=()

    if [[ "$SERVER_ROLE" == "app" || "$SERVER_ROLE" == "full" ]]; then
        required_domains+=("$CLOUD_DOMAIN")
        required_domains+=("$DOCS_DOMAIN")
        required_domains+=("$SSO_DOMAIN")
        required_domains+=("$VAULT_DOMAIN")
    fi
    if [[ "$SERVER_ROLE" == "mail" || "$SERVER_ROLE" == "full" ]]; then
        required_domains+=("$MAIL_DOMAIN")
    fi

    # DNS-Records anzeigen die erstellt werden muessen
    echo -e "  ${BOLD}Bitte folgende DNS A-Records bei deinem DNS-Provider erstellen:${NC}"
    echo ""
    print_table_sep
    printf "  ${DIM}|${NC} %-22s ${DIM}|${NC} %-44s ${DIM}|${NC}\n" "Subdomain" "Ziel (A-Record)"
    print_table_sep
    for domain in "${required_domains[@]}"; do
        print_table_row "$domain" "$server_ip"
    done
    if [[ "$SERVER_ROLE" == "mail" || "$SERVER_ROLE" == "full" ]]; then
        print_table_row "@ (MX Record)" "10 $MAIL_DOMAIN"
    fi
    print_table_sep
    echo ""
    echo -e "  ${DIM}Anleitung: Siehe docs/SETUP-GUIDE.md oder README.md${NC}"
    echo ""

    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        info "AUTO_CONFIRM aktiv - ueberspringe DNS-Wartezeit..."
        warn "Stelle sicher, dass DNS-Eintraege korrekt gesetzt sind!"
        return 0
    fi

    # Warten auf Bestaetigung
    while true; do
        echo -e "  ${YELLOW}Hast du die DNS-Eintraege erstellt?${NC}"
        read -p "  [j]a / [p]ruefen / [s]kippen: " dns_choice

        case "$dns_choice" in
            j|J)
                info "DNS bestaetigt - pruefe mit dig..."
                if _check_dns_records "$server_ip" "${required_domains[@]}"; then
                    log "Alle DNS-Eintraege korrekt!"
                    break
                else
                    warn "Einige DNS-Eintraege fehlen noch (siehe oben)"
                    echo -e "  ${DIM}DNS-Propagation kann bis zu 24h dauern.${NC}"
                    echo ""
                    read -p "  Trotzdem fortfahren? [j/N]: " force
                    [[ "$force" == "j" || "$force" == "J" ]] && break
                fi
                ;;
            p|P)
                _check_dns_records "$server_ip" "${required_domains[@]}" || true
                echo ""
                ;;
            s|S)
                warn "DNS-Check uebersprungen - SSL-Zertifikate koennten fehlschlagen!"
                break
                ;;
            *)
                echo "  Bitte j, p oder s eingeben."
                ;;
        esac
    done
}

_check_dns_records() {
    local expected_ip=$1
    shift
    local domains=("$@")
    local all_ok=true

    echo ""
    for domain in "${domains[@]}"; do
        local resolved_ip
        resolved_ip=$(dig +short "$domain" A 2>/dev/null | head -1)

        if [[ "$resolved_ip" == "$expected_ip" ]]; then
            echo -e "  ${GREEN}OK${NC}  $domain -> $resolved_ip"
        elif [[ -n "$resolved_ip" ]]; then
            echo -e "  ${YELLOW}!!${NC}  $domain -> $resolved_ip (erwartet: $expected_ip)"
            all_ok=false
        else
            echo -e "  ${RED}XX${NC}  $domain -> (nicht aufgeloest)"
            all_ok=false
        fi
    done
    echo ""

    $all_ok
}

#===============================================================================
# [4/6] Scripte herunterladen & Konfiguration speichern
#===============================================================================
download_and_configure() {
    phase_header 4 $TOTAL_PHASES "Scripte herunterladen & konfigurieren"

    # Verzeichnis erstellen
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # Scripte herunterladen
    local scripts=(
        "00-base-setup.sh"
        "01-app-server.sh"
        "02-mail-server.sh"
        "04-sso-setup.sh"
        "05-post-install.sh"
    )

    local total=${#scripts[@]}
    local current=0

    for script in "${scripts[@]}"; do
        current=$((current + 1))
        info "[$current/$total] $script"
        curl -sSL "$REPO_RAW/$script" -o "$script" || wget -q "$REPO_RAW/$script" -O "$script"
        chmod +x "$script"
        progress_bar "$current" "$total"
    done
    echo ""
    log "Scripte heruntergeladen nach $INSTALL_DIR"

    # --- Passwoerter generieren ---
    info "Generiere sichere Passwoerter..."

    POSTGRES_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    REDIS_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    NC_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    KC_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    NPM_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    PAPERLESS_SECRET=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    VW_ADMIN_TOKEN=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    NC_CLIENT_SECRET=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    PL_CLIENT_SECRET=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    MC_CLIENT_SECRET=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

    log "Passwoerter generiert"

    # --- Config speichern ---
    cat > "$CONFIG_FILE" << EOF
#===============================================================================
# Eigendaten Office Cloud Suite - Konfiguration
# Erstellt: $(date '+%Y-%m-%d %H:%M:%S')
# ACHTUNG: Diese Datei enthaelt Passwoerter - sicher aufbewahren!
#===============================================================================

# Basis
DOMAIN="$DOMAIN"
ADMIN_EMAIL="$ADMIN_EMAIL"
SERVER_ROLE="$SERVER_ROLE"

# Subdomains
CLOUD_DOMAIN="$CLOUD_DOMAIN"
DOCS_DOMAIN="$DOCS_DOMAIN"
SSO_DOMAIN="$SSO_DOMAIN"
VAULT_DOMAIN="$VAULT_DOMAIN"
MAIL_DOMAIN="$MAIL_DOMAIN"

# Benutzer
USERS="$USERS"

# Generierte Passwoerter
POSTGRES_PASS="$POSTGRES_PASS"
REDIS_PASS="$REDIS_PASS"
NC_ADMIN_PASS="$NC_ADMIN_PASS"
KC_ADMIN_PASS="$KC_ADMIN_PASS"
NPM_ADMIN_PASS="$NPM_ADMIN_PASS"
PAPERLESS_SECRET="$PAPERLESS_SECRET"
VW_ADMIN_TOKEN="$VW_ADMIN_TOKEN"

# SSO Client Secrets
NC_CLIENT_SECRET="$NC_CLIENT_SECRET"
PL_CLIENT_SECRET="$PL_CLIENT_SECRET"
MC_CLIENT_SECRET="$MC_CLIENT_SECRET"

# Optionale Parameter
SSH_PORT="${SSH_PORT:-22}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"
EOF

    chmod 600 "$CONFIG_FILE"
    log "Konfiguration gespeichert: $CONFIG_FILE"
}

#===============================================================================
# [5/6] Installation ausfuehren
#===============================================================================
run_installation() {
    phase_header 5 $TOTAL_PHASES "Installation ausfuehren"

    cd "$INSTALL_DIR"
    source "$CONFIG_FILE"

    # Export fuer Sub-Scripte
    export DOMAIN ADMIN_EMAIL SERVER_ROLE
    export CLOUD_DOMAIN DOCS_DOMAIN SSO_DOMAIN VAULT_DOMAIN MAIL_DOMAIN
    export USERS
    export POSTGRES_PASS REDIS_PASS NC_ADMIN_PASS KC_ADMIN_PASS NPM_ADMIN_PASS
    export PAPERLESS_SECRET VW_ADMIN_TOKEN
    export NC_CLIENT_SECRET PL_CLIENT_SECRET MC_CLIENT_SECRET
    export SSH_PORT="${SSH_PORT:-22}"
    export DEPLOY_USER="${DEPLOY_USER:-deploy}"
    export TIMEZONE="${TIMEZONE:-Europe/Berlin}"
    export MAILCOW_HOSTNAME="${MAIL_DOMAIN:-mail.${DOMAIN}}"
    export AUTO_CONFIRM=true

    local step=0
    local total_steps=3

    # Anzahl Steps berechnen
    case "$SERVER_ROLE" in
        app)  total_steps=3 ;;  # base + app + post
        mail) total_steps=2 ;;  # base + mail
        full) total_steps=4 ;;  # base + app + mail + post
    esac

    # Base Setup
    step=$((step + 1))
    echo -e "  ${MAGENTA}${BOLD}--- Schritt $step/$total_steps: Base Setup ---${NC}"
    ./00-base-setup.sh

    # Rolle-spezifisch
    case "$SERVER_ROLE" in
        app|full)
            step=$((step + 1))
            echo -e "  ${MAGENTA}${BOLD}--- Schritt $step/$total_steps: App-Server ---${NC}"
            ./01-app-server.sh
            ;;&
        mail|full)
            step=$((step + 1))
            echo -e "  ${MAGENTA}${BOLD}--- Schritt $step/$total_steps: Mail-Server ---${NC}"
            ./02-mail-server.sh
            ;;
    esac

    # Post-Install
    if [[ "$SERVER_ROLE" != "mail" ]]; then
        step=$((step + 1))
        echo -e "  ${MAGENTA}${BOLD}--- Schritt $step/$total_steps: Post-Installation ---${NC}"
        ./05-post-install.sh
    fi
}

#===============================================================================
# [6/6] Abschluss & Zugangsdaten
#===============================================================================
show_credentials() {
    phase_header 6 $TOTAL_PHASES "Installation abgeschlossen"

    source "$CONFIG_FILE"

    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    local creds_file="$INSTALL_DIR/ZUGANGSDATEN.txt"

    # Zugangsdaten-Datei erstellen
    cat > "$creds_file" << EOF
===============================================================================
EIGENDATEN OFFICE CLOUD SUITE - ZUGANGSDATEN
Erstellt: $(date '+%Y-%m-%d %H:%M:%S')
Domain: $DOMAIN
Server: $server_ip
===============================================================================

WICHTIG: Diese Datei enthaelt sensible Passwoerter!
         Nach Einrichtung sicher aufbewahren oder loeschen!

===============================================================================
DIENSTE
===============================================================================
EOF

    if [[ "$SERVER_ROLE" == "app" || "$SERVER_ROLE" == "full" ]]; then
        cat >> "$creds_file" << EOF

NEXTCLOUD (Cloud-Speicher)
  URL:      https://cloud.$DOMAIN
  Admin:    admin
  Passwort: $NC_ADMIN_PASS

PAPERLESS-NGX (Dokumente)
  URL:      https://docs.$DOMAIN
  Admin:    admin
  Passwort: $NC_ADMIN_PASS

KEYCLOAK (SSO)
  URL:      https://sso.$DOMAIN
  Admin:    admin
  Passwort: $KC_ADMIN_PASS
  Realm:    ${DOMAIN%%.*}

VAULTWARDEN (Passwoerter)
  URL:         https://vault.$DOMAIN
  Admin-Token: $VW_ADMIN_TOKEN

NGINX PROXY MANAGER
  URL:      http://$server_ip:81
  E-Mail:   $ADMIN_EMAIL
  Passwort: $NPM_ADMIN_PASS

EOF
    fi

    if [[ "$SERVER_ROLE" == "mail" || "$SERVER_ROLE" == "full" ]]; then
        cat >> "$creds_file" << EOF

MAILCOW (E-Mail)
  URL:      https://mail.$DOMAIN
  Admin:    admin
  Passwort: Siehe /opt/mailcow-dockerized/mailcow.conf

EOF
    fi

    cat >> "$creds_file" << EOF

===============================================================================
DATENBANK
===============================================================================

PostgreSQL: $POSTGRES_PASS
Redis:      $REDIS_PASS

===============================================================================
SSO CLIENT SECRETS
===============================================================================

Nextcloud:  $NC_CLIENT_SECRET
Paperless:  $PL_CLIENT_SECRET
Mailcow:    $MC_CLIENT_SECRET

===============================================================================
EOF

    chmod 600 "$creds_file"

    # --- Erfolgsanzeige ---
    echo -e "${GREEN}${BOLD}"
    echo "  +----------------------------------------------------------------------+"
    echo "  |                                                                      |"
    echo "  |              INSTALLATION ERFOLGREICH ABGESCHLOSSEN!                 |"
    echo "  |                                                                      |"
    echo "  +----------------------------------------------------------------------+"
    echo -e "${NC}"

    # Dienste-Tabelle
    echo -e "  ${BOLD}Installierte Dienste:${NC}"
    echo ""
    print_table_sep
    printf "  ${DIM}|${NC} %-22s ${DIM}|${NC} %-44s ${DIM}|${NC}\n" "Dienst" "URL"
    print_table_sep

    if [[ "$SERVER_ROLE" != "mail" ]]; then
        print_table_row "Nextcloud" "https://cloud.$DOMAIN"
        print_table_row "Paperless-NGX" "https://docs.$DOMAIN"
        print_table_row "Keycloak SSO" "https://sso.$DOMAIN"
        print_table_row "Vaultwarden" "https://vault.$DOMAIN"
        print_table_row "NPM Admin" "http://$server_ip:81"
    fi
    if [[ "$SERVER_ROLE" == "mail" || "$SERVER_ROLE" == "full" ]]; then
        print_table_row "Mailcow" "https://mail.$DOMAIN"
    fi
    print_table_sep
    echo ""

    # Credential-Block
    echo -e "  ${BOLD}Zugangsdaten:${NC}"
    echo ""
    echo -e "  ${YELLOW}Datei: $creds_file${NC}"
    echo -e "  ${DIM}(chmod 600 - nur root kann lesen)${NC}"
    echo ""

    if [[ -f "$INSTALL_DIR/user-credentials.txt" ]]; then
        echo -e "  ${BOLD}Benutzer-Passwoerter:${NC}"
        echo -e "  ${YELLOW}Datei: $INSTALL_DIR/user-credentials.txt${NC}"
        echo ""
    fi

    # Naechste Schritte
    echo -e "  ${BOLD}Naechste Schritte:${NC}"
    echo ""
    echo "  1. NPM oeffnen und SSL-Zertifikate anfordern:"
    echo "     http://$server_ip:81"
    echo ""
    echo "  2. SSO einrichten (Nextcloud <-> Keycloak):"
    echo "     cd $INSTALL_DIR && ./04-sso-setup.sh"
    echo ""
    echo "  3. NPM Admin-Port absichern:"
    echo "     sudo ufw delete allow 81/tcp"
    echo "     sudo ufw allow from DEINE-IP to any port 81"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    show_banner
    check_requirements
    configure
    dns_check
    download_and_configure
    run_installation
    show_credentials

    log "Fertig! Eigendaten Office Cloud Suite ist einsatzbereit."
    echo ""
}

main "$@"

#!/bin/bash
#===============================================================================
# Eigendaten - Base Server Setup v4.0
# 
# Dieses Script richtet einen Ubuntu 24.04 Server ein mit:
# - Docker & Docker Compose
# - UFW Firewall mit Best Practices
# - Fail2Ban
# - SSH Hardening (Key-Only Auth)
# - Automatische Sicherheitsupdates
# - jq, htop, und weitere Tools
#
# Verwendung: sudo ./00-base-setup.sh
# 
# Version: 4.0
# Getestet: Ubuntu 24.04 LTS
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
    echo "║          EIGENDATEN - Base Server Setup v3.0                      ║"
    echo "║          Vollautomatisches Production-Ready Setup                 ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

#===============================================================================
# Root-Check
#===============================================================================
if [ "$EUID" -ne 0 ]; then
    error "Bitte als root ausführen: sudo $0"
fi

banner

#===============================================================================
# Konfiguration (aus ENV oder interaktiv)
#===============================================================================
echo -e "${YELLOW}=== Server-Konfiguration ===${NC}\n"

# AUTO_CONFIRM Modus prüfen
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

# Hostname (aus ENV: HOSTNAME oder aus DOMAIN ableiten)
if [[ -n "${HOSTNAME:-}" ]]; then
    info "Hostname: $HOSTNAME (aus ENV)"
elif [[ -n "${DOMAIN:-}" ]]; then
    case "${SERVER_ROLE:-app}" in
        app)  HOSTNAME="app01" ;;
        mail) HOSTNAME="mail01" ;;
        full) HOSTNAME="srv01" ;;
        *)    HOSTNAME="app01" ;;
    esac
    info "Hostname: $HOSTNAME (automatisch)"
elif [[ "$AUTO_CONFIRM" == "true" ]]; then
    HOSTNAME="srv01"
    info "Hostname: $HOSTNAME (default)"
else
    read -p "Hostname für diesen Server (z.B. app01): " HOSTNAME
    [ -z "$HOSTNAME" ] && error "Hostname darf nicht leer sein!"
fi

# Deploy-User
if [[ -n "${DEPLOY_USER:-}" ]]; then
    info "Deploy-User: $DEPLOY_USER (aus ENV)"
elif [[ "$AUTO_CONFIRM" == "true" ]]; then
    DEPLOY_USER="deploy"
    info "Deploy-User: $DEPLOY_USER (default)"
else
    read -p "Deploy-Benutzer erstellen [deploy]: " DEPLOY_USER
    DEPLOY_USER=${DEPLOY_USER:-deploy}
fi

# SSH-Port
if [[ -n "${SSH_PORT:-}" ]]; then
    info "SSH-Port: $SSH_PORT (aus ENV)"
elif [[ "$AUTO_CONFIRM" == "true" ]]; then
    SSH_PORT="22"
else
    read -p "SSH-Port [22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
fi

# Server-Rolle für Firewall
if [[ -n "${SERVER_ROLE:-}" ]]; then
    case "${SERVER_ROLE}" in
        app|1)  FW_ROLE=1; info "Firewall-Rolle: APP-Server (aus ENV)" ;;
        mail|2) FW_ROLE=2; info "Firewall-Rolle: MAIL-Server (aus ENV)" ;;
        full|3) FW_ROLE=1; info "Firewall-Rolle: APP-Server/Full (aus ENV)" ;;
        *)      FW_ROLE=1 ;;
    esac
elif [[ "$AUTO_CONFIRM" == "true" ]]; then
    FW_ROLE=1
    info "Firewall-Rolle: APP-Server (default)"
else
    echo ""
    echo "Server-Rolle für Firewall-Regeln:"
    echo "  1) APP-Server (HTTP/HTTPS, NPM-Admin, Standard-Ports)"
    echo "  2) MAIL-Server (SMTP, IMAP, POP3, HTTP/HTTPS)"
    echo "  3) Minimal (nur SSH)"
    read -p "Auswahl [1]: " FW_ROLE
    FW_ROLE=${FW_ROLE:-1}
fi

# Zusammenfassung
echo ""
echo -e "${BLUE}Zusammenfassung:${NC}"
echo "  Hostname:     ${HOSTNAME}"
echo "  Deploy-User:  ${DEPLOY_USER}"
echo "  SSH-Port:     ${SSH_PORT}"
echo "  Server-Rolle: ${FW_ROLE}"
echo ""

# Bestätigung
if [[ "$AUTO_CONFIRM" != "true" ]]; then
    read -p "Fortfahren? (j/n): " CONFIRM
    [ "$CONFIRM" != "j" ] && [ "$CONFIRM" != "J" ] && { echo "Abgebrochen."; exit 0; }
else
    info "AUTO_CONFIRM aktiv - starte automatisch..."
fi

#===============================================================================
# System-Update
#===============================================================================
echo ""
log "System wird aktualisiert..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

log "System aktualisiert"

#===============================================================================
# Essentielle Pakete installieren
# WICHTIG: jq wird für Mailcow generate_config.sh benötigt!
#===============================================================================
log "Essentielle Pakete werden installiert..."

apt-get install -y -qq \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    htop \
    iotop \
    ncdu \
    vim \
    nano \
    git \
    unzip \
    wget \
    jq \
    net-tools \
    dnsutils \
    fail2ban \
    ufw \
    unattended-upgrades

log "Pakete installiert (inkl. jq für Mailcow)"

#===============================================================================
# Hostname setzen
#===============================================================================
log "Hostname wird gesetzt..."

hostnamectl set-hostname "$HOSTNAME"
echo "$HOSTNAME" > /etc/hostname

# /etc/hosts aktualisieren
if ! grep -q "$HOSTNAME" /etc/hosts; then
    sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost $HOSTNAME/" /etc/hosts
fi

log "Hostname: $HOSTNAME"

#===============================================================================
# Zeitzone setzen
#===============================================================================
log "Zeitzone wird auf Europe/Berlin gesetzt..."

timedatectl set-timezone Europe/Berlin

log "Zeitzone: Europe/Berlin"

#===============================================================================
# Deploy-User erstellen
#===============================================================================
log "Deploy-User wird erstellt..."

if id "$DEPLOY_USER" &>/dev/null; then
    warn "Benutzer $DEPLOY_USER existiert bereits"
else
    useradd -m -s /bin/bash -G sudo "$DEPLOY_USER"
    
    # SSH-Verzeichnis für deploy user
    mkdir -p /home/$DEPLOY_USER/.ssh
    chmod 700 /home/$DEPLOY_USER/.ssh
    
    # Authorized keys von root kopieren falls vorhanden
    if [ -f /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys /home/$DEPLOY_USER/.ssh/
        chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys
        chown -R $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/.ssh
        log "SSH-Keys von root kopiert"
    fi
    
    # Passwordless sudo für deploy
    echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$DEPLOY_USER
    chmod 440 /etc/sudoers.d/$DEPLOY_USER
fi

log "Deploy-User: $DEPLOY_USER"

#===============================================================================
# Docker installieren
#===============================================================================
log "Docker wird installiert..."

# Alte Docker-Versionen entfernen (falls vorhanden)
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Docker GPG Key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Docker Repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Deploy-User zur Docker-Gruppe hinzufügen
usermod -aG docker "$DEPLOY_USER"

# Docker beim Boot starten
systemctl enable docker
systemctl start docker

log "Docker installiert: $(docker --version)"
log "Docker Compose: $(docker compose version)"

#===============================================================================
# UFW Firewall konfigurieren
#===============================================================================
log "Firewall wird konfiguriert..."

# UFW zurücksetzen und Defaults setzen
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH immer erlauben
ufw allow ${SSH_PORT}/tcp comment 'SSH'

# Rolle-spezifische Regeln
case $FW_ROLE in
    1) # APP-Server
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
        ufw allow 81/tcp comment 'NPM Admin (später einschränken!)'
        log "APP-Server Firewall-Regeln hinzugefügt"
        ;;
    2) # MAIL-Server
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
        ufw allow 25/tcp comment 'SMTP'
        ufw allow 465/tcp comment 'SMTPS'
        ufw allow 587/tcp comment 'Submission'
        ufw allow 143/tcp comment 'IMAP'
        ufw allow 993/tcp comment 'IMAPS'
        ufw allow 110/tcp comment 'POP3'
        ufw allow 995/tcp comment 'POP3S'
        ufw allow 4190/tcp comment 'Sieve'
        log "MAIL-Server Firewall-Regeln hinzugefügt"
        ;;
    3) # Minimal
        log "Minimale Firewall (nur SSH)"
        ;;
esac

# UFW aktivieren
ufw --force enable

log "Firewall aktiviert"

#===============================================================================
# Fail2Ban konfigurieren
#===============================================================================
log "Fail2Ban wird konfiguriert..."

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
EOF

# SSH-Port anpassen falls geändert
if [ "$SSH_PORT" != "22" ]; then
    sed -i "s/port = ssh/port = $SSH_PORT/" /etc/fail2ban/jail.local
fi

systemctl enable fail2ban
systemctl restart fail2ban

log "Fail2Ban konfiguriert und gestartet"

#===============================================================================
# SSH Hardening
#===============================================================================
log "SSH wird gehärtet..."

# Backup der SSH-Config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d)

# SSH-Konfiguration anpassen
cat > /etc/ssh/sshd_config.d/99-hardening.conf << EOF
# Eigendaten SSH Hardening
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
EOF

# SSH-Daemon neu starten (Ubuntu: ssh, nicht sshd)
systemctl restart ssh

log "SSH gehärtet (Key-Only, Port $SSH_PORT)"
warn "WICHTIG: SSH-Key bereits auf Server? Sonst Aussperrung möglich!"

#===============================================================================
# Automatische Updates
#===============================================================================
log "Automatische Sicherheitsupdates werden aktiviert..."

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable unattended-upgrades
systemctl start unattended-upgrades

log "Automatische Updates aktiviert"

#===============================================================================
# FUSE für rclone vorbereiten
#===============================================================================
log "FUSE wird für rclone vorbereitet..."

# user_allow_other in fuse.conf aktivieren (für OneDrive-Mounts mit sudo)
if grep -q "^#user_allow_other" /etc/fuse.conf 2>/dev/null; then
    sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
    log "FUSE user_allow_other aktiviert"
elif ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
    echo "user_allow_other" >> /etc/fuse.conf
    log "FUSE user_allow_other hinzugefügt"
fi

#===============================================================================
# Swap-Datei (für kleine Server)
#===============================================================================
log "Swap wird geprüft..."

if [ ! -f /swapfile ]; then
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$RAM_MB" -lt 8000 ]; then
        # Swap = RAM, max 4GB
        SWAP_SIZE=$((RAM_MB < 4096 ? RAM_MB : 4096))
        fallocate -l ${SWAP_SIZE}M /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log "Swap erstellt: ${SWAP_SIZE}MB"
    else
        info "Genügend RAM (${RAM_MB}MB), kein Swap erstellt"
    fi
else
    info "Swap bereits vorhanden"
fi

#===============================================================================
# Arbeitsverzeichnisse erstellen
#===============================================================================
log "Arbeitsverzeichnisse werden erstellt..."

# Datenverzeichnisse
mkdir -p /mnt/data

# App-Verzeichnis für deploy user
mkdir -p /home/$DEPLOY_USER/app
chown $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/app

log "Verzeichnisse erstellt"

#===============================================================================
# Zusammenfassung
#===============================================================================
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Base-Setup abgeschlossen!                       ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Installiert:${NC}"
echo "  ✓ Docker $(docker --version | cut -d' ' -f3 | tr -d ',')"
echo "  ✓ Docker Compose $(docker compose version --short)"
echo "  ✓ UFW Firewall (aktiv)"
echo "  ✓ Fail2Ban (aktiv)"
echo "  ✓ Automatische Updates"
echo "  ✓ jq (für Mailcow)"
echo ""
echo -e "${GREEN}Konfiguration:${NC}"
echo "  Hostname:     $(hostname)"
echo "  Deploy-User:  $DEPLOY_USER"
echo "  SSH-Port:     $SSH_PORT"
echo "  Zeitzone:     $(timedatectl show -p Timezone --value)"
echo ""
echo -e "${YELLOW}Nächste Schritte:${NC}"
echo ""
echo "  1. Als deploy-User einloggen:"
echo "     ssh $DEPLOY_USER@$(hostname -I | awk '{print $1}')"
echo ""
echo "  2. Für APP-Server:"
echo "     ./01-app-server.sh"
echo ""
echo "  3. Für MAIL-Server:"
echo "     ./02-mail-server.sh"
echo ""
echo ""
echo -e "${YELLOW}WICHTIG:${NC}"
echo "  - NPM Admin-Port (81) später einschränken:"
echo "    sudo ufw delete allow 81/tcp"
echo "    sudo ufw allow from DEINE-IP to any port 81"
echo ""
echo "  - Neustart empfohlen: sudo reboot"
echo ""

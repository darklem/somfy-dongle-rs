#!/usr/bin/env bash
# install.sh — Compile et installe somfy-rts-mqtt comme service systemd.
#
# Usage :
#   sudo ./install.sh           # installation complète
#   sudo ./install.sh --update  # met à jour le binaire uniquement (conserve tout)
set -euo pipefail

BINARY_NAME="somfy-rts-mqtt"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/somfy-rts-mqtt"
CONFIG_FILE="$CONFIG_DIR/config"
SERVICE_NAME="somfy-rts-mqtt"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_USER="somfy-rts"
UPDATE_ONLY=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${BLUE}==>${NC} $*"; }

# ── Vérifications préalables ─────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root."
    echo "  sudo ./install.sh"
    exit 1
fi

for arg in "$@"; do
    [[ "$arg" == "--update" ]] && UPDATE_ONLY=true
done

MIN_RUSTC="1.70.0"
BUILD_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"

# ── Vérification / installation de Rust ──────────────────────────────────────

ensure_rust() {
    # Cherche cargo dans l'ordre : rustup (home utilisateur) puis PATH système
    local cargo_bin
    cargo_bin="$(sudo -u "$BUILD_USER" bash -c 'source "$HOME/.cargo/env" 2>/dev/null; command -v cargo' 2>/dev/null || command -v cargo 2>/dev/null || true)"

    if [[ -z "$cargo_bin" ]]; then
        warn "cargo introuvable — installation de Rust via rustup…"
        install_rustup
        return
    fi

    local rustc_ver
    rustc_ver="$("$cargo_bin" --version 2>/dev/null | awk '{print $2}')"
    # Compare les versions (major.minor.patch)
    if ! version_ge "$rustc_ver" "$MIN_RUSTC"; then
        warn "rustc $rustc_ver détecté — version minimale requise : $MIN_RUSTC"
        warn "Mise à jour via rustup…"
        install_rustup
    else
        info "rustc $rustc_ver — OK"
    fi
}

version_ge() {
    # Retourne 0 si $1 >= $2 (format X.Y.Z)
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

install_rustup() {
    if sudo -u "$BUILD_USER" bash -c 'command -v rustup &>/dev/null'; then
        info "rustup déjà présent — mise à jour du toolchain stable…"
        sudo -u "$BUILD_USER" bash -c 'source "$HOME/.cargo/env" 2>/dev/null; rustup update stable'
    else
        info "Installation de rustup pour l'utilisateur '$BUILD_USER'…"
        sudo -u "$BUILD_USER" bash -c \
            'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable 2>&1'
    fi
    info "Rust stable installé."
}

ensure_rust

# ── Compilation ───────────────────────────────────────────────────────────────

step "Compilation du binaire (release)…"
# Lance cargo en tant que l'utilisateur appelant (pas root) pour éviter de
# polluer le cache Cargo de root ou les permissions du répertoire target/.
sudo -u "$BUILD_USER" bash -c \
    'source "$HOME/.cargo/env" 2>/dev/null; cargo build --release --bin '"$BINARY_NAME"

# ── Installation du binaire ───────────────────────────────────────────────────

step "Installation du binaire dans $INSTALL_DIR…"
install -m 755 "target/release/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"
info "Binaire installé : $INSTALL_DIR/$BINARY_NAME"

if $UPDATE_ONLY; then
    step "Mode --update : rechargement du service…"
    systemctl restart "$SERVICE_NAME" 2>/dev/null && info "Service redémarré." \
        || warn "Service non démarré (démarrez-le manuellement si besoin)."
    info "Mise à jour terminée."
    exit 0
fi

# ── Utilisateur système ───────────────────────────────────────────────────────

step "Configuration de l'utilisateur système…"
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    info "Utilisateur '$SERVICE_USER' créé."
else
    info "Utilisateur '$SERVICE_USER' déjà existant."
fi

# Accès au port série (groupe dialout sur Debian/Ubuntu, uucp sur Arch)
SERIAL_GROUP="dialout"
if getent group uucp &>/dev/null && ! getent group dialout &>/dev/null; then
    SERIAL_GROUP="uucp"
fi
if ! id -nG "$SERVICE_USER" | grep -qw "$SERIAL_GROUP"; then
    usermod -aG "$SERIAL_GROUP" "$SERVICE_USER"
    info "Utilisateur '$SERVICE_USER' ajouté au groupe '$SERIAL_GROUP'."
fi

# ── Fichier de configuration ──────────────────────────────────────────────────

step "Configuration…"
mkdir -p "$CONFIG_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
    warn "Fichier de configuration existant CONSERVÉ : $CONFIG_FILE"
    warn "Aucune modification de vos paramètres MQTT ni du port série."
else
    info "Création du fichier de configuration : $CONFIG_FILE"
    cat > "$CONFIG_FILE" <<'CONF'
# /etc/somfy-rts-mqtt/config
# Modifiez ce fichier, puis rechargez avec : sudo systemctl restart somfy-rts-mqtt
#
# SOMFY_ARGS reçoit l'intégralité des arguments de la ligne de commande.
#
# Format MQTT obligatoire : id:hôte:port
#
# Exemples :
#   Minimal (auto-détection du port série) :
#     SOMFY_ARGS=somfy:192.168.1.10:1883
#
#   Port série explicite :
#     SOMFY_ARGS=--serial /dev/ttyACM0 somfy:192.168.1.10:1883
#
#   Avec authentification MQTT :
#     SOMFY_ARGS=--serial /dev/ttyACM0 somfy:192.168.1.10:1883 --username user --password secret

SOMFY_ARGS=somfy:localhost:1883
CONF
    chmod 640 "$CONFIG_FILE"
    chown root:"$SERVICE_USER" "$CONFIG_FILE"
    warn "Éditez $CONFIG_FILE avant de démarrer le service !"
fi

# ── Service systemd ───────────────────────────────────────────────────────────

step "Installation du service systemd…"
cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=Somfy RTS MQTT Client
Documentation=https://github.com/darklem/somfy-dongle-rs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER

# La configuration (SOMFY_ARGS) est lue depuis ce fichier — jamais écrasé.
EnvironmentFile=$CONFIG_FILE

# \$SOMFY_ARGS est interprété par le shell pour supporter les arguments optionnels.
ExecStart=/bin/sh -c 'exec $INSTALL_DIR/$BINARY_NAME \$SOMFY_ARGS'

Restart=on-failure
RestartSec=5s

# Journalisation
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
info "Service activé au démarrage."

# ── Résumé ────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        Installation terminée avec succès         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  1. Éditez la configuration si ce n'est pas déjà fait :"
echo "       sudo nano $CONFIG_FILE"
echo ""
echo "  2. Démarrez le service :"
echo "       sudo systemctl start $SERVICE_NAME"
echo ""
echo "  3. Suivez les logs :"
echo "       sudo journalctl -u $SERVICE_NAME -f"
echo ""
echo "  Pour mettre à jour le binaire sans toucher à la config :"
echo "       sudo ./install.sh --update"
echo ""

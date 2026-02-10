#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║     🚀 PSIPHON CONDUIT MANAGER v1.3                               ║
# ║                                                                   ║
# ║  One-click setup for Psiphon Conduit                              ║
# ║                                                                   ║
# ║  • Installs Docker (if needed)                                    ║
# ║  • Runs Conduit in Docker with live stats                         ║ 
# ║  • Auto-start on boot via systemd/OpenRC/SysVinit                 ║
# ║  • Easy management via CLI or interactive menu                    ║
# ║                                                                   ║
# ║  GitHub: https://github.com/Psiphon-Inc/conduit                   ║
# ╚═══════════════════════════════════════════════════════════════════╝
# core engine: https://github.com/Psiphon-Labs/psiphon-tunnel-core
# Usage:
# curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh | sudo bash
#
# Reference: https://github.com/ssmirr/conduit/releases/latest
# Conduit CLI options:
#   -m, --max-clients int   maximum number of proxy clients (1-1000) (default 200)
#   -b, --bandwidth float   bandwidth limit per peer in Mbps (1-40, or -1 for unlimited) (default 5)
#   -v, --verbose           increase verbosity (-v for verbose, -vv for debug)
#

set -eo pipefail

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0"
    exit 1
fi

VERSION="1.3"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
BACKUP_DIR="$INSTALL_DIR/backups"
FORCE_REINSTALL=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                🚀 PSIPHON CONDUIT MANAGER v${VERSION}                    ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  Help users access the open internet during shutdowns             ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    OS="unknown"
    OS_VERSION="unknown"
    OS_FAMILY="unknown"
    HAS_SYSTEMD=false
    PKG_MANAGER="unknown"
    
    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        OS_VERSION="${VERSION_ID:-unknown}"
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/arch-release ]; then
        OS="arch"
    elif [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ]; then
        OS="opensuse"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    
    # Map OS family and package manager
    case "$OS" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali|raspbian)
            OS_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        rhel|centos|fedora|rocky|almalinux|oracle|amazon|amzn)
            OS_FAMILY="rhel"
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro|endeavouros|garuda)
            OS_FAMILY="arch"
            PKG_MANAGER="pacman"
            ;;
        opensuse|opensuse-leap|opensuse-tumbleweed|sles)
            OS_FAMILY="suse"
            PKG_MANAGER="zypper"
            ;;
        alpine)
            OS_FAMILY="alpine"
            PKG_MANAGER="apk"
            ;;
        *)
            OS_FAMILY="unknown"
            PKG_MANAGER="unknown"
            ;;
    esac
    
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        HAS_SYSTEMD=true
    fi

    log_info "Detected: $OS ($OS_FAMILY family), Package manager: $PKG_MANAGER"

    if command -v podman &>/dev/null && ! command -v docker &>/dev/null; then
        log_warn "Podman detected. This script is optimized for Docker."
        log_warn "If installation fails, consider installing 'docker-ce' manually."
    fi
}

install_package() {
    local package="$1"
    log_info "Installing $package..."
    
    case "$PKG_MANAGER" in
        apt)
            apt-get update -q || log_warn "apt-get update failed, attempting install anyway..."
            if apt-get install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        dnf)
            if dnf install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        yum)
            if yum install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        pacman)
            if pacman -Sy --noconfirm "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        zypper)
            if zypper install -y -n "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        apk)
            if apk add --no-cache "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        *)
            log_warn "Unknown package manager. Please install $package manually."
            return 1
            ;;
    esac
}

check_dependencies() {
    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! command -v bash &>/dev/null; then
            log_info "Installing bash..."
            apk add --no-cache bash 2>/dev/null
        fi
    fi
    
    if ! command -v curl &>/dev/null; then
        install_package curl || log_warn "Could not install curl automatically"
    fi
    
    if ! command -v awk &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package gawk || log_warn "Could not install gawk" ;;
            apk) install_package gawk || log_warn "Could not install gawk" ;;
            *) install_package awk || log_warn "Could not install awk" ;;
        esac
    fi
    
    if ! command -v free &>/dev/null; then
        case "$PKG_MANAGER" in
            apt|dnf|yum) install_package procps || log_warn "Could not install procps" ;;
            pacman) install_package procps-ng || log_warn "Could not install procps" ;;
            zypper) install_package procps || log_warn "Could not install procps" ;;
            apk) install_package procps || log_warn "Could not install procps" ;;
        esac
    fi

    if ! command -v tput &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package ncurses-bin || log_warn "Could not install ncurses-bin" ;;
            apk) install_package ncurses || log_warn "Could not install ncurses" ;;
            *) install_package ncurses || log_warn "Could not install ncurses" ;;
        esac
    fi

    if ! command -v tcpdump &>/dev/null; then
        install_package tcpdump || log_warn "Could not install tcpdump automatically"
    fi

    # GeoIP (geoiplookup or mmdblookup fallback)
    if ! command -v geoiplookup &>/dev/null && ! command -v mmdblookup &>/dev/null; then
        case "$PKG_MANAGER" in
            apt)
                install_package geoip-bin || log_warn "Could not install geoip-bin"
                install_package geoip-database || log_warn "Could not install geoip-database"
                ;;
            dnf|yum)
                if ! rpm -q epel-release &>/dev/null; then
                    $PKG_MANAGER install -y epel-release &>/dev/null || true
                fi
                if ! install_package GeoIP 2>/dev/null; then
                    # AL2023/Fedora: fallback to libmaxminddb
                    log_info "Legacy GeoIP not available, trying libmaxminddb..."
                    install_package libmaxminddb || log_warn "Could not install libmaxminddb"
                    if [ ! -f /usr/share/GeoIP/GeoLite2-Country.mmdb ] && [ ! -f /var/lib/GeoIP/GeoLite2-Country.mmdb ]; then
                        mkdir -p /usr/share/GeoIP
                        local mmdb_url="https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-Country.mmdb"
                        curl -sL "$mmdb_url" -o /usr/share/GeoIP/GeoLite2-Country.mmdb 2>/dev/null || \
                            log_warn "Could not download GeoLite2-Country.mmdb"
                    fi
                fi
                ;;
            pacman) install_package geoip || log_warn "Could not install geoip." ;;
            zypper) install_package GeoIP || log_warn "Could not install GeoIP." ;;
            apk) install_package geoip || log_warn "Could not install geoip." ;;
            *) log_warn "Could not install geoiplookup automatically" ;;
        esac
    fi

    if ! command -v qrencode &>/dev/null; then
        install_package qrencode || log_warn "Could not install qrencode automatically"
    fi
}

get_ram_mb() {
    local ram=""
    if command -v free &>/dev/null; then
        ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    fi
    
    if [ -z "$ram" ] || [ "$ram" = "0" ]; then
        if [ -f /proc/meminfo ]; then
            local kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
            if [ -n "$kb" ]; then
                ram=$((kb / 1024))
            fi
        fi
    fi
    
    if [ -z "$ram" ] || [ "$ram" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$ram"
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c ^processor /proc/cpuinfo)
    fi
    
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$cores"
    fi
}

calculate_recommended_clients() {
    local cores=$(get_cpu_cores)
    local recommended=$((cores * 100))
    if [ "$recommended" -gt 1000 ]; then
        echo 1000
    else
        echo "$recommended"
    fi
}

get_container_cpus() {
    local idx=${1:-1}
    local var="CPUS_${idx}"
    local val="${!var}"
    echo "${val:-${DOCKER_CPUS:-}}"
}

get_container_memory() {
    local idx=${1:-1}
    local var="MEMORY_${idx}"
    local val="${!var}"
    echo "${val:-${DOCKER_MEMORY:-}}"
}

#═══════════════════════════════════════════════════════════════════════
# Interactive Setup
#═══════════════════════════════════════════════════════════════════════

prompt_settings() {
  while true; do
    local ram_mb=$(get_ram_mb)
    local cpu_cores=$(get_cpu_cores)
    local recommended=$(calculate_recommended_clients)
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    CONDUIT CONFIGURATION                      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Server Info:${NC}"
    echo -e "    CPU Cores: ${GREEN}${cpu_cores}${NC}"
    if [ "$ram_mb" -ge 1000 ]; then
        local ram_gb=$(awk "BEGIN {printf \"%.1f\", $ram_mb/1024}")
        echo -e "    RAM: ${GREEN}${ram_gb} GB${NC}"
    else
        echo -e "    RAM: ${GREEN}${ram_mb} MB${NC}"
    fi
    echo -e "    Recommended max-clients: ${GREEN}${recommended}${NC}"
    echo ""
    echo -e "  ${BOLD}Conduit Options:${NC}"
    echo -e "    ${YELLOW}--max-clients${NC}  Maximum proxy clients (1-1000)"
    echo -e "    ${YELLOW}--bandwidth${NC}    Bandwidth per peer in Mbps (1-40, or -1 for unlimited)"
    echo ""
    
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Enter max-clients (1-1000)"
    echo -e "  Press Enter for recommended: ${GREEN}${recommended}${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  max-clients: " input_clients < /dev/tty || true
    
    if [ -z "$input_clients" ]; then
        MAX_CLIENTS=$recommended
    elif [[ "$input_clients" =~ ^[0-9]+$ ]] && [ "$input_clients" -ge 1 ] && [ "$input_clients" -le 1000 ]; then
        MAX_CLIENTS=$input_clients
    else
        log_warn "Invalid input. Using recommended: $recommended"
        MAX_CLIENTS=$recommended
    fi
    
    echo ""
    
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Do you want to set ${BOLD}UNLIMITED${NC} bandwidth? (Recommended for servers)"
    echo -e "  ${YELLOW}Note: High bandwidth usage may attract attention.${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  Set unlimited bandwidth? [y/N] " unlimited_bw < /dev/tty || true

    if [[ "$unlimited_bw" =~ ^[Yy]$ ]]; then
        BANDWIDTH="-1"
        echo -e "  Selected: ${GREEN}Unlimited (-1)${NC}"
    else
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  Enter bandwidth per peer in Mbps (1-40)"
        echo -e "  Press Enter for default: ${GREEN}5${NC} Mbps"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        read -p "  bandwidth: " input_bandwidth < /dev/tty || true
        
        if [ -z "$input_bandwidth" ]; then
            BANDWIDTH=5
        elif [[ "$input_bandwidth" =~ ^[0-9]+$ ]] && [ "$input_bandwidth" -ge 1 ] && [ "$input_bandwidth" -le 40 ]; then
            BANDWIDTH=$input_bandwidth
        elif [[ "$input_bandwidth" =~ ^[0-9]*\.[0-9]+$ ]]; then
            local float_ok=$(awk -v val="$input_bandwidth" 'BEGIN { print (val >= 1 && val <= 40) ? "yes" : "no" }')
            if [ "$float_ok" = "yes" ]; then
                BANDWIDTH=$input_bandwidth
            else
                log_warn "Invalid input. Using default: 5 Mbps"
                BANDWIDTH=5
            fi
        else
            log_warn "Invalid input. Using default: 5 Mbps"
            BANDWIDTH=5
        fi
    fi
    
    echo ""

    # Detect CPU cores and RAM for recommendation
    # 1 container per core, limited by RAM (1 per GB)
    local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    local ram_mb=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 512)
    local ram_gb=$(( ram_mb / 1024 ))
    local rec_cap=32
    local rec_by_cpu=$cpu_cores
    local rec_by_ram=$ram_gb
    [ "$rec_by_ram" -lt 1 ] && rec_by_ram=1
    local rec_containers=$(( rec_by_cpu < rec_by_ram ? rec_by_cpu : rec_by_ram ))
    [ "$rec_containers" -lt 1 ] && rec_containers=1
    [ "$rec_containers" -gt "$rec_cap" ] && rec_containers="$rec_cap"

    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  How many Conduit containers to run? [1-32]"
    echo -e "  More containers = more connections served"
    echo ""
    echo -e "  ${DIM}System: ${cpu_cores} CPU core(s), ${ram_mb}MB RAM (~${ram_gb}GB)${NC}"
    if [ "$cpu_cores" -le 1 ] || [ "$ram_mb" -lt 1024 ]; then
        echo -e "  ${YELLOW}⚠ Low-end system detected. Recommended: 1 container.${NC}"
        echo -e "  ${YELLOW}  Multiple containers may cause high CPU and instability.${NC}"
    elif [ "$cpu_cores" -le 2 ]; then
        echo -e "  ${DIM}Recommended: 1-2 containers for this system.${NC}"
    else
        echo -e "  ${DIM}Recommended: up to ${rec_containers} containers for this system.${NC}"
    fi
    echo ""
    echo -e "  Press Enter for default: ${GREEN}${rec_containers}${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  containers: " input_containers < /dev/tty || true

    if [ -z "$input_containers" ]; then
        CONTAINER_COUNT=$rec_containers
    elif [[ "$input_containers" =~ ^[1-9][0-9]*$ ]]; then
        CONTAINER_COUNT=$input_containers
        if [ "$CONTAINER_COUNT" -gt 32 ]; then
            log_warn "Maximum is 32 containers. Setting to 32."
            CONTAINER_COUNT=32
        elif [ "$CONTAINER_COUNT" -gt "$rec_containers" ]; then
            echo -e "  ${YELLOW}Note:${NC} You chose ${CONTAINER_COUNT}, which is above the recommended ${rec_containers}."
            echo -e "  ${DIM}  This may cause diminishing returns, higher CPU usage, or instability depending on workload.${NC}"
        fi
    else
        log_warn "Invalid input. Using default: ${rec_containers}"
        CONTAINER_COUNT=$rec_containers
    fi

    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Your Settings:${NC}"
    echo -e "    Max Clients: ${GREEN}${MAX_CLIENTS}${NC}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "    Bandwidth:   ${GREEN}Unlimited${NC}"
    else
        echo -e "    Bandwidth:   ${GREEN}${BANDWIDTH}${NC} Mbps"
    fi
    echo -e "    Containers:  ${GREEN}${CONTAINER_COUNT}${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""

    read -p "  Proceed with these settings? [Y/n] " confirm < /dev/tty || true
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        continue
    fi
    break
  done
}

#═══════════════════════════════════════════════════════════════════════
# Installation Functions
#═══════════════════════════════════════════════════════════════════════

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker is already installed"
        return 0
    fi
    
    log_info "Installing Docker..."
    
    if [ "$OS_FAMILY" = "rhel" ]; then
        log_info "Adding Docker repo for RHEL..."
        $PKG_MANAGER install -y -q dnf-plugins-core 2>/dev/null || true
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
    fi

    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! apk add --no-cache docker docker-cli-compose 2>/dev/null; then
            log_error "Failed to install Docker on Alpine"
            return 1
        fi
        rc-update add docker boot 2>/dev/null || true
        service docker start 2>/dev/null || rc-service docker start 2>/dev/null || true
    else
        if ! curl -fsSL https://get.docker.com | sh; then
            log_error "Official Docker installation script failed."
            log_info "Try installing docker manually: https://docs.docker.com/engine/install/"
            return 1
        fi
        
        if [ "$HAS_SYSTEMD" = "true" ]; then
            systemctl enable docker 2>/dev/null || true
            systemctl start docker 2>/dev/null || true
        else
            if command -v update-rc.d &>/dev/null; then
                update-rc.d docker defaults 2>/dev/null || true
            elif command -v chkconfig &>/dev/null; then
                chkconfig docker on 2>/dev/null || true
            elif command -v rc-update &>/dev/null; then
                rc-update add docker default 2>/dev/null || true
            fi
            service docker start 2>/dev/null || /etc/init.d/docker start 2>/dev/null || true
        fi
    fi
    
    sleep 3
    local retries=27
    while ! docker info &>/dev/null && [ $retries -gt 0 ]; do
        sleep 1
        retries=$((retries - 1))
    done
    
    if docker info &>/dev/null; then
        log_success "Docker installed successfully"
    else
        log_error "Docker installation may have failed. Please check manually."
        return 1
    fi
}


# Check for backup keys and offer restore during install
check_and_offer_backup_restore() {
    if [ ! -d "$BACKUP_DIR" ]; then
        return 0
    fi

    local latest_backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)

    if [ -z "$latest_backup" ]; then
        return 0
    fi

    local backup_filename=$(basename "$latest_backup")
    local backup_date=$(echo "$backup_filename" | sed -E 's/conduit_key_([0-9]{8})_([0-9]{6})\.json/\1/')
    local backup_time=$(echo "$backup_filename" | sed -E 's/conduit_key_([0-9]{8})_([0-9]{6})\.json/\2/')
    local formatted_date="${backup_date:0:4}-${backup_date:4:2}-${backup_date:6:2}"
    local formatted_time="${backup_time:0:2}:${backup_time:2:2}:${backup_time:4:2}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  📁 PREVIOUS NODE IDENTITY BACKUP FOUND${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  A backup of your node identity key was found:"
    echo -e "    ${YELLOW}File:${NC} $backup_filename"
    echo -e "    ${YELLOW}Date:${NC} $formatted_date $formatted_time"
    echo ""
    echo -e "  Restoring this key will:"
    echo -e "    • Preserve your node's identity on the Psiphon network"
    echo -e "    • Maintain any accumulated reputation"
    echo -e "    • Allow peers to reconnect to your known node ID"
    echo ""
    echo -e "  ${YELLOW}Note:${NC} If you don't restore, a new identity will be generated."
    echo ""

    while true; do
        read -p "  Do you want to restore your previous node identity? (y/n): " restore_choice < /dev/tty || true

        if [[ "$restore_choice" =~ ^[Yy]$ ]]; then
            echo ""
            log_info "Restoring node identity from backup..."

            docker volume create conduit-data 2>/dev/null || true

            # Try bind-mount, fall back to docker cp (Snap Docker compatibility)
            local restore_ok=false
            if docker run --rm -v conduit-data:/home/conduit/data -v "$BACKUP_DIR":/backup alpine \
                sh -c 'cp /backup/'"$backup_filename"' /home/conduit/data/conduit_key.json && chown -R 1000:1000 /home/conduit/data' 2>/dev/null; then
                restore_ok=true
            else
                log_info "Bind-mount failed (Snap Docker?), trying docker cp..."
                local tmp_ctr="conduit-restore-tmp"
                docker create --name "$tmp_ctr" -v conduit-data:/home/conduit/data alpine true 2>/dev/null || true
                if docker cp "$latest_backup" "$tmp_ctr:/home/conduit/data/conduit_key.json" 2>/dev/null; then
                    docker run --rm -v conduit-data:/home/conduit/data alpine \
                        chown -R 1000:1000 /home/conduit/data 2>/dev/null || true
                    restore_ok=true
                fi
                docker rm -f "$tmp_ctr" 2>/dev/null || true
            fi

            if [ "$restore_ok" = "true" ]; then
                log_success "Node identity restored successfully!"
                echo ""
                return 0
            else
                log_error "Failed to restore backup. Proceeding with fresh install."
                echo ""
                return 1
            fi
        elif [[ "$restore_choice" =~ ^[Nn]$ ]]; then
            echo ""
            log_info "Skipping restore. A new node identity will be generated."
            echo ""
            return 1
        else
            echo "  Please enter y or n."
        fi
    done
}

run_conduit() {
    local count=${CONTAINER_COUNT:-1}
    log_info "Starting Conduit ($count container(s))..."

    log_info "Pulling Conduit image ($CONDUIT_IMAGE)..."
    if ! docker pull "$CONDUIT_IMAGE"; then
        log_error "Failed to pull Conduit image. Check your internet connection."
        exit 1
    fi

    for i in $(seq 1 "$count"); do
        local cname="conduit"
        local vname="conduit-data"
        [ "$i" -gt 1 ] && cname="conduit-${i}" && vname="conduit-data-${i}"

        docker rm -f "$cname" 2>/dev/null || true

        # Ensure volume exists with correct permissions (uid 1000)
        docker volume create "$vname" 2>/dev/null || true
        docker run --rm -v "${vname}:/home/conduit/data" alpine \
            sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true

        local resource_args=""
        local cpus=$(get_container_cpus $i)
        local mem=$(get_container_memory $i)
        [ -n "$cpus" ] && resource_args+="--cpus $cpus "
        [ -n "$mem" ] && resource_args+="--memory $mem "
        # shellcheck disable=SC2086
        if docker run -d \
            --name "$cname" \
            --restart unless-stopped \
            --log-opt max-size=15m \
            --log-opt max-file=3 \
            -v "${vname}:/home/conduit/data" \
            --network host \
            $resource_args \
            "$CONDUIT_IMAGE" \
            start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file; then
            log_success "$cname started"
        else
            log_error "Failed to start $cname"
        fi
    done

    sleep 3
    if [ -n "$(docker ps -q --filter name=conduit 2>/dev/null)" ]; then
        if [ "$BANDWIDTH" == "-1" ]; then
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=Unlimited, containers=$count"
        else
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=${BANDWIDTH}Mbps, containers=$count"
        fi
    else
        log_error "Conduit failed to start"
        docker logs conduit 2>&1 | tail -10
        exit 1
    fi
}

save_settings_install() {
    mkdir -p "$INSTALL_DIR"
    # Preserve existing Telegram settings on reinstall
    local _tg_token="" _tg_chat="" _tg_interval="6" _tg_enabled="false"
    local _tg_alerts="true" _tg_daily="true" _tg_weekly="true" _tg_label="" _tg_start_hour="0"
    local _sf_enabled="false" _sf_count="1" _sf_cpus="" _sf_memory=""
    local _dc_gb="0" _dc_up="0" _dc_down="0" _dc_iface=""
    local _dc_base_rx="0" _dc_base_tx="0" _dc_prior="0" _dc_prior_rx="0" _dc_prior_tx="0"
    local _dk_cpus="" _dk_memory="" _tracker="true"
    if [ -f "$INSTALL_DIR/settings.conf" ]; then
        source "$INSTALL_DIR/settings.conf" 2>/dev/null || true
        _tg_token="${TELEGRAM_BOT_TOKEN:-}"
        _tg_chat="${TELEGRAM_CHAT_ID:-}"
        _tg_interval="${TELEGRAM_INTERVAL:-6}"
        _tg_enabled="${TELEGRAM_ENABLED:-false}"
        _tg_alerts="${TELEGRAM_ALERTS_ENABLED:-true}"
        _tg_daily="${TELEGRAM_DAILY_SUMMARY:-true}"
        _tg_weekly="${TELEGRAM_WEEKLY_SUMMARY:-true}"
        _tg_label="${TELEGRAM_SERVER_LABEL:-}"
        _tg_start_hour="${TELEGRAM_START_HOUR:-0}"
        _sf_enabled="${SNOWFLAKE_ENABLED:-false}"
        _sf_count="${SNOWFLAKE_COUNT:-1}"
        _sf_cpus="${SNOWFLAKE_CPUS:-}"
        _sf_memory="${SNOWFLAKE_MEMORY:-}"
        _dc_gb="${DATA_CAP_GB:-0}"
        _dc_up="${DATA_CAP_UP_GB:-0}"
        _dc_down="${DATA_CAP_DOWN_GB:-0}"
        _dc_iface="${DATA_CAP_IFACE:-}"
        _dc_base_rx="${DATA_CAP_BASELINE_RX:-0}"
        _dc_base_tx="${DATA_CAP_BASELINE_TX:-0}"
        _dc_prior="${DATA_CAP_PRIOR_USAGE:-0}"
        _dc_prior_rx="${DATA_CAP_PRIOR_RX:-0}"
        _dc_prior_tx="${DATA_CAP_PRIOR_TX:-0}"
        _dk_cpus="${DOCKER_CPUS:-}"
        _dk_memory="${DOCKER_MEMORY:-}"
        _tracker="${TRACKER_ENABLED:-true}"
    fi
    local _tmp="$INSTALL_DIR/settings.conf.tmp.$$"
    cat > "$_tmp" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=${CONTAINER_COUNT:-1}
DATA_CAP_GB=$_dc_gb
DATA_CAP_UP_GB=$_dc_up
DATA_CAP_DOWN_GB=$_dc_down
DATA_CAP_IFACE=$_dc_iface
DATA_CAP_BASELINE_RX=$_dc_base_rx
DATA_CAP_BASELINE_TX=$_dc_base_tx
DATA_CAP_PRIOR_USAGE=$_dc_prior
DATA_CAP_PRIOR_RX=$_dc_prior_rx
DATA_CAP_PRIOR_TX=$_dc_prior_tx
DOCKER_CPUS=$_dk_cpus
DOCKER_MEMORY=$_dk_memory
TRACKER_ENABLED=$_tracker
SNOWFLAKE_ENABLED=$_sf_enabled
SNOWFLAKE_COUNT=$_sf_count
SNOWFLAKE_CPUS=$_sf_cpus
SNOWFLAKE_MEMORY=$_sf_memory
TELEGRAM_BOT_TOKEN="$_tg_token"
TELEGRAM_CHAT_ID="$_tg_chat"
TELEGRAM_INTERVAL=$_tg_interval
TELEGRAM_ENABLED=$_tg_enabled
TELEGRAM_ALERTS_ENABLED=$_tg_alerts
TELEGRAM_DAILY_SUMMARY=$_tg_daily
TELEGRAM_WEEKLY_SUMMARY=$_tg_weekly
TELEGRAM_SERVER_LABEL="${_tg_label//\"/}"
TELEGRAM_START_HOUR=$_tg_start_hour
EOF
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$INSTALL_DIR/settings.conf"

    if [ ! -f "$INSTALL_DIR/settings.conf" ]; then
        log_error "Failed to save settings. Check disk space and permissions."
        return 1
    fi

    log_success "Settings saved"
}

setup_autostart() {
    log_info "Setting up auto-start on boot..."
    
    if [ "$HAS_SYSTEMD" = "true" ]; then
        cat > /etc/systemd/system/conduit.service << EOF
[Unit]
Description=Psiphon Conduit Service
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/conduit start --auto
ExecStop=/usr/local/bin/conduit stop --auto

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload 2>/dev/null || true
        systemctl enable conduit.service 2>/dev/null || true
        systemctl start conduit.service 2>/dev/null || true
        log_success "Systemd service created, enabled, and started"

    elif command -v rc-update &>/dev/null; then
        # OpenRC (Alpine, Gentoo, etc.)
        cat > /etc/init.d/conduit << 'EOF'
#!/sbin/openrc-run

name="conduit"
description="Psiphon Conduit Service"
depend() {
    need docker
    after network
}
start() {
    ebegin "Starting Conduit"
    /usr/local/bin/conduit start --auto
    eend $?
}
stop() {
    ebegin "Stopping Conduit"
    /usr/local/bin/conduit stop --auto
    eend $?
}
EOF
        chmod +x /etc/init.d/conduit
        rc-update add conduit default 2>/dev/null || true
        log_success "OpenRC service created and enabled"

    elif [ -d /etc/init.d ]; then
        # SysVinit fallback
        cat > /etc/init.d/conduit << 'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          conduit
# Required-Start:    $docker
# Required-Stop:     $docker
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Psiphon Conduit Service
### END INIT INFO

case "$1" in
    start)
        /usr/local/bin/conduit start --auto
        ;;
    stop)
        /usr/local/bin/conduit stop --auto
        ;;
    restart)
        /usr/local/bin/conduit restart
        ;;
    status)
        docker ps | grep -q conduit && echo "Running" || echo "Stopped"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF
        chmod +x /etc/init.d/conduit
        if command -v update-rc.d &>/dev/null; then
            update-rc.d conduit defaults 2>/dev/null || true
        elif command -v chkconfig &>/dev/null; then
            chkconfig conduit on 2>/dev/null || true
        fi
        log_success "SysVinit service created and enabled"
        
    else
        log_warn "Could not set up auto-start. Docker's restart policy will handle restarts."
        log_info "Container is set to restart unless-stopped, which works on reboot if Docker starts."
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Management Script
#═══════════════════════════════════════════════════════════════════════

create_management_script() {
    # Write to temp file first to avoid "Text file busy"
    local tmp_script="$INSTALL_DIR/conduit.tmp.$$"
    cat > "$tmp_script" << 'MANAGEMENT'
#!/bin/bash
#
# Psiphon Conduit Manager
# Reference: https://github.com/ssmirr/conduit/releases/latest
#

VERSION="1.3"
INSTALL_DIR="REPLACE_ME_INSTALL_DIR"
BACKUP_DIR="$INSTALL_DIR/backups"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Load settings
[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
MAX_CLIENTS=${MAX_CLIENTS:-200}
BANDWIDTH=${BANDWIDTH:-5}
CONTAINER_COUNT=${CONTAINER_COUNT:-1}
DATA_CAP_GB=${DATA_CAP_GB:-0}
DATA_CAP_UP_GB=${DATA_CAP_UP_GB:-0}
DATA_CAP_DOWN_GB=${DATA_CAP_DOWN_GB:-0}
DATA_CAP_IFACE=${DATA_CAP_IFACE:-}
DATA_CAP_BASELINE_RX=${DATA_CAP_BASELINE_RX:-0}
DATA_CAP_BASELINE_TX=${DATA_CAP_BASELINE_TX:-0}
DATA_CAP_PRIOR_USAGE=${DATA_CAP_PRIOR_USAGE:-0}
DATA_CAP_PRIOR_RX=${DATA_CAP_PRIOR_RX:-0}
DATA_CAP_PRIOR_TX=${DATA_CAP_PRIOR_TX:-0}
SNOWFLAKE_IMAGE="thetorproject/snowflake-proxy:latest"
SNOWFLAKE_ENABLED=${SNOWFLAKE_ENABLED:-false}
SNOWFLAKE_COUNT=${SNOWFLAKE_COUNT:-1}
SNOWFLAKE_CPUS=${SNOWFLAKE_CPUS:-}
SNOWFLAKE_MEMORY=${SNOWFLAKE_MEMORY:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}

# Ensure we're running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This command must be run as root (use sudo conduit)${NC}"
    exit 1
fi

# Check if Docker is available
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Error: Docker is not installed!${NC}"
        echo ""
        echo "Docker is required to run Conduit. Please reinstall:"
        echo "  curl -fsSL https://get.docker.com | sudo sh"
        echo ""
        echo "Or re-run the Conduit installer:"
        echo "  sudo bash conduit.sh"
        exit 1
    fi
    
    if ! docker info &>/dev/null; then
        echo -e "${RED}Error: Docker daemon is not running!${NC}"
        echo ""
        echo "Start Docker with:"
        echo "  sudo systemctl start docker       # For systemd"
        echo "  sudo /etc/init.d/docker start     # For SysVinit"
        echo "  sudo rc-service docker start      # For OpenRC"
        exit 1
    fi
}

# Run Docker check
check_docker

# Check for awk (needed for stats parsing)
if ! command -v awk &>/dev/null; then
    echo -e "${YELLOW}Warning: awk not found. Some stats may not display correctly.${NC}"
fi

get_container_name() {
    local idx=${1:-1}
    if [ "$idx" -eq 1 ]; then
        echo "conduit"
    else
        echo "conduit-${idx}"
    fi
}

get_volume_name() {
    local idx=${1:-1}
    if [ "$idx" -eq 1 ]; then
        echo "conduit-data"
    else
        echo "conduit-data-${idx}"
    fi
}

fix_volume_permissions() {
    local idx=${1:-0}
    if [ "$idx" -eq 0 ]; then
        # Fix all volumes
        for i in $(seq 1 $CONTAINER_COUNT); do
            local vol=$(get_volume_name $i)
            docker run --rm -v "${vol}:/home/conduit/data" alpine \
                sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true
        done
    else
        local vol=$(get_volume_name $idx)
        docker run --rm -v "${vol}:/home/conduit/data" alpine \
            sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true
    fi
}

get_container_max_clients() {
    local idx=${1:-1}
    local var="MAX_CLIENTS_${idx}"
    local val="${!var}"
    echo "${val:-$MAX_CLIENTS}"
}

get_container_bandwidth() {
    local idx=${1:-1}
    local var="BANDWIDTH_${idx}"
    local val="${!var}"
    echo "${val:-$BANDWIDTH}"
}

get_container_cpus() {
    local idx=${1:-1}
    local var="CPUS_${idx}"
    local val="${!var}"
    echo "${val:-${DOCKER_CPUS:-}}"
}

get_container_memory() {
    local idx=${1:-1}
    local var="MEMORY_${idx}"
    local val="${!var}"
    echo "${val:-${DOCKER_MEMORY:-}}"
}

run_conduit_container() {
    local idx=${1:-1}
    local name=$(get_container_name $idx)
    local vol=$(get_volume_name $idx)
    local mc=$(get_container_max_clients $idx)
    local bw=$(get_container_bandwidth $idx)
    local cpus=$(get_container_cpus $idx)
    local mem=$(get_container_memory $idx)
    # Remove existing container if any
    if docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
        docker rm -f "$name" 2>/dev/null || true
    fi
    local resource_args=""
    [ -n "$cpus" ] && resource_args+="--cpus $cpus "
    [ -n "$mem" ] && resource_args+="--memory $mem "
    # shellcheck disable=SC2086
    docker run -d \
        --name "$name" \
        --restart unless-stopped \
        --log-opt max-size=15m \
        --log-opt max-file=3 \
        -v "${vol}:/home/conduit/data" \
        --network host \
        $resource_args \
        "$CONDUIT_IMAGE" \
        start --max-clients "$mc" --bandwidth "$bw" --stats-file
}

# ─── Snowflake Proxy Functions ─────────────────────────────────────────────────

get_snowflake_name() {
    local idx=${1:-1}
    if [ "$idx" -le 1 ] 2>/dev/null; then
        echo "snowflake-proxy"
    else
        echo "snowflake-proxy-${idx}"
    fi
}

get_snowflake_volume() {
    local idx=${1:-1}
    if [ "$idx" -le 1 ] 2>/dev/null; then
        echo "snowflake-data"
    else
        echo "snowflake-data-${idx}"
    fi
}

get_snowflake_metrics_port() {
    local idx=${1:-1}
    echo $((10000 - idx))
}

get_snowflake_default_cpus() {
    local cores=$(nproc 2>/dev/null || echo 1)
    if [ "$cores" -ge 2 ]; then
        echo "1.0"
    else
        echo "0.5"
    fi
}

get_snowflake_default_memory() {
    echo "256m"
}

get_snowflake_cpus() {
    if [ -n "$SNOWFLAKE_CPUS" ]; then
        echo "$SNOWFLAKE_CPUS"
    else
        get_snowflake_default_cpus
    fi
}

get_snowflake_memory() {
    if [ -n "$SNOWFLAKE_MEMORY" ]; then
        echo "$SNOWFLAKE_MEMORY"
    else
        get_snowflake_default_memory
    fi
}

run_snowflake_container() {
    local idx=${1:-1}
    local cname=$(get_snowflake_name $idx)
    local vname=$(get_snowflake_volume $idx)
    local mport=$(get_snowflake_metrics_port $idx)
    local sf_cpus=$(get_snowflake_cpus)
    local sf_mem=$(get_snowflake_memory)

    # Remove existing container
    docker rm -f "$cname" >/dev/null 2>&1 || true
    docker volume create "$vname" >/dev/null 2>&1 || true

    # Pull image if not available locally
    if ! docker image inspect "$SNOWFLAKE_IMAGE" >/dev/null 2>&1; then
        docker pull "$SNOWFLAKE_IMAGE" 2>/dev/null || true
    fi

    local actual_cpus=$(LC_ALL=C awk -v req="$sf_cpus" -v cores="$(nproc 2>/dev/null || echo 1)" \
        'BEGIN{c=req+0; if(c>cores+0) c=cores+0; printf "%.2f",c}')

    local _sf_err
    _sf_err=$(docker run -d \
        --name "$cname" \
        --restart unless-stopped \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        --cpus "$actual_cpus" \
        --memory "$sf_mem" \
        --memory-swap "$sf_mem" \
        --network host \
        --health-cmd "wget -q -O /dev/null http://127.0.0.1:${mport}/internal/metrics || exit 1" \
        --health-interval=300s \
        --health-timeout=10s \
        --health-retries=5 \
        --health-start-period=3600s \
        -v "${vname}:/var/lib/snowflake" \
        "$SNOWFLAKE_IMAGE" \
        -metrics -metrics-address "127.0.0.1" -metrics-port "${mport}" 2>&1)
    local _sf_rc=$?
    if [ $_sf_rc -ne 0 ]; then
        echo -e "  ${DIM}Docker: ${_sf_err}${NC}" >&2
    fi
    return $_sf_rc
}

stop_snowflake() {
    local i
    for i in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
        local cname=$(get_snowflake_name $i)
        docker stop --timeout 10 "$cname" 2>/dev/null || true
    done
}

start_snowflake() {
    # Don't start if data cap exceeded
    if [ -f "$PERSIST_DIR/data_cap_exceeded" ]; then
        echo -e "${YELLOW}⚠ Data cap exceeded. Snowflake will not start.${NC}" 2>/dev/null
        return 1
    fi
    local i
    for i in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
        local cname=$(get_snowflake_name $i)
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            echo -e "${GREEN}✓ ${cname} already running${NC}"
        elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            docker start "$cname" 2>/dev/null && echo -e "${GREEN}✓ ${cname} started${NC}" || echo -e "${RED}✗ Failed to start ${cname}${NC}"
        else
            run_snowflake_container $i && echo -e "${GREEN}✓ ${cname} created${NC}" || echo -e "${RED}✗ Failed to create ${cname}${NC}"
        fi
    done
}

restart_snowflake() {
    # Don't restart if data cap exceeded
    if [ -f "$PERSIST_DIR/data_cap_exceeded" ]; then
        echo -e "${YELLOW}⚠ Data cap exceeded. Snowflake will not restart.${NC}" 2>/dev/null
        return 1
    fi
    local i
    for i in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
        local cname=$(get_snowflake_name $i)
        echo -e "  Recreating ${cname}..."
        run_snowflake_container $i && echo -e "  ${GREEN}✓ ${cname} restarted${NC}" || echo -e "  ${RED}✗ Failed${NC}"
    done
}

is_snowflake_running() {
    local i
    for i in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
        local cname=$(get_snowflake_name $i)
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            return 0
        fi
    done
    return 1
}

get_snowflake_stats() {
    # Returns: "connections inbound_bytes outbound_bytes timeouts"
    local total_connections=0 total_inbound=0 total_outbound=0 total_timeouts=0
    local i
    local _sf_tmpdir=$(mktemp -d /tmp/.conduit_sf.XXXXXX)
    for i in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
        local mport=$(get_snowflake_metrics_port $i)
        ( curl -s --max-time 3 "http://127.0.0.1:${mport}/internal/metrics" 2>/dev/null | awk '
            /^tor_snowflake_proxy_connections_total[{ ]/ { conns += $NF }
            /^tor_snowflake_proxy_connection_timeouts_total / { to += $NF }
            /^tor_snowflake_proxy_traffic_inbound_bytes_total / { ib += $NF }
            /^tor_snowflake_proxy_traffic_outbound_bytes_total / { ob += $NF }
            END { printf "%d %d %d %d", conns, ib, ob, to }
        ' > "$_sf_tmpdir/sf_$i" 2>/dev/null ) &
    done
    wait
    for i in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
        if [ -f "$_sf_tmpdir/sf_$i" ]; then
            local p_conns p_ib p_ob p_to
            read -r p_conns p_ib p_ob p_to < "$_sf_tmpdir/sf_$i"
            total_connections=$((total_connections + ${p_conns:-0}))
            total_inbound=$((total_inbound + ${p_ib:-0}))
            total_outbound=$((total_outbound + ${p_ob:-0}))
            total_timeouts=$((total_timeouts + ${p_to:-0}))
        fi
    done
    rm -rf "$_sf_tmpdir"
    # Snowflake Prometheus reports KB despite metric name saying bytes
    total_inbound=$((total_inbound * 1000))
    total_outbound=$((total_outbound * 1000))
    echo "${total_connections} ${total_inbound} ${total_outbound} ${total_timeouts}"
}

get_snowflake_country_stats() {
    # Returns top 10 countries by connection count
    # Output: "count|CC" per line (e.g. "85|CN")
    local all_metrics="" i
    for i in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
        local mport=$(get_snowflake_metrics_port $i)
        local m
        m=$(curl -s --max-time 3 "http://127.0.0.1:${mport}/internal/metrics" 2>/dev/null)
        [ -n "$m" ] && all_metrics="${all_metrics}${m}"$'\n'
    done
    [ -z "$all_metrics" ] && return
    echo "$all_metrics" | sed -n 's/^tor_snowflake_proxy_connections_total{country="\([^"]*\)"} \([0-9]*\).*/\2|\1/p' | \
        awk -F'|' '{ a[$2] += $1 } END { for(c in a) print a[c] "|" c }' | \
        sort -t'|' -k1,1 -nr | head -10
}

show_snowflake_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}                         ${BOLD}SNOWFLAKE PROXY${NC}                          ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
            local sf_status="${RED}Stopped${NC}"
            is_snowflake_running && sf_status="${GREEN}Running${NC}"
            local cnt_label=""
            [ "${SNOWFLAKE_COUNT:-1}" -gt 1 ] && cnt_label=" (${SNOWFLAKE_COUNT} instances)"
            echo -e "  Status:      ${sf_status}${cnt_label}"
            # Show stats if running
            if is_snowflake_running; then
                local sf_s=$(get_snowflake_stats 2>/dev/null)
                local sf_conns=$(echo "$sf_s" | awk '{print $1}')
                local sf_in=$(echo "$sf_s" | awk '{print $2}')
                local sf_out=$(echo "$sf_s" | awk '{print $3}')
                local sf_to=$(echo "$sf_s" | awk '{print $4}')
                local _sf_to_lbl=""
                [ "${sf_to:-0}" -gt 0 ] 2>/dev/null && _sf_to_lbl=" (${sf_to} timeouts)"
                echo -e "  Served:      ${GREEN}${sf_conns:-0}${NC} connections${_sf_to_lbl}"
                echo -e "  Traffic:     ↓ $(format_bytes ${sf_in:-0})  ↑ $(format_bytes ${sf_out:-0})"
                # Per-country stats table
                local country_data
                country_data=$(get_snowflake_country_stats 2>/dev/null)
                if [ -n "$country_data" ]; then
                    echo ""
                    printf "  ${BOLD}%-14s %10s %8s   %-20s${NC}\n" "Country" "Conns" "Pct" "Activity"
                    local _cnt _cc _max_cnt=0
                    # Find max for bar scaling
                    while IFS='|' read -r _cnt _cc; do
                        [ -z "$_cnt" ] && continue
                        [ "$_cnt" -gt "$_max_cnt" ] 2>/dev/null && _max_cnt=$_cnt
                    done <<< "$country_data"
                    while IFS='|' read -r _cnt _cc; do
                        [ -z "$_cnt" ] && continue
                        local _pct=0
                        [ "${sf_conns:-0}" -gt 0 ] 2>/dev/null && _pct=$(( (_cnt * 100) / sf_conns ))
                        local _bar_len=0
                        [ "$_max_cnt" -gt 0 ] 2>/dev/null && _bar_len=$(( (_cnt * 20) / _max_cnt ))
                        [ "$_bar_len" -lt 1 ] && [ "$_cnt" -gt 0 ] && _bar_len=1
                        local _bar=""
                        local _bi
                        for ((_bi=0; _bi<_bar_len; _bi++)); do _bar+="█"; done
                        printf "  %-14s %10s %7s%%   ${MAGENTA}%s${NC}\n" "$_cc" "$_cnt" "$_pct" "$_bar"
                    done <<< "$country_data"
                fi
            fi
            echo -e "  Resources:   CPU $(get_snowflake_cpus)  RAM $(get_snowflake_memory) (per instance)"
            echo ""
            echo "  Options:"
            echo "    1. Start all"
            echo "    2. Stop all"
            echo "    3. Restart all"
            if [ "${SNOWFLAKE_COUNT:-1}" -eq 1 ]; then
                echo "    4. Add 2nd instance"
            else
                echo "    4. Remove 2nd instance"
            fi
            echo "    5. Change resources"
            echo "    6. View logs"
            echo "    7. Remove Snowflake"
            echo "    0. Back"
            echo ""
            local choice
            read -p "  Choice: " choice < /dev/tty || return
            case "$choice" in
                1)
                    echo ""
                    start_snowflake
                    ;;
                2)
                    echo ""
                    stop_snowflake
                    echo -e "  ${GREEN}✓ Snowflake stopped${NC}"
                    ;;
                3)
                    echo ""
                    restart_snowflake
                    ;;
                4)
                    echo ""
                    if [ "${SNOWFLAKE_COUNT:-1}" -eq 1 ]; then
                        if [ -f "$PERSIST_DIR/data_cap_exceeded" ]; then
                            echo -e "  ${YELLOW}⚠ Data cap exceeded. Cannot add instance.${NC}"
                        else
                            SNOWFLAKE_COUNT=2
                            save_settings
                            echo -e "  Creating 2nd instance..."
                            run_snowflake_container 2 && echo -e "  ${GREEN}✓ 2nd instance added${NC}" || echo -e "  ${RED}✗ Failed${NC}"
                        fi
                    else
                        local cname2=$(get_snowflake_name 2)
                        docker rm -f "$cname2" 2>/dev/null || true
                        SNOWFLAKE_COUNT=1
                        save_settings
                        echo -e "  ${GREEN}✓ 2nd instance removed${NC}"
                    fi
                    ;;
                5)
                    echo ""
                    local new_cpus new_mem
                    local cur_cpus=$(get_snowflake_cpus)
                    local cur_mem=$(get_snowflake_memory)
                    echo -e "  Current: CPU ${cur_cpus} | RAM ${cur_mem}"
                    read -p "  CPU limit (e.g. 0.5, 1.0) [${cur_cpus}]: " new_cpus < /dev/tty || true
                    read -p "  Memory limit (e.g. 256m, 512m) [${cur_mem}]: " new_mem < /dev/tty || true
                    local _valid=true
                    if [ -n "$new_cpus" ]; then
                        if ! echo "$new_cpus" | grep -qE '^[0-9]+\.?[0-9]*$' || [ "$(awk "BEGIN{print ($new_cpus <= 0)}")" = "1" ]; then
                            echo -e "  ${RED}Invalid CPU value. Must be a positive number.${NC}"
                            _valid=false
                        fi
                    fi
                    if [ -n "$new_mem" ]; then
                        if ! echo "$new_mem" | grep -qiE '^[1-9][0-9]*[mMgG]$'; then
                            echo -e "  ${RED}Invalid memory value. Use format like 256m or 1g.${NC}"
                            _valid=false
                        fi
                    fi
                    [ "$_valid" = false ] && continue
                    [ -n "$new_cpus" ] && SNOWFLAKE_CPUS="$new_cpus"
                    [ -n "$new_mem" ] && SNOWFLAKE_MEMORY="$new_mem"
                    save_settings
                    restart_snowflake && echo -e "  ${GREEN}✓ Resources updated and applied${NC}" || echo -e "  ${GREEN}✓ Resources saved (will apply on next start)${NC}"
                    ;;
                6)
                    echo ""
                    if ! is_snowflake_running; then
                        echo -e "  ${YELLOW}Snowflake is not running.${NC}"
                        echo ""
                        read -n 1 -s -p "  Press any key to continue..." < /dev/tty || true
                    else
                        local _log_i _log_count=${SNOWFLAKE_COUNT:-1}
                        for _log_i in $(seq 1 $_log_count); do
                            local _log_name=$(get_snowflake_name $_log_i)
                            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${_log_name}$"; then
                                echo -e "  ${CYAN}── Logs: ${BOLD}${_log_name}${NC} (last 30 lines) ──${NC}"
                                echo ""
                                docker logs --tail 30 "$_log_name" 2>&1 | sed 's/^/    /'
                                echo ""
                            fi
                        done
                        read -n 1 -s -p "  Press any key to continue..." < /dev/tty || true
                    fi
                    ;;
                7)
                    echo ""
                    echo -e "  ${YELLOW}⚠ This will remove all Snowflake containers, volumes, and data.${NC}"
                    local _confirm
                    read -p "  Are you sure? (y/n): " _confirm < /dev/tty || return
                    if [[ "${_confirm:-n}" =~ ^[Yy]$ ]]; then
                        stop_snowflake
                        local si
                        for si in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
                            docker rm -f "$(get_snowflake_name $si)" 2>/dev/null || true
                            docker volume rm "$(get_snowflake_volume $si)" 2>/dev/null || true
                        done
                        SNOWFLAKE_ENABLED=false
                        SNOWFLAKE_COUNT=1
                        save_settings
                        echo -e "  ${GREEN}✓ Snowflake removed${NC}"
                        return
                    fi
                    ;;
                0|"")
                    return
                    ;;
            esac
        else
            echo -e "  Status:      ${DIM}Disabled${NC}"
            echo ""
            echo -e "  Snowflake helps censored users access the internet via WebRTC."
            echo -e "  No port forwarding needed. Runs on host networking."
            echo ""
            echo "  Options:"
            echo "    1. Enable Snowflake Proxy"
            echo "    0. Back"
            echo ""
            local choice
            read -p "  Choice: " choice < /dev/tty || return
            case "$choice" in
                1)
                    echo ""
                    echo -e "  Pulling Snowflake image..."
                    if ! docker pull "$SNOWFLAKE_IMAGE" 2>/dev/null; then
                        echo -e "  ${RED}✗ Failed to pull image. Check internet connection.${NC}"
                        continue
                    fi
                    echo -e "  ${GREEN}✓ Image ready${NC}"
                    echo ""
                    echo -e "  ${BOLD}Configure resources${NC} (press Enter to accept defaults):"
                    echo ""
                    local new_cpus new_mem
                    read -p "  CPU limit (e.g. 0.5, 1.0) [$(get_snowflake_default_cpus)]: " new_cpus < /dev/tty || true
                    read -p "  Memory limit (e.g. 256m, 512m) [$(get_snowflake_default_memory)]: " new_mem < /dev/tty || true
                    if [ -n "$new_cpus" ]; then
                        if echo "$new_cpus" | grep -qE '^[0-9]+\.?[0-9]*$' && [ "$(awk "BEGIN{print ($new_cpus > 0)}")" = "1" ]; then
                            SNOWFLAKE_CPUS="$new_cpus"
                        else
                            echo -e "  ${YELLOW}Invalid CPU, using default.${NC}"
                        fi
                    fi
                    if [ -n "$new_mem" ]; then
                        if echo "$new_mem" | grep -qiE '^[1-9][0-9]*[mMgG]$'; then
                            SNOWFLAKE_MEMORY="$new_mem"
                        else
                            echo -e "  ${YELLOW}Invalid memory, using default.${NC}"
                        fi
                    fi
                    SNOWFLAKE_ENABLED=true
                    SNOWFLAKE_COUNT=1
                    save_settings
                    echo ""
                    if [ -f "$PERSIST_DIR/data_cap_exceeded" ]; then
                        echo -e "  ${YELLOW}⚠ Snowflake enabled but data cap exceeded — container not started.${NC}"
                        echo -e "  ${YELLOW}  It will start automatically when the cap resets.${NC}"
                    else
                        run_snowflake_container 1 && echo -e "  ${GREEN}✓ Snowflake proxy enabled and running!${NC}" || echo -e "  ${RED}✗ Failed to start container${NC}"
                    fi
                    ;;
                0|"")
                    return
                    ;;
            esac
        fi
    done
}

show_snowflake_status() {
    if [ "$SNOWFLAKE_ENABLED" != "true" ]; then
        echo -e "  Snowflake: ${DIM}Disabled${NC}"
        return
    fi
    local sf_status="${RED}Stopped${NC}"
    is_snowflake_running && sf_status="${GREEN}Running${NC}"
    echo -e "  Snowflake: ${sf_status} (${SNOWFLAKE_COUNT:-1} instance(s))"
    if is_snowflake_running; then
        local sf_s=$(get_snowflake_stats 2>/dev/null)
        local sf_conns=$(echo "$sf_s" | awk '{print $1}')
        local sf_in=$(echo "$sf_s" | awk '{print $2}')
        local sf_out=$(echo "$sf_s" | awk '{print $3}')
        local sf_to=$(echo "$sf_s" | awk '{print $4}')
        local _sf_to_lbl=""
        [ "${sf_to:-0}" -gt 0 ] 2>/dev/null && _sf_to_lbl=" (${sf_to} timeouts)"
        echo -e "  Served:      ${sf_conns:-0} connections${_sf_to_lbl}"
        echo -e "  Traffic:     ↓ $(format_bytes ${sf_in:-0})  ↑ $(format_bytes ${sf_out:-0})"
    fi
}

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    printf "║                🚀 PSIPHON CONDUIT MANAGER v%-5s                  ║\n" "${VERSION}"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_live_stats_header() {
    local EL="\033[K"
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${EL}"
    printf "║  ${NC}🚀 PSIPHON CONDUIT MANAGER v%-5s   ${CYAN}CONDUIT LIVE STATISTICS      ║${EL}\n" "${VERSION}"
    echo -e "╠═══════════════════════════════════════════════════════════════════╣${EL}"
    # Check for per-container overrides
    local has_overrides=false
    for i in $(seq 1 $CONTAINER_COUNT); do
        local mc_var="MAX_CLIENTS_${i}"
        local bw_var="BANDWIDTH_${i}"
        if [ -n "${!mc_var}" ] || [ -n "${!bw_var}" ]; then
            has_overrides=true
            break
        fi
    done
    if [ "$has_overrides" = true ] && [ "$CONTAINER_COUNT" -gt 1 ]; then
        for i in $(seq 1 $CONTAINER_COUNT); do
            local mc=$(get_container_max_clients $i)
            local bw=$(get_container_bandwidth $i)
            local bw_d="Unlimited"
            [ "$bw" != "-1" ] && bw_d="${bw}Mbps"
            local line="$(get_container_name $i): ${mc} clients, ${bw_d}"
            printf "║  ${GREEN}%-64s${CYAN}║${EL}\n" "$line"
        done
    else
        printf "║  Max Clients: ${GREEN}%-52s${CYAN}║${EL}\n" "${MAX_CLIENTS}"
        if [ "$BANDWIDTH" == "-1" ]; then
            printf "║  Bandwidth:   ${GREEN}%-52s${CYAN}║${EL}\n" "Unlimited"
        else
            printf "║  Bandwidth:   ${GREEN}%-52s${CYAN}║${EL}\n" "${BANDWIDTH} Mbps"
        fi
    fi
    echo -e "╚═══════════════════════════════════════════════════════════════════╝${EL}"
    echo -e "${NC}\033[K"
}



get_node_id() {
    local vol="${1:-conduit-data}"
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        local mountpoint=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}' 2>/dev/null)
        local key_json=""
        if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
            key_json=$(cat "$mountpoint/conduit_key.json" 2>/dev/null)
        else
            local tmp_ctr="conduit-nodeid-tmp"
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            docker create --name "$tmp_ctr" -v "$vol":/data alpine true 2>/dev/null || true
            key_json=$(docker cp "$tmp_ctr:/data/conduit_key.json" - 2>/dev/null | tar -xO 2>/dev/null)
            docker rm -f "$tmp_ctr" 2>/dev/null || true
        fi
        if [ -n "$key_json" ]; then
            echo "$key_json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n'
        fi
    fi
}

get_raw_key() {
    local vol="${1:-conduit-data}"
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        local mountpoint=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}' 2>/dev/null)
        local key_json=""
        if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
            key_json=$(cat "$mountpoint/conduit_key.json" 2>/dev/null)
        else
            local tmp_ctr="conduit-rawkey-tmp"
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            docker create --name "$tmp_ctr" -v "$vol":/data alpine true 2>/dev/null || true
            key_json=$(docker cp "$tmp_ctr:/data/conduit_key.json" - 2>/dev/null | tar -xO 2>/dev/null)
            docker rm -f "$tmp_ctr" 2>/dev/null || true
        fi
        if [ -n "$key_json" ]; then
            echo "$key_json" | grep "privateKeyBase64" | awk -F'"' '{print $4}'
        fi
    fi
}

show_qr_code() {
    local idx="${1:-}"
    # If multiple containers and no index specified, prompt
    if [ -z "$idx" ] && [ "$CONTAINER_COUNT" -gt 1 ]; then
        echo ""
        echo -e "${CYAN}═══ SELECT CONTAINER ═══${NC}"
        for ci in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $ci)
            echo -e "  ${ci}. ${cname}"
        done
        echo ""
        read -p "  Which container? (1-${CONTAINER_COUNT}): " idx < /dev/tty || true
        if ! [[ "$idx" =~ ^[1-9][0-9]*$ ]] || [ "$idx" -gt "$CONTAINER_COUNT" ]; then
            echo -e "${RED}  Invalid selection.${NC}"
            return
        fi
    fi
    [ -z "$idx" ] && idx=1
    local vol=$(get_volume_name $idx)
    local cname=$(get_container_name $idx)

    clear
    local node_id=$(get_node_id "$vol")
    local raw_key=$(get_raw_key "$vol")
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    CONDUIT ID & QR CODE                           ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    if [ "$CONTAINER_COUNT" -gt 1 ]; then
        printf "${CYAN}║${NC}  Container:  ${BOLD}%-52s${CYAN}║${NC}\n" "$cname"
    fi
    if [ -n "$node_id" ]; then
        printf "${CYAN}║${NC}  Conduit ID: ${GREEN}%-52s${CYAN}║${NC}\n" "$node_id"
    else
        printf "${CYAN}║${NC}  Conduit ID: ${YELLOW}%-52s${CYAN}║${NC}\n" "Not available (start container first)"
    fi
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    if [ -n "$raw_key" ] && command -v qrencode &>/dev/null; then
        local hostname_str=$(hostname 2>/dev/null || echo "conduit")
        local claim_json="{\"version\":1,\"data\":{\"key\":\"${raw_key}\",\"name\":\"${hostname_str}\"}}"
        local claim_b64=$(echo -n "$claim_json" | base64 | tr -d '\n')
        local claim_url="network.ryve.app://(app)/conduits?claim=${claim_b64}"
        echo -e "${BOLD}  Scan to claim rewards:${NC}"
        echo ""
        qrencode -t ANSIUTF8 "$claim_url" 2>/dev/null
    elif ! command -v qrencode &>/dev/null; then
        echo -e "${YELLOW}  qrencode not installed. Install with: sudo apt install qrencode${NC}"
        echo -e "  ${CYAN}Claim rewards at: https://network.ryve.app${NC}"
    else
        echo -e "${YELLOW}  Key not available. Start container first.${NC}"
    fi
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

show_dashboard() {
    local stop_dashboard=0
    trap 'stop_dashboard=1' SIGINT SIGTERM
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    clear

    while [ $stop_dashboard -eq 0 ]; do
        # Move cursor to top-left (0,0)
        # We NO LONGER clear the screen here to avoid the "full black" flash
        if ! tput cup 0 0 2>/dev/null; then
            printf "\033[H"
        fi
        
        print_live_stats_header
        
        show_status "live"
        
        # Check data cap
        if _has_any_data_cap; then
            local usage=$(get_data_usage)
            local used_rx=$(echo "$usage" | awk '{print $1}')
            local used_tx=$(echo "$usage" | awk '{print $2}')
            local total_rx=$((used_rx + ${DATA_CAP_PRIOR_RX:-0}))
            local total_tx=$((used_tx + ${DATA_CAP_PRIOR_TX:-0}))
            local total_used=$((total_rx + total_tx))
            echo -e "${CYAN}═══ DATA USAGE ═══${NC}\033[K"
            local cap_info=""
            [ "${DATA_CAP_UP_GB:-0}" -gt 0 ] 2>/dev/null && cap_info+="  up $(format_gb $total_tx)/${DATA_CAP_UP_GB}GB"
            [ "${DATA_CAP_DOWN_GB:-0}" -gt 0 ] 2>/dev/null && cap_info+="  dn $(format_gb $total_rx)/${DATA_CAP_DOWN_GB}GB"
            [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null && cap_info+="  total $(format_gb $total_used)/${DATA_CAP_GB}GB"
            echo -e " ${cap_info}\033[K"
            if ! check_data_cap; then
                echo -e "  ${RED}⚠ DATA CAP EXCEEDED - Containers stopped!${NC}\033[K"
            fi
            echo -e "\033[K"
        fi

        # Side-by-side: Active Clients | Top Upload
        local snap_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
        local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
        if [ -s "$snap_file" ] || [ -s "$data_file" ]; then
            # Reuse connected count from show_status (already cached)
            local dash_clients=${_total_connected:-0}

            # Left column: Active Clients per country (estimated from snapshot distribution)
            local left_lines=()
            if [ -s "$snap_file" ] && [ "$dash_clients" -gt 0 ]; then
                local snap_data
                snap_data=$(awk -F'|' '{if($2!=""&&$4!="") seen[$2"|"$4]=1} END{for(k in seen){split(k,a,"|");c[a[1]]++} for(co in c) print c[co]"|"co}' "$snap_file" 2>/dev/null | sort -t'|' -k1 -nr | head -5)
                local snap_total=0
                if [ -n "$snap_data" ]; then
                    while IFS='|' read -r cnt co; do
                        snap_total=$((snap_total + cnt))
                    done <<< "$snap_data"
                fi
                [ "$snap_total" -eq 0 ] && snap_total=1
                if [ -n "$snap_data" ]; then
                    while IFS='|' read -r cnt country; do
                        [ -z "$country" ] && continue
                        country="${country%% - #*}"
                        local est=$(( (cnt * dash_clients) / snap_total ))
                        [ "$est" -eq 0 ] && [ "$cnt" -gt 0 ] && est=1
                        local pct=$((est * 100 / dash_clients))
                        [ "$pct" -gt 100 ] && pct=100
                        local bl=$((pct / 20)); [ "$bl" -lt 1 ] && bl=1; [ "$bl" -gt 5 ] && bl=5
                        local bf=""; local bp=""; for ((bi=0; bi<bl; bi++)); do bf+="█"; done; for ((bi=bl; bi<5; bi++)); do bp+=" "; done
                        left_lines+=("$(printf "%-11.11s %3d%% \033[32m%s%s\033[0m %5s" "$country" "$pct" "$bf" "$bp" "$(format_number $est)")")
                    done <<< "$snap_data"
                fi
            fi

            # Right column: Top 5 Upload (cumulative outbound bytes per country)
            local right_lines=()
            if [ -s "$data_file" ]; then
                local all_upload
                all_upload=$(awk -F'|' '{if($1!="" && $3+0>0) print $3"|"$1}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr)
                local top5_upload=$(echo "$all_upload" | head -5)
                local total_upload=0
                if [ -n "$all_upload" ]; then
                    while IFS='|' read -r bytes co; do
                        bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                        total_upload=$((total_upload + bytes))
                    done <<< "$all_upload"
                fi
                [ "$total_upload" -eq 0 ] && total_upload=1
                if [ -n "$top5_upload" ]; then
                    while IFS='|' read -r bytes country; do
                        [ -z "$country" ] && continue
                        country="${country%% - #*}"
                        bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                        local pct=$((bytes * 100 / total_upload))
                        local bl=$((pct / 20)); [ "$bl" -lt 1 ] && bl=1; [ "$bl" -gt 5 ] && bl=5
                        local bf=""; local bp=""; for ((bi=0; bi<bl; bi++)); do bf+="█"; done; for ((bi=bl; bi<5; bi++)); do bp+=" "; done
                        local fmt_bytes=$(format_bytes $bytes)
                        right_lines+=("$(printf "%-11.11s %3d%% \033[35m%s%s\033[0m %9s" "$country" "$pct" "$bf" "$bp" "$fmt_bytes")")
                    done <<< "$top5_upload"
                fi
            fi

            # Print side by side
            printf "  ${GREEN}${BOLD}%-30s${NC} ${YELLOW}${BOLD}%s${NC}\033[K\n" "ACTIVE CLIENTS" "TOP 5 UPLOAD (cumulative)"
            local max_rows=${#left_lines[@]}
            [ ${#right_lines[@]} -gt $max_rows ] && max_rows=${#right_lines[@]}
            for ((ri=0; ri<max_rows; ri++)); do
                local lc="${left_lines[$ri]:-}"
                local rc="${right_lines[$ri]:-}"
                if [ -n "$lc" ] && [ -n "$rc" ]; then
                    printf "  "
                    echo -ne "$lc"
                    printf "   "
                    echo -e "$rc\033[K"
                elif [ -n "$lc" ]; then
                    printf "  "
                    echo -e "$lc\033[K"
                elif [ -n "$rc" ]; then
                    printf "  %-30s " ""
                    echo -e "$rc\033[K"
                fi
            done
            echo -e "\033[K"
        fi

        echo -e "${BOLD}Refreshes every 10 seconds.${NC}\033[K"
        echo -e "${CYAN}[i]${NC} ${DIM}What do these numbers mean?${NC}  ${DIM}[any key] Back to menu${NC}\033[K"

        # Clear any leftover lines below the dashboard content (Erase to End of Display)
        # This only cleans up if the dashboard gets shorter
        if ! tput ed 2>/dev/null; then
            printf "\033[J"
        fi

        # Wait 10 seconds for keypress (balances responsiveness with CPU usage)
        # Redirect from /dev/tty ensures it works when the script is piped
        if read -t 10 -n 1 -s key < /dev/tty 2>/dev/null; then
            if [[ "$key" == "i" || "$key" == "I" ]]; then
                show_dashboard_info
            else
                stop_dashboard=1
            fi
        fi
    done
    
    echo -ne "\033[?25h" # Show cursor
    # Restore main screen buffer
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM # Reset traps
}

get_container_stats() {
    # Returns: "CPU_PERCENT RAM_USAGE"
    local names=""
    for i in $(seq 1 $CONTAINER_COUNT); do
        names+=" $(get_container_name $i)"
    done
    local all_stats=$(timeout 10 docker stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" $names 2>/dev/null)
    if [ -z "$all_stats" ]; then
        echo "0% 0MiB"
    elif [ "$CONTAINER_COUNT" -le 1 ]; then
        echo "$all_stats"
    else
        # Single awk to aggregate all container stats at once
        echo "$all_stats" | awk '{
            # CPU: strip % and sum
            cpu = $1; gsub(/%/, "", cpu); total_cpu += cpu + 0
            # Memory used: convert to MiB and sum
            mem = $2; gsub(/[^0-9.]/, "", mem); mem += 0
            if ($2 ~ /GiB/) mem *= 1024
            else if ($2 ~ /KiB/) mem /= 1024
            total_mem += mem
            # Memory limit: take first one
            if (mem_limit == "") mem_limit = $4
            found = 1
        } END {
            if (!found) { print "0% 0MiB"; exit }
            if (total_mem >= 1024) mem_display = sprintf("%.2fGiB", total_mem/1024)
            else mem_display = sprintf("%.1fMiB", total_mem)
            printf "%.2f%% %s / %s\n", total_cpu, mem_display, mem_limit
        }'
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c ^processor /proc/cpuinfo)
    fi
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then echo 1; else echo "$cores"; fi
}

get_system_stats() {
    # Get System CPU (Live Delta), CPU Temp, and RAM
    # Returns: "CPU_PERCENT CPU_TEMP RAM_USED RAM_TOTAL RAM_PCT"

    # 1. System CPU (Stateful Average)
    local sys_cpu="0%"
    local cpu_tmp="/tmp/conduit_cpu_state"

    if [ -f /proc/stat ]; then
        read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
        local total_curr=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local work_curr=$((user + nice + system + irq + softirq + steal))

        if [ -f "$cpu_tmp" ]; then
            read -r total_prev work_prev < "$cpu_tmp"
            local total_delta=$((total_curr - total_prev))
            local work_delta=$((work_curr - work_prev))

            if [ "$total_delta" -gt 0 ]; then
                local cpu_usage=$(awk -v w="$work_delta" -v t="$total_delta" 'BEGIN { printf "%.1f", w * 100 / t }' 2>/dev/null || echo 0)
                sys_cpu="${cpu_usage}%"
            fi
        else
            sys_cpu="Calc..." # First run calibration
        fi

        # Save current state for next run
        echo "$total_curr $work_curr" > "$cpu_tmp"
    else
        sys_cpu="N/A"
    fi

    # 2. CPU Temperature (cross-platform: Intel coretemp, AMD k10temp, ARM thermal)
    local cpu_temp="-"
    local temp_sum=0
    local temp_count=0

    # First try hwmon - look for CPU temperature sensors (most accurate)
    for hwmon_dir in /sys/class/hwmon/hwmon*; do
        [ -d "$hwmon_dir" ] || continue
        local hwmon_name=$(cat "$hwmon_dir/name" 2>/dev/null)
        case "$hwmon_name" in
            coretemp|k10temp|cpu_thermal|soc_thermal|cpu-thermal|thermal-fan-est)
                for temp_file in "$hwmon_dir"/temp*_input; do
                    [ -f "$temp_file" ] || continue
                    local temp_raw=$(cat "$temp_file" 2>/dev/null)
                    if [ -n "$temp_raw" ] && [ "$temp_raw" -gt 0 ] 2>/dev/null; then
                        temp_sum=$((temp_sum + temp_raw))
                        temp_count=$((temp_count + 1))
                    fi
                done
                ;;
        esac
    done

    # Calculate average if we found CPU temps via hwmon
    if [ "$temp_count" -gt 0 ]; then
        cpu_temp="$((temp_sum / temp_count / 1000))°C"
    else
        # Fallback to thermal_zone (less accurate but works on most systems)
        if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
            local temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
            if [ -n "$temp_raw" ] && [ "$temp_raw" -gt 0 ] 2>/dev/null; then
                cpu_temp="$((temp_raw / 1000))°C"
            fi
        fi
    fi

    # 3. System RAM (Used, Total, Percentage)
    local sys_ram_used="N/A"
    local sys_ram_total="N/A"
    local sys_ram_pct="N/A"

    if command -v free &>/dev/null; then
        # Single free -m call: MiB values for percentage + display
        local free_out=$(free -m 2>/dev/null)
        if [ -n "$free_out" ]; then
            read -r sys_ram_used sys_ram_total sys_ram_pct <<< $(echo "$free_out" | awk '/^Mem:/{
                used_mb=$3; total_mb=$2
                pct = (total_mb > 0) ? (used_mb/total_mb)*100 : 0
                if (total_mb >= 1024) { total_str=sprintf("%.1fGiB", total_mb/1024) } else { total_str=sprintf("%.1fMiB", total_mb) }
                if (used_mb >= 1024) { used_str=sprintf("%.1fGiB", used_mb/1024) } else { used_str=sprintf("%.1fMiB", used_mb) }
                printf "%s %s %.2f%%", used_str, total_str, pct
            }')
        fi
    fi

    echo "$sys_cpu $cpu_temp $sys_ram_used $sys_ram_total $sys_ram_pct"
}

show_live_stats() {
    local ps_cache=$(docker ps --format '{{.Names}}' 2>/dev/null)
    local any_running=false
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        if echo "$ps_cache" | grep -q "^${cname}$"; then
            any_running=true
            break
        fi
    done
    if [ "$any_running" = false ]; then
        print_header
        echo -e "${RED}Conduit is not running!${NC}"
        echo "Start it first with option 6 or 'conduit start'"
        read -n 1 -s -r -p "Press any key to continue..." < /dev/tty 2>/dev/null || true
        return 1
    fi

    if [ "$CONTAINER_COUNT" -le 1 ]; then
        # Single container - stream directly
        echo -e "${CYAN}Streaming live statistics... Press Ctrl+C to return to menu${NC}"
        echo -e "${YELLOW}(showing live logs filtered for [STATS])${NC}"
        echo ""
        trap 'echo -e "\n${CYAN}Returning to menu...${NC}"; return' SIGINT
        if grep --help 2>&1 | grep -q -- --line-buffered; then
            docker logs -f --tail 20 conduit 2>&1 | grep --line-buffered "\[STATS\]"
        else
            docker logs -f --tail 20 conduit 2>&1 | grep "\[STATS\]"
        fi
        trap - SIGINT
    else
        # Multi container - show container picker
        echo ""
        echo -e "${CYAN}Select container to view live stats:${NC}"
        echo ""
        for i in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $i)
            local status="${RED}Stopped${NC}"
            echo "$ps_cache" | grep -q "^${cname}$" && status="${GREEN}Running${NC}"
            echo -e "  ${i}. ${cname}  [${status}]"
        done
        echo ""
        read -p "  Select (1-${CONTAINER_COUNT}): " idx < /dev/tty || true
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$CONTAINER_COUNT" ]; then
            echo -e "${RED}Invalid selection.${NC}"
            return 1
        fi
        local target=$(get_container_name $idx)
        echo ""
        echo -e "${CYAN}Streaming live statistics from ${target}... Press Ctrl+C to return${NC}"
        echo ""
        trap 'echo -e "\n${CYAN}Returning to menu...${NC}"; return' SIGINT
        if grep --help 2>&1 | grep -q -- --line-buffered; then
            docker logs -f --tail 20 "$target" 2>&1 | grep --line-buffered "\[STATS\]"
        else
            docker logs -f --tail 20 "$target" 2>&1 | grep "\[STATS\]"
        fi
        trap - SIGINT
    fi
}

format_bytes() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0 B"
        return
    fi
    if [ "$bytes" -ge 1099511627776 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"
    elif [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
    else
        echo "$bytes B"
    fi
}

format_number() {
    local n=$1
    if [ -z "$n" ] || [ "$n" -eq 0 ] 2>/dev/null; then
        echo "0"
    elif [ "$n" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fM\", $n/1000000}"
    elif [ "$n" -ge 1000 ]; then
        awk "BEGIN {printf \"%.1fK\", $n/1000}"
    else
        echo "$n"
    fi
}

# Background tracker helper
is_tracker_active() {
    if command -v systemctl &>/dev/null; then
        systemctl is-active conduit-tracker.service &>/dev/null
        return $?
    fi
    # Fallback: check if tracker process is running
    pgrep -f "conduit-tracker.sh" &>/dev/null
    return $?
}

regenerate_tracker_script() {
    local tracker_script="$INSTALL_DIR/conduit-tracker.sh"
    local persist_dir="$INSTALL_DIR/traffic_stats"
    mkdir -p "$INSTALL_DIR" "$persist_dir"

    cat > "$tracker_script" << 'TRACKER_SCRIPT'
#!/bin/bash
# Psiphon Conduit Background Tracker
set -u

INSTALL_DIR="/opt/conduit"
PERSIST_DIR="/opt/conduit/traffic_stats"
mkdir -p "$PERSIST_DIR"

# Load settings (CONTAINER_COUNT, MAX_CLIENTS, etc.)
[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
CONTAINER_COUNT=${CONTAINER_COUNT:-1}

STATS_FILE="$PERSIST_DIR/cumulative_data"
IPS_FILE="$PERSIST_DIR/cumulative_ips"
SNAPSHOT_FILE="$PERSIST_DIR/tracker_snapshot"
C_START_FILE="$PERSIST_DIR/container_start"
GEOIP_CACHE="$PERSIST_DIR/geoip_cache"

# Temporal sampling: capture 15s, sleep 15s, multiply by 2
SAMPLE_CAPTURE_TIME=15
SAMPLE_SLEEP_TIME=15
TRAFFIC_MULTIPLIER=2

# Connection tracking files
CONN_HISTORY_FILE="$PERSIST_DIR/connection_history"
CONN_HISTORY_START="$PERSIST_DIR/connection_history_start"
PEAK_CONN_FILE="$PERSIST_DIR/peak_connections"
LAST_CONN_RECORD=0
CONN_RECORD_INTERVAL=300  # Record every 5 minutes
LAST_GEOIP_UPDATE=0
GEOIP_UPDATE_INTERVAL=2592000  # 30 days in seconds

# Get container name by index (matches main script naming)
get_container_name() {
    local idx=${1:-1}
    if [ "$idx" -eq 1 ]; then
        echo "conduit"
    else
        echo "conduit-${idx}"
    fi
}

# Get earliest container start time (for reset detection)
get_container_start() {
    local earliest=""
    local count=${CONTAINER_COUNT:-1}
    for i in $(seq 1 $count); do
        local cname=$(get_container_name $i)
        local start=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
        [ -z "$start" ] && continue
        if [ -z "$earliest" ] || [[ "$start" < "$earliest" ]]; then
            earliest="$start"
        fi
    done
    echo "$earliest"
}

# Check if containers restarted and reset data if needed
check_container_restart() {
    local current_start=$(get_container_start)
    [ -z "$current_start" ] && return

    # Check history file
    if [ -f "$CONN_HISTORY_START" ]; then
        local saved=$(cat "$CONN_HISTORY_START" 2>/dev/null)
        if [ "$saved" != "$current_start" ]; then
            # Container restarted - clear history and peak
            rm -f "$CONN_HISTORY_FILE" "$PEAK_CONN_FILE" 2>/dev/null
            echo "$current_start" > "$CONN_HISTORY_START"
        fi
    else
        echo "$current_start" > "$CONN_HISTORY_START"
    fi
}

count_connections() {
    local total_conn=0
    local total_cing=0
    local count=${CONTAINER_COUNT:-1}
    for i in $(seq 1 $count); do
        local cname=$(get_container_name $i)
        local logdata=$(docker logs --tail 200 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        local stats=$(echo "$logdata" | awk '{for(j=1;j<=NF;j++) if($j=="Connected:") print $(j+1)}')
        local cing=$(echo "$logdata" | awk '{for(j=1;j<=NF;j++) if($j=="Connecting:") print $(j+1)}')
        total_conn=$((total_conn + ${stats:-0}))
        total_cing=$((total_cing + ${cing:-0}))
    done
    echo "$total_conn|$total_cing"
}

# Record connection history and update peak
record_connections() {
    local now=$(date +%s)

    # Only record every 5 minutes
    if [ $((now - LAST_CONN_RECORD)) -lt $CONN_RECORD_INTERVAL ]; then
        return
    fi
    LAST_CONN_RECORD=$now

    check_container_restart

    local counts=$(count_connections)
    local connected=$(echo "$counts" | cut -d'|' -f1)
    local connecting=$(echo "$counts" | cut -d'|' -f2)

    echo "${now}|${connected}|${connecting}" >> "$CONN_HISTORY_FILE"

    # Prune entries older than 25 hours
    local cutoff=$((now - 90000))
    if [ -f "$CONN_HISTORY_FILE" ]; then
        awk -F'|' -v cutoff="$cutoff" '$1 >= cutoff' "$CONN_HISTORY_FILE" > "${CONN_HISTORY_FILE}.tmp" 2>/dev/null
        mv -f "${CONN_HISTORY_FILE}.tmp" "$CONN_HISTORY_FILE" 2>/dev/null
    fi

    local current_peak=0
    if [ -f "$PEAK_CONN_FILE" ]; then
        current_peak=$(tail -1 "$PEAK_CONN_FILE" 2>/dev/null)
        current_peak=${current_peak:-0}
    fi
    if [ "$connected" -gt "$current_peak" ] 2>/dev/null; then
        local start=$(cat "$CONN_HISTORY_START" 2>/dev/null)
        echo "$start" > "$PEAK_CONN_FILE"
        echo "$connected" >> "$PEAK_CONN_FILE"
    fi
}

# Detect local IPs
get_local_ips() {
    ip -4 addr show 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]}' | tr '\n' '|'
    echo ""
}

# GeoIP lookup with file-based cache
geo_lookup() {
    local ip="$1"
    # Check cache
    if [ -f "$GEOIP_CACHE" ]; then
        local cached=$(grep "^${ip}|" "$GEOIP_CACHE" 2>/dev/null | head -1 | cut -d'|' -f2)
        if [ -n "$cached" ]; then
            echo "$cached"
            return
        fi
    fi
    local country=""
    if command -v geoiplookup &>/dev/null; then
        country=$(geoiplookup "$ip" 2>/dev/null | awk -F: '/Country Edition/{print $2}' | sed 's/^ *//' | cut -d, -f2- | sed 's/^ *//')
    elif command -v mmdblookup &>/dev/null; then
        local mmdb=""
        for f in /usr/share/GeoIP/GeoLite2-Country.mmdb /var/lib/GeoIP/GeoLite2-Country.mmdb; do
            [ -f "$f" ] && mmdb="$f" && break
        done
        if [ -n "$mmdb" ]; then
            country=$(mmdblookup --file "$mmdb" --ip "$ip" country names en 2>/dev/null | grep -o '"[^"]*"' | tr -d '"')
        fi
    fi
    [ -z "$country" ] && country="Unknown"
    # Cache it (limit cache size)
    if [ -f "$GEOIP_CACHE" ]; then
        local cache_lines=$(wc -l < "$GEOIP_CACHE" 2>/dev/null || echo 0)
        if [ "$cache_lines" -gt 10000 ]; then
            tail -5000 "$GEOIP_CACHE" > "$GEOIP_CACHE.tmp" && mv "$GEOIP_CACHE.tmp" "$GEOIP_CACHE"
        fi
    fi
    echo "${ip}|${country}" >> "$GEOIP_CACHE"
    echo "$country"
}

# Check for container restart — reset data if restarted
container_start=$(docker inspect --format='{{.State.StartedAt}}' conduit 2>/dev/null | cut -d'.' -f1)
stored_start=""
[ -f "$C_START_FILE" ] && stored_start=$(cat "$C_START_FILE" 2>/dev/null)
if [ "$container_start" != "$stored_start" ]; then
    echo "$container_start" > "$C_START_FILE"
    # Backup before reset
    if [ -s "$STATS_FILE" ] || [ -s "$IPS_FILE" ]; then
        echo "[TRACKER] Container restart detected — backing up tracker data"
        [ -s "$STATS_FILE" ] && cp "$STATS_FILE" "$PERSIST_DIR/cumulative_data.bak"
        [ -s "$IPS_FILE" ] && cp "$IPS_FILE" "$PERSIST_DIR/cumulative_ips.bak"
        [ -s "$GEOIP_CACHE" ] && cp "$GEOIP_CACHE" "$PERSIST_DIR/geoip_cache.bak"
    fi
    rm -f "$STATS_FILE" "$IPS_FILE"
    # Keep stale snapshot visible until first capture cycle replaces it
    # Restore cumulative data across restarts
    if [ -f "$PERSIST_DIR/cumulative_data.bak" ]; then
        cp "$PERSIST_DIR/cumulative_data.bak" "$STATS_FILE"
        cp "$PERSIST_DIR/cumulative_ips.bak" "$IPS_FILE" 2>/dev/null
        echo "[TRACKER] Tracker data restored from backup"
    fi
fi
touch "$STATS_FILE" "$IPS_FILE"

TCPDUMP_BIN=$(command -v tcpdump 2>/dev/null || echo "tcpdump")
AWK_BIN=$(command -v gawk 2>/dev/null || command -v awk 2>/dev/null || echo "awk")

LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
[ -z "$LOCAL_IP" ] && LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

# Primary external interface (avoid docker bridge double-counting)
CAPTURE_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[ -z "$CAPTURE_IFACE" ] && CAPTURE_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
[ -z "$CAPTURE_IFACE" ] && CAPTURE_IFACE="any"

process_batch() {
    local batch="$1"
    local resolved="$PERSIST_DIR/resolved_batch"
    local geo_map="$PERSIST_DIR/geo_map"

    # Extract unique IPs and bulk-resolve GeoIP
    $AWK_BIN -F'|' '{print $2}' "$batch" | sort -u > "$PERSIST_DIR/batch_ips"

    > "$geo_map"
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        country=""
        if [ -f "$GEOIP_CACHE" ]; then
            country=$(grep "^${ip}|" "$GEOIP_CACHE" 2>/dev/null | head -1 | cut -d'|' -f2)
        fi
        if [ -z "$country" ]; then
            country=$(geo_lookup "$ip")
        fi
        # Strip country code prefix (e.g. "US, United States" -> "United States")
        country=$(echo "$country" | sed 's/^[A-Z][A-Z], //')
        # Normalize
        case "$country" in
            *Iran*) country="Iran - #FreeIran" ;;
            *Moldova*) country="Moldova" ;;
            *Korea*Republic*|*"South Korea"*) country="South Korea" ;;
            *"Russian Federation"*|*Russia*) country="Russia" ;;
            *"Taiwan"*) country="Taiwan" ;;
            *"Venezuela"*) country="Venezuela" ;;
            *"Bolivia"*) country="Bolivia" ;;
            *"Tanzania"*) country="Tanzania" ;;
            *"Viet Nam"*|*Vietnam*) country="Vietnam" ;;
            *"Syrian Arab Republic"*) country="Syria" ;;
        esac
        echo "${ip}|${country}" >> "$geo_map"
    done < "$PERSIST_DIR/batch_ips"

    # Merge batch into cumulative_data + write snapshot (MULT compensates for sampling)
    $AWK_BIN -F'|' -v snap="${SNAPSHOT_TMP:-$SNAPSHOT_FILE}" -v MULT="$TRAFFIC_MULTIPLIER" '
        BEGIN { OFMT = "%.0f"; CONVFMT = "%.0f"; if (MULT == "") MULT = 1 }
        FILENAME == ARGV[1] { geo[$1] = $2; next }
        FILENAME == ARGV[2] { existing[$1] = $2 "|" $3; next }
        FILENAME == ARGV[3] {
            dir = $1; ip = $2; bytes = ($3 + 0) * MULT
            c = geo[ip]
            if (c == "") c = "Unknown"
            if (dir == "FROM") from_bytes[c] += bytes
            else to_bytes[c] += bytes
            print dir "|" c "|" bytes "|" ip > snap
            next
        }
        END {
            for (c in existing) {
                split(existing[c], v, "|")
                f = v[1] + 0; t = v[2] + 0
                f += from_bytes[c] + 0
                t += to_bytes[c] + 0
                print c "|" f "|" t
                delete from_bytes[c]
                delete to_bytes[c]
            }
            for (c in from_bytes) {
                f = from_bytes[c] + 0
                t = to_bytes[c] + 0
                print c "|" f "|" t
                delete to_bytes[c]
            }
            for (c in to_bytes) {
                print c "|0|" to_bytes[c] + 0
            }
        }
    ' "$geo_map" "$STATS_FILE" "$batch" > "$STATS_FILE.tmp" && mv "$STATS_FILE.tmp" "$STATS_FILE"

    # Merge batch IPs into cumulative_ips
    $AWK_BIN -F'|' '
        FILENAME == ARGV[1] { geo[$1] = $2; next }
        FILENAME == ARGV[2] { seen[$0] = 1; print; next }
        FILENAME == ARGV[3] {
            ip = $2; c = geo[ip]
            if (c == "") c = "Unknown"
            key = c "|" ip
            if (!(key in seen)) { seen[key] = 1; print key }
        }
    ' "$geo_map" "$IPS_FILE" "$batch" > "$IPS_FILE.tmp" && mv "$IPS_FILE.tmp" "$IPS_FILE"

    rm -f "$PERSIST_DIR/batch_ips" "$geo_map" "$resolved"
}

# Auto-restart stuck containers (no peers for 2+ hours)
LAST_STUCK_CHECK=0
declare -A CONTAINER_LAST_ACTIVE
declare -A CONTAINER_LAST_RESTART
STUCK_THRESHOLD=7200      # 2 hours in seconds
STUCK_CHECK_INTERVAL=900  # Check every 15 minutes

check_stuck_containers() {
    local now=$(date +%s)
    [ -f "$PERSIST_DIR/data_cap_exceeded" ] && return
    local containers=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^conduit(-[0-9]+)?$')
    [ -z "$containers" ] && return

    for cname in $containers; do
        local logs=$(docker logs --tail 50 "$cname" 2>&1)
        local has_stats
        has_stats=$(echo "$logs" | grep -c "\[STATS\]" 2>/dev/null) || true
        has_stats=${has_stats:-0}
        local connected=0
        if [ "$has_stats" -gt 0 ]; then
            local last_stat=$(echo "$logs" | grep "\[STATS\]" | tail -1)
            local parsed=$(echo "$last_stat" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
            if [ -z "$parsed" ]; then
                CONTAINER_LAST_ACTIVE[$cname]=$now
                continue
            fi
            connected=$parsed
        fi

        if [ "$connected" -gt 0 ]; then
            CONTAINER_LAST_ACTIVE[$cname]=$now
            continue
        fi

        if [ -z "${CONTAINER_LAST_ACTIVE[$cname]:-}" ]; then
            CONTAINER_LAST_ACTIVE[$cname]=$now
            continue
        fi

        local last_active=${CONTAINER_LAST_ACTIVE[$cname]:-$now}
        local idle_time=$((now - last_active))
        if [ "$idle_time" -ge "$STUCK_THRESHOLD" ]; then
            local last_restart=${CONTAINER_LAST_RESTART[$cname]:-0}
            if [ $((now - last_restart)) -lt "$STUCK_THRESHOLD" ]; then
                continue
            fi

            local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
            if [ -z "$started" ]; then
                unset CONTAINER_LAST_ACTIVE[$cname] 2>/dev/null
                unset CONTAINER_LAST_RESTART[$cname] 2>/dev/null
                continue
            fi
            local start_epoch=$(date -d "$started" +%s 2>/dev/null || echo "$now")
            local uptime=$((now - start_epoch))
            if [ "$uptime" -lt "$STUCK_THRESHOLD" ]; then
                continue
            fi

            echo "[TRACKER] Auto-restarting stuck container: $cname (no peers for ${idle_time}s)"
            if docker restart "$cname" >/dev/null 2>&1; then
                CONTAINER_LAST_RESTART[$cname]=$now
                CONTAINER_LAST_ACTIVE[$cname]=$now
                if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
                    local _msg="⚠️ *Conduit Alert*
Container \`${cname}\` was stuck (no peers for $((idle_time/3600))h) and has been auto\\-restarted\\."
                    curl -s --max-time 10 -X POST \
                        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                        -d chat_id="$TELEGRAM_CHAT_ID" \
                        -d parse_mode="MarkdownV2" \
                        -d text="$_msg" >/dev/null 2>&1 || true
                fi
            fi
        fi
    done
}

# Main capture loop: capture -> process -> sleep -> repeat
LAST_BACKUP=0
while true; do
    BATCH_FILE="$PERSIST_DIR/batch_tmp"
    > "$BATCH_FILE"

    # Capture phase
    while IFS= read -r line; do
        if [ "$line" = "SYNC_MARKER" ]; then
            if [ -s "$BATCH_FILE" ]; then
                > "${SNAPSHOT_FILE}.new"
                SNAPSHOT_TMP="${SNAPSHOT_FILE}.new"
                if process_batch "$BATCH_FILE" && [ -s "${SNAPSHOT_FILE}.new" ]; then
                    mv -f "${SNAPSHOT_FILE}.new" "$SNAPSHOT_FILE"
                fi
            fi
            > "$BATCH_FILE"

            NOW=$(date +%s)
            if [ $((NOW - LAST_BACKUP)) -ge 10800 ]; then
                [ -s "$STATS_FILE" ] && cp "$STATS_FILE" "$PERSIST_DIR/cumulative_data.bak"
                [ -s "$IPS_FILE" ] && cp "$IPS_FILE" "$PERSIST_DIR/cumulative_ips.bak"
                LAST_BACKUP=$NOW
            fi

            # Monthly GeoIP update
            if [ $((NOW - LAST_GEOIP_UPDATE)) -ge "$GEOIP_UPDATE_INTERVAL" ]; then
                _geoip_url="https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-Country.mmdb"
                _geoip_dir="/usr/share/GeoIP"
                _tmp_mmdb="/tmp/GeoLite2-Country.mmdb.$$"
                mkdir -p "$_geoip_dir" 2>/dev/null
                if curl -fsSL --max-time 60 --max-filesize 10485760 -o "$_tmp_mmdb" "$_geoip_url" 2>/dev/null; then
                    _fsize=$(stat -c %s "$_tmp_mmdb" 2>/dev/null || stat -f %z "$_tmp_mmdb" 2>/dev/null || echo 0)
                    if [ "$_fsize" -gt 1048576 ] 2>/dev/null; then
                        mv "$_tmp_mmdb" "$_geoip_dir/GeoLite2-Country.mmdb"
                        chmod 644 "$_geoip_dir/GeoLite2-Country.mmdb"
                    else
                        rm -f "$_tmp_mmdb"
                    fi
                else
                    rm -f "$_tmp_mmdb" 2>/dev/null
                fi
                LAST_GEOIP_UPDATE=$NOW
            fi
        else
            echo "$line" >> "$BATCH_FILE"
        fi
    done < <(timeout "$SAMPLE_CAPTURE_TIME" $TCPDUMP_BIN -tt -l -ni "$CAPTURE_IFACE" -n -q -s 64 "(tcp or udp) and not port 22" 2>/dev/null | $AWK_BIN -v local_ip="$LOCAL_IP" '
    BEGIN { OFMT = "%.0f"; CONVFMT = "%.0f" }
    {
        ts = $1 + 0
        if (ts == 0) next

        src = ""; dst = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "IP") {
                sf = $(i+1)
                for (j = i+2; j <= NF; j++) {
                    if ($(j-1) == ">") {
                        df = $j
                        gsub(/:$/, "", df)
                        break
                    }
                }
                break
            }
        }
        if (sf != "") { n=split(sf,p,"."); if(n>=4) src=p[1]"."p[2]"."p[3]"."p[4] }
        if (df != "") { n=split(df,p,"."); if(n>=4) dst=p[1]"."p[2]"."p[3]"."p[4] }

        len = 0
        for (i=1; i<=NF; i++) { if ($i=="length") { len=$(i+1)+0; break } }
        if (len==0) { for (i=NF; i>0; i--) { if ($i ~ /^[0-9]+$/) { len=$i+0; break } } }

        if (src ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.|169\.254\.)/) src=""
        if (dst ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.|169\.254\.)/) dst=""

        # Direction + accumulate
        if (src == local_ip && dst != "" && dst != local_ip) {
            to[dst] += len
        } else if (dst == local_ip && src != "" && src != local_ip) {
            from[src] += len
        } else if (src != "" && src != local_ip) {
            from[src] += len
        } else if (dst != "" && dst != local_ip) {
            to[dst] += len
        }
    }
    END {
        # Flush all accumulated data when tcpdump exits (after timeout)
        for (ip in from) { if (from[ip] > 0) print "FROM|" ip "|" from[ip] }
        for (ip in to) { if (to[ip] > 0) print "TO|" ip "|" to[ip] }
        print "SYNC_MARKER"
        fflush()
    }')

    # Check for stuck containers during each cycle
    NOW=$(date +%s)
    if [ $((NOW - LAST_STUCK_CHECK)) -ge "$STUCK_CHECK_INTERVAL" ]; then
        check_stuck_containers
        LAST_STUCK_CHECK=$NOW
    fi

    record_connections

    sleep "$SAMPLE_SLEEP_TIME"
done
TRACKER_SCRIPT

    chmod +x "$tracker_script"
}

setup_tracker_service() {
    if [ "${TRACKER_ENABLED:-true}" = "false" ]; then
        return 0
    fi

    regenerate_tracker_script

    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/conduit-tracker.service << EOF
[Unit]
Description=Conduit Traffic Tracker
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/bin/bash $INSTALL_DIR/conduit-tracker.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable conduit-tracker.service 2>/dev/null || true
        systemctl restart conduit-tracker.service 2>/dev/null || true
    fi
}

stop_tracker_service() {
    if command -v systemctl &>/dev/null; then
        systemctl stop conduit-tracker.service 2>/dev/null || true
    else
        pkill -f "conduit-tracker.sh" 2>/dev/null || true
    fi
}

show_advanced_stats() {
    if [ "${TRACKER_ENABLED:-true}" = "false" ]; then
        echo ""
        echo -e "  ${YELLOW}⚠ Tracker is disabled.${NC}"
        echo -e "  Advanced stats requires the tracker to capture network traffic."
        echo ""
        echo -e "  To enable: Settings & Tools → Toggle tracker (d)"
        echo ""
        read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
        return
    fi

    local persist_dir="$INSTALL_DIR/traffic_stats"
    local exit_stats=0
    trap 'exit_stats=1' SIGINT SIGTERM

    local L="══════════════════════════════════════════════════════════════"
    local D="──────────────────────────────────────────────────────────────"

    # Enter alternate screen buffer
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    printf "\033[2J\033[H"

    local cycle_start=$(date +%s)
    local last_refresh=0

    while [ "$exit_stats" -eq 0 ]; do
        local now=$(date +%s)
        local term_height=$(stty size </dev/tty 2>/dev/null | awk '{print $1}')
        [ -z "$term_height" ] || [ "$term_height" -lt 10 ] 2>/dev/null && term_height=$(tput lines 2>/dev/null || echo "${LINES:-24}")

        local cycle_elapsed=$(( (now - cycle_start) % 15 ))
        local time_until_next=$((15 - cycle_elapsed))

        # Build progress bar
        local bar=""
        for ((i=0; i<cycle_elapsed; i++)); do bar+="●"; done
        for ((i=cycle_elapsed; i<15; i++)); do bar+="○"; done

        # Refresh data every 15 seconds or first run
        if [ $((now - last_refresh)) -ge 15 ] || [ "$last_refresh" -eq 0 ]; then
            last_refresh=$now
            cycle_start=$now

            printf "\033[H"

            echo -e "${CYAN}╔${L}${NC}\033[K"
            echo -e "${CYAN}║${NC}  ${BOLD}ADVANCED STATISTICS${NC}        ${DIM}[q] Back  Auto-refresh${NC}\033[K"
            echo -e "${CYAN}╠${L}${NC}\033[K"

            # Container stats - aggregate from all containers
            local docker_ps_cache=$(docker ps --format '{{.Names}}' 2>/dev/null)
            local container_count=0
            local total_cpu=0 total_conn=0
            local total_up_bytes=0 total_down_bytes=0
            local total_mem_mib=0 first_mem_limit=""

            echo -e "${CYAN}║${NC} ${GREEN}CONTAINER${NC}  ${DIM}|${NC}  ${YELLOW}NETWORK${NC}  ${DIM}|${NC}  ${MAGENTA}TRACKER${NC}\033[K"

            # Fetch docker stats and all container logs in parallel
            local adv_running_names=""
            local _adv_tmpdir=$(mktemp -d /tmp/.conduit_adv.XXXXXX)
            # mktemp already created the directory
            for ci in $(seq 1 $CONTAINER_COUNT); do
                local cname=$(get_container_name $ci)
                if echo "$docker_ps_cache" | grep -q "^${cname}$"; then
                    adv_running_names+=" $cname"
                    ( docker logs --tail 200 "$cname" 2>&1 | grep "\[STATS\]" | tail -1 > "$_adv_tmpdir/logs_${ci}" ) &
                fi
            done
            local adv_all_stats=""
            if [ -n "$adv_running_names" ]; then
                ( timeout 10 docker stats --no-stream --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}" $adv_running_names > "$_adv_tmpdir/stats" 2>/dev/null ) &
            fi
            wait
            [ -f "$_adv_tmpdir/stats" ] && adv_all_stats=$(cat "$_adv_tmpdir/stats")

            for ci in $(seq 1 $CONTAINER_COUNT); do
                local cname=$(get_container_name $ci)
                if echo "$docker_ps_cache" | grep -q "^${cname}$"; then
                    container_count=$((container_count + 1))

                    local stats=$(echo "$adv_all_stats" | grep "^${cname}|" 2>/dev/null)
                    local cpu=$(echo "$stats" | cut -d'|' -f2 | tr -d '%')
                    [[ "$cpu" =~ ^[0-9.]+$ ]] && total_cpu=$(awk -v a="$total_cpu" -v b="$cpu" 'BEGIN{printf "%.2f", a+b}')

                    local cmem_str=$(echo "$stats" | cut -d'|' -f3 | awk '{print $1}')
                    local cmem_val=$(echo "$cmem_str" | sed 's/[^0-9.]//g')
                    local cmem_unit=$(echo "$cmem_str" | sed 's/[0-9.]//g')
                    if [[ "$cmem_val" =~ ^[0-9.]+$ ]]; then
                        case "$cmem_unit" in
                            GiB) cmem_val=$(awk -v v="$cmem_val" 'BEGIN{printf "%.2f", v*1024}') ;;
                            KiB) cmem_val=$(awk -v v="$cmem_val" 'BEGIN{printf "%.2f", v/1024}') ;;
                        esac
                        total_mem_mib=$(awk -v a="$total_mem_mib" -v b="$cmem_val" 'BEGIN{printf "%.2f", a+b}')
                    fi
                    [ -z "$first_mem_limit" ] && first_mem_limit=$(echo "$stats" | cut -d'|' -f3 | awk -F'/' '{print $2}' | xargs)

                    local logs=""
                    [ -f "$_adv_tmpdir/logs_${ci}" ] && logs=$(cat "$_adv_tmpdir/logs_${ci}")
                    local conn=$(echo "$logs" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
                    [[ "$conn" =~ ^[0-9]+$ ]] && total_conn=$((total_conn + conn))

                    # Parse upload/download to bytes
                    local up_raw=$(echo "$logs" | sed -n 's/.*Up:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
                    local down_raw=$(echo "$logs" | sed -n 's/.*Down:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
                    if [ -n "$up_raw" ]; then
                        local up_val=$(echo "$up_raw" | sed 's/[^0-9.]//g')
                        local up_unit=$(echo "$up_raw" | sed 's/[0-9. ]//g')
                        if [[ "$up_val" =~ ^[0-9.]+$ ]]; then
                            case "$up_unit" in
                                GB) total_up_bytes=$(awk -v a="$total_up_bytes" -v v="$up_val" 'BEGIN{printf "%.0f", a+v*1073741824}') ;;
                                MB) total_up_bytes=$(awk -v a="$total_up_bytes" -v v="$up_val" 'BEGIN{printf "%.0f", a+v*1048576}') ;;
                                KB) total_up_bytes=$(awk -v a="$total_up_bytes" -v v="$up_val" 'BEGIN{printf "%.0f", a+v*1024}') ;;
                                B)  total_up_bytes=$(awk -v a="$total_up_bytes" -v v="$up_val" 'BEGIN{printf "%.0f", a+v}') ;;
                            esac
                        fi
                    fi
                    if [ -n "$down_raw" ]; then
                        local down_val=$(echo "$down_raw" | sed 's/[^0-9.]//g')
                        local down_unit=$(echo "$down_raw" | sed 's/[0-9. ]//g')
                        if [[ "$down_val" =~ ^[0-9.]+$ ]]; then
                            case "$down_unit" in
                                GB) total_down_bytes=$(awk -v a="$total_down_bytes" -v v="$down_val" 'BEGIN{printf "%.0f", a+v*1073741824}') ;;
                                MB) total_down_bytes=$(awk -v a="$total_down_bytes" -v v="$down_val" 'BEGIN{printf "%.0f", a+v*1048576}') ;;
                                KB) total_down_bytes=$(awk -v a="$total_down_bytes" -v v="$down_val" 'BEGIN{printf "%.0f", a+v*1024}') ;;
                                B)  total_down_bytes=$(awk -v a="$total_down_bytes" -v v="$down_val" 'BEGIN{printf "%.0f", a+v}') ;;
                            esac
                        fi
                    fi
                fi
            done
            rm -rf "$_adv_tmpdir"

            if [ "$container_count" -gt 0 ]; then
                local cpu_display="${total_cpu}%"
                [ "$container_count" -gt 1 ] && cpu_display="${total_cpu}% (${container_count} containers)"
                local mem_display="${total_mem_mib}MiB"
                if [ -n "$first_mem_limit" ] && [ "$container_count" -gt 1 ]; then
                    mem_display="${total_mem_mib}MiB (${container_count}x ${first_mem_limit})"
                elif [ -n "$first_mem_limit" ]; then
                    mem_display="${total_mem_mib}MiB / ${first_mem_limit}"
                fi
                printf "${CYAN}║${NC} CPU: ${YELLOW}%s${NC}  Mem: ${YELLOW}%s${NC}  Clients: ${GREEN}%d${NC}\033[K\n" "$cpu_display" "$mem_display" "$total_conn"
                local up_display=$(format_bytes "$total_up_bytes")
                local down_display=$(format_bytes "$total_down_bytes")
                printf "${CYAN}║${NC} Upload: ${GREEN}%s${NC}    Download: ${GREEN}%s${NC}\033[K\n" "$up_display" "$down_display"
            else
                echo -e "${CYAN}║${NC} ${RED}No Containers Running${NC}\033[K"
            fi

            # Network info
            local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
            local iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
            printf "${CYAN}║${NC} Net: ${GREEN}%s${NC} (%s)\033[K\n" "${ip:-N/A}" "${iface:-?}"

            echo -e "${CYAN}╠${D}${NC}\033[K"

            # Load tracker data
            local total_active=0 total_in=0 total_out=0
            unset cips cbw_in cbw_out
            declare -A cips cbw_in cbw_out

            if [ -s "$persist_dir/cumulative_data" ]; then
                while IFS='|' read -r country from_bytes to_bytes; do
                    [ -z "$country" ] && continue
                    from_bytes=$(printf '%.0f' "${from_bytes:-0}" 2>/dev/null) || from_bytes=0
                    to_bytes=$(printf '%.0f' "${to_bytes:-0}" 2>/dev/null) || to_bytes=0
                    cbw_in["$country"]=$from_bytes
                    cbw_out["$country"]=$to_bytes
                    total_in=$((total_in + from_bytes))
                    total_out=$((total_out + to_bytes))
                done < "$persist_dir/cumulative_data"
            fi

            if [ -s "$persist_dir/cumulative_ips" ]; then
                while IFS='|' read -r country ip_addr; do
                    [ -z "$country" ] && continue
                    cips["$country"]=$((${cips["$country"]:-0} + 1))
                    total_active=$((total_active + 1))
                done < "$persist_dir/cumulative_ips"
            fi

            local tstat="${RED}Off${NC}"; is_tracker_active && tstat="${GREEN}On${NC}"
            printf "${CYAN}║${NC} Tracker: %b  Clients: ${GREEN}%s${NC}  Unique IPs: ${YELLOW}%s${NC}  In: ${GREEN}%s${NC}  Out: ${YELLOW}%s${NC}\033[K\n" "$tstat" "$(format_number $total_conn)" "$(format_number $total_active)" "$(format_bytes $total_in)" "$(format_bytes $total_out)"

            # TOP 5 by Unique IPs (from tracker)
            echo -e "${CYAN}╠─── ${CYAN}TOP 5 BY UNIQUE IPs${NC} ${DIM}(tracked)${NC}\033[K"
            local total_traffic=$((total_in + total_out))
            if [ "$total_conn" -gt 0 ] && [ "$total_active" -gt 0 ]; then
                for c in "${!cips[@]}"; do echo "${cips[$c]}|$c"; done | sort -t'|' -k1 -nr | head -7 | while IFS='|' read -r active_cnt country; do
                    local peers=$(( (active_cnt * total_conn) / total_active ))
                    [ "$peers" -eq 0 ] && [ "$active_cnt" -gt 0 ] && peers=1
                    local pct=$((peers * 100 / total_conn))
                    local blen=$((pct / 8)); [ "$blen" -lt 1 ] && blen=1; [ "$blen" -gt 14 ] && blen=14
                    local bfill=""; for ((i=0; i<blen; i++)); do bfill+="█"; done
                    printf "${CYAN}║${NC} %-16.16s %3d%% ${CYAN}%-14s${NC} (%s IPs)\033[K\n" "$country" "$pct" "$bfill" "$(format_number $peers)"
                done
            elif [ "$total_traffic" -gt 0 ]; then
                for c in "${!cbw_in[@]}"; do
                    local bytes=$(( ${cbw_in[$c]:-0} + ${cbw_out[$c]:-0} ))
                    echo "${bytes}|$c"
                done | sort -t'|' -k1 -nr | head -7 | while IFS='|' read -r bytes country; do
                    local pct=$((bytes * 100 / total_traffic))
                    local blen=$((pct / 8)); [ "$blen" -lt 1 ] && blen=1; [ "$blen" -gt 14 ] && blen=14
                    local bfill=""; for ((i=0; i<blen; i++)); do bfill+="█"; done
                    printf "${CYAN}║${NC} %-16.16s %3d%% ${CYAN}%-14s${NC} (%9s)\033[K\n" "$country" "$pct" "$bfill" "by traffic"
                done
            else
                echo -e "${CYAN}║${NC} No data yet\033[K"
            fi

            # TOP 5 by Download
            echo -e "${CYAN}╠─── ${GREEN}TOP 5 BY DOWNLOAD${NC} ${DIM}(inbound traffic)${NC}\033[K"
            if [ "$total_in" -gt 0 ]; then
                for c in "${!cbw_in[@]}"; do echo "${cbw_in[$c]}|$c"; done | sort -t'|' -k1 -nr | head -7 | while IFS='|' read -r bytes country; do
                    local pct=$((bytes * 100 / total_in))
                    local blen=$((pct / 8)); [ "$blen" -lt 1 ] && blen=1; [ "$blen" -gt 14 ] && blen=14
                    local bfill=""; for ((i=0; i<blen; i++)); do bfill+="█"; done
                    printf "${CYAN}║${NC} %-16.16s %3d%% ${GREEN}%-14s${NC} (%9s)\033[K\n" "$country" "$pct" "$bfill" "$(format_bytes $bytes)"
                done
            else
                echo -e "${CYAN}║${NC} No data yet\033[K"
            fi

            # TOP 5 by Upload
            echo -e "${CYAN}╠─── ${YELLOW}TOP 5 BY UPLOAD${NC} ${DIM}(outbound traffic)${NC}\033[K"
            if [ "$total_out" -gt 0 ]; then
                for c in "${!cbw_out[@]}"; do echo "${cbw_out[$c]}|$c"; done | sort -t'|' -k1 -nr | head -7 | while IFS='|' read -r bytes country; do
                    local pct=$((bytes * 100 / total_out))
                    local blen=$((pct / 8)); [ "$blen" -lt 1 ] && blen=1; [ "$blen" -gt 14 ] && blen=14
                    local bfill=""; for ((i=0; i<blen; i++)); do bfill+="█"; done
                    printf "${CYAN}║${NC} %-16.16s %3d%% ${YELLOW}%-14s${NC} (%9s)\033[K\n" "$country" "$pct" "$bfill" "$(format_bytes $bytes)"
                done
            else
                echo -e "${CYAN}║${NC} No data yet\033[K"
            fi

            echo -e "${CYAN}╚${L}${NC}\033[K"
            printf "\033[J"
        fi

        # Progress bar at bottom
        printf "\033[${term_height};1H\033[K"
        printf "[${YELLOW}${bar}${NC}] Next refresh in %2ds  ${DIM}[q] Back${NC}" "$time_until_next"

        if read -t 1 -n 1 -s key < /dev/tty 2>/dev/null; then
            case "$key" in
                q|Q) exit_stats=1 ;;
            esac
        fi
    done

    echo -ne "\033[?25h"
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM
}

show_peers() {
    if [ "${TRACKER_ENABLED:-true}" = "false" ]; then
        echo ""
        echo -e "  ${YELLOW}⚠ Tracker is disabled.${NC}"
        echo -e "  Live peers by country requires the tracker to capture network traffic."
        echo ""
        echo -e "  To enable: Settings & Tools → Toggle tracker (d)"
        echo ""
        read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
        return
    fi

    local stop_peers=0
    trap 'stop_peers=1' SIGINT SIGTERM

    local persist_dir="$INSTALL_DIR/traffic_stats"

    if ! is_tracker_active; then
        setup_tracker_service 2>/dev/null || true
    fi

    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    printf "\033[2J\033[H"

    local EL="\033[K"
    local cycle_start=$(date +%s)
    local last_refresh=0

    while [ $stop_peers -eq 0 ]; do
        local now=$(date +%s)
        local term_height=$(stty size </dev/tty 2>/dev/null | awk '{print $1}')
        [ -z "$term_height" ] || [ "$term_height" -lt 10 ] 2>/dev/null && term_height=$(tput lines 2>/dev/null || echo "${LINES:-24}")
        local cycle_elapsed=$(( (now - cycle_start) % 15 ))
        local time_left=$((15 - cycle_elapsed))

        # Progress bar
        local bar=""
        for ((i=0; i<cycle_elapsed; i++)); do bar+="●"; done
        for ((i=cycle_elapsed; i<15; i++)); do bar+="○"; done

        # Refresh data every 15 seconds or first run
        if [ $((now - last_refresh)) -ge 15 ] || [ "$last_refresh" -eq 0 ]; then
            last_refresh=$now
            cycle_start=$now

            printf "\033[H"

            echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}${EL}"
            echo -e "${CYAN}║${NC}  ${BOLD}LIVE PEER TRAFFIC BY COUNTRY${NC}                     ${DIM}[q] Back${NC}  ${EL}"
            echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════╣${NC}${EL}"
            printf "${CYAN}║${NC} Last Update: %-42s ${GREEN}[LIVE]${NC}${EL}\n" "$(date +%H:%M:%S)"
            echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}${EL}"
            echo -e "${EL}"

            # Load tracker data
            unset cumul_from cumul_to total_ips_count 2>/dev/null
            declare -A cumul_from cumul_to total_ips_count

            local grand_in=0 grand_out=0

            if [ -s "$persist_dir/cumulative_data" ]; then
                while IFS='|' read -r c f t; do
                    [ -z "$c" ] && continue
                    [[ "$c" == *"can't"* || "$c" == *"error"* ]] && continue
                    f=$(printf '%.0f' "${f:-0}" 2>/dev/null) || f=0
                    t=$(printf '%.0f' "${t:-0}" 2>/dev/null) || t=0
                    cumul_from["$c"]=$f
                    cumul_to["$c"]=$t
                    grand_in=$((grand_in + f))
                    grand_out=$((grand_out + t))
                done < "$persist_dir/cumulative_data"
            fi

            if [ -s "$persist_dir/cumulative_ips" ]; then
                while IFS='|' read -r c ip; do
                    [ -z "$c" ] && continue
                    [[ "$c" == *"can't"* || "$c" == *"error"* ]] && continue
                    total_ips_count["$c"]=$((${total_ips_count["$c"]:-0} + 1))
                done < "$persist_dir/cumulative_ips"
            fi

            # Get actual connected clients from docker logs (parallel)
            local total_clients=0
            local docker_ps_cache=$(docker ps --format '{{.Names}}' 2>/dev/null)
            local _peer_tmpdir=$(mktemp -d /tmp/.conduit_peer.XXXXXX)
            # mktemp already created the directory
            for ci in $(seq 1 $CONTAINER_COUNT); do
                local cname=$(get_container_name $ci)
                if echo "$docker_ps_cache" | grep -q "^${cname}$"; then
                    ( docker logs --tail 200 "$cname" 2>&1 | grep "\[STATS\]" | tail -1 > "$_peer_tmpdir/logs_${ci}" ) &
                fi
            done
            wait
            for ci in $(seq 1 $CONTAINER_COUNT); do
                if [ -f "$_peer_tmpdir/logs_${ci}" ]; then
                    local logs=$(cat "$_peer_tmpdir/logs_${ci}")
                    local conn=$(echo "$logs" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
                    [[ "$conn" =~ ^[0-9]+$ ]] && total_clients=$((total_clients + conn))
                fi
            done
            rm -rf "$_peer_tmpdir"

            echo -e "${EL}"

            # Parse snapshot for speed and country distribution
            unset snap_from_bytes snap_to_bytes snap_from_ips snap_to_ips 2>/dev/null
            declare -A snap_from_bytes snap_to_bytes snap_from_ips snap_to_ips
            local snap_total_from_ips=0 snap_total_to_ips=0
            if [ -s "$persist_dir/tracker_snapshot" ]; then
                while IFS='|' read -r dir c bytes ip; do
                    [ -z "$c" ] && continue
                    [[ "$c" == *"can't"* || "$c" == *"error"* ]] && continue
                    bytes=$(printf '%.0f' "${bytes:-0}" 2>/dev/null) || bytes=0
                    if [ "$dir" = "FROM" ]; then
                        snap_from_bytes["$c"]=$(( ${snap_from_bytes["$c"]:-0} + bytes ))
                        snap_from_ips["$c|$ip"]=1
                    elif [ "$dir" = "TO" ]; then
                        snap_to_bytes["$c"]=$(( ${snap_to_bytes["$c"]:-0} + bytes ))
                        snap_to_ips["$c|$ip"]=1
                    fi
                done < "$persist_dir/tracker_snapshot"
            fi

            # Count unique snapshot IPs per country + totals
            unset snap_from_ip_cnt snap_to_ip_cnt 2>/dev/null
            declare -A snap_from_ip_cnt snap_to_ip_cnt
            for k in "${!snap_from_ips[@]}"; do
                local sc="${k%%|*}"
                snap_from_ip_cnt["$sc"]=$(( ${snap_from_ip_cnt["$sc"]:-0} + 1 ))
                snap_total_from_ips=$((snap_total_from_ips + 1))
            done
            for k in "${!snap_to_ips[@]}"; do
                local sc="${k%%|*}"
                snap_to_ip_cnt["$sc"]=$(( ${snap_to_ip_cnt["$sc"]:-0} + 1 ))
                snap_total_to_ips=$((snap_total_to_ips + 1))
            done

            # TOP 10 TRAFFIC FROM (peers connecting to you)
            echo -e "${GREEN}${BOLD} 📥 TOP 10 TRAFFIC FROM ${NC}${DIM}(peers connecting to you)${NC}${EL}"
            echo -e "${EL}"
            printf " ${BOLD}%-26s %10s %12s  %s${NC}${EL}\n" "Country" "Total" "Speed" "Clients"
            echo -e "${EL}"
            if [ "$grand_in" -gt 0 ]; then
                while IFS='|' read -r bytes country; do
                    [ -z "$country" ] && continue
                    local snap_b=${snap_from_bytes[$country]:-0}
                    local speed_val=$((snap_b / 15))
                    local speed_str=$(format_bytes $speed_val)
                    local ips_all=${total_ips_count[$country]:-0}
                    # Estimate clients per country using snapshot distribution
                    local snap_cnt=${snap_from_ip_cnt[$country]:-0}
                    local est_clients=0
                    if [ "$snap_total_from_ips" -gt 0 ] && [ "$snap_cnt" -gt 0 ]; then
                        est_clients=$(( (snap_cnt * total_clients) / snap_total_from_ips ))
                        [ "$est_clients" -eq 0 ] && [ "$snap_cnt" -gt 0 ] && est_clients=1
                    fi
                    printf " ${GREEN}%-26.26s${NC} %10s %10s/s  %s${EL}\n" "$country" "$(format_bytes $bytes)" "$speed_str" "$(format_number $est_clients)"
                done < <(for c in "${!cumul_from[@]}"; do echo "${cumul_from[$c]:-0}|$c"; done | sort -t'|' -k1 -nr | head -10)
            else
                echo -e " ${DIM}Waiting for data...${NC}${EL}"
            fi
            echo -e "${EL}"

            # TOP 10 TRAFFIC TO (data sent to peers)
            echo -e "${YELLOW}${BOLD} 📤 TOP 10 TRAFFIC TO ${NC}${DIM}(data sent to peers)${NC}${EL}"
            echo -e "${EL}"
            printf " ${BOLD}%-26s %10s %12s  %s${NC}${EL}\n" "Country" "Total" "Speed" "Clients"
            echo -e "${EL}"
            if [ "$grand_out" -gt 0 ]; then
                while IFS='|' read -r bytes country; do
                    [ -z "$country" ] && continue
                    local snap_b=${snap_to_bytes[$country]:-0}
                    local speed_val=$((snap_b / 15))
                    local speed_str=$(format_bytes $speed_val)
                    local ips_all=${total_ips_count[$country]:-0}
                    local snap_cnt=${snap_to_ip_cnt[$country]:-0}
                    local est_clients=0
                    if [ "$snap_total_to_ips" -gt 0 ] && [ "$snap_cnt" -gt 0 ]; then
                        est_clients=$(( (snap_cnt * total_clients) / snap_total_to_ips ))
                        [ "$est_clients" -eq 0 ] && [ "$snap_cnt" -gt 0 ] && est_clients=1
                    fi
                    printf " ${YELLOW}%-26.26s${NC} %10s %10s/s  %s${EL}\n" "$country" "$(format_bytes $bytes)" "$speed_str" "$(format_number $est_clients)"
                done < <(for c in "${!cumul_to[@]}"; do echo "${cumul_to[$c]:-0}|$c"; done | sort -t'|' -k1 -nr | head -10)
            else
                echo -e " ${DIM}Waiting for data...${NC}${EL}"
            fi

            echo -e "${EL}"
            printf "\033[J"
        fi

        # Progress bar at bottom
        printf "\033[${term_height};1H${EL}"
        printf "[${YELLOW}${bar}${NC}] Next refresh in %2ds  ${DIM}[q] Back${NC}" "$time_left"

        if read -t 1 -n 1 -s key < /dev/tty 2>/dev/null; then
            case "$key" in q|Q) stop_peers=1 ;; esac
        fi
    done
    echo -ne "\033[?25h"
    tput rmcup 2>/dev/null || true
    rm -f /tmp/conduit_peers_sorted
    trap - SIGINT SIGTERM
}

get_net_speed() {
    # Calculate System Network Speed (Active 0.5s Sample)
    # Returns: "RX_MBPS TX_MBPS"
    local iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    [ -z "$iface" ] && iface=$(ip route list default 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    
    if [ -n "$iface" ] && [ -f "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        local rx1=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        local tx1=$(cat /sys/class/net/$iface/statistics/tx_bytes)
        
        sleep 0.5
        
        local rx2=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        local tx2=$(cat /sys/class/net/$iface/statistics/tx_bytes)
        
        # Calculate Delta (Bytes)
        local rx_delta=$((rx2 - rx1))
        local tx_delta=$((tx2 - tx1))
        
        # Convert to Mbps: (bytes * 8 bits) / (0.5 sec * 1,000,000)
        # Formula simplified: bytes * 16 / 1000000
        
        local rx_mbps=$(awk -v b="$rx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
        local tx_mbps=$(awk -v b="$tx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
        
        echo "$rx_mbps $tx_mbps"
    else
        echo "0.00 0.00"
    fi
}

# Show detailed info about dashboard metrics
# Info page 1: Traffic & Bandwidth Explained
show_info_traffic() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  TRAFFIC & BANDWIDTH EXPLAINED${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Traffic (current session)${NC}"
    echo -e "  ${BOLD}Source:${NC}     Container logs ([STATS] lines from Conduit)"
    echo -e "  ${BOLD}Measures:${NC}   Application-level payload data"
    echo -e "  ${BOLD}Meaning:${NC}    Actual content delivered to/from users"
    echo -e "  ${BOLD}Resets:${NC}     When containers restart"
    echo ""
    echo -e "${YELLOW}Top 5 Upload/Download (cumulative)${NC}"
    echo -e "  ${BOLD}Source:${NC}     Network tracker (tcpdump on interface)"
    echo -e "  ${BOLD}Measures:${NC}   Network-level bytes on the wire"
    echo -e "  ${BOLD}Meaning:${NC}    Actual bandwidth used (what your ISP sees)"
    echo -e "  ${BOLD}Resets:${NC}     Via Settings > Reset tracker data"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}WHY ARE THESE NUMBERS DIFFERENT?${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  The tracker typically shows ${YELLOW}5-20x more${NC} traffic than container stats."
    echo -e "  This is ${GREEN}normal${NC} for encrypted tunneling proxies like Conduit."
    echo ""
    echo -e "  ${BOLD}The difference is protocol overhead:${NC}"
    echo -e "    • TLS/encryption framing"
    echo -e "    • Tunnel protocol headers"
    echo -e "    • TCP acknowledgments (ACKs)"
    echo -e "    • Keep-alive packets"
    echo -e "    • Connection handshakes"
    echo -e "    • Retransmissions"
    echo ""
    echo -e "  ${BOLD}Example:${NC}"
    echo -e "    Container reports: 10 GB payload delivered"
    echo -e "    Network actual:    60 GB bandwidth used"
    echo -e "    Overhead ratio:    6x (typical for encrypted tunnels)"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    read -n 1 -s -r -p "  Press any key to go back..." < /dev/tty
}

# Info page 2: Network Mode & Docker
show_info_network() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  NETWORK MODE & DOCKER${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Why --network=host mode?${NC}"
    echo ""
    echo -e "  Conduit containers run with ${YELLOW}--network=host${NC} for best performance."
    echo -e "  This mode gives containers direct access to the host's network stack,"
    echo -e "  eliminating Docker's network bridge overhead and reducing latency."
    echo ""
    echo -e "${YELLOW}The trade-off${NC}"
    echo ""
    echo -e "  Docker cannot track per-container network I/O in host mode."
    echo -e "  Running 'docker stats' will show ${DIM}0B / 0B${NC} for network - this is"
    echo -e "  expected behavior, not a bug."
    echo ""
    echo -e "${YELLOW}Our solution${NC}"
    echo ""
    echo -e "  • ${BOLD}Container traffic:${NC} Parsed from Conduit's own [STATS] log lines"
    echo -e "  • ${BOLD}Network traffic:${NC}   Captured via tcpdump on the host interface"
    echo -e "  • Both methods work reliably with --network=host mode"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}TECHNICAL DETAILS${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Container stats:${NC}"
    echo -e "    Parsed from: docker logs [container] | grep '[STATS]'"
    echo -e "    Fields:      Up (upload), Down (download), Connected, Uptime"
    echo -e "    Scope:       Per-container, aggregated for display"
    echo ""
    echo -e "  ${BOLD}Tracker stats:${NC}"
    echo -e "    Captured by: tcpdump on primary network interface"
    echo -e "    Processed:   GeoIP lookup for country attribution"
    echo -e "    Storage:     /opt/conduit/traffic_stats/cumulative_data"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    read -n 1 -s -r -p "  Press any key to go back..." < /dev/tty
}

# Info page 3: Which Numbers To Use
show_info_client_stats() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  PEAK, AVERAGE & CLIENT HISTORY${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}What these numbers mean${NC}"
    echo ""
    echo -e "  ${BOLD}Peak${NC}      Highest number of connected clients since container"
    echo -e "            started. Useful to see your maximum capacity usage."
    echo ""
    echo -e "  ${BOLD}Avg${NC}       Average connected clients over time. Gives you a"
    echo -e "            realistic picture of typical load."
    echo ""
    echo -e "  ${BOLD}6h/12h/24h${NC} How many clients were connected at that time ago."
    echo -e "            Shows '-' if no data exists for that time."
    echo ""
    echo -e "${YELLOW}When does data reset?${NC}"
    echo ""
    echo -e "  All stats reset when ${BOLD}ALL${NC} containers restart."
    echo -e "  If only some containers restart, data is preserved."
    echo -e "  Closing the dashboard does ${BOLD}NOT${NC} reset any data."
    echo ""
    echo -e "${YELLOW}Tracker ON vs OFF${NC}"
    echo ""
    echo -e "  ┌──────────────┬─────────────────────┬─────────────────────┐"
    echo -e "  │ ${BOLD}Feature${NC}      │ ${GREEN}Tracker ON${NC}          │ ${RED}Tracker OFF${NC}         │"
    echo -e "  ├──────────────┼─────────────────────┼─────────────────────┤"
    echo -e "  │ Peak         │ Records 24/7        │ Only when dashboard │"
    echo -e "  │              │                     │ is open             │"
    echo -e "  ├──────────────┼─────────────────────┼─────────────────────┤"
    echo -e "  │ Avg          │ All time average    │ Only times when     │"
    echo -e "  │              │                     │ dashboard was open  │"
    echo -e "  ├──────────────┼─────────────────────┼─────────────────────┤"
    echo -e "  │ 6h/12h/24h   │ Shows data even if  │ Shows '-' if dash   │"
    echo -e "  │              │ dashboard was closed│ wasn't open then    │"
    echo -e "  └──────────────┴─────────────────────┴─────────────────────┘"
    echo ""
    echo -e "  ${DIM}Tip: Keep tracker enabled for complete, accurate stats.${NC}"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    read -n 1 -s -r -p "  Press any key to go back..." < /dev/tty
}

show_info_which_numbers() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  WHICH NUMBERS SHOULD I USE?${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}For bandwidth & cost planning${NC}"
    echo ""
    echo -e "  Use ${BOLD}Top 5 Upload/Download${NC} (tracker) numbers"
    echo ""
    echo -e "    → This is what your ISP bills you for"
    echo -e "    → This is your actual network usage"
    echo -e "    → Use this for server cost calculations"
    echo -e "    → Use this to monitor bandwidth caps"
    echo ""
    echo -e "${YELLOW}For user impact metrics${NC}"
    echo ""
    echo -e "  Use ${BOLD}Traffic (current session)${NC} numbers"
    echo ""
    echo -e "    → This is actual content delivered to users"
    echo -e "    → This matches Conduit's internal reporting"
    echo -e "    → Use this to measure user activity"
    echo -e "    → Use this to compare with Psiphon stats"
    echo ""
    echo -e "${YELLOW}Quick reference${NC}"
    echo ""
    echo -e "  ┌─────────────────────┬─────────────────────────────────────┐"
    echo -e "  │ ${BOLD}Question${NC}            │ ${BOLD}Use This${NC}                            │"
    echo -e "  ├─────────────────────┼─────────────────────────────────────┤"
    echo -e "  │ ISP bandwidth used? │ Top 5 (tracker)                     │"
    echo -e "  │ User data served?   │ Traffic (session)                   │"
    echo -e "  │ Monthly costs?      │ Top 5 (tracker)                     │"
    echo -e "  │ Users helped?       │ Traffic (session) + Connections     │"
    echo -e "  └─────────────────────┴─────────────────────────────────────┘"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    read -n 1 -s -r -p "  Press any key to go back..." < /dev/tty
}

show_info_snowflake() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SNOWFLAKE PROXY - WHAT IS IT?${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}What is Snowflake?${NC}"
    echo -e "  Snowflake is a pluggable transport for ${BOLD}Tor${NC}, developed by"
    echo -e "  the Tor Project. It helps users in heavily censored countries"
    echo -e "  (like Iran, China, Russia) bypass internet censorship by"
    echo -e "  disguising Tor traffic as regular WebRTC video calls."
    echo ""
    echo -e "${YELLOW}How Does It Work?${NC}"
    echo -e "  ${BOLD}1.${NC} A censored user opens Tor Browser with Snowflake enabled"
    echo -e "  ${BOLD}2.${NC} Their traffic is routed through ${CYAN}your proxy${NC} via WebRTC"
    echo -e "  ${BOLD}3.${NC} To censors, it looks like a normal video call"
    echo -e "  ${BOLD}4.${NC} Your proxy forwards traffic to the Tor network"
    echo ""
    echo -e "  ${DIM}Censored User${NC} --WebRTC--> ${CYAN}Your Snowflake${NC} --> ${GREEN}Tor Network${NC} --> Internet"
    echo ""
    echo -e "${YELLOW}Why Keep It Running?${NC}"
    echo -e "  ${GREEN}•${NC} Each proxy helps ${BOLD}dozens of users simultaneously${NC}"
    echo -e "  ${GREEN}•${NC} More proxies = harder for censors to block"
    echo -e "  ${GREEN}•${NC} Uses minimal resources (0.5 CPU, 256MB RAM default)"
    echo -e "  ${GREEN}•${NC} No port forwarding needed - works behind NAT"
    echo -e "  ${GREEN}•${NC} Traffic is ${BOLD}end-to-end encrypted${NC} - you cannot see it"
    echo ""
    echo -e "${YELLOW}Is It Safe?${NC}"
    echo -e "  ${GREEN}✓${NC} All traffic is encrypted end-to-end"
    echo -e "  ${GREEN}✓${NC} You are a ${BOLD}relay${NC}, not an exit node - traffic exits"
    echo -e "    through Tor's own exit nodes, not your server"
    echo -e "  ${GREEN}✓${NC} Your IP is not exposed to the websites users visit"
    echo -e "  ${GREEN}✓${NC} Endorsed by the Tor Project as a safe way to help"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    read -n 1 -s -r -p "  Press any key to go back..." < /dev/tty
}

show_info_safety() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SAFETY & LEGAL - IS RUNNING A NODE SAFE?${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Am I Responsible For What Users Browse?${NC}"
    echo -e "  ${GREEN}No.${NC} You are providing ${BOLD}infrastructure${NC}, not content."
    echo -e "  This is legally similar to running a Wi-Fi hotspot or"
    echo -e "  being an ISP. You do not control, monitor, or select"
    echo -e "  the traffic that flows through your node."
    echo ""
    echo -e "${YELLOW}Can I See User Traffic?${NC}"
    echo -e "  ${GREEN}No.${NC} All connections are ${BOLD}end-to-end encrypted${NC}."
    echo -e "  You cannot inspect, log, or read user traffic."
    echo -e "  Psiphon uses strong encryption (TLS/DTLS) for all tunnels."
    echo ""
    echo -e "${YELLOW}What About Snowflake Traffic?${NC}"
    echo -e "  Snowflake proxies relay traffic to the ${BOLD}Tor network${NC}."
    echo -e "  Your server is a ${CYAN}middle relay${NC}, NOT an exit node."
    echo -e "  Websites see Tor exit node IPs, ${GREEN}never your IP${NC}."
    echo ""
    echo -e "${YELLOW}What Data Is Stored?${NC}"
    echo -e "  ${GREEN}•${NC} No user browsing data is stored on your server"
    echo -e "  ${GREEN}•${NC} Only aggregate stats: connection counts, bandwidth totals"
    echo -e "  ${GREEN}•${NC} IP addresses in tracker are anonymized country-level only"
    echo -e "  ${GREEN}•${NC} Full uninstall removes everything: ${CYAN}conduit uninstall${NC}"
    echo ""
    echo -e "${YELLOW}Legal Protections${NC}"
    echo -e "  In most jurisdictions, relay operators are protected by:"
    echo -e "  ${GREEN}•${NC} ${BOLD}Common carrier${NC} / safe harbor provisions"
    echo -e "  ${GREEN}•${NC} Section 230 (US) - intermediary liability protection"
    echo -e "  ${GREEN}•${NC} EU E-Commerce Directive Art. 12 - mere conduit defense"
    echo -e "  ${GREEN}•${NC} Psiphon is a ${BOLD}registered Canadian non-profit${NC} backed by"
    echo -e "    organizations including the US State Department"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}Bottom line:${NC} Running a Conduit node is safe. You are helping"
    echo -e "  people access the free internet, and you are legally"
    echo -e "  protected as an infrastructure provider."
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    read -n 1 -s -r -p "  Press any key to go back..." < /dev/tty
}

# Main info menu
show_dashboard_info() {
    while true; do
        clear
        echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  UNDERSTANDING YOUR DASHBOARD${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  Select a topic to learn more:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  Traffic & Bandwidth Explained"
        echo -e "         ${DIM}Why tracker shows more than container stats${NC}"
        echo ""
        echo -e "    ${CYAN}[2]${NC}  Network Mode & Docker"
        echo -e "         ${DIM}Why we use --network=host and how stats work${NC}"
        echo ""
        echo -e "    ${CYAN}[3]${NC}  Which Numbers To Use"
        echo -e "         ${DIM}Choosing the right metric for your needs${NC}"
        echo ""
        echo -e "    ${CYAN}[4]${NC}  Peak, Average & Client History"
        echo -e "         ${DIM}Understanding Peak, Avg, and 6h/12h/24h stats${NC}"
        echo ""
        echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${DIM}Press ${NC}${BOLD}1${NC}${DIM}-${NC}${BOLD}4${NC}${DIM} to view a topic, or any other key to go back${NC}"

        read -n 1 -s -r key < /dev/tty
        case "$key" in
            1) show_info_traffic ;;
            2) show_info_network ;;
            3) show_info_which_numbers ;;
            4) show_info_client_stats ;;
            *) return ;;
        esac
    done
}

CONNECTION_HISTORY_FILE="/opt/conduit/traffic_stats/connection_history"
_LAST_HISTORY_RECORD=0

PEAK_CONNECTIONS_FILE="/opt/conduit/traffic_stats/peak_connections"
_PEAK_CONNECTIONS=0
_PEAK_CONTAINER_START=""

get_container_start_time() {
    local earliest=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i 2>/dev/null)
        [ -z "$cname" ] && continue
        local start=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
        [ -z "$start" ] && continue
        if [ -z "$earliest" ] || [[ "$start" < "$earliest" ]]; then
            earliest="$start"
        fi
    done
    echo "$earliest"
}

# Load peak from file (resets if containers restarted)
load_peak_connections() {
    local current_start=$(get_container_start_time)

    if [ -f "$PEAK_CONNECTIONS_FILE" ]; then
        local saved_start=$(head -1 "$PEAK_CONNECTIONS_FILE" 2>/dev/null)
        local saved_peak=$(tail -1 "$PEAK_CONNECTIONS_FILE" 2>/dev/null)

        # If container start time matches, restore peak
        if [ "$saved_start" = "$current_start" ] && [ -n "$saved_peak" ]; then
            _PEAK_CONNECTIONS=$saved_peak
            _PEAK_CONTAINER_START="$current_start"
            return
        fi
    fi

    # Reset peak on container restart
    _PEAK_CONNECTIONS=0
    _PEAK_CONTAINER_START="$current_start"
    save_peak_connections
}

# Save peak to file
save_peak_connections() {
    mkdir -p "$(dirname "$PEAK_CONNECTIONS_FILE")" 2>/dev/null
    echo "$_PEAK_CONTAINER_START" > "$PEAK_CONNECTIONS_FILE"
    echo "$_PEAK_CONNECTIONS" >> "$PEAK_CONNECTIONS_FILE"
}

CONNECTION_HISTORY_START_FILE="/opt/conduit/traffic_stats/connection_history_start"
_CONNECTION_HISTORY_CONTAINER_START=""

# Check and reset connection history if containers restarted
check_connection_history_reset() {
    local current_start=$(get_container_start_time)

    # Check if we have a saved container start time
    if [ -f "$CONNECTION_HISTORY_START_FILE" ]; then
        local saved_start=$(cat "$CONNECTION_HISTORY_START_FILE" 2>/dev/null)
        if [ "$saved_start" = "$current_start" ] && [ -n "$saved_start" ]; then
            # Same container session, keep history
            _CONNECTION_HISTORY_CONTAINER_START="$current_start"
            return
        fi
    fi

    # Reset history on container restart
    _CONNECTION_HISTORY_CONTAINER_START="$current_start"
    mkdir -p "$(dirname "$CONNECTION_HISTORY_START_FILE")" 2>/dev/null
    echo "$current_start" > "$CONNECTION_HISTORY_START_FILE"

    rm -f "$CONNECTION_HISTORY_FILE" 2>/dev/null
    _AVG_CONN_CACHE=""
    _AVG_CONN_CACHE_TIME=0
}

record_connection_history() {
    local connected=$1
    local connecting=$2
    local now=$(date +%s)

    if [ $(( now - _LAST_HISTORY_RECORD )) -lt 300 ]; then return; fi
    _LAST_HISTORY_RECORD=$now

    check_connection_history_reset
    mkdir -p "$(dirname "$CONNECTION_HISTORY_FILE")" 2>/dev/null
    echo "${now}|${connected}|${connecting}" >> "$CONNECTION_HISTORY_FILE"

    # Prune entries older than 25 hours
    local cutoff=$((now - 90000))
    if [ -f "$CONNECTION_HISTORY_FILE" ]; then
        awk -F'|' -v cutoff="$cutoff" '$1 >= cutoff' "$CONNECTION_HISTORY_FILE" > "${CONNECTION_HISTORY_FILE}.tmp" 2>/dev/null
        mv -f "${CONNECTION_HISTORY_FILE}.tmp" "$CONNECTION_HISTORY_FILE" 2>/dev/null
    fi
}

_AVG_CONN_CACHE=""
_AVG_CONN_CACHE_TIME=0

get_average_connections() {
    local now=$(date +%s)
    if [ -n "$_AVG_CONN_CACHE" ] && [ $((now - _AVG_CONN_CACHE_TIME)) -lt 300 ]; then
        echo "$_AVG_CONN_CACHE"
        return
    fi
    check_connection_history_reset

    if [ ! -f "$CONNECTION_HISTORY_FILE" ]; then
        _AVG_CONN_CACHE="-"
        _AVG_CONN_CACHE_TIME=$now
        echo "-"
        return
    fi

    local avg=$(awk -F'|' '
        NF >= 2 { sum += $2; count++ }
        END { if (count > 0) printf "%.0f", sum/count; else print "-" }
    ' "$CONNECTION_HISTORY_FILE" 2>/dev/null)

    _AVG_CONN_CACHE="${avg:--}"
    _AVG_CONN_CACHE_TIME=$now
    echo "$_AVG_CONN_CACHE"
}

declare -A _STATS_CACHE_UP _STATS_CACHE_DOWN _STATS_CACHE_CONN _STATS_CACHE_CING
_DOCKER_STATS_CACHE=""
_DOCKER_STATS_CYCLE=0
_NET_SPEED_CACHE=""
_SYSTEMD_CACHE=""

status_json() {
    local ts=$(date +%s)
    local hn=$(hostname 2>/dev/null || echo "unknown")
    hn="${hn//\"/}"
    hn="${hn//\\/}"

    local docker_names=$(docker ps --format '{{.Names}}' 2>/dev/null)
    local running_count=0
    local total_conn=0 total_cing=0
    local total_up_bytes=0 total_down_bytes=0

    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        if echo "$docker_names" | grep -q "^${cname}$"; then
            running_count=$((running_count + 1))
        fi
    done

    local _jt=$(mktemp -d /tmp/.conduit_json.XXXXXX)
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        if echo "$docker_names" | grep -q "^${cname}$"; then
            ( docker logs --tail 200 "$cname" 2>&1 | grep "\[STATS\]" | tail -1 > "$_jt/logs_$i" ) &
        fi
    done

    # Resource stats in parallel
    ( get_container_stats > "$_jt/cstats" ) &
    ( get_system_stats > "$_jt/sys" ) &
    wait

    # Parse container logs
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        if [ -f "$_jt/logs_$i" ]; then
            local logs=$(cat "$_jt/logs_$i")
            if [ -n "$logs" ]; then
                local conn cing up_b down_b
                IFS='|' read -r cing conn up_b down_b _ <<< $(echo "$logs" | awk '{
                    ci=0; co=0; up=""; down=""
                    for(j=1;j<=NF;j++){
                        if($j=="Connecting:") ci=$(j+1)+0
                        else if($j=="Connected:") co=$(j+1)+0
                        else if($j=="Up:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Down:/)break; up=up (up?" ":"") $k}}
                        else if($j=="Down:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Uptime:/)break; down=down (down?" ":"") $k}}
                    }
                    printf "%d|%d|%s|%s|", ci, co, up, down
                }')
                total_conn=$((total_conn + ${conn:-0}))
                total_cing=$((total_cing + ${cing:-0}))
                # Convert upload to bytes
                if [ -n "$up_b" ]; then
                    local ub=$(echo "$up_b" | awk '{
                        val=$1; unit=toupper($2)
                        if (unit ~ /^KB/) val*=1024
                        else if (unit ~ /^MB/) val*=1048576
                        else if (unit ~ /^GB/) val*=1073741824
                        else if (unit ~ /^TB/) val*=1099511627776
                        printf "%.0f", val
                    }')
                    total_up_bytes=$((total_up_bytes + ${ub:-0}))
                fi
                # Convert download to bytes
                if [ -n "$down_b" ]; then
                    local db=$(echo "$down_b" | awk '{
                        val=$1; unit=toupper($2)
                        if (unit ~ /^KB/) val*=1024
                        else if (unit ~ /^MB/) val*=1048576
                        else if (unit ~ /^GB/) val*=1073741824
                        else if (unit ~ /^TB/) val*=1099511627776
                        printf "%.0f", val
                    }')
                    total_down_bytes=$((total_down_bytes + ${db:-0}))
                fi
            fi
        fi
    done

    # Uptime calculation
    local uptime_sec=0
    local uptime_str="-"
    local earliest_start=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
        [ -z "$started" ] && continue
        local se=$(date -d "$started" +%s 2>/dev/null || echo 0)
        if [ -z "$earliest_start" ] || { [ "$se" -gt 0 ] && [ "$se" -lt "$earliest_start" ]; } 2>/dev/null; then
            earliest_start=$se
        fi
    done
    if [ -n "$earliest_start" ] && [ "$earliest_start" -gt 0 ] 2>/dev/null; then
        uptime_sec=$((ts - earliest_start))
        local d=$((uptime_sec / 86400)) h=$(( (uptime_sec % 86400) / 3600 )) m=$(( (uptime_sec % 3600) / 60 ))
        uptime_str="${d}d ${h}h ${m}m"
    fi

    # Parse resource stats
    local stats=$(cat "$_jt/cstats" 2>/dev/null)
    local sys_stats=$(cat "$_jt/sys" 2>/dev/null)
    rm -rf "$_jt"

    local raw_app_cpu=$(echo "$stats" | awk '{print $1}' | tr -d '%')
    local num_cores=$(get_cpu_cores)
    local app_cpu="0%"
    if [[ "$raw_app_cpu" =~ ^[0-9.]+$ ]]; then
        app_cpu=$(awk -v cpu="$raw_app_cpu" -v cores="$num_cores" 'BEGIN {printf "%.2f%%", cpu / cores}')
    fi
    local app_ram=$(echo "$stats" | awk '{print $2, $3, $4}')
    [ -z "$app_ram" ] && app_ram="-"

    local sys_cpu=$(echo "$sys_stats" | awk '{print $1}')
    local sys_temp=$(echo "$sys_stats" | awk '{print $2}')
    local sys_ram_used=$(echo "$sys_stats" | awk '{print $3}')
    local sys_ram_total=$(echo "$sys_stats" | awk '{print $4}')

    # Tracker stats
    local data_served=0 data_in=0 data_out=0 unique_ips=0
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file" ]; then
        local _ds
        _ds=$(awk -F'|' '{i+=$2+0; o+=$3+0} END{printf "%d %d", i, o}' "$data_file" 2>/dev/null)
        data_in=$(echo "$_ds" | awk '{print $1}')
        data_out=$(echo "$_ds" | awk '{print $2}')
        data_served=$((data_in + data_out))
    fi
    local ips_file="$INSTALL_DIR/traffic_stats/cumulative_ips"
    [ -s "$ips_file" ] && unique_ips=$(wc -l < "$ips_file" 2>/dev/null || echo 0)

    # Restart count
    local total_restarts=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local rc=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null || echo 0)
        total_restarts=$((total_restarts + ${rc:-0}))
    done

    # Status determination
    local status="stopped"
    [ "$running_count" -gt 0 ] && status="running"
    [ "$running_count" -gt 0 ] && [ "$running_count" -lt "${CONTAINER_COUNT:-1}" ] && status="degraded"

    # Build JSON
    printf '{"version":"%s",' "$VERSION"
    printf '"timestamp":%d,' "$ts"
    printf '"hostname":"%s",' "$hn"
    printf '"status":"%s",' "$status"
    printf '"containers":{"total":%d,"running":%d},' "${CONTAINER_COUNT:-1}" "$running_count"
    printf '"peers":{"connected":%d,"connecting":%d},' "$total_conn" "$total_cing"
    printf '"bandwidth":{"upload_bytes":%d,"download_bytes":%d,' "$total_up_bytes" "$total_down_bytes"
    printf '"upload_human":"%s","download_human":"%s"},' "$(format_bytes $total_up_bytes)" "$(format_bytes $total_down_bytes)"
    printf '"uptime":"%s","uptime_seconds":%d,' "$uptime_str" "$uptime_sec"
    printf '"sys_cpu":"%s","sys_temp":"%s",' "${sys_cpu:-0%}" "${sys_temp:--}"
    printf '"sys_ram_used":"%s","sys_ram_total":"%s",' "${sys_ram_used:-N/A}" "${sys_ram_total:-N/A}"
    printf '"app_cpu":"%s","app_ram":"%s",' "$app_cpu" "${app_ram:--}"
    printf '"data_served_bytes":%d,"data_served_human":"%s",' \
        "${data_served:-0}" "$(format_bytes ${data_served:-0})"
    printf '"tracker_in_bytes":%d,"tracker_out_bytes":%d,"unique_ips":%d,' \
        "${data_in:-0}" "${data_out:-0}" "${unique_ips:-0}"
    printf '"restarts":%d,' "$total_restarts"
    printf '"settings":{"max_clients":%d,"bandwidth":"%s","container_count":%d,"data_cap_gb":%d,"data_cap_up_gb":%d,"data_cap_down_gb":%d},' \
        "${MAX_CLIENTS:-200}" "${BANDWIDTH:-5}" "${CONTAINER_COUNT:-1}" "${DATA_CAP_GB:-0}" "${DATA_CAP_UP_GB:-0}" "${DATA_CAP_DOWN_GB:-0}"
    local sf_enabled="${SNOWFLAKE_ENABLED:-false}"
    local sf_running=false
    local sf_conn=0 sf_in=0 sf_out=0 sf_to=0
    if [ "$sf_enabled" = "true" ] && is_snowflake_running; then
        sf_running=true
        local sf_stats=$(get_snowflake_stats 2>/dev/null)
        sf_conn=$(echo "$sf_stats" | awk '{print $1+0}')
        sf_in=$(echo "$sf_stats" | awk '{print $2+0}')
        sf_out=$(echo "$sf_stats" | awk '{print $3+0}')
        sf_to=$(echo "$sf_stats" | awk '{print $4+0}')
    fi
    local sf_enabled_json="false" sf_running_json="false"
    [ "$sf_enabled" = "true" ] && sf_enabled_json="true"
    [ "$sf_running" = "true" ] && sf_running_json="true"
    printf '"snowflake":{"enabled":%s,"running":%s,"instances":%d,"connections":%d,"inbound_bytes":%d,"outbound_bytes":%d,"timeouts":%d}' \
        "$sf_enabled_json" "$sf_running_json" "${SNOWFLAKE_COUNT:-1}" "${sf_conn:-0}" "${sf_in:-0}" "${sf_out:-0}" "${sf_to:-0}"
    printf '}\n'
}

show_status() {
    local mode="${1:-normal}" # 'live' mode adds line clearing
    local EL=""
    if [ "$mode" == "live" ]; then
        EL="\033[K" # Erase Line escape code
    fi

    # Load peak connections from file (only once per session)
    if [ -z "$_PEAK_CONTAINER_START" ]; then
        load_peak_connections
    fi

    echo ""


    local docker_ps_cache=$(docker ps 2>/dev/null)
    local running_count=0
    declare -A _c_running _c_conn _c_cing _c_up _c_down
    local total_connecting=0
    local total_connected=0
    local uptime=""

    # Fetch all container logs in parallel
    local _st_tmpdir=$(mktemp -d /tmp/.conduit_st.XXXXXX)
    # mktemp already created the directory
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        _c_running[$i]=false
        _c_conn[$i]="0"
        _c_cing[$i]="0"
        _c_up[$i]=""
        _c_down[$i]=""

        if echo "$docker_ps_cache" | grep -q "[[:space:]]${cname}$"; then
            _c_running[$i]=true
            running_count=$((running_count + 1))
            ( docker logs --tail 200 "$cname" 2>&1 | grep "\[STATS\]" | tail -1 > "$_st_tmpdir/logs_${i}" ) &
        fi
    done
    wait

    for i in $(seq 1 $CONTAINER_COUNT); do
        if [ "${_c_running[$i]}" = true ] && [ -f "$_st_tmpdir/logs_${i}" ]; then
            local logs=$(cat "$_st_tmpdir/logs_${i}")
            if [ -n "$logs" ]; then
                IFS='|' read -r c_connecting c_connected c_up_val c_down_val c_uptime_val <<< $(echo "$logs" | awk '{
                    cing=0; conn=0; up=""; down=""; ut=""
                    for(j=1;j<=NF;j++){
                        if($j=="Connecting:") cing=$(j+1)+0
                        else if($j=="Connected:") conn=$(j+1)+0
                        else if($j=="Up:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Down:/)break; up=up (up?" ":"") $k}}
                        else if($j=="Down:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Uptime:/)break; down=down (down?" ":"") $k}}
                        else if($j=="Uptime:"){for(k=j+1;k<=NF;k++){ut=ut (ut?" ":"") $k}}
                    }
                    printf "%d|%d|%s|%s|%s", cing, conn, up, down, ut
                }')
                _c_conn[$i]="${c_connected:-0}"
                _c_cing[$i]="${c_connecting:-0}"
                _c_up[$i]="${c_up_val}"
                _c_down[$i]="${c_down_val}"
                # Update global cache with fresh data
                _STATS_CACHE_UP[$i]="${c_up_val}"
                _STATS_CACHE_DOWN[$i]="${c_down_val}"
                _STATS_CACHE_CONN[$i]="${c_connected:-0}"
                _STATS_CACHE_CING[$i]="${c_connecting:-0}"
                total_connecting=$((total_connecting + ${c_connecting:-0}))
                total_connected=$((total_connected + ${c_connected:-0}))
                if [ -z "$uptime" ]; then
                    uptime="${c_uptime_val}"
                fi
            else
                # No stats in logs - use cached values if available
                if [ -n "${_STATS_CACHE_UP[$i]}" ]; then
                    _c_up[$i]="${_STATS_CACHE_UP[$i]}"
                    _c_down[$i]="${_STATS_CACHE_DOWN[$i]}"
                    _c_conn[$i]="${_STATS_CACHE_CONN[$i]:-0}"
                    _c_cing[$i]="${_STATS_CACHE_CING[$i]:-0}"
                    total_connecting=$((total_connecting + ${_c_cing[$i]:-0}))
                    total_connected=$((total_connected + ${_c_conn[$i]:-0}))
                fi
            fi
        fi
    done
    rm -rf "$_st_tmpdir"
    local connecting=$total_connecting
    local connected=$total_connected
    _total_connected=$total_connected
    if [ "$connected" -gt "$_PEAK_CONNECTIONS" ] 2>/dev/null; then
        _PEAK_CONNECTIONS=$connected
        save_peak_connections
    fi

    local upload=""
    local download=""
    local total_up_bytes=0
    local total_down_bytes=0
    for i in $(seq 1 $CONTAINER_COUNT); do
        if [ -n "${_c_up[$i]}" ]; then
            local bytes=$(echo "${_c_up[$i]}" | awk '{
                val=$1; unit=toupper($2)
                if (unit ~ /^KB/) val*=1024
                else if (unit ~ /^MB/) val*=1048576
                else if (unit ~ /^GB/) val*=1073741824
                else if (unit ~ /^TB/) val*=1099511627776
                printf "%.0f", val
            }')
            total_up_bytes=$((total_up_bytes + ${bytes:-0}))
        fi
        if [ -n "${_c_down[$i]}" ]; then
            local bytes=$(echo "${_c_down[$i]}" | awk '{
                val=$1; unit=toupper($2)
                if (unit ~ /^KB/) val*=1024
                else if (unit ~ /^MB/) val*=1048576
                else if (unit ~ /^GB/) val*=1073741824
                else if (unit ~ /^TB/) val*=1099511627776
                printf "%.0f", val
            }')
            total_down_bytes=$((total_down_bytes + ${bytes:-0}))
        fi
    done
    if [ "$total_up_bytes" -gt 0 ]; then
        upload=$(awk -v b="$total_up_bytes" 'BEGIN {
            if (b >= 1099511627776) printf "%.2f TB", b/1099511627776
            else if (b >= 1073741824) printf "%.2f GB", b/1073741824
            else if (b >= 1048576) printf "%.2f MB", b/1048576
            else if (b >= 1024) printf "%.2f KB", b/1024
            else printf "%d B", b
        }')
    fi
    if [ "$total_down_bytes" -gt 0 ]; then
        download=$(awk -v b="$total_down_bytes" 'BEGIN {
            if (b >= 1099511627776) printf "%.2f TB", b/1099511627776
            else if (b >= 1073741824) printf "%.2f GB", b/1073741824
            else if (b >= 1048576) printf "%.2f MB", b/1048576
            else if (b >= 1024) printf "%.2f KB", b/1024
            else printf "%d B", b
        }')
    fi

    if [ "$running_count" -gt 0 ]; then

        # Run resource stat calls (docker stats + net speed cached every 2 cycles)
        local _rs_tmpdir=$(mktemp -d /tmp/.conduit_rs.XXXXXX)
        _DOCKER_STATS_CYCLE=$(( (_DOCKER_STATS_CYCLE + 1) % 2 ))
        if [ "$_DOCKER_STATS_CYCLE" -eq 1 ] || [ -z "$_DOCKER_STATS_CACHE" ]; then
            ( get_container_stats > "$_rs_tmpdir/cstats" ) &
            ( get_net_speed > "$_rs_tmpdir/net" ) &
        fi
        ( get_system_stats > "$_rs_tmpdir/sys" ) &
        wait

        local stats
        if [ -f "$_rs_tmpdir/cstats" ]; then
            stats=$(cat "$_rs_tmpdir/cstats" 2>/dev/null)
            _DOCKER_STATS_CACHE="$stats"
        else
            stats="$_DOCKER_STATS_CACHE"
        fi
        local sys_stats=$(cat "$_rs_tmpdir/sys" 2>/dev/null)
        local net_speed
        if [ -f "$_rs_tmpdir/net" ]; then
            net_speed=$(cat "$_rs_tmpdir/net" 2>/dev/null)
            _NET_SPEED_CACHE="$net_speed"
        else
            net_speed="$_NET_SPEED_CACHE"
        fi
        rm -rf "$_rs_tmpdir"

        # Normalize App CPU (Docker % / Cores)
        local raw_app_cpu=$(echo "$stats" | awk '{print $1}' | tr -d '%')
        local num_cores=$(get_cpu_cores)
        local app_cpu="0%"
        local app_cpu_display=""

        if [[ "$raw_app_cpu" =~ ^[0-9.]+$ ]]; then
             app_cpu=$(awk -v cpu="$raw_app_cpu" -v cores="$num_cores" 'BEGIN {printf "%.2f%%", cpu / cores}')
             if [ "$num_cores" -gt 1 ]; then
                 app_cpu_display="${app_cpu} (${raw_app_cpu}% vCPU)"
             else
                 app_cpu_display="${app_cpu}"
             fi
        else
             app_cpu="${raw_app_cpu}%"
             app_cpu_display="${app_cpu}"
        fi

        # Keep full "Used / Limit" string for App RAM
        local app_ram=$(echo "$stats" | awk '{print $2, $3, $4}')

        local sys_cpu=$(echo "$sys_stats" | awk '{print $1}')
        local sys_temp=$(echo "$sys_stats" | awk '{print $2}')
        local sys_ram_used=$(echo "$sys_stats" | awk '{print $3}')
        local sys_ram_total=$(echo "$sys_stats" | awk '{print $4}')
        local sys_ram_pct=$(echo "$sys_stats" | awk '{print $5}')
        local sys_cpu_display="$sys_cpu"
        [ "$sys_temp" != "-" ] && sys_cpu_display="${sys_cpu} (${sys_temp})"

        local rx_mbps=$(echo "$net_speed" | awk '{print $1}')
        local tx_mbps=$(echo "$net_speed" | awk '{print $2}')
        local net_display="↓ ${rx_mbps} Mbps  ↑ ${tx_mbps} Mbps"
        
        if [ -n "$upload" ] || [ "$connected" -gt 0 ] || [ "$connecting" -gt 0 ]; then
            local avg_conn=$(get_average_connections)
            local status_line="${BOLD}Status:${NC} ${GREEN}Running${NC}"
            [ -n "$uptime" ] && status_line="${status_line} (${uptime})"
            status_line="${status_line}  ${DIM}|${NC}  ${BOLD}Peak:${NC} ${CYAN}${_PEAK_CONNECTIONS}${NC}"
            status_line="${status_line}  ${DIM}|${NC}  ${BOLD}Avg:${NC} ${CYAN}${avg_conn}${NC}"
            echo -e "${status_line}${EL}"
            echo -e "  Containers: ${GREEN}${running_count}${NC}/${CONTAINER_COUNT}  Clients: ${GREEN}${connected}${NC} connected, ${YELLOW}${connecting}${NC} connecting${EL}"

            echo -e "${EL}"
            echo -e "${CYAN}═══ Traffic (current session) ═══${NC}${EL}"
            # Record connection history (every 5 min) — only if tracker is not running
            # to avoid double entries and race conditions on the history file
            if ! systemctl is-active conduit-tracker.service &>/dev/null 2>&1; then
                record_connection_history "$connected" "$connecting"
            fi
            # Get connection history snapshots (single-pass read)
            local conn_6h="-" conn_12h="-" conn_24h="-"
            check_connection_history_reset
            if [ -f "$CONNECTION_HISTORY_FILE" ]; then
                local _snap_now=$(date +%s)
                local _snap_result
                _snap_result=$(awk -F'|' -v now="$_snap_now" -v tol=1800 '
                    BEGIN { t6=now-21600; t12=now-43200; t24=now-86400; d6=tol+1; d12=tol+1; d24=tol+1; b6="-"; b12="-"; b24="-" }
                    {
                        d = ($1>t6) ? ($1-t6) : (t6-$1); if(d<d6){d6=d; b6=$2}
                        d = ($1>t12) ? ($1-t12) : (t12-$1); if(d<d12){d12=d; b12=$2}
                        d = ($1>t24) ? ($1-t24) : (t24-$1); if(d<d24){d24=d; b24=$2}
                    }
                    END { print b6 "|" b12 "|" b24 }
                ' "$CONNECTION_HISTORY_FILE" 2>/dev/null)
                IFS='|' read -r conn_6h conn_12h conn_24h <<< "$_snap_result"
            fi
            # Display traffic and history side by side
            printf "  Upload:   ${CYAN}%-12s${NC} ${DIM}|${NC} Clients: ${DIM}6h:${NC}${GREEN}%-4s${NC} ${DIM}12h:${NC}${GREEN}%-4s${NC} ${DIM}24h:${NC}${GREEN}%s${NC}${EL}\n" \
                "${upload:-0 B}" "${conn_6h}" "${conn_12h}" "${conn_24h}"
            printf "  Download: ${CYAN}%-12s${NC} ${DIM}|${NC}${EL}\n" "${download:-0 B}"

            echo -e "${EL}"
            echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu_display" "$sys_ram_used / $sys_ram_total"
            printf "  %-8s Net: ${YELLOW}%-43s${NC}${EL}\n" "Total:" "$net_display"


        else
             echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC}${EL}"
             echo -e "  Containers: ${GREEN}${running_count}${NC}/${CONTAINER_COUNT}${EL}"
             echo -e "${EL}"
             echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
             printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
             printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu_display" "$sys_ram_used / $sys_ram_total"
             printf "  %-8s Net: ${YELLOW}%-43s${NC}${EL}\n" "Total:" "$net_display"
             echo -e "${EL}"
             echo -e "  Stats:        ${YELLOW}Waiting for first stats...${NC}${EL}"
        fi
        
    else
        echo -e "${BOLD}Status:${NC} ${RED}Stopped${NC}${EL}"
    fi
    

    
    echo -e "${EL}"
    echo -e "${CYAN}═══ SETTINGS ═══${NC}${EL}"
    # Per-container overrides?
    local has_overrides=false
    for i in $(seq 1 $CONTAINER_COUNT); do
        local mc_var="MAX_CLIENTS_${i}"
        local bw_var="BANDWIDTH_${i}"
        if [ -n "${!mc_var}" ] || [ -n "${!bw_var}" ]; then
            has_overrides=true
            break
        fi
    done
    if [ "$has_overrides" = true ]; then
        echo -e "  Containers:   ${CONTAINER_COUNT}${EL}"
        for i in $(seq 1 $CONTAINER_COUNT); do
            local mc=$(get_container_max_clients $i)
            local bw=$(get_container_bandwidth $i)
            local bw_d="Unlimited"
            [ "$bw" != "-1" ] && bw_d="${bw} Mbps"
            printf "  %-12s clients: %-5s bw: %s${EL}\n" "$(get_container_name $i)" "$mc" "$bw_d"
        done
    else
        echo -e "  Max Clients:  ${MAX_CLIENTS}${EL}"
        if [ "$BANDWIDTH" == "-1" ]; then
            echo -e "  Bandwidth:    Unlimited${EL}"
        else
            echo -e "  Bandwidth:    ${BANDWIDTH} Mbps${EL}"
        fi
        echo -e "  Containers:   ${CONTAINER_COUNT}${EL}"
    fi
    if _has_any_data_cap; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_rx=$((used_rx + ${DATA_CAP_PRIOR_RX:-0}))
        local total_tx=$((used_tx + ${DATA_CAP_PRIOR_TX:-0}))
        local total_used=$((total_rx + total_tx))
        local cap_line="  Data Cap:    "
        [ "${DATA_CAP_UP_GB:-0}" -gt 0 ] 2>/dev/null && cap_line+=" up $(format_gb $total_tx)/${DATA_CAP_UP_GB}GB"
        [ "${DATA_CAP_DOWN_GB:-0}" -gt 0 ] 2>/dev/null && cap_line+=" dn $(format_gb $total_rx)/${DATA_CAP_DOWN_GB}GB"
        [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null && cap_line+=" total $(format_gb $total_used)/${DATA_CAP_GB}GB"
        echo -e "${cap_line}${EL}"
    fi

    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
        local sf_stat="${RED}Stopped${NC}"
        is_snowflake_running && sf_stat="${GREEN}Running${NC}"
        local sf_line="  Snowflake:    ${sf_stat} (${SNOWFLAKE_COUNT:-1})"
        if is_snowflake_running; then
            local sf_s=$(get_snowflake_stats 2>/dev/null)
            local sf_c=$(echo "$sf_s" | awk '{print $1}')
            local sf_i=$(echo "$sf_s" | awk '{print $2}')
            local sf_o=$(echo "$sf_s" | awk '{print $3}')
            sf_line+=" | connections served: ${sf_c:-0}"
            sf_line+=" | ↓$(format_bytes ${sf_i:-0}) ↑$(format_bytes ${sf_o:-0})"
        fi
        echo -e "${sf_line}${EL}"
    fi


    echo -e "${EL}"
    echo -e "${CYAN}═══ AUTO-START SERVICE ═══${NC}${EL}"
    # Cache init system detection (doesn't change mid-session)
    if [ -z "$_SYSTEMD_CACHE" ]; then
        if command -v systemctl &>/dev/null && systemctl is-enabled conduit.service 2>/dev/null | grep -q "enabled"; then
            _SYSTEMD_CACHE="systemd"
        elif command -v rc-status &>/dev/null && rc-status -a 2>/dev/null | grep -q "conduit"; then
            _SYSTEMD_CACHE="openrc"
        elif [ -f /etc/init.d/conduit ]; then
            _SYSTEMD_CACHE="sysvinit"
        else
            _SYSTEMD_CACHE="none"
        fi
    fi
    if [ "$_SYSTEMD_CACHE" = "systemd" ]; then
        echo -e "  Auto-start:   ${GREEN}Enabled (systemd)${NC}${EL}"
        if [ "$running_count" -gt 0 ]; then
            echo -e "  Service:      ${GREEN}active${NC}${EL}"
        else
            echo -e "  Service:      ${YELLOW}inactive${NC}${EL}"
        fi
    elif [ "$_SYSTEMD_CACHE" = "openrc" ]; then
        echo -e "  Auto-start:   ${GREEN}Enabled (OpenRC)${NC}${EL}"
    elif [ "$_SYSTEMD_CACHE" = "sysvinit" ]; then
        echo -e "  Auto-start:   ${GREEN}Enabled (SysVinit)${NC}${EL}"
    else
        echo -e "  Auto-start:   ${YELLOW}Not configured${NC}${EL}"
        echo -e "  Note:         Docker restart policy handles restarts${EL}"
    fi
    # Check Background Tracker
    if is_tracker_active; then
        echo -e "  Tracker:      ${GREEN}Active${NC}${EL}"
    else
        echo -e "  Tracker:      ${YELLOW}Inactive${NC}${EL}"
    fi
    echo -e "${EL}"
}

start_conduit() {
    local _auto="${1:-}"
    local _state_file="$INSTALL_DIR/.user_stopped"

    # Respect user's manual stop on systemd boot
    if [ "$_auto" = "--auto" ] && [ -f "$_state_file" ]; then
        echo "Conduit was manually stopped by user. Skipping auto-start."
        echo "Run 'conduit start' to resume."
        return 0
    fi
    rm -f "$_state_file"
    if _has_any_data_cap; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_rx=$((used_rx + ${DATA_CAP_PRIOR_RX:-0}))
        local total_tx=$((used_tx + ${DATA_CAP_PRIOR_TX:-0}))
        local total_used=$((total_rx + total_tx))
        local cap_hit=""
        if [ "${DATA_CAP_UP_GB:-0}" -gt 0 ] 2>/dev/null; then
            local up_cap=$(awk -v gb="$DATA_CAP_UP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
            [ "$total_tx" -ge "$up_cap" ] 2>/dev/null && cap_hit="Upload cap exceeded ($(format_gb $total_tx) / ${DATA_CAP_UP_GB} GB)"
        fi
        if [ -z "$cap_hit" ] && [ "${DATA_CAP_DOWN_GB:-0}" -gt 0 ] 2>/dev/null; then
            local down_cap=$(awk -v gb="$DATA_CAP_DOWN_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
            [ "$total_rx" -ge "$down_cap" ] 2>/dev/null && cap_hit="Download cap exceeded ($(format_gb $total_rx) / ${DATA_CAP_DOWN_GB} GB)"
        fi
        if [ -z "$cap_hit" ] && [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null; then
            local total_cap=$(awk -v gb="$DATA_CAP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
            [ "$total_used" -ge "$total_cap" ] 2>/dev/null && cap_hit="Total cap exceeded ($(format_gb $total_used) / ${DATA_CAP_GB} GB)"
        fi
        if [ -n "$cap_hit" ]; then
            echo -e "${RED}⚠ ${cap_hit}. Containers will not start.${NC}"
            echo -e "${YELLOW}Reset or increase the data cap from the menu to start containers.${NC}"
            return 1
        fi
    fi

    echo "Starting Conduit ($CONTAINER_COUNT container(s))..."

    # Batch: get all existing containers in one docker call
    local existing_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
    local running_containers=$(docker ps --format '{{.Names}}' 2>/dev/null)

    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        local vol=$(get_volume_name $i)

        if echo "$running_containers" | grep -q "^${name}$"; then
            # Already running — skip
            echo -e "${GREEN}✓ ${name} is already running${NC}"
            continue
        elif echo "$existing_containers" | grep -q "^${name}$"; then
            # Exists but stopped — check if settings changed
            local needs_recreate=false
            local want_mc=$(get_container_max_clients $i)
            local want_bw=$(get_container_bandwidth $i)
            local want_cpus=$(get_container_cpus $i)
            local want_mem=$(get_container_memory $i)
            local cur_args=$(docker inspect --format '{{join .Args " "}}' "$name" 2>/dev/null)
            local cur_mc=$(echo "$cur_args" | sed -n 's/.*--max-clients \([^ ]*\).*/\1/p' 2>/dev/null)
            local cur_bw=$(echo "$cur_args" | sed -n 's/.*--bandwidth \([^ ]*\).*/\1/p' 2>/dev/null)
            local cur_nano=$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$name" 2>/dev/null || echo 0)
            local cur_memb=$(docker inspect --format '{{.HostConfig.Memory}}' "$name" 2>/dev/null || echo 0)
            local want_nano=0
            [ -n "$want_cpus" ] && want_nano=$(awk -v c="$want_cpus" 'BEGIN{printf "%.0f", c*1000000000}')
            local want_memb=0
            if [ -n "$want_mem" ]; then
                local mv=${want_mem%[mMgG]}; local mu=${want_mem: -1}
                [[ "$mu" =~ [gG] ]] && want_memb=$((mv * 1073741824)) || want_memb=$((mv * 1048576))
            fi
            [ "$cur_mc" != "$want_mc" ] && needs_recreate=true
            [ "$cur_bw" != "$want_bw" ] && needs_recreate=true
            [ "${cur_nano:-0}" != "$want_nano" ] && needs_recreate=true
            [ "${cur_memb:-0}" != "$want_memb" ] && needs_recreate=true

            if [ "$needs_recreate" = true ]; then
                echo "Settings changed for ${name}, recreating..."
                docker rm -f "$name" >/dev/null 2>&1 || true
                docker volume create "$vol" >/dev/null 2>&1 || true
                fix_volume_permissions $i
                run_conduit_container $i
            else
                # Settings unchanged — just resume the stopped container
                docker start "$name" >/dev/null 2>&1
            fi
        else
            # Container doesn't exist — create fresh
            docker volume create "$vol" >/dev/null 2>&1 || true
            fix_volume_permissions $i
            run_conduit_container $i
        fi

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ ${name} started${NC}"
        else
            echo -e "${RED}✗ Failed to start ${name}${NC}"
        fi
    done
    # Start background tracker
    setup_tracker_service 2>/dev/null || true
    # Start snowflake if enabled
    [ "$SNOWFLAKE_ENABLED" = "true" ] && start_snowflake 2>/dev/null
    return 0
}

stop_conduit() {
    local _auto="${1:-}"
    echo "Stopping Conduit..."
    # Mark as user-stopped (skip for systemd shutdown)
    if [ "$_auto" != "--auto" ]; then
        touch "$INSTALL_DIR/.user_stopped"
    fi
    local stopped=0
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            docker stop "$name" 2>/dev/null
            echo -e "${YELLOW}✓ ${name} stopped${NC}"
            stopped=$((stopped + 1))
        fi
    done
    # Stop extra containers from previous scaling
    local base_name="$(get_container_name 1)"
    local idx
    docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r cname; do
        case "$cname" in
            "${base_name%1}"*)
                idx="${cname##*[!0-9]}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -gt "$CONTAINER_COUNT" ]; then
                    docker stop "$cname" 2>/dev/null || true
                    docker rm "$cname" 2>/dev/null || true
                    echo -e "${YELLOW}✓ ${cname} stopped and removed (extra)${NC}"
                fi
                ;;
        esac
    done
    [ "$stopped" -eq 0 ] && echo -e "${YELLOW}No Conduit containers are running${NC}"
    [ "$SNOWFLAKE_ENABLED" = "true" ] && stop_snowflake 2>/dev/null
    stop_tracker_service 2>/dev/null || true
    return 0
}

restart_conduit() {
    rm -f "$INSTALL_DIR/.user_stopped"
    if _has_any_data_cap; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_rx=$((used_rx + ${DATA_CAP_PRIOR_RX:-0}))
        local total_tx=$((used_tx + ${DATA_CAP_PRIOR_TX:-0}))
        local total_used=$((total_rx + total_tx))
        local cap_hit=""
        if [ "${DATA_CAP_UP_GB:-0}" -gt 0 ] 2>/dev/null; then
            local up_cap=$(awk -v gb="$DATA_CAP_UP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
            [ "$total_tx" -ge "$up_cap" ] 2>/dev/null && cap_hit="Upload cap exceeded ($(format_gb $total_tx) / ${DATA_CAP_UP_GB} GB)"
        fi
        if [ -z "$cap_hit" ] && [ "${DATA_CAP_DOWN_GB:-0}" -gt 0 ] 2>/dev/null; then
            local down_cap=$(awk -v gb="$DATA_CAP_DOWN_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
            [ "$total_rx" -ge "$down_cap" ] 2>/dev/null && cap_hit="Download cap exceeded ($(format_gb $total_rx) / ${DATA_CAP_DOWN_GB} GB)"
        fi
        if [ -z "$cap_hit" ] && [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null; then
            local total_cap=$(awk -v gb="$DATA_CAP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
            [ "$total_used" -ge "$total_cap" ] 2>/dev/null && cap_hit="Total cap exceeded ($(format_gb $total_used) / ${DATA_CAP_GB} GB)"
        fi
        if [ -n "$cap_hit" ]; then
            echo -e "${RED}⚠ ${cap_hit}. Containers will not restart.${NC}"
            echo -e "${YELLOW}Reset or increase the data cap from the menu to restart containers.${NC}"
            return 1
        fi
    fi

    echo "Restarting Conduit ($CONTAINER_COUNT container(s))..."
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        local vol=$(get_volume_name $i)
        local want_mc=$(get_container_max_clients $i)
        local want_bw=$(get_container_bandwidth $i)
        local want_cpus=$(get_container_cpus $i)
        local want_mem=$(get_container_memory $i)

        if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            # Container is running — check if settings match
            local cur_args=$(docker inspect --format '{{join .Args " "}}' "$name" 2>/dev/null)
            local needs_recreate=false
            # Check if max-clients or bandwidth args differ (portable, no -oP)
            local cur_mc=$(echo "$cur_args" | sed -n 's/.*--max-clients \([^ ]*\).*/\1/p' 2>/dev/null)
            local cur_bw=$(echo "$cur_args" | sed -n 's/.*--bandwidth \([^ ]*\).*/\1/p' 2>/dev/null)
            [ "$cur_mc" != "$want_mc" ] && needs_recreate=true
            [ "$cur_bw" != "$want_bw" ] && needs_recreate=true
            # Check resource limits
            local cur_nano=$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$name" 2>/dev/null || echo 0)
            local cur_memb=$(docker inspect --format '{{.HostConfig.Memory}}' "$name" 2>/dev/null || echo 0)
            local want_nano=0
            [ -n "$want_cpus" ] && want_nano=$(awk -v c="$want_cpus" 'BEGIN{printf "%.0f", c*1000000000}')
            local want_memb=0
            if [ -n "$want_mem" ]; then
                local mv=${want_mem%[mMgG]}
                local mu=${want_mem: -1}
                [[ "$mu" =~ [gG] ]] && want_memb=$((mv * 1073741824)) || want_memb=$((mv * 1048576))
            fi
            [ "${cur_nano:-0}" != "$want_nano" ] && needs_recreate=true
            [ "${cur_memb:-0}" != "$want_memb" ] && needs_recreate=true

            if [ "$needs_recreate" = true ]; then
                echo "Settings changed for ${name}, recreating..."
                docker stop "$name" >/dev/null 2>&1 || true
                docker rm "$name" >/dev/null 2>&1 || true
                docker volume create "$vol" >/dev/null 2>&1 || true
                fix_volume_permissions $i
                run_conduit_container $i
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ ${name} recreated with new settings${NC}"
                else
                    echo -e "${RED}✗ Failed to recreate ${name}${NC}"
                fi
            else
                docker restart "$name" >/dev/null 2>&1
                echo -e "${GREEN}✓ ${name} restarted (settings unchanged)${NC}"
            fi
        elif docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            # Container exists but stopped — check if settings match
            local cur_args=$(docker inspect --format '{{join .Args " "}}' "$name" 2>/dev/null)
            local cur_mc=$(echo "$cur_args" | sed -n 's/.*--max-clients \([^ ]*\).*/\1/p' 2>/dev/null)
            local cur_bw=$(echo "$cur_args" | sed -n 's/.*--bandwidth \([^ ]*\).*/\1/p' 2>/dev/null)
            local cur_nano=$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$name" 2>/dev/null || echo 0)
            local cur_memb=$(docker inspect --format '{{.HostConfig.Memory}}' "$name" 2>/dev/null || echo 0)
            local want_nano=0
            [ -n "$want_cpus" ] && want_nano=$(awk -v c="$want_cpus" 'BEGIN{printf "%.0f", c*1000000000}')
            local want_memb=0
            if [ -n "$want_mem" ]; then
                local mv=${want_mem%[mMgG]}
                local mu=${want_mem: -1}
                [[ "$mu" =~ [gG] ]] && want_memb=$((mv * 1073741824)) || want_memb=$((mv * 1048576))
            fi
            if [ "$cur_mc" != "$want_mc" ] || [ "$cur_bw" != "$want_bw" ] || [ "${cur_nano:-0}" != "$want_nano" ] || [ "${cur_memb:-0}" != "$want_memb" ]; then
                echo "Settings changed for ${name}, recreating..."
                docker rm "$name" >/dev/null 2>&1 || true
                docker volume create "$vol" >/dev/null 2>&1 || true
                fix_volume_permissions $i
                run_conduit_container $i
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ ${name} recreated with new settings${NC}"
                else
                    echo -e "${RED}✗ Failed to recreate ${name}${NC}"
                fi
            else
                docker start "$name" >/dev/null 2>&1
                echo -e "${GREEN}✓ ${name} started${NC}"
            fi
        else
            # Container doesn't exist — create fresh
            docker volume create "$vol" >/dev/null 2>&1 || true
            fix_volume_permissions $i
            run_conduit_container $i
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ ${name} created and started${NC}"
            else
                echo -e "${RED}✗ Failed to create ${name}${NC}"
            fi
        fi
    done
    # Remove extra containers beyond current count (dynamic, no hard max)
    docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r cname; do
        [[ "$cname" =~ ^conduit(-([0-9]+))?$ ]] || continue
        local idx="${BASH_REMATCH[2]:-1}"
        if [ "$idx" -gt "$CONTAINER_COUNT" ]; then
            docker stop "$cname" 2>/dev/null || true
            docker rm "$cname" 2>/dev/null || true
            echo -e "${YELLOW}✓ ${cname} removed (scaled down)${NC}"
        fi
    done
    # Stop tracker before backup to avoid racing with writes
    stop_tracker_service 2>/dev/null || true
    local persist_dir="$INSTALL_DIR/traffic_stats"
    if [ -s "$persist_dir/cumulative_data" ] || [ -s "$persist_dir/cumulative_ips" ]; then
        echo -e "${CYAN}⟳ Saving tracker data snapshot...${NC}"
        [ -s "$persist_dir/cumulative_data" ] && cp "$persist_dir/cumulative_data" "$persist_dir/cumulative_data.bak"
        [ -s "$persist_dir/cumulative_ips" ] && cp "$persist_dir/cumulative_ips" "$persist_dir/cumulative_ips.bak"
        [ -s "$persist_dir/geoip_cache" ] && cp "$persist_dir/geoip_cache" "$persist_dir/geoip_cache.bak"
        echo -e "${GREEN}✓ Tracker data snapshot saved${NC}"
    fi
    # Regenerate tracker script and ensure service is running
    setup_tracker_service 2>/dev/null || true
    # Restart snowflake if enabled
    [ "$SNOWFLAKE_ENABLED" = "true" ] && restart_snowflake 2>/dev/null
}

change_settings() {
    echo ""
    echo -e "${CYAN}═══ Current Settings ═══${NC}"
    echo ""
    printf "  ${BOLD}%-12s %-12s %-12s %-10s %-10s${NC}\n" "Container" "Max Clients" "Bandwidth" "CPU" "Memory"
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────${NC}"
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        local mc=$(get_container_max_clients $i)
        local bw=$(get_container_bandwidth $i)
        local cpus=$(get_container_cpus $i)
        local mem=$(get_container_memory $i)
        local bw_display="Unlimited"
        [ "$bw" != "-1" ] && bw_display="${bw} Mbps"
        local cpu_d="${cpus:-—}"
        local mem_d="${mem:-—}"
        printf "  %-12s %-12s %-12s %-10s %-10s\n" "$cname" "$mc" "$bw_display" "$cpu_d" "$mem_d"
    done
    echo ""
    echo -e "  Default: Max Clients=${GREEN}${MAX_CLIENTS}${NC}  Bandwidth=${GREEN}$([ "$BANDWIDTH" = "-1" ] && echo "Unlimited" || echo "${BANDWIDTH} Mbps")${NC}"
    echo ""

    # Select target
    echo -e "  ${BOLD}Apply settings to:${NC}"
    echo -e "  ${GREEN}a${NC}) All containers (set same values)"
    for i in $(seq 1 $CONTAINER_COUNT); do
        echo -e "  ${GREEN}${i}${NC}) $(get_container_name $i)"
    done
    echo ""
    read -p "  Select (a/1-${CONTAINER_COUNT}): " target < /dev/tty || true

    local targets=()
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        for i in $(seq 1 $CONTAINER_COUNT); do targets+=($i); done
    elif [[ "$target" =~ ^[0-9]+$ ]] && [ "$target" -ge 1 ] && [ "$target" -le "$CONTAINER_COUNT" ]; then
        targets+=($target)
    else
        echo -e "  ${RED}Invalid selection.${NC}"
        return
    fi

    # Get new values
    local cur_mc=$(get_container_max_clients ${targets[0]})
    local cur_bw=$(get_container_bandwidth ${targets[0]})
    echo ""
    read -p "  New max-clients (1-1000) [${cur_mc}]: " new_clients < /dev/tty || true

    echo ""
    local cur_bw_display="Unlimited"
    [ "$cur_bw" != "-1" ] && cur_bw_display="${cur_bw} Mbps"
    echo "  Current bandwidth: ${cur_bw_display}"
    read -p "  Set unlimited bandwidth? [y/N]: " set_unlimited < /dev/tty || true

    local new_bandwidth=""
    if [[ "$set_unlimited" =~ ^[Yy]$ ]]; then
        new_bandwidth="-1"
    else
        read -p "  New bandwidth in Mbps (1-40) [${cur_bw}]: " input_bw < /dev/tty || true
        [ -n "$input_bw" ] && new_bandwidth="$input_bw"
    fi

    # Validate max-clients
    local valid_mc=""
    if [ -n "$new_clients" ]; then
        if [[ "$new_clients" =~ ^[0-9]+$ ]] && [ "$new_clients" -ge 1 ] && [ "$new_clients" -le 1000 ]; then
            valid_mc="$new_clients"
        else
            echo -e "  ${YELLOW}Invalid max-clients. Keeping current.${NC}"
        fi
    fi

    # Validate bandwidth
    local valid_bw=""
    if [ -n "$new_bandwidth" ]; then
        if [ "$new_bandwidth" = "-1" ]; then
            valid_bw="-1"
        elif [[ "$new_bandwidth" =~ ^[0-9]+$ ]] && [ "$new_bandwidth" -ge 1 ] && [ "$new_bandwidth" -le 40 ]; then
            valid_bw="$new_bandwidth"
        elif [[ "$new_bandwidth" =~ ^[0-9]*\.[0-9]+$ ]]; then
            local float_ok=$(awk -v val="$new_bandwidth" 'BEGIN { print (val >= 1 && val <= 40) ? "yes" : "no" }')
            [ "$float_ok" = "yes" ] && valid_bw="$new_bandwidth" || echo -e "  ${YELLOW}Invalid bandwidth. Keeping current.${NC}"
        else
            echo -e "  ${YELLOW}Invalid bandwidth. Keeping current.${NC}"
        fi
    fi

    # Apply to targets
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        # Apply to all = update global defaults and clear per-container overrides
        [ -n "$valid_mc" ] && MAX_CLIENTS="$valid_mc"
        [ -n "$valid_bw" ] && BANDWIDTH="$valid_bw"
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            unset "MAX_CLIENTS_${i}" 2>/dev/null || true
            unset "BANDWIDTH_${i}" 2>/dev/null || true
        done
    else
        # Apply to specific container
        local idx=${targets[0]}
        if [ -n "$valid_mc" ]; then
            eval "MAX_CLIENTS_${idx}=${valid_mc}"
        fi
        if [ -n "$valid_bw" ]; then
            eval "BANDWIDTH_${idx}=${valid_bw}"
        fi
    fi

    save_settings

    # Recreate affected containers
    echo ""
    echo "  Recreating container(s) with new settings..."
    for i in "${targets[@]}"; do
        local name=$(get_container_name $i)
        docker rm -f "$name" 2>/dev/null || true
    done
    sleep 1
    for i in "${targets[@]}"; do
        local name=$(get_container_name $i)
        fix_volume_permissions $i
        run_conduit_container $i
        if [ $? -eq 0 ]; then
            local mc=$(get_container_max_clients $i)
            local bw=$(get_container_bandwidth $i)
            local bw_d="Unlimited"
            [ "$bw" != "-1" ] && bw_d="${bw} Mbps"
            echo -e "  ${GREEN}✓ ${name}${NC} — clients: ${mc}, bandwidth: ${bw_d}"
        else
            echo -e "  ${RED}✗ Failed to restart ${name}${NC}"
        fi
    done
}

change_resource_limits() {
    local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    local ram_mb=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 512)
    echo ""
    echo -e "${CYAN}═══ RESOURCE LIMITS ═══${NC}"
    echo ""
    echo -e "  Set CPU and memory limits per container."
    echo -e "  ${DIM}System: ${cpu_cores} CPU core(s), ${ram_mb} MB RAM${NC}"
    echo ""

    # Show current limits
    printf "  ${BOLD}%-12s %-12s %-12s${NC}\n" "Container" "CPU Limit" "Memory Limit"
    echo -e "  ${CYAN}────────────────────────────────────────${NC}"
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        local cpus=$(get_container_cpus $i)
        local mem=$(get_container_memory $i)
        local cpu_d="${cpus:-No limit}"
        local mem_d="${mem:-No limit}"
        [ -n "$cpus" ] && cpu_d="${cpus} cores"
        printf "  %-12s %-12s %-12s\n" "$cname" "$cpu_d" "$mem_d"
    done
    echo ""

    # Select target
    echo -e "  ${BOLD}Apply limits to:${NC}"
    echo -e "  ${GREEN}a${NC}) All containers"
    for i in $(seq 1 $CONTAINER_COUNT); do
        echo -e "  ${GREEN}${i}${NC}) $(get_container_name $i)"
    done
    echo -e "  ${GREEN}c${NC}) Clear all limits (remove restrictions)"
    echo ""
    read -p "  Select (a/1-${CONTAINER_COUNT}/c): " target < /dev/tty || true

    if [ "$target" = "c" ] || [ "$target" = "C" ]; then
        DOCKER_CPUS=""
        DOCKER_MEMORY=""
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            unset "CPUS_${i}" 2>/dev/null || true
            unset "MEMORY_${i}" 2>/dev/null || true
        done
        save_settings
        echo -e "  ${GREEN}✓ All resource limits cleared. Containers will use full system resources on next restart.${NC}"
        return
    fi

    local targets=()
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        for i in $(seq 1 $CONTAINER_COUNT); do targets+=($i); done
    elif [[ "$target" =~ ^[0-9]+$ ]] && [ "$target" -ge 1 ] && [ "$target" -le "$CONTAINER_COUNT" ]; then
        targets+=($target)
    else
        echo -e "  ${RED}Invalid selection.${NC}"
        return
    fi

    local rec_cpu=$(awk -v c="$cpu_cores" 'BEGIN{v=c/2; if(v<0.5) v=0.5; printf "%.1f", v}')
    local rec_mem="256m"
    [ "$ram_mb" -ge 2048 ] && rec_mem="512m"
    [ "$ram_mb" -ge 4096 ] && rec_mem="1g"

    # CPU limit prompt
    echo ""
    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}CPU Limit${NC}"
    echo -e "  Limits how much processor power this container can use."
    echo -e "  This prevents it from slowing down other services on your system."
    echo -e ""
    echo -e "  ${DIM}Your system has ${GREEN}${cpu_cores}${NC}${DIM} core(s).${NC}"
    echo -e "  ${DIM}  0.5 = half a core    1.0 = one full core${NC}"
    echo -e "  ${DIM}  2.0 = two cores      ${cpu_cores}.0 = all cores (no limit)${NC}"
    echo -e ""
    echo -e "  Press Enter to keep current or use default."
    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
    local cur_cpus=$(get_container_cpus ${targets[0]})
    local cpus_default="${cur_cpus:-${rec_cpu}}"
    read -p "  CPU limit [${cpus_default}]: " input_cpus < /dev/tty || true

    # Validate CPU
    local valid_cpus=""
    if [ -z "$input_cpus" ]; then
        # Enter pressed — keep current if set, otherwise no change
        [ -n "$cur_cpus" ] && valid_cpus="$cur_cpus"
    elif [[ "$input_cpus" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        local cpu_ok=$(awk -v val="$input_cpus" -v max="$cpu_cores" 'BEGIN { print (val > 0 && val <= max) ? "yes" : "no" }')
        if [ "$cpu_ok" = "yes" ]; then
            valid_cpus="$input_cpus"
        else
            echo -e "  ${YELLOW}Must be between 0.1 and ${cpu_cores}. Keeping current.${NC}"
            [ -n "$cur_cpus" ] && valid_cpus="$cur_cpus"
        fi
    else
        echo -e "  ${YELLOW}Invalid input. Keeping current.${NC}"
        [ -n "$cur_cpus" ] && valid_cpus="$cur_cpus"
    fi

    # Memory limit prompt
    echo ""
    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Memory Limit${NC}"
    echo -e "  Maximum RAM this container can use."
    echo -e "  Prevents it from consuming all memory and crashing other services."
    echo -e ""
    echo -e "  ${DIM}Your system has ${GREEN}${ram_mb} MB${NC}${DIM} RAM.${NC}"
    echo -e "  ${DIM}  256m  = 256 MB (good for low-end systems)${NC}"
    echo -e "  ${DIM}  512m  = 512 MB (balanced)${NC}"
    echo -e "  ${DIM}  1g    = 1 GB   (high capacity)${NC}"
    echo -e ""
    echo -e "  Press Enter to keep current or use default."
    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
    local cur_mem=$(get_container_memory ${targets[0]})
    local mem_default="${cur_mem:-${rec_mem}}"
    read -p "  Memory limit [${mem_default}]: " input_mem < /dev/tty || true

    # Validate memory
    local valid_mem=""
    if [ -z "$input_mem" ]; then
        # Enter pressed — keep current if set, otherwise no change
        [ -n "$cur_mem" ] && valid_mem="$cur_mem"
    elif [[ "$input_mem" =~ ^[0-9]+[mMgG]$ ]]; then
        local mem_val=${input_mem%[mMgG]}
        local mem_unit=${input_mem: -1}
        local mem_mb=$mem_val
        [[ "$mem_unit" =~ [gG] ]] && mem_mb=$((mem_val * 1024))
        if [ "$mem_mb" -ge 64 ] && [ "$mem_mb" -le "$ram_mb" ]; then
            valid_mem="$input_mem"
        else
            echo -e "  ${YELLOW}Must be between 64m and ${ram_mb}m. Keeping current.${NC}"
            [ -n "$cur_mem" ] && valid_mem="$cur_mem"
        fi
    else
        echo -e "  ${YELLOW}Invalid format. Use a number followed by m or g (e.g. 256m, 1g). Keeping current.${NC}"
        [ -n "$cur_mem" ] && valid_mem="$cur_mem"
    fi

    # Nothing changed
    if [ -z "$valid_cpus" ] && [ -z "$valid_mem" ]; then
        echo -e "  ${DIM}No changes made.${NC}"
        return
    fi

    # Apply
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        [ -n "$valid_cpus" ] && DOCKER_CPUS="$valid_cpus"
        [ -n "$valid_mem" ] && DOCKER_MEMORY="$valid_mem"
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            unset "CPUS_${i}" 2>/dev/null || true
            unset "MEMORY_${i}" 2>/dev/null || true
        done
    else
        local idx=${targets[0]}
        [ -n "$valid_cpus" ] && eval "CPUS_${idx}=${valid_cpus}"
        [ -n "$valid_mem" ] && eval "MEMORY_${idx}=${valid_mem}"
    fi

    save_settings

    # Recreate affected containers
    echo ""
    echo "  Recreating container(s) with new resource limits..."
    for i in "${targets[@]}"; do
        local name=$(get_container_name $i)
        docker rm -f "$name" 2>/dev/null || true
    done
    sleep 1
    for i in "${targets[@]}"; do
        local name=$(get_container_name $i)
        fix_volume_permissions $i
        run_conduit_container $i
        if [ $? -eq 0 ]; then
            local cpus=$(get_container_cpus $i)
            local mem=$(get_container_memory $i)
            local cpu_d="${cpus:-no limit}"
            local mem_d="${mem:-no limit}"
            [ -n "$cpus" ] && cpu_d="${cpus} cores"
            echo -e "  ${GREEN}✓ ${name}${NC} — CPU: ${cpu_d}, Memory: ${mem_d}"
        else
            echo -e "  ${RED}✗ Failed to restart ${name}${NC}"
        fi
    done
}

#═══════════════════════════════════════════════════════════════════════
# show_logs() - Display color-coded Docker logs
#═══════════════════════════════════════════════════════════════════════
# Colors log entries based on their type:
#   [OK]     - Green   (successful operations)
#   [INFO]   - Cyan    (informational messages)
#   [STATS]  - Blue    (statistics)
#   [WARN]   - Yellow  (warnings)
#   [ERROR]  - Red     (errors)
#   [DEBUG]  - Gray    (debug messages)
#═══════════════════════════════════════════════════════════════════════
show_logs() {
    if ! docker ps -a 2>/dev/null | grep -q conduit; then
        echo -e "${RED}Conduit container not found.${NC}"
        return 1
    fi

    local target="conduit"
    if [ "$CONTAINER_COUNT" -gt 1 ]; then
        echo ""
        echo -e "${CYAN}Select container to view logs:${NC}"
        echo ""
        for i in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $i)
            local status="${RED}Stopped${NC}"
            docker ps 2>/dev/null | grep -q "[[:space:]]${cname}$" && status="${GREEN}Running${NC}"
            echo -e "  ${i}. ${cname}  [${status}]"
        done
        echo ""
        read -p "  Select (1-${CONTAINER_COUNT}): " idx < /dev/tty || true
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$CONTAINER_COUNT" ]; then
            echo -e "${RED}Invalid selection.${NC}"
            return 1
        fi
        target=$(get_container_name $idx)
    fi

    echo -e "${CYAN}Streaming logs from ${target} (filtered, no [STATS])... Press Ctrl+C to stop${NC}"
    echo ""

    docker logs -f "$target" 2>&1 | grep -v "\[STATS\]"
}

uninstall_all() {
    telegram_disable_service
    rm -f /etc/systemd/system/conduit-telegram.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null || true
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  UNINSTALL CONDUIT                          ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "This will completely remove:"
    echo "  • All Conduit Docker containers (conduit, conduit-2..5)"
    echo "  • All Conduit data volumes"
    echo "  • Conduit Docker image"
    echo "  • Auto-start service (systemd/OpenRC/SysVinit)"
    echo "  • Background tracker service & stats data"
    echo "  • Configuration files & Management CLI"
    echo ""
    echo -e "${YELLOW}Docker engine will NOT be removed.${NC}"
    echo ""
    echo -e "${RED}WARNING: This action cannot be undone!${NC}"
    echo ""
    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " confirm < /dev/tty || true

    if [ "$confirm" != "yes" ]; then
        echo "Uninstall cancelled."
        return 0
    fi

    # Check for backup keys
    local keep_backups=false
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  📁 Backup keys found in: ${BACKUP_DIR}${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "You have backed up node identity keys. These allow you to restore"
        echo "your node identity if you reinstall Conduit later."
        echo ""
        while true; do
            read -p "Do you want to KEEP your backup keys? (y/n): " keep_confirm < /dev/tty || true
            if [[ "$keep_confirm" =~ ^[Yy]$ ]]; then
                keep_backups=true
                echo -e "${GREEN}✓ Backup keys will be preserved.${NC}"
                break
            elif [[ "$keep_confirm" =~ ^[Nn]$ ]]; then
                echo -e "${YELLOW}⚠ Backup keys will be deleted.${NC}"
                break
            else
                echo "Please enter y or n."
            fi
        done
        echo ""
    fi

    echo ""
    echo -e "${BLUE}[INFO]${NC} Stopping Conduit container(s)..."
    docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r name; do
        [[ "$name" =~ ^conduit(-([0-9]+))?$ ]] || continue
        docker stop "$name" 2>/dev/null || true
        docker rm -f "$name" 2>/dev/null || true
    done

    echo -e "${BLUE}[INFO]${NC} Removing Conduit Docker image..."
    docker rmi "$CONDUIT_IMAGE" 2>/dev/null || true

    echo -e "${BLUE}[INFO]${NC} Removing Conduit data volume(s)..."
    docker volume ls --format '{{.Name}}' 2>/dev/null | while read -r vol; do
        [[ "$vol" =~ ^conduit-data(-([0-9]+))?$ ]] || continue
        docker volume rm "$vol" 2>/dev/null || true
    done

    echo -e "${BLUE}[INFO]${NC} Removing auto-start service..."
    # Tracker service
    systemctl stop conduit-tracker.service 2>/dev/null || true
    systemctl disable conduit-tracker.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit-tracker.service
    pkill -f "conduit-tracker.sh" 2>/dev/null || true
    # Systemd
    systemctl stop conduit.service 2>/dev/null || true
    systemctl disable conduit.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    systemctl daemon-reload 2>/dev/null || true
    # OpenRC / SysVinit
    rc-service conduit stop 2>/dev/null || true
    rc-update del conduit 2>/dev/null || true
    service conduit stop 2>/dev/null || true
    update-rc.d conduit remove 2>/dev/null || true
    chkconfig conduit off 2>/dev/null || true
    rm -f /etc/init.d/conduit

    echo -e "${BLUE}[INFO]${NC} Removing configuration files..."
    if [ "$keep_backups" = true ]; then
        # Keep backup directory, remove everything else in /opt/conduit
        echo -e "${BLUE}[INFO]${NC} Preserving backup keys in ${BACKUP_DIR}..."
        # Remove files in /opt/conduit but keep backups subdirectory
        rm -f /opt/conduit/config.env 2>/dev/null || true
        rm -f /opt/conduit/conduit 2>/dev/null || true
        rm -f /opt/conduit/conduit-tracker.sh 2>/dev/null || true
        rm -rf /opt/conduit/traffic_stats 2>/dev/null || true
        find /opt/conduit -maxdepth 1 -type f -delete 2>/dev/null || true
    else
        # Remove everything including backups
        rm -rf /opt/conduit
    fi
    rm -f /usr/local/bin/conduit

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ UNINSTALL COMPLETE!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Conduit and all related components have been removed."
    if [ "$keep_backups" = true ]; then
        echo ""
        echo -e "${CYAN}📁 Your backup keys are preserved in: ${BACKUP_DIR}${NC}"
        echo "   You can use these to restore your node identity after reinstalling."
    fi
    echo ""
    echo "Note: Docker engine was NOT removed."
    echo ""
}

manage_containers() {
    local stop_manage=0
    trap 'stop_manage=1' SIGINT SIGTERM

    # Calculate recommendation (1 container per core, limited by RAM)
    local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    local ram_gb=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 1)
    local rec_by_cpu=$cpu_cores
    local rec_by_ram=$ram_gb
    [ "$rec_by_ram" -lt 1 ] && rec_by_ram=1
    local rec_containers=$(( rec_by_cpu < rec_by_ram ? rec_by_cpu : rec_by_ram ))
    [ "$rec_containers" -lt 1 ] && rec_containers=1
    [ "$rec_containers" -gt 32 ] && rec_containers=32

    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    printf "\033[2J\033[H"

    local EL="\033[K"
    local need_input=true
    local mc_choice=""

    while [ $stop_manage -eq 0 ]; do
        # Soft update: cursor home, no clear
        printf "\033[H"

        echo -e "${EL}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}${EL}"
        echo -e "${CYAN}  MANAGE CONTAINERS${NC}    ${GREEN}${CONTAINER_COUNT}${NC}  Host networking${EL}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}${EL}"
        echo -e "${EL}"

        # Per-container stats table
        local docker_ps_cache=$(docker ps --format '{{.Names}}' 2>/dev/null)

        # Collect all docker data in parallel using a temp dir
        local _mc_tmpdir=$(mktemp -d /tmp/.conduit_mc.XXXXXX)
        # mktemp already created the directory

        local running_names=""
        for ci in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $ci)
            if echo "$docker_ps_cache" | grep -q "^${cname}$"; then
                running_names+=" $cname"
                # Fetch logs in parallel background jobs
                ( docker logs --tail 200 "$cname" 2>&1 | grep "\[STATS\]" | tail -1 > "$_mc_tmpdir/logs_${ci}" ) &
            fi
        done
        # Fetch stats in parallel with logs
        if [ -n "$running_names" ]; then
            ( timeout 10 docker stats --no-stream --format "{{.Name}} {{.CPUPerc}} {{.MemUsage}}" $running_names > "$_mc_tmpdir/stats" 2>/dev/null ) &
        fi
        wait

        local all_dstats=""
        [ -f "$_mc_tmpdir/stats" ] && all_dstats=$(cat "$_mc_tmpdir/stats")

        printf "  ${BOLD}%-2s %-11s %-8s %-7s %-8s %-8s %-6s %-7s${NC}${EL}\n" \
            "#" "Container" "Status" "Clients" "Up" "Down" "CPU" "RAM"
        echo -e "  ${CYAN}─────────────────────────────────────────────────────────${NC}${EL}"

        for ci in $(seq 1 "$CONTAINER_COUNT"); do
            local cname=$(get_container_name $ci)
            local status_text status_color
            local c_clients="-" c_up="-" c_down="-" c_cpu="-" c_ram="-"

                if echo "$docker_ps_cache" | grep -q "^${cname}$"; then
                    status_text="Running"
                    status_color="${GREEN}"
                    local logs=""
                    [ -f "$_mc_tmpdir/logs_${ci}" ] && logs=$(cat "$_mc_tmpdir/logs_${ci}")
                    if [ -n "$logs" ]; then
                        IFS='|' read -r conn cing mc_up mc_down <<< $(echo "$logs" | awk '{
                            cing=0; conn=0; up=""; down=""
                            for(j=1;j<=NF;j++){
                                if($j=="Connecting:") cing=$(j+1)+0
                                else if($j=="Connected:") conn=$(j+1)+0
                                else if($j=="Up:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Down:/)break; up=up (up?" ":"") $k}}
                                else if($j=="Down:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Uptime:/)break; down=down (down?" ":"") $k}}
                            }
                            printf "%d|%d|%s|%s", conn, cing, up, down
                        }')
                        c_clients="${conn:-0}/${cing:-0}"
                        c_up="${mc_up:-"-"}"
                        c_down="${mc_down:-"-"}"
                        [ -z "$c_up" ] && c_up="-"
                        [ -z "$c_down" ] && c_down="-"
                        # Update global cache
                        _STATS_CACHE_UP[$ci]="${mc_up}"
                        _STATS_CACHE_DOWN[$ci]="${mc_down}"
                        _STATS_CACHE_CONN[$ci]="${conn:-0}"
                        _STATS_CACHE_CING[$ci]="${cing:-0}"
                    elif [ -n "${_STATS_CACHE_UP[$ci]}" ]; then
                        # Use cached values as fallback
                        c_clients="${_STATS_CACHE_CONN[$ci]:-0}/${_STATS_CACHE_CING[$ci]:-0}"
                        c_up="${_STATS_CACHE_UP[$ci]:-"-"}"
                        c_down="${_STATS_CACHE_DOWN[$ci]:-"-"}"
                    fi
                    local dstats_line=$(echo "$all_dstats" | grep "^${cname} " 2>/dev/null)
                    if [ -n "$dstats_line" ]; then
                        c_cpu=$(echo "$dstats_line" | awk '{print $2}')
                        c_ram=$(echo "$dstats_line" | awk '{print $3}')
                    fi
                else
                    status_text="Stopped"
                    status_color="${RED}"
                fi
            printf "  %-2s %-11s %b%-8s%b %-7s %-8s %-8s %-6s %-7s${EL}\n" \
                "$ci" "$cname" "$status_color" "$status_text" "${NC}" "$c_clients" "$c_up" "$c_down" "$c_cpu" "$c_ram"
        done

        rm -rf "$_mc_tmpdir"

        echo -e "${EL}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}${EL}"
        local max_add=$(( rec_containers - CONTAINER_COUNT ))
        if [ "$max_add" -gt 0 ]; then
            echo -e "  ${GREEN}[a]${NC} Add container(s)      (recommended max: ${rec_containers})${EL}"
        else
            echo -e "  ${YELLOW}[a]${NC} Add container(s)      (above recommendation)${EL}"
        fi
        [ "$CONTAINER_COUNT" -gt 1 ] && echo -e "  ${RED}[r]${NC} Remove container(s)   (min: 1 required)${EL}"
        echo -e "  ${GREEN}[s]${NC} Start a container${EL}"
        echo -e "  ${RED}[t]${NC} Stop a container${EL}"
        echo -e "  ${YELLOW}[x]${NC} Restart a container${EL}"
        echo -e "  ${CYAN}[q]${NC} QR code for container${EL}"
        echo -e "  [b] Back to menu${EL}"
        echo -e "${EL}"
        printf "\033[J"

        echo -e "  ${CYAN}────────────────────────────────────────${NC}"
        echo -ne "\033[?25h"
        local _mc_start=$(date +%s)
        read -t 5 -p "  Enter choice: " mc_choice < /dev/tty 2>/dev/null || { mc_choice=""; }
        echo -ne "\033[?25l"
        local _mc_elapsed=$(( $(date +%s) - _mc_start ))

        # If read failed instantly (not a 5s timeout), /dev/tty is broken
        if [ -z "$mc_choice" ] && [ "$_mc_elapsed" -lt 2 ]; then
            _mc_tty_fails=$(( ${_mc_tty_fails:-0} + 1 ))
            [ "$_mc_tty_fails" -ge 3 ] && { echo -e "\n  ${RED}Input error. Cannot read from terminal.${NC}"; return; }
        else
            _mc_tty_fails=0
        fi

        # Empty = just refresh
        [ -z "$mc_choice" ] && continue

        case "$mc_choice" in
            a)
                local max_can_add=$((32 - CONTAINER_COUNT))
                if [ "$max_can_add" -le 0 ]; then
                    echo -e "  ${RED}Already at maximum (32 containers).${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    continue
                fi
                read -p "  How many to add? [1-${max_can_add}]: " add_count < /dev/tty || true
                if ! [[ "$add_count" =~ ^[1-9][0-9]*$ ]]; then
                    echo -e "  ${RED}Invalid.${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    continue
                fi
                local old_count=$CONTAINER_COUNT
                CONTAINER_COUNT=$((CONTAINER_COUNT + add_count))
                if [ "$CONTAINER_COUNT" -gt 32 ]; then
                    echo -e " ${RED}Maximum is 32 containers. Capping at 32.${NC}"
                    CONTAINER_COUNT=32
                elif [ "$CONTAINER_COUNT" -gt "$rec_containers" ]; then
                    echo -e "  ${YELLOW}Note:${NC} Total containers (${CONTAINER_COUNT}) exceed recommended (${rec_containers})."
                    echo -e "  ${DIM}  Expect diminishing returns or higher resource usage.${NC}"
                fi

                # Ask if user wants to set resource limits on new containers
                local set_limits=""
                local new_cpus="" new_mem=""
                echo ""
                read -p "  Set CPU/memory limits on new container(s)? [y/N]: " set_limits < /dev/tty || true
                if [[ "$set_limits" =~ ^[Yy]$ ]]; then
                    local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
                    local ram_mb=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 512)
                    local rec_cpu=$(awk -v c="$cpu_cores" 'BEGIN{v=c/2; if(v<0.5) v=0.5; printf "%.1f", v}')
                    local rec_mem="256m"
                    [ "$ram_mb" -ge 2048 ] && rec_mem="512m"
                    [ "$ram_mb" -ge 4096 ] && rec_mem="1g"

                    echo ""
                    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
                    echo -e "  ${BOLD}CPU Limit${NC}"
                    echo -e "  Limits how much processor power this container can use."
                    echo -e "  This prevents it from slowing down other services on your system."
                    echo -e ""
                    echo -e "  ${DIM}Your system has ${GREEN}${cpu_cores}${NC}${DIM} core(s).${NC}"
                    echo -e "  ${DIM}  0.5 = half a core    1.0 = one full core${NC}"
                    echo -e "  ${DIM}  2.0 = two cores      ${cpu_cores}.0 = all cores (no limit)${NC}"
                    echo -e ""
                    echo -e "  Press Enter to use the recommended default."
                    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
                    read -p "  CPU limit [${rec_cpu}]: " input_cpus < /dev/tty || true
                    [ -z "$input_cpus" ] && input_cpus="$rec_cpu"
                    if [[ "$input_cpus" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                        local cpu_ok=$(awk -v val="$input_cpus" -v max="$cpu_cores" 'BEGIN { print (val > 0 && val <= max) ? "yes" : "no" }')
                        if [ "$cpu_ok" = "yes" ]; then
                            new_cpus="$input_cpus"
                            echo -e "  ${GREEN}✓ CPU limit: ${new_cpus} core(s)${NC}"
                        else
                            echo -e "  ${YELLOW}Must be between 0.1 and ${cpu_cores}. Using default: ${rec_cpu}${NC}"
                            new_cpus="$rec_cpu"
                        fi
                    else
                        echo -e "  ${YELLOW}Invalid input. Using default: ${rec_cpu}${NC}"
                        new_cpus="$rec_cpu"
                    fi

                    echo ""
                    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
                    echo -e "  ${BOLD}Memory Limit${NC}"
                    echo -e "  Maximum RAM this container can use."
                    echo -e "  Prevents it from consuming all memory and crashing other services."
                    echo -e ""
                    echo -e "  ${DIM}Your system has ${GREEN}${ram_mb} MB${NC}${DIM} RAM.${NC}"
                    echo -e "  ${DIM}  256m  = 256 MB (good for low-end systems)${NC}"
                    echo -e "  ${DIM}  512m  = 512 MB (balanced)${NC}"
                    echo -e "  ${DIM}  1g    = 1 GB   (high capacity)${NC}"
                    echo -e ""
                    echo -e "  Press Enter to use the recommended default."
                    echo -e "  ${CYAN}───────────────────────────────────────────────────────────────${NC}"
                    read -p "  Memory limit [${rec_mem}]: " input_mem < /dev/tty || true
                    [ -z "$input_mem" ] && input_mem="$rec_mem"
                    if [[ "$input_mem" =~ ^[0-9]+[mMgG]$ ]]; then
                        local mem_val=${input_mem%[mMgG]}
                        local mem_unit=${input_mem: -1}
                        local mem_mb_val=$mem_val
                        [[ "$mem_unit" =~ [gG] ]] && mem_mb_val=$((mem_val * 1024))
                        if [ "$mem_mb_val" -ge 64 ] && [ "$mem_mb_val" -le "$ram_mb" ]; then
                            new_mem="$input_mem"
                            echo -e "  ${GREEN}✓ Memory limit: ${new_mem}${NC}"
                        else
                            echo -e "  ${YELLOW}Must be between 64m and ${ram_mb}m. Using default: ${rec_mem}${NC}"
                            new_mem="$rec_mem"
                        fi
                    else
                        echo -e "  ${YELLOW}Invalid format. Using default: ${rec_mem}${NC}"
                        new_mem="$rec_mem"
                    fi
                    # Save per-container overrides for new containers
                    for i in $(seq $((old_count + 1)) $CONTAINER_COUNT); do
                        [ -n "$new_cpus" ] && eval "CPUS_${i}=${new_cpus}"
                        [ -n "$new_mem" ] && eval "MEMORY_${i}=${new_mem}"
                    done
                fi

                save_settings
                for i in $(seq $((old_count + 1)) $CONTAINER_COUNT); do
                    local name=$(get_container_name $i)
                    local vol=$(get_volume_name $i)
                    docker volume create "$vol" 2>/dev/null || true
                    fix_volume_permissions $i
                    run_conduit_container $i
                    if [ $? -eq 0 ]; then
                        local c_cpu=$(get_container_cpus $i)
                        local c_mem=$(get_container_memory $i)
                        local cpu_info="" mem_info=""
                        [ -n "$c_cpu" ] && cpu_info=", CPU: ${c_cpu}"
                        [ -n "$c_mem" ] && mem_info=", Mem: ${c_mem}"
                        echo -e "  ${GREEN}✓ ${name} started${NC}${cpu_info}${mem_info}"
                    else
                        echo -e "  ${RED}✗ Failed to start ${name}${NC}"
                    fi
                done
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
            r)
                if [ "$CONTAINER_COUNT" -le 1 ]; then
                    echo -e "  ${RED}Must keep at least 1 container.${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    continue
                fi
                local max_rm=$((CONTAINER_COUNT - 1))
                read -p "  How many to remove? (1-${max_rm}): " rm_count < /dev/tty || true
                if ! [[ "$rm_count" =~ ^[0-9]+$ ]] || [ "$rm_count" -lt 1 ] || [ "$rm_count" -gt "$max_rm" ]; then
                    echo -e "  ${RED}Invalid.${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    continue
                fi
                local old_count=$CONTAINER_COUNT
                CONTAINER_COUNT=$((CONTAINER_COUNT - rm_count))
                # Cleanup per-container overrides beyond new container count
                for i in $(seq $((CONTAINER_COUNT + 1)) "$old_count"); do
                    unset "CPUS_${i}" \
                          "MEMORY_${i}" \
                          "MAX_CLIENTS_${i}" \
                          "BANDWIDTH_${i}" 2>/dev/null || true
                done
                save_settings
                # Remove containers in parallel
                local _rm_pids=() _rm_names=()
                for i in $(seq $((CONTAINER_COUNT + 1)) $old_count); do
                    local name=$(get_container_name $i)
                    _rm_names+=("$name")
                    ( docker rm -f "$name" >/dev/null 2>&1 ) &
                    _rm_pids+=($!)
                done
                for idx in "${!_rm_pids[@]}"; do
                    if wait "${_rm_pids[$idx]}" 2>/dev/null; then
                        echo -e "  ${YELLOW}✓ ${_rm_names[$idx]} removed${NC}"
                    else
                        echo -e "  ${RED}✗ Failed to remove ${_rm_names[$idx]}${NC}"
                    fi
                done
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
            s)
                read -p "  Start which container? (1-${CONTAINER_COUNT}, or 'all'): " sc_idx < /dev/tty || true
                local sc_targets=()
                if [ "$sc_idx" = "all" ]; then
                    for i in $(seq 1 $CONTAINER_COUNT); do sc_targets+=($i); done
                elif [[ "$sc_idx" =~ ^[1-9][0-9]*$ ]] && [ "$sc_idx" -le "$CONTAINER_COUNT" ]; then
                    sc_targets+=($sc_idx)
                else
                    echo -e "  ${RED}Invalid.${NC}"
                fi
                # Batch: get all existing containers and their inspect data in one call
                local existing_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
                local all_inspect=""
                local inspect_names=""
                for i in "${sc_targets[@]}"; do
                    local cn=$(get_container_name $i)
                    echo "$existing_containers" | grep -q "^${cn}$" && inspect_names+=" $cn"
                done
                [ -n "$inspect_names" ] && all_inspect=$(docker inspect --format '{{.Name}} {{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}' $inspect_names 2>/dev/null)

                for i in "${sc_targets[@]}"; do
                    local name=$(get_container_name $i)
                    local vol=$(get_volume_name $i)
                    if echo "$existing_containers" | grep -q "^${name}$"; then
                        # Check if settings changed — recreate if needed
                        local needs_recreate=false
                        local want_cpus=$(get_container_cpus $i)
                        local want_mem=$(get_container_memory $i)
                        local insp_line=$(echo "$all_inspect" | grep "/${name} " 2>/dev/null)
                        local cur_nano=$(echo "$insp_line" | awk '{print $2}')
                        local cur_memb=$(echo "$insp_line" | awk '{print $3}')
                        local want_nano=0
                        [ -n "$want_cpus" ] && want_nano=$(awk -v c="$want_cpus" 'BEGIN{printf "%.0f", c*1000000000}')
                        local want_memb=0
                        if [ -n "$want_mem" ]; then
                            local mv=${want_mem%[mMgG]}; local mu=${want_mem: -1}
                            [[ "$mu" =~ [gG] ]] && want_memb=$((mv * 1073741824)) || want_memb=$((mv * 1048576))
                        fi
                        [ "${cur_nano:-0}" != "$want_nano" ] && needs_recreate=true
                        [ "${cur_memb:-0}" != "$want_memb" ] && needs_recreate=true
                        if [ "$needs_recreate" = true ]; then
                            echo -e "  Settings changed for ${name}, recreating..."
                            docker rm -f "$name" 2>/dev/null || true
                            docker volume create "$vol" 2>/dev/null || true
                            fix_volume_permissions $i
                            run_conduit_container $i
                        else
                            docker start "$name" 2>/dev/null
                        fi
                    else
                        docker volume create "$vol" 2>/dev/null || true
                        fix_volume_permissions $i
                        run_conduit_container $i
                    fi
                    if [ $? -eq 0 ]; then
                        echo -e "  ${GREEN}✓ ${name} started${NC}"
                    else
                        echo -e "  ${RED}✗ Failed to start ${name}${NC}"
                    fi
                done
                # Ensure tracker service is running when containers are started
                setup_tracker_service 2>/dev/null || true
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
            t)
                read -p "  Stop which container? (1-${CONTAINER_COUNT}, or 'all'): " sc_idx < /dev/tty || true
                if [ "$sc_idx" = "all" ]; then
                    # Stop all containers in parallel with short timeout
                    local _stop_pids=()
                    local _stop_names=()
                    for i in $(seq 1 $CONTAINER_COUNT); do
                        local name=$(get_container_name $i)
                        _stop_names+=("$name")
                        ( docker stop -t 3 "$name" >/dev/null 2>&1 ) &
                        _stop_pids+=($!)
                    done
                    for idx in "${!_stop_pids[@]}"; do
                        if wait "${_stop_pids[$idx]}" 2>/dev/null; then
                            echo -e "  ${YELLOW}✓ ${_stop_names[$idx]} stopped${NC}"
                        else
                            echo -e "  ${YELLOW}  ${_stop_names[$idx]} was not running${NC}"
                        fi
                    done
                elif [[ "$sc_idx" =~ ^[1-9][0-9]*$ ]] && [ "$sc_idx" -le "$CONTAINER_COUNT" ]; then
                    local name=$(get_container_name $sc_idx)
                    if docker stop -t 3 "$name" 2>/dev/null; then
                        echo -e "  ${YELLOW}✓ ${name} stopped${NC}"
                    else
                        echo -e "  ${YELLOW}  ${name} was not running${NC}"
                    fi
                else
                    echo -e "  ${RED}Invalid.${NC}"
                fi
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
            x)
                read -p "  Restart which container? (1-${CONTAINER_COUNT}, or 'all'): " sc_idx < /dev/tty || true
                local xc_targets=()
                if [ "$sc_idx" = "all" ]; then
                    local persist_dir="$INSTALL_DIR/traffic_stats"
                    if [ -s "$persist_dir/cumulative_data" ] || [ -s "$persist_dir/cumulative_ips" ]; then
                        echo -e "  ${CYAN}⟳ Saving tracker data snapshot...${NC}"
                        [ -s "$persist_dir/cumulative_data" ] && cp "$persist_dir/cumulative_data" "$persist_dir/cumulative_data.bak"
                        [ -s "$persist_dir/cumulative_ips" ] && cp "$persist_dir/cumulative_ips" "$persist_dir/cumulative_ips.bak"
                        [ -s "$persist_dir/geoip_cache" ] && cp "$persist_dir/geoip_cache" "$persist_dir/geoip_cache.bak"
                        echo -e "  ${GREEN}✓ Tracker data snapshot saved${NC}"
                    fi
                    for i in $(seq 1 $CONTAINER_COUNT); do xc_targets+=($i); done
                elif [[ "$sc_idx" =~ ^[1-9][0-9]*$ ]] && [ "$sc_idx" -le "$CONTAINER_COUNT" ]; then
                    xc_targets+=($sc_idx)
                else
                    echo -e "  ${RED}Invalid.${NC}"
                fi
                # Batch: get all existing containers and inspect data in one call
                local existing_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
                local all_inspect=""
                local inspect_names=""
                for i in "${xc_targets[@]}"; do
                    local cn=$(get_container_name $i)
                    echo "$existing_containers" | grep -q "^${cn}$" && inspect_names+=" $cn"
                done
                [ -n "$inspect_names" ] && all_inspect=$(docker inspect --format '{{.Name}} {{join .Args " "}} |||{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}' $inspect_names 2>/dev/null)

                for i in "${xc_targets[@]}"; do
                    local name=$(get_container_name $i)
                    local vol=$(get_volume_name $i)
                    local needs_recreate=false
                    local want_cpus=$(get_container_cpus $i)
                    local want_mem=$(get_container_memory $i)
                    local want_mc=$(get_container_max_clients $i)
                    local want_bw=$(get_container_bandwidth $i)
                    if echo "$existing_containers" | grep -q "^${name}$"; then
                        local insp_line=$(echo "$all_inspect" | grep "/${name} " 2>/dev/null)
                        local cur_args=$(echo "$insp_line" | sed 's/.*\/'"$name"' //' | sed 's/ |||.*//')
                        local cur_mc=$(echo "$cur_args" | sed -n 's/.*--max-clients \([^ ]*\).*/\1/p' 2>/dev/null)
                        local cur_bw=$(echo "$cur_args" | sed -n 's/.*--bandwidth \([^ ]*\).*/\1/p' 2>/dev/null)
                        [ "$cur_mc" != "$want_mc" ] && needs_recreate=true
                        [ "$cur_bw" != "$want_bw" ] && needs_recreate=true
                        local cur_nano=$(echo "$insp_line" | sed 's/.*|||//' | awk '{print $1}')
                        local cur_memb=$(echo "$insp_line" | sed 's/.*|||//' | awk '{print $2}')
                        local want_nano=0
                        [ -n "$want_cpus" ] && want_nano=$(awk -v c="$want_cpus" 'BEGIN{printf "%.0f", c*1000000000}')
                        local want_memb=0
                        if [ -n "$want_mem" ]; then
                            local mv=${want_mem%[mMgG]}; local mu=${want_mem: -1}
                            [[ "$mu" =~ [gG] ]] && want_memb=$((mv * 1073741824)) || want_memb=$((mv * 1048576))
                        fi
                        [ "${cur_nano:-0}" != "$want_nano" ] && needs_recreate=true
                        [ "${cur_memb:-0}" != "$want_memb" ] && needs_recreate=true
                    fi
                    if [ "$needs_recreate" = true ]; then
                        echo -e "  Settings changed for ${name}, recreating..."
                        docker rm -f "$name" 2>/dev/null || true
                        docker volume create "$vol" 2>/dev/null || true
                        fix_volume_permissions $i
                        run_conduit_container $i
                        if [ $? -eq 0 ]; then
                            echo -e "  ${GREEN}✓ ${name} recreated with new settings${NC}"
                        else
                            echo -e "  ${RED}✗ Failed to recreate ${name}${NC}"
                        fi
                    else
                        if docker restart -t 3 "$name" 2>/dev/null; then
                            echo -e "  ${GREEN}✓ ${name} restarted${NC}"
                        else
                            echo -e "  ${RED}✗ Failed to restart ${name}${NC}"
                        fi
                    fi
                done
                # Restart tracker to pick up new container state
                if command -v systemctl &>/dev/null && systemctl is-active --quiet conduit-tracker.service 2>/dev/null; then
                    systemctl restart conduit-tracker.service 2>/dev/null || true
                fi
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
            q)
                show_qr_code
                ;;
            b)
                stop_manage=1
                ;;
            *)
                echo -e "  ${RED}Invalid option.${NC}"
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                ;;
        esac
    done
    echo -ne "\033[?25h"
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM
}

# Get default network interface
get_default_iface() {
    local iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    [ -z "$iface" ] && iface=$(ip route list default 2>/dev/null | awk '{print $5}')
    echo "${iface:-eth0}"
}

# Get current data usage since baseline (in bytes)
get_data_usage() {
    local iface="${DATA_CAP_IFACE:-$(get_default_iface)}"
    if [ ! -f "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        echo "0 0"
        return
    fi
    local rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
    local tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
    local used_rx=$((rx - DATA_CAP_BASELINE_RX))
    local used_tx=$((tx - DATA_CAP_BASELINE_TX))
    # Handle counter reset (reboot)
    if [ "$used_rx" -lt 0 ] || [ "$used_tx" -lt 0 ]; then
        DATA_CAP_BASELINE_RX=$rx
        DATA_CAP_BASELINE_TX=$tx
        save_settings
        used_rx=0
        used_tx=0
    fi
    echo "$used_rx $used_tx"
}

DATA_CAP_EXCEEDED=false
_DATA_CAP_LAST_SAVED=0
_has_any_data_cap() {
    { [ "${DATA_CAP_GB:-0}" -gt 0 ] || [ "${DATA_CAP_UP_GB:-0}" -gt 0 ] || [ "${DATA_CAP_DOWN_GB:-0}" -gt 0 ]; } 2>/dev/null
}
check_data_cap() {
    _has_any_data_cap || return 0
    local usage=$(get_data_usage)
    local used_rx=$(echo "$usage" | awk '{print $1}')
    local used_tx=$(echo "$usage" | awk '{print $2}')
    local total_rx=$((used_rx + ${DATA_CAP_PRIOR_RX:-0}))
    local total_tx=$((used_tx + ${DATA_CAP_PRIOR_TX:-0}))
    local total_used=$((total_rx + total_tx))
    # Persist usage periodically (survives reboots)
    local save_threshold=104857600
    local diff=$((total_used - _DATA_CAP_LAST_SAVED))
    [ "$diff" -lt 0 ] && diff=$((-diff))
    if [ "$diff" -ge "$save_threshold" ]; then
        DATA_CAP_PRIOR_RX=$total_rx
        DATA_CAP_PRIOR_TX=$total_tx
        DATA_CAP_PRIOR_USAGE=$total_used
        DATA_CAP_BASELINE_RX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$(get_default_iface)}/statistics/rx_bytes 2>/dev/null || echo 0)
        DATA_CAP_BASELINE_TX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$(get_default_iface)}/statistics/tx_bytes 2>/dev/null || echo 0)
        save_settings
        _DATA_CAP_LAST_SAVED=$total_used
    fi
    # Check each cap independently
    local exceeded=false
    if [ "${DATA_CAP_UP_GB:-0}" -gt 0 ] 2>/dev/null; then
        local up_cap=$(awk -v gb="$DATA_CAP_UP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
        [ "$total_tx" -ge "$up_cap" ] 2>/dev/null && exceeded=true
    fi
    if [ "${DATA_CAP_DOWN_GB:-0}" -gt 0 ] 2>/dev/null; then
        local down_cap=$(awk -v gb="$DATA_CAP_DOWN_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
        [ "$total_rx" -ge "$down_cap" ] 2>/dev/null && exceeded=true
    fi
    if [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null; then
        local total_cap=$(awk -v gb="$DATA_CAP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
        [ "$total_used" -ge "$total_cap" ] 2>/dev/null && exceeded=true
    fi
    if [ "$exceeded" = true ]; then
        # Only stop containers once when cap is first exceeded
        if [ "$DATA_CAP_EXCEEDED" = false ]; then
            DATA_CAP_EXCEEDED=true
            DATA_CAP_PRIOR_RX=$total_rx
            DATA_CAP_PRIOR_TX=$total_tx
            DATA_CAP_PRIOR_USAGE=$total_used
            DATA_CAP_BASELINE_RX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$(get_default_iface)}/statistics/rx_bytes 2>/dev/null || echo 0)
            DATA_CAP_BASELINE_TX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$(get_default_iface)}/statistics/tx_bytes 2>/dev/null || echo 0)
            save_settings
            _DATA_CAP_LAST_SAVED=$total_used
            # Signal tracker to skip stuck-container restarts
            touch "$PERSIST_DIR/data_cap_exceeded" 2>/dev/null
            for i in $(seq 1 $CONTAINER_COUNT); do
                local name=$(get_container_name $i)
                docker stop "$name" 2>/dev/null || true
            done
            [ "$SNOWFLAKE_ENABLED" = "true" ] && stop_snowflake 2>/dev/null
        fi
        return 1  # cap exceeded
    else
        DATA_CAP_EXCEEDED=false
        rm -f "$PERSIST_DIR/data_cap_exceeded" 2>/dev/null
    fi
    return 0
}

# Format bytes to GB/TB with 2 decimal places
format_gb() {
    awk -v b="$1" 'BEGIN{if(b>=1099511627776) printf "%.2f TB", b/1099511627776; else printf "%.2f GB", b/1073741824}'
}

set_data_cap() {
    local iface cap_choice new_cap
    iface=$(get_default_iface)
    echo ""
    echo -e "${CYAN}═══ DATA USAGE CAP ═══${NC}"
    if _has_any_data_cap; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_rx=$((used_rx + ${DATA_CAP_PRIOR_RX:-0}))
        local total_tx=$((used_tx + ${DATA_CAP_PRIOR_TX:-0}))
        local total_used=$((total_rx + total_tx))
        [ "${DATA_CAP_UP_GB:-0}" -gt 0 ] 2>/dev/null && \
            echo -e "  Upload cap:    $(format_gb $total_tx) / ${GREEN}${DATA_CAP_UP_GB} GB${NC}"
        [ "${DATA_CAP_DOWN_GB:-0}" -gt 0 ] 2>/dev/null && \
            echo -e "  Download cap:  $(format_gb $total_rx) / ${GREEN}${DATA_CAP_DOWN_GB} GB${NC}"
        [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null && \
            echo -e "  Total cap:     $(format_gb $total_used) / ${GREEN}${DATA_CAP_GB} GB${NC}"
        echo -e "  Interface:     ${DATA_CAP_IFACE:-$iface}"
    else
        echo -e "  Caps:          ${YELLOW}None configured${NC}"
        echo -e "  Interface:     $iface"
    fi
    echo ""
    echo "  Options:"
    echo "    1. Set upload cap"
    echo "    2. Set download cap"
    echo "    3. Set total cap"
    echo "    4. Reset usage counters"
    echo "    5. Remove all caps"
    echo "    6. Back"
    echo ""
    read -p "  Choice: " cap_choice < /dev/tty || true

    case "$cap_choice" in
        1)
            echo -e "  Current: ${DATA_CAP_UP_GB:-0} GB (0 = disabled)"
            read -p "  Upload cap in GB: " new_cap < /dev/tty || true
            if [[ "$new_cap" =~ ^[0-9]+$ ]]; then
                DATA_CAP_UP_GB=$new_cap
                DATA_CAP_IFACE=$iface
                if [ "$new_cap" -gt 0 ] && [ "${DATA_CAP_PRIOR_RX:-0}" -eq 0 ] && [ "${DATA_CAP_PRIOR_TX:-0}" -eq 0 ] && [ "${DATA_CAP_PRIOR_USAGE:-0}" -eq 0 ]; then
                    DATA_CAP_BASELINE_RX=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
                    DATA_CAP_BASELINE_TX=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
                    DATA_CAP_PRIOR_USAGE=0; DATA_CAP_PRIOR_RX=0; DATA_CAP_PRIOR_TX=0
                fi
                save_settings
                [ "$new_cap" -eq 0 ] && echo -e "  ${GREEN}✓ Upload cap disabled${NC}" || echo -e "  ${GREEN}✓ Upload cap set to ${new_cap} GB${NC}"
            else
                echo -e "  ${RED}Invalid value. Use a number (0 to disable).${NC}"
            fi
            ;;
        2)
            echo -e "  Current: ${DATA_CAP_DOWN_GB:-0} GB (0 = disabled)"
            read -p "  Download cap in GB: " new_cap < /dev/tty || true
            if [[ "$new_cap" =~ ^[0-9]+$ ]]; then
                DATA_CAP_DOWN_GB=$new_cap
                DATA_CAP_IFACE=$iface
                if [ "$new_cap" -gt 0 ] && [ "${DATA_CAP_PRIOR_RX:-0}" -eq 0 ] && [ "${DATA_CAP_PRIOR_TX:-0}" -eq 0 ] && [ "${DATA_CAP_PRIOR_USAGE:-0}" -eq 0 ]; then
                    DATA_CAP_BASELINE_RX=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
                    DATA_CAP_BASELINE_TX=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
                    DATA_CAP_PRIOR_USAGE=0; DATA_CAP_PRIOR_RX=0; DATA_CAP_PRIOR_TX=0
                fi
                save_settings
                [ "$new_cap" -eq 0 ] && echo -e "  ${GREEN}✓ Download cap disabled${NC}" || echo -e "  ${GREEN}✓ Download cap set to ${new_cap} GB${NC}"
            else
                echo -e "  ${RED}Invalid value. Use a number (0 to disable).${NC}"
            fi
            ;;
        3)
            echo -e "  Current: ${DATA_CAP_GB:-0} GB (0 = disabled)"
            read -p "  Total cap in GB: " new_cap < /dev/tty || true
            if [[ "$new_cap" =~ ^[0-9]+$ ]]; then
                DATA_CAP_GB=$new_cap
                DATA_CAP_IFACE=$iface
                if [ "$new_cap" -gt 0 ] && [ "${DATA_CAP_PRIOR_RX:-0}" -eq 0 ] && [ "${DATA_CAP_PRIOR_TX:-0}" -eq 0 ] && [ "${DATA_CAP_PRIOR_USAGE:-0}" -eq 0 ]; then
                    DATA_CAP_BASELINE_RX=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
                    DATA_CAP_BASELINE_TX=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
                    DATA_CAP_PRIOR_USAGE=0; DATA_CAP_PRIOR_RX=0; DATA_CAP_PRIOR_TX=0
                fi
                save_settings
                [ "$new_cap" -eq 0 ] && echo -e "  ${GREEN}✓ Total cap disabled${NC}" || echo -e "  ${GREEN}✓ Total cap set to ${new_cap} GB${NC}"
            else
                echo -e "  ${RED}Invalid value. Use a number (0 to disable).${NC}"
            fi
            ;;
        4)
            DATA_CAP_PRIOR_USAGE=0
            DATA_CAP_PRIOR_RX=0
            DATA_CAP_PRIOR_TX=0
            DATA_CAP_BASELINE_RX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$iface}/statistics/rx_bytes 2>/dev/null || echo 0)
            DATA_CAP_BASELINE_TX=$(cat /sys/class/net/${DATA_CAP_IFACE:-$iface}/statistics/tx_bytes 2>/dev/null || echo 0)
            DATA_CAP_EXCEEDED=false
            rm -f "$PERSIST_DIR/data_cap_exceeded" 2>/dev/null
            save_settings
            echo -e "  ${GREEN}✓ Usage counters reset${NC}"
            ;;
        5)
            DATA_CAP_GB=0
            DATA_CAP_UP_GB=0
            DATA_CAP_DOWN_GB=0
            DATA_CAP_BASELINE_RX=0
            DATA_CAP_BASELINE_TX=0
            DATA_CAP_PRIOR_USAGE=0
            DATA_CAP_PRIOR_RX=0
            DATA_CAP_PRIOR_TX=0
            DATA_CAP_IFACE=""
            DATA_CAP_EXCEEDED=false
            rm -f "$PERSIST_DIR/data_cap_exceeded" 2>/dev/null
            save_settings
            echo -e "  ${GREEN}✓ All data caps removed${NC}"
            ;;
        6|"")
            return
            ;;
    esac
}

# Save all settings to file
save_settings() {
    local _tmp="$INSTALL_DIR/settings.conf.tmp.$$"
    cat > "$_tmp" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
DATA_CAP_GB=$DATA_CAP_GB
DATA_CAP_UP_GB=$DATA_CAP_UP_GB
DATA_CAP_DOWN_GB=$DATA_CAP_DOWN_GB
DATA_CAP_IFACE=$DATA_CAP_IFACE
DATA_CAP_BASELINE_RX=$DATA_CAP_BASELINE_RX
DATA_CAP_BASELINE_TX=$DATA_CAP_BASELINE_TX
DATA_CAP_PRIOR_USAGE=${DATA_CAP_PRIOR_USAGE:-0}
DATA_CAP_PRIOR_RX=${DATA_CAP_PRIOR_RX:-0}
DATA_CAP_PRIOR_TX=${DATA_CAP_PRIOR_TX:-0}
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
DOCKER_CPUS=${DOCKER_CPUS:-}
DOCKER_MEMORY=${DOCKER_MEMORY:-}
TRACKER_ENABLED=${TRACKER_ENABLED:-true}
SNOWFLAKE_ENABLED=${SNOWFLAKE_ENABLED:-false}
SNOWFLAKE_COUNT=${SNOWFLAKE_COUNT:-1}
SNOWFLAKE_CPUS=${SNOWFLAKE_CPUS:-}
SNOWFLAKE_MEMORY=${SNOWFLAKE_MEMORY:-}
EOF
    # Save per-container overrides
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local mc_var="MAX_CLIENTS_${i}"
        local bw_var="BANDWIDTH_${i}"
        local cpu_var="CPUS_${i}"
        local mem_var="MEMORY_${i}"
        [ -n "${!mc_var}" ] && echo "${mc_var}=${!mc_var}" >> "$_tmp"
        [ -n "${!bw_var}" ] && echo "${bw_var}=${!bw_var}" >> "$_tmp"
        [ -n "${!cpu_var}" ] && echo "${cpu_var}=${!cpu_var}" >> "$_tmp"
        [ -n "${!mem_var}" ] && echo "${mem_var}=${!mem_var}" >> "$_tmp"
    done
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$INSTALL_DIR/settings.conf"
}

# ─── Telegram Bot Functions ───────────────────────────────────────────────────

escape_telegram_markdown() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\*/\\*}"
    text="${text//_/\\_}"
    text="${text//\`/\\\`}"
    text="${text//\[/\\[}"
    text="${text//\]/\\]}"
    echo "$text"
}

telegram_send_message() {
    local message="$1"
    { [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; } && return 1
    # Prepend server label + IP (escape for Markdown)
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    label=$(escape_telegram_markdown "$label")
    local _ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
    if [ -n "$_ip" ]; then
        message="[${label} | ${_ip}] ${message}"
    else
        message="[${label}] ${message}"
    fi
    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$message" \
        --data-urlencode "parse_mode=Markdown" 2>/dev/null)
    [ $? -ne 0 ] && return 1
    echo "$response" | grep -q '"ok":true' && return 0
    return 1
}

telegram_test_message() {
    local interval_label="${TELEGRAM_INTERVAL:-6}"
    local report=$(telegram_build_report)
    local message="✅ *Conduit Manager Connected!*

🔗 *What is Psiphon Conduit?*
You are running a Psiphon relay node that helps people in censored regions access the open internet.

📬 *What this bot sends you every ${interval_label}h:*
• Container status & uptime
• Connected peers count
• Upload & download totals
• CPU & RAM usage
• Data cap usage (if set)
• Top countries being served

⚠️ *Alerts:*
If a container gets stuck and is auto-restarted, you will receive an immediate alert.

━━━━━━━━━━━━━━━━━━━━
🎮 *Available Commands:*
━━━━━━━━━━━━━━━━━━━━
/status — Full status report on demand
/peers — Show connected & connecting clients
/uptime — Uptime for each container
/containers — List all containers with status
/start\_N — Start container N (e.g. /start\_1)
/stop\_N — Stop container N (e.g. /stop\_2)
/restart\_N — Restart container N (e.g. /restart\_1)

Replace N with the container number (1+).

━━━━━━━━━━━━━━━━━━━━
📊 *Your first report:*
━━━━━━━━━━━━━━━━━━━━

${report}"
    telegram_send_message "$message"
}

telegram_get_chat_id() {
    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" 2>/dev/null)
    [ -z "$response" ] && return 1
    echo "$response" | grep -q '"ok":true' || return 1
    local chat_id=""
    if command -v python3 &>/dev/null; then
        chat_id=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    msgs=d.get('result',[])
    if msgs:
        print(msgs[-1]['message']['chat']['id'])
except: pass
" <<< "$response" 2>/dev/null)
    fi
    # Fallback: POSIX-compatible grep extraction
    if [ -z "$chat_id" ]; then
        chat_id=$(echo "$response" | grep -o '"chat"[[:space:]]*:[[:space:]]*{[[:space:]]*"id"[[:space:]]*:[[:space:]]*-*[0-9]*' | grep -o -- '-*[0-9]*$' | tail -1 2>/dev/null)
    fi
    if [ -n "$chat_id" ]; then
        # Validate chat_id is numeric (with optional leading minus for groups)
        if ! echo "$chat_id" | grep -qE '^-?[0-9]+$'; then
            return 1
        fi
        TELEGRAM_CHAT_ID="$chat_id"
        return 0
    fi
    return 1
}

telegram_build_report() {
    local report="📊 *Conduit Status Report*"
    report+=$'\n'
    report+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    report+=$'\n'
    report+=$'\n'

    local running_count=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running_count=${running_count:-0}
    local total=$CONTAINER_COUNT
    if [ "$running_count" -gt 0 ]; then
        local earliest_start=""
        for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
            local cname=$(get_container_name $i)
            local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
            if [ -n "$started" ]; then
                local se=$(date -d "$started" +%s 2>/dev/null || echo 0)
                if [ -z "$earliest_start" ] || [ "$se" -lt "$earliest_start" ] 2>/dev/null; then
                    earliest_start=$se
                fi
            fi
        done
        if [ -n "$earliest_start" ] && [ "$earliest_start" -gt 0 ] 2>/dev/null; then
            local now=$(date +%s)
            local up=$((now - earliest_start))
            local days=$((up / 86400))
            local hours=$(( (up % 86400) / 3600 ))
            local mins=$(( (up % 3600) / 60 ))
            if [ "$days" -gt 0 ]; then
                report+="⏱ Uptime: ${days}d ${hours}h ${mins}m"
            else
                report+="⏱ Uptime: ${hours}h ${mins}m"
            fi
            report+=$'\n'
        fi
    fi
    report+="📦 Containers: ${running_count}/${total} running"
    report+=$'\n'

    local uptime_log="$INSTALL_DIR/traffic_stats/uptime_log"
    if [ -s "$uptime_log" ]; then
        local cutoff_24h=$(( $(date +%s) - 86400 ))
        local t24=$(awk -F'|' -v c="$cutoff_24h" '$1+0>=c' "$uptime_log" 2>/dev/null | wc -l)
        local u24=$(awk -F'|' -v c="$cutoff_24h" '$1+0>=c && $2+0>0' "$uptime_log" 2>/dev/null | wc -l)
        if [ "${t24:-0}" -gt 0 ] 2>/dev/null; then
            local avail_24h=$(awk "BEGIN {printf \"%.1f\", ($u24/$t24)*100}" 2>/dev/null || echo "0")
            report+="📈 Availability: ${avail_24h}% (24h)"
            report+=$'\n'
        fi
        # Streak: consecutive minutes at end of log with running > 0
        local streak_mins=$(awk -F'|' '{a[NR]=$2+0} END{n=0; for(i=NR;i>=1;i--){if(a[i]<=0) break; n++} print n}' "$uptime_log" 2>/dev/null)
        if [ "${streak_mins:-0}" -gt 0 ] 2>/dev/null; then
            local sd=$((streak_mins / 1440)) sh=$(( (streak_mins % 1440) / 60 )) sm=$((streak_mins % 60))
            local streak_str=""
            [ "$sd" -gt 0 ] && streak_str+="${sd}d "
            streak_str+="${sh}h ${sm}m"
            report+="🔥 Streak: ${streak_str}"
            report+=$'\n'
        fi
    fi

    # Connected peers + connecting (matching TUI format)
    local total_peers=0
    local total_connecting=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$(docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        local peers=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connected:") print $(j+1)+0}}' | head -1)
        local cing=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connecting:") print $(j+1)+0}}' | head -1)
        total_peers=$((total_peers + ${peers:-0}))
        total_connecting=$((total_connecting + ${cing:-0}))
    done
    report+="👥 Clients: ${total_peers} connected, ${total_connecting} connecting"
    report+=$'\n'

    # App CPU / RAM (normalize CPU by core count like dashboard)
    local stats=$(get_container_stats)
    local raw_cpu=$(echo "$stats" | awk '{print $1}')
    local cores=$(get_cpu_cores)
    local app_cpu=$(awk "BEGIN {printf \"%.1f%%\", ${raw_cpu%\%} / $cores}" 2>/dev/null || echo "$raw_cpu")
    local app_ram=$(echo "$stats" | awk '{print $2, $3, $4}')
    app_cpu=$(escape_telegram_markdown "$app_cpu")
    app_ram=$(escape_telegram_markdown "$app_ram")
    report+="🖥 App CPU: ${app_cpu} | RAM: ${app_ram}"
    report+=$'\n'

    # System CPU + Temp + RAM
    local sys_stats=$(get_system_stats)
    local sys_cpu=$(echo "$sys_stats" | awk '{print $1}')
    local sys_temp=$(echo "$sys_stats" | awk '{print $2}')
    local sys_ram_used=$(echo "$sys_stats" | awk '{print $3}')
    local sys_ram_total=$(echo "$sys_stats" | awk '{print $4}')
    local sys_line="🔧 System CPU: ${sys_cpu}"
    [ "$sys_temp" != "-" ] && sys_line+=" (${sys_temp})"
    sys_line+=" | RAM: ${sys_ram_used} / ${sys_ram_total}"
    sys_line=$(escape_telegram_markdown "$sys_line")
    report+="${sys_line}"
    report+=$'\n'

    # Data usage
    if _has_any_data_cap; then
        local usage=$(get_data_usage 2>/dev/null)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_rx=$(( ${used_rx:-0} + ${DATA_CAP_PRIOR_RX:-0} ))
        local total_tx=$(( ${used_tx:-0} + ${DATA_CAP_PRIOR_TX:-0} ))
        local total_used=$(( total_rx + total_tx ))
        local cap_parts=""
        if [ "${DATA_CAP_UP_GB:-0}" -gt 0 ] 2>/dev/null; then
            local up_gb=$(awk "BEGIN {printf \"%.2f\", $total_tx/1073741824}" 2>/dev/null || echo "0")
            cap_parts+="up ${up_gb}/${DATA_CAP_UP_GB}GB"
        fi
        if [ "${DATA_CAP_DOWN_GB:-0}" -gt 0 ] 2>/dev/null; then
            [ -n "$cap_parts" ] && cap_parts+=" "
            local dn_gb=$(awk "BEGIN {printf \"%.2f\", $total_rx/1073741824}" 2>/dev/null || echo "0")
            cap_parts+="dn ${dn_gb}/${DATA_CAP_DOWN_GB}GB"
        fi
        if [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null; then
            [ -n "$cap_parts" ] && cap_parts+=" "
            local tot_gb=$(awk "BEGIN {printf \"%.2f\", $total_used/1073741824}" 2>/dev/null || echo "0")
            cap_parts+="total ${tot_gb}/${DATA_CAP_GB}GB"
        fi
        report+="📈 Data: ${cap_parts}"
        report+=$'\n'
    fi

    if [ "$SNOWFLAKE_ENABLED" = "true" ] && is_snowflake_running; then
        local sf_stats sf_conn sf_in sf_out sf_to
        sf_stats=$(get_snowflake_stats 2>/dev/null)
        sf_conn=$(echo "$sf_stats" | awk '{print $1}')
        sf_in=$(echo "$sf_stats" | awk '{print $2}')
        sf_out=$(echo "$sf_stats" | awk '{print $3}')
        sf_to=$(echo "$sf_stats" | awk '{print $4}')
        sf_conn=${sf_conn:-0}
        local sf_in_fmt=$(format_bytes "${sf_in:-0}")
        local sf_out_fmt=$(format_bytes "${sf_out:-0}")
        local sf_to_label=""
        [ "${sf_to:-0}" -gt 0 ] 2>/dev/null && sf_to_label=" (${sf_to} to)"
        report+="❄ Snowflake: ${sf_conn} conn${sf_to_label} | ↓${sf_in_fmt} ↑${sf_out_fmt}"
        report+=$'\n'
    fi

    local total_restarts=0
    local restart_details=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local rc=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null || echo 0)
        rc=${rc:-0}
        total_restarts=$((total_restarts + rc))
        [ "$rc" -gt 0 ] && restart_details+=" C${i}:${rc}"
    done
    if [ "$total_restarts" -gt 0 ]; then
        report+="🔄 Restarts: ${total_restarts}${restart_details}"
        report+=$'\n'
    fi

    local snap_file_peers="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snap_file_peers" ]; then
        local top_peers
        top_peers=$(awk -F'|' '{if($2!="") cnt[$2]++} END{for(c in cnt) print cnt[c]"|"c}' "$snap_file_peers" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_peers" ]; then
            report+="🗺 Top by peers:"
            report+=$'\n'
            while IFS='|' read -r cnt country; do
                [ -z "$country" ] && continue
                local safe_c=$(escape_telegram_markdown "$country")
                report+="  • ${safe_c}: ${cnt} clients"
                report+=$'\n'
            done <<< "$top_peers"
        fi
    fi

    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file" ]; then
        local top_countries
        top_countries=$(awk -F'|' '{if($1!="" && $3+0>0) bytes[$1]+=$3+0} END{for(c in bytes) print bytes[c]"|"c}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_countries" ]; then
            report+="🌍 Top by upload:"
            report+=$'\n'
            while IFS='|' read -r bytes country; do
                [ -z "$country" ] && continue
                local safe_country=$(escape_telegram_markdown "$country")
                local fmt=$(format_bytes "$bytes" 2>/dev/null || echo "${bytes} B")
                report+="  • ${safe_country} (${fmt})"
                report+=$'\n'
            done <<< "$top_countries"
        fi
    fi

    # Unique IPs from tracker_snapshot
    local snapshot_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snapshot_file" ]; then
        local active_clients=$(wc -l < "$snapshot_file" 2>/dev/null || echo 0)
        report+="📡 Total lifetime IPs served: ${active_clients}"
        report+=$'\n'
    fi

    # Total bandwidth served from cumulative_data
    if [ -s "$data_file" ]; then
        local total_bw
        total_bw=$(awk -F'|' '{s+=$2+0; s+=$3+0} END{printf "%.0f", s}' "$data_file" 2>/dev/null || echo 0)
        if [ "${total_bw:-0}" -gt 0 ] 2>/dev/null; then
            local total_bw_fmt=$(format_bytes "$total_bw" 2>/dev/null || echo "${total_bw} B")
            report+="📊 Total bandwidth served: ${total_bw_fmt}"
            report+=$'\n'
        fi
    fi

    echo "$report"
}

telegram_generate_notify_script() {
    cat > "$INSTALL_DIR/conduit-telegram.sh" << 'TGEOF'
#!/bin/bash
# Conduit Telegram Notification Service
# Runs as a systemd service, sends periodic status reports

INSTALL_DIR="/opt/conduit"

[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

# Exit if not configured
[ "$TELEGRAM_ENABLED" != "true" ] && exit 0
[ -z "$TELEGRAM_BOT_TOKEN" ] && exit 0
[ -z "$TELEGRAM_CHAT_ID" ] && exit 0

# Cache server IP once at startup
_server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "")

telegram_send() {
    local message="$1"
    # Prepend server label + IP (escape for Markdown)
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    label=$(escape_md "$label")
    if [ -n "$_server_ip" ]; then
        message="[${label} | ${_server_ip}] ${message}"
    else
        message="[${label}] ${message}"
    fi
    curl -s --max-time 10 --max-filesize 1048576 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$message" \
        --data-urlencode "parse_mode=Markdown" >/dev/null 2>&1
}

telegram_send_inline_keyboard() {
    local text="$1"
    local keyboard_json="$2"
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    label=$(escape_md "$label")
    if [ -n "$_server_ip" ]; then
        text="[${label} | ${_server_ip}] ${text}"
    else
        text="[${label}] ${text}"
    fi
    curl -s --max-time 10 --max-filesize 1048576 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$text" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "reply_markup=$keyboard_json" >/dev/null 2>&1
}

telegram_send_photo() {
    local photo_path="$1"
    local caption="$2"
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    if [ -n "$_server_ip" ]; then
        caption="[${label} | ${_server_ip}] ${caption}"
    else
        caption="[${label}] ${caption}"
    fi
    curl -s --max-time 30 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendPhoto" \
        -F "chat_id=$TELEGRAM_CHAT_ID" \
        -F "photo=@${photo_path}" \
        -F "caption=$caption" >/dev/null 2>&1
}

telegram_answer_callback() {
    local callback_id="$1"
    local answer_text="${2:-}"
    curl -s --max-time 5 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/answerCallbackQuery" \
        --data-urlencode "callback_query_id=$callback_id" \
        --data-urlencode "text=$answer_text" >/dev/null 2>&1
}

escape_md() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\*/\\*}"
    text="${text//_/\\_}"
    text="${text//\`/\\\`}"
    text="${text//\[/\\[}"
    text="${text//\]/\\]}"
    echo "$text"
}

get_container_name() {
    local i=$1
    if [ "$i" -le 1 ]; then
        echo "conduit"
    else
        echo "conduit-${i}"
    fi
}

get_volume_name() {
    local idx=${1:-1}
    if [ "$idx" -eq 1 ]; then
        echo "conduit-data"
    else
        echo "conduit-data-${idx}"
    fi
}

get_node_id() {
    local vol="${1:-conduit-data}"
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        local mountpoint=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}' 2>/dev/null)
        local key_json=""
        if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
            key_json=$(cat "$mountpoint/conduit_key.json" 2>/dev/null)
        else
            local tmp_ctr="conduit-nodeid-tmp"
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            docker create --name "$tmp_ctr" -v "$vol":/data alpine true 2>/dev/null || true
            key_json=$(docker cp "$tmp_ctr:/data/conduit_key.json" - 2>/dev/null | tar -xO 2>/dev/null)
            docker rm -f "$tmp_ctr" 2>/dev/null || true
        fi
        if [ -n "$key_json" ]; then
            echo "$key_json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n'
        fi
    fi
}

get_raw_key() {
    local vol="${1:-conduit-data}"
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        local mountpoint=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}' 2>/dev/null)
        local key_json=""
        if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
            key_json=$(cat "$mountpoint/conduit_key.json" 2>/dev/null)
        else
            local tmp_ctr="conduit-rawkey-tmp"
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            docker create --name "$tmp_ctr" -v "$vol":/data alpine true 2>/dev/null || true
            key_json=$(docker cp "$tmp_ctr:/data/conduit_key.json" - 2>/dev/null | tar -xO 2>/dev/null)
            docker rm -f "$tmp_ctr" 2>/dev/null || true
        fi
        if [ -n "$key_json" ]; then
            echo "$key_json" | grep "privateKeyBase64" | awk -F'"' '{print $4}'
        fi
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    fi
    [ "$cores" -lt 1 ] 2>/dev/null && cores=1
    echo "$cores"
}

get_container_stats() {
    local names=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        names+=" $(get_container_name $i)"
    done
    local all_stats=$(timeout 10 docker stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" $names 2>/dev/null)
    if [ -z "$all_stats" ]; then
        echo "0% 0MiB"
    elif [ "${CONTAINER_COUNT:-1}" -le 1 ]; then
        echo "$all_stats"
    else
        echo "$all_stats" | awk '{
            cpu=$1; gsub(/%/,"",cpu); total_cpu+=cpu+0
            mem=$2; gsub(/[^0-9.]/,"",mem); mem+=0
            if($2~/GiB/) mem*=1024; else if($2~/KiB/) mem/=1024
            total_mem+=mem
            if(mem_limit=="") mem_limit=$4
            found=1
        } END {
            if(!found){print "0% 0MiB"; exit}
            if(total_mem>=1024) ms=sprintf("%.2fGiB",total_mem/1024); else ms=sprintf("%.1fMiB",total_mem)
            printf "%.2f%% %s / %s\n", total_cpu, ms, mem_limit
        }'
    fi
}

track_uptime() {
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    echo "$(date +%s)|${running}" >> "$INSTALL_DIR/traffic_stats/uptime_log"
    # Trim to 7 days
    local log_file="$INSTALL_DIR/traffic_stats/uptime_log"
    local lines=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    if [ "$lines" -gt 10080 ] 2>/dev/null; then
        tail -10080 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    fi
}

calc_uptime_pct() {
    local period_secs=${1:-86400}
    local log_file="$INSTALL_DIR/traffic_stats/uptime_log"
    [ ! -s "$log_file" ] && echo "0" && return
    local cutoff=$(( $(date +%s) - period_secs ))
    local total=0
    local up=0
    while IFS='|' read -r ts count; do
        [ "$ts" -lt "$cutoff" ] 2>/dev/null && continue
        total=$((total + 1))
        [ "$count" -gt 0 ] 2>/dev/null && up=$((up + 1))
    done < "$log_file"
    [ "$total" -eq 0 ] && echo "0" && return
    awk "BEGIN {printf \"%.1f\", ($up/$total)*100}" 2>/dev/null || echo "0"
}

rotate_cumulative_data() {
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    local marker="$INSTALL_DIR/traffic_stats/.last_rotation_month"
    local current_month=$(date '+%Y-%m')
    local last_month=""
    [ -f "$marker" ] && last_month=$(cat "$marker" 2>/dev/null)
    # First run: just set the marker, don't archive
    if [ -z "$last_month" ]; then
        echo "$current_month" > "$marker"
        return
    fi
    if [ "$current_month" != "$last_month" ] && [ -s "$data_file" ]; then
        cp "$data_file" "${data_file}.${last_month}"
        echo "$current_month" > "$marker"
        # Delete archives older than 3 months (portable: 90 days in seconds)
        local cutoff_ts=$(( $(date +%s) - 7776000 ))
        for archive in "$INSTALL_DIR/traffic_stats/cumulative_data."[0-9][0-9][0-9][0-9]-[0-9][0-9]; do
            [ ! -f "$archive" ] && continue
            local archive_mtime=$(stat -c %Y "$archive" 2>/dev/null || stat -f %m "$archive" 2>/dev/null || echo 0)
            if [ "$archive_mtime" -gt 0 ] && [ "$archive_mtime" -lt "$cutoff_ts" ] 2>/dev/null; then
                rm -f "$archive"
            fi
        done
    fi
}

check_alerts() {
    [ "$TELEGRAM_ALERTS_ENABLED" != "true" ] && return
    local now=$(date +%s)
    local cooldown=3600

    # CPU + RAM check (single docker stats call)
    local conduit_containers=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "^conduit" 2>/dev/null || true)
    local stats_line=""
    if [ -n "$conduit_containers" ]; then
        stats_line=$(timeout 10 docker stats --no-stream --format "{{.CPUPerc}} {{.MemPerc}}" $conduit_containers 2>/dev/null | \
            awk '{gsub(/%/,""); cpu+=$1; if($2+0>ram) ram=$2} END{printf "%.2f%% %.2f%%", cpu, ram}')
    fi
    local raw_cpu=$(echo "$stats_line" | awk '{print $1}')
    local ram_pct=$(echo "$stats_line" | awk '{print $2}')

    local cores=$(get_cpu_cores)
    local cpu_val=$(awk "BEGIN {printf \"%.0f\", ${raw_cpu%\%} / $cores}" 2>/dev/null || echo 0)
    if [ "${cpu_val:-0}" -gt 90 ] 2>/dev/null; then
        cpu_breach=$((cpu_breach + 1))
    else
        cpu_breach=0
    fi
    if [ "$cpu_breach" -ge 3 ] && [ $((now - last_alert_cpu)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "⚠️ *Alert: High CPU*
CPU usage at ${cpu_val}% for 3\\+ minutes"
        last_alert_cpu=$now
        cpu_breach=0
    fi

    local ram_val=${ram_pct%\%}
    ram_val=${ram_val%%.*}
    if [ "${ram_val:-0}" -gt 90 ] 2>/dev/null; then
        ram_breach=$((ram_breach + 1))
    else
        ram_breach=0
    fi
    if [ "$ram_breach" -ge 3 ] && [ $((now - last_alert_ram)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "⚠️ *Alert: High RAM*
Memory usage at ${ram_pct} for 3\\+ minutes"
        last_alert_ram=$now
        ram_breach=0
    fi

    # All containers down
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    if [ "$running" -eq 0 ] 2>/dev/null && [ $((now - last_alert_down)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "🔴 *Alert: All containers down*
No Conduit containers are running\\!"
        last_alert_down=$now
    fi

    # Zero peers for 2+ hours
    local total_peers=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$(timeout 5 docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        local peers=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connected:") print $(j+1)+0}}' | head -1)
        total_peers=$((total_peers + ${peers:-0}))
    done
    if [ "$total_peers" -eq 0 ] 2>/dev/null; then
        if [ "$zero_peers_since" -eq 0 ] 2>/dev/null; then
            zero_peers_since=$now
        elif [ $((now - zero_peers_since)) -ge 7200 ] && [ $((now - last_alert_peers)) -ge $cooldown ] 2>/dev/null; then
            telegram_send "⚠️ *Alert: Zero peers*
No connected peers for 2\\+ hours"
            last_alert_peers=$now
            zero_peers_since=$now
        fi
    else
        zero_peers_since=0
    fi
}

record_snapshot() {
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    local total_peers=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$(docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        local peers=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connected:") print $(j+1)+0}}' | head -1)
        total_peers=$((total_peers + ${peers:-0}))
    done
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    local total_bw=0
    [ -s "$data_file" ] && total_bw=$(awk -F'|' '{s+=$2+$3} END{print s+0}' "$data_file" 2>/dev/null)
    echo "$(date +%s)|${total_peers}|${total_bw:-0}|${running}" >> "$INSTALL_DIR/traffic_stats/report_snapshots"
    # Trim to 720 entries
    local snap_file="$INSTALL_DIR/traffic_stats/report_snapshots"
    local lines=$(wc -l < "$snap_file" 2>/dev/null || echo 0)
    if [ "$lines" -gt 720 ] 2>/dev/null; then
        tail -720 "$snap_file" > "${snap_file}.tmp" && mv "${snap_file}.tmp" "$snap_file"
    fi
}

build_summary() {
    local period_label="$1"
    local period_secs="$2"
    local snap_file="$INSTALL_DIR/traffic_stats/report_snapshots"
    [ ! -s "$snap_file" ] && return
    local cutoff=$(( $(date +%s) - period_secs ))
    local peak_peers=0
    local sum_peers=0
    local count=0
    local first_bw=0
    local last_bw=0
    local got_first=false
    while IFS='|' read -r ts peers bw running; do
        [ "$ts" -lt "$cutoff" ] 2>/dev/null && continue
        count=$((count + 1))
        sum_peers=$((sum_peers + ${peers:-0}))
        [ "${peers:-0}" -gt "$peak_peers" ] 2>/dev/null && peak_peers=${peers:-0}
        if [ "$got_first" = false ]; then
            first_bw=${bw:-0}
            got_first=true
        fi
        last_bw=${bw:-0}
    done < "$snap_file"
    [ "$count" -eq 0 ] && return

    local avg_peers=$((sum_peers / count))
    local period_bw=$((${last_bw:-0} - ${first_bw:-0}))
    [ "$period_bw" -lt 0 ] 2>/dev/null && period_bw=0
    local bw_fmt=$(awk "BEGIN {b=$period_bw; if(b>1099511627776) printf \"%.2f TB\",b/1099511627776; else if(b>1073741824) printf \"%.2f GB\",b/1073741824; else printf \"%.1f MB\",b/1048576}" 2>/dev/null)
    local uptime_pct=$(calc_uptime_pct "$period_secs")

    # New countries detection
    local countries_file="$INSTALL_DIR/traffic_stats/known_countries"
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    local new_countries=""
    if [ -s "$data_file" ]; then
        local current_countries=$(awk -F'|' '{if($1!="") print $1}' "$data_file" 2>/dev/null | sort -u)
        if [ -f "$countries_file" ]; then
            new_countries=$(comm -23 <(echo "$current_countries") <(sort "$countries_file") 2>/dev/null | head -5 | tr '\n' ', ' | sed 's/,$//')
        fi
        echo "$current_countries" > "$countries_file"
    fi

    local msg="📋 *${period_label} Summary*"
    msg+=$'\n'
    msg+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    msg+=$'\n'
    msg+=$'\n'
    msg+="📊 Bandwidth served: ${bw_fmt}"
    msg+=$'\n'
    msg+="👥 Peak peers: ${peak_peers} | Avg: ${avg_peers}"
    msg+=$'\n'
    msg+="⏱ Uptime: ${uptime_pct}%"
    msg+=$'\n'
    msg+="📈 Data points: ${count}"
    if [ -n "$new_countries" ]; then
        local safe_new=$(escape_md "$new_countries")
        msg+=$'\n'"🆕 New countries: ${safe_new}"
    fi

    telegram_send "$msg"
}

process_commands() {
    local offset_file="$INSTALL_DIR/traffic_stats/last_update_id"
    # Use in-memory offset as primary (survives file write failures)
    # Only read from file on first call (when _CMD_OFFSET is unset)
    if [ -z "${_CMD_OFFSET+x}" ]; then
        _CMD_OFFSET=0
        [ -f "$offset_file" ] && _CMD_OFFSET=$(cat "$offset_file" 2>/dev/null)
        _CMD_OFFSET=${_CMD_OFFSET:-0}
        [ "$_CMD_OFFSET" -eq "$_CMD_OFFSET" ] 2>/dev/null || _CMD_OFFSET=0
    fi
    local offset=$_CMD_OFFSET

    local response
    response=$(curl -s --max-time 15 --max-filesize 1048576 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$((offset + 1))&timeout=5" 2>/dev/null)
    [ -z "$response" ] && return

    # Parse with python3 if available, otherwise skip
    if ! command -v python3 &>/dev/null; then
        return
    fi

    local parsed
    parsed=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    if not data.get('ok'): sys.exit(0)
    results = data.get('result', [])
    if not results: sys.exit(0)
    for r in results:
        uid = r.get('update_id', 0)
        # Handle regular messages
        msg = r.get('message', {})
        if msg:
            chat_id = msg.get('chat', {}).get('id', 0)
            text = msg.get('text', '')
            if str(chat_id) == '$TELEGRAM_CHAT_ID' and text.startswith('/'):
                safe_text = text.split('|')[0].strip()
                print(f'{uid}|{safe_text}')
            else:
                print(f'{uid}|')
            continue
        # Handle callback queries (inline keyboard button presses)
        cbq = r.get('callback_query', {})
        if cbq:
            cb_chat_id = cbq.get('message', {}).get('chat', {}).get('id', 0)
            cb_id = cbq.get('id', '').replace('|', '')
            cb_data = cbq.get('data', '').split('|')[0].strip()
            if str(cb_chat_id) == '$TELEGRAM_CHAT_ID' and cb_data:
                print(f'{uid}|callback|{cb_id}|{cb_data}')
            else:
                print(f'{uid}|')
            continue
        print(f'{uid}|')
except Exception:
    try:
        data = json.loads(sys.argv[1])
        results = data.get('result', [])
        if results:
            max_uid = max(r.get('update_id', 0) for r in results)
            if max_uid > 0:
                print(f'{max_uid}|')
    except Exception:
        pass
" "$response" 2>/dev/null)

    [ -z "$parsed" ] && return

    local max_id=$offset
    while IFS='|' read -r uid field2 field3 field4; do
        [ -z "$uid" ] && continue
        [ "$uid" -gt "$max_id" ] 2>/dev/null && max_id=$uid

        # Handle callback queries (inline keyboard button presses)
        if [ "$field2" = "callback" ]; then
            local cb_id="$field3"
            local cb_data="$field4"
            case "$cb_data" in
                qr_*)
                    local qr_num="${cb_data#qr_}"
                    telegram_answer_callback "$cb_id" "Generating QR for container ${qr_num}..."
                    if [[ "$qr_num" =~ ^[0-9]+$ ]] && [ "$qr_num" -ge 1 ] && [ "$qr_num" -le "${CONTAINER_COUNT:-1}" ]; then
                        local vol=$(get_volume_name "$qr_num")
                        local raw_key=$(get_raw_key "$vol")
                        local node_id=$(get_node_id "$vol")
                        if [ -n "$raw_key" ] && command -v qrencode &>/dev/null; then
                            local hostname_str=$(hostname 2>/dev/null || echo "conduit")
                            local claim_json="{\"version\":1,\"data\":{\"key\":\"${raw_key}\",\"name\":\"${hostname_str}\"}}"
                            local claim_b64=$(echo -n "$claim_json" | base64 | tr -d '\n')
                            local claim_url="network.ryve.app://(app)/conduits?claim=${claim_b64}"
                            qrencode -t PNG -o "/tmp/conduit_qr_${qr_num}.png" "$claim_url" 2>/dev/null
                            if [ -f "/tmp/conduit_qr_${qr_num}.png" ]; then
                                telegram_send_photo "/tmp/conduit_qr_${qr_num}.png" "Container ${qr_num} — Conduit ID: ${node_id:-unknown}"
                                rm -f "/tmp/conduit_qr_${qr_num}.png"
                            else
                                telegram_send "❌ Failed to generate QR code for container ${qr_num}"
                            fi
                        elif ! command -v qrencode &>/dev/null; then
                            telegram_send "❌ qrencode not installed. Install with: apt install qrencode"
                        else
                            telegram_send "❌ Key not available for container ${qr_num}. Start it first."
                        fi
                    else
                        telegram_answer_callback "$cb_id" "Invalid container"
                    fi
                    ;;
                *)
                    telegram_answer_callback "$cb_id" ""
                    ;;
            esac
            continue
        fi

        # Handle regular commands
        local cmd="$field2"
        case "$cmd" in
            /status|/status@*)
                local report=$(build_report)
                telegram_send "$report"
                ;;
            /peers|/peers@*)
                local total_peers=0
                local total_cing=0
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    local last_stat=$(timeout 5 docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
                    local peers=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connected:") print $(j+1)+0}}' | head -1)
                    local cing=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connecting:") print $(j+1)+0}}' | head -1)
                    total_peers=$((total_peers + ${peers:-0}))
                    total_cing=$((total_cing + ${cing:-0}))
                done
                telegram_send "👥 Clients: ${total_peers} connected, ${total_cing} connecting"
                ;;
            /uptime|/uptime@*)
                local ut_msg="⏱ *Uptime Report*"
                ut_msg+=$'\n'
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    local is_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^${cname}$" || true)
                    if [ "${is_running:-0}" -gt 0 ]; then
                        local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null)
                        if [ -n "$started" ]; then
                            local se=$(date -d "$started" +%s 2>/dev/null || echo 0)
                            local diff=$(( $(date +%s) - se ))
                            local d=$((diff / 86400)) h=$(( (diff % 86400) / 3600 )) m=$(( (diff % 3600) / 60 ))
                            ut_msg+="📦 Container ${i}: ${d}d ${h}h ${m}m"
                        else
                            ut_msg+="📦 Container ${i}: ⚠ unknown"
                        fi
                    else
                        ut_msg+="📦 Container ${i}: 🔴 stopped"
                    fi
                    ut_msg+=$'\n'
                done
                local avail=$(calc_uptime_pct 86400)
                ut_msg+=$'\n'
                ut_msg+="📈 Availability: ${avail}% (24h)"
                telegram_send "$ut_msg"
                ;;
            /containers|/containers@*)
                local ct_msg="📦 *Container Status*"
                ct_msg+=$'\n'
                local docker_names=$(docker ps --format '{{.Names}}' 2>/dev/null)
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    ct_msg+=$'\n'
                    if echo "$docker_names" | grep -q "^${cname}$"; then
                        ct_msg+="C${i} (${cname}): 🟢 Running"
                        ct_msg+=$'\n'
                        local logs=$(timeout 5 docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
                        if [ -n "$logs" ]; then
                            local c_cing c_conn c_up c_down
                            IFS='|' read -r c_cing c_conn c_up c_down <<< $(echo "$logs" | awk '{
                                cing=0; conn=0; up=""; down=""
                                for(j=1;j<=NF;j++){
                                    if($j=="Connecting:") cing=$(j+1)+0
                                    else if($j=="Connected:") conn=$(j+1)+0
                                    else if($j=="Up:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Down:/)break; up=up (up?" ":"") $k}}
                                    else if($j=="Down:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Uptime:/)break; down=down (down?" ":"") $k}}
                                }
                                printf "%d|%d|%s|%s", cing, conn, up, down
                            }')
                            ct_msg+="  👥 Connected: ${c_conn:-0} | Connecting: ${c_cing:-0}"
                            ct_msg+=$'\n'
                            ct_msg+="  ⬆ Up: ${c_up:-N/A}  ⬇ Down: ${c_down:-N/A}"
                        else
                            ct_msg+="  ⚠ No stats available yet"
                        fi
                    else
                        ct_msg+="C${i} (${cname}): 🔴 Stopped"
                    fi
                    ct_msg+=$'\n'
                done
                ct_msg+=$'\n'
                ct_msg+="/restart\_N  /stop\_N  /start\_N — manage containers"
                telegram_send "$ct_msg"
                ;;
            /restart_all|/restart_all@*)
                local ra_ok=0 ra_fail=0
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name "$i")
                    if docker restart "$cname" >/dev/null 2>&1; then
                        ra_ok=$((ra_ok + 1))
                    else
                        ra_fail=$((ra_fail + 1))
                    fi
                done
                # Restart snowflake containers if enabled
                if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
                    local si
                    for si in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
                        local sf_cname="snowflake-proxy"
                        [ "$si" -gt 1 ] && sf_cname="snowflake-proxy-${si}"
                        docker restart "$sf_cname" >/dev/null 2>&1 && ra_ok=$((ra_ok + 1)) || ra_fail=$((ra_fail + 1))
                    done
                fi
                if [ "$ra_fail" -eq 0 ]; then
                    telegram_send "✅ All ${ra_ok} containers restarted successfully"
                else
                    telegram_send "⚠️ Restarted ${ra_ok} containers (${ra_fail} failed)"
                fi
                ;;
            /start_all|/start_all@*)
                local sa_ok=0 sa_fail=0
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name "$i")
                    if docker start "$cname" >/dev/null 2>&1; then
                        sa_ok=$((sa_ok + 1))
                    else
                        sa_fail=$((sa_fail + 1))
                    fi
                done
                # Start snowflake containers if enabled
                if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
                    local si
                    for si in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
                        local sf_cname="snowflake-proxy"
                        [ "$si" -gt 1 ] && sf_cname="snowflake-proxy-${si}"
                        docker start "$sf_cname" >/dev/null 2>&1 && sa_ok=$((sa_ok + 1)) || sa_fail=$((sa_fail + 1))
                    done
                fi
                if [ "$sa_fail" -eq 0 ]; then
                    telegram_send "🟢 All ${sa_ok} containers started successfully"
                else
                    telegram_send "⚠️ Started ${sa_ok} containers (${sa_fail} failed)"
                fi
                ;;
            /stop_all|/stop_all@*)
                local sto_ok=0 sto_fail=0
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name "$i")
                    if docker stop "$cname" >/dev/null 2>&1; then
                        sto_ok=$((sto_ok + 1))
                    else
                        sto_fail=$((sto_fail + 1))
                    fi
                done
                # Stop snowflake containers if enabled
                if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
                    local si
                    for si in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
                        local sf_cname="snowflake-proxy"
                        [ "$si" -gt 1 ] && sf_cname="snowflake-proxy-${si}"
                        docker stop "$sf_cname" >/dev/null 2>&1 && sto_ok=$((sto_ok + 1)) || sto_fail=$((sto_fail + 1))
                    done
                fi
                if [ "$sto_fail" -eq 0 ]; then
                    telegram_send "🛑 All ${sto_ok} containers stopped"
                else
                    telegram_send "⚠️ Stopped ${sto_ok} containers (${sto_fail} failed)"
                fi
                ;;
            /restart_*|/stop_*|/start_*)
                local action="${cmd%%_*}"     # /restart, /stop, or /start
                action="${action#/}"          # restart, stop, or start
                local num="${cmd#*_}"
                num="${num%%@*}"              # strip @botname suffix
                if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${CONTAINER_COUNT:-1}" ]; then
                    telegram_send "❌ Invalid container number: ${num}. Use 1-${CONTAINER_COUNT:-1}."
                else
                    local cname=$(get_container_name "$num")
                    if docker "$action" "$cname" >/dev/null 2>&1; then
                        local emoji="✅"
                        [ "$action" = "stop" ] && emoji="🛑"
                        [ "$action" = "start" ] && emoji="🟢"
                        telegram_send "${emoji} Container ${num} (${cname}): ${action} successful"
                    else
                        telegram_send "❌ Failed to ${action} container ${num} (${cname})"
                    fi
                fi
                ;;
            /settings|/settings@*)
                local bw_display="${BANDWIDTH:-5}"
                if [ "$bw_display" = "-1" ]; then
                    bw_display="Unlimited"
                else
                    bw_display="${bw_display} Mbps"
                fi
                local dc_display="${DATA_CAP_GB:-0}"
                if [ "$dc_display" = "0" ]; then
                    dc_display="Unlimited"
                else
                    dc_display="${dc_display} GB"
                fi
                local st_msg="⚙️ *Current Settings*"
                st_msg+=$'\n'
                st_msg+="👥 Max Clients: ${MAX_CLIENTS:-200}"
                st_msg+=$'\n'
                st_msg+="📶 Bandwidth: ${bw_display}"
                st_msg+=$'\n'
                st_msg+="📦 Containers: ${CONTAINER_COUNT:-1}"
                st_msg+=$'\n'
                st_msg+="💾 Data Cap: ${dc_display}"
                st_msg+=$'\n'
                st_msg+="📊 Tracker: ${TRACKER_ENABLED:-true}"
                st_msg+=$'\n'
                st_msg+="🔔 Report Interval: every ${TELEGRAM_INTERVAL:-6}h"
                st_msg+=$'\n'
                st_msg+="🔕 Alerts: ${TELEGRAM_ALERTS_ENABLED:-true}"
                telegram_send "$st_msg"
                ;;
            /health|/health@*)
                local h_msg="🏥 *Health Check*"
                h_msg+=$'\n'
                if docker info >/dev/null 2>&1; then
                    h_msg+="🐳 Docker: ✅ Running"
                else
                    h_msg+="🐳 Docker: ❌ Not running"
                fi
                h_msg+=$'\n'
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name "$i")
                    local is_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^${cname}$" || true)
                    local restarts=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null || echo "N/A")
                    if [ "${is_running:-0}" -gt 0 ]; then
                        h_msg+="📦 ${cname}: 🟢 Running (restarts: ${restarts})"
                    else
                        h_msg+="📦 ${cname}: 🔴 Stopped (restarts: ${restarts})"
                    fi
                    h_msg+=$'\n'
                done
                local net_ok=false
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name "$i")
                    if timeout 5 docker logs --tail 100 "$cname" 2>&1 | grep -q "\[STATS\]\|Connected to Psiphon"; then
                        net_ok=true
                        break
                    fi
                done
                if [ "$net_ok" = true ]; then
                    h_msg+="🌐 Network: ✅ Connected"
                else
                    h_msg+="🌐 Network: ⚠️ No connection detected"
                fi
                h_msg+=$'\n'
                if command -v systemctl &>/dev/null && systemctl is-active conduit-tracker.service &>/dev/null; then
                    h_msg+="📊 Tracker: ✅ Active"
                else
                    h_msg+="📊 Tracker: ❌ Inactive"
                fi
                h_msg+=$'\n'
                if command -v geoiplookup &>/dev/null; then
                    h_msg+="🌍 GeoIP: ✅ geoiplookup"
                elif command -v mmdblookup &>/dev/null; then
                    h_msg+="🌍 GeoIP: ✅ mmdblookup"
                else
                    h_msg+="🌍 GeoIP: ⚠️ Not installed"
                fi
                telegram_send "$h_msg"
                ;;
            /logs_*)
                local log_num="${cmd#/logs_}"
                log_num="${log_num%%@*}"
                if ! [[ "$log_num" =~ ^[0-9]+$ ]] || [ "$log_num" -lt 1 ] || [ "$log_num" -gt "${CONTAINER_COUNT:-1}" ]; then
                    telegram_send "❌ Invalid container number: ${log_num}. Use 1-${CONTAINER_COUNT:-1}."
                else
                    local cname=$(get_container_name "$log_num")
                    local log_output
                    log_output=$(timeout 10 docker logs --tail 15 "$cname" 2>&1 || echo "Failed to get logs")
                    # Truncate to fit Telegram 4096 char limit
                    if [ ${#log_output} -gt 3800 ]; then
                        log_output="${log_output:0:3800}..."
                    fi
                    # Send without escape_md — code blocks render content literally
                    local escaped_cname=$(escape_md "$cname")
                    telegram_send "📋 *Logs: ${escaped_cname}* (last 15 lines):
\`\`\`
${log_output}
\`\`\`"
                fi
                ;;
            /update|/update@*)
                telegram_send "🔄 Checking for updates..."
                local conduit_img="ghcr.io/ssmirr/conduit/conduit:latest"
                local pull_out
                pull_out=$(docker pull "$conduit_img" 2>&1)
                if [ $? -ne 0 ]; then
                    telegram_send "❌ Failed to pull image. Check internet connection."
                elif echo "$pull_out" | grep -q "Status: Image is up to date"; then
                    telegram_send "✅ Docker image is already up to date."
                elif echo "$pull_out" | grep -q "Downloaded newer image\|Pull complete"; then
                    telegram_send "📦 New image found. Recreating containers..."
                    local upd_ok=0 upd_fail=0
                    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                        local cname=$(get_container_name "$i")
                        local vname
                        if [ "$i" -eq 1 ]; then vname="conduit-data"; else vname="conduit-data-${i}"; fi
                        local mc=${MAX_CLIENTS:-200}
                        local bw=${BANDWIDTH:-5}
                        # Per-container overrides
                        local mc_var="MAX_CLIENTS_${i}"
                        [ -n "${!mc_var:-}" ] && mc="${!mc_var}"
                        local bw_var="BANDWIDTH_${i}"
                        [ -n "${!bw_var:-}" ] && bw="${!bw_var}"
                        local resource_args=""
                        local cpus_var="CPUS_${i}"
                        [ -n "${!cpus_var:-}" ] && resource_args+="--cpus ${!cpus_var} "
                        [ -z "${!cpus_var:-}" ] && [ -n "${DOCKER_CPUS:-}" ] && resource_args+="--cpus ${DOCKER_CPUS} "
                        local mem_var="MEMORY_${i}"
                        [ -n "${!mem_var:-}" ] && resource_args+="--memory ${!mem_var} "
                        [ -z "${!mem_var:-}" ] && [ -n "${DOCKER_MEMORY:-}" ] && resource_args+="--memory ${DOCKER_MEMORY} "
                        docker rm -f "$cname" >/dev/null 2>&1
                        if docker run -d \
                            --name "$cname" \
                            --restart unless-stopped \
                            --log-opt max-size=15m \
                            --log-opt max-file=3 \
                            -v "${vname}:/home/conduit/data" \
                            --network host \
                            $resource_args \
                            "$conduit_img" \
                            start --max-clients "$mc" --bandwidth "$bw" --stats-file >/dev/null 2>&1; then
                            upd_ok=$((upd_ok + 1))
                        else
                            upd_fail=$((upd_fail + 1))
                        fi
                    done
                    # Clean up old dangling images
                    docker image prune -f >/dev/null 2>&1
                    if [ "$upd_fail" -eq 0 ]; then
                        telegram_send "✅ Update complete. ${upd_ok} container(s) recreated with new image."
                    else
                        telegram_send "⚠️ Update: ${upd_ok} OK, ${upd_fail} failed."
                    fi
                else
                    telegram_send "✅ Image check complete. No changes detected."
                fi
                ;;
            /qr|/qr@*)
                if [ "${CONTAINER_COUNT:-1}" -le 1 ]; then
                    # Single container: generate and send QR directly
                    local vol=$(get_volume_name 1)
                    local raw_key=$(get_raw_key "$vol")
                    local node_id=$(get_node_id "$vol")
                    if [ -n "$raw_key" ] && command -v qrencode &>/dev/null; then
                        local hostname_str=$(hostname 2>/dev/null || echo "conduit")
                        local claim_json="{\"version\":1,\"data\":{\"key\":\"${raw_key}\",\"name\":\"${hostname_str}\"}}"
                        local claim_b64=$(echo -n "$claim_json" | base64 | tr -d '\n')
                        local claim_url="network.ryve.app://(app)/conduits?claim=${claim_b64}"
                        qrencode -t PNG -o /tmp/conduit_qr_1.png "$claim_url" 2>/dev/null
                        if [ -f /tmp/conduit_qr_1.png ]; then
                            telegram_send_photo "/tmp/conduit_qr_1.png" "Conduit ID: ${node_id:-unknown}"
                            rm -f /tmp/conduit_qr_1.png
                        else
                            telegram_send "❌ Failed to generate QR code"
                        fi
                    elif ! command -v qrencode &>/dev/null; then
                        telegram_send "❌ qrencode not installed. Install with: apt install qrencode"
                    else
                        telegram_send "❌ Key not available. Start container first."
                    fi
                else
                    # Multiple containers: send inline keyboard for selection
                    local buttons=""
                    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                        [ -n "$buttons" ] && buttons+=","
                        buttons+="{\"text\":\"Container ${i}\",\"callback_data\":\"qr_${i}\"}"
                    done
                    local kb="{\"inline_keyboard\":[[${buttons}]]}"
                    telegram_send_inline_keyboard "📱 Select a container for QR code:" "$kb"
                fi
                ;;
            /help|/help@*)
                telegram_send "📖 *Available Commands*
/status — Full status report
/peers — Current peer count
/uptime — Per-container uptime
/containers — Per-container status
/settings — Current configuration
/health — Run health checks
/logs\\_N — Last 15 log lines for container N
/update — Update Docker image
/qr — QR code for rewards
/restart\\_N — Restart container N
/stop\\_N — Stop container N
/start\\_N — Start container N
/restart\\_all — Restart all containers
/start\\_all — Start all containers
/stop\\_all — Stop all containers
/help — Show this help"
                ;;
        esac
    done <<< "$parsed"

    # Update in-memory offset first
    if [ "$max_id" -gt "$offset" ] 2>/dev/null; then
        _CMD_OFFSET=$max_id
        echo "$max_id" > "$offset_file" 2>/dev/null
    fi
}

build_report() {
    local report="📊 *Conduit Status Report*"
    report+=$'\n'
    report+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    report+=$'\n'
    report+=$'\n'

    # Container status + uptime
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    local total=${CONTAINER_COUNT:-1}
    report+="📦 Containers: ${running}/${total} running"
    report+=$'\n'

    local uptime_log="$INSTALL_DIR/traffic_stats/uptime_log"
    if [ -s "$uptime_log" ]; then
        local avail_24h=$(calc_uptime_pct 86400)
        report+="📈 Availability: ${avail_24h}% (24h)"
        report+=$'\n'
        # Streak: consecutive minutes at end of log with running > 0
        local streak_mins=$(awk -F'|' '{a[NR]=$2+0} END{n=0; for(i=NR;i>=1;i--){if(a[i]<=0) break; n++} print n}' "$uptime_log" 2>/dev/null)
        if [ "${streak_mins:-0}" -gt 0 ] 2>/dev/null; then
            local sd=$((streak_mins / 1440)) sh=$(( (streak_mins % 1440) / 60 )) sm=$((streak_mins % 60))
            local streak_str=""
            [ "$sd" -gt 0 ] && streak_str+="${sd}d "
            streak_str+="${sh}h ${sm}m"
            report+="🔥 Streak: ${streak_str}"
            report+=$'\n'
        fi
    fi

    # Uptime from earliest container
    local earliest_start=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null)
        [ -z "$started" ] && continue
        local se=$(date -d "$started" +%s 2>/dev/null || echo 0)
        if [ -z "$earliest_start" ] || [ "$se" -lt "$earliest_start" ] 2>/dev/null; then
            earliest_start=$se
        fi
    done
    if [ -n "$earliest_start" ] && [ "$earliest_start" -gt 0 ] 2>/dev/null; then
        local now=$(date +%s)
        local diff=$((now - earliest_start))
        local days=$((diff / 86400))
        local hours=$(( (diff % 86400) / 3600 ))
        local mins=$(( (diff % 3600) / 60 ))
        report+="⏱ Uptime: ${days}d ${hours}h ${mins}m"
        report+=$'\n'
    fi

    # Peers (connected + connecting, matching TUI format)
    local total_peers=0
    local total_connecting=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$(docker logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        local peers=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connected:") print $(j+1)+0}}' | head -1)
        local cing=$(echo "$last_stat" | awk '{for(j=1;j<=NF;j++){if($j=="Connecting:") print $(j+1)+0}}' | head -1)
        total_peers=$((total_peers + ${peers:-0}))
        total_connecting=$((total_connecting + ${cing:-0}))
    done
    report+="👥 Clients: ${total_peers} connected, ${total_connecting} connecting"
    report+=$'\n'

    # Active unique clients
    local snapshot_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snapshot_file" ]; then
        local active_clients=$(wc -l < "$snapshot_file" 2>/dev/null || echo 0)
        report+="👤 Total lifetime IPs served: ${active_clients}"
        report+=$'\n'
    fi

    # Total bandwidth served (all-time from cumulative_data)
    local data_file_bw="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file_bw" ]; then
        local total_bytes=$(awk -F'|' '{s+=$2+$3} END{print s+0}' "$data_file_bw" 2>/dev/null)
        local total_served=""
        if [ "${total_bytes:-0}" -gt 0 ] 2>/dev/null; then
            total_served=$(awk "BEGIN {b=$total_bytes; if(b>1099511627776) printf \"%.2f TB\",b/1099511627776; else if(b>1073741824) printf \"%.2f GB\",b/1073741824; else printf \"%.1f MB\",b/1048576}" 2>/dev/null)
            report+="📡 Total served: ${total_served}"
            report+=$'\n'
        fi
    fi

    # App CPU / RAM (aggregate all containers)
    local stats=$(get_container_stats)
    local raw_cpu=$(echo "$stats" | awk '{print $1}')
    local cores=$(get_cpu_cores)
    local app_cpu=$(awk "BEGIN {printf \"%.1f%%\", ${raw_cpu%\%} / $cores}" 2>/dev/null || echo "$raw_cpu")
    local app_ram=$(echo "$stats" | awk '{print $2, $3, $4}')
    app_cpu=$(escape_md "$app_cpu")
    app_ram=$(escape_md "$app_ram")
    report+="🖥 App CPU: ${app_cpu} | RAM: ${app_ram}"
    report+=$'\n'

    # System CPU + Temp
    local sys_cpu="N/A"
    if [ -f /proc/stat ]; then
        read -r _c user nice system idle iowait irq softirq steal guest < /proc/stat
        local total_curr=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local work_curr=$((user + nice + system + irq + softirq + steal))
        local cpu_tmp="/tmp/conduit_cpu_state"
        if [ -f "$cpu_tmp" ]; then
            read -r total_prev work_prev < "$cpu_tmp"
            local total_delta=$((total_curr - total_prev))
            local work_delta=$((work_curr - work_prev))
            [ "$total_delta" -gt 0 ] && sys_cpu=$(awk -v w="$work_delta" -v t="$total_delta" 'BEGIN{printf "%.1f%%", w*100/t}')
        fi
        echo "$total_curr $work_curr" > "$cpu_tmp"
    fi
    local cpu_temp=""
    local temp_sum=0 temp_count=0
    for hwmon_dir in /sys/class/hwmon/hwmon*; do
        [ -d "$hwmon_dir" ] || continue
        local hwmon_name=$(cat "$hwmon_dir/name" 2>/dev/null)
        case "$hwmon_name" in
            coretemp|k10temp|cpu_thermal|soc_thermal|cpu-thermal|thermal-fan-est)
                for tf in "$hwmon_dir"/temp*_input; do
                    [ -f "$tf" ] || continue
                    local tr=$(cat "$tf" 2>/dev/null)
                    [ -n "$tr" ] && [ "$tr" -gt 0 ] 2>/dev/null && temp_sum=$((temp_sum + tr)) && temp_count=$((temp_count + 1))
                done ;;
        esac
    done
    if [ "$temp_count" -gt 0 ]; then
        cpu_temp="$((temp_sum / temp_count / 1000))°C"
    elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        local tr=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        [ -n "$tr" ] && [ "$tr" -gt 0 ] 2>/dev/null && cpu_temp="$((tr / 1000))°C"
    fi
    local sys_line="🔧 System CPU: ${sys_cpu}"
    [ -n "$cpu_temp" ] && sys_line+=" (${cpu_temp})"
    # System RAM
    if command -v free &>/dev/null; then
        local sys_ram=$(free -m 2>/dev/null | awk '/^Mem:/{
            u=$3; t=$2
            if(t>=1024) ts=sprintf("%.1fGiB",t/1024); else ts=sprintf("%dMiB",t)
            if(u>=1024) us=sprintf("%.1fGiB",u/1024); else us=sprintf("%dMiB",u)
            printf "%s / %s", us, ts
        }')
        sys_line+=" | RAM: ${sys_ram}"
    fi
    sys_line=$(escape_md "$sys_line")
    report+="${sys_line}"
    report+=$'\n'

    # Data usage
    if [ "${DATA_CAP_GB:-0}" -gt 0 ] || [ "${DATA_CAP_UP_GB:-0}" -gt 0 ] || [ "${DATA_CAP_DOWN_GB:-0}" -gt 0 ]; then
        local iface="${DATA_CAP_IFACE:-eth0}"
        local rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        local tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        local d_rx=$(( rx - ${DATA_CAP_BASELINE_RX:-0} )); [ "$d_rx" -lt 0 ] && d_rx=0
        local d_tx=$(( tx - ${DATA_CAP_BASELINE_TX:-0} )); [ "$d_tx" -lt 0 ] && d_tx=0
        local t_rx=$(( d_rx + ${DATA_CAP_PRIOR_RX:-0} ))
        local t_tx=$(( d_tx + ${DATA_CAP_PRIOR_TX:-0} ))
        local t_all=$(( t_rx + t_tx ))
        local cap_parts=""
        if [ "${DATA_CAP_UP_GB:-0}" -gt 0 ] 2>/dev/null; then
            local up_gb=$(awk "BEGIN {printf \"%.2f\", $t_tx/1073741824}" 2>/dev/null || echo "0")
            cap_parts+="up ${up_gb}/${DATA_CAP_UP_GB}GB"
        fi
        if [ "${DATA_CAP_DOWN_GB:-0}" -gt 0 ] 2>/dev/null; then
            [ -n "$cap_parts" ] && cap_parts+=" "
            local dn_gb=$(awk "BEGIN {printf \"%.2f\", $t_rx/1073741824}" 2>/dev/null || echo "0")
            cap_parts+="dn ${dn_gb}/${DATA_CAP_DOWN_GB}GB"
        fi
        if [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null; then
            [ -n "$cap_parts" ] && cap_parts+=" "
            local tot_gb=$(awk "BEGIN {printf \"%.2f\", $t_all/1073741824}" 2>/dev/null || echo "0")
            cap_parts+="total ${tot_gb}/${DATA_CAP_GB}GB"
        fi
        report+="📈 Data: ${cap_parts}"
        report+=$'\n'
    fi

    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
        local sf_running=false
        local _sf_chk
        for _sf_chk in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
            local _sf_n="snowflake-proxy"
            [ "$_sf_chk" -gt 1 ] && _sf_n="snowflake-proxy-${_sf_chk}"
            docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${_sf_n}$" && sf_running=true && break
        done
        if [ "$sf_running" = true ]; then
            local sf_total_conn=0 sf_total_in=0 sf_total_out=0 sf_total_to=0
            local si
            for si in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
                local sf_mport=$((10000 - si))
                local sf_metrics=$(curl -s --max-time 3 "http://127.0.0.1:${sf_mport}/internal/metrics" 2>/dev/null)
                if [ -n "$sf_metrics" ]; then
                    local sf_parsed
                    sf_parsed=$(echo "$sf_metrics" | awk '
                        /^tor_snowflake_proxy_connections_total[{ ]/ { conns += $NF }
                        /^tor_snowflake_proxy_connection_timeouts_total / { to += $NF }
                        /^tor_snowflake_proxy_traffic_inbound_bytes_total / { ib += $NF }
                        /^tor_snowflake_proxy_traffic_outbound_bytes_total / { ob += $NF }
                        END { printf "%d %d %d %d", conns, ib, ob, to }
                    ' 2>/dev/null)
                    local _pc _pi _po _pt
                    read -r _pc _pi _po _pt <<< "$sf_parsed"
                    sf_total_conn=$((sf_total_conn + ${_pc:-0}))
                    sf_total_in=$((sf_total_in + ${_pi:-0}))
                    sf_total_out=$((sf_total_out + ${_po:-0}))
                    sf_total_to=$((sf_total_to + ${_pt:-0}))
                fi
            done
            # Snowflake Prometheus reports KB despite metric name
            sf_total_in=$((sf_total_in * 1000))
            sf_total_out=$((sf_total_out * 1000))
            local sf_in_f="0 B" sf_out_f="0 B"
            if [ "${sf_total_in:-0}" -ge 1073741824 ] 2>/dev/null; then
                sf_in_f=$(awk "BEGIN{printf \"%.2f GB\",${sf_total_in}/1073741824}")
            elif [ "${sf_total_in:-0}" -ge 1048576 ] 2>/dev/null; then
                sf_in_f=$(awk "BEGIN{printf \"%.2f MB\",${sf_total_in}/1048576}")
            elif [ "${sf_total_in:-0}" -ge 1024 ] 2>/dev/null; then
                sf_in_f=$(awk "BEGIN{printf \"%.2f KB\",${sf_total_in}/1024}")
            elif [ "${sf_total_in:-0}" -gt 0 ] 2>/dev/null; then
                sf_in_f="${sf_total_in} B"
            fi
            if [ "${sf_total_out:-0}" -ge 1073741824 ] 2>/dev/null; then
                sf_out_f=$(awk "BEGIN{printf \"%.2f GB\",${sf_total_out}/1073741824}")
            elif [ "${sf_total_out:-0}" -ge 1048576 ] 2>/dev/null; then
                sf_out_f=$(awk "BEGIN{printf \"%.2f MB\",${sf_total_out}/1048576}")
            elif [ "${sf_total_out:-0}" -ge 1024 ] 2>/dev/null; then
                sf_out_f=$(awk "BEGIN{printf \"%.2f KB\",${sf_total_out}/1024}")
            elif [ "${sf_total_out:-0}" -gt 0 ] 2>/dev/null; then
                sf_out_f="${sf_total_out} B"
            fi
            local sf_to_label=""
            [ "${sf_total_to:-0}" -gt 0 ] 2>/dev/null && sf_to_label=" (${sf_total_to} to)"
            report+="❄ Snowflake: ${sf_total_conn} conn${sf_to_label} | ↓${sf_in_f} ↑${sf_out_f}"
            report+=$'\n'
        fi
    fi

    local total_restarts=0
    local restart_details=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local rc=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null || echo 0)
        rc=${rc:-0}
        total_restarts=$((total_restarts + rc))
        [ "$rc" -gt 0 ] && restart_details+=" C${i}:${rc}"
    done
    if [ "$total_restarts" -gt 0 ]; then
        report+="🔄 Restarts: ${total_restarts}${restart_details}"
        report+=$'\n'
    fi

    local snap_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snap_file" ]; then
        local top_peers
        top_peers=$(awk -F'|' '{if($2!="") cnt[$2]++} END{for(c in cnt) print cnt[c]"|"c}' "$snap_file" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_peers" ]; then
            report+="🗺 Top by peers:"
            report+=$'\n'
            while IFS='|' read -r cnt country; do
                [ -z "$country" ] && continue
                local safe_c=$(escape_md "$country")
                report+="  • ${safe_c}: ${cnt} clients"
                report+=$'\n'
            done <<< "$top_peers"
        fi
    fi

    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file" ]; then
        local top_countries
        top_countries=$(awk -F'|' '{if($1!="" && $3+0>0) bytes[$1]+=$3+0} END{for(c in bytes) print bytes[c]"|"c}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_countries" ]; then
            report+="🌍 Top by upload:"
            report+=$'\n'
            local total_upload=$(awk -F'|' '{s+=$3+0} END{print s+0}' "$data_file" 2>/dev/null)
            while IFS='|' read -r bytes country; do
                [ -z "$country" ] && continue
                local pct=0
                [ "$total_upload" -gt 0 ] 2>/dev/null && pct=$(awk "BEGIN {printf \"%.0f\", ($bytes/$total_upload)*100}" 2>/dev/null || echo 0)
                local safe_country=$(escape_md "$country")
                local fmt=$(awk "BEGIN {b=$bytes; if(b>1073741824) printf \"%.1f GB\",b/1073741824; else if(b>1048576) printf \"%.1f MB\",b/1048576; else printf \"%.1f KB\",b/1024}" 2>/dev/null)
                report+="  • ${safe_country}: ${pct}% (${fmt})"
                report+=$'\n'
            done <<< "$top_countries"
        fi
    fi

    echo "$report"
}

# State variables
cpu_breach=0
ram_breach=0
zero_peers_since=0
last_alert_cpu=0
last_alert_ram=0
last_alert_down=0
last_alert_peers=0
last_rotation_ts=0

# Ensure data directory exists
mkdir -p "$INSTALL_DIR/traffic_stats"

# Persist daily/weekly timestamps across restarts
_ts_dir="$INSTALL_DIR/traffic_stats"
last_daily_ts=$(cat "$_ts_dir/.last_daily_ts" 2>/dev/null || echo 0)
[ "$last_daily_ts" -eq "$last_daily_ts" ] 2>/dev/null || last_daily_ts=0
last_weekly_ts=$(cat "$_ts_dir/.last_weekly_ts" 2>/dev/null || echo 0)
[ "$last_weekly_ts" -eq "$last_weekly_ts" ] 2>/dev/null || last_weekly_ts=0
last_report_ts=$(cat "$_ts_dir/.last_report_ts" 2>/dev/null || echo 0)
[ "$last_report_ts" -eq "$last_report_ts" ] 2>/dev/null || last_report_ts=0

last_periodic=$(date +%s)

while true; do
    # Re-read settings
    [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

    # Exit if disabled
    [ "$TELEGRAM_ENABLED" != "true" ] && exit 0
    [ -z "$TELEGRAM_BOT_TOKEN" ] && exit 0

    # Long-poll for commands (returns on new message or after 5s timeout)
    process_commands

    sleep 1

    now_ts=$(date +%s)
    if [ $((now_ts - last_periodic)) -ge 60 ] 2>/dev/null; then
        track_uptime
        check_alerts

        # Daily rotation
        if [ $((now_ts - last_rotation_ts)) -ge 86400 ] 2>/dev/null; then
            rotate_cumulative_data
            last_rotation_ts=$now_ts
        fi

        # Daily summary (wall-clock, survives restarts)
        if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ] && [ $((now_ts - last_daily_ts)) -ge 86400 ] 2>/dev/null; then
            build_summary "Daily" 86400
            last_daily_ts=$now_ts
            echo "$now_ts" > "$_ts_dir/.last_daily_ts"
        fi

        # Weekly summary (wall-clock, survives restarts)
        if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ] && [ $((now_ts - last_weekly_ts)) -ge 604800 ] 2>/dev/null; then
            build_summary "Weekly" 604800
            last_weekly_ts=$now_ts
            echo "$now_ts" > "$_ts_dir/.last_weekly_ts"
        fi

        # Regular periodic report (wall-clock aligned to start hour)
        # Reports fire when current hour matches start_hour + N*interval
        interval_hours=${TELEGRAM_INTERVAL:-6}
        start_hour=${TELEGRAM_START_HOUR:-0}
        interval_secs=$((interval_hours * 3600))
        current_hour=$(date +%-H)
        hour_diff=$(( (current_hour - start_hour + 24) % 24 ))
        if [ "$interval_hours" -gt 0 ] && [ $((hour_diff % interval_hours)) -eq 0 ] 2>/dev/null; then
            if [ $((now_ts - last_report_ts)) -ge $((interval_secs - 120)) ] 2>/dev/null; then
                report=$(build_report)
                telegram_send "$report"
                record_snapshot
                last_report_ts=$now_ts
                echo "$now_ts" > "$_ts_dir/.last_report_ts"
            fi
        fi

        last_periodic=$now_ts
    fi
done
TGEOF
    chmod 700 "$INSTALL_DIR/conduit-telegram.sh"
}

setup_telegram_service() {
    telegram_generate_notify_script
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/conduit-telegram.service << EOF
[Unit]
Description=Conduit Telegram Notifications
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/bin/bash $INSTALL_DIR/conduit-telegram.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable conduit-telegram.service 2>/dev/null || true
        systemctl restart conduit-telegram.service 2>/dev/null || true
    fi
}

telegram_stop_notify() {
    if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/conduit-telegram.service ]; then
        systemctl stop conduit-telegram.service 2>/dev/null || true
    fi
    # Also clean up legacy PID-based loop if present
    if [ -f "$INSTALL_DIR/telegram_notify.pid" ]; then
        local pid=$(cat "$INSTALL_DIR/telegram_notify.pid" 2>/dev/null)
        if echo "$pid" | grep -qE '^[0-9]+$' && kill -0 "$pid" 2>/dev/null; then
            kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        fi
        rm -f "$INSTALL_DIR/telegram_notify.pid"
    fi
}

telegram_start_notify() {
    telegram_stop_notify
    if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        setup_telegram_service
    fi
}

telegram_disable_service() {
    if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/conduit-telegram.service ]; then
        systemctl stop conduit-telegram.service 2>/dev/null || true
        systemctl disable conduit-telegram.service 2>/dev/null || true
    fi
}

show_about() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "              ${BOLD}ABOUT PSIPHON CONDUIT MANAGER${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}What is Psiphon Conduit?${NC}"
    echo -e "  Psiphon is a free anti-censorship tool helping millions access"
    echo -e "  the open internet. Conduit is their ${BOLD}P2P volunteer network${NC}."
    echo -e "  By running a node, you help users in censored regions connect."
    echo ""
    echo -e "  ${BOLD}${GREEN}How P2P Works${NC}"
    echo -e "  Unlike centralized VPNs, Conduit is ${CYAN}decentralized${NC}:"
    echo -e "    ${YELLOW}1.${NC} Your server registers with Psiphon's broker"
    echo -e "    ${YELLOW}2.${NC} Users discover your node through the P2P network"
    echo -e "    ${YELLOW}3.${NC} Direct encrypted WebRTC tunnels are established"
    echo -e "    ${YELLOW}4.${NC} Traffic: ${GREEN}User${NC} <--P2P--> ${CYAN}You${NC} <--> ${YELLOW}Internet${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}Technical${NC}"
    echo -e "    Protocol:  WebRTC + DTLS (looks like video calls)"
    echo -e "    Ports:     TCP 443 required | Turbo: UDP 16384-32768"
    echo -e "    Resources: ~50MB RAM per 100 clients, runs in Docker"
    echo ""
    echo -e "  ${BOLD}${GREEN}Privacy${NC}"
    echo -e "    ${GREEN}✓${NC} End-to-end encrypted - you can't see user traffic"
    echo -e "    ${GREEN}✓${NC} No logs stored | Clean uninstall available"
    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Made by Sam - SamNet Technologies${NC}"
    echo -e "  GitHub:  ${CYAN}https://github.com/SamNet-dev/conduit-manager${NC}"
    echo -e "  Twitter: ${CYAN}https://x.com/YourAnonHeart${NC}"
    echo -e "  Psiphon: ${CYAN}https://psiphon.ca${NC}"
    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}${YELLOW}Special Thanks${NC}"
    echo -e "  ${BOLD}ssmirr${NC} - For his dedicated fork of Psiphon Conduit that"
    echo -e "  makes this project possible. His commitment to maintaining"
    echo -e "  and improving the conduit container has enabled thousands"
    echo -e "  of volunteers to run nodes and help censored users worldwide."
    echo ""
    echo -e "  GitHub:  ${CYAN}https://github.com/ssmirr${NC}"
    echo -e "  Twitter: ${CYAN}https://x.com/PawnToPromotion${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

show_settings_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            print_header

            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  SETTINGS & TOOLS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "  1. ⚙️  Change settings (max-clients, bandwidth)"
            echo -e "  2. 📊 Set data usage cap"
            echo -e "  l. 🖥️  Set resource limits (CPU, memory)"
            echo ""
            echo -e "  3. 💾 Backup node key"
            echo -e "  4. 📥 Restore node key"
            echo -e "  5. 🩺 Health check"
            echo ""
            echo -e "  6. 📱 Show QR Code & Conduit ID"
            echo -e "  7. ℹ️  Version info"
            echo -e "  8. 📖 About Conduit"
            echo ""
            echo -e "  9. 🔄 Reset tracker data"
            local tracker_status tracker_enabled_status
            if is_tracker_active; then
                tracker_status="${GREEN}Active${NC}"
            else
                tracker_status="${RED}Inactive${NC}"
            fi
            if [ "${TRACKER_ENABLED:-true}" = "true" ]; then
                tracker_enabled_status="${GREEN}Enabled${NC}"
            else
                tracker_enabled_status="${RED}Disabled${NC}"
            fi
            echo -e "  d. 📡 Toggle tracker (${tracker_enabled_status}) — saves CPU when off"
            echo -e "  r. 📡 Restart tracker service  (${tracker_status})"
            echo -e "  t. 📲 Telegram Notifications"
            echo -e "  s. 🌐 Remote Servers"
            echo -e ""
            echo -e "  u. 🗑️  Uninstall"
            echo -e "  0. ← Back to main menu"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            redraw=false
        fi

        read -p "  Enter choice: " choice < /dev/tty || { return; }

        case "$choice" in
            1)
                change_settings
                redraw=true
                ;;
            2)
                set_data_cap
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            l|L)
                change_resource_limits
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            3)
                backup_key
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            4)
                restore_key
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            5)
                health_check
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            6)
                show_qr_code
                redraw=true
                ;;
            7)
                show_version
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            8)
                show_about
                redraw=true
                ;;
            9)
                echo ""
                while true; do
                    read -p "Reset tracker and delete all stats data? (y/n): " confirm < /dev/tty || true
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        echo "Stopping tracker service..."
                        stop_tracker_service 2>/dev/null || true
                        echo "Deleting tracker data..."
                        rm -rf /opt/conduit/traffic_stats 2>/dev/null || true
                        rm -f /opt/conduit/conduit-tracker.sh 2>/dev/null || true
                        echo "Restarting tracker service..."
                        regenerate_tracker_script
                        setup_tracker_service
                        echo -e "${GREEN}Tracker data has been reset.${NC}"
                        break
                    elif [[ "$confirm" =~ ^[Nn]$ ]]; then
                        echo "Cancelled."
                        break
                    else
                        echo "Please enter y or n."
                    fi
                done
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            d|D)
                echo ""
                if [ "${TRACKER_ENABLED:-true}" = "true" ]; then
                    echo -e "  ${YELLOW}⚠ Disabling tracker will stop these features:${NC}"
                    echo -e "    • Live peers by country"
                    echo -e "    • Top upload by country in dashboard"
                    echo -e "    • Advanced stats (country breakdown)"
                    echo -e "    • Unique IP tracking"
                    echo ""
                    echo -e "  ${GREEN}Benefit: Saves ~15-25% CPU on busy servers${NC}"
                    echo ""
                    read -p "  Disable tracker? (y/n): " confirm < /dev/tty || true
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        TRACKER_ENABLED=false
                        save_settings
                        stop_tracker_service
                        echo -e "  ${GREEN}✓ Tracker disabled.${NC}"
                    else
                        echo "  Cancelled."
                    fi
                else
                    read -p "  Enable tracker? (y/n): " confirm < /dev/tty || true
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        TRACKER_ENABLED=true
                        save_settings
                        setup_tracker_service
                        if is_tracker_active; then
                            echo -e "  ${GREEN}✓ Tracker enabled and running.${NC}"
                        else
                            echo -e "  ${YELLOW}Tracker enabled but failed to start. Try 'r' to restart.${NC}"
                        fi
                    else
                        echo "  Cancelled."
                    fi
                fi
                read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            r)
                echo ""
                if [ "${TRACKER_ENABLED:-true}" = "false" ]; then
                    echo -e "  ${YELLOW}Tracker is disabled. Use 'd' to enable it first.${NC}"
                    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
                    redraw=true
                    continue
                fi
                echo -ne "  Regenerating tracker script... "
                regenerate_tracker_script
                echo -e "${GREEN}done${NC}"
                echo -ne "  Starting tracker service... "
                setup_tracker_service
                if is_tracker_active; then
                    echo -e "${GREEN}✓ Tracker is now active${NC}"
                else
                    echo -e "${RED}✗ Failed to start tracker. Run health check for details.${NC}"
                fi
                read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            t)
                show_telegram_menu
                redraw=true
                ;;
            s|S)
                show_server_management_submenu
                redraw=true
                ;;
            u)
                uninstall_all
                exit 0
                ;;
            0)
                return
                ;;
            "")
                ;;
            *)
                echo -e "${RED}Invalid choice${NC}"
                ;;
        esac
    done
}

show_telegram_menu() {
    while true; do
        # Reload settings from disk to reflect any changes
        [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
        clear
        print_header
        if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            # Already configured — show management menu
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            local _sh="${TELEGRAM_START_HOUR:-0}"
            echo -e "  Status: ${GREEN}✓ Enabled${NC} (every ${TELEGRAM_INTERVAL}h starting at ${_sh}:00)"
            echo ""
            local alerts_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_ALERTS_ENABLED:-true}" != "true" ] && alerts_st="${RED}OFF${NC}"
            local daily_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_DAILY_SUMMARY:-true}" != "true" ] && daily_st="${RED}OFF${NC}"
            local weekly_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" != "true" ] && weekly_st="${RED}OFF${NC}"
            echo -e "  1. 📩 Send test message"
            echo -e "  2. ⏱  Change interval"
            echo -e "  3. ❌ Disable notifications"
            echo -e "  4. 🔄 Reconfigure (new bot/chat)"
            echo -e "  5. 🚨 Alerts (CPU/RAM/down):    ${alerts_st}"
            echo -e "  6. 📋 Daily summary:            ${daily_st}"
            echo -e "  7. 📊 Weekly summary:           ${weekly_st}"
            local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
            echo -e "  8. 🏷  Server label:            ${CYAN}${cur_label}${NC}"
            echo -e "  0. ← Back"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            read -p "  Enter choice: " tchoice < /dev/tty || return
            case "$tchoice" in
                1)
                    echo ""
                    echo -ne "  Sending test message... "
                    if telegram_test_message; then
                        echo -e "${GREEN}✓ Sent!${NC}"
                    else
                        echo -e "${RED}✗ Failed. Check your token/chat ID.${NC}"
                    fi
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                2)
                    echo ""
                    echo -e "  Select notification interval:"
                    echo -e "  1. Every 1 hour"
                    echo -e "  2. Every 3 hours"
                    echo -e "  3. Every 6 hours (recommended)"
                    echo -e "  4. Every 12 hours"
                    echo -e "  5. Every 24 hours"
                    echo ""
                    read -p "  Choice [1-5]: " ichoice < /dev/tty || true
                    case "$ichoice" in
                        1) TELEGRAM_INTERVAL=1 ;;
                        2) TELEGRAM_INTERVAL=3 ;;
                        3) TELEGRAM_INTERVAL=6 ;;
                        4) TELEGRAM_INTERVAL=12 ;;
                        5) TELEGRAM_INTERVAL=24 ;;
                        *) echo -e "  ${RED}Invalid choice${NC}"; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; continue ;;
                    esac
                    echo ""
                    echo -e "  What hour should reports start? (0-23, e.g. 8 = 8:00 AM)"
                    echo -e "  Reports will repeat every ${TELEGRAM_INTERVAL}h from this hour."
                    read -p "  Start hour [0-23] (default ${TELEGRAM_START_HOUR:-0}): " shchoice < /dev/tty || true
                    if [ -n "$shchoice" ] && [ "$shchoice" -ge 0 ] 2>/dev/null && [ "$shchoice" -le 23 ] 2>/dev/null; then
                        TELEGRAM_START_HOUR=$shchoice
                    fi
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Reports every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR:-0}:00${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                3)
                    TELEGRAM_ENABLED=false
                    save_settings
                    telegram_disable_service
                    echo -e "  ${GREEN}✓ Telegram notifications disabled${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                4)
                    telegram_setup_wizard
                    ;;
                5)
                    if [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
                        TELEGRAM_ALERTS_ENABLED=false
                        echo -e "  ${RED}✗ Alerts disabled${NC}"
                    else
                        TELEGRAM_ALERTS_ENABLED=true
                        echo -e "  ${GREEN}✓ Alerts enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                6)
                    if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_DAILY_SUMMARY=false
                        echo -e "  ${RED}✗ Daily summary disabled${NC}"
                    else
                        TELEGRAM_DAILY_SUMMARY=true
                        echo -e "  ${GREEN}✓ Daily summary enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                7)
                    if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_WEEKLY_SUMMARY=false
                        echo -e "  ${RED}✗ Weekly summary disabled${NC}"
                    else
                        TELEGRAM_WEEKLY_SUMMARY=true
                        echo -e "  ${GREEN}✓ Weekly summary enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                8)
                    echo ""
                    local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
                    echo -e "  Current label: ${CYAN}${cur_label}${NC}"
                    echo -e "  This label appears in all Telegram messages to identify the server."
                    echo -e "  Leave blank to use hostname ($(hostname 2>/dev/null || echo 'unknown'))"
                    echo ""
                    read -p "  New label: " new_label < /dev/tty || true
                    TELEGRAM_SERVER_LABEL="${new_label}"
                    save_settings
                    telegram_start_notify
                    local display_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
                    echo -e "  ${GREEN}✓ Server label set to: ${display_label}${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                0) return ;;
            esac
        elif [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            # Disabled but credentials exist — offer re-enable
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            echo -e "  Status: ${RED}✗ Disabled${NC} (credentials saved)"
            echo ""
            echo -e "  1. ✅ Re-enable notifications (every ${TELEGRAM_INTERVAL:-6}h)"
            echo -e "  2. 🔄 Reconfigure (new bot/chat)"
            echo -e "  0. ← Back"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            read -p "  Enter choice: " tchoice < /dev/tty || return
            case "$tchoice" in
                1)
                    TELEGRAM_ENABLED=true
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Telegram notifications re-enabled${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                2)
                    telegram_setup_wizard
                    ;;
                0) return ;;
            esac
        else
            # Not configured — run wizard
            telegram_setup_wizard
            return
        fi
    done
}

telegram_setup_wizard() {
    # Save and restore variables on Ctrl+C
    local _saved_token="$TELEGRAM_BOT_TOKEN"
    local _saved_chatid="$TELEGRAM_CHAT_ID"
    local _saved_interval="$TELEGRAM_INTERVAL"
    local _saved_enabled="$TELEGRAM_ENABLED"
    local _saved_starthour="$TELEGRAM_START_HOUR"
    local _saved_label="$TELEGRAM_SERVER_LABEL"
    trap 'TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"; trap - SIGINT; echo; return' SIGINT
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "              ${BOLD}TELEGRAM NOTIFICATIONS SETUP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Step 1: Create a Telegram Bot${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Open Telegram and search for ${BOLD}@BotFather${NC}"
    echo -e "  2. Send ${YELLOW}/newbot${NC}"
    echo -e "  3. Choose a name (e.g. \"My Conduit Monitor\")"
    echo -e "  4. Choose a username (e.g. \"my_conduit_bot\")"
    echo -e "  5. BotFather will give you a token like:"
    echo -e "     ${YELLOW}123456789:ABCdefGHIjklMNOpqrsTUVwxyz${NC}"
    echo ""
    echo -e "  ${BOLD}Recommended:${NC} Send these commands to @BotFather:"
    echo -e "     ${YELLOW}/setjoingroups${NC} → Disable (prevents adding to groups)"
    echo -e "     ${YELLOW}/setprivacy${NC}   → Enable (limits message access)"
    echo ""
    echo -e "  ${YELLOW}⚠ OPSEC Note:${NC} Enabling Telegram notifications creates"
    echo -e "  outbound connections to api.telegram.org from this server."
    echo -e "  This traffic may be visible to your network provider."
    echo ""
    read -p "  Enter your bot token: " TELEGRAM_BOT_TOKEN < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; return; }
    echo ""
    # Trim whitespace
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN## }"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN%% }"
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        echo -e "  ${RED}No token entered. Setup cancelled.${NC}"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    # Validate token format
    if ! echo "$TELEGRAM_BOT_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$'; then
        echo -e "  ${RED}Invalid token format. Should be like: 123456789:ABCdefGHI...${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    echo ""
    echo -e "  ${BOLD}Step 2: Get Your Chat ID${NC}"
    echo -e "  ${CYAN}────────────────────────${NC}"
    echo -e "  1. Open your new bot in Telegram"
    echo -e "  2. Send it the message: ${YELLOW}/start${NC}"
    echo -e ""
    echo -e "  ${YELLOW}Important:${NC} You MUST send ${BOLD}/start${NC} to the bot first!"
    echo -e "  The bot cannot respond to you until you do this."
    echo -e ""
    echo -e "  3. Press Enter here when done..."
    echo ""
    read -p "  Press Enter after sending /start to your bot... " < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"; return; }

    echo -ne "  Detecting chat ID... "
    local attempts=0
    TELEGRAM_CHAT_ID=""
    while [ $attempts -lt 3 ] && [ -z "$TELEGRAM_CHAT_ID" ]; do
        if telegram_get_chat_id; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 2
    done

    if [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo -e "${RED}✗ Could not detect chat ID${NC}"
        echo -e "  Make sure you sent /start to the bot and try again."
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi
    echo -e "${GREEN}✓ Chat ID: ${TELEGRAM_CHAT_ID}${NC}"

    echo ""
    echo -e "  ${BOLD}Step 3: Notification Interval${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Every 1 hour"
    echo -e "  2. Every 3 hours"
    echo -e "  3. Every 6 hours (recommended)"
    echo -e "  4. Every 12 hours"
    echo -e "  5. Every 24 hours"
    echo ""
    read -p "  Choice [1-5] (default 3): " ichoice < /dev/tty || true
    case "$ichoice" in
        1) TELEGRAM_INTERVAL=1 ;;
        2) TELEGRAM_INTERVAL=3 ;;
        4) TELEGRAM_INTERVAL=12 ;;
        5) TELEGRAM_INTERVAL=24 ;;
        *) TELEGRAM_INTERVAL=6 ;;
    esac

    echo ""
    echo -e "  ${BOLD}Step 4: Start Hour${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  What hour should reports start? (0-23, e.g. 8 = 8:00 AM)"
    echo -e "  Reports will repeat every ${TELEGRAM_INTERVAL}h from this hour."
    echo ""
    read -p "  Start hour [0-23] (default 0): " shchoice < /dev/tty || true
    if [ -n "$shchoice" ] && [ "$shchoice" -ge 0 ] 2>/dev/null && [ "$shchoice" -le 23 ] 2>/dev/null; then
        TELEGRAM_START_HOUR=$shchoice
    else
        TELEGRAM_START_HOUR=0
    fi

    echo ""
    echo -ne "  Sending test message... "
    if telegram_test_message; then
        echo -e "${GREEN}✓ Success!${NC}"
    else
        echo -e "${RED}✗ Failed to send. Check your token.${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    TELEGRAM_ENABLED=true
    save_settings
    telegram_start_notify

    trap - SIGINT
    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Telegram notifications enabled!${NC}"
    echo -e "  You'll receive reports every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR}:00."
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

show_menu() {
    # Fix outdated systemd service files
    if command -v systemctl &>/dev/null; then
        local need_reload=false

        # Fix outdated conduit.service
        if [ -f /etc/systemd/system/conduit.service ]; then
            local need_rewrite=false
            grep -q "Requires=docker.service" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
            grep -q "Type=simple" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
            grep -q "Restart=always" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
            grep -q "max-clients" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
            grep -q "conduit start$" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
            if [ "$need_rewrite" = true ]; then
                cat > /etc/systemd/system/conduit.service << SVCEOF
[Unit]
Description=Psiphon Conduit Service
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/conduit start --auto
ExecStop=/usr/local/bin/conduit stop --auto

[Install]
WantedBy=multi-user.target
SVCEOF
                need_reload=true
            fi
        fi

        # Fix tracker service file
        if [ -f /etc/systemd/system/conduit-tracker.service ] && grep -q "Requires=docker.service" /etc/systemd/system/conduit-tracker.service 2>/dev/null; then
            sed -i 's/Requires=docker.service/Wants=docker.service/g' /etc/systemd/system/conduit-tracker.service
            need_reload=true
        fi

        # Single daemon-reload for all file changes
        if [ "$need_reload" = true ]; then
            systemctl daemon-reload 2>/dev/null || true
            systemctl reset-failed conduit.service 2>/dev/null || true
            systemctl enable conduit.service 2>/dev/null || true
        fi

        # Auto-fix conduit.service if it's in failed state
        local svc_state=$(systemctl is-active conduit.service 2>/dev/null)
        if [ "$svc_state" = "failed" ]; then
            systemctl reset-failed conduit.service 2>/dev/null || true
            systemctl restart conduit.service 2>/dev/null || true
        fi
    fi

    # Auto-start/upgrade tracker if containers are up
    local any_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    any_running=${any_running:-0}
    if [ "$any_running" -gt 0 ] 2>/dev/null; then
        local tracker_script="$INSTALL_DIR/conduit-tracker.sh"
        local old_hash=$(md5sum "$tracker_script" 2>/dev/null | awk '{print $1}')
        regenerate_tracker_script
        local new_hash=$(md5sum "$tracker_script" 2>/dev/null | awk '{print $1}')
        if ! is_tracker_active; then
            setup_tracker_service
        elif [ "$old_hash" != "$new_hash" ]; then
            systemctl restart conduit-tracker.service 2>/dev/null || true
        fi
    fi

    [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

    if command -v systemctl &>/dev/null && systemctl is-active conduit-telegram.service &>/dev/null; then
        telegram_generate_notify_script
        systemctl restart conduit-telegram.service 2>/dev/null || true
    fi

    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            print_header

            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  MAIN MENU${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "  1. 📈 View status dashboard"
            echo -e "  2. 📊 Live connection stats"
            echo -e "  3. 📋 View logs"
            echo -e "  4. 🌍 Live peers by country"
            echo ""
            echo -e "  5. ▶️  Start Conduit"
            echo -e "  6. ⏹️  Stop Conduit"
            echo -e "  7. 🔁 Restart Conduit"
            echo -e "  8. 🔄 Update Conduit"
            echo ""
            echo -e "  9. ⚙️  Settings & Tools"
            echo -e "  c. 📦 Manage containers"
            echo -e "  a. 📊 Advanced stats"
            echo -e "  m. 🌐 Multi-server dashboard"
            # Snowflake menu item
            if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
                local _sf_label="${RED}Stopped${NC}"
                is_snowflake_running && _sf_label="${GREEN}Running${NC}"
                echo -e "  f. ❄  Snowflake Proxy [${_sf_label}]"
            else
                echo -e "  f. ❄  Snowflake Proxy"
            fi
            echo -e "  i. ℹ️  Info & Help"
            echo -e "  0. 🚪 Exit"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            redraw=false
        fi

        read -p "  Enter choice: " choice < /dev/tty || { echo "Input error. Exiting."; exit 1; }

        case "$choice" in
            1)
                show_dashboard
                redraw=true
                ;;
            2)
                show_live_stats
                redraw=true
                ;;
            3)
                show_logs
                redraw=true
                ;;
            4)
                show_peers
                redraw=true
                ;;
            5)
                start_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            6)
                stop_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            7)
                restart_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            8)
                update_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            9)
                show_settings_menu
                redraw=true
                ;;
            c)
                manage_containers
                redraw=true
                ;;
            a)
                show_advanced_stats
                redraw=true
                ;;
            m|M)
                show_multi_dashboard
                redraw=true
                ;;
            f|F)
                show_snowflake_menu
                redraw=true
                ;;
            i)
                show_info_menu
                redraw=true
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            "")
                ;;
            *)
                echo -e "${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                ;;
        esac
    done
}

# Info hub - sub-page menu
show_info_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}  INFO & HELP${NC}"
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "  1. 📡 How the Tracker Works"
            echo -e "  2. 📊 Understanding the Stats Pages"
            echo -e "  3. 📦 Containers & Scaling"
            echo -e "  4. 🔒 Privacy & Security"
            echo -e "  5. ❄️  Snowflake Proxy"
            echo -e "  6. ⚖️  Safety & Legal"
            echo -e "  7. 🚀 About Psiphon Conduit"
            echo -e "  8. 📈 Dashboard Metrics Explained"
            echo ""
            echo -e "  [b] Back to menu"
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo ""
            redraw=false
        fi
        read -p "  Select page: " info_choice < /dev/tty || break
        case "$info_choice" in
            1) _info_tracker; redraw=true ;;
            2) _info_stats; redraw=true ;;
            3) _info_containers; redraw=true ;;
            4) _info_privacy; redraw=true ;;
            5) show_info_snowflake; redraw=true ;;
            6) show_info_safety; redraw=true ;;
            7) show_about; redraw=true ;;
            8) show_dashboard_info; redraw=true ;;
            b|"") break ;;
            *) echo -e "  ${RED}Invalid.${NC}"; sleep 1; redraw=true ;;
        esac
    done
}

_info_tracker() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  HOW THE TRACKER WORKS${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}What is it?${NC}"
    echo -e "  A background systemd service (conduit-tracker.service) that"
    echo -e "  monitors network traffic on your server using tcpdump."
    echo -e "  It runs continuously and captures ALL TCP/UDP traffic"
    echo -e "  (excluding SSH port 22) to track where traffic goes."
    echo ""
    echo -e "  ${BOLD}How it works${NC}"
    echo -e "  Every 15 seconds the tracker:"
    echo -e "    ${YELLOW}1.${NC} Captures network packets via tcpdump"
    echo -e "    ${YELLOW}2.${NC} Extracts source/destination IPs and byte counts"
    echo -e "    ${YELLOW}3.${NC} Resolves each IP to a country using GeoIP"
    echo -e "    ${YELLOW}4.${NC} Saves cumulative data to disk"
    echo ""
    echo -e "  ${BOLD}Data files${NC}  ${DIM}(in /opt/conduit/traffic_stats/)${NC}"
    echo -e "    ${CYAN}cumulative_data${NC}  - Country traffic totals (bytes in/out)"
    echo -e "    ${CYAN}cumulative_ips${NC}   - All unique IPs ever seen + country"
    echo -e "    ${CYAN}tracker_snapshot${NC} - Last 15-second cycle (for live views)"
    echo ""
    echo -e "  ${BOLD}Important${NC}"
    echo -e "  The tracker captures ALL server traffic, not just Conduit."
    echo -e "  IP counts include system updates, DNS, Docker pulls, etc."
    echo -e "  This is why unique IP counts are higher than client counts."
    echo -e "  To reset all data: Settings > Reset tracker data."
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

_info_stats() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  UNDERSTANDING THE STATS PAGES${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Unique IPs vs Clients${NC}"
    echo -e "    ${YELLOW}IPs${NC}     = Total unique IP addresses seen in ALL network"
    echo -e "            traffic. Includes non-Conduit traffic (system"
    echo -e "            updates, DNS, Docker, etc). Always higher."
    echo -e "    ${GREEN}Clients${NC} = Actual Psiphon peers connected to your Conduit"
    echo -e "            containers. Comes from Docker logs. This is"
    echo -e "            the real number of people you are helping."
    echo ""
    echo -e "  ${BOLD}Dashboard (option 1)${NC}"
    echo -e "    Shows status, resources, traffic totals, and two"
    echo -e "    side-by-side TOP 5 charts:"
    echo -e "      ${GREEN}Active Clients${NC} - Estimated clients per country"
    echo -e "      ${YELLOW}Top Upload${NC}     - Countries you upload most to"
    echo ""
    echo -e "  ${BOLD}Live Peers (option 4)${NC}"
    echo -e "    Full-page traffic breakdown by country. Shows:"
    echo -e "      Total bytes, Speed (KB/s), Clients per country"
    echo -e "    Client counts are estimated from the snapshot"
    echo -e "    distribution scaled to actual connected count."
    echo ""
    echo -e "  ${BOLD}Advanced Stats (a)${NC}"
    echo -e "    Container resources (CPU, RAM, clients, bandwidth),"
    echo -e "    network speed, tracker status, and TOP 7 charts"
    echo -e "    for unique IPs, download, and upload by country."
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

_info_containers() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  CONTAINERS & SCALING${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}What are containers?${NC}"
    echo -e "  Each container is an independent Conduit node running"
    echo -e "  in Docker. Multiple containers let you serve more"
    echo -e "  clients simultaneously from the same server."
    echo ""
    echo -e "  ${BOLD}Naming${NC}"
    echo -e "    Container 1: ${CYAN}conduit${NC}      Volume: ${CYAN}conduit-data${NC}"
    echo -e "    Container 2: ${CYAN}conduit-2${NC}    Volume: ${CYAN}conduit-data-2${NC}"
    echo -e "    Container N: ${CYAN}conduit-N${NC}    Volume: ${CYAN}conduit-data-N${NC}"
    echo -e "    (Currently configured: 1–${CONTAINER_COUNT})"
    echo ""
    echo -e "  ${BOLD}Scaling recommendations${NC}"
    echo -e "    ${YELLOW}1 CPU / <1GB RAM:${NC}  Stick with 1 container"
    echo -e "    ${YELLOW}2 CPUs / 2GB RAM:${NC}  1-2 containers"
    echo -e "    ${GREEN}4+ CPUs / 4GB+ RAM:${NC} 3-5+ containers"
    echo -e "  Each container uses ~50MB RAM per 100 clients."
    echo ""
    echo -e "  ${BOLD}Per-container settings${NC}"
    echo -e "  You can set different max-clients and bandwidth for"
    echo -e "  each container in Settings > Change settings. Choose"
    echo -e "  'Apply to specific container' to customize individually."
    echo ""
    echo -e "  ${BOLD}Managing${NC}"
    echo -e "  Use Manage Containers (c) to add/remove containers,"
    echo -e "  start/stop individual ones, or view per-container stats."
    echo -e "  Each container has its own volume (identity key)."
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

_info_privacy() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  PRIVACY & SECURITY${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Is my traffic visible?${NC}"
    echo -e "  ${GREEN}No.${NC} All Conduit traffic is end-to-end encrypted using"
    echo -e "  WebRTC + DTLS. You cannot see what users are browsing."
    echo -e "  The connection looks like a regular video call."
    echo ""
    echo -e "  ${BOLD}What data is stored?${NC}"
    echo -e "  Conduit Manager stores:"
    echo -e "    ${GREEN}Node identity key${NC} - Your unique node ID (in Docker volume)"
    echo -e "    ${GREEN}Settings${NC}          - Max clients, bandwidth, container count"
    echo -e "    ${GREEN}Tracker stats${NC}     - Country-level traffic aggregates"
    echo -e "  ${RED}No${NC} user browsing data, IP logs, or personal info is stored."
    echo ""
    echo -e "  ${BOLD}What can the tracker see?${NC}"
    echo -e "  The tracker only records:"
    echo -e "    - Which countries connect (via GeoIP lookup)"
    echo -e "    - How many bytes flow in/out per country"
    echo -e "    - Total unique IP addresses (not logged individually)"
    echo -e "  It cannot see URLs, content, or decrypt any traffic."
    echo ""
    echo -e "  ${BOLD}Uninstall${NC}"
    echo -e "  Full uninstall (option 9 > Uninstall) removes:"
    echo -e "    - All containers and Docker volumes"
    echo -e "    - Tracker service and all stats data"
    echo -e "    - Settings, systemd service files"
    echo -e "    - The conduit command itself"
    echo -e "  Nothing is left behind on your system."
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

#═══════════════════════════════════════════════════════════════════════
# Multi-Server Dashboard
#═══════════════════════════════════════════════════════════════════════

load_servers() {
    SERVER_LABELS=()
    SERVER_CONNS=()
    SERVER_AUTHS=()
    SERVER_COUNT=0
    local conf="$INSTALL_DIR/servers.conf"
    [ -f "$conf" ] || return
    while IFS='|' read -r _l _c _a _rest || [ -n "$_l" ]; do
        [[ "$_l" =~ ^#.*$ ]] && continue
        [ -z "$_l" ] || [ -z "$_c" ] && continue
        SERVER_LABELS+=("$_l")
        SERVER_CONNS+=("$_c")
        SERVER_AUTHS+=("${_a:-key}")
        SERVER_COUNT=$((SERVER_COUNT + 1))
    done < "$conf"
}

# Credential management helpers for password-based SSH auth
_ensure_sshpass() {
    command -v sshpass &>/dev/null && return 0
    echo ""
    echo -e "  ${YELLOW}sshpass is required for password-based SSH but is not installed.${NC}"
    read -p "  Install sshpass now? (y/n): " install_it < /dev/tty || return 1
    [[ "$install_it" =~ ^[Yy]$ ]] || { echo -e "  ${RED}Cannot proceed without sshpass.${NC}"; return 1; }

    echo -e "  ${DIM}Installing sshpass...${NC}"
    local installed=false
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq sshpass 2>/dev/null || { apt-get update -qq 2>/dev/null && apt-get install -y -qq sshpass 2>/dev/null; } && installed=true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q sshpass 2>/dev/null && installed=true
    elif command -v yum &>/dev/null; then
        yum install -y -q sshpass 2>/dev/null && installed=true
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm sshpass 2>/dev/null && installed=true
    elif command -v zypper &>/dev/null; then
        zypper install -y -n sshpass 2>/dev/null && installed=true
    elif command -v apk &>/dev/null; then
        apk add --no-cache sshpass 2>/dev/null && installed=true
    fi

    if [ "$installed" = true ] && command -v sshpass &>/dev/null; then
        echo -e "  ${GREEN}✓ sshpass installed successfully.${NC}"
        return 0
    else
        echo -e "  ${RED}✗ Failed to install sshpass. Install manually: apt install sshpass${NC}"
        return 1
    fi
}

_creds_key() {
    local keyfile="$INSTALL_DIR/.creds_key"
    if [ ! -f "$keyfile" ]; then
        ( umask 077; openssl rand -hex 32 > "$keyfile" 2>/dev/null )
        if [ $? -ne 0 ] || [ ! -s "$keyfile" ]; then
            echo "ERROR: Failed to generate encryption key" >&2
            rm -f "$keyfile"
            return 1
        fi
    fi
    echo "$keyfile"
}

_encrypt_pass() {
    local plaintext="$1"
    local keyfile
    keyfile=$(_creds_key) || return 1
    # -A = single-line base64 (no wrapping) to keep one ciphertext per line in creds file
    printf '%s' "$plaintext" | openssl enc -aes-256-cbc -pbkdf2 -a -A -pass "file:$keyfile" 2>/dev/null
}

_decrypt_pass() {
    local ciphertext="$1"
    local keyfile
    keyfile=$(_creds_key) || return 1
    # printf with \n needed for openssl base64 decoder; -A for single-line input
    printf '%s\n' "$ciphertext" | openssl enc -aes-256-cbc -pbkdf2 -a -A -d -pass "file:$keyfile" 2>/dev/null
}

_save_cred() {
    local label="$1"
    local password="$2"
    local credsfile="$INSTALL_DIR/servers.creds"
    local encrypted
    encrypted=$(_encrypt_pass "$password") || return 1
    [ -z "$encrypted" ] && return 1

    # Remove existing entry for this label
    if [ -f "$credsfile" ]; then
        local tmp="${credsfile}.tmp.$$"
        grep -v "^${label}|" "$credsfile" > "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$credsfile"
        chmod 600 "$credsfile" 2>/dev/null || true
    fi

    ( umask 077; echo "${label}|${encrypted}" >> "$credsfile" )
}

_load_cred() {
    local label="$1"
    local credsfile="$INSTALL_DIR/servers.creds"
    [ -f "$credsfile" ] || return 1
    local encrypted
    encrypted=$(grep "^${label}|" "$credsfile" 2>/dev/null | head -1 | cut -d'|' -f2-)
    [ -z "$encrypted" ] && return 1
    local plaintext
    plaintext=$(_decrypt_pass "$encrypted")
    [ -z "$plaintext" ] && return 1
    echo "$plaintext"
}

_remove_cred() {
    local label="$1"
    local credsfile="$INSTALL_DIR/servers.creds"
    [ -f "$credsfile" ] || return 0
    local tmp="${credsfile}.tmp.$$"
    grep -v "^${label}|" "$credsfile" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$credsfile"
    chmod 600 "$credsfile" 2>/dev/null || true
}

add_server_interactive() {
    local label conn auth_choice setup_key existing anyway
    echo -e "${CYAN}═══ ADD REMOTE SERVER ═══${NC}"
    echo ""
    read -p "  Server label (e.g. vps-nyc): " label < /dev/tty || return
    # Validate label
    if ! [[ "$label" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}  Invalid label. Use only letters, numbers, dashes, underscores.${NC}"
        return 1
    fi
    # Check server limit
    load_servers
    if [ "$SERVER_COUNT" -ge 9 ]; then
        echo -e "${RED}  Maximum of 9 remote servers reached.${NC}"
        return 1
    fi
    # Check for duplicates
    for existing in "${SERVER_LABELS[@]}"; do
        if [ "$existing" = "$label" ]; then
            echo -e "${RED}  Server '$label' already exists.${NC}"
            return 1
        fi
    done

    read -p "  SSH connection (user@host or user@host:port): " conn < /dev/tty || return
    if ! [[ "$conn" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+(:[0-9]+)?$ ]]; then
        echo -e "${RED}  Invalid SSH format. Use: user@host or user@host:port${NC}"
        return 1
    fi

    # Parse host and port
    local ssh_host ssh_port
    if [[ "$conn" == *:* ]]; then
        ssh_host="${conn%:*}"
        ssh_port="${conn##*:}"
    else
        ssh_host="$conn"
        ssh_port=22
    fi

    # Detect non-root user for sudo prefix on remote commands
    local ssh_user="${conn%%@*}"
    local _sudo=""
    if [ "$ssh_user" != "root" ]; then
        _sudo="sudo "
    fi

    # Auth method selection
    echo ""
    echo -e "  Authentication method:"
    echo -e "  1. 🔑 SSH Key (recommended)"
    echo -e "  2. 🔒 Password"
    echo ""
    read -p "  Select (1/2) [1]: " auth_choice < /dev/tty || return
    auth_choice="${auth_choice:-1}"

    local auth_type="key"
    local password=""
    local connection_ok=false

    if [ "$auth_choice" = "2" ]; then
        # --- Password auth flow ---
        _ensure_sshpass || return 1

        auth_type="pass"
        echo ""
        read -s -p "  SSH password: " password < /dev/tty || return
        echo ""
        [ -z "$password" ] && { echo -e "${RED}  Password cannot be empty.${NC}"; return 1; }

        echo ""
        echo -e "  Testing SSH connection to ${CYAN}${conn}${NC} (password)..."
        if SSHPASS="$password" sshpass -e ssh -o ConnectTimeout=10 \
               -o StrictHostKeyChecking=accept-new \
               -o PubkeyAuthentication=no \
               -p "$ssh_port" "$ssh_host" "echo ok" 2>/dev/null | grep -q "ok"; then
            echo -e "  ${GREEN}✓ Connection successful!${NC}"
            connection_ok=true
            # For non-root users, verify sudo access
            if [ "$ssh_user" != "root" ]; then
                echo -e "  ${DIM}Non-root user detected. Checking sudo access...${NC}"
                if SSHPASS="$password" sshpass -e ssh -o ConnectTimeout=5 \
                       -o PubkeyAuthentication=no \
                       -p "$ssh_port" "$ssh_host" "sudo -n true" 2>/dev/null; then
                    echo -e "  ${GREEN}✓ Passwordless sudo verified.${NC}"
                else
                    echo -e "  ${YELLOW}⚠ Passwordless sudo not available for '${ssh_user}'.${NC}"
                    echo -e "  ${DIM}  Remote commands require sudo. Add to sudoers:${NC}"
                    echo -e "  ${DIM}  echo '${ssh_user} ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/${ssh_user}${NC}"
                    local _scont
                    read -p "  Continue anyway? (y/n) [n]: " _scont < /dev/tty || return
                    [[ "${_scont:-n}" =~ ^[Yy]$ ]] || return 1
                fi
            fi
            if SSHPASS="$password" sshpass -e ssh -o ConnectTimeout=5 \
                   -o PubkeyAuthentication=no \
                   -p "$ssh_port" "$ssh_host" "${_sudo}command -v conduit" &>/dev/null; then
                echo -e "  ${GREEN}✓ Conduit detected on remote server.${NC}"
                # Check remote version and script hash to detect outdated code
                local remote_ver needs_update=false update_reason=""
                remote_ver=$(SSHPASS="$password" sshpass -e ssh -o ConnectTimeout=5 \
                    -o PubkeyAuthentication=no \
                    -p "$ssh_port" "$ssh_host" "${_sudo}conduit version 2>/dev/null" 2>/dev/null \
                    | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p')
                if [ -n "$remote_ver" ] && [ "$remote_ver" != "$VERSION" ]; then
                    needs_update=true
                    update_reason="Remote version: v${remote_ver} (local: v${VERSION})"
                elif [ -n "$remote_ver" ]; then
                    # Same version — compare script hash for code-level changes
                    local local_hash remote_hash
                    local_hash=$(sha256sum "$INSTALL_DIR/conduit" 2>/dev/null | cut -d' ' -f1)
                    remote_hash=$(SSHPASS="$password" sshpass -e ssh -o ConnectTimeout=5 \
                        -o PubkeyAuthentication=no \
                        -p "$ssh_port" "$ssh_host" "${_sudo}sha256sum /opt/conduit/conduit 2>/dev/null" 2>/dev/null \
                        | cut -d' ' -f1)
                    if [ -n "$local_hash" ] && [ -n "$remote_hash" ] && [ "$local_hash" != "$remote_hash" ]; then
                        needs_update=true
                        update_reason="Same version (v${remote_ver}) but script differs"
                    fi
                fi
                if [ "$needs_update" = true ]; then
                    echo -e "  ${YELLOW}⚠ ${update_reason}${NC}"
                    local do_update
                    read -p "  Update remote server? (y/n) [y]: " do_update < /dev/tty || true
                    do_update="${do_update:-y}"
                    if [[ "$do_update" =~ ^[Yy]$ ]]; then
                        echo -e "  ${DIM}Updating remote server...${NC}"
                        if SSHPASS="$password" sshpass -e ssh -o ConnectTimeout=60 \
                               -o PubkeyAuthentication=no \
                               -p "$ssh_port" "$ssh_host" "${_sudo}conduit update" 2>/dev/null; then
                            echo -e "  ${GREEN}✓ Remote server updated${NC}"
                        else
                            echo -e "  ${YELLOW}⚠ Update may have failed. You can update later from the dashboard.${NC}"
                        fi
                    fi
                fi
            else
                echo -e "  ${YELLOW}⚠ 'conduit' command not found on remote server.${NC}"
                echo -e "  ${DIM}  Install conduit on the remote server first for full functionality.${NC}"
            fi
        else
            echo -e "  ${RED}✗ Connection failed. Check password, host, and port.${NC}"
            read -p "  Add anyway? (y/n): " anyway < /dev/tty || return
            [[ "$anyway" =~ ^[Yy]$ ]] || return 1
        fi

        # Offer SSH key setup for passwordless future connections
        if [ "$connection_ok" = true ]; then
            echo ""
            echo -e "  ${CYAN}Set up SSH key for passwordless login? (recommended)${NC}"
            read -p "  This avoids storing the password. (y/n) [y]: " setup_key < /dev/tty || true
            setup_key="${setup_key:-y}"
            if [[ "$setup_key" =~ ^[Yy]$ ]]; then
                # Generate SSH key if none exists
                if [ ! -f /root/.ssh/id_rsa.pub ] && [ ! -f /root/.ssh/id_ed25519.pub ]; then
                    echo -e "  ${DIM}Generating SSH key pair...${NC}"
                    mkdir -p /root/.ssh && chmod 700 /root/.ssh
                    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q 2>/dev/null || \
                    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q 2>/dev/null
                fi

                # Copy key to remote server
                echo -e "  ${DIM}Copying SSH key to ${conn}...${NC}"
                if SSHPASS="$password" sshpass -e ssh-copy-id \
                       -o StrictHostKeyChecking=accept-new \
                       -p "$ssh_port" "$ssh_host" 2>/dev/null; then
                    echo -e "  ${GREEN}✓ SSH key installed on remote server!${NC}"
                    # Verify key auth works
                    if ssh -o ConnectTimeout=5 -o BatchMode=yes \
                           -p "$ssh_port" "$ssh_host" "echo ok" 2>/dev/null | grep -q "ok"; then
                        echo -e "  ${GREEN}✓ Key-based auth verified. Switching to key auth.${NC}"
                        auth_type="key"
                        password=""
                    else
                        echo -e "  ${YELLOW}⚠ Key auth verification failed. Keeping password auth.${NC}"
                    fi
                else
                    echo -e "  ${YELLOW}⚠ ssh-copy-id failed. Keeping password auth.${NC}"
                fi
            fi
        fi

        # Store encrypted password if still using password auth
        if [ "$auth_type" = "pass" ] && [ -n "$password" ]; then
            _save_cred "$label" "$password" || {
                echo -e "${RED}  ✗ Failed to store encrypted credentials.${NC}"
                return 1
            }
        fi
    else
        # --- SSH key auth flow (original) ---
        echo ""
        echo -e "  Testing SSH connection to ${CYAN}${conn}${NC}..."
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
               -o BatchMode=yes -p "$ssh_port" "$ssh_host" "echo ok" 2>/dev/null | grep -q "ok"; then
            echo -e "  ${GREEN}✓ Connection successful!${NC}"
            # For non-root users, verify sudo access
            if [ "$ssh_user" != "root" ]; then
                echo -e "  ${DIM}Non-root user detected. Checking sudo access...${NC}"
                if ssh -o ConnectTimeout=5 -o BatchMode=yes \
                       -p "$ssh_port" "$ssh_host" "sudo -n true" 2>/dev/null; then
                    echo -e "  ${GREEN}✓ Passwordless sudo verified.${NC}"
                else
                    echo -e "  ${YELLOW}⚠ Passwordless sudo not available for '${ssh_user}'.${NC}"
                    echo -e "  ${DIM}  Remote commands require sudo. Add to sudoers:${NC}"
                    echo -e "  ${DIM}  echo '${ssh_user} ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/${ssh_user}${NC}"
                    local _scont
                    read -p "  Continue anyway? (y/n) [n]: " _scont < /dev/tty || return
                    [[ "${_scont:-n}" =~ ^[Yy]$ ]] || return 1
                fi
            fi
            if ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$ssh_port" "$ssh_host" "${_sudo}command -v conduit" &>/dev/null; then
                echo -e "  ${GREEN}✓ Conduit detected on remote server.${NC}"
                # Check remote version and script hash to detect outdated code
                local remote_ver needs_update=false update_reason=""
                remote_ver=$(ssh -o ConnectTimeout=5 -o BatchMode=yes \
                    -p "$ssh_port" "$ssh_host" "${_sudo}conduit version 2>/dev/null" 2>/dev/null \
                    | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p')
                if [ -n "$remote_ver" ] && [ "$remote_ver" != "$VERSION" ]; then
                    needs_update=true
                    update_reason="Remote version: v${remote_ver} (local: v${VERSION})"
                elif [ -n "$remote_ver" ]; then
                    # Same version — compare script hash for code-level changes
                    local local_hash remote_hash
                    local_hash=$(sha256sum "$INSTALL_DIR/conduit" 2>/dev/null | cut -d' ' -f1)
                    remote_hash=$(ssh -o ConnectTimeout=5 -o BatchMode=yes \
                        -p "$ssh_port" "$ssh_host" "${_sudo}sha256sum /opt/conduit/conduit 2>/dev/null" 2>/dev/null \
                        | cut -d' ' -f1)
                    if [ -n "$local_hash" ] && [ -n "$remote_hash" ] && [ "$local_hash" != "$remote_hash" ]; then
                        needs_update=true
                        update_reason="Same version (v${remote_ver}) but script differs"
                    fi
                fi
                if [ "$needs_update" = true ]; then
                    echo -e "  ${YELLOW}⚠ ${update_reason}${NC}"
                    local do_update
                    read -p "  Update remote server? (y/n) [y]: " do_update < /dev/tty || true
                    do_update="${do_update:-y}"
                    if [[ "$do_update" =~ ^[Yy]$ ]]; then
                        echo -e "  ${DIM}Updating remote server...${NC}"
                        if ssh -o ConnectTimeout=60 -o BatchMode=yes \
                               -p "$ssh_port" "$ssh_host" "${_sudo}conduit update" 2>/dev/null; then
                            echo -e "  ${GREEN}✓ Remote server updated${NC}"
                        else
                            echo -e "  ${YELLOW}⚠ Update may have failed. You can update later from the dashboard.${NC}"
                        fi
                    fi
                fi
            else
                echo -e "  ${YELLOW}⚠ 'conduit' command not found on remote server.${NC}"
                echo -e "  ${DIM}  Install conduit on the remote server first for full functionality.${NC}"
            fi
        else
            echo -e "  ${RED}✗ Connection failed.${NC}"
            echo -e "  ${DIM}  Ensure SSH key-based auth is configured.${NC}"
            read -p "  Add anyway? (y/n): " anyway < /dev/tty || return
            [[ "$anyway" =~ ^[Yy]$ ]] || return 1
        fi
    fi

    echo "${label}|${conn}|${auth_type}" >> "$INSTALL_DIR/servers.conf"
    chmod 600 "$INSTALL_DIR/servers.conf" 2>/dev/null || true
    echo ""
    echo -e "  ${GREEN}✓ Server '${label}' added (${auth_type} auth).${NC}"
}

remove_server_interactive() {
    load_servers
    if [ "$SERVER_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}  No servers configured.${NC}"
        return
    fi
    echo -e "${CYAN}═══ REMOVE SERVER ═══${NC}"
    echo ""
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        echo "  $((i + 1)). ${SERVER_LABELS[$i]}  (${SERVER_CONNS[$i]})"
    done
    echo ""
    read -p "  Select server to remove (1-${SERVER_COUNT}): " idx < /dev/tty || return
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$SERVER_COUNT" ]; then
        echo -e "${RED}  Invalid selection.${NC}"
        return 1
    fi
    local target_label="${SERVER_LABELS[$((idx - 1))]}"
    # Close SSH control socket if open
    local sock="/tmp/conduit-ssh-${target_label}.sock"
    ssh -O exit -o "ControlPath=$sock" dummy 2>/dev/null || true

    # Remove stored credentials if any
    _remove_cred "$target_label"

    local conf="$INSTALL_DIR/servers.conf"
    local tmp="${conf}.tmp.$$"
    grep -v "^${target_label}|" "$conf" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$conf"
    chmod 600 "$conf" 2>/dev/null || true
    echo -e "  ${GREEN}✓ Server '${target_label}' removed.${NC}"
}

edit_server_interactive() {
    local idx si target_label target_conn target_auth echoice new_pass save_anyway new_conn
    load_servers
    if [ "$SERVER_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}  No servers configured.${NC}"
        return
    fi
    echo -e "${CYAN}═══ EDIT SERVER ═══${NC}"
    echo ""
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local atype="${SERVER_AUTHS[$i]:-key}"
        echo "  $((i + 1)). ${SERVER_LABELS[$i]}  (${SERVER_CONNS[$i]})  [${atype}]"
    done
    echo ""
    read -p "  Select server to edit (1-${SERVER_COUNT}): " idx < /dev/tty || return
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$SERVER_COUNT" ]; then
        echo -e "${RED}  Invalid selection.${NC}"
        return 1
    fi

    local si=$((idx - 1))
    local target_label="${SERVER_LABELS[$si]}"
    local target_conn="${SERVER_CONNS[$si]}"
    local target_auth="${SERVER_AUTHS[$si]:-key}"

    echo ""
    echo -e "  Server: ${GREEN}${target_label}${NC}  (${target_conn})  [${target_auth}]"
    echo ""
    echo -e "  What to change:"
    echo -e "  1. 🔒 Update password"
    echo -e "  2. 🔑 Switch to SSH key auth"
    echo -e "  3. 🌐 Change connection (user@host:port)"
    echo ""
    echo -e "  0. ← Back"
    echo ""
    read -p "  Enter choice: " echoice < /dev/tty || return

    case "$echoice" in
        1)
            # Update password
            _ensure_sshpass || return 1
            echo ""
            read -s -p "  New SSH password: " new_pass < /dev/tty || return
            echo ""
            [ -z "$new_pass" ] && { echo -e "${RED}  Password cannot be empty.${NC}"; return 1; }

            # Parse host/port for testing
            local ssh_host ssh_port
            if [[ "$target_conn" == *:* ]]; then
                ssh_host="${target_conn%:*}"
                ssh_port="${target_conn##*:}"
            else
                ssh_host="$target_conn"
                ssh_port=22
            fi

            echo -e "  Testing new password..."
            if SSHPASS="$new_pass" sshpass -e ssh -o ConnectTimeout=10 \
                   -o StrictHostKeyChecking=accept-new \
                   -o PubkeyAuthentication=no \
                   -p "$ssh_port" "$ssh_host" "echo ok" 2>/dev/null | grep -q "ok"; then
                echo -e "  ${GREEN}✓ Connection successful!${NC}"
            else
                echo -e "  ${YELLOW}⚠ Connection failed with new password.${NC}"
                read -p "  Save anyway? (y/n): " save_anyway < /dev/tty || return
                [[ "$save_anyway" =~ ^[Yy]$ ]] || return
            fi

            # Save new encrypted password
            _save_cred "$target_label" "$new_pass" || {
                echo -e "${RED}  ✗ Failed to store encrypted credentials.${NC}"
                return 1
            }

            # Update auth type to pass if it was key
            if [ "$target_auth" != "pass" ]; then
                local conf="$INSTALL_DIR/servers.conf"
                local tmp="${conf}.tmp.$$"
                sed "s#^${target_label}|.*#${target_label}|${target_conn}|pass#" "$conf" > "$tmp" 2>/dev/null
                if [ -s "$tmp" ]; then mv -f "$tmp" "$conf"; chmod 600 "$conf" 2>/dev/null || true
                else rm -f "$tmp"; echo -e "${RED}  ✗ Config update failed.${NC}"; return 1; fi
            fi

            # Close existing SSH socket so next connection uses new password
            local sock="/tmp/conduit-ssh-${target_label}.sock"
            ssh -O exit -o "ControlPath=$sock" dummy 2>/dev/null || true

            echo -e "  ${GREEN}✓ Password updated for '${target_label}'.${NC}"
            ;;
        2)
            # Switch to SSH key auth (or re-setup broken key auth)
            local ssh_host ssh_port
            if [[ "$target_conn" == *:* ]]; then
                ssh_host="${target_conn%:*}"
                ssh_port="${target_conn##*:}"
            else
                ssh_host="$target_conn"
                ssh_port=22
            fi

            # Close existing ControlMaster socket to avoid false positive
            local sock="/tmp/conduit-ssh-${target_label}.sock"
            ssh -O exit -o "ControlPath=$sock" dummy 2>/dev/null || true

            # Try key auth first (fresh connection)
            echo ""
            echo -e "  Testing SSH key auth to ${CYAN}${target_conn}${NC}..."
            if ssh -o ConnectTimeout=10 -o BatchMode=yes \
                   -p "$ssh_port" "$ssh_host" "echo ok" 2>/dev/null | grep -q "ok"; then
                echo -e "  ${GREEN}✓ Key auth already works!${NC}"
            else
                # Need current password to set up key
                echo -e "  ${DIM}Key auth not set up yet. Need current password to install key.${NC}"
                _ensure_sshpass || return 1
                local cur_pass
                cur_pass=$(_load_cred "$target_label")
                if [ -z "$cur_pass" ]; then
                    echo ""
                    read -s -p "  Enter current SSH password: " cur_pass < /dev/tty || return
                    echo ""
                fi
                [ -z "$cur_pass" ] && { echo -e "${RED}  No password available.${NC}"; return 1; }

                # Generate SSH key if none exists
                if [ ! -f /root/.ssh/id_rsa.pub ] && [ ! -f /root/.ssh/id_ed25519.pub ]; then
                    echo -e "  ${DIM}Generating SSH key pair...${NC}"
                    mkdir -p /root/.ssh && chmod 700 /root/.ssh
                    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q 2>/dev/null || \
                    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q 2>/dev/null
                fi

                echo -e "  ${DIM}Copying SSH key to ${target_conn}...${NC}"
                if SSHPASS="$cur_pass" sshpass -e ssh-copy-id \
                       -o StrictHostKeyChecking=accept-new \
                       -p "$ssh_port" "$ssh_host" 2>/dev/null; then
                    echo -e "  ${GREEN}✓ SSH key installed!${NC}"
                    # Verify
                    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes \
                           -p "$ssh_port" "$ssh_host" "echo ok" 2>/dev/null | grep -q "ok"; then
                        echo -e "  ${RED}✗ Key auth verification failed. Keeping password auth.${NC}"
                        return
                    fi
                else
                    echo -e "  ${RED}✗ ssh-copy-id failed. Keeping password auth.${NC}"
                    return
                fi
            fi

            # Update config to key auth
            local conf="$INSTALL_DIR/servers.conf"
            local tmp="${conf}.tmp.$$"
            sed "s#^${target_label}|.*#${target_label}|${target_conn}|key#" "$conf" > "$tmp" 2>/dev/null
            if [ -s "$tmp" ]; then mv -f "$tmp" "$conf"; chmod 600 "$conf" 2>/dev/null || true
            else rm -f "$tmp"; echo -e "${RED}  ✗ Config update failed.${NC}"; return; fi

            # Remove stored password
            _remove_cred "$target_label"

            # Close existing socket so next connection uses key
            ssh -O exit -o "ControlPath=$sock" dummy 2>/dev/null || true

            echo -e "  ${GREEN}✓ Switched '${target_label}' to SSH key auth. Password removed.${NC}"
            ;;
        3)
            # Change connection string
            echo ""
            read -p "  New SSH connection (user@host or user@host:port): " new_conn < /dev/tty || return
            if ! [[ "$new_conn" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+(:[0-9]+)?$ ]]; then
                echo -e "${RED}  Invalid SSH format. Use: user@host or user@host:port${NC}"
                return 1
            fi

            # Close old SSH socket
            local sock="/tmp/conduit-ssh-${target_label}.sock"
            ssh -O exit -o "ControlPath=$sock" dummy 2>/dev/null || true

            # Rewrite config with new connection (preserve order)
            local conf="$INSTALL_DIR/servers.conf"
            local tmp="${conf}.tmp.$$"
            sed "s#^${target_label}|.*#${target_label}|${new_conn}|${target_auth}#" "$conf" > "$tmp" 2>/dev/null
            if [ -s "$tmp" ]; then mv -f "$tmp" "$conf"; chmod 600 "$conf" 2>/dev/null || true
            else rm -f "$tmp"; echo -e "${RED}  ✗ Config update failed.${NC}"; return 1; fi

            echo -e "  ${GREEN}✓ Connection updated for '${target_label}': ${new_conn}${NC}"
            ;;
        0|"") return ;;
        *) echo -e "${RED}  Invalid choice.${NC}" ;;
    esac
}

list_servers() {
    load_servers
    if [ "$SERVER_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}  No remote servers configured.${NC}"
        echo -e "  Add one with: ${CYAN}conduit add-server${NC}"
        return
    fi
    echo -e "${CYAN}═══ CONFIGURED SERVERS ═══${NC}"
    echo ""
    printf "  ${BOLD}%-4s %-20s %-28s %s${NC}\n" "#" "LABEL" "CONNECTION" "AUTH"
    printf "  %-4s %-20s %-28s %s\n" "──" "────────────────────" "────────────────────────────" "────"
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local atype="${SERVER_AUTHS[$i]:-key}"
        if [ "$atype" = "pass" ]; then
            atype="${YELLOW}pass${NC}"
        else
            atype="${GREEN}key${NC}"
        fi
        printf "  %-4d %-20s %-28s %b\n" "$((i + 1))" "${SERVER_LABELS[$i]}" "${SERVER_CONNS[$i]}" "$atype"
    done
    echo ""
}

show_server_management_submenu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo -e "  ${BOLD}REMOTE SERVERS${NC}"
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "  1. 📋 List servers"
            echo -e "  2. ➕ Add server"
            echo -e "  3. ✏️  Edit server"
            echo -e "  4. ➖ Remove server"
            echo ""
            echo -e "  0. ← Back"
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo ""
            redraw=false
        fi
        read -p "  Enter choice: " choice < /dev/tty || return
        case "$choice" in
            1)
                list_servers
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty || true
                redraw=true
                ;;
            2)
                add_server_interactive
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty || true
                redraw=true
                ;;
            3)
                edit_server_interactive
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty || true
                redraw=true
                ;;
            4)
                remove_server_interactive
                read -n 1 -s -r -p "  Press any key to continue..." < /dev/tty || true
                redraw=true
                ;;
            0|"") return ;;
            *) echo -e "${RED}  Invalid choice.${NC}" ;;
        esac
    done
}

# SSH wrapper with ControlMaster for persistent connections
ssh_cmd() {
    local label="$1"
    shift
    local remote_cmd="$*"

    local conn="" auth_type="key"
    # Requires load_servers() called beforehand
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        if [ "${SERVER_LABELS[$i]}" = "$label" ]; then
            conn="${SERVER_CONNS[$i]}"
            auth_type="${SERVER_AUTHS[$i]:-key}"
            break
        fi
    done
    if [ -z "$conn" ]; then
        echo "ERROR: Server '$label' not found" >&2
        return 1
    fi

    local ssh_host ssh_port
    if [[ "$conn" == *:* ]]; then
        ssh_host="${conn%:*}"
        ssh_port="${conn##*:}"
    else
        ssh_host="$conn"
        ssh_port=22
    fi

    # If SSH user is not root, prefix command with sudo
    local ssh_user="${ssh_host%%@*}"
    if [ "$ssh_user" != "root" ] && [ -n "$remote_cmd" ]; then
        remote_cmd="sudo $remote_cmd"
    fi

    local sock="/tmp/conduit-ssh-${label}.sock"

    if [ "$auth_type" = "pass" ]; then
        # If ControlMaster socket is alive, reuse it (skip sshpass + decrypt)
        if [ -S "$sock" ] && ssh -O check -o "ControlPath=$sock" dummy 2>/dev/null; then
            ssh -o ControlMaster=auto \
                -o "ControlPath=$sock" \
                -o ControlPersist=300 \
                -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=accept-new \
                -p "$ssh_port" \
                "$ssh_host" \
                "$remote_cmd"
        else
            if ! command -v sshpass &>/dev/null; then
                echo "ERROR: sshpass not installed (required for password auth)" >&2
                return 1
            fi
            local _pw
            _pw=$(_load_cred "$label")
            if [ -z "$_pw" ]; then
                echo "ERROR: No stored password for '$label'" >&2
                return 1
            fi
            SSHPASS="$_pw" sshpass -e \
                ssh -o ControlMaster=auto \
                    -o "ControlPath=$sock" \
                    -o ControlPersist=300 \
                    -o ConnectTimeout=5 \
                    -o StrictHostKeyChecking=accept-new \
                    -o PubkeyAuthentication=no \
                    -p "$ssh_port" \
                    "$ssh_host" \
                    "$remote_cmd"
        fi
    else
        ssh -o ControlMaster=auto \
            -o "ControlPath=$sock" \
            -o ControlPersist=300 \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new \
            -o BatchMode=yes \
            -p "$ssh_port" \
            "$ssh_host" \
            "$remote_cmd"
    fi
}

ssh_cmd_bg() {
    local label="$1"
    local remote_cmd="$2"
    local outfile="$3"
    # 15s timeout to prevent hung servers from freezing dashboard
    ssh_cmd "$label" "$remote_cmd" > "$outfile" 2>/dev/null &
    local pid=$!
    ( sleep 15 && kill $pid 2>/dev/null ) &
    local tpid=$!
    wait $pid 2>/dev/null
    kill $tpid 2>/dev/null
    wait $tpid 2>/dev/null
}

ssh_close_all() {
    for sock in /tmp/conduit-ssh-*.sock; do
        [ -e "$sock" ] && ssh -O exit -o "ControlPath=$sock" dummy 2>/dev/null || true
    done
}

json_str() {
    local key="$1" raw="$2"
    local val
    val=$(echo "$raw" | sed -n "s/.*\"${key}\":\"\([^\"]*\)\".*/\1/p")
    echo "${val:--}"
}
json_num() {
    local key="$1" raw="$2"
    local val
    val=$(echo "$raw" | sed -n "s/.*\"${key}\":\([0-9]*\).*/\1/p")
    echo "${val:-0}"
}

# _jparse: zero-fork JSON parser via printf -v
# Usage: _jparse "VARNAME" "json_key" "$json_string" "s|n"
_jparse() {
    local _var="$1" _k="$2" _j="$3" _t="${4:-s}"
    local _r="${_j#*\"${_k}\":}"
    if [ "$_r" = "$_j" ]; then
        # Key not found
        [ "$_t" = "s" ] && printf -v "$_var" '%s' "-" || printf -v "$_var" '%s' "0"
        return
    fi
    if [ "$_t" = "s" ]; then
        _r="${_r#\"}"
        _r="${_r%%\"*}"
        [ -z "$_r" ] && _r="-"
    else
        _r="${_r%%[,\}]*}"
        _r="${_r//[!0-9]/}"
        [ -z "$_r" ] && _r="0"
    fi
    printf -v "$_var" '%s' "$_r"
}

# _fmt_bytes: zero-fork byte formatter via printf -v
_fmt_bytes() {
    local _var="$1" _b="${2:-0}"
    if [ -z "$_b" ] || [ "$_b" -eq 0 ] 2>/dev/null; then
        printf -v "$_var" '0 B'
        return
    fi
    if [ "$_b" -ge 1099511627776 ] 2>/dev/null; then
        local _w=$((_b / 1099511627776))
        local _f=$(( (_b % 1099511627776) * 100 / 1099511627776 ))
        printf -v "$_var" '%d.%02d TB' "$_w" "$_f"
    elif [ "$_b" -ge 1073741824 ] 2>/dev/null; then
        local _w=$((_b / 1073741824))
        local _f=$(( (_b % 1073741824) * 100 / 1073741824 ))
        printf -v "$_var" '%d.%02d GB' "$_w" "$_f"
    elif [ "$_b" -ge 1048576 ] 2>/dev/null; then
        local _w=$((_b / 1048576))
        local _f=$(( (_b % 1048576) * 100 / 1048576 ))
        printf -v "$_var" '%d.%02d MB' "$_w" "$_f"
    elif [ "$_b" -ge 1024 ] 2>/dev/null; then
        local _w=$((_b / 1024))
        local _f=$(( (_b % 1024) * 100 / 1024 ))
        printf -v "$_var" '%d.%02d KB' "$_w" "$_f"
    else
        printf -v "$_var" '%s B' "$_b"
    fi
}

show_multi_dashboard() {
    load_servers

    local stop_dash=0
    local _md_cleanup=""
    local _bd_cleanup=""
    _dash_cleanup() {
        stop_dash=1
        [ -n "$_md_cleanup" ] && [ -d "$_md_cleanup" ] && rm -rf "$_md_cleanup"
        [ -n "$_bd_cleanup" ] && [ -d "$_bd_cleanup" ] && rm -rf "$_bd_cleanup"
    }
    trap '_dash_cleanup' SIGINT SIGTERM SIGHUP SIGQUIT

    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    clear

    local EL="\033[K"
    local last_refresh=0
    local cycle_start=$SECONDS
    local REFRESH_INTERVAL=20
    local si key

    declare -a SRV_STATUS SRV_CTOTAL SRV_RUNNING SRV_PEERS SRV_CING
    declare -a SRV_UP_B SRV_DN_B
    declare -a SRV_CPU SRV_RAM SRV_TEMP SRV_UPTIME SRV_RAW
    declare -a SRV_DATA_H SRV_DATA_B SRV_UIPS

    local L_STATUS="-" L_HOSTNAME="-" L_CTOTAL="0" L_RUNNING="0"
    local L_PEERS="0" L_CING="0" L_UP_B="0" L_DN_B="0"
    local L_CPU="-" L_RAM="-"
    local L_RAM_TOTAL="-" L_TEMP="-" L_UPTIME="-"
    local L_DATA_BYTES="0" L_UNIQUE_IPS="0"

    local g_peers=0 g_ctotal=0 g_running=0 g_up=0 g_dn=0
    local g_data_bytes=0 g_ips=0

    while [ $stop_dash -eq 0 ]; do
        local now=$SECONDS
        local cycle_elapsed=$(( (now - cycle_start) % REFRESH_INTERVAL ))
        local time_left=$((REFRESH_INTERVAL - cycle_elapsed))

        # === DATA FETCH ===
        if [ $((now - last_refresh)) -ge $REFRESH_INTERVAL ] || [ "$last_refresh" -eq 0 ]; then
            last_refresh=$now
            cycle_start=$now

            local _md=$(mktemp -d /tmp/.conduit_md.XXXXXX)
            _md_cleanup="$_md"

            # Fetch local + all remote servers in parallel
            status_json > "$_md/local" 2>/dev/null &
            for ((si=0; si<SERVER_COUNT; si++)); do
                ssh_cmd_bg "${SERVER_LABELS[$si]}" "conduit status --json" "$_md/srv_$si" &
            done
            wait

            # Reset totals
            g_peers=0; g_ctotal=0; g_running=0; g_up=0; g_dn=0; g_data_bytes=0; g_ips=0

            # Parse local server data
            local lraw=""
            [ -f "$_md/local" ] && lraw=$(<"$_md/local")
            if [ -n "$lraw" ] && [[ "$lraw" == *'"status"'* ]]; then
                _jparse L_STATUS    "status"         "$lraw" s
                _jparse L_HOSTNAME  "hostname"       "$lraw" s
                _jparse L_CTOTAL    "total"          "$lraw" n
                _jparse L_RUNNING   "running"        "$lraw" n
                _jparse L_PEERS     "connected"      "$lraw" n
                _jparse L_CING      "connecting"     "$lraw" n
                _jparse L_UP_B      "tracker_out_bytes" "$lraw" n
                _jparse L_DN_B      "tracker_in_bytes"  "$lraw" n
                _jparse L_CPU       "sys_cpu"        "$lraw" s
                _jparse L_RAM       "sys_ram_used"   "$lraw" s
                _jparse L_RAM_TOTAL "sys_ram_total"  "$lraw" s
                _jparse L_TEMP      "sys_temp"       "$lraw" s
                _jparse L_UPTIME    "uptime"         "$lraw" s
                _jparse L_DATA_BYTES  "data_served_bytes" "$lraw" n
                _jparse L_UNIQUE_IPS  "unique_ips"        "$lraw" n
            else
                L_STATUS="offline"; L_HOSTNAME="-"; L_CTOTAL="0"; L_RUNNING="0"
                L_PEERS="0"; L_CING="0"; L_UP_B="0"; L_DN_B="0"; L_CPU="-"; L_RAM="-"
                L_RAM_TOTAL="-"; L_TEMP="-"; L_UPTIME="-"
                L_DATA_BYTES="0"; L_UNIQUE_IPS="0"
            fi

            # Add local to totals
            g_peers=$((g_peers + ${L_PEERS:-0}))
            g_ctotal=$((g_ctotal + ${L_CTOTAL:-0}))
            g_running=$((g_running + ${L_RUNNING:-0}))
            g_up=$((g_up + ${L_UP_B:-0}))
            g_dn=$((g_dn + ${L_DN_B:-0}))
            g_data_bytes=$((g_data_bytes + ${L_DATA_BYTES:-0}))
            g_ips=$((g_ips + ${L_UNIQUE_IPS:-0}))

            # Parse remote server results
            for ((si=0; si<SERVER_COUNT; si++)); do
                local raw=""
                [ -f "$_md/srv_$si" ] && raw=$(<"$_md/srv_$si")
                SRV_RAW[$si]="$raw"

                if [ -n "$raw" ] && [[ "$raw" == *'"status"'* ]]; then
                    _jparse "SRV_STATUS[$si]"  "status"         "$raw" s
                    _jparse "SRV_CTOTAL[$si]"  "total"          "$raw" n
                    _jparse "SRV_RUNNING[$si]" "running"        "$raw" n
                    _jparse "SRV_PEERS[$si]"   "connected"      "$raw" n
                    _jparse "SRV_CING[$si]"    "connecting"     "$raw" n
                    _jparse "SRV_UP_B[$si]"    "tracker_out_bytes" "$raw" n
                    _jparse "SRV_DN_B[$si]"    "tracker_in_bytes"  "$raw" n
                    _jparse "SRV_CPU[$si]"     "sys_cpu"        "$raw" s
                    _jparse "SRV_TEMP[$si]"    "sys_temp"       "$raw" s
                    _jparse "SRV_RAM[$si]"     "sys_ram_used"   "$raw" s
                    _jparse "SRV_UPTIME[$si]"  "uptime"         "$raw" s
                    _jparse "SRV_DATA_H[$si]" "data_served_human" "$raw" s
                    _jparse "SRV_DATA_B[$si]" "data_served_bytes" "$raw" n
                    _jparse "SRV_UIPS[$si]"   "unique_ips"        "$raw" n

                    g_peers=$((g_peers + ${SRV_PEERS[$si]:-0}))
                    g_ctotal=$((g_ctotal + ${SRV_CTOTAL[$si]:-0}))
                    g_running=$((g_running + ${SRV_RUNNING[$si]:-0}))
                    g_up=$((g_up + ${SRV_UP_B[$si]:-0}))
                    g_dn=$((g_dn + ${SRV_DN_B[$si]:-0}))
                    g_data_bytes=$((g_data_bytes + ${SRV_DATA_B[$si]:-0}))
                    g_ips=$((g_ips + ${SRV_UIPS[$si]:-0}))
                else
                    SRV_STATUS[$si]="offline"
                    SRV_CTOTAL[$si]="0"
                    SRV_RUNNING[$si]="0"
                    SRV_PEERS[$si]="0"
                    SRV_CING[$si]="0"
                    SRV_UP_B[$si]="0"
                    SRV_DN_B[$si]="0"
                    SRV_CPU[$si]="-"
                    SRV_TEMP[$si]="-"
                    SRV_RAM[$si]="-"
                    SRV_UPTIME[$si]="-"
                    SRV_DATA_H[$si]="-"
                    SRV_DATA_B[$si]="0"
                    SRV_UIPS[$si]="0"
                fi
            done
            rm -rf "$_md"
            _md_cleanup=""
        fi

        printf "\033[H"

        local _hbar _hrest
        printf -v _hbar '%*s' "$cycle_elapsed" ''; _hbar="${_hbar// /●}"
        printf -v _hrest '%*s' "$time_left" ''; _hrest="${_hrest// /○}"
        _hbar+="$_hrest"
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}${EL}"
        printf "${CYAN}║${NC}  ${BOLD}CONDUIT MULTI-SERVER DASHBOARD${NC}%*s${YELLOW}[%s]${NC} %2ds  ${GREEN}[LIVE]${NC}\033[80G${CYAN}║${NC}${EL}\n" 10 "" "$_hbar" "$time_left"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════╣${NC}${EL}"

        local l_sc l_sd
        case "$L_STATUS" in
            running)  l_sc="${GREEN}"; l_sd="● OK  " ;;
            degraded) l_sc="${YELLOW}"; l_sd="● WARN" ;;
            stopped)  l_sc="${RED}"; l_sd="● STOP" ;;
            *)        l_sc="${RED}"; l_sd="● DOWN" ;;
        esac
        printf "${CYAN}║${NC}  ${BOLD}★ LOCAL${NC} %-14.14s %b%-6s${NC} │ %3s/%-3s ctr %4s peers │ CPU ${YELLOW}%-6.6s${NC}  ${CYAN}%-5.5s${NC}\033[80G${CYAN}║${NC}${EL}\n" \
            "$L_HOSTNAME" "$l_sc" "$l_sd" \
            "$L_RUNNING" "$L_CTOTAL" "$L_PEERS" "$L_CPU" "$L_TEMP"
        local _trk_h="-"
        [ "${L_DATA_BYTES:-0}" -gt 0 ] 2>/dev/null && _fmt_bytes _trk_h "$L_DATA_BYTES"
        printf "${CYAN}║${NC}  Srvd ${GREEN}%-10.10s${NC} │ Uptime ${CYAN}%-11.11s${NC}\033[80G${CYAN}║${NC}${EL}\n" \
            "$_trk_h" "$L_UPTIME"

        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════╣${NC}${EL}"

        local g_up_h g_dn_h g_data_h
        _fmt_bytes g_up_h "$g_up"
        _fmt_bytes g_dn_h "$g_dn"
        _fmt_bytes g_data_h "$g_data_bytes"
        local total_servers=$((SERVER_COUNT + 1))
        local _t_trk="" _t_trk_c=""
        if [ "${g_data_bytes:-0}" -gt 0 ] 2>/dev/null; then
            local _t_try
            printf -v _t_try "  TOTALS: %d svr │ %d/%d ctr │ %d peers │ ↑%s ↓%s │ Srvd %s IPs %s" \
                "$total_servers" "$g_running" "$g_ctotal" "$g_peers" "$g_up_h" "$g_dn_h" "$g_data_h" "$g_ips"
            if [ ${#_t_try} -le 78 ]; then
                _t_trk=" │ Srvd ${g_data_h} IPs ${g_ips}"
                _t_trk_c=" │ Srvd ${CYAN}${g_data_h}${NC} IPs ${CYAN}${g_ips}${NC}"
            else
                _t_trk=" │ Srvd ${g_data_h}"
                _t_trk_c=" │ Srvd ${CYAN}${g_data_h}${NC}"
            fi
        fi
        printf "${CYAN}║${NC}  TOTALS: ${GREEN}%d${NC} svr │ ${GREEN}%d${NC}/%d ctr │ ${GREEN}%d${NC} peers │ ↑${CYAN}%s${NC} ↓${CYAN}%s${NC}%b\033[80G${CYAN}║${NC}${EL}\n" \
            "$total_servers" "$g_running" "$g_ctotal" "$g_peers" "$g_up_h" "$g_dn_h" "$_t_trk_c"

        if [ "$SERVER_COUNT" -gt 0 ]; then
            echo -e "${CYAN}╠══╤════════════╤════════╤═════════╤══════════╤══════════╤═══════════╤═════════╣${NC}${EL}"
            printf "${CYAN}║${NC}${BOLD}# │ SERVER     │ STATUS │ CNT/PER │ UPLOAD   │ DNLOAD   │ CPU(TEMP) │ SERVED  ${NC}\033[80G${CYAN}║${NC}${EL}\n"
            echo -e "${CYAN}╠══╪════════════╪════════╪═════════╪══════════╪══════════╪═══════════╪═════════╣${NC}${EL}"

            for ((si=0; si<SERVER_COUNT; si++)); do
                local num=$((si + 1))
                local label="${SERVER_LABELS[$si]}"
                local st="${SRV_STATUS[$si]}"
                local sc sd

                case "$st" in
                    running)  sc="${GREEN}"; sd="● OK  " ;;
                    degraded) sc="${YELLOW}"; sd="● WARN" ;;
                    stopped)  sc="${RED}"; sd="● STOP" ;;
                    offline)  sc="${RED}"; sd="● DOWN" ;;
                    *)        sc="${DIM}"; sd="  N/A " ;;
                esac

                local ctnr_peer="${SRV_RUNNING[$si]}/${SRV_PEERS[$si]}"
                local _srv_up_h; _fmt_bytes _srv_up_h "${SRV_UP_B[$si]:-0}"
                local _srv_dn_h; _fmt_bytes _srv_dn_h "${SRV_DN_B[$si]:-0}"
                local cpu="${SRV_CPU[$si]}"
                local temp="${SRV_TEMP[$si]}"
                local cpu_temp="$cpu"
                if [ "$temp" != "-" ]; then
                    local temp_num="${temp%%°*}"
                    cpu_temp="${cpu}(${temp_num})"
                fi
                local served="${SRV_DATA_H[$si]:-"-"}"

                printf "${CYAN}║${NC}%d │ %-10.10s │ %b%-6s${NC} │ %-7.7s │ %-8.8s │ %-8.8s │ %-9s │ %-7.7s\033[80G${CYAN}║${NC}${EL}\n" \
                    "$num" "$label" "$sc" "$sd" \
                    "$ctnr_peer" "$_srv_up_h" "$_srv_dn_h" "$cpu_temp" "$served"
            done
            echo -e "${CYAN}╚══╧════════════╧════════╧═════════╧══════════╧══════════╧═══════════╧═════════╝${NC}${EL}"
        else
            echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}${EL}"
            printf " ${DIM}No remote servers. Add with: conduit add-server${NC}${EL}\n"
        fi

        printf " ${DIM}[q]${NC}Quit ${DIM}[r]${NC}Refresh ${DIM}[1-9]${NC}Server ${DIM}[R]${NC}estart ${DIM}[S]${NC}top ${DIM}[T]${NC}start ${DIM}[U]${NC}pdate ${DIM}[M]${NC}anage${EL}\n"
        printf " Enter choice: "
        printf "\033[J"
        echo -ne "\033[?25h"

        # Keypress handling
        if read -t 1 -n 1 -s key < /dev/tty 2>/dev/null; then
            echo -ne "\033[?25l"
            case "$key" in
                q|Q) stop_dash=1 ;;
                r)   last_refresh=0 ;;
                R)   [ "$SERVER_COUNT" -gt 0 ] && { _bulk_action_all "restart"; last_refresh=0; } ;;
                S)   [ "$SERVER_COUNT" -gt 0 ] && { _bulk_action_all "stop"; last_refresh=0; } ;;
                T)   [ "$SERVER_COUNT" -gt 0 ] && { _bulk_action_all "start"; last_refresh=0; } ;;
                U)   [ "$SERVER_COUNT" -gt 0 ] && { _bulk_action_all "update"; last_refresh=0; } ;;
                M|m) _dashboard_server_mgmt; last_refresh=0 ;;
                [1-9])
                    local idx=$((key - 1))
                    if [ "$idx" -lt "$SERVER_COUNT" ]; then
                        _server_actions "$idx"
                        last_refresh=0
                    fi
                    ;;
            esac
        fi
        echo -ne "\033[?25l"
    done

    echo -ne "\033[?25h"
    tput rmcup 2>/dev/null || true
    ssh_close_all
    trap - SIGINT SIGTERM SIGHUP SIGQUIT
}

_dashboard_server_mgmt() {
    # Exit TUI temporarily
    echo -ne "\033[?25h"
    tput rmcup 2>/dev/null || true

    local mgmt_key _mi
    while true; do
        clear
        echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${BOLD}SERVER MANAGEMENT${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo ""
        if [ ${#SERVER_LABELS[@]} -gt 0 ]; then
            echo -e "  ${BOLD}Current servers:${NC}"
            for _mi in "${!SERVER_LABELS[@]}"; do
                echo -e "    $((_mi+1)). ${SERVER_LABELS[$_mi]} (${SERVER_CONNS[$_mi]})"
            done
        else
            echo -e "  ${DIM}No remote servers configured${NC}"
        fi
        echo ""
        echo -e "  ${GREEN}[a]${NC} Add server"
        echo -e "  ${GREEN}[e]${NC} Edit server"
        echo -e "  ${GREEN}[r]${NC} Remove server"
        echo -e "  ${GREEN}[b]${NC} Back to dashboard"
        echo ""
        read -n 1 -s -p "  Choose: " mgmt_key < /dev/tty || break

        case "$mgmt_key" in
            a|A)
                echo ""
                if [ ${#SERVER_LABELS[@]} -ge 9 ]; then
                    echo -e "  ${YELLOW}⚠ Maximum 9 servers reached${NC}"
                    sleep 2
                else
                    add_server_interactive
                    load_servers
                    SERVER_COUNT=${#SERVER_LABELS[@]}
                fi
                ;;
            e|E)
                echo ""
                if [ ${#SERVER_LABELS[@]} -eq 0 ]; then
                    echo -e "  ${YELLOW}No servers to edit${NC}"
                    sleep 1
                else
                    edit_server_interactive
                    load_servers
                    SERVER_COUNT=${#SERVER_LABELS[@]}
                fi
                ;;
            r|R)
                echo ""
                if [ ${#SERVER_LABELS[@]} -eq 0 ]; then
                    echo -e "  ${YELLOW}No servers to remove${NC}"
                    sleep 1
                else
                    remove_server_interactive
                    load_servers
                    SERVER_COUNT=${#SERVER_LABELS[@]}
                fi
                ;;
            b|B|"") break ;;
        esac
    done

    # Re-enter TUI
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
}

_server_actions() {
    local idx=$1
    local label="${SERVER_LABELS[$idx]}"
    local conn="${SERVER_CONNS[$idx]}"

    echo -ne "\033[?25h"
    clear

    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}SERVER: ${GREEN}${label}${NC}  (${conn})"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  1. 🔁 Restart Conduit"
    echo -e "  2. ⏹️  Stop Conduit"
    echo -e "  3. ▶️  Start Conduit"
    echo -e "  4. 🔄 Update Conduit"
    echo -e "  5. 🩺 Health Check"
    echo -e "  6. 📋 View Logs (last 50 lines)"
    echo -e "  7. 📊 Quick Status"
    echo ""
    echo -e "  ${DIM}[b] Back to dashboard${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -p "  Enter choice: " choice < /dev/tty || { echo -ne "\033[?25l"; clear; return; }

    local remote_cmd=""
    case "$choice" in
        1) remote_cmd="conduit restart" ;;
        2) remote_cmd="conduit stop" ;;
        3) remote_cmd="conduit start" ;;
        4) remote_cmd="conduit update" ;;
        5) remote_cmd="conduit health" ;;
        6) remote_cmd="conduit logs" ;;
        7) remote_cmd="conduit status" ;;
        b|B|"") echo -ne "\033[?25l"; clear; return ;;
        *) echo -e "${RED}  Invalid choice.${NC}"; sleep 1; echo -ne "\033[?25l"; clear; return ;;
    esac

    echo ""
    echo -e "  ${CYAN}Executing on ${label}...${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo ""

    # Run with 60s timeout to prevent hung servers from freezing the TUI
    ssh_cmd "$label" "$remote_cmd" 2>&1 &
    local _cmd_pid=$!
    ( sleep 60 && kill $_cmd_pid 2>/dev/null ) &
    local _timer_pid=$!
    wait $_cmd_pid 2>/dev/null
    local _cmd_rc=$?
    kill $_timer_pid 2>/dev/null
    wait $_timer_pid 2>/dev/null
    [ "$_cmd_rc" -eq 143 ] && echo -e "\n  ${YELLOW}⚠ Command timed out after 60s.${NC}"

    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    read -n 1 -s -r -p "  Press any key to return to dashboard..." < /dev/tty || true

    echo -ne "\033[?25l"
    clear
}

_bulk_action_all() {
    local action="$1"
    local action_display

    case "$action" in
        restart) action_display="Restarting" ;;
        stop)    action_display="Stopping" ;;
        start)   action_display="Starting" ;;
        update)  action_display="Updating" ;;
        *)       return ;;
    esac

    echo -ne "\033[?25h"
    clear

    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}BULK ACTION: ${YELLOW}${action_display} all servers${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""

    load_servers

    read -p "  ${action_display} all ${SERVER_COUNT} remote servers? (y/n): " confirm < /dev/tty || { echo -ne "\033[?25l"; return; }
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo -ne "\033[?25l"; return; }

    echo ""

    local _bd=$(mktemp -d /tmp/.conduit_bulk.XXXXXX)
    _bd_cleanup="$_bd"
    for si in $(seq 0 $((SERVER_COUNT - 1))); do
        echo -e "  ${DIM}${action_display} ${SERVER_LABELS[$si]}...${NC}"
        ssh_cmd_bg "${SERVER_LABELS[$si]}" "conduit $action" "$_bd/result_$si" &
    done
    wait

    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}RESULTS:${NC}"
    echo ""
    for si in $(seq 0 $((SERVER_COUNT - 1))); do
        local label="${SERVER_LABELS[$si]}"
        if [ -f "$_bd/result_$si" ] && [ -s "$_bd/result_$si" ]; then
            echo -e "  ${GREEN}✓${NC} ${label}: OK"
        else
            echo -e "  ${RED}✗${NC} ${label}: FAILED (unreachable or error)"
        fi
    done
    rm -rf "$_bd"
    _bd_cleanup=""

    echo ""
    read -n 1 -s -r -p "  Press any key to return to dashboard..." < /dev/tty || true
    echo -ne "\033[?25l"
    clear
}

update_geoip() {
    echo -e "${CYAN}═══ UPDATE GEOIP DATABASE ═══${NC}"
    echo ""
    local geoip_dir="/usr/share/GeoIP"
    local geoip_file="$geoip_dir/GeoLite2-Country.mmdb"
    local geoip_url="https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-Country.mmdb"

    mkdir -p "$geoip_dir" 2>/dev/null
    echo -e "Downloading GeoLite2-Country.mmdb..."
    local tmp_mmdb="/tmp/GeoLite2-Country.mmdb.$$"
    if curl -fsSL --max-time 60 --max-filesize 10485760 -o "$tmp_mmdb" "$geoip_url" 2>/dev/null; then
        local fsize=$(stat -c %s "$tmp_mmdb" 2>/dev/null || stat -f %z "$tmp_mmdb" 2>/dev/null || echo 0)
        if [ "$fsize" -gt 1048576 ] 2>/dev/null; then
            mv "$tmp_mmdb" "$geoip_file"
            chmod 644 "$geoip_file"
            local fsize_mb=$(awk "BEGIN{printf \"%.1f\", $fsize/1048576}")
            echo -e "${GREEN}✓ GeoIP database updated (${fsize_mb}MB)${NC}"
        else
            rm -f "$tmp_mmdb"
            echo -e "${RED}✗ Downloaded file too small (${fsize} bytes), possibly corrupt${NC}"
            return 1
        fi
    else
        rm -f "$tmp_mmdb" 2>/dev/null
        echo -e "${RED}✗ Failed to download GeoIP database${NC}"
        return 1
    fi
}

# Command line interface
show_help() {
    echo "Usage: conduit [command]"
    echo ""
    echo "Commands:"
    echo "  status       Show current status (--json for machine-readable)"
    echo "  stats        View live statistics"
    echo "  logs         View raw Docker logs"
    echo "  health       Run health check on Conduit container"
    echo "  start        Start Conduit container"
    echo "  stop         Stop Conduit container"
    echo "  restart      Restart Conduit container"
    echo "  update       Update to latest Conduit image"
    echo "  settings     Change max-clients/bandwidth"
    echo "  scale        Scale containers (1+)"
    echo "  backup       Backup Conduit node identity key"
    echo "  restore      Restore Conduit node identity from backup"
    echo "  update-geoip Update GeoIP database"
    echo "  dashboard    Open multi-server dashboard"
    echo "  add-server   Add a remote server"
    echo "  edit-server  Edit server credentials or connection"
    echo "  remove-server Remove a configured remote server"
    echo "  servers      List configured remote servers"
    echo "  snowflake    Manage Snowflake proxy (status|start|stop|restart)"
    echo "  uninstall    Remove everything (container, data, service)"
    echo "  menu         Open interactive menu (default)"
    echo "  version      Show version information"
    echo "  about        About Psiphon Conduit"
    echo "  info         Dashboard metrics explained"
    echo "  help         Show this help"
}

show_version() {
    echo "Conduit Manager v${VERSION}"
    echo "Image: ${CONDUIT_IMAGE}"

    # Show actual running image digest if available
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        local actual=$(docker inspect --format='{{index .RepoDigests 0}}' "$CONDUIT_IMAGE" 2>/dev/null | grep -o 'sha256:[a-f0-9]*')
        if [ -n "$actual" ]; then
            echo "Running Digest:  ${actual}"
        fi
    fi

    # Show Snowflake image info if enabled
    if [ "${SNOWFLAKE_ENABLED:-false}" = "true" ]; then
        echo ""
        echo "Snowflake Image: ${SNOWFLAKE_IMAGE}"
        if docker ps 2>/dev/null | grep -q "snowflake-proxy"; then
            local sf_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$SNOWFLAKE_IMAGE" 2>/dev/null | grep -o 'sha256:[a-f0-9]*')
            if [ -n "$sf_digest" ]; then
                echo "Running Digest:  ${sf_digest}"
            fi
        fi
    fi
}

health_check() {
    echo -e "${CYAN}═══ CONDUIT HEALTH CHECK ═══${NC}"
    echo ""

    local all_ok=true

    # 1. Check if Docker is running
    echo -n "Docker daemon:        "
    if docker info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Docker is not running"
        all_ok=false
    fi

    # 2-5. Check each container
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        local vname=$(get_volume_name $i)

        if [ "$CONTAINER_COUNT" -gt 1 ]; then
            echo ""
            echo -e "${CYAN}--- ${cname} ---${NC}"
        fi

        echo -n "Container exists:     "
        if docker ps -a 2>/dev/null | grep -q "[[:space:]]${cname}$"; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC} - Container not found"
            all_ok=false
        fi

        echo -n "Container running:    "
        if docker ps 2>/dev/null | grep -q "[[:space:]]${cname}$"; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC} - Container is stopped"
            all_ok=false
        fi

        echo -n "Restart count:        "
        local restarts=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null)
        if [ -n "$restarts" ]; then
            if [ "$restarts" -eq 0 ]; then
                echo -e "${GREEN}${restarts}${NC} (healthy)"
            elif [ "$restarts" -lt 5 ]; then
                echo -e "${YELLOW}${restarts}${NC} (some restarts)"
            else
                echo -e "${RED}${restarts}${NC} (excessive restarts)"
                all_ok=false
            fi
        else
            echo -e "${YELLOW}N/A${NC}"
        fi

        # Single docker logs call for network + stats checks
        local hc_logs=$(docker logs --tail 100 "$cname" 2>&1)
        local hc_stats_lines=$(echo "$hc_logs" | grep "\[STATS\]" || true)
        local hc_stats_count=0
        if [ -n "$hc_stats_lines" ]; then
            hc_stats_count=$(echo "$hc_stats_lines" | wc -l | tr -d ' ')
        fi
        hc_stats_count=${hc_stats_count:-0}
        local hc_last_stat=$(echo "$hc_stats_lines" | tail -1)
        local hc_connected=$(echo "$hc_last_stat" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p' | head -1 | tr -d '\n')
        hc_connected=${hc_connected:-0}
        local hc_connecting=$(echo "$hc_last_stat" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p' | head -1 | tr -d '\n')
        hc_connecting=${hc_connecting:-0}

        echo -n "Network connection:   "
        if [ "$hc_connected" -gt 0 ] 2>/dev/null; then
            echo -e "${GREEN}OK${NC} (${hc_connected} peers connected, ${hc_connecting} connecting)"
        elif [ "$hc_stats_count" -gt 0 ] 2>/dev/null; then
            if [ "$hc_connecting" -gt 0 ] 2>/dev/null; then
                echo -e "${GREEN}OK${NC} (Connected, ${hc_connecting} peers connecting)"
            else
                echo -e "${GREEN}OK${NC} (Connected, awaiting peers)"
            fi
        elif echo "$hc_logs" | grep -q "\[OK\] Connected to Psiphon network"; then
            echo -e "${GREEN}OK${NC} (Connected, no stats available)"
        else
            local info_lines=0
            if [ -n "$hc_logs" ]; then
                info_lines=$(echo "$hc_logs" | grep "\[INFO\]" | wc -l | tr -d ' ')
            fi
            info_lines=${info_lines:-0}
            if [ "$info_lines" -gt 0 ] 2>/dev/null; then
                echo -e "${YELLOW}CONNECTING${NC} - Establishing connection..."
            else
                echo -e "${YELLOW}WAITING${NC} - Starting up..."
            fi
        fi

        echo -n "Stats output:         "
        if [ "$hc_stats_count" -gt 0 ] 2>/dev/null; then
            echo -e "${GREEN}OK${NC} (${hc_stats_count} entries)"
        else
            echo -e "${YELLOW}NONE${NC} - Run 'conduit restart' to enable"
        fi

        echo -n "Data volume:          "
        if docker volume inspect "$vname" &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC} - Volume not found"
            all_ok=false
        fi

        echo -n "Network (host mode):  "
        local network_mode=$(docker inspect --format='{{.HostConfig.NetworkMode}}' "$cname" 2>/dev/null)
        if [ "$network_mode" = "host" ]; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}WARN${NC} - Not using host network mode"
        fi
    done

    # Node key check (only on first volume)
    if [ "$CONTAINER_COUNT" -gt 1 ]; then
        echo ""
        echo -e "${CYAN}--- Shared ---${NC}"
    fi
    echo -n "Node identity key:    "
    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)
    local key_found=false
    if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
        key_found=true
    else
        # Snap Docker fallback: check via docker cp
        local tmp_ctr="conduit-health-tmp"
        docker rm -f "$tmp_ctr" 2>/dev/null || true
        if docker create --name "$tmp_ctr" -v conduit-data:/data alpine true 2>/dev/null; then
            if docker cp "$tmp_ctr:/data/conduit_key.json" - >/dev/null 2>&1; then
                key_found=true
            fi
            docker rm -f "$tmp_ctr" 2>/dev/null || true
        fi
    fi
    if [ "$key_found" = true ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}PENDING${NC} - Will be created on first run"
    fi

    # Tracker service check
    echo ""
    echo -e "${CYAN}--- Tracker ---${NC}"
    echo -n "Tracker service:      "
    if is_tracker_active; then
        echo -e "${GREEN}OK${NC} (active)"
    else
        echo -e "${RED}FAILED${NC} - Tracker service not running"
        echo -e "         Fix: Settings → Restart tracker (option r)"
        all_ok=false
    fi

    echo -n "tcpdump installed:    "
    if command -v tcpdump &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - tcpdump not found (tracker won't work)"
        all_ok=false
    fi

    echo -n "GeoIP available:      "
    if command -v geoiplookup &>/dev/null; then
        echo -e "${GREEN}OK${NC} (geoiplookup)"
    elif command -v mmdblookup &>/dev/null; then
        echo -e "${GREEN}OK${NC} (mmdblookup)"
    else
        echo -e "${YELLOW}WARN${NC} - No GeoIP tool found (countries show as Unknown)"
    fi

    echo -n "Tracker data:         "
    local tracker_data="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$tracker_data" ]; then
        local country_count=$(awk -F'|' '{if($1!="") c[$1]=1} END{print length(c)}' "$tracker_data" 2>/dev/null || echo 0)
        echo -e "${GREEN}OK${NC} (${country_count} countries tracked)"
    else
        echo -e "${YELLOW}NONE${NC} - No traffic data yet"
    fi

    echo ""
    if [ "$all_ok" = true ]; then
        echo -e "${GREEN}✓ All health checks passed${NC}"
        return 0
    else
        echo -e "${RED}✗ Some health checks failed${NC}"
        return 1
    fi
}

backup_key() {
    echo -e "${CYAN}═══ BACKUP CONDUIT NODE KEY ═══${NC}"
    echo ""

    mkdir -p "$INSTALL_DIR/backups"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="$INSTALL_DIR/backups/conduit_key_${timestamp}.json"

    # Direct mountpoint access, fall back to docker cp
    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)

    if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
        if ! cp "$mountpoint/conduit_key.json" "$backup_file"; then
            echo -e "${RED}Error: Failed to copy key file${NC}"
            return 1
        fi
    else
        # Use docker cp fallback (works with Snap Docker)
        local tmp_ctr="conduit-backup-tmp"
        docker create --name "$tmp_ctr" -v conduit-data:/data alpine true 2>/dev/null || true
        if ! docker cp "$tmp_ctr:/data/conduit_key.json" "$backup_file" 2>/dev/null; then
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            echo -e "${RED}Error: No node key found. Has Conduit been started at least once?${NC}"
            return 1
        fi
        docker rm -f "$tmp_ctr" 2>/dev/null || true
    fi

    chmod 600 "$backup_file"

    # Get node ID for display
    local node_id=$(cat "$backup_file" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n')

    echo -e "${GREEN}✓ Backup created successfully${NC}"
    echo ""
    echo -e "  Backup file: ${CYAN}${backup_file}${NC}"
    echo -e "  Node ID:     ${CYAN}${node_id}${NC}"
    echo ""
    echo -e "${YELLOW}Important:${NC} Store this backup securely. It contains your node's"
    echo "private key which identifies your node on the Psiphon network."
    echo ""

    # List all backups
    echo "All backups:"
    ls -la "$INSTALL_DIR/backups/"*.json 2>/dev/null | awk '{print "  " $9 " (" $5 " bytes)"}'
}

restore_key() {
    echo -e "${CYAN}═══ RESTORE CONDUIT NODE KEY ═══${NC}"
    echo ""

    local backup_dir="$INSTALL_DIR/backups"

    # Check if backup directory exists and has files
    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir"/*.json 2>/dev/null)" ]; then
        echo -e "${YELLOW}No backups found in ${backup_dir}${NC}"
        echo ""
        echo "To restore from a custom path, provide the file path:"
        read -p "  Backup file path (or press Enter to cancel): " custom_path < /dev/tty || true

        if [ -z "$custom_path" ]; then
            echo "Restore cancelled."
            return 0
        fi

        if [ ! -f "$custom_path" ]; then
            echo -e "${RED}Error: File not found: ${custom_path}${NC}"
            return 1
        fi

        local backup_file="$custom_path"
    else
        # List available backups
        echo "Available backups:"
        local i=1
        local backups=()
        for f in "$backup_dir"/*.json; do
            backups+=("$f")
            local node_id=$(cat "$f" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null)
            echo "  ${i}. $(basename "$f") - Node: ${node_id:-unknown}"
            i=$((i + 1))
        done
        echo ""

        read -p "  Select backup number (or 0 to cancel): " selection < /dev/tty || true

        if [ "$selection" = "0" ] || [ -z "$selection" ]; then
            echo "Restore cancelled."
            return 0
        fi

        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
            echo -e "${RED}Invalid selection${NC}"
            return 1
        fi

        backup_file="${backups[$((selection - 1))]}"
    fi

    echo ""
    echo -e "${YELLOW}Warning:${NC} This will replace the current node key."
    echo "The container will be stopped and restarted."
    echo ""
    read -p "Proceed with restore? [y/N] " confirm < /dev/tty || true

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Restore cancelled."
        return 0
    fi

    # Stop all containers
    echo ""
    echo "Stopping Conduit..."
    stop_conduit

    # Try direct mountpoint access, fall back to docker cp (Snap Docker)
    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)
    local use_docker_cp=false

    if [ -z "$mountpoint" ] || [ ! -d "$mountpoint" ]; then
        use_docker_cp=true
    fi

    # Backup current key if exists
    if [ "$use_docker_cp" = "true" ]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        mkdir -p "$backup_dir"
        local tmp_ctr="conduit-restore-tmp"
        docker create --name "$tmp_ctr" -v conduit-data:/data alpine true 2>/dev/null || true
        if docker cp "$tmp_ctr:/data/conduit_key.json" "$backup_dir/conduit_key_pre_restore_${timestamp}.json" 2>/dev/null; then
            echo "  Current key backed up to: conduit_key_pre_restore_${timestamp}.json"
        fi
        # Copy new key in
        if ! docker cp "$backup_file" "$tmp_ctr:/data/conduit_key.json" 2>/dev/null; then
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            echo -e "${RED}Error: Failed to copy key into container volume${NC}"
            return 1
        fi
        docker rm -f "$tmp_ctr" 2>/dev/null || true
        # Fix ownership
        docker run --rm -v conduit-data:/data alpine chown 1000:1000 /data/conduit_key.json 2>/dev/null || true
    else
        if [ -f "$mountpoint/conduit_key.json" ]; then
            local timestamp=$(date '+%Y%m%d_%H%M%S')
            mkdir -p "$backup_dir"
            cp "$mountpoint/conduit_key.json" "$backup_dir/conduit_key_pre_restore_${timestamp}.json"
            echo "  Current key backed up to: conduit_key_pre_restore_${timestamp}.json"
        fi
        if ! cp "$backup_file" "$mountpoint/conduit_key.json"; then
            echo -e "${RED}Error: Failed to copy key to volume${NC}"
            return 1
        fi
        chmod 600 "$mountpoint/conduit_key.json"
    fi

    # Restart all containers
    echo "Starting Conduit..."
    start_conduit

    local node_id=$(cat "$backup_file" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n')

    echo ""
    echo -e "${GREEN}✓ Node key restored successfully${NC}"
    echo -e "  Node ID: ${CYAN}${node_id}${NC}"
}

recreate_containers() {
    echo "Recreating container(s) with updated image..."
    stop_tracker_service 2>/dev/null || true
    local persist_dir="$INSTALL_DIR/traffic_stats"
    if [ -s "$persist_dir/cumulative_data" ] || [ -s "$persist_dir/cumulative_ips" ]; then
        echo -e "${CYAN}⟳ Saving tracker data snapshot...${NC}"
        [ -s "$persist_dir/cumulative_data" ] && cp "$persist_dir/cumulative_data" "$persist_dir/cumulative_data.bak"
        [ -s "$persist_dir/cumulative_ips" ] && cp "$persist_dir/cumulative_ips" "$persist_dir/cumulative_ips.bak"
        [ -s "$persist_dir/geoip_cache" ] && cp "$persist_dir/geoip_cache" "$persist_dir/geoip_cache.bak"
        echo -e "${GREEN}✓ Tracker data snapshot saved${NC}"
    fi
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        docker rm -f "$name" >/dev/null 2>&1 || true
    done
    fix_volume_permissions
    for i in $(seq 1 $CONTAINER_COUNT); do
        run_conduit_container $i
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ $(get_container_name $i) updated and restarted${NC}"
        else
            echo -e "${RED}✗ Failed to start $(get_container_name $i)${NC}"
        fi
    done
    setup_tracker_service 2>/dev/null || true
}

update_conduit() {
    echo -e "${CYAN}═══ UPDATE CONDUIT ═══${NC}"
    echo ""

    local script_updated=false

    # --- Phase 1: Script update ---
    echo -e "${BOLD}Phase 1: Checking for script updates...${NC}"
    local update_url="https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh"
    local tmp_script="/tmp/conduit_update_$$.sh"

    if curl -fsSL --max-time 30 --max-filesize 2097152 -o "$tmp_script" "$update_url" 2>/dev/null; then
        # Validate downloaded script (basic sanity checks)
        if grep -q "CONDUIT_IMAGE=" "$tmp_script" && grep -q "create_management_script" "$tmp_script" && bash -n "$tmp_script" 2>/dev/null; then
            local new_version=$(grep -m1 '^VERSION=' "$tmp_script" 2>/dev/null | cut -d'"' -f2)
            echo -e "  ${GREEN}✓ Downloaded v${new_version:-?} from GitHub${NC}"
            echo -e "  Installing..."

            # Install latest from GitHub
            bash "$tmp_script" --update-components
            local update_status=$?
            rm -f "$tmp_script"

            if [ $update_status -eq 0 ]; then
                echo -e "  ${GREEN}✓ Script installed (v${new_version:-?})${NC}"
                script_updated=true
            else
                echo -e "  ${RED}✗ Installation failed${NC}"
            fi
        else
            echo -e "  ${RED}✗ Downloaded file invalid or corrupted${NC}"
            rm -f "$tmp_script"
        fi
    else
        echo -e "  ${YELLOW}✗ Could not download (check internet connection)${NC}"
        rm -f "$tmp_script" 2>/dev/null
    fi

    # --- Phase 2: Restart tracker service (picks up any script changes) ---
    echo ""
    echo -e "${BOLD}Phase 2: Updating tracker service...${NC}"
    if [ "${TRACKER_ENABLED:-true}" = "true" ]; then
        if command -v systemctl &>/dev/null; then
            systemctl restart conduit-tracker.service 2>/dev/null
            if systemctl is-active conduit-tracker.service &>/dev/null; then
                echo -e "  ${GREEN}✓ Tracker service restarted${NC}"
            else
                echo -e "  ${YELLOW}✗ Tracker restart failed (will retry on next start)${NC}"
            fi
        else
            echo -e "  ${DIM}Tracker service not available (no systemd)${NC}"
        fi
    else
        echo -e "  ${DIM}Tracker is disabled, skipping${NC}"
    fi

    # --- Phase 3: Docker image update ---
    echo ""
    echo -e "${BOLD}Phase 3: Checking for Docker image updates...${NC}"
    local pull_output
    pull_output=$(docker pull "$CONDUIT_IMAGE" 2>&1)
    local pull_status=$?
    echo "$pull_output"

    if [ $pull_status -ne 0 ]; then
        echo -e "${RED}Failed to check for Docker updates. Check your internet connection.${NC}"
        echo ""
        echo -e "${GREEN}Update complete.${NC}"
        return 1
    fi

    if echo "$pull_output" | grep -q "Status: Image is up to date"; then
        echo -e "${GREEN}Docker image is already up to date.${NC}"
    elif echo "$pull_output" | grep -q "Downloaded newer image\|Pull complete"; then
        echo ""
        echo -e "${YELLOW}A new Docker image is available.${NC}"
        echo -e "Recreating containers will cause brief downtime (~10 seconds)."
        echo ""
        read -p "Recreate containers with new image now? [y/N]: " answer < /dev/tty || true
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            recreate_containers
            echo -e "${DIM}Cleaning up old Docker images...${NC}"
            docker image prune -f >/dev/null 2>&1 || true
            echo -e "${GREEN}✓ Old images cleaned up${NC}"
        else
            echo -e "${CYAN}Skipped. Containers will use the new image on next restart.${NC}"
        fi
    fi

    # --- Phase 4: Snowflake image update (if enabled) ---
    if [ "$SNOWFLAKE_ENABLED" = "true" ]; then
        echo ""
        echo -e "${BOLD}Phase 4: Updating Snowflake proxy image...${NC}"
        if docker pull "$SNOWFLAKE_IMAGE" 2>/dev/null | tail -1; then
            echo -e "  ${GREEN}✓ Snowflake image up to date${NC}"
        else
            echo -e "  ${YELLOW}✗ Could not pull Snowflake image (will retry on next start)${NC}"
        fi
    fi

    echo ""
    echo -e "${GREEN}═══ Update complete ═══${NC}"
    if [ "$script_updated" = true ]; then
        echo -e "${DIM}Note: Some changes may require restarting the menu to take effect.${NC}"
    fi
}

case "${1:-menu}" in
    status)
        if [ "${2:-}" = "--json" ]; then
            status_json
        else
            show_status
        fi
        ;;
    stats)    show_live_stats ;;
    logs)     show_logs ;;
    health)   health_check ;;
    start)    start_conduit "${2:-}" ;;
    stop)     stop_conduit "${2:-}" ;;
    restart)  restart_conduit ;;
    update)   update_conduit ;;
    update-geoip) update_geoip ;;
    peers)    show_peers ;;
    settings) change_settings ;;
    backup)   backup_key ;;
    restore)  restore_key ;;
    scale)    manage_containers ;;
    about)    show_about ;;
    info)     show_dashboard_info ;;
    uninstall) uninstall_all ;;
    version|-v|--version) show_version ;;
    help|-h|--help) show_help ;;
    regen-tracker) setup_tracker_service 2>/dev/null ;;
    regen-telegram) [ "${TELEGRAM_ENABLED:-false}" = "true" ] && setup_telegram_service 2>/dev/null ;;
    dashboard)     show_multi_dashboard ;;
    add-server)    add_server_interactive ;;
    edit-server)   edit_server_interactive ;;
    remove-server) remove_server_interactive ;;
    servers)       list_servers ;;
    snowflake)
        case "${2:-status}" in
            status)  show_snowflake_status ;;
            start)   if [ "$SNOWFLAKE_ENABLED" = "true" ]; then start_snowflake; else echo "Snowflake not enabled."; fi ;;
            stop)    stop_snowflake ;;
            restart) if [ "$SNOWFLAKE_ENABLED" = "true" ]; then restart_snowflake; else echo "Snowflake not enabled."; fi ;;
            remove)
                stop_snowflake
                si=""
                for si in $(seq 1 ${SNOWFLAKE_COUNT:-1}); do
                    docker rm -f "$(get_snowflake_name $si)" 2>/dev/null || true
                    docker volume rm "$(get_snowflake_volume $si)" 2>/dev/null || true
                done
                SNOWFLAKE_ENABLED=false
                SNOWFLAKE_COUNT=1
                save_settings
                echo "Snowflake removed."
                ;;
            *)       echo "Usage: conduit snowflake [status|start|stop|restart|remove]" ;;
        esac
        ;;
    menu|*)   show_menu ;;
esac
MANAGEMENT

    # Patch the INSTALL_DIR in the generated script
    sed -i "s#REPLACE_ME_INSTALL_DIR#$INSTALL_DIR#g" "$tmp_script"

    chmod +x "$tmp_script"
    if ! mv -f "$tmp_script" "$INSTALL_DIR/conduit"; then
        rm -f "$tmp_script"
        log_error "Failed to update management script"
        return 1
    fi
    # Force create symlink
    rm -f /usr/local/bin/conduit 2>/dev/null || true
    ln -s "$INSTALL_DIR/conduit" /usr/local/bin/conduit
    
    log_success "Management script installed: conduit"
}

#═══════════════════════════════════════════════════════════════════════
# Summary
#═══════════════════════════════════════════════════════════════════════

print_summary() {
    local init_type="Enabled"
    if [ "$HAS_SYSTEMD" = "true" ]; then
        init_type="Enabled (systemd)"
    elif command -v rc-update &>/dev/null; then
        init_type="Enabled (OpenRC)"
    elif [ -d /etc/init.d ]; then
        init_type="Enabled (SysVinit)"
    fi
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ INSTALLATION COMPLETE!                      ║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Conduit is running and ready to help users!                      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  📊 Settings:                                                     ${GREEN}║${NC}"
    printf "${GREEN}║${NC}     Max Clients: ${CYAN}%-4s${NC}                                             ${GREEN}║${NC}\n" "${MAX_CLIENTS}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "${GREEN}║${NC}     Bandwidth:   ${CYAN}Unlimited${NC}                                        ${GREEN}║${NC}"
    else
        printf "${GREEN}║${NC}     Bandwidth:   ${CYAN}%-4s${NC} Mbps                                        ${GREEN}║${NC}\n" "${BANDWIDTH}"
    fi
    printf "${GREEN}║${NC}     Auto-start:  ${CYAN}%-20s${NC}                             ${GREEN}║${NC}\n" "${init_type}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  COMMANDS:                                                        ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit${NC}               # Open management menu                    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit stats${NC}         # View live statistics + CPU/RAM          ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit status${NC}        # Quick status with resource usage        ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit logs${NC}          # View raw logs                           ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit settings${NC}      # Change max-clients/bandwidth            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit uninstall${NC}     # Remove everything                       ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}View live stats now:${NC} conduit stats"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Uninstall Function
#═══════════════════════════════════════════════════════════════════════

uninstall() {
    telegram_disable_service
    rm -f /etc/systemd/system/conduit-telegram.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null || true
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo "║                    ⚠️  UNINSTALL CONDUIT                          "
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "This will completely remove:"
    echo "  • Conduit Docker container"
    echo "  • Conduit Docker image"
    echo "  • Conduit data volume (all stored data)"
    echo "  • Auto-start service (systemd/OpenRC/SysVinit)"
    echo "  • Configuration files"
    echo "  • Management CLI"
    echo ""
    echo -e "${RED}WARNING: This action cannot be undone!${NC}"
    echo ""
    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " confirm < /dev/tty || true
    
    if [ "$confirm" != "yes" ]; then
        echo "Uninstall cancelled."
        exit 0
    fi
    
    echo ""
    log_info "Stopping Conduit container(s)..."

    docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r name; do
        [[ "$name" =~ ^conduit(-([0-9]+))?$ ]] || continue
        docker stop "$name" 2>/dev/null || true
        docker rm -f "$name" 2>/dev/null || true
    done

    docker volume ls --format '{{.Name}}' 2>/dev/null | while read -r vol; do
        [[ "$vol" =~ ^conduit-data(-([0-9]+))?$ ]] || continue
        docker volume rm "$vol" 2>/dev/null || true
    done

    log_info "Removing Conduit Docker image..."
    docker rmi "$CONDUIT_IMAGE" 2>/dev/null || true
    
    log_info "Removing auto-start service..."
    # Systemd
    systemctl stop conduit.service 2>/dev/null || true
    systemctl disable conduit.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    systemctl daemon-reload 2>/dev/null || true
    # OpenRC / SysVinit
    rc-service conduit stop 2>/dev/null || true
    rc-update del conduit 2>/dev/null || true
    service conduit stop 2>/dev/null || true
    update-rc.d conduit remove 2>/dev/null || true
    chkconfig conduit off 2>/dev/null || true
    rm -f /etc/init.d/conduit
    
    log_info "Removing configuration files..."
    [ -n "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/conduit
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ UNINSTALL COMPLETE!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Conduit and all related components have been removed."
    echo ""
    echo "Note: Docker itself was NOT removed."
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Main
#═══════════════════════════════════════════════════════════════════════

show_usage() {
    echo "Psiphon Conduit Manager v${VERSION}"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no args)      Install or open management menu if already installed"
    echo "  --reinstall    Force fresh reinstall"
    echo "  --uninstall    Completely remove Conduit and all components"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo bash $0              # Install or open menu"
    echo "  sudo bash $0 --reinstall  # Fresh install"
    echo "  sudo bash $0 --uninstall  # Remove everything"
    echo ""
    echo "After install, use: conduit"
}

main() {
    # Handle command line arguments
    case "${1:-}" in
        --uninstall|-u)
            check_root
            uninstall
            exit 0
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        --reinstall)
            # Force reinstall
            FORCE_REINSTALL=true
            ;;
        --update-components)
            # Called by menu update to regenerate scripts without touching containers
            INSTALL_DIR="/opt/conduit"
            [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
            if ! create_management_script; then
                echo -e "${RED}Failed to update management script${NC}"
                exit 1
            fi
            # Regenerate tracker and telegram via the newly installed management script
            "$INSTALL_DIR/conduit" regen-tracker 2>/dev/null || true
            "$INSTALL_DIR/conduit" regen-telegram 2>/dev/null || true
            # Rewrite conduit.service to correct format (fixes stale/old service files)
            if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/conduit.service ]; then
                local need_rewrite=false
                # Detect old/mismatched service files
                grep -q "Requires=docker.service" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
                grep -q "Type=simple" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
                grep -q "Restart=always" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
                grep -q "max-clients" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
                grep -q "conduit start$" /etc/systemd/system/conduit.service 2>/dev/null && need_rewrite=true
                if [ "$need_rewrite" = true ]; then
                    # Overwrite file first, then reload to replace old Restart=always definition
                    cat > /etc/systemd/system/conduit.service << SVCEOF
[Unit]
Description=Psiphon Conduit Service
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/conduit start --auto
ExecStop=/usr/local/bin/conduit stop --auto

[Install]
WantedBy=multi-user.target
SVCEOF
                    systemctl daemon-reload 2>/dev/null || true
                    systemctl stop conduit.service 2>/dev/null || true
                    systemctl reset-failed conduit.service 2>/dev/null || true
                    systemctl enable conduit.service 2>/dev/null || true
                    systemctl start conduit.service 2>/dev/null || true
                fi
            fi
            setup_tracker_service 2>/dev/null || true
            if [ "$TELEGRAM_ENABLED" = "true" ]; then
                telegram_generate_notify_script 2>/dev/null || true
                systemctl restart conduit-telegram 2>/dev/null || true
                echo -e "${GREEN}✓ Telegram service updated${NC}"
            fi
            exit 0
            ;;
    esac
    
    print_header
    check_root
    detect_os
    
    check_dependencies

    while [ -f "$INSTALL_DIR/conduit" ] && [ "$FORCE_REINSTALL" != "true" ]; do
        echo -e "${GREEN}Conduit is already installed!${NC}"
        echo ""
        echo "What would you like to do?"
        echo ""
        echo "  1. 📊 Open management menu"
        echo "  2. 🔄 Reinstall (fresh install)"
        echo "  3. 🗑️  Uninstall"
        echo "  0. 🚪 Exit"
        echo ""
        read -p "  Enter choice: " choice < /dev/tty || { echo -e "\n  ${RED}Input error. Cannot read from terminal. Exiting.${NC}"; exit 1; }

        case "$choice" in
            1)
                echo -e "${CYAN}Updating management script and opening menu...${NC}"
                create_management_script
                # Regenerate Telegram script if enabled (picks up new features)
                if [ -f "$INSTALL_DIR/settings.conf" ]; then
                    source "$INSTALL_DIR/settings.conf"
                    if [ "$TELEGRAM_ENABLED" = "true" ]; then
                        telegram_generate_notify_script 2>/dev/null || true
                        systemctl restart conduit-telegram 2>/dev/null || true
                    fi
                fi
                exec "$INSTALL_DIR/conduit" menu
                ;;
            2)
                echo ""
                log_info "Starting fresh reinstall..."
                break
                ;;
            3)
                uninstall
                exit 0
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                echo -e "${CYAN}Returning to installer...${NC}"
                sleep 1
                ;;
        esac
    done

    prompt_settings

    echo ""
    echo -e "${CYAN}Starting installation...${NC}"
    echo ""

    log_info "Step 1/5: Installing Docker..."
    install_docker

    echo ""

    log_info "Step 2/5: Checking for previous node identity..."
    check_and_offer_backup_restore || true

    echo ""

    log_info "Step 3/5: Starting Conduit..."
    docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r name; do
        [[ "$name" =~ ^conduit(-[0-9]+)?$ ]] || continue
        docker stop "$name" 2>/dev/null || true
        docker rm -f "$name" 2>/dev/null || true
    done
    run_conduit
    
    echo ""

    log_info "Step 4/5: Setting up auto-start..."
    save_settings_install
    setup_autostart
    setup_tracker_service 2>/dev/null || true

    echo ""

    # Create the 'conduit' CLI management script
    log_info "Step 5/5: Creating management script..."
    create_management_script

    print_summary

    read -p "Open management menu now? [Y/n] " open_menu < /dev/tty || true
    if [[ ! "$open_menu" =~ ^[Nn]$ ]]; then
        "$INSTALL_DIR/conduit" menu
    fi
}
#
# REACHED END OF SCRIPT - VERSION 1.3
# ###############################################################################
main "$@"



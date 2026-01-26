#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║        🚀 PSIPHON CONDUIT MANAGER v1.0.1                          ║
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
# Reference: https://github.com/ssmirr/conduit/releases/tag/d8522a8
# Conduit CLI options:
#   -m, --max-clients int   maximum number of proxy clients (1-1000) (default 200)
#   -b, --bandwidth float   bandwidth limit per peer in Mbps (1-40, or -1 for unlimited) (default 5)
#   -v, --verbose           increase verbosity (-v for verbose, -vv for debug)
#

set -e

# Ensure we're running in bash (not sh/dash)
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0"
    exit 1
fi

VERSION="1.0.1"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:d8522a8"
INSTALL_DIR="/opt/conduit"
FORCE_REINSTALL=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                🚀 PSIPHON CONDUIT MANAGER v${VERSION}                  ║"
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
    
    # Detect OS from /etc/os-release
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
    
    # Determine OS family and package manager
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
    
    # Check for systemd
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        HAS_SYSTEMD=true
    fi
    
    log_info "Detected: $OS ($OS_FAMILY family), Package manager: $PKG_MANAGER"
}

install_package() {
    local package="$1"
    log_info "Installing $package..."
    
    case "$PKG_MANAGER" in
        apt)
            apt-get update -qq 2>/dev/null
            apt-get install -y -qq "$package" 2>/dev/null
            ;;
        dnf)
            dnf install -y -q "$package" 2>/dev/null
            ;;
        yum)
            yum install -y -q "$package" 2>/dev/null
            ;;
        pacman)
            pacman -Sy --noconfirm "$package" 2>/dev/null
            ;;
        zypper)
            zypper install -y -n "$package" 2>/dev/null
            ;;
        apk)
            apk add --no-cache "$package" 2>/dev/null
            ;;
        *)
            log_warn "Unknown package manager. Please install $package manually."
            return 1
            ;;
    esac
}

check_dependencies() {
    # Check for bash
    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! command -v bash &>/dev/null; then
            log_info "Installing bash (required for this script)..."
            apk add --no-cache bash 2>/dev/null
        fi
    fi
    
    # Check for curl
    if ! command -v curl &>/dev/null; then
        install_package curl || log_warn "Could not install curl automatically"
    fi
    
    # Check for basic tools
    if ! command -v awk &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package gawk ;;
            apk) install_package gawk ;;
            *) install_package awk ;;
        esac
    fi
    
    # Check for free command
    if ! command -v free &>/dev/null; then
        case "$PKG_MANAGER" in
            apt|dnf|yum) install_package procps ;;
            pacman) install_package procps-ng ;;
            zypper) install_package procps ;;
            apk) install_package procps ;;
        esac
    fi

    # Check for tput (ncurses)
    if ! command -v tput &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package ncurses-bin ;;
            apk) install_package ncurses ;;
            *) install_package ncurses ;;
        esac
    fi

    # Check for tcpdump
    if ! command -v tcpdump &>/dev/null; then
        install_package tcpdump || log_warn "Could not install tcpdump automatically"
    fi

    # Check for GeoIP tools
    if ! command -v geoiplookup &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package geoip-bin ;;
            dnf|yum) 
                # On RHEL/CentOS
                if ! rpm -q epel-release &>/dev/null; then
                    log_info "Enabling EPEL repository for GeoIP..."
                    $PKG_MANAGER install -y epel-release &>/dev/null || true
                fi
                install_package GeoIP 
                ;;
            pacman) install_package geoip ;;
            zypper) install_package GeoIP ;;
            apk) install_package geoip ;;
            *) log_warn "Could not install geoiplookup automatically" ;;
        esac
    fi
}

get_ram_mb() {
    # Get RAM in MB
    local ram=""
    
    # Try free command first
    if command -v free &>/dev/null; then
        ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    fi
    
    # Fallback: parse /proc/meminfo
    if [ -z "$ram" ] || [ "$ram" = "0" ]; then
        if [ -f /proc/meminfo ]; then
            local kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
            if [ -n "$kb" ]; then
                ram=$((kb / 1024))
            fi
        fi
    fi
    
    # Ensure minimum of 1
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
    
    # Safety check
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$cores"
    fi
}

calculate_recommended_clients() {
    local cores=$(get_cpu_cores)
    # Logic: 100 clients per CPU core, max 1000
    local recommended=$((cores * 100))
    if [ "$recommended" -gt 1000 ]; then
        echo 1000
    else
        echo "$recommended"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Interactive Setup
#═══════════════════════════════════════════════════════════════════════

prompt_settings() {
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
    
    # Max clients prompt
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
    
    # Bandwidth prompt
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Do you want to set ${BOLD}UNLIMITED${NC} bandwidth? (Recommended for servers)"
    echo -e "  ${YELLOW}Note: High bandwidth usage may attract attention.${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  Set unlimited bandwidth? [y/N] " unlimited_bw < /dev/tty || true

    if [[ "$unlimited_bw" =~ ^[Yy] ]]; then
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
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Your Settings:${NC}"
    echo -e "    Max Clients: ${GREEN}${MAX_CLIENTS}${NC}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "    Bandwidth:   ${GREEN}Unlimited${NC}"
    else
        echo -e "    Bandwidth:   ${GREEN}${BANDWIDTH}${NC} Mbps"
    fi
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    read -p "  Proceed with these settings? [Y/n] " confirm < /dev/tty || true
    if [[ "$confirm" =~ ^[Nn] ]]; then
        prompt_settings
    fi
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
    
    # Alpine
    if [ "$OS_FAMILY" = "alpine" ]; then
        apk add --no-cache docker docker-cli-compose 2>/dev/null
        rc-update add docker boot 2>/dev/null || true
        service docker start 2>/dev/null || rc-service docker start 2>/dev/null || true
    else
        # Use official Docker install
        curl -fsSL https://get.docker.com | sh
        
        # Enable and start Docker
        if [ "$HAS_SYSTEMD" = "true" ]; then
            systemctl enable docker 2>/dev/null || true
            systemctl start docker 2>/dev/null || true
        else
            # Fallback for non-systemd (SysVinit, OpenRC, etc.)
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
    
    # Wait for Docker to be ready
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

run_conduit() {
    log_info "Starting Conduit container..."
    
    # Stop existing container
    docker rm -f conduit 2>/dev/null || true
    
    # Pull image 
    log_info "Pulling Conduit image ($CONDUIT_IMAGE)..."
    if ! docker pull $CONDUIT_IMAGE; then
        log_error "Failed to pull Conduit image. Check your internet connection."
        exit 1
    fi
    
    # Run container with host networking
    docker run -d \
        --name conduit \
        --restart unless-stopped \
        -v conduit-data:/home/conduit/data \
        --network host \
        $CONDUIT_IMAGE \
        start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" -v
    
    sleep 3
    
    if docker ps | grep -q conduit; then
        log_success "Conduit container is running"
        if [ "$BANDWIDTH" == "-1" ]; then
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=Unlimited"
        else
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=${BANDWIDTH}Mbps"
        fi
    else
        log_error "Conduit failed to start"
        docker logs conduit 2>&1 | tail -10
        exit 1
    fi
}

save_settings() {
    mkdir -p $INSTALL_DIR
    
    # Save settings
    cat > "$INSTALL_DIR/settings.conf" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
EOF
    
    if [ ! -f "$INSTALL_DIR/settings.conf" ]; then
        log_error "Failed to save settings. Check disk space and permissions."
        return 1
    fi
    
    log_success "Settings saved"
}

setup_autostart() {
    log_info "Setting up auto-start on boot..."
    
    if [ "$HAS_SYSTEMD" = "true" ]; then
        # Systemd-based systems
        cat > /etc/systemd/system/conduit.service << 'EOF'
[Unit]
Description=Psiphon Conduit Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start conduit
ExecStop=/usr/bin/docker stop conduit

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
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
    docker start conduit
    eend $?
}
stop() {
    ebegin "Stopping Conduit"
    docker stop conduit
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
        docker start conduit
        ;;
    stop)
        docker stop conduit
        ;;
    restart)
        docker restart conduit
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
    cat > $INSTALL_DIR/conduit << 'MANAGEMENT'
#!/bin/bash
#
# Psiphon Conduit Manager
# Reference: https://github.com/ssmirr/conduit/releases/tag/d8522a8
#

VERSION="1.0.1"
INSTALL_DIR="/opt/conduit"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:d8522a8"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Load settings
[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
MAX_CLIENTS=${MAX_CLIENTS:-200}
BANDWIDTH=${BANDWIDTH:-5}

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
    echo -e "║                    CONDUIT LIVE STATISTICS                        ║${EL}"
    echo -e "╠═══════════════════════════════════════════════════════════════════╣${EL}"
    printf "║  Max Clients: ${GREEN}%-52s${CYAN}║${EL}\n" "${MAX_CLIENTS}"
    if [ "$BANDWIDTH" == "-1" ]; then
        printf "║  Bandwidth:   ${GREEN}%-52s${CYAN}║${EL}\n" "Unlimited"
    else
        printf "║  Bandwidth:   ${GREEN}%-52s${CYAN}║${EL}\n" "${BANDWIDTH} Mbps"
    fi
    echo -e "║                                                                   ║${EL}"
    echo -e "╚═══════════════════════════════════════════════════════════════════╝${EL}"
    echo -e "${NC}\033[K"
}



get_node_id() {
    if docker volume inspect conduit-data >/dev/null 2>&1; then
        local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}')
        if [ -f "$mountpoint/conduit_key.json" ]; then
            # Extract privateKeyBase64, decode, take last 32 bytes, encode base64
            # Logic provided by user
            cat "$mountpoint/conduit_key.json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n'
        fi
    fi
}

show_dashboard() {
    local stop_dashboard=0
    # Setup trap to catch signals gracefully
    trap 'stop_dashboard=1' SIGINT SIGTERM
    
    # Use alternate screen buffer if available for smoother experience
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l" # Hide cursor
    # Initial clear
    clear

    while [ $stop_dashboard -eq 0 ]; do
        # Move cursor to top-left (0,0)
        # We NO LONGER clear the screen here to avoid the "full black" flash
        if ! tput cup 0 0 2>/dev/null; then
            printf "\033[H"
        fi
        
        print_live_stats_header
        
        show_status "live"
        
        # Show Node ID in its own section
        local node_id=$(get_node_id)
        if [ -n "$node_id" ]; then
            echo -e "${CYAN}═══ CONDUIT ID ═══${NC}\033[K"
            echo -e "  ${CYAN}${node_id}${NC}\033[K"
            echo -e "\033[K"
        fi

        echo -e "${BOLD}Refreshes every 5 seconds. Press any key to return to menu...${NC}\033[K"
        
        # Clear any leftover lines below the dashboard content (Erase to End of Display)
        # This only cleans up if the dashboard gets shorter
        if ! tput ed 2>/dev/null; then
            printf "\033[J"
        fi
        
        # Wait 4 seconds for keypress (compensating for processing time)
        # Redirect from /dev/tty ensures it works when the script is piped
        if read -t 4 -n 1 -s <> /dev/tty 2>/dev/null; then
            stop_dashboard=1
        fi
    done
    
    echo -ne "\033[?25h" # Show cursor
    # Restore main screen buffer
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM # Reset traps
}

get_container_stats() {
    # Get CPU and RAM usage for conduit container
    # Returns: "CPU_PERCENT RAM_USAGE"
    local stats=$(docker stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" conduit 2>/dev/null)
    if [ -z "$stats" ]; then
        echo "0% 0MiB"
    else
        # Extract just the raw numbers/units, simpler format
        echo "$stats"
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
    # Get System CPU (Live Delta) and RAM
    # Returns: "CPU_PERCENT RAM_USED RAM_TOTAL RAM_PCT"
    
    # 1. System CPU (Live Delta)
    local sys_cpu="0%"
    if [ -f /proc/stat ]; then
        # Read 1
        read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
        local total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local work1=$((user + nice + system + irq + softirq + steal))
        
        sleep 0.1
        
        # Read 2
        read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
        local total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local work2=$((user + nice + system + irq + softirq + steal))
        
        local total_delta=$((total2 - total1))
        local work_delta=$((work2 - work1))
        
        if [ "$total_delta" -gt 0 ]; then
            local cpu_usage=$((work_delta * 100 / total_delta))
            sys_cpu="${cpu_usage}%"
        fi
    else
        sys_cpu="N/A"
    fi
    
    # 2. System RAM (Used, Total, Percentage)
    local sys_ram_used="N/A"
    local sys_ram_total="N/A"
    local sys_ram_pct="N/A"
    
    if command -v free &>/dev/null; then
        # Output: used total percentage
        local ram_data=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%s %s %.2f%%", $3, $2, ($3/$2)*100}')
        local ram_human=$(free -h 2>/dev/null | awk '/^Mem:/{print $3 " " $2}')
        
        sys_ram_used=$(echo "$ram_human" | awk '{print $1}')
        sys_ram_total=$(echo "$ram_human" | awk '{print $2}')
        sys_ram_pct=$(echo "$ram_data" | awk '{print $3}')
    fi
    
    echo "$sys_cpu $sys_ram_used $sys_ram_total $sys_ram_pct"
}

show_live_stats() {
    print_header
    echo -e "${YELLOW}Reading traffic history...${NC}"
    echo -e "${CYAN}Press ANY KEY to return to menu${NC}"
    echo ""
    
    # Run logs in background
    # Stream logs, filter for [STATS], and strip everything before [STATS]
    # Tail 2500 to reliably capture stats (performance cost is negligible)
    docker logs -f --tail 2500 conduit 2>&1 | grep --line-buffered "\[STATS\]" | sed -u -e 's/.*\[STATS\]/[STATS]/' &
    local cmd_pid=$!
    
    # Wait for any key press
    # Redirect from /dev/tty ensures it works when the script is piped
    read -n 1 -s -r <> /dev/tty 2>/dev/null || true
    
    # Kill the background process
    kill $cmd_pid 2>/dev/null
    wait $cmd_pid 2>/dev/null
}

show_peers() {
    local stop_peers=0
    trap 'stop_peers=1' SIGINT SIGTERM
    
    # Check dependencies again in case they were removed
    if ! command -v tcpdump &>/dev/null || ! command -v geoiplookup &>/dev/null; then
        echo -e "${RED}Error: tcpdump or geoiplookup not found!${NC}"
        echo "Please re-run the main installer to fix dependencies."
        read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
        return 1
    fi

    # Detect primary interface and local IP to filter it out
    local iface="any"
    local local_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    [ -z "$local_ip" ] && local_ip=$(hostname -I | awk '{print $1}')
    
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l" # Hide cursor
    clear

    while [ $stop_peers -eq 0 ]; do
        if ! tput cup 0 0 2>/dev/null; then printf "\033[H"; fi
        # Clear screen from cursor down to prevent ghosting from previous updates
        tput ed 2>/dev/null || printf "\033[J"
        
        # Header Section
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "║                    LIVE PEER CONNECTIONS BY COUNTRY               ║"
        echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
        if [ -f /tmp/conduit_peers_current ]; then
            local update_time=$(date '+%H:%M:%S')
            # 1(║)+2(sp)+13(Last Update: )+8(time)+36(sp)+6([LIVE])+2(sp)+1(║) = 69 total
            echo -e "║  Last Update: ${update_time}                                    ${GREEN}[LIVE]${NC}  ║"
        else
            echo -e "║  Status: ${YELLOW}Initial setup...${NC}                                         ║"
        fi
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
        echo -e ""
        
        # Data Table Section
        if [ -s /tmp/conduit_peers_current ]; then
            echo -e "${BOLD}   Peers | Country${NC}"
            echo -e "   ──────|──────────────────────────────────────"
            while read -r line; do
                local p_count=$(echo "$line" | awk '{print $1}')
                local country=$(echo "$line" | cut -d' ' -f2-)
                # Pad country to prevent wrapping/junk
                printf "   ${GREEN}%5s${NC} | ${CYAN}%-40s${NC}\n" "$p_count" "$country"
            done < /tmp/conduit_peers_current
        else
            echo -e "   ${YELLOW}Waiting for first snapshot... (High traffic helps speed this up)${NC}"
            for i in {1..8}; do echo ""; done
        fi
        
        echo -e ""
        echo -e "${CYAN}─────────────────────────────────────────────────────────────────────${NC}"
        
        # Background capture starts here
        # Removed -c limit to ensure we respect the 14s timeout even on high traffic
        timeout 14 tcpdump -ni $iface '(tcp or udp)' 2>/dev/null | \
            grep ' IP ' | \
            sed -nE 's/.* IP ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})(\.[0-9]+)?[ >].*/\1/p' | \
            grep -vE "^($local_ip|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.|169\.254\.)" | \
            sort -u | \
            xargs -n1 geoiplookup 2>/dev/null | \
            awk -F: '/Country Edition/{print $2}' | \
            sed 's/^ // ' | \
            sed 's/Iran, Islamic Republic of/Iran - #FreeIran/' | \
            sort | \
            uniq -c | \
            sort -nr | \
            head -20 > /tmp/conduit_peers_next 2>/dev/null &
        
        local tcpdump_pid=$!
        
        # Indicator Loop
        local count=0
        while kill -0 $tcpdump_pid 2>/dev/null; do
            if read -t 1 -n 1 -s <> /dev/tty 2>/dev/null; then
                stop_peers=1
                kill $tcpdump_pid 2>/dev/null
                break
            fi
            count=$((count + 1))
            [ $count -gt 14 ] && count=1
            echo -ne "\r  [${YELLOW}"
            for ((i=0; i<count; i++)); do echo -n "•"; done
            for ((i=count; i<14; i++)); do echo -n " "; done
            echo -ne "${NC}] Capturing next update... (Any key to exit) \033[K"
        done
        
        if [ $stop_peers -eq 1 ]; then break; fi
        
        # Move next to current
        mv /tmp/conduit_peers_next /tmp/conduit_peers_current 2>/dev/null

        echo -ne "\r  ${GREEN}✓ Update complete! Refreshing...${NC} \033[K"
        sleep 1
    done
    
    echo -ne "\033[?25h" # Show cursor
    tput rmcup 2>/dev/null || true
    rm -f /tmp/conduit_peers_current
    trap - SIGINT SIGTERM
}

show_status() {
    local mode="${1:-normal}" # 'live' mode adds line clearing
    local EL=""
    if [ "$mode" == "live" ]; then
        EL="\033[K" # Erase Line escape code
    fi

    echo ""

    
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        # Fetch stats once
        local logs=$(docker logs --tail 1000 conduit 2>&1 | grep "STATS" | tail -1)
        
        # Get Resource Stats
        local stats=$(get_container_stats)
        
        # Normalize App CPU (Docker % / Cores)
        local raw_app_cpu=$(echo "$stats" | awk '{print $1}' | tr -d '%')
        local num_cores=$(get_cpu_cores)
        local app_cpu="0%"
        local app_cpu_display=""
        
        if [[ "$raw_app_cpu" =~ ^[0-9.]+$ ]]; then
             # Use awk for floating point math
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
        
        local sys_stats=$(get_system_stats)
        local sys_cpu=$(echo "$sys_stats" | awk '{print $1}')
        local sys_ram_used=$(echo "$sys_stats" | awk '{print $2}')
        local sys_ram_total=$(echo "$sys_stats" | awk '{print $3}')
        local sys_ram_pct=$(echo "$sys_stats" | awk '{print $4}')
        
        if [ -n "$logs" ]; then
            local connecting=$(echo "$logs" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p')
            local connected=$(echo "$logs" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
            local upload=$(echo "$logs" | sed -n 's/.*Up:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
            local download=$(echo "$logs" | sed -n 's/.*Down:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
            local uptime=$(echo "$logs" | sed -n 's/.*Uptime:[[:space:]]*\(.*\)/\1/p' | xargs)
            
            # Default to 0 if missing/empty
            connecting=${connecting:-0}
            connected=${connected:-0}
            
            echo -e "🚀 PSIPHON CONDUIT MANAGER v${VERSION}${EL}"
            echo -e "${NC}${EL}"
            
            if [ -n "$uptime" ]; then
                 echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC} (${uptime})  |  ${BOLD}Clients:${NC} ${GREEN}${connected}${NC} connected, ${YELLOW}${connecting}${NC} connecting${EL}"
            else
                 echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC}  |  ${BOLD}Clients:${NC} ${GREEN}${connected}${NC} connected, ${YELLOW}${connecting}${NC} connecting${EL}"
            fi
            
            echo -e "${EL}"
            echo -e "${CYAN}═══ Traffic ═══${NC}${EL}"
            [ -n "$upload" ] && echo -e "  Upload:       ${CYAN}${upload}${NC}${EL}"
            [ -n "$download" ] && echo -e "  Download:     ${CYAN}${download}${NC}${EL}"
            
            echo -e "${EL}"
            echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu" "$sys_ram_used / $sys_ram_total"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "Total:" "$sys_cpu" "$sys_ram_pct"
            
        else
             echo -e "🚀 PSIPHON CONDUIT MANAGER v${VERSION}${EL}"
             echo -e "${NC}${EL}"
             echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC}${EL}"
             echo -e "${EL}"
             echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
             printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
             printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu" "$sys_ram_used / $sys_ram_total"
             printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "Total:" "$sys_cpu" "$sys_ram_pct"
             echo -e "${EL}"
             echo -e "  Stats:        ${YELLOW}Waiting for first stats...${NC}${EL}"
        fi
        
    else
        echo -e "🚀 PSIPHON CONDUIT MANAGER v${VERSION}${EL}"
        echo -e "${NC}${EL}"
        echo -e "${BOLD}Status:${NC} ${RED}Stopped${NC}${EL}"
    fi
    

    
    echo ""
    echo -e "${CYAN}═══ SETTINGS ═══${NC}${EL}"
    echo -e "  Max Clients:  ${MAX_CLIENTS}${EL}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "  Bandwidth:    Unlimited${EL}"
    else
        echo -e "  Bandwidth:    ${BANDWIDTH} Mbps${EL}"
    fi

    
    echo ""
    echo -e "${CYAN}═══ AUTO-START SERVICE ═══${NC}"
    # Check for systemd
    if command -v systemctl &>/dev/null && systemctl is-enabled conduit.service 2>/dev/null | grep -q "enabled"; then
        echo -e "  Auto-start:   ${GREEN}Enabled (systemd)${NC}"
        local svc_status=$(systemctl is-active conduit.service 2>/dev/null)
        echo -e "  Service:      ${svc_status:-unknown}"
    # Check for OpenRC
    elif command -v rc-status &>/dev/null && rc-status -a 2>/dev/null | grep -q "conduit"; then
        echo -e "  Auto-start:   ${GREEN}Enabled (OpenRC)${NC}"
    # Check for SysVinit
    elif [ -f /etc/init.d/conduit ]; then
        echo -e "  Auto-start:   ${GREEN}Enabled (SysVinit)${NC}"
    else
        echo -e "  Auto-start:   ${YELLOW}Not configured${NC}"
        echo -e "  Note:         Docker restart policy handles restarts"
    fi
    echo ""
}

start_conduit() {
    echo "Starting Conduit..."
    if docker ps -a 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        if docker start conduit 2>/dev/null; then
            echo -e "${GREEN}✓ Conduit started${NC}"
        else
            echo -e "${RED}✗ Failed to start Conduit${NC}"
            return 1
        fi
    else
        echo "Container not found. Creating new container..."
        docker run -d \
            --name conduit \
            --restart unless-stopped \
            -v conduit-data:/home/conduit/data \
            --network host \
            $CONDUIT_IMAGE \
            start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" -v
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Conduit started${NC}"
        else
            echo -e "${RED}✗ Failed to start Conduit${NC}"
            return 1
        fi
    fi
}

stop_conduit() {
    echo "Stopping Conduit..."
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        docker stop conduit 2>/dev/null
        echo -e "${YELLOW}✓ Conduit stopped${NC}"
    else
        echo -e "${YELLOW}Conduit is not running${NC}"
    fi
}

restart_conduit() {
    echo "Restarting Conduit..."
    if docker ps -a 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        docker restart conduit 2>/dev/null
        echo -e "${GREEN}✓ Conduit restarted${NC}"
    else
        echo -e "${RED}Conduit container not found. Use 'conduit start' to create it.${NC}"
        return 1
    fi
}

change_settings() {
    echo ""
    echo -e "${CYAN}Current Settings:${NC}"
    echo -e "  Max Clients: ${MAX_CLIENTS}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "  Bandwidth:   Unlimited"
    else
        echo -e "  Bandwidth:   ${BANDWIDTH} Mbps"
    fi
    echo ""
    
    read -p "New max-clients (1-1000) [${MAX_CLIENTS}]: " new_clients < /dev/tty || true

    
    # Bandwidth prompt logic for settings menu
    echo ""
    if [ "$BANDWIDTH" == "-1" ]; then
        echo "Current bandwidth: Unlimited"
    else
        echo "Current bandwidth: ${BANDWIDTH} Mbps"
    fi
    read -p "Set unlimited bandwidth (-1)? [y/N]: " set_unlimited < /dev/tty || true
    
    if [[ "$set_unlimited" =~ ^[Yy] ]]; then
        new_bandwidth="-1"
    else
        read -p "New bandwidth in Mbps (1-40) [${BANDWIDTH}]: " input_bw < /dev/tty || true
        if [ -n "$input_bw" ]; then
            new_bandwidth="$input_bw"
        fi
    fi
    
    # Validate max-clients
    if [ -n "$new_clients" ]; then
        if [[ "$new_clients" =~ ^[0-9]+$ ]] && [ "$new_clients" -ge 1 ] && [ "$new_clients" -le 1000 ]; then
            MAX_CLIENTS=$new_clients
        else
            echo -e "${YELLOW}Invalid max-clients. Keeping current: ${MAX_CLIENTS}${NC}"
        fi
    fi
    
    # Validate bandwidth
    if [ -n "$new_bandwidth" ]; then
        if [ "$new_bandwidth" = "-1" ]; then
             BANDWIDTH="-1"
        elif [[ "$new_bandwidth" =~ ^[0-9]+$ ]] && [ "$new_bandwidth" -ge 1 ] && [ "$new_bandwidth" -le 40 ]; then
            BANDWIDTH=$new_bandwidth
        elif [[ "$new_bandwidth" =~ ^[0-9]*\.[0-9]+$ ]]; then
            local float_ok=$(awk -v val="$new_bandwidth" 'BEGIN { print (val >= 1 && val <= 40) ? "yes" : "no" }')
            if [ "$float_ok" = "yes" ]; then
                BANDWIDTH=$new_bandwidth
            else
                echo -e "${YELLOW}Invalid bandwidth. Keeping current: ${BANDWIDTH}${NC}"
            fi
        else
            echo -e "${YELLOW}Invalid bandwidth. Keeping current: ${BANDWIDTH}${NC}"
        fi
    fi
    
    # Save settings
    cat > $INSTALL_DIR/settings.conf << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
EOF

    echo ""
    echo "Updating and recreating Conduit container with new settings..."
    docker rm -f conduit 2>/dev/null || true
    sleep 2  # Wait for container cleanup to complete
    echo "Pulling latest image..."
    docker pull $CONDUIT_IMAGE 2>/dev/null || echo -e "${YELLOW}Could not pull latest image, using cached version${NC}"
    docker run -d \
        --name conduit \
        --restart unless-stopped \
        -v conduit-data:/home/conduit/data \
        --network host \
        $CONDUIT_IMAGE \
        start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" -v
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Settings updated and Conduit restarted${NC}"
        echo -e "  Max Clients: ${MAX_CLIENTS}"
        if [ "$BANDWIDTH" == "-1" ]; then
            echo -e "  Bandwidth:   Unlimited"
        else
            echo -e "  Bandwidth:   ${BANDWIDTH} Mbps"
        fi
    else
        echo -e "${RED}✗ Failed to restart Conduit${NC}"
    fi
}

show_logs() {
    if ! docker ps -a 2>/dev/null | grep -q conduit; then
        echo -e "${RED}Conduit container not found.${NC}"
        return 1
    fi
    # Filter out noisy 'context deadline exceeded' and 'port mapping: closed' errors
    docker logs -f --tail 100 conduit 2>&1 | grep -vE "context deadline exceeded|port mapping: closed"
}

uninstall_all() {
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  UNINSTALL CONDUIT                          ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
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
        return 0
    fi
    
    echo ""
    echo "[INFO] Stopping Conduit container..."
    docker stop conduit 2>/dev/null || true
    
    echo "[INFO] Removing Conduit container..."
    docker rm -f conduit 2>/dev/null || true
    
    echo "[INFO] Removing Conduit Docker image..."
    docker rmi $CONDUIT_IMAGE 2>/dev/null || true
    
    echo "[INFO] Removing Conduit data volume..."
    docker volume rm conduit-data 2>/dev/null || true
    
    echo "[INFO] Removing auto-start service..."
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
    
    echo "[INFO] Removing configuration files..."
    rm -rf /opt/conduit
    rm -f /usr/local/bin/conduit
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ UNINSTALL COMPLETE!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Conduit and all related components have been removed."
    echo ""
    echo "Note: Docker itself was NOT removed. To remove Docker:"
    echo "  apt-get purge docker-ce docker-ce-cli containerd.io"
    echo ""
}

show_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            print_header
            
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  MANAGEMENT OPTIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "  1. 📈 View status dashboard"
            echo -e "  2. 📜 View traffic history (Scrolling Logs)"
            echo -e "  3. 📋 View raw logs (Filtered)"
            echo -e "  4. ⚙️  Change settings (max-clients, bandwidth)"
            echo ""
            echo -e "  5. ▶️  Start Conduit"
            echo -e "  6. ⏹️  Stop Conduit"
            echo -e "  7. 🔁 Restart Conduit"
            echo ""
            echo -e "  8. 🌍 View live peers by country (Live Map)"
            echo ""
            echo -e "  u. 🗑️  Uninstall (remove everything)"
            echo -e "  0. 🚪 Exit"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            redraw=false
        fi
        
        read -p "  Enter choice: " choice < /dev/tty || { echo "Input error. Exiting."; exit 1; }
            
        case $choice in
            1)
                show_dashboard
                redraw=true
                ;;
            2)
                show_live_stats
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            3)
                show_logs
                redraw=true
                ;;
            4)
                change_settings
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
                show_peers
                redraw=true
                ;;
            u)
                uninstall_all
                exit 0
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            "")
                # Ignore empty Enter key
                ;;
            *)
                echo -e "${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                echo -e "${CYAN}Choose an option from 0-8, or 'u' to uninstall.${NC}"
                ;;
        esac
    done
}

# Command line interface
show_help() {
    echo "Usage: conduit [command]"
    echo ""
    echo "Commands:"
    echo "  status    Show current status with resource usage"
    echo "  stats     View live statistics"
    echo "  logs      View raw Docker logs"
    echo "  start     Start Conduit container"
    echo "  stop      Stop Conduit container"
    echo "  restart   Restart Conduit container"
    echo "  settings  Change max-clients/bandwidth"
    echo "  uninstall Remove everything (container, data, service)"
    echo "  menu      Open interactive menu (default)"
    echo "  help      Show this help"
}

case "${1:-menu}" in
    status)   show_status ;;
    stats)    show_live_stats ;;
    logs)     show_logs ;;
    start)    start_conduit ;;
    stop)     stop_conduit ;;
    restart)  restart_conduit ;;
    peers)    show_peers ;;
    settings) change_settings ;;
    uninstall) uninstall_all ;;
    help|-h|--help) show_help ;;
    menu|*)   show_menu ;;
esac
MANAGEMENT

    chmod +x $INSTALL_DIR/conduit
    # Force create symlink
    rm -f /usr/local/bin/conduit 2>/dev/null || true
    ln -s $INSTALL_DIR/conduit /usr/local/bin/conduit
    
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
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                    ⚠️  UNINSTALL CONDUIT                          ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
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
    log_info "Stopping Conduit container..."
    docker stop conduit 2>/dev/null || true
    
    log_info "Removing Conduit container..."
    docker rm -f conduit 2>/dev/null || true
    
    log_info "Removing Conduit Docker image..."
    docker rmi ghcr.io/ssmirr/conduit/conduit:latest 2>/dev/null || true
    
    log_info "Removing Conduit data volume..."
    docker volume rm conduit-data 2>/dev/null || true
    
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
    rm -rf /opt/conduit
    rm -f /usr/local/bin/conduit
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ UNINSTALL COMPLETE!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Conduit and all related components have been removed."
    echo ""
    echo "Note: Docker itself was NOT removed. To remove Docker:"
    echo "  apt-get purge docker-ce docker-ce-cli containerd.io"
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
    esac
    
    print_header
    check_root
    detect_os
    
    # Ensure all tools (including new ones like tcpdump) are present
    check_dependencies
    
    # Check if already installed
    if [ -f "$INSTALL_DIR/conduit" ] && [ "$FORCE_REINSTALL" != "true" ]; then
        echo -e "${GREEN}Conduit is already installed!${NC}"
        echo ""
        echo "What would you like to do?"
        echo ""
        echo "  1. 📊 Open management menu"
        echo "  2. 🔄 Reinstall (fresh install)"
        echo "  3. 🗑️  Uninstall"
        echo "  0. 🚪 Exit"
        echo ""
        read -p "  Enter choice: " choice < /dev/tty || true
        
        case $choice in
            1)
                echo -e "${CYAN}Opening management menu...${NC}"
                create_management_script >/dev/null 2>&1
                exec /opt/conduit/conduit menu
                ;;
            2)
                echo ""
                log_info "Starting fresh reinstall..."
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
                main "$@"
                ;;
        esac
    fi

    # Interactive settings prompt
    prompt_settings
    
    echo ""
    echo -e "${CYAN}Starting installation...${NC}"
    echo ""
    
    # Installation steps
    log_info "Step 1/4: Installing Docker..."
    install_docker
    
    echo ""
    log_info "Step 2/4: Starting Conduit..."
    run_conduit
    
    echo ""
    log_info "Step 3/4: Setting up auto-start..."
    save_settings
    setup_autostart
    
    echo ""
    log_info "Step 4/4: Creating management script..."
    create_management_script
    
    print_summary
    
        read -p "View live statistics now? [Y/n] " view_stats < /dev/tty || true
    if [[ ! "$view_stats" =~ ^[Nn] ]]; then
        /opt/conduit/conduit stats
    fi
}
#
# REACHED END OF SCRIPT - VERSION 1.0.1
# ###############################################################################
main "$@"

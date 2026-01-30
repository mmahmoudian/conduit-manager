# Conduit Manager

```
  ██████╗ ██████╗ ███╗   ██╗██████╗ ██╗   ██╗██╗████████╗
 ██╔════╝██╔═══██╗████╗  ██║██╔══██╗██║   ██║██║╚══██╔══╝
 ██║     ██║   ██║██╔██╗ ██║██║  ██║██║   ██║██║   ██║
 ██║     ██║   ██║██║╚██╗██║██║  ██║██║   ██║██║   ██║
 ╚██████╗╚██████╔╝██║ ╚████║██████╔╝╚██████╔╝██║   ██║
  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═════╝  ╚═════╝ ╚═╝   ╚═╝
                      M A N A G E R
```

![Version](https://img.shields.io/badge/version-1.2-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Linux-orange)
![Docker](https://img.shields.io/badge/Docker-Required-2496ED?logo=docker&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-Script-4EAA25?logo=gnubash&logoColor=white)

A powerful management tool for deploying and managing Psiphon Conduit nodes on Linux servers. Help users access the open internet during network restrictions.

## Quick Install

```bash
curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh | sudo bash
```

Or download and run manually:

```bash
wget https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh
sudo bash conduit.sh
```

> For beta/preview releases, use `beta-releases` instead of `main` in the URL above.

## What's New in v1.2

**New Features**
- Per-container CPU and memory resource limits via Settings menu
- Resource limit prompts when adding containers in Container Management
- Smart defaults based on system specs (CPU cores, RAM)
- Telegram bot container management commands (`/containers`, `/restart_N`, `/stop_N`, `/start_N`)
- Telegram bot notifications with guided setup wizard (periodic status reports via Telegram)
- Systemd-based notification service (survives reboots and TUI exits)
- Compact number display — large counts show as 16.5K, 1.2M
- Active clients count in dashboard and Telegram reports
- Total bandwidth served in reports
- Timestamps on all Telegram reports

**Performance**
- Parallelized docker commands across all TUI screens (Status, Container Management, Advanced Stats, Live Peers)
- Batched docker inspect calls instead of per-container
- Parallel container stop/remove operations
- Reduced screen refresh time from ~10s to ~2-3s with multiple containers

**Bug Fixes**
- Auto-restart for stuck containers with improved detection
- False WAITING status in health check for connected containers without stats
- Container start/stop/restart logic with resource limit change detection
- Duplicate country entries in GeoIP data with broader name normalization
- TUI stability (multiple fixes)
- Health check edge cases
- CPU normalization in reports (divide by core count)
- Peers count consistency across views
- Telegram markdown escaping (backslash handling)
- Telegram container name mismatch (`conduit2` → `conduit-2`)
- Wizard failure paths now preserve existing config
- Uninstall cleanup for Telegram service
- Menu no longer restarts notification loop on every open
- PID management for background processes
- Consistent `[STATS]` grep pattern across all screens
- Temp dir cleanup to prevent stale data reads
- Atomic settings file writes to prevent corruption

**Security**
- Silent bot token input (not echoed)
- Numeric-only chat ID validation
- Restricted PID file permissions (600)
- BotFather privacy guidance in setup wizard
- OPSEC warning for operators in censored regions
- Curl calls with `--max-filesize` and `--max-time` limits
- Secure temp directories with `mktemp`

## Features

- **One-Click Deployment** — Automatically installs Docker and configures everything
- **Multi-Container Scaling** — Run 1–5 containers to maximize your server's capacity
- **Multi-Distro Support** — Works on Ubuntu, Debian, CentOS, Fedora, Arch, Alpine, openSUSE
- **Auto-Start on Boot** — Supports systemd, OpenRC, and SysVinit
- **Live Dashboard** — Real-time connection stats with CPU/RAM monitoring and per-country client breakdown
- **Advanced Stats** — Top countries by connected peers, download, upload, and unique IPs with bar charts
- **Live Peer Traffic** — Real-time traffic table by country with speed, total bytes, and IP/client counts
- **Background Tracker** — Continuous traffic monitoring via systemd service with GeoIP resolution
- **Telegram Notifications** — Optional periodic status reports and alerts via Telegram bot
- **Per-Container Settings** — Configure max-clients, bandwidth, CPU, and memory per container
- **Resource Limits** — Set CPU and memory limits with smart defaults based on system specs
- **Backup & Restore** — Backup and restore your node identity keys
- **Health Checks** — Comprehensive diagnostics for troubleshooting
- **Complete Uninstall** — Clean removal of all components including Telegram service

## Supported Distributions

| Family | Distributions |
|--------|---------------|
| Debian | Ubuntu, Debian, Linux Mint, Pop!_OS, Kali, Raspbian |
| RHEL | CentOS, Fedora, Rocky Linux, AlmaLinux, Amazon Linux |
| Arch | Arch Linux, Manjaro, EndeavourOS |
| SUSE | openSUSE Leap, openSUSE Tumbleweed |
| Alpine | Alpine Linux |

## CLI Reference

After installation, use the `conduit` command:

```bash
conduit menu         # Open interactive management menu
conduit status       # Show current status
conduit stats        # Live statistics dashboard
conduit peers        # Live peer traffic by country
conduit start        # Start all containers
conduit stop         # Stop all containers
conduit restart      # Restart all containers
conduit update       # Update Conduit image
conduit backup       # Backup node identity keys
conduit restore      # Restore from backup
conduit qr           # Show QR code for rewards
conduit health       # Run health diagnostics
conduit uninstall    # Remove all components
```

## Configuration

| Option | Default | Range | Description |
|--------|---------|-------|-------------|
| `max-clients` | 200 | 1–1000 | Max concurrent clients per container |
| `bandwidth` | 5 | 1–40, -1 | Bandwidth limit per peer (Mbps). -1 for unlimited |
| `cpu` | Unlimited | 0.1–N cores | CPU limit per container (e.g. 1.0 = one core) |
| `memory` | Unlimited | 64m–system RAM | Memory limit per container (e.g. 256m, 1g) |

## Requirements

- Linux server (any supported distribution)
- Root/sudo access
- Internet connection
- Minimum 512MB RAM (1GB+ recommended for multi-container)

## Upgrading

Just run the install command above or use `conduit update` from the menu. Existing containers are recognized automatically. Telegram settings are preserved across upgrades.

## Claim Rewards (OAT Tokens)

1. Install the **Ryve app** on your phone
2. Create a **crypto wallet** within the app
3. Run `conduit qr` or use the menu to show your QR code
4. Scan with Ryve to link your node and start earning

## Security

- **Secure Backups**: Node identity keys stored with restricted permissions (600)
- **No Telemetry**: The manager collects no data and sends nothing externally
- **Local Tracking Only**: Traffic stats are stored locally and never transmitted
- **Telegram Optional**: Bot notifications are opt-in only, zero resources used if disabled

---

## License

MIT License

## Contributing

Pull requests welcome. For major changes, open an issue first.

## Links

- [Psiphon](https://psiphon.ca/)
- [Psiphon Conduit](https://github.com/Psiphon-Inc/conduit)

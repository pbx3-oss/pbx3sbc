#!/bin/bash
#
# Setup sudoers configuration for pbx3sbc-admin panel
# This allows www-data to run fail2ban-client commands without password
#
# Usage:
#   sudo ./setup-admin-panel-sudoers.sh
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root (use sudo)${NC}" >&2
   exit 1
fi

SUDOERS_FILE="/etc/sudoers.d/pbx3sbc-admin"

# Detect sync / helper script paths
SYNC_SCRIPT_PATH=""
if [[ -f "/home/ubuntu/pbx3sbc/scripts/sync-fail2ban-whitelist.sh" ]]; then
    SYNC_SCRIPT_PATH="/home/ubuntu/pbx3sbc/scripts/sync-fail2ban-whitelist.sh"
elif [[ -f "/opt/pbx3sbc/scripts/sync-fail2ban-whitelist.sh" ]]; then
    SYNC_SCRIPT_PATH="/opt/pbx3sbc/scripts/sync-fail2ban-whitelist.sh"
elif [[ -f "/usr/local/pbx3sbc/scripts/sync-fail2ban-whitelist.sh" ]]; then
    SYNC_SCRIPT_PATH="/usr/local/pbx3sbc/scripts/sync-fail2ban-whitelist.sh"
else
    # Try to find it
    SYNC_SCRIPT_PATH=$(find /home /opt /usr/local -name "sync-fail2ban-whitelist.sh" 2>/dev/null | head -1)
    if [[ -z "$SYNC_SCRIPT_PATH" ]]; then
        echo -e "${YELLOW}Warning: Could not find sync-fail2ban-whitelist.sh${NC}"
        echo -e "${YELLOW}You may need to update the sudoers file manually with the correct path${NC}"
        SYNC_SCRIPT_PATH="/home/*/pbx3sbc/scripts/sync-fail2ban-whitelist.sh"
    fi
fi

BLACKLIST_SYNC_SCRIPT_PATH=""
if [[ -f "/home/ubuntu/pbx3sbc/scripts/sync-fail2ban-blacklist.sh" ]]; then
    BLACKLIST_SYNC_SCRIPT_PATH="/home/ubuntu/pbx3sbc/scripts/sync-fail2ban-blacklist.sh"
elif [[ -f "/opt/pbx3sbc/scripts/sync-fail2ban-blacklist.sh" ]]; then
    BLACKLIST_SYNC_SCRIPT_PATH="/opt/pbx3sbc/scripts/sync-fail2ban-blacklist.sh"
elif [[ -f "/usr/local/pbx3sbc/scripts/sync-fail2ban-blacklist.sh" ]]; then
    BLACKLIST_SYNC_SCRIPT_PATH="/usr/local/pbx3sbc/scripts/sync-fail2ban-blacklist.sh"
elif [[ -f "$(dirname "$0")/sync-fail2ban-blacklist.sh" ]]; then
    BLACKLIST_SYNC_SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/sync-fail2ban-blacklist.sh"
else
    BLACKLIST_SYNC_SCRIPT_PATH=$(find /home /opt /usr/local -name "sync-fail2ban-blacklist.sh" 2>/dev/null | head -1 || true)
    if [[ -z "$BLACKLIST_SYNC_SCRIPT_PATH" ]]; then
        echo -e "${YELLOW}Warning: Could not find sync-fail2ban-blacklist.sh${NC}"
        BLACKLIST_SYNC_SCRIPT_PATH="/home/ubuntu/pbx3sbc/scripts/sync-fail2ban-blacklist.sh"
    fi
fi

TAIL_LOG_SCRIPT_PATH=""
if [[ -f "/home/ubuntu/pbx3sbc/scripts/tail-fail2ban-log.sh" ]]; then
    TAIL_LOG_SCRIPT_PATH="/home/ubuntu/pbx3sbc/scripts/tail-fail2ban-log.sh"
elif [[ -f "/opt/pbx3sbc/scripts/tail-fail2ban-log.sh" ]]; then
    TAIL_LOG_SCRIPT_PATH="/opt/pbx3sbc/scripts/tail-fail2ban-log.sh"
elif [[ -f "/usr/local/pbx3sbc/scripts/tail-fail2ban-log.sh" ]]; then
    TAIL_LOG_SCRIPT_PATH="/usr/local/pbx3sbc/scripts/tail-fail2ban-log.sh"
else
    TAIL_LOG_SCRIPT_PATH=$(find /home /opt /usr/local -name "tail-fail2ban-log.sh" 2>/dev/null | head -1)
    if [[ -z "$TAIL_LOG_SCRIPT_PATH" ]]; then
        echo -e "${YELLOW}Warning: Could not find tail-fail2ban-log.sh${NC}"
        TAIL_LOG_SCRIPT_PATH="/home/ubuntu/pbx3sbc/scripts/tail-fail2ban-log.sh"
    fi
fi

LE_CERT_SCRIPT_PATH=""
if [[ -f "/home/ubuntu/pbx3sbc-admin/scripts/le-admin-cert.sh" ]]; then
    LE_CERT_SCRIPT_PATH="/home/ubuntu/pbx3sbc-admin/scripts/le-admin-cert.sh"
elif [[ -f "/opt/pbx3sbc-admin/scripts/le-admin-cert.sh" ]]; then
    LE_CERT_SCRIPT_PATH="/opt/pbx3sbc-admin/scripts/le-admin-cert.sh"
else
    LE_CERT_SCRIPT_PATH=$(find /home /opt /usr/local -name "le-admin-cert.sh" 2>/dev/null | head -1 || true)
fi

BACKUP_PANEL_SCRIPT_PATH=""
if [[ -f "/home/ubuntu/pbx3sbc/scripts/sbc-backup-panel.sh" ]]; then
    BACKUP_PANEL_SCRIPT_PATH="/home/ubuntu/pbx3sbc/scripts/sbc-backup-panel.sh"
elif [[ -f "/opt/pbx3sbc/scripts/sbc-backup-panel.sh" ]]; then
    BACKUP_PANEL_SCRIPT_PATH="/opt/pbx3sbc/scripts/sbc-backup-panel.sh"
elif [[ -f "$(dirname "$0")/sbc-backup-panel.sh" ]]; then
    BACKUP_PANEL_SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/sbc-backup-panel.sh"
else
    BACKUP_PANEL_SCRIPT_PATH=$(find /home /opt /usr/local -name "sbc-backup-panel.sh" 2>/dev/null | head -1 || true)
fi

MGMT_ACCESS_SCRIPT_PATH=""
if [[ -f "/home/ubuntu/pbx3sbc/scripts/apply-management-access-ufw.sh" ]]; then
    MGMT_ACCESS_SCRIPT_PATH="/home/ubuntu/pbx3sbc/scripts/apply-management-access-ufw.sh"
elif [[ -f "/opt/pbx3sbc/scripts/apply-management-access-ufw.sh" ]]; then
    MGMT_ACCESS_SCRIPT_PATH="/opt/pbx3sbc/scripts/apply-management-access-ufw.sh"
elif [[ -f "$(dirname "$0")/apply-management-access-ufw.sh" ]]; then
    MGMT_ACCESS_SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/apply-management-access-ufw.sh"
else
    MGMT_ACCESS_SCRIPT_PATH=$(find /home /opt /usr/local -name "apply-management-access-ufw.sh" 2>/dev/null | head -1 || true)
fi

PROV_ACCESS_SCRIPT_PATH=""
if [[ -f "/home/ubuntu/pbx3sbc/scripts/apply-provision-access-ufw.sh" ]]; then
    PROV_ACCESS_SCRIPT_PATH="/home/ubuntu/pbx3sbc/scripts/apply-provision-access-ufw.sh"
elif [[ -f "/opt/pbx3sbc/scripts/apply-provision-access-ufw.sh" ]]; then
    PROV_ACCESS_SCRIPT_PATH="/opt/pbx3sbc/scripts/apply-provision-access-ufw.sh"
elif [[ -f "$(dirname "$0")/apply-provision-access-ufw.sh" ]]; then
    PROV_ACCESS_SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/apply-provision-access-ufw.sh"
else
    PROV_ACCESS_SCRIPT_PATH=$(find /home /opt /usr/local -name "apply-provision-access-ufw.sh" 2>/dev/null | head -1 || true)
fi

echo -e "${GREEN}Setting up sudoers configuration for pbx3sbc-admin...${NC}"
echo ""

# Create sudoers file
cat > "$SUDOERS_FILE" <<EOF
# Sudoers configuration for pbx3sbc-admin panel
# Allows www-data user to run Fail2ban management commands without password

# Preserve environment variables for sync script (DB_NAME, DB_USER, DB_PASS)
# Try multiple syntaxes for compatibility
Defaults:www-data !env_reset
Defaults:www-data env_keep += "DB_NAME DB_USER DB_PASS"

# Systemd service status check
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl is-active fail2ban

# Fail2ban status and management commands
www-data ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client status opensips-brute-force
www-data ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client set opensips-brute-force banip *
www-data ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client set opensips-brute-force unbanip *
www-data ALL=(ALL) NOPASSWD: /usr/bin/fail2ban-client set opensips-brute-force unban --all

# Whitelist sync script (with environment variable preservation)
www-data ALL=(ALL) NOPASSWD: $SYNC_SCRIPT_PATH

# Permanent blacklist sync (iptables PBX3SBC-BLACKLIST)
www-data ALL=(ALL) NOPASSWD: $BLACKLIST_SYNC_SCRIPT_PATH

# Fail2ban log viewer (capped tail)
www-data ALL=(ALL) NOPASSWD: $TAIL_LOG_SCRIPT_PATH
EOF

if [[ -n "$LE_CERT_SCRIPT_PATH" ]]; then
    cat >> "$SUDOERS_FILE" <<EOF

# Let's Encrypt helper (Certificates panel)
www-data ALL=(ALL) NOPASSWD: $LE_CERT_SCRIPT_PATH *
EOF
fi

if [[ -n "$BACKUP_PANEL_SCRIPT_PATH" ]]; then
    cat >> "$SUDOERS_FILE" <<EOF

# SBC backup panel (list / create / vip-role)
www-data ALL=(ALL) NOPASSWD: $BACKUP_PANEL_SCRIPT_PATH *
EOF
fi

if [[ -n "$MGMT_ACCESS_SCRIPT_PATH" ]]; then
    cat >> "$SUDOERS_FILE" <<EOF

# Management access (Filament HTTPS :443 UFW lockdown)
www-data ALL=(ALL) NOPASSWD: $MGMT_ACCESS_SCRIPT_PATH *
EOF
fi

if [[ -n "$PROV_ACCESS_SCRIPT_PATH" ]]; then
    cat >> "$SUDOERS_FILE" <<EOF

# Provision access (phone provision HTTPS :41363 UFW lockdown — C10)
www-data ALL=(ALL) NOPASSWD: $PROV_ACCESS_SCRIPT_PATH *
EOF
fi

# php-fpm ProtectSystem=full blocks writing /etc/ufw even after sudo —
# install ReadWritePaths drop-in when available.
if [[ -f "$(dirname "$0")/setup-php-fpm-ufw-write.sh" ]]; then
    echo ""
    echo -e "${YELLOW}Note: Management / Provision access Apply needs php-fpm ReadWritePaths=/etc/ufw${NC}"
    echo -e "  ${GREEN}sudo $(cd "$(dirname "$0")" && pwd)/setup-php-fpm-ufw-write.sh${NC}"
fi

# Set correct permissions (sudoers files must be 0440)
chmod 0440 "$SUDOERS_FILE"

# Validate sudoers syntax
if visudo -c -f "$SUDOERS_FILE" 2>/dev/null; then
    echo -e "${GREEN}✓ Sudoers file created successfully: $SUDOERS_FILE${NC}"
    echo ""
    echo -e "${GREEN}Configuration:${NC}"
    cat "$SUDOERS_FILE"
    echo ""
    echo -e "${GREEN}✓ Sudoers syntax validated${NC}"
    echo ""
    echo -e "${YELLOW}Note: The changes take effect immediately.${NC}"
    echo -e "${YELLOW}You may need to restart your web server for www-data to pick up the changes:${NC}"
    echo -e "  ${GREEN}sudo systemctl restart php*-fpm${NC}  # For PHP-FPM"
    echo -e "  ${GREEN}sudo systemctl restart apache2${NC}   # For Apache"
    echo -e "  ${GREEN}sudo systemctl restart nginx${NC}      # For Nginx (if using PHP-FPM)"
else
    echo -e "${RED}Error: Sudoers syntax validation failed${NC}" >&2
    echo -e "${RED}Removing invalid file...${NC}" >&2
    rm -f "$SUDOERS_FILE"
    exit 1
fi

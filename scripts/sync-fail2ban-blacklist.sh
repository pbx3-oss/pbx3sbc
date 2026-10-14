#!/bin/bash
#
# Sync Fail2ban permanent blacklist from database to iptables chain PBX3SBC-BLACKLIST.
# Each row becomes: -s <ip_or_cidr> -j DROP (all protocols).
#
# Usage:
#   ./sync-fail2ban-blacklist.sh DB_NAME CREDS_FILE
#   # or cron: DB_NAME / DB_USER / DB_PASS env (password never on argv when using CREDS_FILE)
#
# Called from pbx3sbc-admin BlacklistSyncService (sudo) or cron.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CHAIN="PBX3SBC-BLACKLIST"

CREDS_FILE=""
CREDS_FILE_IS_TEMP=0

cleanup() {
    if [[ "$CREDS_FILE_IS_TEMP" -eq 1 && -n "$CREDS_FILE" && -f "$CREDS_FILE" ]]; then
        rm -f "$CREDS_FILE"
    fi
}
trap cleanup EXIT

if [[ $# -ge 2 ]]; then
    DB_NAME="$1"
    CREDS_FILE="$2"
    if [[ ! -f "$CREDS_FILE" ]]; then
        echo -e "${RED}Error: credentials file not found: $CREDS_FILE${NC}" >&2
        exit 1
    fi
else
    DB_NAME="${DB_NAME:-opensips}"
    DB_USER="${DB_USER:-opensips}"
    DB_PASS="${DB_PASS:-}"
    if [[ -z "$DB_PASS" ]]; then
        echo -e "${RED}Error: DB_PASS environment variable not set${NC}" >&2
        exit 1
    fi
    CREDS_FILE=$(mktemp)
    CREDS_FILE_IS_TEMP=1
    chmod 600 "$CREDS_FILE"
    {
        echo "[client]"
        echo "user=${DB_USER}"
        echo "password=${DB_PASS}"
    } > "$CREDS_FILE"
fi

MYSQL=(mysql "--defaults-extra-file=${CREDS_FILE}" "$DB_NAME")

ensure_chain() {
    if ! iptables -nL "$CHAIN" >/dev/null 2>&1; then
        iptables -N "$CHAIN"
        echo -e "${GREEN}Created chain $CHAIN${NC}"
    fi
    # Jump from INPUT (near top) if missing
    if ! iptables -nL INPUT | grep -q "$CHAIN"; then
        iptables -I INPUT 1 -j "$CHAIN"
        echo -e "${GREEN}Inserted INPUT jump to $CHAIN${NC}"
    fi
    if iptables -nL FORWARD >/dev/null 2>&1; then
        if ! iptables -nL FORWARD | grep -q "$CHAIN"; then
            iptables -I FORWARD 1 -j "$CHAIN" || true
        fi
    fi
}

flush_chain() {
    iptables -F "$CHAIN"
}

add_drop() {
    local entry="$1"
    # ip or cidr — iptables -s accepts both
    if [[ "$entry" =~ : ]]; then
        if command -v ip6tables >/dev/null 2>&1; then
            if ! ip6tables -nL "$CHAIN" >/dev/null 2>&1; then
                ip6tables -N "$CHAIN" 2>/dev/null || true
            fi
            if ! ip6tables -nL INPUT 2>/dev/null | grep -q "$CHAIN"; then
                ip6tables -I INPUT 1 -j "$CHAIN" 2>/dev/null || true
            fi
            ip6tables -A "$CHAIN" -s "$entry" -j DROP 2>/dev/null || \
                echo -e "${YELLOW}Warning: could not add IPv6 $entry${NC}" >&2
        else
            echo -e "${YELLOW}Skipping IPv6 $entry (no ip6tables)${NC}" >&2
        fi
        return
    fi
    iptables -A "$CHAIN" -s "$entry" -j DROP
}

echo "Reading permanent blacklist from database..."
mapfile -t ENTRIES < <("${MYSQL[@]}" -sN -e "
    SELECT ip_or_cidr
    FROM fail2ban_blacklist
    ORDER BY id;
" 2>/dev/null || true)

ensure_chain
flush_chain

COUNT=0
for entry in "${ENTRIES[@]:-}"; do
    entry=$(echo "$entry" | xargs)
    [[ -z "$entry" ]] && continue
    add_drop "$entry"
    COUNT=$((COUNT + 1))
done

# Terminal ACCEPT so non-matching traffic returns to INPUT
iptables -A "$CHAIN" -j RETURN

echo -e "${GREEN}Permanent blacklist synced: ${COUNT} DROP rule(s) in $CHAIN${NC}"
iptables -nL "$CHAIN" --line-numbers | head -40

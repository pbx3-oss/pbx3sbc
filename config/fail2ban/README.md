# Fail2ban Configuration for OpenSIPS Brute Force Detection

This directory contains Fail2ban configuration files for detecting and blocking brute force attacks against OpenSIPS.

## Overview

Fail2ban monitors OpenSIPS logs for security events and automatically blocks IP addresses that exceed configured thresholds. This implementation monitors two attack vectors:

1. **Failed Registration Attempts** - Password guessing attacks (403 Forbidden and other failures)
2. **Door-Knock Attempts** - Extension scanning, unknown domain probes, scanner activity, and **unknown-source INVITEs** to `sip:{user}@{VIP}` (not fleet Asterisk / not carrier Peer) — OpenSIPS **silently drops** (no SIP reply) + logs `Door-knock blocked: … (unknown source INVITE)`; Fail2ban bans after `maxretry`

## Files

- `opensips-failed-registrations.conf` - Filter for failed registration attempts (standalone)
- `opensips-door-knock.conf` - Filter for door-knock attempts (standalone)
- `opensips-combined.conf` - **Combined filter** (recommended - monitors both attack types)
- `opensips-brute-force.conf` - Jail configuration using the combined filter

## Installation

### 1. Install Fail2ban

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install fail2ban

# Verify installation
sudo systemctl status fail2ban
```

### 2. Copy Configuration Files

```bash
# Copy combined filter to Fail2ban filter directory (recommended)
sudo cp config/fail2ban/opensips-combined.conf /etc/fail2ban/filter.d/

# OR copy individual filters if you prefer separate jails:
# sudo cp config/fail2ban/opensips-failed-registrations.conf /etc/fail2ban/filter.d/
# sudo cp config/fail2ban/opensips-door-knock.conf /etc/fail2ban/filter.d/

# Copy jail configuration to Fail2ban jail directory
sudo cp config/fail2ban/opensips-brute-force.conf /etc/fail2ban/jail.d/
```

### 3. Configure Log Path

Edit `/etc/fail2ban/jail.d/opensips-brute-force.conf` and update the `logpath` to match your OpenSIPS log location:

```ini
# Common locations:
logpath = /var/log/opensips/opensips.log
# OR if using syslog:
# logpath = /var/log/syslog
```

To find your OpenSIPS log location:

```bash
# Check systemd service
systemctl status opensips | grep -i log

# Check OpenSIPS configuration
grep -i log /etc/opensips/opensips.cfg

# Check syslog
grep opensips /var/log/syslog | head -5
```

### 4. Restart Fail2ban

```bash
sudo systemctl restart fail2ban
sudo systemctl status fail2ban
```

### 5. Verify Configuration

```bash
# Check jail status
sudo fail2ban-client status opensips-brute-force

# Test combined filter (replace with actual log line from your logs)
echo "REGISTER: Failed registration logged to database - user@domain from 192.168.1.100:5060, response 403 Forbidden" | \
  fail2ban-regex /etc/fail2ban/filter.d/opensips-combined.conf -

# Test door-knock pattern
echo "Door-knock blocked: domain=example.com src=192.168.1.100 (not found)" | \
  fail2ban-regex /etc/fail2ban/filter.d/opensips-combined.conf -

# View Fail2ban logs
sudo tail -f /var/log/fail2ban.log
```

## Whitelist Management (CRITICAL for Production)

### Why Whitelisting is Essential

**⚠️ IMPORTANT:** In production environments, Fail2ban's IP-based blocking can cause issues:

- **NAT/Cluster Scenarios:** Multiple endpoints often share the same public IP address
- **One Bad Phone = Entire Cluster Blocked:** If one misconfigured phone triggers Fail2ban, the entire cluster gets blocked
- **Customer Impact:** Legitimate customers can be accidentally blocked, causing service outages

**Solution:** Always whitelist trusted customer IPs and network ranges before deploying Fail2ban to production.

### Using the Whitelist Management Script

We provide a helper script to manage whitelist entries:

```bash
# Add a single IP with comment
sudo ./scripts/manage-fail2ban-whitelist.sh add 203.0.113.50 "Customer A office"

# Add a CIDR range (entire network)
sudo ./scripts/manage-fail2ban-whitelist.sh add 198.51.100.0/24 "Customer B network"

# List all whitelisted IPs
sudo ./scripts/manage-fail2ban-whitelist.sh list

# Remove an IP from whitelist
sudo ./scripts/manage-fail2ban-whitelist.sh remove 203.0.113.50

# Show current configuration
sudo ./scripts/manage-fail2ban-whitelist.sh show
```

### Manual Whitelist Configuration

Edit `/etc/fail2ban/jail.d/opensips-brute-force.conf` and update the `ignoreip` parameter:

```ini
# Production whitelist - add your trusted customer IPs/ranges here
ignoreip = 203.0.113.50 203.0.113.51 198.51.100.0/24 2001:db8::1
```

**Format:**
- Single IP: `203.0.113.50`
- CIDR range: `198.51.100.0/24` (entire subnet)
- Multiple entries: Space-separated list
- IPv6 supported: `2001:db8::1` or `2001:db8::/32`

**After editing, restart Fail2ban:**
```bash
sudo systemctl restart fail2ban
```

### Whitelist Best Practices

1. **Identify Customer IPs Before Deployment:**
   - Query your database for unique source IPs from `failed_registrations` and `door_knock_attempts`
   - Identify which IPs belong to trusted customers vs. attackers

2. **Whitelist Customer Networks:**
   - Use CIDR ranges when possible (e.g., `/24` for entire customer network)
   - Document which customer each IP/range belongs to

3. **Regular Review:**
   - Periodically review whitelist entries
   - Remove IPs that are no longer in use
   - Update when customers change IPs

4. **Test Before Production:**
   - Test Fail2ban in a staging environment first
   - Verify whitelist entries work correctly
   - Monitor for false positives

5. **Emergency Unban:**
   - If a customer is accidentally blocked, unban immediately:
     ```bash
     sudo fail2ban-client set opensips-brute-force unbanip 203.0.113.50
     ```
   - Then add to whitelist to prevent future blocks:
     ```bash
     sudo ./scripts/manage-fail2ban-whitelist.sh add 203.0.113.50 "Customer A - whitelisted after false positive"
     ```

### Querying Database for Customer IPs

To identify which IPs belong to customers vs. attackers:

```sql
-- Find unique source IPs from failed registrations (last 30 days)
SELECT DISTINCT source_ip, COUNT(*) as failure_count
FROM failed_registrations
WHERE attempt_time > DATE_SUB(NOW(), INTERVAL 30 DAY)
GROUP BY source_ip
ORDER BY failure_count DESC;

-- Find unique source IPs from door-knock attempts (last 30 days)
SELECT DISTINCT source_ip, COUNT(*) as attempt_count
FROM door_knock_attempts
WHERE attempt_time > DATE_SUB(NOW(), INTERVAL 30 DAY)
GROUP BY source_ip
ORDER BY attempt_count DESC;

-- Find IPs with successful registrations (likely legitimate)
SELECT DISTINCT received, COUNT(*) as registration_count
FROM location
WHERE last_modified > DATE_SUB(NOW(), INTERVAL 30 DAY)
GROUP BY received
ORDER BY registration_count DESC;
```

## Configuration Options

### Thresholds

Edit `/etc/fail2ban/jail.d/opensips-brute-force.conf`:

- **maxretry** - Number of failures before banning (default: 10)
- **findtime** - Time window to count failures in seconds (default: 300 = 5 minutes)
- **bantime** - Ban duration in seconds (default: 3600 = 1 hour)

### Recommended Settings

**Production (Balanced):**
```ini
maxretry = 10
findtime = 300
bantime = 3600
```

**Aggressive (High Security):**
```ini
maxretry = 5
findtime = 180
bantime = 86400
```

**Permissive (Low False Positives):**
```ini
maxretry = 20
findtime = 600
bantime = 1800
```

## Monitoring

### Check Jail Status

```bash
# View all jails
sudo fail2ban-client status

# View specific jail
sudo fail2ban-client status opensips-brute-force

# View banned IPs
sudo fail2ban-client status opensips-brute-force | grep "Banned IP"
```

### View Logs

```bash
# Fail2ban logs
sudo tail -f /var/log/fail2ban.log

# OpenSIPS logs (adjust path as needed)
sudo tail -f /var/log/opensips/opensips.log
```

### Manual IP Management

```bash
# Ban an IP manually (short-term jail)
sudo fail2ban-client set opensips-brute-force banip 192.168.1.100

# Unban an IP
sudo fail2ban-client set opensips-brute-force unbanip 192.168.1.100

# Unban all IPs
sudo fail2ban-client set opensips-brute-force unban --all
```

### Permanent blacklist (iptables DROP)

Short-term Fail2ban bans expire with `bantime`. Persistent scanners belong on the **permanent blacklist** (admin panel → Fail2Ban → Permanent blacklist), synced to iptables chain `PBX3SBC-BLACKLIST` (DROP all from listed IPs/CIDRs).

```bash
# Sync DB → iptables (also run from admin panel Sync)
sudo ./scripts/sync-fail2ban-blacklist.sh   # needs DB_NAME/DB_USER/DB_PASS or args

# Inspect
sudo iptables -nL PBX3SBC-BLACKLIST --line-numbers
```

Auto-promote: after a lifetime temp-ban count reaches the threshold (default 10; 0 = off), cron `pbx3sbc:ops-fail2ban-bans` inserts a blacklist row and syncs. Spec: `pbx3sbc-admin/workingdocs/FAIL2BAN_PERMANENT_BLACKLIST_REQUIREMENTS.md`.

## Troubleshooting

### Filter Not Matching Log Entries

1. **Check log format**: Verify your OpenSIPS log format matches the filter patterns
   ```bash
   # View recent log entries
   sudo tail -20 /var/log/opensips/opensips.log
   ```

2. **Test filter manually**:
   ```bash
   # Test with actual log line
   echo "YOUR_LOG_LINE_HERE" | \
     fail2ban-regex /etc/fail2ban/filter.d/opensips-failed-registrations.conf -
   ```

3. **Adjust datepattern**: If your log format differs, update the `datepattern` in the filter files

### IPs Not Being Banned

1. **Check jail is active**:
   ```bash
   sudo fail2ban-client status opensips-brute-force
   ```

2. **Check iptables rules**:
   ```bash
   sudo iptables -L -n | grep fail2ban
   ```

3. **Check Fail2ban logs for errors**:
   ```bash
   sudo tail -50 /var/log/fail2ban.log | grep -i error
   ```

### False Positives

If legitimate IPs are being banned:

1. **Immediate Fix - Unban the IP:**
   ```bash
   sudo fail2ban-client set opensips-brute-force unbanip 203.0.113.50
   ```

2. **Permanent Fix - Add to Whitelist:**
   ```bash
   sudo ./scripts/manage-fail2ban-whitelist.sh add 203.0.113.50 "Customer A - whitelisted after false positive"
   ```

3. **Investigate Root Cause:**
   - Check why the IP triggered Fail2ban (misconfigured phone, password issues, etc.)
   - Review logs: `sudo grep "203.0.113.50" /var/log/opensips/opensips.log`
   - Check database: Query `failed_registrations` and `door_knock_attempts` tables

4. **Adjust Thresholds** (if needed):
   - Raise `maxretry` or `findtime` values if false positives are common
   - But prefer whitelisting known-good IPs over making thresholds too permissive

## Advanced Configuration

### Separate Jails

If you prefer separate jails for each attack type:

1. Create `opensips-failed-registrations.conf` in `/etc/fail2ban/jail.d/`:
   ```ini
   [opensips-failed-registrations]
   enabled = true
   filter = opensips-failed-registrations
   logpath = /var/log/opensips/opensips.log
   maxretry = 5
   findtime = 300
   bantime = 3600
   ```

2. Create `opensips-door-knock.conf` in `/etc/fail2ban/jail.d/`:
   ```ini
   [opensips-door-knock]
   enabled = true
   filter = opensips-door-knock
   logpath = /var/log/opensips/opensips.log
   maxretry = 10
   findtime = 300
   bantime = 3600
   ```

### Email Notifications

Add email action to jail configuration:

```ini
action = iptables[name=OPENSIPS, port=5060, protocol=udp]
         sendmail-whois[name=OPENSIPS, dest=admin@example.com, sender=fail2ban@example.com]
```

### Custom Actions

Create custom action scripts in `/etc/fail2ban/action.d/` for custom notification or blocking methods.

## Security Notes

- Fail2ban provides **system-level blocking** via iptables, which is more effective than application-level blocking
- IPs are blocked at the firewall, reducing load on OpenSIPS
- Ban duration and thresholds should be tuned based on your threat environment
- Monitor Fail2ban logs regularly to ensure it's working correctly
- **CRITICAL:** Always whitelist trusted customer IPs/ranges before production deployment
- In NAT/cluster environments, one misconfigured phone can trigger blocking for entire cluster
- Use the whitelist management script (`manage-fail2ban-whitelist.sh`) to manage trusted IPs
- Regularly review and update whitelist entries as customer IPs change

## Related Documentation

- [Security Implementation Plan](../docs/SECURITY-IMPLEMENTATION-PLAN.md) - Overall security project plan
- [Failed Registration Tracking](../docs/FAILED-REGISTRATION-TRACKING-COMPARISON.md) - Details on failed registration logging

## Support

For issues or questions:
1. Check Fail2ban logs: `/var/log/fail2ban.log`
2. Test filters manually using `fail2ban-regex`
3. Review OpenSIPS logs to verify log format matches filter patterns

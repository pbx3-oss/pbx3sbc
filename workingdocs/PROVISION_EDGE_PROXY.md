# Fleet edge provision proxy (C2 + C5)

**Status:** **C2+C5 lab green** on SBC (2026-10-02). Live: `PROVISION_MTLS=optional` + Snom/Yealink CA PEM.  
**2026-10-03:** **RSA dual-cert** on `:41363` — ECDSA-only LE cert caused Poly **Handshake Failure** (ClientHello with no ECDSA suites).  
**Spec:** `pbx3/workingdocs/PROVISIONING_SERVER_REQUIREMENTS.md` §0.3 / §6 / §8 / #3 / #11 · plan **C2/C5**.  
**Depends:** Gatekeeper **C3** MAC index + `catalog/provision-mac.map`.

## Shape

```text
Phone → https://provision.{apex}:41363/provisioning/{mac}.cfg
     or https://provision.{apex}:41363/provisioning/{mac}-reg.cfg   (Poly CONFIG_FILES)
     or https://provision.{apex}:41363/provisioning?mac={mac}   (Snom)
  → nginx [optional mTLS] → MAC extract → local provision-mac.map → http://{home}:41363
```

- Edge terminates **HTTPS**; **no** 3xx to home (topology hiding).
- **#11:** no routable MAC / Yealink `y000000*` / ignore list / bare `/provisioning` → **404**.
- **MAC extract:** `{mac}.cfg` **and** `{mac}-*.cfg` / `{mac}-*.xml` (Poly `-reg.cfg` etc.) — bare `{mac}.cfg`-only extract 404’d Poly settings (**lab 2026-10-03**).
- **#3:** map is a **static file** on the SBC; GET never calls gatekeeper/S3.
- **C5:** vendor client-cert verify against ops-held CA PEM (Snom + Yealink near-term).

## Install (SBC)

1. DNS: `provision.{apex}` A/AAAA → **edge VIP** (same VIP family as SIP).
2. LE cert for `provision.{apex}` (port **41363** is not 443 — use `certbot certonly --webroot` or DNS-01; reuse admin webroot on :80 if convenient, then point ssl paths at the new name).
3. **RSA dual-cert (required for Poly / some legacy desks):** Certbot defaults to **ECDSA**. Phones that only offer RSA suites get nginx **Fatal Handshake Failure** before HTTP. Issue a sibling RSA lineage and reinstall:

```bash
# Same webroot as the ECDSA cert (example):
sudo certbot certonly --webroot -w /home/ubuntu/pbx3sbc-admin/public \
  -d provision.pbx3.com --cert-name provision.pbx3.com-rsa --key-type rsa --rsa-key-size 2048
# install-provision-edge.sh auto-binds /etc/letsencrypt/live/${FQDN}-rsa when present
```

4. Open **UFW 41363/tcp** phone-facing on the edge (this is the public provision port). Homes stay **SBC-only** on 41363.
5. Install vhost (C2 only):

```bash
cd ~/pbx3sbc   # or deploy path
sudo PROVISION_FQDN=provision.pbx3.com ./scripts/install-provision-edge.sh
```

6. **C5 mTLS** (Snom + Yealink lab prove) — copy ops CA PEM then reinstall:

```bash
# On operator Mac (ops repo): build Snom+Yealink-only PEM from local inventory pack
./devdocs/provisioning/extract-snom-yealink-client-cas.sh \
  /path/to/ops-held-3pcerts.pem \
  ./devdocs/provisioning/inventory/vendor-client-cas-snom-yealink.pem

# On SBC:
sudo VENDOR_CLIENT_CA_BUNDLE=/path/to/vendor-client-cas-snom-yealink.pem \
     PROVISION_MTLS=optional \
     PROVISION_FQDN=provision.pbx3.com \
     ./scripts/install-provision-edge.sh
```

| `PROVISION_MTLS` | nginx `ssl_verify_client` | Behaviour |
|-------------------|--------------------------|-----------|
| `off` | (omitted) | No client-cert verify (default when no CA file) |
| `optional` | `optional` | **Lab default when CA present** — verify if phone presents cert; allow curl / manual-URL brands without cert |
| `require` | `on` | Hardened public edge — TLS fails without trusted client cert |

7. **MAC map sync (automatic):** enable the 1-minute systemd timer (also invoked from `install-provision-edge.sh` when `/etc/pbx3sbc/log-ship.env` has `PBX3_ORG_BUCKET`):

```bash
sudo ./scripts/install-provision-mac-map-sync-timer.sh
# systemctl list-timers pbx3-provision-mac-map-sync.timer
```

SPA Save → Gatekeeper claim publishes `catalog/provision-mac.map` to S3 immediately; the SBC picks it up within **~1 minute** (no Instance→SBC login hop). Force refresh:

```bash
sudo ./scripts/sync-provision-mac-map.sh
# or: sudo systemctl start pbx3-provision-mac-map-sync.service
```

Tip-hot push (Gatekeeper → SBC API on claim) is a later polish — not required when the timer is running.

8. Prove:

```bash
# known MAC in index → 200 from home via edge (path or ?mac=)
# With PROVISION_MTLS=optional, curl without client cert still works:
curl -sk -o /dev/null -w '%{http_code}\n' \
  "https://provision.pbx3.com:41363/provisioning/AABBCCDDEEFF.cfg"
curl -sk -o /dev/null -w '%{http_code}\n' \
  "https://provision.pbx3.com:41363/provisioning?mac=AABBCCDDEEFF"
# unknown / y000000 / bare /provisioning → 404
curl -sk -o /dev/null -w '%{http_code}\n' \
  "https://provision.pbx3.com:41363/provisioning/y000000000028.cfg"
```

Snom/Yealink phones that present a vendor client cert are verified (`$ssl_client_verify=SUCCESS`); edge forwards `X-SSL-Client-Verify` / `X-SSL-Client-S-DN` to home (audit only).

## Files

| Path | Role |
|------|------|
| `config/nginx/pbx3-provision-edge.conf` | HTTPS vhost template (`__MTLS_BLOCK__`) |
| `config/nginx/pbx3-provision-log-format.conf` | `log_format provision_mtls` (`$ssl_client_verify` + DN) |
| `config/nginx/mac-from-request.map` | URI/`?mac=` → `$provision_mac` |
| `config/nginx/provision-mac.map.example` | Empty map seed |
| `config/nginx/vendor-client-cas.pem.example` | Placeholder — **do not** commit real CAs |
| `scripts/install-provision-edge.sh` | Install maps + site + optional C5 CA + reload + MAC map timer |
| `scripts/install-provision-mac-map-sync-timer.sh` | Install/enable 1-minute S3→nginx map sync |
| `scripts/sync-provision-mac-map.sh` | Pull catalog artifact → local + reload (also timer ExecStart) |
| `systemd/pbx3-provision-mac-map-sync.{service,timer}` | Auto-sync units |

Live: `/etc/nginx/pbx3-provision/` (`provision-mac.map`, `vendor-client-cas.pem`) + `conf.d/pbx3-provision-maps.conf` + `conf.d/pbx3-provision-log-format.conf`.

## Lab status

- **C2 (2026-09-30):** DNS **A** `provision.pbx3.com` → **`3.93.26.82`**; LE; known MAC **200** / unknown **404**.
- **C5 (2026-10-02):** Yealink T31P **402** (`249ad89b435b`) — `$ssl_client_verify=SUCCESS`, **200** on `.cfg`. Bare curl under `optional` → **NONE**/200; under `require` → **400**. Snom D717 **401** reboot GET **200** (UA present). Left on **`optional`**.
- **MAC map timer (2026-10-03):** `pbx3-provision-mac-map-sync.timer` every **1 min** — SPA claim no longer needs manual SBC sync.

## Related

- Home listener: `pbx3` `install-provision-listener.sh` (fleet HTTP).
- Catalog claim: gatekeeper `POST /api/v1/mac-index/claim` (instance hook on MAC assign).
- Ops CA inventory: `~/GiT/pbx3-ops/devdocs/provisioning/VENDOR_CLIENT_CA_INVENTORY.md`
- Optional: **C10** Provision access IP allowlist — Filament **System → Provision access** + `scripts/apply-provision-access-ufw.sh` (complements mTLS).

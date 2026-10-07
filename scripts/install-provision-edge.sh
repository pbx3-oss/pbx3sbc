#!/bin/sh
# Install fleet edge provision nginx vhost (provision.{apex}:41363).
# Spec: PROVISIONING_IMPLEMENTATION_PLAN.md C2 / C5
#
# Usage (root on SBC):
#   install-provision-edge.sh
#   PROVISION_FQDN=provision.pbx3.com SSL_CERT=... SSL_KEY=... install-provision-edge.sh
#   VENDOR_CLIENT_CA_BUNDLE=/path/to/cas.pem PROVISION_MTLS=optional install-provision-edge.sh
#
# Requires: nginx, LE cert for provision FQDN (or paths via env).
# Idempotent.
set -eu

SCRIPTS="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO="$(CDPATH= cd -- "$SCRIPTS/.." && pwd)"
CONF_SRC="$REPO/config/nginx"
CONF_DST="/etc/nginx/pbx3-provision"
SITE_NAME="pbx3-provision-edge.conf"
AVAILABLE="/etc/nginx/sites-available/$SITE_NAME"
ENABLED="/etc/nginx/sites-enabled/$SITE_NAME"
HTTP_SNIPPET="/etc/nginx/conf.d/pbx3-provision-maps.conf"
LOG_SNIPPET="/etc/nginx/conf.d/pbx3-provision-log-format.conf"
CA_DST="$CONF_DST/vendor-client-cas.pem"

PROVISION_FQDN="${PROVISION_FQDN:-provision.pbx3.com}"
SSL_CERT="${SSL_CERT:-/etc/letsencrypt/live/${PROVISION_FQDN}/fullchain.pem}"
SSL_KEY="${SSL_KEY:-/etc/letsencrypt/live/${PROVISION_FQDN}/privkey.pem}"
# Optional RSA dual-cert for Poly/legacy desks (ECDSA-only LE breaks Handshake Failure).
# Default: sibling lineage ${PROVISION_FQDN}-rsa when present.
SSL_CERT_RSA="${SSL_CERT_RSA:-/etc/letsencrypt/live/${PROVISION_FQDN}-rsa/fullchain.pem}"
SSL_KEY_RSA="${SSL_KEY_RSA:-/etc/letsencrypt/live/${PROVISION_FQDN}-rsa/privkey.pem}"
VENDOR_CLIENT_CA_BUNDLE="${VENDOR_CLIENT_CA_BUNDLE:-}"
PROVISION_MTLS="${PROVISION_MTLS:-}"

die() { echo "install-provision-edge: $*" >&2; exit 1; }
log() { echo "install-provision-edge: $*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v nginx >/dev/null 2>&1 || die "nginx not installed"
[ -f "$CONF_SRC/pbx3-provision-edge.conf" ] || die "missing $CONF_SRC/pbx3-provision-edge.conf"
[ -f "$CONF_SRC/mac-from-request.map" ] || die "missing mac-from-request.map"
[ -f "$SSL_CERT" ] || die "missing SSL cert $SSL_CERT — issue LE for $PROVISION_FQDN first"
[ -f "$SSL_KEY" ] || die "missing SSL key $SSL_KEY"

mkdir -p "$CONF_DST" /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d

cp "$CONF_SRC/mac-from-request.map" "$CONF_DST/mac-from-request.map"
if [ ! -f "$CONF_DST/provision-mac.map" ]; then
	cp "$CONF_SRC/provision-mac.map.example" "$CONF_DST/provision-mac.map"
	log "seeded empty provision-mac.map — timer / sync-provision-mac-map.sh will populate after MAC claims"
fi

# C5 — vendor client CA bundle (ops-supplied; never required in git)
if [ -n "$VENDOR_CLIENT_CA_BUNDLE" ]; then
	[ -f "$VENDOR_CLIENT_CA_BUNDLE" ] || die "VENDOR_CLIENT_CA_BUNDLE not a file: $VENDOR_CLIENT_CA_BUNDLE"
	cp "$VENDOR_CLIENT_CA_BUNDLE" "$CA_DST"
	chmod 0644 "$CA_DST"
	log "installed vendor-client-cas.pem from $VENDOR_CLIENT_CA_BUNDLE"
fi

case "${PROVISION_MTLS}" in
	""|off|optional|require) ;;
	*) die "PROVISION_MTLS must be off|optional|require (got: $PROVISION_MTLS)" ;;
esac

if [ -z "$PROVISION_MTLS" ]; then
	if [ -f "$CA_DST" ] && [ -s "$CA_DST" ]; then
		PROVISION_MTLS=optional
	else
		PROVISION_MTLS=off
	fi
fi

# nginx vocabulary: require → on (not the literal "require")
SSL_VERIFY_CLIENT="$PROVISION_MTLS"
if [ "$PROVISION_MTLS" = "require" ]; then
	SSL_VERIFY_CLIENT=on
fi

MTLS_FILE="$(mktemp)"
trap 'rm -f "$MTLS_FILE"' EXIT
if [ "$PROVISION_MTLS" != "off" ]; then
	[ -f "$CA_DST" ] && [ -s "$CA_DST" ] || die "PROVISION_MTLS=$PROVISION_MTLS needs non-empty $CA_DST (set VENDOR_CLIENT_CA_BUNDLE=…)"
	# Indent to match server{} body (file — portable; avoid awk -v multiline)
	{
		echo "    # C5 vendor client-cert verify (PROVISION_MTLS=${PROVISION_MTLS} → ssl_verify_client ${SSL_VERIFY_CLIENT})"
		echo "    ssl_client_certificate ${CA_DST};"
		echo "    ssl_verify_client ${SSL_VERIFY_CLIENT};"
		echo "    ssl_verify_depth 3;"
		echo ""
	} > "$MTLS_FILE"
	log "mTLS enabled: ssl_verify_client ${SSL_VERIFY_CLIENT} (PROVISION_MTLS=${PROVISION_MTLS})"
else
	: > "$MTLS_FILE"
	log "mTLS off (no client-cert verify)"
fi

# http{} map includes + C5 access log_format (conf.d is pulled into http on Ubuntu nginx)
if [ -f "$CONF_SRC/pbx3-provision-log-format.conf" ]; then
	cp "$CONF_SRC/pbx3-provision-log-format.conf" "$LOG_SNIPPET"
fi
cat > "$HTTP_SNIPPET" <<EOF
# PBX3 provision edge — MAC extract + catalog map (C2 / #3)
include $CONF_DST/mac-from-request.map;
include $CONF_DST/provision-mac.map;
EOF

RSA_BLOCK_FILE="$(mktemp)"
if [ -f "$SSL_CERT_RSA" ] && [ -f "$SSL_KEY_RSA" ]; then
	{
		echo "    # Dual-cert RSA lineage (Poly/legacy — ECDSA-only ClientHello → Handshake Failure)"
		echo "    ssl_certificate     ${SSL_CERT_RSA};"
		echo "    ssl_certificate_key ${SSL_KEY_RSA};"
	} > "$RSA_BLOCK_FILE"
	log "RSA dual-cert enabled: $SSL_CERT_RSA"
else
	: > "$RSA_BLOCK_FILE"
	log "RSA dual-cert skipped (no $SSL_CERT_RSA) — issue: certbot certonly --webroot -w … -d $PROVISION_FQDN --cert-name ${PROVISION_FQDN}-rsa --key-type rsa"
fi

# Substitute placeholders; splice RSA + mTLS blocks at markers
TMP_SITE="$(mktemp)"
sed -e "s|__PROVISION_SERVER_NAME__|${PROVISION_FQDN}|g" \
	-e "s|__SSL_CERTIFICATE__|${SSL_CERT}|g" \
	-e "s|__SSL_CERTIFICATE_KEY__|${SSL_KEY}|g" \
	"$CONF_SRC/pbx3-provision-edge.conf" > "$TMP_SITE"

awk -v mtlsfile="$MTLS_FILE" -v rsafile="$RSA_BLOCK_FILE" '
	$0 == "__SSL_RSA_CERTIFICATE_BLOCK__" {
		while ((getline line < rsafile) > 0) print line
		close(rsafile)
		next
	}
	$0 == "__MTLS_BLOCK__" {
		while ((getline line < mtlsfile) > 0) print line
		close(mtlsfile)
		next
	}
	{ print }
' "$TMP_SITE" > "$AVAILABLE"
rm -f "$TMP_SITE" "$RSA_BLOCK_FILE"

ln -sfn "$AVAILABLE" "$ENABLED"

nginx -t || die "nginx -t failed"
systemctl reload nginx
log "enabled $ENABLED for $PROVISION_FQDN:41363 (mTLS=$PROVISION_MTLS)"

# 1-minute catalog → nginx map sync (SPA Save claim no longer needs manual SBC sync)
if [ -x "$SCRIPTS/install-provision-mac-map-sync-timer.sh" ]; then
	if "$SCRIPTS/install-provision-mac-map-sync-timer.sh"; then
		log "MAC map sync timer enabled"
	else
		log "WARN: MAC map sync timer install failed — run install-provision-mac-map-sync-timer.sh after /etc/pbx3sbc/log-ship.env is set"
	fi
fi

log "next: DNS A $PROVISION_FQDN → edge VIP; open UFW 41363/tcp public (phone-facing)"
log "map sync: timer every 1 min (manual: sync-provision-mac-map.sh)"
if [ "$PROVISION_MTLS" = "optional" ]; then
	log "lab tip: curl without client cert still works; Snom/Yealink with vendor client certs are verified"
elif [ "$PROVISION_MTLS" = "require" ]; then
	log "hardened: phones without trusted client cert will fail TLS handshake"
fi

#!/usr/bin/env bash
#
# install-mail.sh — private mail server on a Tailscale tailnet.
# OpenSMTPD (SMTP submission) + Dovecot CE 2.4 (IMAP + LMTP delivery),
# using a Tailscale-issued TLS certificate so clients get no warnings.
#
# Usage:
#   sudo bash install-mail.sh              # install or reconfigure
#   sudo bash install-mail.sh --check      # verify only (no changes)
#   sudo bash install-mail.sh --renew-cert # renew the TLS certificate now
#
# Environment overrides:
#   LOCAL_USER=mcsquirrel   human mailbox owner (must already exist)
#   AGENT_USER=agent-bot    agent account to create/use
#   DOMAIN=<name.ts.net>    mail domain (default: this node's MagicDNS name)
#   RESET_AGENT_PASSWORD=1  rotate the agent password even if it exists
#
# Idempotent: safe to re-run after a Tailscale IP change or package upgrade.

set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SELF_DIR/config"

LOCAL_USER="${LOCAL_USER:-mcsquirrel}"
AGENT_USER="${AGENT_USER:-agent-bot}"
DOMAIN="${DOMAIN:-}"
RESET_AGENT_PASSWORD="${RESET_AGENT_PASSWORD:-0}"

CERT_DIR=/etc/ssl/tailscale
CERT_FILE="$CERT_DIR/mail.crt"
KEY_FILE="$CERT_DIR/mail.key"
CRED_FILE=/root/mail-credentials.txt
DEFAULTS_FILE=/etc/default/mail-setup

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

MODE=install
case "${1:-}" in
    "")            ;;
    --check)       MODE=check ;;
    --renew-cert)  MODE=renew ;;
    -h|--help)     sed -n '2,22p' "$0"; exit 0 ;;
    *)             die "unknown argument: $1 (try --help)" ;;
esac

[[ ${EUID} -eq 0 ]] || die "run with sudo: sudo bash $0 ${1:-}"

# ---------------------------------------------------------------- tailnet ---

detect_tailnet() {
    command -v tailscale >/dev/null || die "tailscale is not installed"

    local json
    json="$(tailscale status --json 2>/dev/null)" \
        || die "cannot read 'tailscale status' (is tailscaled running?)"

    local detected https line
    line="$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = d.get("Self") or {}
caps = [str(c) for c in (s.get("Capabilities") or [])]
print((s.get("DNSName") or "").rstrip(".") or "-",
      "yes" if "https" in caps else "no")
' 2>/dev/null || true)"
    [[ -n $line ]] || die "could not parse 'tailscale status --json'"
    read -r detected https <<<"$line"

    [[ $detected != "-" ]] || die "this node has no MagicDNS name; is Tailscale logged in?"
    [[ $https == "yes" ]] || die \
"HTTPS certificates are not enabled for this tailnet.
   Open the Tailscale admin console -> DNS -> enable 'HTTPS Certificates',
   then re-run this script."

    TS_DOMAIN="$detected"
    TS_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
    [[ -n $TS_IP ]] || die "this node has no Tailscale IPv4 address"

    DOMAIN="${DOMAIN:-$TS_DOMAIN}"
    BIND_IP="$TS_IP"
}

detect_tailnet

if [[ $MODE == check ]]; then
    exec bash "$SELF_DIR/verify-mail.sh"
fi

if [[ $MODE == renew ]]; then
    [[ -x /usr/local/sbin/mail-cert-renew ]] \
        || die "mail-cert-renew is not installed; run 'sudo bash $0' first"
    exec /usr/local/sbin/mail-cert-renew
fi

if [[ $DOMAIN != "$TS_DOMAIN" ]]; then
    warn "DOMAIN ($DOMAIN) differs from this node's MagicDNS name ($TS_DOMAIN)."
    warn "Clients must be able to reach $DOMAIN and its certificate must cover it."
fi

[[ -f $CONFIG_DIR/dovecot.conf.in ]] || die "missing $CONFIG_DIR/dovecot.conf.in"

# --------------------------------------------------------------- packages ---

need_packages=0
for pkg in opensmtpd dovecot-core dovecot-imapd dovecot-lmtpd; do
    dpkg -s "$pkg" >/dev/null 2>&1 || need_packages=1
done

if (( need_packages )); then
    log "Installing OpenSMTPD and Dovecot CE"
    export DEBIAN_FRONTEND=noninteractive
    echo "opensmtpd opensmtpd/mailname string $DOMAIN" | debconf-set-selections
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        opensmtpd dovecot-core dovecot-imapd dovecot-lmtpd openssl python3
    info "packages installed"
else
    log "Packages already installed"
fi

# ------------------------------------------------------------ certificate ---

log "TLS certificate for $DOMAIN"
install -d -m 0755 -o root -g root "$CERT_DIR"

cert_needs_renewal=0
if [[ ! -s $CERT_FILE || ! -s $KEY_FILE ]]; then
    cert_needs_renewal=1
elif ! openssl x509 -checkend $((14 * 24 * 3600)) -noout -in "$CERT_FILE" >/dev/null 2>&1; then
    cert_needs_renewal=1
elif ! openssl x509 -in "$CERT_FILE" -noout -checkhost "$DOMAIN" 2>/dev/null | grep -q 'does match'; then
    cert_needs_renewal=1
fi

if (( cert_needs_renewal )); then
    tmp="$(mktemp -d)"
    if ! tailscale cert --cert-file "$tmp/mail.crt" --key-file "$tmp/mail.key" "$DOMAIN"; then
        rm -rf "$tmp"
        die "tailscale cert failed — check that HTTPS certificates are enabled and
   that '$DOMAIN' is this node's name in the tailnet."
    fi
    install -m 0644 -o root -g root "$tmp/mail.crt" "$CERT_FILE"
    install -m 0600 -o root -g root "$tmp/mail.key" "$KEY_FILE"
    rm -rf "$tmp"
    info "issued: $(openssl x509 -in "$CERT_FILE" -noout -subject -enddate | tr '\n' ' ')"
else
    info "already present and valid for >14 days:"
    info "$(openssl x509 -in "$CERT_FILE" -noout -enddate)"
    chmod 0644 "$CERT_FILE"
    chmod 0600 "$KEY_FILE"
fi

# ---------------------------------------------------------------- accounts ---

log "Mail accounts"
id -u "$LOCAL_USER" >/dev/null 2>&1 \
    || die "local user '$LOCAL_USER' does not exist"

agent_created=0
first_setup=0
[[ -e $DEFAULTS_FILE ]] || first_setup=1

if ! id -u "$AGENT_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /usr/sbin/nologin \
            --comment "AI agent mail account" "$AGENT_USER"
    agent_created=1
    info "created account $AGENT_USER (nologin: mail only, no SSH)"
else
    info "account $AGENT_USER already exists"
fi
info "addresses: $LOCAL_USER@$DOMAIN and $AGENT_USER@$DOMAIN"

if (( agent_created )) || [[ $RESET_AGENT_PASSWORD == 1 ]] \
   || { (( first_setup )) && [[ ! -s $CRED_FILE ]]; }; then
    agent_password="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
    printf '%s:%s\n' "$AGENT_USER" "$agent_password" | chpasswd
    (
        umask 077
        cat > "$CRED_FILE" <<EOF
# Generated by install-mail.sh on $(date -Is)
# Move this password into your password manager, then delete this file.
host      = $DOMAIN
imap      = imaps://$DOMAIN:993
smtp      = smtps://$DOMAIN:465   (STARTTLS alternative: $DOMAIN:587)
username  = $AGENT_USER
password  = $agent_password
address   = $AGENT_USER@$DOMAIN
EOF
    )
    chmod 0600 "$CRED_FILE"
    info "agent password set → $CRED_FILE (mode 600)"
else
    info "agent password unchanged (set RESET_AGENT_PASSWORD=1 to rotate)"
fi

# ---------------------------------------------------------------- configs ---

backup_once() {
    local f=$1
    if [[ -e $f || -L $f ]] && [[ ! -e $f.orig-mail-setup ]]; then
        cp -a "$f" "$f.orig-mail-setup"
        info "backed up $f → $f.orig-mail-setup"
    fi
}

render() { # template destination mode
    local tmp
    tmp="$(mktemp)"
    sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__BIND_IP__|$BIND_IP|g" "$1" > "$tmp"
    install -m "$3" -o root -g root "$tmp" "$2"
    rm -f "$tmp"
}

log "Writing configuration"
printf '%s\n' "$DOMAIN" > /etc/mailname

backup_once /etc/dovecot/dovecot.conf
rm -f /etc/dovecot/dovecot.conf      # package ships a symlink; replace it
render "$CONFIG_DIR/dovecot.conf.in" /etc/dovecot/dovecot.conf 0644
info "/etc/dovecot/dovecot.conf"

backup_once /etc/smtpd.conf
render "$CONFIG_DIR/smtpd.conf.in" /etc/smtpd.conf 0644
info "/etc/smtpd.conf"

install -m 0644 -o root -g root "$CONFIG_DIR/pam.d-dovecot" /etc/pam.d/dovecot
install -m 0644 -o root -g root "$CONFIG_DIR/pam.d-smtpd"  /etc/pam.d/smtpd
info "/etc/pam.d/dovecot and /etc/pam.d/smtpd"

# Aliases: route daemon mail to the human rather than to root's spool.
touch /etc/aliases
aliases_changed=0
if ! grep -qE "^root:[[:space:]]*${LOCAL_USER}$" /etc/aliases; then
    printf 'root: %s\n' "$LOCAL_USER" >> /etc/aliases
    aliases_changed=1
fi
if ! grep -qE '^postmaster:' /etc/aliases; then
    printf 'postmaster: root\n' >> /etc/aliases
    aliases_changed=1
fi
if (( aliases_changed )); then
    /usr/sbin/newaliases >/dev/null 2>&1 || true
    info "/etc/aliases updated (root → $LOCAL_USER)"
fi

# Start only after tailscaled has the address we bind to.
for unit in dovecot opensmtpd; do
    install -d -m 0755 "/etc/systemd/system/${unit}.service.d"
    cat > "/etc/systemd/system/${unit}.service.d/10-tailscale.conf" <<'EOF'
[Unit]
After=tailscaled.service network-online.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=2s
EOF
done

# Certificate renewal: Tailscale certs last ~90 days.
install -d -m 0755 /usr/local/sbin
render "$CONFIG_DIR/mail-cert-renew.sh.in" /usr/local/sbin/mail-cert-renew 0755
install -m 0644 -o root -g root \
    "$CONFIG_DIR/mail-cert-renew.service" /etc/systemd/system/mail-cert-renew.service
install -m 0644 -o root -g root \
    "$CONFIG_DIR/mail-cert-renew.timer" /etc/systemd/system/mail-cert-renew.timer

cat > "$DEFAULTS_FILE" <<EOF
# Written by install-mail.sh — reference copy of this mail setup.
MAIL_DOMAIN=$DOMAIN
MAIL_BIND_IP=$BIND_IP
MAIL_LOCAL_USER=$LOCAL_USER
MAIL_AGENT_USER=$AGENT_USER
EOF
chmod 0644 "$DEFAULTS_FILE"

# --------------------------------------------------------------- services ---

log "Validating configuration"
/usr/sbin/smtpd -n || die "smtpd.conf failed validation (see error above)"
/usr/bin/doveconf -n >/dev/null || die "dovecot.conf failed validation (see error above)"
info "smtpd.conf and dovecot.conf are syntactically valid"

log "Starting services"
systemctl daemon-reload
systemctl enable dovecot.service opensmtpd.service >/dev/null
systemctl enable --now mail-cert-renew.timer >/dev/null

systemctl restart dovecot.service || true
systemctl restart opensmtpd.service || true

for _ in $(seq 1 20); do
    if systemctl is-active --quiet dovecot.service \
       && systemctl is-active --quiet opensmtpd.service; then
        info "dovecot and opensmtpd are active"
        break
    fi
    sleep 0.5
done

if ! systemctl is-active --quiet dovecot.service; then
    journalctl -u dovecot.service -n 20 --no-pager || true
    die "dovecot failed to start"
fi
if ! systemctl is-active --quiet opensmtpd.service; then
    journalctl -u opensmtpd.service -n 20 --no-pager || true
    die "opensmtpd failed to start"
fi

# ----------------------------------------------------------------- summary ---

printf '\n\033[1;32mSetup complete\033[0m\n\n'
printf '  Mail domain   : %s\n' "$DOMAIN"
printf '  Tailnet bind  : %s\n' "$BIND_IP"
printf '  Mailboxes     : %s@%s, %s@%s\n' "$LOCAL_USER" "$DOMAIN" "$AGENT_USER" "$DOMAIN"
printf '  IMAP          : %s:993  (TLS)\n' "$DOMAIN"
printf '  SMTP          : %s:465  (TLS) / :587 (STARTTLS)\n' "$DOMAIN"
if [[ -s $CRED_FILE ]]; then
    printf '  Credentials   : %s\n' "$CRED_FILE"
fi
printf '  Cert renewal  : weekly systemd timer (mail-cert-renew.timer)\n'
printf '  Agent client  : python3 %s/scripts/tailmail.py --help\n' "$SELF_DIR"

printf '\nNext: store the agent password, then run\n'
printf '  sudo bash %s/verify-mail.sh\n\n' "$SELF_DIR"

exec bash "$SELF_DIR/verify-mail.sh"

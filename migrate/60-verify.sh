#!/usr/bin/env bash
#
# 60-verify.sh — end-to-end checks for the Stalwart deployment.
# Run as root:  sudo bash migrate/60-verify.sh
#
# Checks services, listeners, TLS, IMAP login, SMTP AUTH, delivery and the
# webmail/admin HTTP endpoints. Sends exactly one test message.

set -uo pipefail

PASS=0
FAIL=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }

CRED_FILE=/root/mail-credentials.txt
CERT_FILE=/etc/ssl/tailscale/mail.crt

if [[ -r /etc/default/mail-setup ]]; then
    # shellcheck disable=SC1091
    . /etc/default/mail-setup
fi
DOMAIN="${MAIL_DOMAIN:-}"
BIND_IP="${MAIL_BIND_IP:-$(tailscale ip -4 2>/dev/null | head -n1 || true)}"
LOCAL_USER="${MAIL_LOCAL_USER:-mcsquirrel}"
AGENT_USER="${MAIL_AGENT_USER:-agent-bot}"
[[ -n $DOMAIN && -n $BIND_IP ]] || { echo "cannot determine domain or tailnet address" >&2; exit 1; }

printf '\n\033[1mStalwart verification — %s (%s)\033[0m\n\n' "$DOMAIN" "$BIND_IP"

# --------------------------------------------------------------- services ---

echo "Services"
if systemctl is-active --quiet stalwart.service; then
    pass "stalwart is active"
else
    fail "stalwart is not active — journalctl -u stalwart -n 50"
fi
for svc in dovecot opensmtpd; do
    if systemctl is-active --quiet "$svc.service"; then
        fail "$svc is still active (should be disabled after cutover)"
    else
        pass "$svc is stopped"
    fi
done

# -------------------------------------------------------------- listeners ---

echo
echo "Listening sockets"
socks="$(ss -ltnH 2>/dev/null | awk '{print $4}')"
has() { grep -qxF "$1" <<<"$socks"; }
for port in 25 465 587 993 443; do
    if has "${BIND_IP}:${port}"; then
        pass "tailnet listener on ${BIND_IP}:${port}"
    else
        fail "nothing on ${BIND_IP}:${port}"
    fi
done
if has "0.0.0.0:8080" || has "[::]:8080" || has "*:8080"; then
    fail "port 8080 is still open (recovery mode left running?)"
else
    pass "no recovery listener on 8080"
fi
leaked=""
for port in 25 465 587 993 443; do
    if grep -qE "^0\.0\.0\.0:${port}$|^\[::\]:${port}$|^\*:${port}$" <<<"$socks"; then
        leaked="$leaked $port"
    fi
done
if [[ -z $leaked ]]; then
    pass "no wildcard binds on mail ports"
else
    fail "wildcard bind on port(s):$leaked"
fi

# -------------------------------------------------------------------- TLS ---

echo
echo "TLS"
tls_test() { # description address extra args...
    local desc=$1 address=$2
    shift 2
    if openssl s_client -connect "$address" \
            -servername "$DOMAIN" -verify_hostname "$DOMAIN" \
            -verify_return_error -CAfile /etc/ssl/certs/ca-certificates.crt \
            "$@" </dev/null >/dev/null 2>&1; then
        pass "$desc ($address)"
    else
        fail "$desc ($address)"
    fi
}
tls_test "IMAPS" "${BIND_IP}:993"
tls_test "SMTPS" "${BIND_IP}:465"
tls_test "SMTP STARTTLS" "${BIND_IP}:587" -starttls smtp
tls_test "HTTPS" "${BIND_IP}:443"

if [[ -r $CERT_FILE ]]; then
    if openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1; then
        pass "certificate valid ($(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2))"
    else
        fail "certificate expired"
    fi
else
    fail "certificate file missing"
fi

# ------------------------------------------------------------------- auth ---

echo
echo "Authentication and delivery"
if [[ ! -r $CRED_FILE ]]; then
    skip "no $CRED_FILE — cannot test SMTP AUTH / IMAP"
else
    local_pw="$(awk -F'= *' '/^mcsquirrel[[:space:]]*=/{print $2; exit}' "$CRED_FILE" | awk '{print $1}')"
    app_secret="$(awk -F'= *' '/^app-password/{print $2; exit}' "$CRED_FILE" | awk '{print $1}')"

    if [[ -z $local_pw || -z $app_secret ]]; then
        skip "credentials file lacks mcsquirrel password or app-password"
    elif python3 - "$DOMAIN" "$LOCAL_USER@$DOMAIN" "$local_pw" "$AGENT_USER@$DOMAIN" "$app_secret" <<'PY'
import email.message, imaplib, smtplib, ssl, sys, time

host, local_addr, local_pw, agent_addr, app_secret = sys.argv[1:6]
ctx = ssl.create_default_context()
subject = f"stalwart check {int(time.time())}"

with imaplib.IMAP4_SSL(host, 993, ssl_context=ctx, timeout=20) as imap:
    imap.login(local_addr, local_pw)
    imap.select("INBOX")

msg = email.message.EmailMessage()
msg["From"] = agent_addr
msg["To"] = local_addr
msg["Subject"] = subject
msg.set_content("Automated delivery check.")

with smtplib.SMTP_SSL(host, 465, context=ctx, timeout=20) as smtp:
    smtp.login(agent_addr, app_secret)
    smtp.send_message(msg)

deadline = time.time() + 20
with imaplib.IMAP4_SSL(host, 993, ssl_context=ctx, timeout=20) as imap:
    imap.login(local_addr, local_pw)
    imap.select("INBOX")
    while time.time() < deadline:
        status, data = imap.uid("search", None, f'(SUBJECT "{subject}")')
        if status == "OK" and data and data[0].strip():
            print("delivered")
            sys.exit(0)
        time.sleep(1)
sys.exit(1)
PY
    then
        pass "IMAP login, SMTP AUTH (app password) and delivery"
    else
        fail "IMAP/SMTP test failed — check the credentials and journalctl -u stalwart"
    fi
fi

# ------------------------------------------------------------------ HTTP ---

echo
echo "Web interface"
web="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/webmail/" || true)"
admin="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/admin" || true)"
[[ $web == "200" ]] && pass "GET /webmail/ → 200" || fail "GET /webmail/ → ${web:-no response}"
[[ $admin == "200" || $admin == "302" ]] && pass "GET /admin → $admin" || fail "GET /admin → ${admin:-no response}"

printf '\n%d passed, %d failed\n\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf 'Logs: journalctl -u stalwart -n 60 --no-pager\n\n'
    exit 1
fi

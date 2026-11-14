#!/usr/bin/env bash
#
# verify-mail.sh — end-to-end checks for the tailnet mail server.
# Run as root:  sudo bash verify-mail.sh
#
# Checks configuration, listeners, certificates, TLS handshakes, local
# delivery, SMTP AUTH and IMAP login. Sends one test message to the local user.

set -uo pipefail

PASS=0
FAIL=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }

CRED_FILE=/root/mail-credentials.txt
CERT_FILE=/etc/ssl/tailscale/mail.crt

# ------------------------------------------------------------- parameters ---

if [[ -r /etc/default/mail-setup ]]; then
    # shellcheck disable=SC1091
    . /etc/default/mail-setup
fi

MAIL_BIND_IP="${MAIL_BIND_IP:-$(tailscale ip -4 2>/dev/null | head -n1 || true)}"
MAIL_LOCAL_USER="${MAIL_LOCAL_USER:-mcsquirrel}"
MAIL_AGENT_USER="${MAIL_AGENT_USER:-agent-bot}"
if [[ -z ${MAIL_DOMAIN:-} ]]; then
    MAIL_DOMAIN="$(tailscale status --json 2>/dev/null \
        | python3 -c 'import json,sys; print((json.load(sys.stdin)["Self"]["DNSName"]).rstrip("."))' 2>/dev/null || true)"
fi

[[ -n ${MAIL_DOMAIN:-} ]] || { echo "cannot determine mail domain" >&2; exit 1; }

printf '\n\033[1mMail server verification — %s (%s)\033[0m\n\n' \
    "$MAIL_DOMAIN" "${MAIL_BIND_IP:-?}"

# ------------------------------------------------------------- config/svc ---

echo "Configuration"
if /usr/sbin/smtpd -n >/dev/null 2>&1; then
    pass "smtpd.conf parses"
else
    fail "smtpd.conf does not parse — run: /usr/sbin/smtpd -n"
fi

if /usr/bin/doveconf -n >/dev/null 2>&1; then
    pass "dovecot.conf parses"
else
    fail "dovecot.conf does not parse — run: /usr/bin/doveconf -n"
fi

for pamfile in /etc/pam.d/dovecot /etc/pam.d/smtpd; do
    if [[ -r $pamfile ]]; then
        pass "PAM service file $pamfile present"
    else
        fail "missing $pamfile (logins will fail without it)"
    fi
done

if [[ -S /run/dovecot/lmtp ]]; then
    lmtp_mode="$(stat -c '%a' /run/dovecot/lmtp)"
    if [[ $lmtp_mode == "666" ]]; then
        pass "LMTP socket is writable by mail users (mode $lmtp_mode)"
    else
        fail "LMTP socket mode is $lmtp_mode, expected 666 — OpenSMTPD delivers as the recipient uid"
    fi
else
    fail "LMTP socket /run/dovecot/lmtp is missing"
fi

for svc in dovecot.service opensmtpd.service; do
    if systemctl is-active --quiet "$svc"; then
        pass "$svc is active"
    else
        fail "$svc is not active — journalctl -u $svc -n 30"
    fi
done

if systemctl is-enabled --quiet mail-cert-renew.timer 2>/dev/null; then
    pass "certificate renewal timer enabled"
else
    fail "mail-cert-renew.timer is not enabled"
fi

# -------------------------------------------------------------- listeners ---

echo
echo "Listening sockets"
sockets="$(ss -ltnH 2>/dev/null | awk '{print $4}')"
has_socket() { grep -qxF "$1" <<<"$sockets"; }

check_socket() { # socket description
    if has_socket "$1"; then
        pass "$2 listens on $1"
    else
        fail "$2 is not listening on $1"
    fi
}

check_socket "127.0.0.1:25"  "OpenSMTPD (local)"
check_socket "${MAIL_BIND_IP}:465" "OpenSMTPD (smtps)"
check_socket "${MAIL_BIND_IP}:587" "OpenSMTPD (submission)"
check_socket "${MAIL_BIND_IP}:993" "Dovecot (imaps)"
check_socket "127.0.0.1:993" "Dovecot (imaps, loopback)"

leaked=""
for port in 25 465 587 993; do
    if grep -qE "^0\.0\.0\.0:${port}$|^\[::\]:${port}$|^\*:${port}$" <<<"$sockets"; then
        leaked="$leaked $port"
    fi
done
if [[ -z $leaked ]]; then
    pass "no wildcard binds on mail ports"
else
    fail "wildcard bind found on port(s):$leaked — mail would be reachable off-tailnet"
fi

# ------------------------------------------------------------- certificate ---

echo
echo "Certificate"
if [[ -r $CERT_FILE ]]; then
    enddate="$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2)"
    if openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1; then
        pass "certificate valid (expires $enddate)"
    else
        fail "certificate expired ($enddate)"
    fi
    if openssl x509 -in "$CERT_FILE" -noout -checkhost "$MAIL_DOMAIN" 2>/dev/null \
        | grep -q 'does match'; then
        pass "certificate covers $MAIL_DOMAIN"
    else
        fail "certificate does not cover $MAIL_DOMAIN"
    fi
    if [[ ! -r /etc/ssl/tailscale/mail.key ]]; then
        fail "private key missing"
    elif [[ $(stat -c '%a' /etc/ssl/tailscale/mail.key) != "600" ]]; then
        fail "private key mode is $(stat -c '%a' /etc/ssl/tailscale/mail.key), expected 600"
    else
        pass "private key is root-only (0600)"
    fi
else
    fail "no certificate at $CERT_FILE"
fi

# -------------------------------------------------------------------- TLS ---

echo
echo "TLS handshakes (certificate chain + hostname verified)"
tls_test() { # description address extra args...
    local desc=$1 address=$2
    shift 2
    if openssl s_client -connect "$address" \
            -servername "$MAIL_DOMAIN" -verify_hostname "$MAIL_DOMAIN" \
            -verify_return_error -CAfile /etc/ssl/certs/ca-certificates.crt \
            "$@" </dev/null >/dev/null 2>&1; then
        pass "$desc ($address)"
    else
        fail "$desc ($address)"
    fi
}

tls_test "IMAPS" "127.0.0.1:993"
tls_test "SMTPS" "${MAIL_BIND_IP}:465"
tls_test "SMTP STARTTLS" "${MAIL_BIND_IP}:587" -starttls smtp

# ---------------------------------------------------------- delivery test ---

echo
echo "Local delivery (sendmail → OpenSMTPD → Dovecot LMTP)"
local_home="$(getent passwd "$MAIL_LOCAL_USER" | cut -d: -f6)"
maildir="${local_home:-/home/$MAIL_LOCAL_USER}/Maildir/new"
before=$(find "$maildir" -maxdepth 1 -type f 2>/dev/null | wc -l)
before=$((before + 0))
stamp="$(date +%s)"

message="Subject: mail setup check ${stamp}
From: ${MAIL_AGENT_USER}@${MAIL_DOMAIN}
To: ${MAIL_LOCAL_USER}@${MAIL_DOMAIN}
Date: $(date -R)

Automated delivery check ${stamp}.
"

if printf '%s' "$message" | /usr/sbin/sendmail \
        -f "${MAIL_AGENT_USER}@${MAIL_DOMAIN}" \
        "${MAIL_LOCAL_USER}@${MAIL_DOMAIN}" 2>/dev/null; then
    delivered=0
    for _ in $(seq 1 20); do
        now=$(find "$maildir" -maxdepth 1 -type f 2>/dev/null | wc -l)
        now=$((now + 0))
        if (( now > before )); then delivered=1; break; fi
        sleep 0.5
    done
    if (( delivered )); then
        pass "message accepted and delivered to ${MAIL_LOCAL_USER}'s Maildir"
    else
        fail "message accepted but never appeared in $maildir"
        echo "         socket: $(ls -l /run/dovecot/lmtp 2>/dev/null || echo 'missing')"
        echo "         hint: OpenSMTPD delivers as the recipient's uid, so the LMTP socket needs mode 0666"
        echo "         recent mail log:"
        { tail -n 8 /var/log/mail.log 2>/dev/null || journalctl -u opensmtpd -u dovecot -n 8 --no-pager 2>/dev/null; } | sed 's/^/         /'
    fi
else
    fail "sendmail could not hand the message to OpenSMTPD"
fi

# ------------------------------------------------------- auth (SMTP/IMAP) ---

echo
echo "Authenticated access"
if [[ -r $CRED_FILE ]]; then
    agent_user="$(awk -F'= *' '/^username/{print $2}' "$CRED_FILE")"
    agent_pass="$(awk -F'= *' '/^password/{print $2}' "$CRED_FILE")"

    if python3 - "$MAIL_DOMAIN" "$agent_user" "$agent_pass" \
            "${MAIL_LOCAL_USER}@${MAIL_DOMAIN}" <<'PY'
import smtplib, ssl, sys, imaplib, email.message

host, user, password, recipient = sys.argv[1:5]
ctx = ssl.create_default_context()

msg = email.message.EmailMessage()
msg["From"] = f"{user}@{host}"
msg["To"] = recipient
msg["Subject"] = "authenticated smtp check"
msg.set_content("Sent with SMTP AUTH over TLS.")

with smtplib.SMTP_SSL(host, 465, context=ctx, timeout=15) as s:
    s.login(user, password)
    s.send_message(msg)

with imaplib.IMAP4_SSL(host, 993, ssl_context=ctx) as m:
    m.login(user, password)
    m.select("INBOX")
    m.logout()

print("ok")
PY
    then
        pass "SMTP AUTH (465) and IMAP login (993) as $agent_user"
    else
        fail "authenticated SMTP/IMAP test failed — check /etc/pam.d/smtpd and /etc/pam.d/dovecot"
    fi
else
    skip "no $CRED_FILE (agent password); set one with RESET_AGENT_PASSWORD=1"
fi

# ----------------------------------------------------------------- summary ---

printf '\n%d passed, %d failed\n\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf 'Logs:  journalctl -u dovecot -u opensmtpd -n 50 --no-pager\n'
    printf '       tail -n 50 /var/log/mail.log\n\n'
    exit 1
fi
printf 'Mail is ready: %s@%s on port 993/465/587 over the tailnet.\n\n' \
    "$MAIL_LOCAL_USER" "$MAIL_DOMAIN"

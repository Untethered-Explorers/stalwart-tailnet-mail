#!/usr/bin/env bash
#
# 70-import-maildir.sh — copy the old Dovecot Maildirs into Stalwart.
# Run as root:  sudo bash migrate/70-import-maildir.sh
#
# Uses Vandelay, which reads a Maildir++ tree directly (no Dovecot needed) and
# writes it through JMAP. The Maildirs are not modified.
#
# Re-running imports again and can duplicate messages; run it once per account.

set -euo pipefail

trap 'rc=$?; printf "\n\033[1;31m[error]\033[0m failed at %s line %s (exit %s)\n" "${BASH_SOURCE[0]}" "$LINENO" "$rc" >&2' ERR

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HERE/bin"
CRED_FILE=/root/mail-credentials.txt
VANDELAY_VERSION="1.0.16"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run with sudo: sudo bash $0"
[[ -s $CRED_FILE ]] || die "$CRED_FILE is missing"

if [[ -r /etc/default/mail-setup ]]; then
    # shellcheck disable=SC1091
    . /etc/default/mail-setup
fi
DOMAIN="${MAIL_DOMAIN:-}"
LOCAL_USER="${MAIL_LOCAL_USER:-mcsquirrel}"
AGENT_USER="${MAIL_AGENT_USER:-agent-bot}"
[[ -n $DOMAIN ]] || die "cannot determine the mail domain"

get_pw() { # account key in the credentials file
    awk -F'= *' -v u="$1" '$1 ~ "^" u "[[:space:]]*$" {print $2; exit}' "$CRED_FILE" \
        | awk '{print $1}'
}

# --------------------------------------------------------------- vandelay ---

VANDELAY=""
if command -v vandelay >/dev/null 2>&1; then
    VANDELAY="$(command -v vandelay)"
else
    case "$(uname -m)" in
        aarch64|arm64) TARGET="aarch64-unknown-linux-gnu" ;;
        x86_64|amd64)  TARGET="x86_64-unknown-linux-gnu" ;;
        *) die "unsupported architecture" ;;
    esac
    mkdir -p "$BIN_DIR"
    ASSET="vandelay-${TARGET}.tar.gz"
    BASE="https://github.com/stalwartlabs/vandelay/releases/download/v${VANDELAY_VERSION}"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    log "Downloading Vandelay ${VANDELAY_VERSION}"
    curl -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET"
    curl -fsSL "$BASE/$ASSET.sha256" -o "$TMP/$ASSET.sha256"
    info "verifying checksum"
    ( cd "$TMP" && sha256sum -c "$ASSET.sha256" )
    tar -xzf "$TMP/$ASSET" -C "$TMP"
    BINARY="$(find "$TMP" -maxdepth 3 -type f -name vandelay | head -n1)"
    [[ -n $BINARY ]] || die "vandelay binary not found in the archive"
    install -m 0755 "$BINARY" "$BIN_DIR/vandelay"
    VANDELAY="$BIN_DIR/vandelay"
fi
info "$($VANDELAY --version 2>/dev/null || echo vandelay)"

# ----------------------------------------------------------------- import ---

count_messages() { # address password
    python3 - "$DOMAIN" "$1" "$2" <<'PY'
import imaplib, ssl, sys
host, user, pw = sys.argv[1:4]
with imaplib.IMAP4_SSL(host, 993, ssl_context=ssl.create_default_context(), timeout=20) as m:
    m.login(user, pw)
    m.select("INBOX", readonly=True)
    status, data = m.uid("search", None, "ALL")
    print(len(data[0].split()) if status == "OK" and data and data[0].strip() else 0)
PY
}

for user in "$LOCAL_USER" "$AGENT_USER"; do
    maildir="/home/$user/Maildir"
    if [[ ! -d $maildir ]]; then
        warn "$maildir does not exist — skipping $user"
        continue
    fi

    password="$(get_pw "$user")"
    if [[ -z $password ]]; then
        warn "no password for $user in $CRED_FILE — skipping"
        continue
    fi

    address="$user@$DOMAIN"
    archive="/root/vandelay-$user"

    log "Importing $user"
    info "Maildir: $maildir"
    info "messages before: $(count_messages "$address" "$password" || echo '?')"

    rm -rf "$archive"
    "$VANDELAY" import maildir "$maildir" "$archive"
    "$VANDELAY" export \
        --url "https://$DOMAIN" \
        --auth-basic "$address" --auth-password "$password" \
        --account-name "$address" \
        "$archive"

    info "messages after:  $(count_messages "$address" "$password" || echo '?')"
done

log "Done"
info "archives kept under /root/vandelay-<user> (remove when satisfied)"

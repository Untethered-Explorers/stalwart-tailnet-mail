#!/usr/bin/env bash
#
# 80-agent-config.sh — point tailmail.py at agent-bot on Stalwart.
# Run as root:  sudo bash migrate/80-agent-config.sh
#
# Writes ~/.config/tailmail/config for the human login account (the account
# OpenCode and local scripts run as), using agent-bot's app password. The file
# is owned by that user and mode 0600.

set -euo pipefail

CRED_FILE=/root/mail-credentials.txt
TARGET_USER="${TARGET_USER:-mcsquirrel}"
AGENT_USER="${AGENT_USER:-agent-bot}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run with sudo: sudo bash $0"
[[ -s $CRED_FILE ]] || die "$CRED_FILE is missing"

if [[ -r /etc/default/mail-setup ]]; then
    # shellcheck disable=SC1091
    . /etc/default/mail-setup
fi
DOMAIN="${MAIL_DOMAIN:-}"
[[ -n $DOMAIN ]] || die "cannot determine the mail domain"

secret="$(awk -F'= *' '/^app-password/{print $2; exit}' "$CRED_FILE" | awk '{print $1}')"
[[ -n $secret ]] || die "no app-password line in $CRED_FILE — run 32-agent-app-password.sh"

config_dir="/home/$TARGET_USER/.config/tailmail"
config="$config_dir/config"

log "Writing $config"
install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$config_dir"
( umask 077
  cat > "$config" <<EOF
[default]
host     = $DOMAIN
username = $AGENT_USER@$DOMAIN
password = $secret
from     = $AGENT_USER@$DOMAIN
EOF
)
chown "$TARGET_USER:$TARGET_USER" "$config"
chmod 0600 "$config"

log "Test"
if sudo -u "$TARGET_USER" python3 /home/mcsquirrel/projects/email/scripts/tailmail.py inbox --limit 3; then
    info "agent can read $AGENT_USER's inbox"
else
    printf '    \033[33m[skip]\033[0m inbox read failed (may be empty or unreachable); config is in place\n'
fi

info "send a test:  sudo -u $TARGET_USER python3 /home/mcsquirrel/projects/email/scripts/tailmail.py send --to $TARGET_USER@$DOMAIN --subject test --body hi"

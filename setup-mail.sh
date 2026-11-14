#!/usr/bin/env bash
#
# setup-mail.sh — private mail server on a Tailscale tailnet.
#
# Stalwart (SMTP, IMAP, HTTPS) + Bulwark Lite (webmail served by Stalwart),
# using a Tailscale-issued TLS certificate. Everything binds to loopback and
# the tailnet address only; there is no public exposure and no internet mail.
#
# Usage:
#   sudo ./setup-mail.sh                 # interactive
#   sudo ./setup-mail.sh --preflight     # checks only, changes nothing
#   sudo ./setup-mail.sh --check         # verify an existing install
#   sudo ./setup-mail.sh --diagnose      # support bundle (secrets redacted)
#   sudo ./setup-mail.sh --resume        # continue after a failure
#   sudo ./setup-mail.sh --reconfigure   # re-render listeners for a new tailnet IP
#   sudo ./setup-mail.sh --config mail-setup.conf
#
# Nothing about a particular tailnet is hardcoded: the hostname and address are
# read from `tailscale status`, and every account name is provided.
#
# Requirements: Debian/Ubuntu, root, Tailscale up with HTTPS certificates
# enabled for the tailnet, ports 25/465/587/993/443 free.

set -Eeuo pipefail

PROG="$(basename "$0")"
CONFIG_FILE=""
MODE="install"
RESUME=0
NO_WEBMAIL=0
ASSUME_YES=0
DOMAIN_OVERRIDE=""
LOG_DIR=/var/lib/mail-setup
LOG_FILE="$LOG_DIR/setup.log"
STATE_DIR="$LOG_DIR/phases"
CRED_FILE=/root/mail-credentials.txt
CERT_DIR=/etc/ssl/tailscale
CERT_FILE="$CERT_DIR/mail.crt"
KEY_FILE="$CERT_DIR/mail.key"
STALWART_CLI=/usr/local/bin/stalwart-cli
CLI_VERSION="1.0.14"
BULWARK_URL="https://github.com/bulwarkmail/webmail/releases/latest/download/bulwark-lite-stalwart.zip"

# Resolved during configure.
MAIL_HOST=""
MAIL_DOMAIN=""
TAILNET_IP=""
HUMAN_USER=""
AGENT_USERS=()
BOOTSTRAP_PW=""
RECOVERY_PW=""
ADMIN_PW=""
DOMAIN_ID=""
ADMIN_ID=""
declare -A ACCOUNT_PW=()
declare -A APP_PW=()

C_RESET=$'\033[0m'; C_B=$'\033[1m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_C=$'\033[1;36m'

log()  { printf '\n%s==> %s%s\n' "$C_C" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_RESET" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$C_R" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
    local rc=$?
    printf '\n%s[error]%s failed at %s line %s (exit %s)\n' "$C_R" "$C_RESET" "${BASH_SOURCE[0]}" "$LINENO" "$rc" >&2
    printf '        log: %s\n' "$LOG_FILE" >&2
    printf '        support bundle: sudo %s --diagnose\n' "$PROG" >&2
}
trap on_error ERR

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 0
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --config)      CONFIG_FILE="${2:?--config needs a file}"; shift 2 ;;
            --preflight)   MODE="preflight"; shift ;;
            --check)       MODE="check"; shift ;;
            --diagnose)    MODE="diagnose"; shift ;;
            --resume)      RESUME=1; shift ;;
            --reconfigure) MODE="reconfigure"; shift ;;
            --no-webmail)  NO_WEBMAIL=1; shift ;;
            --domain)      DOMAIN_OVERRIDE="${2:?}"; shift 2 ;;
            -y|--yes)      ASSUME_YES=1; shift ;;
            -h|--help)     usage ;;
            *) die "unknown argument: $1 (try --help)" ;;
        esac
    done
}

# --------------------------------------------------------------- utilities ---

need_root() {
    [[ ${EUID} -eq 0 ]] || die "run with sudo: sudo $PROG"
}

setup_logging() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"
    chmod 0755 "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

marker() { printf '%s\n' "$STATE_DIR/$1"; }
phase_done() { [[ -f "$(marker "$1")" ]]; }
mark_phase() { date -Is > "$(marker "$1")"; }

phase_begin() { # id title
    if phase_done "$1" && (( RESUME )); then
        info "phase $1 already done — skipping"
        return 1
    fi
    log "$2"
    return 0
}

gen_pw() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24; }

tailnet_json() { tailscale status --json 2>/dev/null; }

self_dns_name() {
    tailnet_json | python3 -c 'import json,sys; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))'
}

https_capable() {
    tailnet_json | python3 -c '
import json,sys
d=json.load(sys.stdin); s=d.get("Self") or {}
print("yes" if "https" in [str(c) for c in (s.get("Capabilities") or [])] else "no")'
}

tailnet_ip() { tailscale ip -4 2>/dev/null | head -n1; }

port_busy() { # port
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
}

json_call() { # payload — admin JMAP on the recovery listener
    curl -fsS -u "admin:$RECOVERY_PW" -H 'Content-Type: application/json' \
        -d "$1" "http://127.0.0.1:8080/jmap/"
}

cli() { "$STALWART_CLI" --url http://127.0.0.1:8080 --user admin --password "$RECOVERY_PW" "$@"; }

render_renew() { # writes /usr/local/sbin/mail-cert-renew for $MAIL_DOMAIN
    cat > /usr/local/sbin/mail-cert-renew <<EOF
#!/bin/sh
set -eu
DOMAIN="$MAIL_DOMAIN"
CERT="$CERT_FILE"
KEY="$KEY_FILE"
TOKEN_FILE=/root/stalwart-api-key
tmp="\$(mktemp -d)"
trap 'rm -rf "\$tmp"' EXIT
tailscale cert --cert-file "\$tmp/mail.crt" --key-file "\$tmp/mail.key" "\$DOMAIN" >/dev/null
if cmp -s "\$tmp/mail.crt" "\$CERT" && cmp -s "\$tmp/mail.key" "\$KEY"; then
    exit 0
fi
install -m 0644 -o root -g root "\$tmp/mail.crt" "\$CERT"
install -m 0600 -o root -g root "\$tmp/mail.key" "\$KEY"
[ -s "\$TOKEN_FILE" ] || { echo "mail-cert-renew: \$TOKEN_FILE missing" >&2; exit 1; }
TOKEN="\$(cat "\$TOKEN_FILE")"
response="\$(curl -fsS -H "Authorization: Bearer \$TOKEN" -H 'Content-Type: application/json' \\
    -d '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Certificate/get",{"ids":null},"0"]]}' \\
    "https://\$DOMAIN/jmap/")"
cert_id="\$(printf '%s' "\$response" | jq -r '.methodResponses[0][1].list[0].id // empty')"
[ -n "\$cert_id" ] || { echo "mail-cert-renew: no Certificate object" >&2; exit 1; }
payload="\$(jq -n --arg id "\$cert_id" --rawfile cert "\$CERT" --rawfile key "\$KEY" '{
  using:["urn:ietf:params:jmap:core","urn:stalwart:jmap"],
  methodCalls:[["x:Certificate/set",{update:{(\$id):{certificate:{"@type":"Text",value:\$cert},privateKey:{"@type":"Text",secret:\$key}}}},"0"]]}')"
curl -fsS -H "Authorization: Bearer \$TOKEN" -H 'Content-Type: application/json' \
    -d "\$payload" "https://\$DOMAIN/jmap/" >/dev/null
systemctl restart stalwart.service
EOF
    chmod 0755 /usr/local/sbin/mail-cert-renew
}

# --------------------------------------------------------------- preflight ---

check_prerequisites() {
    log "Preflight"

    [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) info "OS: $PRETTY_NAME" ;;
        *) die "supported on Debian and Ubuntu only (found ${ID:-unknown})" ;;
    esac

    case "$(uname -m)" in
        aarch64|arm64|x86_64|amd64) info "arch: $(uname -m)" ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac

    command -v tailscale >/dev/null || die "Tailscale is not installed"
    systemctl is-active --quiet tailscaled 2>/dev/null \
        || die "tailscaled is not running"

    local dns ip https
    dns="$(self_dns_name || true)"
    ip="$(tailnet_ip || true)"
    https="$(https_capable || true)"
    [[ -n $dns ]] || die "this node has no MagicDNS name; is Tailscale logged in?"
    [[ -n $ip ]] || die "this node has no Tailscale IPv4 address"
    [[ $https == "yes" ]] || die "HTTPS certificates are disabled for this tailnet.
   Enable them under DNS → HTTPS Certificates in the Tailscale admin console."
    info "node: $dns ($ip)"

    local busy=""
    if [[ $MODE == "install" ]] && ! systemctl is-active --quiet stalwart.service 2>/dev/null; then
        for p in 25 465 587 993 443; do
            port_busy "$p" && busy="$busy $p"
        done
        if [[ -n $busy ]]; then
            die "port(s) already in use:$busy. Stop the other mail server first."
        fi
    fi

    local free_mb
    free_mb="$(df -Pm /var 2>/dev/null | awk 'NR==2 {print $4}')"
    [[ ${free_mb:-0} -ge 2048 ]] || warn "less than 2 GB free on /var"

    info "prerequisites OK"
}

# ------------------------------------------------------------ configuration ---

prompt() { # variable, question, default
    local __var=$1 __q=$2 __d=${3:-} __ans=""
    if [[ ! -t 0 ]] || (( ASSUME_YES )); then
        printf -v "$__var" '%s' "$__d"
        return
    fi
    if [[ -n $__d ]]; then
        read -rp "    $__q [$__d]: " __ans || true
        printf -v "$__var" '%s' "${__ans:-$__d}"
    else
        read -rp "    $__q: " __ans || true
        printf -v "$__var" '%s' "$__ans"
    fi
}

load_config() {
    if [[ -n $CONFIG_FILE ]]; then
        [[ -r $CONFIG_FILE ]] || die "cannot read $CONFIG_FILE"
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
        MAIL_HOST="${MAIL_HOST:-}"
        HUMAN_USER="${HUMAN_USER:-}"
        AGENT_USERS_STR="${AGENT_USERS:-}"
        [[ "${WEBMAIL:-yes}" == "no" ]] && NO_WEBMAIL=1
    fi
}

configure_values() {
    log "Configuration"

    local detected_dns detected_ip default_user
    detected_dns="$(self_dns_name)"
    detected_ip="$(tailnet_ip)"
    default_user="${SUDO_USER:-$(id -un)}"
    [[ $default_user == root ]] && default_user="$(id -un 1000 2>/dev/null || echo user)"

    if [[ -z ${MAIL_HOST:-} ]]; then
        prompt MAIL_HOST "Server hostname (MagicDNS name)" "$detected_dns"
    fi
    if [[ -n $DOMAIN_OVERRIDE ]]; then
        MAIL_DOMAIN="$DOMAIN_OVERRIDE"
    elif [[ -z ${MAIL_DOMAIN:-} ]]; then
        prompt MAIL_DOMAIN "Mail domain" "$MAIL_HOST"
    fi
    if [[ -z ${HUMAN_USER:-} ]]; then
        prompt HUMAN_USER "Human mailbox name (local part)" "$default_user"
    fi
    if [[ -z ${AGENT_USERS_STR:-} && ${#AGENT_USERS[@]} -eq 0 ]]; then
        prompt AGENT_USERS_STR "Agent mailbox names, comma-separated (blank for none)" ""
    fi
    if [[ -n ${AGENT_USERS_STR:-} ]]; then
        IFS=',' read -r -a __agents <<<"$AGENT_USERS_STR"
        AGENT_USERS=()
        for a in "${__agents[@]}"; do
            a="$(printf '%s' "$a" | tr -d ' ')"
            [[ -n $a ]] && AGENT_USERS+=("$a")
        done
    fi

    if [[ ${NO_WEBMAIL:-0} != 1 && -t 0 ]] && (( ! ASSUME_YES )); then
        local webmail="yes"
        prompt webmail "Install Bulwark Lite webmail" "yes"
        [[ $webmail == "no" ]] && NO_WEBMAIL=1
    fi

    for v in MAIL_HOST MAIL_DOMAIN HUMAN_USER; do
        [[ -n ${!v} ]] || die "$v is required"
    done
    [[ $MAIL_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die "invalid hostname: $MAIL_HOST"
    [[ $MAIL_DOMAIN =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die "invalid domain: $MAIL_DOMAIN"
    [[ $HUMAN_USER =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "invalid mailbox name: $HUMAN_USER"
    for a in "${AGENT_USERS[@]}"; do
        [[ $a =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "invalid agent mailbox name: $a"
    done

    TAILNET_IP="$detected_ip"
    printf '\n    host      : %s\n    domain    : %s\n    address   : %s\n    human     : %s\n    agents    : %s\n    webmail   : %s\n' \
        "$MAIL_HOST" "$MAIL_DOMAIN" "$TAILNET_IP" "$HUMAN_USER" "${AGENT_USERS[*]:-none}" \
        "$([[ $NO_WEBMAIL == 1 ]] && echo no || echo 'Bulwark Lite')"

    if [[ -t 0 ]] && (( ! ASSUME_YES )); then
        local ok=""
        prompt ok "Proceed" "yes"
        [[ $ok =~ ^(yes|y)$ ]] || die "aborted"
    fi
}

# ------------------------------------------------------------------ phases ---

install_packages() {
    phase_begin install "Installing dependencies and Stalwart" || return 0

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends curl jq openssl python3 ca-certificates

    if [[ -f /etc/systemd/system/stalwart.service ]]; then
        info "Stalwart already installed: $(/usr/local/bin/stalwart --version 2>/dev/null || echo unknown)"
    else
        local tmp; tmp="$(mktemp)"
        curl --proto '=https' --tlsv1.2 -fsSL https://get.stalw.art/install.sh -o "$tmp"
        info "installer sha256: $(sha256sum "$tmp" | cut -d' ' -f1)"
        sh "$tmp"
        rm -f "$tmp"
        for _ in $(seq 1 30); do systemctl is-active --quiet stalwart.service && break; sleep 1; done
        systemctl is-active --quiet stalwart.service \
            || { journalctl -u stalwart -n 40 --no-pager; die "Stalwart did not start"; }
        info "installed: $(/usr/local/bin/stalwart --version 2>/dev/null || echo unknown)"
    fi

    if [[ ! -x $STALWART_CLI ]]; then
        local cli_ver="$CLI_VERSION" target asset base tmpdir
        case "$(uname -m)" in
            aarch64|arm64) target="aarch64-unknown-linux-gnu" ;;
            x86_64|amd64)  target="x86_64-unknown-linux-gnu" ;;
            *) die "no stalwart-cli build for $(uname -m)" ;;
        esac
        asset="stalwart-cli-${target}.tar.xz"
        base="https://github.com/stalwartlabs/cli/releases/download/v${cli_ver}"
        tmpdir="$(mktemp -d)"
        curl -fsSL "$base/$asset" -o "$tmpdir/$asset"
        curl -fsSL "$base/$asset.sha256" -o "$tmpdir/$asset.sha256"
        ( cd "$tmpdir" && sha256sum -c "$asset.sha256" )
        tar -xJf "$tmpdir/$asset" -C "$tmpdir"
        install -m 0755 "$(find "$tmpdir" -maxdepth 3 -type f -name stalwart-cli | head -n1)" "$STALWART_CLI"
        rm -rf "$tmpdir"
        info "stalwart-cli: $("$STALWART_CLI" --version)"
    fi

    mark_phase install
}

bootstrap_stalwart() {
    phase_begin bootstrap "Bootstrapping Stalwart without the web wizard" || return 0

    BOOTSTRAP_PW="$(gen_pw)"
    ( umask 077; printf '%s\n' "$BOOTSTRAP_PW" > /root/stalwart-recovery-password )

    python3 - /etc/stalwart/stalwart.env "$BOOTSTRAP_PW" <<'PY'
import re, sys
path, pw = sys.argv[1], sys.argv[2]
out = []
for line in open(path).read().splitlines():
    if re.match(r"^#?\s*STALWART_RECOVERY_ADMIN=", line):
        out.append(f"STALWART_RECOVERY_ADMIN=admin:{pw}")
    else:
        out.append(line)
if not any(l.startswith("STALWART_RECOVERY_ADMIN=") for l in out):
    out.append(f"STALWART_RECOVERY_ADMIN=admin:{pw}")
open(path, "w").write("\n".join(out) + "\n")
PY
    chown root:stalwart /etc/stalwart/stalwart.env
    chmod 0640 /etc/stalwart/stalwart.env
    systemctl restart stalwart.service

    for _ in $(seq 1 30); do
        curl -fsS -o /dev/null http://127.0.0.1:8080/ 2>/dev/null && break
        sleep 1
    done

    info "applying Bootstrap object"
    "$STALWART_CLI" --url http://127.0.0.1:8080 --user admin --password "$BOOTSTRAP_PW" \
        update Bootstrap \
        --field "defaultHostname=$MAIL_HOST" \
        --field "defaultDomain=$MAIL_DOMAIN" \
        --field "requestTlsCertificate=false" \
        --field "generateDkimKeys=false" >/dev/null

    [[ -s /etc/stalwart/config.json ]] \
        || die "Bootstrap did not write /etc/stalwart/config.json"

    RECOVERY_PW="$BOOTSTRAP_PW"
    mark_phase bootstrap
}

enter_recovery() {
    phase_begin recovery "Entering recovery mode (management API only)" || return 0

    python3 - /etc/stalwart/stalwart.env <<'PY'
import re, sys
path = sys.argv[1]
out, seen = [], False
for line in open(path).read().splitlines():
    if re.match(r"^#?\s*STALWART_RECOVERY_MODE=", line):
        out.append("STALWART_RECOVERY_MODE=1"); seen = True
    else:
        out.append(line)
if not seen:
    out.append("STALWART_RECOVERY_MODE=1")
open(path, "w").write("\n".join(out) + "\n")
PY
    systemctl restart stalwart.service
    for _ in $(seq 1 30); do
        curl -fsS -o /dev/null http://127.0.0.1:8080/ 2>/dev/null && break
        sleep 1
    done
    curl -fsS -o /dev/null http://127.0.0.1:8080/ 2>/dev/null \
        || { journalctl -u stalwart -n 50 --no-pager; die "recovery API did not start"; }
    mark_phase recovery
}

install_certificate() {
    phase_begin certificate "Installing the Tailscale certificate" || return 0

    install -d -m 0755 -o root -g root "$CERT_DIR"
    local tmp; tmp="$(mktemp -d)"
    if ! tailscale cert --cert-file "$tmp/mail.crt" --key-file "$tmp/mail.key" "$MAIL_HOST"; then
        rm -rf "$tmp"
        die "tailscale cert failed — is HTTPS enabled for this tailnet and $MAIL_HOST this node's name?"
    fi
    install -m 0644 -o root -g root "$tmp/mail.crt" "$CERT_FILE"
    install -m 0600 -o root -g root "$tmp/mail.key" "$KEY_FILE"
    rm -rf "$tmp"

    local certs
    certs="$(json_call '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Certificate/get",{"ids":null},"0"]]}' || true)"
    if printf '%s' "$certs" | jq -e '.methodResponses[0][1].list | length > 0' >/dev/null 2>&1; then
        info "a Certificate object already exists — keeping it"
    else
        cert_json="$(jq -Rs '{ "@type": "Text", value: . }' "$CERT_FILE")"
        key_json="$(jq -Rs '{ "@type": "Text", secret: . }' "$KEY_FILE")"
        cli create Certificate --field "certificate=$cert_json" --field "privateKey=$key_json" >/dev/null
        info "certificate installed"
    fi
    info "expires: $(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2)"
    mark_phase certificate
}

create_listeners() {
    phase_begin listeners "Creating listeners bound to loopback + tailnet" || return 0

    local existing
    existing="$(json_call '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:NetworkListener/get",{"ids":null},"0"]]}' \
        | jq -r '.methodResponses[0][1].list[]? | [.id,.name] | @tsv' || true)"

    create_one() { # name protocol port implicit
        local name=$1 protocol=$2 port=$3 implicit=${4:-}
        local bind="{\"127.0.0.1:$port\":true,\"$TAILNET_IP:$port\":true}"
        if printf '%s\n' "$existing" | awk -F'\t' -v n="$name" '$2==n {found=1} END {exit !found}'; then
            local id; id="$(awk -F'\t' -v n="$name" '$2==n {print $1; exit}' <<<"$existing")"
            info "$name already exists ($id) — updating bind"
            cli update NetworkListener "$id" --field "bind=$bind" >/dev/null
        else
            info "creating $name ($protocol/$port)"
            cli create NetworkListener --field "name=$name" --field "protocol=$protocol" --field "bind=$bind" ${implicit:+--field implicitTls=true} >/dev/null
        fi
    }

    create_one smtp        smtp 25
    create_one submissions smtp 465 implicit
    create_one submission  smtp 587
    create_one imaps       imap 993 implicit
    create_one https       http 443 implicit

    mark_phase listeners
}

create_accounts() {
    phase_begin accounts "Creating accounts" || return 0

    ( umask 077
      {
        printf '# Generated by setup-mail.sh on %s\n' "$(date -Is)"
        printf '# Move these to a password manager, then delete this file.\n'
        printf 'host            = %s\nimap            = imaps://%s:993\nsmtp            = smtps://%s:465\n' "$MAIL_HOST" "$MAIL_HOST" "$MAIL_HOST"
        printf 'webmail         = https://%s/webmail/\nadmin_url       = https://%s/admin\n' "$MAIL_HOST" "$MAIL_HOST"
      } > "$CRED_FILE"
    )
    chmod 0600 "$CRED_FILE"

    local domains
    domains="$(json_call '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Domain/get",{"ids":null},"0"]]}')"
    DOMAIN_ID="$(printf '%s' "$domains" | jq -r --arg d "$MAIL_DOMAIN" '.methodResponses[0][1].list | map(select(.name==$d))[0].id // empty')"
    [[ -n $DOMAIN_ID ]] || die "the Bootstrap step did not create domain $MAIL_DOMAIN"

    local accounts
    accounts="$(json_call '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Account/get",{"ids":null},"0"]]}')"
    account_exists() { printf '%s' "$accounts" | jq -e --arg n "$1" '.methodResponses[0][1].list | map(select(.name==$n)) | length > 0' >/dev/null; }

    create_account() { # name
        local name=$1 pw; pw="$(gen_pw)"
        ACCOUNT_PW["$name"]="$pw"
        if account_exists "$name"; then
            info "$name exists — resetting password"
            local id; id="$(printf '%s' "$accounts" | jq -r --arg n "$name" '.methodResponses[0][1].list | map(select(.name==$n))[0].id')"
            cli update Account "$id" --field "credentials/0/secret=$pw" >/dev/null
        else
            info "creating $name"
            cli create Account/User --field "name=$name" --field "domainId=$DOMAIN_ID" \
                --field "credentials={\"0\":{\"@type\":\"Password\",\"secret\":\"$pw\"}}" >/dev/null
        fi
        ( umask 077; printf '%-15s = %s\n' "$name" "$pw" >> "$CRED_FILE" )
    }

    create_account "$HUMAN_USER"
    for a in "${AGENT_USERS[@]}"; do create_account "$a"; done

    # First administrator created by Bootstrap: reset to a known password.
    ADMIN_PW="$(gen_pw)"
    if account_exists admin; then
        ADMIN_ID="$(printf '%s' "$accounts" | jq -r '.methodResponses[0][1].list | map(select(.name=="admin"))[0].id')"
        cli update Account "$ADMIN_ID" --field "credentials/0/secret=$ADMIN_PW" >/dev/null
        info "admin password reset"
    else
        info "creating admin"
        cli create Account/User --field name=admin --field "domainId=$DOMAIN_ID" \
            --field 'roles={"@type":"Admin"}' \
            --field "credentials={\"0\":{\"@type\":\"Password\",\"secret\":\"$ADMIN_PW\"}}" >/dev/null
    fi

    ( umask 077
      printf 'admin           = admin@%s\nadmin_password  = %s\n' "$MAIL_DOMAIN" "$ADMIN_PW" >> "$CRED_FILE"
    )

    mark_phase accounts
}

create_app_passwords() {
    (( ${#AGENT_USERS[@]} )) || { mark_phase app-passwords; return 0; }
    phase_begin app-passwords "Creating agent app passwords" || return 0

    local accounts
    accounts="$(json_call '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Account/get",{"ids":null},"0"]]}')"

    for a in "${AGENT_USERS[@]}"; do
        local id payload response secret
        id="$(printf '%s' "$accounts" | jq -r --arg n "$a" '.methodResponses[0][1].list | map(select(.name==$n))[0].id // empty')"
        [[ -n $id ]] || die "account $a not found"
        payload="$(jq -n --arg id "$id" --arg d "$a-setup" '{
            using:["urn:ietf:params:jmap:core","urn:stalwart:jmap"],
            methodCalls:[["x:AppPassword/set",{accountId:$id,create:{p1:{description:$d,permissions:{"@type":"Inherit"},allowedIps:{}}}},"0"]]}')"
        response="$(json_call "$payload")"
        secret="$(printf '%s' "$response" | jq -r '.methodResponses[0][1].created.p1.secret // empty')"
        [[ -n $secret ]] || { printf '%s\n' "$response" >&2; die "could not create an app password for $a"; }
        APP_PW["$a"]="$secret"
        ( umask 077; printf '%-15s = %s   (app password)\n' "${a}-app" "$secret" >> "$CRED_FILE" )
        info "$a app password created"
    done

    mark_phase app-passwords
}

create_api_key() {
    phase_begin api-key "Creating the certificate-renewal API key" || return 0

    if [[ -z $ADMIN_ID ]]; then
        ADMIN_ID="$(json_call '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Account/get",{"ids":null},"0"]]}' \
            | jq -r '.methodResponses[0][1].list | map(select(.name=="admin"))[0].id // empty')"
    fi
    [[ -n $ADMIN_ID ]] || die "admin account not found"

    local payload response token
    payload="$(jq -n --arg id "$ADMIN_ID" '{
        using:["urn:ietf:params:jmap:core","urn:stalwart:jmap"],
        methodCalls:[["x:ApiKey/set",{accountId:$id,create:{k1:{description:"cert-renewal",permissions:{"@type":"Inherit"},allowedIps:{}}}},"0"]]}')"
    response="$(json_call "$payload")"
    token="$(printf '%s' "$response" | jq -r '.methodResponses[0][1].created.k1.secret // empty')"
    [[ -n $token ]] || { printf '%s\n' "$response" >&2; die "ApiKey creation failed"; }
    ( umask 077; printf '%s\n' "$token" > /root/stalwart-api-key )
    chmod 0600 /root/stalwart-api-key
    mark_phase api-key
}

install_webmail() {
    [[ $NO_WEBMAIL == 1 ]] && { mark_phase webmail; return 0; }
    phase_begin webmail "Mounting Bulwark Lite at /webmail/" || return 0

    local apps
    apps="$(json_call '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Application/get",{"ids":null},"0"]]}' || true)"
    if printf '%s' "$apps" | jq -e '.methodResponses[0][1].list | map(select(.description=="Bulwark Webmail")) | length > 0' >/dev/null 2>&1; then
        info "application already present"
    else
        cli create Application \
            --field "description=Bulwark Webmail" \
            --field "resourceUrl=$BULWARK_URL" \
            --field 'urlPrefix={"/webmail":true}' >/dev/null
        cli create Action/UpdateApps >/dev/null
        info "application created and download triggered"
    fi
    mark_phase webmail
}

activate() {
    phase_begin activate "Leaving recovery mode and starting the mail services" || return 0

    python3 - /etc/stalwart/stalwart.env <<'PY'
import re, sys
path = sys.argv[1]
out = []
for line in open(path).read().splitlines():
    if re.match(r"^\s*(STALWART_RECOVERY_MODE|STALWART_RECOVERY_ADMIN)=", line):
        out.append("# " + line + "   # disabled by setup-mail.sh")
    else:
        out.append(line)
open(path, "w").write("\n".join(out) + "\n")
PY

    for svc in dovecot opensmtpd postfix exim4; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            warn "$svc is running and would block the ports; stopping it"
            systemctl disable --now "$svc" >/dev/null 2>&1 || true
        fi
    done

    systemctl restart stalwart.service
    for _ in $(seq 1 40); do systemctl is-active --quiet stalwart.service && break; sleep 1; done
    systemctl is-active --quiet stalwart.service \
        || { journalctl -u stalwart -n 60 --no-pager; die "Stalwart did not start"; }

    local ok=0
    for _ in $(seq 1 20); do
        ok=1
        for p in 25 465 587 993 443; do
            ss -ltnH | awk '{print $4}' | grep -qxF "$TAILNET_IP:$p" || ok=0
        done
        (( ok )) && break
        sleep 1
    done
    (( ok )) || { journalctl -u stalwart -n 60 --no-pager; die "listeners did not come up"; }
    info "listeners bound to 127.0.0.1 and $TAILNET_IP"

    mark_phase activate
}

configure_firewall() {
    phase_begin firewall "Firewall" || return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in 25 465 587 993 443; do
            ufw allow in on tailscale0 to any port "$p" proto tcp >/dev/null 2>&1 || true
        done
        info "ufw: allowed ports 25/465/587/993/443 on tailscale0"
    else
        info "ufw is not active; no firewall rules added"
    fi
    mark_phase firewall
}

install_renewal() {
    phase_begin renewal "Certificate renewal" || return 0

    render_renew

    cat > /etc/systemd/system/mail-cert-renew.service <<'EOF'
[Unit]
Description=Renew the Tailscale certificate used by Stalwart
After=tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mail-cert-renew
EOF
    cat > /etc/systemd/system/mail-cert-renew.timer <<'EOF'
[Unit]
Description=Weekly renewal of the Tailscale mail certificate

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now mail-cert-renew.timer >/dev/null
    /usr/local/sbin/mail-cert-renew || warn "first renewal run failed; check /root/stalwart-api-key"
    mark_phase renewal
}

write_agent_configs() {
    (( ${#AGENT_USERS[@]} )) || { mark_phase agent-config; return 0; }
    phase_begin agent-config "Agent configuration" || return 0

    local target_user="${SUDO_USER:-$HUMAN_USER}"
    local first_agent="${AGENT_USERS[0]}"
    local secret="${APP_PW[$first_agent]:-}"
    if [[ -z $secret && -r $CRED_FILE ]]; then
        secret="$(awk -F'= *' -v k="${first_agent}-app" '$1 ~ "^" k "[[:space:]]*$" {print $2; exit}' "$CRED_FILE" | awk '{print $1}')"
    fi
    if [[ -z $secret ]]; then
        warn "no app password for $first_agent — skipping agent config"
        mark_phase agent-config
        return 0
    fi

    local dir="/home/$target_user/.config/tailmail"
    if [[ ! -d /home/$target_user ]]; then
        warn "home for $target_user not found; agent config not written"
        mark_phase agent-config
        return 0
    fi
    install -d -m 0700 -o "$target_user" -g "$target_user" "$dir"
    ( umask 077
      cat > "$dir/config" <<EOF
[default]
host     = $MAIL_HOST
username = $first_agent@$MAIL_DOMAIN
password = $secret
from     = $first_agent@$MAIL_DOMAIN
EOF
    )
    chown "$target_user:$target_user" "$dir/config"
    chmod 0600 "$dir/config"
    info "$dir/config → $first_agent@$MAIL_DOMAIN"
    mark_phase agent-config
}

verify() {
    log "Verification"
    local fails=0

    systemctl is-active --quiet stalwart.service && info "stalwart active" || { warn "stalwart inactive"; fails=$((fails+1)); }

    local socks; socks="$(ss -ltnH | awk '{print $4}')"
    for p in 25 465 587 993 443; do
        grep -qxF "$TAILNET_IP:$p" <<<"$socks" && info "listener $TAILNET_IP:$p" || { warn "missing $TAILNET_IP:$p"; fails=$((fails+1)); }
    done
    if grep -qE ':8080$' <<<"$socks"; then warn "port 8080 still open"; fails=$((fails+1)); fi

    for p in 993 465 443; do
        if openssl s_client -connect "$TAILNET_IP:$p" -servername "$MAIL_HOST" \
                -verify_hostname "$MAIL_HOST" -verify_return_error \
                -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null >/dev/null 2>&1; then
            info "TLS ok on $TAILNET_IP:$p"
        else
            warn "TLS failed on $TAILNET_IP:$p"; fails=$((fails+1))
        fi
    done

    if [[ $NO_WEBMAIL != 1 ]]; then
        local code
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$MAIL_HOST/webmail/" || true)"
        [[ $code == 200 ]] && info "webmail HTTP 200" || { warn "webmail returned ${code:-nothing}"; fails=$((fails+1)); }
    fi

    local pw human_addr
    human_addr="$HUMAN_USER@$MAIL_DOMAIN"
    pw="${ACCOUNT_PW[$HUMAN_USER]:-}"
    if [[ -z $pw && -r $CRED_FILE ]]; then
        pw="$(awk -F'= *' -v u="$HUMAN_USER" '$1 ~ "^" u "[[:space:]]*$" {print $2; exit}' "$CRED_FILE" | awk '{print $1}')"
    fi
    if [[ -n $pw ]]; then
        if python3 - "$MAIL_HOST" "$human_addr" "$pw" <<'PY'
import imaplib, ssl, sys
host, user, pw = sys.argv[1:4]
with imaplib.IMAP4_SSL(host, 993, ssl_context=ssl.create_default_context(), timeout=20) as m:
    m.login(user, pw)
    m.select("INBOX", readonly=True)
print("ok")
PY
        then
            info "IMAP login as $human_addr"
        else
            warn "IMAP login failed for $human_addr"; fails=$((fails+1))
        fi
    fi

    (( fails == 0 )) && log "All checks passed" || warn "$fails check(s) failed — see above"
    return 0
}

summary() {
    cat <<EOF

$(printf '%sSetup complete%s' "$C_G" "$C_RESET")

  host        : $MAIL_HOST ($TAILNET_IP)
  domain      : $MAIL_DOMAIN
  accounts    : ${HUMAN_USER}@$MAIL_DOMAIN${AGENT_USERS[0]:+, ${AGENT_USERS[*]}}
  IMAP        : $MAIL_HOST:993
  SMTP        : $MAIL_HOST:465 (or 587 STARTTLS)
  webmail     : $( [[ $NO_WEBMAIL == 1 ]] && echo 'not installed' || echo "https://$MAIL_HOST/webmail/" )
  admin       : https://$MAIL_HOST/admin
  credentials : $CRED_FILE
  log         : $LOG_FILE

Next:
  1. Move $CRED_FILE into a password manager, then delete it.
  2. Sign in to the webmail with the full address as the username.
  3. Agents: python3 tailmail.py (see docs/03-accounts-and-agents.md).
  4. Re-run this script with --check to verify, or --diagnose on failure.

EOF
}

# ------------------------------------------------------------------- modes ---

run_preflight() {
    check_prerequisites
    info "preflight complete; nothing changed"
}

run_diagnose() {
    local out="/root/mail-setup-diagnose-$(date +%Y%m%d-%H%M%S).tar.gz"
    local tmp; tmp="$(mktemp -d)"
    {
        echo "## date"; date -Is
        echo "## os"; cat /etc/os-release
        echo "## kernel"; uname -a
        echo "## tailscale"; (tailscale status 2>&1 || true)
        echo "## version"; (/usr/local/bin/stalwart --version 2>&1 || true)
        echo "## service"; systemctl status stalwart --no-pager 2>&1 | head -40 || true
        echo "## listeners"; ss -ltn 2>&1
        echo "## journal"; journalctl -u stalwart -n 200 --no-pager 2>&1
        echo "## config"; sed -e 's/"secret"[[:space:]]*:[[:space:]]*"[^"]*"/"secret":"REDACTED"/g' /etc/stalwart/config.json 2>/dev/null || true
        echo "## phases"; ls -la "$STATE_DIR" 2>/dev/null || true
    } > "$tmp/report.txt" 2>&1
    tar -czf "$out" -C "$tmp" report.txt
    rm -rf "$tmp"
    chmod 0600 "$out"
    printf 'Support bundle: %s\n' "$out"
    printf 'Review it before sharing; it contains logs and listener information.\n'
}

main() {
    parse_args "$@"
    case "$MODE" in
        preflight)
            need_root; setup_logging; run_preflight; exit 0 ;;
        diagnose)
            need_root; setup_logging; run_diagnose; exit 0 ;;
        check)
            need_root; setup_logging; ASSUME_YES=1
            load_config; check_prerequisites; configure_values; verify; exit 0 ;;
    esac

    need_root
    setup_logging

    if (( ! RESUME )) && compgen -G "$STATE_DIR/*" >/dev/null; then
        die "an existing setup was found in $STATE_DIR. Use --resume to continue, or --reconfigure."
    fi

    load_config
    check_prerequisites
    configure_values

    if [[ $MODE == "reconfigure" ]]; then
        log "Reconfiguring listeners"
        RECOVERY_PW="$(cat /root/stalwart-recovery-password)"
        TAILNET_IP="$(tailnet_ip)"
        python3 - /etc/stalwart/stalwart.env <<'PY'
import re, sys
path = sys.argv[1]
out, seen = [], False
for line in open(path).read().splitlines():
    if re.match(r"^#?\s*STALWART_RECOVERY_MODE=", line):
        out.append("STALWART_RECOVERY_MODE=1"); seen = True
    else:
        out.append(line)
if not seen:
    out.append("STALWART_RECOVERY_MODE=1")
open(path, "w").write("\n".join(out) + "\n")
PY
        systemctl restart stalwart
        for _ in $(seq 1 30); do
            curl -fsS -o /dev/null http://127.0.0.1:8080/ 2>/dev/null && break
            sleep 1
        done
        curl -fsS -o /dev/null http://127.0.0.1:8080/ 2>/dev/null \
            || die "recovery mode did not start; check journalctl -u stalwart"
        create_listeners
        activate
        exit 0
    fi

    install_packages
    bootstrap_stalwart
    enter_recovery
    install_certificate
    create_listeners
    create_accounts
    create_app_passwords
    create_api_key
    install_webmail
    activate
    configure_firewall
    install_renewal
    write_agent_configs

    verify
    summary
}

main "$@"

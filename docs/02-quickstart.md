# Quick start

## 1. Run the installer

```bash
tar xzf stalwart-tailnet-mail-*.tar.gz
cd stalwart-tailnet-mail-*
sudo ./setup-mail.sh
```

It asks for:

| Prompt | Default |
|---|---|
| Server hostname (MagicDNS name) | detected from `tailscale status` |
| Mail domain | the same hostname |
| Human mailbox name (local part) | your sudo user |
| Agent mailbox names (comma-separated) | none |
| Install Bulwark Lite webmail | yes |

Then it prints the resolved values and asks for confirmation. Nothing is
changed before that point.

## 2. Watch the phases

```
Preflight              OS, arch, Tailscale, HTTPS, ports, disk
Installing             apt packages, Stalwart, stalwart-cli
Bootstrapping          writes config.json through the Bootstrap API
Recovery mode          management API on :8080, no mail listeners
Certificate            tailscale cert → Certificate object
Listeners              25/465/587/993/443 on loopback + tailnet
Accounts               human, agents, admin
App passwords          one per agent
API key                for certificate renewal
Webmail                Bulwark Lite mounted at /webmail/
Activate               recovery off, services on the real ports
Firewall               ufw rules for tailscale0
Renewal                weekly timer
Verification           listeners, TLS, IMAP login, webmail HTTP
```

The web wizard is **not** used. The script pins an administrator, submits the
`Bootstrap` object through the JMAP API, and continues in recovery mode. If a
future Stalwart changes the API, the script stops with a clear message and you
can fall back to the wizard (see below).

## 3. Read the credentials

```bash
sudo cat /root/mail-credentials.txt
```

It contains:

- the `admin@<domain>` password for `/admin`
- the human account password
- one account password and one **app password** per agent
- the webmail/admin URLs

Move these into a password manager and delete the file:

```bash
sudo shred -u /root/mail-credentials.txt
```

## 4. Sign in

- Webmail: `https://<host>.<tailnet>.ts.net/webmail/`
  Username is the **full address**, e.g. `alice@<host>.<tailnet>.ts.net`.
- Admin: `https://<host>.<tailnet>.ts.net/admin`
- IMAP/SMTP: same host, ports 993 / 465 (or 587 STARTTLS), full address as the
  username.

## 5. Verify

```bash
sudo ./setup-mail.sh --check
```

It checks services, listeners, wildcard binds, TLS on 993/465/443, IMAP login
as the human account, and the webmail endpoint.

## Unattended install

Copy `mail-setup.conf.example`, edit it, and run:

```bash
sudo ./setup-mail.sh --config mail-setup.conf --yes
```

```ini
# mail-setup.conf
MAIL_HOST="host.tailnet.ts.net"     # blank = detect
MAIL_DOMAIN="host.tailnet.ts.net"
HUMAN_USER="alice"
AGENT_USERS="agent-a,agent-b"       # blank = none
WEBMAIL="yes"
```

Missing values fall back to the Tailscale-detected hostname and the sudo user.
The script never prompts when `--config` is used with `--yes`.

## Flags

| Flag | Effect |
|---|---|
| `--preflight` | Run the checks only; change nothing |
| `--check` | Verify an existing install |
| `--diagnose` | Write a redacted support bundle to `/root` |
| `--resume` | Continue from the last completed phase |
| `--reconfigure` | Re-render listeners after a tailnet IP change |
| `--no-webmail` | Skip Bulwark Lite |
| `--domain <name>` | Override the domain (certificate caveat) |
| `--config <file>` | Load values from a file |
| `--yes` | Do not prompt |

## If the bootstrap API fails

The browser path still works:

1. `sudo systemctl restart stalwart` — it starts in bootstrap mode.
2. Get the temporary admin password:
   ```bash
   sudo journalctl -u stalwart -n 200 | grep -A8 'bootstrap mode'
   ```
3. Open `http://127.0.0.1:8080/admin` through an SSH tunnel
   (`ssh -L 18080:127.0.0.1:8080 user@<tailnet-ip>`), sign in, and complete the
   wizard with:
   - server hostname and domain: the values the script printed
   - **Automatically obtain TLS certificate: off**
   - RocksDB, internal directory, log file, manual DNS
4. Re-run `sudo ./setup-mail.sh --resume`; it continues from recovery mode.

## Logs

Everything is appended to `/var/log/mail-setup.log`. On failure the script
prints the failing line and tells you to run `--diagnose`.

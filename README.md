# Tailnet mail

A private mail server for a Tailscale tailnet, installed by one script:

- **Stalwart** — SMTP, IMAP4, HTTPS, JMAP in one Rust binary
- **Bulwark Lite** — webmail served by Stalwart at `/webmail/`
- **Tailscale TLS** — a trusted certificate for the node's MagicDNS name
- **No public exposure** — listeners bind to loopback and the `100.x` address

Everything about a particular tailnet is detected or asked for. There are no
hardcoded domains, addresses or account names.

## Quick start

```bash
./make-dist.sh
tar xzf dist/stalwart-tailnet-mail-*.tar.gz
cd stalwart-tailnet-mail-*
sudo ./setup-mail.sh
```

The installer asks for the hostname, mail domain, mailbox names and whether to
install the webmail, prints the plan for confirmation, then performs:

```
preflight → install → bootstrap → recovery → certificate → listeners
          → accounts → app passwords → webmail → activate → verify
```

The setup wizard is not required: configuration is applied through Stalwart's
`Bootstrap` API. If that API changes, the docs describe the web-wizard fallback.

## Requirements

- Debian 12/13 or Ubuntu 24.04/26.04, x86_64 or aarch64
- Tailscale logged in, MagicDNS **and HTTPS certificates** enabled
- Ports 25, 465, 587, 993 and 443 free
- Root access

See [docs/01-prerequisites.md](docs/01-prerequisites.md).

## What you get

| | |
|---|---|
| Webmail | `https://<host>.<tailnet>.ts.net/webmail/` |
| Admin | `https://<host>.<tailnet>.ts.net/admin` |
| IMAP | 993, implicit TLS |
| SMTP | 465 implicit TLS, 587 STARTTLS, 25 server-to-server |
| Accounts | full email address is the username |
| Agents | one account and one app password each |

Credentials are written to `/root/mail-credentials.txt` (mode 0600).

## Documentation

| Page | Contents |
|---|---|
| [00-overview](docs/00-overview.md) | architecture, design choices, limits |
| [01-prerequisites](docs/01-prerequisites.md) | host, Tailscale, naming, ports, firewall |
| [02-quickstart](docs/02-quickstart.md) | prompts, phases, flags, fallback |
| [03-accounts-and-agents](docs/03-accounts-and-agents.md) | accounts, app passwords, agent patterns |
| [04-operations](docs/04-operations.md) | backups, upgrades, renewal, recovery, uninstall |
| [05-troubleshooting](docs/05-troubleshooting.md) | symptoms, causes, fixes, API quirks |
| [06-security](docs/06-security.md) | threat model, secrets, exposure |
| [07-migrating-from-dovecot](docs/07-migrating-from-dovecot.md) | moving existing mail with Vandelay |
| [08-faq](docs/08-faq.md) | short answers to common questions |
| [overview.html](docs/overview.html) | one-page visual overview |

## Installer modes

```bash
sudo ./setup-mail.sh                 # interactive
sudo ./setup-mail.sh --preflight     # checks only
sudo ./setup-mail.sh --check         # verify an install
sudo ./setup-mail.sh --diagnose      # redacted support bundle
sudo ./setup-mail.sh --resume        # continue after a failure
sudo ./setup-mail.sh --reconfigure   # new tailnet IP
sudo ./setup-mail.sh --config mail-setup.conf --yes
```

## Scope

This is a private mail system, not a public MX:

- only addresses at the configured domain are accepted
- no internet mail, spam filtering or DKIM for public receivers
- Stalwart upgrades are manual; the certificate renews through a weekly timer
- the tailnet is the security boundary; use ACLs to narrow access

## Repository layout

```
setup-mail.sh              installer
mail-setup.conf.example    unattended configuration sample
make-dist.sh               builds the hand-off tarball
scripts/tailmail.py        minimal SMTP/IMAP client for agents
docs/                      documentation and the HTML overview
```

## Agent client

```bash
python3 scripts/tailmail.py send --to user@<host>.<tailnet>.ts.net \
    --subject "Build finished" --body "All tests passed."
python3 scripts/tailmail.py inbox --limit 10
python3 scripts/tailmail.py read 42
```

It reads `~/.config/tailmail/config`; the installer writes it for the account
that ran `setup-mail.sh`, pointed at the first agent account.

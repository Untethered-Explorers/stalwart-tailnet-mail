# Security

## Threat model

The server assumes:

- The **tailnet is trusted transport** but not necessarily every device on it.
- **No untrusted network** can reach the mail ports: there is no port
  forwarding, no public IP binding, no MX record.
- The **host itself is trusted**; anyone with root can read the mail store.

This is a private mail system, not a hardened public MX. Spam filtering, DKIM
for public receivers and abuse handling are out of scope.

## Exposure

Everything listens on:

```
127.0.0.1        loopback (local scripts, health checks)
100.x.y.z        the node's tailnet address
```

Nothing binds `0.0.0.0` or `::`. Verify:

```bash
ss -ltn | grep -E ':(25|465|587|993|443) '
sudo ./setup-mail.sh --check
```

The check looks for listeners on the tailnet address and for an open `:8080`.
Review `ss -ltn` for wildcard binds; the check does not reject them
independently.

## Authentication

- Accounts are internal to Stalwart; passwords are hashed with Stalwart's
  default (deliberately slow) scheme.
- **App passwords** are per-device secrets. Use them for agents and cron; keep
  account passwords for interactive logins only.
- **Auto-ban** closes connections from an address after repeated failed logins
  (100/day by default). A stale script can ban itself; rotate credentials
  instead of retrying.
- The `admin@` account is for management only. Do not use it in mail clients.

## Secrets on disk

| Secret | Path | Mode |
|---|---|---|
| account/admin passwords | `/root/mail-credentials.txt` | 0600, delete after storing |
| certificate renewal API key | `/root/stalwart-api-key` | 0600 |
| recovery admin password | `/root/stalwart-recovery-password` | 0600 |
| agent config | `~/.config/tailmail/config` | 0600 |
| TLS private key | `/etc/ssl/tailscale/mail.key` | 0600 |
| Stalwart data (includes mail and settings) | `/var/lib/stalwart` | `stalwart` user |

Backups contain all of it. Treat backup archives as sensitive.

## Recovery mode

`STALWART_RECOVERY_MODE=1` stops mail services and opens the management API on
plain HTTP `:8080`, bound to all interfaces, **without** auto-ban, rate limits
or access control. Use it only:

- from the local machine or an SSH tunnel,
- for as short a time as possible,
- and remove the variables afterwards.

The installer uses it internally between bootstrap and activation.

## Tailnet access control

Default tailnet policy lets every device reach every port. Tighten it with
grants (see prerequisites). Port 25 only needs to be reachable from other mail
servers; in a tailnet-only setup that is often just this node.

## Updates

- **Stalwart**: manual, via the official installer. Back up before upgrading.
  A mail server is internet-facing software in spirit even on a tailnet; do not
  run an old release for months.
- **Bulwark Lite**: updated through the `Application` object, same cadence as
  Stalwart releases.
- **Tailscale**: keep it current; it terminates TLS for the webmail and fetches
  the certificate.
- **OS packages**: keep `curl`, `jq`, `openssl` and the base system patched.

## What the certificate covers

`tailscale cert` issues a publicly trusted certificate for the node's MagicDNS
name. It is used for:

- IMAPS 993
- SMTPS 465 / STARTTLS 587 / SMTP 25
- HTTPS 443 (webmail, admin, JMAP)

Clients must connect by the **name**, not the `100.x` address, or hostname
verification fails. Do not disable verification in clients to "fix" that.

## What this setup does not protect against

- **Compromised tailnet devices.** Any allowed device can use the mail ports
  with valid credentials. ACLs and device hygiene are your controls.
- **Compromised root on the host.** Mail is stored unencrypted in the data
  store. Disk encryption is a separate decision.
- **Phishing and malicious attachments.** There is no spam or malware
  filtering; the webmail is a mail client, not a security gateway.
- **Denial of service from inside the tailnet.** Rate limits exist but are not
  a substitute for ACLs.

## Reporting and auditing

Stalwart logs authentication and delivery events per account
(`journalctl -u stalwart`). There is no SIEM integration by default; ship the
journal to your log system if you need retention.

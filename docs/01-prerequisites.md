# Prerequisites

## Host

| Requirement | Notes |
|---|---|
| Debian 12/13 or Ubuntu 24.04/26.04 | The script checks `/etc/os-release` |
| x86_64 or aarch64 | Raspberry Pi 4/5 with a 64-bit OS works |
| Root | `sudo ./setup-mail.sh` |
| ~1 GB RAM free | Stalwart's defaults are modest; mail volume is tiny |
| 2 GB free on `/var` | mail and RocksDB live in `/var/lib/stalwart` |
| Ports 25, 465, 587, 993, 443 free | The script refuses to start otherwise |

Nothing else should own those ports. If another MTA is installed (Postfix,
Exim, OpenSMTPD, Dovecot), stop and disable it first. The script will stop
`dovecot`, `opensmtpd`, `postfix` and `exim4` if they are active, but on a
fresh host you should remove them.

## Tailscale

1. Install Tailscale and log in:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   ```
2. Enable **MagicDNS** and **HTTPS Certificates** in the Tailscale admin
   console under **DNS**. Without HTTPS certificates, `tailscale cert` fails
   and the script stops with that message.
3. Confirm the node's names:
   ```bash
   tailscale status --json | jq -r '.Self.DNSName'
   tailscale ip -4
   ```
   You should see `<host>.<tailnet>.ts.net` and a `100.x.y.z` address.

The script reads both values; nothing is hardcoded.

## Naming model

The guide uses the node's **MagicDNS name as the mail domain**:

```
hostname : <host>.<tailnet>.ts.net
domain   : <host>.<tailnet>.ts.net
addresses: <user>@<host>.<tailnet>.ts.net
```

This is what makes the certificate and the addresses line up with zero DNS
work. You can pass `--domain` to use a different domain, but then the
Tailscale certificate will not cover the addresses' domain and clients that
verify names will complain. For a public domain, you need your own certificate
and DNS; that is out of scope here.

## Firewall

`ufw` is common on Ubuntu. If it is active, the script adds tailnet-scoped
rules:

```bash
ufw allow in on tailscale0 to any port 25  proto tcp
ufw allow in on tailscale0 to any port 465 proto tcp
ufw allow in on tailscale0 to any port 587 proto tcp
ufw allow in on tailscale0 to any port 993 proto tcp
ufw allow in on tailscale0 to any port 443 proto tcp
```

If you use nftables or a cloud firewall, replicate those rules for
`tailscale0` only. Do **not** open the ports on the public interface.

## Tailnet ACLs

By default every tailnet device can reach the mail ports. To limit that, add
grants in the Tailscale ACL policy. Example shape:

```json
{
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["tag:mail"],
      "ip": ["tcp:443", "tcp:465", "tcp:587", "tcp:993"]
    }
  ]
}
```

Tag the mail node `tag:mail` and keep port 25 out of the grant unless another
node must deliver mail directly.

## Before you run

- [ ] Host is fresh, or the old mail server is stopped
- [ ] `tailscale up` is active and the node has a MagicDNS name
- [ ] HTTPS certificates are enabled for the tailnet
- [ ] Ports 25/465/587/993/443 are free
- [ ] You have the sudo password
- [ ] You know which mailbox names you want

Next: [Quick start](02-quickstart.md).

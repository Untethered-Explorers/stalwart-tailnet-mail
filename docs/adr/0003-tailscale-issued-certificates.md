---
id: ADR-0003
applies_to:
  - "setup-mail.sh"
  - "docs/01-prerequisites.md"
  - "docs/04-operations.md"
  - "docs/06-security.md"
status: Accepted
---

# ADR-0003: Use Tailscale-issued certificates and renew them weekly

- **Deciders:** McFuzzySquirrel
- **Date:** 2026-11-14

**Technical Story:** Give mail and web clients a trusted TLS certificate for a
private MagicDNS name without public DNS or inbound ACME challenges.

## Agent Rules

- **MUST:** Obtain the default certificate with `tailscale cert` for
  `MAIL_HOST`.
- **MUST:** Fail preflight when the tailnet lacks HTTPS certificate capability.
- **MUST NOT:** Use a self-signed certificate or ACME in the default install
  path.
- **MUST:** Document that `--domain` requires an externally supplied certificate
  covering that domain.
- **SHOULD:** Renew weekly and update the Stalwart `Certificate` object over
  JMAP.

## Verify

- **Check:** `grep -n 'tailscale cert\|mail-cert-renew' setup-mail.sh`,
  `grep -n 'own certificate' README.md docs/01-prerequisites.md`,
  `systemctl list-timers mail-cert-renew.timer`, and
  `sudo ./setup-mail.sh --check`
- **Expected:** The installer calls `tailscale cert`, both documents state the
  custom-domain certificate caveat, the weekly timer is scheduled, and the check
  verifies the TLS chain and hostname on 993, 465, and 443.

## Context and Problem Statement

Mail clients and browsers verify TLS hostnames. The server uses a MagicDNS name
that is not publicly resolvable, so a public ACME challenge cannot validate it.
How should the server obtain and renew a trusted certificate?

## Decision Drivers

- Clients must validate the certificate without custom trust settings.
- No public port 80, 443, DNS API access, or public DNS record.
- Renewal must survive unattended operation.
- The certificate should match the name clients already use.
- A custom domain is an explicit opt-in with its own certificate burden.

## Considered Options

- Let's Encrypt or another ACME issuer.
- A self-signed certificate installed on every client.
- A Tailscale-issued certificate for the MagicDNS name.

## Decision Outcome

Chosen option: "A Tailscale-issued certificate for the MagicDNS name", because
it is publicly trusted, requires no public DNS or inbound challenge, and matches
the address clients use. A weekly systemd timer renews it and updates the
Stalwart `Certificate` object over JMAP.

### Positive Consequences

- Clients get a trusted certificate with no manual trust store changes.
- Renewal is unattended and only restarts Stalwart when the certificate changes.
- The certificate name matches the default mail domain.

### Negative Consequences

- The certificate only covers the MagicDNS name.
- A custom `--domain` requires a separately supplied certificate, and the
  default renewal script targets `MAIL_DOMAIN`.
- The renewal timer and API key become part of the availability path.
- A failed renewal eventually breaks TLS after the certificate expires.

## Pros and Cons of the Options

### ACME issuer

- Good, because it is widely supported and automatable for public names.
- Bad, because it needs a public name and either inbound port 80/443 or DNS API
  access, none of which this setup has.

### Self-signed certificate

- Good, because it needs no external service.
- Bad, because every client must install and maintain a trust anchor, and
  hostname verification warnings are easy to disable insecurely.

### Tailscale-issued certificate

- Good, because it is trusted, automatic, and tied to the node identity.
- Bad, because it is limited to the MagicDNS name and depends on Tailscale.

## Links

- Implemented by [setup-mail.sh](../../setup-mail.sh).
- Guidance: [01-prerequisites.md](../01-prerequisites.md),
  [04-operations.md](../04-operations.md), [06-security.md](../06-security.md).

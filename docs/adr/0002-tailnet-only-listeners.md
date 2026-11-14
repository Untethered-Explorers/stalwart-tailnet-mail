---
id: ADR-0002
applies_to:
  - "setup-mail.sh"
  - "docs/01-prerequisites.md"
  - "docs/06-security.md"
status: Accepted
---

# ADR-0002: Bind all listeners to loopback and the tailnet address

- **Deciders:** McFuzzySquirrel
- **Date:** 2026-11-14

**Technical Story:** Keep a private mail server reachable to tailnet devices
without creating a public attack surface.

## Agent Rules

- **MUST:** Bind every mail and web listener to `127.0.0.1` and the node's
  `100.x` address.
- **MUST NOT:** Bind a mail or web listener to `0.0.0.0` or `::`.
- **MUST:** Reach the recovery management API through `127.0.0.1:8080` and
  close it before activation.
- **MUST:** Add firewall rules only on `tailscale0`.

## Verify

- **Check:** `grep -n 'bind=' setup-mail.sh`, `grep -n 'ufw allow'
  setup-mail.sh`, then `sudo ./setup-mail.sh --check`, then
  `ss -ltn | grep -E ':(25|465|587|993|443|8080) '`
- **Expected:** Every mail and web listener is on `127.0.0.1` or `100.x`; no
  `0.0.0.0` or `::` appears; `:8080` is absent after install; every ufw rule
  includes `in on tailscale0`.

## Context and Problem Statement

The server must be usable by browsers and mail clients on a tailnet, but it
should not be reachable from the public internet. Which bind addresses and
firewall scope satisfy both requirements?

## Decision Drivers

- No public port forwarding, MX record, or inbound internet traffic.
- The tailnet is the intended security boundary.
- Standard mail clients should connect without a proxy.
- The certificate is issued for the node's MagicDNS name.
- Recovery mode must be reachable locally during installation only.

## Considered Options

- Bind to all interfaces and rely on an external firewall.
- Bind to loopback only and use Tailscale Serve for every protocol.
- Bind to loopback and the node's tailnet address.

## Decision Outcome

Chosen option: "Bind to loopback and the node's tailnet address", because it
lets tailnet clients connect directly while leaving no public bind, and it
avoids depending on an external firewall to hide a wildcard listener.

### Positive Consequences

- No public listener exists even if the host firewall is misconfigured.
- Mail clients use ordinary IMAP/SMTP settings.
- The same bind model applies to webmail, admin, and mail ports.

### Negative Consequences

- Clients must be on the tailnet.
- Tailnet ACLs become the access-control layer.
- A tailnet IP change requires `--reconfigure` to re-render the listeners.

## Pros and Cons of the Options

### Bind to all interfaces and rely on a firewall

- Good, because it works with any client and survives an IP change.
- Bad, because a firewall mistake exposes the mail ports to the internet.

### Loopback only with Tailscale Serve

- Good, because nothing binds the tailnet interface directly.
- Bad, because mail protocols and ports need additional proxying, and the setup
  becomes more complex than the problem requires.

### Loopback and the tailnet address

- Good, because it provides direct access with no public bind.
- Bad, because the tailnet address is part of the configuration and can change.

## Links

- Implemented by [setup-mail.sh](../../setup-mail.sh).
- Related: [ADR-0003](0003-tailscale-issued-certificates.md).
- Guidance: [01-prerequisites.md](../01-prerequisites.md),
  [06-security.md](../06-security.md).

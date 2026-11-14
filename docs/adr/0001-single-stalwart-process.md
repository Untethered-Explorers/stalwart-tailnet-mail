---
id: ADR-0001
applies_to:
  - "setup-mail.sh"
  - "docs/**"
status: Accepted
---

# ADR-0001: Use Stalwart as the only mail and web process

- **Deciders:** McFuzzySquirrel
- **Date:** 2026-11-14

**Technical Story:** Build a private mail server that a single operator can
install, run, and back up without maintaining a multi-process mail stack.

## Agent Rules

- **MUST:** Install and run Stalwart as the SMTP, IMAP, JMAP, and HTTPS process.
- **MUST NOT:** Add Postfix, Dovecot, nginx, Apache, or a separate webmail
  runtime to the default install path.
- **SHOULD:** Configure Stalwart through its APIs instead of editing
  `/etc/stalwart/config.json` by hand.

## Verify

- **Check:** `grep -n 'apt-get install' setup-mail.sh` and
  `grep -nE 'nginx|apache2|dovecot|postfix|opensmtpd' setup-mail.sh`
- **Expected:** The package line installs only `curl jq openssl python3
  ca-certificates`. The only matches for other mail or web servers are the
  legacy-service stop loop in `activate()`.

## Context and Problem Statement

A small tailnet needs real SMTP and IMAP, a browser client, and an admin
interface on one host. Should the install use a conventional multi-process mail
stack, or one server that covers mail, web, and administration?

## Decision Drivers

- Few processes to install, patch, monitor, and back up.
- One data store for mail and settings.
- No public MX, spam filtering, or internet mail to justify a larger stack.
- A browser-free, scriptable install with no PHP, Node, or separate web server.
- Tailscale handles identity transport and certificate issuance.

## Considered Options

- Postfix, Dovecot, Roundcube, and nginx.
- Stalwart with Bulwark Lite served by Stalwart.
- An external hosted mail provider.

## Decision Outcome

Chosen option: "Stalwart with Bulwark Lite served by Stalwart", because it
covers SMTP, IMAP4, JMAP, HTTPS, and webmail hosting in one process and one data
store, which is the smallest stack that still gives real mail clients what they
need.

### Positive Consequences

- One service and one data store to run, patch, and back up.
- One certificate and one set of listeners for mail and web.
- No PHP, Node, nginx, or CORS configuration.
- The installer can configure the server through one API.

### Negative Consequences

- The project depends on Stalwart's API and release cadence.
- Stalwart upgrades are manual and not pinned by this repository.
- Operators familiar with Postfix and Dovecot need to learn Stalwart's account
  and JMAP model.

## Pros and Cons of the Options

### Postfix, Dovecot, Roundcube, and nginx

- Good, because each component is widely documented and replaceable.
- Bad, because it adds several services, a database, a PHP runtime, and a web
  server to install and secure for a small private tailnet.

### Stalwart with Bulwark Lite

- Good, because one process owns mail, webmail hosting, JMAP, and HTTPS.
- Bad, because the stack is less familiar and its API can change between
  releases.

### External hosted mail provider

- Good, because it removes host maintenance.
- Bad, because it moves mail off the tailnet and does not meet the private,
  self-hosted requirement.

## Links

- Implemented by [setup-mail.sh](../../setup-mail.sh).
- Related: [ADR-0006](0006-bulwark-lite-as-application.md).
- Design: [00-overview.md](../00-overview.md).

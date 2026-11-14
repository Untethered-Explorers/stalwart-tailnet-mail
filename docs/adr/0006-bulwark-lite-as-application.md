---
id: ADR-0006
applies_to:
  - "setup-mail.sh"
  - "docs/00-overview.md"
  - "docs/08-faq.md"
status: Accepted
---

# ADR-0006: Serve Bulwark Lite as a Stalwart Application

- **Deciders:** McFuzzySquirrel
- **Date:** 2026-11-14

**Technical Story:** Provide a browser mail client without adding a separate web
server, PHP runtime, or Node process.

## Agent Rules

- **MUST:** Install the webmail as a Stalwart `Application` with
  `urlPrefix={"/webmail":true}`.
- **MUST:** Trigger `Action/UpdateApps` after creating or updating the
  Application.
- **MUST NOT:** Add a separate web server or Node process for the webmail.
- **SHOULD:** Verify that `/webmail/` returns HTTP 200 after install.

## Verify

- **Check:** `grep -n 'Application\|UpdateApps' setup-mail.sh` and
  `curl -sS -o /dev/null -w '%{http_code}' https://<host>/webmail/`
- **Expected:** The installer creates the Application, triggers the update
  action, and the webmail URL returns 200.

## Context and Problem Statement

The server needs a browser client for people who do not want to configure a mail
app. Should the webmail run as a separate service, or be served by the same
process that hosts JMAP?

## Decision Drivers

- No extra runtime or web server to install and secure.
- Same origin as JMAP, so no CORS configuration.
- Simple upgrades through Stalwart's Application object.
- The webmail must work on the tailnet with the existing certificate.
- A `--no-webmail` path must remain available.

## Considered Options

- Roundcube with PHP and a web server.
- Full Bulwark with a Node process and admin console.
- Bulwark Lite served as a Stalwart `Application`.

## Decision Outcome

Chosen option: "Bulwark Lite served as a Stalwart `Application`", because it
adds no process, shares the Stalwart origin and certificate, and covers mail,
calendars, contacts, and files for a small tailnet.

### Positive Consequences

- No PHP, Node, nginx, or CORS configuration.
- The webmail uses the same certificate and hostname as JMAP.
- Updating the webmail is an Application update, not a package upgrade.

### Negative Consequences

- The bundle downloads from GitHub on first use, so `/webmail/` can return 404
  until it arrives.
- The feature set is smaller than full Bulwark.
- The deployment depends on the upstream release asset URL.

## Pros and Cons of the Options

### Roundcube with PHP and a web server

- Good, because it is mature and familiar.
- Bad, because it adds PHP, a web server, a database, and another origin to
  configure and secure.

### Full Bulwark with Node

- Good, because it has more features, including an admin console and web push.
- Bad, because it adds a Node process and settings sync for a small tailnet.

### Bulwark Lite as a Stalwart Application

- Good, because it is static, same-origin, and has no extra runtime.
- Bad, because it depends on a downloaded bundle and has fewer features.

## Links

- Implemented by [setup-mail.sh](../../setup-mail.sh).
- Design: [00-overview.md](../00-overview.md).
- Related: [ADR-0001](0001-single-stalwart-process.md),
  [08-faq.md](../08-faq.md).

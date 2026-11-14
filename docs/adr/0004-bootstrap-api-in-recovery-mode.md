---
id: ADR-0004
applies_to:
  - "setup-mail.sh"
  - "docs/02-quickstart.md"
status: Accepted
---

# ADR-0004: Configure Stalwart through the Bootstrap API in recovery mode

- **Deciders:** McFuzzySquirrel
- **Date:** 2026-11-14

**Technical Story:** Install and configure Stalwart without a browser or the
interactive web wizard.

## Agent Rules

- **MUST:** Configure Stalwart through `update Bootstrap` and the `x:` JMAP
  methods, not by hand-editing `/etc/stalwart/config.json`.
- **MUST:** Stop if `/etc/stalwart/config.json` is absent after the Bootstrap
  step.
- **MUST:** Comment out `STALWART_RECOVERY_MODE` and
  `STALWART_RECOVERY_ADMIN` before activation.
- **MUST:** Verify that `:8080` is closed after activation.
- **MUST NOT:** Require the web wizard for the default install.
- **SHOULD:** Keep the documented web-wizard fallback working when the API
  changes.

## Verify

- **Check:** `grep -n 'update Bootstrap\|STALWART_RECOVERY_MODE\|STALWART_RECOVERY_ADMIN' setup-mail.sh`
  and `sudo ./setup-mail.sh --check`
- **Expected:** The installer calls `update Bootstrap`, disables the recovery
  variables in `activate()`, and the check reports no open `:8080`.

## Context and Problem Statement

The install must run unattended on a fresh host and produce a working server.
Stalwart ships a web wizard, but the installer cannot depend on a browser
session. How should it apply the initial configuration and create the objects
that the wizard would normally create?

## Decision Drivers

- Unattended and repeatable installation.
- No browser or SSH tunnel during the normal path.
- Clear failure when Stalwart's API changes.
- Recovery mode is available before mail listeners exist.
- The final state must not leave the recovery API open.

## Considered Options

- Drive the web wizard with a browser or headless browser.
- Write `/etc/stalwart/config.json` directly.
- Use the Bootstrap API and recovery-mode JMAP calls.

## Decision Outcome

Chosen option: "Use the Bootstrap API and recovery-mode JMAP calls", because it
is scriptable, does not depend on browser automation, and uses Stalwart's
supported configuration surface. The installer enters recovery mode, applies the
Bootstrap object and the `x:` JMAP objects, then comments out the recovery
variables and restarts the service.

### Positive Consequences

- The install runs without a browser.
- Configuration steps are visible in the script and the log.
- The same API creates listeners, accounts, app passwords, and the certificate
  object.

### Negative Consequences

- The installer is coupled to Stalwart's API shapes and can break on an upgrade.
- Recovery mode opens a management API that must be closed correctly.
- The fallback wizard path needs separate documentation and manual steps.

## Pros and Cons of the Options

### Browser-driven web wizard

- Good, because it follows the vendor's intended first-run flow.
- Bad, because it needs a browser, is hard to automate, and is difficult to
  repeat or verify.

### Direct `config.json` editing

- Good, because it avoids API coupling.
- Bad, because the schema is internal, easy to corrupt, and not the supported
  configuration path.

### Bootstrap API and recovery-mode JMAP

- Good, because it is scriptable and uses supported APIs.
- Bad, because API changes can break the installer and recovery mode adds a
  temporary exposed management surface.

## Links

- Implemented by [setup-mail.sh](../../setup-mail.sh).
- Guidance: [02-quickstart.md](../02-quickstart.md).
- Related: [ADR-0002](0002-tailnet-only-listeners.md).

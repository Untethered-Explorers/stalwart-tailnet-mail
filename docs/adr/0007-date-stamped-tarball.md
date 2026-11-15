---
id: ADR-0007
applies_to:
  - "make-dist.sh"
  - "READ-ME-FIRST.md"
  - "README.md"
  - "CHANGELOG.md"
  - "LICENSE"
  - "THIRD-PARTY-NOTICES.md"
  - "docs/**"
status: Accepted
---

# ADR-0007: Distribute a date-stamped, self-contained tarball

- **Deciders:** McFuzzySquirrel
- **Date:** 2026-11-14

**Technical Story:** Hand the installer and its documentation to someone who
wants to run the same setup on another tailnet.

## Agent Rules

- **MUST:** Include `setup-mail.sh`, `make-dist.sh`,
  `mail-setup.conf.example`, `READ-ME-FIRST.md`, `README.md`, `CHANGELOG.md`,
  `LICENSE`, `THIRD-PARTY-NOTICES.md`, the top-level `docs/*.md`,
  `docs/adr/*.md`, `docs/releases/*.md`, `scripts/tailmail.py`, and
  `scripts/install-tailmail-harness.sh` in the tarball.
- **MUST:** Use a date-stamped tarball name and print its SHA-256.
- **MUST NOT:** Require a git checkout on the target host.
- **SHOULD:** Rebuild the tarball after documentation changes.

## Verify

- **Check:** `./make-dist.sh` and
  `tar tzf dist/stalwart-tailnet-mail-*.tar.gz`
- **Expected:** The archive contains the installer, `make-dist.sh`, sample
  config, `READ-ME-FIRST.md`, `README.md`, `CHANGELOG.md`, `LICENSE`,
  `THIRD-PARTY-NOTICES.md`, the top-level docs, the ADRs, the release notes, and
  both tailmail scripts, and the build prints a SHA-256.

## Context and Problem Statement

The project has no package registry or installation channel. How should an
operator get a runnable copy onto a fresh host without cloning the repository or
assembling the files by hand?

## Decision Drivers

- One archive that contains everything needed to install.
- No network fetch for the installer or its local docs.
- A simple integrity check for hand-off.
- Minimal packaging tooling.
- The repository can stay the source of truth.

## Considered Options

- Tell operators to clone the git repository.
- Publish an apt package or container image.
- Build a date-stamped tarball with `make-dist.sh`.

## Decision Outcome

Chosen option: "Build a date-stamped tarball with `make-dist.sh`", because it is
the smallest distribution mechanism that carries the installer, sample config,
docs, and agent client, and it does not require git or a package repository on
the target host.

### Positive Consequences

- The hand-off is one file plus a SHA-256.
- The tarball includes the operational docs next to the installer.
- No registry, signing key, or package repository is required.

### Negative Consequences

- The name is date-stamped, not semantic, so versions do not compare cleanly.
- The archive is not signed by default.
- A tarball can drift from the repository if it is not rebuilt after doc
  changes.

## Pros and Cons of the Options

### Git clone

- Good, because it is always the current tree.
- Bad, because it requires git and network access on the target host and exposes
  the whole repository.

### apt package or container image

- Good, because it supports versioning and standard tooling.
- Bad, because it adds packaging, hosting, and signing work that this project
  does not need yet.

### Date-stamped tarball

- Good, because it is self-contained and trivial to build.
- Bad, because it lacks semantic versions and a signature.

## Links

- Implemented by [make-dist.sh](../../make-dist.sh).
- Entry point: [READ-ME-FIRST.md](../../READ-ME-FIRST.md).

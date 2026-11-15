#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 McFuzzySquirrel
# SPDX-License-Identifier: MIT
#
# make-dist.sh — build the hand-off tarball.
#
#   ./make-dist.sh
#
# Produces dist/stalwart-tailnet-mail-<date>.tar.gz with the installer, docs,
# sample config, agent client and harness setup helper, and Tailscale boot helper.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d)"
NAME="stalwart-tailnet-mail-$STAMP"
STAGE="$HERE/dist/$NAME"
OUT="$HERE/dist/$NAME.tar.gz"

rm -rf "$STAGE"
mkdir -p "$STAGE/docs/adr" "$STAGE/docs/releases" "$STAGE/scripts"

cp "$HERE/setup-mail.sh" "$HERE/make-dist.sh" "$STAGE/"
cp "$HERE/mail-setup.conf.example" "$STAGE/"
cp "$HERE/READ-ME-FIRST.md" "$HERE/README.md" "$HERE/CHANGELOG.md" \
   "$HERE/LICENSE" "$HERE/THIRD-PARTY-NOTICES.md" "$STAGE/"
cp "$HERE"/docs/*.md "$STAGE/docs/"
cp "$HERE"/docs/adr/*.md "$STAGE/docs/adr/"
cp "$HERE"/docs/releases/*.md "$STAGE/docs/releases/"
cp "$HERE/scripts/tailmail.py" "$STAGE/scripts/"
cp "$HERE"/scripts/*.sh "$STAGE/scripts/"
mkdir -p "$STAGE/systemd"
cp "$HERE"/systemd/*.service "$STAGE/systemd/"
chmod +x "$STAGE/setup-mail.sh" "$STAGE/make-dist.sh" "$STAGE"/scripts/*.sh

tar -czf "$OUT" -C "$HERE/dist" "$NAME"
rm -rf "$STAGE"
chmod 0644 "$OUT"

printf 'Built %s\n' "$OUT"
printf 'sha256 %s\n' "$(sha256sum "$OUT" | cut -d' ' -f1)"
printf 'size   %s\n' "$(du -h "$OUT" | cut -f1)"

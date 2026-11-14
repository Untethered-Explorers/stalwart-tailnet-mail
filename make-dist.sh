#!/usr/bin/env bash
#
# make-dist.sh — build the hand-off tarball.
#
#   ./make-dist.sh
#
# Produces dist/stalwart-tailnet-mail-<date>.tar.gz with the installer, docs,
# sample config and the agent client. The tarball is what you give someone who
# wants to run the same setup on their own tailnet.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d)"
NAME="stalwart-tailnet-mail-$STAMP"
STAGE="$HERE/dist/$NAME"
OUT="$HERE/dist/$NAME.tar.gz"

rm -rf "$STAGE"
mkdir -p "$STAGE/docs" "$STAGE/scripts"

cp "$HERE/setup-mail.sh" "$STAGE/"
cp "$HERE/mail-setup.conf.example" "$STAGE/"
cp "$HERE/READ-ME-FIRST.md" "$STAGE/"
cp "$HERE"/docs/*.md "$STAGE/docs/"
cp "$HERE/scripts/tailmail.py" "$STAGE/scripts/"
chmod +x "$STAGE/setup-mail.sh"

# The HTML overview is generated separately; include it when present.
if [[ -f "$HERE/docs/overview.html" ]]; then
    cp "$HERE/docs/overview.html" "$STAGE/docs/"
fi

tar -czf "$OUT" -C "$HERE/dist" "$NAME"
rm -rf "$STAGE"
chmod 0644 "$OUT"

printf 'Built %s\n' "$OUT"
printf 'sha256 %s\n' "$(sha256sum "$OUT" | cut -d' ' -f1)"
printf 'size   %s\n' "$(du -h "$OUT" | cut -f1)"

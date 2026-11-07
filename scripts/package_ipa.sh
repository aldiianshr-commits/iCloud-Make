#!/usr/bin/env bash
# Packages an (unsigned) .app into an .ipa: Payload/<App>.app zipped.
# Usage: scripts/package_ipa.sh "<path/to/iCloud IPA.app>" "<output dir>"
set -euo pipefail
APP="$1"; OUT="$2"
[ -d "$APP" ] || { echo "app not found: $APP" >&2; exit 1; }
WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload" "$OUT"
cp -R "$APP" "$WORK/Payload/"
( cd "$WORK" && /usr/bin/zip -qry "ipa.zip" Payload )
mv "$WORK/ipa.zip" "$OUT/iCloud IPA.ipa"
rm -rf "$WORK"
# sanity check: binary present and arm64
BIN="$APP/iCloud IPA"
file "$BIN"
lipo -info "$BIN"
unzip -l "$OUT/iCloud IPA.ipa" | tail -n 3

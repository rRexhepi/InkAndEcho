#!/usr/bin/env bash
# Build the Flutter Linux release bundle and package it as two .deb files:
#   ink-and-echo_<version>_amd64.deb       (lite)
#   ink-and-echo-full_<version>_amd64.deb  (Calibre as hard dependency)
#
# Usage (from repo root or anywhere):
#   xplatform/scripts/package-linux.sh                  # build + package both
#   xplatform/scripts/package-linux.sh --skip-build     # reuse existing bundle
#
# Output:
#   xplatform/build/linux/x64/release/deb/*.deb
#
# Requires: flutter on PATH (or at /home/$USER/flutter/bin), dpkg-deb.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XPLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LINUX_DIR="$XPLATFORM_DIR/linux"
ICONS_DIR="$LINUX_DIR/icons"
BUNDLE_DIR="$XPLATFORM_DIR/build/linux/x64/release/bundle"
OUT_DIR="$XPLATFORM_DIR/build/linux/x64/release/deb"

BINARY=ink_and_echo
APP_ID=com.rexhep.inkandecho
PKG=ink-and-echo
ARCH=amd64
MAINTAINER='Rexhep Rexhepi <rexhep.rexhepi.5@gmail.com>'
HOMEPAGE='https://rrexhepi.github.io/ink-and-echo-app/'

if ! command -v flutter >/dev/null 2>&1; then
  export PATH="$PATH:$HOME/flutter/bin"
fi

skip_build=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) skip_build=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(awk -F'[ :+]+' '/^version:/ {print $2; exit}' "$XPLATFORM_DIR/pubspec.yaml")"
[ -n "$VERSION" ] || { echo "could not read version from pubspec.yaml" >&2; exit 1; }
echo "==> version $VERSION"

if [ "$skip_build" -eq 0 ]; then
  echo "==> flutter build linux --release"
  (cd "$XPLATFORM_DIR" && flutter pub get && flutter build linux --release)
fi

[ -x "$BUNDLE_DIR/$BINARY" ] || { echo "missing bundle binary at $BUNDLE_DIR/$BINARY" >&2; exit 1; }

mkdir -p "$OUT_DIR"

stage_one() {
  local variant="$1"   # "" or "-full"
  local extra_dep="$2" # "" or ", calibre"
  local desc_tail="$3"

  local pkgname="$PKG$variant"
  local debname="${pkgname}_${VERSION}_${ARCH}.deb"
  local stage; stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN

  install -d "$stage/opt/$PKG"
  cp -a "$BUNDLE_DIR/." "$stage/opt/$PKG/"

  install -d "$stage/usr/bin"
  ln -s "/opt/$PKG/$BINARY" "$stage/usr/bin/$BINARY"

  install -Dm644 "$ICONS_DIR/$APP_ID.desktop" \
    "$stage/usr/share/applications/$APP_ID.desktop"
  install -Dm644 "$ICONS_DIR/$APP_ID.svg" \
    "$stage/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg"
  for size in 16 22 24 32 48 64 96 128 192 256 512; do
    [ -f "$ICONS_DIR/$APP_ID-${size}.png" ] || continue
    install -Dm644 "$ICONS_DIR/$APP_ID-${size}.png" \
      "$stage/usr/share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
  done

  install -d "$stage/DEBIAN"
  cat > "$stage/DEBIAN/control" <<EOF
Package: $pkgname
Version: $VERSION
Section: misc
Priority: optional
Architecture: $ARCH
Depends: libgtk-3-0, libmpv2 | libmpv1, ffmpeg, zenity | kdialog$extra_dep
Maintainer: $MAINTAINER
Homepage: $HOMEPAGE
Description: Audiobook and ebook sync reader$( [ -n "$variant" ] && echo ' (full)' || echo ' (lite)' )
 Ink and Echo pairs an audiobook with its ebook and plays them in sync.
 Word-level or sentence-level highlighting follows the narration, with
 playback speed control, free-form annotation, and a page-curl reader.
 .
$desc_tail
EOF

  echo "==> packaging $debname"
  dpkg-deb --root-owner-group --build "$stage" "$OUT_DIR/$debname" >/dev/null
  rm -rf "$stage"
  trap - RETURN
  echo "    $OUT_DIR/$debname"
}

stage_one "" "" " This is the lite build: EPUB and MOBI imports work out of the box
 using bundled pure-Dart parsers. PDF import is not available without
 Calibre — install the ink-and-echo-full variant or \`sudo apt install
 calibre\` separately if you need it."

stage_one "-full" ", calibre" " This is the full build: depends on Calibre for PDF, AZW3, RTF, DOCX,
 LIT, FB2 and other format conversion. Calibre itself pulls in Python,
 Qt, and a webengine — expect ~500 MB of additional disk on a fresh
 install. Use ink-and-echo (the lite variant) instead if you only need
 EPUB and MOBI."

echo
echo "==> done. .debs in $OUT_DIR"
ls -lh "$OUT_DIR"/*.deb

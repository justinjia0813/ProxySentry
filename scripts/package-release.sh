#!/usr/bin/env bash
set -euo pipefail
umask 022

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ProxySentry.xcodeproj"
SCHEME="ProxySentry"
VERSION_INPUT="${1:-}"

if (( $# > 1 )); then
  echo "usage: $0 [version]" >&2
  exit 2
fi
if [[ -n "$VERSION_INPUT" && ! "$VERSION_INPUT" =~ ^[0-9]+(\.[0-9]+){1,2}([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "invalid version: $VERSION_INPUT" >&2
  exit 2
fi
for command in xcodebuild lipo ditto shasum codesign; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 127
  }
done
[[ -d "$PROJECT" ]] || { echo "missing project: $PROJECT" >&2; exit 1; }

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/proxysentry-release.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

XCODEBUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -derivedDataPath "$BUILD_DIR"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
  ARCHS="arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
)
if [[ -n "$VERSION_INPUT" ]]; then
  XCODEBUILD_ARGS+=(MARKETING_VERSION="$VERSION_INPUT")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

APP="$BUILD_DIR/Build/Products/Release/ProxySentry.app"
EXECUTABLE="$APP/Contents/MacOS/ProxySentry"
INFO_PLIST="$APP/Contents/Info.plist"
[[ -d "$APP" && -x "$EXECUTABLE" && -f "$INFO_PLIST" ]] || {
  echo "built app is incomplete: $APP" >&2
  exit 1
}

lipo "$EXECUTABLE" -verify_arch arm64 x86_64
/usr/bin/codesign --remove-signature "$EXECUTABLE"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$MIN_OS" == "13.0" ]] || {
  echo "expected LSMinimumSystemVersion 13.0, got: ${MIN_OS:-<missing>}" >&2
  exit 1
}
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}([.-][A-Za-z0-9.-]+)?$ ]] || {
  echo "invalid CFBundleShortVersionString: ${VERSION:-<missing>}" >&2
  exit 1
}
if [[ -n "$VERSION_INPUT" && "$VERSION" != "$VERSION_INPUT" ]]; then
  echo "version mismatch: requested $VERSION_INPUT, built $VERSION" >&2
  exit 1
fi

DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$DIST_DIR"
ZIP_NAME="ProxySentry-v${VERSION}-macOS-universal-unsigned.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="$DIST_DIR/$ZIP_NAME.sha256"
rm -f "$ZIP_PATH" "$SHA_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"
(cd "$DIST_DIR" && shasum -a 256 "$ZIP_NAME" > "$(basename "$SHA_PATH")")

echo "created: $ZIP_PATH"
echo "created: $SHA_PATH"

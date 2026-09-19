#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Tendon"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_DIR="$ROOT_DIR/.build/release"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

VERSION=""
PUBLISH_TO_GITHUB=false
DRAFT=false
PRERELEASE=false
NOTES_FILE=""

usage() {
    cat <<USAGE
Usage:
  scripts/release.sh VERSION [--github] [--draft] [--prerelease] [--notes-file PATH]

Examples:
  scripts/release.sh 0.1.0
  scripts/release.sh 0.1.0 --github --draft

Environment:
  CODESIGN_IDENTITY   Defaults to "-" for ad-hoc signing.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --github)
            PUBLISH_TO_GITHUB=true
            shift
            ;;
        --draft)
            DRAFT=true
            shift
            ;;
        --prerelease)
            PRERELEASE=true
            shift
            ;;
        --notes-file)
            NOTES_FILE="${2:-}"
            if [[ -z "$NOTES_FILE" ]]; then
                echo "--notes-file requires a path" >&2
                exit 2
            fi
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ -n "$VERSION" ]]; then
                echo "Unexpected argument: $1" >&2
                usage >&2
                exit 2
            fi
            VERSION="$1"
            shift
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    usage >&2
    exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must look like 0.1.0" >&2
    exit 2
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "This release script intentionally builds arm64 only." >&2
    exit 1
fi

ZIP_NAME="$APP_NAME-$VERSION-macos-arm64.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
TAG_NAME="v$VERSION"

cd "$ROOT_DIR"

echo "Building $APP_NAME $VERSION for macOS arm64..."
swift build -c release

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/assets/tendon.png" "$RESOURCES_DIR/tendon.png"
"$ROOT_DIR/scripts/generate_app_icon.sh" "$ROOT_DIR/assets/tendon_black.png" "$RESOURCES_DIR/$APP_NAME.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/$APP_NAME"

ARCH_DESCRIPTION="$(file "$MACOS_DIR/$APP_NAME")"
case "$ARCH_DESCRIPTION" in
    *"arm64"*)
        ;;
    *)
        echo "Built executable is not arm64: $ARCH_DESCRIPTION" >&2
        exit 1
        ;;
esac

codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
touch "$APP_DIR"

rm -f "$ZIP_PATH"
(
    cd "$DIST_DIR"
    ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_NAME"
)

echo "Created $ZIP_PATH"

if [[ "$PUBLISH_TO_GITHUB" == "true" ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "gh is required for --github. Install GitHub CLI and run gh auth login." >&2
        exit 1
    fi

    if gh release view "$TAG_NAME" >/dev/null 2>&1; then
        echo "Uploading asset to existing GitHub release $TAG_NAME..."
        gh release upload "$TAG_NAME" "$ZIP_PATH" --clobber
    else
        echo "Creating GitHub release $TAG_NAME..."
        args=(release create "$TAG_NAME" "$ZIP_PATH" --title "$APP_NAME $VERSION")

        if [[ -n "$NOTES_FILE" ]]; then
            args+=(--notes-file "$NOTES_FILE")
        else
            args+=(--notes "$APP_NAME $VERSION")
        fi

        if [[ "$DRAFT" == "true" ]]; then
            args+=(--draft)
        fi

        if [[ "$PRERELEASE" == "true" ]]; then
            args+=(--prerelease)
        fi

        gh "${args[@]}"
    fi
fi

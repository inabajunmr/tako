#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Tendon"
CASK_TOKEN="tendon"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
CASK_DIR="$ROOT_DIR/Casks"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

usage() {
    cat <<USAGE
Usage:
  scripts/update_cask.sh VERSION

Environment:
  GITHUB_REPOSITORY   Defaults to the origin remote repository, e.g. inabajunmr/tako.
USAGE
}

VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
    usage >&2
    exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must look like 0.1.0" >&2
    exit 2
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
    origin_url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
    case "$origin_url" in
        git@github.com:*.git)
            GITHUB_REPOSITORY="${origin_url#git@github.com:}"
            GITHUB_REPOSITORY="${GITHUB_REPOSITORY%.git}"
            ;;
        https://github.com/*.git)
            GITHUB_REPOSITORY="${origin_url#https://github.com/}"
            GITHUB_REPOSITORY="${GITHUB_REPOSITORY%.git}"
            ;;
        https://github.com/*)
            GITHUB_REPOSITORY="${origin_url#https://github.com/}"
            ;;
    esac
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
    echo "Could not determine GITHUB_REPOSITORY. Set it to owner/repo." >&2
    exit 1
fi

ZIP_NAME="$APP_NAME-$VERSION-macos-arm64.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
CASK_PATH="$CASK_DIR/$CASK_TOKEN.rb"

if [[ ! -f "$ZIP_PATH" ]]; then
    echo "Missing release zip: $ZIP_PATH" >&2
    exit 1
fi

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

mkdir -p "$CASK_DIR"
cat > "$CASK_PATH" <<CASK
cask "$CASK_TOKEN" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$GITHUB_REPOSITORY/releases/download/v#{version}/$APP_NAME-#{version}-macos-arm64.zip"
  name "$APP_NAME"
  desc "Small macOS launcher"
  homepage "https://github.com/$GITHUB_REPOSITORY"

  depends_on arch: :arm64

  app "$APP_NAME.app"

  uninstall quit: "com.juninaba.Tendon"

  zap trash: [
    "~/Library/Application Support/Tendon",
    "~/Library/Preferences/com.juninaba.Tendon.plist",
  ]
end
CASK

echo "Updated $CASK_PATH"

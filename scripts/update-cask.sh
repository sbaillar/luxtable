#!/usr/bin/env bash
# Point the Homebrew tap's cask at a published release, so
# `brew install --cask sbaillar/luxtable/luxtable` installs it.
#
#   scripts/update-cask.sh <version> <dmg>            write, commit and push the tap's cask
#   scripts/update-cask.sh --print <version> <dmg>    print the cask only
#
# The tap is the GitHub repository $LT_TAP (default sbaillar/homebrew-luxtable), cloned into
# a scratch folder each time. release.sh runs this after publishing; a failure there only
# warns, since the release itself is already out.
set -euo pipefail
cd "$(dirname "$0")/.."

print=0
[ "${1:-}" = --print ] && { print=1; shift; }
[ $# -eq 2 ] || { echo "usage: scripts/update-cask.sh [--print] <version> <dmg>" >&2; exit 2; }
version="$1" dmg="$2"
[ -f "$dmg" ] || { echo "update-cask: no disk image at $dmg" >&2; exit 1; }
sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"

cask() {
  cat <<EOF
cask "luxtable" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/sbaillar/luxtable/releases/download/v#{version}/Luxtable-#{version}-macos-arm64.dmg"
  name "Luxtable"
  desc "RAW photo workflow: fast culling, sessions and editing"
  homepage "https://luxtable.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Luxtable.app"

  zap trash: [
    "~/Library/Application Support/Luxtable",
    "~/Library/Caches/app.luxtable.Luxtable",
    "~/Library/Preferences/app.luxtable.Luxtable.plist",
  ]

  caveats <<~EOS
    Luxtable is signed with its own certificate and is not notarized by Apple,
    so macOS blocks the first launch. Open Luxtable once, then choose
    System Settings > Privacy & Security > Open Anyway.
  EOS
end
EOF
}

if [ "$print" = 1 ]; then cask; exit 0; fi

tap="${LT_TAP:-sbaillar/homebrew-luxtable}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gh repo clone "$tap" "$work/tap" -- --quiet
mkdir -p "$work/tap/Casks"
cask > "$work/tap/Casks/luxtable.rb"
cd "$work/tap"
git add Casks/luxtable.rb
if git diff --cached --quiet; then echo "update-cask: already at $version"; exit 0; fi
git -c credential.helper='!gh auth git-credential' commit -q -m "luxtable $version"
git -c credential.helper='!gh auth git-credential' push -q origin HEAD
echo "update-cask: $tap now installs $version"

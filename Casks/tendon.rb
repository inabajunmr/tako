cask "tendon" do
  version "0.0.1"
  sha256 "968406c1b2543b35abff6f8fe178ebf220278540be55250dcae132891c60392f"

  url "https://github.com/inabajunmr/tako/releases/download/v#{version}/Tendon-#{version}-macos-arm64.zip"
  name "Tendon"
  desc "Small macOS launcher"
  homepage "https://github.com/inabajunmr/tako"

  depends_on arch: :arm64

  app "Tendon.app"

  uninstall quit: "com.juninaba.Tendon"

  zap trash: [
    "~/Library/Application Support/Tendon",
    "~/Library/Preferences/com.juninaba.Tendon.plist",
  ]
end

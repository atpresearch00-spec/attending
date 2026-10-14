# Homebrew cask for Attending, published to the med-abdullah/homebrew-tap repository by
# scripts/publish.sh (version and sha256 are filled in there).
#   brew install --cask med-abdullah/tap/attending
cask "attending" do
  version "VERSION"
  sha256 "SHA256"

  url "https://github.com/med-abdullah/attending/releases/download/v#{version}/Attending-#{version}.zip"
  name "Attending"
  desc "Notch companion for med students: boards countdown, Anki, salah times and AI agents"
  homepage "https://github.com/med-abdullah/attending"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Attending updates itself from GitHub Releases.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Attending.app"

  uninstall quit: "app.attending.Attending"

  zap trash: [
    "~/Library/Application Support/Attending",
    "~/Library/Preferences/app.attending.Attending.plist",
    "~/Pictures/Attending",
  ]
end

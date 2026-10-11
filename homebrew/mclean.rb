cask "mclean" do
  version "1.0.6"
  sha256 "47bb693bd0cbef407dceff8884829450e545b15447c96129531abf2fa7a85fec"

  url "https://github.com/maclifevn/MClean/releases/download/v#{version}/MClean-#{version}.zip"
  name "MClean"
  desc "Free, open-source macOS app manager and system cleaner"
  homepage "https://github.com/maclifevn/MClean"

  depends_on macos: :ventura

  app "MClean.app"

  # Refresh LaunchServices so the Dock/Launchpad icon updates immediately on
  # (re)install instead of showing a stale cached icon (issue #111).
  postflight_steps do
    system_command "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
                   args: ["-f", "#{appdir}/MClean.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.maclife.mclean.plist",
    "~/Library/Caches/com.maclife.mclean",
    "~/Library/LaunchAgents/com.maclife.mclean.scheduler.plist",
  ]
end

cask "mclean" do
  version "1.0.3"
  sha256 "2ea50484026b94b1ff5727e1ab715ed7d6b988c9e5ebef1b5b9ddc7b999738ac"

  url "https://github.com/maclifevn/MClean/releases/download/v#{version}/MClean-#{version}.zip"
  name "MClean"
  desc "Free, open-source macOS app manager and system cleaner"
  homepage "https://github.com/maclifevn/MClean"

  depends_on macos: :ventura

  app "MClean.app"

  # Refresh LaunchServices so the Dock/Launchpad icon updates immediately on
  # (re)install instead of showing a stale cached icon (issue #111).
  postflight do
    system_command "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
                   args: ["-f", "#{appdir}/MClean.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.maclife.mclean.plist",
    "~/Library/Caches/com.maclife.mclean",
    "~/Library/LaunchAgents/com.maclife.mclean.scheduler.plist",
  ]
end

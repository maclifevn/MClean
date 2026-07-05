cask "mclean" do
  version "1.0.4"
  sha256 "72c6389a5561914ed4b616a75f97b09b46e949de6c0ade346292bc6afa0aec37"

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

cask "claudeometer" do
  version "0.6.0"
  sha256 "83aa29fbd1ad5f45611a4756e2c7cae3cec456994263f491c873cdf0c871b021"

  url "https://github.com/SGSI/claudeometer/releases/download/v#{version}/Claudeometer.dmg",
      verified: "github.com/SGSI/claudeometer/"
  name "Claudeometer"
  desc "Menu-bar meter for Claude usage: quota, burn rate, and alerts"
  homepage "https://github.com/SGSI/claudeometer"

  depends_on macos: :ventura

  app "Claudeometer.app"

  # The app is not yet notarized, so strip the quarantine flag Homebrew applies —
  # otherwise Gatekeeper blocks first launch ("damaged and can't be opened").
  # Once the app ships signed + notarized, delete this postflight block.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Claudeometer.app"]
  end

  zap trash: [
    "~/Library/Application Support/Claudeometer",
  ]
end

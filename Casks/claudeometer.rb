cask "claudeometer" do
  version "0.3.0"
  sha256 "c3cd4d921d7d57640ca503227cdec55e9a0c4f3541a41b130e76241e569b4a47"

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

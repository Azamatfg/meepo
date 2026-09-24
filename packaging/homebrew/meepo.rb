# Copy to Casks/meepo.rb in the Azamatfg/homebrew-meepo tap; after each release set version and the
# sha256 printed in the Release workflow's summary.
cask "meepo" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/Azamatfg/meepo/releases/download/v#{version}/Meepo.zip"
  name "Meepo"
  desc "Tab through your Claude Code agents"
  homepage "https://github.com/Azamatfg/meepo"

  depends_on macos: ">= :sonoma"

  app "Meepo.app"

  zap trash: [
    "~/.meepo",
    "~/Library/Group Containers/7N5485K2AV.com.azamatfg.meepo",
  ]
end

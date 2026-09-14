# typed: strict
# frozen_string_literal: true

cask "crow" do
  version "0.1.2"
  sha256 "68837e2e8c28cee19647dbbbd2df2680e58b401959bc4234e568adf1075825dc"

  url "https://github.com/startedourmission/crow/releases/download/v#{version}/Crow-macOS.dmg"
  name "Crow"
  desc "SSH workspace with a terminal and plain-text editor"
  homepage "https://github.com/startedourmission/crow"

  auto_updates true
  depends_on macos: :sequoia

  app "Crow.app"

  zap trash: [
    "~/Library/Application Support/Crow",
    "~/Library/Preferences/dev.chajinwoo.crow.plist",
    "~/Library/Saved Application State/dev.chajinwoo.crow.savedState",
  ]
end

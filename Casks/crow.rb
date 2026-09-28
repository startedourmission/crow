# typed: strict
# frozen_string_literal: true

cask "crow" do
  version "0.1.5"
  sha256 "56c93d77afcf002f38f4ece7bce35d8c246616757068dc24e2865c2e5c8b5faa"

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

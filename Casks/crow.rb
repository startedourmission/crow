# typed: strict
# frozen_string_literal: true

cask "crow" do
  version "0.1.1"
  sha256 "a6ba031b60befbcd659b32cb0f074f005375ca5ed6fa2f7e118f310a674feee4"

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

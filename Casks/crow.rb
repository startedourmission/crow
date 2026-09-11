# typed: strict
# frozen_string_literal: true

cask "crow" do
  version "0.1.0"
  sha256 "7c7c4f4c27e374599f0a4d804acc44f189a1af874a61e1e96561906a78ca60d5"

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

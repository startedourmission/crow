# typed: strict
# frozen_string_literal: true

cask "crow" do
  version "0.1.3"
  sha256 "8805a1d2deefa304eac62b0f8bdcafb96402c58f87c6b1a1ddeff1962e1bbccd"

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

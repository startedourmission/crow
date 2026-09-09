#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild test -project Crow.xcodeproj -scheme Crow-macOS \
    -destination 'platform=macOS' \
    -only-testing:CrowMacTests/TerminalIntegrationTests \
    -only-testing:CrowMacTests/EchoTerminalTests

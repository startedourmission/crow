#!/bin/zsh
set -euo pipefail
crow_root="${0:A:h:h}"
crow_build=$(mktemp -d /tmp/crow-native-smoke.XXXXXX)
printf 'Native smoke build: %s\n' "$crow_build"
crow_app="$crow_build/Smoke.app/Contents"
mkdir -p "$crow_app/MacOS" "$crow_app/Resources"
swiftc -parse-as-library -target arm64-apple-macos15 -emit-library -emit-module -module-name CrowCore \
  -emit-module-path "$crow_build/CrowCore.swiftmodule" "$crow_root"/Packages/CrowCore/Sources/CrowCore/*.swift \
  -o "$crow_build/libCrowCore.dylib"
swiftc -parse-as-library -target arm64-apple-macos15 -I "$crow_build" -L "$crow_build" -lCrowCore \
  -Xlinker -rpath -Xlinker "$crow_build" \
  "$crow_root/App/Services/WindowDragRegion.swift" "$crow_root/App/Editor/MarkdownEditor.swift" \
  "$crow_root/App/Editor/NativeEditor.swift" "$crow_root/App/Theme/CrowTheme.swift" \
  "$crow_root/App/Services/SystemSFTP.swift" "$crow_root/App/Services/SystemSSH.swift" \
  "$crow_root/Tools/NativeSmoke/Smoke.swift" "$crow_root/Tools/NativeSmoke/SFTPSmoke.swift" -o "$crow_app/MacOS/Smoke"
cp "$crow_root/Tools/NativeSmoke/Info.plist" "$crow_app/Info.plist"
cp "$crow_root/App/Editor/markdown-editor.js" "$crow_app/Resources/markdown-editor.js"
"$crow_app/MacOS/Smoke" "$crow_root"

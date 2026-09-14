#!/bin/zsh
set -euo pipefail
crow_root="${0:A:h:h}"
crow_build=$(mktemp -d /tmp/crow-reverse-smoke-build.XXXXXX)
crow_live_args=()
if [[ "${1:-}" == "--existing-connection" ]]; then
  crow_live_args=("$@")
  set --
fi
if [[ $# -gt 0 ]]; then
  crow_derived="$1"
  crow_products="$crow_derived/Build/Products/Debug"
  crow_modules=()
  for crow_map in "$crow_derived"/Build/Intermediates.noindex/GeneratedModuleMaps/*.modulemap(N) \
                  "$crow_derived"/SourcePackages/checkouts/*/Sources/*/include/module.modulemap(N); do
    crow_modules+=(-Xcc "-fmodule-map-file=$crow_map")
  done
  swiftc -parse-as-library -swift-version 6 -D CROW_APP_TEST -target arm64-apple-macos15 -I "$crow_products" \
    -F "$crow_products" -F "$crow_products/PackageFrameworks" "${crow_modules[@]}" \
    -Xlinker "$crow_products/Crow.app/Contents/MacOS/Crow.debug.dylib" \
    -Xlinker -rpath -Xlinker "$crow_products/Crow.app/Contents/MacOS" \
    -Xlinker -rpath -Xlinker "$crow_products/Crow.app/Contents/Frameworks" \
    "$crow_root/Tools/NativeSmoke/ReverseSSHSmoke.swift" -o "$crow_build/ReverseSSHSmoke"
  "$crow_build/ReverseSSHSmoke"
  exit
fi
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos15 -emit-library -emit-module -module-name CrowCore \
  -emit-module-path "$crow_build/CrowCore.swiftmodule" "$crow_root"/Packages/CrowCore/Sources/CrowCore/*.swift \
  -o "$crow_build/libCrowCore.dylib"
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos15 -I "$crow_build" -L "$crow_build" -lCrowCore \
  -Xlinker -rpath -Xlinker "$crow_build" \
  "$crow_root/App/Services/SystemSSH.swift" "$crow_root/App/Services/SystemSFTP.swift" \
  "$crow_root/App/Services/FileRevision.swift" "$crow_root/App/Terminal/ClipboardImage.swift" \
  "$crow_root/App/Services/ReverseSSH.swift" "$crow_root/Tools/NativeSmoke/ReverseSSHSmoke.swift" \
  -o "$crow_build/ReverseSSHSmoke"
"$crow_build/ReverseSSHSmoke" "${crow_live_args[@]}"

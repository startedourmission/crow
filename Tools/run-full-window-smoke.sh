#!/bin/zsh
set -euo pipefail
crow_root="${0:A:h:h}"
crow_derived="${1:?Pass the existing Crow DerivedData directory after building Crow-macOS}"
crow_products="$crow_derived/Build/Products/Debug"
crow_build=$(mktemp -d /tmp/crow-full-window.XXXXXX)
crow_app="$crow_build/Smoke.app/Contents"
mkdir -p "$crow_app/MacOS" "$crow_app/Resources"
crow_modules=()
for crow_map in "$crow_derived"/Build/Intermediates.noindex/GeneratedModuleMaps/*.modulemap(N) \
                "$crow_derived"/SourcePackages/checkouts/*/Sources/*/include/module.modulemap(N); do
  crow_modules+=(-Xcc "-fmodule-map-file=$crow_map")
done
swiftc -parse-as-library -target arm64-apple-macos15 -I "$crow_products" \
  -F "$crow_products/PackageFrameworks" "${crow_modules[@]}" \
  -Xlinker "$crow_products/Crow.app/Contents/MacOS/Crow.debug.dylib" \
  -Xlinker -rpath -Xlinker "$crow_products/Crow.app/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$crow_products/Crow.app/Contents/Frameworks" \
  "$crow_root/Tools/NativeSmoke/FullWindowSmoke.swift" -o "$crow_app/MacOS/Smoke"
cp "$crow_root/Tools/NativeSmoke/Info.plist" "$crow_app/Info.plist"
cp "$crow_root/App/Editor/markdown-editor.js" "$crow_app/Resources/markdown-editor.js"
"$crow_app/MacOS/Smoke"

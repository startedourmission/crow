#!/bin/bash
# Package only. Never sign, notarize, publish, install, or change the input app.
set -euo pipefail
usage() {
  echo "Usage: bash Tools/package-macos-release.sh --unsigned|--release /path/to/Crow.app /new/output/directory"
  echo "--unsigned: local testing ZIP only, no installable Cask."
  echo "--release: requires Developer ID, hardened runtime, notarization and stapling."
}
if [[ "${1:-}" == --help ]]; then usage; exit 0; fi
[[ $# == 3 ]] || { usage >&2; exit 2; }
crow_mode="$1"
[[ "$crow_mode" == --unsigned || "$crow_mode" == --release ]] || { usage >&2; exit 2; }
crow_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$2" ]] || { echo "Missing input app: $2" >&2; exit 1; }
crow_app="$(cd -P "$2" && pwd)"
[[ "$(basename "$crow_app")" == Crow.app ]] || { echo "Expected Crow.app" >&2; exit 1; }
crow_output="$3"
[[ ! -e "$crow_output" && ! -L "$crow_output" ]] || { echo "Refusing to overwrite existing output: $crow_output" >&2; exit 1; }
crow_output_parent="$(cd -P "$(dirname "$crow_output")" && pwd)" || { echo "Output parent directory must already exist" >&2; exit 1; }
case "$crow_output_parent/" in
  "$crow_app/"*) echo "Output must be outside the input app" >&2; exit 1 ;;
esac
crow_output="$crow_output_parent/$(basename "$crow_output")"
crow_info="$crow_app/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$crow_info"; }
[[ "$(plist CFBundleIdentifier)" == dev.chajinwoo.crow ]] || { echo "Wrong bundle identifier" >&2; exit 1; }
[[ "$(plist CFBundleExecutable)" == Crow ]] || { echo "Wrong executable" >&2; exit 1; }
crow_version="$(plist CFBundleShortVersionString)"
crow_build="$(plist CFBundleVersion)"
[[ "$crow_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$crow_build" =~ ^[0-9]+$ ]] || { echo "Expected x.y.z version and numeric build" >&2; exit 1; }
crow_minimum="$(plist LSMinimumSystemVersion)"
[[ "$crow_minimum" == 15.0 || "$crow_minimum" == 15.0.0 || "$crow_minimum" == 15 ]] || {
  echo "Minimum macOS changed; update the Cask and validation together" >&2; exit 1;
}
[[ "$(lipo -archs "$crow_app/Contents/MacOS/Crow")" == arm64 ]] || { echo "This release pipeline supports arm64 only" >&2; exit 1; }
for crow_resource in Assets.car markdown-editor.js MarkdownEditor-LICENSES.txt ThirdPartyNotices.txt; do
  [[ -s "$crow_app/Contents/Resources/$crow_resource" ]] || { echo "Missing resource: $crow_resource" >&2; exit 1; }
done
[[ ! -e "$crow_app/Contents/MacOS/Crow.debug.dylib" ]] || { echo "Debug app is not a release artifact" >&2; exit 1; }

crow_suffix="-UNSIGNED"
if [[ "$crow_mode" == --release ]]; then
  # Never use ad-hoc/development signing or quarantine removal as distribution shortcuts.
  codesign --verify --deep --strict --verbose=2 "$crow_app"
  crow_signature="$(codesign -dvvv "$crow_app" 2>&1)"
  echo "$crow_signature" | grep -q '^Authority=Developer ID Application:' || { echo "Developer ID Application signature required" >&2; exit 1; }
  echo "$crow_signature" | grep -q 'flags=.*runtime' || { echo "Hardened runtime required" >&2; exit 1; }
  echo "$crow_signature" | grep -q '^Timestamp=' || { echo "Secure signing timestamp required" >&2; exit 1; }
  crow_entitlements="$(codesign -d --entitlements - "$crow_app" 2>/dev/null)"
  if [[ -n "$crow_entitlements" ]]; then
    crow_debug_allowed="$(printf '%s' "$crow_entitlements" | plutil -convert json -o - - | /usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("com.apple.security.get-task-allow", false)')"
    [[ "$crow_debug_allowed" == false ]] || { echo "Debug entitlement is enabled or invalid" >&2; exit 1; }
  fi
  xcrun stapler validate "$crow_app"
  spctl --assess --type execute --verbose=2 "$crow_app"
  crow_suffix=""
fi

mkdir "$crow_output"
crow_output="$(cd "$crow_output" && pwd)"
crow_filename="Crow-$crow_version-arm64$crow_suffix.zip"
ditto -c -k --sequesterRsrc --keepParent "$crow_app" "$crow_output/$crow_filename"
crow_sha="$(shasum -a 256 "$crow_output/$crow_filename" | awk '{print $1}')"
printf '%s  %s\n' "$crow_sha" "$crow_filename" > "$crow_output/SHA256SUMS"
printf '{"version":"%s","build":"%s","architecture":"arm64","minimum_macos":"%s","mode":"%s","file":"%s","sha256":"%s"}\n' \
  "$crow_version" "$crow_build" "$crow_minimum" "${crow_mode#--}" "$crow_filename" "$crow_sha" > "$crow_output/manifest.json"
if [[ "$crow_mode" == --release ]]; then
  sed -e "s/@@VERSION@@/$crow_version/g" -e "s/@@SHA256@@/$crow_sha/g" \
    "$crow_root/Distribution/homebrew/crow.rb.in" > "$crow_output/crow.rb"
  echo "Signed/notarized package and Cask generated. Nothing uploaded or installed."
else
  printf '%s\n' "LOCAL TEST BUILD ONLY — NOT SIGNED WITH DEVELOPER ID OR NOTARIZED." \
    "Do not publish this ZIP as a release. No installable Cask was generated." \
    "After Developer ID export and notarization, run package-macos-release.sh --release on the stapled app." \
    > "$crow_output/DO-NOT-PUBLISH.txt"
  echo "Unsigned local test ZIP created. NOT a public release; no Cask generated."
fi
echo "$crow_output"

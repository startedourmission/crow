#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: SPARKLE_PUBLIC_ED_KEY=... [NOTARY_PROFILE=oh-my-opensnap] $0 <version> [output-directory]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 64
fi

version="${1#v}"
output_directory="${2:-dist}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
archive_path="$project_root/build/Crow.xcarchive"
staging_directory="$project_root/build/release-staging"
dmg_staging_directory="$project_root/build/dmg-staging"
app_path="$staging_directory/Crow.app"
submission_zip="$project_root/build/Crow-${version}-notarization.zip"
artifact_name="Crow-${version}-macOS.zip"
dmg_name="Crow-macOS.dmg"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid version '$version'. Expected a semantic version such as 0.1.0." >&2
  exit 64
fi

for command_name in xcodebuild xcrun ditto codesign spctl shasum hdiutil; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 69
  fi
done

APPLE_TEAM_ID="${APPLE_TEAM_ID:-M7NU9F8CZN}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

for variable_name in APPLE_TEAM_ID SPARKLE_PUBLIC_ED_KEY; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Required environment variable is not set: $variable_name" >&2
    exit 64
  fi
done

if [[ -z "$NOTARY_PROFILE" ]]; then
  for variable_name in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
    if [[ -z "${!variable_name:-}" ]]; then
      echo "Set NOTARY_PROFILE, or provide $variable_name for API-key notarization." >&2
      exit 64
    fi
  done
  if [[ ! -f "$NOTARY_KEY_PATH" ]]; then
    echo "Notary API key not found: $NOTARY_KEY_PATH" >&2
    exit 66
  fi
fi

submit_for_notarization() {
  local artifact="$1"
  local result_file="$project_root/build/notarization-$(basename "$artifact").json"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --timeout 30m \
      --output-format json > "$result_file"
  else
    xcrun notarytool submit "$artifact" \
      --key "$NOTARY_KEY_PATH" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      --wait \
      --timeout 30m \
      --output-format json > "$result_file"
  fi
  python3 - "$result_file" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get("status") != "Accepted" or not result.get("id"):
    raise SystemExit(
        f"Notarization failed: {result.get('status', 'unknown')} "
        f"(submission {result.get('id', 'unknown')})"
    )
print(f"Notarization accepted: {result['id']}")
PY
}

mkdir -p "$project_root/build" "$output_directory"
rm -rf "$archive_path" "$staging_directory" "$dmg_staging_directory"
rm -f \
  "$submission_zip" \
  "$output_directory/$artifact_name" \
  "$output_directory/$artifact_name.sha256" \
  "$output_directory/$dmg_name" \
  "$output_directory/$dmg_name.sha256"

build_number="${BUILD_NUMBER:-1}"

echo "Archiving Crow $version ($build_number) for arm64 and x86_64..."
xcodebuild archive \
  -project "$project_root/Crow.xcodeproj" \
  -scheme Crow-macOS \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -clonedSourcePackagesDirPath "$project_root/build/SourcePackages" \
  -skipPackagePluginValidation \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_IDENTITY='Developer ID Application' \
  OTHER_CODE_SIGN_FLAGS='--timestamp' \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"

archived_app="$archive_path/Products/Applications/Crow.app"
if [[ ! -d "$archived_app" ]]; then
  echo "Archive did not contain Crow.app at the expected path." >&2
  exit 66
fi

embedded_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$archived_app/Contents/Info.plist")"
if [[ "$embedded_public_key" != "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "The archived app does not contain the configured Sparkle public key." >&2
  exit 65
fi
if [[ ! -d "$archived_app/Contents/Frameworks/Sparkle.framework" ]]; then
  echo "The archived app does not contain Sparkle.framework." >&2
  exit 66
fi

mkdir -p "$staging_directory"
ditto "$archived_app" "$app_path"

echo "Re-signing Sparkle components from the inside out..."
sign_identity="${SIGN_IDENTITY:-Developer ID Application}"
sign=(codesign --force --options runtime --timestamp --sign "$sign_identity")
sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
sparkle_version="$(readlink "$sparkle_framework/Versions/Current")"
sparkle_contents="$sparkle_framework/Versions/$sparkle_version"
for nested_code in \
  "$sparkle_contents/XPCServices/Downloader.xpc" \
  "$sparkle_contents/XPCServices/Installer.xpc" \
  "$sparkle_contents/Autoupdate" \
  "$sparkle_contents/Updater.app"; do
  if [[ -e "$nested_code" ]]; then
    "${sign[@]}" "$nested_code"
  fi
done
"${sign[@]}" "$sparkle_framework"
if [[ -f "$app_path/Contents/Frameworks/libswiftCompatibilitySpan.dylib" ]]; then
  "${sign[@]}" "$app_path/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
fi
"${sign[@]}" \
  --entitlements "$project_root/App/Crow-macOS.entitlements" \
  "$app_path"

echo "Verifying the Developer ID signature..."
codesign --verify --deep --strict --verbose=2 "$app_path"
architectures="$(lipo -archs "$app_path/Contents/MacOS/Crow")"
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
  echo "Crow is not universal. Found architectures: $architectures" >&2
  exit 65
fi

ditto -c -k --keepParent "$app_path" "$submission_zip"

echo "Submitting Crow to Apple's notary service..."
submit_for_notarization "$submission_zip"

echo "Stapling and validating the notarization ticket..."
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

ditto -c -k --keepParent "$app_path" "$output_directory/$artifact_name"

echo "Creating, signing, and notarizing the DMG..."
mkdir -p "$dmg_staging_directory"
ditto "$app_path" "$dmg_staging_directory/Crow.app"
ln -s /Applications "$dmg_staging_directory/Applications"
hdiutil create \
  -volname Crow \
  -srcfolder "$dmg_staging_directory" \
  -ov \
  -format UDZO \
  "$output_directory/$dmg_name"
codesign \
  --force \
  --sign 'Developer ID Application' \
  --timestamp \
  "$output_directory/$dmg_name"
submit_for_notarization "$output_directory/$dmg_name"
xcrun stapler staple "$output_directory/$dmg_name"
xcrun stapler validate "$output_directory/$dmg_name"
codesign --verify --verbose=2 "$output_directory/$dmg_name"
spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=2 \
  "$output_directory/$dmg_name"

(
  cd "$output_directory"
  shasum -a 256 "$artifact_name" > "$artifact_name.sha256"
  shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
)

echo "Created $output_directory/$artifact_name"
echo "Created $output_directory/$artifact_name.sha256"
echo "Created $output_directory/$dmg_name"
echo "Created $output_directory/$dmg_name.sha256"

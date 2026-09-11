#!/bin/bash
# Build an isolated, unsigned Release archive; never touch Xcode's active build/app.
set -euo pipefail
if [[ "${1:-}" == --help ]]; then
  echo "Usage: bash Tools/prepare-macos-release.sh VERSION BUILD_NUMBER"
  echo "Example: bash Tools/prepare-macos-release.sh 0.1.0 1"
  echo "Optional CROW_SOURCE_PACKAGES_DIR reuses an existing Xcode SourcePackages directory."
  exit 0
fi
[[ $# == 2 && "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || {
  echo "Provide x.y.z version and numeric build number (see --help)." >&2; exit 2;
}
crow_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$crow_root/build"
crow_work="$(mktemp -d "$crow_root/build/release-$1-arm64.XXXXXX")"
echo "Release staging: $crow_work"
crow_packages="${CROW_SOURCE_PACKAGES_DIR:-$crow_work/DerivedData/SourcePackages}"
crow_package_options=()
if [[ -n "${CROW_SOURCE_PACKAGES_DIR:-}" ]]; then
  [[ -d "$crow_packages/checkouts" ]] || { echo "Missing SourcePackages/checkouts" >&2; exit 1; }
  crow_package_options=(-clonedSourcePackagesDirPath "$crow_packages")
fi
xcodebuild archive -quiet -project "$crow_root/Crow.xcodeproj" -scheme Crow-macOS \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$crow_work/DerivedData" -archivePath "$crow_work/Crow.xcarchive" \
  -onlyUsePackageVersionsFromResolvedFile "${crow_package_options[@]}" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ENABLE_DEBUG_DYLIB=NO MARKETING_VERSION="$1" CURRENT_PROJECT_VERSION="$2" \
  2>&1 | tee "$crow_work/build.log"
crow_app="$crow_work/Crow.xcarchive/Products/Applications/Crow.app"
# Include all checked-out Swift package license/notice files before future signing.
# EditorWeb's generated notices are already a bundled app resource.
crow_notices="$crow_app/Contents/Resources/ThirdPartyNotices.txt"
printf 'Crow — Swift package third-party notices\n' > "$crow_notices"
crow_notice_count=0
for crow_checkout in "$crow_packages"/checkouts/*; do
  [[ -d "$crow_checkout" ]] || continue
  # Include nested vendored-library notices too (e.g. BoringSSL), not just roots.
  while IFS= read -r -d '' crow_license; do
    printf '\n\n----- %s / %s -----\n\n' "$(basename "$crow_checkout")" "${crow_license#"$crow_checkout"/}" >> "$crow_notices"
    cat "$crow_license" >> "$crow_notices"
    crow_notice_count=$((crow_notice_count + 1))
  done < <(find "$crow_checkout" -type d -name .git -prune -o -type f \
    \( -iname 'license*' -o -iname 'licence*' -o -iname 'copying*' -o -iname 'notice*' \) -print0)
done
[[ "$crow_notice_count" -gt 0 ]] || { echo "No dependency notices found; refusing to package" >&2; exit 1; }
cp "$crow_root/Crow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$crow_work/Package.resolved"
git -C "$crow_root" rev-parse HEAD > "$crow_work/source-commit.txt"
git -C "$crow_root" status --porcelain > "$crow_work/source-worktree.txt"
bash "$crow_root/Tools/package-macos-release.sh" --unsigned "$crow_app" "$crow_work/package"
echo "Archive retained for inspection: $crow_work/Crow.xcarchive"

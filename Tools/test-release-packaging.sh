#!/bin/bash
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: bash Tools/test-release-packaging.sh /path/to/unsigned/Crow.app" >&2; exit 2; }
crow_root="$(cd "$(dirname "$0")/.." && pwd)"
crow_app="$(cd "$1" && pwd)"
crow_test="$(mktemp -d /tmp/crow-release-packaging.XXXXXX)"
echo "Packaging test artifacts: $crow_test"
bash "$crow_root/Tools/package-macos-release.sh" --unsigned "$crow_app" "$crow_test/unsigned"
[[ -s "$crow_test/unsigned/DO-NOT-PUBLISH.txt" && ! -e "$crow_test/unsigned/crow.rb" ]]
(cd "$crow_test/unsigned" && shasum -a 256 -c SHA256SUMS)
crow_zip=("$crow_test/unsigned/"*-UNSIGNED.zip)
[[ ${#crow_zip[@]} == 1 ]]
ditto -x -k "${crow_zip[0]}" "$crow_test/extracted"
cmp "$crow_app/Contents/MacOS/Crow" "$crow_test/extracted/Crow.app/Contents/MacOS/Crow"
cmp "$crow_app/Contents/Info.plist" "$crow_test/extracted/Crow.app/Contents/Info.plist"
for crow_resource in Assets.car markdown-editor.js MarkdownEditor-LICENSES.txt ThirdPartyNotices.txt; do
  cmp "$crow_app/Contents/Resources/$crow_resource" "$crow_test/extracted/Crow.app/Contents/Resources/$crow_resource"
done
[[ -x "$crow_test/extracted/Crow.app/Contents/MacOS/Crow" ]]
/usr/bin/ruby -rjson -rdigest -e 'm = JSON.parse(File.read(ARGV[0])); abort unless m["mode"] == "unsigned" && m["architecture"] == "arm64" && m["file"] == File.basename(ARGV[1]) && m["sha256"] == Digest::SHA256.file(ARGV[1]).hexdigest' "$crow_test/unsigned/manifest.json" "${crow_zip[0]}"
if bash "$crow_root/Tools/package-macos-release.sh" --unsigned "$crow_app" "$crow_test/unsigned" > "$crow_test/overwrite.log" 2>&1; then
  echo "FAIL existing output was overwritten" >&2; exit 1
fi
grep -q 'Refusing to overwrite' "$crow_test/overwrite.log"
if bash "$crow_root/Tools/package-macos-release.sh" --release "$crow_app" "$crow_test/release" > "$crow_test/release.log" 2>&1; then
  echo "FAIL unsigned app accepted as a public release" >&2; exit 1
fi
[[ ! -e "$crow_test/release" ]]
if bash "$crow_root/Tools/package-macos-release.sh" --invalid "$crow_app" "$crow_test/invalid" > "$crow_test/invalid.log" 2>&1; then
  echo "FAIL invalid mode accepted" >&2; exit 1
fi
[[ ! -e "$crow_test/invalid" ]]
if bash "$crow_root/Tools/package-macos-release.sh" --unsigned "$crow_app" "$crow_app/packaging-test-forbidden" > "$crow_test/inside-app.log" 2>&1; then
  echo "FAIL output inside source app was accepted" >&2; exit 1
fi
[[ ! -e "$crow_app/packaging-test-forbidden" ]]
grep -q 'Output must be outside' "$crow_test/inside-app.log"
# Exercise template substitutions without treating the result as a release artifact.
sed -e 's/@@VERSION@@/0.1.0/g' -e 's/@@SHA256@@/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/g' \
  "$crow_root/Distribution/homebrew/crow.rb.in" > "$crow_test/crow.rb.syntax-only"
/usr/bin/ruby -c "$crow_test/crow.rb.syntax-only"
echo "PASS ZIP round trip, executable permissions, resources, manifest, SHA-256, overwrite guard, unsigned-release refusal, Cask syntax"
echo "No installation, app launch, notarization submission, or publication performed."

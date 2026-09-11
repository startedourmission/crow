#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <version> <sha256> <output-file>" >&2
  exit 64
fi

version="${1#v}"
sha256="$2"
output_file="$3"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
template="$project_root/packaging/homebrew/crow.rb.template"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid version: $version" >&2
  exit 64
fi

if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid SHA-256: $sha256" >&2
  exit 64
fi

mkdir -p "$(dirname "$output_file")"
sed \
  -e "s/__VERSION__/$version/g" \
  -e "s/__SHA256__/$sha256/g" \
  "$template" > "$output_file"

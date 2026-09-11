# Releasing Crow for macOS

Crow's release workflow produces a universal, Developer ID-signed app, notarizes
and staples both the app and DMG, publishes ZIP and DMG artifacts on GitHub,
and updates the Homebrew cask and Sparkle appcast.

## One-time setup

1. Create a public GitHub repository named
   `startedourmission/homebrew-tap`. Homebrew requires this naming convention for
   the short tap name `startedourmission/tap`.
2. Export the **Developer ID Application** certificate and private key from
   Keychain Access as a password-protected `.p12` file.
3. Create a team App Store Connect API key with access to the notary service and
   download its `.p8` private key. Record the key ID and issuer ID.
4. Create a fine-grained GitHub personal access token that can write repository
   contents in `startedourmission/homebrew-tap`.
5. Download the Sparkle 2 tools and generate the update-signing key once. Keep
   the exported private key in a password manager; losing it prevents installed
   copies from trusting future updates.

   ```sh
   ./bin/generate_keys --account startedourmission-crow
   ./bin/generate_keys --account startedourmission-crow -x sparkle-private-key
   ```

   The first command prints the public key. The second exports the private key.
6. Add these GitHub Actions secrets to the `crow` repository:

   | Secret | Value |
   | --- | --- |
   | `APPLE_TEAM_ID` | 10-character Apple Developer team ID |
   | `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded `.p12` file |
   | `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
   | `KEYCHAIN_PASSWORD` | A new random password used only for the CI keychain |
   | `NOTARY_KEY_BASE64` | Base64-encoded App Store Connect `.p8` file |
   | `NOTARY_KEY_ID` | App Store Connect API key ID |
   | `NOTARY_ISSUER_ID` | App Store Connect API issuer ID |
   | `SPARKLE_PUBLIC_ED_KEY` | Public EdDSA key printed by `generate_keys` |
   | `SPARKLE_PRIVATE_KEY_BASE64` | Base64-encoded exported Sparkle private key file |
   | `HOMEBREW_TAP_TOKEN` | Fine-grained token for the tap repository |

   Encode each binary/key file on macOS with:

   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   base64 -i sparkle-private-key | pbcopy
   ```

Both `crow` and `homebrew-tap` must be public so Homebrew and Sparkle can download
release assets and the appcast without GitHub credentials.

## Publish a release

Update `MARKETING_VERSION` in `project.yml`, regenerate the Xcode project, commit
the change, and run the tests. Then create and push the matching tag:

```sh
xcodegen generate
git add project.yml Crow.xcodeproj
git commit -m "Prepare Crow 0.1.0"
git tag -s v0.1.0 -m "Crow 0.1.0"
git push origin main v0.1.0
```

The `v0.1.0` tag becomes version `0.1.0` in the app and cask. The workflow also
signs the release with Sparkle's EdDSA key and updates the signed `appcast.xml` in
the tap repository. Installed copies check that feed automatically and expose
**Crow → Check for Updates…**. The workflow refuses non-semantic release tags. Do
not move a published release tag; publish a new patch version instead.

After the workflow completes, install or upgrade Crow with:

```sh
brew install --cask startedourmission/tap/crow
brew upgrade --cask --greedy crow
```

To inspect the downloaded app independently:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/Crow.app
spctl --assess --type execute --verbose=2 /Applications/Crow.app
xcrun stapler validate /Applications/Crow.app
```

## Local packaging

`scripts/release-macos.sh` runs the same archive, notarization, stapling, and
packaging process outside CI. It expects the signing certificate to already be in
the active keychain and the five documented environment variables to be set:

```sh
APPLE_TEAM_ID=XXXXXXXXXX \
NOTARY_KEY_PATH="$PWD/AuthKey_XXXXXXXXXX.p8" \
NOTARY_KEY_ID=XXXXXXXXXX \
NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
SPARKLE_PUBLIC_ED_KEY=base64-public-key \
scripts/release-macos.sh 0.1.0 dist
```

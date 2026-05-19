# Release Checklist

Use this checklist before publishing a public Hermes Desktop - OS1 Edition
release.

Public release is blocked until the app is signed with a Developer ID
Application certificate and notarization succeeds. A local ad-hoc archive
from `./scripts/package-github-release.sh` is useful for smoke testing, but
is not a public release artifact.

1. Run `scripts/os1-dev.sh test`.
2. Run a full redacted secret scan across the working tree, branches, and tags.
3. Confirm `README.md`, `SECURITY.md`, and `THIRD_PARTY_NOTICES.md` match the
   release behavior.
4. Build the local ad-hoc app/archive with `./scripts/package-github-release.sh`.
5. Verify the archive checksum in `dist/OS1.app.zip.sha256`.
6. Sign and notarize the app for public distribution when a Developer ID
   certificate is available:

   ```sh
   OS1_CODESIGN_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
   OS1_NOTARIZE=1 \
   OS1_NOTARY_KEYCHAIN_PROFILE=os1-notary \
   ./scripts/package-github-release.sh
   ```

   Notarization can also use App Store Connect API key credentials:

   ```sh
   OS1_CODESIGN_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
   OS1_NOTARIZE=1 \
   OS1_NOTARY_KEY=/path/to/AuthKey_KEYID.p8 \
   OS1_NOTARY_KEY_ID=KEYID \
   OS1_NOTARY_ISSUER=ISSUER-UUID \
   ./scripts/package-github-release.sh
   ```

   The script submits the zip, staples the ticket to `dist/OS1.app`, validates
   the staple, then recreates the final zip and checksum.
7. Create a signed Git tag.
8. Attach the notarized `OS1.app.zip` and checksum to the GitHub release.

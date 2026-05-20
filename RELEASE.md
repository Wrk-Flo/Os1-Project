# Release Checklist

Use this checklist before publishing a Hermes Desktop - OS1 Edition release.

## Distribution modes

OS1 ships in one of two modes. The default is **ad-hoc**.

### Ad-hoc (default; free; no Apple Developer membership required)
- Verifier: `scripts/release-archive-verify.sh --mode adhoc` (or set
  `OS1_RELEASE_MODE=adhoc`, which is also the default). Apple-credential
  checks are downgraded to WARN; gate exits 0.
- End users: on first launch, macOS Gatekeeper will block the app. The user
  must either right-click the app → **Open** the first time, or run:

  ```sh
  xattr -dr com.apple.quarantine /Applications/OS1.app
  ```

  to clear the quarantine attribute and let it launch normally. Document this
  in your install instructions for recipients.
- No auto-update via Apple-trusted distribution. Direct download/share only.

### Public (Developer ID, requires paid Apple Developer Program)
- Verifier: `scripts/release-archive-verify.sh --mode developer-id` and
  readiness gate run with `--public`. Both turn the Apple-cert checks into
  hard FAILs unless properly signed, hardened, notarized, and stapled.
- Requires a Developer ID Application certificate, hardened runtime, secure
  Apple TSA timestamp, and a stapled notarization ticket. See
  `docs/apple-credentials-setup.md` for the operator runbook.

1. Run `scripts/os1-dev.sh test`.
2. Run `scripts/os1-production-readiness.sh --local` for the current local
   operating state, including the quick local business smoke.
3. Optional: run `scripts/os1-business-smoke.sh` for the full local model
   business suite.
4. Run a full redacted secret scan across the working tree, branches, and tags.
5. Confirm `README.md`, `SECURITY.md`, and `THIRD_PARTY_NOTICES.md` match the
   release behavior.
6. Build the local ad-hoc app/archive with `./scripts/package-github-release.sh`.
7. Verify the archive checksum: `(cd dist && shasum -a 256 -c OS1.app.zip.sha256)`.
   The checksum file records the bare `OS1.app.zip` name so the same command
   works for end users who download both files into one directory.
8. Run `scripts/os1-production-readiness.sh --public`. It is expected to fail
   until Developer ID signing, notarization credentials, and a stapled public
   archive are available.
9. Sign and notarize the app for public distribution when a Developer ID
   certificate is available:

   ```sh
   OS1_CODESIGN_IDENTITY="Developer ID Application: Example Team (TEAMID)" \
   OS1_NOTARIZE=1 \
   OS1_NOTARY_PROFILE=os1-notary \
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
10. Create a signed Git tag.
11. Attach the notarized `OS1.app.zip` and checksum to the GitHub release.
12. Follow `docs/public-install-update-rollback.md` for the interim manual
    install, update, and rollback procedure until a signed installer/update
    channel exists.

## End-user installation (ad-hoc build)

The current distribution is intentionally ad-hoc signed (not Developer ID /
notarized). macOS Gatekeeper will block it on first launch with a "cannot be
opened because the developer cannot be verified" or "app is damaged" message.
This is expected. End users have two ways to run it:

Optionally verify the download first — place `OS1.app.zip` and
`OS1.app.zip.sha256` in the same directory and run
`shasum -a 256 -c OS1.app.zip.sha256` (expect `OS1.app.zip: OK`).

- **Right-click → Open**: in Finder, right-click (or Control-click) `OS1.app`,
  choose **Open**, then confirm **Open** in the dialog. macOS remembers the
  choice for subsequent launches.
- **Clear the quarantine attribute** (use when the app was downloaded as a zip
  and the right-click path still refuses):

  ```sh
  xattr -dr com.apple.quarantine /Applications/OS1.app
  ```

  Adjust the path to wherever `OS1.app` was placed. Re-run this command after
  every update, since a freshly downloaded zip re-applies the quarantine flag.

These steps are unnecessary once a Developer ID + notarized build is published
(steps 9–11 above).

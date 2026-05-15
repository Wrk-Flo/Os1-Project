# Release Checklist

Use this checklist before publishing a public Hermes Desktop - OS1 Edition
release.

1. Run `swift test`.
2. Run a full secret scan across all branches and tags.
3. Confirm `README.md`, `SECURITY.md`, and `THIRD_PARTY_NOTICES.md` match the
   release behavior.
4. Build the app with `./scripts/package-github-release.sh`.
5. Verify the archive checksum in `dist/OS1.app.zip.sha256`.
6. Sign and notarize the app for public distribution when a Developer ID
   certificate is available.
7. Create a signed Git tag.
8. Attach `OS1.app.zip` and checksum to the GitHub release.

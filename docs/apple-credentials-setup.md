# Apple Credentials Setup — OS1 Signing & Notarization Runbook

> **Status: optional, indefinitely deferred.** Ad-hoc distribution is the
> permanent OS1 release mode (`OS1_RELEASE_MODE=adhoc` is the default; see
> `RELEASE.md` end-user install). The Developer-ID + notarization path below is
> documented but not on the active release path and is not required for a
> release-ready build. Only follow this runbook if a paid Apple Developer
> Program membership is later acquired and `--public` distribution is
> explicitly chosen.

This is the operator runbook for everything an OS1 release engineer needs
**before** running `scripts/sign-os1-app.sh` and `scripts/notarize-os1-app.sh`.

If you can already run `scripts/release-archive-verify.sh` end-to-end and see
`RESULT: release-ready`, the credentials are set up correctly and you can skip
this doc until something breaks.

---

## 1. What you must obtain

| Item | Purpose | Cost |
|------|---------|------|
| Apple Developer Program membership | Eligibility to request Developer ID certs and notarize. | $99 / year |
| **Developer ID Application** certificate | Signs the `OS1.app` bundle for distribution outside the Mac App Store. | Included |
| App-specific password **OR** App Store Connect API key | Authenticates `xcrun notarytool` submissions. | Included |
| The team ID (e.g. `ABCDE12345`) | Required for `notarytool store-credentials`. | Free, in your Apple Developer account |

> The Apple Developer Program membership must be active. Expired memberships
> will keep existing notarized builds valid (Apple does not revoke past tickets)
> but will block *new* signing and notarization.

---

## 2. Create the Developer ID Application certificate

Pick one of the two paths.

### 2a. Via Xcode (easiest)

1. Open Xcode → Settings → Accounts.
2. Add your Apple ID, then select your team.
3. Click **Manage Certificates…** → **+** → **Developer ID Application**.
4. Xcode generates the keypair and installs the certificate into your **login**
   keychain. The private key stays in the keychain — it is never re-downloadable.

### 2b. Via developer.apple.com (manual CSR)

1. In **Keychain Access** → Certificate Assistant → Request a Certificate from a
   Certificate Authority. Save the `.certSigningRequest` to disk.
2. https://developer.apple.com/account/resources/certificates/add → choose
   **Developer ID Application** → upload the CSR → download the `.cer`.
3. Double-click the `.cer` to install it. The private key from step 1 is already
   in your keychain; macOS pairs them automatically.

### Confirm install

```bash
security find-identity -v -p codesigning
```

You should see one line that looks like:

```
1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "Developer ID Application: Jane Doe (ABCDE12345)"
```

Copy the quoted string — that's `OS1_SIGNING_IDENTITY`.

---

## 3. Create an app-specific password for notarytool

1. Go to https://appleid.apple.com/account/manage → **Sign-In and Security** →
   **App-Specific Passwords** → **Generate Password**.
2. Label it something like `OS1 notarytool`.
3. Copy the 19-character password (`xxxx-xxxx-xxxx-xxxx`). You cannot view it
   again later.

> Alternative: an App Store Connect API key (.p8 file + key ID + issuer ID).
> `notarytool store-credentials` supports either; this runbook uses the password
> path because it's simpler for a single-developer setup.

---

## 4. Register the notarytool keychain profile

One-time, on the machine that will run notarization:

```bash
xcrun notarytool store-credentials OS1_NOTARY \
  --apple-id "you@example.com" \
  --team-id  "ABCDE12345" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

This stores the credentials in your login keychain under the name `OS1_NOTARY`
(the default our scripts expect). Verify:

```bash
xcrun notarytool history --keychain-profile OS1_NOTARY
```

If the profile name doesn't match `OS1_NOTARY`, export
`OS1_NOTARY_PROFILE=<your-name>` before running the notarize script.

---

## 5. Environment variables each script reads

| Script | Env | Required | Default |
|--------|-----|----------|---------|
| `scripts/sign-os1-app.sh` | `OS1_SIGNING_IDENTITY` | yes | _none_ — fails clearly |
| `scripts/notarize-os1-app.sh` | `OS1_NOTARY_PROFILE` | no | `OS1_NOTARY` |
| `scripts/release-archive-verify.sh` | _none_ | — | — |

Typical shell setup (`~/.zshrc` or a private `.env` you `source`):

```bash
export OS1_SIGNING_IDENTITY="Developer ID Application: Jane Doe (ABCDE12345)"
export OS1_NOTARY_PROFILE="OS1_NOTARY"
```

---

## 6. Canonical release sequence

```bash
# 1. Build the .app
scripts/build-macos-app.sh

# 2. Sign with hardened runtime + entitlements + secure timestamp
scripts/sign-os1-app.sh                            # uses dist/OS1.app

# 3. Submit to Apple notary, wait, staple the ticket, re-zip
scripts/notarize-os1-app.sh                        # uses dist/OS1.app

# 4. Package for GitHub Release (zip + sha256)
scripts/package-github-release.sh

# 5. Final gate — exits non-zero if anything is off
scripts/release-archive-verify.sh
```

Each step is independently re-runnable. If `release-archive-verify.sh` fails,
fix the specific check it complains about and re-run from that step.

---

## 7. Troubleshooting

### "The executable does not have the hardened runtime enabled" (notarization rejection)

The bundle was signed without `--options runtime`. Re-sign:

```bash
scripts/sign-os1-app.sh
```

The script always passes `--options runtime`. If you're hitting this anyway,
some nested framework was added after signing — re-sign from scratch.

### `errSecInternalComponent` from codesign

Your signing identity's private key is locked or unavailable. Unlock the login
keychain:

```bash
security unlock-keychain login.keychain-db
```

If running in CI, the keychain must be unlocked for the duration of the run.

### `Could not find the certificate "Developer ID Application: ..." in the keychain`

The identity string in `OS1_SIGNING_IDENTITY` doesn't match what's installed.
Run `security find-identity -v -p codesigning` and copy the string verbatim
(including the team-id parenthetical).

### Notarization rejected — reading the log

`scripts/notarize-os1-app.sh` automatically prints the notary log on failure.
Look for entries under `issues[]`. Common ones:

- `The signature does not include a secure timestamp` → re-sign while network
  access to Apple's timestamp server is available.
- `The binary is not signed with a valid Developer ID certificate` → wrong
  identity (e.g. you used a "Mac Developer" cert instead of Developer ID).
- `The executable requests the entitlement com.apple.security.cs.disable-library-validation` →
  remove the entitlement from `packaging/OS1.entitlements` unless you have an
  approved exception.

### Expired Developer ID Application certificate

Generate a new cert (steps in §2). **Existing notarized builds remain valid** —
Apple does not revoke notarization tickets when the signing cert expires. You
only need a new cert for *future* builds.

### `stapler staple` fails immediately after a successful notarization

Wait 60 seconds and retry — there's a propagation delay between notary
acceptance and the staple being fetchable from CloudKit. If it still fails,
check `xcrun stapler staple -v dist/OS1.app` for the underlying CloudKit error.

### `spctl: rejected` even though signing and notarization both succeeded

The `--type install` form (used by `release-archive-verify.sh`) is strictest.
Re-run the verifier; if it still rejects, the ticket may not be stapled. Run
`xcrun stapler validate dist/OS1.app` to confirm.

---

## 8. Where credentials live

- **Signing identity + private key**: macOS login keychain (`login.keychain-db`),
  managed by Keychain Access. The private key is non-exportable on default
  install; back it up by exporting a `.p12` (Keychain Access → right-click cert
  → Export). Store the `.p12` in a password manager, not in the repo.
- **Notarytool credentials**: macOS login keychain under generic password item
  `com.apple.gke.notary.tool` keyed by profile name (`OS1_NOTARY`).
- **App-specific password**: only inside the keychain after step 4. The raw
  string is not retrievable from Apple again — re-generate if lost.

Nothing in this list belongs in the repo. The scripts read from the keychain at
runtime; only the identity *string* is ever exported as an env var, and that
string itself contains no secret material.

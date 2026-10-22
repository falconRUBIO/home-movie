# Build and upload HOME MOVIE CLIPS through GitHub

App Store Connect name: **HOME MOVIE CLIPS**. Registered bundle identifier: `com.falconcraft.homemovie`.

## Signing setup

In App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys, create an **Admin** team API key. Distribution certificate creation requires Account Holder/Admin access; an App Manager key is insufficient for this workflow's automatic signing. Download the private `.p8` file.

In GitHub → this repository → Settings → Secrets and variables → Actions, save:

| Secret | Value |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | Admin key's Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Team's Issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Entire Admin `.p8` text, including BEGIN/END lines |
| `CERTIFICATE_PRIVATE_KEY` | Persistent RSA private key for the Apple distribution certificate |

The API private key and certificate private key serve different purposes. Never commit either one. To generate the certificate key on a Mac without Xcode, open Terminal and run:

```sh
openssl genrsa 2048 2>/dev/null | pbcopy
```

Paste the clipboard directly into the `CERTIFICATE_PRIVATE_KEY` GitHub secret and save. Keep that secret across builds so the workflow reuses its distribution certificate instead of creating a new certificate on each run. If replacing an App Manager API key, edit the Key ID and private-key secrets to match the Admin key; the team's Issuer ID stays the same.

## Start the upload

1. Open [Upload TestFlight or App Store candidate](https://github.com/falconRUBIO/home-movie/actions/workflows/testflight.yml).
2. Click **Run workflow**, select **main**, and keep **distribution: app-store-candidate** for an App Store submission build. Choose **internal** only for a beta that must never be submitted to the App Store. Click **Run workflow**.
3. The workflow checks all four secrets, runs all simulator tests, installs pinned standalone signing tools, creates/fetches the matching Apple distribution certificate and App Store provisioning profile, builds the signed IPA, runs the local archive checks, and uploads to Apple. Apple's upload service validates the package. It uses GitHub's Mac runner; no Codemagic account or queue is involved. Apple agreements and API access must be active. It fails rather than revoking existing certificates if Apple's certificate quota blocks creation.
4. After Apple processing, open App Store Connect → **HOME MOVIE CLIPS** → **TestFlight**. Answer any compliance questions accurately. Create an internal group, add your own eligible App Store Connect user, and assign the build.
5. Install Apple's **TestFlight** app on your iPhone, accept the invitation, and install the beta.
6. Run the physical-device scenarios in `DEVICE_TESTS.md`. Simulator tests do not establish camera, microphone, lens, interruption, or real-device performance behavior.

This workflow is manual and restricted to `main`. It rechecks tests on the exact revision being uploaded. It defaults to an App Store-capable candidate; the optional internal choice creates an internal-only archive. Neither choice submits external beta review or a public App Store release. API credentials are supplied only to the signing step, and no private-key or certificate files are uploaded as artifacts. Build logs and zipped test results are retained for 14 days.

Build numbers use `1000 + 10 × workflow run number + attempt`, allowing a rerun to use a fresh number. If other upload systems later use larger build numbers, adjust this offset before uploading.

## Upload validation behavior

The publish command uses Codemagic's default upload path. The optional separate `--enable-package-validation` preflight is omitted: with the installed CLI, Apple's validation output can report an earlier transient ERROR and then VERIFY SUCCEEDED, while the wrapper still aborts before upload. Local archive checks and Apple's actual upload validation remain enabled. Authentication and timeout retries use the CLI's supported bounded retry options; persistent service errors still fail the job.

An archived or exported IPA is not proof of a successful upload. Look for upload success and confirm the build appears in App Store Connect after processing. A failed run should not be treated as a submitted app.

## References

- [Apple certificates overview](https://developer.apple.com/help/account/certificates/certificates-overview)
- [GitHub signing on hosted Macs](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Standalone signing CLI documentation](https://github.com/codemagic-ci-cd/cli-tools/tree/master/docs)
- [Apple uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)

# First internal TestFlight beta

This is a cloud-build template, not a completed upload. It uses Apple's build tools on a Codemagic Mac, so you do not need Xcode installed locally. Source parsing here does not establish that Swift compiles. Resolve any first-build diagnostics before inviting testers.

1. Create a private GitHub repository. Upload the **contents of the HomeMovie folder**, with `codemagic.yaml`, `scripts`, and `HomeMovie.xcodeproj` at the repository root. No ZIP or extra parent directory.
2. In your Apple Developer account, register a unique explicit bundle identifier, for example `com.yourcompany.HomeMovie`. Create its iOS app record in App Store Connect using the same identifier. Home Movie is a working name; choose an available store name.
3. Connect that repository to Codemagic. Use its YAML configuration and run **validate-ios** first. The workflow requires a current Xcode 26+ image and an available iPhone simulator. Save complete build diagnostics if it fails.
4. Set up Codemagic's App Store Connect integration named **home-movie**. Supply the issuer ID, key ID, and private API key in its secure dashboard. Use the access role and signing setup specified in the current Codemagic guide. Signing certificates and provisioning profiles must be available through that integration. Never commit keys or certificates to the repository.
5. Replace `com.example.HomeMovie` in **both** `BUNDLE_ID` and `ios_signing.bundle_identifier` in `codemagic.yaml`. The generator applies the identifier to the app and test target. The custom backup document type is independent of app signing.
6. Run **testflight-internal**. It runs tests before building a signed IPA and uploading it. The build number is Codemagic's build counter plus one; use `BUILD_NUMBER_OFFSET` if this app already has larger uploaded build numbers. Keep uploaded build numbers increasing.
7. After processing, open App Store Connect → your app → TestFlight. Complete any export-compliance prompts accurately. Create an internal testing group, add your own eligible App Store Connect user, and assign the build. Install Apple's TestFlight app on your iPhone and accept the invitation.
8. Run the first acceptance gate in `DEVICE_TESTS.md`, then the safety scenarios. Use expendable recordings until backup, restore, interruptions, and export have been verified on your phone.

`submit_to_testflight: false` still permits the publishing step to upload the IPA; it avoids automatic submission for **external beta review**. `testFlightInternalTestingOnly` restricts the archive to internal testers. It cannot be used for external testing or an App Store release. Build a separate archive without that restriction when ready for those stages. This workflow does not submit an App Store release.

## Login and beta feedback

The app has no account system or analytics SDK. Recording, editing, local recovery, and Files backup work without login. Sign in with Apple does not itself store or synchronize movies. TestFlight feedback is the starting point for beta feedback. Later usage metrics should minimize identifiers and avoid footage, movie names, or Photos identifiers; review privacy disclosures before implementing collection. Add accounts only when a useful account-based feature needs them.

## References

- [Codemagic native iOS setup and signing](https://docs.codemagic.io/yaml-quick-start/building-a-native-ios-app/)
- [Codemagic App Store Connect publishing](https://docs.codemagic.io/yaml-publishing/app-store-connect/)
- [Apple uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple App Review Guidelines, account sign-in](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage)

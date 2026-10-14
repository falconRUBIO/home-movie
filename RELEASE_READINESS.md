# App Store release readiness

Production readiness is not established by simulator success. Do not mark unperformed checks as passed.

## Current remaining owner/device work

- Run DEVICE_TESTS.md on an iPhone 17 and the oldest supported device/OS configuration. Every physical row is currently NOT RUN. Use expendable recordings for destructive/fault tests.
- Record the exact TestFlight build, OS, device, results and evidence in release-readiness.json. Include long recording, repeated rear/front flips, PiP framing, Log with every film effect, calls/lock/background, low storage, recovery, update installation over a populated library, backup/restore and accessibility.
- Verify original footage hashes where appropriate. Confirm every completed scene survives interruption and an unfinished take is preserved for recovery. MOV fragmentation improves salvage; it does not guarantee the last partial fragment survives power loss.
- Use Instruments (Allocations/VM Tracker, Time Profiler, Energy Log, Hangs) to measure first live frame, peak/steady memory, preview delay, battery and thermal behavior. Test Standard, Log and PiP separately, both orientations and maximum supported zoom. Stop the release for reproducible lag, hangs, audio/video drift, frame corruption or footage loss.
- Confirm redistribution permission for the original Cinema LUT. User possession of a cube file is not evidence of a redistribution license. Keep the LUT intact while this is verified.
- Supply real public HTTPS privacy-policy and support URLs, accurate App Store privacy labels, export-compliance answers, screenshots and review notes explaining hardware-dependent Log/PiP restrictions. No account/login is implemented, so do not advertise one.
- Check final dependency/resource licenses and current App Store submission requirements. This checklist is not approval from Apple.

## Build and verification

1. Merge the reviewed code and pass native CI. The upload workflow retests the exact revision being archived.
2. For routine internal testing, keep the workflow's default `internal` distribution. It creates an internal-only archive.
3. When preparing the actual release candidate, choose `app-store-candidate` in the manual TestFlight workflow. It uploads an App Store-capable archive to Apple; it does not submit App Review or enable external testing. Test that exact build before submitting it.
4. Before upload, release_check.py validates the IPA bundle identifier, version/build, permissions, privacy manifest, effects library and retained original LUT, absence of retired LUTs, and absence of signing-key files. Apple's upload validation remains responsible for package/signing acceptance.
5. package_symbols.py must find and retain archive dSYMs before upload. Download the debug-symbols ZIP and test result artifacts for each candidate; GitHub retention is 14 days. Preserve them in the team's durable release archive before expiry. Keep matching dSYMs for future Xcode crash symbolication.
6. Fill release-readiness.json with evidence. Run:

   `python3 scripts/release_check.py --app-store --ipa /path/to/the-tested-build.ipa`

   This intentionally fails while metadata, rights confirmation, physical tests or exact build evidence are missing. It does not submit the app, verify URL reachability or assert Apple approval. Explicitly open and verify each public page yourself.
7. In App Store Connect, select the same App Store-capable build, verify screenshots/description and device support, review privacy/export declarations, add review notes and submit only after all blockers are resolved. Internal-only archives cannot be used for this final release.

## Recovery and privacy behavior

- Catalog writes are atomic; previous manifests and interrupted recording journals are retained. Original media is not overwritten by trims, looks or exports.
- Recording and export buffers are bounded; writer jobs release intermediates per frame. Camera pressure stops an ordinary take safely, while PiP sheds the presenter stream under pressure. Critical heat cancels export without deleting originals.
- Camera/microphone sessions stop when leaving capture or backgrounding. Verify this with the system privacy indicators and Instruments; source inspection alone is insufficient.
- Support events remain local and bounded. Apple MetricKit reports are retained locally (at most four, 1 MiB each) when Apple delivers them. Reports are not guaranteed immediately or for every termination. They may include device/build details and stack traces; no developer endpoint uploads them. Share Diagnostics explicitly exports a copy using the selected destination.
- Diagnostics can be cleared without touching movies. Destination privacy is governed by the service the user chooses.

## Release stop conditions

Do not release with a reproducible crash, silent loss of an expected recording/inset, unbounded memory growth, unknown data migration behavior, unverified LUT redistribution rights, inaccurate privacy disclosures, missing recovery evidence or failing native/archive checks. Roll back the candidate in development/TestFlight and ship a newly tested build; do not test recovery on a user's only copy of footage.

# App Store submission handoff

Use `release-readiness.json` as an evidence checklist, not an approval certificate. Run `python3 scripts/release_check.py --app-store --ipa <exact-tested-signed-archive.ipa>` before submission.

- After this change is merged, open the public privacy policy URL without signing in and enter it in App Store Connect. Check the in-app Settings > Privacy link in the release build.
- Copy `app_review_notes` into App Review Information and supply the developer's current contact details.
- Source currently has no developer collection endpoint, advertising or analytics SDK. Review the final signed build and Apple App Privacy definitions before selecting Data Not Collected; do not equate on-device camera access with developer collection. User-initiated diagnostics/support sharing still needs consideration in that review.
- Complete screenshots, age rating and export-compliance answers against the final binary. Do not claim unsupported-device Apple Log/PiP capabilities.
- Cinema contains third-party LUT data. Renaming it does not grant distribution rights. Obtain written permission/license covering redistribution inside this app, retain that evidence, and only then confirm `original_lut_redistribution_confirmed`. If permission cannot be obtained, replace/remove that data with an explicit migration plan for existing movies. Do not silently change users' saved grades.
- Record actual iPhone and oldest-supported-device evidence for the exact submission build. Simulator tests do not certify camera handoffs, thermal behavior, Photos writes, or export reliability on hardware.

An App Store-capable candidate upload does not submit the app for review. The workflow may create a candidate for physical testing while readiness evidence is incomplete; the strict preflight remains blocked until that evidence is supplied.

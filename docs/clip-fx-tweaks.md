# Movie FX with optional clip tweaks

The FX tab retains the shared movie look. A segmented Movie / This Clip selector adds per-clip fine-tuning. Existing clips without tweaks open on Movie. Adjusted clips reopen on This Clip. Clip Adjusted identifies a local recipe; Reset to Movie Look removes it.

This Clip starts with the resolved movie look. Store only relative offsets for numeric controls changed on that clip, plus an optional grain texture choice. Untouched controls follow subsequent movie edits. Amounts use effective enabled values, so a disabled legacy amount is zero. The original movie recipe and old catalogs retain their behavior.

Resolution clamps values to each slider's valid range. Stored offsets survive clamping, so reducing another control does not erase an earlier clip correction. Returning a control to its movie value removes that offset. Reset clears all offsets and returns to exact inheritance.

Save trim, lighting/color edits, the movie recipe and clip tweaks together in the catalog transaction. Ordinary light-only saves preserve clip FX. Duplicates copy tweaks; catalog encoding and backup validation retain them. Undo and redo capture both recipe layers. Export revisions invalidate cached files; thumbnails include the resolved FX identity.

MediaAssembler resolves the same recipe per scene for Watch, thumbnails, movie export and single-clip export. Scene review starts with that recipe and applies current editor state directly, avoiding a second layer of effects. Original comparison bypasses both layers. A movie with only clip FX still enables the custom compositor.

## Audit and validation

- Added unit tests for inheritance, sparse deltas, disabled effect amounts, relative movie updates, clamping, reset, serialization, invalid data and undo/redo.
- Added pipeline tests for persistence after reopening, sibling isolation, preview/export recipe parity, Original bypass, light-only saves, duplicate ownership and invalid-write atomicity.
- Portable project/resource validation, Python release checks and changed-Swift grammar parsing run locally. Xcode compilation, XCTest execution and hardware behavior require macOS/iPhone validation; these have not run for this change.

Device acceptance: set a movie look; reduce one clip's grain; verify another clip is unchanged; change the movie's grain and glow; verify the adjusted clip retains its relative grain correction and follows glow. Reset to Movie Look, undo/redo, duplicate, reopen the app and export both the full movie and single clip. Compare each exported clip with preview.

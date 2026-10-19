# Scene editing workflow

- Undo and Redo use the native navigation bar buttons. History belongs to the
  currently open scene editor and retains up to 50 steps. Closing the editor ends
  its history; original media is never used as an undo buffer or overwritten.
- Slider, curve, and trim-handle drags form one transaction. Reset, white balance,
  paste, and discrete accessibility adjustments form separate actions. A no-op
  drag preserves redo; a new edit after Undo starts a new branch.
- History includes trims, Light, Color, HSL, and movie-wide FX. Undoing FX restores
  the editor's movie-wide recipe, which is committed through the existing Save
  workflow. Save to Photos retains the open session's history. Compare is only a
  preview bypass and does not enter history.
- Scene actions > Copy Adjustments opens native selection toggles. Light, Color,
  HSL start selected; Exposure and White Balance start off. Selected groups
  replace destination values. Light includes curves/fade; Color includes only
  saturation/vibrance. Source and destination originals remain untouched.
- Paste Adjustments is available after copying, including across movies. The
  clipboard is app-local, in memory until quit; it does not read/write the system
  clipboard. FX, trim, LUT, movie settings and media cannot be copied by its type.
- A neutral destination can adopt a copied legacy processing version. An active
  destination with a different processing version rejects paste, avoiding silent
  changes to unselected controls. Reset the destination adjustments first.
- Regression tests exercise grouped/no-op drags, bounded history, redo branching,
  deferred observation, whole-state restoration, category selection and legacy
  compatibility. A store integration test reopens saved pasted edits and checks
  that source edits, destination corrections, trim, media and global FX persist.
  Native layout and touch/VoiceOver interactions still need an iPhone check.

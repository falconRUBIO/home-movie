# Device acceptance — not yet executed

Dolly motion follow-up (NOT RUN on corrected source): compare slow and fast slider drags and pinches at every Manual Dolly Response setting. Try every available lens pair in both directions and all automatic durations, including rapid nearby retargets, direction reversals, release, close, Hands-Free Start and Stay on This Lens changes. Inspect saved footage as well as the viewfinder. Repeat with Standard and Cinema, a stationary camera, bright/low light and a warmed device. Expect continuous movement and truthful measured progress; a long queue stall may extend duration without a catch-up jump. Record any physical sensor-switch, focus/exposure or frame-delivery discontinuity separately. Native motion/gesture tests do not establish smoothness on real sensors.

Every row below is **NOT RUN**. Run the complete matrix on an older supported iPhone and a recent multi-camera iPhone. Include iOS 18 and iOS 26+ when devices are available. Save device/model, OS, Xcode version, result, and a reproduction for any failure.

## First acceptance gate

1. Create movies A and B. Hold the phone sideways for A’s first take and upright for B’s first take.
2. Record three audible scenes into A, then two into B, using different available cameras.
3. Stop each take, wait until saving finishes, then immediately record again.
4. Quit and reopen the app. Check movie names, assignment, sequence, duration and covers.
5. Watch both movies from start to finish. Confirm no dropped audio, black joins, unintended crop or sideways frames.
6. Export both. Inspect videos in Photos and Files, including dimensions and duration.
7. Add another scene to A after export. Confirm its prior export stays unchanged and the next export includes the new scene.

The app must not be represented as device-tested until this gate passes.

| Area | Action | Expected result | Result |
|---|---|---|---|
| Permission denial | Deny camera, deny microphone separately | Existing movies stay accessible; no crash; Record unavailable; Settings link works | NOT RUN |
| Permission return | Grant permission in Settings, return | A usable camera appears only after preparation | NOT RUN |
| Lens discovery | Compare rear/front controls across devices | Only device-derived zoom/lens choices appear; no invented telephoto | NOT RUN |
| Lens range | Pinch past either end, switch lenses while recording | Values clamp; no overlapping capture; valid output and sound | NOT RUN |
| Default lens | Enter rear camera | Starts at the device’s displayed 1× where available | NOT RUN |
| Full frame | Record a framing chart with corners visible | Live preview fills its region between native-style black control areas; controls stay inside safe areas. Fill preview may trim edges; saved footage and export retain the complete source frame | NOT RUN |
| Orientation | Landscape left/right, Portrait, rotate during a take | First take chooses the format; later pages open in that saved format without a rotation prompt; take orientation remains fixed | NOT RUN |
| Front camera | Record a page of text | Mirrored preview; unmirrored saved footage; complete frame | NOT RUN |
| Rapid taps | Tap Record/Stop repeatedly during start and save | One take and one commit; destination remains fixed | NOT RUN |
| Movie switching | Attempt to switch during a take/finalization | Controls disabled; take stays in original movie | NOT RUN |
| Audio routing | Built-in mic, headphones, Bluetooth changes | Sound captured; interruption clear; deliberate resume | NOT RUN |
| Phone call | Interrupt an active take | Previous scenes intact; completed take validated; no automatic recording resume | NOT RUN |
| Lock/background | Lock or switch apps during a take | Finalization attempted; committed scenes survive; recording never restarts automatically | NOT RUN |
| Forced termination | Kill while recording, finalizing, and just after saving | Prior scenes intact; recover valid journaled media; preserve incomplete files | NOT RUN |
| Low storage | Near-full device before and during capture/export | Clear error; saved originals remain usable | NOT RUN |
| Mixed geometry | Exercise portrait/landscape fixtures in a movie | Canvas fits with letterbox/pillarbox rather than cropping | NOT RUN |
| Silent media | Run generated no-audio fixtures | Playback/export valid without assuming audio tracks | NOT RUN |
| Audio offsets | Fixture with delayed audio-track start | Correct offset; no shifted dialogue or insertion exception | NOT RUN |
| Scene audio joins | Record quiet room tone and speech across three takes; listen on speaker/headphones in Watch Movie and a fresh export | No boundary click or noticeable fade/dip; speech timing and duration unchanged; compare originals to identify any click already recorded by the mic | NOT RUN |
| Trim | Drag edges; reset; reopen and export | Same range in playback/export; original file byte-for-byte unchanged | NOT RUN |
| Deletion | Remove scene/movie; reopen; restore in Settings | Original retained; scene order/trim restored | NOT RUN |
| Missing source | In a developer test container, remove one source | Missing scene reported; fail clearly; no silent skipped footage | NOT RUN |
| Damaged catalog | In a developer test container, corrupt catalog JSON | Fail closed; no empty replacement catalog | NOT RUN |
| Export cancellation | Cancel early/late and leave app mid-export | Partial output removed; retry possible; originals safe | NOT RUN |
| Export snapshot | Compare existing/new revision exports | First export unchanged; new export uses new revision | NOT RUN |
| Re-export | Reopen unchanged movie, export again | Validated revision cache reused when present | NOT RUN |
| Save destinations | Photos add-only permission, Files cancel/save, share cancel/send | No broad Photos read access; output remains alive through UI | NOT RUN |
| Long movies | 60-minute and multi-hour assembled fixture | Bounded frame memory; progress/cancel remain responsive; storage sufficient | NOT RUN |
| Offline | Enable airplane mode | Create, record, review, trim, restore, export all work | NOT RUN |
| Accessibility | VoiceOver and largest Dynamic Type | Meaningful labels; trim adjustable actions; no clipped essential controls | NOT RUN |
| Appearance | Light/dark, Reduce Transparency, Reduce Motion | Native materials legible; no required information depends on animation | NOT RUN |
| Thermal | Prolonged recording on older iPhone | Session errors/pressure clear; existing scenes preserved | NOT RUN |

## Backup and recovery acceptance — all NOT RUN

| Action | Expected result | Result |
|---|---|---|
| Save a backup to Files, then cancel a second save | Only successful save creates a receipt; cancellation never claims backup success | NOT RUN |
| Record or trim after backup | Backup status reports changes since saved revision | NOT RUN |
| Restore on a fresh installation using expendable recordings | Originals, movie format, trims, sequence and deleted items preserved; new identities | NOT RUN |
| Restore into a populated library twice | Existing movies unchanged; separate copies on each import | NOT RUN |
| Corrupt a copied payload, change a manifest path or use a symlink | Reject before catalog commit; existing footage retained | NOT RUN |
| Cancel backup/restore and terminate during each phase | No false success; maintenance releases on cancel/relaunch; prior movies safe | NOT RUN |
| Restore an iCloud Drive package not downloaded locally | Coordinated provider access; clear progress/error; existing movies safe | NOT RUN |
| Low storage while backing up/restoring | Clear failure; no destructive replacement | NOT RUN |
| Damage catalog and repair previous version | Damaged bytes preserved, previous catalog loaded, footage reconciled | NOT RUN |
| Export/recover an unassigned playable file | Source retained; new imported scene validated | NOT RUN |
| Enable Photos copy; deny/regrant permission; retry | Local recording remains usable; separate accurate Photos status | NOT RUN |
| Terminate between Photos save and receipt | Local source retained; document possible duplicate on retry | NOT RUN |
| Large multi-hour backup | Bounded byte memory; responsive cancellation; sufficient local/provider space | NOT RUN |

## Test record

- Device and OS:
- Xcode version:
- Source package revision:
- Automated tests:
- First acceptance gate:
- Failed matrix rows and reproduction:
- Export inspection (codec, dimensions, fps, audio, duration):
- Memory/thermal measurements:

Use copies and test movies for destructive developer-container scenarios, never irreplaceable footage.

Zoom-option acceptance: compare buttons with the phone's available recording modes. On the reported phone, verify 0.5×, 1×, secondary 2×, 4× and 8× when supported by the active format. Record at 8×, stop, review and export; confirm the selected zoom persists. Repeat with an older phone and front camera to confirm unsupported options do not appear.

Tap-focus acceptance (NOT RUN): before recording and during one uninterrupted recording, alternate taps on near/far subjects and bright/dark areas. Confirm supported focus and exposure respond, the yellow square appears at the touch, and the saved scene remains continuous with audio. Repeat near all preview edges, in portrait and both landscape orientations, on front/back cameras and each zoom choice. Check front-camera mirroring targets the touched object. Move the camera significantly and verify automatic metering resumes. Pinch to zoom and tap all overlay controls; controls must not accidentally focus through to the preview. On fixed-focus hardware, verify exposure-only behavior where supported.

Familiar-controls acceptance (NOT RUN): hold a near/far subject until AE/AF LOCK appears, then move to another subject and lighting condition; verify focus/exposure settle and hold, including while recording. Tap to unlock and confirm automatic metering resumes. Drag vertically beside the sun to brighten/darken and confirm limits, reticle position, and recorded result. Repeat while locked, and on front/fixed-focus cameras where supported. Check tap/hold/exposure drag do not prevent pinch zoom or overlay buttons. Verify VoiceOver centered-focus/lock and brightness actions. Toggle torch before/during recording, then switch to front camera, open review, background and exit; the torch must turn off. Test thermal/unavailable torch failures without losing or stopping a recording.

Stability acceptance (NOT RUN): rapidly record then stop, background immediately after record, and interrupt with a call while capture starts. Verify no recording starts after cancellation, no permanent SAVING state, and later recording still works. Stop immediately after the recording begins and verify any playable scene saves. Repeat background/foreground and review/return during permission prompts and finalization. Force a camera-switch/configuration failure; confirm the old camera remains usable or Resume Camera reconnects. Exercise high-frequency pinch/exposure updates while recording; a failed adjustment must not stop the scene. Rotate while the yellow indicator is visible and verify it stays aligned with the metered subject. Confirm torch extinguishes on camera/audio interruption and runtime recovery. Relaunch after each phase and inspect journal recovery and saved media. Use test footage.

Full-app follow-up acceptance (NOT RUN): switch scenes during thumbnail loading and dismiss scene review while it loads; no stale images or late playback. Turn Photos copies off during a retry batch; no new submissions after opt-out, while already accepted copies retain receipts. Try repeated retry taps; only one retry batch runs. Attempt restore while catalog repair is active; controls must prevent overlap. Cancel restore during installation and confirm existing movies and original footage remain intact. Record microphone audio, trim/join scenes, and export a long portrait/landscape movie; inspect audio continuity, dimensions, duration, thermal behavior and memory. Check add-only permission denial, low storage, provider-offline errors, large backups, and each disabled/loading/error state with VoiceOver and larger text.

Watch Movie layout acceptance (NOT RUN): open portrait and landscape movies on a small iPhone and a larger iPhone. Without scrolling down, confirm the Scenes heading, scene thumbnails and Continue Recording button are visible below the player. Swipe the timeline and open the first/last scene for review. Rotate during playback, test larger text and VoiceOver, and confirm the entire recorded frame remains visible with native playback controls. Playback/loading/error states must not move the timeline off-screen.

Library export acceptance (NOT RUN): from Movies, open a card’s three-dot menu and choose Export. Check the selected movie name/duration, prepare the video, then Save to Photos, Save to Files and Share Video. Cancel export and reopen it. Confirm the library stays in place, originals remain editable, and Export is disabled for an empty movie. Repeat with multiple movie cards to verify the chosen movie is exported.

Automatic-orientation acceptance (NOT RUN): create a movie without selecting a format. Rotate before recording and confirm no prompt and an upright preview between black controls. Start in portrait, landscape-left and landscape-right on separate movies, rotate mid-take, stop and verify saved/exported dimensions remain those chosen at Record. Return/relaunch and confirm later scenes open directly in the saved orientation without any rotation prompt or disabled record button. Delete all scenes and confirm the original format stays locked. Cancel/background before the first take starts and confirm the draft remains automatic. Repeat with front camera, each supported lens, system Portrait Orientation Lock, face-up/down, focus/AE-AF lock, and both rotation directions. Confirm reticle stays on the touched subject. Relaunch with a finished uncommitted journal and verify recovered first-scene orientation.

Apple Log/looks acceptance (NOT RUN): Standard New Movie remains simple and has no Look controls. On a supported phone, choose Apple Log and record portrait and both landscapes with microphone audio. Inspect file transfer tags, 10-bit codec profile, lens availability/zoom and dimensions; verify front-camera switching is disabled when unsupported. View Apple Standard, import Cinema.cube through Files, switch among multiple Apple Log looks, compare Show Original and return to the selected look. Export while the original comparison is showing and confirm the selected look is burned into the copy. Compare exported frames/audio with playback and Resolve references, including dark shadows, bright highlights, skin, saturated colors, edges/rotation and trims. Show Original must preserve the selected look; Standard scenes must not get Log conversion. Relaunch and backup/restore to another install, confirming look identity, checksum verification, original footage integrity and selected-look rendering. Test malformed/oversized/1D cubes, unavailable iCloud providers, cancellation/backgrounding, larger text and VoiceOver. Measure long-playback/export memory, thermal and battery behavior on actual hardware.

Established-format/live-look acceptance (NOT RUN): reopen portrait and landscape movies while holding the phone in either direction and verify their Camera and Watch pages request the saved format without a rotation prompt. Compare live framing with recorded playback/export, including both landscape directions, front-camera mirroring, tap focus and locked exposure. Switch live looks and Show Original during one uninterrupted take; confirm the original file stays genuine Log without any baked grade. Import Cinema.cube before recording, relaunch, and confirm setup, live preview, playback and export agree. Test Original bypass, unsupported high-bit-depth dual-output configurations, background/interruption, rapid look changes, Files import, sheet dismissal and return to an unlocked library. Measure sustained 10-minute recording/rendering memory, GPU, heat and dropped preview frames on actual supported phones; preview slowness must never queue frames or change the recorded file.

Live-look handoff acceptance (NOT RUN): rapidly alternate Show Original and several imported looks during a single take. Original must remain visible until a selected look is explicitly enabled; a finishing GPU frame must not flash the previous look. Switch away during rendering, return, and repeat across foreground/background transitions. Timer, zoom and metering updates must not flicker an unchanged look. Confirm New Movie can expand with the keyboard and larger text, and both Cancel and swipe dismissal are blocked during a look import.

Native-control acceptance (NOT RUN): confirm no movie-name pill or VIDEO caption, black top/bottom controls, lowered lens row, recent thumbnail and Watch Movie in the lower portrait panel. Rotate to either landscape direction and confirm the recording panel and lens strip fit safe areas. With Standard and Log, check 0.5×/1×/2×/4×/8× only where device-derived and no 0.9× button. In good lighting with a distant subject, compare fields of view with native Camera and verify physical telephoto/ultra-wide switching during recording using a developer device session; allow the system’s normal low-light/close-focus fallbacks. Inspect originals rather than relying on viewfinder crop. Repeat with an older/non-Pro phone and front camera. Test current Log readiness on the reported iPhone and report the new specific failure if it still rejects capture.

Smooth Zoom acceptance (NOT RUN): verify the closed screen only adds a small button after the actual lens choices. Open it before and during a take: actual zoom/framing must not change, the track sits directly above the lenses and recording/audio stay uninterrupted. Drag slowly/rapidly in both directions, release and allow settling, then close mid-motion and inspect smooth ease-out/held position in the saved file. Leave it open while framing; it must not dismiss itself. Tap each lens and pinch: pending Smooth Zoom motion stops before the new action, with no delayed return to its old target. Change Slow/Normal/Fast in Camera Settings. Enable Stay on This Lens on a supported virtual camera, verify the active physical camera stays and limits narrow, then close/change lenses/flip/interrupt/background and confirm automatic selection returns. Repeat front/back, each supported zoom, Standard/Log, both orientations, small screen, VoiceOver, larger text, pressure/heat and long takes. Check no permanent timer or hidden motion after dismissal/suspension; open-state visual layout, actual zoom accuracy and recorded motion cannot be established by simulator math tests.


## Log codec follow-up (build 1041 regression)

1. On the reported iPhone, open a new Apple Log movie. Camera must reach Ready without the missing-HEVC error. Inspect Camera settings for HEVC or ProRes.
2. Record a ten-second audible clip with Original and a live look; stop, relaunch, watch and export. Inspect source format: ten-bit HEVC or ProRes, original Apple Log metadata, no SDR/HLG/Log 2 substitution.
3. Check compatible rear lens choices, zoom and interruptions; reconnect must retain the valid Log capture format.
4. Verify ProRes footage produces a valid Cinema preview/export and untouched source. Check low-storage start refusal and mid-take stop without deleting any original or recovery file.

Status: NOT RUN. Simulator cannot exercise capture codec negotiation.


## Camera preview proportions follow-up

Compare against IMG_5438.PNG on the same iPhone: tall 9:16 portrait preview; header, lens buttons and Record overlay the picture; thumbnail and Watch Movie occupy the small lower black strip; total runtime sits below Watch Movie. Landscape preview must retain 16:9 with a compact side review rail. Opening/closing Smooth Zoom must not change the preview frame. Check taps/pinch/metering around the overlays, hardware orientation, smaller screens and accessibility text. Verify elapsed take time appears during recording and total duration updates below Watch Movie after durable save. Status/errors must remain readable above the controls. Status: NOT RUN.


## Library cover Play (NOT RUN)

Tap the circular Play control for a multi-scene movie: open full-screen playback, start from the beginning, play every active scene/trim in sequence with sound and the selected look. Pause/scrub using native controls; change looks while paused and while playing; background during loading/playback; Done must stop audio and return to the same library. The rest of the cover opens recording and the three-dot export still works. Empty movies must not offer Play. Check both orientations, accessibility labels and a bright cover for button contrast. Existing camera Watch must still show the timeline.

## Built-in Filmica (NOT RUN)

On a supported iPhone, New Movie initially shows Standard. Choose Apple Log and confirm bundled Cinema is selected without opening Files. Record; confirm Cinema preview, full-screen playback and export agree with the supplied Cinema reference. Compare skin, neutral gray and highlights to the creator workflow to confirm Apple Log input (cube lacks metadata). Look opens its menu; only Add opens Files. Apple Standard, Original and custom look switches must work and persist. Existing Standard movies retain their original capture profile. Back up and restore a Cinema movie with no external LUT import.

Live-preview report follow-up (NOT RUN on corrected source): the user reported flat live video despite LOG · Cinema, with graded playback working. Install the build containing the visible-overlay fix. Compare Cinema and Show Original on the same stationary scene before/during recording, return from Watch Movie, and repeat after backgrounding, lens changes and both orientations. The badge must show the selected look only when a graded frame is presented. Check ten-minute rendering, heat, GPU load and capture continuity; native eight/ten-bit render and onscreen presentation tests do not certify actual camera delivery.

## Hands-Free Start acceptance — NOT RUN

Enable Hands-Free Start in camera settings, open Dolly, tap the starting lens and then the ending lens, and select a move duration. The bar shows the planned endpoints. Tap Record: a silent 3–2–1 countdown appears, the same button cancels it, and capture starts before the planned Dolly begins.

Verify both zoom directions and every supported duration, portrait and landscape, Standard and Apple Log. Tap cancel at each countdown number, lock the phone, switch apps and simulate a camera interruption. None of those cancellations may create a take or restart recording on return. Verify the start lens is held through the countdown, the saved take includes the complete move, and rapid Record/Cancel taps never produce duplicate takes. Turn Hands-Free Start off and confirm Record starts immediately.


## Dolly delay and stabilization release check (2026-10-12)

- Open Dolly at 1×: start highlights immediately. Choose 8× without retapping 1×. Repeat from 4× and from an intermediate manual zoom value.
- Expanded Dolly only: timer menu on the left, move duration on the right. Verify Off / 3s / 5s / 7s, selected checkmark, readable labels, 44-point tap targets, portrait, landscape and accessibility text sizes.
- With a delay selected, choose a destination then Record. Countdown starts at the selected number; recording and Dolly begin after it finishes. Cancel using the record control and confirm neither recording nor queued Dolly starts.
- Keep 7s selected, close Dolly, then Record: starts immediately. Reopen Dolly: the saved delay returns. Verify backgrounding, phone interruptions, camera switching and unavailable camera cancel a pending countdown.
- Tap the video to focus before and during manual and automatic Dolly moves. Tap every lens, timer and duration control: never triggers focus. Verify exposure dragging and pinch zoom still work.
- Compare Apple Camera and Movie Roll on the same iPhone, lighting, lens/zoom and 1080p30 format: preview and saved clips at 1× / 4× / 8×, steady hands, walking and panning. Include Standard, Cinema, front camera, 1×→8× and 8×→1× Dolly moves. Record actual active stabilization modes using Xcode; simulator cannot prove optical steadiness or device crop/latency.
- Film Effects: compare playing and paused frames, inspect fullscreen, return to Export, save/export/reopen settings, and verify exported effects match preview while ordinary Watch Movie remains clean.

- Rotation regression: start a fresh movie in portrait, rotate to each landscape side and back repeatedly before recording. Confirm live Standard and Cinema previews remain visible, upright and responsive, with lens/focus/Dolly controls usable. Record the first landscape clip, review it and reopen the camera. Repeat from a portrait first clip. Existing movies retain their recording format; rotating must never produce a missing preview.

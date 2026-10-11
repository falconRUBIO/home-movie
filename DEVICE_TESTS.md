# Device acceptance — not yet executed

Every row below is **NOT RUN**. Run the complete matrix on an older supported iPhone and a recent multi-camera iPhone. Include iOS 18 and iOS 26+ when devices are available. Save device/model, OS, Xcode version, result, and a reproduction for any failure.

## First acceptance gate

1. Create movie A in Landscape and movie B in Portrait.
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
| Full frame | Record a framing chart with corners visible | Live preview fills the screen edge to edge in both orientations; controls stay inside safe areas. Fill preview may trim edges; saved footage and export retain the complete source frame | NOT RUN |
| Orientation | Landscape left/right, Portrait, rotate during a take | Required starting orientation enforced; take orientation remains fixed | NOT RUN |
| Front camera | Record a page of text | Mirrored preview; unmirrored saved footage; complete frame | NOT RUN |
| Rapid taps | Tap Record/Stop repeatedly during start and save | One take and one commit; destination remains fixed | NOT RUN |
| Movie switching | Attempt to switch during a take/finalization | Controls disabled; take stays in original movie | NOT RUN |
| Audio routing | Built-in mic, headphones, Bluetooth changes | Sound captured; interruption clear; deliberate resume | NOT RUN |
| Phone call | Interrupt an active take | Previous scenes intact; completed take validated; no automatic recording resume | NOT RUN |
| Lock/background | Lock or switch apps during a take | Finalization attempted; committed scenes survive; resume requires a tap | NOT RUN |
| Forced termination | Kill while recording, finalizing, and just after saving | Prior scenes intact; recover valid journaled media; preserve incomplete files | NOT RUN |
| Low storage | Near-full device before and during capture/export | Clear error; saved originals remain usable | NOT RUN |
| Mixed geometry | Exercise portrait/landscape fixtures in a movie | Canvas fits with letterbox/pillarbox rather than cropping | NOT RUN |
| Silent media | Run generated no-audio fixtures | Playback/export valid without assuming audio tracks | NOT RUN |
| Audio offsets | Fixture with delayed audio-track start | Correct offset; no shifted dialogue or insertion exception | NOT RUN |
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

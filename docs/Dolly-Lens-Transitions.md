# Dolly lens transitions

Smooth Zoom previously used unrestricted automatic constituent selection. Each 60 Hz zoom update could coincide with a change of primary lens due to lighting or focus, including near the telephoto boundary.

During Smooth Zoom, use AVFoundation's restricted switching policy with an empty fallback-condition set. This is not a lens lock: crossing the device-reported switch-over factor still allows an eligible lens after exposure and focus stabilize. Apple can retain the shorter lens when the longer lens cannot meet exposure/focus requirements. Do not include `videoZoomChanged`, because every animation tick would permit another fallback decision, not just boundary crossings.

Preserve the device's prior switching behavior and conditions and restore them on closing, interruption, cancellation, or switching camera. The optional Stay on This Lens setting still explicitly locks the lens. Keep continuous exposure, user exposure bias, focus, stabilization, and the existing zoom trajectory intact. No hard-coded 4x boundary or artificial frame blending is introduced.

This reduces opportunities for lens hunting; it does not prove the reported brightness/framing jump is eliminated. Different physical lenses have different viewpoints and light sensitivity. Verify on iPhone before calling this visually seamless.

## Physical acceptance — not run

- In bright daylight and indoor light, run 1x to 8x and back at 3, 5, and 15 seconds. Repeat Standard and Apple Log, idle and recording.
- Inspect both preview and saved footage across the actual device telephoto boundary for exposure steps, repeated lens switching, frame jumps, focus pumping, and audio continuity.
- Repeat with a near subject and in low light. Confirm a lens that cannot expose/focus adequately is not forced on by zooming in.
- Close Smooth Zoom, leave/reopen the camera, interrupt capture, and flip front/rear. Confirm ordinary automatic lens selection and tap metering recover.
- Repeat with Stay on This Lens enabled and disabled. A physical lens lock may trade image quality for avoiding a physical handoff; it is not the default solution.

## Apple references

- [Restricted switching conditions](https://developer.apple.com/documentation/avfoundation/avcapturedevice/primaryconstituentdevicerestrictedswitchingbehaviorconditions-swift.struct)
- [Video zoom changed](https://developer.apple.com/documentation/avfoundation/avcapturedevice/primaryconstituentdevicerestrictedswitchingbehaviorconditions-swift.struct/videozoomchanged)
- [Constituent selection](https://developer.apple.com/documentation/avfoundation/avcapturedevice/primaryconstituentdeviceswitchingbehavior-swift.enum)

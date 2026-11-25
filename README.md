# ExposureControl

iPhone 11 camera features for the iPhone XS, XS Max and XR

Exposure Slider (adjust exposure without locking)

Zoom Dial (iPhone 11 Style)

Automatic Live Photos (the A12 Neural Engine scores each Live Photo)

NOTE: DUAL CAMERAS (XS / XS MAX) ARE NEEDED FOR THE FOLLOWING ADDITIONS

View Outside the Frame (at 2x, the wide camera supplies the area outside the frame)

## Experimental (separate build)

Night Mode on the XS / XS Max wide camera (iPhone 11 Pro tuning, unverified)

## Download from my repo

https://michaelmelita1.github.io

## Compatibility

iPhone XS, XS Max, XR

iOS 15 - 18, rootless

Untested on a device yet.

## NOT POSSIBLE

~~Deep Fusion~~ Needs the camera hardware to report "Soft ISP" (A13 and later)

~~Photographic Styles / Smart HDR 3~~ Needs A13 / A15 processing

~~Ultra Wide, front 120 fps / 4K~~ No such camera hardware

## HOW IT WORKS

One dylib for Camera, Settings and the camera daemon (mediaserverd on iOS 15-16, cameracaptured on iOS 17+). It answers the camera feature questions the Camera app asks at launch, and patches the daemon's camera config in memory (no system files are replaced). Firmware notes are in [CLAUDE.md](CLAUDE.md).

## TO BUILD

make package

make package EXP=NIGHTMODE (Night mode experiment)

make package DIAG=DIAG_LOG (diagnostic logs)

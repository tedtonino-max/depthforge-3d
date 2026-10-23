# Validation — consensus surface rebuild

## Code review decisions

- Correct image-down to AR-camera-up conversion before applying the camera pose.
- Projective data association in a single persistent surfel map; no patch history.
- At most one observation per surfel per timestamp, even when several pixels match.
- Reject low/missing confidence, invalid depth, grazing normals and discontinuities.
- Four frame consensus for export/display; point-to-plane residual for consistency.
- Repeated free-space contradiction removes stale elements; foreground occlusion preserves them.
- Bounds are checked on insertion, refinement, displayed disks and final PLY export.
- Detail taps use native depth and local derivatives, not arbitrary estimated planes.
- All processing/storage is ordered on one worker; finish drains it before closing.
- Tracking recovery updates the instruction and rejects stale visibility.
- Existing RoomPlan session survives pause/resume; finishing has a bounded fallback.
- Photo selection is pose/angle/exposure/visibility gated and committed only after writing.
- No mixed quality percentage, no whole-object completeness inference from a single view.

## Automated regression coverage

`swift test -c release` runs the production core (no reimplementation):

- projection axes and rigid-pose round trip;
- single-frame and repeated-timestamp exclusion from consensus;
- noisy-plane refinement and bounded growth over repeated passes;
- camera-distance changes preserving surface consistency;
- independent angular evidence and readiness prerequisites;
- low confidence, invalid depth, strict object bounds and exported PLY parsing;
- missing object selection rejecting capture;
- a synthetic object with two three-pixel-wide legs in front of a distant background;
- free-space replacement versus occlusion preservation;
- surface-oriented detail selection and increased sampling;
- memory/render/deadline limits and reset;
- photo stability, tracking gaps, exposure, visibility and view novelty.

Tests are deterministic geometric regression cases, not physical LiDAR measurements.
The workflow must pass these tests before building the iPad app. App-source parsing
is an extra check; only Xcode compilation confirms Apple framework compatibility.

## Required iPad checks (not executable on this Windows host)

Use a small stool/poof with thin legs and a room with a selected wall/floor zone.
Keep the PLY, manifest, original frames and a screen recording for assessment.

1. Draw the floor circle, check height and start. The camera must remain dominant.
2. Hold still; confirmed surface appears. Move sideways, hold again; the SAME
   surface refines. No rectangular patches, floating panels or filled scan volume.
3. Capture the legs from a low angle. Missing sensor data must remain open rather
   than joining legs to background or claiming unseen detail is complete.
4. Temporarily obscure tracking, then recover. The instruction must recover;
   the overlay must not be displayed with a stale pose.
5. Inspect the PLY: no positions outside the cylinder, no single-frame points.
6. In Room mode, select and confirm a wall/floor detail disk, observe focused
   guidance, then reselect. Old zone readiness must not carry over.
7. Capture stable novel views in usable light; verify thumbnails, view angles,
   photo paths and camera poses in the manifest. Fast movement must not select photos.
8. Pause/resume, review/continue, save, share PLY and export the full scan folder.
9. Try a longer scan: camera responsiveness, visible slowdown, thermal pause,
   bounded element count and storage errors. Measure real device timings.

A green CI result authorizes a device-validation IPA, not a claim that these
physical acceptance checks have already passed. Distribution beyond that test
requires assessment of both device scans. No sub-millimetre or texture-atlas claim.

## Primary implementation references

- Apple sceneDepth input and confidence: https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth
- Camera exposure duration: https://developer.apple.com/documentation/arkit/arcamera/exposureduration
- Native folder export: https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(forexporting:ascopy:)

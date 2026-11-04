# Native UI verification — 3 November 2026

Environment: macOS 15.8.2 on Intel. UI interactions use the computer-use bridge,
as requested. Existing library media is excluded from compression and deletion.

## Verified through the native UI

- Photo Compressor 0.1.1 connected to the dev account's Photos library without
  the previously reported privacy-key crash. The user approved the native
  permission prompts.
- The starting library contained three photos and no videos.
- Imported a generated portrait H.264/AAC test clip through Photos' import dialog.
  Photos then displayed **3 Photos, 1 Video**.
- Marked only the generated clip as a favorite and added it to the test-only
  album `PHOTO_COMPRESSOR_UI_QA_20261103`.
- Refreshed Photo Compressor. It found the test clip and displayed its original
  size (351 KB), thumbnail, duration, and initial size estimate.
- After the user approved the rebuilt app's prompts, 0.1.2 connected and
  displayed the original video without the previous preview abort.
- Changed the maximum resolution to 720p and quality to Smaller. The estimate
  changed to 210 KB (40% savings); only the generated clip was selected and
  replacement remained off.
- Compressed, validated, and automatically imported a **115,941-byte** copy of
  the **351,233-byte** original (67% smaller). The journal records successful
  metadata verification and `readyToDelete`.
- Switched to the compressed preview and played it. The playback timeline
  advanced and the synthetic image visibly changed.
- Photos showed both versions in the test album, with both favorite flags and
  matching capture dates. Library totals were **3 Photos, 2 Videos**, and Photos
  displayed **Synced to iCloud**. This observation covers this small test only.
- Quit and reopened Photo Compressor through the bridge, reconnected, and
  opened History. The ready copy, byte sizes, and original-deletion selection
  survived the restart.
- Compared SHA-256 hashes of the imported fixture and local original archive;
  they match exactly.
- After the user confirmed macOS's deletion dialog, History changed to
  **Replaced in Photos**. Photos showed **3 Photos, 1 Video** and **Synced with
  iCloud Just Now**. The remaining test-album video retained its favorite flag
  and capture date. No existing photos were edited or deleted.

## Issues found and fixes in 0.1.2

1. Selecting a real video caused an abort in `_AVKit_SwiftUI` generic superclass
   metadata initialization. Replaced SwiftUI `VideoPlayer` with an AppKit
   `AVPlayerView` hosted using `NSViewRepresentable`.
2. A successfully connected library with no videos still displayed the initial
   Connect Photos welcome screen. Added an explicit connected/empty state.

The universal 0.1.2 app builds and passes privacy-description, architecture, and
signature checks. All ten automated tests pass, including generated HDR, actual
HEVC encoding, portrait geometry, frame-rate caps, AAC packet preservation,
cancellation, and journal recovery.

## Follow-up fixes in 0.1.3

- Native playback controls appeared for the compressed file but were not
  visible for the initial PhotoKit preview. Added visible transport controls
  below the player for play/pause, replay, seeking, and mute.
- When filters hid all processed videos, the main pane shrank vertically.
  Replaced the native split view with fixed side panels and a flexible preview,
  and made the empty-list placeholder explicitly fill the available space.
- Video previews are now real, accessible buttons, rather than tap gestures on
  text. Selection for compression remains a separate control.

The universal 0.1.3 ZIP passes privacy-description, architecture, and signature
checks, including after extraction. The ten automated tests passed after the
playback-control change; the packaging test and builds passed again after the
final layout/accessibility changes.

Verified through the bridge in the final build:

- Local-file play, pause, replay from the end, seek, and mute/unmute controls.
- Opening a Photos preview through its accessible Preview button and playing it
  with the visible transport controls.
- Filtering every video out while a preview is open. The header, preview,
  settings, footer, and empty-list message retain their normal layout.
- A second import of the synthetic clip, followed by **Compress & replace** with
  replacement enabled. Compression, import, and metadata checks succeeded and
  the app automatically requested the final native deletion confirmation.
- After the user confirmed that dialog, automatic replacement completed.
  History shows **Replaced in Photos** for both test operations; both journal
  records have stage `originalDeleted` and verified metadata.
- Switched to the compressed preview after original deletion and played it
  successfully, with an advancing timeline and changing image.
- Final Photos totals are **3 Photos, 2 Videos**, with **Synced with iCloud
  Just Now** displayed. These are the three existing photos and the two
  compressed test copies. Recently Deleted was not emptied.
- Both full original archives match the fixture's SHA-256 hash, and both
  compressed outputs remain present with the expected 115,941-byte size.
- Restored 1080p, 30 fps, Balanced, 15% minimum savings, and replacement off.
  No videos are selected. The app is left showing the completed History.

Both the review-first workflow and automatic **Compress & replace** workflow
passed for this synthetic local Photos video. No further manual steps are
pending for this test.

## Verification limits

The native system dialogs required the user's manual interaction because the
bridge blocks the system-dialog app. No alternative UI automation was used.

Cloud-only original downloads, a full iCloud account, large libraries,
multi-video batches, nonempty captions/keywords, nonempty locations, and real
iPhone Dolby Vision footage remain unverified. A synthetic 1.2-second clip does
not establish visual quality or performance for long personal videos.

## Test asset

The generated original is retained outside Photos at:

`/tmp/PhotoCompressor-UI-QA-20261103/PHOTO_COMPRESSOR_UI_TEST_20261103.mov`

It is synthetic test media, not a personal video. Existing photos have not been
edited, compressed, or deleted.

Permanent archives of both test runs are in `~/Movies/Photo Compressor Backups`,
under operation IDs `39D6F8A5-6352-4BEC-825B-AB2886C43377` and
`FCE7B49D-E95B-42DB-9E6C-F828D9FB8449`.

## 0.1.4 changes — 4 November 2026

Added Show in Photos actions using Photos' native scripting `spotlight`
command, per-video explanations of compression tradeoffs, measured size and
saved-setting display for finished copies, and a generated app icon packaged
at standard/Retina sizes. Newly recorded operations retain source video facts
so later explanations can use the measured source frame rate and HDR status.
Existing journal records remain readable; unknown source details are labeled.

This release is built and packaged without another automated or native UI test
run, as requested. The end-to-end test results above apply to 0.1.3.

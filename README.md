# Photo Compressor

A native macOS app for browsing large Apple Photos videos, previewing them,
estimating savings, and compressing/replacing a selected batch. No subscription,
server, iCloud login, FFmpeg, or Python installation is required.

[Preview the sample interface](docs/sample-library.png). The sample data and
artwork are illustrative, rather than compression benchmarks.

## Download

[Download Photo Compressor for macOS](https://github.com/blubbbot/applephotocompressor/releases/latest/download/PhotoCompressor-macOS-universal.zip)
or see the [release notes and checksums](https://github.com/blubbbot/applephotocompressor/releases).
Requires macOS 14 or newer; the same app supports Intel and Apple Silicon.

Unzip the download, move **Photo Compressor.app** to Applications, and open it.
The release is locally signed, not signed with an Apple Developer ID or
notarized by Apple. If macOS blocks the first launch, use **System Settings →
Privacy & Security → Open Anyway** for this app, following
[Apple's instructions](https://support.apple.com/en-gb/102445).

## Build and open

Requires macOS 14 or newer and Xcode command-line tools with Swift 5.9 or newer.

```sh
./scripts/build-app.sh
open "dist/Photo Compressor.app"
```

The build script checks the required privacy purpose strings, creates a locally
signed `.app`, verifies both architectures and the signature, and packages a
versioned ZIP in `dist`. The local build uses ad-hoc signing; Developer ID
signing and notarization are not part of this script. It produces a universal
application for Apple Silicon and Intel.

Explore the UI without granting Photos access:

```sh
open "dist/Photo Compressor.app" --args --demo
```

The sample library uses fictional names, artwork, and sizes. Compression is
disabled for sample items. **Open Video Files** provides a real file-based mode
for trying the encoder without modifying any Photos library.

## Library workflow

1. Open the app and choose **Connect Photos Library**. Allow full Photos access
   and allow the app to control Photos when macOS requests it. Photos should have
   your iCloud-enabled System Photo Library open.
2. Browse videos by original size, estimated savings, duration, or date. File
   sizes are read through Photos' scripting interface, without intentionally
   downloading every original. If sizes are unavailable, the app measures them
   when selected originals download.
3. Click a video to play its Photos preview. Check the videos you want, or use
   **Select recommended**. Set maximum resolution/frame rate, quality or video
   bitrate, and the minimum acceptable savings.
4. Choose an archive folder outside iCloud Drive with enough room for full originals and compressed
   files. An external drive can be useful. The default is
   `~/Movies/Photo Compressor Backups`.
5. Enable **Replace originals in Photos**, then click **Compress & replace**. The app downloads and archives each original,
   encodes a smaller HEVC copy, validates it, imports it, and restores supported
   library metadata. After the batch, macOS asks you to confirm deletion of
   successfully replaced originals.

Replacement is initially off, so the first batch retains both versions in Photos.
Turn **Replace originals in Photos** off whenever you want to trial a batch while retaining both
versions in Photos. **History** shows the archive locations and allows playback
of compressed files. A focused video with an available output also has an
Original/Compressed preview switch. Processed items are hidden by default; use
the list's filter menu to show them again.

For a review-first workflow, leave replacement off, compress the batch, and play
the smaller copies. Then use **Delete this original from Photos** in the preview,
or choose the originals to delete in **History**. No manual reimport or searching
for matching originals in Photos is needed.

Right-click a video and choose **Show in Photos** to reveal that specific item
in the Photos app. The preview also has a Show in Photos button; when viewing a
compressed copy, it reveals that copy. History offers **Show copy in Photos**
and context-menu links for retained originals and imported replacements.
Local videos offer **Show in Finder** instead.

The preview summarizes what changes before compression. **What changes** shows
source and target pixel dimensions, frame-rate changes, the selected video
bitrate, the quality tradeoff, and what is preserved. Unknown source frame rate
and HDR are labeled until the original is inspected. Selecting a video first
tries to inspect its original with iCloud access disabled. If the original is
not available locally, use **Inspect original…**; a confirmation asks before an
iCloud download is allowed, and the inspection can be cancelled. Playback may
use a streamed preview independently of original inspection.

**Original frame rate** is the default. On the first launch of 0.1.5, existing
settings also switch to Original once; subsequent explicit frame-rate choices
are remembered. Photos-recognized Slo-mo videos are excluded entirely, using
both the high-frame-rate subtype and the Slo-mo smart album. The list shows a
protected Slo-mo count and offers a way to show these normally hidden items.
Unflagged high-frame-rate footage keeps its nominal frame rate unless you
explicitly select a lower cap. An original with an unusable frame rate is kept
rather than encoded with a guessed rate.

HEVC re-encoding remains
lossy even at Original resolution/frame rate. Finished copies show their actual
file size and saved encoding settings, so later control changes do not alter
the explanation of an already-created copy.

Switching Original/Compressed retains the playhead position, playback state,
and mute setting. Sorting, search, size filters, and visibility filters are
remembered, and a library refresh retains valid selections and the focused
preview. A completion summary shows ready, skipped, failed, interrupted, and
unstarted items, plus measured savings in completed copies.

The archive panel shows available disk space and estimated space for the
selection, including working space. Estimates can increase once original
metadata and unknown file sizes are inspected. Compression prevents automatic
idle sleep while a batch is running; the assertion is released when it finishes
or stops. This does not prevent manual sleep or closing a laptop's lid.

## Control and safeguards

- Resolution and frame-rate settings are caps. Smaller/slower sources are not
  upscaled or converted to a higher frame rate.
- Initial output estimates use duration, target video bitrate, and an audio
  allowance. Actual VBR output varies with content. The finished file must meet
  the configured minimum savings before it is imported or replaces anything.
- The encoder checks output dimensions, duration, audio-track count, and HDR
  properties, then decodes the output video completely. Audio is copied without
  re-encoding and its complete packet data is compared using SHA-256 hashes.
- Photos capture dates, location, favorites, hidden status, and regular album
  membership (not manual album order) are restored and checked. Titles, captions, and keywords are
  restored through Photos automation and read back for verification.
- A deletion candidate needs a confirmed imported copy, verified metadata, and
  both archived files still present with their expected sizes. Changed source
  assets are kept. Any download, encoding, validation, import, metadata, or
  journal failure retains the original.
- Downloads/encoding run sequentially to limit temporary disk use. Photos may
  retain its own downloaded original as well as the independent archive.
- **Stop safely** prevents batch deletion. The current iCloud resource download
  may finish first. Verified, prepared replacements can be deleted later from
  History after reconnecting the library.
- Operations are recorded atomically in
  `~/Library/Application Support/PhotoCompressor/operations.json`. A corrupt
  journal disables compression rather than silently discarding history.
- Local originals and outputs are never removed automatically. Keep an
  independent archive until the smaller copy has synchronized to your other
  devices and you have checked it.

## Current boundaries

This is an initial locally built application. Automated tests cover packaging and
the required Photos/Automation purpose strings, as well as
actual HEVC encoding, portrait downscaling, frame-rate caps, exact audio
packet preservation, generated HLG HDR, cancellation, and journal recovery.
Native UI testing on macOS 15.8.2 (Intel) covers library connection, a generated
video's compression and automatic import, favorite/date/album preservation,
compressed playback, history persistence after restart, deletion from History,
and automatic **Compress & replace** after native macOS confirmation. Two
generated test originals were each reduced from 351 KB to 116 KB; the three
existing photos remained present and both original archives were verified.
Start with a backed-up test clip and replacement disabled before using replacement.

- Ordinary, unedited single-track video is supported. Edited videos, slow-motion,
  cinematic video, spatial video, shared-album items, and unsupported audio codecs are
  skipped with a reason. Hidden assets are not listed.
- HDR HLG/PQ is encoded as 10-bit HEVC and checked for an HDR transfer function.
  Dolby Vision dynamic metadata may be regenerated; exact Dolby Vision fidelity
  has not been verified with real iPhone HDR footage.
- Original frame rate uses the source's nominal rate. Exact timing preservation
  for variable-frame-rate footage has not been verified. Photos-recognized
  Slo-mo is excluded rather than relying on nominal FPS to preserve its timing.
- Apple Silicon uses native hardware encoding when available. Intel builds use
  the native software HEVC encoder to avoid hardware initialization failures on
  older Macs.
- People/face tags, shared-album interactions, and editable adjustment history
  cannot be transferred to a new asset.
- The app cannot force or independently prove completion of iCloud uploads.
  A full account may block replacement upload until deletion frees space. Local
  archives protect both versions during that interval.
- Deletion still requires the native macOS confirmation. The app never empties
  Recently Deleted. Apple warns that over-quota accounts may have no recovery
  period, which is why an independent archive is required.
- A restart retains operation history, but does not automatically resume encoding
  or delete anything. Inspect interrupted operations in History before retrying.

## Development

```sh
swift build
swift test
```

`CompressionCore` contains planning, HEVC encoding/validation, and the persistent
operation journal. `PhotoCompressor` contains SwiftUI, PhotoKit, and Photos
automation. The app bundles its Photos/Automation usage descriptions and
entitlements; run the `.app` for library access rather than the bare SwiftPM
executable.

The original alternatives research is in [RESEARCH.md](RESEARCH.md).
Native UI test progress and known verification limits are in
[docs/TESTING.md](docs/TESTING.md).
The app icon source and generation prompt are documented in [docs/ICON.md](docs/ICON.md).

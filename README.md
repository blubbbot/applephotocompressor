# Photo Compressor

A native macOS app for browsing large Apple Photos videos, previewing them,
estimating savings, and compressing/replacing a selected batch. No subscription,
server, iCloud login, FFmpeg, or Python installation is required.

Videos remain the default and main workflow. The **Videos / Photos** selector
also supports ordinary JPEG/HEIC photos and supported Live Photos.

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

Requires macOS 14 or newer and Xcode with Swift 5.9 or newer. The build uses
Xcode's `actool` to compile the standard macOS app icon asset catalog.

```sh
./scripts/build-app.sh
open "dist/Photo Compressor.app"
```

The build script checks the required privacy purpose strings, compiles the app
icon as an asset catalog plus an ICNS fallback, creates a locally
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
5. Leave **Replace originals in Photos** off for a review-first workflow, or enable it and click **Compress & replace**. The app downloads and archives each original,
   encodes a smaller HEVC copy, validates it, imports it, and restores supported
   library metadata. After the batch, macOS asks you to confirm deletion of
   successfully replaced originals.

Replacement is initially off, so the first batch retains both versions in Photos.
Turn **Replace originals in Photos** off whenever you want to trial a batch while retaining both
versions in Photos. The separate **Review** tab shows compressed videos awaiting
a decision, with a persistent count in the tab. It never opens as a modal after
a batch. **History** shows the archive locations and allows playback
of compressed files. A focused video with an available output also has an
Original/Compressed preview switch. Processed items are hidden by default; use
the list's filter menu to show them again.

For a review-first workflow, leave replacement off, compress the batch, and open
**Review**. Choose a video to compare its archived original and compressed file
side by side. Playback, seeking, and frame stepping are linked; choose which
version's audio to hear. Both previews use the local archives, without requesting
another iCloud download. Source and output dimensions, frame rates, file sizes,
and the encoding tradeoffs appear with the comparison.

Library and Review use matching native sidebar lists with compact thumbnail
rows, single-line filenames (hover for the full name), and standard selection
and keyboard navigation. In Library, row selection opens the preview; the
separate checkbox chooses whether to include that video in a compression batch.

In Review, **Hide list / Show list** (Control–Command–S) frees horizontal space;
that visibility preference is remembered. **Expand previews** also hides the
longer details and idle footer, sizes the comparison to the available window,
and moves accept/revert actions into the top bar. **Restore layout** returns to
the previous list visibility and full details. Previous/Next controls and the
To review/All filter remain accessible while the list is hidden. Layout changes
keep the current review and loaded players; error notices remain visible in
expanded mode.

Controls become available when both AVPlayers are ready. Review playback uses
AVPlayer's host-clock synchronization with automatic stall waiting disabled,
as required by that API. Interrupted or timed-out seeks show a visible error
and a retry action. Changing the reviewed item cancels pending seeks.

- **Accept & delete original** keeps the compressed Photos copy and requests
  native macOS confirmation before removing the original.
- **Revert compression** keeps the original and requests confirmation to remove
  only the compressed Photos copy.
- If automatic replacement already removed the original, **Accept compressed
  version** only records approval. Reverting first imports the full archived
  original, restores and verifies supported metadata, then requests deletion of
  the compressed copy. The restored original is a new Photos asset, with a
  unique restoration marker in its resource filename; People tags, the original
  asset identifier, and editable history cannot be restored.

Decisions survive restarts. **To review** shows undecided copies; **All** also
shows accepted and reverted work. Accepted copies can still be reverted while
their archives and required Photos assets are available. Reversion checkpoints
and the unique resource name prevent a retry from importing another original
after an interrupted restoration. Changed compressed assets are retained for
manual inspection. Both archived files are always kept. For local-file mode,
accept/revert records a decision and leaves all files in place.

Photos must be connected before a review action changes its library; archived
previews work without connecting. Missing or changed archives block deletion.
History also retains its batch deletion action. No manual reimport or searching
for matching originals in Photos is needed for the normal review workflow.

### Savings and navigation

Lists show savings as a prominent green badge, with both bytes and percentage.
Estimates retain their `~` marker; finished-copy badges use measured resource
totals. New inspection results update the numbers immediately, but sorting waits
for two seconds without a new preview selection or measurement. Continuing with
the arrow keys postpones that reorder, so the next row remains the next row in
the order you were browsing. An explicit sort/settings change or the list's
update-order button applies the new ordering immediately. Ties use stable IDs.

### iCloud Shared Photo Library

**Regular albums, Shared Albums, and iCloud Shared Photo Library are different.**
The public SDK used by this macOS 14+ app exposes Shared Albums through
`PHAssetSourceType.typeCloudShared`; it does not provide a supported membership
property or a move-to-Shared-Library operation for iCloud Shared Photo Library.
The Photos scripting dictionary likewise provides neither operation.

**Optional read-only database detection** adds advisory **Shared / Personal /
Unknown** labels to Photos items in both media modes and to Review. Under
**After compression**, enable **Detect Shared Library (read-only)** and choose
**the same System Photo Library** connected through PhotoKit. You can also use
**File → Choose Library for Sharing Detection…**. The selection is retained with
a read-only security-scoped bookmark; turning the option off stops database
inspection. No media downloads are needed for this check.

This native SQLite reader uses the participation-state approach in
[OSXPhotos](https://github.com/RhetTbull/osxphotos/blob/main/osxphotos/photosdb/_photosdb_process_shared_library.py).
The field interpretation is undocumented and heuristic. Supported database
model versions are 16320–19999 (Photos 8 through 11); future/older models,
missing or null fields, inaccessible databases, and ambiguous or unmatched
assets stay **Unknown**. Each result matches the public asset UUID, original
resource filename, media type, and available creation date. Reads use a consistent
SQLite transaction with `SQLITE_OPEN_READONLY` and `query_only`; no SQL writes or
private PhotoKit selectors are used. SQLite may update its WAL shared-memory
reader bookkeeping; the app never changes Photos database contents.

Choose the current library, not a backup: a copied or stale database can still
contain matching asset IDs. Labels are advisory, expire without refresh, and do
not prove the active library identity or iCloud synchronization. Metadata refreshes
on connection, during review, periodically while idle, and before compression or
automatic deletion. Hover over a label for the observation time and detail.

**Detected shared originals are retained for Review even when automatic
replacement is enabled.** The source observation is saved in the operation
history. Review compares that result with the current copy's result and offers
**Show copy in Photos**. Moving or restoring Shared Library placement still needs
**Photos → Image → Move to Shared Library** before deleting the shared source.
The same check applies to originals restored from an archive. See
[Apple's instructions](https://support.apple.com/guide/photos/pht9a3599aac/mac).

Automatic replacement still asks once per app session whether to keep copies
for review or proceed for other items; Unknown may include shared originals.
Shared Album items remain protected.
When a tracked replacement's modification date changes, its original resources
are compared against the archive with SHA-256 and its supported metadata is
rechecked before removal. This allows an unchanged copy moved in Photos to be
revalidated without treating an arbitrary edit as safe. It does not certify
shared membership or iCloud synchronization.

### Photos and Live Photos

Photo compression makes sense particularly for large JPEGs and for deliberate
downscaling. Already-efficient HEIC images may offer little saving at an
acceptable visual quality. Encoding remains lossy; the quality percentage is an
encoder control, not a measurement of fidelity.

Choose **Photos** in the header, connect the same library, and select ordinary
JPEG/HEIC photos. Set photo quality, maximum long edge, and minimum **measured**
savings. Photo settings, filters, and replacement preference are separate from
video settings. Photos initially uses review-first replacement; the app always
starts in Videos. Local JPEG/HEIC files can also be opened; local Live Photo
pairs must be handled through the Photos library, rather than guessed from
neighboring files.

- Ordinary SDR photos are encoded as HEIC using native Image I/O. Dimensions,
  orientation, and decodability are checked. Supported library date, location,
  favorites, regular albums, title, caption, and keywords use the same verified
  transfer workflow as videos.
- **Keep Live Photo is the default.** Both original image and original motion
  resources are archived. Only the still image is re-encoded; the motion file,
  sound, and timing are retained byte for byte. Public `PHLivePhoto` validation
  must accept both the original and compressed pairs before import, and the
  imported asset must still report Live Photo status.
- **Convert Live Photos to stills** is an explicit optional setting. Its loss of
  motion and sound is labeled in settings, the selection footer, and Review.
  The full original pair is still archived so Revert can restore a Live Photo.
- Image **and** motion bytes count toward minimum savings. A result below the
  threshold is not imported. Initial photo estimates are rough; Live motion
  size is measured only after the original resources are archived.
- Review compares both image versions and offers Live Photo playback when
  applicable. It supports accept/delete and archive-backed revert for photos
  as well as videos. New restored assets do not retain their old Photos IDs,
  People tags, editable history, or automatically restored shared placement.
- RAW/RAW+JPEG, PNG/other formats, animated or spatial photos, bursts, edited
  photos, HDR/gain-map, high-bit-depth, transparency, and depth/Portrait
  resources are protected. This release does not silently flatten those extras.

Native API references: [creating assets from resources](https://developer.apple.com/documentation/photos/phassetcreationrequest),
[Live Photo resource validation](https://developer.apple.com/documentation/photos/phlivephoto/request(withresourcefileurls:placeholderimage:targetsize:contentmode:resulthandler:)),
[image auxiliary data](https://developer.apple.com/documentation/imageio/cgimagesourcecopyauxiliarydatainfoatindex(_:_:_:)).

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
  Review after reconnecting the library.
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
Focused review tests cover legacy journal compatibility, acceptance eligibility,
and persistent restoration checkpoints and decisions. Native UI testing on
macOS 15.8.2 (Intel) from version 0.1.3 covers library connection, a generated
video's compression and automatic import, favorite/date/album preservation,
compressed playback, history persistence after restart, deletion from History,
and automatic **Compress & replace** after native macOS confirmation. Two
generated test originals were each reduced from 351 KB to 116 KB; the three
existing photos remained present and both original archives were verified.
The 0.1.6 review playback failure was reproduced in the UI and confirmed in the
app log as AVPlayer's invalid synchronized-start configuration. Version 0.1.7
adds four real-player regression tests for timeline movement, seeking/stepping,
audio selection, missing files, and cancellation/reload. They passed on Intel.
The corrected 0.1.7 UI, archive restoration, and Dock folder-stack icon have not
had a live verification; the computer-use bridge failed and further UI testing
was skipped at the user's request.
Version 0.2.0 passed 29 automated tests, including JPEG/HEIC encoding,
orientation/EXIF/GPS preservation, resizing, archive manifests, deferred ordering,
and a synthetic Live Photo that remained valid after re-encoding its still image
while its movie bytes remained unchanged. New photo-library import/deletion,
reversion, real iPhone Live Photos/HDR, manual Shared Library moves, and the new
UI have not had a live library test. The resource validator fails closed when a
pair cannot be reconstructed; earlier video UI tests do not verify these paths.
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

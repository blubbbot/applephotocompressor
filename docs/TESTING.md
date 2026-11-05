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

## 0.1.5 changes — 4 November 2026

- Local-first original metadata inspection when a video is focused. Network
  access is explicitly disabled for that first PhotoKit request.
- On-demand confirmation before enabling an iCloud download for inspection,
  with progress, cancellation, source-change checks, and original FPS/HDR
  displayed after inspection. Photos' network-access-required error is handled
  as a download-needed state.
- Original frame rate is the default, with a one-time migration for existing
  settings. Nominal frame rate must be finite and positive before encoding.
- Slo-mo protection uses both the media subtype and the Slo-mo smart album.
  Protected items are labeled and remain excluded from selection. The source's
  protection status is rechecked before archiving.
- Original/Compressed switching preserves position, playback state, and mute;
  new-video focus resets the comparison position.
- Sorting/search/filters persist; refresh retains valid selections, measured
  metadata for unchanged assets, and the focused preview.
- Batch completion summaries distinguish completed, skipped, failed,
  interrupted, and unstarted work, plus measured savings and replaced originals.
- Scoped automatic-idle-sleep prevention during batches and background archive
  disk-space reporting, including estimates for the current selection.

Validation for this release is compilation and package verification only. The
app has not been launched, and automated/native UI tests have not been rerun.
Cloud-only inspection, cancellation races, Slo-mo classification with real
footage, and the new UI workflows remain unverified in a live library. Earlier
0.1.3 results do not establish these new behaviors.

## 0.1.6 changes — 4 November 2026

- Separate Library/Review navigation, with a persistent undecided-copy count.
  Batches leave results in the Review tab without opening it or a modal.
- Side-by-side local archive playback with linked play/pause, seeking, frame
  stepping, drift correction, and one selected audio source. Both sides show
  measured dimensions, nominal FPS, and file size.
- Accept requests deletion only for a retained original that still passes all
  archive, metadata, and asset-change checks. Already-replaced originals require
  no further deletion; acceptance only records the review decision.
- Revert removes the compressed Photos copy after confirming the original is
  present. For an already-replaced original, it first restores the archived file,
  restores/checks supported library metadata, and journals the restored asset ID
  and verification checkpoint before requesting compressed-copy deletion.
- A unique restoration resource filename recovers an import completed just
  before a journal write or app interruption. Restored assets receive new Photos
  identifiers. Existing People tags and editable history are not recovered.
- Changed compressed assets and missing/changed archives block automatic removal.
  A cancelled removal retains the videos. Local-file reviews only record a
  decision. Both archived files always remain on disk.
- Review decisions and optional metadata/checkpoint fields are backward
  compatible with older operation journals. Reverted work stays in All and
  History while its source can be compressed again.
- The app explicitly loads the bundled ICNS and assigns it to the running
  application's Dock tile at launch, and uses that same image in the header.
- Original-deletion history errors are distinguished from actual Photos
  deletion failures, so a later journal error cannot be reported as cancellation.

Validation: `swift build` passed, and all five focused `ReviewJournalTests`
passed. These check old-journal compatibility, auto-replaced reviews, deletion
eligibility, local minimum-savings behavior, and durable restoration checkpoints
and decisions. The universal release build and extracted package verification
are also checked. No app launch, Photos mutation, UI run, or encoder test run
was performed for this release. Linked playback, native accept/revert dialogs,
archive restoration (including interrupted restores), and the visible Dock icon
remain unverified at runtime.

## 0.1.7 fixes — 5 November 2026

The 0.1.6 failure was reproduced through the computer-use bridge with the two
existing generated test-video archives. Clicking Play left the controls
unchanged. The app's log showed `NSInvalidArgumentException`: AVPlayer cannot
service `setRate:time:atHostTime:` while `automaticallyWaitsToMinimizeStalling`
is enabled. The exception also left the seek task pending, so later actions
could appear unresponsive.

Both review players now disable that automatic waiting before synchronized
playback. Controls wait for actual player readiness, Play avoids an unnecessary
seek when both players are already aligned, and pending seeks have cancellation
and timeout handling with visible errors/retry. Missing files and native player
failures are reported in the review interface.

Four focused real-AVPlayer tests passed on macOS 15.8.2 Intel:

- Play advances both timelines; Stop pauses both; audio selection mutes the
  appropriate player. The test also checks the host-clock API precondition.
- Seeking moves both actual player timelines, and frame stepping advances both.
- A missing compressed file disables comparison and reports an error.
- Stop/reload cancels pending playback and does not restart a new comparison.

The icon is now compiled by `actool` into a standard macOS app-icon asset
catalog plus ICNS fallback. Build metadata must match the compiler's icon
metadata. The app updates only its own Launch Services registration on launch,
and the package build updates the root bundle's modification date.

The updated UI could not be checked on screen: the bridge subsequently failed
with `Sky Computer Use native pipe startup failed`. The user requested
continuing without further UI testing. No substitute UI automation was used;
no Photos connection, import, compression, acceptance, or deletion was performed
during this fix. The fixed playback UI and the visible Dock folder-stack icon
remain unverified through the bridge. Universal release/package checks and
compiled-icon asset checks are recorded for this build.

## 0.1.8 layout changes

- Library and Review now use full-width native sidebar Lists with the same
  compact row layout, small thumbnails, and single-line middle-truncated names.
  Hovering shows the full filename. Removed the Review List's outer inset and
  the Library's custom row cards and preview buttons.
- Library row selection binds to preview focus, including keyboard selection;
  a separate native checkbox still controls batch membership.
- Review adds a remembered Show list/Hide list preference, with a
  Control–Command–S shortcut. Previous/Next and an item count remain available
  without the list, as does the To review/All filter.
- Expand previews hides the list, longer details, and idle footer, uses the
  available comparison height, and puts review actions in the top bar. Restore
  layout restores the previous sidebar preference. A running operation still
  shows its footer/status; errors remain visible in the comparison.
- The player view hierarchy and loading task identity do not depend on sidebar
  visibility or expanded mode, so changing the layout does not request new
  players or intentionally reset the playhead.

Validation for this release is compilation of both architectures and extracted
package verification. No new automated tests were added for these reversible
view changes, and no app launch or native UI/Photos test was performed. The
earlier bridge failure and request to proceed without further UI testing were
honored. Native row interaction, expanded layout at different window sizes,
and playback continuity during layout changes remain unverified on screen.

## 0.2.0 — savings, ordering, sharing hints, and Photos

Savings now have a green bytes/percentage badge. Inspection numbers update
immediately; a stable list-order snapshot delays sorting until two seconds after
the latest navigation or measurement. Explicit sort/settings changes apply
immediately. Tests cover unchanged keyboard neighbors while updates are pending,
stable ties/dataset changes, and added/removed rows.

Shared Library research checked the public Photos SDK and the Photos scripting
dictionary. Shared Albums are detectable and remain protected, but neither
interface supplies iCloud Shared Photo Library membership or a supported move
operation. Review and replacement settings explain that limitation and link to
manual re-sharing in Photos. Automatic replacement asks once per session whether
to proceed or keep originals for review. Modified tracked replacements require
resource hash and supported metadata revalidation; the Shared Library move
itself and that live-resource revalidation have not been tested in a library.

The header selects Videos (default on launch) or Photos. Photos has separate
quality, long-edge, minimum-savings, filter, and replacement preferences;
replacement starts off. Ordinary single-image JPEG/HEIC SDR sources use Image I/O
HEIC encoding. Resource-level HDR/gain-map/depth checks and catalog protection
retain unsupported, edited, burst, RAW, and other compound assets.

Live Photos preserve their original movie by default. The still and movie are
archived separately; both resource totals count toward savings. Both the
original and recompressed pair must load successfully through `PHLivePhoto`
before import. Imported Live status and supported metadata are verified. Explicit
still conversion retains the complete original pair in the archive. Review and
revert know which resources belong to each version, including restoring Live
status after a still conversion.

`swift test` passed **29 tests** on Intel, including:

- JPEG → HEIC with orientation, EXIF capture time, and GPS retained.
- HEIC → HEIC re-encoding; PNG rejection; resized orientation; no upscaling;
  cancellation and no overwriting existing files.
- Live Photo archive totals, required motion manifest, still-conversion recovery
  requirements, backward-compatible journal fields, and stable list ordering.
- A generated JPEG/QuickTime Live Photo pair that loaded before and after HEIC
  re-encoding of its still. The original motion bytes remained identical.
- Existing real HEVC/HDR/audio/portrait encoding, player playback/cancellation,
  operation-journal, and packaging regressions.

No user-library asset was imported, compressed, edited, or deleted by these
tests. No app UI was launched. Real iPhone Live Photos, Photos import/subtype
readback, photo acceptance/reversion, shared membership/manual moves, cloud-only
photo resources, and the new UI remain unverified live. The earlier user request
to proceed without computer-use testing was retained. Release validation also
checks both architectures, extracted signature/privacy/icon resources, and the
public download checksum.

### 0.2.1 follow-up

Automatic deletion rechecks the batch cancellation flag between candidates and
after any asynchronous replacement revalidation, before asking Photos to delete.
This keeps Stop safely effective if it is requested during a copy-resource
download. Explicit accept/history deletion remains a separate user action.
The follow-up is compiled and package-verified; no live deletion test was run.

### 0.2.2 — optional read-only Shared Library detection

The app can inspect a user-selected `.photoslibrary/database/Photos.sqlite`
through SQLite's read-only open mode and a query-only read transaction. The
native implementation follows OSXPhotos' heuristic interpretation of
`ZACTIVELIBRARYSCOPEPARTICIPATIONSTATE`, with an explicit model-version range
(16320–19999), schema checks, and public PhotoKit UUID/resource filename/media
type/creation-date matching. It does not use private PhotoKit selectors or write
Photos database contents. SQLite's normal WAL shared-memory reader bookkeeping
may still change. A cloned/stale library can match the same IDs; UI and README
make the user-selected current library and advisory nature explicit.

Optional setup retains a read-only security-scoped bookmark. Labels refresh on
connection, Review, periodically while idle, and before compression/automatic
deletion. Observations expire after two minutes. Unsupported schema, denied or
missing access, null/negative participation flags, trashed assets, duplicates,
and identity mismatches stay Unknown. Original observations persist in history.
A detected shared source is held for explicit Review even with automatic
replacement enabled. A failed refresh does not remove previously observed shared
evidence from the automatic-replacement hold. Shared Library moves remain manual.

`swift test` passed **35 tests** on Intel. The six new synthetic-database tests
cover positive/zero/null/negative flags, original resource names, case-insensitive
UUID matching, type/date/trash/duplicate mismatches, unknown models and changed
schemas, strict local-ID parsing, non-creation of missing databases, and journal
compatibility/persistence. The WAL test keeps a real SQLite writer open, verifies
that committed updates are visible, and confirms that reads leave the database
and WAL contents unchanged. Existing video, photo/Live Photo, playback, ordering,
archive/journal, and package regressions also pass.

No actual Photos database was opened by these tests. No app UI or permission
panel was launched, and no user-library asset was read, changed, imported, or
deleted. Real Shared Library membership/resharing and the new UI remain untested
live, consistent with the user's instruction to proceed without computer-use
verification. Universal-package signature, privacy strings, icon resources,
architectures, and the published ZIP checksum are checked separately.

### 0.2.3 — automatic shared replacements and sharing filters

Replace originals now applies to shared items using the same import, metadata,
archive, cancellation, and native deletion-confirmation checks as other items.
The special shared-original hold and once-per-session Shared Library approval
have been removed. Source sharing observations remain in the journal, including
when a fresh pre-deletion read detects sharing that was unknown at compression.
A transient metadata failure retains any previous shared evidence for Review;
sharing hints do not determine deletion eligibility.

Review uses the saved source status where known, independently of the current
replacement's placement. After automatic deletion it explains that the original
has already been replaced, preserves the archive information, and offers
Show copy to re-share… with Photos → Image → Move to Shared Library instructions.
Refresh detects the copy's new state when available. Reverted originals use the
restored item's identifier rather than revealing the removed compressed copy.

Library has All libraries / Shared Library / Personal Library / Unknown filters.
Review has All libraries / Shared originals / Personal originals / Unknown
originals / Needs re-sharing. The latter includes shared originals with a
Personal or Unknown replacement/restored original, automatically selects All
copies (so accepted items remain findable), and clears an item after a fresh
Shared result. It does not certify synchronization. Filters are independent and
remembered. Review filters remain accessible with the sidebar hidden; explicit
review navigation clears an excluding filter. Local-file review is included in
All libraries and does not masquerade as a Photos placement result.

All **39 automated tests** passed on Intel. Four new workflow tests exercise
replacement/deletion/acceptance with preserved source observations, re-sharing
queue transitions, restored-original reveal targets, and Unknown-versus-Personal
filtering. Existing synthetic SQLite, JPEG/HEIC/Live Photo, video/HDR/audio,
playback, journal/archive, ordering, and privacy regressions remain green.
The final targeted run rechecks the 15 workflow, database, and review-journal
tests after UI/dead-code cleanup. Universal builds and extracted ZIP checks cover
both architectures, signatures, privacy descriptions, icons, and SQLite linkage.
No real Photos library/database or app UI was opened, and no user-library asset
was changed. Live shared deletion, menu/filter layout, and manual re-sharing
remain untested, following the user's request to continue without UI testing.

### 0.2.4 — photo types, responsive indexing, and compact status controls

Library and Review have independent All photos / Live Photos / Panoramas filters
in Photos mode. Catalog classification uses PhotoKit's photoLive/photoPanorama
subtypes without a media download. Original panorama flags are stored as an
optional journal field. Review still classifies Live-to-still conversions by
source kind. Older records without a panorama flag cannot be classified as
panoramas retrospectively after their source is gone.

Code inspection identified main-actor PhotoKit resource enumeration during whole
library sharing refresh, repeated processed-ID set construction inside the item
filter, and repeated full-library ranking/sorting during view evaluation. The
new list builder takes value snapshots, computes each sort key once, builds
lookup sets once, and filters/orders on a cancellable detached task. The model
publishes one cached visible array guarded by a revision token. Measurements
retain pending stable order until the existing two-second idle delay commits;
filters retain the ranks of hidden items. Selection actions wait for the new
list snapshot rather than selecting an obsolete filtered result.

Sharing refresh reuses names/type/date already indexed for catalog assets;
missing history identities and database inspection run off the UI actor. Cached
fact reconciliation is part of background PhotoKit enumeration, with a per-item
autorelease pool and cancellation checks. Mode changes cancel the prior catalog
job, clear its old list, and reject late load/size results. The mode selector is
usable during catalog and size loading. File loading also uses the same revision
guards. A shared two-minute size cache coalesces concurrent/rapid mode switches
into one Photos scripting pass; explicit library Refresh requests fresh sizes.

Expanded Review replaces the large sharing banner with a compact toolbar menu
containing source/current status, reveal, manual sharing instructions, refresh,
and the Apple help link. Normal review keeps the detailed banner. Icon layout
controls and shorter compact review actions leave room for the previews.

A single-line free-space label fits the existing footer HStack, or the expanded
Review toolbar. It reads archive and Mac temporary-working volume capacity on
background tasks, every ten seconds including while busy. It warns orange below
10 GB or when the selection estimate exceeds archive capacity, and red below
2 GB. Its tooltip gives both capacities, the selection's archive/working estimate,
and unknown-size limitations. A missing archive drive is shown as unavailable;
no extra status row or warning modal was introduced. Existing per-item capacity
checks and archive/import/deletion safeguards remain in force.

All **48 automated tests** passed on Intel, including nine new cases: subtype
selection and source/journal compatibility, warning thresholds and insufficient
selection capacity, real concurrent size-pass coalescing/refresh/retry, cancelled
snapshot rejection, combined sharing/type filters, stable order across filtering
and measurement, and a 30,000-item off-main catalog build. The complete large
catalog test took about 0.13 seconds here; this is a synthetic list benchmark,
not a live Photos/PhotoKit loading measurement. A final focused run passed all
nine new tests after file-load cancellation and enumeration cleanup.

No real Photos library/database or app UI was opened. Large live-library load
latency, the native subtype filters, expanded toolbar layout, and live low-disk
rendering remain unverified. Universal-build and extracted ZIP checks validate
both architectures, privacy descriptions, signature, icon resources, version,
and SQLite linkage; public download verification compares the SHA-256 checksum.

### 0.2.5 — Live Photo motion previews and selectable photo types

The Library detail preview now requests a native PHLivePhoto representation of
the selected Live Photo, with its current Photos appearance. Play motion / Stop
motion and Mute control the native view. It does not auto-play. Requests may
fetch preview resources from iCloud; progress, Cancel, and Retry are provided.
The view reloads when the selected asset's modification date changes. Failed
motion requests attempt a still-image fallback without hiding the motion error.
Leaving the view cancels its request and stops playback.

PhotoKit requests use a locked, exactly-once continuation bridge. It handles
cancellation before attachment, cancellation before a request ID is returned,
synchronous completion, repeated/late callbacks, and completion/cancel races.
Final errors are handled before degraded-result filtering. The same cancellation
bridge now protects archive-based Live Photo pairing requests and library still
previews. No PhotoKit changes/imports/deletions are performed by preview loading.
Native playback delegates update the Library play/stop state; dismantling the
view clears callbacks and stops playback.

The photo-types menu lets Library and Review independently select Normal photos,
Live Photos, and Panoramas. Normal excludes both special subtypes; selected
categories are combined, and an empty selection is allowed. All and Normal-only
shortcuts are available. Old all/livePhotos/panoramas preferences migrate to the
new stored selection. Original type still governs Review after Live-to-still
conversion. Old Review entries without a panorama flag are included by All but
are not incorrectly labelled Normal when their panorama status is unknown.

Review defaults to compressed audio for videos and paired Live Photos. Original
and Muted remain selectable. A compressed still has no audio; its original Live
motion stays muted by default until Original audio is explicitly selected.

The full **55-test suite** passed on Intel. New checks cover saved-filter
migration, mixed/empty selections, Normal-only exclusion and unknown legacy
metadata, catalog filtering, and callback completion/cancellation races. The
existing AVPlayer playback test now checks compressed-default mute state and
switching back to original/muted. Native PHLivePhoto validation of a generated
still/movie pair still passes before and after HEIC re-encoding, with unchanged
motion bytes. Focused preview/filter/player/pairing checks also pass.

No app UI or actual Photos library/database was opened. Actual Library motion
playback, cloud fetching, interactive native playback controls, and the menu
layout remain unverified live, following the prior instruction to proceed
without computer-use testing. Universal-build and extracted-package checks
validate signatures, privacy strings, icons, version, architectures, SQLite
linkage, and the public download checksum.

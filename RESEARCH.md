# Compressing an iCloud Photos video library on macOS

Research checked on 3 November 2026. This is a review of current product listings,
documentation, repository contents, and selected source files. No applications
were installed and no personal Photos library was accessed or modified.

Follow-up: a native application is now implemented in this project; see
[README.md](README.md). It uses PhotoKit, AVFoundation, and the installed Photos
scripting dictionary's `size` property, with no Python or FFmpeg dependency.

## Recommendation

Try **Cloud Media Shrinker** on a few backed-up videos first if free software is
the main requirement. If source availability is essential, use **HandBrake** for
compression and **OSXPhotos** to help select/export media. A polished, established,
unlimited, open-source application covering the complete Photos replacement
workflow did not emerge from this search.

Building a macOS app is feasible without developing an encoder. Its useful
contribution would be library integration, metadata preservation, review, and
reliable recovery after interrupted work.

## Existing applications

### Cloud Media Shrinker — the closest free integrated option

- The current [US Mac App Store listing](https://apps.apple.com/us/app/cloud-media-shrinker/id6824383256?mt=12)
  says **Free**, requires macOS 13+, and does not list in-app purchases.
- The developer advertises size-based browsing, configurable video compression,
  HDR output, local processing, and optional deletion of originals.
- Its [current repository](https://github.com/danielyaa5/photo-review) contains
  product information and demos only; it explicitly says the source is private.
  Search snippets still describe an older publicly buildable version.
- The store has insufficient reviews for an overview. Treat it as a candidate to
  evaluate, with metadata and output quality checked on representative clips.

### HandBrake — the established open-source option

[HandBrake](https://handbrake.fr/) is free, open source, and available for macOS.
It handles encoding rather than managing the Photos library. The workflow is:
export selected videos, compress them, import the smaller files, review them,
and delete the corresponding originals.

Its [HDR documentation](https://handbrake.fr/docs/en/latest/technical/hdr.html)
documents Dolby Vision support for selected 10-bit encoders, including Apple
VideoToolbox HEVC, and supported profiles including 8.4. Its
[metadata option](https://handbrake.fr/docs/en/latest/advanced/metadata-passthru.html)
passes common embedded metadata; it is not a complete transfer of Photos library
information. [Version 1.10 release notes](https://github.com/HandBrake/HandBrake/releases/tag/1.10.0)
also document improved creation-date and location passthrough.

### Kompakt — a simpler open-source file compressor

[Kompakt](https://github.com/edinabazi/Kompakt) has an MIT-licensed native macOS
codebase and downloadable releases. It provides drag-and-drop file compression
and conversion, rather than an integrated Photos replacement workflow. Its
queue and process-running code could be relevant to a new application. Its
[third-party notices](https://github.com/edinabazi/Kompakt/blob/main/THIRD_PARTY_NOTICES.md)
show that it bundles FFmpeg and other helper tools.

### Clop — less suitable for this particular free workflow

[Clop's repository](https://github.com/FuzzyIdeas/Clop) lists five optimizations
per session for several free features. Public code is GPL-3.0, but the README
says further development continues privately. It is not an unlimited free Photos
library compressor.

## Automation projects and reusable components

### iPhone-Video-Compressor

[KisanThapa/iPhone-Video-Compressor](https://github.com/KisanThapa/iPhone-Video-Compressor)
is MIT licensed. Despite the name, it runs on macOS: Python/PyObjC invokes
AVFoundation, ExifTool copies selected dates/GPS fields, and ffprobe inspects
outputs. It supports resolution/frame-rate caps and optional Photos import.

Inspection of [the implementation](https://github.com/KisanThapa/iPhone-Video-Compressor/blob/main/compress_iphone_videos.py)
found checks for dimensions, timing, duration, and Dolby Vision 8.4 properties.
It does not check audio integrity or verify all copied metadata. The README says
its tests do not validate Dolby Vision or Photos import. Useful reusable code,
but not a complete library browser/download/replacement application.

### iCloud Photo Manager

[handcrafting-codes/icloud-photo-manager](https://github.com/handcrafting-codes/icloud-photo-manager)
attempts the full workflow using OSXPhotos, FFmpeg, AppleScript import, PhotoKit
deletion, and a local web interface. It has no published releases or explicit
license file in the inspected repository. Do not treat it as a licensed
open-source foundation without resolving that with the author.

Source inspection found that it checks whether an output is smaller, but has no
post-encode duration/audio/HDR checks. The caller also ignores the imported-item
count returned by its import function before scheduling original deletion.
Its job history is in memory. These are reasons to review and harden the workflow
before entrusting a library to it. Relevant files:
[compress.py](https://github.com/handcrafting-codes/icloud-photo-manager/blob/main/compress.py),
[jobs.py](https://github.com/handcrafting-codes/icloud-photo-manager/blob/main/jobs.py),
[photos_ops.py](https://github.com/handcrafting-codes/icloud-photo-manager/blob/main/photos_ops.py).

### OSXPhotos and PhotoScript

[OSXPhotos](https://github.com/RhetTbull/osxphotos) is an established MIT-licensed
Python package and CLI for querying/exporting Photos media and associated
metadata, including downloading missing originals. Its own documented example
finds large videos and adds them to an album:

```sh
osxphotos query --only-movies --min-size 200MB --add-to-album "Big Videos"
```

This changes album membership; it does not compress or delete files. OSXPhotos
reads Apple's internal database formats, so compatibility must be checked on the
target macOS version. Use it for querying/exporting rather than implementing
direct database writes.

[PhotoScript](https://github.com/RhetTbull/PhotoScript) is another MIT-licensed
package from the same author, wrapping Photos AppleScript automation. It is a
possible helper for library metadata that older PhotoKit APIs do not expose.

## Proposed implementation if the existing tools are insufficient

For a personal prototype, combine OSXPhotos for discovery/export, an existing
encoding backend, and PhotoKit/PhotoScript for import and metadata. For a friendly
standalone Mac app, use SwiftUI, PhotoKit, and AVFoundation.

1. **Discover:** list ordinary video assets and identify large candidates. Show
   size, duration, resolution, frame rate, and expected output settings.
2. **Stage:** download one selected original at a time, accounting for temporary
   disk space. Record its asset identifier and library metadata.
3. **Encode:** use hardware HEVC through AVFoundation/VideoToolbox. Offer an
   original-resolution setting and an optional 1080p/30-fps cap. Do not upscale
   clips or increase low source frame rates.
4. **Validate:** compare size and duration, check audio tracks and rotation,
   inspect HDR/color properties, and test decoding. Skip outputs with negligible
   savings. Unsupported special video types should be skipped explicitly.
5. **Import and review:** create a new Photos asset, restore supported metadata
   and ordinary album memberships, and show both versions for review.
6. **Delete:** offer original deletion only after confirmed import and review.
   Persist an original-to-replacement journal so a restart cannot cause duplicate
   work or deletion of the wrong asset. Let Photos handle synchronization.

Apple documents the underlying pieces in
[PhotoKit asset creation](https://developer.apple.com/documentation/photos/phassetcreationrequest),
[asset change requests](https://developer.apple.com/documentation/photos/phassetchangerequest),
and [HDR export with AVFoundation](https://developer.apple.com/videos/play/wwdc2020/10010/).
AVAssetExportSession is a simple starting point; AVAssetReader/Writer offers more
control over encoding settings.

For size discovery, the documented
[`PHAssetResource.dataSize`](https://developer.apple.com/documentation/photos/phassetresource/datasize-5lxva)
API starts with macOS 27 and can return no value. Supporting older Macs therefore
needs a fallback, such as OSXPhotos metadata or measuring downloaded resources.

FFmpeg is an alternative backend, with powerful inspection/filtering tools. Its
exact build determines the applicable LGPL/GPL terms; see
[FFmpeg's licensing documentation](https://ffmpeg.org/legal.html). A native
AVFoundation backend avoids shipping a separate encoding executable.

## Constraints that affect the workflow

- **Optimization does not reduce the iCloud bill.** Apple stores full-resolution
  originals in iCloud even when a device uses optimized local copies.
  [Apple storage documentation](https://support.apple.com/en-us/105061)
- **A compressed replacement is a new asset.** PhotoKit resources include
  originals and edited representations. Ordinary nondestructive editing does
  not provide the desired original-removal workflow. Do not overwrite files
  inside the `.photoslibrary` package.
  [Apple asset-resource documentation](https://developer.apple.com/documentation/photos/phassetresource)
- **Embedded metadata and library metadata differ.** Copying QuickTime tags
  does not by itself transfer albums, favorites, captions, manually tagged people,
  or editable adjustment history. Preserve supported fields explicitly and
  disclose anything that cannot transfer.
- **Savings depend on the source.** Some videos may already use efficient HEVC.
  Trial a few representative clips; a lower resolution or frame rate can matter
  more than changing the codec. Apple documents both HEVC capture and recording
  settings in its [HEVC guide](https://support.apple.com/en-us/116944).
- **A full account needs special care.** Keep originals outside iCloud before
  deletion. Apple says deletions propagate across synchronized devices and warns
  that over-quota accounts may not get Recently Deleted recovery. Its current
  guidance also says Recently Deleted items do not count toward iCloud storage,
  contrary to some compressor READMEs.
  [Apple iCloud storage guidance](https://support.apple.com/en-gb/108922)
- **Local import is not proof of cloud upload.** With no quota headroom, a
  replacement can be imported locally while its upload remains blocked. Keep
  independent copies of the original and replacement until Photos finishes
  synchronizing after space is freed.

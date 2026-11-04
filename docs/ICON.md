# App icon

Created with the built-in imagegen tool, using the imagegen skill. The generated
artwork is saved in `Resources/AppIcon.png`, with transparency preserved.
`scripts/build-icon.sh` uses macOS `sips` and `iconutil` to produce all standard
and Retina sizes in `Resources/AppIcon.icns`. The app bundle and in-app header
use this icon.

The running app also loads `AppIcon.icns` explicitly through its bundle resource
URL and assigns `NSApplication.applicationIconImage` at launch. The in-app header
uses the same loaded image. This avoids relying on the Dock refreshing its cached
generic image for earlier builds. No Dock cache is deleted or reset.

## Final generation prompt

Use case: logo-brand. Asset type: production macOS app icon for Photo Compressor, a native app for making videos in Apple Photos smaller. Create a single polished macOS icon at 1024x1024. A deep forest-teal rounded-square tile with subtle material depth and an illuminated mint edge. Center a simple, bold ivory rounded video frame with a play triangle; two small opposing inward compression arrows integrate naturally with the frame so it reads as a compact video. Minimal sculpted 3D icon design, refined soft highlights, excellent silhouette and readability at 32 pixels. Centered front view, generous consistent inner margins. The tile occupies about 88% of the canvas with a gentle shadow. Only transparent pixels outside the rounded tile; the interior is opaque. No lettering, no numbers, no badges, no Apple logos, no rainbow Photos flower, no additional symbols, no desktop scene or mockup.

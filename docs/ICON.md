# App icon

Created with the built-in imagegen tool, using the imagegen skill. The generated
artwork is saved in `Resources/AppIcon.png`, with transparency preserved.
`scripts/build-icon.sh` uses macOS `sips` and `iconutil` to produce all standard
and Retina sizes in `Resources/AppIcon.icns`. The app bundle and in-app header
use this icon.

Since 0.1.7, `scripts/build-icon-assets.sh` compiles those generated PNG sizes with
Xcode's `actool` as the `PhotoCompressorIcon` app icon. The bundle includes both
`Assets.car` and `PhotoCompressorIcon.icns`, and declares `CFBundleIconName` and
`CFBundleIconFile`. This supplies the icon to Finder and Dock folder stacks,
independently of the running application's Dock tile.

The running app loads the icon named by its bundle's `CFBundleIconFile` and
assigns `NSApplication.applicationIconImage` at launch. The in-app header uses
the same image. On launch, the app also updates only its own Launch Services
registration. The package build updates the bundle modification date, so an
older registration is not reused solely because nested files were rebuilt.
No system-wide Dock cache is deleted or reset.

## Final generation prompt

Use case: logo-brand. Asset type: production macOS app icon for Photo Compressor, a native app for making videos in Apple Photos smaller. Create a single polished macOS icon at 1024x1024. A deep forest-teal rounded-square tile with subtle material depth and an illuminated mint edge. Center a simple, bold ivory rounded video frame with a play triangle; two small opposing inward compression arrows integrate naturally with the frame so it reads as a compact video. Minimal sculpted 3D icon design, refined soft highlights, excellent silhouette and readability at 32 pixels. Centered front view, generous consistent inner margins. The tile occupies about 88% of the canvas with a gentle shadow. Only transparent pixels outside the rounded tile; the interior is opaque. No lettering, no numbers, no badges, no Apple logos, no rainbow Photos flower, no additional symbols, no desktop scene or mockup.

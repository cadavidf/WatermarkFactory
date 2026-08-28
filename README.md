# WatermarkFactory

WatermarkFactory is a native macOS 13+ SwiftUI app that batch-applies a selected watermark image to every supported image in a folder. Originals are never modified; exports are written to a `Watermarked/` subfolder.

## Build

```sh
xcodebuild -scheme WatermarkFactory -configuration Release build
```

## Package

```sh
./build_dmg.sh
```

The DMG is written to `dist/WatermarkFactory.dmg`.

## Test Build

Run the Release app from Xcode's build products, or open the app after mounting the generated DMG. Pick a source folder, pick a watermark PNG/JPEG/HEIC/TIFF, adjust size, opacity, placement or tiling, choose an export format, then click `Watermark All Images`.

## Known Limitations

- `Keep Original` preserves JPEG, PNG, and TIFF extensions. HEIC sources export as PNG because this app intentionally avoids extra encoders.
- The output size estimate is computed from the currently selected preview image, not the entire batch.
- The app uses the standard macOS sandbox user-selected read/write entitlement only.

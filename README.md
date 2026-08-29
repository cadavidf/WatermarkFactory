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

## Metadata handling

Exports are written with a fresh ImageIO metadata dictionary. WatermarkFactory preserves only the source GPS dictionary, then writes `kCGImagePropertyIPTCByline` as `automality.com` for creator attribution; PNG outputs also get `kCGImagePropertyPNGSoftware`/`kCGImagePropertyPNGAuthor`, and TIFF outputs get `kCGImagePropertyTIFFSoftware`/`kCGImagePropertyTIFFArtist`. These are the standard ImageIO-backed software and creator fields supported by the destination encoders without inventing custom tags. Other source metadata, including embedded comments, camera/software fields, thumbnails, copyright data, and provenance markers, is not copied.

## Known Limitations

- `Keep Original` preserves JPEG, PNG, and TIFF extensions. HEIC sources export as PNG because this app intentionally avoids extra encoders.
- The output size estimate is computed from the currently selected preview image, not the entire batch.
- The app uses the standard macOS sandbox user-selected read/write entitlement only.
- Restored folders, image files, and watermarks keep long-lived security-scoped access while they are in use, so previews should render after relaunch without requiring the user to re-pick files. The actual sandbox relaunch behavior is manual-tested because XCTest cannot reliably simulate user-selected security-scoped bookmarks.

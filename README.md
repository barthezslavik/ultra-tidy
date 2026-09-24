<p align="center">
  <img src="docs/hero.svg" alt="Ultra Tidy: review similar photos from your iCloud Photos library on macOS" width="100%">
</p>

<h1 align="center">Ultra Tidy — iCloud Photos Similar Photo Finder for macOS</h1>
<p align="center"><strong>A similar photo finder for iCloud Photos, built with Rust and native macOS APIs.</strong></p>
<p align="center">Find the shots you kept "just in case." Compare them at a comfortable size. Delete only the ones you choose.</p>

<p align="center">
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-18181b?logo=apple&logoColor=white">
  <img alt="Rust engine" src="https://img.shields.io/badge/engine-Rust-f97316?logo=rust&logoColor=white">
  <img alt="SwiftUI interface" src="https://img.shields.io/badge/interface-SwiftUI-2563eb?logo=swift&logoColor=white">
</p>

## Find similar and duplicate photos in iCloud Photos

Bursts, retakes, and tiny changes in framing turn one moment into dozens of photos. They clutter search results and eat into your iCloud storage. Finding them manually means scrolling through years of iCloud Photos. Ultra Tidy scans the Photos library available on your Mac, groups visually similar images, and lets you review large thumbnails before deciding what to remove.

**You stay in control:** scanning never deletes a photo. Click thumbnails to mark unwanted shots, then delete the marked set in one PhotoKit operation. Photos presents one system confirmation for the batch. Deleted photos go to **Recently Deleted** and, if iCloud Photos is enabled, the deletion syncs across your devices.

## Features

| | |
| --- | --- |
| 🔎 **Similar photo groups** | Find near duplicates and related shots in your Apple Photos library. |
| 🖼️ **Large review grid** | Resize thumbnails with a trackpad pinch or the zoom slider. |
| ✅ **Review first** | Mark or unmark photos with a click; nothing is deleted during scanning. |
| 🗑️ **One batch, one prompt** | Delete marked photos together through the macOS Photos confirmation. |
| 🦀 **Rust matching engine** | Compare image structure, average color, and capture-time proximity. |
| 🔒 **Local processing** | No account, cloud API, or upload to an Ultra Tidy server. PhotoKit may download images from your own iCloud library. |

## Build and run

**Requirements:** macOS 14+, Xcode Command Line Tools, and Rust. No third-party Rust crates are required.

```sh
git clone https://github.com/barthezslavik/ultra-tidy.git
cd ultra-tidy
./build-app.sh
open "dist/Ultra Tidy.app"
```

Grant access to Photos when macOS asks, then start a scan in the app. If you grant limited access, only the selected photos can be scanned. Large libraries and iCloud-only originals may take longer to process.

1. Choose a group in the sidebar.
2. Pinch on the trackpad or use the slider to make thumbnails larger.
3. Click photos to mark them for deletion; click again to unmark.
4. Delete the marked set and confirm in the macOS Photos dialog.

You can mark photos across multiple groups before deleting. The app is currently available from source; the build script creates a locally signed `.app`, not a notarized release.

## How similar photo detection works

The Rust library computes a compact brightness-pattern hash and average color for each image. Strong visual matches group together even when their capture dates are far apart. Photos captured within one hour may differ a little more visually and still match: **time is a helpful signal, not a requirement**. Photos without a capture date are matched by appearance alone.

This is approximate matching, so heavily cropped or edited copies may be missed, and unrelated photos with similar composition may occasionally group together. Review every photo before deleting it.

## Project structure

| Path | Purpose |
| --- | --- |
| [`src/lib.rs`](src/lib.rs) | Rust image signatures and similarity grouping |
| [`macos/UltraTidyApp.swift`](macos/UltraTidyApp.swift) | SwiftUI interface and PhotoKit library access |
| [`build-app.sh`](build-app.sh) | Build and ad-hoc sign the macOS app |

Run the Rust tests with `cargo test`.

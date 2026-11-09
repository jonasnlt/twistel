# Changelog

All notable changes to twistel are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [1.1.0] - 2026-11-09

- Presets in a fan: rest the pointer on **Crop**, **Rotate** or **Compress** in the tools ring (or move out over its edge) and an arc
  of presets opens: aspect ratios 1:1, 4:3, 3:2, 16:9, 9:16 and 4:5 (cut around faces, people or the main subject), 90° left,
  90° right and 180°, at most 1, 5, 10 or 25 MB, 1080p and 720p for videos. “Customize …” opens the window. Cropping with a preset
  also works for several pictures at once. A size limit is kept for sure: a result that doesn’t fit is not saved, a note says why.
  In the keyboard ring Space opens the fan; VoiceOver offers the presets as actions; “More …” finds them too.
- Scrolling with a mouse over an open ring changes the ring (one wheel step, one ring; Magic Mouse too).
- New tool **Remove audio** for videos: the picture is copied, not encoded again (rotation, HDR and Dolby Vision stay). MKV, WebM,
  AVI and WMV need FFmpeg.
- 7Z archives can be opened (macOS’s own `tar`, no helper program). 7Z archives with a password get a clear note.
- New targets **ICO** and **ICNS** for PNG, JPG, HEIC and SVG, with all their sizes in one file (ICO 16 to 256 pixels, ICNS 16 to
  1024).
- Each release is checked for networking code before it is published (`scripts/check-no-network.sh`).
- 314 conversions and 42 tools.

## [1.0.0] - 2026-11-08

First public release.

- Ring menu for files dragged in the Finder: **⇧ Convert**, **⌘ Tools**, **⌃ Actions** (keys and ring items can be changed).
- Also without dragging: menu bar icon › Choose Files …, and the Finder’s right-click menu (Services).
- 303 conversions between image, audio, video, document, spreadsheet, presentation, subtitle and archive formats.
- 41 tools, among them compress, crop, resize, redact (PDF, images, video, audio), sign PDF, OCR, PDF/A, PDF password, transcribe
  with whisper.cpp, social media presets, cut out subject.
- Results appear as new files next to the original; the original is never changed. Undo moves the result to the Trash.
- No network access: no telemetry, no update check; helper programs run in a macOS sandbox without network access.
- English and German.
- “Check for Updates …” in the menu bar menu opens the Releases page in the browser.
- Requires macOS 26 and a Mac with Apple silicon. Not notarized: confirm the first start with “Open Anyway”.

[1.1.0]: https://github.com/jonasnlt/twistel/releases/tag/v1.1.0
[1.0.0]: https://github.com/jonasnlt/twistel/releases/tag/v1.0.0

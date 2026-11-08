## twistel 1.0.0

The first public release: convert and edit files on your Mac with a ring menu, right where you drag them.

Drag files in the Finder and hold **⇧** (convert), **⌘** (tools) or **⌃** (actions): a ring appears around the pointer. Drop the
files on an option and the result appears next to the original. There are 303 conversions and 41 tools, for example HEIC to PNG,
Word to PDF, redacting, signing, OCR and transcription.

Everything stays on your Mac: twistel has no network access of its own, no telemetry and no update check. Optional helper
programs (FFmpeg, LibreOffice, Ghostscript, qpdf, whisper.cpp, Poppler, unar) are not included; if you install them with Homebrew,
twistel runs them in a sandbox without internet.

### Requirements

- macOS 26 or later
- A Mac with Apple silicon (M1 or later)

### Installation

1. Download `twistel-1.0.0.dmg` below, open it and drag **twistel** into **Applications**.
2. The app is not notarized by Apple. The first time you open it, macOS warns you: click **Done**, then go to **System Settings ›
   Privacy & Security** and click **Open Anyway**.

Step-by-step guide, helper programs and the speech model for transcription:
[docs/INSTALLATION.md](https://github.com/jonasnlt/twistel/blob/main/docs/INSTALLATION.md).

### Checksums

`SHA256SUMS.txt` contains the SHA-256 checksums of the DMG and the ZIP:

```
d11cc3286771b22ef3ca1f65ed84d6bea84991331cae0fd108c0f46ea04a04e4  twistel-1.0.0.zip
70e9195a2dedae9d5450f9470b0956923a6ad9467dec2db3fcc067c6cdbb7b4b  twistel-1.0.0.dmg
```

Check a download in Terminal with `shasum -a 256 twistel-1.0.0.dmg`.

### Feedback

Found a bug? Open an [issue](https://github.com/jonasnlt/twistel/issues). Please report security problems privately
(see [SECURITY.md](https://github.com/jonasnlt/twistel/blob/main/SECURITY.md)).

This is free software under the GPL-3.0.

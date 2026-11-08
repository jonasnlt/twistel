# Third-party components and licenses

The app itself is licensed under the [GNU General Public License v3.0](LICENSE) (Copyright (C) 2026 jonasnlt). This page lists
everything twistel contains or uses that comes from others. It is an overview, not legal advice.

## Included in twistel’s code

| What | License | Note |
| --- | --- | --- |
| [Satsuma](https://github.com/plyght/satsuma) by plyght | MIT | The starting point of this project. The MIT notice is kept in [LICENSES/Satsuma-MIT.txt](LICENSES/Satsuma-MIT.txt) and is also inside the app (`Contents/Resources/LICENSES`). MIT code may be part of a GPL-3.0 program as long as its notice is kept. |

Apart from that, the app contains no third-party code.

## Called, never shipped

These programs are not part of twistel and are not included in the app, the DMG or the ZIP. Users install them themselves,
if they want to (usually with Homebrew). The app looks for them in the usual places (`/opt/homebrew/bin`, `/usr/local/bin`;
LibreOffice in `/Applications`) and starts them as separate programs, always inside a macOS sandbox without network access. It does
not link against them and does not copy any of their code. If a program is missing, the features that need it say so and explain how
to install it.

| Program | License | What twistel uses it for |
| --- | --- | --- |
| [FFmpeg](https://ffmpeg.org) (`ffmpeg`, `ffprobe`) | LGPL 2.1 or later; GPL when built that way (Homebrew’s build is GPL) | audio and video formats Apple does not support |
| [Ghostscript](https://www.ghostscript.com) (`gs`) | AGPL 3.0 or commercial | strong PDF compression, PDF/A, a check after redacting |
| [qpdf](https://qpdf.sourceforge.io) | Apache 2.0 | PDF passwords |
| [LibreOffice](https://www.libreoffice.org) (`soffice`) | MPL 2.0 | Office documents |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (`whisper-cli`) | MIT | transcription |
| [Poppler](https://poppler.freedesktop.org) (`pdftotext`) | GPL 2 or 3 | an additional check after redacting a PDF; also used by the tests |
| [unar](https://theunarchiver.com/command-line) | LGPL 2.1 | reading RAR archives |
| [unrar](https://www.rarlab.com) | RARLAB’s own freeware license | reading RAR archives if unar is not installed |

Speech models for whisper.cpp are also not shipped; users download them themselves into `~/whisper-models`:

| Model | License |
| --- | --- |
| Whisper large-v3 / large-v3-turbo by OpenAI (`ggml-large-v3.bin`, `ggml-large-v3-turbo.bin`) | MIT |
| Silero VAD (`ggml-silero-v5.1.2.bin`) | MIT |

## Part of macOS

Apple’s frameworks (AppKit, SwiftUI, PDFKit, ImageIO, AVFoundation, Vision and others) and the programs that come with macOS:
`tar`, `zip`, `ditto`, `gunzip`, `sandbox-exec`. The color profile for PDF/A is Apple’s sRGB profile from the system; it is only
copied while converting and not shipped with twistel.

## Notes

- Should twistel ever bundle or download helper programs itself, their licenses (especially Ghostscript’s AGPL and the GPL build of
  FFmpeg) have to be checked again for that case.
- The app icon, sounds and all texts were made for twistel.

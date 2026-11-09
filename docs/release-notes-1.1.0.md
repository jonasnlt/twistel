## twistel 1.1.0

Presets in the ring, scrolling to change rings, removing the sound from a video, 7Z archives and Mac and Windows icons.

### New

- **Presets in a fan.** Rest the pointer on **Crop**, **Rotate** or **Compress** in the tools ring, or move out over its edge,
  and an arc of presets opens outside it. Drop the files on a preset and it runs at once:
  - Crop: 1:1, 4:3, 3:2, 16:9, 9:16, 4:5. The cut follows faces, people or the main subject, otherwise the middle; the picture
    keeps its full resolution. Works for several pictures at once.
  - Rotate: 90° left, 90° right, 180°.
  - Compress: at most 1, 5, 10 or 25 MB (pictures and sound; videos with FFmpeg installed), and 1080p or 720p for videos. A size
    limit is kept for sure: a result that doesn’t fit is not saved, and a note says why. PDFs keep the window as before.
  - **Customize …** opens the tool’s window, as dropping on the item itself does.

  The fan always stays fully on screen. In the keyboard ring (menu bar › Choose Files …) **Space** opens it, the arrow keys move
  and Return chooses. VoiceOver offers the presets as actions of their item, and the “More …” list finds them by name (“16:9”).
- **Scroll to change rings.** With a mouse, scrolling over an open ring changes the ring: one wheel step, or one swipe on a Magic
  Mouse, is one ring. Nothing scrolls behind the ring.
- **Remove audio** (tools ring, videos). The picture is copied, not encoded again: quality, rotation, HDR and Dolby Vision stay
  exactly as they were. MP4 and MOV need nothing; MKV, WebM, AVI and WMV need FFmpeg.
- **7Z archives** can be converted to ZIP, TAR or TAR.GZ, with macOS’s own `tar` (no helper program). Archives with a password
  can’t be opened; twistel says so.
- **ICO and ICNS.** PNG, JPG, HEIC and SVG can become a Windows icon (16 to 256 pixels) or a Mac icon (16 to 1024 pixels), all
  sizes in one file. A picture that isn’t square is fitted in with transparent edges.
- **No networking code, checked.** Every release is checked before it is published: no networking frameworks linked, no
  networking APIs called (`scripts/check-no-network.sh`).

314 conversions and 42 tools in all.

### Requirements

- macOS 26 or later
- A Mac with Apple silicon (M1 or later)

### Installation

1. Download `twistel-1.1.0.dmg` below, open it and drag **twistel** into **Applications** (replace the older version).
2. The app is not notarized by Apple. The first time you open it, macOS warns you: click **Done**, then go to **System Settings ›
   Privacy & Security** and click **Open Anyway**.

Step-by-step guide, helper programs and the speech model for transcription:
[docs/INSTALLATION.md](https://github.com/jonasnlt/twistel/blob/main/docs/INSTALLATION.md).

### Checksums

`SHA256SUMS.txt` contains the SHA-256 checksums of the DMG and the ZIP:

```
65b3f4e1f8cb8b55fc3fe1ee2c57db95b9487158923baf8eadc6cf33317f77b9  twistel-1.1.0.zip
e1a99ae18fffbfa21f0d659d87bb829b9eaacb6bed24d088db4f6242fb405ee8  twistel-1.1.0.dmg
```

Check a download in Terminal with `shasum -a 256 twistel-1.1.0.dmg`.

### Feedback

Found a bug? Open an [issue](https://github.com/jonasnlt/twistel/issues). Please report security problems privately (see
[SECURITY.md](https://github.com/jonasnlt/twistel/blob/main/SECURITY.md)). Pull requests are not accepted.

# Installing twistel

For twistel 1.0.0.

The app is not notarized by Apple (that needs a paid developer account). macOS therefore warns the first time you open it; step 3
shows how to open it anyway. Everything else works like any other app.

## 1. Check the requirements

- macOS 26 or later. The app does not start on older versions.
  - Check: Apple menu  › **About This Mac**. Below the name it says “macOS …” with the version, e.g. “macOS 26.1”.
  - Or in Terminal (the first number must be 26 or higher):

    ```bash
    sw_vers -productVersion
    ```

- A Mac with Apple silicon (M1 or later). Intel Macs are not supported.
- Memory, important for transcription (step 6): Apple menu  › About This Mac › “Memory”, e.g. “8 GB”.
- Free space: about 1 GB for twistel and the helper programs, about 1 GB for LibreOffice, 1.6 to 3.1 GB for the speech model.

## 2. Download and install

Download from the [Releases page](https://github.com/jonasnlt/twistel/releases):

| File | What |
| --- | --- |
| `twistel-1.0.0.dmg` | disk image with the app and a shortcut to Applications (recommended) |
| `twistel-1.0.0.zip` | the same app as a ZIP |
| `SHA256SUMS.txt` | checksums of both files |

With the DMG:

1. Double-click `twistel-1.0.0.dmg`. A window with **twistel** and **Applications** opens.
2. Drag **twistel** onto **Applications**. Important: only the copy in Applications gets the entries in the Finder’s right-click menu.
3. Eject the disk image (in the Finder sidebar, click ⏏ next to “twistel 1.0.0”). The DMG file can go to the Trash afterwards.

Or with the ZIP: double-click `twistel-1.0.0.zip`, then drag the resulting `twistel.app` into **Applications**.

Optional: check that the download is intact (in Terminal, in the folder of the file). The output must match the line in
`SHA256SUMS.txt`:

```bash
shasum -a 256 twistel-1.0.0.dmg
```

## 3. First start: “Open Anyway”

1. Double-click **twistel** in **Applications**.
2. macOS says: *“twistel” Not Opened. Apple could not verify “twistel” is free of malware that may harm your Mac or compromise your
   privacy.* (The wording can differ slightly between macOS versions.) Click **Done**, not *Move to Trash*.
3. Open Apple menu  › **System Settings** › **Privacy & Security**.
4. Scroll down to **Security**. It says *“twistel” was blocked to protect your Mac.* Click **Open Anyway** next to it. The note is
   only shown for about an hour after the attempt to open; otherwise repeat step 1.
5. Confirm with your password or Touch ID.
6. In the next window choose **Open Anyway** once more.

From then on, twistel starts normally, even after a restart. An icon appears in the menu bar (top right), no icon in the Dock. The
introduction opens on the first start.

> **Only if “Open Anyway” does not appear:** remove the download mark in Terminal. This switches off macOS’s check for this one app
> only, so use it only for a copy you downloaded from the Releases page or built yourself:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/twistel.app
> ```

## 4. Permissions

The app needs none of the “strong” permissions: no Accessibility, no Input Monitoring, no Screen Recording, no microphone, no
camera. If macOS asks for one of these, something is wrong: please decline and [report it](https://github.com/jonasnlt/twistel/issues).

What macOS may ask, and what to answer:

| Prompt | When | Answer | Change later |
| --- | --- | --- | --- |
| *“twistel” would like to access files in your Desktop folder* (Documents, Downloads, iCloud Drive, removable volumes) | the first time you convert a file from that folder | **Allow**: twistel puts the result next to the original | System Settings › Privacy & Security › **Files & Folders** › twistel |
| Notification *Background item added* | only if you switch on *Open twistel at login* in the app’s settings | nothing to do | System Settings › General › **Login Items & Extensions** |
| Keychain | signatures for PDFs are stored in this Mac’s keychain (not in iCloud) | if asked: **Allow** | Keychain Access app |

**Right-click in the Finder:** after the first start, *Convert with twistel*, *Tools in twistel* and *Actions in twistel* appear at
the very bottom of a file’s right-click menu (with many services, under *Services* or *Quick Actions*). If they are missing: System
Settings › Keyboard › **Keyboard Shortcuts …** › **Services** › under *Files and Folders* switch on the three twistel entries, then
relaunch the Finder (Apple menu  › Force Quit › Finder › Relaunch) or log out and in again.

## 5. Helper programs with Homebrew

Much works on its own (images, PDFs, Apple’s audio and video formats, text recognition). For the rest, twistel calls free programs
if they are installed. If one is missing, twistel shows a note with the command at that point. Overview in the app: menu bar icon ›
Settings › **Helper Programs**.

Homebrew is the usual way to install such programs. Instructions and the install command: <https://brew.sh>. After installing,
Homebrew shows two commands under “Next steps” that you still need to run; then close Terminal and open it again.

Then in Terminal, one command after another (each takes a few minutes):

| Command | What for | Without it |
| --- | --- | --- |
| `brew install ffmpeg` | audio and video beyond Apple’s formats (writing MP3, FLAC, OGG, Opus, WMA, MKV, WebM, AVI, WMV, GIF, WebP, AVIF), normalize loudness, visualize audio, audio for transcription | these conversions and tools say that ffmpeg is missing |
| `brew install --cask libreoffice` | Word, Excel, PowerPoint and OpenDocument with their real layout; DOC, XLS, PPT, ODS, ODP | Word, RTF and HTML go through Apple’s simpler text system (no headers, some images and tables lost); spreadsheets and presentations say that LibreOffice is missing |
| `brew install ghostscript` | strong PDF compression (text stays selectable), PDF/A | compression with Apple’s simpler method; *Archive as PDF/A* is not available |
| `brew install qpdf` | set and remove PDF passwords (AES-256) | *PDF password* says that qpdf is missing |
| `brew install whisper-cpp` | transcription and subtitles from speech (also needs the model, step 6) | *Transcribe* says what is missing |
| `brew install poppler` | an additional check after redacting a PDF | the check runs without this one reader |
| `brew install unar` | open RAR archives | RAR only if macOS’s built-in `tar` can open it, otherwise a note |

To save space: ffmpeg, LibreOffice and Ghostscript are the most useful; whisper-cpp is only needed for transcription.

The app finds the programs in Homebrew’s location (`/opt/homebrew/bin`) and LibreOffice in **Applications** by itself. Nothing needs
to be entered in its settings.

**No internet:** twistel starts every helper program inside a macOS sandbox without network access. If this lock does not work on a
Mac, twistel does not start the programs at all and says so.

## 6. Speech model for transcription (whisper.cpp)

Transcription needs a speech model and a small silence model in the folder `whisper-models` in your home folder
(`~/whisper-models`). The app only looks there and only for these file names:

| File (exactly this name) | What | Size | Download |
| --- | --- | --- | --- |
| `ggml-large-v3.bin` | the large speech model | 3.1 GB | <https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin> |
| `ggml-large-v3-turbo.bin` | the smaller speech model (instead of the large one) | 1.6 GB | <https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin> |
| `ggml-silero-v5.1.2.bin` | detects silence so that nothing is made up (always needed) | 0.9 MB | <https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin> |

One of the two speech models is enough. If both are in the folder, the large one is used. Keep the file names as they are.

**Which speech model for how much memory:**

- 16 GB or more: `ggml-large-v3.bin`. Most accurate. Needs about 3 to 4 GB of memory while transcribing.
- 8 GB: `ggml-large-v3-turbo.bin`. Much faster, needs about half the memory and is almost as accurate.

How to put them there:

1. In the Finder: Go › **Home** (⇧⌘H). Create a new folder named `whisper-models` (exactly like this, lower case).
2. Open the link to the speech model you chose and the one to the silence model in your browser, download the files and move them
   into `whisper-models`.
3. Check that the names are exactly right. Move a file only once its download has finished (Safari adds “.download” while it is
   still loading).

The app never downloads anything itself; you download these files yourself in your browser.

## 7. Quick test

Put a few test files in a folder of their own. Results appear next to the files.

1. Start and helper programs: menu bar icon › Settings › **Helper Programs**. Every installed program is marked as installed.
2. Image: drag a photo (e.g. HEIC from an iPhone) in the Finder while holding **⇧ Shift** and let go on **PNG** in the ring. A PNG
   appears next to the photo. The first time, macOS asks for access to the folder: Allow.
3. Office (LibreOffice): drag a Word document with ⇧ and let go on **PDF**. The PDF looks like the document.
4. Audio (ffmpeg): drag a voice memo (M4A) with ⇧ and let go on **MP3**. The MP3 plays.
5. Right-click and transcription (whisper.cpp): right-click the same voice memo › **Tools in twistel** › **Transcribe** › Text.
   A text file with what was said appears next to it.

If something does not work: the card at the top of the screen says what is missing. The log is at
`~/Library/Logs/twistel/twistel.log` (menu bar icon › Show Log); it contains file names and steps, no folder paths and no contents.

## 8. Uninstalling

1. If it is on, turn off menu bar icon › Settings › General › **Open twistel at login**.
2. Menu bar icon › **Quit twistel**.
3. Move `twistel.app` from **Applications** to the Trash.
4. Remove what is left (in the Finder with Go › Go to Folder …, ⇧⌘G):
   - `~/Library/Logs/twistel` (logs).
   - Empty folders, if present: `~/Library/Caches/io.github.jonasnlt.twistel` and
     `~/Library/Application Support/io.github.jonasnlt.twistel`.
   - Settings, in Terminal:

     ```bash
     defaults delete io.github.jonasnlt.twistel
     ```

   - Saved signatures: open **Keychain Access**, search for “twistel” and delete the “twistel signature” items.
   - Reset granted folder access (optional):

     ```bash
     tccutil reset All io.github.jonasnlt.twistel
     ```

5. Optional, if nothing else needs them: delete the speech models (`~/whisper-models`, up to 3 GB) and remove the helper programs:

   ```bash
   brew uninstall ffmpeg ghostscript qpdf whisper-cpp poppler unar
   ```

   ```bash
   brew uninstall --cask libreoffice
   ```

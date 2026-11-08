# Security policy

## Reporting a vulnerability

Please do not report security problems as a public issue.

Report them privately through GitHub: on the repository page, open the **Security** tab and click **Report a vulnerability**
(<https://github.com/jonasnlt/twistel/security/advisories/new>). Only the maintainer can see the report. Reports are handled on a
best-effort basis, with no guaranteed response time and no guarantee of a fix.

Please include:

- what the problem is and what an attacker could do with it,
- how to reproduce it (a small example file helps; no private files, please),
- the twistel and macOS versions.

This is a personal project maintained by one person. Please give a reasonable amount of time to fix the problem before you
publish details.

## Supported versions

Only the newest release receives fixes.

## Scope

The app works on files locally and has no network access of its own; helper programs run in a macOS sandbox without network access.
Of particular interest are, for example:

- files that make twistel write outside the intended folder, overwrite or change the original, or leave unredacted content in a
  redacted PDF, image or video,
- ways around the network lock for helper programs,
- passwords or file contents that end up in the log.

Problems in the helper programs themselves (FFmpeg, Ghostscript, LibreOffice, qpdf, whisper.cpp, Poppler, unar) should be reported
to their projects.

Place optional repo-managed media binaries here if you want BridgeSub builds to
bundle fixed tool versions instead of copying from Homebrew or system paths.

Expected filenames:
- `ffprobe`
- `ffmpeg`
- `mkvextract`
- `mkvmerge`

Build behavior:
- The XcodeGen post-build script copies executables from this folder into
  `BridgeSub.app/Contents/Resources/Tools/` when present.
- If a repo-managed binary is missing, the script falls back to known system
  locations such as `/opt/homebrew/bin`.

Do not commit ad-hoc local binaries without updating the release manifest in
`Docs/BundledToolchainManifest.md`.

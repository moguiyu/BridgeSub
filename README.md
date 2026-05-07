# BridgeSub

BridgeSub is a native macOS workbench for bilingual subtitle alignment, translation, preview, and export.

It is built for local video workflows where you need to inspect media, choose or download subtitle tracks, translate missing tracks, review alignment quality, preview bilingual output, and export a merged sidecar or embedded MKV/WebM subtitle stream.

## Current Features

- Inspect local videos with `ffprobe`.
- Discover embedded text subtitles, sidecars, audio streams, and container metadata.
- Manage two subtitle slots with independent language, provider, candidate, and reference state.
- Load embedded or sidecar subtitles into a shared domain model.
- Search and download OpenSubtitles candidates.
- Translate subtitles with Ollama or OpenAI-compatible chat providers.
- Merge two subtitle documents into bilingual preview/export output.
- Score alignment and target-language quality before export.
- Export merged sidecars and optionally embed them into MKV/WebM containers.

## Requirements

- macOS 14+
- Xcode 26+ / Swift 6
- XcodeGen
- Media tools available either in `SubtitleStudio/Tools/` or on the system path:
  - `ffprobe`
  - `ffmpeg`
  - `mkvextract`
  - `mkvmerge`

## Build

```bash
xcodegen generate
xcodebuild -project SubtitleStudio.xcodeproj -scheme SubtitleStudio -destination 'platform=macOS' build
```

The Swift module and Xcode target are still named `SubtitleStudio` for now. The app product name is `BridgeSub`.

Automated test sources are not included in this sanitized initial upload. Restore `SubtitleStudioTests/` before re-enabling the test target and `xcodebuild ... test` workflow.

## Privacy And Credentials

BridgeSub works with local media files. Provider credentials are stored in the macOS Keychain via `KeychainCredentialStore`.

Do not commit local agent settings, `.env` files, API keys, media files, subtitle samples, DerivedData, or generated exports. The current repository is intended for a clean private GitHub upload from a sanitized working tree.

## Development Notes

See [Docs/Development.md](Docs/Development.md) for local build notes. Agent-specific instructions should stay in ignored local files and should not be committed.

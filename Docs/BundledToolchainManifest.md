# Bundled Media Toolchain Manifest

Use this manifest when preparing a release build that bundles media tools inside
`BridgeSub.app/Contents/Resources/Tools/`.

## Required Entries Per Tool

For each bundled binary, record:
- tool name
- version
- source URL
- local acquisition method
- build flags
- architecture
- checksum
- license

## Current Expected Tools

| Tool | Purpose | Preferred Source |
| --- | --- | --- |
| `ffprobe` | container inspection | FFmpeg build |
| `ffmpeg` | fallback extraction and remux | FFmpeg build |
| `mkvextract` | fast Matroska subtitle extraction | MKVToolNix build |
| `mkvmerge` | Matroska remux and subtitle embedding | MKVToolNix build |

## Release Checklist

- Record exact versions and checksums before shipping.
- Verify bundled binaries are universal or match the intended target arch.
- Confirm the app can launch bundled tools on a clean Mac without Homebrew.
- Include the relevant third-party license notices in release materials.
- Keep FFmpeg build flags aligned with the chosen compliance path.

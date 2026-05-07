# Development

BridgeSub is generated with XcodeGen and built with Xcode.

```bash
xcodegen generate
xcodebuild -project SubtitleStudio.xcodeproj -scheme SubtitleStudio -destination 'platform=macOS' build
```

The source module remains `SubtitleStudio`; the app product name is `BridgeSub`.

Automated test sources are not included in this sanitized initial upload. Restore `SubtitleStudioTests/` before re-enabling the test target and `xcodebuild ... test` workflow.

Local media tools can be supplied through `SubtitleStudio/Tools/` or resolved from common Homebrew/system locations. Keep binary tools, local media, sample subtitles, credentials, and generated exports out of Git unless there is an explicit project reason to add a sanitized fixture.

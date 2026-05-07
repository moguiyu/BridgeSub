import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var viewModel: WorkflowViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var activeCardIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            mainWorkspace
            statusBar
        }
        .background(StudioColor.background)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    presentOpenPanel(for: .video)
                } label: {
                    Label("Open Video", systemImage: "folder")
                }

                Button {
                    Task { await viewModel.inspectVideo() }
                } label: {
                    Label("Re-inspect", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.selectedVideoURL == nil || viewModel.isProcessing)

                Divider()

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .onAppear {
            clampActiveCardIndex()
        }
        .onChange(of: viewModel.cards.count) {
            clampActiveCardIndex()
        }
    }

    private var mainWorkspace: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 1_080
            let sidebarWidth = isCompact ? 238.0 : 270.0
            let inspectorWidth = isCompact ? 318.0 : 360.0

            HStack(spacing: 0) {
                WorkflowSidebarView(
                    viewModel: viewModel,
                    activeCardIndex: $activeCardIndex
                )
                .frame(width: sidebarWidth)

                Divider()

                VStack(spacing: 0) {
                    workspaceHeader
                        .studioPaneHeader()

                    SubtitleWorkspaceView(
                        cardIndex: activeCardIndex,
                        viewModel: viewModel
                    )
                    .padding(StudioSpacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(StudioColor.surface)
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                WorkflowInspectorView(viewModel: viewModel)
                    .frame(width: inspectorWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: StudioSpacing.md) {
            Image(systemName: "text.bubble")
                .foregroundStyle(StudioColor.textSecondary)

            VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                Text(activeCardTitle)
                    .font(StudioFont.paneTitle)
                    .foregroundStyle(StudioColor.text)

                Text(activeCardSubtitle)
                    .font(StudioFont.caption)
                    .foregroundStyle(StudioColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: StudioSpacing.md)

            if viewModel.hasPendingWorkflowWork {
                StudioStatusTag("Working", tone: .accent, systemImage: "arrow.triangle.2.circlepath")
            }

            if viewModel.previewState.isDraftPreview {
                StudioStatusTag("Live Draft", tone: .warning, systemImage: "sparkles")
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: StudioSpacing.md) {
            Label(statusTitle, systemImage: statusIcon)
                .foregroundStyle(statusTint)

            Divider()
                .frame(height: 14)

            Text(videoStatus)
                .lineLimit(1)

            Divider()
                .frame(height: 14)

            Text(previewStatus)
                .lineLimit(1)

            Spacer(minLength: StudioSpacing.md)

            if viewModel.hasPendingWorkflowWork {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)
            }

            Text(exportStatus)
                .lineLimit(1)
        }
        .font(StudioFont.caption)
        .foregroundStyle(StudioColor.textSecondary)
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, StudioSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColor.backgroundElevated)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StudioColor.border)
                .frame(height: 1 / 2)
        }
    }

    private var activeCardTitle: String {
        "Subtitle \(activeCardIndex + 1) Workspace"
    }

    private var activeCardSubtitle: String {
        guard viewModel.cards.indices.contains(activeCardIndex) else {
            return "No subtitle workspace selected."
        }
        let card = viewModel.cards[activeCardIndex]
        return "\(card.language.displayName) - \(viewModel.selectionSummary(forCardIndex: activeCardIndex))"
    }

    private var statusTitle: String {
        if let latest = viewModel.statusLines.first {
            return latest.message
        }
        return "Ready."
    }

    private var statusIcon: String {
        viewModel.lastError == nil ? "circle.fill" : "xmark.circle.fill"
    }

    private var statusTint: Color {
        viewModel.lastError == nil ? StudioColor.success : StudioColor.danger
    }

    private var videoStatus: String {
        guard let inspection = viewModel.inspectionReport else {
            return viewModel.selectedVideoURL?.lastPathComponent ?? "No video selected"
        }
        let textSubtitleCount = inspection.embeddedSubtitleTracks.filter { $0.isTextBased }.count
        return "\(inspection.containerName) - \(inspection.audioStreams.count) audio - \(textSubtitleCount) subtitles - \(inspection.localSubtitleSidecars.count) sidecars"
    }

    private var previewStatus: String {
        if viewModel.previewTotalCueCount > 0 {
            return "Preview \(viewModel.visiblePreviewCues.count)/\(viewModel.previewTotalCueCount) cues"
        }
        return viewModel.previewPlaceholderMessage
    }

    private var exportStatus: String {
        if let sidecar = viewModel.lastSavedSidecarURL {
            return "Saved \(sidecar.lastPathComponent)"
        }
        if let embedded = viewModel.lastEmbeddedOutputURL {
            return "Embedded \(embedded.lastPathComponent)"
        }
        if viewModel.canSaveSidecar {
            return "Export ready"
        }
        return "Export pending"
    }

    private func clampActiveCardIndex() {
        guard !viewModel.cards.isEmpty else {
            activeCardIndex = 0
            return
        }
        activeCardIndex = min(max(activeCardIndex, 0), viewModel.cards.count - 1)
    }

    private func presentOpenPanel(for kind: WorkflowViewModel.FileImportKind) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = allowedContentTypes(for: kind)
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.handleImportedURL(url, kind: kind)
        }
    }

    private func allowedContentTypes(for kind: WorkflowViewModel.FileImportKind) -> [UTType] {
        switch kind {
        case .video:
            return [
                .mpeg4Movie,
                .quickTimeMovie,
                .movie,
                .avi,
                .audiovisualContent,
                UTType(filenameExtension: "mkv"),
                UTType(filenameExtension: "ts"),
                UTType(filenameExtension: "m2ts")
            ]
            .compactMap { $0 }
        case .cardFallback:
            return [
                .plainText,
                .text,
                UTType(filenameExtension: "srt"),
                UTType(filenameExtension: "ass"),
                UTType(filenameExtension: "ssa"),
                UTType(filenameExtension: "vtt"),
                UTType(filenameExtension: "sub")
            ]
            .compactMap { $0 }
        }
    }
}

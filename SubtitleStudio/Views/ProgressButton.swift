import SwiftUI

struct ProgressButton<Label: View>: View {
    let title: String
    let isLoading: Bool
    let isCompact: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        _ title: String,
        isLoading: Bool = false,
        isCompact: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.title = title
        self.isLoading = isLoading
        self.isCompact = isCompact
        self.action = action
        self.label = label
    }

    init(
        _ title: String,
        isLoading: Bool = false,
        isCompact: Bool = false,
        action: @escaping () -> Void
    ) where Label == Text {
        self.title = title
        self.isLoading = isLoading
        self.isCompact = isCompact
        self.action = action
        self.label = { Text(title) }
    }

    var body: some View {
        let button = Button {
            action()
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .fixedSize()
                    Text(title.isEmpty ? "Working..." : title)
                } else {
                    label()
                }
            }
        }
        .disabled(isLoading)

        if isCompact {
            button
                .buttonStyle(StudioCompactButtonStyle())
                .controlSize(.small)
        } else {
            button
                .buttonStyle(BorderedProminentButtonStyle())
                .controlSize(.regular)
        }
    }
}

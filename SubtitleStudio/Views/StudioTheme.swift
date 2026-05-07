import SwiftUI

enum StudioColor {
    static let background = Color(red: 0.965, green: 0.969, blue: 0.977)
    static let backgroundElevated = Color(red: 0.988, green: 0.989, blue: 0.993)
    static let surface = Color(red: 0.999, green: 0.999, blue: 1.0)
    static let surfaceSubtle = Color(red: 0.975, green: 0.978, blue: 0.984)
    static let surfaceStrong = Color(red: 0.93, green: 0.936, blue: 0.949)
    static let border = Color(red: 0.84, green: 0.852, blue: 0.875)
    static let borderStrong = Color(red: 0.74, green: 0.758, blue: 0.79)
    static let text = Color(red: 0.11, green: 0.132, blue: 0.168)
    static let textSecondary = Color(red: 0.36, green: 0.392, blue: 0.452)
    static let textTertiary = Color(red: 0.51, green: 0.545, blue: 0.6)
    static let accent = Color(red: 0.195, green: 0.404, blue: 0.85)
    static let success = Color(red: 0.118, green: 0.59, blue: 0.357)
    static let warning = Color(red: 0.8, green: 0.486, blue: 0.0)
    static let danger = Color(red: 0.794, green: 0.192, blue: 0.176)
    static let info = Color(red: 0.156, green: 0.486, blue: 0.83)
}

enum StudioSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
}

enum StudioRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 8
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 16
}

enum StudioFont {
    static let sectionHeader = Font.system(size: 13, weight: .semibold)
    static let paneTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11, weight: .regular)
    static let captionStrong = Font.system(size: 11, weight: .semibold)
    static let tag = Font.system(size: 11, weight: .semibold)
    static let compactButton = Font.system(size: 12, weight: .semibold)
}

enum StudioTagTone: CaseIterable {
    case neutral
    case accent
    case success
    case warning
    case danger
    case info

    var background: Color {
        switch self {
        case .neutral:
            return StudioColor.surfaceStrong
        case .accent:
            return StudioColor.accent.opacity(0.14)
        case .success:
            return StudioColor.success.opacity(0.14)
        case .warning:
            return StudioColor.warning.opacity(0.14)
        case .danger:
            return StudioColor.danger.opacity(0.14)
        case .info:
            return StudioColor.info.opacity(0.14)
        }
    }

    var foreground: Color {
        switch self {
        case .neutral:
            return StudioColor.textSecondary
        case .accent:
            return StudioColor.accent
        case .success:
            return StudioColor.success
        case .warning:
            return StudioColor.warning
        case .danger:
            return StudioColor.danger
        case .info:
            return StudioColor.info
        }
    }

    var border: Color {
        switch self {
        case .neutral:
            return StudioColor.border
        case .accent:
            return StudioColor.accent.opacity(0.32)
        case .success:
            return StudioColor.success.opacity(0.32)
        case .warning:
            return StudioColor.warning.opacity(0.32)
        case .danger:
            return StudioColor.danger.opacity(0.32)
        case .info:
            return StudioColor.info.opacity(0.32)
        }
    }
}

struct StudioSubtleSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = StudioRadius.xl
    var padding: CGFloat = StudioSpacing.lg

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(StudioColor.surfaceSubtle)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(StudioColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct StudioPaneHeaderModifier: ViewModifier {
    var bottomDivider: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, StudioSpacing.lg)
            .padding(.vertical, StudioSpacing.md)
            .background(StudioColor.backgroundElevated)
            .overlay(alignment: .bottom) {
                if bottomDivider {
                    Rectangle()
                        .fill(StudioColor.border)
                        .frame(height: 1 / 2)
                }
            }
    }
}

struct StudioCompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StudioFont.compactButton)
            .padding(.horizontal, StudioSpacing.md)
            .padding(.vertical, StudioSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                    .fill(configuration.isPressed ? StudioColor.surfaceStrong : StudioColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                    .stroke(StudioColor.border, lineWidth: 1)
            )
            .foregroundStyle(StudioColor.text)
            .contentShape(RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct StudioStatusTag: View {
    let title: String
    var tone: StudioTagTone = .neutral
    var systemImage: String? = nil

    init(_ title: String, tone: StudioTagTone = .neutral, systemImage: String? = nil) {
        self.title = title
        self.tone = tone
        self.systemImage = systemImage
    }

    var body: some View {
        label
            .font(StudioFont.tag)
            .padding(.horizontal, StudioSpacing.sm)
            .padding(.vertical, StudioSpacing.xs)
            .background(tone.background)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tone.border, lineWidth: 1)
            )
            .clipShape(Capsule(style: .continuous))
            .foregroundStyle(tone.foreground)
    }

    @ViewBuilder
    private var label: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

extension View {
    func studioSubtleSurface(cornerRadius: CGFloat = StudioRadius.xl, padding: CGFloat = StudioSpacing.lg) -> some View {
        modifier(StudioSubtleSurfaceModifier(cornerRadius: cornerRadius, padding: padding))
    }

    func studioPaneHeader(bottomDivider: Bool = true) -> some View {
        modifier(StudioPaneHeaderModifier(bottomDivider: bottomDivider))
    }
}


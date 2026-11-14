import SwiftUI

/// The single source of truth for client typography, color, shape and layout.
nonisolated enum DesignSystem {
    static let appearance: ColorScheme = .light

    enum TextRole: CaseIterable {
        case pageTitle, sectionTitle, cardTitle, contentTitle
        case body, secondary, caption, micro, code, button, value

        var size: CGFloat {
#if os(tvOS)
            switch self {
            case .pageTitle: 48
            case .sectionTitle: 36
            case .cardTitle: 30
            case .contentTitle: 26
            case .body: 24
            case .secondary: 22
            case .caption, .code: 20
            case .micro: 16
            case .button: 22
            case .value: 42
            }
#else
            switch self {
            case .pageTitle, .value: 28
            case .sectionTitle: 22
            case .cardTitle: 20
            case .contentTitle: 17
            case .body, .button: 16
            case .secondary: 14
            case .caption: 12
            case .micro: 10
            case .code: 13
            }
#endif
        }

        var weight: Font.Weight {
            switch self {
            case .pageTitle: .bold
            case .sectionTitle, .cardTitle, .contentTitle, .value: .semibold
            case .button: .medium
            default: .regular
            }
        }

        var lineSpacing: CGFloat {
#if os(tvOS)
            4
#else
            switch self {
            case .body, .secondary, .code: 3
            default: 2
            }
#endif
        }

        var relativeTo: Font.TextStyle {
            switch self {
            case .pageTitle: .largeTitle
            case .sectionTitle, .value: .title2
            case .cardTitle: .title3
            case .contentTitle: .headline
            case .body, .button: .body
            case .secondary: .subheadline
            case .caption, .code: .caption
            case .micro: .caption2
            }
        }
    }

    enum Colors {
        static let background = Color(red: 0.97, green: 0.975, blue: 0.99)
        static let card = Color.white
        static let text = Color.primary
        static let secondaryText = Color.secondary
        static let tertiaryLabel = Color.gray.opacity(0.65)
        static let accent = Color.blue
        static let application = Color.teal
        static let success = Color.green
        static let warning = Color.orange
        static let error = Color.red
        static let divider = Color.primary.opacity(0.10)
        static let policyPalettes: [[Color]] = [
            [Color(red: 0.08, green: 0.75, blue: 0.64), Color(red: 0.66, green: 0.94, blue: 0.23)],
            [Color(red: 0.04, green: 0.28, blue: 0.73), Color(red: 0.02, green: 0.78, blue: 0.86)],
            [Color(red: 0.35, green: 0.25, blue: 0.92), Color(red: 0.90, green: 0.23, blue: 0.80)],
            [Color(red: 0.03, green: 0.43, blue: 0.96), Color(red: 0.02, green: 0.76, blue: 0.97)],
            [Color(red: 0.17, green: 0.13, blue: 0.47), Color(red: 0.63, green: 0.17, blue: 0.87)],
            [Color(red: 0.12, green: 0.37, blue: 0.48), Color(red: 0.05, green: 0.68, blue: 0.65)],
            [Color(red: 0.73, green: 0.24, blue: 0.96), Color(red: 0.99, green: 0.39, blue: 0.68)],
            [Color(red: 0.41, green: 0.35, blue: 0.89), Color(red: 0.22, green: 0.52, blue: 0.98)],
            [Color(red: 1.0, green: 0.36, blue: 0.33), Color(red: 1.0, green: 0.79, blue: 0.22)],
            [Color(red: 0.12, green: 0.69, blue: 0.91), Color(red: 0.75, green: 0.24, blue: 0.97)]
        ]
    }

    enum CardTheme {
        case outbound, profiles, proxies, rules

        var colors: [Color] {
            switch self {
            case .outbound: [Color(red: 0.25, green: 0.31, blue: 0.81), Color(red: 0.20, green: 0.56, blue: 0.88)]
            case .profiles: [Color(red: 0.43, green: 0.28, blue: 0.77), Color(red: 0.64, green: 0.39, blue: 0.87)]
            case .proxies: [Color(red: 0.70, green: 0.31, blue: 0.11), Color(red: 0.85, green: 0.48, blue: 0.18)]
            case .rules: [Color(red: 0.60, green: 0.30, blue: 0.48), Color(red: 0.78, green: 0.42, blue: 0.60)]
            }
        }

        var tint: Color { colors[0] }
    }

    enum Spacing {
        static let tiny: CGFloat = 4
        static let small: CGFloat = 8
        static let compact: CGFloat = 12
        static let regular: CGFloat = 16
        static let comfortable: CGFloat = 20
        static let section: CGFloat = 24
        static let television: CGFloat = 28
        static let large: CGFloat = 32
        static let page: CGFloat = 40
    }

    enum Card {
        static var radius: CGFloat {
#if os(tvOS)
            28
#else
            24
#endif
        }
        static let policyRadius: CGFloat = 22
        static var policyHeight: CGFloat {
#if os(tvOS)
            220
#else
            146
#endif
        }
        static let policyPadding: CGFloat = 18
        static let tintOpacity = 0.12
        static let borderOpacity = 0.025
        static var padding: CGFloat {
#if os(tvOS)
            28
#else
            20
#endif
        }
    }

    enum Icon {
        static let small: CGFloat = 14
        static let regular: CGFloat = 22
        static let row: CGFloat = 18
        static let backgroundRadius: CGFloat = 11
        static let preview: CGFloat = 27
        static let add: CGFloat = 32
        static let container: CGFloat = 36
    }

    enum Layout {
        static let readingWidth: CGFloat = 760
        static let groupWidth: CGFloat = 1000
        static let televisionWidth: CGFloat = 1700
        static let compactTopInset: CGFloat = 28
        static var topInset: CGFloat {
#if os(tvOS)
            56
#else
            40
#endif
        }
        static var horizontalInset: CGFloat {
#if os(tvOS)
            48
#elseif os(macOS)
            32
#else
            20
#endif
        }
        static let bottomInset: CGFloat = 40
    }

    enum Interaction {
        static let minimumHitSize: CGFloat = 44
        static let buttonRadius: CGFloat = 14
        static let focusOutline: CGFloat = 3
        static let focusScale: CGFloat = 1.025
        static let focusDuration = 0.15
        static let disabledOpacity = 0.4
    }
}

private struct DesignTextModifier: ViewModifier {
    let role: DesignSystem.TextRole
    let weight: Font.Weight?
    let design: Font.Design
    @ScaledMetric private var size: CGFloat

    init(role: DesignSystem.TextRole, weight: Font.Weight?, design: Font.Design?) {
        self.role = role
        self.weight = weight
        self.design = design ?? (role == .code ? .monospaced : .default)
        _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.relativeTo)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight ?? role.weight, design: design))
            .lineSpacing(role.lineSpacing)
    }
}

private struct DesignCardSurface: ViewModifier {
    let colors: [Color]

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    DesignSystem.Colors.card
                    if !colors.isEmpty {
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            .opacity(DesignSystem.Card.tintOpacity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Card.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Card.radius, style: .continuous)
                    .stroke(Color.primary.opacity(DesignSystem.Card.borderOpacity), lineWidth: 1)
            }
    }
}

extension View {
    func designText(_ role: DesignSystem.TextRole, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(DesignTextModifier(role: role, weight: weight, design: design))
    }

    func designCard(colors: [Color] = []) -> some View {
        modifier(DesignCardSurface(colors: colors))
    }
}

// Existing client views share the same colors through this compatibility name.
typealias ClientAppearance = DesignSystem.Colors

import MacScopeCore
import SwiftUI

enum MacScopeAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum MacScopeTheme {
    static let accent = Color(red: 0.12, green: 0.58, blue: 0.95)
    static let cyan = Color(red: 0.18, green: 0.78, blue: 0.82)
    static let contentBackground = Color(nsColor: .underPageBackgroundColor)
    static let warning = Color.orange
    static let critical = Color.red
    static let cardRadius: CGFloat = 10
    static let metricCardHeight: CGFloat = 148
}

struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

struct Card<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: MacScopeTheme.cardRadius))
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: MacScopeTheme.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MacScopeTheme.cardRadius, style: .continuous)
                        .stroke(.separator.opacity(0.45), lineWidth: 1)
                }
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var icon: String
    var tint: Color = MacScopeTheme.accent
    var availability: DataAvailability = .available

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    Label {
                        Text(title).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: icon).foregroundStyle(tint)
                    }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    Spacer()
                    AvailabilityBadge(availability: availability)
                }
                Text(value)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Spacer(minLength: 0)
                Text(subtitle ?? " ")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .opacity(subtitle == nil ? 0 : 1)
            }
            .frame(height: MacScopeTheme.metricCardHeight - 32, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: MacScopeTheme.metricCardHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

extension View {
    @ViewBuilder func macScopeGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder func macScopeGlassControl() -> some View {
        if #available(macOS 26.0, *) {
            self
                .padding(2)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 9))
        } else {
            self
        }
    }

    @ViewBuilder func macScopeGlassSurface(cornerRadius: CGFloat = MacScopeTheme.cardRadius) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.separator.opacity(0.4), lineWidth: 1)
                }
        }
    }
}

struct AvailabilityBadge: View {
    let availability: DataAvailability

    private var shouldDisplay: Bool {
        availability != .available && availability != .degraded
    }

    private var color: Color {
        switch availability {
        case .available: .green
        case .degraded, .unmapped, .stale: .orange
        case .restricted: .purple
        case .unsupported: .secondary
        }
    }

    @ViewBuilder
    var body: some View {
        if shouldDisplay {
            Text(availability.rawValue.capitalized)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(color.opacity(0.12), in: Capsule())
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyMetricView: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        Card {
            ContentUnavailableView(title, systemImage: icon, description: Text(detail))
                .frame(maxWidth: .infinity, minHeight: 180)
        }
    }
}

struct TableFilterBar: View {
    @Binding var text: String
    let prompt: String
    let resultCount: Int
    let resultLabel: String

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(prompt)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 330, height: 30)
            .macScopeGlassSurface(cornerRadius: 8)

            Spacer()
            Text("\(resultCount.formatted()) \(resultLabel)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }
}

import SwiftUI

/// Accent colour and light/dark choice, applied at the root of every scene.
enum AccentTheme: String, CaseIterable, Identifiable {
    case graphite, ocean, forest, amber, rose, violet, blue
    var id: String { rawValue }

    var name: String {
        switch self {
        case .graphite: return "Graphite"
        case .ocean: return "Ocean"
        case .forest: return "Forest"
        case .amber: return "Amber"
        case .rose: return "Rose"
        case .violet: return "Violet"
        case .blue: return "System blue"
        }
    }

    var color: Color {
        switch self {
        case .graphite: return Color(red: 0.62, green: 0.66, blue: 0.72)
        case .ocean: return Color(red: 0.20, green: 0.66, blue: 0.73)
        case .forest: return Color(red: 0.30, green: 0.64, blue: 0.45)
        case .amber: return Color(red: 0.93, green: 0.64, blue: 0.22)
        case .rose: return Color(red: 0.88, green: 0.38, blue: 0.48)
        case .violet: return Color(red: 0.56, green: 0.47, blue: 0.91)
        case .blue: return .accentColor
        }
    }

    /// Recording stays red in every theme so it is unmistakable.
    static let recording = Color.red
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

extension AppSettings {
    static let accentKey = "ui.accent"
    static let appearanceKey = "ui.appearance"
    static var accent: AccentTheme { AccentTheme(rawValue: UserDefaults.standard.string(forKey: accentKey) ?? "") ?? .ocean }
    static var appearance: Appearance { Appearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system }
}

/// Applies the chosen accent and appearance; re-renders when either setting changes.
struct Themed<Content: View>: View {
    @AppStorage(AppSettings.accentKey) private var accent = AccentTheme.ocean.rawValue
    @AppStorage(AppSettings.appearanceKey) private var appearance = Appearance.system.rawValue
    let content: () -> Content

    var body: some View {
        content()
            .tint((AccentTheme(rawValue: accent) ?? .ocean).color)
            .preferredColorScheme((Appearance(rawValue: appearance) ?? .system).scheme)
    }
}

/// Text tabs with an underline that slides between them. Sits on a header, not in a form.
struct UnderlineTabs<T: Hashable>: View {
    struct Item { let value: T; let title: String; let detail: String? }
    let items: [Item]
    @Binding var selection: T
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 24) {
            ForEach(items, id: \.value) { item in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = item.value }
                } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Text(item.title).font(.body.weight(selection == item.value ? .semibold : .regular))
                            if let detail = item.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                        }
                        .foregroundStyle(selection == item.value ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        ZStack {
                            Rectangle().fill(.clear).frame(height: 2)
                            if selection == item.value {
                                Rectangle().fill(.tint).frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) { Rectangle().fill(.quaternary).frame(height: 1) }
    }
}

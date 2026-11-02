import SwiftUI

// Typografie und Farben wie MediaFiles Ferry (ui/app.slint dort).
struct Theme {
    let dark: Bool
    private func c(_ d: UInt32, _ l: UInt32) -> Color {
        let v = dark ? d : l
        return Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
    var background: Color { c(0x1f2225, 0xf5f5f3) }
    var text: Color { c(0xeceded, 0x17191b) }
    var muted: Color { c(0xa9adb1, 0x3f444a) }
    var faint: Color { c(0x7c8288, 0x60666c) }
    var line: Color { c(0x3a3f44, 0xc4c8cc) }
    var disabled: Color { c(0x6a7076, 0x70767c) }
    var primary: Color { c(0xe6e7e8, 0x2e3236) }
    var onPrimary: Color { c(0x1f2225, 0xf5f5f3) }
    var online: Color { c(0x3fb950, 0x1f883d) }
    var warning: Color { c(0xd29922, 0x8a5a00) }
    // Punkt „nicht alle eingehängt / Problem“
    var partial: Color { c(0xf0883e, 0xe16f24) }
    var error: Color { c(0xf85149, 0xc62828) }
}

extension Font {
    static func mono(_ size: CGFloat = 13, semibold: Bool = false) -> Font {
        .custom(semibold ? "JetBrainsMono-SemiBold" : "JetBrainsMono-Regular", size: size)
    }
}

struct FerryButtonStyle: ButtonStyle {
    let theme: Theme
    var primary = false
    /// 26 im Panel, 32 (wie Ferry) in größeren Fenstern
    var height: CGFloat = 26
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.mono(height > 26 ? 13 : 12, semibold: primary))
            .foregroundColor(!enabled ? theme.disabled : primary ? theme.onPrimary : theme.text)
            .padding(.horizontal, height > 26 ? 16 : 12)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(
                    !enabled ? Color.clear
                        : primary ? theme.primary.opacity(pressed ? 0.85 : 1)
                        : theme.text.opacity(pressed ? 0.12 : hover ? 0.06 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary && enabled ? theme.primary : theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .fixedSize()
    }
}

struct SectionTitle: View {
    let title: String
    let theme: Theme
    var body: some View {
        Text(title.uppercased())
            .font(.mono(11, semibold: true))
            .tracking(1)
            .foregroundColor(theme.muted)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Kleines „⋯“-Menü ohne Systemknopf-Optik
struct MoreMenu<Content: View>: View {
    let theme: Theme
    @ViewBuilder let content: () -> Content
    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundColor(theme.muted)
        .fixedSize()
    }
}

struct Checkbox: View {
    let title: LocalizedStringKey
    let on: Bool
    let theme: Theme
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(on ? theme.primary : theme.line, lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(on ? theme.primary : .clear))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.onPrimary).opacity(on ? 1 : 0))
                    .frame(width: 13, height: 13)
                Text(title).font(.mono()).foregroundColor(theme.text)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}


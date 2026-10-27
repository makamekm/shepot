import SwiftUI

enum Palette {
    static let background = Color(hex: 0xFAF9F6)
    static let sidebar = Color(hex: 0xF1F0EC)
    static let ink = Color(hex: 0x252624)
    static let muted = Color(hex: 0x80817A)
    static let line = Color(hex: 0xE6E5DF)
    static let accent = Color(hex: 0x7562C5)
    static let lavender = Color(hex: 0xEDE9F8)
    static let green = Color(hex: 0x4E8063)
}
extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
struct BrandMark: View {
    var size: CGFloat = 36
    var body: some View {
        HStack(spacing: size * 0.075) {
            ForEach(0..<5) { i in
                Capsule().fill(.white).frame(width: size * 0.075, height: size * [0.22, 0.43, 0.62, 0.43, 0.22][i])
            }
        }
        .frame(width: size, height: size)
        .background(Palette.ink, in: RoundedRectangle(cornerRadius: size * 0.31))
        .accessibilityHidden(true)
    }
}
struct KeyCap: View {
    var text: String = "⌃"
    var body: some View {
        Text(text).font(.system(size: 16, weight: .medium, design: .monospaced))
            .frame(width: 34, height: 31)
            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.07), radius: 0, y: 2)
    }
}
struct PrimaryButton: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: compact ? 12 : 14, weight: .semibold))
            .foregroundStyle(.white).padding(.horizontal, compact ? 15 : 21).padding(.vertical, compact ? 11 : 14)
            .background(Palette.ink.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.ink).padding(.horizontal, 13).padding(.vertical, 9)
            .background(configuration.isPressed ? Palette.line : .white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
    }
}
struct Tag: View {
    var text: String
    var color: Color = Palette.green
    var body: some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 5, height: 5); Text(text) }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6).background(color.opacity(0.08), in: Capsule())
    }
}
struct Waveform: View {
    var level: Double
    var active: Bool
    var color: Color = Palette.accent
    var height: CGFloat = 65
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.10, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<35) { i in
                    let shape = 0.18 + 0.82 * pow(max(0, sin(Double(i) * 0.53)), 2)
                    let motion = active ? 0.55 + 0.45 * sin(t * 8 + Double(i) * 0.8) : 0.8
                    Capsule().fill(color.opacity(active ? 0.9 : 0.45 + shape * 0.5))
                        .frame(width: 4, height: max(4, (active ? 8 + level * (height - 8) : height * 0.66) * shape * motion))
                }
            }.frame(height: height)
        }.accessibilityHidden(true)
    }
}
struct SectionHeading: View {
    var eyebrow: String
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(eyebrow.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Palette.muted)
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.9)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(4)
        }
    }
}

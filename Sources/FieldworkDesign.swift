import SwiftUI

/// Visual language adapted from the supplied Wes Bos Fieldwork UI only.
enum Fieldwork {
    static let paper = Color(red: 0.965, green: 0.951, blue: 0.922)
    static let ink = Color(red: 0.12, green: 0.13, blue: 0.12)
    static let secondary = Color(red: 0.39, green: 0.39, blue: 0.36)
    static let orange = Color(red: 0.76, green: 0.28, blue: 0.12)
    static let rule = Color(red: 0.81, green: 0.79, blue: 0.75)
}

struct FieldworkButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 12)
            .foregroundStyle(filled ? .white : Fieldwork.orange)
            .background(filled ? Fieldwork.orange : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Fieldwork.orange, lineWidth: filled ? 0 : 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct FieldworkEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption, design: .monospaced))
            .tracking(2)
            .foregroundStyle(Fieldwork.secondary)
    }
}

struct FieldworkRule: View {
    var body: some View { Rectangle().fill(Fieldwork.rule).frame(height: 0.5) }
}

struct FieldworkCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let d: CGFloat = 14
        for (x, y, sx, sy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0), (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            path.move(to: CGPoint(x: x, y: y + sy * d))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + sx * d, y: y))
        }
        return path
    }
}

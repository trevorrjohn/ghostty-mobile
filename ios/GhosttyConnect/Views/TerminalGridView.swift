import SwiftUI

struct TerminalGridView: View {
    let snapshot: TerminalSnapshot
    let fontSize: Double

    private var cellWidth: CGFloat { Self.cellWidth(fontSize: fontSize) }
    private var cellHeight: CGFloat { Self.cellHeight(fontSize: fontSize) }

    static func cellWidth(fontSize: Double) -> CGFloat { fontSize * 0.62 }
    static func cellHeight(fontSize: Double) -> CGFloat { fontSize * 1.35 }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Canvas { context, _ in
                drawCells(in: &context)
                drawCursor(in: &context)
            }
            .frame(
                width: CGFloat(snapshot.columns) * cellWidth,
                height: CGFloat(snapshot.rows) * cellHeight
            )
            .background(Color(snapshot.background))
        }
        .background(Color(snapshot.background))
        .accessibilityLabel("Terminal contents")
    }

    private func drawCells(in context: inout GraphicsContext) {
        for (index, cell) in snapshot.cells.enumerated() {
            let column = index % snapshot.columns
            let row = index / snapshot.columns
            let rect = CGRect(
                x: CGFloat(column) * cellWidth,
                y: CGFloat(row) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            context.fill(Path(rect), with: .color(Color(cell.background)))
            guard !cell.text.isEmpty else { continue }

            var text = Text(cell.text)
                .font(.system(
                    size: fontSize,
                    weight: cell.bold ? .bold : .regular,
                    design: .monospaced
                ))
                .foregroundStyle(Color(cell.foreground).opacity(cell.faint ? 0.65 : 1))
            if cell.italic { text = text.italic() }
            if cell.underline != .none { text = text.underline() }
            if cell.strikethrough { text = text.strikethrough() }

            context.draw(text, at: rect.origin, anchor: .topLeading)
            if cell.overline {
                let line = CGRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: 1)
                context.fill(Path(line), with: .color(Color(cell.foreground)))
            }
        }
    }

    private func drawCursor(in context: inout GraphicsContext) {
        guard let cursor = snapshot.cursor, cursor.visible else { return }
        let rect = CGRect(
            x: CGFloat(cursor.column) * cellWidth,
            y: CGFloat(cursor.row) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        let color = Color(snapshot.cursorColor)
        switch cursor.style {
        case .bar:
            context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)), with: .color(color))
        case .block:
            context.fill(Path(rect), with: .color(color.opacity(0.45)))
        case .underline:
            context.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)), with: .color(color))
        case .hollowBlock:
            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(color), lineWidth: 1)
        }
    }
}

private extension Color {
    init(_ color: TerminalColor) {
        self.init(
            .sRGB,
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255,
            opacity: 1
        )
    }
}

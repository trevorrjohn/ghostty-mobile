import SwiftUI
import UIKit

struct TerminalGridView: View {
    let snapshot: TerminalSnapshot
    let fontSize: Double
    let onTap: () -> Void
    let onDoubleTap: (Int, Int) -> Void
    let onScrollRows: (Int) -> Void
    let onSelectWord: (Int, Int) -> Void
    let onMagnify: (Double, Bool) -> Void

    private var cellWidth: CGFloat { Self.cellWidth(fontSize: fontSize) }
    private var cellHeight: CGFloat { Self.cellHeight(fontSize: fontSize) }

    static func cellWidth(fontSize: Double) -> CGFloat { fontSize * 0.62 }
    static func cellHeight(fontSize: Double) -> CGFloat { fontSize * 1.35 }

    init(
        snapshot: TerminalSnapshot,
        fontSize: Double,
        onTap: @escaping () -> Void = {},
        onDoubleTap: @escaping (Int, Int) -> Void = { _, _ in },
        onScrollRows: @escaping (Int) -> Void = { _ in },
        onSelectWord: @escaping (Int, Int) -> Void = { _, _ in },
        onMagnify: @escaping (Double, Bool) -> Void = { _, _ in }
    ) {
        self.snapshot = snapshot
        self.fontSize = fontSize
        self.onTap = onTap
        self.onDoubleTap = onDoubleTap
        self.onScrollRows = onScrollRows
        self.onSelectWord = onSelectWord
        self.onMagnify = onMagnify
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawCells(in: &context)
                drawCursor(in: &context)
            }
            .frame(
                width: CGFloat(snapshot.columns) * cellWidth,
                height: CGFloat(snapshot.rows) * cellHeight
            )
            .background(Color(snapshot.background))

            TerminalInteractionOverlay(
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                columns: snapshot.columns,
                rows: snapshot.rows,
                onTap: onTap,
                onDoubleTap: onDoubleTap,
                onScrollRows: onScrollRows,
                onSelectWord: onSelectWord,
                onMagnify: onMagnify
            )
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
            let background = cell.selected ? Color(red: 0.12, green: 0.48, blue: 0.32) : Color(cell.background)
            context.fill(Path(rect), with: .color(background))
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

private struct TerminalInteractionOverlay: UIViewRepresentable {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let columns: Int
    let rows: Int
    let onTap: () -> Void
    let onDoubleTap: (Int, Int) -> Void
    let onScrollRows: (Int) -> Void
    let onSelectWord: (Int, Int) -> Void
    let onMagnify: (Double, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.longPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        tap.require(toFail: longPress)
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: TerminalInteractionOverlay
        private var pinchStartFontSize: Double?

        init(parent: TerminalInteractionOverlay) {
            self.parent = parent
        }

        @objc func tap() {
            parent.onTap()
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            let column = min(parent.columns - 1, max(0, Int(location.x / parent.cellWidth)))
            let row = min(parent.rows - 1, max(0, Int(location.y / parent.cellHeight)))
            parent.onDoubleTap(column, row)
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .changed else { return }
            let translation = recognizer.translation(in: recognizer.view)
            let rowDelta = Int(-translation.y / parent.cellHeight)
            guard rowDelta != 0 else { return }
            parent.onScrollRows(rowDelta)
            recognizer.setTranslation(.zero, in: recognizer.view)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                pinchStartFontSize = Double(parent.cellHeight / 1.35)
            case .changed:
                guard let pinchStartFontSize else { return }
                parent.onMagnify(clampedFontSize(pinchStartFontSize * Double(recognizer.scale)), false)
            case .ended:
                guard let pinchStartFontSize else { return }
                parent.onMagnify(clampedFontSize(pinchStartFontSize * Double(recognizer.scale)), true)
                self.pinchStartFontSize = nil
            case .cancelled, .failed:
                if let pinchStartFontSize {
                    parent.onMagnify(pinchStartFontSize, true)
                }
                self.pinchStartFontSize = nil
            default:
                break
            }
        }

        private func clampedFontSize(_ fontSize: Double) -> Double {
            min(30, max(9, fontSize))
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            let column = min(parent.columns - 1, max(0, Int(location.x / parent.cellWidth)))
            let row = min(parent.rows - 1, max(0, Int(location.y / parent.cellHeight)))
            parent.onSelectWord(column, row)
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

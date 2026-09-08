import SwiftUI
import UIKit

struct TerminalGridView: View {
    let snapshot: TerminalSnapshot
    let fontSize: Double
    let onTap: () -> Void
    let onDoubleTap: (Int, Int) -> Void
    let onScrollRows: (Int) -> Void
    let onSelectWord: (Int, Int) -> Void
    let onSelectionEndpointChanged: (Bool, Int, Int) -> Void
    let onSelectionFinished: () -> Void
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
        onSelectionEndpointChanged: @escaping (Bool, Int, Int) -> Void = { _, _, _ in },
        onSelectionFinished: @escaping () -> Void = {},
        onMagnify: @escaping (Double, Bool) -> Void = { _, _ in }
    ) {
        self.snapshot = snapshot
        self.fontSize = fontSize
        self.onTap = onTap
        self.onDoubleTap = onDoubleTap
        self.onScrollRows = onScrollRows
        self.onSelectWord = onSelectWord
        self.onSelectionEndpointChanged = onSelectionEndpointChanged
        self.onSelectionFinished = onSelectionFinished
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
                selectionEndpoints: snapshot.selectionEndpoints,
                onTap: onTap,
                onDoubleTap: onDoubleTap,
                onScrollRows: onScrollRows,
                onSelectWord: onSelectWord,
                onSelectionEndpointChanged: onSelectionEndpointChanged,
                onSelectionFinished: onSelectionFinished,
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

enum TerminalSelectionEndpoint: Equatable {
    case start
    case end
}

struct TerminalSelectionDragState {
    private(set) var anchor: (column: Int, row: Int)?
    private(set) var endpoint: TerminalSelectionEndpoint?

    mutating func begin(column: Int, row: Int) {
        anchor = (column, row)
        endpoint = nil
    }

    mutating func update(column: Int, row: Int) -> TerminalSelectionEndpoint? {
        guard let anchor, anchor.column != column || anchor.row != row else { return nil }
        let beforeAnchor = row < anchor.row || (row == anchor.row && column < anchor.column)
        if endpoint == nil {
            endpoint = beforeAnchor ? .start : .end
        }
        if endpoint == .start, !beforeAnchor { return nil }
        if endpoint == .end, beforeAnchor { return nil }
        return endpoint
    }

    mutating func endpointForAutoscroll(direction: Int) -> TerminalSelectionEndpoint? {
        guard anchor != nil, direction != 0 else { return nil }
        let proposed: TerminalSelectionEndpoint = direction < 0 ? .start : .end
        if endpoint == nil { endpoint = proposed }
        return endpoint == proposed ? endpoint : nil
    }

    mutating func reset() {
        anchor = nil
        endpoint = nil
    }
}

struct TerminalSelectionAutoscrollState {
    private(set) var rowDelta = 0

    mutating func update(locationY: CGFloat, height: CGFloat, edgeHeight: CGFloat) {
        guard height > 0, edgeHeight > 0 else {
            rowDelta = 0
            return
        }
        if locationY < edgeHeight { rowDelta = -1 }
        else if locationY > height - edgeHeight { rowDelta = 1 }
        else { rowDelta = 0 }
    }

    mutating func reset() {
        rowDelta = 0
    }
}

struct TerminalSelectionHandleDragState {
    private var endpoint: TerminalSelectionEndpoint?
    private var opposite: TerminalSelectionPoint?
    private var endpointWasBeforeOpposite = false

    mutating func begin(endpoint: TerminalSelectionEndpoint, endpoints: TerminalSelectionEndpoints) {
        self.endpoint = endpoint
        let current = endpoint == .start ? endpoints.start : endpoints.end
        opposite = endpoint == .start ? endpoints.end : endpoints.start
        if let current, let opposite {
            endpointWasBeforeOpposite = Self.isBefore(current, opposite)
        }
    }

    func allows(_ point: TerminalSelectionPoint) -> Bool {
        guard endpoint != nil, let opposite, point != opposite else { return false }
        return Self.isBefore(point, opposite) == endpointWasBeforeOpposite
    }

    mutating func reset() {
        endpoint = nil
        opposite = nil
    }

    private static func isBefore(_ lhs: TerminalSelectionPoint, _ rhs: TerminalSelectionPoint) -> Bool {
        lhs.row < rhs.row || (lhs.row == rhs.row && lhs.column < rhs.column)
    }
}

private struct TerminalInteractionOverlay: UIViewRepresentable {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let columns: Int
    let rows: Int
    let selectionEndpoints: TerminalSelectionEndpoints?
    let onTap: () -> Void
    let onDoubleTap: (Int, Int) -> Void
    let onScrollRows: (Int) -> Void
    let onSelectWord: (Int, Int) -> Void
    let onSelectionEndpointChanged: (Bool, Int, Int) -> Void
    let onSelectionFinished: () -> Void
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
        longPress.numberOfTouchesRequired = 1
        for recognizer in [tap, doubleTap, pan, pinch, longPress] {
            recognizer.delegate = context.coordinator
        }
        context.coordinator.panRecognizer = pan
        context.coordinator.longPressRecognizer = longPress
        context.coordinator.installSelectionHandles(in: view)
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
        context.coordinator.updateSelectionHandles(in: view)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TerminalInteractionOverlay
        weak var panRecognizer: UIPanGestureRecognizer?
        weak var longPressRecognizer: UILongPressGestureRecognizer?
        private var pinchStartFontSize: Double?
        private var selectionDrag = TerminalSelectionDragState()
        private var selectionDragActive = false
        private var selectionAutoscroll = TerminalSelectionAutoscrollState()
        private var selectionAutoscrollTimer: Timer?
        private var selectionColumn = 0
        private let startHandle = TerminalSelectionHandleView()
        private let endHandle = TerminalSelectionHandleView()
        private var handleDrag = TerminalSelectionHandleDragState()

        init(parent: TerminalInteractionOverlay) {
            self.parent = parent
        }

        deinit {
            selectionAutoscrollTimer?.invalidate()
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
            if selectionDragActive {
                recognizer.setTranslation(.zero, in: recognizer.view)
                return
            }
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
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            let column = min(parent.columns - 1, max(0, Int(location.x / parent.cellWidth)))
            let row = min(parent.rows - 1, max(0, Int(location.y / parent.cellHeight)))
            switch recognizer.state {
            case .began:
                selectionDragActive = true
                selectionDrag.begin(column: column, row: row)
                parent.onSelectWord(column, row)
            case .changed:
                guard selectionDragActive else { return }
                if let endpoint = selectionDrag.update(column: column, row: row) {
                    parent.onSelectionEndpointChanged(endpoint == .start, column, row)
                }
                updateSelectionAutoscroll(location: location, in: view)
            case .ended:
                stopSelectionAutoscroll()
                if selectionDragActive { parent.onSelectionFinished() }
                selectionDragActive = false
                selectionDrag.reset()
            case .cancelled, .failed:
                stopSelectionAutoscroll()
                selectionDragActive = false
                selectionDrag.reset()
            default:
                break
            }
        }

        func installSelectionHandles(in view: UIView) {
            for (handle, endpoint) in [(startHandle, TerminalSelectionEndpoint.start), (endHandle, .end)] {
                handle.isAccessibilityElement = true
                handle.accessibilityLabel = endpoint == .start ? "Selection start" : "Selection end"
                handle.addGestureRecognizer(UIPanGestureRecognizer(
                    target: self,
                    action: #selector(selectionHandlePan(_:))
                ))
                view.addSubview(handle)
            }
            updateSelectionHandles(in: view)
        }

        func updateSelectionHandles(in view: UIView) {
            position(startHandle, at: parent.selectionEndpoints?.start, endpoint: .start, in: view)
            position(endHandle, at: parent.selectionEndpoints?.end, endpoint: .end, in: view)
        }

        private func position(
            _ handle: TerminalSelectionHandleView,
            at point: TerminalSelectionPoint?,
            endpoint: TerminalSelectionEndpoint,
            in view: UIView
        ) {
            guard let point else {
                handle.isHidden = true
                return
            }
            let x = CGFloat(point.column + (endpoint == .end ? 1 : 0)) * parent.cellWidth
            let y = CGFloat(point.row + 1) * parent.cellHeight
            handle.center = CGPoint(
                x: min(view.bounds.maxX - handle.bounds.width / 2, max(handle.bounds.width / 2, x)),
                y: min(view.bounds.maxY - handle.bounds.height / 2, max(handle.bounds.height / 2, y))
            )
            handle.isHidden = false
        }

        @objc private func selectionHandlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view?.superview,
                  let endpoints = parent.selectionEndpoints else { return }
            let endpoint: TerminalSelectionEndpoint = recognizer.view === startHandle ? .start : .end
            switch recognizer.state {
            case .began:
                handleDrag.begin(endpoint: endpoint, endpoints: endpoints)
            case .changed:
                let location = recognizer.location(in: view)
                let point = TerminalSelectionPoint(
                    column: min(parent.columns - 1, max(0, Int(location.x / parent.cellWidth))),
                    row: min(parent.rows - 1, max(0, Int(location.y / parent.cellHeight)))
                )
                guard handleDrag.allows(point) else { return }
                parent.onSelectionEndpointChanged(endpoint == .start, point.column, point.row)
            case .ended, .cancelled, .failed:
                handleDrag.reset()
                parent.onSelectionFinished()
            default:
                break
            }
        }

        private func updateSelectionAutoscroll(location: CGPoint, in view: UIView) {
            selectionColumn = min(parent.columns - 1, max(0, Int(location.x / parent.cellWidth)))
            selectionAutoscroll.update(
                locationY: location.y,
                height: view.bounds.height,
                edgeHeight: min(parent.cellHeight * 1.5, view.bounds.height / 4)
            )
            guard selectionDrag.endpointForAutoscroll(direction: selectionAutoscroll.rowDelta) != nil else {
                stopSelectionAutoscroll()
                return
            }
            guard selectionAutoscrollTimer == nil else { return }
            selectionAutoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.selectionAutoscrollTick()
            }
        }

        private func selectionAutoscrollTick() {
            let rowDelta = selectionAutoscroll.rowDelta
            guard selectionDragActive, rowDelta != 0,
                  let endpoint = selectionDrag.endpointForAutoscroll(direction: rowDelta) else {
                stopSelectionAutoscroll()
                return
            }
            parent.onScrollRows(rowDelta)
            let row = rowDelta < 0 ? 0 : parent.rows - 1
            parent.onSelectionEndpointChanged(endpoint == .start, selectionColumn, row)
        }

        private func stopSelectionAutoscroll() {
            selectionAutoscrollTimer?.invalidate()
            selectionAutoscrollTimer = nil
            selectionAutoscroll.reset()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            let pair = [gestureRecognizer, otherGestureRecognizer]
            return pair.contains { $0 === panRecognizer } && pair.contains { $0 === longPressRecognizer }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            return !(touch.view is TerminalSelectionHandleView)
        }
    }
}

private final class TerminalSelectionHandleView: UIView {
    init() {
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: 28, height: 28)))
        backgroundColor = UIColor(red: 0.12, green: 0.48, blue: 0.32, alpha: 1)
        layer.cornerRadius = 14
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
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

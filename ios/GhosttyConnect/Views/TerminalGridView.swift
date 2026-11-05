import SwiftUI
import UIKit

struct TerminalGridView: View {
    let snapshot: TerminalSnapshot
    let fontSize: Double
    let scrollMultiplier: Double
    let onTap: () -> Void
    let onDoubleTap: (Int, Int) -> Void
    let onScrollRows: (Int) -> Void
    let onSelectWord: (Int, Int) -> Void
    let onSelectionEndpointChanged: (Bool, Int, Int) -> Void
    let onSelectionFinished: () -> Void
    let onMagnify: (Double, Bool) -> Void
    let onQuickNavigation: (() -> Void)?
    let quickActionLabels: [TerminalQuickDirection: String]
    let onQuickAction: (TerminalQuickDirection, Int, Int) -> Void
    let interactionID: UUID?

    private var cellWidth: CGFloat { Self.cellWidth(fontSize: fontSize) }
    private var cellHeight: CGFloat { Self.cellHeight(fontSize: fontSize) }

    static func cellWidth(fontSize: Double) -> CGFloat { fontSize * 0.62 }
    static func cellHeight(fontSize: Double) -> CGFloat { fontSize * 1.35 }

    init(
        snapshot: TerminalSnapshot,
        fontSize: Double,
        scrollMultiplier: Double = 1,
        onTap: @escaping () -> Void = {},
        onDoubleTap: @escaping (Int, Int) -> Void = { _, _ in },
        onScrollRows: @escaping (Int) -> Void = { _ in },
        onSelectWord: @escaping (Int, Int) -> Void = { _, _ in },
        onSelectionEndpointChanged: @escaping (Bool, Int, Int) -> Void = { _, _, _ in },
        onSelectionFinished: @escaping () -> Void = {},
        onMagnify: @escaping (Double, Bool) -> Void = { _, _ in },
        onQuickNavigation: (() -> Void)? = nil,
        quickActionLabels: [TerminalQuickDirection: String] = [:],
        onQuickAction: @escaping (TerminalQuickDirection, Int, Int) -> Void = { _, _, _ in },
        interactionID: UUID? = nil
    ) {
        self.snapshot = snapshot
        self.fontSize = fontSize
        self.scrollMultiplier = scrollMultiplier
        self.onTap = onTap
        self.onDoubleTap = onDoubleTap
        self.onScrollRows = onScrollRows
        self.onSelectWord = onSelectWord
        self.onSelectionEndpointChanged = onSelectionEndpointChanged
        self.onSelectionFinished = onSelectionFinished
        self.onMagnify = onMagnify
        self.onQuickNavigation = onQuickNavigation
        self.quickActionLabels = quickActionLabels
        self.onQuickAction = onQuickAction
        self.interactionID = interactionID
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawCells(in: &context)
            }
            .frame(
                width: CGFloat(snapshot.columns) * cellWidth,
                height: CGFloat(snapshot.rows) * cellHeight
            )
            .background(Color(snapshot.background))

            cursorLayer

            TerminalInteractionOverlay(
                scrollMultiplier: scrollMultiplier,
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
                onMagnify: onMagnify,
                onQuickNavigation: onQuickNavigation,
                quickActionLabels: quickActionLabels,
                onQuickAction: onQuickAction,
                interactionID: interactionID
            )
        }
        .background(Color(snapshot.background))
        .accessibilityLabel("Terminal contents")
    }

    @ViewBuilder
    private var cursorLayer: some View {
        if let cursor = snapshot.cursor, cursor.visible, cursor.blinking {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                Canvas { context, _ in
                    if TerminalCursorBlinkPhase.isVisible(at: timeline.date) {
                        drawCursor(in: &context)
                    }
                }
            }
            .frame(
                width: CGFloat(snapshot.columns) * cellWidth,
                height: CGFloat(snapshot.rows) * cellHeight
            )
            .allowsHitTesting(false)
        } else {
            Canvas { context, _ in drawCursor(in: &context) }
                .frame(
                    width: CGFloat(snapshot.columns) * cellWidth,
                    height: CGFloat(snapshot.rows) * cellHeight
                )
                .allowsHitTesting(false)
        }
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

enum TerminalCursorBlinkPhase {
    static func isVisible(at date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) < 0.5
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

struct TerminalScrollAccumulator {
    private(set) var remainder: CGFloat = 0

    mutating func consume(points: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return 0 }
        remainder += points
        let rows = Int(remainder / cellHeight)
        remainder -= CGFloat(rows) * cellHeight
        return rows
    }

    mutating func reset() {
        remainder = 0
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

struct TerminalInteractionOverlay: UIViewRepresentable {
    let scrollMultiplier: Double
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
    let onQuickNavigation: (() -> Void)?
    let quickActionLabels: [TerminalQuickDirection: String]
    let onQuickAction: (TerminalQuickDirection, Int, Int) -> Void
    let interactionID: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.allowedScrollTypesMask = []
        let wheel = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.wheel(_:)))
        wheel.allowedScrollTypesMask = [.continuous, .discrete]
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.longPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        longPress.numberOfTouchesRequired = 1
        for recognizer in [tap, doubleTap, pan, wheel, pinch, longPress] {
            recognizer.delegate = context.coordinator
        }
        context.coordinator.panRecognizer = pan
        context.coordinator.wheelRecognizer = wheel
        context.coordinator.longPressRecognizer = longPress
        context.coordinator.installSelectionHandles(in: view)
        tap.require(toFail: longPress)
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(wheel)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if context.coordinator.parent.interactionID != interactionID || quickActionLabels.isEmpty || context.coordinator.parent.columns != columns || context.coordinator.parent.rows != rows {
            context.coordinator.dismissQuickActions()
        }
        context.coordinator.parent = self
        context.coordinator.updateSelectionHandles(in: view)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TerminalInteractionOverlay
        weak var panRecognizer: UIPanGestureRecognizer?
        weak var wheelRecognizer: UIPanGestureRecognizer?
        weak var longPressRecognizer: UILongPressGestureRecognizer?
        private var pinchStartFontSize: Double?
        private var selectionDrag = TerminalSelectionDragState()
        private var selectionDragActive = false
        private var quickNavigationActive = false
        private var quickActionOrigin = CGPoint.zero
        private var quickActionColumn = 0
        private var quickActionRow = 0
        private var quickActionPanel: UIView?
        private var quickActionButtons: [TerminalQuickDirection: UIButton] = [:]
        private var heldAction: ((TerminalQuickDirection, Int, Int) -> Void)?
        private var heldNavigation: (() -> Void)?
        private var selectionAutoscroll = TerminalSelectionAutoscrollState()
        private var selectionAutoscrollTimer: Timer?
        private var selectionColumn = 0
        private let startHandle = TerminalSelectionHandleView()
        private let endHandle = TerminalSelectionHandleView()
        private var handleDrag = TerminalSelectionHandleDragState()
        private var scrollAccumulator = TerminalScrollAccumulator()
        private var inertiaDisplayLink: CADisplayLink?
        private var inertiaVelocity: CGFloat = 0
        private var inertiaTimestamp: CFTimeInterval?

        init(parent: TerminalInteractionOverlay) {
            self.parent = parent
        }

        deinit {
            selectionAutoscrollTimer?.invalidate()
            inertiaDisplayLink?.invalidate()
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
            if selectionDragActive || quickNavigationActive {
                recognizer.setTranslation(.zero, in: recognizer.view)
                return
            }
            switch recognizer.state {
            case .began:
                stopInertia()
                scrollAccumulator.reset()
            case .changed:
                consumeScroll(recognizer)
            case .ended:
                consumeScroll(recognizer)
                guard !UIAccessibility.isReduceMotionEnabled else { return }
                startInertia(velocity: -recognizer.velocity(in: recognizer.view).y * parent.scrollMultiplier)
            case .cancelled, .failed:
                scrollAccumulator.reset()
            default:
                break
            }
        }

        @objc func wheel(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { stopInertia() }
            if recognizer.state == .changed || recognizer.state == .ended {
                consumeScroll(recognizer)
            }
            if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                scrollAccumulator.reset()
            }
        }

        private func consumeScroll(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            let rows = scrollAccumulator.consume(points: -translation.y * parent.scrollMultiplier, cellHeight: parent.cellHeight)
            if rows != 0 { parent.onScrollRows(rows) }
        }

        private func startInertia(velocity: CGFloat) {
            guard abs(velocity) >= parent.cellHeight * 2 else {
                scrollAccumulator.reset()
                return
            }
            inertiaVelocity = velocity
            inertiaTimestamp = nil
            let displayLink = CADisplayLink(target: self, selector: #selector(inertiaTick(_:)))
            displayLink.add(to: .main, forMode: .common)
            inertiaDisplayLink = displayLink
        }

        @objc private func inertiaTick(_ displayLink: CADisplayLink) {
            defer { inertiaTimestamp = displayLink.timestamp }
            guard let previous = inertiaTimestamp else { return }
            let elapsed = min(0.05, displayLink.timestamp - previous)
            let rows = scrollAccumulator.consume(
                points: inertiaVelocity * elapsed,
                cellHeight: parent.cellHeight
            )
            if rows != 0 { parent.onScrollRows(rows) }
            inertiaVelocity *= pow(0.92, elapsed * 60)
            if abs(inertiaVelocity) < parent.cellHeight { stopInertia() }
        }

        private func stopInertia() {
            inertiaDisplayLink?.invalidate()
            inertiaDisplayLink = nil
            inertiaTimestamp = nil
            inertiaVelocity = 0
            scrollAccumulator.reset()
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

        func dismissQuickActions() {
            quickActionPanel?.removeFromSuperview()
            quickActionPanel = nil
            quickActionButtons = [:]
            heldAction = nil
            heldNavigation = nil
            quickNavigationActive = false
        }

        private func performHeldAction(_ direction: TerminalQuickDirection) {
            let action = heldAction
            let column = quickActionColumn
            let row = quickActionRow
            dismissQuickActions()
            action?(direction, column, row)
        }

        private func showQuickActions(in view: UIView) {
            let panel = UIView()
            panel.backgroundColor = .secondarySystemBackground
            panel.layer.cornerRadius = 14
            panel.layer.shadowOpacity = 0.3
            panel.layer.shadowRadius = 8
            let width = min(300, view.bounds.width - 12)
            let height: CGFloat = 156
            panel.frame = CGRect(x: max(6, min(view.bounds.width - width - 6, quickActionOrigin.x - width / 2)),
                                 y: max(0, min(view.bounds.height - height, quickActionOrigin.y - height / 2)),
                                 width: width, height: height)
            func button(_ title: String, column: Int, row: Int, action: @escaping () -> Void) -> UIButton {
                let button = UIButton(type: .system)
                var config = UIButton.Configuration.tinted()
                config.title = title
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var attributes = attributes
                    attributes.font = .preferredFont(forTextStyle: .caption1)
                    return attributes
                }
                button.configuration = config
                button.titleLabel?.numberOfLines = 2
                button.frame = CGRect(x: CGFloat(column) * width / 3 + 2, y: CGFloat(row) * 52 + 2,
                                      width: width / 3 - 4, height: 48)
                button.addAction(UIAction { _ in action() }, for: .touchUpInside)
                panel.addSubview(button)
                return button
            }
            let positions: [(TerminalQuickDirection, Int, Int, String)] = [
                (.up, 1, 0, "↑"), (.left, 0, 1, "←"), (.right, 2, 1, "→"), (.down, 1, 2, "↓"),
            ]
            for (direction, column, row, arrow) in positions {
                quickActionButtons[direction] = button("\(arrow) \(parent.quickActionLabels[direction] ?? "Unavailable")", column: column, row: row) { [weak self] in
                    self?.performHeldAction(direction)
                }
            }
            _ = button("Sessions", column: 1, row: 1) { [weak self] in
                let action = self?.heldNavigation
                self?.dismissQuickActions()
                action?()
            }
            _ = button("Cancel", column: 2, row: 0) { [weak self] in self?.dismissQuickActions() }
            view.addSubview(panel)
            quickActionPanel = panel
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            let column = min(parent.columns - 1, max(0, Int(location.x / parent.cellWidth)))
            let row = min(parent.rows - 1, max(0, Int(location.y / parent.cellHeight)))
            switch recognizer.state {
            case .began:
                stopInertia()
                if !parent.quickActionLabels.isEmpty, !UIAccessibility.isVoiceOverRunning {
                    dismissQuickActions()
                    quickNavigationActive = true
                    quickActionOrigin = location
                    quickActionColumn = column
                    quickActionRow = row
                    heldAction = parent.onQuickAction
                    heldNavigation = parent.onQuickNavigation
                    showQuickActions(in: view)
                    return
                }
                if let quickNavigation = parent.onQuickNavigation, !UIAccessibility.isVoiceOverRunning {
                    quickNavigationActive = true
                    quickNavigation()
                    return
                }
                selectionDragActive = true
                selectionDrag.begin(column: column, row: row)
                parent.onSelectWord(column, row)
            case .changed:
                if quickActionPanel != nil {
                    let direction = TerminalQuickDirection.resolve(dx: location.x - quickActionOrigin.x, dy: location.y - quickActionOrigin.y)
                    for (candidate, button) in quickActionButtons { button.isHighlighted = candidate == direction }
                    return
                }
                guard selectionDragActive else { return }
                if let endpoint = selectionDrag.update(column: column, row: row) {
                    parent.onSelectionEndpointChanged(endpoint == .start, column, row)
                }
                updateSelectionAutoscroll(location: location, in: view)
            case .ended:
                if quickActionPanel != nil {
                    if let direction = TerminalQuickDirection.resolve(dx: location.x - quickActionOrigin.x, dy: location.y - quickActionOrigin.y) {
                        performHeldAction(direction)
                    }
                    // A centered release pins the native buttons until selection or Cancel.
                    return
                }
                quickNavigationActive = false
                stopSelectionAutoscroll()
                if selectionDragActive { parent.onSelectionFinished() }
                selectionDragActive = false
                selectionDrag.reset()
            case .cancelled, .failed:
                dismissQuickActions()
                quickNavigationActive = false
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
            if let panel = quickActionPanel, touch.view?.isDescendant(of: panel) == true { return false }
            if gestureRecognizer === wheelRecognizer { return false }
            if quickActionPanel != nil { dismissQuickActions(); return false }
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

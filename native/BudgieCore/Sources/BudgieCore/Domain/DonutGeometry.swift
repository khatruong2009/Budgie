import Foundation

/// The Spend donut's ring (Flutter `CategoryDonutChart` and `_DonutPainter`,
/// widgets/category_donut_chart.dart). Pure geometry: drawing, the sweep-in
/// and hit testing, all from the slice values in slice order.
///
/// Angles are in radians in Flutter's canvas convention: 0 points to 3
/// o'clock and positive angles turn clockwise on screen (y grows downward),
/// so 12 o'clock is -π/2.
public struct DonutGeometry: Sendable, Equatable {
    /// Default diameter (`size`, :66; the Spend page uses the default).
    public static let size = 240.0
    /// `_ringThickness` (:171): the ring spans r 90...120.
    public static let ringThickness = 30.0
    /// `_gapFraction` (:172): each drawn arc is shortened by 0.5% of the
    /// circle at its trailing (clockwise) end.
    public static let gapFraction = 0.005
    /// The selected arc is 6 thicker (:287) on a radius 3 smaller (:270-273),
    /// so its outer edge stays at 120 and it grows inward to r 84.
    public static let selectedExtraThickness = 6.0
    public static let selectedRadiusInset = 3.0
    /// The centre disc is inset `ringThickness + 8` (:208-212): radius 82 at
    /// the default size, filled with the page background.
    public static let centreDiscInset = ringThickness + 8
    /// Entry sweep: 500 ms, `Curves.easeOut` = cubic (0, 0, 0.58, 1) (:82-86).
    /// Instant under Reduce Motion. Replays on mount and when the month
    /// (year and month) changes, not on selection or data changes.
    public static let sweepDuration = 0.5
    public static let sweepCurve = (x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0)

    /// One stroked arc (butt caps).
    public struct Arc: Sendable, Equatable {
        /// The slice it draws.
        public let index: Int
        public let startAngle: Double
        /// Always > 0: slices whose sweep minus the gap is not positive draw
        /// nothing and get no arc.
        public let sweepAngle: Double
        /// Radius of the stroke's centre line.
        public let radius: Double
        public let lineWidth: Double

        public var endAngle: Double { startAngle + sweepAngle }
        public var outerRadius: Double { radius + lineWidth / 2 }
    }

    /// What a tap does to the selection (`_handleTapUp`, :124-139).
    public enum Tap: Sendable, Equatable {
        /// Select this slice (selection-click haptic).
        case select(Int)
        /// Clear the selection (selection-click haptic).
        case deselect
        /// Nothing happens and there is no haptic: the tap missed every
        /// slice while nothing was selected, or fell outside the square.
        case ignore
    }

    /// Slice values in slice order (`CategorySlice.value`).
    public let values: [Double]

    public init(values: [Double]) {
        self.values = values
    }

    /// `slices.fold(0.0, (sum, s) => sum + s.value)`.
    private var total: Double { values.reduce(0.0) { $0 + $1 } }

    /// The arcs `_DonutPainter.paint` draws (:242-304) at `sweep` progress
    /// (the eased animation value, 0...1; 1 when settled). The progress
    /// scales every share and the running cursor, so the whole ring sweeps
    /// out clockwise from 12 o'clock keeping its proportions; the gap is
    /// subtracted at every frame, so small slices appear late. The first
    /// slice starts exactly at 12 o'clock. A slice under 0.5% of the total
    /// (or zero, or negative) draws nothing but keeps its hit range.
    /// Nothing is drawn when the total is not positive.
    public func arcs(in size: CGSize = CGSize(width: DonutGeometry.size, height: DonutGeometry.size),
                     sweep: Double = 1, selectedIndex: Int?) -> [Arc] {
        let total = self.total
        guard total > 0 else { return [] }
        let outerRadius = Double(min(size.width, size.height)) / 2
        let thickness = Self.ringThickness
        let baseRadius = outerRadius - thickness / 2
        let selectedRadius = outerRadius - thickness / 2 - Self.selectedRadiusInset
        let startAngle = -Double.pi / 2
        let gapAngle = 2 * Double.pi * Self.gapFraction

        var arcs: [Arc] = []
        var cursor = 0.0
        for (index, value) in values.enumerated() {
            let share = value / total
            let sweepAngle = 2 * Double.pi * share * sweep
            let isSelected = index == selectedIndex
            // math.max(sweepAngle - gapAngle, 0.0), drawn only when > 0.
            let drawSweep = Swift.max(sweepAngle - gapAngle, 0.0)
            if drawSweep > 0 {
                arcs.append(Arc(
                    index: index, startAngle: startAngle + 2 * Double.pi * cursor, sweepAngle: drawSweep,
                    radius: isSelected ? selectedRadius : baseRadius,
                    lineWidth: isSelected ? thickness + Self.selectedExtraThickness : thickness))
            }
            cursor += share * sweep
        }
        return arcs
    }

    /// `_hitTest` (:143-169): the slice under `point` (in the donut's own
    /// square, origin top-left), or nil. Only the annulus 90...120 (both
    /// edges included) hits; the selected slice's inward growth (r 84..<90)
    /// and the centre do not. The angle runs clockwise from 12 o'clock and
    /// each slice owns [cursor, cursor + value / total) of the turn with no
    /// gap, so a tap in a gap belongs to the slice before it. Zero and
    /// negative slices never hit. Independent of the sweep animation.
    /// Points outside the square return nil (Flutter never sees them).
    public func hitTest(point: CGPoint, in size: CGSize) -> Int? {
        let x = Double(point.x), y = Double(point.y)
        let width = Double(size.width), height = Double(size.height)
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        // Flutter uses the square's side for both (`widget.size / 2`).
        let outerRadius = Swift.min(width, height) / 2
        let centerHole = outerRadius - Self.ringThickness
        let dx = x - width / 2
        let dy = y - height / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < centerHole || distance > outerRadius { return nil }

        let total = self.total
        if total <= 0 { return nil }

        var angle = atan2(dy, dx) + Double.pi / 2
        if angle < 0 { angle += 2 * Double.pi }
        let fraction = angle / (2 * Double.pi)

        var cursor = 0.0
        for (index, value) in values.enumerated() {
            let share = value / total
            if fraction >= cursor && fraction < cursor + share { return index }
            cursor += share
        }
        return nil
    }

    /// `_handleTapUp` (:124-139) with the current selection (nil = none).
    /// A miss deselects only when something is selected; a tap on the
    /// selected slice deselects it; any other slice becomes selected. A
    /// stale selection (no longer a slice) still counts as selected.
    public func tap(at point: CGPoint, in size: CGSize, selectedIndex: Int?) -> Tap {
        let x = Double(point.x), y = Double(point.y)
        guard x >= 0, y >= 0, x < Double(size.width), y < Double(size.height) else { return .ignore }
        guard let index = hitTest(point: point, in: size) else {
            return selectedIndex == nil ? .ignore : .deselect
        }
        return index == selectedIndex ? .deselect : .select(index)
    }
}

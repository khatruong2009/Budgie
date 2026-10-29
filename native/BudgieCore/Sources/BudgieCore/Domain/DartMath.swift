import Foundation

// `dart:math` and `num` helpers on doubles, shared by the Worth and Flow
// math (NetWorthPresentation, CashFlowMath) so both fold values as Dart.

/// Dart `dart:math` `max`/`min` on doubles (NaN wins; `max(-0.0, 0.0)` is 0.0).
func dartMax(_ a: Double, _ b: Double) -> Double {
    if a > b { return a }
    if a < b { return b }
    if a == 0 && b == 0 { return a.sign == .minus ? b : a }
    return b.isNaN ? b : a
}

func dartMin(_ a: Double, _ b: Double) -> Double {
    if a > b { return b }
    if a < b { return a }
    if a == 0 && b == 0 { return a.sign == .minus ? a : b }
    return b.isNaN ? b : a
}

/// Dart `num.clamp` for doubles in range order.
func dartClamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    if value < lower { return lower }
    if value > upper { return upper }
    return value
}

/// Dart `double.compareTo`: -0.0 before 0.0, NaN after everything.
func dartCompare(_ a: Double, _ b: Double) -> Int {
    if a < b { return -1 }
    if a > b { return 1 }
    if a == b {
        if a == 0 && a.sign != b.sign { return a.sign == .minus ? -1 : 1 }
        return 0
    }
    if a.isNaN { return b.isNaN ? 0 : 1 }
    return -1
}

/// Dart `num.clamp` on doubles: `compareTo` order, so -0.0 clamps up to a
/// 0.0 lower bound and NaN clamps to the upper bound.
func dartClampExact(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    if dartCompare(value, lower) < 0 { return lower }
    if dartCompare(value, upper) > 0 { return upper }
    return value
}

/// Dart's `List.sort`, element for element.
///
/// The Dart VM sorts every list with `Sort.sort` (dart:_internal
/// `sort.dart`): an insertion sort when the range spans at most 32 steps
/// (`right - left <= 32`, so lists of up to 33 elements), otherwise
/// Yaroslavskiy's dual-pivot quicksort. The insertion sort is stable; the
/// quicksort is not, so from 34 elements up the order of elements the
/// comparator calls equal depends on the algorithm. Swift's `sort` is
/// stable, so wherever Dart sorts a list whose ties are visible (rules of
/// equal priority, rows with the same date), use this to get Dart's order.
///
/// Verified against the Dart VM on random lists with many ties
/// (Fixtures/backup/dart_sort.json).
public enum DartSort {
    /// `Sort._INSERTION_SORT_THRESHOLD`: ranges with `right - left` up to
    /// this use insertion sort.
    public static let insertionSortThreshold = 32

    /// Dart `list.sort(compare)`. `compare` returns a negative number, zero
    /// or a positive number, like Dart's `Comparator`.
    public static func sort<E>(_ list: inout [E], by compare: (E, E) -> Int) {
        guard list.count > 1 else { return }
        doSort(&list, 0, list.count - 1, compare)
    }

    /// A sorted copy (`List.of(items)..sort(compare)`).
    public static func sorted<S: Sequence>(_ items: S, by compare: (S.Element, S.Element) -> Int) -> [S.Element] {
        var list = Array(items)
        sort(&list, by: compare)
        return list
    }

    /// Dart `int.compareTo`.
    public static func compare<T: BinaryInteger>(_ a: T, _ b: T) -> Int {
        a < b ? -1 : a > b ? 1 : 0
    }

    /// Dart `double.compareTo`: -0.0 sorts before 0.0, and NaN after
    /// everything (equal to itself).
    public static func compare(_ a: Double, _ b: Double) -> Int {
        if a < b { return -1 }
        if a > b { return 1 }
        if a == b {
            if a == 0 {
                let aNegative = a.sign == .minus, bNegative = b.sign == .minus
                if aNegative == bNegative { return 0 }
                return aNegative ? -1 : 1
            }
            return 0
        }
        if a.isNaN { return b.isNaN ? 0 : 1 }
        return -1
    }

    /// Dart `String.compareTo`: UTF-16 code-unit order.
    public static func compare(_ a: String, _ b: String) -> Int {
        a.utf16.lexicographicallyPrecedes(b.utf16) ? -1 : a.utf16.elementsEqual(b.utf16) ? 0 : 1
    }

    // MARK: - Port of dart:_internal Sort

    private static func doSort<E>(_ a: inout [E], _ left: Int, _ right: Int, _ compare: (E, E) -> Int) {
        if right - left <= insertionSortThreshold {
            insertionSort(&a, left, right, compare)
        } else {
            dualPivotQuicksort(&a, left, right, compare)
        }
    }

    private static func insertionSort<E>(_ a: inout [E], _ left: Int, _ right: Int, _ compare: (E, E) -> Int) {
        var i = left + 1
        while i <= right {
            let el = a[i]
            var j = i
            while j > left && compare(a[j - 1], el) > 0 {
                a[j] = a[j - 1]
                j -= 1
            }
            a[j] = el
            i += 1
        }
    }

    private static func dualPivotQuicksort<E>(_ a: inout [E], _ left: Int, _ right: Int, _ compare: (E, E) -> Int) {
        // Compute the two pivots by looking at 5 elements.
        let sixth = (right - left + 1) / 6
        let index1 = left + sixth
        let index5 = right - sixth
        let index3 = (left + right) / 2  // The midpoint.
        let index2 = index3 - sixth
        let index4 = index3 + sixth

        var el1 = a[index1]
        var el2 = a[index2]
        var el3 = a[index3]
        var el4 = a[index4]
        var el5 = a[index5]

        // Sort the selected 5 elements using a sorting network.
        if compare(el1, el2) > 0 { swap(&el1, &el2) }
        if compare(el4, el5) > 0 { swap(&el4, &el5) }
        if compare(el1, el3) > 0 { swap(&el1, &el3) }
        if compare(el2, el3) > 0 { swap(&el2, &el3) }
        if compare(el1, el4) > 0 { swap(&el1, &el4) }
        if compare(el3, el4) > 0 { swap(&el3, &el4) }
        if compare(el2, el5) > 0 { swap(&el2, &el5) }
        if compare(el2, el3) > 0 { swap(&el2, &el3) }
        if compare(el4, el5) > 0 { swap(&el4, &el5) }

        let pivot1 = el2
        let pivot2 = el4

        // el2 and el4 are held in the pivots and written back after the
        // partitioning.
        a[index1] = el1
        a[index3] = el3
        a[index5] = el5

        a[index2] = a[left]
        a[index4] = a[right]

        var less = left + 1  // First element in the middle partition.
        var great = right - 1  // Last element in the middle partition.

        let pivotsAreEqual = compare(pivot1, pivot2) == 0
        if pivotsAreEqual {
            let pivot = pivot1
            // Dutch national flag partitioning around one pivot.
            var k = less
            while k <= great {
                defer { k += 1 }
                let ak = a[k]
                var comp = compare(ak, pivot)
                if comp == 0 { continue }
                if comp < 0 {
                    if k != less {
                        a[k] = a[less]
                        a[less] = ak
                    }
                    less += 1
                } else {
                    while true {
                        comp = compare(a[great], pivot)
                        if comp > 0 {
                            great -= 1
                            continue
                        }
                        exchange(&a, k, ak, &less, &great, intoLow: comp < 0)
                        break
                    }
                }
            }
        } else {
            // Partition into < pivot1, [pivot1, pivot2], > pivot2.
            var k = less
            while k <= great {
                defer { k += 1 }
                let ak = a[k]
                let compPivot1 = compare(ak, pivot1)
                if compPivot1 < 0 {
                    if k != less {
                        a[k] = a[less]
                        a[less] = ak
                    }
                    less += 1
                } else {
                    let compPivot2 = compare(ak, pivot2)
                    if compPivot2 > 0 {
                        while true {
                            if compare(a[great], pivot2) > 0 {
                                great -= 1
                                if great < k { break }
                                continue
                            }
                            exchange(&a, k, ak, &less, &great, intoLow: compare(a[great], pivot1) < 0)
                            break
                        }
                    }
                }
            }
        }

        // Move the pivots into their final positions.
        a[left] = a[less - 1]
        a[less - 1] = pivot1
        a[right] = a[great + 1]
        a[great + 1] = pivot2

        // Recursive descent, without the pivots.
        doSort(&a, left, less - 2, compare)
        doSort(&a, great + 2, right, compare)

        if pivotsAreEqual {
            // The middle partition equals the pivot: nothing to sort.
            return
        }

        // Android's refinement: when the middle partition is large, take the
        // pivot values out of it before recursing.
        if less < index1 && great > index5 {
            while compare(a[less], pivot1) == 0 { less += 1 }
            while compare(a[great], pivot2) == 0 { great -= 1 }

            // Partition into == pivot1, (pivot1, pivot2), == pivot2.
            var k = less
            while k <= great {
                defer { k += 1 }
                let ak = a[k]
                let compPivot1 = compare(ak, pivot1)
                if compPivot1 == 0 {
                    if k != less {
                        a[k] = a[less]
                        a[less] = ak
                    }
                    less += 1
                } else {
                    let compPivot2 = compare(ak, pivot2)
                    if compPivot2 == 0 {
                        while true {
                            if compare(a[great], pivot2) == 0 {
                                great -= 1
                                if great < k { break }
                                continue
                            }
                            exchange(&a, k, ak, &less, &great, intoLow: compare(a[great], pivot1) < 0)
                            break
                        }
                    }
                }
            }
        }
        doSort(&a, less, great, compare)
    }

    /// Moves `ak` (the element at `k`) out and `a[great]` into the slot at
    /// `k`; with `intoLow` the old `a[less]` takes `a[great]`'s place first
    /// (the triple exchange), keeping Dart's write order.
    private static func exchange<E>(
        _ a: inout [E], _ k: Int, _ ak: E, _ less: inout Int, _ great: inout Int, intoLow: Bool
    ) {
        if intoLow {
            a[k] = a[less]
            a[less] = a[great]
            less += 1
        } else {
            a[k] = a[great]
        }
        a[great] = ak
        great -= 1
    }
}

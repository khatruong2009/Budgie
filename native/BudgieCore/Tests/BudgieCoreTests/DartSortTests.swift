import Foundation
import Testing

@testable import BudgieCore

@Suite("DartSort: Dart's List.sort, including its tie order")
struct DartSortTests {
    struct Vector {
        let keys: [Int]
        let ascending: [Int]
        let descending: [Int]
    }

    static func vectors() throws -> (firstUnstable: Int, cases: [Vector]) {
        let fixture = try Fixtures.json("backup/dart_sort.json")
        let cases = fixture["cases"].array.map { item in
            Vector(
                keys: item["keys"].array.map { $0.int! },
                ascending: item["ascending"].array.map { $0.int! },
                descending: item["descending"].array.map { $0.int! })
        }
        return (fixture["firstUnstableLength"].int!, cases)
    }

    @Test("same permutation as the Dart VM on every vector (both directions)")
    func matchesDart() throws {
        let (_, cases) = try Self.vectors()
        #expect(cases.count > 500)
        for vector in cases {
            let keys = vector.keys
            let ascending = DartSort.sorted(keys.indices) { DartSort.compare(keys[$0], keys[$1]) }
            #expect(ascending == vector.ascending, "ascending, n=\(keys.count)")
            let descending = DartSort.sorted(keys.indices) { DartSort.compare(keys[$1], keys[$0]) }
            #expect(descending == vector.descending, "descending, n=\(keys.count)")
        }
    }

    @Test("stable up to 33 elements, unstable from 34 (the verified threshold)")
    func threshold() throws {
        let (firstUnstable, cases) = try Self.vectors()
        #expect(firstUnstable == 34)
        #expect(DartSort.insertionSortThreshold + 2 == firstUnstable)
        var sawUnstableAt34 = false
        for vector in cases {
            let keys = vector.keys
            let stable = keys.indices.sorted { keys[$0] != keys[$1] ? keys[$0] < keys[$1] : $0 < $1 }
            if keys.count <= 33 {
                #expect(vector.ascending == stable)
            } else if keys.count == 34 && vector.ascending != stable {
                sawUnstableAt34 = true
            }
        }
        #expect(sawUnstableAt34)
    }

    @Test("compare helpers follow Dart's compareTo")
    func compareHelpers() {
        #expect(DartSort.compare(1, 2) == -1)
        #expect(DartSort.compare(Int64.max, Int64.min) == 1)
        #expect(DartSort.compare(-0.0, 0.0) == -1)
        #expect(DartSort.compare(0.0, -0.0) == 1)
        #expect(DartSort.compare(Double.nan, .infinity) == 1)
        #expect(DartSort.compare(Double.nan, .nan) == 0)
        #expect(DartSort.compare(-Double.infinity, .nan) == -1)
        // UTF-16 order: U+FF5E sorts after U+1F600 (a surrogate pair, 0xD83D...).
        #expect(DartSort.compare("\u{FF5E}", "\u{1F600}") == 1)
        #expect(DartSort.compare("é", "e\u{301}") == 1)
        #expect(DartSort.compare("ab", "abc") == -1)
        #expect(DartSort.compare("", "") == 0)
    }

    @Test("sorts objects in place and handles tiny lists")
    func basics() {
        var empty: [Int] = []
        DartSort.sort(&empty) { DartSort.compare($0, $1) }
        #expect(empty.isEmpty)
        var list = Array((0..<500).reversed())
        DartSort.sort(&list) { DartSort.compare($0, $1) }
        #expect(list == Array(0..<500))
    }
}

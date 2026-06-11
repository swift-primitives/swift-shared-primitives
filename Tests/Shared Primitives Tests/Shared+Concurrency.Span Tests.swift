import Shared_Primitive
import Buffer_Primitive
import Buffer_Linear_Primitive
import Storage_Contiguous_Primitives
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Index_Primitives
import Synchronization
import Testing

// W2 adversarial suite 3 — withUnique VS LIVE SPANS, lawful compositions only
// (GOAL-tower-arc-shared-soundness §W2.3).
//
// Span borrows END before any detach; exclusivity + the `@_lifetime` window are
// honored by construction at every call site below. The ACCEPTED residuals are NOT
// test targets (per the c27eaa7 blessing record): sibling misuse is UB-by-contract
// and same-handle overlap is compiler-excluded — no test here instantiates UB and
// asserts a defined outcome.
//
// Move-only rung note (structural): siblings of a `~Copyable`-element column are
// UNCONSTRUCTIBLE (`Shared: Copyable` requires `Element: Copyable`), so the
// detach-race misuse class cannot exist for it BY CONSTRUCTION — that is the
// design-strength datum, not a coverage gap. Cross-task transfer of a live
// move-only column is STRUCTURED-only on 6.3.2 (the `sending` spike: the
// `Task {}`/`addTask` escaping-capture wall, REPORT-W4 §ADDENDUM), so the lawful
// concurrent surface exercised here is task-LOCAL columns + exact teardown.

private typealias HeapColumn<E: ~Copyable> =
    Buffer<Storage<Memory.Allocator<Memory.Heap>.System>.Contiguous<E>>.Linear
private typealias SharedColumn<E: ~Copyable> = Shared<E, HeapColumn<E>>

private func makeShared<E>(capacity: UInt) -> SharedColumn<E> {
    SharedColumn<E>(HeapColumn<E>(minimumCapacity: Index<E>.Count(capacity)))
}

private func makeSharedMoveOnly<E: ~Copyable>(capacity: UInt) -> SharedColumn<E> {
    SharedColumn<E>(HeapColumn<E>(minimumCapacity: Index<E>.Count(capacity)))
}

private enum Ledger {
    static let created = Atomic<Int>(0)
    static let destroyed = Atomic<Int>(0)
    static func reset() {
        created.store(0, ordering: .sequentiallyConsistent)
        destroyed.store(0, ordering: .sequentiallyConsistent)
    }
}

/// Move-only element with ledgered teardown (concurrent task-local columns).
private struct Item: ~Copyable {
    let id: Int
    init(_ id: Int) {
        self.id = id
        _ = Ledger.created.wrappingAdd(1, ordering: .relaxed)
    }
    deinit {
        _ = Ledger.destroyed.wrappingAdd(1, ordering: .relaxed)
    }
}

@Suite
struct SharedConcurrencySpanWindowTests {

    @Test(arguments: [4, 12])
    func `span borrows end before detach; the window holds under concurrency`(width: Int) async {
        var proto: SharedColumn<Int> = makeShared(capacity: 8)
        proto.append(1)
        proto.append(2)
        proto.append(3)
        let frozen = proto
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for t in 0..<width {
                group.addTask {
                    var mine = frozen
                    let before = mine.withSpan { span in     // borrow ends at return…
                        var acc = 0
                        for i in 0..<span.count { acc &+= span[i] }
                        return acc
                    }
                    let sharedBefore = (mine._boxID == frozen._boxID)
                    mine.withUnique { column in              // …then the gate detaches
                        column.append(40 &+ t)
                    }
                    let diverged = (mine._boxID != frozen._boxID)
                    let after = mine.withSpan { span in      // fresh borrow on the new box
                        var acc = 0
                        for i in 0..<span.count { acc &+= span[i] }
                        return acc
                    }
                    return before == 6 && sharedBefore && diverged && after == 46 &+ t
                }
            }
            var out: [Bool] = []
            for await ok in group { out.append(ok) }
            return out
        }
        #expect(outcomes.count == width)
        #expect(outcomes.allSatisfy { $0 })
    }

    @Test
    func `borrow-only traffic never trips the gate`() async {
        var proto: SharedColumn<Int> = makeShared(capacity: 4)
        proto.append(7)
        proto.append(8)
        let frozen = proto
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let mine = frozen
                    var good = true
                    for _ in 0..<200 {
                        let stillShared = (mine._boxID == frozen._boxID)
                        let viaColumn = mine.withColumn { column in
                            column.count == Index<Int>.Count(2)
                        }
                        let viaSpan = mine.withSpan { span in
                            span.count == 2 && span[0] == 7 && span[1] == 8
                        }
                        good = good && stillShared && viaColumn && viaSpan
                    }
                    return good
                }
            }
            var out: [Bool] = []
            for await ok in group { out.append(ok) }
            return out
        }
        #expect(outcomes.count == 12)
        #expect(outcomes.allSatisfy { $0 })
        let sourceUntouched = (proto._boxID == frozen._boxID)
        #expect(sourceUntouched)                             // reads NEVER detached anything
    }

    @Test(arguments: [4, 12])
    func `the payload-threading withUnique form moves values in lawfully`(width: Int) async {
        var proto: SharedColumn<Int> = makeShared(capacity: 8)
        proto.append(5)
        let frozen = proto
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for t in 0..<width {
                group.addTask {
                    var mine = frozen
                    mine.withUnique(consuming: 90 &+ t) { column, value in
                        column.append(value)
                    }
                    return mine.withSpan { span in
                        span.count == 2 && span[0] == 5 && span[1] == 90 &+ t
                    }
                }
            }
            var out: [Bool] = []
            for await ok in group { out.append(ok) }
            return out
        }
        #expect(outcomes.count == width)
        #expect(outcomes.allSatisfy { $0 })
    }
}

// MARK: - Move-only rung (task-local statically-unique columns; serialized for the
// file-global ledger)

@Suite(.serialized)
struct SharedConcurrencyMoveOnlyTests {

    @Test
    func `concurrent task-local move-only columns: no-op gates and exact teardown`() async {
        Ledger.reset()
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for t in 0..<12 {
                group.addTask {
                    var column: SharedColumn<Item> = makeSharedMoveOnly(capacity: 8)
                    column.appendAssumingUnique(Item(t &* 10))
                    column.appendAssumingUnique(Item(t &* 10 &+ 1))
                    column.withUnique { buffer in            // the gate is the lawful no-op here
                        buffer.append(Item(t &* 10 &+ 2))
                    }
                    let took = column.removeLastAssumingUnique()
                    let tookID = took.id
                    _ = consume took
                    let n = column.count
                    return tookID == t &* 10 &+ 2 && n == Index<Item>.Count(2)
                }                                            // column dies in-task: box drains here
            }
            var out: [Bool] = []
            for await ok in group { out.append(ok) }
            return out
        }
        #expect(outcomes.count == 12)
        #expect(outcomes.allSatisfy { $0 })
        // 12 tasks × 3 items, every one destroyed exactly once on its task's thread.
        let created = Ledger.created.load(ordering: .sequentiallyConsistent)
        let destroyed = Ledger.destroyed.load(ordering: .sequentiallyConsistent)
        #expect(created == 36)
        #expect(destroyed == created)
    }
}

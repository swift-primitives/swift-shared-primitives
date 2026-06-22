import Shared_Primitive
import Buffer_Primitive
import Buffer_Linear_Primitive
import Storage_Contiguous_Primitives
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Index_Primitives
import Synchronization
import Testing

// W2 adversarial suite 2 — SIBLING STORMS (GOAL-tower-arc-shared-soundness §W2.2).
//
// Many siblings of one box under a mixed read/mutate TaskGroup storm. The sharpest
// LAWFUL overlap lives here: reader siblings keep borrowing the ORIGINAL box while
// writer siblings clone-read it during their detaches — concurrent reads of shared
// storage with all writes confined to freshly-detached boxes. Postconditions:
// sibling independence after divergence (each writer matches its model, every
// reader observes the seed on every iteration) + exact teardown accounting.

private typealias HeapColumn<E: ~Copyable> =
    Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<E>>.Linear
private typealias SharedColumn<E: ~Copyable> = Shared<E, HeapColumn<E>>

private func makeShared<E>(capacity: UInt) -> SharedColumn<E> {
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

private final class Payload: Sendable {
    let value: Int
    init(_ value: Int) {
        self.value = value
        _ = Ledger.created.wrappingAdd(1, ordering: .relaxed)
    }
    deinit {
        _ = Ledger.destroyed.wrappingAdd(1, ordering: .relaxed)
    }
}

// MARK: - Trivial rung

@Suite
struct SharedConcurrencyStormTests {

    @Test
    func `readers stay on the seed while writers detach away`() async {
        var proto: SharedColumn<Int> = makeShared(capacity: 8)
        for i in 0..<4 { proto.append(i &* 10) }
        let frozen = proto
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<8 {
                group.addTask {                              // reader: never mutates its sibling
                    let mine = frozen
                    var good = true
                    for _ in 0..<250 {
                        let seedIntact = mine.withSpan { span in
                            span.count == 4 && span[0] == 0 && span[1] == 10
                                && span[2] == 20 && span[3] == 30
                        }
                        good = good && seedIntact
                    }
                    return good
                }
            }
            for t in 0..<8 {
                group.addTask {                              // writer: detaches, then churns
                    var mine = frozen
                    for k in 0..<99 {
                        mine.append(t &* 1000 &+ k)
                        if k % 3 == 0 { _ = mine.removeLast() }
                    }
                    // appends 99, removals at k % 3 == 0 → 33; net 66 over the seed 4
                    let n = mine.count
                    return n == Index<Int>.Count(UInt(70))
                }
            }
            var out: [Bool] = []
            for await ok in group { out.append(ok) }
            return out
        }
        #expect(outcomes.count == 16)
        #expect(outcomes.allSatisfy { $0 })
        let sourceCount = proto.count
        #expect(sourceCount == Index<Int>.Count(4))
    }

    @Test(arguments: [4, 16])
    func `interleaved read-mutate storms on independent siblings match their models`(width: Int) async {
        var proto: SharedColumn<Int> = makeShared(capacity: 8)
        for i in 0..<4 { proto.append(i) }
        let frozen = proto
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for t in 0..<width {
                group.addTask {
                    var mine = frozen
                    var model = [0, 1, 2, 3]
                    var good = true
                    for k in 0..<200 {
                        switch k % 5 {
                        case 0:
                            mine.append(t &+ k)
                            model.append(t &+ k)

                        case 2 where model.count > 1:
                            let got = mine.removeLast()
                            let want = model.removeLast()
                            good = good && (got == want)

                        case 4:
                            mine.withMutableSpan { span in
                                if span.count > 0 { span[0] &+= 1 }
                            }
                            if model.count > 0 { model[0] &+= 1 }

                        default:
                            let consistent = mine.withSpan { span in
                                guard span.count == model.count else { return false }
                                var same = true
                                for i in 0..<span.count { same = same && (span[i] == model[i]) }
                                return same
                            }
                            good = good && consistent
                        }
                    }
                    let final = mine.withSpan { span in
                        guard span.count == model.count else { return false }
                        var same = true
                        for i in 0..<span.count { same = same && (span[i] == model[i]) }
                        return same
                    }
                    return good && final
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

// MARK: - Refcounted rung (the same storm shape with retain/release traffic on
// shared element instances + exact teardown at quiescence)

@Suite(.serialized)
struct SharedConcurrencyStormTeardownTests {

    @Test
    func `refcounted storm: readers, writers, and exact teardown`() async {
        Ledger.reset()
        do {
            var proto: SharedColumn<Payload> = makeShared(capacity: 8)
            for i in 0..<4 { proto.append(Payload(i)) }
            let frozen = proto
            let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                // W2-F2 applies to every Span<Payload> closure in this group: values
                // are EXTRACTED inside the borrow and verified outside (a Bool-flow
                // closure over a class-element span crashes the 6.3.2 -O pipeline —
                // see probes-2026-06-11/tsan-spike/w2-release-wall/).
                for _ in 0..<6 {
                    group.addTask {                          // readers borrow the shared box
                        let mine = frozen
                        var good = true
                        for _ in 0..<150 {
                            let values = mine.withSpan { span in
                                var out: [Int] = []
                                out.reserveCapacity(span.count)
                                for i in 0..<span.count { out.append(span[i].value) }
                                return out
                            }
                            good = good && (values == [0, 1, 2, 3])
                        }
                        return good
                    }
                }
                for t in 0..<6 {
                    group.addTask {                          // writers detach + replace refs
                        var mine = frozen
                        for k in 0..<20 {
                            mine.append(Payload(t &* 100 &+ k))
                        }
                        mine.withMutableSpan { span in
                            for i in 0..<4 { span[i] = Payload(span[i].value &+ 50) }
                        }
                        let values = mine.withSpan { span in
                            var out: [Int] = []
                            out.reserveCapacity(span.count)
                            for i in 0..<span.count { out.append(span[i].value) }
                            return out
                        }
                        var model: [Int] = []
                        for i in 0..<4 { model.append(i &+ 50) }
                        for k in 0..<20 { model.append(t &* 100 &+ k) }
                        return values == model
                    }
                }
                var out: [Bool] = []
                for await ok in group { out.append(ok) }
                return out
            }
            #expect(outcomes.count == 12)
            #expect(outcomes.allSatisfy { $0 })
        }
        // 4 seed + 6 writers × (20 appended + 4 replacements) = 148, each destroyed once.
        let created = Ledger.created.load(ordering: .sequentiallyConsistent)
        let destroyed = Ledger.destroyed.load(ordering: .sequentiallyConsistent)
        #expect(created == 148)
        #expect(destroyed == created)
    }
}

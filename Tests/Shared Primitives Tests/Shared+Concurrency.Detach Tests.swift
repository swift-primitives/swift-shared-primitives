import Shared_Primitive
import Buffer_Primitive
import Buffer_Linear_Primitive
import Buffer_Linear_Bounded_Primitive
import Storage_Contiguous_Primitives
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Index_Primitives
import Synchronization
import Testing

// W2 adversarial suite 1 — DETACH RACES (GOAL-tower-arc-shared-soundness §W2.1).
//
// N tasks over sibling copies of one box, concurrent mutate→detach. Postconditions:
// every task's end state matches a FORKED REFERENCE MODEL (the seed plus that task's
// own ops), the source handle still sees the seed, and teardown oracles are EXACT
// (created == destroyed at quiescence — no leak, no double-deinit). The suite runs
// under the arc's TSan gate (REPORT-arc-shared-soundness-W1 §3): value correctness
// here AND sanitizer silence there are one combined verdict.
//
// Columns: heap-linear (growable lane) + bounded-linear (the fixed column; its extra
// postcondition is CAPACITY PRESERVATION through the concurrent detach).

private typealias HeapColumn<E: ~Copyable> =
    Buffer<Storage<Memory.Allocator<Memory.Heap>.System>.Contiguous<E>>.Linear
private typealias SharedColumn<E: ~Copyable> = Shared<E, HeapColumn<E>>
private typealias BoundedColumn<E: ~Copyable> =
    Buffer<Storage<Memory.Allocator<Memory.Heap>.System>.Contiguous<E>>.Linear.Bounded
private typealias SharedBounded<E: ~Copyable> = Shared<E, BoundedColumn<E>>

private func makeShared<E>(capacity: UInt) -> SharedColumn<E> {
    SharedColumn<E>(HeapColumn<E>(minimumCapacity: Index<E>.Count(capacity)))
}

/// Thread-safe teardown ledger. The suite's siblings drop on TaskGroup worker
/// threads, so the single-threaded `Probe` recorder idiom does not apply — exactness
/// is counted atomically and asserted at quiescence.
private enum Ledger {
    static let created = Atomic<Int>(0)
    static let destroyed = Atomic<Int>(0)
    static func reset() {
        created.store(0, ordering: .sequentiallyConsistent)
        destroyed.store(0, ordering: .sequentiallyConsistent)
    }
}

/// Refcounted element rung: sibling clones share these instances across threads
/// (retain/release traffic on the SAME objects during concurrent detaches).
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

// MARK: - Trivial rung (value correctness under concurrent detach)

@Suite
struct SharedConcurrencyDetachTrivialTests {

    @Test(arguments: [2, 8, 32])
    func `concurrent mutate-detach: every sibling matches its forked model`(width: Int) async {
        var proto: SharedColumn<Int> = makeShared(capacity: 16)
        for i in 0..<8 { proto.append(i) }
        let frozen = proto
        let outcomes = await withTaskGroup(of: (Int, [Int]).self, returning: [Int: [Int]].self) { group in
            for t in 0..<width {
                group.addTask {
                    var mine = frozen                       // sibling: shares the box
                    mine.append(100 &+ t)                   // gate-first append → detach
                    mine.withMutableSpan { span in
                        for i in 0..<span.count { span[i] &+= t }
                    }
                    _ = mine.removeLast()
                    let snapshot = mine.withSpan { span in
                        var out: [Int] = []
                        out.reserveCapacity(span.count)
                        for i in 0..<span.count { out.append(span[i]) }
                        return out
                    }
                    return (t, snapshot)
                }
            }
            var collected: [Int: [Int]] = [:]
            for await (t, snapshot) in group { collected[t] = snapshot }
            return collected
        }
        #expect(outcomes.count == width)
        for t in 0..<width {
            var model = Array(0..<8)                        // fork: the shared seed…
            model.append(100 &+ t)                          // …plus this task's ops
            model = model.map { $0 &+ t }
            model.removeLast()
            #expect(outcomes[t] == model)
        }
        let source = proto.withSpan { span in
            var out: [Int] = []
            for i in 0..<span.count { out.append(span[i]) }
            return out
        }
        #expect(source == Array(0..<8))                     // the source never moved
    }

    @Test(arguments: [2, 8])
    func `bounded column: concurrent detach preserves capacity exactly`(width: Int) async {
        var proto = SharedBounded<Int>(BoundedColumn<Int>(minimumCapacity: Index<Int>.Count(8)))
        proto.initialize(at: 0, to: 10)
        proto.initialize(at: 1, to: 11)
        let frozen = proto
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for t in 0..<width {
                group.addTask {
                    var mine = frozen
                    mine[0] = 1000 &+ t                     // self-gating seam write → detach
                    let mine0 = mine[0]
                    let mine1 = mine[1]
                    let theirs0 = frozen[0]                 // lawful read on the shared box
                    let capacityPreserved = (mine.capacity == frozen.capacity)
                    return mine0 == 1000 &+ t && mine1 == 11 && theirs0 == 10 && capacityPreserved
                }
            }
            var out: [Bool] = []
            for await ok in group { out.append(ok) }
            return out
        }
        #expect(outcomes.count == width)
        #expect(outcomes.allSatisfy { $0 })
        let source0 = proto[0]
        #expect(source0 == 10)
    }
}

// MARK: - Refcounted rung (exact teardown across the storm; serialized so the
// file-global ledger observes one test's quiescence at a time)

@Suite(.serialized)
struct SharedConcurrencyDetachTeardownTests {

    @Test
    func `refcounted elements: exact teardown after a concurrent detach storm`() async {
        Ledger.reset()
        do {
            var proto: SharedColumn<Payload> = makeShared(capacity: 16)
            for i in 0..<8 { proto.append(Payload(i)) }
            let frozen = proto
            let checks = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for t in 0..<16 {
                    group.addTask {
                        var mine = frozen
                        mine.append(Payload(100 &+ t))      // detach: the clone retains the seed refs
                        mine.withMutableSpan { span in
                            for i in 0..<span.count where i % 2 == 0 {
                                span[i] = Payload(span[i].value &+ 1000)
                            }
                        }
                        // W2-F2: verification stays OUTSIDE the Span<Payload> closure —
                        // a guard/early-return Bool closure over a class-element span
                        // crashes the 6.3.2 -O pipeline (CopyPropagation "leaked owned
                        // value", signal 6; snapshot + log:
                        // probes-2026-06-11/tsan-spike/w2-release-wall/). Extract the
                        // values, compare against the model afterward.
                        let values = mine.withSpan { span in
                            var out: [Int] = []
                            out.reserveCapacity(span.count)
                            for i in 0..<span.count { out.append(span[i].value) }
                            return out
                        }
                        var model: [Int] = []
                        for i in 0..<8 { model.append(i % 2 == 0 ? i &+ 1000 : i) }
                        model.append(1100 &+ t)                 // appended, then re-boxed
                        return values == model
                    }
                }
                var out: [Bool] = []
                for await ok in group { out.append(ok) }
                return out
            }
            #expect(checks.count == 16)
            #expect(checks.allSatisfy { $0 })
        }
        // Quiescence: every sibling and the source died. Exact arithmetic: 8 seed
        // payloads + 16 tasks × (1 appended + 5 replacements) = 104; every one
        // destroyed exactly once.
        let created = Ledger.created.load(ordering: .sequentiallyConsistent)
        let destroyed = Ledger.destroyed.load(ordering: .sequentiallyConsistent)
        #expect(created == 104)
        #expect(destroyed == created)
    }
}

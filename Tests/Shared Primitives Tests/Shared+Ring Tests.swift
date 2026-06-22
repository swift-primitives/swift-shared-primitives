import Shared_Primitive
import Buffer_Primitive
import Buffer_Ring_Primitive
import Buffer_Ring_Bounded_Primitive
import Buffer_Primitives_Test_Support
import Storage_Contiguous_Primitives
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Index_Primitives
import Testing

// The ring CoW columns (ASK-C, 2026-06-10): the four pinned constructor pairs + the
// scoped-access trio, exercised against the ratified ring seam. Mirrors the
// ratification spike (.handoffs/probes-2026-06-10/queue-family-spike/).

private typealias HeapStorage<E: ~Copyable> =
    Storage<Memory.Allocator<Memory.Heap>>.Contiguous<E>

private typealias GrowableRing<E: ~Copyable> = Buffer<HeapStorage<E>>.Ring
private typealias BoundedRing<E: ~Copyable> = Buffer<HeapStorage<E>>.Ring.Bounded

private typealias SharedRing<E: ~Copyable> = Shared<E, GrowableRing<E>>
private typealias SharedBoundedRing<E: ~Copyable> = Shared<E, BoundedRing<E>>

// MARK: - [DS-024]: the boxed ring columns are lawful

@Suite
struct SharedRingLawTests {

    @Test
    func `the shared growable-ring column obeys the seam ledger laws`() {
        let violations = Seam.Ledger.violations(
            makeEmpty: { SharedRing<Int>(GrowableRing<Int>(minimumCapacity: Index<Int>.Count(4))) },
            element: { $0 }
        )
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test
    func `the shared bounded-ring column obeys the seam ledger laws`() {
        let violations = Seam.Ledger.violations(
            makeEmpty: { SharedBoundedRing<Int>(BoundedRing<Int>(minimumCapacity: Index<Int>.Count(4))) },
            element: { $0 }
        )
        #expect(violations.isEmpty, "\(violations)")
    }
}

// MARK: - CoW value semantics on the ring column

@Suite(.serialized)
struct SharedRingCoWTests {

    @Test
    func `copies share the box until a gated seam write diverges them`() {
        var s = SharedRing<Int>(GrowableRing<Int>(minimumCapacity: Index<Int>.Count(4)))
        s.initialize(at: 0, to: 1)
        s.initialize(at: 1, to: 2)
        let t = s
        let sharedBefore = (s._boxID == t._boxID)
        #expect(sharedBefore)
        s[0] = 100                              // self-gating _modify clones first
        let diverged = (s._boxID != t._boxID)
        #expect(diverged)
        let mine = s[0], theirs = t[0]
        #expect(mine == 100)
        #expect(theirs == 1)
    }

    @Test
    func `a front move through the seam detaches from the sibling`() {
        var s = SharedRing<Int>(GrowableRing<Int>(minimumCapacity: Index<Int>.Count(4)))
        s.initialize(at: 0, to: 7)
        s.initialize(at: 1, to: 8)
        let t = s
        let popped = s.move(at: 0)              // gated front-pop; head re-anchors
        #expect(popped == 7)
        let mine = s.count, theirs = t.count
        #expect(mine == Index<Int>.Count(1))
        #expect(theirs == Index<Int>.Count(2))
        let myFront = s[0], theirFront = t[0]
        #expect(myFront == 8)
        #expect(theirFront == 7)
    }
}

// MARK: - The scoped-access trio at the class hop

@Suite(.serialized)
struct SharedRingScopedAccessTests {

    @Test
    func `withUnique detaches first and reaches ops the seam cannot spell`() {
        var s = SharedRing<Int>(GrowableRing<Int>(minimumCapacity: Index<Int>.Count(4)))
        s.initialize(at: 0, to: 2)
        let t = s
        s.withUnique { ring in
            ring.pushFront(1)                   // front-insert: a column op, not a seam op
        }
        let myFront = s[0], myCount = s.count
        #expect(myFront == 1)
        #expect(myCount == Index<Int>.Count(2))
        let theirCount = t.count
        #expect(theirCount == Index<Int>.Count(1))
        let theirFront = t[0]
        #expect(theirFront == 2)                // the gate inside withUnique detached first
    }

    @Test
    func `withUnique(consuming:) threads a move-only payload into the column`() {
        ScopedProbe.reset()
        do {
            var s = SharedRing<ScopedItem>(GrowableRing<ScopedItem>(minimumCapacity: Index<ScopedItem>.Count(2)))
            s.withUnique(consuming: ScopedItem(1)) { ring, item in
                ring.pushBack(item)
            }
            let n = s.count
            #expect(n == Index<ScopedItem>.Count(1))
            let lived = ScopedProbe.destroyedSorted
            #expect(lived.isEmpty)              // moved in, not destroyed
        }
        let all = ScopedProbe.destroyedSorted
        #expect(all == [1])                     // the box drain tore it down (R-5)
    }

    @Test
    func `withColumn reads without detaching`() {
        var s = SharedRing<Int>(GrowableRing<Int>(minimumCapacity: Index<Int>.Count(2)))
        s.initialize(at: 0, to: 42)
        let t = s
        let read = s.withColumn { ring in ring[0] }
        #expect(read == 42)
        let stillShared = (s._boxID == t._boxID)
        #expect(stillShared)
        _ = t
    }

    @Test
    func `the bounded column rejects on full through the box`() {
        var s = SharedBoundedRing<Int>(BoundedRing<Int>(minimumCapacity: Index<Int>.Count(2)))
        s.initialize(at: 0, to: 1)
        s.initialize(at: 1, to: 2)
        let rejected = s.withUnique { ring in
            ring.push.back(3)                   // full: the bounded ring hands it back
        }
        #expect(rejected == 3)
        let n = s.count
        #expect(n == Index<Int>.Count(2))
    }
}

private struct ScopedItem: ~Copyable {
    let id: Int
    init(_ id: Int) { self.id = id }
    deinit { ScopedProbe.recordDestroy(id) }
}

private enum ScopedProbe {
    nonisolated(unsafe) static var _destroyed: [Int] = []
    static func reset() { unsafe _destroyed = [] }
    static func recordDestroy(_ id: Int) { unsafe _destroyed.append(id) }
    static var destroyedSorted: [Int] { unsafe _destroyed.sorted() }
}

// MARK: - The box drain on the ring columns (R-5; the release leg runs the -O regime)

@Suite(.serialized)
struct SharedRingTeardownTests {

    @Test
    func `the box drain destroys live move-only elements exactly once`() {
        DrainProbe.reset()
        do {
            var s = SharedRing<DrainItem>(GrowableRing<DrainItem>(minimumCapacity: Index<DrainItem>.Count(4)))
            s.initialize(at: Index<DrainItem>(Ordinal(UInt(0))), to: DrainItem(1))
            s.initialize(at: Index<DrainItem>(Ordinal(UInt(1))), to: DrainItem(2))
            let taken = s.move(at: Index<DrainItem>(Ordinal(UInt(0))))
            let tid = taken.id
            #expect(tid == 1)
            _ = consume taken
            let mid = DrainProbe.destroyedSorted
            #expect(mid == [1])
        }
        let all = DrainProbe.destroyedSorted
        #expect(all == [1, 2])
    }

    @Test
    func `the bounded box drain tears down its live elements`() {
        DrainProbe.reset()
        do {
            var s = SharedBoundedRing<DrainItem>(BoundedRing<DrainItem>(minimumCapacity: Index<DrainItem>.Count(2)))
            s.initialize(at: Index<DrainItem>(Ordinal(UInt(0))), to: DrainItem(5))
        }
        let all = DrainProbe.destroyedSorted
        #expect(all == [5])
    }
}

private struct DrainItem: ~Copyable {
    let id: Int
    init(_ id: Int) { self.id = id }
    deinit { DrainProbe.recordDestroy(id) }
}

private enum DrainProbe {
    nonisolated(unsafe) static var _destroyed: [Int] = []
    static func reset() { unsafe _destroyed = [] }
    static func recordDestroy(_ id: Int) { unsafe _destroyed.append(id) }
    static var destroyedSorted: [Int] { unsafe _destroyed.sorted() }
}

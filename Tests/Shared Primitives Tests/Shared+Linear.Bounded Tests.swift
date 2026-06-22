import Shared_Primitive
import Buffer_Primitive
import Buffer_Linear_Primitive
import Buffer_Linear_Bounded_Primitive
import Buffer_Primitives_Test_Support
import Storage_Contiguous_Primitives
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Index_Primitives
import Testing

// The bounded-linear CoW column (ASK-W1-1, principal-ruled 2026-06-11): the pinned
// constructor pair over Buffer.Linear.Bounded — the Stack.Bounded substrate. Mirrors
// the ring pair's suite shape; the load-bearing extra is CAPACITY PRESERVATION
// through a CoW detach (the clone is capacity-preserving by contract).

private typealias HeapStorage<E: ~Copyable> =
    Storage<Memory.Allocator<Memory.Heap>>.Contiguous<E>

private typealias BoundedLinear<E: ~Copyable> = Buffer<HeapStorage<E>>.Linear.Bounded

private typealias SharedBoundedLinear<E: ~Copyable> = Shared<E, BoundedLinear<E>>

// MARK: - [DS-024]: the boxed bounded-linear column is lawful

@Suite
struct SharedLinearBoundedLawTests {

    @Test
    func `the shared bounded-linear column obeys the seam ledger laws`() {
        let violations = Seam.Ledger.violations(
            makeEmpty: { SharedBoundedLinear<Int>(BoundedLinear<Int>(minimumCapacity: Index<Int>.Count(4))) },
            element: { $0 }
        )
        #expect(violations.isEmpty, "\(violations)")
    }
}

// MARK: - CoW value semantics + the capacity contract

@Suite(.serialized)
struct SharedLinearBoundedCoWTests {

    @Test
    func `copies share the box; a gated write detaches with capacity preserved exactly`() {
        var s = SharedBoundedLinear<Int>(BoundedLinear<Int>(minimumCapacity: Index<Int>.Count(4)))
        s.initialize(at: 0, to: 1)
        s.initialize(at: 1, to: 2)
        let capacityBefore = s.capacity
        let t = s
        let sharedBefore = (s._boxID == t._boxID)
        #expect(sharedBefore)
        s[0] = 100                              // self-gating _modify clones first
        let diverged = (s._boxID != t._boxID)
        #expect(diverged)
        #expect(s.capacity == capacityBefore)   // the capacity-preserving clone
        let mine = s[0], theirs = t[0]
        #expect(mine == 100)
        #expect(theirs == 1)
    }

    @Test
    func `a move-only bounded column drains through the box deinit`() {
        BoundedProbe.reset()
        do {
            var s = SharedBoundedLinear<BoundedItem>(BoundedLinear<BoundedItem>(minimumCapacity: Index<BoundedItem>.Count(2)))
            s.initialize(at: 0, to: BoundedItem(7))
            s.initialize(at: 1, to: BoundedItem(8))
            let n = s.count
            #expect(n == Index<BoundedItem>.Count(2))
        }
        let all = BoundedProbe.destroyedSorted
        #expect(all == [7, 8])
    }
}

private struct BoundedItem: ~Copyable {
    let id: Int
    init(_ id: Int) { self.id = id }
    deinit { BoundedProbe.recordDestroy(id) }
}

private enum BoundedProbe {
    nonisolated(unsafe) static var _destroyed: [Int] = []
    static func reset() { unsafe _destroyed = [] }
    static func recordDestroy(_ id: Int) { unsafe _destroyed.append(id) }
    static var destroyedSorted: [Int] { unsafe _destroyed.sorted() }
}

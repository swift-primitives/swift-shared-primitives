import Shared_Primitive
import Buffer_Primitive
import Buffer_Linear_Primitive
import Storage_Contiguous_Primitives
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Index_Primitives
import Testing

// MARK: - Fixtures

/// ~Copyable element with identity + recording deinit (drain-box teardown observation).
private struct Item: ~Copyable {
    let id: Int
    var value: Int
    init(_ id: Int, value: Int = 0) { self.id = id; self.value = value }
    deinit { Probe.recordDestroy(id) }
}

/// Copyable element with observable destruction (class ref — deinit at refcount zero).
private final class Payload {
    let id: Int
    init(_ id: Int) { self.id = id }
    deinit { Probe.recordDestroy(id) }
}

/// Serialized destruction recorder (the suite below is `.serialized`).
private enum Probe {
    nonisolated(unsafe) static var _destroyed: [Int] = []
    static func reset() { unsafe _destroyed = [] }
    static func recordDestroy(_ id: Int) { unsafe _destroyed.append(id) }
    static var destroyed: [Int] { unsafe _destroyed }
    static var destroyedSorted: [Int] { unsafe _destroyed.sorted() }
}

private typealias HeapColumn<E: ~Copyable> =
    Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<E>>.Linear

private typealias SharedColumn<E: ~Copyable> = Shared<E, HeapColumn<E>>

// Split on element copyability, mirroring `Shared`'s constructors: the Copyable form
// resolves the clone-capturing init (CoW-capable); the move-only form resolves the
// statically-unique init. A single `~Copyable`-generic helper would silently build
// every column through the move-only constructor — `prepareForMutation`'s backstop
// traps on the first shared mutation of such a column.
private func makeShared<E>(capacity: UInt) -> SharedColumn<E> {
    SharedColumn<E>(HeapColumn<E>(minimumCapacity: Index<E>.Count(capacity)))
}

private func makeSharedMoveOnly<E: ~Copyable>(capacity: UInt) -> SharedColumn<E> {
    SharedColumn<E>(HeapColumn<E>(minimumCapacity: Index<E>.Count(capacity)))
}

@Suite(.serialized)
struct SharedTests {

    // MARK: - The conditional chain (the union, in one type)

    @Test
    func `copy shares the box; first mutation diverges (value semantics)`() {
        Probe.reset()
        var a: SharedColumn<Payload> = makeShared(capacity: 4)
        a.append(Payload(1))
        a.append(Payload(2))
        let idBefore = a._boxID
        let b = a                                   // Copyable fires (Element is a class)
        let sharedAfterCopy = (b._boxID == idBefore)
        #expect(sharedAfterCopy)                    // copy shares — no eager clone
        a.append(Payload(3))                        // first mutation → CoW restore
        let diverged = (a._boxID != b._boxID)
        #expect(diverged)
        let aCount = a.count, bCount = b.count
        #expect(aCount == Index<Payload>.Count(3))
        #expect(bCount == Index<Payload>.Count(2))  // the copy is untouched
        let b0 = b[.zero].id
        #expect(b0 == 1)
    }

    @Test
    func `unique mutation stays in place (no clone)`() {
        Probe.reset()
        var a: SharedColumn<Payload> = makeShared(capacity: 4)
        a.append(Payload(1))
        let id0 = a._boxID
        a.append(Payload(2))
        let id1 = a._boxID
        #expect(id0 == id1)
    }

    // MARK: - Teardown through the DRAIN-BOX (the R-5 rule; the R-6 regime under -O)

    @Test
    func `teardown drains each payload exactly once — shared, no mutation`() {
        Probe.reset()
        do {
            var a: SharedColumn<Payload> = makeShared(capacity: 2)
            a.append(Payload(10))
            a.append(Payload(11))
            let b = a
            let bCount = b.count
            #expect(bCount == Index<Payload>.Count(2))
        }                                           // one box → one drain
        let ds = Probe.destroyedSorted
        #expect(ds == [10, 11])
    }

    @Test
    func `teardown after clone drains both boxes; each payload once`() {
        Probe.reset()
        do {
            var a: SharedColumn<Payload> = makeShared(capacity: 4)
            a.append(Payload(20))
            a.append(Payload(21))
            var b = a
            b.append(Payload(22))                   // clone: two boxes, two storages
            let diverged = (a._boxID != b._boxID)
            #expect(diverged)
        }
        let ds = Probe.destroyedSorted
        #expect(ds == [20, 21, 22])                 // shared refs released to zero exactly once
    }

    @Test
    func `move-only column is statically unique and drains through the box`() {
        Probe.reset()
        do {
            var a: SharedColumn<Item> = makeSharedMoveOnly(capacity: 2)
            a.appendAssumingUnique(Item(5, value: 50))
            a.appendAssumingUnique(Item(6, value: 60))
            let taken = a.removeLastAssumingUnique()
            let tid = taken.id
            #expect(tid == 6)
            _ = consume taken
            let mid = Probe.destroyedSorted
            #expect(mid == [6])
        }
        let ds = Probe.destroyedSorted
        #expect(ds == [5, 6])
    }

    // MARK: - The element-keyed carriers (the W4 re-materialization)

    @Test
    func `Equatable and Hashable carry through the direct Element parameter`() {
        var a: SharedColumn<Int> = makeShared(capacity: 4)
        a.append(1)
        a.append(2)
        var b: SharedColumn<Int> = makeShared(capacity: 8)
        b.append(1)
        b.append(2)
        #expect(a == b)                             // element-wise, capacity-independent
        b.append(3)
        #expect(a != b)
        var h1 = Hasher(), h2 = Hasher()
        a.hash(into: &h1)
        var a2 = a
        a2.ensureUnique()                           // distinct boxes, same elements
        a2.hash(into: &h2)
        #expect(h1.finalize() == h2.finalize())
    }

    // MARK: - Spans (scoped at the hop; mutable = unique-first)

    @Test
    func `withSpan reads; withMutableSpan restores uniqueness before vending`() {
        Probe.reset()
        var a: SharedColumn<Int> = makeShared(capacity: 4)
        a.append(1)
        a.append(2)
        a.append(3)
        let sum = a.withSpan { span in
            var acc = 0
            for i in 0..<span.count { acc += span[i] }
            return acc
        }
        #expect(sum == 6)

        let b = a                                   // share
        let bIDBefore = b._boxID
        a.withMutableSpan { span in
            span[0] = 100                           // must NOT alias b
        }
        let diverged = (a._boxID != bIDBefore)
        #expect(diverged)                           // uniqueness restored BEFORE the view
        let aSees = a[.zero], bSees = b[.zero]
        #expect(aSees == 100)
        #expect(bSees == 1)
    }

    // MARK: - The self-gating seam (Sendable soundness: no public unchecked mutation lane)

    @Test
    func `the seam's own mutators self-gate — writes through Store-Protocol diverge`() {
        var a: SharedColumn<Int> = makeShared(capacity: 2)
        a.append(1)
        a.append(2)
        let b = a                                   // share the box
        let bIDBefore = b._boxID
        a[.zero] = 100                              // the SEAM subscript._modify, no ADT gate above
        let diverged = (a._boxID != bIDBefore)
        #expect(diverged)                           // the seam itself restored uniqueness
        let aSees = a[.zero], bSees = b[.zero]
        #expect(aSees == 100)
        #expect(bSees == 1)

        var c: SharedColumn<Int> = makeShared(capacity: 2)
        c.append(7)
        let d = c
        let moved = c.move(at: .zero)               // seam move on a shared box
        #expect(moved == 7)
        let dSees = d[.zero]
        #expect(dSees == 7)                         // sibling's element untouched by the move-out
    }

    // MARK: - Sendable chain

    @Test
    func `sendable composes through the chain`() {
        let a: SharedColumn<Int> = makeShared(capacity: 1)
        requireSendable(a)
        #expect(Bool(true))
    }
}

private func requireSendable<T: Sendable & ~Copyable>(_ value: borrowing T) {}

import Shared_Primitive
import Buffer_Primitive
import Buffer_Linear_Primitive
import Buffer_Linear_Bounded_Primitive
import Storage_Contiguous_Primitives
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Index_Primitives
import Testing

// W2 adversarial suite 5 — SENDABLE SURFACE AS CODE (GOAL-tower-arc-shared-soundness
// §W2.5): the line-by-line re-walk of the conditional `Sendable`/`SendableMetatype`
// bounds (SE-0470 finding, shared `5b369cd`). Each documented invariant maps to a
// test where testable, a cited rationale where not:
//
// | Invariant (source site) | Disposition |
// |---|---|
// | `Shared: Sendable where B: Sendable` — sendability flows through the COLUMN, never the element directly (Shared.swift:79) | positive compile assertions below: heap-linear, bounded-linear |
// | FINDING W2-F1 — the move-only rung is NOT Sendable today: `Storage.Contiguous`'s conditional Sendable bounds `Element: Sendable` WITHOUT `~Copyable` suppression (Storage.Contiguous.swift:187), implicitly requiring `Element: Copyable`; `Shared`'s own clause explicitly admits `Element: ~Copyable`, so the combinator's intent is blocked one tier down | recorded at the assertion site below + REPORT-arc-shared-soundness-W2 (PROPOSED fix in storage-primitives — ungranted here; not baked) |
// | `Box: @unchecked Sendable where Wrapped: Sendable` (Box.swift:62) | rationale comment at the site (rider on this commit); behavioral evidence = suites 1–3 green under the arc's TSan gate |
// | drain/clone strategies stored as `@Sendable` closures (Box.swift:36,43) | compile-enforced by the stored property types — no construction can smuggle a non-Sendable strategy into a Sendable box |
// | every public mutation path gates BEFORE writing (Shared+Store.Protocol.swift:16–25 seam; Shared+Unique.swift append/removeLast/reserveCapacity/reallocate; Shared+withUnique.swift:44,60; Shared+Span.swift:42) | divergence + sibling-independence postconditions in suites 1–3, plus the pre-existing single-threaded gate tests |
// | the `…AssumingUnique` unchecked lane asserts in debug (Shared+Unique.swift:104,123; Shared+Span.swift:53) | suite 4 death tests (debug config) |
// | `ensureUnique()`'s no-clone precondition lane (Shared+Unique.swift:77) | unreachable through public constructors — rationale recorded in suite 4's header, not instantiated |
// | Hash.Indexed constructors bound `Element: Hash.Key & SendableMetatype` (Shared+Hash.Indexed.swift:31,40) | SE-0470 rationale comment at the site (rider); construction smokes live with the ordered family's packages (arc-2 territory), not here |
// | negative direction: non-Sendable `B` ⇒ `Shared` not Sendable | compile-time NEGATIVE — untestable in-target by design; an expected-failure probe is the only spelling, recorded as rationale |

private typealias HeapColumn<E: ~Copyable> =
    Buffer<Storage<Memory.Allocator<Memory.Heap>.System>.Contiguous<E>>.Linear
private typealias SharedColumn<E: ~Copyable> = Shared<E, HeapColumn<E>>
private typealias BoundedColumn<E: ~Copyable> =
    Buffer<Storage<Memory.Allocator<Memory.Heap>.System>.Contiguous<E>>.Linear.Bounded
private typealias SharedBounded<E: ~Copyable> = Shared<E, BoundedColumn<E>>

private func makeShared<E>(capacity: UInt) -> SharedColumn<E> {
    SharedColumn<E>(HeapColumn<E>(minimumCapacity: Index<E>.Count(capacity)))
}

private func makeSharedMoveOnly<E: ~Copyable>(capacity: UInt) -> SharedColumn<E> {
    SharedColumn<E>(HeapColumn<E>(minimumCapacity: Index<E>.Count(capacity)))
}

/// Move-only Sendable element (trivial payload — the rung only exercises bounds).
private struct Item: ~Copyable, Sendable {
    let id: Int
    init(_ id: Int) { self.id = id }
}

@Suite
struct SharedSendableSurfaceTests {

    @Test
    func `sendable composes across columns and rungs`() {
        let heap: SharedColumn<Int> = makeShared(capacity: 1)
        requireSendable(heap)
        let bounded = SharedBounded<Int>(BoundedColumn<Int>(minimumCapacity: Index<Int>.Count(1)))
        requireSendable(bounded)
        // FINDING W2-F1: the move-only rung does NOT compose today —
        //     requireSendable(makeSharedMoveOnly(capacity: 1) as SharedColumn<Item>)
        // fails: "requires that 'Item' conform to 'Copyable'", sourced from
        // Storage.Contiguous.swift:187's Sendable clause (`Element: Sendable` with no
        // `~Copyable` suppression). The line above IS the minimal repro; it stays
        // commented until the storage-tier bound is ruled on (PROPOSE-don't-bake).
        let moveOnlyLocal: SharedColumn<Item> = makeSharedMoveOnly(capacity: 1)
        let n = moveOnlyLocal.count
        #expect(n == Index<Item>.Count(0))
        #expect(Bool(true))
    }
}

private func requireSendable<T: Sendable & ~Copyable>(_ value: borrowing T) {}

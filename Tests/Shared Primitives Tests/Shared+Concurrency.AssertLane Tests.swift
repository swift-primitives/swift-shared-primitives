#if DEBUG

import Shared_Primitive
import Buffer_Primitive
import Buffer_Linear_Primitive
import Storage_Contiguous_Primitives
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Index_Primitives
import Testing

// W2 adversarial suite 4 — ASSERT-LANE DEATH TESTS (GOAL-tower-arc-shared-soundness
// §W2.4; debug configuration only).
//
// The `…AssumingUnique` debug assertions (`f38c758`) are the standing mitigation for
// the unchecked lane (the `sending` spike confirmed no type-level proof of refcount
// uniqueness exists — REPORT-W4 §ADDENDUM (i)). Each exit test below misuses one
// spelling on a SHARED box and passes IFF the child process dies; if the assert were
// compiled out or skipped, the body would return normally, the child would exit 0,
// and `processExitsWith: .failure` would FAIL the test. W1 established viability and
// the config carve: asserts are inactive in release, so this whole file is
// `#if DEBUG`-gated (the release leg runs without it — its gate counts differ by
// design).
//
// NOT a test target: `ensureUnique()`'s `preconditionFailure` lane (a shared box
// with no clone strategy, Shared+Unique.swift:77) — unreachable through the public
// constructors (sharing requires `Shared: Copyable`, which requires
// `Element: Copyable`, whose constructor always captures the strategy). Recorded as
// rationale, not instantiated.

private typealias HeapColumn<E: ~Copyable> =
    Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<E>>.Linear
private typealias SharedColumn<E: ~Copyable> = Shared<E, HeapColumn<E>>

private func makeShared<E>(capacity: UInt) -> SharedColumn<E> {
    SharedColumn<E>(HeapColumn<E>(minimumCapacity: Index<E>.Count(capacity)))
}

@Suite
struct SharedAssertLaneDeathTests {

    @Test
    func `appendAssumingUnique on a shared box dies in debug`() async {
        await #expect(processExitsWith: .failure) {
            var a: SharedColumn<Int> = makeShared(capacity: 4)
            a.append(1)
            let b = a                                        // share the box: refcount 2
            a.appendAssumingUnique(2)                        // the assert must fire here
            _ = b
        }
    }

    @Test
    func `removeLastAssumingUnique on a shared box dies in debug`() async {
        await #expect(processExitsWith: .failure) {
            var a: SharedColumn<Int> = makeShared(capacity: 4)
            a.append(1)
            let b = a
            _ = a.removeLastAssumingUnique()
            _ = b
        }
    }

    @Test
    func `withMutableSpanAssumingUnique on a shared box dies in debug`() async {
        await #expect(processExitsWith: .failure) {
            var a: SharedColumn<Int> = makeShared(capacity: 4)
            a.append(1)
            let b = a
            a.withMutableSpanAssumingUnique { span in
                span[0] = 99
            }
            _ = b
        }
    }

    // MARK: - No-fire controls (the lawful side of the lane)

    @Test
    func `assumingUnique spellings succeed on a truly unique box`() {
        var a: SharedColumn<Int> = makeShared(capacity: 4)
        a.appendAssumingUnique(1)
        a.appendAssumingUnique(2)
        a.withMutableSpanAssumingUnique { span in
            span[0] = 10
        }
        let last = a.removeLastAssumingUnique()
        #expect(last == 2)
        let first = a[.zero]
        #expect(first == 10)
        let n = a.count
        #expect(n == Index<Int>.Count(1))
    }

    @Test
    func `the gate restores uniqueness so a post-detach assumingUnique is lawful`() {
        var a: SharedColumn<Int> = makeShared(capacity: 4)
        a.append(1)
        let b = a                                            // shared…
        a.ensureUnique()                                     // …explicitly detached
        a.appendAssumingUnique(2)                            // lawful: a is unique again
        let aCount = a.count, bCount = b.count
        #expect(aCount == Index<Int>.Count(2))
        #expect(bCount == Index<Int>.Count(1))
    }
}

#endif

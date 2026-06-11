import Shared_Primitive
import Buffer_Primitive
import Buffer_Linear_Primitive
import Buffer_Linear_Primitives
import Storage_Contiguous_Primitives
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Span_Protocol_Primitives
import Index_Primitives
import Testing

// The W1-4 laundered span (spike: .handoffs/probes-2026-06-11/shared-span-spike/):
// Shared: Span.Protocol where B: Span.Protocol — the conformance that admits the
// Shared column to the span-bridged Collection lattice.

private typealias HeapStorage<E: ~Copyable> =
    Storage<Memory.Allocator<Memory.Heap>.System>.Contiguous<E>

private typealias HeapColumn<E: ~Copyable> = Buffer<HeapStorage<E>>.Linear
private typealias SharedColumn<E: ~Copyable> = Shared<E, HeapColumn<E>>

/// Generic Span.Protocol-bound walk — the lattice dispatch shape.
private func total<S: Span.`Protocol`>(_ s: borrowing S) -> Int where S.Element == Int {
    var sum = 0
    let span = s.span
    for i in span.indices { sum &+= span[i] }
    return sum
}

@Suite(.serialized)
struct SharedSpanProtocolTests {

    @Test
    func `the laundered span reads the boxed column, directly and via the witness`() {
        var column = HeapColumn<Int>(minimumCapacity: Index<Int>.Count(4))
        column.append(1)
        column.append(2)
        column.append(3)
        let s = SharedColumn<Int>(column)
        let direct = s.span
        #expect(direct.count == 3)
        var sum = 0
        for i in direct.indices { sum &+= direct[i] }
        #expect(sum == 6)
        #expect(total(s) == 6)                  // generic witness dispatch
    }

    @Test
    func `the empty column vends the lawful empty window`() {
        let s = SharedColumn<Int>(HeapColumn<Int>(minimumCapacity: Index<Int>.Count(2)))
        let span = s.span
        #expect(span.count == 0)
        #expect(total(s) == 0)
    }

    @Test
    func `a live span survives a sibling's gated detach-mutation unchanged`() {
        var column = HeapColumn<Int>(minimumCapacity: Index<Int>.Count(4))
        column.append(1)
        column.append(2)
        column.append(3)
        let s = SharedColumn<Int>(column)
        var sibling = s                         // share the box
        let live = s.span
        sibling.append(99)                      // gate detaches the SIBLING first
        var after = 0
        for i in live.indices { after &+= live[i] }
        #expect(after == 6)                     // our box untouched — never torn
        let siblingCount = sibling.count
        #expect(siblingCount == Index<Int>.Count(4))
        let ourCount = s.count
        #expect(ourCount == Index<Int>.Count(3))
    }
}

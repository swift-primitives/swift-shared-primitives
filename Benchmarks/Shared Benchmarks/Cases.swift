// ===----------------------------------------------------------------------===//
//
// This source file is part of the swift-primitives open source project
//
// Copyright (c) 2024-2026 Coen ten Thije Boonkkamp and the swift-primitives project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// ===----------------------------------------------------------------------===//

import Shared_Primitive
import Buffer_Linear_Primitive
import Buffer_Linear_Primitives
import Buffer_Primitive
import Storage_Contiguous_Primitives
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Index_Primitives
import Tagged_Primitives_Standard_Library_Integration
import Ordinal_Primitives
import Ordinal_Primitives_Standard_Library_Integration
import Cardinal_Primitives

// The gate decomposition through the REAL box (the B-1′ before-picture the
// engine-fix arc waits on): every gated door has its `AssumingUnique` twin,
// so pair-differences isolate the gate exactly; the bare Linear column is the
// unboxed control at identical substrate. Boxes stay UNIQUE throughout the
// gated rows (R4's always-unique worst case); detach rows make the only
// siblings. Measured at the b652394 tip — the activated W2-F1 chain assertion
// is part of the shipped door and belongs in the baseline.

typealias LinearColumn =
    Buffer<Storage<Memory.Allocator<Memory.Heap>.System>.Contiguous<Int>>.Linear

typealias SharedColumn = Shared<Int, LinearColumn>

extension Bench {
    /// Typed count from a runtime size via the non-throwing `UInt` lane.
    static func count<E>(_ n: Int) -> Index_Primitives.Index<E>.Count {
        Index_Primitives.Index<E>.Count(Cardinal(UInt(n)))
    }

    /// Typed index stream (setup-only construction).
    static func indexStream<E>(_ n: Int) -> [Index_Primitives.Index<E>] {
        (0..<n).map { Index_Primitives.Index<E>(Ordinal(UInt($0))) }
    }

    static func sharedCases() -> [Result] {
        var results: [Result] = []
        let n = 1_024
        let gateOps = elementOpsTarget
        let seed = opaque(7)

        var s = SharedColumn(LinearColumn(minimumCapacity: count(n)))
        for i in 0..<n { s.append(i) }

        // 1. The gate alone, on an always-unique box.
        results.append(Result(
            name: "gate.prepareForMutation", subject: "shared.unique", n: n, opsPerBatch: gateOps,
            perOpNs: sample(opsPerBatch: gateOps) {
                for _ in 0..<gateOps { s.prepareForMutation() }
                sink(s.isEmpty ? 0 : 1)
            }
        ))

        results.append(Result(
            name: "gate.ensureUnique", subject: "shared.unique", n: n, opsPerBatch: gateOps,
            perOpNs: sample(opsPerBatch: gateOps) {
                var detached = 0
                for _ in 0..<gateOps where s.ensureUnique() { detached &+= 1 }
                sink(detached)
            }
        ))

        // 2. Gated vs assuming-unique pairs: append+removeLast cycles.
        let pairTarget = elementOpsTarget / 2

        results.append(Result(
            name: "appendPop.gated", subject: "shared.unique", n: n, opsPerBatch: pairTarget * 2,
            perOpNs: sample(opsPerBatch: pairTarget * 2) {
                var acc = 0
                for i in 0..<pairTarget {
                    s.append(i &+ seed)
                    acc &+= s.removeLast()
                }
                sink(acc)
            }
        ))

        results.append(Result(
            name: "appendPop.assumingUnique", subject: "shared.unique", n: n, opsPerBatch: pairTarget * 2,
            perOpNs: sample(opsPerBatch: pairTarget * 2) {
                var acc = 0
                for i in 0..<pairTarget {
                    s.appendAssumingUnique(i &+ seed)
                    acc &+= s.removeLastAssumingUnique()
                }
                sink(acc)
            }
        ))

        var bare = LinearColumn(minimumCapacity: count(n))
        for i in 0..<n { bare.append(i) }

        results.append(Result(
            name: "appendPop.bareColumn", subject: "column.direct", n: n, opsPerBatch: pairTarget * 2,
            perOpNs: sample(opsPerBatch: pairTarget * 2) {
                var acc = 0
                for i in 0..<pairTarget {
                    bare.append(i &+ seed)
                    acc &+= bare.removeLast()
                }
                sink(acc)
            }
        ))

        // 3. Writes: per-element subscript vs bulk span vs assuming-unique span.
        let idxs: [Index_Primitives.Index<Int>] = indexStream(n)
        let passes = Swift.max(1, elementOpsTarget / n)
        let writeOps = passes * n
        let v = opaque(7)

        results.append(Result(
            name: "write.subscript", subject: "shared.unique", n: n, opsPerBatch: writeOps,
            perOpNs: sample(opsPerBatch: writeOps) {
                for _ in 0..<passes {
                    for idx in idxs { s[idx] = v }
                }
                sink(s[idxs[0]])
            }
        ))

        results.append(Result(
            name: "write.span", subject: "shared.unique", n: n, opsPerBatch: writeOps,
            perOpNs: sample(opsPerBatch: writeOps) {
                for _ in 0..<passes {
                    s.withMutableSpan { ms in
                        for i in 0..<n { ms[i] = v }
                    }
                }
                sink(s[idxs[0]])
            }
        ))

        results.append(Result(
            name: "write.spanAssumingUnique", subject: "shared.unique", n: n, opsPerBatch: writeOps,
            perOpNs: sample(opsPerBatch: writeOps) {
                for _ in 0..<passes {
                    s.withMutableSpanAssumingUnique { ms in
                        for i in 0..<n { ms[i] = v }
                    }
                }
                sink(s[idxs[0]])
            }
        ))

        // 4. Reads: subscript through the box vs span vend vs bare column.
        results.append(Result(
            name: "read.subscript", subject: "shared.unique", n: n, opsPerBatch: writeOps,
            perOpNs: sample(opsPerBatch: writeOps) {
                var sum = 0
                for _ in 0..<passes {
                    for idx in idxs { sum &+= s[idx] }
                }
                sink(sum)
            }
        ))

        results.append(Result(
            name: "read.span", subject: "shared.unique", n: n, opsPerBatch: writeOps,
            perOpNs: sample(opsPerBatch: writeOps) {
                var sum = 0
                for _ in 0..<passes {
                    s.withSpan { sp in
                        for i in 0..<n { sum &+= sp[i] }
                    }
                }
                sink(sum)
            }
        ))

        results.append(Result(
            name: "read.subscript", subject: "column.direct", n: n, opsPerBatch: writeOps,
            perOpNs: sample(opsPerBatch: writeOps) {
                var sum = 0
                for _ in 0..<passes {
                    for idx in idxs { sum &+= bare[idx] }
                }
                sink(sum)
            }
        ))

        // 5. Detach (sibling alive) at two scales — one op = one full detach.
        for dn in [1_024, 65_536] {
            var owner = SharedColumn(LinearColumn(minimumCapacity: count(dn)))
            for i in 0..<dn { owner.append(i) }
            let reps = Swift.max(16, copiedSlotsTarget / dn)
            let first: [Index_Primitives.Index<Int>] = indexStream(1)

            results.append(Result(
                name: "detach.firstMutation", subject: "shared.sibling", n: dn, opsPerBatch: reps,
                perOpNs: sample(opsPerBatch: reps) {
                    var acc = 0
                    for _ in 0..<reps {
                        var sibling = owner
                        sibling[first[0]] = v
                        acc &+= sibling[first[0]]
                    }
                    sink(acc)
                }
            ))
        }

        return results
    }
}

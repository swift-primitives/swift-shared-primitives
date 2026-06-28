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

public import Ownership_Box_Primitives

// MARK: - Scoped column access at the class hop (the ratified trio, ASK-C 2026-06-10)
//
// The 4+1-op seam carries element access, back-initialize, boundary moves, and the
// gate — and nothing else. Ops the seam cannot spell (growth, front-insert, compact,
// column-specific teardown) cross the box through ONE generic device instead of
// per-family op-forwards accumulating here: the gate-first scoped accessor — the
// `withMutableSpan` discipline (`Shared+Span.swift`) generalized from the element
// region to the column's own API. Families pin THEIR ops in THEIR packages:
//
// ```swift
// extension Queue where S: ~Copyable {
//     public mutating func pushFront<E>(_ element: consuming E)
//     where S == Shared<E, Buffer<…>.Ring> {
//         store.withUnique(consuming: element) { ring, element in
//             ring.pushFront(element)
//         }
//     }
// }
// ```

extension Shared where Element: ~Copyable, B: ~Copyable {
    /// Scoped MUTABLE access to the uniquely-owned column: restores uniqueness FIRST
    /// (the gate — siblings sharing the box are detached before the closure sees the
    /// buffer), then yields the wrapped buffer.
    ///
    /// Exclusivity holds `self` for the call, so no new sharer can form mid-closure;
    /// on `~Copyable`-element columns the gate is the usual no-op. The yielded `inout B`
    /// cannot escape (non-escaping closure) and cannot be duplicated (`B: ~Copyable`).
    @inlinable
    public mutating func withUnique<R: ~Copyable, Failure: Swift.Error>(
        _ body: (inout B) throws(Failure) -> R
    ) throws(Failure) -> R {
        ensureUnique()
        return try body(&box.unguarded)
    }

    /// The payload-threading form: moves `payload` INTO the column.
    ///
    /// Exists because a `consuming` parameter cannot be consumed inside the closure on
    /// 6.3.2 ("missing reinitialization of closure capture after consume" — the
    /// closure-capture consume restriction applies to non-escaping closures too), so a
    /// value bound for the column is handed to the body as a `consuming` closure
    /// PARAMETER instead of a capture.
    @inlinable
    public mutating func withUnique<T: ~Copyable, R: ~Copyable, Failure: Swift.Error>(
        consuming payload: consuming T,
        _ body: (inout B, consuming T) throws(Failure) -> R
    ) throws(Failure) -> R {
        ensureUnique()
        return try body(&box.unguarded, payload)
    }

    /// Scoped BORROWING access to the column (reads never need uniqueness — no gate).
    @inlinable
    public func withColumn<R: ~Copyable, Failure: Swift.Error>(
        _ body: (borrowing B) throws(Failure) -> R
    ) throws(Failure) -> R {
        try body(box.unguarded)
    }
}

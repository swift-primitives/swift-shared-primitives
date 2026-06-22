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

public import Buffer_Primitive
public import Buffer_Linear_Primitive
public import Storage_Contiguous_Primitives
public import Memory_Heap_Primitives
public import Memory_Allocator_Primitive

// MARK: - Span surface (scoped at the class hop)
//
// A RETURNING span cannot be forwarded out of a class-property access (its formal access scope
// ends first — the coroutine-window rule), so the shared column's region views are the
// SCOPED/yielding forms. The mutable form restores uniqueness FIRST (the stdlib
// `_makeMutableAndUnique()` order — a mutable view over a shared box would alias).

extension Shared where Element: ~Copyable, B: ~Copyable {
    /// Calls `body` with a read-only span over the live elements.
    @inlinable
    public func withSpan<R, Failure: Swift.Error>(
        _ body: (Swift.Span<Element>) throws(Failure) -> R
    ) throws(Failure) -> R
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear {
        try Self._withSpan(box.wrapped, body)
    }

    /// Calls `body` with a mutable span over the live elements. CoW-checked FIRST for
    /// Copyable elements (uniqueness is restored before any mutable view exists).
    @inlinable
    public mutating func withMutableSpan<R, Failure: Swift.Error>(
        _ body: (inout Swift.MutableSpan<Element>) throws(Failure) -> R
    ) throws(Failure) -> R
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear, Element: Copyable {
        ensureUnique()
        return try Self._withMutableSpan(&box.wrapped, body)
    }

    /// Mutable span on the statically-unique (~Copyable-element) column.
    /// Debug builds assert uniqueness (see `appendAssumingUnique`).
    @inlinable
    public mutating func withMutableSpanAssumingUnique<R, Failure: Swift.Error>(
        _ body: (inout Swift.MutableSpan<Element>) throws(Failure) -> R
    ) throws(Failure) -> R
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear {
        assert(isKnownUniquelyReferenced(&box), "AssumingUnique on a shared box")
        return try Self._withMutableSpan(&box.wrapped, body)
    }

    // The hop helpers: the buffer arrives as a PARAMETER (borrow / inout) — struct-containment
    // regime inside, so the buffer's own span surfaces compose soundly.
    @inlinable
    internal static func _withSpan<R, Failure: Swift.Error>(
        _ buffer: borrowing Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear,
        _ body: (Swift.Span<Element>) throws(Failure) -> R
    ) throws(Failure) -> R {
        try body(buffer.span)
    }

    @inlinable
    internal static func _withMutableSpan<R, Failure: Swift.Error>(
        _ buffer: inout Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear,
        _ body: (inout Swift.MutableSpan<Element>) throws(Failure) -> R
    ) throws(Failure) -> R {
        var span = buffer.mutableSpan
        return try body(&span)
    }
}

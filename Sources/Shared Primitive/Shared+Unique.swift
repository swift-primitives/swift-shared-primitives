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

// MARK: - Construction (pinned per column; drain + clone strategies are supplied here)
//
// The two overloads split on element copyability: the `Copyable` form captures the
// column's deep-copy strategy so a shared box can restore uniqueness; the `~Copyable`
// form captures none (the wrapper is statically unique — `Shared: Copyable` requires
// `Element: Copyable` — so uniqueness never needs restoring). At `Copyable` construction
// sites the more-constrained overload wins.

extension Shared where Element: ~Copyable, B: ~Copyable {
    /// Wraps a dense heap-linear buffer as a statically-unique (move-only element) column.
    @inlinable
    public init(_ buffer: consuming Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear {
        self.init(box: Box(buffer, drain: { $0.removeAll(keepingCapacity: true) }))
    }
}

extension Shared where Element: Copyable, B: ~Copyable {
    /// Wraps a dense heap-linear buffer as a shared (CoW-capable) column.
    @inlinable
    public init(_ buffer: consuming Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear {
        self.init(box: Box(
            buffer,
            drain: { $0.removeAll(keepingCapacity: true) },
            clone: { $0.clone() }
        ))
    }
}

// MARK: - Uniqueness

extension Shared where Element: Copyable, B: ~Copyable {
    /// Whether this value holds the only reference to its backing box.
    @inlinable
    public var isUnique: Bool {
        mutating get { isKnownUniquelyReferenced(&box) }
    }
}

extension Shared where Element: ~Copyable, B: ~Copyable {
    /// Ensures this value uniquely owns its backing, installing a deep copy of the live
    /// elements when the box is shared — the CoW restore, placed at the SEMANTIC boundary
    /// (every public mutation of a shared column runs through here FIRST; the seam beneath
    /// stays the unchecked fast lane).
    ///
    /// Fully generic over the column: on statically-unique (`~Copyable` element) columns the
    /// box can never be shared and this is a no-op; on `Copyable`-element columns the clone
    /// strategy captured at construction restores uniqueness.
    ///
    /// - Returns: `true` if a copy was made to restore uniqueness.
    @inlinable
    @discardableResult
    public mutating func ensureUnique() -> Bool {
        guard !isKnownUniquelyReferenced(&box) else { return false }
        guard let clone = box._clone else {
            // A shared box without a clone strategy cannot occur through the public
            // constructors: sharing requires `Shared: Copyable`, which requires
            // `Element: Copyable`, whose constructor captures the strategy.
            preconditionFailure("Shared box is not unique but carries no clone strategy")
        }
        box = Box(clone(box.wrapped), drain: box._drain, clone: box._clone)
        return true
    }
}

// MARK: - The CoW-checked mutation surface (heap-linear column)

extension Shared where Element: ~Copyable, B: ~Copyable {
    /// Appends an element (grows as needed). CoW-checked for Copyable elements.
    @inlinable
    public mutating func append(_ element: consuming Element)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear, Element: Copyable {
        ensureUnique()
        box.wrapped.append(element)
    }

    /// Appends an element on the statically-unique (~Copyable-element) column.
    ///
    /// The name states the caller's obligation: on a `Copyable`-element column this is
    /// the unchecked lane (debug builds assert the box really is unique — the `sending`
    /// spike confirmed no type-level proof of refcount uniqueness exists, report
    /// §ADDENDUM (i), so the assertion is the standing mitigation).
    @inlinable
    public mutating func appendAssumingUnique(_ element: consuming Element)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear {
        assert(isKnownUniquelyReferenced(&box), "AssumingUnique on a shared box")
        box.wrapped.append(element)
    }

    /// Removes and returns the last element. CoW-checked for Copyable elements.
    @inlinable
    public mutating func removeLast()
        -> Element
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear, Element: Copyable {
        ensureUnique()
        return box.wrapped.removeLast()
    }

    /// Removes and returns the last element on the statically-unique column.
    /// Debug builds assert uniqueness (see `appendAssumingUnique`).
    @inlinable
    public mutating func removeLastAssumingUnique()
        -> Element
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear {
        assert(isKnownUniquelyReferenced(&box), "AssumingUnique on a shared box")
        return box.wrapped.removeLast()
    }

    /// Ensures at least `minimumCapacity` slots, growing (uniquely) if needed.
    @inlinable
    public mutating func reserveCapacity(_ minimumCapacity: Index<Element>.Count)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear, Element: Copyable {
        ensureUnique()
        box.wrapped.reserveCapacity(minimumCapacity)
    }

    /// Grows or shrinks storage to exactly `newCapacity`, preserving elements (uniquely).
    @inlinable
    public mutating func reallocate(capacity newCapacity: Index<Element>.Count)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear, Element: Copyable {
        ensureUnique()
        box.wrapped.reallocate(capacity: newCapacity)
    }
}

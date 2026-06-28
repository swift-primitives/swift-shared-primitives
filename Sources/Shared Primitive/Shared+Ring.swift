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
public import Buffer_Ring_Primitive
public import Buffer_Ring_Bounded_Primitive
public import Storage_Contiguous_Primitives
public import Memory_Heap_Primitives
public import Memory_Allocator_Primitive
public import Ownership_Box_Primitives

// MARK: - Construction, pinned per RING column ([MEM-COPY-017] split; ASK-C 2026-06-10)
//
// The queue/deque families' CoW columns. Like the linear pairs (`Shared+Unique.swift`),
// the overloads split on element copyability — the `Copyable` form captures the
// column's deep-copy strategy (the ring's LINEARIZING `clone()`); the `~Copyable` form
// captures none (statically unique). Drains are the columns' own teardown ops; the box's
// class deinit owns element teardown (R-5, [MEM-SAFE-028]).

extension Shared where Element: ~Copyable, B: ~Copyable {
    /// Wraps a growable heap-ring buffer as a statically-unique (move-only element) column.
    @inlinable
    public init(_ buffer: consuming Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Ring)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Ring {
        self.init(box: Ownership.Box(buffer, drain: { $0.removeAll() }))
    }

    /// Wraps a bounded heap-ring buffer as a statically-unique (move-only element) column.
    @inlinable
    public init(_ buffer: consuming Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Ring.Bounded)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Ring.Bounded {
        self.init(box: Ownership.Box(buffer, drain: { $0.remove.all() }))
    }
}

extension Shared where Element: Copyable, B: ~Copyable {
    /// Wraps a growable heap-ring buffer as a shared (CoW-capable) column.
    @inlinable
    public init(_ buffer: consuming Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Ring)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Ring {
        self.init(box: Ownership.Box(
            buffer,
            drain: { $0.removeAll() },
            clone: { $0.clone() }
        ))
    }

    /// Wraps a bounded heap-ring buffer as a shared (CoW-capable) column.
    @inlinable
    public init(_ buffer: consuming Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Ring.Bounded)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Ring.Bounded {
        self.init(box: Ownership.Box(
            buffer,
            drain: { $0.remove.all() },
            clone: { $0.clone() }
        ))
    }
}

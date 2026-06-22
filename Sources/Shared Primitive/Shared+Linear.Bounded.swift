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
public import Buffer_Linear_Bounded_Primitive
public import Storage_Contiguous_Primitives
public import Memory_Heap_Primitives
public import Memory_Allocator_Primitive

// MARK: - Construction, pinned for the BOUNDED LINEAR column ([MEM-COPY-017] split;
// ASK-W1-1, principal-ruled 2026-06-11)
//
// The fixed-capacity ADT families' CoW column (Stack.Bounded, Fixed-adjacent
// disciplines). Mirrors `Shared+Ring.swift`'s Ring.Bounded pair: the `Copyable`
// form captures the column's deep-copy strategy — the CAPACITY-PRESERVING
// `Buffer.Linear.Bounded.clone()` (a shrink-to-fit copy would break the bounded
// capacity contract after a CoW detach); the `~Copyable` form captures none
// (statically unique). The drain is the column's own `remove.all()`; the box's
// class deinit owns element teardown (R-5, [MEM-SAFE-028]).

extension Shared where Element: ~Copyable, B: ~Copyable {
    /// Wraps a bounded heap-linear buffer as a statically-unique (move-only element) column.
    @inlinable
    public init(_ buffer: consuming Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear.Bounded)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear.Bounded {
        self.init(box: Box(buffer, drain: { $0.remove.all() }))
    }
}

extension Shared where Element: Copyable, B: ~Copyable {
    /// Wraps a bounded heap-linear buffer as a shared (CoW-capable) column.
    @inlinable
    public init(_ buffer: consuming Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear.Bounded)
    where B == Buffer<Storage<Memory.Allocator<Memory.Heap>>.Contiguous<Element>>.Linear.Bounded {
        self.init(box: Box(
            buffer,
            drain: { $0.remove.all() },
            clone: { $0.clone() }
        ))
    }
}

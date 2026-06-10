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

public import Storage_Primitive
public import Storage_Generational_Primitives
public import Memory_Heap_Primitives
public import Memory_Allocator_Primitive

// MARK: - Construction, pinned for the GENERATIONAL column ([MEM-COPY-017] split)
//
// The slot-map family's CoW column. The clone strategy is the GENERATION-PRESERVING
// deep copy (sibling handles survive a CoW detach); the drain is the store's own
// removeAll() (R-5, [MEM-SAFE-028]).

extension Shared where Element: ~Copyable, B: ~Copyable {
    /// Wraps a generational (slot-map) store as a statically-unique (move-only element)
    /// column.
    @inlinable
    public init(_ store: consuming Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element>)
    where B == Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element> {
        self.init(box: Box(store, drain: { $0.removeAll() }))
    }
}

extension Shared where Element: Copyable, B: ~Copyable {
    /// Wraps a generational (slot-map) store as a shared (CoW-capable) column.
    @inlinable
    public init(_ store: consuming Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element>)
    where B == Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element> {
        self.init(box: Box(
            store,
            drain: { $0.removeAll() },
            clone: { $0.clone() }
        ))
    }
}

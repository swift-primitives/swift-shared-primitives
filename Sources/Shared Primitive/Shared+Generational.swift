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
public import Store_Primitive
public import Memory_Heap_Primitives
public import Memory_Allocator_Primitive
public import Index_Primitives
public import Ownership_Box_Primitives

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
        self.init(box: Ownership.Box(store, drain: { $0.removeAll() }))
    }
}

extension Shared where Element: Copyable, B: ~Copyable {
    /// Wraps a generational (slot-map) store as a shared (CoW-capable) column.
    @inlinable
    public init(_ store: consuming Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element>)
    where B == Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element> {
        self.init(box: Ownership.Box(
            store,
            drain: { $0.removeAll() },
            clone: { $0.clone() }
        ))
    }
}

// MARK: - The HANDLE seam (SELF-GATING mutators) — the generational column's identity surface
//
// `Shared` forwards the generational slot-map's HANDLE surface so the linked family's
// `Buffer<S>.Linked<N>` composes over the shared column exactly as over the bare store
// (`swift-buffer-linked-primitives` writes its ops once over the `Store.Generational.`Protocol``
// capability seam both columns conform to). The positional `Store.`Protocol`` seam
// (`Shared+Store.Protocol.swift`) is a DENSE-PREFIX surface — wrong for a slot-map, whose
// occupancy is sparse and whose positions are non-canonical after removals; handle access is
// the slot-map's only sound surface.
//
// Every MUTATING forwarder restores uniqueness FIRST (`ensureUnique()`) — unconditionally, as the
// positional seam witnesses do (`Shared+Store.Protocol.swift:41-50`): `Shared` is conditionally
// `Sendable`, so an unchecked public mutator would let two threads holding copies of one box race.
// `ensureUnique()` is a no-op on statically-unique (`~Copyable`-element) columns and the CoW
// restore on `Copyable`-element columns; after the first restore in a batch the box IS unique, so
// every later branch is clone-free. Reads stay free.

extension Shared where Element: ~Copyable, B: ~Copyable {
    /// Inserts an element into the wrapped slot-map; returns a fresh handle to its slot.
    @inlinable
    public mutating func insert(_ element: consuming Element) -> Store.Generational.Handle
    where B == Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element> {
        ensureUnique()
        return box.unguarded.insert(element)
    }

    /// Removes the element at `handle` (moved out); `nil` if the handle is stale or invalid.
    @inlinable
    public mutating func remove(_ handle: Store.Generational.Handle) -> Element?
    where B == Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element> {
        ensureUnique()
        return box.unguarded.remove(handle)
    }

    /// Validated access to the element at `handle` (occupancy + generation checked).
    ///
    /// - Precondition: the handle is live (use `contains` for a soft check).
    @inlinable
    public subscript(_ handle: Store.Generational.Handle) -> Element
    where B == Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element> {
        _read { yield box.unguarded[handle] }
        _modify {
            ensureUnique()
            yield &box.unguarded[handle]
        }
    }

    /// Whether `handle` is live (in range, slot occupied, generation matches).
    @inlinable
    public func contains(_ handle: Store.Generational.Handle) -> Bool
    where B == Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element> {
        box.unguarded.contains(handle)
    }

    /// Grows the wrapped slot universe to `slotCapacity`, preserving handles index-aligned
    /// (outstanding handles keep resolving). CoW-checked: uniqueness restored FIRST.
    ///
    /// The growth pin for the linked family's `Shared` column; the move-based generation-
    /// preserving relocation lives in the store (`Storage.Generational.grow(to:)`).
    @inlinable
    public mutating func grow(to slotCapacity: Index<Element>.Count)
    where B == Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element> {
        ensureUnique()
        box.unguarded.grow(to: slotCapacity)
    }
}

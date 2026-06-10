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

public import Store_Protocol_Primitives
public import Buffer_Protocol_Primitives
public import Index_Primitives

// MARK: - The seam (SELF-GATING mutators) + the count surface
//
// `Shared` forwards the 4-op seam through the box so seam-generic composition reaches the
// shared column uniformly. Every MUTATING seam op restores uniqueness FIRST (`ensureUnique()`):
// `Shared` is conditionally `Sendable`, so an unchecked public mutator would let two threads
// holding copies of one box race through safe-looking code. The check is one
// `isKnownUniquelyReferenced` branch per op — after the first restore in a batch the box IS
// unique, so the branch is true and clone-free (batching economics survive). Reads stay free.
// The explicit `…AssumingUnique` spellings (`Shared+Unique.swift`) remain the ONLY unchecked
// mutation lane, for proven-hot batches whose uniqueness the caller has already established.

extension Shared: Store.`Protocol` where Element: ~Copyable, B: ~Copyable {
    @inlinable
    public var capacity: Index<Element>.Count { box.wrapped.capacity }

    @inlinable
    public subscript(slot: Index<Element>) -> Element {
        _read { yield box.wrapped[slot] }
        _modify {
            ensureUnique()
            yield &box.wrapped[slot]
        }
    }

    @inlinable
    public mutating func initialize(at slot: Index<Element>, to element: consuming Element) {
        ensureUnique()
        box.wrapped.initialize(at: slot, to: element)
    }

    @inlinable
    public mutating func move(at slot: Index<Element>) -> Element {
        ensureUnique()
        return box.wrapped.move(at: slot)
    }

    /// The semantic mutation gate — restores uniqueness before generic seam writes.
    ///
    /// Generic ADT code calls this before its first write in any semantic mutation,
    /// making protocol-keyed mutation (subscript `_modify`, removal, in-place edits)
    /// copy-on-write-correct on this column without per-column pins. The seam's own
    /// mutators above ALSO self-gate (defense in depth + Sendable soundness); after the
    /// gate runs once, their per-op checks are clone-free true branches.
    @inlinable
    public mutating func prepareForMutation() {
        ensureUnique()
    }
}

extension Shared: Buffer.`Protocol` where Element: ~Copyable, B: ~Copyable {
    public typealias Count = Index<Element>.Count

    /// The number of live elements (forwarded from the wrapped buffer's cursor).
    @inlinable
    public var count: Index<Element>.Count { box.wrapped.count }
}

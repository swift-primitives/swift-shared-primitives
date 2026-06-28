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

public import Buffer_Protocol_Primitives
public import Store_Protocol_Primitives
public import Index_Primitives
public import Ownership_Box_Primitives

/// The CoW column combinator — where conditional copyability enters the tower (the ratified
/// W4 design, `PROPOSAL-tower-perfected-design.md` §1.3 / R-1 / R-2).
///
/// `Shared` wraps a MOVE-ONLY buffer column in a refcounted box and is `Copyable` exactly when
/// the ELEMENT is copyable: copies share the box until the first mutation restores uniqueness
/// (`ensureUnique()`); `~Copyable`-element instantiations are move-only and statically unique
/// (no CoW surface exists for them at all). Copyability flows from the COLUMN:
/// `Array<Shared<E, …Linear>>` is the value-semantic column, `Array<…Linear>` stays the
/// zero-cost move-only column.
///
/// ## The SE-0427-forced spelling
///
/// Conditional `Copyable` may not depend on `B.Element` ("conditional conformance to
/// suppressible protocol 'Copyable' cannot depend on 'B.Element: Copyable'"), so the element is
/// a DIRECT generic parameter welded to the buffer's element — and that direct parameter is
/// also what makes `Shared` the ELEMENT-KEYED CONFORMANCE CARRIER (`Equatable`/`Hashable`/…):
/// the semantics the phantom buffers faked through `S.Element` re-materialize here, where the
/// element type is genuinely first-class.
///
/// ## Teardown (the drain-box rule, R-5, [MEM-SAFE-028])
///
/// Element teardown is owned by ``Ownership/Box``'s `Storage.deinit` — the one audited home for the
/// drain-box rule. Each construction site here supplies the buffer's own `removeAll`-class drain;
/// `Ownership.Box` drains through it before tearing down, so the storage oracle behind the box tears
/// down an EMPTY buffer (correct whether or not it runs) and the `-O` devirtualized-destroy
/// deinit-omission miscompile for generic-namespace-nested `~Copyable` columns is dodged (durable
/// repro: `swift-institute/Experiments/cow-box-deinit-omission-miscompile`).
@frozen
public struct Shared<
    Element: ~Copyable,
    B: Store.`Protocol` & Buffer.`Protocol` & ~Copyable
>: ~Copyable where B.Element == Element, B.Count == Index<Element>.Count {

    /// The single refcounted backing (internal — the unchecked lane lives behind the
    /// CoW-checked surface).
    @usableFromInline
    internal var box: Ownership.Box<B>

    @usableFromInline
    internal init(box: consuming Ownership.Box<B>) {
        self.box = box
    }

    /// Identity of the current backing box — CoW divergence is observable here (test window).
    @usableFromInline
    package var _boxID: ObjectIdentifier { box.identity }
}

// MARK: - Conditional Conformances (co-located per [COPY-FIX-004])

/// The union, in one type: `Copyable` exactly when `Element` is (the stored property is a class
/// reference — always Copyable-layout — and the struct carries no deinit, so SE-0427 is
/// satisfied; `B` stays explicitly `~Copyable` as the diagnostic demands). For `~Copyable`
/// elements no clone path exists, so the instantiation is move-only by construction.
extension Shared: Copyable where Element: Copyable, B: ~Copyable {}

/// Sendable via the CoW discipline: every PUBLIC mutation path — the semantic surface
/// (`Shared+Unique.swift`) AND the seam's own mutators (`Shared+Store.Protocol.swift`, which
/// self-gate) — restores uniqueness before writing, so a shared box is never mutated while
/// shared. The sole exception is the explicit `…AssumingUnique` spellings, whose names state
/// the obligation the caller assumes; misusing one on a shared box is the documented unchecked
/// lane, not the default path.
extension Shared: Sendable where Element: ~Copyable, B: Sendable & ~Copyable {}

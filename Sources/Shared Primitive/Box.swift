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

/// The one class in the tower above Memory — the refcounted box behind `Shared`.
///
/// ## The drain-box rule (R-5, binding)
///
/// The box's `deinit` OWNS element teardown: it drains the wrapped buffer through public
/// mutating API (the column-correct strategy captured at construction), then closes with
/// `_fixLifetime(self)` — the stdlib `_ContiguousArrayStorage` idiom. Relying on the wrapped
/// struct's own deinit oracle is UNSOUND here: under `-O`, once `isKnownUniquelyReferenced`
/// has been applied to the box, the devirtualized release synthesizes a destroy of the
/// generic-namespace-nested `~Copyable` struct that OMITS its user deinit while still
/// destroying its fields (elements leak, bytes are freed). Durable repro:
/// `swift-institute/Experiments/cow-box-deinit-omission-miscompile`. With the drain, the
/// struct oracle behind the box tears down an EMPTY buffer — count-driven, so correctness no
/// longer depends on whether the compiler runs it.
///
/// The drain strategy is a stored `@Sendable` closure so the box stays COLUMN-AGNOSTIC: each
/// pinned `Shared` construction site supplies the drain its column needs (linear prefix today;
/// ring/linked disciplines supply theirs when their ADTs arrive).
@usableFromInline
internal final class Box<Wrapped: ~Copyable> {
    @usableFromInline
    internal var wrapped: Wrapped

    @usableFromInline
    internal let _drain: @Sendable (inout Wrapped) -> Void

    /// The column-correct deep-copy strategy, captured at construction alongside the drain.
    /// `nil` on statically-unique columns (`~Copyable` elements — the wrapper cannot be
    /// duplicated, so uniqueness never needs restoring). Non-`nil` whenever the element is
    /// `Copyable`, where the box CAN become shared: `prepareForMutation()` clones through it.
    @usableFromInline
    internal let _clone: (@Sendable (borrowing Wrapped) -> Wrapped)?

    @usableFromInline
    internal init(
        _ wrapped: consuming Wrapped,
        drain: @escaping @Sendable (inout Wrapped) -> Void,
        clone: (@Sendable (borrowing Wrapped) -> Wrapped)? = nil
    ) {
        self.wrapped = wrapped
        self._drain = drain
        self._clone = clone
    }

    deinit {
        _drain(&wrapped)
        _fixLifetime(self)
    }
}

/// `@unchecked` is load-bearing: `wrapped` is mutable class state, which the compiler
/// cannot prove Sendable. Soundness is the CoW discipline AROUND the box — every public
/// mutation path restores uniqueness before writing (the `Shared: Sendable` note), both
/// strategies are themselves `@Sendable` by stored type, and the only unchecked lane
/// (`…AssumingUnique`) asserts uniqueness in debug. Adversarial record: the W2
/// concurrency suites (detach races, sibling storms, span windows) under the arc's
/// TSan gate — REPORT-arc-shared-soundness-W2.
extension Box: @unchecked Sendable where Wrapped: Sendable & ~Copyable {}

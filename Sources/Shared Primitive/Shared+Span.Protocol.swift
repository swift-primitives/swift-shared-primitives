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

public import Span_Protocol_Primitives

// MARK: - Span.Protocol (the lifetime-laundered span across the box hop)
//
// The recorded future-work item, ruled + spike-proven at W1-4 (2026-06-11;
// .handoffs/probes-2026-06-11/shared-span-spike/ — 4 probes, debug AND release).
// This is what admits `Array<Shared<E, B>>` (and every Shared-column ADT) to the
// span-bridged Collection lattice: `Array: Collection.Protocol where S: Span.Protocol`
// chains automatically once Shared itself conforms.
//
// ## Why laundering is needed
//
// The column lives behind a CLASS box. A span formed THROUGH the class-property
// access cannot escape that access's borrow window (the coroutine/class-hop rule —
// re-confirmed at the spike). The shape that works: form the inner span against a
// borrowed PARAMETER inside a helper (no property hop in the dependence chain),
// extract the raw window closure-scoped, construct a fresh span from the raw
// window, and re-root its lifetime on `self`'s borrow with the stdlib rebind
// (`_overrideLifetime` — the Span.Raw precedent class).
//
// ## Safety Invariant ([MEM-SAFE-025c])
//
// The laundered span is sound under the GATE-EVERYWHERE invariant:
// - While `self` is borrowed, the box is strongly retained and the storage
//   address is stable (heap column; the box never relocates its wrapped value's
//   buffer without mutation).
// - No mutation can occur through THIS handle while the span lives (exclusivity
//   on `self`).
// - Sibling handles never mutate THIS box: every checked mutation path gates
//   (`ensureUnique`/`prepareForMutation`) and a non-unique gate DETACHES the
//   mutating sibling into a fresh box first — this box's contents are immutable
//   from the outside for the span's whole life.
// - The unchecked `…AssumingUnique` lane is convention-restricted and
//   debug-asserted ([MEM-SAFE] residual, recorded at the W4 re-bless).
//
// The empty window uses a dangling-aligned non-nil base with count 0 (never
// dereferenced — the stdlib slice idiom).

extension Shared where Element: ~Copyable, B: ~Copyable {
    /// Forms the inner span against a borrowed PARAMETER (not the class-property
    /// access) and extracts the raw window closure-scoped — the dependence chain
    /// stays inside this call frame.
    @inlinable
    internal static func _window(
        of column: borrowing B
    ) -> (base: UnsafeRawPointer?, count: Int) where B: Span.`Protocol`, B.Element == Element {
        unsafe column.span.withUnsafeBufferPointer { ptr in
            unsafe (UnsafeRawPointer(ptr.baseAddress), ptr.count)
        }
    }
}

extension Shared: Span.`Protocol` where B: Span.`Protocol`, B: ~Copyable {
    /// A read-only contiguous view of the boxed column's elements, borrowing `self`.
    ///
    /// See the file-header Safety Invariant for the laundering soundness argument.
    @inlinable
    public var span: Swift.Span<Element> {
        @_lifetime(borrow self)
        borrowing get {
            let raw = unsafe Self._window(of: box.wrapped)
            let typed = unsafe (raw.base?.assumingMemoryBound(to: Element.self))
                ?? UnsafePointer<Element>(bitPattern: MemoryLayout<Int>.alignment).unsafelyUnwrapped
            let laundered = unsafe Swift.Span(_unsafeStart: typed, count: raw.base == nil ? 0 : raw.count)
            return unsafe _overrideLifetime(laundered, borrowing: self)
        }
    }
}

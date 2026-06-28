// exports.swift
// Shared Primitive declares `Shared<Element, B>` (the CoW column combinator) — a thin adapter
// over `Ownership.Box` (swift-ownership-primitives), which owns the box, the uniqueness gate,
// and the drain-box rule ([MEM-SAFE-028]).
// Per the exports-narrowing ruling (audit #9, 2026-06-10), nothing is re-exported:
// consumers SPELL their wrapped column by importing the column-vocabulary modules
// explicitly (Buffer/Storage/Memory/Index).

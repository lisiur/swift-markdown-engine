//
//  PasteScopeIndexTests.swift
//  Regression guard for the 10k-line paste freeze.
//
//  A paste of thousands of blank-line-separated paragraphs hands the styler
//  ~20k scoped paragraph candidates over ~20k blocks. `Ctx.inScope` answered
//  each block with a linear scan of the UNSORTED candidates, so one Cmd+V
//  spent ~35 s (Debug) inside those two loops while producing zero styled
//  ranges for plain text. `MarkdownASTStyler.ScopeIndex` replaces the scan
//  with one binary search; the whole insertText cascade drops to ~1.5 s.
//
//  Three halves, in the spirit of `InlineSpanDensityTests`:
//
//    - EQUIVALENCE — the index's answers are pinned to the naive definition
//      it replaced, on randomized overlapping/nested/degenerate inputs. This
//      is the always-on semantic net (it caught a real zero-length-query
//      divergence during development).
//    - RESULT — a document-wide 10k-paragraph restyle must produce no styled
//      ranges for plain text, always on, no timing.
//    - TIMED — the end-to-end styled pass must stay linear, OPT-IN via
//      `MDE_PERF=1 swift test` because a wall-clock bound is not portable and
//      `inScope` exposes no counters to assert on (the counted form the house
//      prefers does not exist here).
//

import Foundation
import Testing
@testable import MarkdownEngine

/// See `InlineSpanDensityTests` for the house rationale: gating CI on a
/// timing buys flakiness, not safety.
private let perfGateEnabled = ProcessInfo.processInfo.environment["MDE_PERF"] != nil

@Suite("Paste scope index (10k-line paste freeze)")
struct PasteScopeIndexTests {

    // MARK: - Equivalence with the naive linear scan

    @Test("the scope index answers exactly what the naive linear scan answers")
    func matchesLinearIntersectionScan() {
        for seed in 0..<32 {
            var rng = LCG(state: UInt64(seed) &+ 0x9E37_79B9_7F4A_7C15)
            // Random ranges over a 20k-char document: overlapping, nested,
            // degenerate, unsorted — everything the naive scan tolerates.
            let ranges = (0..<200).map { _ in
                NSRange(location: rng.next(22_000), length: rng.next(900))
            }
            let index = MarkdownASTStyler.ScopeIndex(ranges)

            for _ in 0..<500 {
                let query = NSRange(location: rng.next(23_000), length: rng.next(1_200))

                let expected = ranges.contains { scope in
                    NSIntersectionRange(scope, query).length > 0
                }
                #expect(index.intersects(query) == expected, "seed \(seed), query \(query)")
            }
        }
    }

    @Test("scope index edge cases match the naive scan")
    func edgeCases() {
        // Empty index intersects nothing.
        #expect(!MarkdownASTStyler.ScopeIndex([]).intersects(NSRange(location: 0, length: 10)))
        // NSNotFound location can never intersect.
        let index = MarkdownASTStyler.ScopeIndex([NSRange(location: 0, length: 10)])
        #expect(!index.intersects(NSRange(location: NSNotFound, length: 5)))
        // Zero-length scopes are filtered out at construction (the styler's
        // candidates are pre-filtered the same way)…
        let withDegenerate = MarkdownASTStyler.ScopeIndex([
            NSRange(location: 0, length: 0),
            NSRange(location: 5, length: 5),
        ])
        // …so a query touching only the degenerate scope's position misses.
        #expect(!withDegenerate.intersects(NSRange(location: 0, length: 1)))
        #expect(withDegenerate.intersects(NSRange(location: 5, length: 1)))
        // Touching boundaries (end == start) is NOT an overlap — matching
        // NSIntersectionRange's strict semantics.
        let adjacent = MarkdownASTStyler.ScopeIndex([NSRange(location: 0, length: 10)])
        #expect(!adjacent.intersects(NSRange(location: 10, length: 5)))
        #expect(adjacent.intersects(NSRange(location: 9, length: 5)))
        // Zero-length queries answer false — the caret-position case.
        #expect(!index.intersects(NSRange(location: 3, length: 0)))
    }

    // MARK: - End-to-end result, always on

    /// 10k blank-line-separated paragraphs — the shape that froze the app.
    private static let paragraph10k: String = {
        (0..<10_000).map { "Paragraph \($0): the quick brown fox jumps over the lazy dog." }
            .joined(separator: "\n\n")
    }()

    /// The parse really does see ~20k separate blocks, and the document-wide
    /// restyle that used to burn 35 s on them produces NOTHING for plain text.
    @Test("a document-wide 10k-paragraph restyle yields no styled ranges for plain text")
    func paragraphedPasteResult() {
        let doc = Self.paragraph10k
        let ns = doc as NSString

        let state = DocumentParseState()
        let tokens = state.tokens(
            for: doc,
            edit: ParseEditDescriptor(
                editedRange: NSRange(location: 0, length: ns.length),
                delta: ns.length
            )
        )
        let blocks = state.currentBlocks
        #expect(blocks.count >= 19_000)

        let candidates = paragraphCandidates(of: ns)
        let styled = styleParagraphed(doc, tokens: tokens, blocks: blocks, candidates: candidates)
        #expect(styled.isEmpty)
    }

    // MARK: - Cost curve, timed

    /// The quadratic this guards against measured 35.5 s (Debug) before the
    /// ScopeIndex fix and 0.45 s after — the 4 s ceiling has >8× headroom.
    @Test("a document-wide 10k-paragraph styled pass stays linear", .enabled(if: perfGateEnabled))
    func paragraphedPasteStylingStaysLinear() {
        let doc = Self.paragraph10k
        let ns = doc as NSString

        let state = DocumentParseState()
        let tokens = state.tokens(
            for: doc,
            edit: ParseEditDescriptor(
                editedRange: NSRange(location: 0, length: ns.length),
                delta: ns.length
            )
        )

        let candidates = paragraphCandidates(of: ns)
        let start = DispatchTime.now()
        let styled = styleParagraphed(doc, tokens: tokens, blocks: state.currentBlocks, candidates: candidates)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

        #expect(styled.isEmpty)
        #expect(ms < 4_000, "scoped styling went quadratic again (35.5 s before the ScopeIndex fix); took \(Int(ms)) ms")
    }

    // MARK: - Shared plumbing

    /// Paragraph candidates exactly as the coordinator's textDidChange builds
    /// them for a document-wide paste.
    private func paragraphCandidates(of ns: NSString) -> [NSRange] {
        var candidates: [NSRange] = []
        candidates.reserveCapacity(ns.length / 2)
        var cursor = 0
        while cursor < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            candidates.append(paragraph)
            let next = NSMaxRange(paragraph)
            if next <= cursor { break }
            cursor = next
        }
        return candidates
    }

    private func styleParagraphed(
        _ doc: String,
        tokens: [MarkdownToken],
        blocks: [Block],
        candidates: [NSRange]
    ) -> [StyledRange] {
        MarkdownStyler.styleAttributes(
            text: doc,
            fontName: "",
            fontSize: 14,
            caretLocation: (doc as NSString).length,
            selection: nil,
            activeTokenIndices: [],
            precomputedTokens: tokens,
            precomputedBlocks: blocks,
            scopedRanges: candidates
        )
    }
}

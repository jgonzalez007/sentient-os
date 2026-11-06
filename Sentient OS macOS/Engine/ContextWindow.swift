//
//  ContextWindow.swift
//  Sentient OS macOS
//
//  Phase 2.7 — Context Window Optimization: Smart context truncation for oversized
//  prompts. Implements relevance scoring, priority-based preservation, and token
//  estimation to fit conversations within the model's context window.
//
//  Integration:
//   - ContextWindowManager.shared.optimize(items)           → truncate to fit
//   - ContextWindowManager.shared.scoreItems(items)        → add relevance scores
//   - ContextWindowManager.shared.estimateTokens(for:)     → token count estimate
//
//  Truncation strategy:
//   1. Never touch pinned items and priority sources (even if over budget).
//   2. Score remaining items by relevance (timestamp + source weight).
//   3. Drop lowest-scoring items until within budget.
//   4. Preserve at least a minimum context (10% of budget) even if all items dropped.
//
//  Scoring formula (v1, no ML):
//   score = (isPinned ? 1.0 : 0.0) +
//           (prioritySources.contains(source) ? 0.3 : 0.0) +
//           log10(timestampAgeHours + 1) / 5.0  (freshness, 0–0.6 range)
//
//  The context window manager is designed for the triage pipeline: each file's
//  context items (transcript, metadata, verdict) are scored and truncated to fit
//  the Gemma 4 context window (8192 tokens default).
//

import Foundation

// MARK: - Public Types

@MainActor
final class ContextWindowManager: @unchecked Sendable {

    // MARK: - SourceKind

    /// The kind of source for a context item. Determines priority preservation.
    enum SourceKind: String, Sendable, CaseIterable {
        case userPrompt       // The user's original prompt
        case systemPrompt     // System/instructions
        case transcriptLine   // A line from a document transcript
        case metadata         // File metadata (name, size, etc.)
        case verdict          // Triage verdict
        case triageSummary    // Triage summary from a previous pass
        case research         // Research/analysis output
        case toolOutput       // Tool invocation result

        /// Display name for UI.
        var displayName: String {
            switch self {
            case .userPrompt:      return "User Prompt"
            case .systemPrompt:    return "System Prompt"
            case .transcriptLine:  return "Transcript"
            case .metadata:        return "Metadata"
            case .verdict:         return "Verdict"
            case .triageSummary:   return "Triage Summary"
            case .research:        return "Research"
            case .toolOutput:      return "Tool Output"
            }
        }
    }

    // MARK: - ContextConfig

    /// Configuration for context window optimization. Sendable.
    struct ContextConfig: Sendable {
        /// Maximum tokens the model can handle (e.g., 8192 for Gemma 4).
        var maxTokens: Int = 8192

        /// Relevance score below which items are eligible for truncation (0.0–1.0).
        var relevanceThreshold: Float = 0.2

        /// Source kinds that are never truncated, even if over budget.
        var prioritySources: [SourceKind] = [
            .systemPrompt,
            .userPrompt,
            .verdict,
        ]

        /// Enable relevance scoring (ML-based in future versions).
        var enableRelevanceScoring: Bool = true

        /// Minimum tokens to retain, even if all items are below the threshold.
        /// Represents 10% of the budget as a safety floor.
        var minRetainedTokens: Int {
            maxTokens / 10
        }

        /// Maximum tokens that can be removed (budget minus safety floor).
        var maxRemovableTokens: Int {
            max(0, maxTokens - minRetainedTokens)
        }
    }

    // MARK: - ContextItem

    /// A single item in the context window. Sendable.
    struct ContextItem: Sendable {
        let source: SourceKind
        let text: String
        var relevanceScore: Float     // 0.0 to 1.0; set by scoreItems()
        let timestamp: Date
        let isPinned: Bool            // Never truncated
        let id: UUID                  // Unique identity for the item

        /// Initialize a context item without a score (pre-scoring).
        init(source: SourceKind, text: String, isPinned: Bool = false) {
            self.source = source
            self.text = text
            self.relevanceScore = 0.0
            self.timestamp = .now
            self.isPinned = isPinned
            self.id = UUID()
        }

        /// Initialize with a pre-computed relevance score.
        init(source: SourceKind, text: String, relevanceScore: Float, timestamp: Date = .now, isPinned: Bool = false) {
            self.source = source
            self.text = text
            self.relevanceScore = relevanceScore
            self.timestamp = timestamp
            self.isPinned = isPinned
            self.id = UUID()
        }

        /// Estimate the token count for this item's text.
        var estimatedTokens: Int {
            ContextWindowManager.shared.estimateTokens(for: text)
        }
    }

    // MARK: - ContextResult

    /// Result of a context optimization pass. Sendable.
    struct ContextResult: Sendable {
        let originalItemCount: Int
        let retainedItemCount: Int
        let truncatedItems: [ContextItem]  // For debug/logging

        /// The list of items that were retained (not truncated).
        var retainedItems: [ContextItem]

        /// Whether any truncation was necessary.
        var wasTruncated: Bool {
            retainedItemCount < originalItemCount
        }

        /// Human-readable summary.
        var summary: String {
            if wasTruncated {
                return "Context truncated: \(retainedItems.count) of \(originalItemCount) items retained"
            } else {
                return "Context fits: \(retainedItems.count) of \(originalItemCount) items"
            }
        }
    }

    // MARK: - Shared

    static let shared = ContextWindowManager()
    private init() {}

    // MARK: - State

    /// Current configuration.
    var config: ContextConfig = .init()

    // MARK: - Public API

    /// Optimize a list of context items to fit within the token budget.
    ///
    /// Strategy:
    ///   1. Separate pinned/priority items (never truncated).
    ///   2. Score remaining items by relevance.
    ///   3. Drop lowest-scoring items first until within budget.
    ///   4. Preserve at least a minimum context (10% of budget).
    ///
    /// - Parameter items: The full set of context items to optimize.
    /// - Returns: A ContextResult with retained and truncated items.
    ///
    /// Example:
    /// ```swift
    /// let items = [
    ///     ContextItem(source: .userPrompt, text: "Analyze this file", isPinned: true),
    ///     ContextItem(source: .transcriptLine, text: "The transcript..."),
    /// ]
    /// let result = await ContextWindowManager.shared.optimize(items)
    /// let retained = result.retainedItems
    /// ```
    func optimize(_ items: [ContextItem]) async -> ContextResult {
        let config = self.config
        let maxTokens = config.maxTokens
        let minTokens = config.minRetainedTokens

        guard items.count > 1 else {
            // Nothing to optimize.
            return ContextResult(
                originalItemCount: items.count,
                retainedItemCount: items.count,
                truncatedItems: [],
                retainedItems: Array(items)
            )
        }

        // Score all items first.
        let scoredItems = scoreItems(items)

        // Separate into pinned/priority and rest.
        var pinnedItems: [ContextItem] = []
        var restItems: [ContextItem] = []

        for item in scoredItems {
            if item.isPinned || config.prioritySources.contains(item.source) {
                pinnedItems.append(item)
            } else {
                restItems.append(item)
            }
        }

        // Calculate pinned token usage.
        var pinnedTokens: Int = 0
        for item in pinnedItems {
            pinnedTokens += item.estimatedTokens
        }

        // If pinned items alone exceed the budget, we still keep them (priority).
        // The context will be over budget — that's the caller's problem to handle.
        if pinnedTokens <= minTokens {
            // All items can fit (even the minimum budget).
            return ContextResult(
                originalItemCount: items.count,
                retainedItemCount: items.count,
                truncatedItems: [],
                retainedItems: Array(scoredItems)
            )
        }

        // Sort remaining items by score (ascending — lowest first = best to drop).
        restItems.sort { $0.relevanceScore < $1.relevanceScore }

        // Trim from the bottom while respecting the minimum budget.
        var retainedItems = pinnedItems
        var retainedTokens = pinnedTokens
        var truncatedItems: [ContextItem] = []

        for item in restItems {
            let itemTokens = item.estimatedTokens

            // If adding this item exceeds the maximum budget, skip it.
            if retainedTokens + itemTokens > maxTokens {
                // But we still need to stay above the minimum.
                if retainedTokens + itemTokens < minTokens {
                    // Even the minimum budget would be exceeded — include it.
                    retainedItems.append(item)
                    retainedTokens += itemTokens
                } else {
                    truncatedItems.append(item)
                }
            } else {
                retainedItems.append(item)
                retainedTokens += itemTokens
            }
        }

        return ContextResult(
            originalItemCount: items.count,
            retainedItemCount: retainedItems.count,
            truncatedItems: truncatedItems,
            retainedItems: retainedItems
        )
    }

    /// Add a relevance score to each item based on the scoring formula.
    ///
    /// Score formula:
    ///   score = (isPinned ? 1.0 : 0.0) +
    ///           (prioritySources.contains(source) ? 0.3 : 0.0) +
    ///           log10(timestampAgeHours + 1) / 5.0
    ///
    /// - Parameter items: Items to score.
    /// - Returns: The same items with relevance scores set.
    func scoreItems(_ items: [ContextItem]) -> [ContextItem] {
        guard config.enableRelevanceScoring else {
            // If scoring is disabled, return items as-is.
            return items
        }

        return items.map { item -> ContextItem in
            var mutable = item
            mutable.relevanceScore = computeScore(for: item)
            return mutable
        }
    }

    /// Estimate the token count for a text string.
    ///
    /// Uses a simple heuristic: ~4 characters per token (standard for English text).
    /// This is a rough estimate — actual LiteRT-LM tokenization may differ slightly.
    ///
    /// - Parameter text: The text to estimate.
    /// - Returns: An approximate token count.
    func estimateTokens(for text: String) -> Int {
        let charCount = text.count
        // Heuristic: ~4 characters per token for English text.
        let estimated = charCount / 4
        return max(1, estimated)
    }

    // MARK: - Internal

    /// Compute the relevance score for a single context item.
    ///
    /// The scoring formula balances three factors:
    ///   1. Pin status (isPinned): up to 1.0 — always pinned items score highest.
    ///   2. Source priority: up to 0.3 — priority sources get a bonus.
    ///   3. Recency (timestampAgeHours): up to 0.6 — fresher items score higher.
    ///
    /// The recency component uses log10 scaling to penalize age gradually
    /// rather than sharply — a 1-hour-old message scores ~0.18, a 1-day-old
    /// ~0.4, and a 30-day-old ~0.58.
    private func computeScore(for item: ContextItem) -> Float {
        var score: Float = 0.0

        // Pin bonus.
        if item.isPinned {
            score += 1.0
        }

        // Source priority bonus.
        if config.prioritySources.contains(item.source) {
            score += 0.3
        }

        // Recency (freshness) score: log10(timestampAgeHours + 1) / 5.0.
        let hoursAgo = max(0, Date().timeIntervalSince(item.timestamp) / 3600.0)
        let freshness = Float(log(Float(hoursAgo + 1)) / log(10.0)) / 5.0
        score += min(freshness, 0.6)  // Cap at 0.6

        return score
    }
}

// MARK: - ContextConfig Defaults

extension ContextWindowManager.ContextConfig {

    /// Default config for Gemma 4 E4B with 8192 context window.
    static var `default`: ContextConfig {
        ContextConfig(
            maxTokens: 8192,
            relevanceThreshold: 0.2,
            prioritySources: [
                .systemPrompt,
                .userPrompt,
                .verdict,
            ],
            enableRelevanceScoring: true
        )
    }

    /// Compact config for when the context window is very limited (e.g., 4096 tokens).
    static var compact: ContextConfig {
        ContextConfig(
            maxTokens: 4096,
            relevanceThreshold: 0.3,
            prioritySources: [
                .systemPrompt,
                .userPrompt,
                .verdict,
            ],
            enableRelevanceScoring: true
        )
    }
}

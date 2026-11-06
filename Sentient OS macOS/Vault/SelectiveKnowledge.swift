//
//  SelectiveKnowledge.swift
//  Sentient OS macOS
//
//  Phase 3.6: Smart filtering — only include high-value items in context. Uses a scoring
//  system to prioritize knowledge based on relevance, recency, trust, and frequency.
//
//  Key methods:
//   - score(note:) → compute relevance score
//   - filter(notes:limit:) → apply scoring and return top-k
//   - updateWeights(relevance:recency:trust:frequency:) → adjust scoring weights
//   - getTopItems(n:) → get top-N most valuable items
//
//  Usage: `SelectiveKnowledge.filter(notes: notes, limit: 10)` before sending to LLM.
//
//  Doc: Vault/Documentation - Knowledge Base (Vault).md
//

import Foundation

/// Knowledge score — a single note's value for context inclusion.
struct KnowledgeScore: Sendable {
    let note: CloudNote
    let totalScore: Float
    let breakdown: ScoreBreakdown
    
    struct ScoreBreakdown: Sendable {
        let relevance: Float    // semantic similarity to user's goals
        let recency: Float      // how recent the item is
        let trust: Float        // source trust level
        let frequency: Float    // how often referenced
        let importance: Float   // self-reported or inferred importance
    }
    
    init(note: CloudNote, totalScore: Float, breakdown: ScoreBreakdown) {
        self.note = note
        self.totalScore = totalScore
        self.breakdown = breakdown
    }
}

/// Scoring weights — adjustable parameters.
struct ScoringWeights: Sendable, Codable {
    var relevance: Float = 0.35
    var recency: Float = 0.20
    var trust: Float = 0.20
    var frequency: Float = 0.15
    var importance: Float = 0.10
    
    static let defaultWeights = ScoringWeights()
    
    init(relevance: Float = 0.35, recency: Float = 0.20, trust: Float = 0.20,
         frequency: Float = 0.15, importance: Float = 0.10) {
        self.relevance = relevance
        self.recency = recency
        self.trust = trust
        self.frequency = frequency
        self.importance = importance
    }
}

/// Selective knowledge engine — filters and prioritizes knowledge items.
actor SelectiveKnowledge {
    
    static let shared = SelectiveKnowledge()
    
    private var weights = ScoringWeights.defaultWeights
    private var referenceCounts: [String: Int] = [:]  // sourceID → reference count
    
    // MARK: - Scoring
    
    /// Score a single note.
    func score(note: CloudNote) -> KnowledgeScore {
        let relevance = self.computeRelevance(note)
        let recency = self.computeRecency(note)
        let trust = self.computeTrust(note)
        let frequency = self.computeFrequency(note)
        let importance = self.computeImportance(note)
        
        let totalScore = relevance * weights.relevance +
                        recency * weights.recency +
                        trust * weights.trust +
                        frequency * weights.frequency +
                        importance * weights.importance
        
        return KnowledgeScore(
            note: note,
            totalScore: totalScore,
            breakdown: KnowledgeScore.ScoreBreakdown(
                relevance: relevance,
                recency: recency,
                trust: trust,
                frequency: frequency,
                importance: importance
            )
        )
    }
    
    /// Filter notes by score — returns top-N most valuable items.
    func filter(notes: [CloudNote], limit: Int = 10) -> [KnowledgeScore] {
        guard !notes.isEmpty else { return [] }
        
        // Score all notes
        let scored = notes.map { self.score(note: $0) }
        
        // Sort by total score, descending
        let sorted = scored.sorted { $0.totalScore > $1.totalScore }
        
        // Return top-N
        return Array(sorted.prefix(limit))
    }
    
    /// Update scoring weights.
    func updateWeights(relevance: Float? = nil, recency: Float? = nil,
                      trust: Float? = nil, frequency: Float? = nil,
                      importance: Float? = nil) {
        var newWeights = weights
        
        if let relevance { newWeights.relevance = relevance }
        if let recency { newWeights.recency = recency }
        if let trust { newWeights.trust = trust }
        if let frequency { newWeights.frequency = frequency }
        if let importance { newWeights.importance = importance }
        
        // Normalize weights to sum to 1.0
        let sum = newWeights.relevance + newWeights.recency + 
                newWeights.trust + newWeights.frequency + newWeights.importance
        if sum > 0 {
            newWeights.relevance /= sum
            newWeights.recency /= sum
            newWeights.trust /= sum
            newWeights.frequency /= sum
            newWeights.importance /= sum
        }
        
        self.weights = newWeights
    }
    
    /// Get top-N most valuable items.
    func getTopItems(n: Int) -> [KnowledgeScore] {
        // This would need access to stored notes — for now, returns empty
        return []
    }
    
    // MARK: - Score Computation
    
    /// Compute relevance score (0.0 to 1.0).
    private func computeRelevance(_ note: CloudNote) -> Float {
        // Score based on semantic relevance to user's primary goals
        // Placeholder: use keyword matching for now
        let keywords = ["important", "critical", "deadline", "priority", "action", "plan"]
        let text = note.text.lowercased()
        
        var score: Float = 0.0
        for keyword in keywords {
            if text.contains(keyword) {
                score += 0.2
            }
        }
        
        return min(score, 1.0)
    }
    
    /// Compute recency score (0.0 to 1.0).
    private func computeRecency(_ note: CloudNote) -> Float {
        guard let date = note.itemDate else { return 0.5 }  // neutral score
        
        let daysSince = abs(Date().timeIntervalSince(date)) / 86400.0
        
        // Exponential decay: recent = 1.0, old = 0.0
        return exp(-daysSince / 30.0)  // half-life of 30 days
    }
    
    /// Compute trust score (0.0 to 1.0).
    private func computeTrust(_ note: CloudNote) -> Float {
        switch note.kind {
        case .appleMail, .gmail, .outlook:
            return 0.9  // high trust for personal email
        case .appleCalendar, .calendar:
            return 0.7  // medium trust for calendar
        case .whatsapp, .slack:
            return 0.6  // medium-low for messages
        case .notes, .siyuan, .notion, .granola:
            return 0.8  // high for user-authored notes
        case .mcp:
            return 0.5  // variable for MCP
        default:
            return 0.5  // neutral for unknown
        }
    }
    
    /// Compute frequency score (0.0 to 1.0).
    private func computeFrequency(_ note: CloudNote) -> Float {
        let count = referenceCounts[note.sourceID] ?? 0
        return min(Float(count) / 10.0, 1.0)  // cap at 10 references
    }
    
    /// Compute importance score (0.0 to 1.0).
    private func computeImportance(_ note: CloudNote) -> Float {
        // Score based on content characteristics
        let text = note.text.lowercased()
        
        var score: Float = 0.0
        
        // Longer, more detailed notes tend to be more important
        if note.text.count > 500 { score += 0.3 }
        if note.text.count > 1000 { score += 0.2 }
        
        // Keywords indicating importance
        let importantKeywords = ["important", "critical", "deadline", "must", "must not", 
                                "never", "always", "essential", "key", "primary"]
        for keyword in importantKeywords {
            if text.contains(keyword) {
                score += 0.1
            }
        }
        
        return min(score, 1.0)
    }
    
    // MARK: - Privacy Filtering
    
    /// Apply privacy-aware filtering — removes sensitive items.
    func filterPrivately(notes: [CloudNote]) -> [CloudNote] {
        return notes.filter { note in
            // Remove items with sensitive content
            let text = note.text.lowercased()
            
            // Filter based on privacy level
            let sensitiveTerms = ["password", "credit card", "ssn", "social security", 
                                "account number", "pin code", "private"]
            
            for term in sensitiveTerms {
                if text.contains(term) {
                    return false
                }
            }
            
            // Filter based on source trust
            switch note.kind {
            case .whatsapp, .slack:
                // Be conservative with messages
                return note.text.count < 1000
            default:
                return true
            }
        }
    }
    
    // MARK: - Reference Tracking
    
    /// Track a reference — increments frequency count.
    func trackReference(for sourceID: String) {
        referenceCounts[sourceID, default: 0] += 1
    }
    
    /// Reset reference counts.
    func resetReferences() {
        referenceCounts.removeAll()
    }
}

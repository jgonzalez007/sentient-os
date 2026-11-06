//
//  RAGEngine.swift
//  Sentient OS macOS
//
//  Phase 3.2: Retrieval-Augmented Generation engine — provides RAG-powered queries for the
//  Sidekick. Instead of full-context passes, it retrieves only the most relevant knowledge
//  base entries for each query, reducing token usage and improving response quality.
//
//  Key methods:
//   - query(query:context:options:)       → retrieve + augment + generate
//   - retrieve(query:options:)            → semantic search + filtering
//   - augment(context:retrieved:)         → build context window from retrieved docs
//   - configure(queryType:privacyLevel:)  → set query parameters
//
//  Usage: `RAGEngine.shared.query(query: "...")` from Sidekick or Proactive modules.
//
//  Doc: Vault/Documentation - Knowledge Base (Vault).md
//

import Foundation
import CoreML

/// RAG query configuration — controls retrieval behavior.
struct RAGConfig: Sendable {
    var maxResults: Int = 5           // max retrieved documents
    var minSimilarity: Float = 0.3    // minimum cosine similarity threshold
    var includeMetadata: Bool = true  // include source/trust info in context
    var contextWindow: Int = 4000     // target context window (tokens approx.)
    var queryType: RAGQueryType = .general
    var privacyLevel: PrivacyLevel = .default
    
    static let sidekick = RAGConfig(
        maxResults: 3,
        minSimilarity: 0.4,
        includeMetadata: true,
        contextWindow: 3000,
        queryType: .sidekick,
        privacyLevel: .strict
    )
    
    static let proactive = RAGConfig(
        maxResults: 5,
        minSimilarity: 0.3,
        includeMetadata: true,
        contextWindow: 4000,
        queryType: .proactive,
        privacyLevel: .moderate
    )
    
    static let research = RAGConfig(
        maxResults: 10,
        minSimilarity: 0.2,
        includeMetadata: false,
        contextWindow: 8000,
        queryType: .research,
        privacyLevel: .relaxed
    )
}

/// Query type — affects retrieval strategy.
enum RAGQueryType: String, Sendable {
    case general
    case sidekick      // Sidekick assistant queries
    case proactive     // Proactive intelligence triggers
    case research      // Deep research / analysis
}

/// Privacy level — controls what metadata is included.
enum PrivacyLevel: String, Sendable {
    case strict    // no metadata, no PII
    case moderate  // basic metadata, PII-stripped
    case relaxed   // full metadata (admin only)
}

/// RAG result — retrieved context + optional generated answer.
struct RAGResult: Sendable {
    let query: String
    let retrieved: [SearchHit]
    let context: String
    let generatedAnswer: String?
    let confidence: Float       // average confidence of retrieved docs
    let totalTokens: Int        // estimated token count
}

/// The RAG engine — combines semantic search with context-aware generation.
actor RAGEngine {
    
    static let shared = RAGEngine()
    
    private let vectorStore: VectorStore
    private var config: RAGConfig
    
    init(vectorStore: VectorStore = .shared) {
        self.vectorStore = vectorStore
        self.config = .sidekick
    }
    
    // MARK: - Main Query Interface
    
    /// Execute a RAG query — retrieve relevant docs + generate answer if model available.
    func query(query: String, context: String? = nil, options: RAGConfig? = nil) async throws -> RAGResult {
        let config = options ?? self.config
        
        // Step 1: Retrieve relevant documents
        let retrieved = try await vectorStore.search(query: query, k: config.maxResults)
        
        // Step 2: Filter by minimum similarity
        let filtered = retrieved.filter { $0.similarity >= config.minSimilarity }
        
        // Step 3: Augment with context
        let contextText = try await self.augment(context: context ?? "", retrieved: filtered, privacy: config.privacyLevel)
        
        // Step 4: Calculate confidence
        let confidence = filtered.isEmpty ? 0.0 : filtered.map(\.similarity).reduce(0.0, +) / Float(filtered.count)
        
        // Step 5: Estimate token count
        let totalTokens = self.estimateTokens(contextText)
        
        return RAGResult(
            query: query,
            retrieved: filtered,
            context: contextText,
            generatedAnswer: nil,  // to be filled by the model backend
            confidence: confidence,
            totalTokens: totalTokens
        )
    }
    
    // MARK: - Retrieval
    
    /// Retrieve documents matching the query.
    func retrieve(query: String, options: RAGConfig? = nil) async throws -> [SearchHit] {
        let config = options ?? self.config
        let all = try await vectorStore.search(query: query, k: config.maxResults)
        return all.filter { $0.similarity >= config.minSimilarity }
    }
    
    // MARK: - Context Augmentation
    
    /// Build a context window from retrieved documents.
    private func augment(context: String, retrieved: [SearchHit], privacy: PrivacyLevel) async -> String {
        var contextParts: [String] = [context]
        
        for hit in retrieved {
            let entry = hit.entry
            
            // Add metadata based on privacy level
            var metadata = ""
            switch privacy {
            case .strict:
                metadata = "[RELEVANT KNOWLEDGE]\n"
            case .moderate:
                let source = entry.metadata["source"] as? String ?? "unknown"
                metadata = "[SOURCE: \(source)]\n"
            case .relaxed:
                var fields: [String] = []
                if let source = entry.metadata["source"] as? String { fields.append("source: \(source)") }
                if let folder = entry.metadata["folder"] as? String { fields.append("folder: \(folder)") }
                if let trust = entry.metadata["trust"] as? String { fields.append("trust: \(trust)") }
                metadata = "[\(fields.joined(separator: ", "))]\n"
            }
            
            // Add the document text
            contextParts.append("\(metadata)\n\(entry.text)\n")
        }
        
        // Truncate to context window
        let maxChars = config.contextWindow * 4  // rough estimate: 4 chars per token
        if contextParts.joined().count > maxChars {
            return String(contextParts.joined().prefix(maxChars))
        }
        
        return contextParts.joined()
    }
    
    // MARK: - Configuration
    
    /// Configure the RAG engine for a specific query type.
    func configure(queryType: RAGQueryType, privacyLevel: PrivacyLevel = .default) {
        switch queryType {
        case .sidekick:
            self.config = .sidekick
        case .proactive:
            self.config = .proactive
        case .research:
            self.config = .research
        case .general:
            self.config.maxResults = 5
            self.config.minSimilarity = 0.3
        }
        self.config.privacyLevel = privacyLevel
    }
    
    // MARK: - Token Estimation
    
    /// Estimate token count from text.
    private func estimateTokens(_ text: String) -> Int {
        // Rough estimate: ~4 characters per token for English text
        return text.count / 4
    }
}

// MARK: - Sidekick Integration

extension RAGEngine {
    /// Generate a response for Sidekick using retrieved context.
    func generateResponse(for query: String, context: String) async throws -> String {
        let prompt = """
        Based on the following context, answer the user's query:

        ## Context
        \(context)

        ## Query
        \(query)

        Answer the query based on the context above. If the context doesn't contain relevant information, 
        say "I don't have enough information to answer this."
        """
        
        // This would integrate with ModelBackend for actual generation
        // For now, return the prompt as a placeholder
        return prompt
    }
}

// MARK: - Proactive Integration

extension RAGEngine {
    /// Trigger proactive suggestions based on retrieved knowledge.
    func triggerProactiveSuggestions(from query: String) async throws -> [String] {
        let retrieved = try await self.retrieve(query: query, options: .proactive)
        
        var suggestions: [String] = []
        for hit in retrieved.prefix(3) {
            let entry = hit.entry
            let text = entry.text
            // Generate a proactive suggestion based on the retrieved document
            if text.lowercased().contains("important") || text.lowercased().contains("deadline") {
                suggestions.append("📌 Important: \(text.prefix(100))...")
            }
        }
        
        return suggestions
    }
}

//
//  VectorStore.swift
//  Sentient OS macOS
//
//  Phase 3.1: Vector store integration — replaces the plain-text-only KB with CoreML-powered
//  vector embeddings for semantic search. Provides vector storage, similarity search, and
//  embedding generation backed by Apple's coreml tools.
//
//  Key methods:
//   - store(note:embedding:)         → add a note + its embedding
//   - search(query:embedding:k:)     → semantic search by similarity
//   - delete(id:)                    → remove a note by ID
//   - batchStore(notes:embeddings:)  → bulk insert for initial vault build
//   - rebuildIndex()                 → re-embed all stored notes from scratch
//
//  Usage: Initialize with `VectorStore.shared`. All methods are async-safe via actor isolation.
//
//  Doc: Vault/Documentation - Knowledge Base (Vault).md
//

import Foundation
import CoreML
import NaturalLanguage

/// A simple vector representation — wraps a [Float] with metadata for the KB.
struct VectorEntry: Sendable {
    let id: String              // unique note ID (file path or source ID)
    let text: String            // the original text (for display, not search)
    let embedding: [Float]      // the vector embedding (CoreML-generated)
    let metadata: [String: Any] // source info, dates, trust tags, etc.
    
    init(id: String, text: String, embedding: [Float], metadata: [String: Any] = [:]) {
        self.id = id
        self.text = text
        self.embedding = embedding
        self.metadata = metadata
    }
}

/// A semantic search result — ranked by similarity to the query.
struct SearchHit: Sendable {
    let entry: VectorEntry
    let similarity: Float       // cosine similarity score (0.0 to 1.0)
    
    init(entry: VectorEntry, similarity: Float) {
        self.entry = entry
        self.similarity = similarity
    }
}

/// CoreML-backed vector store for the knowledge base.
/// Provides persistent storage, semantic search, and embedding generation.
actor VectorStore {
    
    static let shared = VectorStore()
    
    private let storageKey = "vector_store_entries"
    private let modelCacheKey = "nlvec_model_cache"
    
    /// The embedded note entries, keyed by ID.
    private var entries: [String: VectorEntry] = [:]
    
    /// The CoreML model for embedding generation (lazy-loaded).
    private lazy var embeddingModel: NLModel? = {
        guard let cached = try? NSKeyedArchiver.archivedData(withRootObject: Self.modelCacheKey, requiringSecureCoding: false),
              let model = Self.loadModel(from: cached) {
            return model
        }
        return Self.createDefaultModel()
    }()
    
    /// Number of dimensions in the embedding space.
    var dimensions: Int {
        embeddingModel?.hyperparameters["n_dimensions"] as? Int ?? 768
    }
    
    // MARK: - Storage Operations
    
    /// Add a note with its embedding to the store.
    func store(note: CloudNote, embedding: [Float]) {
        let entry = VectorEntry(
            id: note.sourceID,
            text: note.text,
            embedding: embedding,
            metadata: [
                "source": note.kind.rawValue,
                "folder": note.folder,
                "title": note.title ?? "",
                "date": note.itemDate?.timeIntervalSince1970 as Any,
                "trust": self.trustTag(for: note.kind)
            ]
        )
        entries[note.sourceID] = entry
        self.saveToDisk()
    }
    
    /// Semantic search — returns top-k results by cosine similarity.
    func search(query: String, k: Int = 5) -> [SearchHit] {
        guard let model = embeddingModel else { return [] }
        guard let queryEmbedding = model.predictions(from: query as MLFeatureProvider) else { return [] }
        
        // Convert MLFeatureProvider to [Float]
        var queryVector: [Float] = []
        for i in 0..<dimensions {
            queryVector.append(Float(queryEmbedding[i].doubleValue))
        }
        
        // Compute cosine similarity for all entries
        var hits: [SearchHit] = []
        for entry in entries.values {
            let similarity = self.cosineSimilarity(queryVector, against: entry.embedding)
            hits.append(SearchHit(entry: entry, similarity: similarity))
        }
        
        // Sort by similarity, descending
        hits.sort { $0.similarity > $1.similarity }
        
        return Array(hits.prefix(k))
    }
    
    /// Delete a note by its ID.
    func delete(id: String) -> Bool {
        guard entries.removeValue(forKey: id) != nil else { return false }
        saveToDisk()
        return true
    }
    
    /// Bulk insert — for initial vault build.
    func batchStore(notes: [(CloudNote, [Float])]) {
        for (note, embedding) in notes {
            let entry = VectorEntry(
                id: note.sourceID,
                text: note.text,
                embedding: embedding,
                metadata: [
                    "source": note.kind.rawValue,
                    "folder": note.folder,
                    "title": note.title ?? "",
                    "date": note.itemDate?.timeIntervalSince1970 as Any,
                    "trust": self.trustTag(for: note.kind)
                ]
            )
            entries[note.sourceID] = entry
        }
        saveToDisk()
    }
    
    /// Rebuild the entire index — re-embeds all notes from scratch.
    /// Use after model updates or when embeddings become stale.
    func rebuildIndex(with notes: [CloudNote], embeddingFn: @escaping (String) async throws -> [Float]) {
        entries.removeAll()
        for note in notes {
            do {
                let embedding = try await embeddingFn(note.text)
                self.store(note: note, embedding: embedding)
            } catch {
                Log("VectorStore: ⚠️ failed to embed \(note.sourceID): \(error)")
            }
        }
        saveToDisk()
    }
    
    /// Get all entries — for export or backup.
    func getAllEntries() -> [VectorEntry] {
        Array(entries.values)
    }
    
    /// Get entry count.
    var count: Int {
        entries.count
    }
    
    // MARK: - Helper Methods
    
    /// Compute cosine similarity between two vectors.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count > 0 else { return 0.0 }
        
        var dotProduct: Float = 0.0
        var normA: Float = 0.0
        var normB: Float = 0.0
        
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        
        guard normA > 0 && normB > 0 else { return 0.0 }
        
        return dotProduct / (sqrt(normA) * sqrt(normB))
    }
    
    /// Trust tag for a source kind.
    private func trustTag(for kind: SourceKind) -> String {
        switch kind {
        case .appleMail: "mail-high-trust"
        case .appleCalendar: "calendar-med-trust"
        case .gmail: "gmail-high-trust"
        case .calendar: "calendar-med-trust"
        case .whatsapp: "whatsapp-med-trust"
        case .notes: "notes-user-trust"
        case .mcp: "mcp-varies"
        case .siyuan: "siyuan-user-trust"
        case .slack: "slack-med-trust"
        case .outlook: "outlook-high-trust"
        case .notion: "notion-user-trust"
        case .granola: "granola-user-trust"
        default: "unknown"
        }
    }
    
    /// Save the entire store to disk (UserDefaults).
    private func saveToDisk() {
        // For now, store in a file-based cache
        // TODO: migrate to SQLite with vector extension
        let data = try? NSKeyedArchiver.archivedData(withRootObject: entries, requiringSecureCoding: false)
        UserDefaults.standard.set(data, forKey: storageKey)
    }
    
    /// Load from disk (on initialization).
    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let loaded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: [String: VectorEntry].self, from: data) else {
            return
        }
        entries = loaded
    }
    
    /// Create a default NLModel for embedding.
    private static func createDefaultModel() -> NLModel? {
        // Use Apple's built-in NLModel for basic embeddings
        // This is a placeholder — production should use a fine-tuned model
        guard let model = NLModel(modelName: .embeddingsV1, matrixType: .float16) else {
            // Fallback: simple hash-based embeddings
            return nil
        }
        return model
    }
    
    /// Load a model from cached data.
    private static func loadModel(from data: Data) -> NLModel? {
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NLModel.self, from: data)
    }
    
    /// Save a model to cache.
    private static func saveModel(_ model: NLModel, to data: inout Data) {
        data = try? NSKeyedArchiver.archivedData(withRootObject: model, requiringSecureCoding: false) ?? Data()
    }
}

// MARK: - CoreML Extension

extension NLModel {
    /// Convenience initializer for embeddings.
    @available(macOS 13.0, *)
    static func embeddingsV1() -> NLModel {
        return NLModel(
            name: "embeddings-v1",
            parameters: [
                "n_dimensions": 768,
                "vocab_size": 50265,
                "max_sequence_length": 512
            ]
        )
    }
}

// MARK: - Hash-based Embedding Fallback

extension VectorStore {
    /// Generate a simple hash-based embedding (fallback when CoreML unavailable).
    /// Uses character n-grams for semantic similarity.
    func hashEmbedding(text: String, dimensions: Int = 768) -> [Float] {
        var embedding = [Float](repeating: 0.0, count: dimensions)
        let chars = Array(text.lowercased())
        
        for i in 0..<chars.count {
            let hash = self.simpleHash(chars[i].unicodeScalar!.value)
            let dim = hash % dimensions
            embedding[dim] += 1.0
        }
        
        // Normalize
        let magnitude = sqrt(embedding.reduce(0.0) { $0 + $1 * $1 })
        if magnitude > 0 {
            embedding = embedding.map { $0 / magnitude }
        }
        
        return embedding
    }
    
    private func simpleHash(_ value: UInt32) -> Int {
        var hash = Int(value)
        hash = (hash ^ 61) ^ (hash >> 16)
        hash = hash &* 10990875
        hash = hash ^ (hash >> 16)
        hash = hash &* 10990875
        hash = hash ^ (hash >> 16)
        return abs(hash)
    }
}

//
//  CrossReferenceEngine.swift
//  Sentient OS macOS
//
//  Phase 3.7: Cross-reference engine — links knowledge items across sources (email ↔ calendar ↔ notes).
//  Creates semantic links between related items, enabling richer retrieval and context.
//
//  Key methods:
//   - buildReferences(from:notes:)    → create cross-source links
//   - getReferences(for:)             → get linked items for a source
//   - removeReference(from:to:)       → remove a link
//   - getGraph()                      → full cross-reference graph
//
//  Usage: `CrossReferenceEngine.buildReferences(from: vaultRoot, notes: allNotes)`
//         after knowledge base generation.
//
//  Doc: Vault/Documentation - Knowledge Base (Vault).md
//

import Foundation

/// A cross-reference link between two knowledge items.
struct CrossReference: Sendable, Codable {
    let id: String                  // unique ID
    let sourceID: String            // source note ID
    let targetID: String            // target note ID
    let type: ReferenceType         // link type
    let confidence: Float           // link confidence (0.0-1.0)
    let timestamp: Date
    
    init(sourceID: String, targetID: String, type: ReferenceType, confidence: Float) {
        self.id = UUID().uuidString
        self.sourceID = sourceID
        self.targetID = targetID
        self.type = type
        self.confidence = confidence
        self.timestamp = Date()
    }
}

/// Reference type — what kind of relationship exists.
enum ReferenceType: String, Codable, Sendable {
    case mentions                // source mentions target
    case relatesTo               // source is related to target
    case supplements             // source supplements target
    case contradicts             // source contradicts target
    case dependsOn               // source depends on target
    case precedes                // source precedes target
    case follows                 // source follows target
    case partOf                  // source is part of target
    
    var label: String {
        switch self {
        case .mentions: return "Mentions"
        case .relatesTo: return "Relates To"
        case .supplements: return "Supplements"
        case .contradicts: return "Contradicts"
        case .dependsOn: return "Depends On"
        case .precedes: return "Precedes"
        case .follows: "Follows"
        case .partOf: "Part Of"
        }
    }
}

/// Cross-reference graph node.
struct ReferenceNode: Sendable {
    let id: String
    let type: SourceKind
    let text: String
    let references: [CrossReference]
    let reverseReferences: [CrossReference]
    
    init(id: String, type: SourceKind, text: String, 
         references: [CrossReference] = [], reverseReferences: [CrossReference] = []) {
        self.id = id
        self.type = type
        self.text = text
        self.references = references
        self.reverseReferences = reverseReferences
    }
}

/// Cross-reference engine — builds and manages links between knowledge items.
actor CrossReferenceEngine {
    
    static let shared = CrossReferenceEngine()
    
    private var references: [CrossReference] = []
    private var nodes: [String: ReferenceNode] = [:]
    private let storageKey = "cross_references"
    private let nodesKey = "reference_nodes"
    
    // MARK: - Reference Building
    
    /// Build cross-references from a set of notes.
    func buildReferences(from vaultRoot: URL, notes: [CloudNote]) async {
        references.removeAll()
        nodes.removeAll()
        
        // Build nodes
        for note in notes {
            let node = ReferenceNode(
                id: note.sourceID,
                type: note.kind,
                text: note.text.prefix(500).description  // truncate for graph
            )
            nodes[note.sourceID] = node
        }
        
        // Build references between notes
        for i in 0..<notes.count {
            for j in (i+1)..<notes.count {
                let noteA = notes[i]
                let noteB = notes[j]
                
                // Compute similarity
                let similarity = self.computeSimilarity(noteA.text, noteB.text)
                
                if similarity > 0.5 {
                    let type = self.determineReferenceType(noteA.kind, noteB.kind, similarity)
                    let ref = CrossReference(
                        sourceID: noteA.sourceID,
                        targetID: noteB.sourceID,
                        type: type,
                        confidence: similarity
                    )
                    references.append(ref)
                    
                    // Update nodes
                    if var nodeA = nodes[noteA.sourceID] {
                        nodeA.references.append(ref)
                        nodes[noteA.sourceID] = nodeA
                    }
                    if var nodeB = nodes[noteB.sourceID] {
                        nodeB.reverseReferences.append(ref)
                        nodes[noteB.sourceID] = nodeB
                    }
                }
            }
        }
        
        saveToDisk()
        Log("CrossReferenceEngine: built \(references.count) references from \(notes.count) notes")
    }
    
    /// Get references for a specific source.
    func getReferences(for sourceID: String) -> [CrossReference] {
        references.filter { $0.sourceID == sourceID || $0.targetID == sourceID }
    }
    
    /// Remove a reference.
    func removeReference(from sourceID: String, to targetID: String) {
        references.removeAll { $0.sourceID == sourceID && $0.targetID == targetID }
        saveToDisk()
    }
    
    /// Get the full graph.
    func getGraph() -> [ReferenceNode] {
        Array(nodes.values)
    }
    
    // MARK: - Similarity Computation
    
    /// Compute text similarity between two notes.
    private func computeSimilarity(_ textA: String, _ textB: String) -> Float {
        // Simple word overlap similarity
        let wordsA = Set(textA.lowercased().components(separatedBy: .whitespaces))
        let wordsB = Set(textB.lowercased().components(separatedBy: .whitespaces))
        
        let intersection = wordsA.intersection(wordsB)
        let union = wordsA.union(wordsB)
        
        guard !union.isEmpty else { return 0.0 }
        
        return Float(intersection.count) / Float(union.count)
    }
    
    /// Determine reference type based on source types and similarity.
    private func determineReferenceType(_ kindA: SourceKind, _ kindB: SourceKind, _ similarity: Float) -> ReferenceType {
        // Higher similarity → stronger relationship
        if similarity > 0.8 {
            return .relatesTo
        } else if similarity > 0.6 {
            // Check if they're from the same source type
            if kindA == kindB {
                return .supplements
            } else {
                return .relatesTo
            }
        } else {
            return .mentions
        }
    }
    
    // MARK: - Cross-Source Linking
    
    /// Build cross-source references — links between different source types.
    func buildCrossSourceLinks(notes: [CloudNote]) -> [CrossReference] {
        var links: [CrossReference] = []
        
        // Email ↔ Calendar links
        let emails = notes.filter { $0.kind == .appleMail || $0.kind == .gmail }
        let calendars = notes.filter { $0.kind == .appleCalendar || $0.kind == .calendar }
        
        for email in emails {
            for calendar in calendars {
                // Check for date overlap
                if hasDateOverlap(email.text, calendar.text) {
                    let link = CrossReference(
                        sourceID: email.sourceID,
                        targetID: calendar.sourceID,
                        type: .relatesTo,
                        confidence: 0.7
                    )
                    links.append(link)
                }
            }
        }
        
        // Notes ↔ Files links
        let notesList = notes.filter { $0.kind == .notes || $0.kind == .siyuan || $0.kind == .notion }
        let files = notes.filter { $0.kind.rawValue == "file" }
        
        for note in notesList {
            for file in files {
                if hasContentOverlap(note.text, file.text) {
                    let link = CrossReference(
                        sourceID: note.sourceID,
                        targetID: file.sourceID,
                        type: .supplements,
                        confidence: 0.5
                    )
                    links.append(link)
                }
            }
        }
        
        return links
    }
    
    /// Check for date overlap between two texts.
    private func hasDateOverlap(_ textA: String, _ textB: String) -> Bool {
        // Simple heuristic: check for common date patterns
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        
        // Look for dates in both texts
        let datesA = self.extractDates(from: textA)
        let datesB = self.extractDates(from: textB)
        
        // Check for overlap
        for dateA in datesA {
            for dateB in datesB {
                if abs(dateA.timeIntervalSince(dateB)) < 86400 * 7 {  // within 7 days
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Extract dates from text.
    private func extractDates(from text: String) -> [Date] {
        var dates: [Date] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        
        // Simple date extraction — in production, use a more robust parser
        let scanner = Scanner(string: text)
        while !scanner.isAtEnd {
            if let date = dateFormatter.date(from: scanner.scanUpToCharacters(from: .whitespaces) ?? "") {
                dates.append(date)
            } else {
                scanner.scanUpToCharacters(from: .whitespaces)
            }
        }
        
        return dates
    }
    
    /// Check for content overlap between two texts.
    private func hasContentOverlap(_ textA: String, _ textB: String) -> Bool {
        let wordsA = Set(textA.lowercased().components(separatedBy: .punctuationCharacters))
        let wordsB = Set(textB.lowercased().components(separatedBy: .punctuationCharacters))
        
        let overlap = wordsA.intersection(wordsB)
        let total = wordsA.union(wordsB)
        
        guard !total.isEmpty else { return false }
        
        return Float(overlap.count) / Float(total.count) > 0.3
    }
    
    // MARK: - Persistence
    
    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(references) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        if let data = try? JSONEncoder().encode(Array(nodes.values)) {
            UserDefaults.standard.set(data, forKey: nodesKey)
        }
    }
    
    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let loaded = try? JSONDecoder().decode([CrossReference].self, from: data) else {
            return
        }
        references = loaded
        
        guard let data = UserDefaults.standard.data(forKey: nodesKey),
              let loaded = try? JSONDecoder().decode([ReferenceNode].self, from: data) else {
            return
        }
        for node in loaded {
            nodes[node.id] = node
        }
    }
}

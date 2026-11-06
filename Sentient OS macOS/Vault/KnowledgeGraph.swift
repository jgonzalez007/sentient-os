//
//  KnowledgeGraph.swift
//  Sentient OS macOS
//
//  Phase 3.3: Knowledge graph upgrade — transforms the flat markdown vault into a proper graph
//  with entities, relationships, and temporal information. Provides graph-based retrieval and
//  cross-reference linking.
//
//  Key methods:
//   - addEntity(name:type:properties:timestamp:) → add a node to the graph
//   - addRelation(from:to:type:properties:timestamp:) → add an edge
//   - queryEntities(query:filters:) → graph-based search
//   - getGraphSnapshot() → full graph export
//   - buildFromVault(vaultRoot:) → initialize graph from existing vault
//
//  Usage: `KnowledgeGraph.shared` — auto-builds from vault on initialization.
//
//  Doc: Vault/Documentation - Knowledge Base (Vault).md
//

import Foundation
import CoreML

/// An entity in the knowledge graph — a person, place, thing, or concept.
struct GraphEntity: Codable, Sendable, Hashable {
    let id: String                  // unique identifier
    let name: String                // display name
    let type: EntityType            // entity type (person, event, etc.)
    var properties: [String: Any]   // key-value properties
    var timestamp: Date              // when this entity was created/updated
    
    init(id: String, name: String, type: EntityType, properties: [String: Any] = [:]) {
        self.id = id
        self.name = name
        self.type = type
        self.properties = properties
        self.timestamp = Date()
    }
}

/// A relationship between two entities.
struct GraphRelation: Codable, Sendable, Hashable {
    let id: String                  // unique identifier
    let from: String                // source entity ID
    let to: String                  // target entity ID
    let type: RelationType          // relationship type
    var properties: [String: Any]   // additional metadata
    var timestamp: Date              // when this relation was created
    
    init(id: String, from: String, to: String, type: RelationType, properties: [String: Any] = [:]) {
        self.id = id
        self.from = from
        self.to = to
        self.type = type
        self.properties = properties
        self.timestamp = Date()
    }
}

/// Entity type — categorizes nodes in the graph.
enum EntityType: String, Codable, Sendable, CaseIterable {
    case person
    case event
    case project
    case location
    case concept
    case document
    case tool
    case organization
    
    var label: String {
        switch self {
        case .person: return "Person"
        case .event: return "Event"
        case .project: return "Project"
        case .location: return "Location"
        case .concept: return "Concept"
        case .document: return "Document"
        case .tool: return "Tool"
        case .organization: return "Organization"
        }
    }
}

/// Relation type — categorizes edges in the graph.
enum RelationType: String, Codable, Sendable {
    case relatedTo
    case partOf
    case belongsTo
    case created
    case attended
    case locatedAt
    case uses
    case knownAbout
    case mentions
    case references
    case dependsOn
    case precedes
    case follows
    
    var label: String {
        switch self {
        case .relatedTo: return "Related To"
        case .partOf: return "Part Of"
        case .belongsTo: return "Belongs To"
        case .created: return "Created"
        case .attended: return "Attended"
        case .locatedAt: return "Located At"
        case .uses: return "Uses"
        case .knownAbout: return "Known About"
        case .mentions: return "Mentions"
        case .references: return "References"
        case .dependsOn: return "Depends On"
        case .precedes: return "Precedes"
        case .follows: return "Follows"
        }
    }
}

/// A graph query — defines what to search for.
struct GraphQuery: Sendable {
    var queryText: String
    var entityTypes: [EntityType]?          // filter by type
    var relationTypes: [RelationType]?      // filter by relation
    var dateRange: DateRange?               // filter by date
    var maxResults: Int = 10
    
    struct DateRange: Sendable {
        var start: Date?
        var end: Date?
    }
}

/// Graph query result — matches with context.
struct GraphResult: Sendable {
    let query: String
    let entities: [GraphEntity]
    let relations: [GraphRelation]
    let confidence: Float
    
    init(query: String, entities: [GraphEntity], relations: [GraphRelation], confidence: Float) {
        self.query = query
        self.entities = entities
        self.relations = relations
        self.confidence = confidence
    }
}

/// The knowledge graph — stores entities and relations with temporal awareness.
actor KnowledgeGraph {
    
    static let shared = KnowledgeGraph()
    
    private var entities: [String: GraphEntity] = [:]
    private var relations: [GraphRelation] = []
    private var index: [String: [GraphEntity]] = [:]  // term → entities
    private var dateIndex: [String: [GraphEntity]] = [:]  // date string → entities
    
    // MARK: - Entity Management
    
    /// Add an entity to the graph.
    func addEntity(name: String, type: EntityType, properties: [String: Any] = [:]) {
        let id = UUID().uuidString
        let entity = GraphEntity(id: id, name: name, type: type, properties: properties)
        entities[id] = entity
        self.rebuildIndex()
    }
    
    /// Add a relation between two entities.
    func addRelation(from entityId: String, to targetId: String, type: RelationType, properties: [String: Any] = [:]) {
        guard entities[entityId] != nil, entities[targetId] != nil else {
            Log("KnowledgeGraph: ⚠️ relation failed — entity not found")
            return
        }
        let id = UUID().uuidString
        let relation = GraphRelation(id: id, from: entityId, to: targetId, type: type, properties: properties)
        relations.append(relation)
    }
    
    /// Query the graph — returns matching entities and relations.
    func queryEntities(query: String, filters: GraphQuery? = nil) -> GraphResult {
        let q = filters ?? GraphQuery(queryText: query)
        let queryTerms = self.tokenize(query)
        
        var matchingEntities: [GraphEntity] = []
        var matchingRelations: [GraphRelation] = []
        
        // Search by text
        for entity in entities.values where entity.name.lowercased().contains(query.lowercased()) {
            matchingEntities.append(entity)
        }
        
        // Search by type filter
        if let types = q.entityTypes {
            matchingEntities = matchingEntities.filter { types.contains($0.type) }
        }
        
        // Search by relation type
        if let relTypes = q.relationTypes {
            matchingRelations = relations.filter { relTypes.contains($0.type) }
        }
        
        // Search by date range
        if let range = q.dateRange, let start = range.start, let end = range.end {
            matchingEntities = matchingEntities.filter {
                $0.timestamp >= start && $0.timestamp <= end
            }
        }
        
        let confidence = matchingEntities.isEmpty ? 0.0 : 1.0
        
        return GraphResult(query: query, entities: matchingEntities, relations: matchingRelations, confidence: confidence)
    }
    
    // MARK: - Graph Export
    
    /// Get a snapshot of the entire graph — for export or visualization.
    func getGraphSnapshot() -> (entities: [GraphEntity], relations: [GraphRelation]) {
        (Array(entities.values), relations)
    }
    
    // MARK: - Vault Integration
    
    /// Build the graph from an existing vault — scans all markdown files.
    func buildFromVault(vaultRoot: URL) async {
        entities.removeAll()
        relations.removeAll()
        
        do {
            let paths = try FileManager.default.subpathsOfDirectory(atPath: vaultRoot.path)
            for path in paths where path.hasSuffix(".md") {
                let url = vaultRoot.appendingPathComponent(path)
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                
                // Extract entities from markdown
                let entityRegex = try NSRegularExpression(pattern: #"##\s+(\w.+)"#, options: [])
                let matches = entityRegex.matches(in: content, options: [], range: NSRange(content.startIndex..., in: content))
                
                for match in matches {
                    guard let range = Range(match.range, in: content) else { continue }
                    let name = String(content[range])
                    let entity = GraphEntity(
                        id: path,
                        name: name,
                        type: .document,
                        properties: ["path": path, "content": content.prefix(500)]
                    )
                    entities[path] = entity
                }
            }
            
            Log("KnowledgeGraph: built from vault — \(entities.count) entities, \(relations.count) relations")
        } catch {
            Log("KnowledgeGraph: ⚠️ failed to build from vault: \(error)")
        }
    }
    
    // MARK: - Cross-References
    
    /// Generate cross-references between entities — links across sources.
    func generateCrossReferences(entities: [GraphEntity]) -> [[GraphRelation]] {
        var crossRefs: [[GraphRelation]] = []
        
        for i in 0..<entities.count {
            for j in (i+1)..<entities.count {
                let entityA = entities[i]
                let entityB = entities[j]
                
                // Check for similarity
                let similarity = self.similarityBetween(entityA, entityB)
                
                if similarity > 0.5 {
                    let id = UUID().uuidString
                    let relation = GraphRelation(
                        id: id,
                        from: entityA.id,
                        to: entityB.id,
                        type: .relatedTo,
                        properties: ["similarity": similarity]
                    )
                    crossRefs.append([relation])
                }
            }
        }
        
        return crossRefs
    }
    
    // MARK: - Index Management
    
    /// Rebuild the text index — for faster searching.
    private func rebuildIndex() {
        index.removeAll()
        dateIndex.removeAll()
        
        for entity in entities.values {
            // Build term index
            let terms = self.tokenize(entity.name)
            for term in terms {
                if index[term] == nil { index[term] = [] }
                index[term]!.append(entity)
            }
            
            // Build date index
            let dateStr = ISO8601DateFormatter().string(from: entity.timestamp)
            if dateIndex[dateStr.prefix(10)] == nil { dateIndex[String(dateStr.prefix(10))] = [] }
            dateIndex[String(dateStr.prefix(10))]!.append(entity)
        }
    }
    
    /// Tokenize text into terms for indexing.
    private func tokenize(_ text: String) -> [String] {
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }
    
    /// Compute similarity between two entities — for cross-referencing.
    private func similarityBetween(_ a: GraphEntity, _ b: GraphEntity) -> Float {
        var score: Float = 0.0
        
        // Type match
        if a.type == b.type { score += 0.3 }
        
        // Name similarity
        let aTerms = Set(self.tokenize(a.name))
        let bTerms = Set(self.tokenize(b.name))
        let intersection = aTerms.intersection(bTerms)
        let union = aTerms.union(bTerms)
        if !union.isEmpty {
            score += Float(intersection.count) / Float(union.count) * 0.7
        }
        
        return min(score, 1.0)
    }
    
    // MARK: - Privacy Controls
    
    /// Apply privacy filters — redact sensitive information.
    func applyPrivacyFilter(entity: GraphEntity) -> GraphEntity {
        var filtered = entity
        var safeProperties: [String: Any] = [:]
        
        for (key, value) in entity.properties {
            switch key {
            case "email", "phone", "address", "password", "account":
                safeProperties[key] = "[REDACTED]"
            default:
                safeProperties[key] = value
            }
        }
        
        filtered.properties = safeProperties
        return filtered
    }
}

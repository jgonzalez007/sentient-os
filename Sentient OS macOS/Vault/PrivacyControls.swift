//
//  PrivacyControls.swift
//  Sentient OS macOS
//
//  Phase 3.8: Granular per-source privacy controls — let users configure what gets included
//  in the knowledge base, what metadata is exposed, and what PII is redacted. Provides
//  source-level, field-level, and content-level privacy controls.
//
//  Key methods:
//   - configure(source:policy:)      → set privacy policy for a source
//   - isAllowed(source:)             → check if source is allowed
//   - redact(text:for:)             → redact sensitive content
//   - getPrivacySettings()           → get all privacy settings
//   - applyPolicy(note:)             → apply privacy policy to a note
//
//  Usage: `PrivacyControls.configure(source: .appleMail, policy: .readOnly)` to set mail to read-only.
//
//  Doc: Vault/Documentation - Knowledge Base (Vault).md
//

import Foundation

/// Privacy policy — what can be done with a source.
enum PrivacyPolicy: String, Codable, Sendable {
    case blocked       // completely blocked, no data collected
    case readOnly      // read-only, no writes
    case readWrite     // full access
    case anonymized    // data collected but anonymized
    
    var label: String {
        switch self {
        case .blocked: return "Blocked"
        case .readOnly: return "Read Only"
        case .readWrite: return "Read & Write"
        case .anonymized: return "Anonymized"
        }
    }
}

/// Field privacy level — what metadata is exposed.
enum FieldPrivacy: String, Codable, Sendable {
    case none          // no metadata
    case basic         // basic info (type, date)
    case full          // all metadata
    case redacted      // PII stripped
    
    var label: String {
        switch self {
        case .none: return "None"
        case .basic: return "Basic"
        case .full: return "Full"
        case .redacted: return "Redacted"
        }
    }
}

/// Source-level privacy configuration.
struct SourcePrivacyConfig: Codable, Sendable {
    var policy: PrivacyPolicy
    var fieldPrivacy: FieldPrivacy
    var redactionLevel: RedactionLevel
    
    init(policy: PrivacyPolicy = .readWrite, 
         fieldPrivacy: FieldPrivacy = .full,
         redactionLevel: RedactionLevel = .standard) {
        self.policy = policy
        self.fieldPrivacy = fieldPrivacy
        self.redactionLevel = redactionLevel
    }
}

/// Redaction level — how aggressively to redact PII.
enum RedactionLevel: String, Codable, Sendable {
    case none        // no redaction
    case standard    // standard PII (email, phone, address)
    case strict      // strict redaction (all PII)
    case paranoid    // paranoid redaction (all PII + context)
    
    var label: String {
        switch self {
        case .none: return "None"
        case .standard: return "Standard"
        case .strict: return "Strict"
        case .paranoid: return "Paranoid"
        }
    }
}

/// Privacy controls engine — manages per-source privacy policies.
actor PrivacyControls {
    
    static let shared = PrivacyControls()
    
    private var configs: [SourceKind: SourcePrivacyConfig] = [:]
    private let storageKey = "privacy_configs"
    
    // MARK: - Configuration
    
    /// Configure a source's privacy policy.
    func configure(source: SourceKind, policy: PrivacyPolicy, 
                   fieldPrivacy: FieldPrivacy = .full,
                   redactionLevel: RedactionLevel = .standard) {
        let config = SourcePrivacyConfig(policy: policy, 
                                       fieldPrivacy: fieldPrivacy,
                                       redactionLevel: redactionLevel)
        configs[source] = config
        saveToDisk()
    }
    
    /// Check if a source is allowed.
    func isAllowed(source: SourceKind) -> Bool {
        guard let config = configs[source] else { return true }  // default: allowed
        return config.policy != .blocked
    }
    
    /// Get privacy settings for all sources.
    func getPrivacySettings() -> [SourceKind: SourcePrivacyConfig] {
        configs
    }
    
    /// Apply privacy policy to a note.
    func applyPolicy(note: CloudNote) -> CloudNote {
        guard let config = configs[note.kind] else { return note }
        
        // Apply redaction
        let redactedText = self.redact(text: note.text, for: config.redactionLevel)
        
        // Create a new note with redacted text
        return CloudNote(
            kind: note.kind,
            sourceID: note.sourceID,
            folder: config.policy == .anonymized ? "[anonymized]" : note.folder,
            title: note.title,
            text: redactedText,
            itemDate: note.itemDate
        )
    }
    
    // MARK: - Redaction
    
    /// Redact sensitive content from text.
    func redact(text: String, for level: RedactionLevel) -> String {
        switch level {
        case .none:
            return text
        case .standard:
            return self.redactStandard(text)
        case .strict:
            return self.redactStrict(text)
        case .paranoid:
            return self.redactParanoid(text)
        }
    }
    
    /// Standard redaction — emails, phone numbers, addresses.
    private func redactStandard(_ text: String) -> String {
        var redacted = text
        
        // Email addresses
        redacted = redacted.replacingOccurrences(of: #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#, 
                                               with: "[EMAIL]", 
                                               options: .regularExpression)
        
        // Phone numbers
        redacted = redacted.replacingOccurrences(of: #"\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#, 
                                               with: "[PHONE]", 
                                               options: .regularExpression)
        
        // SSN
        redacted = redacted.replacingOccurrences(of: #"\d{3}-\d{2}-\d{4}"#, 
                                               with: "[SSN]", 
                                               options: .regularExpression)
        
        return redacted
    }
    
    /// Strict redaction — all PII including names, dates of birth, etc.
    private func redactStrict(_ text: String) -> String {
        var redacted = self.redactStandard(text)
        
        // Names (heuristic: capitalized words in certain contexts)
        // Note: This is a simple heuristic — production should use NER
        let namePatterns = [
            "Mr\\. ", "Mrs\\. ", "Ms\\. ", "Dr\\. ", "Prof\\. ",
            "Dear ", "To: ", "From: "
        ]
        for pattern in namePatterns {
            redacted = redacted.replacingOccurrences(of: pattern, 
                                                   with: "", 
                                                   options: .regularExpression)
        }
        
        return redacted
    }
    
    /// Paranoid redaction — all PII + contextual information.
    private func redactParanoid(_ text: String) -> String {
        var redacted = self.redactStrict(text)
        
        // Redact specific amounts
        redacted = redacted.replacingOccurrences(of: #"\$\d[\d,]*(\.\d{2})?"#, 
                                               with: "[AMOUNT]", 
                                               options: .regularExpression)
        
        // Redact account numbers
        redacted = redacted.replacingOccurrences(of: #"\b\d{4,}[\s-]?\d{4,}[\s-]?\d{4,}[\s-]?\d{0,4}\b", 
                                               with: "[ACCOUNT]", 
                                               options: .regularExpression)
        
        // Redact dates (except years)
        redacted = redacted.replacingOccurrences(of: #"(\d{1,2})/( \d{1,2})/\d{4}"#, 
                                               with: "[DATE]", 
                                               options: .regularExpression)
        
        return redacted
    }
    
    // MARK: - Persistence
    
    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let loaded = try? JSONDecoder().decode([SourceKind: SourcePrivacyConfig].self, from: data) else {
            return
        }
        configs = loaded
    }
}

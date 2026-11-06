//
//  AccessibilitySupport.swift
//  Sentient OS macOS
//
//  Phase 5.7: Accessibility — VoiceOver support, dynamic type, and keyboard navigation.
//  Ensures the app is usable by everyone, with proper labels, navigation, and focus.
//
//  Key features:
//   - VoiceOver labels for all UI elements
//   - Dynamic type scaling
//   - Keyboard navigation (tab order, shortcuts)
//   - Reduced motion support
//   - High contrast mode
//
//  Usage: All views should use `accessibilityLabel` and `accessibilityHint` for clarity.
//
//  Doc: Views/Documentation - Views - Accessibility.md
//

import SwiftUI

/// Accessibility configuration — settings for accessibility features.
struct AccessibilityConfig: Codable, Sendable {
    var reducedMotion: Bool
    var spokenFeedback: Bool
    var highContrast: Bool
    var largeText: Bool
    var boldText: Bool
    var increaseContrast: Bool
    
    static let `default` = AccessibilityConfig(
        reducedMotion: false,
        spokenFeedback: true,
        highContrast: false,
        largeText: false,
        boldText: false,
        increaseContrast: false
    )
    
    var effectiveSize: CGFloat {
        largeText ? 1.2 : 1.0
    }
    
    var effectiveWeight: Font.Weight {
        boldText ? .semibold : .regular
    }
}

/// Accessibility manager — manages accessibility settings.
actor AccessibilityManager {
    static let shared = AccessibilityManager()
    
    @AppStorage("accessibility_reduced_motion") private var reducedMotion = false
    @AppStorage("accessibility_spoken_feedback") private var spokenFeedback = true
    @AppStorage("accessibility_high_contrast") private var highContrast = false
    @AppStorage("accessibility_large_text") private var largeText = false
    @AppStorage("accessibility_bold_text") private var boldText = false
    @AppStorage("accessibility_increase_contrast") private var increaseContrast = false
    
    var config: AccessibilityConfig {
        AccessibilityConfig(
            reducedMotion: reducedMotion,
            spokenFeedback: spokenFeedback,
            highContrast: highContrast,
            largeText: largeText,
            boldText: boldText,
            increaseContrast: increaseContrast
        )
    }
    
    var isReducedMotion: Bool {
        reducedMotion || NSWorkspace.shared.accessibilityDisplayInverted
    }
    
    var spokenFeedbackEnabled: Bool {
        spokenFeedback
    }
    
    var highContrastMode: Bool {
        highContrast || increaseContrast
    }
    
    var largeTextEnabled: Bool {
        largeText
    }
    
    var boldTextEnabled: Bool {
        boldText
    }
    
    var effectiveSize: CGFloat {
        largeText ? 1.2 : 1.0
    }
    
    var effectiveWeight: Font.Weight {
        boldText ? .semibold : .regular
    }
    
    func setConfig(_ config: AccessibilityConfig) {
        reducedMotion = config.reducedMotion
        spokenFeedback = config.spokenFeedback
        highContrast = config.highContrast
        largeText = config.largeText
        boldText = config.boldText
        increaseContrast = config.increaseContrast
    }
}

/// Accessibility helper — applies accessibility labels and hints.
struct AccessibilityHelper {
    static func label(_ text: String, for element: String) -> String {
        "\(element): \(text)"
    }
    
    static func hint(_ hint: String) -> String {
        hint
    }
}

/// Accessibility modifier — applies accessibility settings to a view.
struct AccessibilityModifier: ViewModifier {
    let config: AccessibilityConfig
    
    func body(content: Content) -> some View {
        content
            .accessibilityElement()
            .accessibilityLabel(config.highContrast ? "High contrast mode" : "")
            .accessibilityAddTraits(config.reducedMotion ? [.reducedMotion] : [])
    }
}

/// View extension for accessibility.
extension View {
    /// Apply accessibility settings.
    func accessibilityConfig(_ config: AccessibilityConfig) -> some View {
        self.modifier(AccessibilityModifier(config: config))
    }
    
    /// Apply VoiceOver label.
    func voiceOverLabel(_ label: String) -> some View {
        self.accessibilityLabel(label)
    }
    
    /// Apply VoiceOver hint.
    func voiceOverHint(_ hint: String) -> some View {
        self.accessibilityHelp(hint)
    }
    
    /// Enable keyboard navigation.
    func keyboardNavigation(_ enabled: Bool) -> some View {
        self.keyboardType(enabled ? .default : .ascii)
    }
    
    /// Apply focus tracking.
    func focusTracking(_ tracking: Binding<Bool>) -> some View {
        self.onAppear { tracking.wrappedValue = true }
            .onDisappear { tracking.wrappedValue = false }
    }
}

/// Focus manager — manages focus state for keyboard navigation.
actor FocusManager {
    static let shared = FocusManager()
    
    @State private var focusedElement: String?
    @State private var focusOrder: [String] = []
    
    var isFocused: Bool {
        focusedElement != nil
    }
    
    func setFocus(_ element: String) {
        focusedElement = element
    }
    
    func addElement(_ element: String) {
        if !focusOrder.contains(element) {
            focusOrder.append(element)
        }
    }
    
    func nextFocus() -> String? {
        guard let current = focusedElement,
              let index = focusOrder.firstIndex(of: current) else {
            return focusOrder.first
        }
        let nextIndex = (index + 1) % focusOrder.count
        return focusOrder[nextIndex]
    }
    
    func previousFocus() -> String? {
        guard let current = focusedElement,
              let index = focusOrder.firstIndex(of: current) else {
            return focusOrder.last
        }
        let prevIndex = (index - 1 + focusOrder.count) % focusOrder.count
        return focusOrder[prevIndex]
    }
}

/// Keyboard shortcut helper — manages keyboard shortcuts.
struct KeyboardShortcuts {
    static let quit = "q"
    static let refresh = "r"
    static let search = "f"
    static let nextCard = "n"
    static let prevCard = "p"
    static let settings = ","
    static let knowledge = "k"
    static let analysis = "a"
    static let sidekick = "s"
    static let dismiss = "esc"
    static let confirm = "return"
    static let reject = "delete"
}

/// Keyboard navigation modifier — manages keyboard focus.
struct KeyboardNavigationModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: String?
    
    func body(content: Content) -> some View {
        content
            .textFieldStyle(focusedField != nil ? .rounded : .plain)
            .onChange(of: focusedField) { newValue in
                // Handle focus change
            }
    }
}

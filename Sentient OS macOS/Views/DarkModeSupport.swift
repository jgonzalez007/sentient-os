//
//  DarkModeSupport.swift
//  Sentient OS macOS
//
//  Phase 5.6: Dark mode support — removes the hardcoded `preferredColorScheme(.dark)` and
//  enables system light/dark mode switching. Provides a toggle in Settings for forcing
//  a specific mode.
//
//  Key features:
//   - System-aware theme (follows macOS setting)
//   - Forced light/dark mode toggle
//   - Adaptive colors for light backgrounds
//   - Accessibility support for reduced contrast
//
//  Usage: The app will automatically follow the system theme. Users can override in Settings.
//
//  Doc: Views/Documentation - Views - Home, Processing & Shared UI.md
//

import SwiftUI

/// Theme mode — light, dark, or system.
enum ThemeMode: String, Codable, Sendable, CaseIterable {
    case system    // follow macOS
    case dark      // force dark
    case light     // force light
    
    var localized: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

/// Adaptive theme — changes colors based on light/dark mode.
struct AdaptiveTheme {
    static var isDarkMode: Bool {
        #if os(macOS)
        return NSApplication.shared.effectiveAppearance?.matchingPolicy() == .prefersDark
        #else
        return false
        #endif
    }
    
    // Background colors
    static var background: Color {
        isDarkMode ? Color.black : Color(NSColor.white)
    }
    
    static var panel: Color {
        isDarkMode ? Color(red: 0.053, green: 0.058, blue: 0.072) : Color(red: 0.95, green: 0.95, blue: 0.97)
    }
    
    static var elevated: Color {
        isDarkMode ? Color.white.opacity(0.05) : Color.black.opacity(0.05)
    }
    
    static var stroke: Color {
        isDarkMode ? Color.white.opacity(0.09) : Color.black.opacity(0.09)
    }
    
    // Text colors
    static var primary: Color {
        isDarkMode ? Color.white : Color.black
    }
    
    static var secondary: Color {
        isDarkMode ? Color.white.opacity(0.55) : Color.black.opacity(0.55)
    }
    
    static var faint: Color {
        isDarkMode ? Color.white.opacity(0.32) : Color.black.opacity(0.32)
    }
    
    // Accent colors
    static var accent: Color {
        isDarkMode ? Color(red: 0.62, green: 0.55, blue: 1.0) : Color(red: 0.4, green: 0.3, blue: 0.9)
    }
    
    static var knowledgeAccent: Color {
        isDarkMode ? Color(red: 0.557, green: 0.651, blue: 1.0) : Color(red: 0.3, green: 0.2, blue: 0.8)
    }
    
    // Verdict colors
    static func verdictColor(_ verdict: Verdict) -> Color {
        switch verdict {
        case .survivor:
            return Color(red: 0.290, green: 0.871, blue: 0.502)
        case .junk:
            return Color.gray.opacity(0.5)
        case .sensitive:
            return Color(red: 1.0, green: 0.3, blue: 0.3)
        }
    }
}

/// Theme manager — manages theme settings and mode.
actor ThemeManager {
    static let shared = ThemeManager()
    
    @AppStorage("theme_mode") private var themeModeRaw = ThemeMode.system.rawValue
    @AppStorage("forced_theme") private var forcedMode: Bool?
    
    var mode: ThemeMode {
        get { ThemeMode(rawValue: themeModeRaw) ?? .system }
        set { themeModeRaw = newValue.rawValue }
    }
    
    var isForcedDark: Bool {
        forcedMode == true
    }
    
    var isForcedLight: Bool {
        forcedMode == false
    }
    
    func setMode(_ mode: ThemeMode) {
        self.mode = mode
    }
    
    func setForcedDark(_ forced: Bool) {
        forcedMode = forced
    }
    
    var effectiveMode: ThemeMode {
        if let forced = forcedMode {
            return forced ? .dark : .light
        }
        return mode
    }
    
    var isDark: Bool {
        let effective = effectiveMode
        if effective == .dark { return true }
        if effective == .light { return false }
        // System mode — follow macOS
        return AdaptiveTheme.isDarkMode
    }
}

/// View extension for theme-aware styling.
extension View {
    /// Apply theme-aware styling.
    func themed(_ style: ThemeStyle) -> some View {
        self.foregroundStyle(style.primary)
            .background(style.background)
    }
}

/// Theme style — colors for a themed view.
struct ThemeStyle {
    let background: Color
    let primary: Color
    let secondary: Color
    let accent: Color
    
    static var dark: ThemeStyle {
        ThemeStyle(
            background: .black,
            primary: .white,
            secondary: .white.opacity(0.55),
            accent: .init(red: 0.62, green: 0.55, blue: 1.0)
        )
    }
    
    static var light: ThemeStyle {
        ThemeStyle(
            background: .white,
            primary: .black,
            secondary: .black.opacity(0.55),
            accent: .init(red: 0.4, green: 0.3, blue: 0.9)
        )
    }
}

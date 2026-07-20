import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.0, green: 0.45, blue: 0.58)
    static let accentSoft = accent.opacity(0.12)
    static let accentSubtle = accent.opacity(0.08)
    static let accentStroke = accent.opacity(0.35)

    static let success = Color(red: 0.12, green: 0.54, blue: 0.34)
    static let warning = Color.orange
    static let destructive = Color.red
    static let neutralFill = Color.gray.opacity(0.12)
    static let neutralStroke = Color.secondary.opacity(0.25)
}

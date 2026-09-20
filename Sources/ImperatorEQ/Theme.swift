import SwiftUI

enum AppColors {
    static let brand = Color(red: 0xa0 / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0)
    static let brandFaded = brand.opacity(0.25)
    static let accent = Color(red: 0.43, green: 0.05, blue: 0.05)
    static let badgeRed = Color(red: 0xD9 / 255.0, green: 0x33 / 255.0, blue: 0x33 / 255.0)
    static let error = Color(red: 0.9, green: 0.3, blue: 0.3)
    /// Brandbook 2.4: the popover content background overlay.
    static let popoverBackground = Color.black.opacity(0.15)

    static let gradientColors: [Color] = [brand, brandFaded]
}

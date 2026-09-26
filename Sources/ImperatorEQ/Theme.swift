import SwiftUI

enum AppColors {
    static let brand = Color(red: 0xa0 / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0)
    static let brandFaded = brand.opacity(0.25)
    /// Brandbook 2.4: the popover content background overlay.
    static let popoverBackground = Color.black.opacity(0.15)

    static let gradientColors: [Color] = [brand, brandFaded]
}

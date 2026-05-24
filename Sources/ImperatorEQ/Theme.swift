import SwiftUI

enum Theme {
    static let brand = Color(red: 0xA0 / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0)
    static let brandFaded = brand.opacity(0.25)

    static let gradientColors: [Color] = [brand, brandFaded]
}

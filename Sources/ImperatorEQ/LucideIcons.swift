import AppKit

/// Three icons from Lucide (https://lucide.dev), Plus, Check and Rotate CCW, kept as the
/// SVG they ship as and drawn by AppKit, which reads SVG data into a vector
/// image. Template images, so they take the colour of the text next to them.
///
/// Lucide is under the ISC License, Copyright (c) 2026 Lucide Icons and
/// Contributors, and Plus and Check are among its icons derived from Feather, also
/// under the MIT License, Copyright (c) 2013-present Cole Bemis. Both notices are in
/// Resources/ThirdPartyNotices.txt, which build.sh copies into the app bundle.
enum LucideIcons {
    static let plus = make("""
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" \
        stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\
        <path d="M5 12h14"/><path d="M12 5v14"/></svg>
        """)

    static let check = make("""
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" \
        stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\
        <path d="M20 6 9 17l-5-5"/></svg>
        """)

    static let rotateCCW = make("""
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" \
        stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\
        <path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/></svg>
        """)

    private static func make(_ svg: String) -> NSImage {
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }
}

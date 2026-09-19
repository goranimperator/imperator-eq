import AppKit

/// The app's glyph, used by the menu bar item and by the popover header.
///
/// Brandbook 16.1 keeps the sigil out of the header: the header carries the
/// app's own icon. Sharing one source between the two means the glyph in the
/// menu bar and the glyph above the popover cannot drift apart, which is what
/// happened while the header drew the `waveform` SF Symbol and the status item
/// drew this.
///
/// Lucide's `audio-lines` on a 24-unit viewBox, stroked as a template image so
/// AppKit tints it for the menu bar and for the header's foreground style.
enum StatusItemIcon {
    private static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 10v3"/><path d="M6 6v11"/><path d="M10 3v18"/><path d="M14 8v7"/><path d="M18 5v13"/><path d="M22 10v3"/></svg>
    """

    /// Brandbook 8.1: 18 x 18pt, template, in a `.squareLength` status item.
    /// The header asks for 16 so the glyph sits with the headline rather than
    /// over it.
    static func make(size: CGFloat = 18) -> NSImage {
        guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else {
            return NSImage()
        }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        return image
    }
}

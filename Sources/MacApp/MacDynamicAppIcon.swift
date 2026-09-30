@MainActor
enum MacDynamicAppIcon {
    /// macOS supplies the correct Dock/Finder mask for the compiled AppIcon asset.
    /// Assigning a raw square `NSImage` here bypasses that treatment and leaves a
    /// square tile inside the system icon shape. Keep the OS-owned app icon intact.
    static func synchronize(theme: String, highlight: String) {
        _ = theme
        _ = highlight
    }
}

import AppKit

/// Process-wide cache for Finder file icons.
///
/// `NSWorkspace.shared.icon(forFile:)` is a Launch Services lookup that isn't
/// free, and the file/orphan/Space Lens row views call it directly in `body`
/// — so it re-runs on every re-render of every visible row (selection toggle,
/// scroll, hover). Caching by extension collapses that to one lookup per file
/// type: rows in the same list overwhelmingly share extensions, and the icon
/// for a given type is identical, so a per-path cache would just waste memory.
enum FileIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    /// Icon for the file at `path`, cached by its lowercased extension. Files
    /// with no extension (typical for cache folders and dot-directories) fall
    /// back to a per-path lookup so bundles/folders still get their real icon.
    static func icon(forPath path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? ("path:" + path) as NSString : ("ext:" + ext) as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }
}

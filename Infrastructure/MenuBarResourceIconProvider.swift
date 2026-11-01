import AppKit

/// Best-effort resource discovery for any owner; never substitutes its Dock icon.
@MainActor
final class MenuBarResourceIconProvider {
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func invalidate() { images.removeAll(); missing.removeAll() }

    func image(bundleID: String, bundleURL: URL) -> NSImage? {
        guard bundleURL.isFileURL, let bundle = Bundle(url: bundleURL), bundle.bundleIdentifier == bundleID else { return nil }
        let key = bundleURL.path + "|" + bundleID
        if let image = images[key] { return image.copy() as? NSImage }
        if missing.contains(key) { return nil }
        if images.count + missing.count >= 128 { invalidate() }
        for name in Self.conventionalNames(bundle: bundle) {
            if let source = bundle.image(forResource: NSImage.Name(name)), let image = validated(source, name: name) {
                images[key] = image
                return image.copy() as? NSImage
            }
        }
        if let url = discoverFile(in: bundle), let source = NSImage(contentsOf: url),
           let image = validated(source, name: url.deletingPathExtension().lastPathComponent) {
            images[key] = image
            return image.copy() as? NSImage
        }
        missing.insert(key)
        return nil
    }

    private static func conventionalNames(bundle: Bundle) -> [String] {
        var names = ["StatusIcon", "StatusItemIcon", "statusItemIcon", "statusItemIcon-0", "MenuBarIcon", "MenuIcon", "TrayIcon", "trayIcon", "trayTemplate", "TrayTemplate"]
        let stems = [bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                     bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                     bundle.bundleIdentifier?.split(separator: ".").last.map(String.init)]
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_."))
        for stem in stems.compactMap({ $0 }) where stem.utf8.count <= 128 && !stem.contains("..") && stem.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            for suffix in ["Status", "StatusIcon", "MenuBarIcon", "TrayIcon"] { names.append(stem + suffix) }
        }
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    private func discoverFile(in bundle: Bundle) -> URL? {
        guard let root = bundle.resourceURL?.resolvingSymlinksInPath(),
              let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(75))
        let names = Set(Self.conventionalNames(bundle: bundle).map { $0.lowercased() })
        var choices: [(URL, Int)] = []
        for case let url as URL in enumerator {
            guard enumerator.level <= 8 else { enumerator.skipDescendants(); continue }
            guard ContinuousClock.now < deadline, choices.count < 32 else { break }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            let name = url.lastPathComponent.lowercased()
            if values.isDirectory == true {
                if ["node_modules", "linux", "win32", "extensions", "locales"].contains(name) || name.hasSuffix(".lproj") { enumerator.skipDescendants() }
                continue
            }
            guard ["png", "pdf", "tiff"].contains(url.pathExtension.lowercased()),
                  (values.fileSize ?? Int.max) <= 262_144,
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
            var stem = url.deletingPathExtension().lastPathComponent.lowercased()
            stem = stem.replacingOccurrences(of: "@2x", with: "").replacingOccurrences(of: "@3x", with: "")
            let components = url.pathComponents.map { $0.lowercased() }
            guard !components.contains("linux"), !components.contains("win32") else { continue }
            if names.contains(stem) { choices.append((url, 0)) }
            else if ["menubaricon", "trayicon", "statusitemicon", "traytemplate"].contains(where: { stem.contains($0) }) {
                guard !["notify", "notification", "unread", "attention", "update", "disabled", "connected", "sync"].contains(where: { stem.contains($0) }) else { continue }
                choices.append((url, 1))
            }
        }
        guard let best = choices.map(\.1).min() else { return nil }
        let preferred = choices.filter { $0.1 == best }
        // Resolution variants of one resource are acceptable; different equally likely resources are ambiguous.
        let groups = Dictionary(grouping: preferred) { entry in
            entry.0.deletingPathExtension().path.replacingOccurrences(of: "@2x", with: "").replacingOccurrences(of: "@3x", with: "")
        }
        if groups.count > 1 {
            // Electron bundles can ship the same tray asset in multiple directories.
            let originals = groups.values.compactMap { $0.sorted { $0.0.path < $1.0.path }.first?.0 }
            guard let first = originals.first, let data = try? Data(contentsOf: first),
                  originals.dropFirst().allSatisfy({ (try? Data(contentsOf: $0)) == data }) else { return nil }
        }
        return preferred.sorted { $0.0.path < $1.0.path }.first?.0
    }

    private func validated(_ source: NSImage, name: String) -> NSImage? {
        guard source.size.width.isFinite, source.size.height.isFinite,
              source.size.width > 0, source.size.width <= 128,
              source.size.height > 0, source.size.height <= 64,
              source.representations.allSatisfy({ $0.pixelsWide <= 512 && $0.pixelsHigh <= 256 }),
              let image = source.copy() as? NSImage else { return nil }
        image.isTemplate = source.isTemplate || name.lowercased().contains("template") || isMonochrome(image)
        return image
    }

    private func isMonochrome(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cgImage.width <= 512, cgImage.height <= 256 else { return false }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.01 else { continue }
                if abs(color.redComponent - color.greenComponent) > 0.02 || abs(color.greenComponent - color.blueComponent) > 0.02 { return false }
            }
        }
        return true
    }
}

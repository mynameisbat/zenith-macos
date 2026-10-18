import Foundation

/// User audio feedback customization choice for semantic acoustic events across Zenith.
public enum SoundChoice: Codable, Sendable, Equatable, Hashable {
    case system(name: String)
    case custom(relativePath: String, displayName: String)
    case muted

    /// The 14 standard macOS system sounds located in `/System/Library/Sounds/`.
    public static let standardSystemSounds: [String] = [
        "Pop", "Tink", "Hero", "Bottle", "Funk", "Ping", "Purr",
        "Submarine", "Basso", "Blow", "Frog", "Glass", "Morse", "Sosumi"
    ]

    /// Directory URL where custom sounds are stored: `~/Library/Application Support/Zenith/Sounds/`.
    public static var customSoundsDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Zenith/Sounds", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// User-facing label for UI pickers.
    public var displayName: String {
        switch self {
        case .system(let name):
            return name
        case .custom(_, let displayName):
            return displayName
        case .muted:
            return "Muted"
        }
    }

    /// Discovers all supported audio files imported in `~/Library/Application Support/Zenith/Sounds/`.
    public static func availableCustomSounds() -> [SoundChoice] {
        let dir = customSoundsDirectoryURL
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let audioExtensions: Set<String> = ["wav", "aiff", "aif", "m4a", "mp3"]
        var results: [SoundChoice] = []
        for file in files.sorted() {
            guard !file.hasPrefix(".") else { continue }
            let ext = (file as NSString).pathExtension.lowercased()
            if audioExtensions.contains(ext) {
                let displayName = (file as NSString).deletingPathExtension
                results.append(.custom(relativePath: file, displayName: displayName))
            }
        }
        return results
    }

    /// Default mapping of semantic sound effects to system sound choices.
    public static var defaultAssignments: [String: SoundChoice] {
        var dict: [String: SoundChoice] = [:]
        for effect in SoundEffect.allCases {
            dict[effect.rawValue] = .system(name: effect.standardSoundName)
        }
        return dict
    }
}

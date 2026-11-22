import Foundation

/// The island shows a notice as one bold line (and an optional smaller one) in a 280 pt capsule, so a long sentence was
/// cut off ("Cleaning Mode off. The keyboard…"). A long message without a subtitle is split after its first sentence
/// or label: the rest becomes the subtitle.
public enum IslandNoticeText {
    /// About what fits on the capsule's bold line.
    public static let titleLimit = 34

    public static func split(title: String, subtitle: String?) -> (title: String, subtitle: String?) {
        guard subtitle?.isEmpty ?? true, title.count > titleLimit else { return (title, subtitle) }
        for separator in [". ", ": ", "。", "：", ", "] {
            guard let range = title.range(of: separator) else { continue }
            var head = String(title[..<range.lowerBound])
            let tail = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty, !tail.isEmpty, head.count <= titleLimit else { continue }
            if separator == "。" { head += "。" }
            return (head, tail)
        }
        return (title, subtitle)
    }
}

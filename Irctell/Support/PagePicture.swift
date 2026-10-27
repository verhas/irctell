import Foundation

/// The picture a web page is about, guessed from its HTML: what it names
/// for link previews first (Open Graph, Twitter cards), then the large
/// pictures in it -- logos, icons, avatars and tracking pixels left out.
enum PagePicture {
    /// A picture on the page, and how likely it is the one meant.
    struct Candidate: Equatable {
        var url: URL
        var score: Int
    }

    /// At most this much of a page is read: what names its picture is in
    /// its head, or near the top.
    static let pageLimit = 2 << 20
    /// A picture smaller than this on either side is taken only when no
    /// larger one is found.
    static let minimumSide = 100
    /// In the log, for a page found to have no picture, so the history's
    /// download does not read it again.
    static let noPictureMarker = "text/html; no picture"

    /// The pictures on the page, the likeliest first.
    static func candidates(in html: String, base: URL) -> [Candidate] {
        var base = base
        var found: [String: Candidate] = [:]
        var pictures = 0

        func add(_ link: String?, _ score: Int) {
            guard let link = link.map(decode)?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty,
                  let url = URL(string: link, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  !url.path.lowercased().hasSuffix(".svg") else { return }
            let key = url.absoluteString
            if var known = found[key] {
                // Named for previews and also shown on the page: surely it.
                known.score = max(known.score, score) + 10
                found[key] = known
            } else {
                found[key] = Candidate(url: url, score: score)
            }
        }

        for tag in tags(in: html) {
            let attributes = tag.attributes
            switch tag.name {
            case "base":
                if let href = attributes["href"].map(decode), let url = URL(string: href, relativeTo: base) {
                    base = url.absoluteURL
                }
            case "meta":
                let name = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"] ?? "").lowercased()
                let score: Int? = switch name {
                case "og:image", "og:image:url", "og:image:secure_url": 100
                case "twitter:image", "twitter:image:src": 90
                case "image", "thumbnailurl": 70
                default: nil
                }
                guard let score, let content = attributes["content"] else { continue }
                // A site's own share picture -- its logo -- rather than the page's.
                add(content, looksLikeDecoration(content) ? score - 60 : score)
            case "link":
                let rel = attributes["rel"]?.lowercased() ?? ""
                if rel.split(separator: " ").contains("image_src") { add(attributes["href"], 80) }
            case "img", "source":
                let link = largest(in: attributes["srcset"] ?? attributes["data-srcset"])
                    ?? attributes["data-src"] ?? attributes["data-original"] ?? attributes["data-lazy-src"]
                    ?? attributes["src"]
                guard let link, !link.hasPrefix("data:"), !looksLikeDecoration(link) else { continue }
                let width = attributes["width"].flatMap { Int($0.filter(\.isNumber)) }
                let height = attributes["height"].flatMap { Int($0.filter(\.isNumber)) }
                let smaller = [width, height].compactMap { $0 }.min()
                if let smaller, smaller < minimumSide { continue }
                var score = 20
                if let smaller { score += smaller >= 300 ? 40 : 20 }
                // Of pictures alike, the first on the page is the likelier.
                score += max(0, 10 - pictures)
                pictures += 1
                add(link, score)
            default:
                continue
            }
        }
        return found.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.url.absoluteString < $1.url.absoluteString }
    }

    /// Names that pictures of a page's furniture have, not of its content.
    private static let decorationWords = [
        "logo", "icon", "favicon", "sprite", "avatar", "badge", "emoji", "spinner", "loading", "placeholder",
        "pixel", "spacer", "blank", "tracking", "1x1", "default-share", "share-default",
    ]

    static func looksLikeDecoration(_ link: String) -> Bool {
        let path = (URL(string: link)?.path ?? link).lowercased()
        return decorationWords.contains { path.contains($0) }
    }

    /// The widest picture of a `srcset`: "a.jpg 480w, b.jpg 1080w" or "a.jpg 1x, b.jpg 2x".
    static func largest(in srcset: String?) -> String? {
        guard let srcset, !srcset.isEmpty else { return nil }
        let choices = srcset.split(separator: ",").compactMap { entry -> (String, Double)? in
            let parts = entry.split(whereSeparator: \.isWhitespace)
            guard let link = parts.first else { return nil }
            let size = parts.dropFirst().first.flatMap { Double($0.dropLast()) } ?? 1
            return (String(link), size)
        }
        return choices.max { $0.1 < $1.1 }?.0
    }

    // MARK: - Reading tags

    struct Tag {
        var name: String
        var attributes: [String: String]
    }

    private static let tagPattern =
        try! NSRegularExpression(pattern: "<(meta|link|img|source|base)\\b([^>]*)>", options: [.caseInsensitive])
    private static let attributePattern = try! NSRegularExpression(
        pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))")

    /// The tags that may name a picture, with their attributes, names lowercased.
    static func tags(in html: String) -> [Tag] {
        let text = html as NSString
        return tagPattern.matches(in: html, range: NSRange(location: 0, length: text.length)).map { match in
            let inside = text.substring(with: match.range(at: 2)) as NSString
            var attributes: [String: String] = [:]
            for attribute in attributePattern.matches(in: inside as String, range: NSRange(location: 0, length: inside.length)) {
                let name = inside.substring(with: attribute.range(at: 1)).lowercased()
                let value = (2...4).lazy.map { attribute.range(at: $0) }.first { $0.location != NSNotFound }
                    .map { inside.substring(with: $0) } ?? ""
                if attributes[name] == nil { attributes[name] = value }
            }
            return Tag(name: text.substring(with: match.range(at: 1)).lowercased(), attributes: attributes)
        }
    }

    /// The character references links have in HTML: `&amp;` and the like.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&#x2F;", "/"), ("&#x2f;", "/"), ("&#47;", "/")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

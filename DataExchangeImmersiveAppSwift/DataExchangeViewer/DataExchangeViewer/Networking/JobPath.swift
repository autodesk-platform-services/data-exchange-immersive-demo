//
//  JobPath.swift
//  DataExchangeViewer
//

import Foundation

/// The path that addresses a conversion job on the service: `{collectionId}/{exchangeUrn}`, each
/// half escaped where a character is not legal in a path segment.
///
/// The escaping lives here because the obvious ways to do it are both wrong.
/// `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)` leaves `/` alone — it is a path
/// character, just not one a single segment may contain — and `appendingPathComponent` escapes
/// whatever it is handed, so it cannot be pointed at a string that is already escaped.
enum JobPath {
    /// The characters a path segment may contain, per RFC 3986: unreserved, sub-delims, `:` and
    /// `@`. `:` matters — every exchange URN has two, and leaving them alone is what keeps a URN
    /// readable in a URL. `/`, `?` and `#` are excluded because each would end the segment rather
    /// than sit inside it — the service decodes them back — and `%` so that an escape introduced
    /// here is the only kind in the result.
    private static let segmentAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return allowed
    }()

    static func of(collectionId: String, exchangeUrn: String) -> String {
        "\(escaped(collectionId))/\(escaped(exchangeUrn))"
    }

    /// One escaped path segment. Also used for artifact file names, which are derived from the
    /// exchange's contents and so carry no guarantee of being URL-safe.
    static func escaped(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }
}

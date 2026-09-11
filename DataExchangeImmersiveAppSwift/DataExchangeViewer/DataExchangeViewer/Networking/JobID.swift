//
//  JobID.swift
//  DataExchangeViewer
//

import Foundation

/// The conversion service addresses a job by one path segment: the base64url encoding of
/// `"{collectionId}|{exchangeUrn}"`.
///
/// The encoding is why this exists as its own type. An exchange URN is made of characters that are
/// reserved in a URL path — `:` always, and `/`, `+` and `=` in the base64 tail of a version URN —
/// so putting one in a path meant percent-encoding it by hand, and `appendingPathComponent` would
/// then double-encode the result. base64url output is drawn from `A–Z a–z 0–9 - _`, all of which
/// are safe in a path segment, so building the URL is now plain concatenation.
enum JobID {
    /// Separates the two halves inside the encoded payload. Neither an ACC collection ID
    /// (`b.<uuid>`) nor a Data Exchange URN can contain it, so the split back is unambiguous.
    private static let separator: Character = "|"

    static func encode(collectionId: String, exchangeUrn: String) -> String {
        Data("\(collectionId)\(separator)\(exchangeUrn)".utf8)
            .base64EncodedString()
            // base64url per RFC 4648 §5.
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The inverse of `encode`, or nil when the text is not a job ID. The app never needs to
    /// decode one — the service does — but a round trip is how `ConversionEndpointTests` checks
    /// that what the app sends is what the service will read back.
    static func decode(_ jobId: String) -> (collectionId: String, exchangeUrn: String)? {
        var base64 = jobId
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Base64 decodes in blocks of four characters, so the padding `encode` stripped has to go
        // back on. A remainder of one is not a length any base64 text can have.
        switch base64.count % 4 {
        case 0: break
        case 2: base64 += "=="
        case 3: base64 += "="
        default: return nil
        }

        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8),
              let separatorIndex = decoded.firstIndex(of: separator) else {
            return nil
        }
        let collectionId = String(decoded[decoded.startIndex..<separatorIndex])
        let exchangeUrn = String(decoded[decoded.index(after: separatorIndex)...])
        // Both halves are required: a job identifies one exchange within one collection.
        guard !collectionId.isEmpty, !exchangeUrn.isEmpty else { return nil }
        return (collectionId, exchangeUrn)
    }
}

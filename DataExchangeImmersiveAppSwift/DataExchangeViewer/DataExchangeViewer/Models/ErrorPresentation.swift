//
//  ErrorPresentation.swift
//  DataExchangeViewer
//

import Foundation

extension Error {
    /// The message to put in front of a person. `localizedDescription` returns only
    /// `errorDescription`, so the `recoverySuggestion` written alongside it — the half that says
    /// what to do next — never reaches the UI on its own. Errors that aren't `LocalizedError`
    /// (`URLError`, `DecodingError`) still fall back to Foundation's description, so this is safe
    /// to use on anything caught from a `do` block.
    var userFacingDescription: String {
        guard let suggestion = (self as? LocalizedError)?.recoverySuggestion else {
            return localizedDescription
        }
        return "\(localizedDescription) \(suggestion)"
    }

    /// True when a service rejected an access token the app believed was still valid. Those
    /// failures repeat on every subsequent request, so they're worth clearing the session for
    /// instead of reporting the same message from each screen independently.
    var indicatesExpiredSession: Bool {
        if let conversion = self as? ConversionError, case .unauthorized = conversion {
            return true
        }
        if let graphQL = self as? GraphQLError, case .http(401, _) = graphQL {
            return true
        }
        return false
    }
}

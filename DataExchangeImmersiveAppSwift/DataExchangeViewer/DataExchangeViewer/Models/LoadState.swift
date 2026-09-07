//
//  LoadState.swift
//  DataExchangeViewer
//

import Foundation

/// The lifecycle of an asynchronously loaded collection.
///
/// Views that tracked this with a separate array, `isLoading` flag, and error string could
/// represent "empty because nothing loaded yet" and "empty because there genuinely is nothing"
/// identically — which is how the sidebar came to claim "No hubs found" while the request was
/// still in flight. Making `.loading` a distinct case means a view can only render a
/// "not found" message from `.loaded`, where it's actually true.
enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    /// The loaded value, or `nil` while loading or after a failure. Lets callers keep deriving
    /// filtered/sorted views of the data without switching over the whole state.
    var value: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}

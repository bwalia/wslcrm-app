import Foundation

/// The loading lifecycle of a screen's primary content.
enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(APIError)

    var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    var error: APIError? {
        if case .failed(let e) = self { return e }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

extension Error {
    /// Normalises any thrown error into `APIError` for display.
    var asAPIError: APIError {
        if let api = self as? APIError { return api }
        if let url = self as? URLError { return APIError.from(urlError: url) }
        if self is CancellationError { return .cancelled }
        return .server(ServerError(status: 0, message: localizedDescription, fieldErrors: [:], rawBody: ""))
    }
}

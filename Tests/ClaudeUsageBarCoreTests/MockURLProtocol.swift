import Foundation

/// Intercepts every request made through a `URLSession` configured with this
/// protocol class, so relay-client tests never touch the network.
///
/// Handlers are stored in a lock-guarded dictionary keyed by the request's
/// `scheme://host:port` rather than a single global variable. Swift Testing
/// may schedule separate `@Suite` types concurrently with each other even
/// when each is individually `.serialized` (serialization only orders tests
/// *within* a suite); keying by the test's own `RelayConfig.baseURL` lets
/// suites that use distinct base URLs run in parallel without clobbering one
/// another's handler.
final class MockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    // Guarded by `lock` on every read/write, so accesses are safe despite not
    // being isolated to an actor.
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    /// Registers `handler` for every request whose URL shares `baseURL`'s
    /// scheme, host, and port. Overwrites any handler previously registered
    /// for the same base URL.
    static func setHandler(for baseURL: URL, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[key(for: baseURL)] = handler
    }

    private static func key(for url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? "")\((url.port.map { ":\($0)" }) ?? "")"
    }

    private static func handler(for url: URL) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[key(for: url)]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let handler = Self.handler(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let body = Self.bodyData(from: request)
            let (response, data) = try handler(request, body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

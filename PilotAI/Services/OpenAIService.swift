import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class OpenAIService {
    public static let shared = OpenAIService()
    private let configuration: URLSessionConfiguration

    /// Configuration injection also permits deterministic URLProtocol transport tests.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.configuration.httpCookieStorage = nil
        self.configuration.httpShouldSetCookies = false
        self.configuration.urlCredentialStorage = nil
        self.configuration.urlCache = nil
        self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration.timeoutIntervalForRequest = 120
        self.configuration.timeoutIntervalForResource = 600
    }

    /// Existing callers remain source compatible. An explicit search switch can restrict the provider default per run.
    public func streamChat(
        provider: ModelProvider,
        modelId: String,
        messages: [Message],
        systemPrompt: String? = nil,
        tools: [[String: Any]]? = nil,
        hostedWebSearchEnabled: Bool? = nil
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let request = try ProviderRequestBuilder.request(provider: provider, modelId: modelId, messages: messages,
                                                                     systemPrompt: systemPrompt, tools: tools,
                                                                     hostedWebSearchEnabled: hostedWebSearchEnabled)
                    let transport = ProviderHTTPStream(configuration: self.configuration)
                    defer { transport.cancel() }
                    var parser = ProviderStreamParser(api: ProviderRequestBuilder.api(for: provider))
                    for try await data in transport.start(request: request, streaming: true) {
                        try Task.checkCancellation()
                        for chunk in try parser.append(data) { continuation.yield(chunk) }
                        if parser.isFinished { break }
                    }
                    try Task.checkCancellation()
                    try parser.finish()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ProviderServiceError.sanitized(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Authenticated discovery always uses the supplied draft, including Anthropic's headers and pagination.
    public func fetchModels(provider: ModelProvider) async throws -> [ModelDefinition] {
        do {
            var models: [ModelDefinition] = []
            var seen = Set<String>()
            var cursors = Set<String>()
            var cursor: String?
            for _ in 0..<100 {
                try Task.checkCancellation()
                let request = try ProviderRequestBuilder.modelsRequest(provider: provider, afterID: cursor)
                let transport = ProviderHTTPStream(configuration: configuration)
                var data = Data()
                do {
                    for try await bytes in transport.start(request: request, streaming: false) {
                        try Task.checkCancellation()
                        guard data.count + bytes.count <= 4 * 1024 * 1024 else { throw ProviderServiceError.streamLimit }
                        data.append(bytes)
                    }
                } catch {
                    transport.cancel()
                    throw error
                }
                transport.cancel()
                try Task.checkCancellation()
                let page = try ProviderRequestBuilder.parseModels(data, anthropic: provider.type == .anthropic)
                models.append(contentsOf: page.models.filter { seen.insert($0.id).inserted })
                guard let next = page.nextID else { return models }
                guard cursors.insert(next).inserted else { throw ProviderServiceError.invalidResponse }
                cursor = next
            }
            throw ProviderServiceError.streamLimit
        } catch { throw ProviderServiceError.sanitized(error) }
    }

    /// A real inference request verifies a model, rather than mistaking /models for generation access.
    public func testModel(provider: ModelProvider, modelId: String) async throws {
        var testProvider = provider
        testProvider.hostedWebSearchEnabled = false
        var completed = false
        for try await chunk in streamChat(provider: testProvider, modelId: modelId,
                                          messages: [Message(role: .user, content: "Reply with OK.")],
                                          systemPrompt: "", tools: [], hostedWebSearchEnabled: false) {
            if chunk.toolCallDelta != nil { throw ProviderServiceError.invalidToolCall }
            if chunk.isFinished { completed = true }
        }
        try Task.checkCancellation()
        guard completed else { throw ProviderServiceError.incompleteStream }
    }
}

/// A small delegate transport avoids AsyncBytes.lines dropping SSE framing information.
/// All redirects are rejected so neither built-in nor arbitrary custom auth headers can leak to a new origin.
private final class ProviderHTTPStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var receivedResponse = false
    private var streaming = false

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
    }

    func start(request: URLRequest, streaming: Bool) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            self.lock.lock()
            self.streaming = streaming
            self.continuation = continuation
            let session = URLSession(configuration: self.configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.cancel() }
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        let session = self.session
        let task = self.task
        self.session = nil
        self.task = nil
        self.continuation = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    private func finish(_ error: Error? = nil) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let error { continuation?.finish(throwing: ProviderServiceError.sanitized(error)) }
        else { continuation?.finish() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            finish(ProviderServiceError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(response.statusCode) else {
            finish(ProviderServiceError.http(response.statusCode))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        let requiresSSE = streaming
        lock.unlock()
        if requiresSSE && response.mimeType?.lowercased() != "text/event-stream" {
            finish(ProviderServiceError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        receivedResponse = true
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        if case .dropped = continuation?.yield(data) { finish(ProviderServiceError.streamLimit) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let received = receivedResponse
        lock.unlock()
        finish(error ?? (received ? nil : ProviderServiceError.invalidResponse))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        finish(ProviderServiceError.http(response.statusCode))
        completionHandler(nil)
    }
}

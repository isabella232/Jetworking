import Foundation

enum APIError: Error {
    case unexpectedError
    case responseMissing
    case decodingError
    case invalidURLComponents
}

public final class Client {
    public typealias RequestCompletion<ResponseType> = (HTTPURLResponse?, Result<ResponseType, Error>) -> Void
    // MARK: - Properties
    private let configuration: Configuration

    private lazy var session: URLSession = .init(configuration: .default)

    private lazy var requestExecutor: RequestExecutor = {
        switch configuration.requestExecutorType {
        case .sync:
            return SyncRequestExecutor(session: session)

        case .async:
            return AsyncRequestExecutor(session: session)

        case let .custom(executorType):
            return executorType.init(session: session)
        }
    }()

    private var executingDownloads: [Int: DownloadHandler] = [:]
    private lazy var downloadExecutor: DownloadExecutor = {
        switch configuration.downloadExecutorType {
        case .default:
            return DefaultDownloadExecutor(
                sessionConfiguration: session.configuration,
                downloadExecutorDelegate: self
            )

        case .background:
            return BackgroundDownloadExecutor(
                sessionConfiguration: session.configuration,
                downloadExecutorDelegate: self
            )

        case let .custom(executorType):
            return executorType.init(
                sessionConfiguration: session.configuration,
                downloadExecutorDelegate: self
            )
        }
    }()

    // MARK: - Initialisation
    /**
     * Initialises a new client instance with a default url session.
     *
     * - Parameter configuration: The client configuration.
     * - Parameter sessionConfiguration: A function to configure the URLSession as inout parameter.
     */
    init(
        configuration: Configuration,
        sessionConfiguration: ((inout URLSession) -> Void)? = nil
    ) {
        self.configuration = configuration
        sessionConfiguration?(&session)
    }

    // MARK: - Methods
    @discardableResult
    public func get<ResponseType>(endpoint: Endpoint<ResponseType>, _ completion: @escaping RequestCompletion<ResponseType>) -> CancellableRequest? {
        do {
            let request: URLRequest = try createRequest(forHttpMethod: .GET, and: endpoint)
            return requestExecutor.send(request: request) { [weak self] data, urlResponse, error in
                self?.handleResponse(data: data, urlResponse: urlResponse, error: error, endpoint: endpoint, completion: completion)
            }
        } catch {
            completion(nil, .failure(error))
        }

        return nil
    }

    @discardableResult
    public func post<BodyType: Encodable, ResponseType>(endpoint: Endpoint<ResponseType>, body: BodyType, _ completion: @escaping RequestCompletion<ResponseType>) -> CancellableRequest? {
        do {
            let bodyData: Data = try configuration.encoder.encode(body)
            let request: URLRequest = try createRequest(forHttpMethod: .POST, and: endpoint, and: bodyData)
            return requestExecutor.send(request: request) { [weak self] data, urlResponse, error in
                self?.handleResponse(data: data, urlResponse: urlResponse, error: error, endpoint: endpoint, completion: completion)
            }
        } catch {
            completion(nil, .failure(error))
        }

        return nil
    }

    @discardableResult
    public func put<BodyType: Encodable, ResponseType>(endpoint: Endpoint<ResponseType>, body: BodyType, _ completion: @escaping RequestCompletion<ResponseType>) -> CancellableRequest? {
        do {
            let bodyData: Data = try configuration.encoder.encode(body)
            let request: URLRequest = try createRequest(forHttpMethod: .PUT, and: endpoint, and: bodyData)
            return requestExecutor.send(request: request) { [weak self] data, urlResponse, error in
                self?.handleResponse(data: data, urlResponse: urlResponse, error: error, endpoint: endpoint, completion: completion)
            }
        } catch {
            completion(nil, .failure(error))
        }

        return nil
    }

    @discardableResult
    public func patch<BodyType: Encodable, ResponseType>(
        endpoint: Endpoint<ResponseType>,
        body: BodyType,
        _ completion: @escaping RequestCompletion<ResponseType>
    ) -> CancellableRequest? {
        do {
            let bodyData: Data = try configuration.encoder.encode(body)
            let request: URLRequest = try createRequest(forHttpMethod: .PATCH, and: endpoint, and: bodyData)
            return requestExecutor.send(request: request) { [weak self] data, urlResponse, error in
                self?.handleResponse(data: data, urlResponse: urlResponse, error: error, endpoint: endpoint, completion: completion)
            }
        } catch {
            completion(nil, .failure(error))
        }

        return nil
    }

    @discardableResult
    public func delete<ResponseType>(endpoint: Endpoint<ResponseType>, parameter: [String: Any] = [:], _ completion: @escaping RequestCompletion<ResponseType>) -> CancellableRequest? {
        do {
            let request: URLRequest = try createRequest(forHttpMethod: .DELETE, and: endpoint)
            return requestExecutor.send(request: request) { [weak self] data, urlResponse, error in
                self?.handleResponse(data: data, urlResponse: urlResponse, error: error, endpoint: endpoint, completion: completion)
            }
        } catch {
            completion(nil, .failure(error))
        }

        return nil
    }

    @discardableResult
    public func download(
        url: URL,
        progressHandler: DownloadHandler.ProgressHandler,
        _ completion: @escaping DownloadHandler.CompletionHandler
    ) -> CancellableRequest? {
        // TODO: Add correct error handling
        guard checkForValidDownloadURL(url) else { return nil }

        let request: URLRequest = .init(url: url)
        let task = downloadExecutor.download(request: request)
        task.flatMap { executingDownloads[$0.identifier] = DownloadHandler(progressHandler: progressHandler, completionHandler: completion) }
        return task
    }

    private func checkForValidDownloadURL(_ url: URL) -> Bool {
        guard let scheme = URLComponents(string: url.absoluteString)?.scheme else { return false }

        return scheme == "http" || scheme == "https"
    }

    private func createRequest<ResponseType>(
        forHttpMethod httpMethod: HTTPMethod,
        and endpoint: Endpoint<ResponseType>,
        and body: Data? = nil
    ) throws -> URLRequest {
        let request = URLRequest(
            url: try URLFactory.makeURL(from: endpoint, withBaseURL: configuration.baseURL),
            httpMethod: httpMethod,
            httpBody: body
        )
        return configuration.requestInterceptors.reduce(request) { request, interceptor in
            return interceptor.intercept(request)
        }
    }

    // TODO: Improve this function (Error handling, evaluation of header fields, status code evalutation, ...)
    private func handleResponse<ResponseType>(
        data: Data?,
        urlResponse: URLResponse?,
        error: Error?,
        endpoint: Endpoint<ResponseType>,
        completion: @escaping RequestCompletion<ResponseType>
    ) {
        let interceptedResponse = configuration.responseInterceptors.reduce(urlResponse) { response, component in
            return component.intercept(data: data, response: response, error: error)
        }

        guard let currentURLResponse = interceptedResponse as? HTTPURLResponse else {
            return completion(nil, .failure(error ?? APIError.responseMissing))
        }

        if let error = error { return completion(currentURLResponse, .failure(error)) }

        switch HTTPStatusCodeType(statusCode: currentURLResponse.statusCode) {
        case .successful:
            guard
                let data = data,
                let decodedData = try? configuration.decoder.decode(ResponseType.self, from: data)
            else {
                return completion(currentURLResponse, .failure(APIError.decodingError))
            }
            // Evaluate Header fields --> urlResponse.allHeaderFields

            completion(currentURLResponse, .success(decodedData))
            
        case .clientError, .serverError:
            guard let error = error else { return completion(currentURLResponse, .failure(APIError.unexpectedError)) }

            completion(currentURLResponse, .failure(error))

        default:
            return
        }
    }
}

extension Client: DownloadExecutorDelegate {
    public func downloadExecutor(
        _ downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        executingDownloads[downloadTask.identifier]?.progressHandler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func downloadExecutor(_ downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // TODO handle response before calling the completion
        executingDownloads[downloadTask.identifier]?.completionHandler(location, downloadTask.response, downloadTask.error)
    }

    public func downloadExecutor(_ downloadTask: URLSessionDownloadTask, didCompleteWithError error: Error?) {
        // TODO handle response before calling the completion
        executingDownloads[downloadTask.identifier]?.completionHandler(nil, downloadTask.response, error)
    }
}

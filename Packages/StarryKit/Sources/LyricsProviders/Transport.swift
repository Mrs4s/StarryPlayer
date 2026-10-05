import Foundation
import zlib

/// Plain HTTP for the AMLL TTML DB: ephemeral session, 8 s timeout.
struct LyricsHTTP: Sendable {
    enum Failure: Error, Sendable, Equatable {
        case status(Int)
    }

    private let session: URLSession

    init(timeout: TimeInterval = 8) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
    }

    func get(_ url: URL, headers: [String: String] = [:], followRedirects: Bool = true) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try await send(request, delegate: followRedirects ? nil : RedirectBlocker())
    }

    private func send(_ request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request, delegate: delegate)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

enum Inflate {
    enum Failure: Error { case corrupt(Int32) }

    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        do {
            return try run(input, windowBits: 15 + 32) // zlib or gzip header
        } catch {
            return try run(input, windowBits: -15)     // raw deflate
        }
    }

    private static func run(_ input: [UInt8], windowBits: Int32) throws -> [UInt8] {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.corrupt(Z_STREAM_ERROR)
        }
        defer { inflateEnd(&stream) }
        var input = input
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let status: Int32 = input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)
            var status: Int32 = Z_OK
            while status == Z_OK {
                status = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    output.append(contentsOf: buffer[0..<(buffer.count - Int(stream.avail_out))])
                    return result
                }
            }
            return status
        }
        // Block ciphers pad the stream, so trailing bytes after the end marker are expected.
        guard status == Z_STREAM_END else { throw Failure.corrupt(status) }
        return output
    }
}

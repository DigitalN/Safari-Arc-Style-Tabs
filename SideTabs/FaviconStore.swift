import AppKit
import Observation

/// Downloads and caches favicons. Tries the icon URL the page declared, then the
/// site's /favicon.ico; views fall back to a letter tile when both fail.
@Observable
final class FaviconStore {
    private(set) var images: [String: NSImage] = [:]

    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        configuration.urlCache = URLCache(
            memoryCapacity: 4 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            directory: caches.appending(path: "Favicons", directoryHint: .isDirectory)
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 10
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15",
            "Accept": "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5",
        ]
        return URLSession(configuration: configuration)
    }()

    /// Icon URLs to try for a page, best first.
    static func candidates(iconURL: String?, pageURL: String?) -> [String] {
        var result: [String] = []
        if let iconURL, !iconURL.isEmpty {
            result.append(iconURL)
        }
        if let pageURL, let url = URL(string: pageURL), let scheme = url.scheme, ["http", "https"].contains(scheme),
           let host = url.host() {
            let fallback = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/favicon.ico"
            if !result.contains(fallback) {
                result.append(fallback)
            }
        }
        return result
    }

    /// The first cached image among the candidates. Reading this in a view body keeps
    /// the view updated as icons arrive.
    func image(for candidates: [String]) -> NSImage? {
        for candidate in candidates {
            if let image = images[candidate] {
                return image
            }
        }
        return nil
    }

    func load(_ candidates: [String]) async {
        for candidate in candidates {
            if images[candidate] != nil {
                return
            }
            if let failed = failedAt[candidate], Date().timeIntervalSince(failed) < 600 {
                continue
            }
            if await fetch(candidate) {
                return
            }
        }
    }

    private func fetch(_ urlString: String) async -> Bool {
        guard !inFlight.contains(urlString), let url = URL(string: urlString) else { return false }
        inFlight.insert(urlString)
        defer { inFlight.remove(urlString) }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let image = NSImage(data: data), image.isValid, image.size.width > 0 else {
                throw URLError(.cannotDecodeContentData)
            }
            images[urlString] = image
            return true
        } catch {
            failedAt[urlString] = Date()
            return false
        }
    }
}

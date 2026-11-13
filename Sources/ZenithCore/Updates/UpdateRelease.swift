import Foundation

// What GitHub says the latest release is, after every field that matters has been checked. Everything in the API's
// answer is untrusted: the version is parsed strictly, the download URL must be exactly the one this repository's
// release would have, and the release page is built here from the checked tag rather than taken from the response.

public enum UpdateLimits {
    /// The GitHub repository releases come from.
    public static let repositoryPath = "/mynameisbat/zenith-macos"
    public static let latestReleaseEndpoint = URL(string: "https://api.github.com/repos/mynameisbat/zenith-macos/releases/latest")!
    /// A release DMG is about 4 MB; anything far bigger is not ours.
    public static let maximumDownloadBytes: Int64 = 300 * 1024 * 1024
    /// The API's JSON for one release is a few KB.
    public static let maximumFeedBytes = 1024 * 1024
    /// What the app bundle inside the image is called, and its bundle identifier.
    public static let appBundleName = "Zenith.app"
    public static let bundleIdentifier = "com.zenith.workspace"

    /// `Zenith-2.5.0.dmg`. `version` is the tag without its `v`, already checked to be digits and dots.
    public static func assetName(forVersionText version: String) -> String {
        "Zenith-\(version).dmg"
    }
}

/// A release that may be offered: newer or not is decided by the caller.
public struct UpdateRelease: Equatable, Sendable {
    public let version: AppVersion
    /// The tag exactly as published (`v2.5.0`), already checked by `AppVersion`.
    public let tag: String
    public let assetName: String
    public let downloadURL: URL
    /// Bytes, as the API states; the download must be exactly this long.
    public let assetSize: Int64
    /// Lower-case hex SHA-256 when the API publishes one (`digest: "sha256:…"`).
    public let sha256: String?

    public init(version: AppVersion, tag: String, assetName: String, downloadURL: URL, assetSize: Int64, sha256: String?) {
        self.version = version
        self.tag = tag
        self.assetName = assetName
        self.downloadURL = downloadURL
        self.assetSize = assetSize
        self.sha256 = sha256
    }

    /// The release page, built from the checked tag (never the `html_url` of the response).
    public var releasePageURL: URL {
        URL(string: "https://github.com\(UpdateLimits.repositoryPath)/releases/tag/\(tag)")!
    }
}

public enum UpdateFeedError: Error, Equatable, Sendable, LocalizedError {
    case offline
    case rateLimited
    case httpStatus(Int)
    case malformedResponse
    case notAVersion
    case noMatchingAsset
    case invalidAssetURL
    case invalidAssetSize

    public var errorDescription: String? {
        switch self {
        case .offline:
            return String(localized: "Could not reach GitHub. Check your internet connection and try again.")
        case .rateLimited:
            return String(localized: "GitHub is limiting requests from this network. Try again in an hour.")
        case .httpStatus(let code):
            return String(localized: "GitHub answered with an error (HTTP \(String(code))). Try again later.")
        case .malformedResponse:
            return String(localized: "GitHub sent an answer Zenith could not read.")
        case .notAVersion:
            return String(localized: "The latest release on GitHub does not have a version number Zenith understands.")
        case .noMatchingAsset, .invalidAssetURL, .invalidAssetSize:
            return String(localized: "The latest release on GitHub has no Zenith download Zenith can trust.")
        }
    }
}

/// Turns the `releases/latest` JSON into an `UpdateRelease`, or refuses it.
public enum UpdateReleaseParser {
    private struct RawRelease: Decodable {
        let tag_name: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [RawAsset]?
    }

    private struct RawAsset: Decodable {
        let name: String?
        let size: Int64?
        let browser_download_url: String?
        let digest: String?
    }

    public enum Outcome: Equatable, Sendable {
        case release(UpdateRelease)
        /// A draft or a pre-release: not offered (the `/latest` endpoint should never return one).
        case ignored
    }

    public static func parse(_ data: Data) throws -> Outcome {
        guard data.count <= UpdateLimits.maximumFeedBytes,
              let raw = try? JSONDecoder().decode(RawRelease.self, from: data) else {
            throw UpdateFeedError.malformedResponse
        }
        if raw.draft == true || raw.prerelease == true { return .ignored }
        guard let tag = raw.tag_name, let version = AppVersion(tag) else { throw UpdateFeedError.notAVersion }
        // The tag passed AppVersion, so it is `v?` + digits and dots: safe in a file name and a URL path.
        let versionText = (tag.first == "v" || tag.first == "V") ? String(tag.dropFirst()) : tag
        let expectedName = UpdateLimits.assetName(forVersionText: versionText)

        let matching = (raw.assets ?? []).filter { $0.name == expectedName }
        guard matching.count == 1, let asset = matching.first else { throw UpdateFeedError.noMatchingAsset }
        guard let urlText = asset.browser_download_url,
              let url = URL(string: urlText),
              UpdateURLPolicy.isAllowedDownloadURL(url, tag: tag, assetName: expectedName) else {
            throw UpdateFeedError.invalidAssetURL
        }
        guard let size = asset.size, size > 0, size <= UpdateLimits.maximumDownloadBytes else {
            throw UpdateFeedError.invalidAssetSize
        }
        return .release(UpdateRelease(
            version: version,
            tag: tag,
            assetName: expectedName,
            downloadURL: url,
            assetSize: size,
            sha256: asset.digest.flatMap(sha256Hex(fromDigest:))
        ))
    }

    /// `sha256:<64 hex>` → the hex in lower case. Any other form is ignored (the signature check is the authority;
    /// the digest only catches a damaged download early).
    static func sha256Hex(fromDigest digest: String) -> String? {
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else { return nil }
        let hex = digest.dropFirst(prefix.count).lowercased()
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return nil
        }
        return hex
    }
}

/// Which URLs a release download may come from.
public enum UpdateURLPolicy {
    /// The URL the API gives must be exactly
    /// `https://github.com/mynameisbat/zenith-macos/releases/download/<tag>/Zenith-<version>.dmg`: no other host,
    /// port, user, query, fragment or path, and no percent-encoded tricks.
    public static func isAllowedDownloadURL(_ url: URL, tag: String, assetName: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let expectedPath = "\(UpdateLimits.repositoryPath)/releases/download/\(tag)/\(assetName)"
        return components.scheme == "https"
            && components.host == "github.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil && components.password == nil
            && components.query == nil && components.fragment == nil
            && components.percentEncodedPath == expectedPath
    }

    /// GitHub answers the download URL with a redirect to its asset storage. A redirect is followed only to https on
    /// github.com or a `*.githubusercontent.com` host (today `release-assets.githubusercontent.com`).
    public static func isAllowedRedirect(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
}

// MARK: - Feed

/// Fetches a URL. The real one is an ephemeral `URLSession`; tests return fixtures.
public protocol UpdateFeedTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Where "is there a newer Zenith?" is asked.
public protocol UpdateFeed: Sendable {
    /// The latest published release, or nil when there is none to offer (a draft or pre-release).
    func latestRelease() async throws -> UpdateRelease?
}

/// GitHub's `releases/latest`.
public struct GitHubUpdateFeed: UpdateFeed {
    private let transport: UpdateFeedTransport
    private let runningVersion: AppVersion

    public init(transport: UpdateFeedTransport = URLSessionUpdateTransport(), runningVersion: AppVersion = .running) {
        self.transport = transport
        self.runningVersion = runningVersion
    }

    /// No identifiers, no cookies: a plain product User-Agent and the API's media type.
    public func makeRequest() -> URLRequest {
        var request = URLRequest(url: UpdateLimits.latestReleaseEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Zenith/\(runningVersion.description)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    public func latestRelease() async throws -> UpdateRelease? {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: makeRequest())
        } catch let error as UpdateFeedError {
            throw error
        } catch {
            throw UpdateFeedError.offline
        }
        switch response.statusCode {
        case 200: break
        case 403, 429: throw UpdateFeedError.rateLimited
        default: throw UpdateFeedError.httpStatus(response.statusCode)
        }
        switch try UpdateReleaseParser.parse(data) {
        case .release(let release): return release
        case .ignored: return nil
        }
    }
}

/// An ephemeral session: nothing cached, no cookies, short time limits.
public final class URLSessionUpdateTransport: UpdateFeedTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateFeedError.malformedResponse }
        return (data, http)
    }
}

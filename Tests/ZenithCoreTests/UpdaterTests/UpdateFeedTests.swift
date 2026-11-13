import Testing
import Foundation
@testable import ZenithCore

/// Versions and the release JSON: everything from GitHub is untrusted and checked strictly. No network.
@Suite("Updater: versions and release feed")
struct UpdateFeedTests {
    // MARK: - Versions

    @Test("UPD-V01: Valid versions parse; v prefix, missing components are 0")
    func testVersionParsing() throws {
        let cases: [(String, [Int])] = [
            ("2.4.0", [2, 4, 0]), ("v2.4.0", [2, 4, 0]), ("V2.4", [2, 4]), ("10", [10]),
            ("2.10.0.1", [2, 10, 0, 1]), ("002.4.0", [2, 4, 0]), ("999999.0", [999_999, 0])
        ]
        for (text, components) in cases {
            #expect(AppVersion(text)?.components == components, "\(text)")
        }
        #expect(AppVersion("2.4") == AppVersion("2.4.0"))
        #expect(AppVersion("v2.4.0")?.description == "2.4.0")
    }

    @Test("UPD-V02: Anything that is not digits and dots is rejected, not guessed")
    func testVersionRejects() {
        let bad = [
            "", "v", "2.4.0-beta", "2.4.0 ", " 2.4.0", "2..4", ".2.4", "2.4.", "2.4.0.0.1", "vv2.4", "2.4.x",
            "+2.4", "-1.0", "２.4.0", "2.٤.0", "1234567.0", "2.4.0\n", "2.4;rm -rf", "latest", "v2.4.0/../x",
            String(repeating: "1.", count: 20) + "1"
        ]
        for text in bad {
            #expect(AppVersion(text) == nil, "\(text.debugDescription) should be rejected")
        }
    }

    @Test("UPD-V03: Comparison is numeric per component")
    func testVersionComparison() throws {
        func v(_ s: String) -> AppVersion { AppVersion(s)! }
        #expect(v("2.10.0") > v("2.9.9"))
        #expect(v("2.4.1") > v("2.4"))
        #expect(v("3") > v("2.99.99"))
        #expect(!(v("2.4.0") > v("2.4")))
        #expect(!(v("2.4.0") < v("2.4")))
        #expect(v("2.4.0.1") > v("2.4.0"))
        #expect(v("1.0.0") < v("1.0.1"))
    }

    // MARK: - Release JSON

    private static let goodURL = "https://github.com/mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg"
    private static let digest = "sha256:5d6c54558118d94c9319e252e8000752d32807f73a48ed637584e885cea8dffa"

    private struct Asset {
        var name = "Zenith-2.5.0.dmg"
        var size: Int64 = 3_787_349
        var url = UpdateFeedTests.goodURL
        var digest: String? = UpdateFeedTests.digest
    }

    private static func json(tag: Any = "v2.5.0", draft: Bool = false, prerelease: Bool = false, assets: [Asset] = [Asset()]) -> Data {
        let assetObjects: [[String: Any]] = assets.map { asset in
            var object: [String: Any] = [
                "name": asset.name, "size": asset.size, "browser_download_url": asset.url,
                "content_type": "application/x-apple-diskimage", "state": "uploaded"
            ]
            if let digest = asset.digest { object["digest"] = digest }
            return object
        }
        let object: [String: Any] = [
            "tag_name": tag, "name": "Zenith", "draft": draft, "prerelease": prerelease,
            "html_url": "https://evil.example/somewhere", "assets": assetObjects
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("UPD-F01: A normal release parses; the page URL is built from the tag, not html_url")
    func testNormalRelease() throws {
        guard case .release(let release) = try UpdateReleaseParser.parse(Self.json()) else {
            Issue.record("expected a release"); return
        }
        #expect(release.version == AppVersion("2.5.0"))
        #expect(release.tag == "v2.5.0")
        #expect(release.assetName == "Zenith-2.5.0.dmg")
        #expect(release.downloadURL.absoluteString == Self.goodURL)
        #expect(release.assetSize == 3_787_349)
        #expect(release.sha256 == "5d6c54558118d94c9319e252e8000752d32807f73a48ed637584e885cea8dffa")
        #expect(release.releasePageURL.absoluteString == "https://github.com/mynameisbat/zenith-macos/releases/tag/v2.5.0")
    }

    @Test("UPD-F02: The real v2.4.0 shape (captured once by hand) parses")
    func testRealShape() throws {
        let data = Data("""
        {"tag_name":"v2.4.0","name":"Zenith v2.4.0","draft":false,"prerelease":false,
         "html_url":"https://github.com/mynameisbat/zenith-macos/releases/tag/v2.4.0","published_at":"2026-11-08T06:36:04Z",
         "assets":[{"name":"Zenith-2.4.0.dmg","size":3787349,"state":"uploaded","content_type":"application/x-apple-diskimage",
           "digest":"sha256:5d6c54558118d94c9319e252e8000752d32807f73a48ed637584e885cea8dffa",
           "browser_download_url":"https://github.com/mynameisbat/zenith-macos/releases/download/v2.4.0/Zenith-2.4.0.dmg"}]}
        """.utf8)
        guard case .release(let release) = try UpdateReleaseParser.parse(data) else { Issue.record("expected a release"); return }
        #expect(release.version == AppVersion("2.4.0"))
    }

    @Test("UPD-F03: No asset, or only a wrongly named one, is refused")
    func testNoMatchingAsset() {
        #expect(throws: UpdateFeedError.noMatchingAsset) { try UpdateReleaseParser.parse(Self.json(assets: [])) }
        for name in ["Zenith-2.4.0.dmg", "zenith-2.5.0.dmg", "Zenith-2.5.0.dmg.zip", "Zenith.dmg", "Zenith-v2.5.0.dmg", "../Zenith-2.5.0.dmg"] {
            #expect(throws: UpdateFeedError.noMatchingAsset, "\(name)") {
                try UpdateReleaseParser.parse(Self.json(assets: [Asset(name: name)]))
            }
        }
        // Two assets with the right name is not something GitHub allows: refused rather than picking one.
        #expect(throws: UpdateFeedError.noMatchingAsset) { try UpdateReleaseParser.parse(Self.json(assets: [Asset(), Asset()])) }
    }

    @Test("UPD-F04: Download URLs other than this repository's exact release asset are refused")
    func testBadURLs() {
        let bad = [
            "http://github.com/mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg",
            "https://evil.example/mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg",
            "https://github.com.evil.example/mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg",
            "https://objects.githubusercontent.com/mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg",
            "https://github.com/someoneelse/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg",
            "https://github.com/mynameisbat/zenith-macos/raw/main/Zenith-2.5.0.dmg",
            "https://github.com/mynameisbat/zenith-macos/releases/download/v2.4.0/Zenith-2.5.0.dmg",
            "https://github.com/mynameisbat/zenith-macos/releases/download/v2.5.0/../v2.5.0/Zenith-2.5.0.dmg",
            "https://github.com/mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith%2D2.5.0.dmg",
            "https://github.com/mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg?x=1",
            "https://github.com/mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg#x",
            "https://user:pw@github.com/mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg",
            "https://github.com:8443/mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg",
            "file:///mynameisbat/zenith-macos/releases/download/v2.5.0/Zenith-2.5.0.dmg",
            "not a url"
        ]
        for url in bad {
            #expect(throws: UpdateFeedError.invalidAssetURL, "\(url)") {
                try UpdateReleaseParser.parse(Self.json(assets: [Asset(url: url)]))
            }
        }
    }

    @Test("UPD-F05: Sizes that are zero, negative or over the cap are refused")
    func testSizes() {
        for size: Int64 in [0, -1, UpdateLimits.maximumDownloadBytes + 1, 50_000_000_000] {
            #expect(throws: UpdateFeedError.invalidAssetSize, "\(size)") {
                try UpdateReleaseParser.parse(Self.json(assets: [Asset(size: size)]))
            }
        }
        #expect((try? UpdateReleaseParser.parse(Self.json(assets: [Asset(size: UpdateLimits.maximumDownloadBytes)]))) != nil)
    }

    @Test("UPD-F06: Drafts and pre-releases are ignored, not offered")
    func testPrerelease() throws {
        #expect(try UpdateReleaseParser.parse(Self.json(prerelease: true)) == .ignored)
        #expect(try UpdateReleaseParser.parse(Self.json(draft: true)) == .ignored)
    }

    @Test("UPD-F07: Garbage, wrong types and a tag that is not a version are refused")
    func testGarbage() {
        for data in [Data(), Data("<html>".utf8), Data("[]".utf8), Data("{\"tag_name\": 5}".utf8), Data(repeating: 0x7B, count: 2_000_000)] {
            #expect(throws: UpdateFeedError.malformedResponse) { try UpdateReleaseParser.parse(data) }
        }
        for tag in ["latest", "v2.5.0-rc1", "v2.5.0; rm -rf ~", "nightly"] {
            #expect(throws: UpdateFeedError.notAVersion, "\(tag)") { try UpdateReleaseParser.parse(Self.json(tag: tag)) }
        }
        #expect(throws: UpdateFeedError.notAVersion) { try UpdateReleaseParser.parse(Data("{\"assets\": []}".utf8)) }
    }

    @Test("UPD-F08: A digest is used only in its sha256:<64 hex> form")
    func testDigest() throws {
        for digest in ["sha512:abc", "sha256:xyz", "sha256:" + String(repeating: "a", count: 63), "md5:00"] {
            guard case .release(let release) = try UpdateReleaseParser.parse(Self.json(assets: [Asset(digest: digest)])) else {
                Issue.record("expected a release"); continue
            }
            #expect(release.sha256 == nil)
        }
        guard case .release(let upper) = try UpdateReleaseParser.parse(Self.json(assets: [Asset(digest: "sha256:" + String(repeating: "AB", count: 32))])) else {
            Issue.record("expected a release"); return
        }
        #expect(upper.sha256 == String(repeating: "ab", count: 32))
    }

    @Test("UPD-F09: Redirects are followed only to https on GitHub's hosts")
    func testRedirectPolicy() {
        #expect(UpdateURLPolicy.isAllowedRedirect(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/2?x=y")!))
        #expect(UpdateURLPolicy.isAllowedRedirect(URL(string: "https://objects.githubusercontent.com/a")!))
        #expect(!UpdateURLPolicy.isAllowedRedirect(URL(string: "http://release-assets.githubusercontent.com/a")!))
        #expect(!UpdateURLPolicy.isAllowedRedirect(URL(string: "https://githubusercontent.com.evil.example/a")!))
        #expect(!UpdateURLPolicy.isAllowedRedirect(URL(string: "https://evilgithubusercontent.com/a")!))
    }

    // MARK: - Feed (transport stubbed)

    private struct StubTransport: UpdateFeedTransport {
        let result: @Sendable (URLRequest) throws -> (Data, Int)
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, status) = try result(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("UPD-F10: The request is a plain GET with a product User-Agent, the API media type and no cookies")
    func testRequest() {
        let request = GitHubUpdateFeed(transport: StubTransport { _ in (Data(), 200) }, runningVersion: AppVersion("2.4.0")!).makeRequest()
        #expect(request.url == UpdateLimits.latestReleaseEndpoint)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Zenith/2.4.0")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval <= 30)
    }

    @Test("UPD-F11: Offline, rate limits and HTTP errors map to their errors")
    func testFeedErrors() async {
        let offline = GitHubUpdateFeed(transport: StubTransport { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: UpdateFeedError.offline) { try await offline.latestRelease() }
        for status in [403, 429] {
            let limited = GitHubUpdateFeed(transport: StubTransport { _ in (Data("{\"message\":\"API rate limit exceeded\"}".utf8), status) })
            await #expect(throws: UpdateFeedError.rateLimited) { try await limited.latestRelease() }
        }
        let missing = GitHubUpdateFeed(transport: StubTransport { _ in (Data(), 404) })
        await #expect(throws: UpdateFeedError.httpStatus(404)) { try await missing.latestRelease() }
        let pre = GitHubUpdateFeed(transport: StubTransport { _ in (Self.json(prerelease: true), 200) })
        #expect(try! await pre.latestRelease() == nil)
        let good = GitHubUpdateFeed(transport: StubTransport { _ in (Self.json(), 200) })
        #expect(try! await good.latestRelease()?.version == AppVersion("2.5.0"))
    }
}

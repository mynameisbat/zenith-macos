import Testing
import Foundation
@testable import ZenithCore

@Suite("Tracking link cleaner")
struct TrackingLinkCleanerTests {

    /// (input, expected output). Expected == input means the link must come back exactly as it was.
    static let cases: [(String, String)] = [
        // utm_* and the click identifiers go, other parameters stay in their order.
        ("https://example.com/article?utm_source=newsletter&utm_medium=email&utm_campaign=fall",
         "https://example.com/article"),
        ("https://shop.example.com/p/123?color=red&utm_source=fb&size=m&fbclid=IwAR0abc",
         "https://shop.example.com/p/123?color=red&size=m"),
        ("https://www.example.org/?gclid=Cj0KCQ&q=swift", "https://www.example.org/?q=swift"),
        ("https://example.com/?gclsrc=aw.ds&dclid=x&msclkid=y&yclid=1&twclid=2&ttclid=3&li_fat_id=4",
         "https://example.com/"),
        ("https://example.com/x?mc_cid=abc&mc_eid=def&id=7", "https://example.com/x?id=7"),
        ("https://example.com/x?_hsenc=p2AN&_hsmi=12345&page=2", "https://example.com/x?page=2"),
        ("https://www.instagram.com/p/Cxyz/?igshid=MzRlODBiNWFlZA==", "https://www.instagram.com/p/Cxyz/"),
        ("https://www.instagram.com/reel/Cabc/?igsh=MWQ1ZGUxMzBkMA%3D%3D", "https://www.instagram.com/reel/Cabc/"),
        // Fragment kept as is.
        ("https://docs.example.com/guide?utm_source=x#install", "https://docs.example.com/guide#install"),
        ("https://docs.example.com/guide?v=2&utm_source=x#section-3", "https://docs.example.com/guide?v=2#section-3"),
        // Case-insensitive names, percent-encoded names.
        ("https://example.com/?UTM_Source=X&a=1", "https://example.com/?a=1"),
        ("https://example.com/?utm%5Fsource=x&a=1", "https://example.com/?a=1"),
        // Percent-encoded values that stay are not decoded or re-encoded.
        ("https://example.com/search?q=caf%C3%A9%20au%20lait&utm_term=coffee&x=a%2Bb",
         "https://example.com/search?q=caf%C3%A9%20au%20lait&x=a%2Bb"),
        // Parameters without a value, repeated names, and empty pieces next to kept ones.
        ("https://example.com/?flag&utm_source=x&tag=a&tag=b", "https://example.com/?flag&tag=a&tag=b"),
        ("https://example.com/?utm_source=x&", "https://example.com/"),
        // "?" with nothing left goes away.
        ("https://example.com/path?fbclid=abc", "https://example.com/path"),
        ("http://example.com?utm_campaign=x", "http://example.com"),
        // YouTube and Spotify "si" share ids; X/Twitter ref_src / ref_url.
        ("https://youtu.be/dQw4w9WgXcQ?si=AbCdEf123", "https://youtu.be/dQw4w9WgXcQ"),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=AbCdEf&t=42", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42"),
        ("https://music.youtube.com/watch?v=abc&si=xyz", "https://music.youtube.com/watch?v=abc"),
        ("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=a1b2c3d4", "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"),
        ("https://twitter.com/jack/status/20?ref_src=twsrc%5Etfw&ref_url=https%3A%2F%2Fexample.com",
         "https://twitter.com/jack/status/20"),
        ("https://x.com/user/status/1?ref_src=twsrc%5Egoogle&lang=en", "https://x.com/user/status/1?lang=en"),
        // Port, user info and upper-case scheme are understood.
        ("HTTPS://Example.com:8443/a?utm_source=x&b=2", "HTTPS://Example.com:8443/a?b=2"),
        ("https://user@youtube.com/watch?v=1&si=2", "https://user@youtube.com/watch?v=1"),

        // --- Must NOT change ---
        // No query at all.
        ("https://example.com/path/to/page", "https://example.com/path/to/page"),
        ("https://example.com/page#utm_source=x", "https://example.com/page#utm_source=x"),
        // Nothing to remove.
        ("https://www.google.com/search?q=utm_source&hl=en", "https://www.google.com/search?q=utm_source&hl=en"),
        ("https://example.com/?a=1&&b=2", "https://example.com/?a=1&&b=2"),
        ("https://example.com/?", "https://example.com/?"),
        // "si" and "ref_src" are only tracking on their own sites.
        ("https://example.com/report?si=units&ref_src=menu", "https://example.com/report?si=units&ref_src=menu"),
        ("https://notyoutube.com/watch?si=1", "https://notyoutube.com/watch?si=1"),
        // "utm_" alone and names that merely contain a tracking name.
        ("https://example.com/?utm_=1&my_fbclid=2&gclid_backup=3", "https://example.com/?utm_=1&my_fbclid=2&gclid_backup=3"),
        // A query inside the fragment (hash routing) is the page's own.
        ("https://app.example.com/#/inbox?utm_source=x", "https://app.example.com/#/inbox?utm_source=x"),
        // Not a web link.
        ("utm_source=x&fbclid=y", "utm_source=x&fbclid=y"),
        ("ftp://example.com/file?utm_source=x", "ftp://example.com/file?utm_source=x"),
        ("mailto:someone@example.com?subject=hi&utm_source=x", "mailto:someone@example.com?subject=hi&utm_source=x"),
        ("Read https://example.com/?utm_source=x today", "Read https://example.com/?utm_source=x today"),
        ("https://example.com/?utm_source=x\nhttps://example.org/?fbclid=y", "https://example.com/?utm_source=x\nhttps://example.org/?fbclid=y"),
        ("https:///?utm_source=x", "https:///?utm_source=x"),
        ("", "")
    ]

    @Test("Cleans tracking parameters and leaves everything else exactly as it was", arguments: cases)
    func testCleanTable(input: String, expected: String) {
        #expect(TrackingLinkCleaner.clean(input) == expected)
        #expect(TrackingLinkCleaner.containsTracking(input) == (input != expected))
        #expect((TrackingLinkCleaner.cleanedIfChanged(input) == nil) == (input == expected))
    }

    @Test("Cleaning is idempotent", arguments: cases)
    func testCleanIsIdempotent(input: String, expected: String) {
        let once = TrackingLinkCleaner.clean(input)
        #expect(TrackingLinkCleaner.clean(once) == once)
        #expect(TrackingLinkCleaner.cleanedIfChanged(once) == nil)
    }

    @Test("Host-specific parameters follow the host, including subdomains")
    func testHostSpecificParameters() {
        #expect(TrackingLinkCleaner.isTrackingParameter("si", host: "www.youtube.com"))
        #expect(TrackingLinkCleaner.isTrackingParameter("si", host: "open.spotify.com"))
        #expect(!TrackingLinkCleaner.isTrackingParameter("si", host: "example.com"))
        #expect(TrackingLinkCleaner.isTrackingParameter("ref_src", host: "mobile.twitter.com"))
        #expect(!TrackingLinkCleaner.isTrackingParameter("ref_src", host: "github.com"))
        #expect(TrackingLinkCleaner.isTrackingParameter("utm_content", host: "anything.test"))
        #expect(!TrackingLinkCleaner.isTrackingParameter("", host: "example.com"))
    }

    @Test("Hosts are read from the link by hand, including IPv6 literals")
    func testWebHost() {
        #expect(TrackingLinkCleaner.webHost(of: "https://Example.COM/x") == "example.com")
        #expect(TrackingLinkCleaner.webHost(of: "http://[::1]:8080/?utm_source=x") == "[::1]")
        #expect(TrackingLinkCleaner.webHost(of: "https://a:b@host.test:1/") == "host.test")
        #expect(TrackingLinkCleaner.webHost(of: "example.com/?utm_source=x") == nil)
        #expect(TrackingLinkCleaner.webHost(of: "https:// spaced.com") == nil)
        #expect(TrackingLinkCleaner.clean("http://[::1]:8080/?utm_source=x&a=1") == "http://[::1]:8080/?a=1")
    }
}

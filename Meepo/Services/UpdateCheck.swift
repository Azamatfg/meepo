import Foundation

/// New versions from GitHub Releases (SPEC §7), no Sparkle: Meepo only says one exists; Homebrew or the
/// release page does the update.
enum UpdateCheck {
    struct Release: Decodable, Equatable {
        let tag_name: String
        let html_url: String
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    }

    static let latestURL = URL(string: "https://api.github.com/repos/Azamatfg/meepo/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The latest release if it is newer than this build; nil when not, or offline, or no releases yet.
    static func newer(than current: String = currentVersion) async -> Release? {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              isNewer(release.version, than: current) else { return nil }
        return release
    }

    /// Numeric, part by part: 0.10.0 > 0.9.3.
    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : 0) != (i < b.count ? b[i] : 0) {
            return (i < a.count ? a[i] : 0) > (i < b.count ? b[i] : 0)
        }
        return false
    }
}

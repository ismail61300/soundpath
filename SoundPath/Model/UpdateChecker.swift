import Foundation

/// Asks GitHub whether a newer release exists. This is SoundPath's only network request: it runs when
/// the user presses "Check Now", or once a day at launch if they turned the daily check on. Nothing
/// is sent except the request itself, and the app never downloads or installs anything on its own.
@MainActor @Observable
final class UpdateChecker {
    enum State: Equatable { case idle, checking, upToDate, available(version: String, url: URL), failed }

    static let shared = UpdateChecker()
    private(set) var state: State = .idle

    private static let endpoint = URL(string: "https://api.github.com/repos/ismail61300/soundpath/releases?per_page=5")!
    private static let releasePrefix = "https://github.com/ismail61300/soundpath/releases/"

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Dotted numeric versions ("0.2.0", "v1.10"); anything else is never "newer".
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
            let numbers = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard (1...4).contains(numbers.count), numbers.allSatisfy({ $0 != nil }) else { return nil }
            return numbers.compactMap { $0 }
        }
        guard let r = parts(remote), let l = parts(local) else { return false }
        for index in 0..<max(r.count, l.count) {
            let a = index < r.count ? r[index] : 0
            let b = index < l.count ? l[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Daily check for users who opted in; `lastCheck` keeps it to once per 24 hours.
    func checkIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: PrefKey.updateAuto) else { return }
        let last = defaults.double(forKey: PrefKey.updateLastCheck)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        await check()
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: PrefKey.updateLastCheck)

        let config = URLSessionConfiguration.ephemeral // no cookies, no cache on disk
        config.timeoutIntervalForRequest = 10
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession(configuration: config).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 512 * 1024,
                  let releases = try? JSONDecoder().decode([Release].self, from: data) else { state = .failed; return }
            guard let latest = releases.first(where: { !$0.draft }) else { state = .upToDate; return }
            let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
            // Only ever open a page of our own releases, whatever the response says.
            guard latest.html_url.hasPrefix(Self.releasePrefix), let url = URL(string: latest.html_url) else {
                state = .failed; return
            }
            state = Self.isNewer(version, than: Self.currentVersion) ? .available(version: version, url: url) : .upToDate
        } catch {
            state = .failed
        }
    }
}

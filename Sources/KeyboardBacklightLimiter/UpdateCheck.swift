import Foundation

/// Tells the user when a newer release exists. It does **not** install anything
/// — that is Sparkle's job, and Sparkle costs an embedded framework plus XPC
/// services, which turns the single `codesign` call in release.sh into
/// inside-out signing of every nested binary. This is the version that changes
/// nothing about signing or notarization.
///
/// Everything here fails silently. A missed update check is not worth a dialog,
/// and this app's whole character is being invisible when nothing is wrong.
enum UpdateCheck {
    /// The releases API always reflects whatever was last published, so there
    /// is no separate manifest to maintain — and therefore none to forget to
    /// update, which is the failure mode a hand-written appcast invites.
    private static let latestAPI = URL(string:
        "https://api.github.com/repos/dmartoon/MacBook-Keyboard-Backlight-Limiter/releases/latest")!

    static let releasesPage = URL(string:
        "https://github.com/dmartoon/MacBook-Keyboard-Backlight-Limiter/releases/latest")!

    private static let lastCheckKey = "lastUpdateCheck"
    /// One hour, not one day. A day sounds harmless and is not: after a
    /// release, a user can open the panel repeatedly for 24 hours and be told
    /// nothing, which reads as the feature being broken. Observed twice on real
    /// machines before it was believed.
    ///
    /// The limit this guards against is GitHub's unauthenticated 60 requests
    /// per hour per IP (measured: `x-ratelimit-limit: 60`). One check an hour
    /// is nowhere near it — you would have to open the panel 60 times in an
    /// hour, and even then only from a shared IP.
    private static let interval: TimeInterval = 60 * 60

    /// Calls back on the main queue with the newer version, or never calls back
    /// at all. Throttled — see `interval` for why an hour and not a day.
    static func check(currentVersion: String,
                      force: Bool = false,
                      completion: @escaping (String) -> Void) {
        let now = Date()
        if !force,
           let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           now.timeIntervalSince(last) < interval {
            return
        }
        UserDefaults.standard.set(now, forKey: lastCheckKey)

        var request = URLRequest(url: latestAPI, timeoutInterval: 10)
        // GitHub rejects API requests that arrive without a User-Agent.
        request.setValue("DimKeys/\(currentVersion)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = object["tag_name"] as? String
            else { return }   // includes the 404 you get before the first release

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isNewer(latest, than: currentVersion) else { return }
            DispatchQueue.main.async { completion(latest) }
        }.resume()
    }

    /// Component-wise numeric compare. String comparison gets this exactly
    /// backwards at the first double-digit release: "1.10.0" < "1.9.0"
    /// lexicographically, but 1.10.0 is the newer build.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

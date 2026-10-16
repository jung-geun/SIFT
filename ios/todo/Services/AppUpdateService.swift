import Foundation
import UIKit
import Combine

struct AppUpdateInfo: Equatable {
    let latestVersion: String
    let currentVersion: String
    let appStoreURL: URL

    var title: String {
        AppLanguage.localized("update.available", defaultValue: "New Version Available", language: AppLanguage.current)
    }

    var message: String {
        String(format: AppLanguage.localized("update.versions", defaultValue: "Current %@ · Latest %@", language: AppLanguage.current), locale: AppLanguage.current.locale, String(currentVersion), String(latestVersion))
    }
}

@MainActor
final class AppUpdateService: ObservableObject {
    @Published private(set) var updateInfo: AppUpdateInfo?
    @Published private(set) var isChecking = false

    private struct LookupResponse: Decodable {
        let resultCount: Int
        let results: [LookupResult]
    }

    private struct LookupResult: Decodable {
        let version: String
        let trackViewUrl: String
    }

    private let session: URLSession
    private let defaults: UserDefaults
    private let dismissedVersionKey = "pieroot.todo.dismissedUpdateVersion"
    private var lastCheckedAt: Date?

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    var hasUpdate: Bool {
        updateInfo != nil
    }

    func refreshIfNeeded(force: Bool = false) async {
        if !force, let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < 6 * 60 * 60 {
            return
        }
        await refresh()
    }

    func refresh() async {
        #if SIFT_QA
        // QA builds are not distributed through the production App Store listing.
        updateInfo = nil
        #else
        guard !isChecking else { return }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else { return }
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "country", value: Self.currentCountryCode())
        ]
        guard let url = components.url else { return }

        isChecking = true
        defer {
            isChecking = false
            lastCheckedAt = Date()
        }

        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(LookupResponse.self, from: data)
            guard response.resultCount > 0,
                  let result = response.results.first,
                  let appStoreURL = URL(string: result.trackViewUrl),
                  Self.isVersion(result.version, newerThan: currentVersion) else {
                updateInfo = nil
                return
            }
            if defaults.string(forKey: dismissedVersionKey) == result.version {
                updateInfo = nil
                return
            }
            updateInfo = AppUpdateInfo(
                latestVersion: result.version,
                currentVersion: currentVersion,
                appStoreURL: appStoreURL
            )
        } catch {
            updateInfo = nil
        }
        #endif
    }

    func dismissCurrentUpdate() {
        guard let latestVersion = updateInfo?.latestVersion else { return }
        defaults.set(latestVersion, forKey: dismissedVersionKey)
        updateInfo = nil
    }

    func openAppStore() {
        guard let appStoreURL = updateInfo?.appStoreURL else { return }
        UIApplication.shared.open(appStoreURL)
    }

    nonisolated private static func currentCountryCode() -> String {
        if #available(iOS 16.0, *) {
            return Locale.current.region?.identifier ?? "KR"
        }
        return (Locale.current as NSLocale).object(forKey: .countryCode) as? String ?? "KR"
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = versionComponents(candidate)
        let rhs = versionComponents(current)
        let count = max(lhs.count, rhs.count)

        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    nonisolated private static func versionComponents(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}

import AppKit
import Foundation

/// Stable entry points for the menu and settings. Sparkle owns update checks,
/// verification, and installation when a trusted feed and public key are embedded.
@MainActor
enum UpdateChecker {
    private static let provider = SparkleUpdateProvider()

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let body: String?
    }

    struct Version: Comparable {
        let numbers: [Int]
        let prerelease: [String]

        init?(_ input: String) {
            let text = input.hasPrefix("v") ? String(input.dropFirst()) : input
            guard text.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$"#,
                             options: .regularExpression) != nil else { return nil }
            let parts = text.split(separator: "-", maxSplits: 1)
            let components = parts[0].split(separator: ".").compactMap { Int($0) }
            guard components.count == 3 else { return nil }
            numbers = components
            prerelease = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
            guard !prerelease.contains(where: { $0.isEmpty }) else { return nil }
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
            if lhs.prerelease.isEmpty { return false }
            if rhs.prerelease.isEmpty { return true }
            for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
                if let l = Int(left), let r = Int(right) { return l < r }
                if Int(left) != nil { return true }
                if Int(right) != nil { return false }
                return left < right
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }

    static func checkOnLaunch() {
        _ = provider // starts Sparkle once; its scheduler owns background checks
    }

    static func checkPeriodic() {
        // Compatibility with the old timer until AppDelegate removes it.
        // A second scheduler would duplicate update checks.
    }

    static func checkNow() {
        guard provider.isConfigured else {
            let alert = NSAlert()
            alert.messageText = "MacSwitcher"
            alert.informativeText = L10n.languageCode == "ru"
                ? "Встроенная установка обновлений пока недоступна. Откройте официальные выпуски MacSwitcher и установите новую версию вручную."
                : "In-app updates are not configured yet. Open official MacSwitcher releases to install a new version manually."
            alert.addButton(withTitle: L10n.languageCode == "ru" ? "Открыть выпуски" : "Open Releases")
            alert.addButton(withTitle: L10n.updateLater)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: SettingsManager.githubURL + "/releases") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        provider.checkNow()
    }

    static func setAutomaticChecks(_ enabled: Bool) { provider.setAutomaticChecks(enabled) }

    static func setBetaChannel(_ enabled: Bool) { provider.setBetaChannel(enabled) }

    private static func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "MacSwitcherReleaseVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func fetchReleases() async throws -> [Release] {
        let endpoint = "https://api.github.com/repos/\(SettingsManager.githubOwner)/\(SettingsManager.githubRepo)/releases?per_page=25"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacSwitcher/\(currentVersion())", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([Release].self, from: data)
    }

    static func fetchBetaNotes() async -> String? {
        guard SettingsManager.shared.betaChannelEnabled,
              let releases = try? await fetchReleases() else { return nil }
        return newest(in: releases, includePrereleases: true)?.body
    }

    private static func newest(in releases: [Release], includePrereleases: Bool) -> Release? {
        releases.filter { !$0.draft && (includePrereleases || !$0.prerelease) && Version($0.tag_name) != nil }
            .max { Version($0.tag_name)! < Version($1.tag_name)! }
    }

}

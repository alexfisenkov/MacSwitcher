import AppKit
import Foundation

/// Own public releases only. This alpha opens a release page for manual installation;
/// it never downloads executables, invokes a shell, or replaces the running app.
@MainActor
enum UpdateChecker {
    private static var busy = false

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
        guard shouldAutoCheck() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Task { await check(silent: true) }
        }
    }

    static func checkPeriodic() {
        guard shouldAutoCheck() else { return }
        Task { await check(silent: true) }
    }

    static func checkNow() { Task { await check(silent: false) } }

    private static func shouldAutoCheck() -> Bool {
        let settings = SettingsManager.shared
        guard settings.checkUpdatesEnabled else { return false }
        return settings.lastUpdateCheck.map { Date().timeIntervalSince($0) >= 86400 } ?? true
    }

    private static func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "MacSwitcherReleaseVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func releaseURL(tag: String) -> URL? {
        guard Version(tag) != nil,
              let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: SettingsManager.githubURL + "/releases/tag/" + encoded)
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

    private static func check(silent: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let release = newest(in: try await fetchReleases(),
                                 includePrereleases: SettingsManager.shared.betaChannelEnabled)
            SettingsManager.shared.lastUpdateCheck = Date()
            guard let release, let version = Version(release.tag_name),
                  let installed = Version(currentVersion()), version > installed else {
                if !silent {
                    message(ru: "Более нового выпуска в выбранном канале пока нет.",
                            en: "There is no newer release in the selected channel yet.")
                }
                return
            }
            if silent && SettingsManager.shared.skippedVersion == release.tag_name { return }
            guard let url = releaseURL(tag: release.tag_name) else { return }
            let alert = NSAlert()
            alert.messageText = "MacSwitcher \(release.tag_name)"
            alert.informativeText = L10n.languageCode == "ru"
                ? "Доступен новый выпуск. Откроется страница MacSwitcher на GitHub; скачивание и установка выполняются вручную. Приложение не заменяет себя автоматически."
                : "A new release is available. Open MacSwitcher on GitHub to download and install it manually. The app does not replace itself automatically."
            alert.addButton(withTitle: L10n.languageCode == "ru" ? "Открыть выпуск" : "Open Release")
            alert.addButton(withTitle: L10n.updateLater)
            alert.addButton(withTitle: L10n.updateSkip)
            switch alert.runModal() {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(url)
            case .alertThirdButtonReturn: SettingsManager.shared.skippedVersion = release.tag_name
            default: break
            }
        } catch {
            if !silent {
                message(ru: "Не удалось проверить выпуски на GitHub. Попробуйте позже или откройте страницу проекта.",
                        en: "Could not check GitHub releases. Try again later or open the project page.")
            }
        }
    }

    private static func message(ru: String, en: String) {
        let alert = NSAlert()
        alert.messageText = "MacSwitcher"
        alert.informativeText = L10n.languageCode == "ru" ? ru : en
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

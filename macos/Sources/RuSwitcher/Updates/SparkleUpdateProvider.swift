import AppKit
import Foundation
import Sparkle

/// The only in-app installer. Sparkle verifies the published archive with the
/// EdDSA public key embedded in the signed app bundle. An unconfigured build
/// keeps the release-page action available, but cannot offer installation.
@MainActor
final class SparkleUpdateProvider: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let validFeed = feed.flatMap(URL.init(string:)).map { $0.scheme == "https" && $0.host != nil } ?? false
        let validKey = publicKey.flatMap { Data(base64Encoded: $0) }.map { $0.count == 32 } ?? false

        // Honor users who disabled the former GitHub check before Sparkle was
        // introduced. After migration, Sparkle owns its persisted preference.
        if validFeed && validKey,
           UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil,
           !SettingsManager.shared.checkUpdatesEnabled {
            UserDefaults.standard.set(false, forKey: "SUEnableAutomaticChecks")
        }
        controller = nil
        super.init()
        if validFeed && validKey {
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
    }

    var isConfigured: Bool { controller != nil }

    func checkNow() {
        guard let controller else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        SettingsManager.shared.checkUpdatesEnabled = enabled
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setBetaChannel(_ enabled: Bool) {
        SettingsManager.shared.betaChannelEnabled = enabled
        // Changing allowed channels needs a new scheduled feed cycle.
        controller?.updater.resetUpdateCycleAfterShortDelay()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        SettingsManager.shared.betaChannelEnabled ? ["beta", "alpha"] : []
    }
}

import Foundation

enum PredictionResources {
    enum LoadError: Error { case missingPackagedBundle }

    static func bundle() throws -> Bundle {
        #if MACSWITCHER_APP_BUNDLE
        // A distribution build must never fall back to a private SwiftPM path.
        guard let root = Bundle.main.resourceURL,
              let bundle = Bundle(url: root.appendingPathComponent("RuSwitcher_RuSwitcher.bundle")) else {
            throw LoadError.missingPackagedBundle
        }
        return bundle
        #else
        return Bundle.module
        #endif
    }
}

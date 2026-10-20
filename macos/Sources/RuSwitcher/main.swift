import AppKit

if CommandLine.arguments.contains("--self-test-resources") {
    // A packaged app must find its dictionary INSIDE the app, never through
    // SwiftPM's absolute build-directory fallback on the developer's machine.
    guard let resourceBundle = try? PredictionResources.bundle() else { exit(2) }
    let resourceRoot = resourceBundle.bundleURL.standardizedFileURL.path
    let appRoot = Bundle.main.bundleURL.standardizedFileURL.path
    guard resourceRoot.hasPrefix(appRoot + "/") else {
        fputs("Resource bundle is outside the app\n", stderr)
        exit(1)
    }
    for language in ["ru", "en"] {
        guard let url = resourceBundle.url(forResource: language, withExtension: "tsv"),
              let data = try? String(contentsOf: url, encoding: .utf8) else { exit(2) }
        let count = data.split(separator: "\n").count
        guard count == 200_000 else { exit(3) }
        print("\(language): \(count) bundled entries")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

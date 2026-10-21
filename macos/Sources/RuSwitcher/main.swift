import AppKit
import Darwin

if let status = AXCapabilityDiagnostics.runIfRequested(arguments: CommandLine.arguments) { exit(status) }

if CommandLine.arguments.contains("--benchmark-prediction") {
    do {
        let lexicon = try PredictionLexicon.bundled()
        let report = try PredictionBenchmark.run(engine: PredictionEngine(lexicon: lexicon),
            bundle: PredictionResources.bundle())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
        exit(report.passed ? 0 : 1)
    } catch {
        fputs("Synthetic benchmark could not load its bundled resources\n", stderr)
        exit(2)
    }
}

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
    let started = ProcessInfo.processInfo.systemUptime
    guard let lexicon = try? PredictionLexicon.bundled() else { exit(2) }
    for language in ["ru", "en"] {
        guard let url = resourceBundle.url(forResource: language, withExtension: "tsv"),
              let data = try? String(contentsOf: url, encoding: .utf8) else { exit(2) }
        let count = data.split(separator: "\n").count
        guard count == 200_000 else { exit(3) }
        print("\(language): \(count) bundled entries")
        guard let full = lexicon.fullWordCounts[language], full > count,
              let protected = lexicon.protectedTermCounts[language], protected > 0 else { exit(4) }
        print("\(language): \(full) full entries; \(protected) protected terms")
    }
    var usage = rusage()
    _ = getrusage(RUSAGE_SELF, &usage)
    print(String(format: "Lexicon load: %.1f ms; peak RSS: %.1f MiB",
        (ProcessInfo.processInfo.systemUptime - started) * 1000, Double(usage.ru_maxrss) / 1_048_576))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

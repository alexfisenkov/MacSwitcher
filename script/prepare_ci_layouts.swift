import Carbon
import Foundation

// System-input tests require both built-in layouts. Enable them only on a
// disposable hosted runner; never change a developer's input-source preferences.
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
    fputs("This fixture is restricted to GitHub Actions runners.\n", stderr)
    exit(2)
}
for identifier in ["com.apple.keylayout.US", "com.apple.keylayout.Russian"] {
    let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
    guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
          let source = sources.first else {
        fputs("Required built-in input source unavailable\n", stderr)
        exit(1)
    }
    guard TISEnableInputSource(source) == noErr else {
        fputs("Could not enable the required CI input source\n", stderr)
        exit(1)
    }
}
print("CI built-in RU/EN input sources ready")

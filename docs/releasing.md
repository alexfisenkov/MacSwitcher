# Local release candidate

`script/package_release.py` prepares a local candidate from an exact clean Git checkout. It does not tag, upload, commit, publish the appcast, install, or start the app. The current `version.json` is the sole version/build/channel source. A new release needs a build number higher than every item in `updates/appcast.xml` and an unused local Git tag `v<version>`.

The checkout must already contain the pinned Sparkle SwiftPM artifact. The signing identity is a full `Developer ID Application: … (TEAMID)` selector. `--notary-profile` names credentials previously stored for `notarytool` in Keychain; `--sparkle-account` names Sparkle's EdDSA Keychain account. The script never accepts key material or password values. Check that both selectors refer to the intended release credentials before running.

```sh
/usr/bin/python3 script/package_release.py \
  --identity 'Developer ID Application: Example Name (TEAMID1234)' \
  --notary-profile 'existing-profile-name' \
  --sparkle-account 'existing-account-name'
```

The command above is a syntax example, not a working credential set. The optional `--output-dir` must be a new, versioned directory inside `.сборки/`; by default a unique versioned directory is created there. Existing output is never replaced. The real command performs a network write to Apple notarization, so run it only for a release candidate that is ready for that step.

The helper invokes `build_app.py` for a signed universal bundle, verifies metadata, architecture, strict signature, hardened runtime, team and packaged resources, then makes a submission ZIP with `ditto`. It waits up to 60 minutes for an **Accepted** notarization result. An accepted app is stapled, validated and assessed by Gatekeeper. Only then does it create the final `MacSwitcher-<version>-universal.zip`, calculate its exact byte length and SHA-256, and sign that archive with Sparkle. It inserts a new first item into a local appcast candidate, preserves existing items, signs the candidate feed and verifies it. `updates/appcast.xml` remains untouched.

The candidate directory contains the app, notarization submission ZIP, final ZIP, signed `appcast.xml`, exact `previous-appcast.xml`, `notary-result.json` and `manifest.json`. Before submission, `notary-result.json` records `IN_PROGRESS` with the submission archive hash, length and start time. A nonzero exit, timeout, invalid response or missing accepted submission ID records `UNKNOWN`, plus a validated submission UUID/status and return code when available. It never stores raw tool output or credential selectors. `UNKNOWN` stops the pipeline before the final ZIP or feed candidate; do not submit again automatically. Reconcile the Apple submission using its ID where available before deciding how to proceed. An explicit rejection also stops the pipeline. Review the manifest, exact final ZIP, signed appcast and diff against `updates/appcast.xml` before any external release step. The manifest's `published: false` records only local preparation. Verify the GitHub Release asset and raw HTTPS feed independently after publication; do not infer publication or physical keyboard acceptance from local packaging.

Run the offline contract tests with `/usr/bin/python3 -m unittest script/test_package_release.py`. A real signing/notarization run, final manual CI and post-publication read-back are separate release gates. The old signed feed and immutable release assets must remain available until the new signed feed is independently verified. If publication fails, keep the previous feed serving its existing releases and diagnose the retained candidate instead of overwriting it.

During installation, use the normal quit/update path. Never force-terminate a running MacSwitcher: it may hold originals from an unconfirmed edit in RAM. If normal quit offers a local recovery export, complete that export before replacing the app. A crash before export can lose those RAM-only originals. Explicit exports remain in `~/Library/Application Support/MacSwitcher/Recovery/` with private file permissions; after checking that recovery is no longer needed, the user can remove those files in Finder. The updater does not delete them automatically.

## Legacy local build migration

Normal MacSwitcher upgrades, including alpha.14 to alpha.15, keep bundle ID `com.alexfisenkov.macswitcher` and the same preference and personal-dictionary locations. They do not need a preference-domain migration.

`script/migrate_settings.py` is a separate operator tool for the earlier local build whose exact source domain is `com.alexfisenkov.ruswitcher.local`. It is not a general importer for other applications. From this repository's root, before the first launch of MacSwitcher:

1. Quit the earlier local app and MacSwitcher normally, preserving pending originals through their normal exit flow.
2. Run `/usr/bin/python3 script/migrate_settings.py`. This read-only preview lists eligible missing keys without printing their values.
3. If the preview matches the intended migration, run `/usr/bin/python3 script/migrate_settings.py --apply`. The tool creates a private destination backup, preserves existing destination values, imports only allowlisted missing preferences, and checks the result. Keep the backup until the settings have been verified.
4. Launch MacSwitcher and check the layout pair, manual gestures, autocorrection choice and personal exceptions. macOS access permissions and startup registration require the application's normal setup; they are not imported as granted permissions.

An `unchanged` result means there were no eligible missing preferences. Do not interpret it as proof that another application's data was imported.

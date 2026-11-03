# MacSwitcher website

The static website lives in `website/` and adapts the published MacDictate landing page's visual language: fixed glass navigation, dark gradient hero, three feature cards, a learning callout, download/setup section and responsive footer. The design reference is `MacDictate/macos/web-landing/index.html` in the source checkout, byte-identical to the live MacDictate page at the time of the project brief (source commit `4c387ebe382a845fc5987715357b399604c38c39`, SHA-256 `20b16744775c02380dab53bda01f3cbbca6566d7ca3e3177a4ac18c6a218428b`). Only layout and styling patterns were adapted; the copied product mark is MacSwitcher's own `assets/MacSwitcher.svg`.

## Preview and checks

From the repository root, run `python3 -m http.server 8000 --directory website` and open `http://localhost:8000`. Validate the static pages and local references with `python3 script/check_website.py`; include `--javascript` to parse inline scripts with Node.

Publish the signed alpha.25 archive before deploying the website. The manual `Publish MacSwitcher website` workflow checks the static website and JavaScript, verifies that the linked archive is publicly reachable and nonempty, then uploads only `website/` to GitHub Pages. The local `python3 script/check_website.py` check leaves this network guard off; use `--published-release` when validating release availability. The workflow is triggered with `workflow_dispatch`; it does not run the Swift app build. The archive availability guard does not replace release SHA-256 or signature verification. GitHub Pages must be enabled for the repository before deployment. A successful local check or workflow file does not mean the site is published; verify the deployment URL and page contents after the workflow runs.

The main page also links Windows alpha.2 and explains default-on learning in Russian and English. The checker derives both versions from the platform version JSON files, requires their current download/release links, and checks public availability of the macOS ZIP plus Windows Setup and portable ZIP. The Windows target range is distinguished from tested hardware; unsigned Windows packages are identified as such.

## Release details and open limits

The page points directly to the alpha.25 universal ZIP because GitHub's `releases/latest` endpoint does not select prereleases. The release list and issue tracker are linked separately. The site states macOS 13 or later and Apple Silicon/Intel support, required Accessibility and Input Monitoring permissions, local text handling, and the prerelease caveat. It does not promise compatibility with every editor. Telegram selected-text correction and undo and isolated Shift gestures were physically confirmed in earlier releases; broader app compatibility and the new learning feature still need live acceptance. The privacy page explains default-on, word-only local learning and its controls. Do not describe this website as published until the Pages deployment has been independently read back.

The app source uses MIT; upstream code attribution is in `NOTICE.md`. Dictionary data has separate attribution and licensing in `dictionaries/NOTICE.md`; the site links to both and makes no claim that dictionary assets share the code license.

Planned site URL: https://alexfisenkov.github.io/MacSwitcher/.

## Learning release deployment · 2026-11-03

The alpha.25 download and learning disclosure sources passed the Pages workflow's static/JavaScript/public-download checks at `53e1f08add419bbc1c116d51fd2ddf4882dd5384`. The first deployment [41635185709](https://github.com/alexfisenkov/MacSwitcher/actions/runs/41635185709) was rejected before deployment steps: the `github-pages` environment does not allow the feature branch. Protection was not changed; at that point publication was still pending. App releases and the installed first-launch explanation had already been delivered independently.

The owner subsequently explicitly authorized merging PR #4 and publishing the site. PR #4 was retargeted to `main` and merged as `528e272c4ab208b0b4fd1062e47282e62d8e4f45`, preserving the already released ancestor stack. GitHub also recognized ancestor PRs #1–3 as merged. The application source and release artifacts remain unchanged; the new delta is website content, its checker and precise release documentation. Local browser checks passed at 1440×900 and 375×812 in both languages, including language switching, privacy/terms tabs, return navigation and overflow checks, with no console errors.

Publication [41648752742](https://github.com/alexfisenkov/MacSwitcher/actions/runs/41648752742) from that exact `main` commit passed both checks and deployment. The public [home page](https://alexfisenkov.github.io/MacSwitcher/), explicit index, legal page and product mark returned HTTP200 and byte-matched the deployed source. Main HTML SHA-256: `6041e30b3b092fab4e37f07132012028bcee514168e0e93f292282a4e230e436`; legal HTML: `ecd2075f22343cc0c48fdeeb4dd7bc96fa65a27d34a8924e9e751701b505f03d`. Public browser checks also passed at desktop/mobile widths: current Mac/Windows links, learning text, language switching and privacy/terms navigation, with no console errors. Stale Mac and Windows download links are rejected by isolated checker fixtures. Physical learning and the external editor/hardware matrix are unchanged separate acceptance items.

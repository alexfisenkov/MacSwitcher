# MacSwitcher website

The static website lives in `website/` and adapts the published MacDictate landing page's visual language: fixed glass navigation, dark gradient hero, three feature cards, download/setup section and responsive footer. The design reference is `MacDictate/macos/web-landing/index.html` in the source checkout, byte-identical to the live MacDictate page at the time of the project brief (source commit `4c387ebe382a845fc5987715357b399604c38c39`, SHA-256 `20b16744775c02380dab53bda01f3cbbca6566d7ca3e3177a4ac18c6a218428b`). Only layout and styling patterns were adapted; the copied product mark is MacSwitcher's own `assets/MacSwitcher.svg`.

## Preview and checks

From the repository root, run `python3 -m http.server 8000 --directory website` and open `http://localhost:8000`. Validate the static pages and local references with `python3 script/check_website.py`; include `--javascript` to parse inline scripts with Node.

Publish the signed alpha.19 archive before deploying the website. The manual `Publish MacSwitcher website` workflow checks the static website and JavaScript, verifies that the linked archive is publicly reachable and nonempty, then uploads only `website/` to GitHub Pages. The local `python3 script/check_website.py` check leaves this network guard off; use `--published-release` when validating release availability. The workflow is triggered with `workflow_dispatch`; it does not run the Swift app build. The archive availability guard does not replace release SHA-256 or signature verification. GitHub Pages must be enabled for the repository before deployment. A successful local check or workflow file does not mean the site is published; verify the deployment URL and page contents after the workflow runs.

## Release details and open limits

The page points directly to the alpha.19 universal ZIP because GitHub's `releases/latest` endpoint does not select prereleases. The release list and issue tracker are linked separately. The site states macOS 13 or later and Apple Silicon/Intel support, required Accessibility and Input Monitoring permissions, local text handling, and the prerelease caveat. It does not promise compatibility with every editor. Telegram selected-text correction and undo were physically confirmed; single-Shift behavior and broader app compatibility remain under evaluation. Do not describe this website as published until the Pages deployment has been independently read back.

The app source uses MIT; upstream code attribution is in `NOTICE.md`. Dictionary data has separate attribution and licensing in `dictionaries/NOTICE.md`; the site links to both and makes no claim that dictionary assets share the code license.

Planned site URL: https://alexfisenkov.github.io/MacSwitcher/.

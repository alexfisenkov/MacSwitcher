# MacSwitcher website

The static website lives in `website/` and adapts the published MacDictate landing page's visual language: fixed glass navigation, dark gradient hero, three feature cards, a learning callout, download/setup section and responsive footer. The design reference is `MacDictate/macos/web-landing/index.html` in the source checkout, byte-identical to the live MacDictate page at the time of the project brief (source commit `4c387ebe382a845fc5987715357b399604c38c39`, SHA-256 `20b16744775c02380dab53bda01f3cbbca6566d7ca3e3177a4ac18c6a218428b`). Only layout and styling patterns were adapted; the copied product mark is MacSwitcher's own `assets/MacSwitcher.svg`.

## Preview and checks

From the repository root, run `python3 -m http.server 8000 --directory website` and open `http://localhost:8000`. Validate the static pages and local references with `python3 script/check_website.py`; include `--javascript` to parse inline scripts with Node.

Publish and verify the signed archive referenced by the current website before deploying the website. The alpha.32 release archive and signed appcast are publicly available and verified. Pages publication must also be checked by reading back the deployment URL and page contents. The manual `Publish MacSwitcher website` workflow checks the static website and JavaScript, verifies that the linked archive is publicly reachable and nonempty, then uploads only `website/` to GitHub Pages. The local `python3 script/check_website.py` check leaves this network guard off; use `--published-release` when validating release availability. The workflow is triggered with `workflow_dispatch`; it does not run the Swift app build. The archive availability guard does not replace release SHA-256 or signature verification. GitHub Pages must be enabled for the repository before deployment. A successful local check or workflow file does not mean the site is published; verify the deployment URL and page contents after the workflow runs.

The main page also links Windows alpha.3 and explains default-on learning in Russian and English. The checker derives both versions from the platform version JSON files, requires their current download/release links, and checks public availability of the macOS ZIP plus Windows Setup and portable ZIP. The Windows target range is distinguished from tested hardware; unsigned Windows packages are identified as such.

## Release details and open limits

The local page points directly to the alpha.32 universal ZIP because GitHub's `releases/latest` endpoint does not select prereleases. The release list and issue tracker are linked separately. The site states macOS 13 or later and Apple Silicon/Intel support, required Accessibility and Input Monitoring permissions, local text handling, and the prerelease caveat. It does not promise compatibility with every editor. The installed settings window was visually checked: it opens to the usage guide and has three tabs. Physical Shift gestures and compatibility across all apps remain unverified. The privacy page explains default-on, word-only local learning and its controls, plus the separate macOS recovery backup option (default OFF, possible full-field copies, restricted local folder, no app network transmission or automatic deletion). The alpha.31 Pages deployment has been independently read back. The alpha.32 GitHub Release, ZIP, signed appcast and deployed website have been publicly verified; deployment evidence is recorded below.

The app source uses MIT; upstream code attribution is in `NOTICE.md`. Dictionary data has separate attribution and licensing in `dictionaries/NOTICE.md`; the site links to both and makes no claim that dictionary assets share the code license.

Public site URL: https://alexfisenkov.github.io/MacSwitcher/.

## Learning release deployment · 2026-11-03

The alpha.25 download and learning disclosure sources passed the Pages workflow's static/JavaScript/public-download checks at `53e1f08add419bbc1c116d51fd2ddf4882dd5384`. The first deployment [41635185709](https://github.com/alexfisenkov/MacSwitcher/actions/runs/41635185709) was rejected before deployment steps: the `github-pages` environment does not allow the feature branch. Protection was not changed; at that point publication was still pending. App releases and the installed first-launch explanation had already been delivered independently.

The owner subsequently explicitly authorized merging PR #4 and publishing the site. PR #4 was retargeted to `main` and merged as `528e272c4ab208b0b4fd1062e47282e62d8e4f45`, preserving the already released ancestor stack. GitHub also recognized ancestor PRs #1–3 as merged. The application source and release artifacts remain unchanged; the new delta is website content, its checker and precise release documentation. Local browser checks passed at 1440×900 and 375×812 in both languages, including language switching, privacy/terms tabs, return navigation and overflow checks, with no console errors.

Publication [41648752742](https://github.com/alexfisenkov/MacSwitcher/actions/runs/41648752742) from that exact `main` commit passed both checks and deployment. The public [home page](https://alexfisenkov.github.io/MacSwitcher/), explicit index, legal page and product mark returned HTTP200 and byte-matched the deployed source. Main HTML SHA-256: `6041e30b3b092fab4e37f07132012028bcee514168e0e93f292282a4e230e436`; legal HTML: `ecd2075f22343cc0c48fdeeb4dd7bc96fa65a27d34a8924e9e751701b505f03d`. Public browser checks also passed at desktop/mobile widths: current Mac/Windows links, learning text, language switching and privacy/terms navigation, with no console errors. Stale Mac and Windows download links are rejected by isolated checker fixtures. Physical learning and the external editor/hardware matrix are unchanged separate acceptance items.

## Settings release delivery · 2026-11-04

Alpha.26 and the alpha.27 layout correction are released. PR5/PR6 are merged; executable alpha.27 source is `96fd8207499b111fd5f5b7d383575517ba237473`. [Pages41719711609](https://github.com/alexfisenkov/MacSwitcher/actions/runs/41719711609) deployed exact main `2fa744992df7a7421382245acf67f6076d271fd3`; public home/legal/product-mark bytes matched source. Downloads now point to Mac alpha.27 and Windows alpha.2, with the existing local-learning disclosure. Native settings were inspected after normal update; the original intermittent correction report remains an open product issue.

## Brand-context delivery · 2026-11-04

PR7 merged; Mac alpha.28 and Windows alpha.3 released from e57592474d19bf2e93b73740fc32683542acc879. [Pages41772148476](https://github.com/alexfisenkov/MacSwitcher/actions/runs/41772148476) deployed exact main0adb38050d8a59562d7c102f9d4ef78ad48787ac. Public home/legal/product mark byte-matched source. Both current releases and signed feeds were anonymously read back; Windows RSA feed accepted by the Core verifier. No website layout changes, only versioned download links/labels.


## Recovery-capacity publication · 2026-11-10

The owner explicitly authorized merging PR10, publishing alpha.30 and updating the site. PR10 merged as `2b1f52936556c69d033d92189ed2947199c21aa8`, preserving the earlier branch history. The release tag v0.1.0-alpha.30 points to the exact signed/CI executable source `f0717815adbf9a7c9b9cb22f06126734bf2224f4`; later commits update documentation and the signed feed only.

The public universal ZIP is42,971,684 bytes, SHA-256 `d441a12a9bbe39b8bde8ce6900a7b5aab0b5d4f0c1616d2278131b6435baa1cb`. Anonymous downloads of the ZIP, SHA256SUMS and release.json matched the prepared files. The normal public raw appcast matched its signed source byte-for-byte and passed Sparkle verification; version.json reports alpha.30/build30. Windows remains alpha.3.

[Pages42816504804](https://github.com/alexfisenkov/MacSwitcher/actions/runs/42816504804) passed check/deploy from exactmain `cca642f88d00ab869a9dcf8400d48f82394534c2`. Public home, legal page and SVG returnedHTTP200 and byte-matched that source. Home SHA-256: `2ea79e1c518a1beb9482812bcba822f6707dc499d3b2f4eb6a5612b51dc49cfd`; legal: `383ee182bb53b0fd9d079b7907bf6618eb48e6036366cbd5d666b7c15766a3a3`. Both languages point to Mac alpha.30; the privacy page describes optional macOS recovery backups, default OFF, possible full-field content, local permissions and retention. No layout changes. Physical repeated-gesture acceptance remains deferred; Spotlight/Campo and Terminal are separate follow-up work.

## Alpha.31 · historical pre-deployment note · 2026-11-13

На момент этой промежуточной записи публичный релиз уже был подтверждён, а remote feed и Pages ещё ожидали проверки. Итоговая запись о завершении опубликована ниже.


## Alpha.31 · публичная доставка подтверждена · 2026-11-13

Публичный подписанный feed `updates/appcast.xml` вернул HTTP 200, совпал побайтно с подготовленным feed (SHA-256 `f40c33ef107c19f2f4c4c238411e27d128b4acf25a28ba9788992e043c41f053`) и прошёл Sparkle verification; версия/build — 0.1.0-alpha.31/31. Pages run [43356600525](https://github.com/alexfisenkov/MacSwitcher/actions/runs/43356600525) завершился SUCCESS из точного source `dfe2d6785d2c34646177716849635f0a0aa6a85f`. Публичные home, legal и SVG вернули HTTP 200 и побайтно совпали с source. Release/source и assets описаны в [заметках alpha.31](releases/0.1.0-alpha.31.md). Владелец разрешил публикацию без представленного результата физической клавиатурной приёмки; она остаётся неподтверждённой. Windows alpha.3 без изменений.

## Alpha.32 · публичная доставка подтверждена · 2026-11-13

PR #12 слит, tag `v0.1.0-alpha.32` создан, пакет подписан/notarized и установлен; точные сведения есть в [заметках alpha.32](releases/0.1.0-alpha.32.md). `website/index.html` обновлён для этой версии, включая краткое пояснение, что окно настроек открывается инструкцией и содержит три вкладки. GitHub Release и три assets публично перечитаны и сверены с локальными файлами. Подписанный feed проверен по публичным байтам и подписи Sparkle. Pages run [43389847510](https://github.com/alexfisenkov/MacSwitcher/actions/runs/43389847510) завершился SUCCESS из source `c76c2d4c146175bd271c253c35eeb7d87b0b9466`. Публичные home/legal/SVG — HTTP 200 и byte-equal. Новый browser-render проход не выполнялся; static/JavaScript/download checks прошли.

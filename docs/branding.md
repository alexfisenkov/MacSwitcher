# MacSwitcher brand mark

The canonical product mark is `assets/MacSwitcher.svg`. Its two text glyphs are
read by `script/generate_icon.swift` when building `assets/MacSwitcher.icns`,
which the app bundle uses as its application icon and About-window image. The
website copy at `website/assets/MacSwitcher.svg` must remain byte-identical;
`script/check_website.py` checks that resource contract.

Keep the background, glyph tiles, arrows, colors, and overall geometry aligned
across SVG and ICNS. Functional language indicators in the menu bar are UI
controls, not the product mark. Branding acceptance confirms only mark
consistency; it does not establish keyboard behavior or physical-device
acceptance.

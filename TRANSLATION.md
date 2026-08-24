# Translating Switch

Switch uses Apple String Catalogs. Language follows the macOS system language. There is no in-app language picker.

Supported locales: `en` (source) and `zh-Hans` (Simplified Chinese). Other locales fall back to English.

## Files

- `Sources/Switch/Resources/Localizable.xcstrings` — UI, menus, alerts, Space names, key names
- `Sources/Switch/Resources/InfoPlist.xcstrings` — `NSAppleEventsUsageDescription` and `NSScreenCaptureUsageDescription`
- `Sources/Switch/Resources/<locale>.lproj/` — empty locale stubs so Xcode lists the language

Do not add `Localizable.strings`. Edit the catalogs in Xcode (or the same JSON in a PR).

## Adding a language

1. In Xcode, open `Localizable.xcstrings` and add the locale.
2. Do the same for `InfoPlist.xcstrings`.
3. Add `Sources/Switch/Resources/<locale>.lproj/.gitkeep` (no `.strings` files).
4. Translate in the catalog. Prefer a native-speaker PR that edits those two files only.

After changing the system language, quit and reopen Switch.

## Extraction

`project.yml` sets `SWIFT_EMIT_LOC_STRINGS` and `STRING_CATALOG_GENERATE_SYMBOLS`. Rebuild after adding `Text("…", comment:)` or `String(localized:comment:)` so new keys land in the catalog.

Interpolation keys must match Swift extraction:

- `"\(count) spaces"` → `%lld spaces`
- `"Desktop \(n)"` → `Desktop %lld`
- `"\(count) windows"` → `%lld windows` (vary by plural)

English plurals use `one` / `other`. Simplified Chinese uses only `other`.

## Do not translate

- Brand **Switch** (`shouldTranslate: false`)
- Window titles from apps, `app.localizedName`, filter text
- Shortcut glyphs (`⌘W`, `↵`, `⇧`) and F1–F12 / arrow symbols
- UserDefaults keys, CGS keys such as `"Current Space"`, process skip lists
- Internal sentinel `"Current"` (compared in code). Only the on-screen badge `CURRENT` is localized
- README (English product docs stay English)

## Glossary

| Term | Keep / prefer |
| --- | --- |
| Switch | Brand. Never translate. |
| Space | Mission Control Space. Do not replace with “desktop” unless the string is the generated name `Desktop %lld`. |
| Desktop N | User-visible Space name for a desktop Space. |
| Fullscreen | User-visible name for a fullscreen Space. |
| picker | The Switch overlay that lists windows. |
| sticky | Picker stays open after you release the modifier. Keep “sticky” if the language already uses it in this product sense; otherwise a short local equivalent is fine. |
| Space (key) | Keyboard Space bar. This catalog key is the key name, not Mission Control. |

## Info.plist

English usage strings stay in `Info.plist`. Translations live only in `InfoPlist.xcstrings`.

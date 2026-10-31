# Localization

The Mac app ships in English (the source language), German, French, Spanish, Japanese and
Simplified Chinese. macOS picks the language from System Settings ▸ General ▸ Language &
Region (per-app overrides included); there is no in-app setting.

## How it works

- One string table per language: `app/Resources/Localization/<lang>.lproj/Localizable.strings`,
  plus `InfoPlist.strings` for the privacy prompts in `app/Resources/Info.plist.in`.
- `scripts/build-app.sh` copies every `<lang>.lproj` into `Luxtable.app/Contents/Resources`,
  and `Info.plist` lists them in `CFBundleLocalizations`. Every target looks strings up in
  `Bundle.main`, so the code never passes a `bundle:` argument.
- Why plain `.strings` and not a String Catalog (`.xcstrings`), and why not per-target
  `Bundle.module` resources: the build needs only the Command Line Tools, which have no
  `xcstringstool` to compile catalogs. SwiftUI's `Text("…")` looks in `Bundle.main` unless
  told otherwise, so one table in the app bundle covers LuxtableCore, LuxtableUI and
  LuxtableMac without touching every view.
- The keys are the English text. The English table is generated from the code: the Swift
  compiler lists every localizable literal it compiles (`-emit-localized-strings`).
- Tests run in a host without the tables, so every string resolves to its English key and
  tests assert English text.

## Adding or changing a string

1. In a SwiftUI view, a literal is already localizable: `Text("Export")`, `Button("Cancel")`,
   `.help("…")`, `Toggle("…", isOn:)`. A `String` *variable* is shown verbatim, so:
   - in models and services (LuxtableCore), and for AppKit (`NSAlert`, menu items, panels),
     write `String(localized: "Moved \(count) photos to \(name)")`;
   - a helper view that only ever gets literals can take a `LocalizedStringKey`.
2. Interpolate only `String` and `Int` values (they become `%@` and `%lld`). Format a
   `Double` or a measurement to a `String` first: `String(localized:)` formats a `Double` as
   `%lf`, six decimals.
3. Do not localize log messages, identifiers, raw values, anything persisted (sidecars,
   JSON, `UserDefaults`), file names, URLs, or strings that code compares or parses
   (voice-command phrases have their own per-language tables).
4. Run `scripts/l10n.sh`. It builds with string extraction (in `app/.build-l10n`), adds the
   new keys to the English table, drops keys no longer used from every table, and prints how
   many keys each translation lacks.
5. Translate the new keys in each `<lang>.lproj/Localizable.strings` (sorted by key; an
   entry missing from a translation falls back to English at run time, but the checks fail).
   Keep every format specifier; reorder arguments with positions (`%2$@ … %1$lld`). Keep
   "Luxtable", keyboard shortcuts (⌘, ⇧, ⌥, ⌃), units and file formats as they are.

`scripts/test-app.sh` builds with the same extraction and runs `scripts/l10n.py check`: it
fails when a string in the code is missing from the English table, or a translation is
missing a key, has a stale one, or changes a format specifier. `LocalizationTests` checks
the tables themselves and that the bundle resolves each language.

## Terminology

Use the words mainstream photo apps use in each language (Apple Photos, Lightroom), and keep
them consistent across the table: for example Session (de *Session*, fr *session*, es
*sesión*, ja セッション, zh 会话), Pick/Reject (de *Auswahl/Abgelehnt*, fr *retenue/rejetée*,
es *elegida/rechazada*, ja 採用/不採用, zh 选取/拒绝), Export (de *Exportieren*, fr
*Exporter*, es *Exportar*, ja 書き出す, zh 导出). Grep the table for an existing translation
before choosing a new word.

## Adding a language

1. `mkdir app/Resources/Localization/<lang>.lproj` and copy the English
   `Localizable.strings` and `InfoPlist.strings` into it; translate the values.
2. Add `<string><lang></string>` to `CFBundleLocalizations` in `app/Resources/Info.plist.in`,
   and the language to `LocalizationTests` (`shipsTheDeclaredLanguages`, `everyKeyIsTranslated`).
3. Mention it in `docs/user-guide/01-install.md` (Language).
4. `scripts/test-app.sh`, then `scripts/build-app.sh` and check with
   `dist/Luxtable.app/Contents/MacOS/Luxtable -AppleLanguages '(<lang>)'`.

## Known limits

- No plural rules (`.stringsdict`): the code chooses singular or plural English text, and
  each is translated on its own.
- A few messages are assembled from fragments (smart-folder descriptions); each fragment is
  translated, so the word order follows English.
- Text from the Rust core (error details from the FFI) and from plug-ins stays as it is.

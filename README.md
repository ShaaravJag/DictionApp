# DictionApp

A free, fully local Wispr Flow–style dictation app for macOS. Hold the 🎤 key, talk naturally, and let go. Punctuated text then appears in whatever app you're typing in.

- **Speech-to-text:** Parakeet (via [FluidAudio](https://github.com/FluidInference/FluidAudio)) on the Apple Neural Engine. Nothing leaves your Mac.
- **Hotkey:** the MacBook 🎤 dictation key, remapped to F18 with `hidutil` while the app runs. Fn, right ⌥ and right ⌘ also work.
- **Insertion:** clipboard + ⌘V, after which your previous clipboard is restored.

## Use

| Action | What happens |
|---|---|
| Hold 🎤, speak, release | Text is pasted at the cursor |
| Double-tap 🎤 | Hands-free mode. Tap again to finish |
| Esc while recording | Cancel |

The menu bar icon has: last dictation (paste/copy), hotkey choice, speech model, filler-word removal, spoken punctuation, smart spacing, per-app writing style, vocabulary, contact names, sounds, launch at login.

## Formatting

- **Automatic punctuation** comes from the speech model.
- **Spoken punctuation** works on top of it: say "comma", "period", "question mark", "exclamation point", "colon", "semicolon", "new line", "new paragraph", "open/close quote", "open/close paren", "em dash", or "dot dot dot".
- **Smart spacing & capitalization** reads the text around the cursor (via Accessibility). It adds the space after the previous sentence and lowercases when you're mid-sentence. For apps that hide their text, it remembers what it last pasted.
- **Numbers as digits** (every app): six → 6, twenty five → 25, three a m → 3am, three thirty p m → 3:30pm, five dollars and fifty cents → $5.50, ten percent → 10%, three point five → 3.5, twenty twenty six → 2026, five million → 5 million. "one" stays a word unless it's clearly a number ("no one", "one more thing"). Ordinals (first, second) stay words.
- **Per-app styles:** Casual (all lowercase, acronyms kept, only the punctuation you say) is preset for Messages. The model's own commas, periods and question marks are removed there; "comma", "question mark", "period" still work. Any app can be set from the menu.

## Your vocabulary

Menu → **Edit Vocabulary…** opens `~/Library/Application Support/DictionApp/Vocabulary.md`. It reloads as soon as you save.

```markdown
## Words          names, places, brands. Every app.
Anirudh | Anirud      ← after the | : what it comes out as; always swapped back

## Slang          only in Casual apps (Messages)
fuh

## Replacements   every app
gonna -> going to
```

- Words and names are **listened for**: a second small model (Parakeet CTC 110M, ~100 MB, downloaded once) checks the audio for your terms and fixes near-misses ("Sharav" → "Shaarav"). It only runs when the transcript has something close to one of your terms (~+80 ms).
- **Use Contact Names** (menu) adds first, last and nicknames from Contacts that the dictionary doesn't know (Indian and unusual names, uncommon spellings). Phonetic names in Contacts are used as hints. Stays on this Mac and refreshes when Contacts changes.
- Short slang that sounds like a common word ("fuh" vs "for") can't be told apart by sound. Use a swap (`fuh | for`) if you want it.

## Build & install

```bash
scripts/install.sh      # Release build → /Applications/DictionApp.app
```

The first launch downloads the speech model (~600 MB, one time) and asks for **Microphone** and **Accessibility** access.

## Layout

```
Packages/DictationCore/   shared engine (audio, transcription, formatting), reused by iOS later
DictionMac/               macOS menu bar app (hotkey, overlay, paste)
project.yml               XcodeGen spec (run `xcodegen generate` after adding files)
```

## Tests

```bash
cd Packages/DictationCore
swift test                                                      # unit tests
DICTATION_E2E=1 swift test --filter TranscriberIntegrationTests # real model end-to-end
```

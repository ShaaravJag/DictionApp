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

The menu bar icon has: last dictation (paste/copy), hotkey choice, speech model, filler-word removal, spoken punctuation, smart spacing, per-app writing style, sounds, launch at login.

## Formatting

- **Automatic punctuation** comes from the speech model.
- **Spoken punctuation** works on top of it: say "comma", "period", "question mark", "exclamation point", "colon", "semicolon", "new line", "new paragraph", "open/close quote", "open/close paren", "em dash", or "dot dot dot".
- **Smart spacing & capitalization** reads the text around the cursor (via Accessibility). It adds the space after the previous sentence and lowercases when you're mid-sentence. For apps that hide their text, it remembers what it last pasted.
- **Per-app styles:** Casual (all lowercase, acronyms kept, no automatic final period) is preset for Messages. Any app can be set from the menu.

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

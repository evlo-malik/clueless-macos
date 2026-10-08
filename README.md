# clueless

A floating assistant for macOS. Liquid Glass on macOS 26, a plain material on earlier systems. No Dock icon.

The panel sets `sharingType = .none`, so screenshots and screen sharing don't include it. The eye button in the overlay turns that off if you want the panel in the recording.

Chat goes through [OpenRouter](https://openrouter.ai). Paste any model id. Screenshots need a vision model. Audio sessions transcribe with a second model (Whisper by default).

## Build

Xcode 16 or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open Clueless.xcodeproj
```

Pick your own signing team in the Clueless target, then run the scheme. ⌘\\ shows the panel. It starts in the top-right.

## Setup

1. Settings → OpenRouter, paste an API key. It goes in the Keychain, not a file.
2. Settings → Models if you don't want the defaults (`openai/gpt-5.6-luna` for chat, `openai/whisper-large-v3-turbo` for transcription).
3. Grant Screen Recording for screenshots and system audio, and Microphone for voice. After changing Screen Recording, quit and reopen.

## Shortcuts

| Keys | Action |
| --- | --- |
| ⌘\\ | Show or hide the overlay |
| ⌘R | Clear the chat |
| ⌘Return | Capture the screen and ask, even if another app is in front |

The rest is in the panel: attach the screen to each message, start or stop an audio session, settings, hide, quit.

## Layout

```
Sources/Clueless/
├── CluelessApp.swift
├── AppDelegate.swift
├── Overlay/          panel, SwiftUI HUD
├── Hotkeys/          Carbon hotkeys, no Accessibility permission
├── Capture/          screenshots, mic, system audio
├── AI/               chat and the listen session
├── Detection/        capture check
├── Persistence/      optional launch-at-login agent
└── Services/         Keychain, settings, OpenRouter client
```

## License

MIT. See [LICENSE](LICENSE).

# BYOKchat

BYOKchat is an iOS-only, BYOK-only AI chat client under active development.

## Current Phase 1 slice

The repository now contains an independent Swift provider core with first-class presets for:

- DeepSeek
- OpenRouter
- NVIDIA

Implemented foundations:

- OpenAI-compatible one-shot generation
- Native SSE streaming on Apple platforms
- Visible text and reasoning separation
- Stream usage events
- Mid-stream provider error handling
- Cancellation propagation
- Model discovery with bundled seed fallback
- DeepSeek thinking controls
- OpenRouter reasoning and provider-routing controls
- OpenRouter generation metadata capture
- NVIDIA hosted API preset
- Provider registry with stable string IDs
- Credential vault protocol and Apple Keychain implementation
- XcodeGen iOS 26 scaffold
- Debug provider console

## Local validation

```sh
swift test
```

On macOS with XcodeGen installed:

```sh
xcodegen generate
open BYOKchat.xcodeproj
```

The debug app requires your own provider key. No live credentials are committed.

## Important

BYOKchat does not use AppFoundation's AI provider management. AppFoundation may later be used only for approved non-AI UI infrastructure.

# Changelog

## [0.9.1] - 2026-04-17

### Added
- **Fn + Option** as the default AI Agent hotkey — fresh installs now have a working AI trigger out of the box (v0.9.0 shipped with AI hotkey defaulting to `None`, which made the feature appear broken).
- **Screen Recording** permission row in Settings → Permissions with a direct deep-link to the Screen & System Audio Recording pane (the generic "Privacy & Security" landing page required hunting).
- **Permission gate on AI Agent start**: when the selected model supports vision and Screen Recording access is missing, an in-app alert opens with a one-click "Open Settings" button that jumps straight to the right pane — recording is held off until access is granted.

### Fixed
- AI Agent hotkey silently failing when set to the same combo as the Record hotkey (the event tap delivered the press once and the STT state machine claimed it, leaving AI silent). The picker now greys out the reserved option in both roles and refuses to let them collide.
- Hotkey picker list was unordered; now grouped single-keys → combos → None so the dropdown scans from "likely" to "less likely".
- `Fn` single-key option rendered with an empty symbol in the picker — now shows `fn`.

### Internal
- `scripts/release.sh` — one-shot version bump / squash-merge / tag / DMG / GitHub Release pipeline, with preflight checks (branch, working tree, CHANGELOG section, tag existence) and automated notarization setup from `.env` when the keychain profile is missing.

## [0.9.0] - 2026-04-17

### Added
- **AI Agent**: contextual reply assistant triggered by a dedicated hotkey — hold, speak your intent, release, and a reply is generated from what's on your screen.
- **Built-in agents**: Email (with template, sign-off, and recipient extraction), Instant Message (short-form replies for iMessage/WeChat/Slack DM/Discord), and Assistant (generic fallback).
- **Auto agent routing**: picks the right agent based on the frontmost app's bundle ID (Apple Mail, Outlook, Spark, Slack, WhatsApp, Discord, iTerm, etc.) or the browser window title (Gmail, Outlook Web, GitHub, and so on).
- **Manual agent mode**: pin a specific agent if Auto's choice isn't what you want.
- **Copy Last Transcription** (⇧⌘C) and **Retry Last Transcription** menu items — recover or regenerate the most recent recording without reopening History.
- **Multi-provider AI backend**: Ollama (local), OpenRouter, Google Gemini, Local CLI, and Custom OpenAI-compatible endpoints. Per-provider API key stored in the macOS Keychain.
- **Support for new Google AI Studio API keys** (AQ.* prefix): Gemini now routes through the native `/v1beta/models/*:generateContent` endpoint with `x-goog-api-key` header auth.
- **Email agent recipient extraction**: 4-tier priority — person's first name → name mentioned in voice intent → "Hi [Company] team," for noreply/support senders → "Hi there,".
- **Multi-language email replies**: sign-off and body match the chosen output language ("Match conversation" by default; individual agents can be pinned to English / Chinese / Japanese / etc.).

### Changed
- **Thinking mode disabled by default** for AI replies across all providers (Gemini `thinkingBudget=0`, OpenRouter `reasoning.effort=low`, Ollama `think=false`) — 3-10x latency improvement for short pattern-matched replies.
- **Prompt architecture refactored**: shared output / context / language rules are composed at runtime; each agent's prompt now contains only its unique specialization, no boilerplate repetition.
- **AI Agent Settings UI**: toggles and buttons use consistent control sizes, matching the rest of Settings.
- **History Settings UI**: aligned Open / Show-in-Finder buttons, Auto-delete picker disables when Save History is off, "Never" retention caption no longer claims files are auto-removed.

### Fixed
- **AI reply overlay height stable across states**: pill no longer jumps between recording, generating, and error states.
- **Sender name (`{sender_name}`) substitution** now holds even in non-English replies — post-processing guard catches any unsubstituted template tokens.
- **Explicit `outputLanguage` override** (e.g. "always English") defeats strong source-language context from the screenshot.
- **Agent state cleanup**: `aiSelectedAgent` is cleared on every terminal state transition so stale agent state can't leak into the next session.
- **Gemini "Test Connection"** uses the native endpoint instead of the OpenAI-compat shim (which rejects new AQ.* keys).

### Removed
- **Code agent**: collapsed into Assistant — serious coding work belongs in Claude Code / Cursor, not a push-to-talk reply assistant.

### Internal
- Post-v0.8.3 audit closed 3 HIGH / 1 MEDIUM findings around Gemini auth, agent routing, and stale state.
- Diagnostic logging for agent selection and language-rule composition.
- Real company / vendor / trade-show names and the hardcoded sender name scrubbed from shipped prompts and the A/B test harness — placeholders now used.

## [0.2.0] - 2026-03-05

### Added
- Context Awareness: capture selected text (Accessibility API) and browser URL (AppleScript) before recording
- Smart Text Replacements: voice commands like "换行" → newline, "句号" → 。 with regex support
- Replacements management UI in Settings (add/delete/edit, reset to defaults)
- Personal Dictionary (P1)
- Power Mode — per-app configuration profiles (P1)
- AI Text Enhancement via Ollama with Cmd+E manual trigger (P1)
- LaunchAtLogin, Sparkle auto-update, media pause during recording (P0)

### Changed
- Text processing pipeline: STT → Smart Replacements → Dictionary → AI Enhancement → Paste
- Settings window enlarged to accommodate new tabs
- Version bumped to 0.2.0

## [0.1.0] - 2026-03-05

### Added
- Push-to-talk voice input (Option+Space) with system-wide text injection
- Chinese-first speech recognition powered by FunASR MLX (SenseVoice)
- Support for Chinese, English, Japanese, Korean, and Cantonese
- Menu bar app with recording status indicator and animation
- Sound feedback for recording start/stop
- Python STT server with automatic lifecycle management
- Health check and auto-reconnection to STT server
- One-click install script (`scripts/install.sh`)
- DMG packaging script (`scripts/make-dmg.sh`)

### Technical
- Swift (SwiftUI + AppKit) frontend with Python (FastAPI) backend
- MLX acceleration on Apple Silicon (Neural Engine + GPU)
- ~0.5s transcription latency on M-series chips
- 100% offline — no data leaves your Mac

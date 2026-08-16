# Security Policy

## Supported versions

Only the latest release receives fixes. Please upgrade before reporting.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report privately through GitHub's
[private vulnerability reporting](https://github.com/Jason-Kou/zhiyin/security/advisories/new).
If that is unavailable to you, reach out via [@AgentLabX](https://x.com/AgentLabX)
and ask for a private channel.

Please include the version, macOS version, and the steps to reproduce. Expect a
first response within a week — this is a small project, not a staffed security team.

## What ZhiYin can access

ZhiYin holds unusually broad permissions, so it is worth being explicit about what
they are used for:

| Permission | Why | Scope |
|---|---|---|
| Microphone | Recording speech to transcribe | Only while the hotkey is held — there is no always-listening mode |
| Accessibility | Global hotkey capture, and simulating Cmd+V to paste the result | Keyboard events are inspected for the configured hotkey only |
| Screen Recording | AI Agent reads the frontmost window to draft a contextual reply | Only when the AI Agent hotkey is used, and only if the feature is enabled |

Transcription runs entirely on-device; audio never leaves the machine. Recordings
and transcripts are stored unencrypted under `~/.zhiyin/recordings/` and can be
disabled or auto-expired in Settings → History.

The **AI Agent is the one feature that can send data off-device.** When configured
with a remote provider (OpenRouter, Google Gemini, or a custom OpenAI-compatible
endpoint), your spoken intent and a screenshot of the frontmost window are sent to
that provider. Choosing Ollama or a local CLI keeps everything on-device. API keys
are stored in the macOS Keychain.

## Scope

In scope: privilege escalation, unintended network transmission of audio or screen
contents, key or token disclosure, and code execution via crafted model or config
files.

Out of scope: usage limits and licence enforcement. ZhiYin is free and unlimited —
there is nothing to bypass, so there is nothing to report here.

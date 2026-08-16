# Contributing to ZhiYin

Thanks for taking the time. ZhiYin is a small project — issues and pull requests
are both welcome, and you do not need to ask permission before opening either.

## Before you start

ZhiYin only runs on **macOS 14.0+ with Apple Silicon**. The speech engine is built
on [MLX](https://github.com/ml-explore/mlx), which is Metal-based and has no Intel
or Windows equivalent, so there is currently no way to develop or test on other
hardware.

## Setting up

```bash
git clone https://github.com/Jason-Kou/zhiyin.git
cd zhiyin
./scripts/install.sh     # Python venv + dependencies + model download (~1.5GB, one time)
./scripts/run-dev.sh     # build, bundle, and launch with console output
```

`run-dev.sh` runs the app in the foreground and prints both the Swift and Python
logs, which is where you want to be while developing. Add `--rebuild` to force a
full Swift rebuild.

To stop a stuck instance:

```bash
pkill -f zhiyin; lsof -ti:17760 | xargs kill
```

### How the two halves fit together

Swift owns the UI, audio capture, hotkeys, and text injection. Python runs the STT
inference server on `127.0.0.1:17760`, started and stopped by the Swift app as a
child process. They talk over HTTP. `docs/vad-streaming-architecture.md` explains
the streaming and sentence-segmentation design.

Dev builds resolve their interpreter through `~/.zhiyin/venv`. `install.sh` creates
it; if that path is a dangling symlink the app will say so on startup and clear it.

## Testing

There is no unit test suite. For anything touching transcription, run the streaming
harness against a real recording:

```bash
./scripts/run-dev.sh                                    # in one terminal
python/test_streaming.py ~/.zhiyin/recordings/<file>.wav # in another
```

It checks full-file transcription, streaming transcription, the hallucination
filter, and that streaming captured everything the full pass did. Your own
recordings land in `~/.zhiyin/recordings/` as you use the app.

**Please include before/after output from this harness in any PR that changes STT
behaviour.** Model and VAD parameters interact in non-obvious ways, and a change
that helps one language often hurts another.

## Pull requests

- Keep changes small and focused. One concern per PR.
- Commit messages in English, [Conventional Commits](https://www.conventionalcommits.org/)
  style — `fix(hotkey): ...`, `feat(ai): ...`, `docs: ...`.
- Do not bundle unrelated refactoring into a behaviour change.
- Update `CHANGELOG.md` under an `## [Unreleased]` heading if the change is
  user-visible.

### Things worth knowing before you touch them

- **MLX is not thread-safe.** All transcription runs on a single-thread executor in
  `stt_server.py`. Do not widen it.
- **Model parameters are tuned.** `mlx-community/Fun-ASR-MLT-Nano-2512-8bit` and the
  VAD thresholds were arrived at empirically; changing them needs harness evidence.
- **The `mlx-audio` 0.2.10 wheel ships without its `funasr` module.** A patched copy
  lives at `python/vendor/funasr/` and is restored automatically by `install.sh`,
  `make-dmg.sh`, and the app's own venv bootstrap. If you upgrade `mlx-audio`, check
  whether this is still needed.
- **Two copies of the dependency list exist** — `scripts/install.sh` and `pipDeps` in
  `ZhiYinApp.swift`. Change both.

## Reporting bugs

Use the issue templates; they ask for the chip, macOS version, and console output,
which is almost always what a diagnosis turns on. Console output comes from running
`./scripts/run-dev.sh` and reproducing the problem.

## License

ZhiYin is GPL-3.0. Contributions are accepted under the same license — by opening a
pull request you agree your work may be distributed under GPL-3.0.

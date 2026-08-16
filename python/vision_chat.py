"""Built-in vision-language chat, so the AI Agent works without external setup.

Before this, using the AI Agent meant installing Ollama or an MLX server, then
typing an endpoint and an exact model id into Settings. Most people will not do
that, and getting any of it subtly wrong fails in ways that look like the app is
broken — a text-only model silently drops the screenshot, a mistyped id returns
404, a 9B model on modest hardware times out.

The STT model already downloads itself from Hugging Face on first use. This gives
the language model the same treatment: pick it in Settings, it downloads once,
and there is no endpoint, port, or API key anywhere.

Runs on the caller's executor. MLX is not thread-safe, so vision inference shares
the single transcription thread — a reply and a transcription cannot overlap,
which is fine for push-to-talk but is the reason this module never spawns its own.
"""

from __future__ import annotations

import base64
import os
import re
import tempfile
import time

# Loaded on first use rather than at startup: most sessions never ask for a reply,
# and this model is several GB.
_model = None
_processor = None
_config = None
_loaded_repo: str | None = None

DEFAULT_REPO = "mlx-community/Qwen3-VL-8B-Instruct-4bit"


def is_loaded(repo: str | None = None) -> bool:
    if _model is None:
        return False
    return repo is None or _loaded_repo == repo


def load_vision_model(repo: str = DEFAULT_REPO):
    """Load (downloading on first call) the vision-language model."""
    global _model, _processor, _config, _loaded_repo
    if _model is not None and _loaded_repo == repo:
        return

    from mlx_vlm import load
    from mlx_vlm.utils import load_config

    print(f"Loading vision model: {repo}")
    t0 = time.time()
    _model, _processor = load(repo)
    _config = load_config(repo)
    _loaded_repo = repo
    print(f"Vision model ready ({time.time() - t0:.1f}s).")


def unload_vision_model():
    """Free several GB when the feature is switched off."""
    global _model, _processor, _config, _loaded_repo
    _model = _processor = _config = None
    _loaded_repo = None


_DATA_URL = re.compile(r"^data:image/[a-zA-Z]+;base64,(.+)$", re.DOTALL)


def _extract(messages: list) -> tuple[str, str | None, list[str]]:
    """Split OpenAI-style messages into (prompt, system, image paths on disk).

    mlx-vlm reads images from paths, so any inline base64 is written to a temp
    file. Callers are responsible for nothing; the files are cleaned up below.
    """
    system: str | None = None
    parts: list[str] = []
    images: list[str] = []

    for msg in messages:
        role = msg.get("role")
        content = msg.get("content")

        if role == "system":
            if isinstance(content, str):
                system = content
            continue

        if isinstance(content, str):
            parts.append(content)
            continue

        for item in content or []:
            if item.get("type") == "text":
                parts.append(item.get("text", ""))
            elif item.get("type") == "image_url":
                url = (item.get("image_url") or {}).get("url", "")
                m = _DATA_URL.match(url)
                if m:
                    fd, path = tempfile.mkstemp(suffix=".jpg", prefix="zhiyin_vlm_")
                    with os.fdopen(fd, "wb") as f:
                        f.write(base64.b64decode(m.group(1)))
                    images.append(path)
                elif url.startswith("/") and os.path.exists(url):
                    images.append(url)

    return "\n\n".join(p for p in parts if p), system, images


def chat(messages: list, max_tokens: int = 512, repo: str = DEFAULT_REPO) -> str:
    """Answer an OpenAI-style message list. Blocking; call on the executor."""
    load_vision_model(repo)

    from mlx_vlm import generate
    from mlx_vlm.prompt_utils import apply_chat_template

    prompt_text, system, images = _extract(messages)
    if system:
        prompt_text = f"{system}\n\n{prompt_text}"

    try:
        prompt = apply_chat_template(
            _processor, _config, prompt_text, num_images=len(images)
        )
        out = generate(
            _model, _processor, prompt, images, max_tokens=max_tokens, verbose=False
        )
    finally:
        for p in images:
            if "zhiyin_vlm_" in p:
                try:
                    os.unlink(p)
                except OSError:
                    pass

    text = out if isinstance(out, str) else getattr(out, "text", str(out))
    return text.strip()

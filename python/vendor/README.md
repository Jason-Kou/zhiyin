# Vendored third-party code

Code here is not written or maintained by ZhiYin. It is copied in verbatim because
an upstream package does not ship it.

## `funasr/`

The FunASR speech-recognition model implementation for MLX.

**Why it is here.** The `mlx-audio==0.2.10` wheel on PyPI is missing
`mlx_audio/stt/models/funasr/`, even though the package's own loader imports it.
Installing `mlx-audio` from PyPI therefore produces a venv that cannot run ZhiYin's
STT engine. This directory holds the module so it can be restored after install.
Three places copy from it, all checking for the module before writing:

- `scripts/install.sh` — dev setup
- `scripts/make-dmg.sh` — release packaging
- `AppDelegate.patchFunasrModule` in `ZhiYin/Sources/App/ZhiYinApp.swift` — the app's
  own venv bootstrap

If a future `mlx-audio` release ships the module, all three become no-ops and this
directory can be deleted.

**Provenance.** Taken from `mlx-audio` 0.2.10, path
`mlx_audio/stt/models/funasr/`. Unmodified — do not edit these files. Upgrade by
replacing them wholesale from a newer upstream.

**Copyright**, as stated in the file headers:

```
Copyright © 2025 FunASR (original model implementation)
Copyright © Anthony DePasquale (MLX port)
Ported to MLX from https://github.com/modelscope/FunASR
```

**License.** MIT, in both directions: [`mlx-audio`](https://github.com/Blaizzy/mlx-audio)
is MIT (Copyright © 2024 Prince Canuma — text in [`funasr/LICENSE`](funasr/LICENSE)),
and the [FunASR](https://github.com/modelscope/FunASR) toolkit it was ported from is
MIT as well. MIT is compatible with ZhiYin's GPL-3.0 license.

Note that FunASR licenses its *pretrained model weights* separately from the toolkit
source. No weights are vendored here — ZhiYin downloads them from Hugging Face at
first launch.

The file headers point at `licenses/funasr.txt`, a path that upstream does not
actually ship in the wheel. The links above are the authoritative terms.

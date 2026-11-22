# AI Upscale model

`build-model.sh` builds the bundled RealESRGAN_x2plus float16 package. It uses `convert.py`, `rrdbnet.py` and the AI Denoise model's hash-locked `requirements.txt` (`../denoise-model/`). `template.py` writes the template (`app/Resources/UpscaleModel`) the app converts the authors' release checkpoint with, in builds that don't bundle the model. `LICENSE-Real-ESRGAN` is the upstream BSD 3-Clause licence.

Sources, pins, cache, reproducibility and runtime checks are in [docs/UPSCALE_MODEL.md](../../docs/UPSCALE_MODEL.md).

# AI Upscale model

AI Upscale runs RealESRGAN_x2plus as a Core ML float16 package, `LuxtableUpscale.mlpackage`. Its training data (DIV2K, Flickr2K, OST) is licensed for non-commercial research, so builds don't bundle it by default and Luxtable doesn't distribute it: on the user's request the app downloads the authors' release checkpoint and converts it on their Mac (see Download). `LT_BUNDLE_UPSCALE=1 scripts/build-app.sh` builds it from source and bundles it in `Luxtable.app/Contents/Resources/Models/`, next to the AI Denoise model, for personal builds.

| | |
|---|---|
| Network | RealESRGAN_x2plus (RRDBNet, 23 blocks, 2×). Wang, Xie, Dong, Shan, *Real-ESRGAN: Training Real-World Blind Super-Resolution with Pure Synthetic Data*, ICCVW 2021 |
| Architecture | RRDBNet of xinntao/BasicSR (`basicsr/archs/rrdbnet_arch.py`), rewritten for tracing in `scripts/upscale-model/rrdbnet.py` |
| Weights | `RealESRGAN_x2plus.pth` from github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1, SHA-256 `49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb` |
| Licence | BSD 3-Clause, © 2021 Xintao Wang (RRDBNet: BasicSR, Apache 2.0). It ships in the app as `Contents/Resources/Acknowledgements.md` (`app/Resources/Acknowledgements.md`) |
| Input / output | `input` `[1, 3, 256, 256]` → `output` `[1, 3, 512, 512]`, float16, planar RGB, sRGB-encoded 0..1 |
| Converted weights | `Data/com.apple.CoreML/weights/weight.bin`, SHA-256 `d43bffce05fa1714f1a50e6ef19780f0ef5453a7e9448875316a4d564f46a310`, 33,451,648 bytes |

## Build

With `LT_BUNDLE_UPSCALE=1`, `scripts/build-app.sh` calls `scripts/upscale-model/build-model.sh`, which works like the AI Denoise model's (`docs/DENOISE_MODEL.md`):

1. **Cache check.** `~/.cache/luxtable/models/<upstream weights SHA-256>/<stamp>/LuxtableUpscale.mlpackage`, the stamp hashing `build-model.sh`, `convert.py`, `rrdbnet.py` and the requirements. `LT_MODEL_CACHE` overrides the location; concurrent builds take turns on the same lock.
2. **Venv.** The AI Denoise model's venv and hash-locked `scripts/denoise-model/requirements.txt` (torch 2.14.1, coremltools 9.0, numpy 2.5.3).
3. **Convert.** `convert.py`:
   - downloads the pinned weights to a temporary name, renames them when complete, and checks their SHA-256 (a cached copy that doesn't match is downloaded again, once);
   - loads `params_ema` strictly (only the fixed unshuffle weights are not in the checkpoint) and checks that the rewritten pixel unshuffle equals PyTorch's;
   - converts to float16 with a fixed 256² input;
   - checks Core ML against PyTorch float32 on the GPU and the Neural Engine (max error 0.017 and 0.031, RMSE 0.0008 and 0.0015, limits 0.05 / 0.005);
   - checks that the converted weights hash to the pinned `EXPECTED_WEIGHTS_SHA256`.
4. **Bundle.** The package is copied into the app, which grows by about 33 MB.

Without `LT_BUNDLE_UPSCALE=1`, or with `LT_SKIP_MODELS=1`, it is skipped. A build without Python 3.13 or network, or with a failed check, prints a warning and still succeeds without the model.

### The pixel unshuffle

The x2 model packs each 2×2 block into 12 channels before its first convolution (`F.pixel_unshuffle`), a 6-D reshape. `rrdbnet.py` does it as a stride-2 convolution with fixed 0/1 weights instead: exact, and it keeps the network on the Neural Engine.

## Download

When the build doesn't bundle the model, Photo ▸ Enhance offers **Download AI Upscale Model…** instead of Upscale 2× (export recipes resample until then, and say why).

1. **Ask.** An alert states where the model comes from, its licence and its training-data terms (`UpscaleModelDescriptor.downloadNotice`); nothing is fetched unless the user agrees.
2. **Fetch.** The release checkpoint `RealESRGAN_x2plus.pth` (67 MB, the Weights row above) is downloaded from its authors' GitHub release into a staging folder `<support>/Models/.upscale-download-<uuid>/` and must match its pinned SHA-256 (`UpscaleModelDescriptor.checkpointSHA256`, the same as `convert.py`'s). The menu item shows the progress and cancels the download.
3. **Convert.** `UpscaleConversion` builds the Core ML package from the checkpoint in the staging folder, with the template the app ships (`Contents/Resources/UpscaleModel`, from `app/Resources/UpscaleModel`):
   - `recipe.json` says where each tensor of `weight.bin` lies in the checkpoint. Each is written in float16 into Core ML's blob storage; the `conv5` tensors are multiplied by 0.2 first (the residual scale, which the conversion folds in), and the pixel unshuffle's fixed weights are a constant in the recipe.
   - `model.mlmodel` is the converted package's model spec with the one trained tensor it holds inline (`conv_last.bias`, three values) zeroed; the conversion writes it back from the checkpoint.
   - `Manifest.json` is the package's manifest.

   The result must be the pinned conversion bit for bit: the weights are checked against `weightsSHA256` and the model spec against `specSHA256`. The template holds none of the trained weights, so Luxtable distributes none.
4. **Install.** The checked package is moved to `<support>/Models/LuxtableUpscale.mlpackage` in one rename (a damaged earlier copy is swapped out with `replaceItemAt`), so a cancel or a failed check leaves nothing installed. The staging folder, and the checkpoint in it, is removed. A staging folder a crash leaves behind is removed at the next launch; other models' sweeps of `.download-*` never touch it. From then on the model is used like a bundled one: checked against `weightsSHA256` on first use and compiled once. A downloaded copy that fails that check is offered for download again.

**Where from.** `UpscaleModelDescriptor.checkpointURL`: `github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth`. The `LT_UPSCALE_MODEL_URL` environment variable names another `https://` URL of the same file (a mirror); other schemes and redirects off https are refused. A build without the template (`swift run`, tests) doesn't offer the download, and Upscale 2× says the model isn't included.

**Regenerating the template.** After a change to the conversion (`convert.py`, `rrdbnet.py`, the requirements), run `scripts/upscale-model/template.py <package> <checkpoint> app/Resources/UpscaleModel` in the model venv, with the package `scripts/upscale-model/build-model.sh` prints. It stops unless the recipe rebuilds the package's `weight.bin` exactly, and prints the pins for `UpscaleModelDescriptor` (`specSHA256` changes with each conversion; the weights reproduce bit for bit).

## Speed (M4 Pro, 256² tiles in, 512² out)

| Compute units | ms per tile |
|---|---|
| GPU | 77 |
| Neural Engine | 37 |

A 24 MP A9 frame is 468 tiles (26 × 18, overlapping by at least 24 px). End to end (`UpscaleLiveTests`, an ISO 4000 sample, GPU and Neural Engine side by side, model already loaded): **12.5 s** to a 12000×8000 DNG of 550 MB, peak RSS +839 MB for the whole test process. First use adds ~2.7 s (checksum, compile, load). 512 px renders of the original and the upscale differ by 3/255 on average.

## The new photo (Photo ▸ Enhance ▸ Upscale 2×)

- **Input.** The full-resolution BASE (RCD at the reference white balance), sRGB-encoded, the same as AI Denoise (`lt_pipeline::upscale`, `UpscaleJob::from_raw`).
- **Tiles.** 256² in, 512² out, cross-faded with linear ramps over each overlap (the denoiser's ramps, scaled 2×; 8 output px at each tile edge get no weight). Rows are handed out as soon as every tile covering them is written, so the output is never held whole: about two tile rows (≤ 1024 output rows; ~150 MB for 24 MP, ~230 MB for 60 MP) plus the encoded input (6 bytes per input pixel).
- **Clipped pixels** (a channel at the clip after white balance, which the model can't see past) take the original, interpolated.
- **Output.** A linear DNG (`lt_export::dng`): uncompressed `LinearRaw`, 3 × 16 bits, linear camera RGB before white balance, written strip by strip as the rows arrive. Its colour tags make it decode to the source's `cam_to_xyz`, as-shot and daylight white balance, so it develops like the original. It carries the source's orientation, default crop (×2), EXIF (camera, lens, exposure, capture time, GPS) and embedded JPEG preview.
- **Where.** Next to the original, `<name>-Upscaled.dng`, or the first `-N` free both on disk and in the session (a photo whose file was deleted keeps its name); an existing file is never replaced. It is written to a hidden temp file (`.lt-*.partial`), fsync'd and renamed. A cancel before the rename leaves nothing; once placed, the photo is always added (or, if the session refuses it, the file is removed). A temp file a crash left behind is removed when the session's folder is next read, once it is an hour old; the archive never copies it (`--exclude=*.partial`).
- **In the session.** Added as a new photo (`Session::add_derived`) starting with the source's adjustments and IPTC metadata (title, caption, credits, rights; no undo step), and focused. HDR and panorama merges take the first selected photo's metadata the same way. Its pixel radii (sharpening, clarity) act at the new resolution.
- **Size.** Up to 256 MP out (a 64 MP original): the DNG is 6 bytes per output pixel (576 MB for 24 MP).
- **Cancel.** Stops after the tiles in flight; photos already done stay.

## Export (recipe ▸ AI Upscale)

A recipe with AI Upscale may enlarge. When its size is larger than the render, the render (output-encoded 16-bit RGB) goes through the model 2× first (`UpscaleJob::from_encoded`, the app's `UpscaleProvider`, on the Neural Engine) and is then resized to the size. That holds one more image of 4× the render's pixels, so a batch with AI Upscale runs one worker (60 MP: render 360 MB + the model job's sink 1.44 GB + band ≈ 0.2 GB, its f16 input of 360 MB released after the last tile is read; then the 2× image is the working copy at 200 % or is resized from, +0.8 GB at 150 %: about 2.4–2.6 GB peak, against 6–7 GB with two workers and a copy). A render over 64 MP (2× past 256 MP) is resampled. Without the model in the build (or no provider) the render is resampled as with Allow upscaling; a model failure fails that photo; cancelling the export cancels the run.

## Runtime

- **Loading.** The app takes `Models/LuxtableUpscale.mlpackage` from its bundle, or else the downloaded `<support>/Models/LuxtableUpscale.mlpackage`, checks the weights against `UpscaleModelDescriptor.weightsSHA256` (a test keeps it equal to `convert.py`'s), and compiles it once into `<support>/Models/`.
- **No model yet.** The menu offers the download (above); without the conversion template Upscale 2× is disabled with "AI Upscale model not included in this build."; export recipes resample either way.
- **Checksum mismatch.** The model is refused and never compiled; Upscale 2× is disabled with the reason.

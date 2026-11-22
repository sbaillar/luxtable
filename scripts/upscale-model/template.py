"""Write the AI Upscale conversion template the app ships (app/Resources/UpscaleModel).

Luxtable doesn't distribute RealESRGAN_x2plus's trained weights. The app downloads the
release checkpoint from its authors (convert.py's WEIGHTS_URL) and builds the Core ML
package from it on the user's Mac, with this template (docs/UPSCALE_MODEL.md, "Download"):

  Manifest.json   the converted package's manifest
  model.mlmodel   its model spec, with the one trained tensor it holds inline
                  (conv_last.bias) zeroed
  recipe.json     where each tensor of the package's weight.bin lies in the checkpoint

    python template.py <LuxtableUpscale.mlpackage> <RealESRGAN_x2plus.pth> <out dir>

It rebuilds weight.bin from the recipe and stops unless that matches the package's, then
prints the SHA-256 pins for `UpscaleModelDescriptor`.
"""
import base64
import hashlib
import json
import os
import shutil
import struct
import sys
import zipfile

import numpy as np
import torch

SPEC = "Data/com.apple.CoreML/model.mlmodel"
WEIGHTS = "Data/com.apple.CoreML/weights/weight.bin"
SENTINEL = 0xDEADBEEF
FLOAT16 = 1  # the blob storage's dtype tag


def half(raw, off, count, scale):
    a = np.frombuffer(raw, dtype="<f4", count=count, offset=off)
    return (a * np.float32(0.2) if scale else a).astype("<f2").tobytes()


def rebuild(raw, blobs):
    """weight.bin (Core ML's blob storage, version 2) from the recipe."""
    out = bytearray(struct.pack("<II", len(blobs), 2) + bytes(56))
    for b in blobs:
        data = base64.b64decode(b["d"]) if "d" in b else half(raw, b["o"], b["n"], b.get("s", False))
        out += struct.pack("<IIQQ", SENTINEL, FLOAT16, len(data), len(out) + 64) + bytes(40) + data
        out += bytes(-len(out) % 64)
    return bytes(out)


def main(pkg, pth, out):
    raw = open(pth, "rb").read()
    wb = open(os.path.join(pkg, WEIGHTS), "rb").read()
    spec = open(os.path.join(pkg, SPEC), "rb").read()
    state = torch.load(pth, map_location="cpu", weights_only=True)["params_ema"]

    # Each tensor's bytes in the checkpoint (a zip of stored, uncompressed entries).
    where = {}
    for info in zipfile.ZipFile(pth).infolist():
        name_len, extra_len = struct.unpack_from("<HH", raw, info.header_offset + 26)
        start = info.header_offset + 30 + name_len + extra_len
        where.setdefault(raw[start:start + info.file_size], start)
    source = {}
    for key, tensor in state.items():
        data = tensor.numpy().astype("<f4").tobytes()
        source[key] = (where[data], tensor.numel())

    # The package's blobs in order: each is a checkpoint tensor in float16, a conv5 tensor
    # times 0.2 (the residual scale, folded in by the conversion), or a constant.
    blobs = []
    count, version = struct.unpack_from("<II", wb, 0)
    if version != 2:
        sys.exit(f"weight.bin version {version}")
    at = 64
    for _ in range(count):
        sentinel, dtype, size, offset = struct.unpack_from("<IIQQ", wb, at)
        if sentinel != SENTINEL or dtype != FLOAT16:
            sys.exit(f"unexpected blob at {at}")
        data = wb[offset:offset + size]
        for key, (off, n) in source.items():
            scale = ".conv5." in key
            if n * 2 == size and half(raw, off, n, scale) == data:
                blobs.append({"o": off, "n": n, "s": True} if scale else {"o": off, "n": n})
                break
        else:
            if any(v not in (0, 0x3C00) for v in np.frombuffer(data, dtype="<u2")):
                sys.exit(f"blob at {at} is neither a checkpoint tensor nor a 0/1 constant")
            blobs.append({"d": base64.b64encode(data).decode()})
        at = (offset + size + 63) // 64 * 64
    if rebuild(raw, blobs) != wb:
        sys.exit("the recipe doesn't rebuild weight.bin")

    # The spec holds conv_last.bias inline (too small for weight.bin): shipped zeroed.
    off, n = source["conv_last.bias"]
    bias = half(raw, off, n, False)
    if spec.count(bias) != 1:
        sys.exit("conv_last.bias isn't in the model spec exactly once")
    spec_at = spec.find(bias)
    template = spec[:spec_at] + bytes(len(bias)) + spec[spec_at + len(bias):]

    os.makedirs(out, exist_ok=True)
    shutil.copyfile(os.path.join(pkg, "Manifest.json"), os.path.join(out, "Manifest.json"))
    with open(os.path.join(out, "model.mlmodel"), "wb") as f:
        f.write(template)
    with open(os.path.join(out, "recipe.json"), "w") as f:
        json.dump({"blobs": blobs, "bias": {"o": off, "n": n, "at": spec_at}}, f, separators=(",", ":"))
        f.write("\n")
    print(f"checkpoint  {hashlib.sha256(raw).hexdigest()}  {len(raw)}")
    print(f"spec        {hashlib.sha256(spec).hexdigest()}  {len(spec)}")
    print(f"weights     {hashlib.sha256(wb).hexdigest()}  {len(wb)}")


if __name__ == "__main__":
    main(*sys.argv[1:4])

import Foundation

/// Builds AI Upscale's Core ML package from the release checkpoint its authors publish
/// (`RealESRGAN_x2plus.pth`), so Luxtable never distributes the trained weights. The
/// template the app ships (`scripts/upscale-model/template.py`) has the package's
/// manifest, its model spec with the one inline trained tensor zeroed, and a recipe:
/// where each tensor of `weight.bin` lies in the checkpoint. The result is the pinned
/// conversion bit for bit; `UpscaleModelDownload` checks its SHA-256s before installing it.
enum UpscaleConversion {
    struct Recipe: Decodable {
        /// One tensor of `weight.bin`: `n` float32 values at byte `o` of the checkpoint
        /// (times 0.2 when `s`, the residual scale the conversion folds in), or the
        /// constant bytes `d`.
        struct Blob: Decodable {
            var o: Int?
            var n: Int?
            var s: Bool?
            var d: Data?
        }
        /// The spec's inline tensor: `n` values at byte `o` of the checkpoint, written at
        /// byte `at` of the spec.
        struct Patch: Decodable {
            var o: Int
            var n: Int
            var at: Int
        }
        var blobs: [Blob]
        var bias: Patch
    }

    static let checkpointName = "RealESRGAN_x2plus.pth"
    static let specPath = "Data/com.apple.CoreML/model.mlmodel"

    /// Writes `package` (which must not exist) from `checkpoint` and the `template` folder.
    /// A recipe that reaches outside the checkpoint or the spec throws
    /// `ModelFetchError.checksum`.
    static func build(checkpoint: URL, template: URL, package: URL) throws {
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: template.appendingPathComponent("recipe.json")))
        let source = try Data(contentsOf: checkpoint, options: .alwaysMapped)
        func half(_ offset: Int, _ count: Int, scaled: Bool) throws -> Data {
            guard offset >= 0, count > 0, count <= (source.count - offset) / 4 else {
                throw ModelFetchError.checksum(checkpointName)
            }
            var out = Data(count: count * 2)
            source.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    for i in 0..<count {
                        let v = Float(bitPattern: UInt32(littleEndian: src.loadUnaligned(fromByteOffset: offset + i * 4, as: UInt32.self)))
                        dst.storeBytes(of: Float16(scaled ? v * 0.2 : v).bitPattern.littleEndian, toByteOffset: i * 2, as: UInt16.self)
                    }
                }
            }
            return out
        }
        func append<T: FixedWidthInteger>(_ v: T, to data: inout Data) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }

        // Core ML's blob storage, version 2: a 64-byte header (count, version), then per
        // blob 64 bytes of metadata (sentinel, dtype, size, offset of the data) and the
        // data, each padded to 64 bytes.
        var weights = Data(capacity: 34 << 20)
        append(UInt32(recipe.blobs.count), to: &weights)
        append(UInt32(2), to: &weights)
        weights.append(Data(count: 56))
        for blob in recipe.blobs {
            let data: Data
            if let d = blob.d { data = d } else { data = try half(blob.o ?? -1, blob.n ?? 0, scaled: blob.s ?? false) }
            append(UInt32(0xDEAD_BEEF), to: &weights)
            append(UInt32(1), to: &weights) // float16
            append(UInt64(data.count), to: &weights)
            append(UInt64(weights.count + 48), to: &weights)
            weights.append(Data(count: 40))
            weights.append(data)
            weights.append(Data(count: (64 - weights.count % 64) % 64))
        }

        var spec = try Data(contentsOf: template.appendingPathComponent("model.mlmodel"))
        let bias = try half(recipe.bias.o, recipe.bias.n, scaled: false)
        guard recipe.bias.at >= 0, recipe.bias.at <= spec.count - bias.count else { throw ModelFetchError.checksum(specPath) }
        spec.replaceSubrange(recipe.bias.at..<recipe.bias.at + bias.count, with: bias)

        let fm = FileManager.default
        let weightsURL = package.appendingPathComponent(DenoiseModelDescriptor.weightsPath)
        try fm.createDirectory(at: weightsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: template.appendingPathComponent("Manifest.json"), to: package.appendingPathComponent("Manifest.json"))
        try spec.write(to: package.appendingPathComponent(specPath))
        try weights.write(to: weightsURL)
    }
}

import CoreVideo
import Metal

/// Converts Dolby Vision frames whose base layer is IPTPQc2 (profiles 5, 10.0,
/// 20) into HDR10 — BT.2020 PQ YCbCr in a 10-bit video-range buffer — on the
/// GPU, CVPixelBuffer to CVPixelBuffer, before enqueue (PLAN.md §4, §6).
///
/// Per pixel, in one compute pass: reshape the base layer with the frame's
/// RPU curves, IPT→L'M'S' with the RPU matrix, PQ-decode, LMS→BT.2020, then
/// re-encode as PQ BT.2020 YCbCr. The renderer takes it from there exactly as
/// it takes any HDR10 stream, tone mapping included. What this does *not*
/// carry over is Dolby's dynamic display management (L1/L2/L8 trims): the
/// output is static HDR10, and Apple's HDR10 path does the tone mapping.
///
/// Decode-thread-only, like `PixelBufferFactory`. Hardware frames never leave
/// the GPU: VideoToolbox surfaces are bound as Metal textures through the
/// texture cache, zero-copy.
final class DolbyVisionConverter {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            throw EngineError(code: .unsupported, message: "Dolby Vision conversion needs Metal; no GPU available")
        }
        do {
            // Compiled from source at runtime: SwiftPM's command-line build does
            // not compile .metal files, and the kernel is small. Once per session
            // that actually carries Dolby Vision.
            let options = MTLCompileOptions()
            // Fast math halves the kernel's cost (it is mostly `pow`), which
            // matters on an Apple TV: the decode thread waits for every frame.
            // Safe here — every `pow` input is clamped non-negative and no
            // divisor can reach zero — and it stays within a code of the
            // Double reference (`DolbyVisionTests`).
            options.mathMode = .fast
            let library = try device.makeLibrary(source: DolbyVisionShader.source, options: options)
            guard let function = library.makeFunction(name: DolbyVisionShader.kernelName) else {
                throw EngineError(code: .internalError, message: "Dolby Vision kernel missing from library")
            }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError(code: .internalError, message: "Dolby Vision kernel failed to compile: \(error)")
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw EngineError(code: .internalError, message: "CVMetalTextureCacheCreate failed")
        }
        self.device = device
        self.queue = queue
        self.textureCache = cache
    }

    /// Where the source's chroma samples sit relative to luma, in luma pixels.
    /// FFmpeg reports it per frame (`AVFrame.chroma_location`).
    struct ChromaSiting: Equatable {
        var horizontal: Float
        var vertical: Float

        /// Both co-sited with the top-left luma sample.
        static let topLeft = ChromaSiting(horizontal: 0, vertical: 0)
        /// Horizontally co-sited, vertically between rows (MPEG-2, HEVC default).
        static let left = ChromaSiting(horizontal: 0, vertical: 0.5)
        static let center = ChromaSiting(horizontal: 0.5, vertical: 0.5)
        static let top = ChromaSiting(horizontal: 0.5, vertical: 0)
    }

    /// Converts one frame. Blocks until the GPU is done — this runs on the
    /// decode thread, which is allowed to block (PLAN.md D1).
    ///
    /// Throws `.renderFailed` when the GPU failed or refused the work, which
    /// is transient (iOS refuses GPU work from a backgrounded app); any other
    /// error means this source cannot be converted at all.
    func convert(
        _ source: CVPixelBuffer,
        mapping: DolbyVisionMapping,
        chromaSiting: ChromaSiting
    ) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard let input = InputFormat(CVPixelBufferGetPixelFormatType(source)),
              CVPixelBufferGetPlaneCount(source) == 2
        else {
            throw EngineError(
                code: .unsupported,
                message: "Dolby Vision conversion: unsupported source pixel format \(CVPixelBufferGetPixelFormatType(source))"
            )
        }

        let output = try dequeueBuffer(width: width, height: height)

        let sourceLuma = try texture(source, plane: 0, format: input.lumaFormat)
        let sourceChroma = try texture(source, plane: 1, format: input.chromaFormat)
        let outputLuma = try texture(output, plane: 0, format: .r16Unorm)
        let outputChroma = try texture(output, plane: 1, format: .rg16Unorm)
        defer { CVMetalTextureCacheFlush(textureCache, 0) }

        guard let sourceLumaTexture = CVMetalTextureGetTexture(sourceLuma),
              let sourceChromaTexture = CVMetalTextureGetTexture(sourceChroma),
              let outputLumaTexture = CVMetalTextureGetTexture(outputLuma),
              let outputChromaTexture = CVMetalTextureGetTexture(outputChroma),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw EngineError(code: .internalError, message: "Dolby Vision conversion: Metal setup failed")
        }

        let parameters = DolbyVisionShader.parameters(
            for: mapping,
            inputScale: input.normalizationScale(baseLayerBitDepth: mapping.baseLayerBitDepth),
            chromaSiting: chromaSiting
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceLumaTexture, index: 0)
        encoder.setTexture(sourceChromaTexture, index: 1)
        encoder.setTexture(outputLumaTexture, index: 2)
        encoder.setTexture(outputChromaTexture, index: 3)
        parameters.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                encoder.setBytes(base, length: bytes.count, index: 0)
            }
        }

        // One thread per output chroma sample, i.e. per 2×2 block of luma.
        let blocks = MTLSize(width: outputChromaTexture.width, height: outputChromaTexture.height, depth: 1)
        let groupWidth = pipeline.threadExecutionWidth
        let groupHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / groupWidth / 4)
        let group = MTLSize(width: groupWidth, height: groupHeight, depth: 1)
        let grid = MTLSize(
            width: (blocks.width + groupWidth - 1) / groupWidth,
            height: (blocks.height + groupHeight - 1) / groupHeight,
            depth: 1
        )
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            let detail = commandBuffer.error.map { " — \($0.localizedDescription)" } ?? ""
            throw EngineError(code: .renderFailed, message: "Dolby Vision conversion failed on the GPU\(detail)")
        }
        // Textures (and with them the surfaces) are held until here by the
        // CVMetalTexture locals above.
        withExtendedLifetime((sourceLuma, sourceChroma, outputLuma, outputChroma)) {}

        tagAsHDR10(output)
        return output
    }

    // MARK: Buffers

    private func dequeueBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if pool == nil || poolWidth != width || poolHeight != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var newPool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            guard status == kCVReturnSuccess, let newPool else {
                throw EngineError(code: .decodeFailed, message: "CVPixelBufferPoolCreate failed (\(status))")
            }
            pool = newPool
            poolWidth = width
            poolHeight = height
        }

        var buffer: CVPixelBuffer?
        guard let pool else {
            throw EngineError(code: .internalError, message: "pixel buffer pool missing")
        }
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw EngineError(code: .decodeFailed, message: "pixel buffer allocation failed (\(status))")
        }
        return buffer
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane),
            plane, &texture
        )
        guard status == kCVReturnSuccess, let texture else {
            throw EngineError(code: .internalError, message: "Metal texture for plane \(plane) failed (\(status))")
        }
        return texture
    }

    /// What the kernel wrote, spelled out for CoreMedia. The format description
    /// is built from these attachments (`SampleBufferBuilder`), which is what
    /// makes the renderer treat the stream as HDR10.
    private func tagAsHDR10(_ buffer: CVPixelBuffer) {
        let tags: [CFString: CFString] = [
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            // The kernel averages each 2×2 block into one chroma sample.
            kCVImageBufferChromaLocationTopFieldKey: kCVImageBufferChromaLocation_Center,
            kCVImageBufferChromaLocationBottomFieldKey: kCVImageBufferChromaLocation_Center,
        ]
        for (key, value) in tags {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
    }

    /// Source layouts the kernel reads: 4:2:0 bi-planar, 8 or 10 bit. Both
    /// the VideoToolbox and the software path deliver one of these.
    private struct InputFormat {
        let lumaFormat: MTLPixelFormat
        let chromaFormat: MTLPixelFormat
        /// Bits of real code value per sample (10-bit formats keep them in the
        /// top of 16).
        let significantBits: Int

        init?(_ pixelFormat: OSType) {
            switch pixelFormat {
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
                lumaFormat = .r16Unorm
                chromaFormat = .rg16Unorm
                significantBits = 10
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                lumaFormat = .r8Unorm
                chromaFormat = .rg8Unorm
                significantBits = 8
            default:
                return nil
            }
        }

        /// Factor from a sampled unorm value to the base layer's code value as
        /// a fraction of its range — what the RPU's pivots are expressed in.
        /// The range flag of the pixel format plays no part: it labels the
        /// codes, the codes themselves are what the curves were built for.
        func normalizationScale(baseLayerBitDepth: Int) -> Float {
            let containerBits = lumaFormat == .r16Unorm ? 16 : 8
            // unorm · (2^container − 1) is the raw container value; the code
            // sits in its top `significantBits`.
            let code = Double((1 << containerBits) - 1) / Double(1 << (containerBits - significantBits))
            let rescaled = code * Double(1 << baseLayerBitDepth) / Double(1 << significantBits)
            return Float(rescaled / Double((1 << baseLayerBitDepth) - 1))
        }
    }
}

// MARK: - Kernel

/// The kernel and the layout of its parameter block. The layout constants are
/// interpolated into the Metal source, so Swift and the shader cannot drift.
enum DolbyVisionShader {
    static let kernelName = "lume_dovi_to_hdr10"

    // Parameter block, in floats.
    static let inputScaleIndex = 0
    static let chromaOffsetIndex = 1 // x, y
    static let yccToRGBIndex = 4 // 9, row-major
    static let yccOffsetIndex = 13 // 3
    static let lmsToRGBIndex = 16 // 9, row-major
    static let curvesIndex = 28

    // One reshaping curve: piece count, pivots, pieces.
    static let maxPieces = 8
    static let curvePivotsIndex = 1 // maxPieces + 1
    static let curvePiecesIndex = 10
    // One piece: method, polynomial (3), MMR order, MMR constant, MMR (3 × 7).
    static let pieceStride = 27
    static let curveStride = curvePiecesIndex + maxPieces * pieceStride
    static let parameterCount = curvesIndex + 3 * curveStride

    static func parameters(
        for mapping: DolbyVisionMapping,
        inputScale: Float,
        chromaSiting: DolbyVisionConverter.ChromaSiting
    ) -> [Float] {
        var block = [Float](repeating: 0, count: parameterCount)
        block[inputScaleIndex] = inputScale
        block[chromaOffsetIndex] = chromaSiting.horizontal
        block[chromaOffsetIndex + 1] = chromaSiting.vertical
        for (offset, value) in mapping.yccToRGB.enumerated() { block[yccToRGBIndex + offset] = Float(value) }
        for (offset, value) in mapping.yccToRGBOffset.enumerated() { block[yccOffsetIndex + offset] = Float(value) }
        for (offset, value) in mapping.linearLMSToRGB.enumerated() { block[lmsToRGBIndex + offset] = Float(value) }

        for (component, curve) in mapping.curves.prefix(3).enumerated() {
            let base = curvesIndex + component * curveStride
            let pieces = curve.pieces.prefix(maxPieces)
            block[base] = Float(pieces.count)
            for index in 0...maxPieces {
                // Pad with the last pivot so a stray read stays in range.
                let pivot = curve.pivots[min(index, curve.pivots.count - 1)]
                block[base + curvePivotsIndex + index] = Float(pivot)
            }
            for (index, piece) in pieces.enumerated() {
                let start = base + curvePiecesIndex + index * pieceStride
                switch piece {
                case .polynomial(let coefficients):
                    block[start] = 0
                    for (term, value) in coefficients.prefix(3).enumerated() { block[start + 1 + term] = Float(value) }
                case .mmr(let constant, let coefficients):
                    block[start] = 1
                    block[start + 4] = Float(min(coefficients.count, 3))
                    block[start + 5] = Float(constant)
                    for (order, row) in coefficients.prefix(3).enumerated() {
                        for (term, value) in row.prefix(7).enumerated() {
                            block[start + 6 + order * 7 + term] = Float(value)
                        }
                    }
                }
            }
        }
        return block
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant int kInputScale = \(inputScaleIndex);
    constant int kChromaOffset = \(chromaOffsetIndex);
    constant int kYccToRGB = \(yccToRGBIndex);
    constant int kYccOffset = \(yccOffsetIndex);
    constant int kLMSToRGB = \(lmsToRGBIndex);
    constant int kCurves = \(curvesIndex);
    constant int kCurveStride = \(curveStride);
    constant int kCurvePivots = \(curvePivotsIndex);
    constant int kCurvePieces = \(curvePiecesIndex);
    constant int kPieceStride = \(pieceStride);

    // SMPTE ST 2084. Linear values are relative to 10 000 cd/m².
    constant float kM1 = 2610.0 / 16384.0;
    constant float kM2 = 2523.0 / 4096.0 * 128.0;
    constant float kC1 = 3424.0 / 4096.0;
    constant float kC2 = 2413.0 / 4096.0 * 32.0;
    constant float kC3 = 2392.0 / 4096.0 * 32.0;

    static float3 pq_eotf(float3 e) {
        float3 p = pow(max(e, 0.0), 1.0 / kM2);
        return pow(max(p - kC1, 0.0) / (kC2 - kC3 * p), 1.0 / kM1);
    }

    static float3 pq_oetf(float3 y) {
        float3 p = pow(clamp(y, 0.0, 1.0), kM1);
        return pow((kC1 + kC2 * p) / (1.0 + kC3 * p), kM2);
    }

    static float3 mul3(constant float *m, float3 v) {
        return float3(dot(float3(m[0], m[1], m[2]), v),
                      dot(float3(m[3], m[4], m[5]), v),
                      dot(float3(m[6], m[7], m[8]), v));
    }

    // One component of the RPU reshaping. The piece is chosen by the
    // component's own input; MMR pieces regress on all three.
    static float reshape(constant float *curve, float3 sig, int component) {
        int pieces = int(curve[0]);
        constant float *pivots = curve + kCurvePivots;
        float s = clamp(sig[component], pivots[0], pivots[pieces]);
        int piece = 0;
        for (int i = 1; i < pieces; i++) {
            if (s >= pivots[i]) piece = i;
        }
        constant float *p = curve + kCurvePieces + piece * kPieceStride;
        float out;
        if (p[0] < 0.5) {
            out = p[1] + s * (p[2] + s * p[3]);
        } else {
            float4 cross = float4(sig.x * sig.y, sig.x * sig.z, sig.y * sig.z, sig.x * sig.y * sig.z);
            float3 power = sig;
            float4 crossPower = cross;
            out = p[5];
            constant float *c = p + 6;
            int order = int(p[4]);
            for (int k = 0; k < order; k++) {
                out += dot(float3(c[0], c[1], c[2]), power)
                     + dot(float4(c[3], c[4], c[5], c[6]), crossPower);
                c += 7;
                power *= sig;
                crossPower *= cross;
            }
        }
        return clamp(out, 0.0, 1.0);
    }

    // Base-layer sample → HDR10 Y'CbCr (chroma centred on 0).
    static float3 convert(constant float *params, float3 sig) {
        float3 reshaped = float3(reshape(params + kCurves, sig, 0),
                                 reshape(params + kCurves + kCurveStride, sig, 1),
                                 reshape(params + kCurves + 2 * kCurveStride, sig, 2));
        float3 offset = float3(params[kYccOffset], params[kYccOffset + 1], params[kYccOffset + 2]);
        float3 lms = pq_eotf(mul3(params + kYccToRGB, reshaped - offset));
        float3 rgb = pq_oetf(max(mul3(params + kLMSToRGB, lms), 0.0));
        float y = dot(rgb, float3(0.2627, 0.6780, 0.0593));
        return float3(y, (rgb.b - y) / 1.8814, (rgb.r - y) / 1.4746);
    }

    // One thread per 2×2 luma block: four luma samples, one chroma sample.
    kernel void \(kernelName)(texture2d<float, access::read> srcLuma [[texture(0)]],
                              texture2d<float, access::sample> srcChroma [[texture(1)]],
                              texture2d<float, access::write> dstLuma [[texture(2)]],
                              texture2d<float, access::write> dstChroma [[texture(3)]],
                              constant float *params [[buffer(0)]],
                              uint2 block [[thread_position_in_grid]]) {
        if (block.x >= dstChroma.get_width() || block.y >= dstChroma.get_height()) return;
        constexpr sampler bilinear(coord::pixel, address::clamp_to_edge, filter::linear);

        uint width = srcLuma.get_width();
        uint height = srcLuma.get_height();
        float scale = params[kInputScale];
        float2 siting = float2(params[kChromaOffset], params[kChromaOffset + 1]);

        float2 chroma = 0.0;
        float count = 0.0;
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint2 pixel = block * 2 + uint2(dx, dy);
                if (pixel.x >= width || pixel.y >= height) continue;
                // Chroma sample i sits at luma position 2i + siting; +0.5 is
                // the texel centre in pixel coordinates.
                float2 at = (float2(pixel) - siting) * 0.5 + 0.5;
                float3 sig = float3(srcLuma.read(pixel).r, srcChroma.sample(bilinear, at).rg) * scale;
                float3 ycc = convert(params, sig);
                // 10-bit video range, stored in the top of 16 bits.
                dstLuma.write(float4(round(64.0 + 876.0 * ycc.x) * 64.0 / 65535.0), pixel);
                chroma += ycc.yz;
                count += 1.0;
            }
        }
        float2 codes = round(512.0 + 896.0 * clamp(chroma / count, -0.5, 0.5));
        dstChroma.write(float4(codes * 64.0 / 65535.0, 0.0, 0.0), block);
    }
    """
}

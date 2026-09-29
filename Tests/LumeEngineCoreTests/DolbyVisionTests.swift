import CFFmpeg
import CoreVideo
import Foundation
import Metal
import Testing
@testable import LumeEngineCore

/// Dolby Vision with an IPTPQc2 base layer (profiles 5, 10.0, 20). Shown as
/// YCbCr it comes out pink/green; the engine reshapes it with the frame's RPU
/// and hands the renderer HDR10 instead.
@Suite("Dolby Vision", .serialized)
struct DolbyVisionTests {
    // MARK: Colour science

    @Test("HPE LMS→RGB matches the published matrix and preserves white")
    func hpeMatrix() {
        // libplacebo's pl_ipt_lms2rgb, derived from the unquantized HPE
        // transform. The engine derives it from BT.2100's 1/4096-quantized
        // ICtCp matrix instead, so they agree to that quantization.
        let published = [
            3.06441879, -2.16597676, 0.10155818,
            -0.65612108, 1.78554118, -0.12943749,
            0.01736321, -0.04725154, 1.03004253,
        ]
        let derived = Matrix3.hpeLMSToBT2020
        for (lhs, rhs) in zip(derived, published) {
            #expect(abs(lhs - rhs) < 5e-4, "\(derived) vs \(published)")
        }
        for row in 0..<3 {
            let sum = derived[row * 3] + derived[row * 3 + 1] + derived[row * 3 + 2]
            #expect(abs(sum - 1) < 1e-9, "row \(row) sums to \(sum): white would shift")
        }
    }

    // MARK: Metadata extraction

    @Test("reads FFmpeg's metadata: pivots normalized, fixed point unscaled, MMR rows intact")
    func extraction() throws {
        var size = 0
        let metadata = try #require(av_dovi_metadata_alloc(&size))
        defer { av_free(metadata) }
        let one: Int64 = 1 << 23

        let header = try #require(av_dovi_get_header(metadata))
        header.pointee.bl_bit_depth = 10
        header.pointee.coef_log2_denom = 23

        let mapping = try #require(av_dovi_get_mapping(metadata))
        // I: two polynomial pieces.
        mapping.pointee.curves.0.num_pivots = 3
        mapping.pointee.curves.0.pivots.0 = 0
        mapping.pointee.curves.0.pivots.1 = 400
        mapping.pointee.curves.0.pivots.2 = 1023
        mapping.pointee.curves.0.mapping_idc.0 = AV_DOVI_MAPPING_POLYNOMIAL
        mapping.pointee.curves.0.mapping_idc.1 = AV_DOVI_MAPPING_POLYNOMIAL
        mapping.pointee.curves.0.poly_coef.0 = (-612_867, 9_803_467, 0)
        mapping.pointee.curves.0.poly_coef.1 = (one, 0, -one / 4)
        // P: one second-order MMR piece.
        mapping.pointee.curves.1.num_pivots = 2
        mapping.pointee.curves.1.pivots.0 = 0
        mapping.pointee.curves.1.pivots.1 = 1023
        mapping.pointee.curves.1.mapping_idc.0 = AV_DOVI_MAPPING_MMR
        mapping.pointee.curves.1.mmr_order.0 = 2
        mapping.pointee.curves.1.mmr_constant.0 = -one / 8
        mapping.pointee.curves.1.mmr_coef.0 = (
            (one, 2 * one, 3 * one, 4 * one, 5 * one, 6 * one, 7 * one),
            (-one, -2 * one, -3 * one, -4 * one, -5 * one, -6 * one, -7 * one),
            (99 * one, 99 * one, 99 * one, 99 * one, 99 * one, 99 * one, 99 * one) // beyond order: ignored
        )
        // T: identity.
        mapping.pointee.curves.2.num_pivots = 2
        mapping.pointee.curves.2.pivots.0 = 0
        mapping.pointee.curves.2.pivots.1 = 1023
        mapping.pointee.curves.2.poly_coef.0 = (0, one, 0)

        let color = try #require(av_dovi_get_color(metadata))
        color.pointee.ycc_to_rgb_matrix.0 = AVRational(num: 8192, den: 8192)
        color.pointee.ycc_to_rgb_matrix.1 = AVRational(num: 799, den: 8192)
        color.pointee.ycc_to_rgb_offset.1 = AVRational(num: 1 << 27, den: 1 << 28)
        color.pointee.rgb_to_lms_matrix.0 = AVRational(num: 17081, den: 16384)
        color.pointee.rgb_to_lms_matrix.4 = AVRational(num: 16384, den: 16384)

        let parsed = try #require(DolbyVisionMapping(metadata: metadata))
        #expect(parsed.baseLayerBitDepth == 10)
        #expect(parsed.curves.count == 3)

        #expect(parsed.curves[0].pivots == [0, 400.0 / 1023, 1])
        #expect(parsed.curves[0].pieces == [
            .polynomial([-612_867.0 / 8_388_608, 9_803_467.0 / 8_388_608, 0]),
            .polynomial([1, 0, -0.25]),
        ])
        #expect(parsed.curves[1].pieces == [
            .mmr(constant: -0.125, coefficients: [[1, 2, 3, 4, 5, 6, 7], [-1, -2, -3, -4, -5, -6, -7]]),
        ])
        #expect(parsed.curves[2].pieces == [.polynomial([0, 1, 0])])

        #expect(parsed.yccToRGB[0] == 1)
        #expect(parsed.yccToRGB[1] == 799.0 / 8192)
        #expect(parsed.yccToRGB[2] == 0, "zero-initialized denominators must read as 0, not NaN")
        #expect(parsed.yccToRGBOffset == [0, 0.5, 0])
        #expect(parsed.rgbToLMS[0] == 17081.0 / 16384)
        #expect(parsed.rgbToLMS[4] == 1)
    }

    // MARK: GPU conversion

    @Test(
        "GPU output matches an independent CPU reference",
        .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"),
        arguments: [DolbyVisionConverter.ChromaSiting.topLeft, .left]
    )
    func gpuMatchesReference(siting: DolbyVisionConverter.ChromaSiting) throws {
        // Odd on both axes: the last column and row of blocks are partial.
        let width = 33, height = 17
        let chromaWidth = (width + 1) / 2, chromaHeight = (height + 1) / 2
        let luma = (0..<(width * height)).map { index -> Int in
            let x = index % width, y = index / width
            return 64 + (x * 29 + y * 13) % 900
        }
        let chroma = (0..<(chromaWidth * chromaHeight)).map { index -> (Int, Int) in
            let x = index % chromaWidth, y = index / chromaWidth
            return (350 + (x * 37 + y * 11) % 320, 360 + (x * 23 + y * 41) % 300)
        }
        let source = try Self.makeSource(width: width, height: height, luma: luma, chroma: chroma)

        let mapping = Self.syntheticMapping
        let converter = try DolbyVisionConverter()
        let output = try converter.convert(source, mapping: mapping, chromaSiting: siting)

        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(Self.attachment(output, kCVImageBufferYCbCrMatrixKey) == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        #expect(Self.attachment(output, kCVImageBufferColorPrimariesKey) == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(Self.attachment(output, kCVImageBufferTransferFunctionKey) == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)

        let reference = Reference(mapping: mapping, siting: siting, width: width, height: height, luma: luma, chroma: chroma)
        let (outLuma, outChroma) = Self.readCodes(output)

        var worstLuma = 0, worstChroma = 0
        for y in 0..<height {
            for x in 0..<width {
                let expected = Reference.lumaCode(reference.pixel(x, y).y)
                worstLuma = max(worstLuma, abs(outLuma[y * width + x] - expected))
            }
        }
        for j in 0..<chromaHeight {
            for i in 0..<chromaWidth {
                let (cb, cr) = reference.block(i, j)
                let actual = outChroma[j * chromaWidth + i]
                worstChroma = max(worstChroma, abs(actual.0 - cb), abs(actual.1 - cr))
            }
        }
        // Float32 on the GPU against Double here, plus the texture unit's
        // filter precision: a code either way, never a visible difference.
        #expect(worstLuma <= 2, "luma off by \(worstLuma) codes")
        #expect(worstChroma <= 2, "chroma off by \(worstChroma) codes")
    }

    // MARK: Real streams (local only)

    /// The Dolby Vision samples are not redistributable, so they live in the
    /// gitignored `TestStreams/DolbyVision/` of a developer machine; these
    /// tests skip wherever they are absent (CI included).
    private static func sample(_ name: String) -> URL {
        Fixtures.repoRoot.appendingPathComponent("TestStreams/DolbyVision/\(name)")
    }

    private static func hasSample(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: sample(name).path)
    }

    @Test(
        "profile 20 (IPT base layer) is converted to HDR10 with natural colour",
        .enabled(if: hasSample("DVprofile20.mp4"), "local Dolby Vision sample missing"),
        .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"),
        .timeLimit(.minutes(2)),
        arguments: [VideoDecoder.HardwarePolicy.videoToolbox, .software]
    )
    func profile20(policy: VideoDecoder.HardwarePolicy) async throws {
        let frames = try await decodeFirstFrames(Self.sample("DVprofile20.mp4"), count: 6, policy: policy)
        #expect(frames.count == 6)
        for frame in frames {
            #expect(frame.converting, "the decoder must report the conversion engaged")
            #expect(!frame.zeroCopy, "a converted frame is an engine-written surface")
            #expect(frame.format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            #expect(frame.matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
            #expect(frame.transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)

            // The opening shot is sea water. Read as YCbCr it is saturated
            // green (G' far above B'); reshaped it is turquoise — blue and
            // green close together, both well above red.
            let (r, g, b) = frame.meanRGB
            #expect(b > r + 0.05 && g > r + 0.05, "water must not turn pink: R'G'B' = \(r), \(g), \(b)")
            #expect(abs(g - b) < 0.08, "water must not turn green: R'G'B' = \(r), \(g), \(b)")
        }
    }

    @Test(
        "profile 8 (HDR10 base layer) is left alone",
        .enabled(if: hasSample("DV8_TEST.mp4"), "local Dolby Vision sample missing"),
        .timeLimit(.minutes(2))
    )
    func profile8Untouched() async throws {
        let frames = try await decodeFirstFrames(Self.sample("DV8_TEST.mp4"), count: 6, policy: .videoToolbox)
        #expect(frames.count == 6)
        for frame in frames {
            #expect(!frame.converting, "profile 8's base layer is HDR10 already")
            #expect(frame.matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        }
    }

    // MARK: Support

    private struct DecodedFrame: Sendable {
        let format: OSType
        let zeroCopy: Bool
        let converting: Bool
        let matrix: String?
        let transfer: String?
        /// Frame-average non-linear R'G'B', from a sparse grid of samples.
        let meanRGB: (Double, Double, Double)
    }

    /// Decodes the first `count` frames of a stream, then stops — the samples
    /// are long 4K files and six frames say everything these tests ask.
    private func decodeFirstFrames(
        _ url: URL,
        count: Int,
        policy: VideoDecoder.HardwarePolicy
    ) async throws -> [DecodedFrame] {
        let demuxer = Demuxer(url: url.path)
        defer { demuxer.shutdown() }
        var demuxEvents = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await demuxEvents.next() else {
            throw EngineError(code: .openFailed, message: "\(url.lastPathComponent) failed to open")
        }

        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))
        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 4, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = VideoDecoder(parameters: parameters, input: packets, output: frames, policy: policy)
        decoder.start()
        demuxer.resume()

        // Stopping the decoder from the drain closes the frame channel, which
        // is what ends the drain (see `ChannelDrain`).
        let collector = ChannelDrain(frames, into: [DecodedFrame]()) { collected, frame in
            guard collected.count < count else { return }
            collected.append(DecodedFrame(
                format: CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
                zeroCopy: frame.isHardwareDecoded,
                converting: decoder.isConvertingDolbyVision,
                matrix: Self.attachment(frame.pixelBuffer, kCVImageBufferYCbCrMatrixKey),
                transfer: Self.attachment(frame.pixelBuffer, kCVImageBufferTransferFunctionKey),
                meanRGB: Self.meanRGB(frame.pixelBuffer)
            ))
            if collected.count == count { decoder.shutdown() }
        }
        let result = await collector.value
        decoder.shutdown()
        return result
    }

    private static func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    /// Average R'G'B' of a 10-bit video-range BT.2020 buffer, from every 16th
    /// pixel on both axes — read in place, since copying a 4K plane per frame
    /// is what a debug build is slowest at. Anything else reads as black,
    /// which the colour assertions then reject.
    private static func meanRGB(_ buffer: CVPixelBuffer) -> (Double, Double, Double) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
            return (0, 0, 0)
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return (0, 0, 0) }
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        func code(_ base: UnsafeMutableRawPointer, _ rowBytes: Int, _ row: Int, _ index: Int) -> Double {
            Double((base + row * rowBytes).assumingMemoryBound(to: UInt16.self)[index] >> 6)
        }

        var sum = (0.0, 0.0, 0.0), samples = 0.0
        for y in stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: 16) {
            for x in stride(from: 0, to: CVPixelBufferGetWidth(buffer), by: 16) {
                let luma = (code(lumaBase, lumaRow, y, x) - 64) / 876
                let cb = (code(chromaBase, chromaRow, y / 2, x / 2 * 2) - 512) / 896
                let cr = (code(chromaBase, chromaRow, y / 2, x / 2 * 2 + 1) - 512) / 896
                let r = luma + 1.4746 * cr, b = luma + 1.8814 * cb
                let g = (luma - 0.2627 * r - 0.0593 * b) / 0.6780
                sum = (sum.0 + r, sum.1 + g, sum.2 + b)
                samples += 1
            }
        }
        return (sum.0 / samples, sum.1 / samples, sum.2 / samples)
    }

    /// 10-bit codes of a bi-planar MSB-aligned buffer, planes packed tightly.
    private static func readCodes(_ buffer: CVPixelBuffer) -> ([Int], [(Int, Int)]) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        func plane(_ index: Int, components: Int) -> [Int] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, index) else { return [] }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
            let width = CVPixelBufferGetWidthOfPlane(buffer, index)
            var values: [Int] = []
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, index) {
                let line = (base + row * rowBytes).assumingMemoryBound(to: UInt16.self)
                for column in 0..<(width * components) { values.append(Int(line[column] >> 6)) }
            }
            return values
        }
        let chroma = plane(1, components: 2)
        return (plane(0, components: 1), stride(from: 0, to: chroma.count, by: 2).map { (chroma[$0], chroma[$0 + 1]) })
    }

    /// A full-range 10-bit IPT base layer, as VideoToolbox hands it over.
    private static func makeSource(width: Int, height: Int, luma: [Int], chroma: [(Int, Int)]) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            attributes as CFDictionary, &buffer
        )
        let source = try #require(status == kCVReturnSuccess ? buffer : nil)
        CVPixelBufferLockBaseAddress(source, [])
        defer { CVPixelBufferUnlockBaseAddress(source, []) }
        let lumaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(source, 0))
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        for y in 0..<height {
            let line = (lumaBase + y * lumaRow).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width { line[x] = UInt16(luma[y * width + x] << 6) }
        }
        let chromaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(source, 1))
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(source, 1)
        for y in 0..<CVPixelBufferGetHeightOfPlane(source, 1) {
            let line = (chromaBase + y * chromaRow).assumingMemoryBound(to: UInt16.self)
            for x in 0..<chromaWidth {
                let (p, t) = chroma[y * chromaWidth + x]
                line[2 * x] = UInt16(p << 6)
                line[2 * x + 1] = UInt16(t << 6)
            }
        }
        return source
    }

    /// Exercises every code path: two polynomial pieces on I, a third-order MMR
    /// on P, a single polynomial on T. Matrices are DVprofile20.mp4's.
    private static let syntheticMapping = DolbyVisionMapping(
        baseLayerBitDepth: 10,
        curves: [
            .init(pivots: [0, 0.4, 1], pieces: [.polynomial([-0.073, 1.1687, 0]), .polynomial([-0.05, 1.1, -0.02])]),
            .init(pivots: [0, 1], pieces: [.mmr(constant: -0.02, coefficients: [
                [0.05, 1.05, 0.01, 0.02, -0.03, 0.01, 0.005],
                [0.01, 0, -0.01, 0.002, 0.001, -0.002, 0],
                [0.001, 0, 0, 0, 0, 0, 0],
            ])]),
            .init(pivots: [0, 1], pieces: [.polynomial([-0.0714, 1.1426, 0])]),
        ],
        yccToRGB: [8192, 799, 1681, 8192, -933, 1091, 8192, 267, -5545].map { $0 / 8192 },
        yccToRGBOffset: [0, 0.5, 0.5],
        rgbToLMS: [17081, -349, -349, -349, 17081, -349, -349, -349, 17081].map { $0 / 16384 }
    )
}

/// The conversion again, in Double and written independently of the kernel —
/// including its own LMS→RGB matrix (libplacebo's published one).
private struct Reference {
    let mapping: DolbyVisionMapping
    let siting: DolbyVisionConverter.ChromaSiting
    let width: Int, height: Int
    let luma: [Int]
    let chroma: [(Int, Int)]

    private var chromaWidth: Int { (width + 1) / 2 }
    private var chromaHeight: Int { (height + 1) / 2 }

    static func lumaCode(_ y: Double) -> Int { Int((64 + 876 * y).rounded()) }
    static func chromaCode(_ c: Double) -> Int { Int((512 + 896 * min(max(c, -0.5), 0.5)).rounded()) }

    /// Output Y'CbCr of one pixel.
    func pixel(_ x: Int, _ y: Int) -> (y: Double, cb: Double, cr: Double) {
        let (p, t) = sampleChroma(x, y)
        return convert([Double(luma[y * width + x]) / 1023, p, t])
    }

    /// Output chroma codes of one block: the average over its pixels.
    func block(_ i: Int, _ j: Int) -> (Int, Int) {
        var cb = 0.0, cr = 0.0, count = 0.0
        for y in (2 * j)..<min(2 * j + 2, height) {
            for x in (2 * i)..<min(2 * i + 2, width) {
                let value = pixel(x, y)
                cb += value.cb
                cr += value.cr
                count += 1
            }
        }
        return (Self.chromaCode(cb / count), Self.chromaCode(cr / count))
    }

    /// Bilinear, edge-clamped, with chroma sample i at luma position 2i + siting.
    private func sampleChroma(_ x: Int, _ y: Int) -> (Double, Double) {
        let u = (Double(x) - Double(siting.horizontal)) / 2
        let v = (Double(y) - Double(siting.vertical)) / 2
        let i0 = Int(u.rounded(.down)), j0 = Int(v.rounded(.down))
        let fu = u - Double(i0), fv = v - Double(j0)
        func at(_ i: Int, _ j: Int) -> (Double, Double) {
            let value = chroma[min(max(j, 0), chromaHeight - 1) * chromaWidth + min(max(i, 0), chromaWidth - 1)]
            return (Double(value.0) / 1023, Double(value.1) / 1023)
        }
        let a = at(i0, j0), b = at(i0 + 1, j0), c = at(i0, j0 + 1), d = at(i0 + 1, j0 + 1)
        func mix(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
            (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + d * fu) * fv
        }
        return (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1))
    }

    private func reshape(_ curve: DolbyVisionMapping.Curve, _ sig: [Double], _ component: Int) -> Double {
        let s = min(max(sig[component], curve.pivots.first ?? 0), curve.pivots.last ?? 1)
        let index = (1..<curve.pieces.count).last { s >= curve.pivots[$0] } ?? 0
        let out: Double
        switch curve.pieces[index] {
        case .polynomial(let c):
            out = c[0] + c[1] * s + c[2] * s * s
        case .mmr(let constant, let rows):
            let (y, u, v) = (sig[0], sig[1], sig[2])
            let terms = [y, u, v, y * u, y * v, u * v, y * u * v]
            out = rows.enumerated().reduce(constant) { total, row in
                let order = Double(row.offset + 1)
                return total + zip(row.element, terms).reduce(0) { $0 + $1.0 * pow($1.1, order) }
            }
        }
        return min(max(out, 0), 1)
    }

    private func convert(_ sig: [Double]) -> (y: Double, cb: Double, cr: Double) {
        let reshaped = (0..<3).map { reshape(mapping.curves[$0], sig, $0) }
        let centred = zip(reshaped, mapping.yccToRGBOffset).map { $0 - $1 }
        let lmsPQ = Self.apply(mapping.yccToRGB, centred)
        let lms = lmsPQ.map(Self.pqEOTF)
        let lmsToRGB = Self.multiply(Self.publishedHPEToBT2020, mapping.rgbToLMS)
        let rgb = Self.apply(lmsToRGB, lms).map { Self.pqOETF(max($0, 0)) }
        let y = 0.2627 * rgb[0] + 0.6780 * rgb[1] + 0.0593 * rgb[2]
        return (y, (rgb[2] - y) / 1.8814, (rgb[0] - y) / 1.4746)
    }

    private static let publishedHPEToBT2020 = [
        3.06441879, -2.16597676, 0.10155818,
        -0.65612108, 1.78554118, -0.12943749,
        0.01736321, -0.04725154, 1.03004253,
    ]

    private static func apply(_ m: [Double], _ v: [Double]) -> [Double] {
        (0..<3).map { row in (0..<3).reduce(0) { $0 + m[row * 3 + $1] * v[$1] } }
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        (0..<9).map { index in (0..<3).reduce(0) { $0 + a[index / 3 * 3 + $1] * b[$1 * 3 + index % 3] } }
    }

    private static let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
    private static let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32

    static func pqEOTF(_ e: Double) -> Double {
        let p = pow(max(e, 0), 1 / m2)
        return pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    static func pqOETF(_ y: Double) -> Double {
        let p = pow(min(max(y, 0), 1), m1)
        return pow((c1 + c2 * p) / (1 + c3 * p), m2)
    }
}

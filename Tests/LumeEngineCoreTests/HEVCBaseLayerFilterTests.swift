import Testing
@testable import LumeEngineCore

/// Enhancement layers (MV-HEVC's second view) have to be gone before the codec
/// sees them, or VideoToolbox refuses the stream and FFmpeg silently decodes
/// in software — see `HEVCBaseLayerFilter`.
@Suite("HEVC base layer filter")
struct HEVCBaseLayerFilterTests {
    /// A NAL unit: two-byte header for `type`/`layer`, then `payload`.
    private static func nal(type: UInt8, layer: UInt8, payload: [UInt8] = [0xAB, 0xCD]) -> [UInt8] {
        [type << 1 | layer >> 5, (layer & 0x1F) << 3 | 1] + payload
    }

    private static func lengthPrefixed(_ units: [[UInt8]]) -> [UInt8] {
        units.flatMap { unit in
            let length = unit.count
            return [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + unit
        }
    }

    private static func apply(_ filter: HEVCBaseLayerFilter, _ bytes: [UInt8]) -> [UInt8]? {
        bytes.withUnsafeBytes { buffer in
            filter.baseLayerRanges(of: buffer).map { ranges in ranges.flatMap { Array(buffer[$0]) } }
        }
    }

    @Test("header layer ID is the 6 bits spanning both bytes")
    func layerID() {
        for layer in [0, 1, 31, 32, 63] as [UInt8] {
            let unit = Self.nal(type: 1, layer: layer)
            #expect(HEVCBaseLayerFilter.layerID(unit[0], unit[1]) == Int(layer))
        }
    }

    @Test("length-prefixed: only layer-0 units survive, in order")
    func lengthPrefixedPacket() {
        let base = [Self.nal(type: 35, layer: 0), Self.nal(type: 19, layer: 0, payload: [1, 2, 3]), Self.nal(type: 62, layer: 0)]
        let mixed = [base[0], Self.nal(type: 33, layer: 1), base[1], Self.nal(type: 19, layer: 1), base[2]]
        let filter = HEVCBaseLayerFilter(framing: .lengthPrefixed(4))

        #expect(Self.apply(filter, Self.lengthPrefixed(mixed)) == Self.lengthPrefixed(base))
        #expect(Self.apply(filter, Self.lengthPrefixed(base)) == nil, "nothing to drop must mean no copy")
    }

    @Test("length-prefixed: a packet of enhancement data only leaves nothing")
    func onlyEnhancement() {
        let filter = HEVCBaseLayerFilter(framing: .lengthPrefixed(4))
        #expect(Self.apply(filter, Self.lengthPrefixed([Self.nal(type: 1, layer: 1)])) == [])
    }

    @Test("length-prefixed: a truncated packet passes through untouched")
    func truncated() {
        var bytes = Self.lengthPrefixed([Self.nal(type: 1, layer: 0), Self.nal(type: 1, layer: 1)])
        bytes.removeLast()
        #expect(Self.apply(HEVCBaseLayerFilter(framing: .lengthPrefixed(4)), bytes) == nil)
    }

    @Test("Annex B: three- and four-byte start codes, leading junk kept")
    func annexB() {
        let junk: [UInt8] = [0x00]
        let keepA = [0, 0, 0, 1] + Self.nal(type: 32, layer: 0)
        let dropB = [0, 0, 1] + Self.nal(type: 33, layer: 1, payload: [9, 9, 9])
        let keepC = [0, 0, 1] + Self.nal(type: 1, layer: 0, payload: [0x00, 0x00, 0x03, 0x01])
        let filter = HEVCBaseLayerFilter(framing: .annexB)

        #expect(Self.apply(filter, junk + keepA + dropB + keepC) == junk + keepA + keepC)
        #expect(Self.apply(filter, keepA + keepC) == nil)
        #expect(Self.apply(filter, [1, 2, 3, 4]) == nil, "no start code: not ours to judge")
    }

    @Test("framing follows the extradata the way FFmpeg's decoder decides")
    func framing() {
        var hvcC = [UInt8](repeating: 0, count: 23)
        hvcC[0] = 1
        hvcC[21] = 0xFC | 3
        hvcC.withUnsafeBytes { #expect(HEVCBaseLayerFilter(extradata: $0).framing == .lengthPrefixed(4)) }
        hvcC[21] = 0xFC | 1
        hvcC.withUnsafeBytes { #expect(HEVCBaseLayerFilter(extradata: $0).framing == .lengthPrefixed(2)) }
        let annexB: [UInt8] = [0, 0, 0, 1] + Self.nal(type: 32, layer: 0)
        annexB.withUnsafeBytes { #expect(HEVCBaseLayerFilter(extradata: $0).framing == .annexB) }
        [UInt8]().withUnsafeBytes { #expect(HEVCBaseLayerFilter(extradata: $0).framing == .annexB) }
    }

    /// An hvcC shaped like DVprofile20.mp4's once FFmpeg's MP4 demuxer has
    /// folded its lhvC in: base VPS/SPS/PPS/SEI, then the second view's SPS
    /// and PPS as arrays of their own.
    @Test("hvcC: enhancement parameter sets and the arrays they empty are removed")
    func hvcC() {
        func array(_ type: UInt8, _ units: [[UInt8]]) -> [UInt8] {
            [0x80 | type, UInt8(units.count >> 8), UInt8(units.count & 0xFF)]
                + units.flatMap { [UInt8($0.count >> 8), UInt8($0.count & 0xFF)] + $0 }
        }
        let header = [UInt8](repeating: 0xEE, count: 22)
        let vps = Self.nal(type: 32, layer: 0), sps = Self.nal(type: 33, layer: 0)
        let pps = Self.nal(type: 34, layer: 0), sei = Self.nal(type: 39, layer: 0)
        let sps1 = Self.nal(type: 33, layer: 1), pps1 = Self.nal(type: 34, layer: 1)

        let merged = header + [6]
            + array(32, [vps]) + array(33, [sps]) + array(34, [pps]) + array(39, [sei])
            + array(33, [sps1]) + array(34, [pps1])
        let expected = header + [4] + array(32, [vps]) + array(33, [sps]) + array(34, [pps]) + array(39, [sei])
        merged.withUnsafeBytes { #expect(HEVCBaseLayerFilter.baseLayerHVCC($0) == expected) }

        // Mixed within one array: the array stays, with a corrected count.
        let shared = header + [1] + array(33, [sps, sps1])
        shared.withUnsafeBytes { #expect(HEVCBaseLayerFilter.baseLayerHVCC($0) == header + [1] + array(33, [sps])) }

        expected.withUnsafeBytes { #expect(HEVCBaseLayerFilter.baseLayerHVCC($0) == nil, "single-layer hvcC stays as is") }
        Array(merged.dropLast()).withUnsafeBytes { #expect(HEVCBaseLayerFilter.baseLayerHVCC($0) == nil, "truncated: untouched") }
    }
}

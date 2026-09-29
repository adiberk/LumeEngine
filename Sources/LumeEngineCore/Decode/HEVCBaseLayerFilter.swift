/// Reduces a multi-layer HEVC stream (MV-HEVC stereo — Dolby Vision profile
/// 20, Apple spatial video — as well as SHVC and alpha layers) to its base
/// layer by dropping every NAL unit with `nuh_layer_id > 0`.
///
/// The engine only ever presents the base view, so nothing is lost. What is
/// gained is hardware decoding: FFmpeg's decoder files the enhancement layer's
/// SPS/PPS alongside the base layer's, and its VideoToolbox glue hands all of
/// them to VideoToolbox in one `hvcC` — where Apple expects the second layer's
/// in a separate `lhvC`. VideoToolbox rejects that session outright and FFmpeg
/// falls back to software decoding without an error, which for 4K 10-bit HEVC
/// is too slow to play on an Apple TV. Stripped, the same stream decodes on
/// VideoToolbox. (FFmpeg's MP4 demuxer even merges `lhvC` into the extradata,
/// so both the extradata and the in-band parameter sets need filtering.)
///
/// Pure byte work, no FFmpeg types: the decoder applies it to packets and to
/// its codec context's extradata. Malformed input is passed through untouched
/// — the decoder is better at judging broken bitstreams than this filter.
struct HEVCBaseLayerFilter: Sendable, Equatable {
    enum Framing: Sendable, Equatable {
        /// Each NAL unit preceded by its big-endian length in this many bytes
        /// (MP4/MKV, signalled by an `hvcC` extradata).
        case lengthPrefixed(Int)
        /// Start-code delimited (MPEG-TS, raw `.hevc`).
        case annexB
    }

    let framing: Framing

    /// Picks the framing FFmpeg's decoder will assume, the same way it does: an
    /// `hvcC` (configuration version 1) means length-prefixed packets.
    init(extradata: UnsafeRawBufferPointer) {
        if extradata.count >= 23, extradata[0] == 1 {
            framing = .lengthPrefixed(Int(extradata[21] & 0x3) + 1)
        } else {
            framing = .annexB
        }
    }

    init(framing: Framing) {
        self.framing = framing
    }

    /// `nuh_layer_id` from a NAL unit's two header bytes.
    static func layerID(_ first: UInt8, _ second: UInt8) -> Int {
        Int(first & 0x1) << 5 | Int(second >> 3)
    }

    // MARK: Packets

    /// Byte ranges of `data` that belong to the base layer, in order. Nil when
    /// nothing needs dropping — by far the common case, which then costs no
    /// copy. An empty result means the packet held no base-layer data at all.
    func baseLayerRanges(of data: UnsafeRawBufferPointer) -> [Range<Int>]? {
        guard let units = nalUnits(of: data) else { return nil }
        var kept: [Range<Int>] = []
        var dropped = false
        for unit in units {
            if let layer = unit.layer, layer > 0 {
                dropped = true
            } else if let last = kept.last, last.upperBound == unit.range.lowerBound {
                kept[kept.count - 1] = last.lowerBound..<unit.range.upperBound
            } else {
                kept.append(unit.range)
            }
        }
        return dropped ? kept : nil
    }

    private struct Unit {
        /// The whole unit including its length field or start code.
        let range: Range<Int>
        /// Nil when the unit is too short to carry a header; such units are
        /// kept.
        let layer: Int?
    }

    private func nalUnits(of data: UnsafeRawBufferPointer) -> [Unit]? {
        switch framing {
        case .lengthPrefixed(let size):
            return lengthPrefixedUnits(of: data, lengthSize: size)
        case .annexB:
            return annexBUnits(of: data)
        }
    }

    private func lengthPrefixedUnits(of data: UnsafeRawBufferPointer, lengthSize: Int) -> [Unit]? {
        var units: [Unit] = []
        var offset = 0
        while offset < data.count {
            guard offset + lengthSize <= data.count else { return nil }
            var length = 0
            for index in 0..<lengthSize { length = length << 8 | Int(data[offset + index]) }
            let payload = offset + lengthSize
            guard length <= data.count - payload else { return nil }
            let layer = length >= 2 ? Self.layerID(data[payload], data[payload + 1]) : nil
            units.append(Unit(range: offset..<(payload + length), layer: layer))
            offset = payload + length
        }
        return units
    }

    private func annexBUnits(of data: UnsafeRawBufferPointer) -> [Unit]? {
        // Offsets of every 00 00 01; a four-byte start code's leading zero
        // stays with the unit before it, which is harmless either way.
        var starts: [Int] = []
        var index = 0
        while index + 2 < data.count {
            if data[index + 2] > 1 {
                index += 3
            } else if data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
                starts.append(index)
                index += 3
            } else {
                index += 1
            }
        }
        guard let first = starts.first else { return nil }

        var units: [Unit] = []
        if first > 0 { units.append(Unit(range: 0..<first, layer: nil)) }
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : data.count
            let header = start + 3
            let layer = header + 1 < end ? Self.layerID(data[header], data[header + 1]) : nil
            units.append(Unit(range: start..<end, layer: layer))
        }
        return units
    }

    // MARK: Extradata

    /// The codec's extradata with the enhancement layers' parameter sets
    /// removed, or nil when it has none (or cannot be parsed).
    func baseLayerExtradata(_ extradata: UnsafeRawBufferPointer) -> [UInt8]? {
        switch framing {
        case .annexB:
            guard let ranges = baseLayerRanges(of: extradata) else { return nil }
            return ranges.flatMap { Array(extradata[$0]) }
        case .lengthPrefixed:
            return Self.baseLayerHVCC(extradata)
        }
    }

    /// Rewrites an `hvcC` record (ISO/IEC 14496-15 §8.3.3), dropping
    /// enhancement-layer NAL units and any array they leave empty.
    static func baseLayerHVCC(_ hvcC: UnsafeRawBufferPointer) -> [UInt8]? {
        guard hvcC.count >= 23 else { return nil }
        var arrays: [[UInt8]] = []
        var dropped = false
        var offset = 23
        for _ in 0..<Int(hvcC[22]) {
            guard offset + 3 <= hvcC.count else { return nil }
            let arrayHeader = hvcC[offset]
            let count = Int(hvcC[offset + 1]) << 8 | Int(hvcC[offset + 2])
            offset += 3

            var nalUnits: [[UInt8]] = []
            for _ in 0..<count {
                guard offset + 2 <= hvcC.count else { return nil }
                let length = Int(hvcC[offset]) << 8 | Int(hvcC[offset + 1])
                let end = offset + 2 + length
                guard end <= hvcC.count else { return nil }
                if length >= 2, layerID(hvcC[offset + 2], hvcC[offset + 3]) > 0 {
                    dropped = true
                } else {
                    nalUnits.append(Array(hvcC[offset..<end]))
                }
                offset = end
            }
            guard !nalUnits.isEmpty else { continue }
            arrays.append([arrayHeader, UInt8(nalUnits.count >> 8), UInt8(nalUnits.count & 0xff)] + nalUnits.joined())
        }
        guard dropped else { return nil }

        var result = Array(hvcC[0..<22])
        result.append(UInt8(arrays.count))
        for array in arrays { result += array }
        // Anything after the arrays is not ours to interpret; keep it.
        if offset < hvcC.count { result += hvcC[offset...] }
        return result
    }
}

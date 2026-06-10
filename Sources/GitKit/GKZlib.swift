import Foundation

// MARK: - Zlib Compression (Pure Swift Deflate/Inflate)

/// Pure Swift zlib compression and decompression.
/// Git stores objects using zlib (deflate) compression.
enum GKZlib {
    /// Decompresses zlib-compressed data.
    /// - Parameter data: Zlib-compressed data (with 2-byte header).
    /// - Returns: The decompressed data.
    /// - Throws: `GKError.zlibError` if decompression fails.
    static func decompress(_ data: Data) throws -> Data {
        // Verify zlib header
        guard data.count >= 6 else {
            throw GKError.zlibError("Data too short for zlib format")
        }

        let cmf = data[data.startIndex]
        let flg = data[data.startIndex + 1]

        // CMF low nibble must be 8 (deflate method)
        guard (cmf & 0x0F) == 8 else {
            throw GKError.zlibError("Invalid zlib compression method: \(cmf & 0x0F)")
        }

        guard (UInt16(cmf) * 256 + UInt16(flg)) % 31 == 0 else {
            throw GKError.zlibError("Invalid zlib header checksum")
        }

        // Skip 2-byte zlib header, inflate the deflate stream
        let deflateData = data.dropFirst(2)
        return try inflate(Array(deflateData))
    }

    /// Decompresses a raw deflate stream (no zlib header) and returns
    /// both the decompressed data and the number of compressed bytes consumed.
    /// Useful for packfile parsing where streams are concatenated.
    static func inflateRaw(_ bytes: [UInt8]) throws -> (data: Data, bytesRead: Int) {
        var reader = BitReader(data: bytes)
        let output = try inflateStream(reader: &reader)
        return (output, reader.totalBytesConsumed)
    }

    /// Compresses data using zlib (deflate with zlib wrapper).
    /// - Parameter data: The data to compress.
    /// - Returns: Zlib-compressed data.
    static func compress(_ data: Data) throws -> Data {
        var result = Data()

        // Zlib header: CMF=0x78 (deflate, window=32K), FLG=0x01 (no dict, level 0)
        let cmf: UInt8 = 0x78
        let flg: UInt8 = 0x01
        result.append(cmf)
        result.append(flg)

        // Use stored blocks (no compression) for simplicity
        // This is valid deflate — just not optimally compressed
        let bytes = Array(data)
        var offset = 0

        while offset < bytes.count {
            let remaining = bytes.count - offset
            let blockSize = min(remaining, 65535)
            let isFinal: UInt8 = (offset + blockSize >= bytes.count) ? 0x01 : 0x00

            // Block header: BFINAL=isFinal, BTYPE=00 (no compression)
            result.append(isFinal)

            // LEN and NLEN (little-endian)
            let len = UInt16(blockSize)
            let nlen = ~len
            result.append(UInt8(len & 0xFF))
            result.append(UInt8(len >> 8))
            result.append(UInt8(nlen & 0xFF))
            result.append(UInt8(nlen >> 8))

            // Literal data
            result.append(contentsOf: bytes[offset..<offset + blockSize])
            offset += blockSize
        }

        if bytes.isEmpty {
            // Empty input: single final stored block with length 0
            result.append(0x01) // BFINAL=1, BTYPE=00
            result.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF])
        }

        // Adler-32 checksum
        let checksum = adler32(data)
        result.append(UInt8((checksum >> 24) & 0xFF))
        result.append(UInt8((checksum >> 16) & 0xFF))
        result.append(UInt8((checksum >> 8) & 0xFF))
        result.append(UInt8(checksum & 0xFF))

        return result
    }

    // MARK: - Inflate (Deflate Decompression)

    private static func inflate(_ bytes: [UInt8]) throws -> Data {
        var reader = BitReader(data: bytes)
        return try inflateStream(reader: &reader)
    }

    private static func inflateStream(reader: inout BitReader) throws -> Data {
        var output = Data()

        var isFinal = false
        while !isFinal {
            isFinal = try reader.readBit() == 1
            let blockType = try reader.readBits(2)

            switch blockType {
            case 0:
                // No compression (stored block)
                reader.alignToByte()
                let len = try reader.readUInt16LE()
                let _ = try reader.readUInt16LE() // NLEN
                let blockData = try reader.readBytes(Int(len))
                output.append(contentsOf: blockData)

            case 1:
                // Fixed Huffman codes
                try inflateHuffmanBlock(reader: &reader, output: &output,
                                        litLenTree: HuffmanTree.fixedLitLen,
                                        distTree: HuffmanTree.fixedDist)

            case 2:
                // Dynamic Huffman codes
                let (litLenTree, distTree) = try decodeDynamicTrees(reader: &reader)
                try inflateHuffmanBlock(reader: &reader, output: &output,
                                        litLenTree: litLenTree, distTree: distTree)

            default:
                throw GKError.zlibError("Invalid deflate block type: \(blockType)")
            }
        }

        return output
    }

    private static func inflateHuffmanBlock(
        reader: inout BitReader,
        output: inout Data,
        litLenTree: HuffmanTree,
        distTree: HuffmanTree
    ) throws {
        while true {
            let symbol = try litLenTree.decode(reader: &reader)

            if symbol == 256 {
                break // End of block
            } else if symbol < 256 {
                output.append(UInt8(symbol))
            } else {
                // Length/distance pair
                let length = try decodeLength(symbol: symbol, reader: &reader)
                let distSymbol = try distTree.decode(reader: &reader)
                let distance = try decodeDistance(symbol: distSymbol, reader: &reader)

                // Copy from back-reference (byte-by-byte for overlapping copies)
                let startIdx = output.count - distance
                guard startIdx >= 0 else {
                    throw GKError.zlibError("Invalid back-reference distance \(distance) with output size \(output.count)")
                }
                for i in 0..<length {
                    output.append(output[startIdx + i])
                }
            }
        }
    }

    // MARK: - Huffman Tree (Canonical, Lookup-Table Based)

    /// A canonical Huffman tree built from code lengths.
    /// Uses a flat lookup table for fast decoding.
    private struct HuffmanTree {
        /// For each (bitLength, code) pair we store the symbol.
        /// Organized as: for each bit length, the symbols in code-order.
        private let symbolsByLength: [[Int]] // index = bitLength (1...maxBits)
        private let firstCodes: [Int]        // first canonical code at each bit length
        private let maxBits: Int

        static let fixedLitLen: HuffmanTree = {
            var lengths = [Int](repeating: 0, count: 288)
            for i in 0...143 { lengths[i] = 8 }
            for i in 144...255 { lengths[i] = 9 }
            for i in 256...279 { lengths[i] = 7 }
            for i in 280...287 { lengths[i] = 8 }
            return HuffmanTree(lengths: lengths)
        }()

        static let fixedDist: HuffmanTree = {
            let lengths = [Int](repeating: 5, count: 32)
            return HuffmanTree(lengths: lengths)
        }()

        init(lengths: [Int]) {
            let maxBits = lengths.max() ?? 0
            self.maxBits = maxBits

            guard maxBits > 0 else {
                self.symbolsByLength = []
                self.firstCodes = []
                return
            }

            // Count codes of each length
            var blCount = [Int](repeating: 0, count: maxBits + 1)
            for len in lengths where len > 0 {
                blCount[len] += 1
            }

            // Compute first code for each bit length (canonical Huffman)
            var firstCode = [Int](repeating: 0, count: maxBits + 1)
            var code = 0
            for bits in 1...maxBits {
                code = (code + blCount[bits - 1]) << 1
                firstCode[bits] = code
            }
            self.firstCodes = firstCode

            // Collect symbols grouped by their bit length, in code-order
            // Within the same bit length, symbols with lower numeric value come first
            // (canonical Huffman assignment)
            var byLength = [[Int]](repeating: [], count: maxBits + 1)
            for (symbol, len) in lengths.enumerated() where len > 0 {
                byLength[len].append(symbol)
            }
            self.symbolsByLength = byLength
        }

        func decode(reader: inout BitReader) throws -> Int {
            guard maxBits > 0 else {
                throw GKError.zlibError("Cannot decode from empty Huffman tree")
            }

            var code = 0
            for bits in 1...maxBits {
                code = (code << 1) | (try reader.readBit())

                let syms = symbolsByLength[bits]
                guard !syms.isEmpty else { continue }

                let first = firstCodes[bits]
                let index = code - first
                if index >= 0 && index < syms.count {
                    return syms[index]
                }
            }

            throw GKError.zlibError("Invalid Huffman code")
        }
    }

    // MARK: - Bit Reader

    private struct BitReader {
        private let data: [UInt8]
        private var bytePos: Int = 0
        private var bitPos: Int = 0

        init(data: [UInt8]) {
            self.data = data
        }

        /// The total number of bytes consumed so far (rounded up if mid-byte).
        var totalBytesConsumed: Int {
            bitPos > 0 ? bytePos + 1 : bytePos
        }

        mutating func readBit() throws -> Int {
            guard bytePos < data.count else {
                throw GKError.zlibError("Unexpected end of deflate stream")
            }
            let bit = Int((data[bytePos] >> bitPos) & 1)
            bitPos += 1
            if bitPos == 8 {
                bitPos = 0
                bytePos += 1
            }
            return bit
        }

        mutating func readBits(_ count: Int) throws -> Int {
            var value = 0
            for i in 0..<count {
                value |= (try readBit()) << i
            }
            return value
        }

        mutating func alignToByte() {
            if bitPos > 0 {
                bitPos = 0
                bytePos += 1
            }
        }

        mutating func readUInt16LE() throws -> UInt16 {
            guard bytePos + 1 < data.count else {
                throw GKError.zlibError("Unexpected end of data")
            }
            let value = UInt16(data[bytePos]) | (UInt16(data[bytePos + 1]) << 8)
            bytePos += 2
            return value
        }

        mutating func readBytes(_ count: Int) throws -> [UInt8] {
            guard bytePos + count <= data.count else {
                throw GKError.zlibError("Unexpected end of data")
            }
            let result = Array(data[bytePos..<bytePos + count])
            bytePos += count
            return result
        }
    }

    // MARK: - Length/Distance Tables

    private static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
    ]

    private static let lengthExtra: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
    ]

    private static let distBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
    ]

    private static let distExtra: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
    ]

    private static func decodeLength(symbol: Int, reader: inout BitReader) throws -> Int {
        let index = symbol - 257
        guard index >= 0 && index < lengthBase.count else {
            throw GKError.zlibError("Invalid length symbol: \(symbol)")
        }
        let base = lengthBase[index]
        let extra = lengthExtra[index]
        let extraBits = extra > 0 ? try reader.readBits(extra) : 0
        return base + extraBits
    }

    private static func decodeDistance(symbol: Int, reader: inout BitReader) throws -> Int {
        guard symbol >= 0 && symbol < distBase.count else {
            throw GKError.zlibError("Invalid distance symbol: \(symbol)")
        }
        let base = distBase[symbol]
        let extra = distExtra[symbol]
        let extraBits = extra > 0 ? try reader.readBits(extra) : 0
        return base + extraBits
    }

    private static func decodeDynamicTrees(reader: inout BitReader) throws -> (HuffmanTree, HuffmanTree) {
        let hlit = try reader.readBits(5) + 257
        let hdist = try reader.readBits(5) + 1
        let hclen = try reader.readBits(4) + 4

        let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [Int](repeating: 0, count: 19)

        for i in 0..<hclen {
            codeLengths[codeLengthOrder[i]] = try reader.readBits(3)
        }

        let codeLenTree = HuffmanTree(lengths: codeLengths)

        var lengths = [Int]()
        lengths.reserveCapacity(hlit + hdist)
        let totalCodes = hlit + hdist

        while lengths.count < totalCodes {
            let sym = try codeLenTree.decode(reader: &reader)
            switch sym {
            case 0..<16:
                lengths.append(sym)
            case 16:
                guard let last = lengths.last else {
                    throw GKError.zlibError("Code length 16 with no previous length")
                }
                let count = try reader.readBits(2) + 3
                lengths.append(contentsOf: [Int](repeating: last, count: count))
            case 17:
                let count = try reader.readBits(3) + 3
                lengths.append(contentsOf: [Int](repeating: 0, count: count))
            case 18:
                let count = try reader.readBits(7) + 11
                lengths.append(contentsOf: [Int](repeating: 0, count: count))
            default:
                throw GKError.zlibError("Invalid code length symbol: \(sym)")
            }
        }

        let litLenLengths = Array(lengths.prefix(hlit))
        let distLengths = Array(lengths.dropFirst(hlit).prefix(hdist))

        return (HuffmanTree(lengths: litLenLengths), HuffmanTree(lengths: distLengths))
    }

    // MARK: - Adler-32

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let mod: UInt32 = 65521

        for byte in data {
            a = (a + UInt32(byte)) % mod
            b = (b + a) % mod
        }

        return (b << 16) | a
    }
}

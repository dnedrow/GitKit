import Foundation

// MARK: - SHA-1 Implementation (Pure Swift)

/// Pure Swift SHA-1 hash implementation.
/// Used internally by GitKit to compute object IDs without external dependencies.
enum GKSHA1 {
    /// Computes the SHA-1 hash of the given data.
    /// - Parameter data: The input data to hash.
    /// - Returns: A 20-byte SHA-1 digest.
    static func hash(_ data: Data) -> [UInt8] {
        hash(Array(data))
    }

    /// Computes the SHA-1 hash of the given bytes.
    /// - Parameter bytes: The input bytes to hash.
    /// - Returns: A 20-byte SHA-1 digest.
    static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        // Pre-processing: adding padding bits
        var message = bytes
        let originalLength = message.count
        message.append(0x80)

        while message.count % 64 != 56 {
            message.append(0x00)
        }

        // Append original length in bits as 64-bit big-endian
        let bitLength = UInt64(originalLength) * 8
        for i in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> i))
        }

        // Process each 512-bit block
        let blockCount = message.count / 64
        for block in 0..<blockCount {
            let offset = block * 64
            var w = [UInt32](repeating: 0, count: 80)

            for i in 0..<16 {
                let j = offset + i * 4
                w[i] = UInt32(message[j]) << 24
                    | UInt32(message[j + 1]) << 16
                    | UInt32(message[j + 2]) << 8
                    | UInt32(message[j + 3])
            }

            for i in 16..<80 {
                w[i] = leftRotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], by: 1)
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4

            for i in 0..<80 {
                let f: UInt32
                let k: UInt32

                switch i {
                case 0..<20:
                    f = (b & c) | ((~b) & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }

                let temp = leftRotate(a, by: 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = leftRotate(b, by: 30)
                b = a
                a = temp
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }

        // Produce the final hash value (big-endian)
        var digest = [UInt8](repeating: 0, count: 20)
        for i in 0..<4 {
            digest[i] = UInt8(truncatingIfNeeded: h0 >> (24 - i * 8))
            digest[i + 4] = UInt8(truncatingIfNeeded: h1 >> (24 - i * 8))
            digest[i + 8] = UInt8(truncatingIfNeeded: h2 >> (24 - i * 8))
            digest[i + 12] = UInt8(truncatingIfNeeded: h3 >> (24 - i * 8))
            digest[i + 16] = UInt8(truncatingIfNeeded: h4 >> (24 - i * 8))
        }

        return digest
    }

    private static func leftRotate(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}

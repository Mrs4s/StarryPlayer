import CommonCrypto
import CryptoKit
import Foundation
import Security
import zlib

enum PluginCrypto {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func hash(_ algorithm: String, _ data: Data) throws -> Data {
        switch algorithm {
        case "md5": Data(Insecure.MD5.hash(data: data))
        case "sha1": Data(Insecure.SHA1.hash(data: data))
        case "sha256": Data(SHA256.hash(data: data))
        case "sha384": Data(SHA384.hash(data: data))
        case "sha512": Data(SHA512.hash(data: data))
        default: throw Failure(message: "不支持的摘要算法：\(algorithm)")
        }
    }

    static func hmac(_ algorithm: String, key: Data, _ data: Data) throws -> Data {
        let key = SymmetricKey(data: key)
        switch algorithm {
        case "md5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: key))
        case "sha1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
        case "sha256": return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case "sha384": return Data(HMAC<SHA384>.authenticationCode(for: data, using: key))
        case "sha512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: key))
        default: throw Failure(message: "不支持的 HMAC 算法：\(algorithm)")
        }
    }

    struct Cipher {
        var algorithm: String
        var mode: String
        var decrypt: Bool
        var key: Data
        var iv: Data?
        var aad: Data?
        var padding: Bool
    }

    static func run(_ cipher: Cipher, _ data: Data) throws -> Data {
        if cipher.mode == "gcm" {
            guard cipher.algorithm == "aes" else { throw Failure(message: "GCM 只支持 AES") }
            return try gcm(cipher, data)
        }
        guard ["ecb", "cbc"].contains(cipher.mode) else { throw Failure(message: "不支持的模式：\(cipher.mode)") }
        let algorithm: CCAlgorithm
        let blockSize: Int
        var key = cipher.key
        switch cipher.algorithm {
        case "aes":
            guard [16, 24, 32].contains(key.count) else { throw Failure(message: "AES 密钥须为 16、24 或 32 字节，而不是 \(key.count)") }
            algorithm = CCAlgorithm(kCCAlgorithmAES)
            blockSize = kCCBlockSizeAES128
        case "des":
            guard key.count == 8 else { throw Failure(message: "DES 密钥须为 8 字节") }
            algorithm = CCAlgorithm(kCCAlgorithmDES)
            blockSize = kCCBlockSizeDES
        case "3des":
            if key.count == 16 { key += key.prefix(8) }
            guard key.count == 24 else { throw Failure(message: "3DES 密钥须为 16 或 24 字节") }
            algorithm = CCAlgorithm(kCCAlgorithm3DES)
            blockSize = kCCBlockSize3DES
        default:
            throw Failure(message: "不支持的算法：\(cipher.algorithm)")
        }
        if !cipher.padding, data.count % blockSize != 0 { throw Failure(message: "不填充时数据长度须为 \(blockSize) 的倍数") }
        var options = CCOptions(0)
        if cipher.padding { options |= CCOptions(kCCOptionPKCS7Padding) }
        if cipher.mode == "ecb" { options |= CCOptions(kCCOptionECBMode) }
        let iv = cipher.mode == "cbc" ? (cipher.iv ?? Data(count: blockSize)) : nil
        if let iv, iv.count != blockSize { throw Failure(message: "IV 须为 \(blockSize) 字节") }
        var output = Data(count: data.count + blockSize)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    withIV(iv) { iv in
                        CCCrypt(CCOperation(cipher.decrypt ? kCCDecrypt : kCCEncrypt), algorithm, options,
                                key.baseAddress, key.count, iv,
                                input.baseAddress, input.count,
                                out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure(message: cipher.decrypt ? "解密失败（密钥、IV 或填充不对）" : "加密失败（\(status)）") }
        return output.prefix(written)
    }

    private static func withIV<T>(_ iv: Data?, _ body: (UnsafeRawPointer?) -> T) -> T {
        guard let iv else { return body(nil) }
        return iv.withUnsafeBytes { body($0.baseAddress) }
    }

    /// AES-GCM layout is ciphertext followed by a 16-byte tag, matching WebCrypto.
    private static func gcm(_ cipher: Cipher, _ data: Data) throws -> Data {
        guard [16, 24, 32].contains(cipher.key.count) else { throw Failure(message: "AES 密钥须为 16、24 或 32 字节") }
        guard let iv = cipher.iv, let nonce = try? AES.GCM.Nonce(data: iv) else { throw Failure(message: "GCM 需要 iv（通常 12 字节）") }
        let key = SymmetricKey(data: cipher.key)
        let aad = cipher.aad ?? Data()
        do {
            if cipher.decrypt {
                guard data.count >= 16 else { throw Failure(message: "数据比认证标签还短") }
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
                return try AES.GCM.open(box, using: key, authenticating: aad)
            }
            let box = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: aad)
            return box.ciphertext + box.tag
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: cipher.decrypt ? "GCM 解密失败（认证不通过）" : "GCM 加密失败")
        }
    }

    static func rsaEncrypt(_ data: Data, publicKey: String, padding: String) throws -> Data {
        let key = try rsaKey(publicKey)
        let algorithm: SecKeyAlgorithm
        var input = data
        switch padding {
        case "pkcs1": algorithm = .rsaEncryptionPKCS1
        case "oaep": algorithm = .rsaEncryptionOAEPSHA1
        case "none":
            algorithm = .rsaEncryptionRaw
            let size = SecKeyGetBlockSize(key)
            guard input.count <= size else { throw Failure(message: "数据比 RSA 密钥长") }
            input = Data(count: size - input.count) + input
        default: throw Failure(message: "不支持的 RSA 填充：\(padding)")
        }
        var error: Unmanaged<CFError>?
        guard let output = SecKeyCreateEncryptedData(key, algorithm, input as CFData, &error) else {
            throw Failure(message: "RSA 加密失败：\(error?.takeRetainedValue().localizedDescription ?? "")")
        }
        return output as Data
    }

    private static func rsaKey(_ text: String) throws -> SecKey {
        let base64 = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined().filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: base64) else { throw Failure(message: "不是 PEM 公钥") }
        let pkcs1 = subjectPublicKey(in: [UInt8](der)).map { Data($0) } ?? der
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw Failure(message: "读不出 RSA 公钥：\(error?.takeRetainedValue().localizedDescription ?? "")")
        }
        return key
    }

    /// The RSAPublicKey inside a SubjectPublicKeyInfo, or nil when `der` is not one.
    private static func subjectPublicKey(in der: [UInt8]) -> [UInt8]? {
        var outer = DERReader(der)
        guard let info = outer.read(tag: 0x30) else { return nil }
        var inner = DERReader(info)
        guard inner.read(tag: 0x30) != nil, let bits = inner.read(tag: 0x03), bits.first == 0 else { return nil }
        return Array(bits.dropFirst())
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        guard count > 0 else { return data }
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
}

private struct DERReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func read(tag: UInt8) -> [UInt8]? {
        guard index + 2 <= bytes.count, bytes[index] == tag else { return nil }
        var length = Int(bytes[index + 1])
        var start = index + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, start + count <= bytes.count else { return nil }
            length = bytes[start..<start + count].reduce(0) { $0 << 8 | Int($1) }
            start += count
        }
        guard start + length <= bytes.count else { return nil }
        index = start + length
        return Array(bytes[start..<start + length])
    }
}

enum PluginZlib {
    struct Failure: Error, LocalizedError {
        var status: Int32
        var errorDescription: String? { "zlib 数据损坏（\(status)）" }
    }

    static func inflate(_ data: Data) throws -> Data {
        do {
            return try run(data, windowBits: 15 + 32, inflating: true)
        } catch {
            return try run(data, windowBits: -15, inflating: true)
        }
    }

    static func deflate(_ data: Data, format: String) throws -> Data {
        let windowBits: Int32 = switch format {
        case "gzip": 15 + 16
        case "raw": -15
        default: 15
        }
        return try run(data, windowBits: windowBits, inflating: false)
    }

    private static func run(_ data: Data, windowBits: Int32, inflating: Bool) throws -> Data {
        var stream = z_stream()
        let size = Int32(MemoryLayout<z_stream>.size)
        let initStatus = inflating
            ? inflateInit2_(&stream, windowBits, ZLIB_VERSION, size)
            : deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, size)
        guard initStatus == Z_OK else { throw Failure(status: initStatus) }
        defer { if inflating { inflateEnd(&stream) } else { deflateEnd(&stream) } }
        var input = [UInt8](data)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let status: Int32 = input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)
            var status: Int32 = Z_OK
            while status == Z_OK {
                status = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let result = inflating ? zlib.inflate(&stream, Z_NO_FLUSH) : zlib.deflate(&stream, Z_FINISH)
                    output.append(buffer.baseAddress!, count: buffer.count - Int(stream.avail_out))
                    return result
                }
                if inflating, status == Z_BUF_ERROR || (status == Z_OK && stream.avail_in == 0 && stream.avail_out != 0) { break }
            }
            return status
        }
        guard status == Z_STREAM_END else { throw Failure(status: status) }
        return output
    }
}

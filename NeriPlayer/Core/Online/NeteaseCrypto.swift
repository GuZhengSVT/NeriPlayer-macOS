// NeteaseCrypto.swift
// M5-T1: compatibility-safe NetEase WEAPI encryption primitives.
// AES uses the system CommonCrypto implementation; RSA uses Security's raw RSA
// operation, matching the Android client without third-party crypto dependencies.
import CommonCrypto
import CryptoKit
import Foundation
import Security

enum NeteaseCrypto {
    private static let presetKey = Data("0CoJUm6Qyw8W8jud".utf8)
    private static let iv = Data("0102030405060708".utf8)
    private static let publicKey = """
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFb
    t7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZ
    MldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB
    """
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)

    static func weAPI(payload: [String: Any], secretKey: Data? = nil) throws -> [String: String] {
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let secret = try secretKey ?? randomKey()
        guard secret.count == 16 else { throw NeteaseCryptoError.invalidKey }
        let first = try aes(json, key: presetKey, iv: iv).base64EncodedString()
        let second = try aes(Data(first.utf8), key: secret, iv: iv)
        return ["params": second.base64EncodedString(), "encSecKey": try rsaRaw(Data(secret.reversed()))]
    }

    private static func randomKey() throws -> Data {
        var key: [UInt8] = []
        while key.count < 16 {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { throw NeteaseCryptoError.randomFailed }
            // Rejection sampling avoids modulo bias over the 62-character alphabet.
            if byte < 248 { key.append(alphabet[Int(byte) % alphabet.count]) }
        }
        return Data(key)
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func eAPI(path: String, payload: [String: Any]) throws -> [String: String] {
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let content = String(bytes: json, encoding: .utf8) ?? "{}"
        let digest = md5(Data("nobody\(path)use\(content)md5forencrypt".utf8))
        let message = Data("\(path)-36cd479b6b5-\(content)-36cd479b6b5-\(digest)".utf8)
        let encrypted = try aes(message, key: Data("e82ckenh8dichen8".utf8), iv: Data(), ecb: true)
        return ["params": encrypted.map { String(format: "%02X", $0) }.joined()]
    }

    private static func aes(_ data: Data, key: Data, iv: Data, ecb: Bool = false) throws -> Data {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var length = 0
        let status = data.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | (ecb ? kCCOptionECBMode : 0)),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, data.count,
                            &output, output.count, &length)
                }
            }
        }
        guard status == kCCSuccess else { throw NeteaseCryptoError.aesFailed(status) }
        return Data(output.prefix(length))
    }

    private static func rsaRaw(_ reversed: Data) throws -> String {
        guard let der = Data(base64Encoded: publicKey.filter { !$0.isWhitespace }) else { throw NeteaseCryptoError.rsaFailed }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024
        ]
        // Security imports PKCS#1 public keys, while the published key is SPKI.
        let pkcs1 = try rsaPublicKey(from: der)
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionRaw) else { throw NeteaseCryptoError.rsaFailed }
        let blockSize = SecKeyGetBlockSize(key)
        guard reversed.count < blockSize else { throw NeteaseCryptoError.invalidKey }
        let message = Data(repeating: 0, count: blockSize - reversed.count) + reversed
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, message as CFData, nil) as Data? else {
            throw NeteaseCryptoError.rsaFailed
        }
        return encrypted.map { String(format: "%02x", $0) }.joined()
    }

    private static func rsaPublicKey(from data: Data) throws -> Data {
        let bytes = Array(data)
        var cursor = 0
        func readElement(_ expectedTag: UInt8) throws -> Range<Int> {
            guard cursor + 2 <= bytes.count, bytes[cursor] == expectedTag else { throw NeteaseCryptoError.rsaFailed }
            cursor += 1
            var length = Int(bytes[cursor])
            cursor += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, cursor + count <= bytes.count else { throw NeteaseCryptoError.rsaFailed }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[cursor]); cursor += 1 }
            }
            guard length <= bytes.count - cursor else { throw NeteaseCryptoError.rsaFailed }
            return cursor..<(cursor + length)
        }
        _ = try readElement(0x30)
        let algorithm = try readElement(0x30)
        cursor = algorithm.upperBound
        let bitString = try readElement(0x03)
        guard !bitString.isEmpty, bytes[bitString.lowerBound] == 0 else { throw NeteaseCryptoError.rsaFailed }
        return Data(bytes[(bitString.lowerBound + 1)..<bitString.upperBound])
    }
}

enum NeteaseCryptoError: Error { case aesFailed(CCCryptorStatus); case rsaFailed; case invalidKey; case randomFailed }

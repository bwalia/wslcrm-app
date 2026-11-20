import CommonCrypto
import CryptoKit
import Foundation

/// A key pair for a web terminal, made on this phone (docs/AI_RUNNER_WEB_TERMINAL.md §10), exactly as the
/// dashboard makes it in the browser: an ed25519 key, the private half an OpenSSH key file locked with a
/// passphrase (bcrypt KDF, 16 rounds, aes256-ctr — what `ssh-keygen -N` writes). Only the public half is
/// sent to OpsAPI; the file and its passphrase are shown once, to hand over.
struct AITerminalKey: Sendable, Hashable {
    /// `ssh-ed25519 AAAA… comment` — the only part sent to OpsAPI.
    let publicKey: String
    /// The passphrase-locked OpenSSH private key file.
    let privateKey: String
    let passphrase: String
}

enum AITerminalKeyMaker {
    static let rounds: UInt32 = 16
    /// No look-alikes (0/o, 1/l/i): it's read out or typed by hand.
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    enum Failure: Error { case random, cipher }

    /// A key pair; `comment` names it inside the files (the person's email).
    static func make(comment: String, passphrase: String? = nil) throws -> AITerminalKey {
        let pass = try passphrase ?? newPassphrase()
        let signing = Curve25519.Signing.PrivateKey()
        let seed = signing.rawRepresentation
        let pub = signing.publicKey.rawRepresentation
        return try encode(seed: [UInt8](seed), publicKey: [UInt8](pub), comment: comment, passphrase: pass,
                          salt: random(16), check: random(4))
    }

    /// 6 groups of 4 letters/digits (~119 bits), e.g. "k7m3-x9q2-…".
    static func newPassphrase() throws -> String {
        var out: [Character] = []
        while out.count < 24 {
            for b in try random(32) where b < 248 && out.count < 24 {  // 248 = 8 × 31: every character equally likely
                out.append(alphabet[Int(b) % alphabet.count])
            }
        }
        return stride(from: 0, to: 24, by: 4).map { String(out[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// The files for a key (deterministic given salt and check bytes, so it can be tested).
    static func encode(seed: [UInt8], publicKey pub: [UInt8], comment: String, passphrase: String, salt: [UInt8],
                       check: [UInt8]) throws -> AITerminalKey {
        let pubBlob = sshString("ssh-ed25519") + sshString(pub)
        var secret = check + check + sshString("ssh-ed25519") + sshString(pub) + sshString(seed + pub) + sshString(comment)
        var pad: UInt8 = 1
        while secret.count % 16 != 0 { secret.append(pad); pad += 1 }
        let derived = BcryptPBKDF.derive(password: Array(passphrase.utf8), salt: salt, length: 48, rounds: rounds)
        let sealed = try aes256CTR(key: Array(derived[0..<32]), iv: Array(derived[32..<48]), data: secret)
        let file = Array("openssh-key-v1\0".utf8) + sshString("aes256-ctr") + sshString("bcrypt")
            + sshString(sshString(salt) + u32(rounds)) + u32(1) + sshString(pubBlob) + sshString(sealed)
        let base64 = Data(file).base64EncodedString()
        var lines: [String] = []
        var rest = Substring(base64)
        while !rest.isEmpty {
            lines.append(String(rest.prefix(70)))
            rest = rest.dropFirst(70)
        }
        return AITerminalKey(
            publicKey: "ssh-ed25519 \(Data(pubBlob).base64EncodedString()) \(comment)",
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n\(lines.joined(separator: "\n"))\n-----END OPENSSH PRIVATE KEY-----\n",
            passphrase: passphrase)
    }

    // MARK: Pieces

    static func u32(_ n: UInt32) -> [UInt8] {
        [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
    }

    /// An SSH wire-format string: uint32 length + bytes.
    static func sshString(_ data: [UInt8]) -> [UInt8] { u32(UInt32(data.count)) + data }
    static func sshString(_ text: String) -> [UInt8] { sshString(Array(text.utf8)) }

    static func random(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw Failure.random }
        return bytes
    }

    static func aes256CTR(key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        var cryptor: CCCryptorRef?
        guard CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                      CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
                                      CCModeOptions(kCCModeOptionCTR_BE), &cryptor) == kCCSuccess, let cryptor else {
            throw Failure.cipher
        }
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        guard CCCryptorUpdate(cryptor, data, data.count, &out, out.count, &moved) == kCCSuccess, moved == data.count else {
            throw Failure.cipher
        }
        return out
    }
}

/// OpenBSD's bcrypt_pbkdf (what OpenSSH uses to lock a key file with a passphrase).
enum BcryptPBKDF {
    static func derive(password: [UInt8], salt: [UInt8], length: Int, rounds: UInt32) -> [UInt8] {
        let sha2pass = [UInt8](SHA512.hash(data: password))
        let stride = (length + 32 - 1) / 32
        var amount = (length + stride - 1) / stride
        var key = [UInt8](repeating: 0, count: length)
        var remaining = length
        var count: UInt32 = 1
        while remaining > 0 {
            var sha2salt = [UInt8](SHA512.hash(data: salt + AITerminalKeyMaker.u32(count)))
            var out = bcryptHash(sha2pass, sha2salt)
            var tmp = out
            if rounds > 1 {
                for _ in 1..<rounds {
                    sha2salt = [UInt8](SHA512.hash(data: tmp))
                    tmp = bcryptHash(sha2pass, sha2salt)
                    for i in 0..<out.count { out[i] ^= tmp[i] }
                }
            }
            amount = min(amount, remaining)
            var written = 0
            for i in 0..<amount {
                let dest = i * stride + Int(count - 1)
                if dest >= length { break }
                key[dest] = out[i]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return key
    }

    /// bcrypt's hash of a 64-byte password hash and salt hash: 32 bytes.
    static func bcryptHash(_ pass: [UInt8], _ salt: [UInt8]) -> [UInt8] {
        var state = Blowfish()
        state.expandState(data: salt, key: pass)
        for _ in 0..<64 {
            state.expand0State(key: salt)
            state.expand0State(key: pass)
        }
        let ciphertext = Array("OxychromaticBlowfishSwatDynamite".utf8)
        var cdata = [UInt32](repeating: 0, count: 8)
        var j = 0
        for i in 0..<8 { cdata[i] = Blowfish.streamToWord(ciphertext, &j) }
        for _ in 0..<64 {
            for block in 0..<4 {
                var l = cdata[block * 2], r = cdata[block * 2 + 1]
                state.encipher(&l, &r)
                cdata[block * 2] = l
                cdata[block * 2 + 1] = r
            }
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            out[4 * i + 3] = UInt8(cdata[i] >> 24 & 0xFF)
            out[4 * i + 2] = UInt8(cdata[i] >> 16 & 0xFF)
            out[4 * i + 1] = UInt8(cdata[i] >> 8 & 0xFF)
            out[4 * i] = UInt8(cdata[i] & 0xFF)
        }
        return out
    }
}

/// Blowfish, with the expensive key schedule bcrypt uses. Its starting tables are the hexadecimal digits of
/// π's fraction (18 P words, then 4 × 256 S words), worked out once rather than typed in.
struct Blowfish {
    var p: [UInt32]
    var s: [UInt32]

    static let initial: [UInt32] = PiDigits.fractionWords(18 + 1024)

    init() {
        p = Array(Self.initial[0..<18])
        s = Array(Self.initial[18..<(18 + 1024)])
    }

    /// The next 4 bytes of `data` (wrapping round) as a big-endian word.
    static func streamToWord(_ data: [UInt8], _ j: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            if j >= data.count { j = 0 }
            word = word << 8 | UInt32(data[j])
            j += 1
        }
        return word
    }

    func encipher(_ xl: inout UInt32, _ xr: inout UInt32) {
        s.withUnsafeBufferPointer { s in
            p.withUnsafeBufferPointer { p in
                Self.encipher(&xl, &xr, p, s)
            }
        }
    }

    @inline(__always)
    static func encipher(_ xl: inout UInt32, _ xr: inout UInt32, _ p: UnsafeBufferPointer<UInt32>,
                         _ s: UnsafeBufferPointer<UInt32>) {
        @inline(__always) func f(_ x: UInt32) -> UInt32 {
            ((s[Int(x >> 24)] &+ s[0x100 + Int(x >> 16 & 0xFF)]) ^ s[0x200 + Int(x >> 8 & 0xFF)]) &+ s[0x300 + Int(x & 0xFF)]
        }
        var l = xl ^ p[0]
        var r = xr
        var n = 1
        while n <= 16 {
            r ^= f(l) ^ p[n]
            l ^= f(r) ^ p[n + 1]
            n += 2
        }
        xl = r ^ p[17]
        xr = l
    }

    mutating func expandState(data: [UInt8], key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.streamToWord(key, &j) }
        j = 0
        var l: UInt32 = 0, r: UInt32 = 0
        var table = p
        var boxes = s
        table.withUnsafeMutableBufferPointer { pp in
            boxes.withUnsafeMutableBufferPointer { ss in
                for i in Swift.stride(from: 0, to: 18, by: 2) {
                    l ^= Self.streamToWord(data, &j)
                    r ^= Self.streamToWord(data, &j)
                    Self.encipher(&l, &r, UnsafeBufferPointer(pp), UnsafeBufferPointer(ss))
                    pp[i] = l
                    pp[i + 1] = r
                }
                for k in Swift.stride(from: 0, to: 1024, by: 2) {
                    l ^= Self.streamToWord(data, &j)
                    r ^= Self.streamToWord(data, &j)
                    Self.encipher(&l, &r, UnsafeBufferPointer(pp), UnsafeBufferPointer(ss))
                    ss[k] = l
                    ss[k + 1] = r
                }
            }
        }
        p = table
        s = boxes
    }

    mutating func expand0State(key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.streamToWord(key, &j) }
        var l: UInt32 = 0, r: UInt32 = 0
        var table = p
        var boxes = s
        table.withUnsafeMutableBufferPointer { pp in
            boxes.withUnsafeMutableBufferPointer { ss in
                for i in Swift.stride(from: 0, to: 18, by: 2) {
                    Self.encipher(&l, &r, UnsafeBufferPointer(pp), UnsafeBufferPointer(ss))
                    pp[i] = l
                    pp[i + 1] = r
                }
                for k in Swift.stride(from: 0, to: 1024, by: 2) {
                    Self.encipher(&l, &r, UnsafeBufferPointer(pp), UnsafeBufferPointer(ss))
                    ss[k] = l
                    ss[k + 1] = r
                }
            }
        }
        p = table
        s = boxes
    }
}

/// π's fraction in base 2³², exactly: π = 16·atan(1/5) − 4·atan(1/239) (Machin) in fixed point, with
/// guard words so the words asked for are exact. Each word is 8 hexadecimal digits of π.
enum PiDigits {
    static func fractionWords(_ count: Int) -> [UInt32] {
        let size = count + 4  // [0] the integer part, then the fraction, then guard words
        var five = atanInverse(5, size: size)
        var other = atanInverse(239, size: size)
        multiply(&five, by: 16)
        multiply(&other, by: 4)
        subtract(&five, other)
        return Array(five[1...count])
    }

    /// atan(1/x) = Σ (−1)ᵏ / ((2k+1)·x²ᵏ⁺¹), in fixed point.
    static func atanInverse(_ x: UInt32, size: Int) -> [UInt32] {
        var power = [UInt32](repeating: 0, count: size)
        power[0] = 1
        divide(&power, by: x)  // 1/x
        var sum = power
        let square = x * x
        var k: UInt32 = 1
        while !isZero(power) {
            divide(&power, by: square)
            var term = power
            divide(&term, by: 2 * k + 1)
            if k % 2 == 1 { subtract(&sum, term) } else { add(&sum, term) }
            k += 1
        }
        return sum
    }

    static func isZero(_ a: [UInt32]) -> Bool { !a.contains { $0 != 0 } }

    static func divide(_ a: inout [UInt32], by d: UInt32) {
        var remainder: UInt64 = 0
        for i in 0..<a.count {
            let value = remainder << 32 | UInt64(a[i])
            a[i] = UInt32(value / UInt64(d))
            remainder = value % UInt64(d)
        }
    }

    static func multiply(_ a: inout [UInt32], by m: UInt32) {
        var carry: UInt64 = 0
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            let value = UInt64(a[i]) * UInt64(m) + carry
            a[i] = UInt32(value & 0xFFFF_FFFF)
            carry = value >> 32
        }
    }

    static func add(_ a: inout [UInt32], _ b: [UInt32]) {
        var carry: UInt64 = 0
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            let value = UInt64(a[i]) + UInt64(b[i]) + carry
            a[i] = UInt32(value & 0xFFFF_FFFF)
            carry = value >> 32
        }
    }

    static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: Int64 = 0
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            var value = Int64(a[i]) - Int64(b[i]) - borrow
            if value < 0 { value += 1 << 32; borrow = 1 } else { borrow = 0 }
            a[i] = UInt32(value)
        }
    }
}

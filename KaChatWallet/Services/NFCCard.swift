#if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
import CommonCrypto
import CoreNFC
import CryptoKit
import Foundation
import Security

/// Client for a KaChat-NFC card: an optional backup of a seed phrase the user already has, saved
/// and restored by tapping a Java Card. The card never generates or uses a key. It holds bytes this
/// file has already encrypted, behind a PIN. The commands and backup format are public, in
/// docs/PROTOCOL.md of https://github.com/KaspaSilver/KaChat-NFC, so a card works across apps.
enum NFCCard {
    /// Also in Info.plist under `com.apple.developer.nfc.readersession.iso7816.select-identifiers`.
    static let appletAID = Data([0xF0, 0x4B, 0x41, 0x43, 0x48, 0x41, 0x54, 0x4E, 0x46, 0x43, 0x01])

    /// Beta only until the owner decides who it's for, since everyone else would also need a card
    /// loaded through Kaspa Quick Start. iPads and Macs can't read these cards over NFC.
    static var isAvailable: Bool {
        !AppVersion.isRelease && NFCTagReaderSession.readingAvailable
    }

    static let pinLength = 6
    static let tapPrompt = "Hold your card flat against the top back of your iPhone."

    static func isValidPIN(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Runs `work` against one card inside one NFC session. A tap lasts as long as `work` does, so
    /// slow work such as key derivation belongs outside it.
    @MainActor
    static func run<T>(success: String, work: (NFCCardConnection) async throws -> T) async throws -> T {
        let host = NFCCardSessionHost()
        let connection = try await host.begin(prompt: tapPrompt)
        do {
            let result = try await work(connection)
            host.finish(message: success)
            return result
        } catch {
            host.finish(failure: error)
            throw error
        }
    }
}

enum NFCCardError: LocalizedError {
    case cancelled
    case timedOut
    case cardRemoved
    case notLoaded
    case wrongPIN(triesRemaining: Int)
    case pinBlocked
    case noBackup
    case noPIN
    case cardChanged
    case backupTooLarge
    case wrongPassphrase
    case noPassphrase
    case unreadableBackup
    case saveNotConfirmed
    case seedUnavailable
    case cardFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The scan was cancelled."
        case .timedOut:
            return "No card was found in time. Try again, and keep the card flat against the top back of your iPhone."
        case .cardRemoved:
            return "The card moved away too soon. Hold it still and try again. If a save was interrupted, your previous backup on the card is still there."
        case .notLoaded:
            return "This card doesn't have the KaChat-NFC software yet. Load it from the NFC Card page in Kaspa Quick Start."
        case .wrongPIN(let triesRemaining):
            return triesRemaining == 1
                ? "Wrong PIN. 1 try left before this card's PIN is blocked for good."
                : "Wrong PIN. \(triesRemaining) tries left."
        case .pinBlocked:
            return "This card's PIN is blocked after too many wrong tries, so any backup on it can no longer be read. Use your seed phrase instead."
        case .noBackup:
            return "There's no backup on this card."
        case .noPIN:
            return "This card has no PIN yet, so it has no backup on it."
        case .cardChanged:
            return "This isn't the card you scanned first. Start again with the card you want to use."
        case .backupTooLarge:
            return "This account's backup is too large for the card."
        case .wrongPassphrase:
            return "That passphrase doesn't match this backup. It has to be exact, including capitals and spaces."
        case .noPassphrase:
            return "This account has no passphrase, so it can't be backed up to a card."
        case .unreadableBackup:
            return "This backup can't be read. It may have been made by a newer version of KaPay."
        case .saveNotConfirmed:
            return "The save couldn't be confirmed, so don't rely on this card. Try again."
        case .seedUnavailable:
            return "This account's seed phrase couldn't be read on this device."
        case .cardFailed(let detail):
            return "The card reported a problem (\(detail)). Try again."
        }
    }
}

/// The applet's answer to SELECT.
struct NFCCardStatus {
    let pinSet: Bool
    let hasBackup: Bool
    let pinBlocked: Bool
    let triesRemaining: Int
    let maxBackup: Int
}

/// One card, for the length of one tap.
final class NFCCardConnection {
    private let tag: NFCISO7816Tag
    private let session: NFCTagReaderSession

    fileprivate init(tag: NFCISO7816Tag, session: NFCTagReaderSession) {
        self.tag = tag
        self.session = session
    }

    func setMessage(_ message: String) {
        session.alertMessage = message
    }

    @MainActor
    private func send(_ apdu: NFCISO7816APDU) async throws -> (data: Data, status: UInt16) {
        try await withCheckedThrowingContinuation { continuation in
            tag.sendCommand(apdu: apdu) { data, sw1, sw2, error in
                if let error {
                    continuation.resume(throwing: NFCCardSessionHost.mapped(error))
                } else {
                    continuation.resume(returning: (data, UInt16(sw1) << 8 | UInt16(sw2)))
                }
            }
        }
    }

    private func command(_ instruction: UInt8, p1p2: Int = 0, data: Data = Data(), responseLength: Int = -1) async throws -> Data {
        let apdu = NFCISO7816APDU(
            instructionClass: 0x80,
            instructionCode: instruction,
            p1Parameter: UInt8((p1p2 >> 8) & 0xFF),
            p2Parameter: UInt8(p1p2 & 0xFF),
            data: data,
            expectedResponseLength: responseLength
        )
        let reply = try await send(apdu)
        switch reply.status {
        case 0x9000:
            return reply.data
        case 0x63C0...0x63CF:
            throw NFCCardError.wrongPIN(triesRemaining: Int(reply.status & 0x000F))
        case 0x6983:
            throw NFCCardError.pinBlocked
        case 0x6A88:
            throw NFCCardError.noBackup
        default:
            throw NFCCardError.cardFailed(String(format: "%04X", reply.status))
        }
    }

    func select() async throws -> NFCCardStatus {
        let apdu = NFCISO7816APDU(
            instructionClass: 0x00,
            instructionCode: 0xA4,
            p1Parameter: 0x04,
            p2Parameter: 0x00,
            data: NFCCard.appletAID,
            expectedResponseLength: 256
        )
        let reply = try await send(apdu)
        guard reply.status != 0x6A82 else { throw NFCCardError.notLoaded }
        guard reply.status == 0x9000 else {
            throw NFCCardError.cardFailed(String(format: "%04X", reply.status))
        }
        let bytes = [UInt8](reply.data)
        guard bytes.count == 7, bytes[0] == 1 else { throw NFCCardError.unreadableBackup }
        return NFCCardStatus(
            pinSet: bytes[3] & 0x01 != 0,
            hasBackup: bytes[3] & 0x02 != 0,
            pinBlocked: bytes[3] & 0x04 != 0,
            triesRemaining: Int(bytes[4]),
            maxBackup: Int(bytes[5]) << 8 | Int(bytes[6])
        )
    }

    func setPIN(_ pin: String) async throws {
        _ = try await command(0x21, data: Data(pin.utf8))
    }

    func verifyPIN(_ pin: String) async throws {
        _ = try await command(0x20, data: Data(pin.utf8))
    }

    /// The card checks the hash before the new copy replaces the old one, so an interrupted save
    /// leaves the previous backup in place.
    func writeBackup(_ backup: Data) async throws {
        _ = try await command(0xD0, p1p2: backup.count)
        let chunkSize = 200
        var offset = 0
        while offset < backup.count {
            let end = min(offset + chunkSize, backup.count)
            _ = try await command(0xD1, p1p2: offset, data: backup.subdata(in: offset..<end))
            offset = end
        }
        _ = try await command(0xD2, data: Data(SHA256.hash(data: backup)))
    }

    func readBackup() async throws -> Data {
        var backup = Data()
        while true {
            let chunk = try await command(0xB0, p1p2: backup.count, responseLength: 256)
            if chunk.isEmpty { return backup }
            backup.append(chunk)
        }
    }

    func wipe() async throws {
        _ = try await command(0xE0)
    }
}

private final class NFCCardSessionHost: NSObject, NFCTagReaderSessionDelegate {
    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<NFCCardConnection, Error>?
    // A session only holds its delegate weakly, and it still reports closing after `run` returns.
    private var keepAlive: NFCCardSessionHost?

    static func mapped(_ error: Error) -> Error {
        guard let reader = error as? NFCReaderError else { return error }
        switch reader.code {
        case .readerSessionInvalidationErrorUserCanceled:
            return NFCCardError.cancelled
        case .readerSessionInvalidationErrorSessionTimeout:
            return NFCCardError.timedOut
        case .readerTransceiveErrorTagConnectionLost, .readerTransceiveErrorTagNotConnected,
             .readerTransceiveErrorRetryExceeded, .readerSessionInvalidationErrorSessionTerminatedUnexpectedly:
            return NFCCardError.cardRemoved
        default:
            return error
        }
    }

    @MainActor
    func begin(prompt: String) async throws -> NFCCardConnection {
        try await withCheckedThrowingContinuation { continuation in
            guard let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: .main) else {
                continuation.resume(throwing: NFCCardError.cardFailed("no session"))
                return
            }
            self.continuation = continuation
            self.session = session
            keepAlive = self
            session.alertMessage = prompt
            session.begin()
        }
    }

    func finish(message: String) {
        session?.alertMessage = message
        session?.invalidate()
    }

    func finish(failure: Error) {
        if case NFCCardError.cancelled = failure {
            session?.invalidate()
        } else {
            session?.invalidate(errorMessage: failure.localizedDescription)
        }
    }

    private func resolve(_ result: Result<NFCCardConnection, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        resolve(.failure(Self.mapped(error)))
        self.session = nil
        keepAlive = nil
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = "More than one card was found. Hold just one."
            session.restartPolling()
            return
        }
        guard case .iso7816(let card) = tag else {
            let problem = NFCCardError.notLoaded
            session.invalidate(errorMessage: problem.localizedDescription)
            resolve(.failure(problem))
            return
        }
        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if let error {
                let problem = Self.mapped(error)
                session.invalidate(errorMessage: problem.localizedDescription)
                self.resolve(.failure(problem))
                return
            }
            // iOS tries Info.plist's IDs in order, so anything else means the applet isn't there.
            guard card.initialSelectedAID.caseInsensitiveCompare(NFCCard.appletAID.nfcCardHex) == .orderedSame else {
                let problem = NFCCardError.notLoaded
                session.invalidate(errorMessage: problem.localizedDescription)
                self.resolve(.failure(problem))
                return
            }
            self.resolve(.success(NFCCardConnection(tag: card, session: session)))
        }
    }
}

private extension Data {
    var nfcCardHex: String { map { String(format: "%02X", $0) }.joined() }
}

/// What's encrypted on the card: everything an account needs beyond the words, because some
/// accounts can't be restored correctly from the words alone. The BIP39 passphrase is deliberately
/// not here: it's what protects the account if someone gets past the PIN. `chattingAddress` lets a
/// restore catch a mistyped passphrase, which would otherwise open a different, empty account.
struct NFCCardBackupPayload: Codable {
    var version = 2
    let words: [String]
    let chattingAddress: String
    let family: String
    let chattingAddressIndex: Int
    let alias: String
}

/// The backup format in docs/PROTOCOL.md: magic, PBKDF2 iterations, salt, nonce, then AES-256-GCM.
/// The key comes from the card's PIN, so nothing extra to remember. A six-digit PIN can be guessed
/// offline by anyone who extracts the chip, which is why the passphrase stays off the card. Key
/// derivation takes a moment, so call these away from the main thread.
enum NFCCardBackupFormat {
    private static let magic = Data("KNB1".utf8)
    private static let iterations: UInt32 = 600_000
    private static let maximumIterations: UInt32 = 10_000_000
    private static let saltLength = 16
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let headerLength = 4 + 4 + saltLength + nonceLength

    static func seal(_ payload: NFCCardBackupPayload, pin: String) throws -> Data {
        var salt = Data(count: saltLength)
        let randomStatus = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw NFCCardError.cardFailed("random") }
        let nonce = AES.GCM.Nonce()

        var header = magic
        withUnsafeBytes(of: iterations.bigEndian) { header.append(contentsOf: $0) }
        header.append(salt)
        header.append(contentsOf: nonce)

        let key = try deriveKey(password: pin, salt: salt, iterations: iterations)
        let plaintext = try JSONEncoder().encode(payload)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)
        return header + sealed.ciphertext + sealed.tag
    }

    static func open(_ backup: Data, pin: String) throws -> NFCCardBackupPayload {
        let bytes = Data(backup)
        guard bytes.count > headerLength + tagLength, bytes.prefix(4) == magic else {
            throw NFCCardError.unreadableBackup
        }
        let count = bytes.subdata(in: 4..<8).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard count >= iterations, count <= maximumIterations else { throw NFCCardError.unreadableBackup }
        let salt = bytes.subdata(in: 8..<(8 + saltLength))
        let header = bytes.prefix(headerLength)
        guard let nonce = try? AES.GCM.Nonce(data: bytes.subdata(in: (8 + saltLength)..<headerLength)),
              let box = try? AES.GCM.SealedBox(
                  nonce: nonce,
                  ciphertext: bytes.subdata(in: headerLength..<(bytes.count - tagLength)),
                  tag: bytes.suffix(tagLength)
              ) else {
            throw NFCCardError.unreadableBackup
        }
        let key = try deriveKey(password: pin, salt: salt, iterations: count)
        guard let plaintext = try? AES.GCM.open(box, using: key, authenticating: header) else {
            throw NFCCardError.unreadableBackup
        }
        guard let payload = try? JSONDecoder().decode(NFCCardBackupPayload.self, from: plaintext), payload.version == 2 else {
            throw NFCCardError.unreadableBackup
        }
        return payload
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        // NFKD, so the same password typed on another device or keyboard gives the same key.
        let passwordBytes = Data(password.decomposedStringWithCompatibilityMapping.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            passwordBytes.withUnsafeBytes { passwordPointer in
                salt.withUnsafeBytes { saltPointer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordBytes.count,
                        saltPointer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw NFCCardError.cardFailed("key") }
        return SymmetricKey(data: derived)
    }
}
#endif

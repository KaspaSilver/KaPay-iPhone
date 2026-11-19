import Foundation
import CryptoKit

/// kUSDT on Kaspa L1: Trestly's KCC-20 token (kaspador/kusdt-open, SPEC.md). What a wallet needs
/// to read and move it: the deployment (covenant ids, the KAS a coin carries), the token template
/// (pinned, `Resources/kusdt-kcc20-template.json`), a coin's state, and the script it locks to.
///
/// Trust: nothing Trestly's API says is believed until the node shows it. A coin counts only when
/// the node holds that exact outpoint, at the script recomputed here from the state, carrying
/// kUSDT's covenant id (`KusdtBalances`). A wrong template or a lying API can only hide coins,
/// never invent them.
enum Kusdt {
    /// kUSDT has 6 decimals, like USDT.
    static let decimals = 6

    // MARK: Deployment

    struct Deployment {
        /// kUSDT's covenant id: every kUSDT coin carries it (and so does the minter and its seed,
        /// which is why the script check matters too).
        let covenantId: Data
        /// KasPool's covenant id.
        let poolId: Data
        /// KAS (sompi) every new token coin carries for its storage mass (`tokenValue`).
        let tokenValue: UInt64
        /// KAS (sompi) a new liquidity position carries.
        let positionValue: UInt64
    }

    /// kusdt-open `deployments/<network>.json` and `wallet/extension/src/config/defaults.ts`.
    static func deployment(for network: NetworkType) -> Deployment {
        switch network {
        case .mainnet:
            return Deployment(
                covenantId: unhex("50b3477e7368d0c5bfbd64483b4607350ec411377972f33e40b2d4b6d1513fd3"),
                poolId: unhex("28e7758e6fc0e2054cceb7f87f9da44a53accfa0a1795c8075c80fb99c83aaad"),
                tokenValue: 150_000_000,
                positionValue: 200_000_000
            )
        case .testnet:
            return Deployment(
                covenantId: unhex("a1d9fd1347128011ad0036b077949d63274d5d3b8ac8351776c30c945ef2c2fb"),
                poolId: unhex("99445008e36139d0a57040f562414e298a3022fb739c0e9374b1dbb9f4c42171"),
                tokenValue: 150_000_000,
                positionValue: 200_000_000
            )
        }
    }

    static var current: Deployment { deployment(for: AppSettings.load().networkType) }

    // MARK: Template

    /// The KCC20 token template: a coin's redeem script is `prefix ‖ state ‖ suffix`.
    struct Template {
        let templateHash: Data
        let prefix: Data
        let suffix: Data
    }

    /// SHA-256 of `prefix ‖ suffix` as shipped: a resource that differs is refused.
    static let templateSHA256 = "e87405ef5a227167e373f94968432ccec6d792c47dce783a41f45c0095a97137"

    /// The pinned template, or nil if the resource is missing or not the one pinned.
    static let template: Template? = {
        guard let url = Bundle.main.url(forResource: "kusdt-kcc20-template", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hash = (json["templateHash"] as? String).flatMap(unhexOrNil),
              let prefix = (json["prefix"] as? String).flatMap(unhexOrNil),
              let suffix = (json["suffix"] as? String).flatMap(unhexOrNil) else {
            AppLog.log("[kUSDT] the token template resource is missing or unreadable")
            return nil
        }
        let digest = SHA256.hash(data: prefix + suffix).map { String(format: "%02x", $0) }.joined()
        guard digest == templateSHA256, prefix.count == 34, prefix.suffix(32) == hash else {
            AppLog.log("[kUSDT] the token template resource isn't the pinned one: refused")
            return nil
        }
        return Template(templateHash: hash, prefix: prefix, suffix: suffix)
    }()

    // MARK: State

    /// KCC-2 owner schemes (SPEC section 4). KaPay holds tokens only as 0x00 (a Schnorr key).
    static let ownerP2PKSchnorr: UInt8 = 0x00
    static let ownerP2SH: UInt8 = 0x03
    static let ownerCovenantId: UInt8 = 0x04

    /// A KCC20 coin's state: what it holds and who owns it. Encoded as 112 bytes of explicit
    /// pushes: `08 amount(8, LE sign-magnitude) 20 owner 01 scheme 01 borrow 20 guard 20 extension`.
    struct State: Equatable {
        var amount: UInt64
        var owner: Data
        var ownerScheme: UInt8
        var borrowScheme: UInt8 = 0
        var borrowGuard = Data(count: 32)
        var extensionCommitment = Data(count: 32)

        /// A plain coin of this key: Schnorr owner, nothing borrowed, no extension (the only kind
        /// KaPay shows or spends; SPEC section 5).
        static func plain(owner: Data, amount: UInt64) -> State {
            State(amount: amount, owner: owner, ownerScheme: Kusdt.ownerP2PKSchnorr)
        }

        func isPlain(of owner: Data) -> Bool {
            ownerScheme == Kusdt.ownerP2PKSchnorr && self.owner == owner && borrowScheme == 0
                && borrowGuard == Data(count: 32) && extensionCommitment == Data(count: 32)
        }

        var encoded: Data {
            var d = Data([0x08])
            var a = amount
            for _ in 0..<8 { d.append(UInt8(a & 0xff)); a >>= 8 }
            d.append(0x20); d.append(owner)
            d.append(0x01); d.append(ownerScheme)
            d.append(0x01); d.append(borrowScheme)
            d.append(0x20); d.append(borrowGuard)
            d.append(0x20); d.append(extensionCommitment)
            return d
        }
    }

    /// The coin's redeem script and its P2SH locking script (`OP_BLAKE2B <hash> OP_EQUAL`).
    static func redeemScript(_ state: State, template: Template) -> Data {
        template.prefix + state.encoded + template.suffix
    }

    static func lockingScript(_ state: State, template: Template) -> Data {
        KachatNames.Codec.p2shScript(redeemScript(state, template: template))
    }

    /// The address the node lists the coin under.
    static func address(ofLockingScript script: Data) -> String? {
        KachatNamesService.p2shAddress(script: script)
    }

    // MARK: Owners

    /// The KCC-2 owner a KaPay address stands for: a Schnorr key address's x-only key. Nil for
    /// anything else (KaPay never holds tokens on a script or ECDSA address).
    static func schnorrOwner(of address: String) -> Data? {
        guard let decoded = KaspaAddress(address: address), decoded.type == .pubKey, decoded.payload.count == 32 else { return nil }
        return decoded.payload
    }

    // MARK: Hex

    static func unhex(_ s: String) -> Data { unhexOrNil(s) ?? Data() }

    static func unhexOrNil(_ s: String) -> Data? {
        let chars = Array(s.lowercased())
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(byte)
            i += 2
        }
        return out
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

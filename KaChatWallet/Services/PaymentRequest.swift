import Foundation
import CryptoKit
import P256K

// MARK: - Internal KaChat links

/// A KaChat link the wallet opens: someone's profile, or a request to be paid.
///
/// Wire contract, shared with the Android client (both platforms emit AND accept both forms):
///
/// | Target         | Custom scheme                  | Universal link                                    |
/// |----------------|--------------------------------|---------------------------------------------------|
/// | Profile          | `kachat://profile/<address>`   | `https://kachat.app/u/<address>`                  |
/// | Payment request  | `kachat://pay/<address>?amount=<KAS>&memo=<text>[&chat=1]&by=<address>&sig=<hex>` | `https://kachat.app/pay/<address>?…` |
///
/// `<address>` is a full Kaspa address; in the universal form a mainnet address may drop its
/// `kaspa:` prefix (the app writes it without, so the link reads cleanly), and a missing
/// prefix means mainnet.
/// Everything a pasted link carries is attacker-controlled, so `parse` re-validates it from
/// scratch rather than trusting the URL's text. KaChat's post and room links open nothing here.
enum KaChatInternalLink: Equatable {
    /// Someone's KaChat profile: opens their User Info (yours too, for your own link).
    case profile(address: String)
    /// A request to be paid: opens Send Kaspa with the address, amount and memo filled in
    /// (`PaymentRequest`).
    case paymentRequest(PaymentRequest)

    /// The universal-link host - the only host a share ever carries (see KACHAT_APP_LINKS.md in
    /// KaChat-iPhone).
    static let universalLinkHost = "kachat.app"

    /// The custom-scheme form of the link.
    var shareLinkString: String {
        switch self {
        case .profile(let address): return "kachat://profile/\(address)"
        case .paymentRequest(let request): return "kachat://pay/\(request.linkTail)"
        }
    }

    /// The https twin of `shareLinkString` - survives apps that strip unknown schemes, and
    /// falls back to the web/App Store for people who don't have KaChat installed.
    var universalLinkString: String {
        switch self {
        case .profile(let address):
            let path = address.hasPrefix("kaspa:") ? String(address.dropFirst("kaspa:".count)) : address
            return "https://\(Self.universalLinkHost)/u/\(path)"
        case .paymentRequest(let request):
            return "https://\(Self.universalLinkHost)/pay/\(request.linkTail)"
        }
    }


    // MARK: Parsing

    /// `kapay://market`: KaPay's .kachat Marketplace, which KaChat's "Get a domain" opens. Not a
    /// case of this enum, since it carries nothing to share or detect in pasted text.
    static func isMarketLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "kapay" || scheme == "kachatwallet" else { return false }
        return url.host?.lowercased() == "market" && url.pathComponents.allSatisfy { $0 == "/" }
    }

    /// Both link forms -> a validated target, or nil for anything else (including a
    /// well-formed-looking link whose payload fails validation).
    static func parse(_ url: URL) -> KaChatInternalLink? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        // `pathComponents` percent-decodes for us, and drops the leading "/" marker below.
        let parts = url.pathComponents.filter { $0 != "/" }
        switch scheme {
        // kapay:// is KaPay's own scheme: KaPost hands its payment requests over with it
        // (kachat:// opens KaChat). kachatwallet:// is its name from before KaPay. The targets
        // are the same as kachat://.
        case "kachat", "kapay", "kachatwallet":
            // kachat://<target>/<payload> - exactly one payload component, so a link with extra
            // path segments (kachat://pay/a/b) is rejected rather than silently truncated.
            guard let host = url.host?.lowercased(), parts.count == 1, let payload = parts.first else { return nil }
            switch host {
            case "profile": return profileLink(rawAddress: payload)
            case "pay": return PaymentRequest(rawAddress: payload, url: url).map { .paymentRequest($0) }
            default: return nil
            }
        case "http", "https":
            var host = url.host?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            guard host == universalLinkHost, parts.count == 2 else { return nil }
            switch parts[0].lowercased() {
            case "u": return profileLink(rawAddress: parts[1])
            case "pay": return PaymentRequest(rawAddress: parts[1], url: url).map { .paymentRequest($0) }
            default: return nil
            }
        default:
            return nil
        }
    }

    /// A pasted address is attacker-controlled like everything else in a link: it has to be a
    /// valid Kaspa address, checksum and all, or the link is not ours.
    /// The address opens on the network the app runs on: a link without a prefix (or shared
    /// from the other network) names the same key, so it becomes that key's address here -
    /// a `kaspa:` contact on testnet could never be reached (IOS-003).
    private static func profileLink(rawAddress: String) -> KaChatInternalLink? {
        let raw = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= 100, let address = KaspaAddress.onActiveNetwork(raw) else { return nil }
        return .profile(address: address)
    }

    // MARK: Detection inside message text

    /// One internal link found inside pasted text.
    struct Match: Equatable {
        let link: KaChatInternalLink
        let url: URL
        /// The exact substring matched, so the caller can tell "the message IS this link" from
        /// "the message mentions this link".
        let matchedText: String
        /// True when the trimmed message consists of nothing but this link - the card then
        /// replaces the text bubble entirely (matching how a bare http link already renders).
        let coversWholeMessage: Bool
    }

    /// Both link forms, anywhere in free text (a pasted message holding a request).
    private static let pattern =
        #"(?:kachat://(?:profile|pay)/|https?://(?:www\.)?kachat\.app/(?:u|pay)/)[^\s<>"']+"#

    private static let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)

    /// Trailing prose punctuation is not part of the link ("... pay me: kachat://pay/...").
    private static let trailingTrim = CharacterSet(charactersIn: ".,;:!?)]}'\"")

    private final class MatchBox: NSObject {
        let value: Match?
        init(_ value: Match?) { self.value = value }
    }

    /// Cached: a paste field asks on every change.
    private static let matchCache: NSCache<NSString, MatchBox> = {
        let cache = NSCache<NSString, MatchBox>()
        cache.countLimit = 2_048
        return cache
    }()

    static func match(in text: String) -> Match? {
        let key = text as NSString
        if let cached = matchCache.object(forKey: key) { return cached.value }
        let result = uncachedMatch(in: text)
        matchCache.setObject(MatchBox(result), forKey: key)
        return result
    }

    private static func uncachedMatch(in text: String) -> Match? {
        // Cheap bail-out before paying for the regex: neither form can appear without one of
        // these two literals.
        let lowered = text.lowercased()
        guard lowered.contains("kachat://") || lowered.contains(universalLinkHost) else { return nil }
        guard let regex else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: Match?
        regex.enumerateMatches(in: text, options: [], range: full) { result, _, stop in
            guard let result else { return }
            var candidate = ns.substring(with: result.range)
            while let last = candidate.unicodeScalars.last, trailingTrim.contains(last) {
                candidate.removeLast()
            }
            guard let url = URL(string: candidate), let link = parse(url) else { return }
            found = Match(
                link: link,
                url: url,
                matchedText: candidate,
                coversWholeMessage: text.trimmingCharacters(in: .whitespacesAndNewlines) == candidate
            )
            stop.pointee = true
        }
        return found
    }
}

/// A request to be paid, carried in a link (`KaChatInternalLink.paymentRequest`): who to pay, the
/// exact amount and what it's for. KaChat makes them; opening one in the wallet opens Send Kaspa
/// with it filled in.
///
/// `https://kachat.app/pay/<address>?amount=<KAS>&memo=<text>&chat=1` (or `kachat://pay/...`):
/// - the address without `kaspa:` on mainnet (like profile links), with `kaspatest:` on testnet;
/// - `amount` in KAS, at most 8 decimals, "." as the separator;
/// - `memo` optional, at most `memoLimit` characters;
/// - `chat=1` when the address is the requester's KaChat chatting address: KaChat pays it as a
///   chat payment with the memo in it; the wallet pays it as a plain transfer, the memo only
///   telling the payer what it is for.
/// - `by` + `sig`: who made it - the maker's main (chatting) address, which has an identity (a
///   `.kachat` name, a profile) where a spending address has none - and a Schnorr signature by
///   that address's key over everything above (`signingDigest`). A request is shown as "from"
///   someone only when the signature checks out; a link whose signature doesn't is refused
///   outright, since that is a link someone changed. Requests without them (none are made that
///   way) show no maker.
/// Everything in it is attacker-controlled: the address must be valid on the network the app runs
/// on, the amount positive and exact, and the memo is cleaned of control and direction marks.
struct PaymentRequest: Equatable, Identifiable {
    let address: String
    let amountSompi: UInt64
    let memo: String
    let toChattingAddress: Bool
    /// The chatting address that signed the request - verified, or nil.
    let creator: String?
    /// The creator's Schnorr signature over `signingDigest(creator:)`.
    let signature: Data?
    /// Each opening is its own sheet, even for the same request.
    let id = UUID()

    static let memoLimit = 140
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func == (lhs: PaymentRequest, rhs: PaymentRequest) -> Bool {
        lhs.address == rhs.address && lhs.amountSompi == rhs.amountSompi
            && lhs.memo == rhs.memo && lhs.toChattingAddress == rhs.toChattingAddress
            && lhs.creator == rhs.creator && lhs.signature == rhs.signature
    }

    init(address: String, amountSompi: UInt64, memo: String, toChattingAddress: Bool,
         creator: String? = nil, signature: Data? = nil) {
        self.address = address
        self.amountSompi = amountSompi
        self.memo = Self.cleanMemo(memo)
        self.toChattingAddress = toChattingAddress
        self.creator = creator
        self.signature = signature
    }

    /// What the maker signs: every field of the request and the maker's own address, under a
    /// domain tag so the signature can't be passed off as anything else. SHA-256 of
    /// "kachat-payment-request:v1" and the fields, one per line: address, amount in sompi, memo,
    /// "1"/"0" for chat, creator.
    func signingDigest(creator: String) -> Data {
        let text = ["kachat-payment-request:v1", address.lowercased(), String(amountSompi), memo,
                    toChattingAddress ? "1" : "0", creator.lowercased()].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(text.utf8)))
    }

    /// This request signed by `creator` (the wallet's chatting address) with its key.
    func signed(by creator: String, privateKey: Data) -> PaymentRequest? {
        guard let schnorrKey = try? P256K.Schnorr.PrivateKey(dataRepresentation: privateKey) else { return nil }
        var message = [UInt8](signingDigest(creator: creator))
        guard let signature = try? schnorrKey.signature(message: &message, auxiliaryRand: nil) else { return nil }
        return PaymentRequest(address: address, amountSompi: amountSompi, memo: memo,
                              toChattingAddress: toChattingAddress, creator: creator.lowercased(),
                              signature: Data(signature.bytes))
    }

    /// True when `signature` is `creator`'s over this request.
    static func verify(_ signature: Data, creator: String, request: PaymentRequest) -> Bool {
        guard let key = KaspaAddress.publicKey(from: creator), key.count == 32 else { return false }
        return schnorrVerify(signature, message: request.signingDigest(creator: creator), xOnlyPublicKey: key)
    }

    /// From a link's address segment and its query; nil unless every part is valid.
    init?(rawAddress: String, url: URL) {
        let raw = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard raw.count <= 100 else { return nil }
        let full = raw.contains(":") ? raw : "kaspa:" + raw
        // the request names an address on one network: a payment can't cross networks
        guard KaspaAddress.isValidOnActiveNetwork(full) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }
        guard let amountText = value("amount"), amountText.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let sompi = KaspaUnit.sompi(fromUserText: amountText), sompi > 0 else { return nil }
        let unsigned = PaymentRequest(address: full, amountSompi: sompi, memo: value("memo") ?? "", toChattingAddress: value("chat") == "1")
        switch (value("by"), value("sig")) {
        case (nil, nil):
            self = unsigned
        case let (by?, sig?):
            let rawBy = by.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let creator = rawBy.contains(":") ? rawBy : "kaspa:" + rawBy
            // a maker is shown only when the signature is theirs; one that isn't is a changed link
            guard rawBy.count <= 100, KaspaAddress.isValidOnActiveNetwork(creator),
                  let signature = Data(hexString: sig), signature.count == 64,
                  Self.verify(signature, creator: creator, request: unsigned) else { return nil }
            self.init(address: full, amountSompi: sompi, memo: unsigned.memo, toChattingAddress: unsigned.toChattingAddress,
                      creator: creator, signature: signature)
        default:
            return nil
        }
    }

    /// The first payment request in `text` - a pasted link, or a message holding one.
    static func found(in text: String) -> PaymentRequest? {
        guard let match = KaChatInternalLink.match(in: text), case .paymentRequest(let request) = match.link else { return nil }
        return request
    }

    /// The amount in KAS, exact: "12.5", "0.00000001".
    var amountText: String {
        let whole = amountSompi / 100_000_000
        let frac = amountSompi % 100_000_000
        guard frac > 0 else { return String(whole) }
        var fracText = String(format: "%08llu", frac)
        while fracText.hasSuffix("0") { fracText.removeLast() }
        return "\(whole).\(fracText)"
    }

    /// The link's address segment and query, shared by both forms.
    var linkTail: String {
        let path = address.hasPrefix("kaspa:") ? String(address.dropFirst("kaspa:".count)) : address
        var query = "amount=\(amountText)"
        // Only unreserved characters stay as they are: "&", "=", "+", "#" and spaces in a memo are
        // all escaped, so it reads back exactly as written whatever decodes it.
        if !memo.isEmpty, let encoded = memo.addingPercentEncoding(withAllowedCharacters: Self.unreserved) {
            query += "&memo=\(encoded)"
        }
        if toChattingAddress { query += "&chat=1" }
        if let creator, let signature {
            let by = creator.hasPrefix("kaspa:") ? String(creator.dropFirst("kaspa:".count)) : creator
            query += "&by=\(by)&sig=\(signature.hexString)"
        }
        return "\(path)?\(query)"
    }

    /// The link the Copy button gives out.
    var shareURLString: String { KaChatInternalLink.paymentRequest(self).universalLinkString }

    /// True when the address is one of this wallet's: your own request pastes as text (to send it
    /// to someone) instead of opening Send.
    ///
    /// Cheap enough for a view body (the request card asks on every draw): one you signed is yours
    /// at once, and the wallet's addresses are worked out once per account and address count -
    /// listing the spending addresses reads the seed and derives each of them, which on every
    /// redraw made a screen holding a request crawl.
    @MainActor
    var isOwn: Bool {
        let wallet = WalletManager.shared.currentWallet?.publicAddress.lowercased()
        if let creator, creator.lowercased() == wallet { return true }
        return Self.ownAddresses().contains(address.lowercased())
    }

    @MainActor private static var ownAddressCache: (key: String, addresses: Set<String>)?

    @MainActor
    private static func ownAddresses() -> Set<String> {
        let manager = WalletManager.shared
        guard let wallet = manager.currentWallet?.publicAddress.lowercased() else { return [] }
        let key = "\(wallet)|\(manager.maxSpendingAddressIndex)|q\(manager.maxQuantumAddressIndex)"
        if let cached = ownAddressCache, cached.key == key { return cached.addresses }
        var addresses: Set<String> = [wallet]
        addresses.formUnion(manager.allSpendingAddresses().map { $0.lowercased() })
        ownAddressCache = (key, addresses)
        return addresses
    }

    private static func schnorrVerify(_ signature: Data, message: Data, xOnlyPublicKey: Data) -> Bool {
        guard let schnorrSig = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: signature) else { return false }
        let xonlyKey = P256K.Schnorr.XonlyKey(dataRepresentation: xOnlyPublicKey)
        var messageBytes = [UInt8](message)
        return xonlyKey.isValid(schnorrSig, for: &messageBytes)
    }

    static func cleanMemo(_ memo: String) -> String {
        let scalars = memo.unicodeScalars.filter { scalar in
            let category = scalar.properties.generalCategory
            if category == .control || category == .format { return false }
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return false
            default: return true
            }
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(memoLimit))
    }
}

/// The payment request waiting to be shown: `MainTabView` presents Send Kaspa for it.
@MainActor
final class PaymentRequestRouter: ObservableObject {
    static let shared = PaymentRequestRouter()
    @Published var pending: PaymentRequest?
    private init() {}
}

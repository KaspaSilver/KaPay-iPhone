import Foundation
import SwiftUI

// MARK: - Shared formatters

enum SharedFormatting {
    static let mediumDateShortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let iso8601 = ISO8601DateFormatter()
}

// MARK: - Wallet Models

struct Wallet: Codable, Equatable {
    let publicAddress: String
    let publicKey: String
    var alias: String
    let createdAt: Date
    var balanceSompi: UInt64?

    // Spending-chain state (see WalletManager's spending-address derivation). Optional so
    // existing Keychain-stored Wallet JSON without these keys still decodes (synthesized
    // Decodable treats a missing key on an Optional property as nil, not a decode failure).
    var spendingAddressIndex: Int?
    var maxSpendingAddressIndex: Int?

    /// The spending-chain index currently active as the "primary" spending address.
    var effectiveSpendingAddressIndex: Int { spendingAddressIndex ?? 0 }

    /// The highest spending-chain index ever generated/shown in Manage Addresses.
    /// LEGACY chain only: the primary pointer counts while it is on the legacy chain. Once a
    /// spend rotated the primary onto the quantum chain (KIP-22, index >= quantumIndexBase), the
    /// pointer made this a million, and every legacy range loop - own-address sets, the activity
    /// watcher, Profile's balances - tried to derive a million addresses on the main thread.
    var effectiveMaxSpendingAddressIndex: Int {
        let base = WalletManager.quantumIndexBase
        let stored = maxSpendingAddressIndex ?? 0
        return max(stored < base ? stored : 0, effectiveSpendingAddressIndex < base ? effectiveSpendingAddressIndex : 0)
    }

    var shortAddress: String {
        guard publicAddress.count > 16 else { return publicAddress }
        let prefix = String(publicAddress.prefix(10))
        let suffix = String(publicAddress.suffix(6))
        return "\(prefix)...\(suffix)"
    }
}

/// A single derived spending-chain address as shown in Manage Addresses — always re-derived
/// live from the seed + index rather than persisted, matching Android (only the index bounds
/// are stored, never the address list itself).
struct SpendingAddressEntry: Identifiable, Equatable, Codable {
    let index: Int
    let address: String
    let balanceSompi: UInt64
    let isCurrent: Bool
    /// Whether this address has ever appeared in a transaction (independent of current
    /// balance — swept-to-zero addresses still count as used). Defaults false until the
    /// network history check completes.
    var everUsed: Bool = false
    /// User-assigned display name for this address, if any.
    var label: String?
    /// A quantum-safe (KIP-22) slot: public index `WalletManager.quantumIndexBase + n`. Computed,
    /// so cached entry lists from before the upgrade decode unchanged.
    var isQuantum: Bool { index >= WalletManager.quantumIndexBase }
    /// The row's number on its own chain, both named "Address #n" (quantum numbering starts at
    /// 0 again; the shield is what tells the chains apart).
    var displayTitle: String {
        "Address #\(isQuantum ? index - WalletManager.quantumIndexBase : index)"
    }
    /// Whether this address is hidden from the main Manage Addresses list. Enforced
    /// server-side (WalletManager.setSpendingAddressHidden refuses to hide the primary
    /// address or one with a balance) — this flag alone should never be trusted to imply
    /// "safe to hide."
    var hidden: Bool = false

    var id: Int { index }

    var displayLabel: String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? displayTitle : trimmed
    }

    var shortAddress: String {
        guard address.count > 20 else { return address }
        return "\(address.prefix(14))...\(address.suffix(6))"
    }
}

struct SeedPhrase: Codable {
    let words: [String]

    /// Optional BIP39 passphrase (the "25th word"). Combined with the mnemonic during seed
    /// derivation (`BIP39.mnemonicToSeed`) to unlock a distinct, hidden account. Optional so
    /// wallets stored before this feature still decode (a missing key on an Optional synthesizes
    /// as `nil`, same trick as `Wallet.spendingAddressIndex`). `nil` and `""` are equivalent
    /// (no passphrase). Persisted Secure-Enclave-wrapped and device-only alongside the words
    /// (see `KeychainService.saveSeedPhrase`), so the account auto-unlocks like any other.
    var passphrase: String?

    var phrase: String {
        words.joined(separator: " ")
    }

    init(words: [String], passphrase: String? = nil) {
        self.words = words
        self.passphrase = passphrase
    }

    init?(phrase: String, passphrase: String? = nil) {
        // Split by any whitespace including newlines, tabs, etc.
        let words = phrase.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard words.count == 12 || words.count == 24 else {
            return nil
        }
        self.words = words
        self.passphrase = passphrase
    }
}

/// One saved Kaspa address in the Address Book (Wallet > Address Book). Kept per wallet,
/// on this device and in its Nextcloud backup - never in the phone's Contacts.
struct AddressBookEntry: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var address: String
    /// May be empty: the person removed the name they gave, and the address goes by who it is on
    /// chain again (its .kachat name, else the address). Read it through `customName`.
    var name: String

    /// The name the person gave this address, or nil when it has none.
    var customName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    var note: String
    var createdAt: Date
    var updatedAt: Date
    /// The assigned photo as base64 JPEG - only in the backup archive. In the app it is a file
    /// (`AddressBookManager.photo(for:)`), so this stays nil everywhere else.
    var photo: String? = nil

    init(id: UUID = UUID(), address: String, name: String, note: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.address = address
        self.name = name
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Diagnostics Models

struct ConnectionStatus: Equatable {
    var isConnected: Bool
    var pingMs: Int?
    var nodeAddress: String?
    var indexerAddress: String?
    var lastChecked: Date?
    var networkType: NetworkType
    var blockHeight: UInt64?
    var error: String?

    static var disconnected: ConnectionStatus {
        ConnectionStatus(
            isConnected: false,
            pingMs: nil,
            nodeAddress: nil,
            indexerAddress: nil,
            lastChecked: nil,
            networkType: .mainnet,
            blockHeight: nil,
            error: nil
        )
    }
}

enum NetworkType: String, Codable, CaseIterable {
    case mainnet
    case testnet

    var displayName: String {
        switch self {
        case .mainnet: return "Mainnet"
        case .testnet: return "Testnet"
        }
    }

    /// The network an address belongs to, by its prefix (`kaspa:` / `kaspatest:`); nil for an
    /// address without one.
    init?(address: String) {
        let lower = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("kaspatest:") {
            self = .testnet
        } else if lower.hasPrefix("kaspa:") {
            self = .mainnet
        } else {
            return nil
        }
    }

    /// False only for an address that names the OTHER network than the one the app runs on -
    /// e.g. a mainnet sender in a push that reached a device switched to testnet. One key is
    /// one account on both networks, so such a message decrypts fine and would otherwise land
    /// on the wrong network.
    static func isOnActiveNetwork(_ address: String) -> Bool {
        guard let network = NetworkType(address: address) else { return true }
        return network == AppSettings.load().networkType
    }
}

extension KaspaAddress {
    /// A recipient the app can use: a valid address of the network the app runs on. A `kaspa:`
    /// address on testnet (or `kaspatest:` on mainnet) is the same key on the other chain, so
    /// paying it sends coins to the wrong network (IOS-003).
    static func isValidOnActiveNetwork(_ address: String) -> Bool {
        isValid(address) && NetworkType(address: address) == AppSettings.load().networkType
    }

    /// Why a valid address can't be used here: it's the other network's. nil for an address of
    /// the running network or one that isn't valid at all.
    static func otherNetworkReason(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(trimmed), let network = NetworkType(address: trimmed),
              network != AppSettings.load().networkType else { return nil }
        return AppLocalization.string(network == .testnet
            ? "This is a Testnet address. KaPay is on Mainnet."
            : "This is a Mainnet address. KaPay is on Testnet.")
    }

    /// The line under an address field: "Valid address", the other-network reason, or "Invalid
    /// address format".
    static func validityText(_ address: String, isValid: Bool) -> String {
        if isValid { return AppLocalization.string("Valid address") }
        return otherNetworkReason(address) ?? AppLocalization.string("Invalid address format")
    }

    /// The same key's address on the network the app runs on, for an address with or without its
    /// prefix (profile links drop it). nil if it isn't a valid address on either network.
    static func onActiveNetwork(_ raw: String) -> String? {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = lower.contains(":") ? [lower] : ["kaspa:" + lower, "kaspatest:" + lower]
        guard let valid = candidates.first(where: isValid), let parsed = KaspaAddress(address: valid) else { return nil }
        let hrp = AppSettings.load().networkType == .testnet ? "kaspatest" : "kaspa"
        guard parsed.hrp != hrp else { return valid }
        let converted = KaspaAddress(hrp: hrp, type: parsed.type, payload: parsed.payload).address
        return converted.isEmpty ? nil : converted
    }
}

/// The unit every amount is shown in: KAS on mainnet, TKAS on testnet, so a testnet amount can
/// never be read as real KAS. Market data (the KAS price, exchange tickers) stays "KAS".
/// The version the app shows for itself, everywhere one is shown (Profile > Version, the saved
/// accounts screen): "5.2.2 (2581)" through the beta cycle, plain "5.2.2" once the train is
/// released. The build is the real CFBundleVersion of the shipped bundle (Xcode Cloud's counter,
/// a local archive's, or the "Local Build Number" script phase's for an Xcode run), shown by its
/// last 4 digits for easier reading; `KaChatIsRelease` = YES drops the parenthetical for the
/// App Store build.
enum AppVersion {
    /// True for the App Store build, false through the beta cycle.
    static var isRelease: Bool {
        ((Bundle.main.infoDictionary?["KaChatIsRelease"] as? String) ?? "").uppercased() == "YES"
    }

    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { return "Unknown" }
        let fullBuild = (info?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = String(fullBuild.suffix(4))
        if isRelease || build.isEmpty {
            return version
        }
        return "\(version) (\(build))"
    }
}

enum KaspaUnit {
    static var symbol: String { AppSettings.load().networkType == .testnet ? "TKAS" : "KAS" }

    /// `text` with the word KAS shown as the running network's unit. For strings that are
    /// already localized: every translation keeps "KAS" as is. Matches KAS only as a whole
    /// ASCII word, so it also works inside scripts without word breaks ("%@ KASを受信") and never
    /// touches "Kaspa" or an existing "TKAS".
    static func label(_ text: String) -> String {
        guard AppSettings.load().networkType == .testnet else { return text }
        return text.replacingOccurrences(of: "(?<![A-Za-z])KAS(?![A-Za-z])", with: "TKAS", options: .regularExpression)
    }

    /// A `Text` for a localized key that mentions KAS (the same key `Text("...")` would look
    /// up), formatted in the in-app language and labelled for the network.
    static func text(_ key: String, _ args: CVarArg...) -> Text {
        let template = AppLocalization.string(key)
        let resolved = args.isEmpty ? template : String(format: template, locale: AppLocalization.locale, arguments: args)
        return Text(verbatim: label(resolved))
    }
}

extension KaspaUnit {
    /// Most sompi any typed amount can mean: a little above Kaspa's 28.7 billion KAS supply.
    static let maxTypedSompi: UInt64 = 29_000_000_000 * 100_000_000

    /// A KAS amount the person typed, in sompi: "1.5", "1,5" (comma-decimal keyboards), ".5",
    /// at most 8 decimals, no grouping, signs or exponents. Exact integer math (no Double), and
    /// nil above `maxTypedSompi`, so no input can trap the conversion. 0 is a valid result.
    static func sompi(fromUserText text: String) -> UInt64? {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).map(asciiAmountCharacter))
        let parts = t.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let wholePart = parts.first else { return nil }
        let fracPart = parts.count > 1 ? parts[1] : ""
        guard !(wholePart.isEmpty && fracPart.isEmpty),
              wholePart.allSatisfy({ $0.isASCII && $0.isNumber }), fracPart.allSatisfy({ $0.isASCII && $0.isNumber }),
              fracPart.count <= 8 else { return nil }
        let wholeDigits = wholePart.drop { $0 == "0" }
        // 29e9 KAS has 11 digits; anything longer is over the cap anyway (and can't overflow below)
        guard wholeDigits.count <= 11 else { return nil }
        let whole = UInt64(wholeDigits.isEmpty ? "0" : String(wholeDigits)) ?? 0
        let frac = UInt64(fracPart + String(repeating: "0", count: 8 - fracPart.count)) ?? 0
        let total = whole * 100_000_000 + frac
        return total <= maxTypedSompi ? total : nil
    }

    /// Arabic-Indic and Persian digits (what those keyboards type) as ASCII digits, and the
    /// comma and Arabic decimal separators as ".".
    private static func asciiAmountCharacter(_ c: Character) -> Character {
        if c == "," || c == "\u{066B}" { return "." }
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return c }
        if (0x0660...0x0669).contains(v) { return Character(UnicodeScalar(v - 0x0660 + 0x30)!) }
        if (0x06F0...0x06F9).contains(v) { return Character(UnicodeScalar(v - 0x06F0 + 0x30)!) }
        return c
    }

    /// Cleans an amount field as it's typed: digits and one decimal point ("," becomes "."), at
    /// most 8 decimals. The default for every amount entry.
    static func sanitizeAmountInput(_ value: String) -> String {
        var result = ""
        var dotSeen = false
        var decimals = 0
        for raw in value {
            let ch = asciiAmountCharacter(raw)
            if ch == "." {
                if dotSeen { continue }
                dotSeen = true
                result.append(ch)
            } else if ch.isASCII && ch.isNumber {
                if dotSeen {
                    if decimals == 8 { continue }
                    decimals += 1
                }
                result.append(ch)
            }
        }
        return result
    }
}

/// App-wide appearance override. "System" (the default) just follows the device's own Light/Dark
/// Mode setting like any well-behaved app — Light/Dark force one specific appearance regardless
/// of what the device is currently set to.
enum AppAppearance: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil tells SwiftUI's `.preferredColorScheme` to defer to the device setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// In-app language override, independent of the device's system language. `.system` (the
/// default) means "follow the device setting" - the app never touches `AppleLanguages` in that
/// case, so it behaves exactly as it did before this setting existed. Any other case persists a
/// preferred-language override via the standard `AppleLanguages` UserDefaults key, which iOS only
/// picks up on the next cold launch - there is no in-process Bundle-swizzling here by design (see
/// the Settings row that sets this: it always prompts for a restart after changing this value).
enum AppLanguage: String, Codable, CaseIterable {
    case system
    case ar, arEG = "ar-EG", bn, de, en, es, fa, fr, he, hi, id, it, ja, ko, pt, ru, tr, vi
    case zhHans = "zh-Hans"

    /// Native name, matching how a language picker conventionally presents itself (each language
    /// names itself, not translated into the currently-displayed language).
    var displayName: String {
        switch self {
        case .system: return "System"
        case .ar: return "العربية"
        case .arEG: return "العربية (مصر)"
        case .bn: return "বাংলা"
        case .de: return "Deutsch"
        case .en: return "English"
        case .es: return "Español"
        case .fa: return "فارسی"
        case .fr: return "Français"
        case .he: return "עברית"
        case .hi: return "हिन्दी"
        case .id: return "Bahasa Indonesia"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .tr: return "Türkçe"
        case .vi: return "Tiếng Việt"
        case .zhHans: return "简体中文"
        }
    }

    /// The `AppleLanguages` preferred-language code for this case, or `nil` for `.system` (which
    /// means "remove the override, follow the device setting").
    var appleLanguageCode: String? {
        self == .system ? nil : rawValue
    }

    /// The `Locale` to pass as `.environment(\.locale, ...)` at the app root so every
    /// `Text(LocalizedStringKey)` in the tree re-resolves against this language's `.lproj`
    /// bundle immediately, no relaunch required (see `AppLocalization`'s doc comment for why
    /// this actually works, unlike the `AppleLanguages`/restart approach this replaces). `nil`
    /// for `.system` means "don't override the environment" - follow the device's own locale.
    var locale: Locale? {
        appleLanguageCode.map { Locale(identifier: $0) }
    }
}

/// Fiat currency for Portfolio's live KAS price/value display. Raw value is the lowercase ISO
/// 4217 code, doubling as the literal `vs_currency`/`vs_currencies` value CoinGecko's API expects
/// (see `CoinGeckoService`) - no separate mapping table to keep in sync. Unlike `AppLanguage`,
/// changing this takes effect immediately (no restart) since it only affects a live-fetched price,
/// not `Bundle`/`Locale`-driven UI strings.
enum AppCurrency: String, Codable, CaseIterable {
    case usDollar = "usd"
    case euro = "eur"
    case britishPound = "gbp"
    case japaneseYen = "jpy"
    case chineseYuan = "cny"
    case australianDollar = "aud"
    case canadianDollar = "cad"
    case swissFranc = "chf"
    case hongKongDollar = "hkd"
    case indianRupee = "inr"
    case southKoreanWon = "krw"
    case singaporeDollar = "sgd"
    case indonesianRupiah = "idr"
    case newZealandDollar = "nzd"
    case mexicanPeso = "mxn"
    case brazilianReal = "brl"
    case russianRuble = "rub"
    case turkishLira = "try"
    case southAfricanRand = "zar"
    /// Not ISO 4217 (no fiat currency is) - CoinGecko's `vs_currency` list includes major
    /// cryptocurrencies alongside fiat ones, "btc" among them, so this needs no special handling
    /// anywhere else: same API call, same `NumberFormatter` fallback-to-code behavior as any other
    /// code it doesn't recognize a symbol for (see `PortfolioView.currencySymbol(for:)`).
    case bitcoin = "btc"

    /// Uppercased for display (e.g. "USD") - `Foundation.Currency`/`NumberFormatter` both expect
    /// this casing. Not every case is a real ISO 4217 code (see `.bitcoin`).
    var code: String { rawValue.uppercased() }

    var name: String {
        switch self {
        case .usDollar: return "US Dollar"
        case .euro: return "Euro"
        case .britishPound: return "British Pound"
        case .japaneseYen: return "Japanese Yen"
        case .chineseYuan: return "Chinese Yuan"
        case .australianDollar: return "Australian Dollar"
        case .canadianDollar: return "Canadian Dollar"
        case .swissFranc: return "Swiss Franc"
        case .hongKongDollar: return "Hong Kong Dollar"
        case .indianRupee: return "Indian Rupee"
        case .southKoreanWon: return "South Korean Won"
        case .singaporeDollar: return "Singapore Dollar"
        case .indonesianRupiah: return "Indonesian Rupiah"
        case .newZealandDollar: return "New Zealand Dollar"
        case .mexicanPeso: return "Mexican Peso"
        case .brazilianReal: return "Brazilian Real"
        case .russianRuble: return "Russian Ruble"
        case .turkishLira: return "Turkish Lira"
        case .southAfricanRand: return "South African Rand"
        case .bitcoin: return "Bitcoin"
        }
    }

    var displayName: String { "\(name) (\(code))" }
}

/// The dock's five tabs. `tag` is a fixed identifier per case (not tied to display position), so
/// tag-based navigation (a notification tap jumping to a tab) keeps working. The raw values are
/// KaChat's, persisted in settings.
enum AppTab: String, Codable, CaseIterable, Identifiable, Equatable, Hashable {
    case portfolio
    case coldStorage
    /// Shown as "Wallet": KaChat's Profile, with KaPosts' wallet icon (owner's call, 2026-10-24).
    case profile
    /// .kachat names - the marketplace for KaChat's own names (claim, buy and sell, trustless).
    case kachatNames
    /// Settings as its own dock tab (owner's call, 2026-10-27).
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .portfolio: return "Portfolio"
        case .coldStorage: return "Storage"
        case .profile: return "Wallet"
        // Under the domains logo in the dock (`KachatTabIcon.domainsImage`).
        case .kachatNames: return ".kachat"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .portfolio: return "chart.pie"
        case .coldStorage: return "lock.shield"
        // KaPosts' wallet symbol; it only exists from iOS 17, so iOS 16 gets the pass-style wallet.
        case .profile:
            if #available(iOS 17, *) { return "wallet.bifold" }
            return "wallet.pass"
        // Drawn as the ".kachat" wordmark (KachatTabIcon) in the dock; this symbol is only the
        // fallback.
        case .kachatNames: return "at"
        case .settings: return "gearshape"
        }
    }

    var tag: Int {
        switch self {
        case .profile: return 2
        case .portfolio: return 3
        case .coldStorage: return 4
        case .kachatNames: return 12
        case .settings: return 16
        }
    }

    /// The dock, in order: Wallet in the middle (owner's call, 2026-10-24), Settings last.
    static let dock: [AppTab] = [.portfolio, .coldStorage, .profile, .kachatNames, .settings]

    /// Where the app opens after logging in: Wallet, the middle of the dock (owner's call,
    /// 2026-10-27).
    static let home: AppTab = .profile
}

/// Block explorer used for "view transaction" links, matching Android's KaspaExplorer enum.
enum KaspaExplorer: String, Codable, CaseIterable {
    case kaspaStream
    case kaspaOrg

    var displayName: String {
        switch self {
        case .kaspaStream: return "kaspa.stream"
        case .kaspaOrg: return "explorer.kaspa.org"
        }
    }

    /// On testnet every link goes to kaspa.stream's testnet-10 explorer, whichever explorer is
    /// picked: explorer.kaspa.org has no live testnet-10 site (explorer-tn10 answers 402), and a
    /// mainnet page for a testnet transaction or address is just "not found".
    private var isTestnet: Bool { AppSettings.load().networkType == .testnet }

    private var txBaseURL: String {
        if isTestnet { return "https://tn10.kaspa.stream/transactions/" }
        switch self {
        case .kaspaStream: return "https://kaspa.stream/transactions/"
        case .kaspaOrg: return "https://explorer.kaspa.org/txs/"
        }
    }

    private var addressBaseURL: String {
        if isTestnet { return "https://tn10.kaspa.stream/addresses/" }
        switch self {
        case .kaspaStream: return "https://kaspa.stream/addresses/"
        case .kaspaOrg: return "https://explorer.kaspa.org/addresses/"
        }
    }

    func txURL(for txId: String) -> URL? {
        URL(string: txBaseURL + txId)
    }

    func addressURL(for address: String) -> URL? {
        guard let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: addressBaseURL + encoded)
    }

    /// kaspa.stream first: the picker lists it first and a fresh install opens links there.
    static let `default`: KaspaExplorer = .kaspaStream
}

enum NotificationMode: String, Codable, CaseIterable {
    case disabled
    case remotePush

    static var allCases: [NotificationMode] {
        [.disabled, .remotePush]
    }

    var displayName: String {
        switch self {
        case .disabled: return String(localized: "Disabled")
        case .remotePush: return String(localized: "Remote push")
        }
    }
}

// MARK: - Settings Models

struct AppSettings: Codable {
    var networkType: NetworkType
    var notificationMode: NotificationMode
    var notificationPermissionRequested: Bool
    var incomingNotificationSoundEnabled: Bool
    var incomingNotificationVibrationEnabled: Bool
    /// Settings > Notifications > "Address Activity" (default ON): "Received" notifications when
    /// any of the wallet's own addresses - main, spending-chain (Manage Addresses) or watch-only
    /// cold storage - receives Kaspa from someone else. Gates the live UTXO path, the foreground
    /// catch-up diff (see AddressActivityNotifier) and the push registration's watched addresses.
    var addressActivityNotificationsEnabled: Bool

    // Customization
    var appearance: AppAppearance
    var language: AppLanguage
    var currency: AppCurrency

    // Security
    var biometricSeedPhraseEnabled: Bool
    var biometricAccountLoginEnabled: Bool
    /// Gates the "Export" button on a spending address's own screen (Manage Addresses > tap an
    /// address) - separate from `biometricSeedPhraseEnabled`, since one address's key is
    /// lower-stakes than the whole seed phrase.
    var biometricSpendingKeyEnabled: Bool

    // Diagnostics
    /// Settings > Diagnostics > "Verbose API Logging" (default OFF): per-request success log
    /// lines. While off, only failures and slow requests are logged.
    var verboseAPILogging: Bool

    // Connection settings
    /// The KaChat indexer: the .kachat names registry reads.
    var indexerURL: String
    /// The push service ("Received" and .kachat name pushes).
    var pushIndexerURL: String
    /// The Kaspa Name Service endpoint. Fixed to the current network's default, never stored and
    /// never user-editable, so switching networks moves it.
    var knsBaseURL: String { Self.defaultKNSURL(for: networkType) }

    var kaspaRestAPIURL: String
    var kaspaExplorer: KaspaExplorer
    /// A user-pinned "host:port" gRPC node - when non-blank, NodePoolService stops discovery
    /// (DNS seeds/peer-gossip/scoring) entirely and only ever connects to this address,
    /// Kaspium-style. Empty string = disabled (normal pool discovery). See
    /// NodeRegistry.setTrustedNode.
    var trustedNodeAddress: String

    /// User-saved node addresses for quick copy/paste into `trustedNodeAddress` above -
    /// purely a convenience list, never itself read by the node pool.
    var savedNodeAddresses: [SavedNodeAddress]

    /// The connection settings of the network NOT in use, kept while it is switched away from
    /// (keyed by `NetworkType.rawValue`). The fields above always hold the active network's
    /// values; `switchNetwork(to:)` swaps them. A network never used starts from
    /// `ConnectionProfile.defaults(for:)`.
    var connectionProfiles: [String: ConnectionProfile] = [:]

    // gRPC endpoint pool settings
    var grpcEndpointPool: [GrpcEndpoint]
    var discoverNewPeers: Bool           // Enable peer discovery from hot pool nodes
    var grpcPoolNetworkType: NetworkType?
    var lastPoolPersistDate: Date?       // Track when pool was last saved

    // Default URLs per network
    static let defaultIndexerURL = "https://indexer.kachat.app"
    /// Testnet has no KaChat indexer: blank, so push and `.kachat` names stay off there until
    /// someone enters an indexer in Connection Settings (names then read from the chain).
    static let defaultTestnetIndexerURL = ""
    static let defaultPushIndexerURL = "https://indexer.kachat.app"
    /// Retired mainnet indexer defaults: `indexer.kasia.fyi` (offline), the community
    /// `indexer.kasia.wtf`, and KaChat's own earlier `kachat.duckdns.org`. A setting still on
    /// one of these moves to the current default; a custom indexer is kept.
    static let supersededIndexerURLs: Set<String> = [
        "https://indexer.kasia.fyi", "https://indexer.kasia.wtf", "https://kachat.duckdns.org"
    ]
    /// The retired testnet-10 indexer: a testnet setting still on it goes blank.
    static let supersededTestnetIndexerURLs: Set<String> = ["https://tnkachat.duckdns.org:7443"]
    static func migratedIndexerURL(_ url: String, network: NetworkType) -> String {
        var key = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        switch network {
        case .mainnet: return supersededIndexerURLs.contains(key) ? defaultIndexerURL : url
        case .testnet: return supersededTestnetIndexerURLs.contains(key) ? defaultTestnetIndexerURL : url
        }
    }
    static let defaultKNSMainnetURL = "https://api.knsdomains.org/mainnet/api/v1"
    static let defaultKNSTestnetURL = "https://api.knsdomains.org/tn10/api/v1"
    static let defaultKaspaMainnetURL = "https://api.kaspa.org"
    /// Testnet means testnet-10: it carries the Toccata covenants (`.kachat` names test there)
    /// and is where the node pool's testnet DNS seeds (port 16210) already point.
    static let defaultKaspaTestnetURL = "https://api-tn10.kaspa.org"
    /// The previous testnet default, testnet-11 (retired - the API answers 503). Migrated forward
    /// to `defaultKaspaTestnetURL` when settings decode.
    static let legacyDefaultKaspaTestnetURL = "https://api-tn11.kaspa.org"
    /// The wallet ships pinned to this node out of the box, rather than defaulting to full
    /// seed/DNS/peer-gossip discovery - the "Use Default" button in Connection Settings resets
    /// back to this same address. Kaspium's own currently-live default, TLS-secured (`grpcs://`).
    static let defaultTrustedNodeAddress = "grpcs://toccata.kaspium.io"

    /// The active network's connection settings, as one value.
    var currentConnectionProfile: ConnectionProfile {
        ConnectionProfile(
            indexerURL: indexerURL,
            pushIndexerURL: pushIndexerURL,
            kaspaRestAPIURL: kaspaRestAPIURL,
            trustedNodeAddress: trustedNodeAddress,
            savedNodeAddresses: savedNodeAddresses
        )
    }

    /// Mainnet <-> testnet. The current network's connection settings are kept aside, the other
    /// network's come back (or its defaults, the first time), so each network remembers its own
    /// indexer, node and REST API. The wallet address follows at the next launch (see
    /// `WalletManager.walletOnCurrentNetwork`).
    mutating func switchNetwork(to network: NetworkType) {
        guard network != networkType else { return }
        connectionProfiles[networkType.rawValue] = currentConnectionProfile
        let next = connectionProfiles[network.rawValue] ?? .defaults(for: network)
        indexerURL = next.indexerURL
        pushIndexerURL = next.pushIndexerURL
        kaspaRestAPIURL = next.kaspaRestAPIURL
        trustedNodeAddress = next.trustedNodeAddress
        savedNodeAddresses = next.savedNodeAddresses
        networkType = network
    }

    static func defaultKNSURL(for network: NetworkType) -> String {
        network == .mainnet ? defaultKNSMainnetURL : defaultKNSTestnetURL
    }

    static func defaultKaspaRestURL(for network: NetworkType) -> String {
        network == .mainnet ? defaultKaspaMainnetURL : defaultKaspaTestnetURL
    }

    static var `default`: AppSettings {
        AppSettings(
            networkType: .mainnet,
            notificationMode: .remotePush,
            indexerURL: defaultIndexerURL,
            pushIndexerURL: defaultPushIndexerURL,
            kaspaRestAPIURL: defaultKaspaMainnetURL
        )
    }

    enum CodingKeys: String, CodingKey {
        case networkType
        case notificationMode
        case notificationPermissionRequested
        case incomingNotificationSoundEnabled
        case incomingNotificationVibrationEnabled
        case addressActivityNotificationsEnabled
        case appearance
        case language
        case currency
        case biometricSeedPhraseEnabled
        case biometricAccountLoginEnabled
        case biometricSpendingKeyEnabled
        case verboseAPILogging
        case indexerURL
        case pushIndexerURL
        case kaspaRestAPIURL
        case kaspaExplorer
        case trustedNodeAddress
        case savedNodeAddresses
        case connectionProfiles
        case grpcEndpointPool
        case discoverNewPeers
        case grpcPoolNetworkType
        case lastPoolPersistDate
        // Legacy keys for migration
        case autoRefreshGrpcPool  // Legacy, migrate to discoverNewPeers
        case notificationsEnabled  // Legacy, migrate to notificationMode
        case pushNotificationsEnabled  // Legacy, migrate to notificationMode
    }

    init(
        networkType: NetworkType,
        notificationMode: NotificationMode,
        notificationPermissionRequested: Bool = false,
        incomingNotificationSoundEnabled: Bool = true,
        incomingNotificationVibrationEnabled: Bool = true,
        addressActivityNotificationsEnabled: Bool = true,
        appearance: AppAppearance = .system,
        language: AppLanguage = .system,
        currency: AppCurrency = .usDollar,
        biometricSeedPhraseEnabled: Bool = true,
        // Asked when signing back in to a saved account: on by default (owner's call, 2026-11-01).
        biometricAccountLoginEnabled: Bool = true,
        biometricSpendingKeyEnabled: Bool = true,
        verboseAPILogging: Bool = false,
        indexerURL: String,
        pushIndexerURL: String,
        kaspaRestAPIURL: String,
        kaspaExplorer: KaspaExplorer = .default,
        trustedNodeAddress: String = AppSettings.defaultTrustedNodeAddress,
        savedNodeAddresses: [SavedNodeAddress] = [],
        grpcEndpointPool: [GrpcEndpoint] = [],
        discoverNewPeers: Bool = true,
        grpcPoolNetworkType: NetworkType? = nil,
        lastPoolPersistDate: Date? = nil
    ) {
        self.networkType = networkType
        self.notificationMode = notificationMode
        self.notificationPermissionRequested = notificationPermissionRequested
        self.incomingNotificationSoundEnabled = incomingNotificationSoundEnabled
        self.incomingNotificationVibrationEnabled = incomingNotificationVibrationEnabled
        self.addressActivityNotificationsEnabled = addressActivityNotificationsEnabled
        self.appearance = appearance
        self.language = language
        self.currency = currency
        self.biometricSeedPhraseEnabled = biometricSeedPhraseEnabled
        self.biometricAccountLoginEnabled = biometricAccountLoginEnabled
        self.biometricSpendingKeyEnabled = biometricSpendingKeyEnabled
        self.verboseAPILogging = verboseAPILogging
        self.indexerURL = indexerURL
        self.pushIndexerURL = pushIndexerURL
        self.kaspaRestAPIURL = kaspaRestAPIURL
        self.kaspaExplorer = kaspaExplorer
        self.trustedNodeAddress = trustedNodeAddress
        self.savedNodeAddresses = savedNodeAddresses
        self.grpcEndpointPool = grpcEndpointPool
        self.discoverNewPeers = discoverNewPeers
        self.grpcPoolNetworkType = grpcPoolNetworkType
        self.lastPoolPersistDate = lastPoolPersistDate
    }

    /// Every field falls back to its default, so a blob from an older build (including KaChat's
    /// chat settings it no longer has) decodes without resetting anything.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkType = try container.decodeIfPresent(NetworkType.self, forKey: .networkType) ?? .mainnet
        if let storedModeRaw = try container.decodeIfPresent(String.self, forKey: .notificationMode) {
            notificationMode = storedModeRaw == NotificationMode.disabled.rawValue ? .disabled : .remotePush
        } else {
            let legacyNotifications = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
            let legacyPush = try container.decodeIfPresent(Bool.self, forKey: .pushNotificationsEnabled) ?? false
            notificationMode = legacyPush || legacyNotifications ? .remotePush : .disabled
        }
        notificationPermissionRequested = try container.decodeIfPresent(Bool.self, forKey: .notificationPermissionRequested) ?? false
        incomingNotificationSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .incomingNotificationSoundEnabled) ?? true
        incomingNotificationVibrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .incomingNotificationVibrationEnabled) ?? true
        addressActivityNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .addressActivityNotificationsEnabled) ?? true
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        currency = try container.decodeIfPresent(AppCurrency.self, forKey: .currency) ?? .usDollar
        biometricSeedPhraseEnabled = try container.decodeIfPresent(Bool.self, forKey: .biometricSeedPhraseEnabled) ?? true
        biometricAccountLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .biometricAccountLoginEnabled) ?? true
        biometricSpendingKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .biometricSpendingKeyEnabled) ?? true
        verboseAPILogging = try container.decodeIfPresent(Bool.self, forKey: .verboseAPILogging) ?? false

        func filled(_ key: CodingKeys, _ fallback: String) throws -> String {
            let stored = try container.decodeIfPresent(String.self, forKey: key) ?? ""
            return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : stored
        }
        let indexerDefault = networkType == .testnet ? AppSettings.defaultTestnetIndexerURL : AppSettings.defaultIndexerURL
        // Superseded defaults migrate: mainnet (kasia, kachat.duckdns.org) to indexer.kachat.app,
        // testnet (tnkachat.duckdns.org) to blank.
        indexerURL = AppSettings.migratedIndexerURL(try filled(.indexerURL, indexerDefault), network: networkType)
        let storedPush = try filled(.pushIndexerURL, networkType == .testnet ? AppSettings.defaultTestnetIndexerURL : AppSettings.defaultPushIndexerURL)
        pushIndexerURL = AppSettings.migratedIndexerURL(storedPush, network: networkType)

        kaspaRestAPIURL = try container.decodeIfPresent(String.self, forKey: .kaspaRestAPIURL) ?? AppSettings.defaultKaspaRestURL(for: networkType)
        connectionProfiles = try container.decodeIfPresent([String: ConnectionProfile].self, forKey: .connectionProfiles) ?? [:]
        // Testnet moved from the retired testnet-11 to testnet-10: carry the old default forward,
        // both live and in the stashed testnet profile. A custom URL is left alone.
        if kaspaRestAPIURL == AppSettings.legacyDefaultKaspaTestnetURL {
            kaspaRestAPIURL = AppSettings.defaultKaspaTestnetURL
        }
        if connectionProfiles[NetworkType.testnet.rawValue]?.kaspaRestAPIURL == AppSettings.legacyDefaultKaspaTestnetURL {
            connectionProfiles[NetworkType.testnet.rawValue]?.kaspaRestAPIURL = AppSettings.defaultKaspaTestnetURL
        }
        // The stashed profiles get the same indexer migration as the live settings.
        for network in NetworkType.allCases {
            guard var stashed = connectionProfiles[network.rawValue] else { continue }
            stashed.indexerURL = AppSettings.migratedIndexerURL(stashed.indexerURL, network: network)
            stashed.pushIndexerURL = AppSettings.migratedIndexerURL(stashed.pushIndexerURL, network: network)
            connectionProfiles[network.rawValue] = stashed
        }
        kaspaExplorer = try container.decodeIfPresent(KaspaExplorer.self, forKey: .kaspaExplorer) ?? .default
        trustedNodeAddress = try container.decodeIfPresent(String.self, forKey: .trustedNodeAddress) ?? AppSettings.defaultTrustedNodeAddress
        savedNodeAddresses = try container.decodeIfPresent([SavedNodeAddress].self, forKey: .savedNodeAddresses) ?? []

        // gRPC pool settings
        grpcEndpointPool = try container.decodeIfPresent([GrpcEndpoint].self, forKey: .grpcEndpointPool) ?? []
        grpcPoolNetworkType = try container.decodeIfPresent(NetworkType.self, forKey: .grpcPoolNetworkType)
        lastPoolPersistDate = try container.decodeIfPresent(Date.self, forKey: .lastPoolPersistDate)

        // Migrate from legacy autoRefreshGrpcPool to discoverNewPeers
        if let newValue = try container.decodeIfPresent(Bool.self, forKey: .discoverNewPeers) {
            discoverNewPeers = newValue
        } else if let legacyValue = try container.decodeIfPresent(Bool.self, forKey: .autoRefreshGrpcPool) {
            discoverNewPeers = legacyValue
        } else {
            discoverNewPeers = true
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(networkType, forKey: .networkType)
        try container.encode(notificationMode, forKey: .notificationMode)
        try container.encode(notificationPermissionRequested, forKey: .notificationPermissionRequested)
        try container.encode(incomingNotificationSoundEnabled, forKey: .incomingNotificationSoundEnabled)
        try container.encode(incomingNotificationVibrationEnabled, forKey: .incomingNotificationVibrationEnabled)
        try container.encode(addressActivityNotificationsEnabled, forKey: .addressActivityNotificationsEnabled)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(language, forKey: .language)
        try container.encode(currency, forKey: .currency)
        try container.encode(biometricSeedPhraseEnabled, forKey: .biometricSeedPhraseEnabled)
        try container.encode(biometricAccountLoginEnabled, forKey: .biometricAccountLoginEnabled)
        try container.encode(biometricSpendingKeyEnabled, forKey: .biometricSpendingKeyEnabled)
        try container.encode(verboseAPILogging, forKey: .verboseAPILogging)
        try container.encode(indexerURL, forKey: .indexerURL)
        try container.encode(pushIndexerURL, forKey: .pushIndexerURL)
        try container.encode(kaspaRestAPIURL, forKey: .kaspaRestAPIURL)
        try container.encode(kaspaExplorer, forKey: .kaspaExplorer)
        try container.encode(trustedNodeAddress, forKey: .trustedNodeAddress)
        try container.encode(savedNodeAddresses, forKey: .savedNodeAddresses)
        try container.encode(connectionProfiles, forKey: .connectionProfiles)
        try container.encode(grpcEndpointPool, forKey: .grpcEndpointPool)
        try container.encode(discoverNewPeers, forKey: .discoverNewPeers)
        try container.encodeIfPresent(grpcPoolNetworkType, forKey: .grpcPoolNetworkType)
        try container.encodeIfPresent(lastPoolPersistDate, forKey: .lastPoolPersistDate)
    }

    var notificationsEnabled: Bool {
        get { notificationMode != .disabled }
        set { notificationMode = newValue ? .remotePush : .disabled }
    }

    var backgroundFetchEnabled: Bool {
        get { false }
        set { }
    }

    var pushNotificationsEnabled: Bool {
        get { notificationMode == .remotePush }
        set {
            if newValue {
                notificationMode = .remotePush
            } else if notificationMode == .remotePush {
                notificationMode = .disabled
            }
        }
    }
}

// MARK: - Error Types

enum KasiaError: LocalizedError {
    case walletNotFound
    case invalidSeedPhrase
    case seedPhraseParsingFailed(wordCount: Int)
    case mnemonicValidationFailed(reason: String)
    case invalidAddress
    /// The address belongs to one of the user's own accounts on this device.
    case ownAccountAddress
    case networkError(String)
    case keychainError(String)
    case encryptionError(String)
    case apiError(String)
    case unknownError

    var errorDescription: String? {
        switch self {
        case .walletNotFound:
            return "Account not found. Please create or import an account."
        case .invalidSeedPhrase:
            return "Invalid seed phrase. Please enter 12 or 24 words."
        case .seedPhraseParsingFailed(let wordCount):
            return "Seed phrase parsing failed. Detected \(wordCount) words (expected 12 or 24)."
        case .mnemonicValidationFailed(let reason):
            return "Mnemonic validation failed: \(reason)"
        case .invalidAddress:
            return "Invalid Kaspa address format."
        case .ownAccountAddress:
            return "That address is one of your own accounts, so it cannot be added as a contact."
        case .networkError(let message):
            return "Network error: \(message)"
        case .keychainError(let message):
            return "Keychain error: \(message)"
        case .encryptionError(let message):
            return "Encryption error: \(message)"
        case .apiError(let message):
            return "API error: \(message)"
        case .unknownError:
            return "An unknown error occurred."
        }
    }
}

/// What an error says when a person has to read it.
///
/// About forty alerts used to show `error.localizedDescription` as it came: Foundation's
/// `DecodingError` dump when a feed failed to parse, a raw `URLError` string when a backup
/// failed, "Keychain error: -25300". The app's own errors carry sentences already written for
/// the user, so those pass through with their developer prefixes stripped; system and library
/// errors are translated; the raw text still goes to the log for diagnostics.
enum UserFacingError {
    static func message(for error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        if let kasia = error as? KasiaError {
            switch kasia {
            case .networkError(let text), .apiError(let text), .keychainError(let text), .encryptionError(let text):
                return text.isEmpty ? kasia.localizedDescription : text
            default:
                return kasia.localizedDescription
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "No internet connection. Check your connection and try again."
            case .timedOut:
                return "The connection timed out. Check your connection and try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .badURL, .unsupportedURL:
                return "Couldn't reach the server. Check the address in Settings and your connection."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
                return "Couldn't make a secure connection to the server."
            case .cancelled:
                return "Cancelled."
            default:
                return "A network error occurred. Check your connection and try again."
            }
        }
        if error is DecodingError {
            return "The server sent something the app couldn't read. Try again; if it keeps happening, update the app."
        }
        let typeName = String(describing: type(of: error))
        if typeName.hasPrefix("GRPC") {
            return "The Kaspa node returned an error. The app will try another node; try again in a moment."
        }
        // LocalizedError conformers (NextcloudError, the swap client, ...) write their own
        // sentences; anything else gets Foundation's description with any prefix removed.
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return message(text)
    }

    /// The same treatment for an error that is already a string.
    static func message(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Network error: ", "API error: ", "Keychain error: ", "Encryption error: "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)) }
        }
        return cleaned.isEmpty ? "Something went wrong. Please try again." : cleaned
    }
}

// MARK: - gRPC Endpoint Pool

/// Pool tier for endpoint classification
enum PoolType: Int, Codable, CaseIterable {
    case hot = 0    // Active endpoints for user requests
    case warm = 1   // Validated candidates ready for promotion
    case cold = 2   // Discovery source, unchecked or failed endpoints

    var displayName: String {
        switch self {
        case .hot: return "Hot"
        case .warm: return "Warm"
        case .cold: return "Cold"
        }
    }
}

/// Origin of endpoint
enum EndpointOrigin: Int, Codable {
    case dynamic = 0        // Discovered via peer discovery
    case userAdded = 1      // Manually added by user
    case preProvisioned = 2 // Bundled with app

    var displayName: String {
        switch self {
        case .dynamic: return "Discovered"
        case .userAdded: return "Manual"
        case .preProvisioned: return "Default"
        }
    }

    /// Whether this endpoint can be deleted by user
    var canDelete: Bool { true }

    /// Maximum cooling time for this origin type
    var maxCoolingMinutes: Int {
        switch self {
        case .preProvisioned: return 5
        default: return 7 * 24 * 60 // 1 week
        }
    }
}

/// A user-saved "host:port" node address, kept purely for quick copy/paste into the
/// trusted-node field in Connection Settings - not itself used for connections.
/// One network's connection settings - see `AppSettings.connectionProfiles`.
struct ConnectionProfile: Codable, Equatable {
    var indexerURL: String
    var pushIndexerURL: String
    var kaspaRestAPIURL: String
    var trustedNodeAddress: String
    var savedNodeAddresses: [SavedNodeAddress]

    /// What a network starts with. Testnet: the public testnet REST API, automatic node
    /// discovery, and no indexer (push and .kachat names stay off unless one is entered).
    static func defaults(for network: NetworkType) -> ConnectionProfile {
        switch network {
        case .mainnet:
            return ConnectionProfile(
                indexerURL: AppSettings.defaultIndexerURL,
                pushIndexerURL: AppSettings.defaultPushIndexerURL,
                kaspaRestAPIURL: AppSettings.defaultKaspaMainnetURL,
                trustedNodeAddress: AppSettings.defaultTrustedNodeAddress,
                savedNodeAddresses: []
            )
        case .testnet:
            return ConnectionProfile(
                indexerURL: AppSettings.defaultTestnetIndexerURL,
                pushIndexerURL: AppSettings.defaultTestnetIndexerURL,
                kaspaRestAPIURL: AppSettings.defaultKaspaTestnetURL,
                trustedNodeAddress: "",
                savedNodeAddresses: []
            )
        }
    }
}

struct SavedNodeAddress: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var address: String

    init(id: UUID = UUID(), label: String, address: String) {
        self.id = id
        self.label = label
        self.address = address
    }
}

struct GrpcEndpoint: Codable, Identifiable, Equatable {
    var id: String { url }
    let url: String

    // Pool assignment
    var pool: PoolType

    // Health metrics
    var latencyMs: Int?              // Last measured gRPC ping latency
    var errorCount: Int              // Cumulative errors (preserved across transitions)
    var coolingUntil: Date?          // Don't recheck until this time
    var lastDaaScore: UInt64?        // Last observed DAA score

    // Tracking
    var peerSeenDate: Date?          // Last seen in getPeerAddresses response
    var lastSuccessDate: Date?       // Last successful request
    var lastCheckDate: Date?         // Last health check attempt
    var dateAdded: Date              // When endpoint was first added

    // Origin and network
    var origin: EndpointOrigin
    var networkType: NetworkType

    // Legacy compatibility
    var isManual: Bool {
        get { origin == .userAdded }
        set { if newValue { origin = .userAdded } }
    }

    init(url: String, networkType: NetworkType, origin: EndpointOrigin = .dynamic, pool: PoolType = .cold) {
        self.url = url
        self.networkType = networkType
        self.origin = origin
        self.pool = pool
        self.dateAdded = Date()
        self.latencyMs = nil
        self.errorCount = 0
        self.lastSuccessDate = nil
        self.coolingUntil = nil
        self.lastDaaScore = nil
        self.peerSeenDate = nil
        self.lastCheckDate = nil
    }

    // MARK: - Codable with migration support

    enum CodingKeys: String, CodingKey {
        case url, pool, latencyMs, errorCount, coolingUntil, lastDaaScore
        case peerSeenDate, lastSuccessDate, lastCheckDate, dateAdded
        case origin, networkType
        // Legacy keys for migration
        case isManual
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        url = try container.decode(String.self, forKey: .url)
        networkType = try container.decode(NetworkType.self, forKey: .networkType)

        // New fields with defaults for migration
        pool = try container.decodeIfPresent(PoolType.self, forKey: .pool) ?? .cold
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
        errorCount = try container.decodeIfPresent(Int.self, forKey: .errorCount) ?? 0
        coolingUntil = try container.decodeIfPresent(Date.self, forKey: .coolingUntil)
        lastDaaScore = try container.decodeIfPresent(UInt64.self, forKey: .lastDaaScore)
        peerSeenDate = try container.decodeIfPresent(Date.self, forKey: .peerSeenDate)
        lastSuccessDate = try container.decodeIfPresent(Date.self, forKey: .lastSuccessDate)
        lastCheckDate = try container.decodeIfPresent(Date.self, forKey: .lastCheckDate)
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()

        // Migrate origin from legacy isManual field
        if let origin = try container.decodeIfPresent(EndpointOrigin.self, forKey: .origin) {
            self.origin = origin
        } else if let isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual), isManual {
            self.origin = .userAdded
        } else {
            self.origin = .dynamic
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(pool, forKey: .pool)
        try container.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try container.encode(errorCount, forKey: .errorCount)
        try container.encodeIfPresent(coolingUntil, forKey: .coolingUntil)
        try container.encodeIfPresent(lastDaaScore, forKey: .lastDaaScore)
        try container.encodeIfPresent(peerSeenDate, forKey: .peerSeenDate)
        try container.encodeIfPresent(lastSuccessDate, forKey: .lastSuccessDate)
        try container.encodeIfPresent(lastCheckDate, forKey: .lastCheckDate)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encode(origin, forKey: .origin)
        try container.encode(networkType, forKey: .networkType)
    }

    /// Display-friendly hostname extracted from URL
    var displayName: String {
        guard let urlComponents = URLComponents(string: url),
              let host = urlComponents.host else {
            return url
        }
        return host
    }

    /// Time since endpoint was added, formatted for display
    var addedAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: dateAdded, relativeTo: Date())
    }

    /// Whether endpoint is currently in cooling period
    var isCooling: Bool {
        guard let coolingUntil = coolingUntil else { return false }
        return Date() < coolingUntil
    }

    /// Calculate cooling time based on error count and origin
    mutating func setCoolingTime() {
        let baseMinutes: Double
        let maxMinutes: Double
        let randomRange: Double

        switch origin {
        case .preProvisioned:
            baseMinutes = 1
            maxMinutes = 5
            randomRange = 1
        default:
            baseMinutes = 10
            maxMinutes = Double(7 * 24 * 60) // 1 week
            randomRange = 10
        }

        let coolingMinutes = min(maxMinutes, baseMinutes * pow(2, Double(errorCount)))
        let randomMinutes = Double.random(in: 0...randomRange)
        coolingUntil = Date().addingTimeInterval((coolingMinutes + randomMinutes) * 60)
    }

    /// Set success cooling time (for periodic rechecks)
    mutating func setSuccessCoolingTime() {
        let baseMinutes: Double
        let randomRange: Double

        switch pool {
        case .hot:
            baseMinutes = 10
            randomRange = 10
        case .warm:
            baseMinutes = 30
            randomRange = 30
        case .cold:
            baseMinutes = 60
            randomRange = 60
        }

        coolingUntil = Date().addingTimeInterval((baseMinutes + Double.random(in: 0...randomRange)) * 60)
    }
}

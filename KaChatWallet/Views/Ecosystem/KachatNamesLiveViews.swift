import SwiftUI
import UIKit

// The live `.kachat` screens, TESTNET ONLY (testnet-10 and a verified registry manifest): the hub's
// search, registrations in flight, Marketplace / My Names / Activity, the name detail with its
// actions, every transaction sheet and the address profile editor. On mainnet none of this is
// reached - `KachatMarketView`, `KachatListingDetailView` and the profile editor keep their
// "Coming soon" mockups. Every spending or destructive action shows its cost first, asks to
// confirm, then passes the device's own lock (`DeviceAuth`) before anything is signed.

// MARK: - Amounts

extension KaspaUnit {
    /// "35 TKAS", "0.2 TKAS", "1.99831 TKAS": exact, trailing zeros dropped.
    static func amount(_ sompi: UInt64) -> String {
        "\(plain(sompi)) \(symbol)"
    }

    static func plain(_ sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let frac = sompi % 100_000_000
        guard frac > 0 else { return "\(whole)" }
        var f = String(format: "%08llu", frac)
        while f.hasSuffix("0") { f.removeLast() }
        return "\(whole).\(f)"
    }

    /// "+1.99 TKAS" / "-36.002 TKAS".
    static func signed(_ delta: Int64) -> String {
        delta >= 0 ? "+\(amount(UInt64(delta)))" : "-\(amount(delta.magnitude))"
    }
}

// MARK: - Shared pieces

enum KachatLive {
    /// The registry is live on this network (testnet only for now) - reads and actions run.
    static var isEnabled: Bool { KachatNamesService.isLaunched }
    /// What the device lock prompt says before any .kachat transaction is signed.
    static var authReason: String { AppLocalization.string("Confirm this .kachat transaction") }
    /// testnet-10 runs at 10 blocks per second
    static let daaPerSecond: UInt64 = 10

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    /// A unix-ms day as a row value ("Oct 12, 2027"), in the in-app language, with the time when
    /// it is within two days (testnet's 24-hour periods).
    static func day(_ ms: Int64) -> String {
        let near = abs(ms - KachatNames.nowMs()) < 2 * 86_400_000
        return date(ms).formatted(Date.FormatStyle(date: .abbreviated, time: near ? .shortened : .omitted).locale(AppLocalization.locale))
    }

    /// The registry parameters, once the manifest is verified.
    @MainActor static var params: KachatNames.Params? { KachatNamesService.shared.manifest?.params }

    /// The receipt's line for a registration: how much stays locked with the name.
    @MainActor static var lockedNote: String? {
        guard let p = params else { return nil }
        return String(format: AppLocalization.string("%@ is locked with this name. It comes back to you when you release it."), KaspaUnit.amount(p.bond + p.gapValue))
    }

    /// Whether a period is a year (mainnet), not a short test clock (testnet's 24 hours).
    @MainActor static var yearlyPeriods: Bool { (params?.periodMs ?? KachatNames.yearMs) == KachatNames.yearMs }

    /// A length of time ("10 min", "10 days"), in the in-app language.
    /// Time left until a moment, for a live countdown: "2d 5h" while days remain, else "1:04:09"
    /// or "4:09" (hours, minutes, seconds).
    static func countdown(_ ms: Int64) -> String {
        let seconds = Double(max(ms, 0)) / 1000
        let f: DateComponentsFormatter
        if seconds >= 86_400 {
            f = componentsFormatter("countdown-days") {
                $0.allowedUnits = [.day, .hour]
                $0.unitsStyle = .abbreviated
                $0.maximumUnitCount = 2
            }
        } else {
            let hours = seconds >= 3600
            f = componentsFormatter(hours ? "countdown-hms" : "countdown-ms") {
                $0.allowedUnits = hours ? [.hour, .minute, .second] : [.minute, .second]
                $0.unitsStyle = .positional
                $0.zeroFormattingBehavior = .pad
            }
        }
        return f.string(from: seconds) ?? ""
    }

    static func duration(_ ms: Int64) -> String {
        let seconds = Double(ms) / 1000
        let units: NSCalendar.Unit = seconds >= 86_400 ? [.day] : (seconds >= 3600 ? [.hour, .minute] : [.minute])
        let f = componentsFormatter("duration-\(units.rawValue)") {
            $0.allowedUnits = units
            $0.unitsStyle = .abbreviated
            $0.maximumUnitCount = 2
        }
        return f.string(from: seconds) ?? ""
    }

    /// One formatter per style and language, not one per call: the Expired page ticks every
    /// tile's countdown once a second.
    private static var componentsFormatters: [String: DateComponentsFormatter] = [:]
    private static let componentsFormattersLock = NSLock()

    private static func componentsFormatter(_ style: String, _ configure: (DateComponentsFormatter) -> Void) -> DateComponentsFormatter {
        let locale = AppLocalization.locale
        let key = style + "|" + locale.identifier
        componentsFormattersLock.lock()
        defer { componentsFormattersLock.unlock() }
        if let known = componentsFormatters[key] { return known }
        let f = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        f.calendar = calendar
        configure(f)
        componentsFormatters[key] = f
        return f
    }

    /// `count` periods: "1 year" / "2 years", or on a short clock "10 min" / "20 min".
    @MainActor static func periods(_ count: Int64) -> String {
        if yearlyPeriods {
            return count == 1 ? AppLocalization.string("1 year") : String(format: AppLocalization.string("%lld years"), count)
        }
        return duration(count * (params?.periodMs ?? KachatNames.yearMs))
    }

    /// Who an address is when you haven't named it yourself: its `.kachat` name ("alice.kachat"),
    /// the same rule as `AddressBookManager.displayName`. nil without one (mainnet, until names
    /// launch). Views that call this observe `KachatNamesRegistry` so the name lands on its own.
    @MainActor static func identityName(_ address: String) -> String? {
        guard !address.isEmpty else { return nil }
        return KachatNamesRegistry.shared.cachedIdentity(for: address)?.label.map { "\($0).kachat" }
    }

    /// An address's `.kachat` profile banner and bio, each looked up from its social link on this
    /// device (every network: profiles aren't registry data). Callers observe
    /// `KachatNamesRegistry` and `KachatSocialImageResolver`.
    @MainActor static func profileBanner(_ address: String) -> String? {
        let link = KachatNamesRegistry.shared.cachedIdentity(for: address)?.profile?.banner
        return KachatSocialImageResolver.shared.profile(for: link)?.banner
    }

    @MainActor static func profileBio(_ address: String) -> String? {
        let link = KachatNamesRegistry.shared.cachedIdentity(for: address)?.profile?.bio
        return KachatSocialImageResolver.shared.profile(for: link)?.bio
    }

    /// What registering `name` costs for its first period (registry v4: fixed, baked into the
    /// pinned templates). Each further period costs `renewPrice`.
    @MainActor static func price(_ name: String) -> UInt64? {
        guard let prices = KachatNamesRegistry.shared.registerPrices, prices.count == 5 else { return nil }
        return prices[KachatNames.Codec.tier(name.utf8.count)]
    }

    /// What one more period of `name` costs: extend, renew, and registering past the first period.
    @MainActor static func renewPrice(_ name: String) -> UInt64? {
        guard let prices = KachatNamesRegistry.shared.renewPrices, prices.count == 5 else { return nil }
        return prices[KachatNames.Codec.tier(name.utf8.count)]
    }

    /// "Price per year", or on a short clock "Price per 10 min".
    @MainActor static var pricePerPeriodTitle: LocalizedStringKey {
        yearlyPeriods ? "Price per year" : "Price per \(periods(1))"
    }

    /// An event party: an address (indexer) or an x-only key in hex (walker), as a short address.
    static func party(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("kaspa") { return KachatNamesRegistry.shortAddress(s) }
        if let key = try? KachatNames.unhex32(s), let a = KachatNamesRegistry.address(of: key) {
            return KachatNamesRegistry.shortAddress(a)
        }
        return s
    }

    /// A key of this wallet: the chatting address or any revealed spending address (IOS-085).
    @MainActor static func isMine(_ key: Data) -> Bool { KachatNamesActions.shared.isOwnKey(key) }

    static func eventIcon(_ op: String) -> String {
        switch op {
        case "register": return "at.badge.plus"
        case "transfer": return "arrow.left.arrow.right"
        case "list": return "tag"
        case "delist": return "tag.slash"
        case "sale", "offer_accepted": return "cart"
        case "extend": return "calendar.badge.plus"
        case "renew": return "arrow.clockwise"
        case "release": return "arrow.uturn.backward"
        case "reclaim": return "arrow.3.trianglepath"
        case "import": return "arrow.down.doc"
        default: return "hand.raised"
        }
    }

    static func eventTitle(_ op: String) -> LocalizedStringKey {
        switch op {
        case "register": return "Registered"
        case "transfer": return "Transferred"
        case "list": return "Listed"
        case "delist": return "Delisted"
        case "sale": return "Sold"
        case "offer_accepted", "offer_accept": return "Offer accepted"
        case "extend": return "Extended"
        case "renew": return "Renewed"
        case "release": return "Released"
        case "reclaim": return "Reclaimed"
        case "import": return "Moved to the new registry"
        case "offer": return "Offer made"
        case "offer_withdraw": return "Offer withdrawn"
        case "offer_refund": return "Offer refunded"
        case "offer_decline": return "Offer declined"
        default: return "Activity"
        }
    }

    /// Why a typed name is not a name.
    static func invalidReason(_ name: String) -> LocalizedStringKey? {
        let b = Array(name.utf8)
        if b.isEmpty || b.count > 32 { return "A name is 1 to 32 characters." }
        if !b.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d }) {
            return "Use a-z, 0-9 and hyphens only."
        }
        if b.first == 0x2d || b.last == 0x2d { return "A name can't start or end with a hyphen." }
        return nil
    }

}

/// The app's glass card (`.regularMaterial`, hairline, soft shadow).
struct KachatGlass: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 4)
        )
    }
}

extension View {
    func kachatGlass(cornerRadius: CGFloat = 16) -> some View { modifier(KachatGlass(cornerRadius: cornerRadius)) }
}

/// "Testnet", on testnet only: mainnet's names are the real ones and need no label.
struct KachatTestnetBadge: View {
    var body: some View {
        if KachatNamesService.networkName != "mainnet" {
            Text("Testnet")
                .font(.caption.weight(.bold))
                .foregroundColor(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
        }
    }
}

struct KachatStatusPill: View {
    let status: KachatNames.Status

    var body: some View {
        Group {
            switch status {
            case .active: Text("Active")
            case .grace: Text("Expired")
            // past grace a name is free to claim
            case .lapsed: Text("Available")
            }
        }
        .font(.caption2.weight(.bold))
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private var color: Color {
        switch status {
        case .active: return .green
        case .grace: return .orange
        case .lapsed: return .green
        }
    }
}

// MARK: - Name tiles

/// A square tile for one name in the marketplace grids (For sale, Available): the full name -
/// it wraps onto more lines, never truncates, and the tile grows to fit - with ".kachat" under
/// it, and the price (or a Reclaim button) at the bottom.
struct KachatNameTile<Footer: View>: View {
    let name: String
    @ViewBuilder var footer: Footer

    /// Centered: the name, ".kachat" under it, then the footer (the price asked, and any button).
    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(verbatim: name)
                    .font(.headline.weight(.bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: ".kachat")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
            footer
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
        .kachatGlass()
        .contentShape(Rectangle())
    }
}

/// Two tiles per row.
struct KachatNameGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            content
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Hub model

@MainActor
final class KachatHubModel: ObservableObject {
    enum Search: Equatable {
        case idle
        case checking
        case invalid(String)
        case free(String, KachatNames.GapInfo?)
        case registered(KachatNames.NameInfo)
        case failed(String)
    }

    /// nil until the manifest is checked; false when it fails (the hub then stays a mockup).
    @Published private(set) var ready: Bool?
    @Published private(set) var setupError: String?
    /// The manifest is for the previous registry (v1): the hub says "Setting up", calmly.
    @Published private(set) var upgrading = false
    @Published private(set) var search: Search = .idle
    @Published private(set) var listings: [KachatNames.NameInfo] = []
    @Published private(set) var lapsed: [KachatNames.NameInfo] = []
    /// Expired and still in grace: the Expired tab, with a countdown to each release.
    @Published private(set) var grace: [KachatNames.NameInfo] = []
    @Published private(set) var mine: [KachatNames.NameInfo] = []
    @Published private(set) var myOffers: [KachatNames.OfferInfo] = []
    @Published private(set) var activity: [KachatNames.Event] = []
    @Published private(set) var loadError: String?
    @Published private(set) var loaded = false

    var registry: KachatNamesRegistry { .shared }
    var params: KachatNames.Params? { KachatNamesService.shared.manifest?.params }
    var isLive: Bool { KachatLive.isEnabled && ready == true }

    func start() async {
        guard KachatLive.isEnabled else {
            // Not launched here (mainnet): the same pages, empty, under "Coming soon".
            ready = nil
            loaded = true
            return
        }
        do {
            try await registry.prepare(forceSourceCheck: true)
            ready = true
            setupError = nil
            upgrading = false
        } catch {
            ready = false
            upgrading = KachatNamesService.isRegistryUpgrading(error)
            setupError = error.localizedDescription
            return
        }
        KachatNamesActions.shared.resume()
        // Coming back to the screen: the pages are loaded, so only a stale registry is refreshed
        // (the screen reloads on its revision). A full refresh and reload ran on every appear.
        if loaded, loadError == nil {
            await registry.refreshIfStale()
            return
        }
        // A refresh that moved `revision` already reloads through the screen's revision
        // observer; reloading here as well ran the seven requests twice, side by side.
        let before = registry.revision
        await registry.refresh()
        if registry.revision == before { await reload() }
    }

    func refresh() async {
        guard isLive else { return }
        await registry.refresh()
        await reload()
    }

    func reload() async {
        guard isLive else { return }
        do {
            listings = try await registry.listings()
            lapsed = try await registry.lapsed()
            grace = (try? await registry.inGrace()) ?? []
            // the chatting address and every used address of this wallet (IOS-085)
            if KachatNamesActions.shared.myKey != nil {
                let own = try await KachatNamesActions.shared.ownNamesAndOffers(heldOnly: false)
                mine = own.names
                myOffers = own.offers
                if !myOffers.isEmpty {
                    await KachatNamesActions.shared.refreshVirtualDaa()
                    // Your own expired offers come back to you on their own, and so do the ones
                    // whose name changed hands since you made them.
                    await KachatNamesActions.shared.returnExpiredOffers(myOffers)
                    await KachatNamesActions.shared.withdrawDeclinedOffers(myOffers)
                }
            } else {
                mine = []
                myOffers = []
            }
            activity = try await registry.activity()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    func lookup(_ text: String) async {
        let typed = KachatNames.Codec.normalize(text)
        guard !typed.isEmpty else { search = .idle; return }
        guard KachatLive.invalidReason(typed) == nil else { search = .invalid(typed); return }
        search = .checking
        do {
            switch try await registry.claimLookup(typed) {
            case .registered(let n): search = .registered(n)
            case .free(let name, let gap): search = .free(name, gap)
            }
        } catch {
            search = .failed(error.localizedDescription)
        }
    }

    func pricePerYear(_ name: String) -> UInt64? { KachatLive.price(name) }
}

// MARK: - Hub: search result

struct KachatClaimTarget: Identifiable {
    let name: String
    let gap: KachatNames.GapInfo
    var id: String { name }
}

struct KachatLiveSearchResult: View {
    @ObservedObject var model: KachatHubModel
    let typed: String
    let onClaim: (KachatClaimTarget) -> Void

    var body: some View {
        content
            .padding(12)
            .kachatGlass(cornerRadius: 12)
            .task(id: typed) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await model.lookup(typed)
            }
    }

    private var name: String { KachatNames.Codec.normalize(typed) }

    @ViewBuilder
    private var content: some View {
        switch model.search {
        case .registered(let n) where n.name == name:
            NavigationLink {
                KachatListingDetailView(info: n)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: n.display).font(.headline).lineLimit(1)
                        registeredLine(n)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(Color(.tertiaryLabel))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .free(let free, let gap) where free == name:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(free).kachat").font(.headline).lineLimit(1)
                    // no price here: a name's first year and later years cost differently (the
                    // claim's "For how long?" shows each)
                    Text("Available")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                Spacer()
                Button("Claim") {
                    if let gap { onClaim(KachatClaimTarget(name: free, gap: gap)) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(gap == nil)
            }
        case .invalid:
            row(subtitle: KachatLive.invalidReason(name).map { Text($0) } ?? Text("Not a valid name."))
        case .failed(let message):
            row(subtitle: Text(verbatim: message))
        default:
            HStack(spacing: 10) {
                Text(verbatim: "\(name).kachat").font(.headline).lineLimit(1)
                Spacer()
                ProgressView()
            }
        }
    }

    private func row(subtitle: Text) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(name).kachat").font(.headline).lineLimit(1)
                subtitle.font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func registeredLine(_ n: KachatNames.NameInfo) -> some View {
        switch n.status(graceMs: KachatNamesRegistry.shared.graceMs) {
        case .active:
            if KachatLive.isMine(n.owner) {
                Text("Yours").font(.caption).foregroundColor(.secondary)
            } else if n.isListed {
                Text("Taken · for sale at \(KaspaUnit.amount(n.price))").font(.caption).foregroundColor(.secondary)
            } else {
                Text("Taken").font(.caption).foregroundColor(.secondary)
            }
        case .grace:
            Text("Expired - the owner can still renew it").font(.caption).foregroundColor(.orange)
        case .lapsed:
            // never reached: a lapsed name searches as free to claim (`claimLookup`)
            EmptyView()
        }
    }
}

// MARK: - A finished transaction

/// A name transaction that went out: what it did and its id, for the half sheet below.
struct KachatTxDone: Identifiable, Equatable {
    var id: String { txId }
    let txId: String
    /// Localization key of the headline ("Listed for sale", "Profile saved", ...).
    var title: String = "Transaction sent"
    /// Already known to be in a block (a registration the driver saw land): no progress to follow.
    var accepted = false
    /// A line under the headline - a registration says how much stays locked with the name.
    var note: String? = nil
}

/// The receipt every name transaction ends on, in the Send receipt's style: what it does, its
/// progress followed on a node - sent, in a block, showing in KaChat - and the transaction id
/// as a link to the block explorer picked in Settings (the testnet-10 one on testnet), opened in
/// the in-app browser. Closing it early is fine: the change still lands.
struct KachatTxDoneSheet: View {
    let done: KachatTxDone
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var actions = KachatNamesActions.shared
    @State private var browserURL: URL?

    private var explorerURL: URL? { AppSettings.load().kaspaExplorer.txURL(for: done.txId) }
    private var stage: KachatNamesActions.TxStage { actions.txStages[done.txId] ?? (done.accepted ? .shown : .sent) }
    private var inBlock: Bool { stage == .accepted || stage == .shown }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch stage {
                case .shown:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.scaled(size: 52))
                        .foregroundColor(.green)
                case .dropped:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.scaled(size: 52))
                        .foregroundColor(.orange)
                default:
                    ProgressView()
                        .controlSize(.large)
                        .frame(height: 52)
                }
            }
            .padding(.top, 28)

            Text(LocalizedStringKey(done.title))
                .font(.title3.weight(.bold))
                .padding(.top, 12)

            Text(stageText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 4)

            if let note = done.note {
                Label { Text(verbatim: note) } icon: { Image(systemName: "lock.fill") }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .multilineTextAlignment(.leading)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sendKaspaGlass(cornerRadius: 14))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            KachatTxStageSteps(txId: done.txId, accepted: done.accepted)
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Button {
                browserURL = explorerURL
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: done.txId)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.up.right.square")
                        .font(.footnote)
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(sendKaspaGlass(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(explorerURL == nil)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Text("Tap the transaction to open it in the explorer.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.black)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(520), .large])
        .presentationDragIndicator(.visible)
        .task {
            // a transaction this sheet wasn't handed by `perform` (a profile save): follow it here
            if actions.txStages[done.txId] == nil, !done.accepted { actions.follow(txId: done.txId, plan: nil) }
        }
        .fullScreenCover(isPresented: Binding(
            get: { browserURL != nil },
            set: { if !$0 { browserURL = nil } }
        )) {
            if let browserURL {
                InAppBrowserScreen(url: browserURL) { self.browserURL = nil }
            }
        }
    }

    private var stageText: LocalizedStringKey {
        switch stage {
        case .sent, .inMempool: return "Waiting for the network to put it in a block. Usually a few seconds; longer when it's busy."
        case .accepted: return "It's in a block. Updating KaPay..."
        case .shown: return "Done. It shows in KaPay now."
        case .dropped: return "The network hasn't taken it. Nothing was spent if it never lands - try again with a faster fee."
        }
    }

}

/// A name transaction's progress, followed on a node: sent, in a block, showing in KaPay. In the
/// receipt half sheet and on the swipe-up screen after a purchase.
struct KachatTxStageSteps: View {
    let txId: String
    /// Already known to be in a block.
    var accepted = false
    @ObservedObject private var actions = KachatNamesActions.shared

    private var stage: KachatNamesActions.TxStage { actions.txStages[txId] ?? (accepted ? .shown : .sent) }
    private var inBlock: Bool { stage == .accepted || stage == .shown }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step("Sent to the network", done: true)
            step("In a block", done: inBlock, active: !inBlock && stage != .dropped)
            step("Updated in KaPay", done: stage == .shown, active: stage == .accepted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sendKaspaGlass(cornerRadius: 16))
    }

    private func step(_ title: LocalizedStringKey, done: Bool, active: Bool = false) -> some View {
        HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundColor(.secondary)
                }
            }
            .frame(width: 20)
            Text(title)
                .font(.subheadline)
                .foregroundColor(done || active ? .primary : .secondary)
        }
    }
}

// MARK: - Hub: registrations in flight

/// A registration's progress as a half sheet. Swiping it away leaves the claim running: the
/// .kachat screen's claims button (`KachatClaimsButton`) lists it. Claiming takes the app being
/// open (the commit has to age about a minute before the name registers).
struct KachatRegistrationProgressSheet: View {
    let registrationId: String
    let onClose: () -> Void
    @ObservedObject private var actions = KachatNamesActions.shared

    private var registration: KachatNames.PendingRegistration? { actions.pending.first { $0.id == registrationId } }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let registration {
                    Text(String(format: AppLocalization.string("Claiming %@"), "\(registration.name).kachat"))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.top, 22)
                    KachatRegistrationCard(registration: registration)
                    if registration.needsDriving {
                        Text("Keep KaPay open: the name is registered about a minute after the hidden commit confirms. If you leave, it picks up where it left off when you come back.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        // closes once the registration is dismissed (Done) or its commit was cancelled
        .onChange(of: registration?.isOpen != true) { over in if over { onClose() } }
    }
}

/// The app-level progress sheet: brings a claim still in progress back up once when the app
/// starts (a claim needs the app open to finish). Swiping it away leaves the claim running.
struct KachatRegistrationPresenter: ViewModifier {
    @ObservedObject private var actions = KachatNamesActions.shared

    private struct Route: Identifiable { let id: String }

    private var route: Binding<Route?> {
        Binding(
            get: {
                guard KachatNamesService.isLaunched, let id = actions.autoPresentedRegistration else { return nil }
                return Route(id: id)
            },
            set: { if $0 == nil { actions.autoPresentedRegistration = nil } }
        )
    }

    func body(content: Content) -> some View {
        content.sheet(item: route) { r in
            KachatRegistrationProgressSheet(registrationId: r.id) { actions.autoPresentedRegistration = nil }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// The .kachat screen's claims button, next to "How it works": the names being claimed right
/// now (and finished ones not yet dismissed), with a count. Hidden when there are none.
struct KachatClaimsButton: View {
    @ObservedObject private var actions = KachatNamesActions.shared
    @State private var showList = false

    var body: some View {
        let open = actions.openRegistrations
        if KachatNamesService.isLaunched, !open.isEmpty {
            Button {
                showList = true
            } label: {
                Image(systemName: "hourglass")
                    .overlay(alignment: .topTrailing) {
                        Text(verbatim: "\(open.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 9, y: -8)
                    }
            }
            .accessibilityLabel(Text("Names being claimed"))
            .sheet(isPresented: $showList) { KachatClaimsListSheet() }
        }
    }
}

/// Every open claim with its progress: the list behind `KachatClaimsButton`.
struct KachatClaimsListSheet: View {
    @ObservedObject private var actions = KachatNamesActions.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(actions.openRegistrations) { registration in
                        KachatRegistrationCard(registration: registration)
                    }
                    Text("Keep KaPay open: the name is registered about a minute after the hidden commit confirms. If you leave, it picks up where it left off when you come back.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Claiming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // the last one dismissed: nothing left to show
            .onChange(of: actions.openRegistrations.isEmpty) { empty in if empty { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct KachatRegistrationCard: View {
    let registration: KachatNames.PendingRegistration
    @ObservedObject private var actions = KachatNamesActions.shared
    @State private var confirmCancel = false
    @State private var working = false
    @State private var error: String?
    @State private var done: KachatTxDone?

    private var tCommit: UInt64 { KachatNamesService.shared.manifest?.params.tCommit ?? 600 }

    /// The finished registration (or cancelled commit) as the half sheet shows it.
    private var finished: KachatTxDone? {
        switch registration.stage {
        case .registered: return registration.registerTxId.map { KachatTxDone(txId: $0, title: "Name registered", accepted: true, note: KachatLive.lockedNote) }
        case .cancelled: return registration.cancelTxId.map { KachatTxDone(txId: $0, title: "Commit cancelled", accepted: true) }
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: "\(registration.name).kachat")
                    .font(.headline)
                Spacer()
                if registration.needsDriving {
                    ProgressView()
                } else if registration.stage == .registered {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                } else {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                }
            }
            stageText
                .font(.subheadline)
                .foregroundColor(.secondary)
            if registration.stage == .waiting, let daa = registration.commitDaa, let now = actions.virtualDaa {
                let target = Double(tCommit + 20)
                let done = Double(now > daa ? now - daa : 0)
                ProgressView(value: min(done, target), total: target)
                let left = max(0, Int((target - done) / Double(KachatLive.daaPerSecond)))
                Text("About \(left) s to go").font(.caption).foregroundColor(.secondary)
            }
            if let message = error ?? (registration.stage == .failed ? registration.lastError : nil) {
                Text(verbatim: message).font(.caption).foregroundColor(.red)
            } else if registration.needsDriving, let note = registration.lastError {
                // what the driver is doing or waiting on (a busy network, freeing an expired name)
                Text(verbatim: note).font(.caption).foregroundColor(.secondary)
            }
            buttons
        }
        .padding(14)
        .kachatGlass()
        .padding(.horizontal, 16)
        // Pops up the moment the registration lands (or the commit is cancelled).
        .onChange(of: registration.stage) { _ in if let finished { done = finished } }
        .sheet(item: $done) { KachatTxDoneSheet(done: $0) }
        .alert(Text("Cancel the commit?"), isPresented: $confirmCancel) {
            Button("Cancel Commit", role: .destructive) { authorizeCancel() }
            Button("Keep", role: .cancel) {}
        } message: {
            KaspaUnit.text("The registration stops and the commit's 0.2 KAS comes back to you, less the network fee.")
        }
    }

    @ViewBuilder
    private var stageText: some View {
        switch registration.stage {
        case .committing: Text("Sending the hidden commit...")
        case .waiting:
            if registration.commitDaa == nil {
                Text("Waiting for the commit to confirm...")
            } else {
                Text("The commit has to age for about a minute before the name can be registered. Keep KaPay open - it registers by itself, and picks up where it left off if you leave.")
            }
        case .registering: Text("Registering...")
        case .registered: Text("Registered. It's yours.")
        case .taken: KaspaUnit.text("Someone registered this name first. Cancel the commit to get its 0.2 KAS back.")
        case .failed: Text("The registration stopped.")
        case .cancelling: Text("Cancelling the commit...")
        case .cancelled: Text("Cancelled.")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch registration.stage {
        case .registered, .cancelled:
            HStack {
                if let finished {
                    Button("View Transaction") { done = finished }
                        .buttonStyle(.borderedProminent)
                }
                Button("Done") { actions.dismiss(registration) }
                    .buttonStyle(.bordered)
            }
        case .taken:
            Button("Cancel Commit", role: .destructive) { confirmCancel = true }
                .buttonStyle(.bordered)
                .disabled(working)
        case .failed:
            HStack {
                Button("Try Again") { actions.retry(registration) }
                    .buttonStyle(.borderedProminent)
                Button("Cancel Commit", role: .destructive) { confirmCancel = true }
                    .buttonStyle(.bordered)
                    .disabled(working)
            }
        default:
            EmptyView()
        }
    }

    private func authorizeCancel() {
        DeviceAuth.authenticate(reason: KachatLive.authReason) {
            working = true
            error = nil
            Task { @MainActor in
                do { try await actions.cancel(registration) } catch { self.error = error.localizedDescription }
                working = false
            }
        }
    }
}

// MARK: - Hub: pages

struct KachatLiveMarketPage: View {
    @ObservedObject var model: KachatHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            KachatLiveSectionHeader(title: "For sale", detail: nil)
            if model.listings.isEmpty {
                KachatLiveEmpty(text: model.loaded ? "No names are listed right now." : nil)
            } else {
                KachatNameGrid {
                    ForEach(model.listings) { n in
                        NavigationLink { KachatListingDetailView(info: n) } label: {
                            KachatNameTile(name: n.name) {
                                Text(verbatim: KaspaUnit.amount(n.price))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                // what a buyer gets: the paid time left, flagged when it's short
                                Text(String(format: AppLocalization.string("Expires %@"), KachatNamesActions.dayString(n.expiresAt)))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                if n.expiresAt - (KachatLive.params?.expiresSoonMs ?? 30 * 86_400_000) < KachatNames.nowMs() {
                                    Text("Expires soon")
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Names that expired and are still in their grace period: only their owner can renew them, and
/// each counts down to the moment it is released to Available - for anyone waiting to claim a
/// name they want.
struct KachatLiveExpiredPage: View {
    @ObservedObject var model: KachatHubModel
    @State private var openName: KachatNames.NameInfo?
    @State private var reloadedFor: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            KachatLiveSectionHeader(title: "Expired", detail: nil)
            if model.grace.isEmpty {
                KachatLiveEmpty(text: model.loaded ? "No names are in their grace period right now." : nil)
            } else {
                KachatNameGrid {
                    ForEach(model.grace) { n in
                        NavigationLink { KachatListingDetailView(info: n) } label: {
                            KachatNameTile(name: n.name) {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let releaseAt = n.expiresAt + (KachatLive.params?.graceMs ?? 0)
                                    let left = releaseAt - Int64(context.date.timeIntervalSince1970 * 1000)
                                    VStack(spacing: 2) {
                                        Text("Released in")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(verbatim: KachatLive.countdown(left))
                                            .font(.subheadline.weight(.bold).monospacedDigit())
                                            .foregroundColor(.orange)
                                    }
                                    .onChange(of: left <= 0) { released in
                                        // released: it moves to Available
                                        if released, !reloadedFor.contains(n.id) {
                                            reloadedFor.insert(n.id)
                                            Task { await model.reload() }
                                        }
                                    }
                                }
                                if let price = KachatLive.price(n.name) {
                                    Text(verbatim: KaspaUnit.amount(price))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Names that expired and stayed unrenewed through the grace period: back on the market at the
/// normal price. Claim frees the old record and registers it in one go (the progress half sheet).
struct KachatLiveAvailablePage: View {
    @ObservedObject var model: KachatHubModel
    @State private var claimTarget: KachatClaimTarget?
    /// The tile tapped (outside its Claim button): its detail opens.
    @State private var openName: KachatNames.NameInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            KachatLiveSectionHeader(title: "Available", detail: nil)
            if model.lapsed.isEmpty {
                KachatLiveEmpty(text: model.loaded ? "No expired names right now." : nil)
            } else {
                // a tap gesture, not a NavigationLink, so the Claim button inside keeps its tap
                KachatNameGrid {
                    ForEach(model.lapsed) { n in
                        KachatNameTile(name: n.name) {
                            // what claiming it costs: the price for its length
                            if let price = KachatLive.price(n.name) {
                                Text(verbatim: KaspaUnit.amount(price))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            Button("Claim") { claim(n) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        .onTapGesture { openName = n }
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
        .padding(.top, 4)
        .sheet(item: $claimTarget) { KachatClaimSheet(target: $0) }
        .navigationDestination(isPresented: Binding(get: { openName != nil }, set: { if !$0 { openName = nil } })) {
            if let openName { KachatListingDetailView(info: openName) }
        }
    }

    private func claim(_ n: KachatNames.NameInfo) {
        Task { @MainActor in
            guard let gap = try? await KachatNamesRegistry.shared.claimGap(for: n) else { return }
            claimTarget = KachatClaimTarget(name: n.name, gap: gap)
        }
    }
}

/// The offers this wallet made, with Withdraw (and Refund once expired). Shown in Profile >
/// Your Domains > .kachat, under your names.
struct KachatMyOffersSection: View {
    let offers: [KachatNames.OfferInfo]
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @State private var openOffer: KachatNames.OfferInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KachatLiveSectionHeader(title: "My Offers", detail: "Offers you made. Withdraw one any time; once it expires it comes back to you on its own.")
            KachatNameGrid {
                ForEach(offers) { o in
                    KachatOfferTile(state: KachatOfferState(offer: o, isBuyer: true, isOwner: false), showsName: true) {
                        openOffer = o
                    }
                }
            }
        }
        .sheet(item: $openOffer) { o in
            KachatOfferDetailSheet(state: KachatOfferState(offer: o, isBuyer: true, isOwner: false))
        }
    }
}

struct KachatLiveActivityPage: View {
    @ObservedObject var model: KachatHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KachatLiveSectionHeader(title: "Recent activity", detail: "Every claim, renewal, listing, sale, offer, transfer and reclaim across the registry.")
            if model.activity.isEmpty {
                KachatLiveEmpty(text: model.loaded ? "Nothing yet." : nil)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.activity.prefix(100).enumerated()), id: \.element.id) { index, e in
                        KachatEventRow(event: e, showName: true)
                        if index < min(model.activity.count, 100) - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .kachatGlass()
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 4)
    }
}

struct KachatLiveSectionHeader: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }
}

struct KachatLiveEmpty: View {
    /// nil while loading
    let text: LocalizedStringKey?

    var body: some View {
        Group {
            if let text {
                Text(text).font(.subheadline).foregroundColor(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .kachatGlass()
        .padding(.horizontal, 16)
    }
}

struct KachatEventRow: View {
    let event: KachatNames.Event
    var showName = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: KachatLive.eventIcon(event.op))
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(KachatLive.eventTitle(event.op))
                    if showName, let name = event.name {
                        Text(verbatim: "\(name).kachat")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                HStack(spacing: 4) {
                    if let to = KachatLive.party(event.to), event.op != "offer" {
                        Text(verbatim: "→ \(to)")
                    }
                    if let at = event.at {
                        Text(KachatLive.date(at), format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let price = event.price {
                Text(verbatim: KaspaUnit.amount(price)).font(.subheadline)
            } else if let years = event.years {
                Text(verbatim: "+\(years)").font(.subheadline).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Offers

/// What the person wants to do with an offer.
struct KachatOfferAction: Identifiable {
    enum Kind { case withdraw, refund, accept, decline }
    let kind: Kind
    let offer: KachatNames.OfferInfo
    var name: KachatNames.NameInfo?

    var id: String { "\(kind)-\(offer.id)" }

    /// The action as its own sheet.
    @ViewBuilder @MainActor
    var sheet: some View {
        form(embedded: false, onDone: { _ in })
    }

    /// The action's transaction screen; `embedded` pushes it inside the offer's half sheet
    /// (`KachatOfferDetailSheet`), with Back instead of Cancel.
    @ViewBuilder @MainActor
    func form(embedded: Bool, onDone: @escaping (String) -> Void) -> some View {
        switch kind {
        case .withdraw:
            KachatTxSheet(
                title: "Withdraw Offer", confirmTitle: "Withdraw",
                authReason: KachatLive.authReason, doneTitle: "Offer withdrawn",
                rows: [.init(title: "Offer", value: KaspaUnit.amount(offer.amount))],
                operation: .withdraw(offer), operationKey: offer.id, onDone: onDone, embedded: embedded
            )
        case .refund:
            KachatTxSheet(
                title: "Refund Offer", confirmTitle: "Refund",
                authReason: KachatLive.authReason, doneTitle: "Offer refunded",
                rows: [.init(title: "Offer", value: KaspaUnit.amount(offer.amount))],
                operation: .refund(offer), operationKey: offer.id, onDone: onDone, embedded: embedded
            )
        case .accept:
            if let n = name {
                KachatTxSheet(
                    title: "Accept Offer", confirmTitle: "Accept and Transfer",
                    authReason: KachatLive.authReason, doneTitle: "Offer accepted",
                    warning: "The name goes to the buyer and the offer's amount comes to you, in one transaction. This can't be undone.",
                    rows: [.init(title: "Name", value: n.display), .init(title: "Offer", value: KaspaUnit.amount(offer.amount)),
                           .init(title: "Buyer", value: KachatNamesRegistry.address(of: offer.buyer).map(KachatNamesRegistry.shortAddress) ?? "")],
                    operation: .accept(offer, name: n), operationKey: offer.id, onDone: onDone, embedded: embedded
                )
            }
        case .decline:
            KachatTxSheet(
                title: "Decline Offer", confirmTitle: "Decline",
                authReason: KachatLive.authReason, doneTitle: "Offer declined",
                footer: "The offer goes back to the buyer. Its network fee comes out of the offer, so declining costs you nothing.",
                rows: [.init(title: "Offer", value: KaspaUnit.amount(offer.amount)),
                       .init(title: "Buyer", value: KachatNamesRegistry.address(of: offer.buyer).map(KachatNamesRegistry.shortAddress) ?? "")],
                operation: .decline(offer), operationKey: "decline-\(offer.id)", onDone: onDone, embedded: embedded
            )
        }
    }
}

/// What an offer is and what this wallet can do with it - shared by its tile and its half sheet.
struct KachatOfferState {
    let offer: KachatNames.OfferInfo
    let isBuyer: Bool
    let isOwner: Bool
    var name: KachatNames.NameInfo?
    /// Made before the name changed hands: never acceptable, and on its way back to the buyer.
    var declined = false

    @MainActor private var actions: KachatNamesActions { KachatNamesActions.shared }
    @MainActor var refundable: Bool { actions.virtualDaa.map { offer.refundable(atDaa: $0) } ?? false }
    @MainActor var returning: Bool { actions.returningOffers.contains(offer.id) }
    /// Declined and being pulled back by this app (the buyer's).
    @MainActor var withdrawing: Bool { actions.withdrawingOffers.contains(offer.id) }
    /// The owner can take it: still inside its time (an expired one is on its way back), and the
    /// name itself still active - an expired name would reach the buyer only to be reclaimed.
    @MainActor var acceptable: Bool { isOwner && !refundable && !declined && nameActive }
    @MainActor var nameActive: Bool {
        guard let name else { return false }
        return name.status(graceMs: KachatNamesRegistry.shared.graceMs) == .active
    }
    @MainActor var dimmed: Bool { refundable || declined || withdrawing }
    /// Anyone may send an expired offer back; this app does it on its own for its own offers.
    @MainActor var canRefund: Bool { refundable && !returning }

    var buyerAddress: String? { KachatNamesRegistry.address(of: offer.buyer) }

    /// "2d 21h": how long until it can be refunded (10 DAA per second), nil once it can.
    @MainActor var timeLeft: String? {
        guard let daa = actions.virtualDaa, !refundable else { return nil }
        let seconds = Double(UInt64(max(offer.refundAfter, 0)) - daa) / Double(KachatLive.daaPerSecond)
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : (seconds >= 3600 ? [.hour, .minute] : [.minute])
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.calendar?.locale = AppLocalization.locale
        return f.string(from: max(60, seconds))
    }

    /// An expired or declined offer's state, in orange; nil for an open one.
    @MainActor var statusText: LocalizedStringKey? {
        if declined || withdrawing {
            return isBuyer ? "Declined - the name changed hands, returning to you" : "Declined - made to an earlier owner"
        }
        if refundable {
            return returning || isOwner
                ? (isBuyer ? "Expired - returning to you" : "Expired - returning to the buyer")
                : "Expired - refundable now"
        }
        return nil
    }
}

/// One offer as a square tile: the amount, who made it, and when it expires. Tapping it opens
/// its half sheet (`KachatOfferDetailSheet`) to accept, decline, withdraw or refund it.
struct KachatOfferTile: View {
    let state: KachatOfferState
    /// The name it is for, on tiles shown away from that name's page (My Offers).
    var showsName = false
    let onTap: () -> Void
    @ObservedObject private var actions = KachatNamesActions.shared

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(.accentColor)
                Text(verbatim: KaspaUnit.amount(state.offer.amount))
                    .font(.headline.weight(.bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if showsName, let n = state.offer.name {
                    Text(verbatim: "\(n).kachat")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                }
                Group {
                    if state.isBuyer {
                        Text("Your offer")
                    } else if let a = state.buyerAddress {
                        Text(verbatim: KachatNamesRegistry.shortAddress(a))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                if let status = state.statusText {
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                } else if let left = state.timeLeft {
                    Text(String(format: AppLocalization.string("Expires in %@"), left))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 140)
            .kachatGlass()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(state.dimmed ? 0.6 : 1)
    }
}

/// An offer's half sheet: the amount, who made it and when it expires, and what this wallet can
/// do - Accept or Decline (the name's owner), Withdraw or Refund (the buyer), Refund (anyone,
/// once expired). Each opens its transaction inside this sheet; when it's sent the sheet closes.
struct KachatOfferDetailSheet: View {
    let state: KachatOfferState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var actions = KachatNamesActions.shared
    @State private var finished = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Image(systemName: "hand.raised.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text(verbatim: KaspaUnit.amount(state.offer.amount))
                            .font(.largeTitle.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if let n = state.offer.name ?? state.name?.name {
                            Text(verbatim: "\(n).kachat")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.top, 4)

                    KachatCard {
                        HStack {
                            Text("From")
                            Spacer()
                            if state.isBuyer {
                                Text("You").fontWeight(.semibold)
                            } else if let a = state.buyerAddress {
                                Button {
                                    UIPasteboard.general.string = a
                                    copied = true
                                    Haptics.success()
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(verbatim: KachatNamesRegistry.shortAddress(a))
                                            .font(.subheadline.monospaced())
                                            .lineLimit(1)
                                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption)
                                    }
                                    .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if let left = state.timeLeft {
                            HStack {
                                Text("Expires in")
                                Spacer()
                                Text(verbatim: left).foregroundColor(.secondary)
                            }
                        }
                        if let status = state.statusText {
                            Text(status)
                                .font(.footnote)
                                .foregroundColor(.orange)
                        }
                    }

                    actionButtons
                }
                .padding(16)
            }
            .navigationTitle("Offer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            // back from a sent action: the offer is settled, so the sheet closes
            .onAppear { if finished { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            if state.acceptable {
                actionLink("Accept", systemImage: "checkmark.circle", prominent: true, kind: .accept)
                actionLink("Decline", systemImage: "xmark.circle", prominent: false, kind: .decline)
            } else if state.isBuyer {
                actionLink("Withdraw", systemImage: "arrow.uturn.backward.circle", prominent: !state.canRefund, kind: .withdraw)
                if state.canRefund {
                    actionLink("Refund", systemImage: "arrow.counterclockwise.circle", prominent: true, kind: .refund)
                }
            } else if state.canRefund {
                actionLink("Refund", systemImage: "arrow.counterclockwise.circle", prominent: true, kind: .refund)
            } else if state.isOwner {
                Text("This offer can't be accepted any more.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                Text("Only the name's owner can accept or decline this offer.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func actionLink(_ title: LocalizedStringKey, systemImage: String, prominent: Bool, kind: KachatOfferAction.Kind) -> some View {
        NavigationLink {
            KachatOfferAction(kind: kind, offer: state.offer, name: state.name)
                .form(embedded: true) { _ in finished = true }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(prominent ? Color.accentColor : Color.accentColor.opacity(0.15))
                )
                .foregroundColor(prominent ? .black : (kind == .decline ? .red : .accentColor))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The transaction sheet

struct KachatTxRow: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let value: String
}

/// A glass card in the Send screens' style, for one group of a name transaction's details.
struct KachatCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sendKaspaGlass(cornerRadius: 20))
    }
}

/// An input in a name transaction's sheet (price, offer, new owner...): a small caption title,
/// the field, and an optional note under it - in a Send-style card.
struct KachatInputCard<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var footer: Text? = nil
    @ViewBuilder var content: Content

    var body: some View {
        KachatCard {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            content
            if let footer {
                footer
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shown when the network is busy: Normal may wait, a faster fee gets in sooner.
struct KachatBusyNetworkNotice: View {
    let estimate: KachatNamesActions.FeeEstimate

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("The network is busy")
                    .font(.subheadline.weight(.semibold))
                Text("At Normal this may wait a while. Fast or Priority pays a little more to get into a block sooner.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

/// Every action's sheet, in the Send Kaspa flow's steps: an entry step when the action takes
/// one (`entryQuestion`: an offer's amount, a price, a new owner - typed on the keypad or the
/// recipient card), then the review - what it does (a card), the network fee with Normal / Fast /
/// Priority or Edit for a fee of your own (`SendFeeEditorScreen`), the cost, the destructive ones'
/// warning in red - and swipe up to confirm, then the device lock, then the transaction, followed
/// into a block on the swipe-up's own screen (or Failed with Try Again).
/// The address paying a name transaction and its key (`KachatTxSheet`).
struct KachatPayerInfo: Equatable {
    let address: String
    let key: Data
}

struct KachatTxSheet<Inputs: View>: View {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    let authReason: String
    /// The headline of the finished screen (a localization key).
    var doneTitle: String = "Transaction sent"
    var warning: LocalizedStringKey? = nil
    var footer: LocalizedStringKey? = nil
    var rows: [KachatTxRow] = []
    let operation: KachatNamesActions.Operation?
    let operationKey: String
    var onDone: (String) -> Void = { _ in }
    /// Shown inside a flow that already has its NavigationStack (an offer's half sheet, Renew's
    /// "How long?" first): no stack of its own.
    var embedded = false
    /// Where the review's Back goes when it has no entry step (Renew: back to "How long?"). An
    /// embedded sheet without one goes back with `dismiss`.
    var onBack: (() -> Void)? = nil
    /// The swipe-up's words and what it is for; nil: "Swipe up to Confirm".
    var swipeUp: KachatSwipeUp? = nil
    /// Set: `inputs` are a step of their own before the review, asking this.
    var entryQuestion: LocalizedStringKey? = nil
    /// The entry step's Continue.
    var canContinue = true
    @ViewBuilder var inputs: () -> Inputs

    private enum Screen: Int { case entry, review, fee }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var actions = KachatNamesActions.shared
    @State private var plan: KachatNames.Plan?
    /// The fee rate `plan` was built at: the send uses exactly this (IOS-061).
    @State private var planFeerate: Double?
    /// The plan assumes the small coins combined first (`planWithRate`); the combine is sent only
    /// after the swipe and Face ID.
    @State private var combinesCoins = false
    @State private var planError: String?
    @State private var building = false
    @State private var sending = false
    @State private var txId: String?
    @State private var sendError: String?
    /// The paying address's balance when it isn't the chatting address (`payer`).
    @State private var payerBalance: UInt64?
    /// Who pays this transaction (`KachatNamesActions.payer(for:)`), worked out once per operation.
    @State private var payerInfo: KachatPayerInfo?
    /// The step on screen; nil until the first move.
    @State private var screen: Screen?
    @State private var screenForward = true
    /// The fee being typed on the fee screen, and the fee it opened with (for its warning).
    @State private var feeDraft = ""
    @State private var feeAtEdit: UInt64?

    private var payer: (address: String, key: Data)? {
        if let payerInfo { return (payerInfo.address, payerInfo.key) }
        guard let me = actions.myKey, let address = actions.myAddress else { return nil }
        return (address, me)
    }

    /// "Address #3" (or its name) for one of your addresses, else the short address.
    private func payerLabel(_ address: String) -> String {
        WalletManager.shared.ownAddressLabel(for: address) ?? KachatNamesRegistry.compactAddress(address)
    }
    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var customFee: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""
    /// The person picked a speed: a busy network no longer moves it for them.
    @State private var feeTouched = false

    private var feeChoice: KachatNamesActions.FeeChoice {
        customFee.map { .customTotal($0) } ?? .tier(feeTier)
    }

    private var currentScreen: Screen { screen ?? (entryQuestion != nil ? .entry : .review) }

    private var swipe: KachatSwipeUp {
        swipeUp ?? KachatSwipeUp(bar: "Swipe up to Confirm", labels: .transaction(done: LocalizedStringKey(doneTitle)),
                                 showsAmount: false)
    }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        ZStack {
            switch currentScreen {
            case .entry: entryScreen.transition(screenTransition)
            case .review: reviewScreen.transition(screenTransition)
            case .fee: feeScreen.transition(screenTransition)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .modifier(planTasks)
    }

    private var screenTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: screenForward ? .trailing : .leading),
                    removal: .move(edge: screenForward ? .leading : .trailing))
    }

    private func go(to next: Screen) {
        dismissSystemKeyboard()
        screenForward = next.rawValue > currentScreen.rawValue
        // The leaving screen re-renders with the new direction before it animates out.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { screen = next }
        }
    }

    /// The review's Back: to the entry step, else the flow's own Back, else out of an embedded one.
    private var reviewBack: (() -> Void)? {
        if entryQuestion != nil { return { go(to: .entry) } }
        if let onBack { return onBack }
        return embedded ? { dismiss() } : nil
    }

    // MARK: Screens

    private var entryScreen: some View {
        SendStepScreen(title: Text(title), onBack: onBack ?? (embedded ? { dismiss() } : nil),
                       onCancel: { dismiss() }, continueTitle: "Review", canContinue: canContinue) {
            go(to: .review)
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if let entryQuestion {
                    SendStepQuestion(text: entryQuestion)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                inputs()
            }
        }
    }

    private var reviewScreen: some View {
        SwipeUpToSendScrollView(
            screenTitle: "",
            onCancel: { dismiss() },
            onBack: reviewBack,
            titleText: Text(title),
            // pushed inside another sheet: Back is the way out
            showsCancel: !(embedded && onBack == nil && entryQuestion == nil),
            title: swipe.bar,
            isBusy: sending,
            isEnabled: plan != nil && !building && txId == nil,
            amountSompi: swipe.showsAmount ? spentSompi : nil,
            recipient: swipe.recipient,
            sent: txId.map { SentTransaction(txId: $0, amountSompi: spentSompi, recipient: swipe.recipient) },
            failureMessage: sendError,
            labels: swipe.labels,
            authReason: authReason,
            outcome: txId.map { AnyView(KachatTxStageSteps(txId: $0)) },
            onDone: { dismiss() },
            action: { startSend() }
        ) {
            form
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var feeScreen: some View {
        SendFeeEditorScreen(draft: $feeDraft, referenceSompi: feeAtEdit,
                            onCancel: { go(to: .review) }) { typed in
            feeTouched = true
            customFee = typed
            go(to: .review)
        }
    }

    private func openFeeEditor() {
        guard let plan else { return }
        feeAtEdit = plan.networkFee
        feeDraft = KaspaUnit.plain(plan.networkFee)
        go(to: .fee)
    }

    /// What leaves the wallet: everything the transaction spends from it less what comes back.
    private var spentSompi: UInt64? {
        guard let plan, let payer else { return nil }
        return UInt64(max(0, -Self.balanceChange(plan, me: payer.key)))
    }

    private var planTasks: KachatTxPlanTasks {
        KachatTxPlanTasks(
            operationKey: operationKey, feeKey: "\(feeTier.rawValue)|\(customFee ?? 0)",
            rebuild: { await rebuild() },
            loadPayer: {
                payerInfo = operation.flatMap { actions.payer(for: $0) }.map { KachatPayerInfo(address: $0.address, key: $0.key) }
                guard let address = payerInfo?.address, address != actions.myAddress else { return }
                let utxos = (try? await NodePoolService.shared.getUtxosByAddresses([address])) ?? []
                payerBalance = utxos.reduce(UInt64(0)) { $0 + $1.amount }
            },
            startOnBusyNetwork: {
                // A busy network starts on Fast unless the person already chose.
                if let estimate = await actions.refreshFeeEstimate(), estimate.isBusy, !feeTouched, customFee == nil {
                    feeTier = .fast
                }
            },
            feeTier: feeTier,
            onFeeTierChange: {
                // a speed replaces a typed fee
                feeTouched = true
                customFee = nil
            }
        )
    }

    private var form: some View {
            VStack(spacing: 16) {
                if !rows.isEmpty || (plan?.priceFee ?? 0) > 0 {
                    KachatCard {
                        ForEach(rows) { row in
                            LabeledRow(title: row.title, value: row.value)
                        }
                        if let plan, plan.priceFee > 0 {
                            if !rows.isEmpty { Divider() }
                            LabeledRow(title: "Price (to miners)", value: KaspaUnit.amount(plan.priceFee))
                        }
                    }
                }

                // inputs with a step of their own were filled in there
                if entryQuestion == nil {
                    inputs()
                }

                if let estimate = actions.feeEstimate, estimate.isBusy, txId == nil {
                    KachatBusyNetworkNotice(estimate: estimate)
                }

                SendFeeControls(
                    feeTier: $feeTier,
                    isEditingFee: $isEditingFee,
                    customFeeText: $customFeeText,
                    isEstimatingFee: building,
                    feeText: plan.map { KaspaUnit.amount($0.networkFee) },
                    onStartEditing: {},
                    onCommit: {},
                    showsCoinControl: false,
                    onEditFee: openFeeEditor
                )

                if let plan, let payer {
                    // Spends from, and pays back to, the address that pays: the chatting address,
                    // the marketplace's chosen one, or the spending address holding the name.
                    let change = Self.balanceChange(plan, me: payer.key)
                    let fromChatting = payer.address == actions.myAddress
                    HStack(spacing: 8) {
                        if !fromChatting {
                            SendInfoPill {
                                Text("From: \(payerLabel(payer.address))")
                            }
                        }
                        if let balance = fromChatting ? WalletManager.shared.currentWallet?.balanceSompi : payerBalance {
                            SendInfoPill {
                                Text("Balance after: \(KaspaUnit.amount(UInt64(max(0, Int64(balance) + change))))")
                            }
                        } else {
                            SendInfoPill {
                                Text("Balance change: \(KaspaUnit.signed(change))")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let warning {
                    Label { Text(warning) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.red.opacity(0.1)))
                }

                if let planError {
                    Text(verbatim: planError)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let footer {
                    Text(footer)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if combinesCoins, plan != nil, txId == nil {
                    Label {
                        Text("Your KAS is in many small coins. When you swipe, KaPay first combines them into one (a separate transaction with its own small fee), then sends this.")
                    } icon: { Image(systemName: "square.stack.3d.up") }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let sendError {
                    Text(verbatim: sendError)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
    }

    private func rebuild() async {
        plan = nil
        planError = nil
        combinesCoins = false
        guard let operation else { return }
        building = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        do {
            let built = try await KachatNamesActions.shared.planWithRate(operation, fee: feeChoice)
            // A newer choice replaced this build while it ran: its plan is for the old choice,
            // and the new build owns the sheet now.
            guard !Task.isCancelled else { return }
            plan = built.plan
            planFeerate = built.feerate
            combinesCoins = built.combinesCoins
        } catch {
            // Cancelled (the choice changed): not an error to show, and the new build owns the
            // sheet. Showing it left "Swift.CancellationError" and a disabled button.
            guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            planError = error.localizedDescription
        }
        building = false
    }

    /// The swipe-up has already asked for Face ID.
    private func startSend() {
        // busy at once: the swipe-up's screen is already sending
        sending = true
        sendError = nil
        Task { @MainActor in await send() }
    }

    private func send() async {
        guard let operation else { return }
        sending = true
        sendError = nil
        do {
            // never pays more than the price shown, and sends at the fee rate shown (refused if the
            // rebuilt fee is higher)
            let id = try await KachatNamesActions.shared.perform(
                operation, maxPrice: plan?.priceFee, fee: feeChoice,
                exactFeerate: planFeerate, maxNetworkFee: plan?.networkFee
            )
            txId = id
            onDone(id)
        } catch {
            sendError = error.localizedDescription
            // the price or the fee moved: show the new plan so the person can confirm it
            switch error as? KachatNamesActions.ActionError {
            case .priceChanged?, .feeChanged?:
                sending = false
                await rebuild()
                return
            default:
                break
            }
        }
        sending = false
    }

    /// What the transaction does to the wallet: its outputs to the wallet minus its inputs from it.
    static func balanceChange(_ plan: KachatNames.Plan, me: Data) -> Int64 {
        let mine = KachatNames.Codec.p2pkScript(me)
        let received = plan.unsignedTx.outputs.filter { $0.script == mine }.reduce(UInt64(0)) { $0 + $1.value }
        let spent = plan.entries.filter { $0.script == mine }.reduce(UInt64(0)) { $0 + $1.amount }
        return Int64(bitPattern: received &- spent)
    }
}

/// How a `KachatTxSheet` confirms with a swipe up: the bar's words, what the sending screen says,
/// what it is for ("name.kachat"), and whether it shows what leaves the wallet (a purchase, an
/// offer) or not (a listing, a transfer: only a fee).
struct KachatSwipeUp {
    let bar: LocalizedStringKey
    let labels: SwipeUpLabels
    var recipient: String? = nil
    var showsAmount = true
}

/// `KachatTxSheet`'s loading work: the plan for the chosen fee, who pays, and a busy network
/// starting on Fast.
private struct KachatTxPlanTasks: ViewModifier {
    let operationKey: String
    let feeKey: String
    let rebuild: () async -> Void
    let loadPayer: () async -> Void
    let startOnBusyNetwork: () async -> Void
    let feeTier: WithdrawFeeTier
    let onFeeTierChange: () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: "\(operationKey)|\(feeKey)") { await rebuild() }
            .task(id: operationKey) { await loadPayer() }
            .task { await startOnBusyNetwork() }
            .onChange(of: feeTier) { _ in onFeeTierChange() }
    }
}

extension KachatTxSheet where Inputs == EmptyView {
    init(title: LocalizedStringKey, confirmTitle: LocalizedStringKey, authReason: String, doneTitle: String = "Transaction sent",
         warning: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil, rows: [KachatTxRow] = [],
         operation: KachatNamesActions.Operation?, operationKey: String, onDone: @escaping (String) -> Void = { _ in },
         embedded: Bool = false, onBack: (() -> Void)? = nil, swipeUp: KachatSwipeUp? = nil) {
        self.init(title: title, confirmTitle: confirmTitle, authReason: authReason, doneTitle: doneTitle, warning: warning, footer: footer,
                  rows: rows, operation: operation, operationKey: operationKey, onDone: onDone, embedded: embedded,
                  onBack: onBack, swipeUp: swipeUp, inputs: { EmptyView() })
    }
}

private struct LabeledRow: View {
    let title: LocalizedStringKey
    let value: String
    var bold = false

    var body: some View {
        HStack {
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(verbatim: value)
                .fontWeight(bold ? .semibold : .regular)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Claim

struct KachatClaimSheet: View {
    let target: KachatClaimTarget
    var onStarted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var actions = KachatNamesActions.shared
    /// Once the registration started, the swipe-up screen shows its progress - from the
    /// marketplace and from Your Domains alike. Closing it leaves the claim running.
    @State private var progressId: String?
    @State private var detent: PresentationDetent = .large
    @State private var years: Int64 = 1
    @State private var quote: KachatNamesActions.Quote?
    @State private var quoteError: String?
    /// Registry v5 before its migration deadline, or mainnet before its public opening: why
    /// claiming waits, and until when.
    @State private var notOpen: String?
    @State private var notOpenIsMigration = false
    @State private var starting = false
    @State private var startError: String?
    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var feeTouched = false
    /// A fee of the person's own (the review's Edit), as a rate; a speed replaces it.
    @State private var customFeerate: Double?
    @State private var feeDraft = ""
    /// `SendFeeControls`' inline editing, unused here (its Edit opens the fee screen).
    @State private var isEditingFee = false
    @State private var customFeeText = ""

    /// Like a send: how long first, then the review (costs, the fee) and swipe up to claim.
    private enum Step: Int { case years, review, fee }
    @State private var step: Step = .years
    @State private var stepForward = true

    private var maxYears: Int64 { KachatNamesService.shared.manifest?.params.maxYears ?? 2 }

    var body: some View {
        NavigationStack {
            ZStack {
                switch step {
                case .years: yearsStep.transition(stepTransition)
                case .review: reviewStep.transition(stepTransition)
                case .fee: feeStep.transition(stepTransition)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: "\(years)|\(feeTier.rawValue)|\(customFeerate ?? 0)") {
                quote = nil
                quoteError = nil
                notOpen = nil
                do {
                    quote = try await KachatNamesActions.shared.quote(name: target.name, years: years, gap: target.gap,
                                                                      feeTier: feeTier, customFeerate: customFeerate)
                } catch let error as KachatNamesActions.ActionError {
                    if error.isNotOpenYet {
                        notOpen = error.localizedDescription
                        if case .registrationNotOpen = error { notOpenIsMigration = true } else { notOpenIsMigration = false }
                    } else {
                        quoteError = error.localizedDescription
                    }
                } catch {
                    quoteError = error.localizedDescription
                }
            }
            .task {
                // A busy network starts on Fast unless the person already chose.
                if let estimate = await actions.refreshFeeEstimate(), estimate.isBusy, !feeTouched { feeTier = .fast }
            }
            .onChange(of: feeTier) { _ in
                feeTouched = true
                // a speed replaces a typed fee
                customFeerate = nil
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: stepForward ? .trailing : .leading),
                    removal: .move(edge: stepForward ? .leading : .trailing))
    }

    private func go(to next: Step) {
        stepForward = next.rawValue > step.rawValue
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { step = next }
        }
    }

    // MARK: How long

    /// "For how long?": one button per length, each with its price; a tap goes to the review.
    private var yearsStep: some View {
        VStack(spacing: 0) {
            SendStepHeader(title: AppLocalization.string("Claim Name"))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "For how long?")
                    Text(verbatim: "\(target.name).kachat")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                    ForEach(1...max(1, Int(maxYears)), id: \.self) { y in
                        Button {
                            Haptics.impact(.light)
                            years = Int64(y)
                            go(to: .review)
                        } label: {
                            HStack {
                                KachatYearsText(years: y)
                                Spacer()
                                if let price = price(years: Int64(y)) {
                                    Text(verbatim: KaspaUnit.amount(price))
                                        .foregroundColor(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.accentColor)
                            }
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity)
                            .frame(height: 68)
                            .background(sendKaspaGlass(cornerRadius: 20))
                            .contentShape(RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("The price goes to the miners - KaChat takes nothing.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            Button { dismiss() } label: {
                Text("Cancel")
                    .font(.headline)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// The registration price for `years` from the manifest (the first period at the register
    /// price, any further one at the renewal price).
    private func price(years: Int64) -> UInt64? {
        KachatNamesService.shared.manifest?.params.registerCost(forLength: target.name.utf8.count, years: years)
    }

    // MARK: Review

    /// Swipe up to claim, like Send Kaspa: the screen goes up into the BlockDAG while the commit
    /// goes out, then shows the claim's progress (`KachatRegistrationCard`).
    private var reviewStep: some View {
        SwipeUpToSendScrollView(
            screenTitle: AppLocalization.string("Claim Name"),
            onCancel: { dismiss() },
            onBack: { go(to: .years) },
            title: "Swipe up to Claim",
            isBusy: starting,
            isEnabled: quote?.affordable == true,
            amountSompi: quote?.total,
            recipient: "\(target.name).kachat",
            sent: nil,
            failureMessage: startError,
            labels: .claim,
            authReason: KachatLive.authReason,
            succeeded: progressId != nil,
            outcome: progressId.map { AnyView(KachatClaimOutcome(registrationId: $0)) },
            onDone: { dismiss() },
            action: startClaim
        ) {
            VStack(spacing: 16) {
                if let notOpen {
                    KachatCard {
                        Label {
                            Text(verbatim: notOpen)
                        } icon: {
                            Image(systemName: "clock").foregroundColor(.orange)
                        }
                        .font(.subheadline)
                        if notOpenIsMigration {
                            Text("Every name from the old registry comes over with the same owner and expiry first.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                KachatCard {
                    LabeledRow(title: "Name", value: "\(target.name).kachat")
                    HStack {
                        Text("Length")
                        Spacer()
                        KachatYearsText(years: Int(years))
                    }
                    Divider()
                    if let q = quote {
                        // the first period at the registration price, any further one at the renewal price
                        LabeledRow(title: "Price (to miners)", value: KaspaUnit.amount(q.price))
                        LabeledRow(title: "Bond (returned on release)", value: KaspaUnit.amount(q.bond))
                        LabeledRow(title: "Registry deposit (returned on release)", value: KaspaUnit.amount(q.gapDeposit))
                        LabeledRow(title: "Commit (returned at registration)", value: KaspaUnit.amount(q.commit))
                        LabeledRow(title: "Network fees", value: KaspaUnit.amount(q.networkFee))
                        Divider()
                        LabeledRow(title: "Total", value: KaspaUnit.amount(q.total), bold: true)
                        // the bond and the deposit stay with the name: said once, as one amount
                        Label {
                            Text(verbatim: String(format: AppLocalization.string("%@ stays locked with your name while you hold it (bond + registry deposit). You get it back when you release the name."), KaspaUnit.amount(q.bond + q.gapDeposit)))
                        } icon: { Image(systemName: "lock.fill") }
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    } else if let quoteError {
                        Text(verbatim: quoteError).foregroundColor(.red)
                    } else if notOpen != nil {
                        HStack { Text("Total"); Spacer(); Text(verbatim: "-").foregroundColor(.secondary) }
                    } else {
                        HStack { Text("Total"); Spacer(); ProgressView() }
                    }
                }

                if let estimate = actions.feeEstimate, estimate.isBusy {
                    KachatBusyNetworkNotice(estimate: estimate)
                }

                // The only thing that can still change: the fee (a speed, or Edit for your own).
                SendFeeControls(
                    feeTier: $feeTier,
                    isEditingFee: $isEditingFee,
                    customFeeText: $customFeeText,
                    isEstimatingFee: quote == nil && quoteError == nil && notOpen == nil,
                    feeText: quote.map { KaspaUnit.amount($0.networkFee) },
                    onStartEditing: {},
                    onCommit: {},
                    showsCoinControl: false,
                    onEditFee: openFeeEditor
                )

                Text("Claiming sends two transactions: the commit now, the registration about a minute later. Both pay this fee rate.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let q = quote {
                    HStack(spacing: 8) {
                        SendInfoPill { Text("Available: \(KaspaUnit.amount(q.spendable))") }
                        Spacer(minLength: 0)
                    }
                    if q.combinesCoins, q.affordable {
                        Label("Your KAS is in many small coins. KaPay combines them into one before registering, for a tiny extra network fee.", systemImage: "arrow.triangle.merge")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !q.affordable {
                        KaspaUnit.text("Not enough KAS on your chatting address for this name.")
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let startError {
                    Text(verbatim: startError)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    // MARK: Fee

    /// The fee screen: both transactions' fees together, typed on the keypad. Becomes a rate in
    /// proportion to the quote's, never under the relay floor.
    private var feeStep: some View {
        SendFeeEditorScreen(draft: $feeDraft, minimumSompi: minimumFee,
                            referenceSompi: quote?.networkFee,
                            onCancel: { go(to: .review) }) { typed in
            if let q = quote, q.networkFee > 0, q.feerate > 0 {
                customFeerate = max(KachatNames.minFeerate, q.feerate * Double(typed) / Double(q.networkFee))
                feeTouched = true
            }
            go(to: .review)
        }
    }

    /// Both fees at the network's floor rate.
    private var minimumFee: UInt64? {
        guard let q = quote, q.feerate > 0 else { return nil }
        return UInt64((Double(q.networkFee) * KachatNames.minFeerate / q.feerate).rounded(.up))
    }

    private func openFeeEditor() {
        guard let q = quote else { return }
        feeDraft = KaspaUnit.plain(q.networkFee)
        go(to: .fee)
    }

    private func stepRow(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(n)")
                .font(.caption.weight(.bold))
                .foregroundColor(.accentColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text).font(.subheadline)
        }
    }

    /// The swipe let go: busy at once (the swipe screen is already sending), then the device
    /// check, then the commit.
    /// The swipe-up has already asked for Face ID.
    private func startClaim() {
        starting = true
        startError = nil
        Task { @MainActor in await start() }
    }

    private func start() async {
        // the price shown is the most the registration will ever pay
        guard let q = quote, q.years == years else {
            startError = AppLocalization.string("The price changed. Check it and swipe again.")
            starting = false
            return
        }
        starting = true
        startError = nil
        do {
            try await KachatNamesActions.shared.startRegistration(name: target.name, years: years, maxPrice: q.price, feeTier: feeTier,
                                                                  customFeerate: customFeerate)
            onStarted()
            progressId = actions.pending.last(where: { $0.name == target.name && $0.isOpen })?.id
            // no registration to follow (it finished at once): nothing left to show
            if progressId == nil { dismiss() }
        } catch {
            startError = error.localizedDescription
        }
        starting = false
    }
}

/// A started claim's progress, under "Claim Started" on the swipe-up screen: the registration's
/// own card, and why the app should stay open until the name registers.
private struct KachatClaimOutcome: View {
    let registrationId: String
    @ObservedObject private var actions = KachatNamesActions.shared

    var body: some View {
        if let registration = actions.pending.first(where: { $0.id == registrationId }) {
            VStack(spacing: 12) {
                KachatRegistrationCard(registration: registration)
                if registration.needsDriving {
                    Text("Keep KaPay open: the name is registered about a minute after the hidden commit confirms. If you leave, it picks up where it left off when you come back.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

// MARK: - Name detail

/// A registered name, live: who owns it, its status and expiry, its price, and what the person
/// can do with it - buy, offer or message the owner; or, for their own names, renew, list,
/// transfer, release and make it their primary name. Offers and history below.
struct KachatLiveNameDetail: View {
    /// MAINNET.md C6: an offer is bound to a seller key, so one made to this owner before the name
    /// last left them - and came back - could be accepted again. Only offers made since the
    /// current owner got the name are shown for them; others to other sellers (declined, on
    /// their way back to the buyer) stay.
    static func currentOffers(_ offers: [KachatNames.OfferInfo], owner: Data, history: [KachatNames.Event]) -> [KachatNames.OfferInfo] {
        let ownershipOps: Set<String> = ["register", "import", "transfer", "sale", "offer_accepted", "offer_accept"]
        guard let since = history.filter({ ownershipOps.contains($0.op) }).compactMap(\.at).max() else { return offers }
        return offers.filter { o in
            guard o.seller == owner, let created = o.createdAt else { return true }
            return created >= since
        }
    }

    @State var info: KachatNames.NameInfo
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @ObservedObject private var actions = KachatNamesActions.shared

    private enum Sheet: Identifiable {
        case buy, offer, extend, renew, list, delist, transfer, release
        var id: Int { hashValue }
    }

    @State private var claimTarget: KachatClaimTarget?

    @State private var ownerCopied = false
    @State private var sheet: Sheet?
    /// The Manage Name half sheet, and what it picked: opened once it has gone down (two
    /// sheets can't present at once).
    @State private var showManage = false
    @State private var pendingSheet: Sheet?
    @State private var pendingPrimary = false
    /// The offer whose half sheet is open (`KachatOfferDetailSheet`).
    @State private var openOffer: KachatNames.OfferInfo?
    @State private var ownerLabel: String?
    @State private var offers: [KachatNames.OfferInfo] = []
    @State private var history: [KachatNames.Event] = []
    @State private var gone = false
    /// The free gap the name sits in once it's gone (released or reclaimed), or the one claiming
    /// a lapsed name reopens: Claim uses it.
    @State private var freeGap: KachatNames.GapInfo?
    @State private var confirmPrimary = false
    /// Which of this wallet's addresses holds the name (main, a spending address, a KasSigner
    /// address), or nil for someone else's. Resolved on load: it derives addresses.
    @State private var heldBy: KachatNamesActions.OwnAddress?

    /// Held by the chatting address: the identity, so "Set as Primary" applies.
    /// Held by the chatting address (Set as Primary applies only there).
    private var mine: Bool { heldBy == .chatting || (heldBy == nil && KachatNamesActions.shared.myKey == info.owner) }
    /// Held by an address this app can sign for: every owner action is available.
    private var canActAsOwner: Bool {
        switch heldBy {
        case .chatting?, .spending?: return true
        default: return mine
        }
    }
    /// Held by any of this wallet's addresses - never offered Buy / Make an Offer.
    private var ownedByWallet: Bool { heldBy != nil || mine }
    private var status: KachatNames.Status { info.status(graceMs: registry.graceMs) }
    /// Listed and still active: the only state in which the asking price means anything.
    private var forSale: Bool { info.isListed && status == .active }
    /// Free to claim: released or reclaimed, or expired past grace (claiming frees it first).
    private var isFree: Bool { gone || status == .lapsed }
    private var ownerAddress: String? { KachatNamesRegistry.address(of: info.owner) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                nameCard
                if isFree {
                    if let freeGap, KachatLive.isEnabled {
                        actionButton("Claim", "at.badge.plus", prominent: true) {
                            claimTarget = KachatClaimTarget(name: info.name, gap: freeGap)
                        }
                        .padding(.horizontal, 16)
                    }
                    Text(gone ? "This name was released or reclaimed. It's free to claim again."
                              : "This name expired and wasn't renewed, so anyone can claim it at the normal price. The old owner's bond goes back to them.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                } else {
                    actionButtons
                    ownerCard
                    offersSection
                }
                historySection
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(info.display)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await registry.refresh() }
        .task(id: registry.revision) { await reload() }
        .sheet(item: $sheet) { s in sheetView(s) }
        .sheet(item: $claimTarget) { target in KachatClaimSheet(target: target) }
        .sheet(isPresented: $showManage, onDismiss: {
            if let next = pendingSheet {
                pendingSheet = nil
                sheet = next
            } else if pendingPrimary {
                pendingPrimary = false
                confirmPrimary = true
            }
        }) {
            manageSheet
        }
        .sheet(item: $openOffer) { o in KachatOfferDetailSheet(state: offerState(o)) }
        .sheet(isPresented: $confirmPrimary) {
            KachatProfileSaveSheet(title: "Set as Primary", confirmTitle: "Set as Primary", doneTitle: "Primary name set",
                                   makeProfile: { await primaryProfile() })
        }
    }

    // MARK: Parts

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor)
                .frame(height: 110)
                .overlay(
                    Text(verbatim: info.display)
                        .font(.title2.weight(.heavy))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 16)
                )
            if isFree {
                // Released, reclaimed or lapsed: the old record (its expiry, period, listing) is
                // history.
                HStack {
                    Text("Free to claim").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    Text("Available")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                }
            } else {
                recordDetails
            }
        }
        .padding(14)
        .kachatGlass(cornerRadius: 18)
        .padding(.horizontal, 16)
    }

    /// The live record under the name: price, status, expiry, paid period, and what expiry means.
    @ViewBuilder
    private var recordDetails: some View {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    // A listing only stands while the name is active: an expired or lapsed name's
                    // old asking price is never shown (it can't be bought, only renewed or reclaimed).
                    Group {
                        if forSale { Text("Price") } else { Text("Not for sale") }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    if forSale {
                        Text(verbatim: KaspaUnit.amount(info.price)).font(.title3.weight(.bold))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    KachatStatusPill(status: status)
                    Text("Expires \(KachatLive.date(info.expiresAt), format: .dateTime.year().month().day())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let start = info.periodStart {
                // registry v2: the paid period, from its start to the expiry (at most 2 years)
                Label {
                    Text("Paid from \(KachatLive.day(start)) to \(KachatLive.day(info.expiresAt))")
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            if status == .grace {
                // when the grace period ends: then anyone can claim it (Available)
                let ends = info.expiresAt + registry.graceMs
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grace period ends \(KachatLive.day(ends))")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Released in") + Text(verbatim: " " + KachatLive.countdown(ends - Int64(context.date.timeIntervalSince1970 * 1000)))
                                .monospacedDigit()
                                .fontWeight(.semibold)
                        }
                    }
                } icon: {
                    Image(systemName: "hourglass")
                }
                .font(.caption)
                .foregroundColor(.orange)
            }
            switch status {
            case .grace where ownedByWallet:
                Text("Expired - renew to keep it. Until the grace period ends it still resolves to you and nobody else can take it.")
                    .font(.footnote).foregroundColor(.orange)
            case .grace:
                Text("Expired. It still resolves to its owner until the grace period ends, and the owner can still renew it.")
                    .font(.footnote).foregroundColor(.orange)
            case .lapsed, .active:
                EmptyView()
            }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            if canActAsOwner {
                // Expired (in grace) and renewable: the one thing that matters now stays on the
                // page instead of inside the menu. (A lapsed name shows as free to claim.)
                if status != .active, let p = KachatLive.params, info.renewOpen(p) {
                    actionButton("Renew", "arrow.clockwise", prominent: true) { sheet = .renew }
                }
                // Every owner action lives in one half sheet of tiles.
                actionButton("Manage Name", "slider.horizontal.3", prominent: status == .active) { showManage = true }
            } else if case .kasSigner? = heldBy {
                // Read-only: the app shows that a KasSigner address holds the name (the Owner card
                // says which); acting on it is the device's job.
                EmptyView()
            } else {
                HStack(spacing: 10) {
                    if info.isListed && status == .active {
                        actionButton("Buy Now", "cart", prominent: true) { sheet = .buy }
                    }
                    // an expired name is free to claim soon: no offers on it
                    if status == .active {
                        actionButton("Make an Offer", "hand.raised") { sheet = .offer }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// One tile of the Manage Name sheet.
    private struct ManageItem: Identifiable {
        let title: String
        let subtitle: String
        let icon: String
        var tint: Color = .accentColor
        var disabled = false
        let run: () -> Void
        var id: String { title }
    }

    /// The owner's actions, as tiles. Registry v2 periods: "Extend" while the paid period holds
    /// less than 2 years ("Extend to 2 years" when that fills it), "Renew" once the renewal
    /// window is open (10 days before the expiry, and on through grace and lapse) - otherwise the
    /// sheet's header says when it opens.
    private var manageItems: [ManageItem] {
        var items: [ManageItem] = []
        // The picked action opens once this sheet has gone down (see the onDismiss).
        let open: (Sheet) -> () -> Void = { s in { pendingSheet = s; showManage = false } }
        if let p = KachatLive.params {
            let extendable = info.extendableYears(p)
            if extendable > 0 {
                let fills = KachatExtendSheet.fillsPeriod(info, years: extendable, params: p)
                let title = !fills ? "Extend"
                    : KachatLive.yearlyPeriods ? String(format: AppLocalization.string("Extend to %lld years"), p.maxYears)
                    : String(format: AppLocalization.string("Extend to %@"), KachatLive.periods(p.maxYears))
                let subtitle = KachatLive.yearlyPeriods ? AppLocalization.string("Pays for more years now, up to the 2-year limit.")
                    : String(format: AppLocalization.string("Pays for more time now, up to the %@ limit."), KachatLive.periods(p.maxYears))
                items.append(ManageItem(title: title, subtitle: subtitle,
                                        icon: "calendar.badge.plus", run: open(.extend)))
            }
            if info.renewOpen(p) {
                items.append(ManageItem(title: "Renew", subtitle: "Starts a new paid period from the expiry date.",
                                        icon: "arrow.clockwise", run: open(.renew)))
            }
        }
        if info.isListed {
            items.append(ManageItem(title: "Change Price", subtitle: "Changes the asking price.",
                                    icon: "tag", disabled: status != .active, run: open(.list)))
            items.append(ManageItem(title: "Delist", subtitle: "Takes the name off the market.",
                                    icon: "tag.slash", run: open(.delist)))
        } else {
            items.append(ManageItem(title: "List for Sale", subtitle: "Puts the name up for sale at your price.",
                                    icon: "tag", disabled: status != .active, run: open(.list)))
        }
        items.append(ManageItem(title: "Transfer", subtitle: "Sends the name to another address.",
                                icon: "arrow.left.arrow.right", run: open(.transfer)))
        // The primary name is the chatting address's identity; a name on a spending address
        // can't be it.
        if mine {
            items.append(ManageItem(title: "Set as Primary", subtitle: "Shows you by this name across KaChat.",
                                    icon: "person.crop.circle.badge.checkmark", disabled: status != .active) {
                pendingPrimary = true
                showManage = false
            })
        }
        items.append(ManageItem(title: "Release Name", subtitle: "Gives the name up and returns its deposit.",
                                icon: "trash", tint: .red, run: open(.release)))
        return items
    }

    /// When the renewal window opens, while it hasn't yet - shown under the sheet's title.
    private var renewalOpensNote: String? {
        guard let p = KachatLive.params, !info.renewOpen(p) else { return nil }
        let day = KachatLive.date(info.renewOpens(p)).formatted(.dateTime.year().month().day())
        return String(format: AppLocalization.string("Renewal opens on %@"), day)
    }

    private var manageSheet: some View {
        let items = manageItems
        let note = renewalOpensNote
        return VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(verbatim: info.display)
                    .font(.headline)
                    .lineLimit(1)
                if let note {
                    Text(verbatim: note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 4)
            ActionSheetTiles {
                ForEach(items) { item in
                    ActionSheetRow(title: item.title, subtitle: item.subtitle, systemImage: item.icon,
                                   tint: item.tint, isDisabled: item.disabled, action: item.run)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(ActionSheetTileMetrics.sheetHeight(tiles: items.count, header: note == nil ? 70 : 90))])
        .presentationDragIndicator(.visible)
    }

    private func actionButton(_ title: LocalizedStringKey, _ icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Group {
            if prominent {
                Button(action: action) {
                    Label(title, systemImage: icon).font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) {
                    Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var ownerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatLiveSectionHeader(title: "Owner", detail: nil)
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor.opacity(0.6))
                VStack(alignment: .leading, spacing: 3) {
                    if mine {
                        Text("You").font(.subheadline.weight(.semibold))
                    } else if case .spending(let index, _)? = heldBy {
                        Text("Your spending address #\(index)").font(.subheadline.weight(.semibold))
                    } else if case .kasSigner(let account, let index, _)? = heldBy {
                        Text("Your KasSigner address (\(account) #\(index))").font(.subheadline.weight(.semibold))
                    } else if let ownerLabel {
                        Text(verbatim: "\(ownerLabel).kachat").font(.subheadline.weight(.semibold))
                    }
                    if let ownerAddress {
                        // The whole address doesn't fit on two lines: show its network prefix
                        // and both ends on one line, and copy the full address on tap.
                        Button {
                            UIPasteboard.general.string = ownerAddress
                            Haptics.success()
                            ownerCopied = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(verbatim: KachatNamesRegistry.compactAddress(ownerAddress))
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                Image(systemName: ownerCopied ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                            }
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: ownerAddress))
                        .accessibilityHint(Text("Copies the address"))
                        .task(id: ownerCopied) {
                            guard ownerCopied else { return }
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            ownerCopied = false
                        }
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(14)
            .kachatGlass()
            .padding(.horizontal, 16)
        }
    }

    /// One offer on this name, as this wallet sees it.
    private func offerState(_ o: KachatNames.OfferInfo) -> KachatOfferState {
        KachatOfferState(offer: o, isBuyer: KachatLive.isMine(o.buyer), isOwner: canActAsOwner && registry.source?.isIndexer == true,
                         name: info, declined: o.isDeclined(currentOwner: info.owner))
    }

    private var offersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatLiveSectionHeader(title: "Offers", detail: canActAsOwner ? "Tap an offer to accept or decline it. Expired offers go back to their buyers." : nil)
            if offers.isEmpty {
                Text("No open offers.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .kachatGlass()
                    .padding(.horizontal, 16)
            } else {
                KachatNameGrid {
                    ForEach(offers) { o in
                        KachatOfferTile(state: offerState(o)) { openOffer = o }
                    }
                }
            }
            if registry.source == .chain {
                Text("Offers from others appear once a names indexer is connected.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatLiveSectionHeader(title: "History", detail: nil)
            if history.isEmpty {
                Text("No history yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .kachatGlass()
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.prefix(50).enumerated()), id: \.element.id) { index, e in
                        KachatEventRow(event: e)
                        if index < min(history.count, 50) - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .kachatGlass()
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .buy: KachatBuySheet(info: info)
        case .offer: KachatOfferSheet(info: info)
        case .extend: KachatExtendSheet(info: info)
        case .renew: KachatRenewSheet(info: info)
        case .list: KachatListSheet(info: info)
        case .delist:
            KachatTxSheet(
                title: "Delist", confirmTitle: "Delist",
                authReason: KachatLive.authReason, doneTitle: "Delisted",
                rows: [.init(title: "Name", value: info.display), .init(title: "Listed at", value: KaspaUnit.amount(info.price))],
                operation: .list(info, price: 0), operationKey: "delist-\(info.outpoint.index)-\(KachatNames.hex(info.outpoint.txid))"
            )
        case .transfer: KachatTransferSheet(info: info)
        case .release:
            KachatTxSheet(
                title: "Release Name", confirmTitle: "Release",
                authReason: KachatLive.authReason, doneTitle: "Name released",
                warning: "Releasing gives the name up for good: it becomes free for anyone to register, and the time you paid for is lost. You get the bond and the registry deposit back.",
                rows: [.init(title: "Name", value: info.display)],
                operation: .release(info), operationKey: "release-\(KachatNames.hex(info.outpoint.txid))"
            )
        }
    }

    // MARK: Loading

    private func reload() async {
        do {
            switch try await registry.lookup(info.name) {
            case .registered(let n):
                info = n
                gone = false
                // lapsed: free to claim, in the gap claiming it reopens
                if n.status(graceMs: registry.graceMs) == .lapsed {
                    freeGap = try? await registry.claimGap(for: n)
                } else {
                    freeGap = nil
                }
            case .free(_, let gap):
                gone = true
                freeGap = gap
            }
        } catch {}
        heldBy = actions.ownAddress(of: info.owner)
        if !ownedByWallet, let ownerAddress, let id = try? await registry.identity(address: ownerAddress) {
            ownerLabel = id.label
        }
        history = (try? await registry.history(name: info.name)) ?? []
        offers = Self.currentOffers((try? await registry.offers(for: info.name)) ?? [], owner: info.owner, history: history)
        if !offers.isEmpty {
            await actions.refreshVirtualDaa()
            // Expired offers don't stay on your name: the owner's app (and the buyer's) send
            // them back.
            if canActAsOwner {
                await actions.returnExpiredOffers(offers)
            } else {
                await actions.returnExpiredOffers(offers.filter { KachatLive.isMine($0.buyer) })
            }
            // Your offers made to an earlier owner of this name: pulled back.
            await actions.withdrawDeclinedOffers(offers)
        }
    }

    /// Your current profile with this name as the primary one: setting it rewrites the record.
    private func primaryProfile() async -> KachatNames.Profile {
        var profile = KachatNames.Profile()
        if let address = actions.myAddress {
            if let own = registry.ownProfile(for: address)?.profile {
                profile = own
            } else if let p = try? await registry.identity(address: address).profile {
                profile = p
            }
        }
        profile.primaryName = info.name
        return profile
    }
}

// MARK: - Sheets with inputs

struct KachatLiveBuySheet: View {
    let info: KachatNames.NameInfo

    var body: some View {
        KachatTxSheet(
            title: "Buy Name", confirmTitle: "Confirm Purchase",
            authReason: KachatLive.authReason, doneTitle: "Name bought",
            footer: soon ? "Less than \(KachatLive.duration(soonMs)) is left before this name expires. You'd have to renew it soon." : "The payment reaches the seller and the name reaches you in the same transaction - both happen, or neither does.",
            rows: [.init(title: "Name", value: info.display), .init(title: "Price (to the seller)", value: KaspaUnit.amount(info.price)),
                   .init(title: "Expires", value: KachatLive.day(info.expiresAt))],
            operation: .buy(info), operationKey: "buy-\(KachatNames.hex(info.outpoint.txid))",
            swipeUp: KachatSwipeUp(bar: "Swipe up to Buy", labels: .buy, recipient: info.display)
        )
    }

    /// 30 days on mainnet's yearly clock, the renewal window on testnet's 24-hour one.
    private var soonMs: Int64 { KachatLive.params?.expiresSoonMs ?? 30 * 86_400_000 }
    private var soon: Bool { info.expiresAt - soonMs < KachatNames.nowMs() }
}

struct KachatLiveOfferSheet: View {
    let name: String
    /// the name as registered: the offer is made to its current owner
    let info: KachatNames.NameInfo

    @State private var amountText = ""
    @State private var days = 3
    @State private var virtualDaa: UInt64?
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    private var amount: UInt64? { KaspaUnit.sompi(fromUserText: amountText).flatMap { $0 > 0 ? $0 : nil } }
    /// `days` from now, but never past the name's expiry (MAINNET.md C1): with yearly names that
    /// rarely matters, near the end of a period it does.
    private var refundAfter: UInt64? {
        guard let virtualDaa else { return nil }
        let wanted = virtualDaa + UInt64(days) * 86_400 * KachatLive.daaPerSecond
        let msLeft = info.expiresAt - KachatNames.nowMs() - 600_000   // 10 minutes of margin
        guard msLeft > 0 else { return nil }
        let atExpiry = virtualDaa + UInt64(msLeft) * KachatLive.daaPerSecond / 1000
        return min(wanted, atExpiry)
    }
    private var cappedByExpiry: Bool {
        guard let virtualDaa, let refundAfter else { return false }
        return refundAfter < virtualDaa + UInt64(days) * 86_400 * KachatLive.daaPerSecond
    }

    private var operation: KachatNamesActions.Operation? {
        guard let amount, let refundAfter else { return nil }
        return .offer(target: info, amount: amount, refundAfterDaa: refundAfter)
    }

    var body: some View {
        KachatTxSheet(
            title: "Make an Offer", confirmTitle: "Send Offer",
            authReason: KachatLive.authReason, doneTitle: "Offer sent",
            footer: belowListing
                ? "This name is listed for less than your offer. Consider buying it instead."
                : "Your KAS stays locked on chain until the owner accepts or declines, you withdraw the offer, or it expires - then anyone can send it back to you.",
            rows: rows,
            operation: operation, operationKey: "\(amount ?? 0)-\(days)-\(virtualDaa ?? 0)",
            swipeUp: KachatSwipeUp(bar: "Swipe up to Offer", labels: .transaction(done: "Offer sent"), recipient: "\(name).kachat"),
            entryQuestion: "How much do you offer?",
            canContinue: operation != nil
        ) {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Refundable after")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Picker("Expires", selection: $days) {
                        Text("1 Day").tag(1)
                        Text("3 Days").tag(3)
                        // the app's cap (KachatNamesActions.maxOfferDays)
                        Text("7 Days").tag(7)
                    }
                    .pickerStyle(.segmented)
                    if cappedByExpiry {
                        Text(String(format: AppLocalization.string("This name expires sooner, so your offer is refundable from %@."), KachatLive.day(info.expiresAt - 600_000)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                KaspaKeypadAmountEntry(
                    fiatAmountState: fiatAmountState,
                    onAmountChange: { amountText = $0 },
                    showsMax: false,
                    footnote: info.isListed ? "\(AppLocalization.string("Listed at")) \(KaspaUnit.amount(info.price))" : nil,
                    onMax: {}
                )
            }
        }
        .task {
            virtualDaa = await NodePoolService.shared.currentVirtualDaaScore()
        }
    }

    private var belowListing: Bool {
        guard info.isListed, let amount else { return false }
        return info.price < amount
    }

    private var rows: [KachatTxRow] {
        var r: [KachatTxRow] = [.init(title: "Name", value: "\(name).kachat")]
        if info.isListed { r.append(.init(title: "Listed at", value: KaspaUnit.amount(info.price))) }
        r.append(.init(title: "Expires", value: KachatLive.day(info.expiresAt)))
        if let amount { r.append(.init(title: "Offer", value: KaspaUnit.amount(amount))) }
        if refundAfter != nil {
            r.append(.init(title: "Refundable after", value: cappedByExpiry
                ? KachatLive.day(info.expiresAt - 600_000)
                : String(format: AppLocalization.string(days == 1 ? "%d day" : "%d days"), days)))
        }
        return r
    }
}

/// `extend`: periods added to the current paid period (periodStart kept), up to `maxYears`
/// periods past its start - in practice a 1-period name extended to 2. Anyone may extend any name.
struct KachatExtendSheet: View {
    let info: KachatNames.NameInfo
    @State private var years: Int64 = 1

    private var params: KachatNames.Params? { KachatLive.params }
    private var maxYears: Int64 { params?.maxYears ?? 2 }
    /// The years that still fit in the period (in practice 1).
    private var available: Int64 { max(1, params.map { info.extendableYears($0) } ?? 1) }
    private var perYear: UInt64 { KachatLive.renewPrice(info.name) ?? 0 }
    private var periodMs: Int64 { params?.periodMs ?? KachatNames.yearMs }

    /// Whether extending by `years` fills the period to exactly `maxYears`.
    static func fillsPeriod(_ info: KachatNames.NameInfo, years: Int64, params p: KachatNames.Params) -> Bool {
        guard let start = info.periodStart else { return false }
        return info.expiresAt + years * p.periodMs == start + p.maxYears * p.periodMs
    }

    private var title: LocalizedStringKey {
        if let params, Self.fillsPeriod(info, years: years, params: params) {
            return KachatLive.yearlyPeriods ? "Extend to \(maxYears) years" : "Extend to \(KachatLive.periods(maxYears))"
        }
        return "Extend"
    }

    private var footer: LocalizedStringKey {
        KachatLive.yearlyPeriods
            ? "Extending adds years to the current paid period, which holds at most 2 years. The price goes to the miners."
            : "Extending adds time to the current paid period, which holds at most \(KachatLive.periods(maxYears)). The price goes to the miners."
    }

    var body: some View {
        KachatTxSheet(
            title: title, confirmTitle: "Extend",
            authReason: KachatLive.authReason, doneTitle: "Extended",
            footer: footer,
            rows: [
                .init(title: "Name", value: info.display),
                .init(title: KachatLive.pricePerPeriodTitle, value: KaspaUnit.amount(perYear)),
                .init(title: "Expires", value: KachatLive.day(info.expiresAt)),
                .init(title: "New expiry", value: KachatLive.day(info.expiresAt + years * periodMs))
            ],
            operation: .extend(info, years: min(years, available)), operationKey: "extend-\(years)",
            swipeUp: KachatSwipeUp(bar: "Swipe up to Extend", labels: .transaction(done: "Extended"), recipient: info.display)
        ) {
            if available > 1 {
                KachatInputCard {
                    Picker("Years", selection: $years) {
                        ForEach(1...Int(available), id: \.self) { y in
                            KachatYearsText(years: y).tag(Int64(y))
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }
}

/// `renew`: the next period, from the current expiry, for 1 or 2 periods - only once the
/// renewal window is open (`renewWindowMs` before the expiry; the detail screen says when). Two
/// steps, like a send: how long (10m / 20m on testnet's clock, 1 / 2 years on mainnet's), then
/// the review with the fee and swipe up.
struct KachatRenewSheet: View {
    let info: KachatNames.NameInfo
    /// Nothing is chosen until the person taps one.
    @State private var years: Int?
    @State private var reviewing = false
    @Environment(\.dismiss) private var dismiss

    private var maxYears: Int { Int(KachatLive.params?.maxYears ?? 2) }
    private var perYear: UInt64 { KachatLive.renewPrice(info.name) ?? 0 }

    var body: some View {
        NavigationStack {
            ZStack {
                if reviewing, let years {
                    KachatRenewReview(info: info, years: Int64(years)) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { reviewing = false }
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
                } else {
                    chooser
                        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var chooser: some View {
        SendStepScreen(title: Text("Renew"), onCancel: { dismiss() }, continueTitle: "Review",
                       canContinue: years != nil) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { reviewing = true }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "How long?")
                    Text("A renewal starts the next period at the current expiry, not from today.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    ForEach(1...max(1, maxYears), id: \.self) { y in
                        Button {
                            Haptics.impact(.light)
                            years = y
                        } label: {
                            HStack {
                                Image(systemName: years == y ? "checkmark.circle.fill" : "circle")
                                KachatYearsText(years: y)
                                Spacer()
                                Text(verbatim: KaspaUnit.amount(perYear * UInt64(y)))
                            }
                            .font(.body.weight(.semibold))
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(years == y ? Color.accentColor : Color.clear)
                            .foregroundColor(years == y ? .black : .accentColor)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, lineWidth: 1.5))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(years == y ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
        }
    }
}

/// Renew, step 2: what the chosen period costs, the fee, and swipe up to renew.
private struct KachatRenewReview: View {
    let info: KachatNames.NameInfo
    let years: Int64
    let onBack: () -> Void

    private var perYear: UInt64 { KachatLive.renewPrice(info.name) ?? 0 }
    private var periodMs: Int64 { KachatLive.params?.periodMs ?? KachatNames.yearMs }

    var body: some View {
        KachatTxSheet(
            title: "Renew", confirmTitle: "Renew",
            authReason: KachatLive.authReason, doneTitle: "Renewed",
            footer: "A renewal starts the next period at the current expiry, not from today, so a name that expired a while ago gets less time. The price goes to the miners.",
            rows: [
                .init(title: "Name", value: info.display),
                .init(title: KachatLive.pricePerPeriodTitle, value: KaspaUnit.amount(perYear)),
                .init(title: "New period", value: "\(KachatLive.day(info.expiresAt)) – \(KachatLive.day(info.expiresAt + years * periodMs))")
            ],
            operation: .renew(info, years: years), operationKey: "renew-\(years)",
            embedded: true, onBack: onBack,
            swipeUp: KachatSwipeUp(bar: "Swipe up to Renew", labels: .transaction(done: "Renewed"), recipient: info.display)
        )
    }
}

struct KachatListSheet: View {
    let info: KachatNames.NameInfo
    @State private var priceText = ""
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    private var price: UInt64? { KaspaUnit.sompi(fromUserText: priceText).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        KachatTxSheet(
            title: info.isListed ? "Change Price" : "List for Sale", confirmTitle: info.isListed ? "Change Price" : "List",
            authReason: KachatLive.authReason, doneTitle: info.isListed ? "Price changed" : "Listed for sale",
            footer: "Anyone can buy it at this price: the payment reaches you and the name reaches them in one transaction. Delist any time.",
            rows: rows,
            operation: price.map { .list(info, price: $0) }, operationKey: "list-\(price ?? 0)",
            swipeUp: KachatSwipeUp(bar: info.isListed ? "Swipe up to Change Price" : "Swipe up to List",
                                   labels: .transaction(done: info.isListed ? "Price changed" : "Listed for sale"),
                                   recipient: info.display, showsAmount: false),
            entryQuestion: info.isListed ? "What's the new price?" : "What's your price?",
            canContinue: price != nil
        ) {
            KaspaKeypadAmountEntry(
                fiatAmountState: fiatAmountState,
                onAmountChange: { priceText = $0 },
                showsMax: false,
                footnote: info.isListed ? "\(AppLocalization.string("Listed at")) \(KaspaUnit.amount(info.price))" : nil,
                onMax: {}
            )
        }
    }

    private var rows: [KachatTxRow] {
        var r: [KachatTxRow] = [.init(title: "Name", value: info.display)]
        if info.isListed { r.append(.init(title: "Listed at", value: KaspaUnit.amount(info.price))) }
        if let price { r.append(.init(title: info.isListed ? "New price" : "Price", value: KaspaUnit.amount(price))) }
        return r
    }
}

struct KachatTransferSheet: View {
    let info: KachatNames.NameInfo
    @State private var input = ""
    @State private var resolved: (address: String, key: Data)?
    @State private var resolveError: String?
    @State private var resolving = false
    /// A typed name: what it resolved as (.kachat first) and every service's answer.
    @State private var resolvedName: String?
    @State private var nameResolutions: [NameResolution] = []
    @State private var selectedTLD: NameServiceTLD?
    @State private var showScanner = false

    var body: some View {
        KachatTxSheet(
            title: "Transfer", confirmTitle: "Transfer",
            authReason: KachatLive.authReason, doneTitle: "Name transferred",
            warning: "A transfer can't be undone. The new owner gets the name with its current expiry; your profile stays with your address.",
            rows: [KachatTxRow(title: "Name", value: info.display)]
                + (resolved.map { r in
                    [KachatTxRow(title: "To", value: resolvedName.map { "\($0) · \(KachatNamesRegistry.compactAddress(r.address))" } ?? r.address)]
                } ?? []),
            operation: resolved.map { .transfer(info, to: $0.key) }, operationKey: resolved?.address ?? "-",
            swipeUp: KachatSwipeUp(bar: "Swipe up to Transfer", labels: .transaction(done: "Name transferred"),
                                   recipient: info.display, showsAmount: false),
            entryQuestion: "Who gets the name?",
            canContinue: resolved != nil && !resolving
        ) {
            // The Send screens' recipient card: Paste, Scan QR and the Address Book under it.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SendRecipientCard(
                        input: $input,
                        isResolving: resolving,
                        resolvedAddress: resolvedName != nil ? resolved?.address : nil,
                        resolvedName: resolvedName,
                        lookupError: resolveError,
                        isValidAddress: resolved != nil,
                        onScan: { showScanner = true },
                        nameResolutions: nameResolutions,
                        selectedTLD: selectedTLD,
                        onSelectResolution: { _ = use($0) },
                        focusOnAppear: true
                    )
                    Text("An address or a domain - .kachat names are looked up first, and it's resolved to the address shown.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .task(id: input) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await resolve()
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                var scanned = code.trimmingCharacters(in: .whitespacesAndNewlines)
                if let q = scanned.firstIndex(of: "?") { scanned = String(scanned[..<q]) }
                input = scanned
                showScanner = false
            }
        }
    }

    private func resolve() async {
        resolved = nil
        resolveError = nil
        resolvedName = nil
        nameResolutions = []
        selectedTLD = nil
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return }
        if t.hasPrefix("kaspatest:") || t.hasPrefix("kaspa:") {
            guard let key = KachatNamesRegistry.keyOf(t) else {
                resolveError = AppLocalization.string("Not a Schnorr address on this network.")
                return
            }
            guard (try? KachatNamesActions.validateKey(key, "")) != nil else {
                resolveError = AppLocalization.string("That address's key is not valid.")
                return
            }
            resolved = (t, key)
            return
        }
        // a name on any service, .kachat first (the ending typed, else .kachat only (the others wait under Other domains))
        guard NameServicesClient.looksLikeName(t) else {
            resolveError = AppLocalization.string("Enter an address or a domain.")
            return
        }
        resolving = true
        let results = await NameServicesClient.shared.resolveEverywhere(t)
        resolving = false
        guard input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == t else { return }
        nameResolutions = results
        if let primary = NameServicesClient.primary(of: results, typed: t) {
            if !use(primary) { resolveError = AppLocalization.string("That name's address can't own a .kachat name.") }
        } else {
            resolveError = NameServicesClient.notFoundMessage(typed: t, results: results)
        }
    }

    /// Takes one service's answer as the new owner: its address must be a Schnorr key, the
    /// only kind a name can be locked to. False when it isn't.
    @discardableResult
    private func use(_ resolution: NameResolution) -> Bool {
        guard let address = resolution.address?.lowercased(),
              let key = KachatNamesRegistry.keyOf(address),
              (try? KachatNamesActions.validateKey(key, "")) != nil else { return false }
        resolved = (address, key)
        resolvedName = resolution.display
        selectedTLD = resolution.tld
        resolveError = nil
        return true
    }
}

// MARK: - Your Domains > .kachat

struct KachatLiveDomainsTab: View {
    let walletAddress: String
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @ObservedObject private var service = KachatNamesService.shared
    @State private var names: [KachatNames.NameInfo] = []
    /// the offers this wallet made (moved here from the marketplace's former My Names tab)
    @State private var myOffers: [KachatNames.OfferInfo] = []
    @State private var loaded = false
    /// The .kachat marketplace, opened by Inscribe as a sheet over Your Domains: a new name
    /// lands back here as soon as it is swiped away, and it works whether or not .kachat is in
    /// the dock.
    @State private var showMarketplace = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if !loaded {
                    ProgressView().padding(.vertical, 24)
                } else if service.registryUpgrading {
                    // the bundled manifest is for the previous registry: calm, no error
                    VStack(spacing: 10) {
                        Image(systemName: "hammer")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundColor(.accentColor)
                        Text("Setting up")
                            .font(.headline)
                        Text("The .kachat registry is being upgraded. Names open here again once the new registry is live.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    if names.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "at.circle")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundColor(.accentColor)
                            Text("No .kachat names yet")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(names) { n in
                            NavigationLink {
                                KachatListingDetailView(info: n)
                            } label: {
                                DomainNameCardView(title: n.display, badge: Self.badge(for: n, graceMs: registry.graceMs),
                                                   footnote: Self.expiryLine(for: n, graceMs: registry.graceMs))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !myOffers.isEmpty {
                        KachatMyOffersSection(offers: myOffers)
                            .padding(.horizontal, -16)
                            .padding(.top, 8)
                    }
                }
            }
            .padding()
        }
        .refreshable { await registry.refresh() }
        .task(id: registry.revision) {
            showCachedIfNeeded()
            await load()
            // a name that lapses while this is open leaves right then
            await registry.dropLapsed(from: names) { names = $0 }
        }
        .safeAreaInset(edge: .bottom) {
            if loaded && !service.registryUpgrading {
                inscribeButton
            }
        }
        .sheet(isPresented: $showMarketplace, onDismiss: {
            Task { await registry.refresh() }
        }) {
            KachatMarketView()
                .presentationDragIndicator(.visible)
        }
    }

    /// Pinned under the list like the other name services' "Get a domain" button, in the same
    /// glass capsule with a teal outline (the cards above are accent-filled).
    private var inscribeButton: some View {
        Button {
            showMarketplace = true
        } label: {
            Text("Inscribe")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.bottom, 16)
        .accessibilityHint(Text("Opens the .kachat marketplace"))
    }

    /// The card badge for a name: Listed, or Expired (in grace). Shared with the per-address
    /// lists (`KachatAddressLiveNamesList`); neither lists lapsed names (`heldNames`).
    /// The card's bottom-right corner: when the name expires - or, once it has, when its grace
    /// period ends (renew before then to keep it).
    static func expiryLine(for n: KachatNames.NameInfo, graceMs: Int64) -> String? {
        switch n.status(graceMs: graceMs) {
        case .active: return String(format: AppLocalization.string("Expires %@"), KachatLive.day(n.expiresAt))
        case .grace: return String(format: AppLocalization.string("Grace ends %@"), KachatLive.day(n.expiresAt + graceMs))
        case .lapsed: return nil
        }
    }

    static func badge(for n: KachatNames.NameInfo, graceMs: Int64) -> String? {
        switch n.status(graceMs: graceMs) {
        case .active: return n.isListed ? AppLocalization.string("Listed") : nil
        case .grace: return AppLocalization.string("Expired")
        case .lapsed: return AppLocalization.string("Available")
        }
    }

    /// The names this wallet had last time, straight away - they rarely change. `load()` then
    /// checks the registry and replaces them when it answers (`KachatOwnedNamesCache`).
    private func showCachedIfNeeded() {
        guard !loaded, let cached = KachatOwnedNamesCache.load(walletAddress) else { return }
        let grace = registry.graceMs
        names = cached.names.filter { $0.status(graceMs: grace) != .lapsed }
        myOffers = cached.offers
        loaded = true
    }

    private func load() async {
        guard let key = KachatNamesRegistry.keyOf(walletAddress) else { loaded = true; return }
        if registry.refreshedAt == nil { await registry.refresh() }
        // A lapsed name is no longer yours: it moves to the marketplace's Reclaimable tab (and the
        // bell says so, `KachatNamesNotifier`). Expired names in grace stay, to be renewed.
        // Your own list (the chatting address's) holds the names and offers on every address of
        // this wallet - one claimed with Buy From too, on any device restored from the seed.
        // Only an answer replaces what is shown (and the saved copy); a failed read keeps it.
        if walletAddress.lowercased() == KachatNamesActions.shared.myAddress {
            if let own = try? await KachatNamesActions.shared.ownNamesAndOffers(heldOnly: true) {
                names = own.names
                myOffers = own.offers
                KachatOwnedNamesCache.save(names: names, offers: myOffers, for: walletAddress)
            }
        } else if let held = try? await registry.heldNames(owner: key) {
            names = held
            myOffers = (try? await registry.myOffers(buyer: key)) ?? myOffers
            KachatOwnedNamesCache.save(names: names, offers: myOffers, for: walletAddress)
        }
        if !myOffers.isEmpty {
            // expired offers, and ones made to an earlier owner, come back on their own
            await KachatNamesActions.shared.refreshVirtualDaa()
            await KachatNamesActions.shared.returnExpiredOffers(myOffers)
            await KachatNamesActions.shared.withdrawDeclinedOffers(myOffers)
        }
        loaded = true
    }
}

// MARK: - Edit KaChat Profile

/// Where a social link's lookup stands - the editor saves only a field whose lookup found what
/// that field shows, so what gets saved is what was reviewed.
enum KachatSocialLookup: Equatable {
    case none, looking, found, empty, unreachable
}

/// One profile field's source (avatar, banner or bio) looked up on this device, showing exactly
/// the piece other people will see.
struct KachatSocialPreview: View {
    let link: String
    let kind: KachatNames.SocialSource.Kind
    @Binding var lookup: KachatSocialLookup

    @ObservedObject private var resolver = KachatSocialImageResolver.shared
    @State private var resolved: KachatNames.SocialProfile?
    @State private var attempt = 0
    /// The lookup whose answer may land: a newer one (edited link, Retry) supersedes it.
    @State private var activeKey = ""

    private var source: KachatNames.SocialSource? { KachatNames.SocialSource(link: link, for: kind) }

    private func piece(_ p: KachatNames.SocialProfile?) -> String? {
        switch kind {
        case .avatar: return p?.avatar
        case .banner: return p?.banner
        case .bio: return p?.bio
        }
    }

    var body: some View {
        // A VStack, not a Group: a Group hands its modifiers to each child, so `.task` below
        // would belong to whichever child shows - and switching from the spinner to the result
        // would cancel it and start the lookup again, endlessly. The VStack is one stable view.
        VStack(alignment: .leading, spacing: 0) {
            if let source {
                switch lookup {
                case .none, .looking:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up the profile...").font(.footnote).foregroundColor(.secondary)
                    }
                case .found:
                    found(source)
                case .empty:
                    note("person.crop.circle.badge.exclamationmark", missingText(source.platform))
                case .unreachable:
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark").foregroundColor(.secondary)
                        Text(verbatim: String(format: AppLocalization.string("Couldn't reach %@."), source.platform.displayName))
                            .font(.footnote).foregroundColor(.secondary)
                        Spacer()
                        Button("Retry") { attempt += 1 }.font(.footnote.weight(.semibold))
                    }
                }
            }
        }
        // Debounced: one lookup once typing pauses. `attempt` reruns it for Retry. Whatever
        // happens - cancelled, restarted, failed - the state always lands somewhere final.
        .task(id: "\(source?.link ?? "")#\(attempt)") {
            let myKey = "\(source?.link ?? "")#\(attempt)"
            activeKey = myKey
            guard let source else { resolved = nil; lookup = .none; return }
            // The row scrolled back into view (a Form rebuilds its rows): the answer this
            // screen already got shows at once - no debounce, no "Looking up" flash, no
            // refetch. Retry (attempt > 0) still runs the full lookup.
            if attempt == 0, let cached = resolver.cachedProfile(source) {
                resolved = cached
                lookup = piece(cached) == nil ? .empty : .found
                // Still re-checked quietly (the resolver's own 5-minute freshness): a profile
                // changed on the platform lands here without the flash.
                let result = await resolver.resolve(source)
                guard activeKey == myKey, case .answered(let fresh) = result, fresh != cached else { return }
                resolved = fresh
                lookup = piece(fresh) == nil ? .empty : .found
                return
            }
            lookup = .looking
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard activeKey == myKey else { return }
            let result = await resolver.resolve(source)
            guard activeKey == myKey else { return }
            resolved = result.profile
            switch result {
            case .answered(let p):
                lookup = piece(p) == nil ? .empty : .found
            case .unreachable(let cached):
                lookup = piece(cached) == nil ? .unreachable : .found
            }
        }
    }

    @ViewBuilder
    private func found(_ source: KachatNames.SocialSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case .avatar:
                KNSAvatarView(avatarURLString: resolved?.avatar, fallbackText: "", size: 64)
            case .banner:
                KNSBannerImageView(bannerURLString: resolved?.banner, height: 90, cornerRadius: 8, fitsWidth: true)
            case .bio:
                Text(verbatim: resolved?.bio ?? "").font(.subheadline)
            }
            Text(verbatim: String(format: AppLocalization.string("From %@"), source.platform.displayName))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func missingText(_ platform: KachatNames.SocialSource.Platform) -> String {
        let key: String
        switch kind {
        case .avatar: key = "No avatar on this %@ profile."
        case .banner: key = "No banner on this %@ profile."
        case .bio: key = "No bio on this %@ profile."
        }
        return String(format: AppLocalization.string(key), platform.displayName)
    }

    private func note(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.secondary)
            Text(verbatim: text).font(.footnote).foregroundColor(.secondary)
        }
    }
}

/// One profile field's source as the editor holds it: the platform picked and the handle typed.
struct KachatSourceInput: Equatable {
    var platform: KachatNames.SocialSource.Platform = .x
    var handle = ""

    init(platform: KachatNames.SocialSource.Platform = .x, handle: String = "") {
        self.platform = platform
        self.handle = handle
    }

    /// From a stored profile link.
    init(stored link: String?, _ kind: KachatNames.SocialSource.Kind) {
        if let s = KachatNames.SocialSource(link: link ?? "", for: kind) {
            self.init(platform: s.platform, handle: s.displayHandle)
        } else {
            self.init()
        }
    }

    var isEmpty: Bool { handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func source(_ kind: KachatNames.SocialSource.Kind) -> KachatNames.SocialSource? {
        KachatNames.SocialSource.from(platform: platform, handle: handle, for: kind)
    }

    func isBad(_ kind: KachatNames.SocialSource.Kind) -> Bool { !isEmpty && source(kind) == nil }

    /// The source when the handle field holds a whole pasted link (rather than a handle).
    func pastedSource(_ kind: KachatNames.SocialSource.Kind) -> KachatNames.SocialSource? {
        let t = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("http") || (t.contains(".") && t.contains("/")) else { return nil }
        return source(kind)
    }
}

/// The address profile (KACHAT_NAMES.md section 7): where the avatar, banner and bio come from
/// (a social profile link each - they can be different accounts), a Linktree link, and which of
/// your names labels you - written as a `kchat:1:profile:` self-transfer. No free text and no
/// uploads: what shows comes from a platform that moderates it.
struct KachatLiveProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = KachatNamesRegistry.shared

    /// Each piece's source: a platform from the picker plus the handle typed after its prefix.
    @State private var avatarIn = KachatSourceInput()
    @State private var bannerIn = KachatSourceInput()
    @State private var bioIn = KachatSourceInput()
    @State private var avatarLookup: KachatSocialLookup = .none
    @State private var bannerLookup: KachatSocialLookup = .none
    @State private var bioLookup: KachatSocialLookup = .none
    @State private var linktree = ""
    @State private var primary = ""
    @State private var activeNames: [String] = []
    @State private var loaded = false
    @State private var showSave = false
    @State private var showClear = false

    private typealias Kind = KachatNames.SocialSource.Kind

    private var profile: KachatNames.Profile {
        var p = KachatNames.Profile()
        p.avatar = avatarIn.source(.avatar)?.link
        p.banner = bannerIn.source(.banner)?.link
        p.bio = bioIn.source(.bio)?.link
        p.linktree = KachatNames.Profile.linktreeLink(username: linktree)
        p.primaryName = primary.isEmpty ? nil : primary
        return p.sanitized()
    }

    /// A filled-in field whose lookup hasn't found what it shows (still looking, unreachable, or
    /// nothing there). It doesn't block saving - a social site being slow or unreachable from
    /// this phone must never stop a profile (or a primary name) from saving; the link is saved
    /// as entered and every viewer's app looks it up itself. The editor just says so.
    private func notReviewed(_ input: KachatSourceInput, _ lookup: KachatSocialLookup) -> Bool {
        !input.isEmpty && lookup != .found
    }

    private var hasUncheckedLinks: Bool {
        notReviewed(avatarIn, avatarLookup) || notReviewed(bannerIn, bannerLookup) || notReviewed(bioIn, bioLookup)
    }

    /// Only a malformed handle or Linktree username stops a save.
    private var blocked: Bool {
        avatarIn.isBad(.avatar) || bannerIn.isBad(.banner) || bioIn.isBad(.bio) || badLinktree
    }

    /// The Linktree field holds just the username (`linktr.ee/` is shown in front of it).
    private var badLinktree: Bool {
        let t = linktree.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && KachatNames.Profile.linktreeLink(username: t) == nil
    }

    /// Once one field's account is found, the empty fields take the same account where its
    /// platform can fill them - one handle sets up the whole profile, and each stays editable.
    private func fillEmpty(from input: KachatSourceInput) {
        let fits = { (kind: Kind) in KachatNames.SocialSource.Platform.choices(for: kind).contains(input.platform) }
        if avatarIn.isEmpty, fits(.avatar) { avatarIn = input }
        if bannerIn.isEmpty, fits(.banner) { bannerIn = input }
        if bioIn.isEmpty, fits(.bio) { bioIn = input }
    }

    /// Platform picker, the handle after the platform's prefix, and the preview of what it shows.
    private func sourceField(_ input: Binding<KachatSourceInput>, _ kind: Kind, _ lookup: Binding<KachatSocialLookup>) -> some View {
        Group {
            Picker("Account on", selection: input.platform) {
                ForEach(KachatNames.SocialSource.Platform.choices(for: kind), id: \.self) { p in
                    Text(verbatim: p.displayName).tag(p)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 0) {
                Text(verbatim: input.wrappedValue.platform.prefix).foregroundColor(.secondary)
                TextField(input.wrappedValue.platform == .discord ? LocalizedStringKey("invite") : LocalizedStringKey("handle"), text: input.handle)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: input.wrappedValue.handle) { _ in
                        // A whole pasted link: switch the picker to its platform, keep the handle.
                        if let pasted = input.wrappedValue.pastedSource(kind) {
                            input.wrappedValue = KachatSourceInput(platform: pasted.platform, handle: pasted.displayHandle)
                        }
                    }
                // One tap empties the field; saving then writes the profile without it.
                if !input.wrappedValue.handle.isEmpty {
                    Button {
                        input.wrappedValue = KachatSourceInput()
                        lookup.wrappedValue = .none
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear"))
                }
            }
            // Only while the handle names an account: no empty row, and the lookup starts when it
            // appears.
            if let link = input.wrappedValue.source(kind)?.link {
                KachatSocialPreview(link: link, kind: kind, lookup: lookup)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("Your profile belongs to your address, not to a name: it stays the same when you buy, sell or let a name go.")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "person.text.rectangle").foregroundColor(.accentColor)
                    }
                } footer: {
                    Text("Each piece comes from a social profile you link, exactly as that platform shows it, so its moderation applies here too. You can use one account for all three, or mix them.")
                }
                Section {
                    sourceField($avatarIn, .avatar, $avatarLookup)
                } header: { Text("Avatar") } footer: {
                    if avatarIn.isBad(.avatar) { invalidHandleNote }
                }
                Section {
                    sourceField($bannerIn, .banner, $bannerLookup)
                } header: { Text("Banner") } footer: {
                    if bannerIn.isBad(.banner) { invalidHandleNote }
                }
                Section {
                    sourceField($bioIn, .bio, $bioLookup)
                } header: { Text("Bio") } footer: {
                    if bioIn.isBad(.bio) { invalidHandleNote }
                }
                Section {
                    HStack(spacing: 0) {
                        Text(verbatim: "linktr.ee/").foregroundColor(.secondary)
                        TextField("username", text: $linktree)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !linktree.isEmpty {
                            Button {
                                linktree = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear"))
                        }
                    }
                } header: { Text("Links") } footer: {
                    if badLinktree {
                        Text("Enter your Linktree username: letters, numbers, dots, dashes or underscores.").foregroundColor(.red)
                    } else {
                        Text("Add your Linktree to point people to your other accounts and websites.")
                    }
                }
                Section {
                    // The primary name needs the registry: until it launches on this network
                    // (mainnet) there's no name to pick, so the profile saves without one.
                    if KachatNamesService.isLaunched {
                        Picker("Primary name", selection: $primary) {
                            Text("None").tag("")
                            ForEach(activeNames, id: \.self) { n in Text(verbatim: "\(n).kachat").tag(n) }
                        }
                    } else {
                        HStack {
                            Text("Primary name")
                            Spacer()
                            Text("Coming soon").foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text(".kachat Name")
                } footer: {
                    if KachatNamesService.isLaunched {
                        Text("KaChat shows you by your primary name while you own it and it's active; otherwise by your oldest active name, or your address.")
                    } else {
                        Text(".kachat names aren't on mainnet yet. Your avatar, banner, bio and links save now; you can pick a primary name once names launch.")
                    }
                }
                Section {
                    Button {
                        showSave = true
                    } label: {
                        HStack { Spacer(); Text("Save Profile").font(.headline); Spacer() }
                    }
                    // Saves on every network: a profile is a self-send, with no registry behind it.
                    .disabled(!loaded || blocked || !KachatNamesService.profilesEnabled)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if hasUncheckedLinks {
                            Text("Some links couldn't be checked from this phone right now. They're saved as entered, and people's apps load them when they can.")
                        }
                        Text("Saving writes your profile to the chain from your address to itself, for a network fee. Profiles are public.")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        showClear = true
                    } label: {
                        HStack { Spacer(); Text("Clear Profile").font(.headline); Spacer() }
                    }
                    // Same gate as saving: a clear IS a save, of the empty record.
                    .disabled(!loaded || !KachatNamesService.profilesEnabled)
                } footer: {
                    Text("Clearing writes an empty profile to the chain from your address to itself, for a network fee, so KaChat shows nothing for your address again.")
                }
            }
            .sheet(isPresented: $showSave) {
                KachatProfileSaveSheet(title: "Save Profile", confirmTitle: "Save Profile", doneTitle: "Profile saved",
                                       makeProfile: { profile }, onSaved: { dismiss() })
            }
            // The newest record is the whole profile, so the empty record IS "this address has
            // nothing": the indexer and every app show nothing for it from then on.
            .sheet(isPresented: $showClear) {
                KachatProfileSaveSheet(title: "Clear Profile", confirmTitle: "Clear Profile", doneTitle: "Profile cleared",
                                       makeProfile: { KachatNames.Profile() }, onSaved: { dismiss() })
            }
            .onChange(of: avatarLookup) { v in if v == .found { fillEmpty(from: avatarIn) } }
            .onChange(of: bannerLookup) { v in if v == .found { fillEmpty(from: bannerIn) } }
            .onChange(of: bioLookup) { v in if v == .found { fillEmpty(from: bioIn) } }
            .navigationTitle("Edit KaChat Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var invalidHandleNote: some View {
        Text("That doesn't look like a handle on this platform.").foregroundColor(.red)
    }

    private func load() async {
        guard let address = KachatNamesActions.shared.myAddress else { loaded = true; return }
        await registry.refreshIfStale()
        // start from the newest profile, wherever it was saved (another device included)
        await registry.syncOwnProfile(address: address)
        var p = registry.ownProfile(for: address)?.profile
        if p == nil { p = try? await registry.identity(address: address).profile }
        if let p {
            avatarIn = KachatSourceInput(stored: p.avatar, .avatar)
            bannerIn = KachatSourceInput(stored: p.banner, .banner)
            bioIn = KachatSourceInput(stored: p.bio, .bio)
            linktree = KachatNames.Profile.linktreeUsername(p.linktree)
        }
        if let key = KachatNamesRegistry.keyOf(address) {
            activeNames = ((try? await registry.names(owner: key, includeInactive: false)) ?? []).map(\.name)
        }
        if let pn = p?.primaryName, activeNames.contains(pn) { primary = pn }
        loaded = true
    }

}

/// Review before a profile record goes out - what will be saved, the network fee, the main
/// address's balance before and after - the same confirmation every other name action shows.
/// Used by Edit KaChat Profile and by Set as Primary.
struct KachatProfileSaveSheet: View {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    /// The finished-transaction half sheet's headline (a localization key).
    let doneTitle: String
    /// Builds the record to save when the sheet opens (Set as Primary reads your current profile).
    let makeProfile: () async -> KachatNames.Profile
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var profile: KachatNames.Profile?
    @State private var fee: UInt64?
    @State private var quoteError: String?
    @State private var sending = false
    @State private var sendError: String?
    @State private var done: KachatTxDone?
    /// The "not enough funds" popup: the chatting address's QR to fund it. It opens by itself
    /// once per sheet; after that the Fund button under the message opens it (IOS-084).
    @State private var showFunding = false
    @State private var fundingShownOnce = false
    /// The last quote or save failed for lack of funds: the Fund button shows.
    @State private var shortOfFunds = false
    @AppStorage("kachat_profile_privacy_seen") private var privacySeen = false

    private static var notEnoughFundsMessage: String {
        KaspaUnit.label(AppLocalization.string("You don't have enough funds. Please send at least 1 KAS to your chatting address."))
    }

    /// The save can't be paid: the chatting address has no spendable coin, or too little for
    /// the fee - read from the error alone (an unreachable node is not "no funds").
    private func isShortOfFunds(_ error: Error) -> Bool {
        if case let KasiaError.networkError(message) = error, message.localizedCaseInsensitiveContains("insufficient") {
            return true
        }
        return false
    }

    /// Short of funds: the popup the first time, the Fund button after that.
    private func noteShortOfFunds() {
        shortOfFunds = true
        if !fundingShownOnce {
            fundingShownOnce = true
            showFunding = true
        }
    }

    private func source(_ link: String?, _ kind: KachatNames.SocialSource.Kind) -> String {
        guard let s = KachatNames.SocialSource(link: link ?? "", for: kind) else { return AppLocalization.string("None") }
        return "\(s.platform.displayName) · \(s.platform.prefix)\(s.displayHandle)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let profile {
                    Section {
                        LabeledRow(title: "Avatar", value: source(profile.avatar, .avatar))
                        LabeledRow(title: "Banner", value: source(profile.banner, .banner))
                        LabeledRow(title: "Bio", value: source(profile.bio, .bio))
                        LabeledRow(title: "Linktree", value: profile.linktree.map { $0.replacingOccurrences(of: "https://", with: "") } ?? AppLocalization.string("None"))
                        LabeledRow(title: "Primary name", value: profile.primaryName.map { "\($0).kachat" } ?? AppLocalization.string("None"))
                    } header: {
                        Text("Your Profile")
                    }
                }
                Section {
                    if let fee {
                        LabeledRow(title: "Network fee", value: KaspaUnit.amount(fee))
                        if let balance = WalletManager.shared.currentWallet?.balanceSompi {
                            LabeledRow(title: "Chatting address balance", value: KaspaUnit.amount(balance))
                            LabeledRow(title: "Balance after", value: KaspaUnit.amount(balance > fee ? balance - fee : 0), bold: true)
                        }
                    } else if quoteError == nil {
                        HStack { Text("Network fee"); Spacer(); ProgressView() }
                    }
                } footer: {
                    if let quoteError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: quoteError).foregroundColor(.red)
                            if shortOfFunds {
                                Button {
                                    showFunding = true
                                } label: {
                                    Label("Fund", systemImage: "qrcode")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    } else if privacySeen {
                        Text("Saved on chain from your chatting address to itself.")
                    } else {
                        Text("Profiles are public and on chain: anyone can read them, and earlier versions stay readable after you change them.")
                    }
                }
                Section {
                    Button {
                        authorize()
                    } label: {
                        HStack { Spacer(); if sending { ProgressView() } else { Text(confirmTitle).font(.headline) }; Spacer() }
                    }
                    .disabled(fee == nil || profile == nil || sending || done != nil)
                } footer: {
                    if let sendError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: sendError).foregroundColor(.red)
                            if shortOfFunds {
                                Button {
                                    showFunding = true
                                } label: {
                                    Label("Fund", systemImage: "qrcode")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await quote() }
            .sheet(item: $done, onDismiss: { dismiss(); onSaved() }) { KachatTxDoneSheet(done: $0) }
            // Closes by itself once 1 KAS has arrived; either way the fee is worked out again.
            .sheet(isPresented: $showFunding, onDismiss: {
                quoteError = nil
                sendError = nil
                fee = nil
                Task { await quote() }
            }) {
                // closes once any KAS arrives; the fee is then worked out again
                ZeroBalanceFundingSheetView(title: Self.notEnoughFundsMessage)
            }
        }
    }

    private func quote() async {
        let p = await makeProfile()
        profile = p
        do {
            fee = try await KachatNamesActions.shared.profileFee(p)
            shortOfFunds = false
        } catch {
            if isShortOfFunds(error) {
                quoteError = Self.notEnoughFundsMessage
                noteShortOfFunds()
            } else {
                quoteError = error.localizedDescription
            }
        }
    }

    private func authorize() {
        guard let profile else { return }
        DeviceAuth.authenticate(reason: KachatLive.authReason) {
            Task { @MainActor in
                sending = true
                sendError = nil
                do {
                    let tx = try await KachatNamesActions.shared.saveProfile(profile)
                    privacySeen = true
                    done = KachatTxDone(txId: tx, title: doneTitle)
                    Haptics.success()
                } catch {
                    if isShortOfFunds(error) {
                        sendError = Self.notEnoughFundsMessage
                        noteShortOfFunds()
                    } else {
                        sendError = error.localizedDescription
                    }
                }
                sending = false
            }
        }
    }
}

/// "1 year" / "2 years", or on a short clock (testnet) "10 min" / "20 min".
struct KachatYearsText: View {
    let years: Int

    var body: some View {
        if !KachatLive.yearlyPeriods {
            Text(verbatim: KachatLive.periods(Int64(years)))
        } else if years == 1 { Text("1 year") } else { Text("\(years) years") }
    }
}


// MARK: - Opening a name from a notification

/// Where a tapped `.kachat` name notification lands. Kept until the `.kachat` screen is on
/// screen to take it, so a cold start from the notification still opens the name.
@MainActor
enum KachatDeepLink {
    static var pendingName: String?
    /// `kapay://market`: open the Marketplace page.
    static var pendingMarketplace = false
}

/// This wallet's .kachat names that have expired and sit in their grace period, for Profile's
/// banner (`KachatExpiredNamesBanner`): renew before grace ends, or anyone can claim them. A
/// dismissal (the X) is per name and expiry, so a name that expires again brings it back.
@MainActor
final class KachatExpiredNamesModel: ObservableObject {
    @Published private(set) var expired: [KachatNames.NameInfo] = []
    @Published private var dismissed: Set<String> = []

    var visible: [KachatNames.NameInfo] { expired.filter { !dismissed.contains(Self.key($0)) } }

    private static func key(_ n: KachatNames.NameInfo) -> String { "\(n.name)@\(n.expiresAt)" }
    private var storeKey: String? { KachatNamesActions.shared.myAddress.map { "kachatExpiredBannerDismissed.\($0)" } }

    func load() async {
        guard KachatNamesService.isLaunched, let me = KachatNamesActions.shared.myKey, let storeKey else {
            expired = []
            return
        }
        let stored = Set(UserDefaults.standard.stringArray(forKey: storeKey) ?? [])
        if stored != dismissed { dismissed = stored }
        let registry = KachatNamesRegistry.shared
        // Profile's own loads use five minutes too: a shorter window here refreshed in between
        // and restarted every task on the Profile screen keyed on the registry's revision.
        await registry.refreshIfStale(maxAge: 300)
        let grace = registry.graceMs
        let now = KachatNames.nowMs()
        let owned = (try? await registry.names(owner: me, includeInactive: true)) ?? []
        let inGrace = owned.filter { $0.status(graceMs: grace, nowMs: now) == .grace }.sorted { $0.expiresAt < $1.expiresAt }
        // assigned only on a change: each assignment redraws the whole Profile scroll
        if inGrace != expired { expired = inGrace }
    }

    func dismissAll() {
        guard let storeKey else { return }
        dismissed.formUnion(visible.map(Self.key))
        // only names still in grace are worth remembering
        UserDefaults.standard.set(Array(dismissed.intersection(Set(expired.map(Self.key)))), forKey: storeKey)
    }
}

/// Profile's banner while one of this wallet's .kachat names is in its grace period. Tapping it
/// opens the name (renew is there); the X hides it.
struct KachatExpiredNamesBanner: View {
    @ObservedObject var model: KachatExpiredNamesModel
    @ObservedObject private var registry = KachatNamesRegistry.shared

    var body: some View {
        let visible = model.visible
        if let n = visible.first {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(visible.count == 1
                         ? AppLocalization.string("One of your .kachat domains expired")
                         : String(format: AppLocalization.string("%lld of your .kachat domains expired"), visible.count))
                        .font(.subheadline.weight(.semibold))
                    Text(visible.count == 1
                         ? String(format: AppLocalization.string("Renew %@ before its grace period ends on %@ to keep it."),
                                  "\(n.name).kachat", KachatNamesActions.dayString(n.expiresAt + registry.graceMs))
                         : AppLocalization.string("Renew them before their grace periods end to keep them."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { open(n) }
                Button {
                    withAnimation { model.dismissAll() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        }
    }

    private func open(_ n: KachatNames.NameInfo) {
        KachatDeepLink.pendingName = n.name
        PendingTabRoute.pending = .kachatNames
        NotificationCenter.default.post(name: .openKachatName, object: nil)
    }
}

/// A name to open, by name: the destination looks it up itself.
struct KachatNameRoute: Hashable, Identifiable {
    let name: String
    var id: String { name }
}

/// The name a notification pointed at: its live detail once looked up, or - when it was
/// released or reclaimed since - the name as free to claim.
struct KachatNameRouteView: View {
    let name: String

    private enum Found {
        case registered(KachatNames.NameInfo)
        case free(KachatNames.GapInfo?)
        case failed
    }

    @State private var found: Found?
    @State private var claimTarget: KachatClaimTarget?

    var body: some View {
        Group {
            switch found {
            case .registered(let info):
                KachatLiveNameDetail(info: info)
            case .free(let gap):
                freeName(gap)
            case .failed:
                VStack(spacing: 12) {
                    Text(verbatim: "\(name).kachat").font(.headline)
                    Text("Couldn't look that name up.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $claimTarget) { KachatClaimSheet(target: $0) }
    }

    private func freeName(_ gap: KachatNames.GapInfo?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(height: 110)
                        .overlay(
                            Text(verbatim: "\(name).kachat")
                                .font(.title2.weight(.heavy))
                                .foregroundColor(.black)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .padding(.horizontal, 16)
                        )
                    HStack {
                        Text("Free to claim").font(.subheadline).foregroundColor(.secondary)
                        Spacer()
                        Text("Available")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                    }
                }
                .padding(14)
                .kachatGlass()
                Button {
                    if let gap { claimTarget = KachatClaimTarget(name: name, gap: gap) }
                } label: {
                    Label("Claim", systemImage: "at").font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(gap == nil)
            }
            .padding()
        }
    }

    private func load() async {
        found = nil
        do {
            switch try await KachatNamesRegistry.shared.claimLookup(name) {
            case .registered(let info): found = .registered(info)
            case .free(_, let gap): found = .free(gap)
            }
        } catch {
            found = .failed
        }
    }
}

/// `navigationDestination(item:)` on iOS 17, the `isPresented:` form on iOS 16 (as KaChat's chat list
/// does - see ChatDetailNavigationDestination).
struct KachatNameRouteDestination: ViewModifier {
    @Binding var route: KachatNameRoute?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $route) { KachatNameRouteView(name: $0.name) }
        } else {
            content.navigationDestination(isPresented: Binding(
                get: { route != nil },
                set: { if !$0 { route = nil } }
            )) {
                if let route { KachatNameRouteView(name: route.name) }
            }
        }
    }
}

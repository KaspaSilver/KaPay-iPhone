import SwiftUI
import UIKit

/// The ".kachat" wordmark as a template image - the dock item and
/// Dock draw it the way `ChessTabIcon` draws the chess pieces, tinted like any SF Symbol.
enum KachatTabIcon {
    private static var cache: [String: UIImage] = [:]

    /// A template image `side` points tall; the word is wider than it is tall. `fontScale` is the
    /// word's size as a share of `side` - the dock passes a smaller one, so the item is no wider
    /// than the tabs beside it.
    static func image(side: CGFloat, fontScale: CGFloat = 0.62) -> UIImage {
        let key = "\(Int(side.rounded()))-\(Int((fontScale * 100).rounded()))"
        if let cached = cache[key] { return cached }
        let font = UIFont.systemFont(ofSize: side * fontScale, weight: .heavy)
        let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        let text = NSAttributedString(string: ".kachat", attributes: [.font: rounded, .foregroundColor: UIColor.black])
        let measured = text.size()
        let width = max(measured.width, side)
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: width, height: side)).image { _ in
            text.draw(at: CGPoint(x: (width - measured.width) / 2, y: (side - measured.height) / 2))
        }
        let template = rendered.withRenderingMode(.alwaysTemplate)
        cache[key] = template
        return template
    }

    /// KaPay's dock icon for .kachat: a name tag with an "@" cut out of it, filled like
    /// the SF Symbols beside it. A template image `side` points square.
    static func domainsImage(side: CGFloat) -> UIImage {
        let key = "domains-\(Int(side.rounded()))"
        if let cached = cache[key] { return cached }
        let u = side / 24
        let mid = 12 * u
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let ctx = context.cgContext
            // Tag: a rounded body on the right, a point on the left.
            let top = 3.5 * u, bottom = 20.5 * u, left = 0.5 * u, shoulder = 7 * u, right = 23.5 * u, r = 3.5 * u
            let tag = CGMutablePath()
            tag.move(to: CGPoint(x: left, y: mid))
            tag.addLine(to: CGPoint(x: shoulder, y: top))
            tag.addLine(to: CGPoint(x: right - r, y: top))
            tag.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top + r), radius: r)
            tag.addLine(to: CGPoint(x: right, y: bottom - r))
            tag.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right - r, y: bottom), radius: r)
            tag.addLine(to: CGPoint(x: shoulder, y: bottom))
            tag.closeSubpath()
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.addPath(tag)
            ctx.fillPath()
            // The hole it hangs by, and the "@", both cut out of the body.
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: 4.4 * u, y: mid - 1.5 * u, width: 3 * u, height: 3 * u))
            let font = UIFont.systemFont(ofSize: 14 * u, weight: .heavy)
            let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
            let at = NSAttributedString(string: "@", attributes: [.font: rounded, .foregroundColor: UIColor.black])
            let size = at.size()
            at.draw(at: CGPoint(x: 15.5 * u - size.width / 2, y: mid - size.height / 2))
        }
        let template = rendered.withRenderingMode(.alwaysTemplate)
        cache[key] = template
        return template
    }

    static func view(side: CGFloat) -> some View {
        Image(uiImage: image(side: side))
            .renderingMode(.template)
            .foregroundStyle(Color.accentColor)
    }
}

/// The .kachat tab: the marketplace for KaChat's own names - claim one, list it, buy one,
/// peer to peer and trustless (the name and the payment settle together on chain, no one holds
/// either in between).
///
/// On mainnet it is UI only: search answers "not live yet", listings and activity show
/// placeholder skeletons, and every action is disabled with "Coming soon". No invented names or
/// prices anywhere - the skeletons are redacted shapes, so nothing here can be mistaken for a
/// real listing.
///
/// On TESTNET (testnet-10, with the bundled registry manifest verified) it is live
/// (`KachatNamesLiveViews.swift`): search shows real availability and the price, Claim registers,
/// the pages read the registry (`KachatNamesRegistry`), and registrations in flight show their
/// progress.
///
/// The screen is the logo and a numbered card per page: Marketplace, Available, Expired, Activity.
/// A card opens its page; only the Marketplace has the name search.
struct KachatMarketView: View {
    /// Names for sale, names in their grace period (counting down to release), expired names
    /// anyone may claim, and everything that happens in the registry.
    /// Your own names (and the offers you made) live in Profile > Your Domains.
    private enum Page: String, CaseIterable, Identifiable {
        case market, available, expired, activity

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .market: return "tag"
            case .available: return "checkmark.seal"
            case .expired: return "hourglass"
            case .activity: return "clock.arrow.circlepath"
            }
        }

        var title: String {
            switch self {
            case .market: return "Marketplace"
            case .expired: return "Expired"
            case .available: return "Available"
            case .activity: return "Activity"
            }
        }
    }

    @State private var showHowItWorks = false
    @StateObject private var live = KachatHubModel()
    @State private var claimTarget: KachatClaimTarget?
    /// A name opened from a notification (`KachatDeepLink`).
    @State private var nameRoute: KachatNameRoute?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    // Registrations in flight: the claims button in the toolbar (KachatClaimsButton).
                    pageCards
                }
                .padding(.bottom, 28)
            }
            // Pull to refresh on testnet only; mainnet has nothing to refresh.
            .modifier(KachatRefreshable(enabled: live.isLive) { await live.refresh() })
            .task { await live.start() }
            .onReceive(KachatNamesRegistry.shared.$revision.dropFirst()) { _ in
                guard live.isLive else { return }
                Task { await live.reload() }
            }
            .modifier(KachatNameRouteDestination(route: $nameRoute))
            // A notification that opened this screen fresh (a cold start, or .kachat not the open
            // tab) leaves its name pending: open it once the screen is up. Pushing in
            // the same update as the stack's first appearance came up as a blank screen.
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { takePendingName() }
            }
            // after the tab switch to this screen has landed: a push onto a stack that isn't on
            // screen yet came up blank
            .onReceive(NotificationCenter.default.publisher(for: .openKachatName)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { takePendingName() }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(".kachat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                // the marketplace buys with the chatting address, like every other screen pays
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        // names being claimed: shown only while there are some
                        KachatClaimsButton()
                        Button {
                            showHowItWorks = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .accessibilityLabel(Text("How it works"))
                    }
                }
            }
            .sheet(isPresented: $showHowItWorks) { howItWorksSheet }
        }
        // on the stack, so the Marketplace page it opens from can be pushed
        .sheet(item: $claimTarget) { target in
            KachatClaimSheet(target: target)
        }
    }

    // MARK: - Cards and pages

    private var pageCards: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(Page.allCases) { page in
                NavigationLink {
                    pageScreen(page)
                } label: {
                    KachatHubCard(title: page.title, icon: page.icon, count: count(of: page))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    /// How many live on a page; nil until the registry has answered.
    private func count(of page: Page) -> Int? {
        guard live.isLive, live.loaded, live.loadError == nil else { return nil }
        switch page {
        case .market: return live.listings.count
        case .available: return live.lapsed.count
        case .expired: return live.grace.count
        case .activity: return live.activity.count
        }
    }

    private func pageScreen(_ page: Page) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                if page == .market {
                    KachatNameSearchCard(live: live) { claimTarget = $0 }
                }
                pageContent(page)
            }
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .modifier(KachatRefreshable(enabled: live.isLive) { await live.refresh() })
        .background(Color(.systemGroupedBackground))
        .navigationTitle(LocalizedStringKey(page.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { KachatClaimsButton() }
        }
    }

    /// Live, or not launched here (mainnet): the same pages - empty on mainnet. The placeholder
    /// pages remain only for a testnet registry that is setting up.
    @ViewBuilder
    private func pageContent(_ page: Page) -> some View {
        if live.isLive || !KachatNamesService.isLaunched {
            switch page {
            case .market: KachatLiveMarketPage(model: live)
            case .expired: KachatLiveExpiredPage(model: live)
            case .available: KachatLiveAvailablePage(model: live)
            case .activity: KachatLiveActivityPage(model: live)
            }
        } else {
            switch page {
            case .market: marketPage
            case .expired: expiredPage
            case .available: availablePage
            case .activity: activityPage
            }
        }
    }

    /// Opens the name a tapped notification pointed at (testnet only, where names are live).
    /// One name screen at a time: the same name again leaves the open one as it is, and another
    /// name replaces it (closed first, then opened) instead of piling up on the stack.
    private func takePendingName() {
        guard let name = KachatDeepLink.pendingName, KachatLive.isEnabled else { return }
        KachatDeepLink.pendingName = nil
        let route = KachatNameRoute(name: name)
        guard let open = nameRoute else {
            nameRoute = route
            return
        }
        guard open != route else { return }
        nameRoute = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { nameRoute = route }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 8) {
            KachatTabIcon.view(side: 56)
            if live.isLive {
                KachatTestnetBadge()
            } else if KachatLive.isEnabled, live.upgrading {
                // the bundled manifest is for the previous registry: a calm "setting up", no error
                HStack(spacing: 6) {
                    KachatTestnetBadge()
                    settingUpPill
                }
                Text("The .kachat registry is being upgraded. Names open here again once the new registry is live.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                comingSoonPill
                if KachatLive.isEnabled, live.ready == false, let error = live.setupError {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .padding(.top, 8)
    }

    private var settingUpPill: some View {
        Label("Setting up", systemImage: "hammer")
            .font(.caption.weight(.bold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }

    private var comingSoonPill: some View {
        Text("Coming soon")
            .font(.caption.weight(.bold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }

    // MARK: - Marketplace

    private var marketPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("For sale", detail: nil)
            KachatNameGrid {
                ForEach(0..<4, id: \.self) { _ in
                    NavigationLink { KachatListingDetailView() } label: { tilePlaceholder(footer: "000 \(KaspaUnit.symbol)") }
                        .buttonStyle(.plain)
                }
            }

            Button {} label: {
                Label("List a Name for Sale", systemImage: "tag")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .padding(.horizontal, 16)

            Text("Listings appear here once .kachat names launch.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    private func sectionHeader(_ title: LocalizedStringKey, detail: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    /// A name tile's shape, redacted: no invented name or price.
    private func tilePlaceholder(footer: String) -> some View {
        KachatNameTile(name: "somename") {
            Text(verbatim: footer)
                .font(.subheadline.weight(.semibold))
        }
        .redacted(reason: .placeholder)
    }

    // MARK: - Expired

    private var expiredPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Expired", detail: nil)
            KachatNameGrid {
                ForEach(0..<2, id: \.self) { _ in tilePlaceholder(footer: "00:00") }
            }
            Text("Names in their grace period appear here once .kachat names launch.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    // MARK: - Available

    private var availablePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Available", detail: nil)
            KachatNameGrid {
                ForEach(0..<2, id: \.self) { _ in tilePlaceholder(footer: "000 \(KaspaUnit.symbol)") }
            }
            Text("Expired names appear here once .kachat names launch.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    // MARK: - Activity

    private var activityPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recent activity", detail: "Every claim, renewal, listing, sale, offer, transfer and reclaim across the registry.")
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: ["tag", "cart", "at", "arrow.left.arrow.right"][index])
                            .foregroundColor(.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("somename.kachat sold")
                                .font(.subheadline.weight(.semibold))
                            Text("2h ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .redacted(reason: .placeholder)
                        Spacer()
                        Text(verbatim: "000 \(KaspaUnit.symbol)")
                            .font(.subheadline)
                            .redacted(reason: .placeholder)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    if index < 3 { Divider().padding(.leading, 56) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal, 16)
            Text("Activity appears here once .kachat names launch.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    // MARK: - How it works

    private var howItWorksSheet: some View {
        NavigationStack {
            List {
                Section {
                    howItWorksRow(
                        icon: "at.badge.plus",
                        title: "Claim",
                        detail: "Pick a free name and register it on Kaspa. It's yours: your name, your profile, your link."
                    )
                    howItWorksRow(
                        icon: "tag",
                        title: "List",
                        detail: "Set a price. The name waits in an on-chain covenant, not with KaChat or anyone else, until someone buys it or you take it back."
                    )
                    howItWorksRow(
                        icon: "cart",
                        title: "Buy",
                        detail: "Pay the listed price. The payment reaches the seller and the name reaches you in the same transaction - both happen, or neither does."
                    )
                    howItWorksRow(
                        icon: "hand.raised",
                        title: "Offer",
                        detail: LocalizedStringKey(KaspaUnit.label(AppLocalization.string("Name your own price. Your KAS waits on chain until the seller accepts, you withdraw the offer, or it expires - and you can message the seller first.")))
                    )
                    howItWorksRow(
                        icon: "checkmark.shield",
                        title: "Trustless",
                        detail: "No middleman and no escrow account: Kaspa's own rules enforce every sale."
                    )
                } footer: {
                    if live.isLive, KachatNamesService.networkName == "mainnet" {
                        Text("Live on Mainnet: names, prices and payments here are real KAS.")
                    } else if live.isLive {
                        Text("Live on Testnet: names, prices and payments here use TKAS on testnet-10. Mainnet names are live on Mainnet.")
                    } else {
                        Text("Nothing here is live yet.")
                    }
                }
            }
            .navigationTitle("How .kachat works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showHowItWorks = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func howItWorksRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Listing

/// One listing in the .kachat marketplace: the name and its price, the three ways to act on it
/// - buy it at the listed price, make an offer, or message the seller first - the offers already
/// on it, and its history.
///
/// UI only, like the rest of the marketplace: no listing exists yet, so the name, price, seller
/// and offers are redacted shapes and every final action is disabled. Buy and Make an Offer still
/// open their sheets so the flow can be looked at. `sellerAddress` is where a real listing hands
/// in its seller.
struct KachatListingDetailView: View {
    var sellerAddress: String? = nil
    /// A real name (testnet only): the live detail with its actions instead of the mockup.
    var info: KachatNames.NameInfo? = nil

    @State private var showBuy = false
    @State private var showOffer = false

    var body: some View {
        if let info, KachatLive.isEnabled {
            KachatLiveNameDetail(info: info)
        } else {
            mockup
        }
    }

    private var mockup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                nameCard
                actionButtons
                sellerCard
                offersSection
                historySection
                notes
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Listing")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBuy) { KachatBuySheet() }
        .sheet(isPresented: $showOffer) { KachatOfferSheet() }
    }

    private var nameCard: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor)
                .frame(height: 120)
                .overlay(
                    Text(verbatim: "name.kachat")
                        .font(.title2.weight(.heavy))
                        .foregroundColor(.black)
                        .redacted(reason: .placeholder)
                )
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Price")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(verbatim: "000 \(KaspaUnit.symbol)")
                        .font(.title3.weight(.bold))
                        .redacted(reason: .placeholder)
                }
                Spacer()
                Text(verbatim: "listed 1h ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .redacted(reason: .placeholder)
            }
            KachatComingSoonPill()
        }
        .padding(14)
        .background(KachatCardBackground())
        .padding(.horizontal, 16)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button { showBuy = true } label: {
                Label("Buy Now", systemImage: "cart")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Button { showOffer = true } label: {
                Label("Make an Offer", systemImage: "hand.raised")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
    }

    private var sellerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatSectionHeader(title: "Seller", detail: nil)
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: sellerAddress.map(KaspaAddress.shortAlias) ?? "kaspa:xxxx....xxxx")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .redacted(reason: sellerAddress == nil ? .placeholder : [])
                }
                Spacer(minLength: 8)
            }
            .padding(14)
            .background(KachatCardBackground())
            .padding(.horizontal, 16)
        }
    }

    private var offersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatSectionHeader(title: "Offers", detail: "Open offers on this name, highest first. The seller can accept any of them.")
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "kaspa:xxxx....xxxx")
                                .font(.subheadline.weight(.semibold))
                            Text(verbatim: "expires in 2d")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .redacted(reason: .placeholder)
                        Spacer()
                        Text(verbatim: "000 \(KaspaUnit.symbol)")
                            .font(.subheadline.weight(.semibold))
                            .redacted(reason: .placeholder)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    if index < 2 { Divider().padding(.leading, 50) }
                }
            }
            .background(KachatCardBackground())
            .padding(.horizontal, 16)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            KachatSectionHeader(title: "History", detail: nil)
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: ["tag", "arrow.left.arrow.right", "at.badge.plus"][index])
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text(verbatim: "listed by kaspa:xxxx")
                            .font(.subheadline)
                            .redacted(reason: .placeholder)
                        Spacer()
                        Text(verbatim: "3d ago")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .redacted(reason: .placeholder)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    if index < 2 { Divider().padding(.leading, 50) }
                }
            }
            .background(KachatCardBackground())
            .padding(.horizontal, 16)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Buying pays the seller and moves the name to you in one transaction.", systemImage: "cart")
            Label(KaspaUnit.label(AppLocalization.string("An offer locks your KAS on chain until the seller accepts it, you withdraw it, or it expires.")), systemImage: "lock")
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.horizontal, 20)
    }
}

/// Buy at the listed price: what you pay, then one confirmation. Opens full height with Cancel
/// top left, the same as the offer sheet. Disabled until names launch.
struct KachatBuySheet: View {
    /// A real listing (testnet only): the live purchase instead of the mockup.
    var info: KachatNames.NameInfo? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let info, KachatLive.isEnabled {
            KachatLiveBuySheet(info: info)
        } else {
            mockup
        }
    }

    private var mockup: some View {
        NavigationStack {
            Form {
                Section {
                    summaryRow("Name", value: "name.kachat")
                    summaryRow("Price", value: "000 \(KaspaUnit.symbol)")
                    summaryRow("Network fee", value: "0.0000 \(KaspaUnit.symbol)")
                    summaryRow("Total", value: "000 \(KaspaUnit.symbol)", bold: true)
                } footer: {
                    Text("The payment reaches the seller and the name reaches you in the same transaction - both happen, or neither does.")
                }

                Section {
                    Button {} label: {
                        Text("Confirm Purchase")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(true)
                } footer: {
                    Text("Buying opens when .kachat names launch.")
                }
            }
            .navigationTitle("Buy Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func summaryRow(_ title: LocalizedStringKey, value: String, bold: Bool = false) -> some View {
        HStack {
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(verbatim: value)
                .fontWeight(bold ? .semibold : .regular)
                .redacted(reason: .placeholder)
        }
    }
}

/// Make an offer: an amount, how long it stands, and what happens to the KAS meanwhile. The
/// amount and expiry can be set so the form can be tried; sending is disabled until names launch.
struct KachatOfferSheet: View {
    /// A real name (testnet only): the live offer instead of the mockup.
    var info: KachatNames.NameInfo? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var expiry: Expiry = .threeDays

    private enum Expiry: String, CaseIterable, Hashable {
        // up to 7 days, the app's cap on offers (KachatNamesActions.maxOfferDays)
        case oneDay, threeDays, sevenDays

        var title: LocalizedStringKey {
            switch self {
            case .oneDay: return "1 Day"
            case .threeDays: return "3 Days"
            case .sevenDays: return "7 Days"
            }
        }
    }

    var body: some View {
        if let info, KachatLive.isEnabled {
            KachatLiveOfferSheet(name: info.name, info: info)
        } else {
            mockup
        }
    }

    private var mockup: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(verbatim: "name.kachat").redacted(reason: .placeholder)
                    }
                    HStack {
                        Text("Listed at")
                        Spacer()
                        Text(verbatim: "000 \(KaspaUnit.symbol)").redacted(reason: .placeholder)
                    }
                }

                Section {
                    HStack {
                        TextField("0", text: $amount.groupedAmount)
                            .keyboardType(.decimalPad)
                            .font(.title3.weight(.semibold))
                        Text(verbatim: KaspaUnit.symbol)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Your offer")
                } footer: {
                    KaspaUnit.text("Your KAS stays locked on chain until the owner accepts or declines, you withdraw the offer, or it expires - then anyone can send it back to you.")
                }

                Section {
                    Picker("Expires", selection: $expiry) {
                        ForEach(Expiry.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Expires after")
                }

                Section {
                    Button {} label: {
                        Text("Send Offer")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(true)
                } footer: {
                    Text("Offers open when .kachat names launch.")
                }
            }
            .navigationTitle("Make an Offer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Shared pieces

private struct KachatRefreshable: ViewModifier {
    let enabled: Bool
    let action: () async -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.refreshable { await action() }
        } else {
            content
        }
    }
}

private struct KachatSectionHeader: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct KachatCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

private struct KachatComingSoonPill: View {
    var body: some View {
        Text("Coming soon")
            .font(.caption.weight(.bold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

// MARK: - An address's .kachat names

/// The ".kachat" tab of every screen that shows an address's history - Manage Addresses,
/// Cold Storage and the chatting address: the .kachat names that address holds. It replaced the
/// KNS Domains tab (5.2), and is empty until .kachat names launch.
/// The Domains tab of an address screen (the chatting address, a spending address, a KasSigner
/// address): one card per name service - .kachat, .k, .kaspa, .kas - each with how many names
/// this address holds there; tap one to see them. Every service is asked at once, for this
/// address only (Your Domains' own lists are left alone).
struct AddressDomainsTab: View {
    let address: String

    /// nil while that service's answer is on the way; a failed lookup is `failed`.
    @State private var counts: [NameServiceTLD: Int] = [:]
    @State private var names: [NameServiceTLD: [String]] = [:]
    @State private var failed: Set<NameServiceTLD> = []

    /// The order the cards are listed in.
    static let order: [NameServiceTLD] = [.kachat, .k, .kaspa, .kas]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Self.order, id: \.self) { tld in
                    NavigationLink {
                        destination(tld)
                    } label: {
                        card(tld)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .refreshable { await load() }
        .task(id: address) { await load() }
    }

    private func card(_ tld: NameServiceTLD) -> some View {
        HStack(spacing: 14) {
            // the same globe on every card: the suffix beside it says which service it is
            Image(systemName: "globe")
                .font(.scaled(size: 22, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 48, height: 48)
            .background(Circle().fill(Color.accentColor.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: tld.suffix)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(verbatim: tld.serviceName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            countLabel(tld)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func countLabel(_ tld: NameServiceTLD) -> some View {
        if let count = counts[tld] {
            Text(verbatim: "\(count)")
                .font(.subheadline.weight(.bold))
                .foregroundColor(count > 0 ? .black : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(count > 0 ? Color.accentColor : Color.secondary.opacity(0.15)))
                .accessibilityLabel(Text(count == 1 ? "1 domain" : "\(count) domains"))
        } else if failed.contains(tld) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
                .accessibilityLabel(Text("Couldn't load"))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func destination(_ tld: NameServiceTLD) -> some View {
        if tld == .kachat {
            // the .kachat cards and their detail screens, as before
            KachatAddressDomainsList(address: address)
                .navigationTitle(".kachat")
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    let list = names[tld] ?? []
                    if list.isEmpty {
                        Text(failed.contains(tld)
                             ? "Couldn't reach \(tld.serviceName). Pull down to try again."
                             : "No \(tld.suffix) names on this address.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(list, id: \.self) { name in
                            DomainNameCardView(title: name)
                        }
                    }
                }
                .padding()
            }
            .refreshable { await load() }
            .navigationTitle(Text(verbatim: tld.suffix))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Every service at once, for this address.
    private func load() async {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let network = AppSettings.load().networkType
        async let kachat = NameServicesClient.shared.kachatNames(of: [address])
        async let services = NameServicesClient.shared.ownedNamesByService(of: address)
        async let kns = KNSService.shared.fetchInfo(for: address, network: network)

        let kachatNames = (await kachat)[address] ?? []
        set(.kachat, kachatNames.map(\.display))

        let byService = await services
        for tld in [NameServiceTLD.k, .kaspa] {
            if let list = byService[tld] { set(tld, list.map(\.display)) } else { failed.insert(tld) }
        }

        if let info = await kns {
            set(.kas, info.allDomains.map(\.fullName))
        } else {
            failed.insert(.kas)
        }
    }

    private func set(_ tld: NameServiceTLD, _ list: [String]) {
        names[tld] = list
        counts[tld] = list.count
        failed.remove(tld)
    }
}

struct KachatAddressDomainsList: View {
    /// The address whose names to show. On testnet (live registry) the list is that address's
    /// own .kachat names; nil, or mainnet, shows the "coming" note.
    var address: String? = nil

    var body: some View {
        if let address, KachatNamesService.isEnabled {
            KachatAddressLiveNamesList(address: address)
        } else {
            comingNote
        }
    }

    private var comingNote: some View {
        List {
            VStack(spacing: 10) {
                KachatTabIcon.view(side: 40)
                Text("No .kachat names on this address")
                    .font(.headline)
                Text("Names this address claims or buys show here once .kachat names launch.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
    }
}

/// One address's .kachat names on testnet - Manage Addresses (spending), the chatting address and
/// KasSigner each show their own address's names in its .kachat tab. Same cards and detail screen
/// as Your Domains > .kachat. Names on an address this wallet can't sign for (a KasSigner address)
/// open read-only: their actions need that address's key.
struct KachatAddressLiveNamesList: View {
    let address: String
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @ObservedObject private var service = KachatNamesService.shared
    @State private var names: [KachatNames.NameInfo] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if !loaded {
                    ProgressView().padding(.vertical, 24)
                } else if service.registryUpgrading || names.isEmpty {
                    VStack(spacing: 10) {
                        KachatTabIcon.view(side: 40)
                        Text("No .kachat names on this address")
                            .font(.headline)
                        Text("Names this address owns show here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(names) { n in
                        NavigationLink {
                            KachatListingDetailView(info: n)
                        } label: {
                            DomainNameCardView(title: n.display, badge: KachatLiveDomainsTab.badge(for: n, graceMs: registry.graceMs))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .refreshable { await registry.refresh() }
        .task(id: "\(address)|\(registry.revision)") { await load() }
    }

    private func load() async {
        guard let key = KachatNamesRegistry.keyOf(address) else { loaded = true; return }
        if registry.refreshedAt == nil { await registry.refresh() }
        // an expired name past grace isn't theirs any more: it's available to anyone
        names = (try? await registry.heldNames(owner: key)) ?? []
        loaded = true
    }
}

/// One page's card on the .kachat screen: what it is and how many live there.
private struct KachatHubCard: View {
    let title: String
    let icon: String
    /// nil until the registry has answered.
    let count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.title3.weight(.medium))
                    .foregroundColor(.accentColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            Text(count.map { "\($0)" } ?? "-")
                .font(.title.weight(.bold).monospacedDigit())
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(LocalizedStringKey(title))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kachatGlass()
        .contentShape(Rectangle())
    }
}

/// The Marketplace's search: "Find a name", and whether it's free or taken.
private struct KachatNameSearchCard: View {
    @ObservedObject var live: KachatHubModel
    let onClaim: (KachatClaimTarget) -> Void
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Find a name", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(".kachat")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))

            let typed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !typed.isEmpty && live.isLive {
                KachatLiveSearchResult(model: live, typed: typed) { onClaim($0) }
            } else if !typed.isEmpty {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(typed).kachat")
                            .font(.headline)
                            .lineLimit(1)
                        Text("Registration isn't open yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Claim") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            }
        }
        .padding(.horizontal, 16)
    }
}

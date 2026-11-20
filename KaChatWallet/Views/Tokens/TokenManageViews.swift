import SwiftUI
import WebKit

// Managing a token, the way Manage Addresses manages Kaspa (owner's design, 2026-11-19): the
// addresses holding it, each with its own page (its history of just that token, Receive and
// Send), and a floating options button at the bottom right. Swapping KAS and kUSDT and adding to
// KasPool aren't KaPay screens: they happen on Trestly's own site, opened inside KaPay and connected
// to the address you choose (`TrestlyBrowserView`). Nothing bridges or redeems from KaPay.

// MARK: - Manage kUSDT

/// "Manage kUSDT": the total, then every address holding it (the Chatting Address and regular
/// spending addresses), each opening `TokenAddressView`, then what the token is. The floating
/// button at the bottom right opens its actions: Trestly's site, and a fresh address to receive on.
struct TokenManageView: View {
    let token: WalletToken
    @ObservedObject private var tokens = TokenWallet.shared
    @EnvironmentObject private var walletManager: WalletManager

    @State private var showActions = false
    /// What the actions sheet picked, opened once it has finished closing.
    @State private var afterActions: (() -> Void)?
    /// The "Bridged by Trestly" pill under the balance: the details, in a sheet.
    @State private var showAbout = false
    @State private var showVisibility = false
    /// The ⋮ on an address row: its own actions (as Manage Addresses has for each address).
    @State private var rowActionsTarget: TokenHolding?
    @State private var renameTarget: TokenHolding?
    @State private var renameText = ""
    /// Spending slots Manage Addresses knows as used (any history, or KAS on them now), for each
    /// row's Used / Unused.
    @State private var usedSpendingIndices: Set<Int> = []
    @State private var qrTarget: TokenHolding?
    /// Combine Coins from a row's ⋮.
    @State private var combineTarget: TokenHolding?
    /// Send to Chatting Address from a row's ⋮: that address's kUSDT, the Chatting Address filled in.
    @State private var sendToChattingTarget: TokenHolding?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var isGenerating = false
    /// Discover kUSDT Addresses: it belongs to this screen, so closing the sheet doesn't stop it.
    @State private var isDiscovering = false
    @State private var discoveryChecking = 0
    @State private var discoveryFound = 0
    @State private var discoverySummary: String?

    var body: some View {
        List {
            summary
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            let rows = tokens.listedHoldings(of: token)
            let hiddenCount = tokens.holdings(of: token).filter { !tokens.isListed($0, of: token) }.count
            if rows.isEmpty && hiddenCount == 0 {
                emptyState
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(rows) { holding in
                    addressRow(holding)
                        .padding(.vertical, 6)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if hiddenCount > 0 {
                    Button {
                        showVisibility = true
                    } label: {
                        Text(verbatim: String(format: AppLocalization.string("%d hidden: they still count in the total."), hiddenCount))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

        }
        .listStyle(.plain)
        // a pull is Discover kUSDT Addresses: every address to 20 past the last, revealing any holding some
        .refreshable { _ = await tokens.discoverHoldings(of: token) { _, _ in } }
        .task { await tokens.refreshIfStale() }
        // Room to scroll the last row out from under the floating button.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 72)
        }
        .overlay(alignment: .bottomTrailing) {
            actionsButton
        }
        .navigationTitle(Text(verbatim: String(format: AppLocalization.string("Manage %@"), token.symbol)))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showActions, onDismiss: {
            let next = afterActions
            afterActions = nil
            next?()
        }) {
            // Trestly opens from the Wallet tab's Swap Stablecoins now (owner's call, 2026-11-20)
            actionsSheet
                .fittedSheetDetents(360)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showVisibility) {
            TokenAddressVisibilityView(token: token)
        }
        .sheet(item: $rowActionsTarget) { holding in
            rowActionsSheet(holding)
                .fittedSheetDetents(holding.coins > 1 ? 520 : 440)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $qrTarget) { holding in
            TokenReceiveSheet(token: token, chattingAddress: "", fixedHolding: holding)
        }
        .sheet(item: $combineTarget) { holding in
            TokenCombineView(token: token, holding: holding)
        }
        .sheet(item: $sendToChattingTarget) { holding in
            TokenSendView(token: token, startFrom: holding,
                          prefillRecipient: WalletManager.shared.currentWallet?.publicAddress,
                          prefillName: AppLocalization.string("Chatting Address"))
        }
        .alert("Rename Address", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Label", text: $renameText)
            Button("Save") {
                if let index = renameTarget?.spendingIndex {
                    WalletManager.shared.setSpendingAddressLabel(index: index, label: renameText)
                    tokens.objectWillChange.send()
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Give this address a label to help you recognize it.")
        }
        .toast(message: toastMessage)
        .task {
            // the snapshot first, then the live list (it carries what Manage Addresses has probed)
            usedSpendingIndices = Self.usedIndices(walletManager.cachedSpendingAddressList())
            usedSpendingIndices.formUnion(Self.usedIndices(await walletManager.getSpendingAddressList()))
        }
        .sheet(isPresented: $showAbout) {
            TokenAboutSheet(token: token)
        }
    }

    private var summary: some View {
        let total = tokens.balance(of: token)
        // the same card as Manage Addresses' total and an address's own page
        return AddressBalanceCard(
            label: AppLocalization.string("Total Balance"),
            amount: total.map { TokenAmount.amount($0, token: token) } ?? "--",
            detail: total.flatMap { TokenAmount.dollars($0, token: token) }
        ) {
            TokenSampleBadge()
                .padding(.top, 4)
            Button {
                Haptics.impact(.light)
                showAbout = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "building.columns")
                        .font(.caption2.weight(.semibold))
                    Text(verbatim: String(format: AppLocalization.string("Bridged by %@"), token.issuer))
                    Image(systemName: "info.circle")
                        .font(.caption2.weight(.semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            if let error = tokens.lastError {
                Label(String(format: AppLocalization.string("Couldn't check %@ just now: %@ Pull down to try again."), token.symbol, error),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } else if tokens.isRefreshing && total == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: String(format: AppLocalization.string("Checking your %@..."), token.symbol))
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            TokenIcon(token: token, size: 48)
            Text(verbatim: String(format: AppLocalization.string("No %@ Yet"), token.symbol))
                .font(.headline)
            Text("Receive it on a fresh address, or buy it with Swap Stablecoins on the Wallet tab.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }

    private static func usedIndices(_ entries: [SpendingAddressEntry]) -> Set<Int> {
        Set(entries.filter { $0.everUsed || $0.balanceSompi > 0 }.map(\.index))
    }

    /// Used, as Manage Addresses says it (owner's call, 2026-11-20): the Chatting Address always;
    /// another address once it holds or has held kUSDT on this phone, or has any Kaspa history.
    private func isUsed(_ holding: TokenHolding) -> Bool {
        guard let index = holding.spendingIndex else { return true }
        return holding.units > 0 || holding.coins > 0 || usedSpendingIndices.contains(index)
            || !tokens.activity(of: token, at: holding).isEmpty
    }

    /// One address holding the token, as Manage Addresses draws a row: its name, the address, the
    /// amount, the KAS held with it, and Used or Unused.
    private func addressRow(_ holding: TokenHolding) -> some View {
        ZStack {
            NavigationLink {
                TokenAddressView(token: token, holding: holding)
            } label: {
                EmptyView()
            }
            .opacity(0)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(verbatim: holding.label)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        Image(systemName: holding.isChatting ? "bubble.left.and.bubble.right.fill" : "eye.slash.fill")
                            .font(.caption2)
                            .foregroundColor(holding.isChatting ? .accentColor : .green)
                    }
                    Text(verbatim: "\(holding.address.prefix(14))...\(holding.address.suffix(6))")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.primary)
                    Text(verbatim: TokenAmount.amount(holding.units, token: token))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(verbatim: String(format: AppLocalization.string("%@ held with it"),
                                          KaspaUnit.amount(UInt64(holding.coins) * token.kasPerCoinSompi)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    // Manage Addresses' tag: orange once the address has been used, green while fresh
                    let used = isUsed(holding)
                    Text(used ? "Used" : "Unused")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(used ? .orange : .green)
                }
                Spacer()
                if holding.isChatting {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    // its own actions, as Manage Addresses has on each spending address
                    Button {
                        rowActionsTarget = holding
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.scaled(size: 18, weight: .bold))
                            .rotationEffect(.degrees(90))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Address Actions"))
                }
            }
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        )
    }

    /// One address's ⋮: Rename, Copy, Show QR Code and Hide, the same four Manage Addresses has.
    private func rowActionsSheet(_ holding: TokenHolding) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(verbatim: holding.label)
                    .font(.headline)
                Text(verbatim: "\(holding.address.prefix(14))...\(holding.address.suffix(6))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            ActionSheetRow(
                title: "Rename Address",
                subtitle: "Gives this address a label of your own.",
                systemImage: "pencil"
            ) {
                rowActionsTarget = nil
                DispatchQueue.main.async {
                    // the name it was given, or empty for the default "Address #n"
                    let current = WalletManager.shared.ownAddressLabel(for: holding.address) ?? ""
                    renameText = current.hasPrefix("Address #") ? "" : current
                    renameTarget = holding
                }
            }
            ActionSheetRow(
                title: "Copy Address",
                subtitle: "Puts the full address on the clipboard.",
                systemImage: "doc.on.doc"
            ) {
                UIPasteboard.general.string = holding.address
                Haptics.success()
                rowActionsTarget = nil
                showToast(holding.address.addressCopiedToastText)
            }
            ActionSheetRow(
                title: "Show QR Code",
                subtitle: "Full screen, for scanning with another device.",
                systemImage: "qrcode"
            ) {
                rowActionsTarget = nil
                DispatchQueue.main.async { qrTarget = holding }
            }
            // as Kaspa's Manage Addresses: this address's kUSDT, the Chatting Address filled in
            ActionSheetRow(
                title: "Send to Chatting Address",
                subtitle: "Moves kUSDT from this address to your Chatting Address.",
                systemImage: "arrow.up.circle",
                isDisabled: holding.units == 0
            ) {
                rowActionsTarget = nil
                DispatchQueue.main.async { sendToChattingTarget = holding }
            }
            // more than one coin: each holds 1.5 KAS, merging them gives the extra back
            if holding.coins > 1 {
                ActionSheetRow(
                    title: "Combine Coins",
                    subtitle: "Merges its coins into one and gives the extra KAS back.",
                    systemImage: "arrow.triangle.merge"
                ) {
                    rowActionsTarget = nil
                    DispatchQueue.main.async { combineTarget = holding }
                }
            }
            // as unchecking it in kUSDT Address Visibility; it still counts in the total
            ActionSheetRow(
                title: "Hide Address",
                subtitle: String(format: AppLocalization.string("Removes it from this list. Re-enable it in %@ Address Visibility."), token.symbol),
                systemImage: "eye.slash",
                tint: .orange
            ) {
                rowActionsTarget = nil
                if tokens.isListed(holding, of: token) { tokens.toggleListed(holding, of: token) }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A new regular address on the list, with Manage Addresses' "Address #n is ready."
    private func generateFresh() {
        guard !isGenerating else { return }
        isGenerating = true
        Task { @MainActor in
            defer { isGenerating = false }
            guard let number = await tokens.generateFreshAddress(for: token) else { return }
            Haptics.success()
            showToast(String(format: AppLocalization.string("Address #%lld is ready."), locale: AppLocalization.locale, number))
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) { toastMessage = nil }
            }
        }
    }

    /// The floating glass button at the bottom right, as on Manage Addresses.
    private var actionsButton: some View {
        Button {
            Haptics.impact(.light)
            showActions = true
        } label: {
            Group {
                if isDiscovering {
                    ProgressView()
                } else {
                    Image(systemName: "slider.horizontal.3")
                        .font(.scaled(size: 22, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                )
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel(Text(verbatim: String(format: AppLocalization.string("%@ Actions"), token.symbol)))
    }

    private var actionsSheet: some View {
        VStack(spacing: 0) {
            Text(verbatim: String(format: AppLocalization.string("%@ Actions"), token.symbol))
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 16)
            if isDiscovering {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(verbatim: String(format: AppLocalization.string("Checking address #%d"), discoveryChecking))
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: discoveryFound == 0
                         ? String(format: AppLocalization.string("No addresses with %@ yet"), token.symbol)
                         : String(format: AppLocalization.string("%d found so far"), discoveryFound))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        showActions = false
                    } label: {
                        Text("Close and Keep Scanning")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundColor(.accentColor)
                            .background(sendKaspaGlass(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 12) {
                    ActionSheetRow(
                        title: "Generate New Address",
                        subtitle: "Adds a brand-new regular address of yours to this list.",
                        systemImage: "plus.square.on.square",
                        isBusy: isGenerating
                    ) {
                        showActions = false
                        generateFresh()
                    }
                    ActionSheetRow(
                        title: "Discover kUSDT Addresses",
                        subtitle: "Finds your addresses holding kUSDT.",
                        systemImage: "magnifyingglass"
                    ) {
                        discover()
                    }
                    ActionSheetRow(
                        title: "kUSDT Address Visibility",
                        subtitle: "Check off which addresses holding kUSDT are on the list.",
                        systemImage: "checklist"
                    ) {
                        afterActions = { showVisibility = true }
                        showActions = false
                    }
                    if let discoverySummary {
                        Text(verbatim: discoverySummary)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 20)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear { if !isDiscovering { discoverySummary = nil } }
    }

    /// Walks the addresses for the token, reporting in the sheet as it goes; the result stays in
    /// the sheet, or the button's spinner if it was closed.
    private func discover() {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryChecking = 0
        discoveryFound = 0
        discoverySummary = nil
        Task { @MainActor in
            let found = await tokens.discoverHoldings(of: token) { checking, soFar in
                discoveryChecking = checking
                discoveryFound = soFar
            }
            isDiscovering = false
            discoverySummary = found == 0
                ? String(format: AppLocalization.string("No addresses with %@ found."), token.symbol)
                : String(format: AppLocalization.string("Found %d addresses with %@."), found, token.symbol)
            Haptics.success()
        }
    }
}

// MARK: - Address Visibility

/// kUSDT Address Visibility: the same screen as Kaspa's Non-Quantum Addresses
/// (`AddressVisibilityChainList`), for the token. Tokens never live on quantum addresses, so there's
/// no chain to choose. Every regular address in pages of 50 (#0 the Chatting Address, always on),
/// a checkmark per row (checked = on Manage kUSDT's list), and the token's amount on the right, or
/// Unused. A tap saves at once; Hide All starts the list over with only the Chatting Address.
struct TokenAddressVisibilityView: View {
    let token: WalletToken
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var walletManager: WalletManager
    @ObservedObject private var tokens = TokenWallet.shared

    @State private var page = 0
    @State private var pageRows: [TokenHolding] = []
    @State private var showHideAllConfirm = false
    private let pageSize = 50

    var body: some View {
        NavigationStack {
            List {
                if page == 0, let wallet = walletManager.currentWallet {
                    chattingRow(wallet)
                }
                if pageRows.isEmpty {
                    Text("These addresses couldn't be derived right now. Go back a page or reopen this screen to retry.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(pageRows) { holding in
                    row(holding)
                }
            }
            .listStyle(.plain)
            // A new identity per page: a fresh list, scrolled to the top.
            .id(page)
            .safeAreaInset(edge: .bottom) {
                pagerBar
            }
            .navigationTitle(Text(verbatim: String(format: AppLocalization.string("%@ Address Visibility"), token.symbol)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hide All") { showHideAllConfirm = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Hide All Addresses?", isPresented: $showHideAllConfirm) {
                Button("Hide All", role: .destructive) { tokens.hideAllListed(of: token) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(verbatim: String(format: AppLocalization.string("Manage %@ starts over with only your Chatting Address. Nothing is lost: bring any address back here, and its %@ still counts in your total."), token.symbol, token.symbol))
            }
            .onAppear { rebuildPage() }
            .onChange(of: page) { _ in rebuildPage() }
        }
    }

    /// The page's regular addresses (#1 on: #0 is the Chatting Address), derived in one go, with
    /// the token's amount where they hold some.
    private func rebuildPage() {
        let held = Dictionary(uniqueKeysWithValues: tokens.holdings(of: token).compactMap { h in h.spendingIndex.map { ($0, h) } })
        let range = (page * pageSize)..<(page * pageSize + pageSize)
        let derived = walletManager.spendingAddresses(inRange: range)
        pageRows = range.compactMap { index in
            if let holding = held[index] { return holding }
            guard let address = derived[index] else { return nil }
            return TokenHolding(spendingIndex: index, address: address, units: 0, coins: 0)
        }
    }

    private var pagerBar: some View {
        HStack {
            Button {
                page = max(0, page - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 44, height: 36)
            }
            .disabled(page == 0)
            Spacer()
            Text(verbatim: "#\(page == 0 ? 0 : WalletManager.addressNumber(forIndex: page * pageSize)) - #\(WalletManager.addressNumber(forIndex: page * pageSize + pageSize - 1))")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Button {
                page += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 44, height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    /// #0: always on Manage kUSDT, so it's checked and a tap does nothing.
    private func chattingRow(_ wallet: Wallet) -> some View {
        let units = tokens.holdings(of: token).first(where: \.isChatting)?.units ?? 0
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.scaled(size: 20))
                .foregroundColor(.accentColor)
                .opacity(0.45)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: "#0")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    Text("Chatting Address")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(verbatim: "\(wallet.publicAddress.prefix(16))…\(wallet.publicAddress.suffix(6))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            amountTag(units)
        }
        .listRowSeparatorTint(Color.secondary.opacity(0.2))
    }

    private func row(_ holding: TokenHolding) -> some View {
        let listed = tokens.isListed(holding, of: token)
        return HStack(spacing: 10) {
            Image(systemName: listed ? "checkmark.circle.fill" : "circle")
                .font(.scaled(size: 20))
                .foregroundColor(listed ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "#\(WalletManager.addressNumber(forIndex: holding.spendingIndex ?? 0))")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Text(verbatim: "\(holding.address.prefix(16))…\(holding.address.suffix(6))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            amountTag(holding.units)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.impact(.light)
            tokens.toggleListed(holding, of: token)
        }
        .listRowSeparatorTint(Color.secondary.opacity(0.2))
    }

    /// The token's amount in accent, as Kaspa's rows show KAS, or Unused.
    @ViewBuilder
    private func amountTag(_ units: UInt64) -> some View {
        if units > 0 {
            Text(verbatim: TokenAmount.amount(units, token: token))
                .font(.caption2.weight(.semibold))
                .foregroundColor(.accentColor)
        } else {
            Text("Unused")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - One address's page

/// One address holding the token, like a spending address's page in Manage Addresses: its
/// balance, its history of just this token, and Receive and Send at the bottom (from this
/// address). The options button at the top right opens Trestly connected to this address, and the
/// explorer.
struct TokenAddressView: View {
    let token: WalletToken
    let holding: TokenHolding
    @ObservedObject private var tokens = TokenWallet.shared
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    @State private var showOptions = false
    @State private var afterOptions: (() -> Void)?
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showCombine = false

    /// The address as it is now (its amount changes after a send).
    private var current: TokenHolding {
        tokens.holdings(of: token).first(where: { $0.id == holding.id }) ?? holding
    }

    var body: some View {
        let rows = tokens.activity(of: token, at: holding)
        VStack(spacing: 0) {
            // the same card as a Kaspa address's page
            AddressBalanceCard(
                label: holding.label,
                amount: TokenAmount.amount(current.units, token: token),
                detail: String(format: AppLocalization.string("%@ held with it"),
                               KaspaUnit.amount(UInt64(current.coins) * token.kasPerCoinSompi))
            ) {
                TokenSampleBadge()
                    .padding(.top, 4)
            }

            Text(verbatim: String(format: AppLocalization.string("%@ History"), token.symbol))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 6)

            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    // Trestly's API keeps no history: this phone keeps what it sees from now on
                    Text(verbatim: String(format: AppLocalization.string("No %@ activity yet."), token.symbol))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Sends, receives and combines on this phone show here from now on.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // the same list as a Kaspa address's transactions (Manage Addresses)
                List {
                    ForEach(rows) { row in
                        TokenActivityRow(token: token, row: row)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(Text(verbatim: holding.label))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                AddressOptionsButton { showOptions = true }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    showReceive = true
                } label: {
                    Label("Receive", systemImage: "qrcode")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                Button {
                    showSend = true
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                .disabled(current.units == 0)
                .opacity(current.units == 0 ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(isPresented: $showReceive) {
            TokenReceiveSheet(token: token, chattingAddress: "", fixedHolding: current)
        }
        .sheet(isPresented: $showSend) {
            TokenSendView(token: token, startFrom: current)
        }
        .sheet(isPresented: $showOptions, onDismiss: {
            let next = afterOptions
            afterOptions = nil
            next?()
        }) {
            optionsSheet
                .fittedSheetDetents(current.coins > 1 ? 300 : 220)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCombine) {
            TokenCombineView(token: token, holding: current)
        }
    }

    private var optionsSheet: some View {
        VStack(spacing: 0) {
            Text("Address Actions")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 16)
            VStack(spacing: 12) {
                if current.coins > 1 {
                    ActionSheetRow(
                        title: "Combine Coins",
                        subtitle: "Merges its coins into one and gives the extra KAS back.",
                        systemImage: "arrow.triangle.merge"
                    ) {
                        afterOptions = { showCombine = true }
                        showOptions = false
                    }
                }
                if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: holding.address) {
                    ActionSheetRow(
                        title: "View in Explorer",
                        subtitle: "This address on the Kaspa explorer.",
                        systemImage: "safari"
                    ) {
                        showOptions = false
                        UIApplication.shared.open(url)
                    }
                }
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - What the token is

/// The "Bridged by Trestly" pill's sheet: the details about the token and who stands behind it.
struct TokenAboutSheet: View {
    let token: WalletToken
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                TokenAboutCard(token: token)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .navigationTitle(Text(verbatim: String(format: AppLocalization.string("About %@"), token.symbol)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// "Bridged by Trestly": what the token is, the not-audited warning, the KAS each coin holds,
/// and links to the vault and Trestly's site.
struct TokenAboutCard: View {
    let token: WalletToken

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "building.columns")
                    .foregroundColor(.accentColor)
                Text(verbatim: String(format: AppLocalization.string("Bridged by %@"), token.issuer))
                    .font(.headline)
            }
            Text("kUSDT is USDT from Ethereum and BNB Chain, held 1:1 in Trestly's vault and issued as a token on Kaspa. It isn't issued by Tether, and only Trestly can turn it back into USDT.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Not independently audited yet. Hold only what you can afford to lose.")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
            Text("Every kUSDT coin holds 1.5 KAS. It goes along with the kUSDT when you send it.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                linkPill("View the Vault", systemImage: "checkmark.seal", url: token.backingURL)
                linkPill(LocalizedStringKey(token.issuer), systemImage: "safari", url: token.issuerSite)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sendKaspaGlass(cornerRadius: 18))
    }

    private func linkPill(_ title: LocalizedStringKey, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
    }
}

// MARK: - Trestly, inside KaPay

/// The address Trestly's site works with while it's open.
struct TrestlyTarget: Identifiable, Equatable {
    let label: String
    let address: String
    /// nil: the Chatting Address; else the regular spending slot, whose key signs the site's trades.
    let spendingIndex: Int?
    /// The token on it, shown on its row in the address picker (`TrestlyConnectSheet`).
    var units: UInt64 = 0
    var id: String { address }

    @MainActor init(holding: TokenHolding) {
        label = holding.label
        address = holding.address
        spendingIndex = holding.spendingIndex
        units = holding.units
    }

    init(label: String, address: String, spendingIndex: Int?, units: UInt64 = 0) {
        self.label = label
        self.address = address
        self.spendingIndex = spendingIndex
        self.units = units
    }
}

/// Swap Stablecoins' kUSDT (`BuyStablecoinsSheet`, the only way in): which address the site works
/// with (the Chatting Address, every address holding the token, regular addresses holding KAS,
/// or a fresh one), then the site itself inside KaPay.
struct TrestlyConnectSheet: View {
    let token: WalletToken
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var walletManager: WalletManager
    @ObservedObject private var tokens = TokenWallet.shared
    @State private var pickedID: String?
    @State private var fresh: (index: Int, address: String)?
    @State private var openTarget: TrestlyTarget?
    /// Each spending address's KAS (Manage Addresses' list), shown under its kUSDT; nil until read.
    @State private var kasByAddress: [String: UInt64]?
    /// Regular spending addresses holding KAS (hidden ones too), offered beside those holding kUSDT
    /// (owner's call, 2026-11-20: every address with a balance of either). Never a quantum one:
    /// Trestly's code trades only from plain Schnorr addresses.
    @State private var kasAddresses: [SpendingAddressEntry] = []

    /// An address's KAS: the wallet's own balance for the Chatting Address, the spending list's
    /// for the rest (a fresh address has none yet).
    private func kasBalance(_ address: String) -> UInt64? {
        if let wallet = walletManager.currentWallet, wallet.publicAddress == address {
            return wallet.balanceSompi
        }
        guard let kasByAddress else { return nil }
        return kasByAddress[address] ?? 0
    }

    private var choices: [TrestlyTarget] {
        var list: [TrestlyTarget] = []
        let held = tokens.holdings(of: token)
        if let chatting = walletManager.currentWallet?.publicAddress {
            list.append(TrestlyTarget(label: AppLocalization.string("Chatting Address"), address: chatting, spendingIndex: nil,
                                      units: held.first(where: \.isChatting)?.units ?? 0))
        }
        for holding in held where !holding.isChatting {
            list.append(TrestlyTarget(holding: holding))
        }
        // and every regular address holding KAS, in address order
        for entry in kasAddresses where !list.contains(where: { $0.address == entry.address }) {
            list.append(TrestlyTarget(label: entry.displayLabel, address: entry.address, spendingIndex: entry.index))
        }
        // one row per address: a fresh one that somehow matched a listed address isn't offered twice
        if let fresh, !list.contains(where: { $0.address == fresh.address }) {
            list.append(TrestlyTarget(label: AppLocalization.string("Fresh Address"), address: fresh.address, spendingIndex: fresh.index))
        }
        return list
    }

    private var picked: TrestlyTarget? { choices.first(where: { $0.id == pickedID }) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "Which address should Trestly use?")
                    Text("Everything you do on Trestly's site, swapping or adding to the pool, happens on this address. Only it is shown to the site.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(choices) { choice in
                        choiceRow(choice)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .navigationTitle("Open Trestly")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard let picked else { return }
                    if picked.address == fresh?.address, let fresh {
                        Task { await TokenWallet.shared.revealFreshReceiveAddress(fresh.index) }
                    }
                    openTarget = picked
                } label: {
                    Text("Open Trestly")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Capsule().fill(Color.accentColor.opacity(picked == nil ? 0.4 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(picked == nil)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .onAppear {
            if fresh == nil { fresh = TokenWallet.shared.freshReceiveAddress() }
        }
        .task {
            let entries = await walletManager.getSpendingAddressList()
            kasByAddress = Dictionary(entries.map { ($0.address, $0.balanceSompi) }, uniquingKeysWith: { first, _ in first })
            kasAddresses = entries.filter { !$0.isQuantum && $0.balanceSompi > 0 }.sorted { $0.index < $1.index }
        }
        .fullScreenCover(item: $openTarget) { target in
            TrestlyBrowserView(target: target)
        }
        .onReceive(NotificationCenter.default.publisher(for: .trestlyDone)) { _ in dismiss() }
    }

    private func choiceRow(_ choice: TrestlyTarget) -> some View {
        let selected = pickedID == choice.id
        let isChatting = choice.address == walletManager.currentWallet?.publicAddress
        return Button {
            Haptics.impact(.light)
            pickedID = choice.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(selected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: choice.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Image(systemName: isChatting ? "person.crop.circle.fill" : "eye.slash.fill")
                            .font(.caption2)
                            .foregroundColor(isChatting ? .orange : .green)
                    }
                    Text(verbatim: choice.address)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                // both balances: the kUSDT to trade, and the KAS to swap or pay the fee with
                let kas = kasBalance(choice.address)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: TokenAmount.amount(choice.units, token: token))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(choice.units > 0 ? .primary : .secondary)
                    Text(verbatim: kas.map { KaspaUnit.amount($0) } ?? "\u{2013} \(KaspaUnit.symbol)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor((kas ?? 0) > 0 ? .primary : .secondary)
                }
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(selected ? Color.accentColor : Color.white.opacity(0.18), lineWidth: selected ? 1.5 : 0.8)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

/// Trestly's site inside KaPay, full screen, working with one address: Done, the site, and a
/// strip saying which address it's connected to.
///
/// The page gets KaPay's wallet provider (`TrestlyProvider`, kusdt-open SPEC section 14) for `target`
/// only: it connects, reads the network and that address's balances, and swaps or moves liquidity
/// through Trestly's own code after KaPay's Approve. Send and redeem are answered 4200. The page
/// can't leave Trestly's site (`TrestlyWebView.Coordinator`).
struct TrestlyBrowserView: View {
    let target: TrestlyTarget
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    /// The page's wallet provider, kept for as long as the browser is open; its `approval` is the
    /// trade waiting for an answer.
    @StateObject private var provider: TrestlyProvider

    init(target: TrestlyTarget) {
        self.target = target
        _provider = StateObject(wrappedValue: TrestlyProvider(target: target, siteURL: Self.siteURL))
    }

    /// Settings > Connection Settings > Trestly (this network's own by default).
    static var siteURL: URL {
        URL(string: AppSettings.load().trestlySiteURL) ?? URL(string: AppSettings.defaultTrestlySiteURL(for: .mainnet))!
    }

    /// Where the site opens: its Swap page (KAS ⇄ kUSDT), what most people come for first (owner's
    /// call, 2026-11-19). The site's menu has Bridge, Swap, Pool, Portfolio, Reserves and Activity.
    static var startURL: URL { siteURL.appendingPathComponent("swap") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Done") {
                    dismiss()
                    // straight back to the Wallet tab, not the screen Trestly was opened from
                    NotificationCenter.default.post(name: .trestlyDone, object: nil)
                }
                    .font(.headline)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                    Text(verbatim: Self.siteURL.host ?? "trestly.io")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundColor(.secondary)
                Spacer(minLength: 0)
                if isLoading {
                    ProgressView()
                        .frame(width: 44)
                } else {
                    Color.clear.frame(width: 44, height: 1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.accentColor)
                Text(verbatim: String(format: AppLocalization.string("Connected: %@"), target.label))
                    .font(.caption.weight(.semibold))
                Text(verbatim: "\(target.address.prefix(14))...\(target.address.suffix(6))")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                TokenSampleBadge()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12))

            TrestlyWebView(url: Self.startURL, provider: provider, isLoading: $isLoading)
        }
        .background(Color(.systemBackground))
        // a completed swap, over the page (`TrestlyProvider.announceSwap`)
        .toast(message: provider.banner)
        .sheet(item: $provider.approval) { request in
            TrestlyApprovalSheet(request: request) { approved in
                provider.approval = nil
                request.respond(approved)
            }
            .interactiveDismissDisabled(false)
            .onDisappear { request.respond(false) }
        }
        // Done or any other way out: a sheet still up is declined and the page can't ask again
        .onDisappear { provider.close() }
    }
}

/// The page itself: a `WKWebView` with its own data store (nothing shared with the app) and KaPay's
/// wallet provider (`TrestlyProvider`) for `target`, on the Trestly site only.
private struct TrestlyWebView: UIViewRepresentable {
    let url: URL
    let provider: TrestlyProvider
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isLoading: $isLoading, siteURL: url) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        provider.install(in: configuration)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding var isLoading: Bool
        /// The only origin the page may be: the bar above it says this site, and the wallet
        /// provider answers only here.
        let host: String
        let port: Int
        init(isLoading: Binding<Bool>, siteURL: URL) {
            _isLoading = isLoading
            host = siteURL.host?.lowercased() ?? ""
            port = siteURL.port ?? 443
        }

        private func isTrestly(_ url: URL?) -> Bool {
            guard let url, url.scheme == "https", url.host?.lowercased() == host else { return false }
            return (url.port ?? 443) == port
        }

        /// The page stays on Trestly's site (audit, 2026-11-20): a link or redirect anywhere else
        /// would show another site under the "trestly.io" bar, inside the wallet. A link the user
        /// tapped opens in Safari instead; anything else off the site is stopped. Frames inside the
        /// page may load (they can't reach the wallet provider).
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if !mainFrame || isTrestly(url) || url?.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, let url, url.scheme == "https" {
                UIApplication.shared.open(url)
            }
        }

        /// A link meant for a new window: Trestly's own pages load here, others open in Safari.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isTrestly(url) {
                    webView.load(URLRequest(url: url))
                } else if url.scheme == "https" {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isLoading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { isLoading = false }
    }
}

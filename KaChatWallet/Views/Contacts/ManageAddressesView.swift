import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Every address of this account, reached from Profile > Manage Addresses: the chatting address
/// first, then the spending addresses, each with its balance and whether it was used, a
/// "generate new address" action, rename, QR, hide. Which address a send comes from is picked on
/// the send screen itself (From), so there is no "primary" here.
struct ManageAddressesView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var activityNotifier = AddressActivityNotifier.shared

    @State private var entries: [SpendingAddressEntry] = []
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var isDiscovering = false
    @State private var isConsolidating = false
    @State private var showConsolidateConfirm = false
    @State private var showConsolidateSuccess = false
    @State private var consolidateSentTxIds: [String] = []
    @State private var errorMessage: String?
    @State private var qrTarget: SpendingAddressEntry?
    @State private var renameTarget: SpendingAddressEntry?
    @State private var renameText = ""
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    /// Addresses that own at least one KNS domain (cached assets-by-owner lookup) - drives the
    /// "Contains domain" row tag and promotes those rows into the funded group in the sort.
    @State private var domainOwningAddresses: Set<String> = []
    /// Zero-balance addresses whose used/unused probe has NOT confirmed an answer - either
    /// still in flight this load, or failed (network/rate limit). Their badge shows a neutral
    /// "Checking" state instead of a possibly-wrong "Unused", and Generate refuses to recycle
    /// them without a targeted probe. Seeded with every unprobed row at the start of a load
    /// and shrunk per-row the moment each probe lands, so low rows resolve within a second
    /// or two of the screen opening instead of when the whole sweep ends.
    @State private var unknownUsedAddresses: Set<String> = []
    /// Quantum (KIP-22) rows whose key is on chain (they spent once): the shield is off for
    /// good. Seeded from the local marks, confirmed per row by the on-chain probe.
    @State private var quantumSpentAddresses: Set<String> = []
    /// The bulk show/hide checklist, reached from the Address Actions sheet - it is one of this
    /// account's address actions, so it lives with the others rather than as an unlabelled
    /// checklist glyph in the toolbar. Same placement as Cold Storage.
    @State private var showVisibilityManager = false
    /// The "Address Actions" half sheet, and the per-row one behind each ellipsis.
    @State private var showAddressActions = false
    @State private var addressActionsTarget: SpendingAddressEntry?
    /// Live scan position while discovering, so the actions sheet can count up rather than sit
    /// on a spinner for the half-minute a gap-limit walk takes.
    @State private var discoveryProgress: WalletManager.SpendingDiscoveryProgress?
    @State private var discoverySummary: String?

    /// Authoritative primary index, read live from WalletManager rather than the rows'
    /// snapshotted `isCurrent` flags - a payment send can rotate the primary while this
    /// screen's entries are stale, and every isCurrent-dependent decision here (the star,
    /// the sort, Set as Primary / Hide menu items) must follow the rotation immediately.
    /// WalletManager republishes `currentWallet` on rotation, so this recomputes right away.
    private var primaryIndex: Int {
        walletManager.currentSpendingAddressIndex
    }

    /// The spending rows shown: everything not hidden.
    private var visibleEntries: [SpendingAddressEntry] {
        entries.filter { !$0.hidden }
    }

    private var hiddenCount: Int {
        entries.filter { $0.hidden }.count
    }

    /// The spending addresses under the Chatting Address: unused ones first, newest first - so a
    /// freshly generated address lands right under the Chatting Address - then the used ones in
    /// number order (owner's call, 2026-10-27). One still being checked counts as unused until
    /// its check says otherwise.
    private var sortedEntries: [SpendingAddressEntry] {
        func isUsed(_ entry: SpendingAddressEntry) -> Bool { entry.everUsed || entry.balanceSompi > 0 }
        return visibleEntries.sorted { a, b in
            let aUsed = isUsed(a), bUsed = isUsed(b)
            if aUsed != bUsed { return !aUsed }
            return aUsed ? a.index < b.index : a.index > b.index
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                addressesTabContent
            }
            .listStyle(.plain)
            .refreshable {
                await loadEntries()
            }
            // Room to scroll the last row out from under the floating button.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 72)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            addressActionsButton
        }
        .navigationTitle("Manage Addresses")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddressActions) {
            addressActionsSheet
                .presentationDetents([.height(440)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $addressActionsTarget) { entry in
            addressRowActionsSheet(entry)
                .presentationDetents([.height(rowActionsSheetHeight(entry))])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showVisibilityManager, onDismiss: {
            // Apply the visibility edits to the rows we already have IMMEDIATELY -
            // loadEntries() re-fetches every balance and used-flag, which takes long
            // enough on big wallets that the screen looked stale after hitting Done.
            applyVisibilityChangesInstantly()
            Task { await loadEntries() }
        }) {
            SpendingAddressVisibilityView()
        }
        .task {
            await loadEntries()
        }
        // Live own-address receive detected (AddressActivityNotifier) - refresh balances so
        // the screen reflects the funds without a manual pull.
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressActivity)) { _ in
            Task { await loadEntries() }
        }
        // Always-post variant: also fires for self-send change (payment rotation,
        // consolidation) that the notification-gated event above suppresses.
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressUtxoActivity)) { _ in
            Task { await loadEntries() }
        }
        // Primary pointer rotated (post-send rotation or Set as Primary elsewhere) - the rows
        // already read the live primary index for the star and menu guards, so they update the
        // moment WalletManager republishes; this reload refreshes balances and the persisted
        // snapshot so the old primary's row is consistent (and hideable) right away.
        .onReceive(NotificationCenter.default.publisher(for: .spendingPrimaryChanged)) { _ in
            Task { await loadEntries() }
        }
        .toast(message: toastMessage)
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showConsolidateConfirm) {
            ConsolidateToPrimaryConfirmView(
                sources: entries.filter { $0.index != walletManager.currentSpendingAddressIndex && $0.balanceSompi > 0 },
                primaryAddress: walletManager.currentSpendingAddress() ?? ""
            ) { extraFeeSompi in
                consolidateToPrimary(extraFeeSompi: extraFeeSompi)
            }
            // .medium clipped the fee row's footer text on shorter screens once the fee
            // picker/editable field pushed the "From" list below the fold - always opening
            // full height avoids that ambiguity for what's a fund-affecting confirmation.
            .presentationDetents([.large])
        }
        // A half sheet like every other send confirmation. It keeps its own card body rather
        // than using `SentConfirmationSheet`, because a consolidation sweep submits one
        // transaction per source address and the list of them is the whole point.
        .sheet(isPresented: $showConsolidateSuccess) {
            ConsolidateSuccessCard(
                txIds: consolidateSentTxIds,
                explorer: settingsViewModel.settings.kaspaExplorer
            ) {
                showConsolidateSuccess = false
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .presentationDetents([.height(min(420, 220 + CGFloat(consolidateSentTxIds.count) * 44))])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $qrTarget) { entry in
            SpendingAddressQRView(entry: entry)
        }
        .alert(
            "Rename Address",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Label", text: $renameText)
            Button("Save") {
                if let renameTarget {
                    walletManager.setSpendingAddressLabel(index: renameTarget.index, label: renameText)
                }
                renameTarget = nil
                Task { await loadEntries() }
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        } message: {
            Text("Give this address a label to help you recognize it.")
        }
    }

    /// Every address: the total, the actions, then the chatting address, then the spending ones.
    @ViewBuilder
    private var addressesTabContent: some View {
        accountSummary
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        // This account's own switch (cold-storage accounts have theirs in their menu): the
        // spending addresses' receives, not every address the wallet watches.
        Toggle(isOn: $activityNotifier.spendingReceiveNotificationsEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notify on receive")
                    .font(.subheadline.weight(.semibold))
                Text("When a spending address receives Kaspa from someone else.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .tint(.accentColor)
        .listRowSeparator(.hidden)
        .onAppear { activityNotifier.reloadSpendingSwitchForCurrentWallet() }

        if let wallet = walletManager.currentWallet {
            chattingAddressRow(wallet)
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }

        if isLoading && entries.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.top, 20)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if visibleEntries.isEmpty {
            emptyState
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            // Hiding moved to the bulk Address Visibility screen (toolbar checklist) -
            // the old swipe-to-hide is gone.
            ForEach(sortedEntries) { entry in
                addressRow(entry)
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "creditcard")
                .font(.scaled(size: 40))
                .foregroundColor(.secondary)
            Text("No Spending Addresses")
                .font(.headline)
            Text("Generate one below to send payments from a separate address than your main one.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// The chatting address, first in the list: it opens its own screen (history, UTXOs,
    /// Domains, Send / Receive), the same one Profile used to.
    private func chattingAddressRow(_ wallet: Wallet) -> some View {
        ZStack {
            NavigationLink {
                ChattingAddressManageView(address: wallet.publicAddress)
            } label: {
                EmptyView()
            }
            .opacity(0)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Chatting Address")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                    Text(verbatim: "\(wallet.publicAddress.prefix(14))...\(wallet.publicAddress.suffix(6))")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.primary)
                    Text(verbatim: "\(formatKasExact(wallet.balanceSompi ?? 0)) \(KaspaUnit.symbol)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("Used")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
        }
        .background(glassBackground(cornerRadius: 18))
    }

    private func addressRow(_ entry: SpendingAddressEntry) -> some View {
        let isUsed = entry.everUsed || entry.balanceSompi > 0
        // The history probe for this address failed on the last load: used-ness is unknown,
        // and claiming "Unused" could invite address reuse. Pull to refresh re-checks.
        let usedUnknown = !isUsed && unknownUsedAddresses.contains(entry.address)

        return ZStack {
            NavigationLink {
                SpendingAddressTransactionHistoryView(entry: entry)
            } label: {
                EmptyView()
            }
            .opacity(0)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(entry.displayLabel)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        if entry.isQuantum {
                            quantumShield(for: entry)
                        }
                    }
                    Text(entry.shortAddress)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.primary)
                    Text(verbatim: "\(formatKasExact(entry.balanceSompi)) \(KaspaUnit.symbol)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    HStack(spacing: 6) {
                        Text(isUsed ? "Used" : (usedUnknown ? "Checking" : "Unused"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(isUsed ? .orange : (usedUnknown ? .secondary : .green))
                        if domainOwningAddresses.contains(entry.address) {
                            ContainsDomainTag()
                        }
                    }
                }

                Spacer()

                // Half sheet rather than a context menu - the rows have room to say what each
                // one does, which a menu of bare verbs cannot. See `addressRowActionsSheet`.
                Button {
                    addressActionsTarget = entry
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.scaled(size: 18, weight: .bold))
                        .rotationEffect(.degrees(90))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(glassBackground(cornerRadius: 18))
    }

    /// The quantum (KIP-22) state of a row, told honestly:
    /// - shield: the key has never been on chain (receiving reveals nothing) - quantum-safe.
    /// - slashed shield: this address SPENT once, so its key is public forever; orange when
    ///   funds sit on it again (move them to a fresh address), gray when it is empty.
    @ViewBuilder
    private func quantumShield(for entry: SpendingAddressEntry) -> some View {
        let spent = quantumSpentAddresses.contains(entry.address.lowercased())
        if spent {
            Image(systemName: "shield.slash.fill")
                .font(.caption2)
                .foregroundColor(entry.balanceSompi > 0 ? .orange : .secondary)
                .accessibilityLabel(Text("Key revealed by a spend"))
        } else {
            Image(systemName: "shield.fill")
                .font(.caption2)
                .foregroundColor(.green)
                .accessibilityLabel(Text("Quantum-safe"))
        }
    }

    /// Everything this account holds: the chatting address and every spending address, hidden
    /// ones too - the same total as Profile's Manage Addresses card.
    private var totalBalanceSompi: UInt64 {
        (walletManager.currentWallet?.balanceSompi ?? 0) + entries.reduce(0) { $0 + $1.balanceSompi }
    }

    private var accountSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total Balance")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(verbatim: "\(formatKasExact(totalBalanceSompi)) \(KaspaUnit.symbol)")
                    .font(.title2)
                    .fontWeight(.bold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// The floating glass button behind "Address Actions", like the Wallet tab's send / receive one.
    private var addressActionsButton: some View {
        Button {
            Haptics.impact(.light)
            showAddressActions = true
        } label: {
            Group {
                if isGenerating || isDiscovering || isConsolidating {
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
        .disabled(isGenerating || isDiscovering || isConsolidating)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel(Text("Address Actions"))
    }

    /// The half sheet behind "Address Actions".
    ///
    /// Discovery reports its position as it walks, and that lands HERE rather than dismissing:
    /// a scan is a balance lookup per address until the gap limit is reached, easily half a
    /// minute, and a sheet closing on an unmoving spinner said nothing about whether it was
    /// working. The sheet stays put, counts up, and finishes with what it found.
    private var addressActionsSheet: some View {
        VStack(spacing: 0) {
            Text("Address Actions")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 16)

            if isDiscovering, let progress = discoveryProgress {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Checking address #\(progress.checkingIndex)")
                        .font(.subheadline.weight(.semibold))
                    Text(progress.foundCount == 0
                         ? "No addresses with a balance or domain yet"
                         : "\(progress.foundCount) found so far")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Checks the first thousand addresses whatever the gaps, then keeps going while it keeps finding.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    // The scan belongs to this screen, not to the sheet, so closing the sheet
                    // does not stop it - it keeps running and reports what it found in a toast.
                    // Holding the sheet open for the length of a thousand-address sweep was the
                    // only reason to sit and watch it.
                    Button {
                        showAddressActions = false
                    } label: {
                        Text("Close and Keep Scanning")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundColor(.accentColor)
                            .background(glassBackground(cornerRadius: 14))
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
                        title: "Generate New Spending Address",
                        subtitle: "Reveals the next unused address in this wallet.",
                        systemImage: "plus.circle",
                        isBusy: isGenerating,
                        isDisabled: isDiscovering || isConsolidating
                    ) {
                        generateNew()
                        showAddressActions = false
                    }
                    ActionSheetRow(
                        title: "Discover Addresses",
                        subtitle: "Finds addresses holding a balance or a domain.",
                        systemImage: "magnifyingglass",
                        isDisabled: isDiscovering || isConsolidating
                    ) {
                        discoverAddresses()
                    }
                    ActionSheetRow(
                        title: "Address Visibility",
                        subtitle: "Check off every address you want on the list, in one sitting.",
                        systemImage: "checklist",
                        isDisabled: isDiscovering
                    ) {
                        showAddressActions = false
                        // One runloop turn: presenting a sheet from inside one that is still
                        // dismissing drops it.
                        DispatchQueue.main.async { showVisibilityManager = true }
                    }
                    if let discoverySummary {
                        Text(discoverySummary)
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
        // Freely dismissable mid-scan now, by the swipe as well as by the button above: the scan
        // belongs to this screen rather than to the sheet, so closing it does not abandon
        // anything - the Address Actions button keeps its spinner and the result arrives as a
        // toast. Holding the sheet open was only ever protecting a progress readout.
        .onDisappear { discoverySummary = nil }
    }

    /// Rows vary by address, so the detent has to as well - see `addressRowActionsSheet`.
    private func rowActionsSheetHeight(_ entry: SpendingAddressEntry) -> CGFloat {
        let rows = 4
        return CGFloat(120 + rows * 62)
    }

    /// The half sheet behind one address row's ellipsis, replacing the menu that was there.
    private func addressRowActionsSheet(_ entry: SpendingAddressEntry) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(entry.displayLabel)
                    .font(.headline)
                Text(entry.shortAddress)
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
                addressActionsTarget = nil
                DispatchQueue.main.async {
                    renameText = entry.label ?? ""
                    renameTarget = entry
                }
            }
            ActionSheetRow(
                title: "Copy Address",
                subtitle: "Puts the full address on the clipboard.",
                systemImage: "doc.on.doc"
            ) {
                UIPasteboard.general.string = entry.address
                Haptics.success()
                addressActionsTarget = nil
                showToast(entry.address.addressCopiedToastText)
            }
            ActionSheetRow(
                title: "Show QR Code",
                subtitle: "Full screen, for scanning with another device.",
                systemImage: "qrcode"
            ) {
                addressActionsTarget = nil
                DispatchQueue.main.async { qrTarget = entry }
            }
            // Hide straight from the row - same effect as unchecking it in Address Visibility,
            // without opening that screen. Any address, funded too: it comes back from there.
            ActionSheetRow(
                title: "Hide Address",
                subtitle: "Removes it from this list. Re-enable it in Address Visibility.",
                systemImage: "eye.slash",
                tint: .orange
            ) {
                addressActionsTarget = nil
                hideAddress(entry)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Row-menu "Hide Address": flips the same per-wallet hidden flag the Address Visibility
    /// checklist edits (so it shows unchecked there), updates the row in place, and refreshes
    /// the persisted snapshot. setSpendingAddressHidden re-verifies primary/zero-balance
    /// server-side and returns false if the address can't be hidden.
    private func hideAddress(_ entry: SpendingAddressEntry) {
        Task {
            let ok = await walletManager.setSpendingAddressHidden(index: entry.index, hidden: true)
            guard ok else {
                showToast("This address can't be hidden.")
                return
            }
            if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                var updated = entries[position]
                updated.hidden = true
                entries[position] = updated
            }
            walletManager.storeSpendingAddressListCache(entries)
            Haptics.success()
            showToast("Address hidden. Re-enable it in Address Visibility.")
        }
    }

    /// Instant sync after the Address Visibility sheet closes: stamp the stored hidden
    /// set onto the rows already loaded and add any newly revealed indices (pager-derived
    /// addresses beyond what this screen had), so the list reflects the user's edits the
    /// moment they hit Done. The full loadEntries() that follows fills in balances/used.
    private func applyVisibilityChangesInstantly() {
        let hidden = walletManager.hiddenSpendingIndexSet()
        var updated = entries
        for i in updated.indices {
            updated[i].hidden = hidden.contains(updated[i].index)
        }
        let known = Set(updated.map(\.index))
        let maxIndex = walletManager.maxSpendingAddressIndex
        if maxIndex >= 0 {
            for index in 0...maxIndex where !known.contains(index) && !hidden.contains(index) {
                guard let address = walletManager.spendingAddress(at: index) else { continue }
                updated.append(SpendingAddressEntry(
                    index: index,
                    address: address,
                    balanceSompi: 0,
                    isCurrent: index == walletManager.currentSpendingAddressIndex,
                    everUsed: false,
                    label: nil,
                    hidden: false
                ))
            }
        }
        entries = updated.sorted { $0.index < $1.index }
    }

    private func loadEntries() async {
        // Instant paint from the persisted snapshot of the last full load — the screen shows
        // rows immediately (even with the network down) while the live refresh below replaces
        // them. Only used when we have nothing on screen yet, so a live list never regresses.
        if entries.isEmpty {
            let cached = walletManager.cachedSpendingAddressList()
            if !cached.isEmpty { entries = cached }
        }
        isLoading = entries.isEmpty
        let baseEntries = await walletManager.getSpendingAddressList()

        // Resolve everything answerable WITHOUT a network probe before the rows paint:
        // funded rows are used by definition (a balance proves history - persist that, it's
        // monotonic), and zero-balance rows take a cached answer when one exists (persistent
        // used cache, or this session's confirmed-unused memory). Only rows with no cached
        // answer go on the probe list; a failed earlier probe keeps its last known everUsed
        // (from the cached snapshot / previous load) instead of resetting to false.
        let previousUsed = Dictionary(entries.map { ($0.address, $0.everUsed) }, uniquingKeysWith: { first, _ in first })
        var toProbe: [SpendingAddressEntry] = []
        var merged = baseEntries.map { entry -> SpendingAddressEntry in
            var updated = entry
            if entry.balanceSompi > 0 {
                updated.everUsed = true
                walletService.markSpendingAddressUsed(entry.address)
            } else if let cached = walletService.cachedSpendingAddressUsedState(entry.address) {
                updated.everUsed = cached
            } else {
                updated.everUsed = previousUsed[entry.address] ?? false
                toProbe.append(entry)
            }
            return updated
        }
        merged.sort { $0.index < $1.index }
        entries = merged
        // Every not-yet-confirmed row shows "Checking" from the first frame and clears the
        // moment its OWN probe lands below - not when the whole sweep ends.
        unknownUsedAddresses = Set(toProbe.map(\.address))
        isLoading = false

        // Quantum shields: local spend marks at once, then the chain's word per row for spends
        // made on another device or before a restore (a spent mark is permanent - a revealed
        // key cannot be unrevealed).
        quantumSpentAddresses = Set(merged.filter { $0.isQuantum }.map { $0.address.lowercased() }
            .filter { WalletManager.shared.isQuantumAddressSpentLocally($0) })
        let shieldCandidates = merged.filter { $0.isQuantum && !quantumSpentAddresses.contains($0.address.lowercased()) }
        if !shieldCandidates.isEmpty {
            Task {
                for entry in shieldCandidates {
                    if await walletService.quantumAddressSpentState(entry.address) == true {
                        quantumSpentAddresses.insert(entry.address.lowercased())
                    }
                }
            }
        }

        // Lowest indices first: they are the Generate-recycling candidates, so they should be
        // the first badges to resolve (within a second or two of the screen opening).
        //
        // Bounded concurrency, not fully serial and not unbounded: firing every zero-balance
        // address's request at once risked the REST host/CDN rate-limiting the burst and
        // returning a degraded response that isn't a clean empty result - but one-at-a-time
        // made load time scale linearly with how many zero-balance addresses existed. The cap
        // is 8 now that each probe is a one-integer transactions-count response instead of a
        // full resolved transaction, so even a full in-flight batch is tiny on the wire.
        toProbe.sort { $0.index < $1.index }
        let concurrencyLimit = 8
        var pending = toProbe.makeIterator()
        await withTaskGroup(of: (String, Bool?).self) { group in
            for _ in 0..<concurrencyLimit {
                guard let entry = pending.next() else { break }
                group.addTask { (entry.address, await self.walletService.spendingAddressUsedState(entry.address)) }
            }
            while let (address, used) = await group.next() {
                if let used {
                    if let position = entries.firstIndex(where: { $0.address == address }) {
                        entries[position].everUsed = used
                    }
                    unknownUsedAddresses.remove(address)
                    AppLog.log("[ManageAddresses] everUsed check address=%@ used=%@", address, used ? "true" : "false")
                }
                // A failed probe stays in unknownUsedAddresses: the badge keeps showing
                // "Checking" (never a possibly-wrong "Unused") and pull to refresh retries.
                if let entry = pending.next() {
                    group.addTask { (entry.address, await self.walletService.spendingAddressUsedState(entry.address)) }
                }
            }
        }

        // Persist the freshly-loaded snapshot so the NEXT open paints instantly from cache.
        walletManager.storeSpendingAddressListCache(entries)

        // Contains-domain tags, after the rows are already visible. refreshIfNeeded is the same
        // batched KNS lookup: capped
        // concurrency, per-address debounce and failure cooldown, shared in-flight requests -
        // so re-opening this screen reads warm cache instead of re-firing a request burst.
        let addresses = baseEntries.map { $0.address }
        await KNSService.shared.refreshIfNeeded(for: addresses)
        var owners: Set<String> = []
        for address in addresses where KNSService.shared.domainCache[address]?.allDomains.isEmpty == false {
            owners.insert(address)
        }
        // .kachat names count too (testnet, where the registry is live).
        owners.formUnion(await KachatNamesRegistry.shared.ownersOfNames(among: addresses))
        domainOwningAddresses = owners
    }

    private func generateNew() {
        guard !isGenerating else { return }
        isGenerating = true
        Task {
            // A sequence, not a single answer: each press yields the lowest HIDDEN unused
            // index (un-hiding it), and extends the chain past the all-time max once no
            // hidden unused index remains - so repeat presses keep producing new rows.
            //
            // Fast path (Android parity): pick from the rows this screen already live-loaded
            // instead of re-fetching the list and re-probing history per press - recycling
            // trusts only a session-confirmed-unused row. A candidate whose probe hasn't
            // resolved yet (still "Checking") gets ONE targeted probe of just that row,
            // walking up to the next candidate when it turns out used, under a short overall
            // budget so the press never feels slow - this is what makes Generate reliably
            // yield the LOWEST unused index instead of skipping unresolved low rows. Only
            // when the budget runs out or a probe fails do we fall through to deriving past
            // the all-time max, which is provably fresh by construction and needs no network
            // at all. A background reload reconciles afterwards.
            let primaryIndex = walletManager.currentSpendingAddressIndex
            // Generate makes quantum-safe (KIP-22) slots from now on: recycling considers only
            // hidden unused QUANTUM rows, and the fresh path extends the quantum chain - the
            // legacy chain is never grown again from here.
            let candidates = entries
                .sorted { $0.index < $1.index }
                .filter { entry in
                    entry.isQuantum
                        && entry.hidden
                        && entry.index != primaryIndex
                        && entry.balanceSompi == 0
                        && !entry.everUsed
                }
            var chosen: Int?
            let probeDeadline = Date().addingTimeInterval(2.0)
            for candidate in candidates {
                // Re-check against LIVE row state: the background sweep may have resolved
                // this row (either way) while an earlier iteration's probe was in flight.
                let live = entries.first(where: { $0.address == candidate.address }) ?? candidate
                if live.everUsed || live.balanceSompi > 0 || !live.hidden { continue }
                if !unknownUsedAddresses.contains(candidate.address) {
                    // Confirmed unused this session - the true lowest recyclable row.
                    chosen = candidate.index
                    break
                }
                // Unresolved: one targeted probe of just this row, bounded by what's left
                // of the press's overall budget.
                guard let used = await timedUsedProbe(candidate.address, deadline: probeDeadline) else {
                    break // budget spent or probe failed - the derive-past-max path is always safe
                }
                if let position = entries.firstIndex(where: { $0.address == candidate.address }) {
                    entries[position].everUsed = used
                }
                unknownUsedAddresses.remove(candidate.address)
                if !used {
                    chosen = candidate.index
                    break
                }
                // Confirmed used: keep walking to the next-lowest candidate.
            }
            let index: Int
            if let chosen {
                index = chosen
                _ = await walletManager.setSpendingAddressHidden(index: index, hidden: false)
                if let i = entries.firstIndex(where: { $0.index == index }) {
                    entries[i].hidden = false
                }
            } else {
                index = await walletManager.generateNextQuantumAddress()
                if let address = walletManager.spendingAddress(at: index) {
                    entries.append(SpendingAddressEntry(
                        index: index,
                        address: address,
                        balanceSompi: 0,
                        isCurrent: false,
                        everUsed: false,
                        label: nil,
                        hidden: false
                    ))
                    entries.sort { $0.index < $1.index }
                }
            }
            isGenerating = false
            // showToast auto-dismisses on the standard timer and replaces (never stacks or
            // extends) any toast a rapid earlier press put up. The old direct assignment
            // here never scheduled a dismissal, so the success toast lingered indefinitely.
            showToast("Address #\(WalletManager.addressNumber(forIndex: index)) is ready.")
            Task { await loadEntries() }
        }
    }

    /// One used-state probe raced against Generate's overall deadline. Returns the probe's
    /// tri-state answer, collapsed to `nil` for BOTH "probe failed" and "deadline hit" -
    /// Generate treats the two identically (don't recycle, fall back to derive-past-max).
    /// Returns immediately without a request when the budget is already gone.
    private func timedUsedProbe(_ address: String, deadline: Date) async -> Bool? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.05 else { return nil }
        let service = walletService
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await service.spendingAddressUsedState(address) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func discoverAddresses() {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoverySummary = nil
        discoveryProgress = WalletManager.SpendingDiscoveryProgress(checkingIndex: 0, foundCount: 0)
        Task {
            let discovered = await walletManager.discoverSpendingAddresses { progress in
                discoveryProgress = progress
            }
            await HotWalletBalance.shared.refresh(force: true)
            await loadEntries()
            isDiscovering = false
            discoveryProgress = nil
            // The count is addresses that hold a balance or a KNS domain - say so, rather than
            // "used", which is what the old high-water-mark number implied and was not.
            let summary = discovered == 0
                ? "No addresses with a balance or domain found."
                : "Found \(discovered) address\(discovered == 1 ? "" : "es") with a balance or domain."
            discoverySummary = summary
            // Closed the sheet and carried on? Then the summary above has nowhere to render, so
            // say it here instead of finishing silently.
            if !showAddressActions { showToast(summary) }
        }
    }

    /// Sweeps every non-primary spending address's balance into the current primary, one at
    /// a time. Best-effort: a failure on one address doesn't block the rest. `extraFeeSompi`
    /// (chosen in the confirmation sheet) is applied to each individual sweep, same as any other
    /// send's fee customization - there's no single combined fee to show since this can be
    /// several separate transactions, one per source address.
    private func consolidateToPrimary(extraFeeSompi: UInt64 = 0) {
        guard !isConsolidating else { return }
        isConsolidating = true
        errorMessage = nil
        Task {
            guard let primaryAddress = walletManager.currentSpendingAddress() else {
                isConsolidating = false
                return
            }
            let activeIndex = walletManager.currentSpendingAddressIndex
            var sentTxIds: [String] = []
            // One address failing must not hide the others' success - but if nothing went out
            // and something threw, that error is the answer, not a sheet that just closes.
            var lastError: Error?
            for entry in entries where entry.index != activeIndex && entry.balanceSompi > 0 {
                do {
                    let maxSendable = try await walletService.estimateMaxSpendingAddressAmount(index: entry.index, toAddress: primaryAddress, extraFeeSompi: extraFeeSompi)
                    guard maxSendable > 0 else { continue }
                    let txId = try await walletService.sendFromSpendingAddress(index: entry.index, toAddress: primaryAddress, amountSompi: maxSendable, extraFeeSompi: extraFeeSompi)
                    sentTxIds.append(txId)
                } catch {
                    lastError = error
                }
            }
            await loadEntries()
            isConsolidating = false
            if !sentTxIds.isEmpty {
                consolidateSentTxIds = sentTxIds
                showConsolidateSuccess = true
            } else if let lastError {
                errorMessage = lastError.localizedDescription
            }
        }
    }

    private func formatKasExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}

/// Small teal-tinted capsule shown on address rows that own at least one KNS domain. Shared by
/// ManageAddressesView's spending-address list and ColdStorageDetailView's address list. Same
/// capsule treatment as the app's other inline badges (e.g. KNSDomainCard's "Primary"), tinted
/// with the accent color instead of drawn on a dark card.
struct ContainsDomainTag: View {
    var body: some View {
        Text("Contains domain")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

/// Confirm-before-you-sweep sheet for "Send All Kaspa To Primary Spend Address" - shows exactly
/// which addresses will be swept, where the funds are going, and a fee the user can adjust,
/// rather than firing off however-many transactions the instant the menu item is tapped.
private struct ConsolidateToPrimaryConfirmView: View {
    let sources: [SpendingAddressEntry]
    let primaryAddress: String
    let onConfirm: (UInt64) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var feeEditorText = ""
    @FocusState private var feeFieldFocused: Bool

    /// Same reference-mass shortcut used by Cold Storage's fee editor - a fixed 1-input/2-output
    /// mass, good enough to show/edit a per-transaction fee estimate without a network round trip.
    private var referenceMass: UInt64 { ColdStorageSendEngine.referenceMassForFeeEditor }

    private var normalFeeSompi: UInt64 {
        ColdStorageSendEngine.calculateFee(mass: referenceMass, rateSompiPerGram: KaspaFeePolicy.minimumRelayFeePerGramSompi)
    }

    /// Extra priority tip on top of the base (Normal-tier) fee - same Normal/Fast/Priority
    /// system as the main-address withdraw flow, applied per swept address here since a
    /// consolidation can be several separate transactions.
    private var extraFeeSompi: UInt64 {
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return normalFeeSompi * (feeTier.multiplier - 1)
    }

    private var effectiveFeeSompi: UInt64 {
        normalFeeSompi + extraFeeSompi
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if sources.isEmpty {
                        Text("No other addresses have a balance to consolidate.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sources) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayLabel)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(entry.shortAddress)
                                        .font(.system(.subheadline, design: .monospaced))
                                }
                                Spacer()
                                Text(verbatim: "\(formatKas(entry.balanceSompi)) \(KaspaUnit.symbol)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                } header: {
                    Text("From")
                }

                Section {
                    Text(primaryAddress)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } header: {
                    Text("To (Primary Address)")
                }

                if !sources.isEmpty {
                    Section {
                        Picker("Fee", selection: $feeTier) {
                            ForEach(WithdrawFeeTier.allCases) { tier in
                                Text(tier.rawValue).tag(tier)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: feeTier) { _ in
                            customExtraFeeSompi = nil
                            isEditingFee = false
                        }

                        HStack {
                            Text("Network Fee")
                            Spacer()
                            if isEditingFee {
                                TextField("0.00", text: $feeEditorText)
                                    .keyboardType(.decimalPad)
                                    .numericKeyboardDoneButton()
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 100)
                                    .focused($feeFieldFocused)
                                    .onSubmit { commitCustomFee() }
                                Button {
                                    commitCustomFee()
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Button {
                                    feeEditorText = formatKas(effectiveFeeSompi)
                                    isEditingFee = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(verbatim: "~\(formatKas(effectiveFeeSompi)) \(KaspaUnit.symbol)")
                                            .underline()
                                        Image(systemName: "pencil")
                                            .font(.caption2)
                                    }
                                    .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } footer: {
                        Text(sources.count > 1
                             ? "\(sources.count) separate transactions will be sent, one per address. Fast or Priority pays a higher fee to help them confirm sooner. Tap the fee amount to set a custom fee, applied to each."
                             : "If the network is busy, Fast or Priority pays a higher fee to help this confirm sooner. Tap the fee amount to set a custom fee.")
                    }
                }
            }
            .navigationTitle("Consolidate to Primary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        feeFieldFocused = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Confirm") {
                        onConfirm(extraFeeSompi)
                        dismiss()
                    }
                    .disabled(sources.isEmpty)
                }
            }
        }
    }

    /// Commits the manually-typed total fee. Values below the network-computed minimum are
    /// clamped up to that minimum rather than rejected outright, matching the main-address
    /// withdraw flow's identical behavior.
    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let totalSompi = KaspaUnit.sompi(fromUserText: feeEditorText) else { return }
        customExtraFeeSompi = totalSompi > normalFeeSompi ? totalSompi - normalFeeSompi : 0
    }

    private func formatKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Confirms a completed consolidation sweep - shown after "Send All Kaspa To Primary Spend
/// Address" finishes, listing every transaction id it actually submitted (there can be more
/// than one, one per source address swept) so the user has something concrete to check on an
/// explorer rather than just trusting the sheet silently closed. Same half-sheet language as
/// `SentConfirmationSheet` (checkmark + "Sent" + tappable ids), just extended to a list, since a
/// sweep submits one transaction per source address and that list is the whole point.
private struct ConsolidateSuccessCard: View {
    let txIds: [String]
    let explorer: KaspaExplorer
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.scaled(size: 44))
                .foregroundColor(.green)

            Text("Sent")
                .font(.headline)
                .fontWeight(.bold)

            VStack(spacing: 8) {
                ForEach(txIds, id: \.self) { txId in
                    if let url = explorer.txURL(for: txId) {
                        Link(destination: url) {
                            Text(txId)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .underline()
                                .multilineTextAlignment(.center)
                        }
                    } else {
                        Text(txId)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            Button {
                onDismiss()
            } label: {
                Text("OK")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
        }
        .padding(24)
        .frame(maxWidth: 300)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
    }
}

/// Scoped withdraw dialog for a single spending address — change stays on that same address
/// (no rotation), unlike the rotate-on-send behavior of the primary. Widened
/// from `private` so ContactsView.swift's Profile-tab "Spending Address" dropdown can reuse it
/// for the primary spending address rather than duplicating this whole flow.
struct SpendingAddressWithdrawView: View {
    let entry: SpendingAddressEntry
    /// Pre-fills the recipient with `entry.address` itself (a self-send) and auto-fills Max, for
    /// the "Compound UTXOs" entry point - merges every UTXO at this address into one. Locks the
    /// recipient field instead of just pre-filling it, matching Cold Storage's identical
    /// ColdSendFlowView behavior, since editing it away from `entry.address` would defeat the
    /// point of a compound send.
    var isCompoundMode: Bool = false
    /// UTXOs already loaded for `entry.address` by the parent (the list the user is looking at).
    /// Passed through the compound flow so the "Max" estimate and send don't depend on a second
    /// pooled fetch that can transiently return empty - which was surfacing as a spurious
    /// "No spendable UTXOs available" when compounding a large UTXO set.
    var preloadedUtxos: [UTXO] = []
    let onComplete: () -> Void

    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var portfolioViewModel = PortfolioViewModel.shared
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var addressInput = ""
    @State private var isValidAddress = false
    @State private var amountInput = ""
    @State private var showQRScanner = false
    @State private var isSending = false
    @State private var isEstimatingMax = false
    @State private var errorMessage: String?
    /// The completed send, driving the sent-confirmation half sheet.
    @State private var sentTransaction: SentTransaction?

    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    /// Every service's answer for a typed name and the one in use: the rest go under "Other domains".
    @State private var nameResolutions: [NameResolution] = []
    @State private var selectedTLD: NameServiceTLD?
    @State private var knsError: String?
    private let knsService = KNSService.shared

    /// The actual address to use (resolved from a KNS domain, or the direct input) - same
    /// precedence as ContactsView's WithdrawKaspaView/AddContactView.
    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    /// True once we have a usable recipient - either a resolved KNS domain or a directly valid
    /// Kaspa address (mirrors WithdrawKaspaView.hasValidRecipient).
    private var hasValidRecipient: Bool {
        if resolvedAddress != nil { return true }
        return isValidAddress && !isResolvingKNS
    }

    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var normalFeeSompi: UInt64?
    /// Change too small to keep, which goes to the fee (`SendFeeEstimate`).
    @State private var foldedChangeSompi: UInt64 = 0
    /// The fee a send with a higher fee will really pay, once estimated.
    @State private var tippedFeeSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""
    /// The fee editor (the fee row's Edit) is on screen in place of the review.
    @State private var editingFee = false
    @State private var feeDraft = ""

    @State private var manualUtxos: [UTXO]?
    @State private var showCoinControl = false

    private var amountSompi: UInt64? {
        guard let sompi = KaspaUnit.sompi(fromUserText: amountInput), sompi > 0 else { return nil }
        return sompi
    }

    private var canSend: Bool {
        hasValidRecipient && amountSompi != nil && !isSending
    }

    /// Extra priority tip on top of the base (Normal-tier) fee, for network congestion. A
    /// manually-entered custom fee (tapped on the Network Fee row) overrides the tier
    /// multiplier until a tier is tapped again - same behavior as the main-address
    /// withdraw flow (ContactsView.WithdrawKaspaView).
    private var extraFeeSompi: UInt64 {
        guard let normalFeeSompi else { return 0 }
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return normalFeeSompi * (feeTier.multiplier - 1)
    }

    private var totalFeeSompi: UInt64? {
        guard let normalFeeSompi else { return nil }
        if extraFeeSompi > 0, let tippedFeeSompi { return tippedFeeSompi }
        return SendFeeEstimate(networkFee: normalFeeSompi, foldedChange: foldedChangeSompi).total(extra: extraFeeSompi)
    }

    private var feeEstimationKey: String {
        let manualKey = manualUtxos?.map { "\($0.outpoint.transactionId):\($0.outpoint.index)" }.sorted().joined(separator: ",") ?? ""
        return "\(source.index)|\(hasValidRecipient ? effectiveAddress : "")|\(amountSompi ?? 0)|\(manualKey)"
    }

    /// The spending address this send comes from: `entry` (the primary, from Profile or the
    /// Wallet tab), unless another was picked from the Available pill for this one send.
    /// The primary itself doesn't change.
    @State private var chosenSource: SpendingAddressEntry?
    @State private var showSourcePicker = false
    private var source: SpendingAddressEntry { chosenSource ?? entry }

    var body: some View {
        NavigationStack {
            ZStack {
                if editingFee {
                    // The send flow's fee editor: the whole fee on the keypad, Confirm back here.
                    SendFeeEditorScreen(draft: $feeDraft, minimumSompi: normalFeeSompi,
                                        onCancel: { showFeeEditor(false) }) { typed in
                        if let normalFeeSompi {
                            customExtraFeeSompi = typed > normalFeeSompi ? typed - normalFeeSompi : 0
                        }
                        showFeeEditor(false)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
                } else {
                    review
                        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled()
    }

    private func showFeeEditor(_ show: Bool) {
        if show, let totalFeeSompi { feeDraft = formatKas(totalFeeSompi) }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { editingFee = show }
    }

    /// The review: in Compound UTXOs (this screen's one use) the recipient is this address and
    /// the amount everything on it, so only the fee and coin control change before swiping up.
    private var review: some View {
            SwipeUpToSendScrollView(
                screenTitle: isCompoundMode ? "Compound UTXOs"
                    : "Send Kaspa from Address #\(WalletManager.addressNumber(forIndex: source.index))",
                onCancel: { dismiss() },
                title: isCompoundMode ? "Swipe up to Consolidate" : "Swipe up to Send",
                isBusy: isSending,
                isEnabled: canSend,
                amountSompi: amountSompi,
                recipient: isCompoundMode ? nil : effectiveAddress,
                sent: sentTransaction,
                failureMessage: errorMessage,
                onDone: {
                    sentTransaction = nil
                    onComplete()
                    dismiss()
                },
                action: send
            ) {
                VStack(spacing: 18) {
                    SendRecipientCard(
                        input: $addressInput,
                        lockedAddress: isCompoundMode ? source.address : nil,
                        isResolving: isResolvingKNS,
                        resolvedAddress: resolvedAddress,
                        resolvedName: resolvedDomain,
                        lookupError: knsError,
                        isValidAddress: isValidAddress,
                        onScan: { showQRScanner = true },
                        nameResolutions: nameResolutions,
                        selectedTLD: selectedTLD,
                        onSelectResolution: selectResolution
                    )

                    if isCompoundMode {
                        VStack(spacing: 6) {
                            Text("Consolidating")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            if let amountSompi {
                                Text(verbatim: "\(formatKas(amountSompi)) \(KaspaUnit.symbol)")
                                    .font(.system(size: 40, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                            } else {
                                ProgressView().frame(height: 48)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    } else {
                        KaspaAmountEntry(
                            fiatAmountState: fiatAmountState,
                            onAmountChange: { amountInput = $0 },
                            isEstimatingMax: isEstimatingMax,
                            maxEnabled: hasValidRecipient,
                            onMax: setMaxAmount
                        )
                        .padding(.top, 8)
                    }

                    // Tap to send from a different spending address (not in Compound, which is
                    // about this one address).
                    Button {
                        showSourcePicker = true
                    } label: {
                        SendInfoPill {
                            HStack(spacing: 6) {
                                KaspaUnit.text("Available: %@ KAS", formatKas(source.balanceSompi))
                                Text(verbatim: "·")
                                Text(source.displayLabel)
                                if !isCompoundMode {
                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.bold))
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCompoundMode)
                    .accessibilityHint(Text("Choose which spending address to send from"))

                    SendFeeControls(
                        feeTier: $feeTier,
                        isEditingFee: $isEditingFee,
                        customFeeText: $customFeeText,
                        isEstimatingFee: isEstimatingFee,
                        feeText: totalFeeSompi.map { "\(formatKas($0)) \(KaspaUnit.symbol)" },
                        onStartEditing: startEditingFee,
                        onCommit: commitCustomFee,
                        coinControlSummary: coinControlSummary(manualUtxos),
                        onCoinControl: { showCoinControl = true },
                        onEditFee: { showFeeEditor(true) }
                    )

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            // The recipient card only shows the lookup; this screen runs it.
            .onChange(of: addressInput) { handleInputChange($0) }
            .onChange(of: feeTier) { _ in
                customExtraFeeSompi = nil
                isEditingFee = false
                if isCompoundMode { setMaxAmount() }
            }
            .onChange(of: customExtraFeeSompi) { _ in
                // Compound sends everything: the amount is what's left after the fee
                if isCompoundMode { setMaxAmount() }
            }
            // A higher fee can leave too little change to keep, and then all of it goes to the fee: the
            // total comes from an estimate made with that fee, what the send itself will do.
            .task(id: "\(feeEstimationKey)|\(extraFeeSompi)") {
                tippedFeeSompi = nil
                guard extraFeeSompi > 0, !isCompoundMode, hasValidRecipient, let amountSompi else { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                let fee = try? await walletService.estimateSpendingAddressWithdrawalFee(index: source.index, toAddress: effectiveAddress, amountSompi: amountSompi, manualUtxos: manualUtxos, extraFeeSompi: extraFeeSompi)
                guard !Task.isCancelled, let fee else { return }
                tippedFeeSompi = fee.networkFee + fee.foldedChange
            }
            .task(id: feeEstimationKey) {
                guard hasValidRecipient, let amountSompi else {
                    normalFeeSompi = nil
                    return
                }
                isEstimatingFee = true
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let fee = try await walletService.estimateSpendingAddressWithdrawalFee(index: source.index, toAddress: effectiveAddress, amountSompi: amountSompi, manualUtxos: manualUtxos, availableUtxos: isCompoundMode ? preloadedUtxos : [])
                    guard !Task.isCancelled else { return }
                    normalFeeSompi = fee.networkFee
                    foldedChangeSompi = fee.foldedChange
                } catch {
                    guard !Task.isCancelled else { return }
                    normalFeeSompi = nil
                }
                isEstimatingFee = false
            }
            .task {
                if isCompoundMode {
                    addressInput = source.address
                    isValidAddress = true
                    setMaxAmount()
                }
            }
            // The header (Cancel, title) is SwipeUpToSendScrollView's own, so it moves with the swipe.
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    handleScannedQRCode(code)
                }
            }
            .sheet(isPresented: $showSourcePicker) {
                SpendingSourcePicker(currentIndex: source.index) { picked in
                    chosenSource = picked
                    // Coin control and the fee belong to the address they were set for.
                    manualUtxos = nil
                    customExtraFeeSompi = nil
                    errorMessage = nil
                }
            }
            .sheet(isPresented: $showCoinControl) {
                CoinControlView(fromAddress: source.address, initialSelection: manualUtxos) { selection in
                    manualUtxos = selection
                    if isCompoundMode { setMaxAmount() }
                }
            }
            // The confirmation is the swipe-up's own full screen (SwipeUpToSendScrollView).
    }

    private func handleInputChange(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        resolvedAddress = nil
        resolvedDomain = nil
        knsError = nil
        isResolvingKNS = false
        nameResolutions = []
        selectedTLD = nil

        guard !trimmed.isEmpty else {
            isValidAddress = false
            return
        }

        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") {
            // the other network's address is the same key on another chain: refused
            isValidAddress = KaspaAddress.isValidOnActiveNetwork(trimmed)
            return
        }

        if NameServicesClient.looksLikeName(trimmed) {
            isValidAddress = false
            resolveKNSDomain(trimmed)
        } else {
            isValidAddress = false
        }
    }

    /// Use one service's answer (the priority one, or a pick from "Other domains").
    private func selectResolution(_ resolution: NameResolution) {
        guard let address = resolution.address else { return }
        resolvedAddress = address
        resolvedDomain = resolution.display
        selectedTLD = resolution.tld
        knsError = nil
    }

    private func resolveKNSDomain(_ domain: String) {
        isResolvingKNS = true

        // On the main actor: the check below must read the field as it is now. Read from a
        // background task while typing fast, it could see an older value, take this lookup for a
        // stale one and stop - leaving "Looking up domain..." up for good.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain ||
                  addressInput.trimmingCharacters(in: .whitespacesAndNewlines) + ".kas" == domain + ".kas" else {
                return
            }

            // Every name service, in priority: the ending typed, else .kachat only (the others wait under Other domains)
            // (see NameServicesClient). The resolved line names which one answered; the others
            // are offered under "Other domains".
            let results = await NameServicesClient.shared.resolveEverywhere(domain)
            await MainActor.run {
                guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain else { return }
                nameResolutions = results
                isResolvingKNS = false
                if let resolution = NameServicesClient.primary(of: results, typed: domain), resolution.address != nil {
                    selectResolution(resolution)
                } else {
                    resolvedAddress = nil
                    resolvedDomain = nil
                    selectedTLD = nil
                    knsError = NameServicesClient.notFoundMessage(typed: domain, results: results)
                }
            }
        }
    }

    private func handleScannedQRCode(_ code: String) {
        var address = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("kaspa:") || address.lowercased().hasPrefix("kaspatest:") {
            if let queryIndex = address.firstIndex(of: "?") {
                address = String(address[..<queryIndex])
            }
        }
        addressInput = address
        handleInputChange(address)
    }

    private func setMaxAmount() {
        guard hasValidRecipient else { return }
        isEstimatingMax = true
        errorMessage = nil
        let recipient = effectiveAddress
        let tipSompi = extraFeeSompi
        Task {
            do {
                if isCompoundMode {
                    // Consolidation is bounded by Kaspa's per-transaction mass cap, so estimate the
                    // max over only the UTXOs that fit ONE transaction (largest-first) and pin the
                    // send to exactly those inputs. This is why "Max" works even when the address has
                    // more UTXOs than a single tx can hold - it consolidates one batch; repeat to
                    // reduce further.
                    let (maxSompi, utxos) = try await walletService.maxConsolidatableChunk(index: source.index, extraFeeSompi: tipSompi, availableUtxos: preloadedUtxos)
                    await MainActor.run {
                        manualUtxos = utxos
                        amountInput = fiatAmountState.setMaxKas(Double(maxSompi) / 100_000_000.0, priceInCurrency: portfolioViewModel.currentPriceUsd)
                        isEstimatingMax = false
                    }
                } else {
                    let maxSompi = try await walletService.estimateMaxSpendingAddressAmount(index: source.index, toAddress: recipient, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
                    await MainActor.run {
                        amountInput = fiatAmountState.setMaxKas(Double(maxSompi) / 100_000_000.0, priceInCurrency: portfolioViewModel.currentPriceUsd)
                        isEstimatingMax = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = UserFacingError.message(for: error)
                    isEstimatingMax = false
                }
            }
        }
    }

    private func startEditingFee() {
        guard let totalFeeSompi else { return }
        customFeeText = formatKas(totalFeeSompi)
        isEditingFee = true
    }

    /// Commits the manually-typed total fee. Values below the network-computed minimum are
    /// clamped up to that minimum rather than rejected outright, matching the main-address
    /// withdraw flow's identical behavior.
    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let normalFeeSompi, let totalSompi = KaspaUnit.sompi(fromUserText: customFeeText) else { return }
        customExtraFeeSompi = totalSompi > normalFeeSompi ? totalSompi - normalFeeSompi : 0
    }

    private func send() {
        guard let amountSompi else { return }
        isSending = true
        errorMessage = nil
        // In compound mode, `manualUtxos` is the one-transaction chunk pinned by setMaxAmount() and
        // `recipient` is this address itself, so this self-sends exactly those inputs = one
        // consolidation transaction. In normal mode it's a regular send.
        let recipient = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let tipSompi = extraFeeSompi
        Task {
            do {
                try await SendFailureSimulation.failIfEnabled()
                let txId = try await walletService.sendFromSpendingAddress(index: source.index, toAddress: recipient, amountSompi: amountSompi, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
                await MainActor.run {
                    isSending = false
                    sentTransaction = SentTransaction(
                        txId: txId,
                        amountSompi: amountSompi,
                        // A compound is a self-send: naming this address as the recipient reads
                        // as a mistake, so it just says how much moved.
                        recipient: isCompoundMode ? nil : recipient
                    )
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = UserFacingError.message(for: error)
                }
            }
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// White-background QR display for a single spending address, matching the same visual
/// treatment as ChattingAddressQRView (literal colors, not adaptive semantic colors, so text
/// stays readable regardless of system dark/light mode without affecting the nav bar).
/// Which spending address a send comes from, picked from a Send screen's Available pill (the
/// spending-address Send):
/// every spending address you can see (plus hidden ones that hold Kaspa), funded ones first, each
/// with its balance. Picking one changes this send only - the primary stays where it is.
struct SpendingSourcePicker: View {
    let currentIndex: Int
    let onPick: (SpendingAddressEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SpendingAddressEntry]?

    var body: some View {
        NavigationStack {
            Group {
                if let entries {
                    List(entries) { entry in
                        Button {
                            onPick(entry)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(entry.displayLabel)
                                            .font(.subheadline.weight(.semibold))
                                        if entry.isCurrent {
                                            Text("Primary")
                                                .font(.caption2.weight(.bold))
                                                .foregroundColor(.accentColor)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                        }
                                    }
                                    Text(verbatim: "\(entry.address.prefix(14))...\(entry.address.suffix(6))")
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(verbatim: "\(Self.formatKas(entry.balanceSompi)) \(KaspaUnit.symbol)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(entry.balanceSompi > 0 ? .primary : .secondary)
                                if entry.index == currentIndex {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Send From")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            let all = await WalletManager.shared.getSpendingAddressList()
            entries = all
                .filter { !$0.hidden || $0.balanceSompi > 0 || $0.index == currentIndex }
                .sorted { ($0.balanceSompi > 0 ? 0 : 1, $0.index) < ($1.balanceSompi > 0 ? 0 : 1, $1.index) }
        }
    }

    private static func formatKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

private struct SpendingAddressQRView: View {
    let entry: SpendingAddressEntry
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    var body: some View {
        NavigationStack {
            Color.white
                .ignoresSafeArea()
                .overlay(
                    VStack(spacing: 20) {
                        Spacer()
                        Group {
                            if let qrImage {
                                Image(uiImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 240, height: 240)
                            } else {
                                ProgressView()
                                    .frame(width: 240, height: 240)
                            }
                        }
                        .padding(20)
                        .background(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.accentColor, lineWidth: 3)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                        Text(entry.address)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Color.black.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Text("Tap anywhere to copy")
                            .font(.footnote)
                            .foregroundColor(Color.black.opacity(0.4))

                        Spacer()
                        Spacer()
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture { copyAddress() }
                .navigationTitle(entry.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
                .onAppear { generateQR() }
                .toast(message: toastMessage)
        }
    }

    private func copyAddress() {
        UIPasteboard.general.string = entry.address
        Haptics.success()
        showToast(entry.address.addressCopiedToastText)
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func generateQR() {
        let trimmed = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let uri = trimmed.hasPrefix("kaspa:") ? trimmed : "kaspa:\(trimmed)"
        guard let data = uri.data(using: .utf8) else { return }

        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }
        qrImage = UIImage(cgImage: cgImage)
    }
}

/// Reveals a single spending address's own derived private key - not the wallet's seed phrase -
/// so a specific address's spending capability can be exported/backed up without exposing the
/// rest of the wallet. Mirrors SettingsView's seed-phrase reveal flow at the same sensitivity
/// level (SecureView screenshot protection, tap-to-reveal with a 7s auto-hide timer, clipboard
/// auto-clear after 30s) rather than inventing a lighter-weight pattern for equally sensitive
/// key material. The caller gates presentation behind `DeviceAuth`/biometrics already, same as
/// the seed-phrase entry point does.
private struct SpendingAddressPrivateKeyView: View {
    let entry: SpendingAddressEntry
    @Environment(\.dismiss) private var dismiss

    @State private var isRevealed = false
    @State private var revealToken = UUID()
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    private var privateKeyHex: String {
        WalletManager.shared.spendingPrivateKey(at: entry.index)?.hexString ?? "Unavailable"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Security Warning", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Text("Anyone with this address's private key can spend its funds. Never share it with anyone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if isRevealed {
                    SecureView {
                        Text(privateKeyHex)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        copySensitiveToClipboard(privateKeyHex)
                        Haptics.success()
                        showToast("Private key copied. Clipboard will clear in 30s.")
                    } label: {
                        Label("Copy Private Key Hex", systemImage: "doc.on.doc")
                    }
                    .padding(.top)
                } else {
                    Button {
                        isRevealed = true
                        let token = UUID()
                        revealToken = token
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                            if revealToken == token {
                                isRevealed = false
                            }
                        }
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "eye.slash.fill")
                                .font(.largeTitle)
                            Text("Tap to reveal private key")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(60)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle(entry.displayLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .toast(message: toastMessage)
        }
    }

    /// Sensitive copy: hard 30s system expiration + localOnly (no Universal Clipboard sync);
    /// the asyncAfter wipe is an in-app belt-and-suspenders clear (see SettingsView's twin).
    private func copySensitiveToClipboard(_ value: String) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)]
        )
        let copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if UIPasteboard.general.string == copiedValue {
                UIPasteboard.general.string = ""
            }
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

/// Transaction history for a single spending address. Tapping a transaction opens it
/// directly on whichever block explorer is selected in Settings > Connection > Kaspa
/// Explorer, rather than showing an in-app detail screen.
struct SpendingAddressTransactionHistoryView: View {
    let entry: SpendingAddressEntry

    /// The tapped transaction, while its action chooser is up.
    @State private var transactionActionTarget: KaspaFullTransactionResponse?
    @State private var pendingPortfolioCandidate: PortfolioCandidateTransaction?
    /// The transaction being filed into a portfolio, if any - see `AddToPortfolioSheet`.
    @State private var portfolioCandidate: PortfolioCandidateTransaction?
    /// Name of the portfolio just added to, for the confirmation capsule.
    @State private var addedPortfolioName: String?

    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    private enum Tab: String, CaseIterable {
        case transactions = "History"
        case utxos = "UTXOs"
        case kachatDomains = "Domains"
    }

    @State private var selectedTab: Tab = .transactions
    @State private var transactions: [KaspaFullTransactionResponse] = []
    /// The last history fetch gave up partway. Kept separate from `transactions.isEmpty` because
    /// the two mean opposite things and used to render identically: a rate-limited request looked
    /// exactly like an address that has never been used.
    @State private var historyIncomplete = false
    @State private var isLoading = false
    @State private var utxos: [UTXO] = []
    @State private var isLoadingUtxos = false
    /// See `CoinControlView.loadError`.
    @State private var utxoLoadError: String?
    @State private var showReceiveSheet = false
    @State private var showSendSheet = false
    @State private var showCompoundSheet = false
    @State private var showPrivateKeySheet = false
    @State private var utxoLabels: [String: String] = [:]
    @State private var renamingUtxo: UTXO?
    @State private var renameUtxoText = ""

    private func outpointKey(_ utxo: UTXO) -> String {
        "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)"
    }

    /// Plain names - History, UTXOs, Domains - the way the user asked for them.
    private func tabLabel(_ tab: Tab) -> String {
        tab.rawValue
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("Balance")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(verbatim: "\(formatKasExact(entry.balanceSompi)) \(KaspaUnit.symbol)")
                    .font(.title3.weight(.semibold))
            }
            .padding(.top, 12)

            // The app's tab look (`UnderlineTabBar`), not a segmented control.
            UnderlineTabBar(
                tabs: Tab.allCases.map { (tab: $0, title: tabLabel($0)) },
                selection: $selectedTab
            )
            .padding(.top, 4)

            switch selectedTab {
            case .transactions:
                transactionsList
            case .utxos:
                utxosList
            case .kachatDomains:
                AddressDomainsTab(address: entry.address)
            }
        }
        .navigationTitle(entry.displayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A single ToolbarItem with both icons inside an HStack (rather than two separate
            // ToolbarItems) so left-to-right order (Export, then Explorer) is guaranteed - but
            // each icon draws its own circular glass background explicitly, so they read as two
            // distinct pills with a gap between them instead of iOS's automatic toolbar-item
            // grouping merging adjacent trailing items into one shared pill shape.
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 10) {
                    Button {
                        if settingsViewModel.settings.biometricSpendingKeyEnabled {
                            DeviceAuth.authenticate(reason: "Unlock to view this address's private key") {
                                showPrivateKeySheet = true
                            }
                        } else {
                            showPrivateKeySheet = true
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(.regularMaterial))
                    }
                    if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: entry.address) {
                        Link(destination: url) {
                            Image(systemName: "globe")
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(.regularMaterial))
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    showReceiveSheet = true
                } label: {
                    Label("Receive", systemImage: "qrcode")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                Button {
                    showSendSheet = true
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                .disabled(entry.balanceSompi == 0)
                .opacity(entry.balanceSompi == 0 ? 0.5 : 1)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showReceiveSheet) {
            SpendingAddressQRView(entry: entry)
        }
        .sheet(isPresented: $showSendSheet) {
            // Send from this address's own page: it is the From, with no other to pick.
            if let wallet = WalletManager.shared.currentWallet {
                WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: wallet.balanceSompi,
                                  lockedSource: .spending(index: entry.index, address: entry.address,
                                                          label: entry.displayLabel)) {
                    Task {
                        await loadTransactions()
                        await loadUtxos()
                    }
                }
            }
        }
        .sheet(isPresented: $showCompoundSheet) {
            SpendingAddressWithdrawView(entry: entry, isCompoundMode: true, preloadedUtxos: utxos) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
            }
        }
        .sheet(isPresented: $showPrivateKeySheet) {
            SpendingAddressPrivateKeyView(entry: entry)
        }
        .alert(
            "Rename UTXO",
            isPresented: Binding(
                get: { renamingUtxo != nil },
                set: { if !$0 { renamingUtxo = nil } }
            )
        ) {
            TextField("Name", text: $renameUtxoText)
            Button("Save") {
                if let renamingUtxo {
                    WalletManager.shared.setSpendingUtxoLabel(address: entry.address, outpointKey: outpointKey(renamingUtxo), label: renameUtxoText)
                    utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: entry.address)
                }
                renamingUtxo = nil
            }
            Button("Cancel", role: .cancel) {
                renamingUtxo = nil
            }
        }
        .task {
            utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: entry.address)
            // The push used to stutter: both loads fired mid-animation and their state writes
            // re-rendered the lists under it. Let the transition land first, then load history
            // and UTXOs side by side.
            isLoading = true
            isLoadingUtxos = true
            try? await Task.sleep(nanoseconds: 420_000_000)
            async let history: Void = loadTransactions()
            async let coins: Void = loadUtxos()
            _ = await (history, coins)
        }
    }

    private var transactionsList: some View {
        List {
            if isLoading && transactions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if transactions.isEmpty && historyIncomplete {
                // A failed fetch is not an empty history. Saying "No transactions yet." here was
                // a confident answer about someone's money that the app had not actually got.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Could not load transactions.")
                        .foregroundColor(.secondary)
                    Button("Try Again") {
                        Task { await loadTransactions() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else if transactions.isEmpty {
                Text("No transactions yet.")
                    .foregroundColor(.secondary)
            } else {
                if historyIncomplete {
                    // Some pages landed, some did not. Say so rather than letting a truncated
                    // list read as the whole history.
                    Text("Some transactions could not be loaded. Pull to refresh to try again.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                ForEach(transactions, id: \.transactionId) { tx in
                    Button {
                        Haptics.impact(.light)
                        // Tapping a transaction asks what to do with it. It used to open the
                        // explorer outright, which left "Add to Portfolio" on a swipe and a long
                        // press - both invisible until you already knew they were there.
                        transactionActionTarget = tx
                    } label: {
                        transactionRow(tx)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        // The menu is a sheet rather than a confirmation dialog so each option can say what it
        // does, and so the transaction it applies to stays on screen while you choose.
        .sheet(item: $transactionActionTarget, onDismiss: {
            // Handing the portfolio sheet over only once this one is fully gone. Presenting a
            // sheet from inside a sheet that is still dismissing drops it on the floor.
            if let pending = pendingPortfolioCandidate {
                pendingPortfolioCandidate = nil
                portfolioCandidate = pending
            }
        }) { tx in
            TransactionActionsSheet(
                transaction: tx,
                address: entry.address,
                onOpenExplorer: { openInExplorer(tx) },
                onAddToPortfolio: { pendingPortfolioCandidate = $0 }
            )
        }
        .sheet(item: $portfolioCandidate) { candidate in
            AddToPortfolioSheet(candidate: candidate) { portfolio in
                addedPortfolioName = portfolio.name
            }
        }
        .overlay(alignment: .bottom) {
            if let addedPortfolioName {
                PortfolioAddedCapsule(portfolioName: addedPortfolioName) {
                    self.addedPortfolioName = nil
                }
            }
        }
        .refreshable {
            await loadTransactions()
        }
    }

    private var utxosList: some View {
        List {
            if utxos.count > 1 {
                Section {
                    Button {
                        showCompoundSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.merge")
                            Text("Compound UTXOs")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                } footer: {
                    Text("Combines this address's UTXOs to reduce the inputs a future send needs. A single transaction can only merge so many at once, so if this address has a very large number, tap Compound again after it confirms to keep reducing.")
                }
            }
            if isLoadingUtxos && utxos.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if utxos.isEmpty {
                if let utxoLoadError {
                    UtxoLoadFailureRow(detail: utxoLoadError) {
                        Task { await loadUtxos() }
                    }
                } else {
                    Text("No UTXOs.")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(Array(utxos.enumerated()), id: \.offset) { _, utxo in
                    utxoRow(utxo)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadUtxos()
        }
    }

    private func utxoRow(_ utxo: UTXO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: utxo.isCoinbase ? "cube.fill" : "circle.grid.2x2.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let label = utxoLabels[outpointKey(utxo)], !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                }
                Text(verbatim: "\(formatKasExact(utxo.amount)) \(KaspaUnit.symbol)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("\(utxo.outpoint.transactionId):\(utxo.outpoint.index)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if utxo.isCoinbase {
                Text("Coinbase")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            Button {
                renameUtxoText = utxoLabels[outpointKey(utxo)] ?? ""
                renamingUtxo = utxo
            } label: {
                Image(systemName: "pencil")
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func loadUtxos() async {
        isLoadingUtxos = true
        do {
            utxos = try await NodePoolService.shared.getUtxosByAddresses([entry.address])
            utxoLoadError = nil
        } catch {
            // The list keeps what it had; an outage is not an empty address.
            utxoLoadError = UserFacingError.message(for: error)
        }
        isLoadingUtxos = false
    }

    private func transactionRow(_ tx: KaspaFullTransactionResponse) -> some View {
        let info = tx.direction(for: entry.address)
        return HStack(spacing: 12) {
            Image(systemName: info?.isOutgoing == true ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundColor(info == nil ? .secondary : (info!.isOutgoing ? .red : .green))

            VStack(alignment: .leading, spacing: 2) {
                Text(info == nil ? "Transaction" : (info!.isOutgoing ? "Sent" : "Received"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(info == nil ? .secondary : (info!.isOutgoing ? .red : .green))
                Text(tx.transactionId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let blockTime = tx.blockTime {
                    Text(Date(timeIntervalSince1970: Double(blockTime) / 1000).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let info {
                    Text(verbatim: "\(info.isOutgoing ? "-" : "+")\(formatKasExact(info.amountSompi)) \(KaspaUnit.symbol)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(info.isOutgoing ? .red : .green)
                }
                // The network fee this transaction paid (inputs minus outputs). Every
                // transaction has one, whoever sent it; on a received one it is what the
                // sender paid.
                if let fee = tx.feeText() {
                    Text(fee)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatKasExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }

    private func loadTransactions() async {
        isLoading = true
        // Confirmed live against api.kaspa.org that limit=500 works fine in a single call
        // (~0.7s) - cuts this from up to 4 sequential round trips down to 1.
        let result = await walletService.fetchFullTransactionsResult(for: entry.address, pageSize: 200, maxTransactions: 200)
        // block rewards the chain never accepted paid nothing: not history
        transactions = result.transactions.filter(\.belongsInHistory)
        historyIncomplete = !result.complete
        isLoading = false
    }

    private func openInExplorer(_ tx: KaspaFullTransactionResponse) {
        guard let url = settingsViewModel.settings.kaspaExplorer.txURL(for: tx.transactionId) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Bulk address visibility (toolbar checklist on Manage Addresses)

/// Address Visibility: first a card per chain - Quantum Addresses and Non-Quantum Addresses -
/// then that chain's checklist (owner's design, 2026-10-21). One pager over raw indices could
/// never reach the quantum chain, which starts at `quantumIndexBase`. Hide All covers both.
private struct SpendingAddressVisibilityView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [SpendingAddressEntry] = []
    @State private var isLoading = true
    @State private var showHideAllConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    chainCard(quantum: true)
                    chainCard(quantum: false)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle("Address Visibility")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Hide All Addresses?", isPresented: $showHideAllConfirm) {
                Button("Hide All", role: .destructive) { hideAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Manage Addresses starts over with only your chatting address. Nothing is lost: bring any address back here, and its Kaspa still counts in your total.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hide All") { showHideAllConfirm = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task { await load() }
        }
    }

    /// A square tile: the chain, and how many of its addresses Manage Addresses shows.
    private func chainCard(quantum: Bool) -> some View {
        let chain = entries.filter { $0.isQuantum == quantum }
        // The Chatting Address is the legacy list's always-shown #0.
        let chattingRows = quantum ? 0 : 1
        let shown = chain.filter { !$0.hidden }.count + chattingRows
        // Hidden addresses count too: their Kaspa is still in the account's total.
        let balance = chain.reduce(quantum ? 0 : walletManager.currentWallet?.balanceSompi ?? 0) { $0 + $1.balanceSompi }
        return NavigationLink {
            AddressVisibilityChainList(quantum: quantum, entries: $entries, isLoading: isLoading)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: quantum ? "shield.fill" : "circle.grid.2x2.fill")
                            .font(.scaled(size: 26, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Text(quantum ? "Quantum Addresses" : "Non-Quantum Addresses")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("\(shown) of \(chain.count + chattingRows) shown")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(verbatim: KaspaUnit.amount(balance))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(balance > 0 ? .accentColor : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        entries = await walletManager.getSpendingAddressList()
        isLoading = false
    }

    /// Every revealed address hidden, both chains: the list starts from nothing.
    private func hideAll() {
        walletManager.hideAllSpendingAddresses()
        entries = entries.map { var e = $0; e.hidden = true; return e }
    }
}

/// A very compact list of EVERY revealed spending address with a toggleable checkmark per row -
/// checked = shown on the Manage Addresses list. Built for wallets with a hundred-plus revealed
/// addresses: tap through as many rows as you like in one sitting. Each row also shows whether
/// the address has ever been used on-chain (balance counts as used; swept-to-zero addresses are
/// checked against history lazily). The primary address and any address holding a balance can't
/// be hidden - the same rules WalletManager.setSpendingAddressHidden enforces server-side.
private struct AddressVisibilityChainList: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var walletService: WalletService

    /// Which chain this list pages: the quantum chain lives at `quantumIndexBase` and up, so
    /// one pager over raw indices never reached it (its first page was #20,000).
    let quantum: Bool
    @Binding var entries: [SpendingAddressEntry]
    let isLoading: Bool
    /// Lazily-filled history results for zero-balance addresses (address -> ever used).
    @State private var usedByAddress: [String: Bool] = [:]
    /// Pager: 50 addresses per page, endless - pages past the revealed set derive future
    /// indices on the fly (checking one reveals it without flooding the main list).
    @State private var page = 0
    private let pageSize = 50
    /// The rows for the current page, by raw index order - STATE, rebuilt by `rebuildPage()`,
    /// never derived inside `body`. The old computed-property version called the public
    /// `walletManager.spendingAddress(at:)` once per beyond-revealed row during body
    /// evaluation: 50 separate Secure Enclave seed decrypts + PBKDF2 runs on the main thread
    /// per page render (and an all-nil page - i.e. a blank list - whenever the keychain read
    /// transiently failed), which is why tapping the next page appeared to load nothing.
    /// `rebuildPage()` derives the whole page through one shared change-key derivation instead.
    @State private var pageEntries: [SpendingAddressEntry] = []

    var body: some View {
        Group {
            if isLoading && entries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if pageEntries.isEmpty {
                            Text("These addresses couldn't be derived right now. Go back a page or reopen this screen to retry.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .listRowSeparator(.hidden)
                        }
                        if !quantum, page == 0, let wallet = walletManager.currentWallet {
                            chattingRow(wallet)
                        }
                        ForEach(pageEntries) { entry in
                            row(entry)
                        }
                    }
                    .listStyle(.plain)
                    // New identity per page: guarantees a fresh list AND resets the scroll
                    // position to the top on every page transition.
                    .id(page)
                }
            }
            .safeAreaInset(edge: .bottom) {
                pagerBar
            }
            .navigationTitle(quantum ? "Quantum Addresses" : "Non-Quantum Addresses")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { rebuildPage() }
            .onChange(of: page) { _ in rebuildPage() }
            .onChange(of: entries) { _ in rebuildPage() }
    }

    /// Recomputes the current page's rows: revealed indices come from the loaded entries;
    /// anything beyond derives its address through ONE shared change-key derivation
    /// (`spendingAddresses(inRange:)` - single seed decrypt for the whole page). Unrevealed
    /// rows render unchecked.
    private func rebuildPage() {
        let byIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0) })
        let start = (quantum ? WalletManager.quantumIndexBase : 0) + page * pageSize
        let range = start..<(start + pageSize)
        let derived = walletManager.spendingAddresses(inRange: range)
        pageEntries = range.compactMap { index -> SpendingAddressEntry? in
            if let existing = byIndex[index] { return existing }
            guard let address = derived[index] else { return nil }
            return SpendingAddressEntry(
                index: index, address: address, balanceSompi: 0,
                isCurrent: false, everUsed: false, label: nil, hidden: true
            )
        }
    }

    /// Bottom pager: "#start - #end" with arrows; the right arrow never runs out (pages past
    /// the revealed set derive future addresses).
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
            Text("#\(pagerRange.lowerBound) - #\(pagerRange.upperBound)")
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

    /// The numbers on the current page. The legacy chain's first page also holds #0, the
    /// Chatting Address.
    private var pagerRange: ClosedRange<Int> {
        let first = (quantum ? WalletManager.quantumIndexBase : 0) + page * pageSize
        let lower = !quantum && page == 0 ? 0 : WalletManager.addressNumber(forIndex: first)
        return lower...WalletManager.addressNumber(forIndex: first + pageSize - 1)
    }

    /// #0: always shown on Manage Addresses, so it's checked and tapping it does nothing.
    private func chattingRow(_ wallet: Wallet) -> some View {
        HStack(spacing: 10) {
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
            if let balance = wallet.balanceSompi, balance > 0 {
                Text(verbatim: "\(String(format: "%.4f", Double(balance) / 100_000_000.0)) \(KaspaUnit.symbol)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
        }
        .listRowSeparatorTint(Color.secondary.opacity(0.2))
    }

    private func row(_ entry: SpendingAddressEntry) -> some View {
        let funded = entry.balanceSompi > 0
        // Every row toggles both ways - funded ones too (Hide All starts the list over).
        let visible = !entry.hidden
        let locked = false
        return HStack(spacing: 10) {
            Image(systemName: visible ? "checkmark.circle.fill" : "circle")
                .font(.scaled(size: 20))
                .foregroundColor(visible ? .accentColor : .secondary)
                .opacity(locked ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // The chain-local number; the shield marks the quantum chain's rows apart
                    // from the legacy chain's same numbers.
                    Text("#\(WalletManager.addressNumber(forIndex: entry.index))")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    if entry.isQuantum {
                        Image(systemName: "shield")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if let label = entry.label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Text("\(entry.address.prefix(16))…\(entry.address.suffix(6))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            usedTag(entry, funded: funded)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(entry) }
        .listRowSeparatorTint(Color.secondary.opacity(0.2))
        .task(id: entry.address) { await ensureUsedLoaded(entry, funded: funded) }
    }

    @ViewBuilder
    private func usedTag(_ entry: SpendingAddressEntry, funded: Bool) -> some View {
        if funded {
            Text(verbatim: "\(String(format: "%.4f", Double(entry.balanceSompi) / 100_000_000.0)) \(KaspaUnit.symbol)")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.accentColor)
        } else if let used = usedByAddress[entry.address] {
            Text(used ? "Used" : "Unused")
                .font(.caption2.weight(.semibold))
                .foregroundColor(used ? .orange : .secondary)
        } else {
            Text("…")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// One history lookup per zero-balance address, cached for the session of this sheet.
    /// A failed probe stores nothing, so the row keeps its neutral "…" badge (never a
    /// possibly-wrong "Unused") and the next appearance of the row retries.
    private func ensureUsedLoaded(_ entry: SpendingAddressEntry, funded: Bool) async {
        guard !funded, usedByAddress[entry.address] == nil else { return }
        if let used = await walletService.spendingAddressUsedState(entry.address) {
            usedByAddress[entry.address] = used
        }
    }

    private func toggle(_ entry: SpendingAddressEntry) {
        Task {
            // Per chain: a quantum slot (1,000,000+) must not hide that a legacy row lies past the
            // legacy bound - the row would only be unhidden and the bound never extended.
            let revealedMax = entries.filter { $0.isQuantum == entry.isQuantum }.map(\.index).max()
                ?? (entry.isQuantum ? WalletManager.quantumIndexBase - 1 : -1)
            if entry.index > revealedMax {
                // A derived future index from the endless pager: reveal exactly this one
                // (indices in between stay hidden so the main list doesn't flood).
                await walletManager.revealSpendingAddress(at: entry.index)
                entries = await walletManager.getSpendingAddressList()
            } else {
                let ok = await walletManager.setSpendingAddressHidden(index: entry.index, hidden: !entry.hidden)
                guard ok else { return }
                if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                    var updated = entries[position]
                    updated.hidden.toggle()
                    entries[position] = updated
                }
            }
        }
    }
}

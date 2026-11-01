import Foundation
import SwiftUI

/// The bell on the Wallet tab holds two things:
/// - Kaspa arriving in one of your own addresses - the chatting address, a spending address, cold
///   storage (fed by AddressActivityNotifier);
/// - your .kachat names: offers, sales, renewal and expiry, what happened to your offers
///   (`KachatNamesNotifier`).
/// Entries are account-scoped, persisted, deduped by id, and capped; opening the list marks
/// everything seen.
@MainActor
final class GlobalNotificationCenter: ObservableObject {
    static let shared = GlobalNotificationCenter()

    struct Entry: Identifiable, Codable, Equatable {
        enum Source: String, Codable {
            case wallet
            /// a .kachat name event; `targetId` is the name
            case kachat

            var label: String {
                switch self {
                case .wallet: return "Wallet"
                case .kachat: return ".kachat"
                }
            }

            var icon: String {
                switch self {
                case .wallet: return "arrow.down.circle"
                case .kachat: return "at"
                }
            }
        }

        let id: String
        let source: Source
        let title: String
        let body: String
        let timestamp: Int64 // ms
        /// The address that got the Kaspa, or the .kachat name - what tapping the row opens.
        let targetId: String?
    }

    /// One stored entry; nil for a row this build no longer lists (KaChat's chat, group and
    /// KaPosts rows an older build saved), so one of those never fails the whole list's decode.
    private struct StoredEntry: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var lastSeenAt: Int64 = 0

    private let maxEntries = 100

    var unreadCount: Int {
        entries.filter { $0.timestamp > lastSeenAt }.count
    }

    private init() {
        reload()
    }

    // MARK: - Persistence (account-scoped)

    private var walletAddress: String { WalletManager.shared.currentWallet?.publicAddress ?? "" }
    private var entriesKey: String { "globalNotifCenter.entries.\(walletAddress)" }
    private var seenKey: String { "globalNotifCenter.seenAt.\(walletAddress)" }

    /// Delete Account: one wallet's feed, from this device.
    static func removeAllData(forWalletAddress walletAddress: String) {
        UserDefaults.standard.removeObject(forKey: "globalNotifCenter.entries.\(walletAddress)")
        UserDefaults.standard.removeObject(forKey: "globalNotifCenter.seenAt.\(walletAddress)")
    }

    /// Call on account switch (and at init) to load the active wallet's feed.
    func reload() {
        if let data = UserDefaults.standard.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([StoredEntry].self, from: data) {
            let kept = decoded.compactMap(\.entry)
            entries = kept
            if kept.count != decoded.count { persist() }
        } else {
            entries = []
        }
        lastSeenAt = (UserDefaults.standard.object(forKey: seenKey) as? NSNumber)?.int64Value ?? 0
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(entries.prefix(maxEntries))) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }

    // MARK: - Feed mutations

    func record(id: String, source: Entry.Source, title: String, body: String, timestamp: Int64, targetId: String?) {
        guard !id.isEmpty, !entries.contains(where: { $0.id == id }) else { return }
        entries.insert(Entry(id: id, source: source, title: title, body: body, timestamp: timestamp, targetId: targetId), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        persist()
    }

    func markAllSeen() {
        lastSeenAt = Int64(Date().timeIntervalSince1970 * 1000)
        UserDefaults.standard.set(NSNumber(value: lastSeenAt), forKey: seenKey)
    }

    func clearAll() {
        entries = []
        persist()
    }
}

/// The bell's sheet: newest-first feed of all sources, source-tagged rows, Clear all.
/// Opening it marks everything seen (clears the bell badge).
struct GlobalNotificationListView: View {
    @ObservedObject private var center = GlobalNotificationCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if center.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bell")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No notifications yet")
                            .font(.headline)
                        Text("Kaspa arriving in your wallets and news about your .kachat names show up here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(center.entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.source.icon)
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                    .font(.subheadline.weight(.semibold))
                                if !entry.body.isEmpty {
                                    Text(entry.body)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                HStack(spacing: 6) {
                                    Text(entry.source.label)
                                    Text(Date(timeIntervalSince1970: TimeInterval(entry.timestamp) / 1000)
                                        .formatted(.relative(presentation: .named)))
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        // Every row opens its subject the way the OS notification tap does.
                        .contentShape(Rectangle())
                        .onTapGesture { open(entry) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear All") { center.clearAll() }
                        .disabled(center.entries.isEmpty)
                }
            }
            .onAppear { center.markAllSeen() }
        }
    }

    /// Routes a tapped row to its subject. The sheet has to close first (only one sheet presents
    /// at a time), so the pending target is staged now and the tab switch posted after the
    /// dismissal animation - the same two-step every notification tap uses.
    private func open(_ entry: GlobalNotificationCenter.Entry) {
        let target = entry.targetId ?? ""
        switch entry.source {
        case .wallet:
            // A receipt opens the history of the address that got the Kaspa (main, spending or
            // cold storage - MainTabView works out which), as a tapped banner does. Entries
            // recorded before receipts carried their address fall back to the wallet screen.
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if !target.isEmpty {
                    OwnAddressRoute.pending = target
                    NotificationCenter.default.post(name: .openOwnAddress, object: nil)
                } else {
                    NotificationCenter.default.post(name: .openPortfolio, object: nil)
                }
            }
        case .kachat:
            // The name, the same way a tapped .kachat push opens it.
            guard !target.isEmpty else { return }
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                KachatDeepLink.pendingName = KachatNames.Codec.normalize(target)
                PendingTabRoute.pending = .kachatNames
                NotificationCenter.default.post(name: .openKachatName, object: nil)
            }
        }
    }
}

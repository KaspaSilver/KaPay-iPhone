import SwiftUI

/// Who is behind the address a screen has resolved - the card the send screens show,
/// for every other place an address or a domain goes in (withdrawals, sends from an address,
/// the portfolio, a group invite). The SCREEN does the resolving (.kachat first, see
/// `NameServicesClient.resolveEverywhere`); this card takes the outcome and shows the face and
/// the name: the domain that was typed, else the address's own .kachat name. Nil address, no card - a half-typed
/// address gets nothing rather than a card flickering through wrong faces.
struct AddressResolutionCard: View {
    /// The address the input stands for: a valid typed address, or a domain's resolved owner.
    let address: String?
    /// The domain that resolved to it, when the user typed one (shown at once, before the
    /// profile fetch lands).
    var domain: String? = nil
    /// Only the address counts here (a signature proves it, and says nothing of any name).
    var addressOnly = false

    @State private var profile: KNSAddressProfileInfo?
    @State private var isLoadingProfile = false
    /// re-renders when the address's .kachat identity lands (`cachedIdentity` fills in the background)
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared

    /// The name to show: the domain typed, else the address's .kachat name.
    private func displayName(for address: String) -> String? {
        if let domain { return domain }
        if let label = kachatRegistry.cachedIdentity(for: address)?.label { return "\(label).kachat" }
        return profile?.domainName
    }

    var body: some View {
        if let address, !address.isEmpty {
            HStack(spacing: 12) {
                KNSAvatarView(
                    avatarURLString: profile?.avatarURL,
                    fallbackText: displayName(for: address) ?? address,
                    size: 44,
                    contactAddress: address
                )
                VStack(alignment: .leading, spacing: 2) {
                    let name = displayName(for: address)
                    if !addressOnly {
                        Text(name ?? (isLoadingProfile ? "Looking up..." : "No domain"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(name == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    Text(address)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // one of this wallet's own addresses: you are sending to yourself
                    if let own = WalletManager.shared.ownAddressLabel(for: address) {
                        Label(String(format: AppLocalization.string("Your own address: %@"), own),
                              systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isLoadingProfile { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .task(id: address) { await loadProfile(for: address) }
        }
    }

    /// Cached by KNSService, so an address already looked at costs nothing.
    /// A new address starts clean - never the previous one's avatar or name while it loads - and
    /// the spinner always stops, a cancelled lookup included (IOS-074).
    private func loadProfile(for address: String) async {
        profile = nil
        isLoadingProfile = false
        guard KaspaAddress.isValid(address) else { return }
        if let cached = KNSService.shared.profileCache[address] {
            profile = cached
            return
        }
        isLoadingProfile = true
        // a lookup for an address the card no longer shows leaves the newer one's spinner alone
        defer { if address == self.address { isLoadingProfile = false } }
        let fetched = await KNSService.shared.fetchProfile(for: address)
        guard !Task.isCancelled, address == self.address else { return }
        profile = fetched
    }
}

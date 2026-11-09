import SwiftUI

/// The .kachat names guide: claim a name, how a name works, make it your name, keep it. Opened
/// from Wallet > Help. About the name only - an avatar, banner and bio are not part of a name
/// (they are the address's profile, set in KaChat or KaPost).
struct KachatSetupGuideView: View {
    let onClose: () -> Void

    private enum Step: Int, CaseIterable {
        case claim, howItWorks, useIt, keepIt, finished
    }

    @State private var step: Step = .claim

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        progressDots
                        content
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                KNSWizardBottomBar(
                    nextTitle: step == .finished ? "Done" : "Next",
                    onBack: previous.map { target in { withAnimation { step = target } } },
                    onNext: {
                        if let next = Step(rawValue: step.rawValue + 1) {
                            withAnimation { step = next }
                        } else {
                            onClose()
                        }
                    }
                )
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(".kachat Names")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
        }
    }

    private var previous: Step? {
        Step(rawValue: step.rawValue - 1)
    }

    /// One dot per step before the last, filled up to the current one.
    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.filter { $0 != .finished }, id: \.self) { dot in
                Capsule()
                    .fill(dot.rawValue <= step.rawValue ? Color.accentColor : Color(.systemGray4))
                    .frame(width: dot == step ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .claim:
            stepHeader(
                title: "Claim your .kachat name",
                subtitle: "It's the name people see you as across KaChat and on your profile link. Without one, people see your address."
            ) {
                KachatTabIcon.view(side: 56)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("yourname")
                        .foregroundColor(Color(.placeholderText))
                    Spacer()
                    Text(".kachat")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(fieldBackground)
                Text("Search for the name you want in the .kachat tab, then claim it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .howItWorks:
            stepHeader(
                title: "How a name works",
                subtitle: "Your name lives on the Kaspa network, held by your chatting address. Nobody can take it or change it while it's yours."
            ) {
                Image(systemName: "seal.fill")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundColor(.accentColor)
            }
            bulletList([
                "Claiming takes two quick transactions: the first keeps your pick secret, the second registers it.",
                "You pay for one period at a time. Shorter names cost more.",
                "The price goes to the network's miners, not to KaChat."
            ])

        case .useIt:
            stepHeader(
                title: "Make it your name",
                subtitle: "Set it as your primary name and it's how you appear everywhere in KaChat."
            ) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundColor(.accentColor)
            }
            bulletList([
                "People can find you by typing your name.",
                "They can send you Kaspa to yourname.kachat instead of a long address.",
                "Your profile link shows your name."
            ])

        case .keepIt:
            stepHeader(
                title: "Keep it",
                subtitle: "Your names are in Wallet > Your Domains > .kachat."
            ) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundColor(.accentColor)
            }
            bulletList([
                "Renew before it expires. It shows when, on each name.",
                "After it expires there's a grace period to renew it before anyone else can claim it.",
                "You can transfer it, list it for sale, or accept an offer for it."
            ])

        case .finished:
            stepHeader(
                title: "You're all set",
                subtitle: "Claim your name in the .kachat tab whenever you're ready."
            ) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundColor(.accentColor)
            }
        }
    }

    private func bulletList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                    Text(LocalizedStringKey(line))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(fieldBackground)
    }

    private func stepHeader<Icon: View>(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(spacing: 10) {
            icon()
                .frame(height: 64)
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

/// The wizard's fixed two-button footer: Previous left, Next right, same place on every step so
/// it can be tapped through without chasing buttons. Matches the KaChat setup guide's bar.
///
/// A disabled Previous renders dimmed rather than vanishing, so Next never moves between steps.
struct KNSWizardBottomBar: View {
    var nextTitle: String = "Next"
    var onBack: (() -> Void)?
    var onNext: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button { onBack?() } label: {
                Text("Previous")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(onBack == nil)
            .opacity(onBack == nil ? 0.35 : 1)

            Button { onNext?() } label: {
                Text(LocalizedStringKey(nextTitle))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(onNext == nil)
            .opacity(onNext == nil ? 0.5 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

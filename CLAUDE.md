# CLAUDE.md

Guidance for Claude Code in this repository.

## What KaPay is

KaPay (named KaChat Wallet until 2026-10-27) is a standalone iOS Kaspa wallet, split out of KaChat so KaChat can stay focused on
1:1 and group chats. It keeps KaChat's wallet features: Portfolio, Cold Storage, the .kachat names
marketplace, Contacts and the account's Wallet tab (receive, send, addresses, domains, help,
about).

The source started as a copy of KaChat-iPhone (`KaspaSilver/KaChat-iPhone`) at commit `b603eb9f`
(2026-10-24). Everything that was not the wallet has been removed (2026-10-25 calls; 2026-10-27
1:1, group and public chats, KaPosts, Chess, Swap, bots, voice/Opus, the message store, chat push
and sync, the app-extension data sharing). There is no chat code left: don't bring any back.
The wallet's identity address keeps KaChat's name, "Chatting Address", in code and UI alike: the
wallet is part of the KaChat ecosystem (owner's call, 2026-10-27). Don't rename it.

Saved addresses are **Contacts** in everything people read (named the Address Book until
2026-10-28): the Wallet tab's Contacts card, the Contacts pill under a recipient field, Settings >
Storage's Contact Photos. The code keeps its names (`AddressBookManager`, `AddressBookView`,
`AddressBookEntry`).

## Dock

Five fixed tabs (`AppTab` in `KaChatWallet/Models/Models.swift`, rendered by
`KaChatWallet/App/MainTabView.swift`):

| Tab | View |
|---|---|
| Portfolio | `PortfolioView` (`Views/Portfolio/`) |
| Cold Storage | `ColdStorageListView` (`Views/ColdStorage/`) |
| Wallet | `ProfileView` (`Views/Contacts/ContactsView.swift`, `AppTab.profile`) - the home tab, where the app opens after logging in; receive, the Chatting Address, Manage Addresses, Your Domains, Contacts (`AddressBookView`, as a sheet), help, about; a floating up/down arrow (bottom right, as in KaChat) opens a half sheet: Send Kaspa, Receive Kaspa, Request Payment (`CreatePaymentRequestView`) |
| .kachat | `KachatMarketView` (`Views/Ecosystem/`); dock icon `KachatTabIcon.domainsImage` (name tag with an @) - the full .kachat names marketplace: the logo and four numbered cards (Marketplace, Available, Expired, Activity), each opening its page; only the Marketplace has the name search. Search, buy, claim, sell, offers, activity |
| Settings | `SettingsView(isDockTab: true)` (`Views/Settings/SettingsView.swift`, `AppTab.settings`) - no Done button as a tab; Delete Account (`DeleteAccountSheet`, the warning the sign-in screen's Delete also shows; `WalletManager.deleteCurrentAccount`) and Log Out are its last rows |

Account setup: `ContentView` -> `OnboardingView` (create / import a seed) -> `MainTabView`. Create
New Account makes an account in one tap: 24 words, no passphrase, the next free default name
(`WalletManager.nextDefaultAccountName`: My Account, My Account 2 and on). "Advanced: Create with a
Passphrase" (`CreateWalletView`) is the only other way: also 24 words, through
`PassphraseOptionView`. Import still takes 12 or 24 words. Creating never shows the seed phrase: an
account made here is owed a backup (`AccountBackupStatus`), and until the backup steps
(`AccountBackupView`: why, get ready, the words six at a time, a check of four random words, the
passphrase and its check if there is one, where to keep them) are finished, the Wallet tab shows
`AccountBackupCard` above Manage Addresses (red once the account holds funds), Receive shows a
reminder and the Delete Account warning leads with Back Up Account; deleting is never blocked. The
steps never offer a copy; Settings > View Seed Phrase does. Imported and older accounts are never
owed one. Finishing the steps starts a six-month timer (`AccountBackupStatus`); when it runs out
the Wallet tab shows `BackupHygieneCard` in the same place, and `BackupHygieneView` asks for five
random words in random order on `SeedPhraseKeyboardView`, then the passphrase if the account has
one. Passing, or Can't Complete This and the backup steps again, starts the timer over; closing
leaves the card up. The passphrase entry screen shows the chatting address and its balance as you type, so
someone importing can tell they typed the right one. Every sign-in gets new tabs (`ContentView`'s
`signInSession`, the `MainTabView` id, bumped on sign-out), opening on Wallet; without it SwiftUI
brought the last account's tabs back, on Settings and with no onAppear.

The sign-in screen says "KaPay" with the wallet logo and no tagline. The rename kept every identifier
(bundle ID, keychain group, URL scheme, folder and target names `KaChatWallet`): only what people
read says KaPay. Texts about the KaChat ecosystem (KaChat profiles, .kachat names, the Nextcloud
`KaChat` folder) still say KaChat.

The Wallet tab keeps KaChat's profile (Receive, Chatting Address, Edit KaChat Profile, Your Domains,
share link); Help has only the .kachat names guide. The bell (`GlobalNotificationCenter`) lists
"Received" and .kachat notifications.

## Send Kaspa (and every other send)

Every screen that moves Kaspa is the same steps, built from the shared pieces in
`Views/Shared/SendKaspaComponents.swift`. Change those pieces, not one screen.

1. **To**: `SendStepScreen` + `SendStepQuestion` ("Who are you sending to?") + `SendRecipientCard`
   (address or name; Paste, Scan QR and Addresses pills under the field). Cancel sits at the
   bottom beside Continue (`SendContinueButton`) on a first step; later steps have Back and Cancel
   in the header (`SendStepHeader`).
2. **From**: "Where are you sending from?": the Chatting Address and Choose an Address pills;
   Choose an Address lists your addresses right on the screen (`OwnAddressList`, no sheet).
   Skipped when the From is fixed (an address's own Send).
3. **Amount**: `KaspaKeypadAmountEntry`, the app's own number pad (`KaspaKeypad`, `KeypadAmountText`),
   so no system keyboard covers the screen; "To" and "From" chips, the KAS / currency switch and
   Max; the From address's balance is the footnote's Available.
4. **Review**: `SwipeUpToSendScrollView` with Back: the amount, To, From, Total. Nothing can change
   but the fee and coin control (`SendFeeControls`); a Max amount is worked out again when they
   change. The fee's Edit (`onEditFee`) opens `SendFeeEditorScreen` (the fee typed on the keypad,
   never under the network's minimum, warned above ten times it); Confirm goes back to the review.

Where each screen uses them:
- `WithdrawKaspaView` (`Views/Contacts/ContactsView.swift`): the Wallet tab's Send, an address's
  Send, a contact's, paying a payment request, Compound UTXOs. A pre-filled recipient or a
  payment request opens on From (a request's amount is fixed: no keypad), Compound on the review.
- Cold Storage (`ColdSendFlowView`): To, Amount ("To" / "From Cold Storage" chips, `SendStepChip`),
  Review (fee Edit, Coin Control) ending in Build Unsigned Transaction; then **Sign with KasSigner**
  (the animated QR, Scan Signed Transaction opens the scanner, closing it returns to the QR) and
  the **signed** screen ("Signed by KasSigner", the summary) with swipe up to send: the BlockDAG,
  Sent, or Failed with Try Again (still signed). Compound opens on the review.
- Manage Addresses' compound (`SpendingAddressWithdrawView`): the review with the fee editor.
- Request Payment (`CreatePaymentRequestView`, `Views/Shared/PaymentRequestViews.swift`): the same
  step screens the other way round: "Where do you want to be paid?" (Fresh Address, or Choose an
  Address with the list right on the screen: `OwnAddressList`, the list `OwnAddressPicker`'s sheet
  also shows), "How much?" on the keypad, then the review with the memo, Copy Payment Request (the
  bottom button) and Share.
- .kachat (`KachatTxSheet`, `Views/Ecosystem/KachatNamesLiveViews.swift`): an entry step when the
  action takes one (`entryQuestion`: Make an Offer and List / Change Price on the keypad,
  Transfer on the recipient card), then the review with the fee editor and swipe up
  (`KachatSwipeUp`; "Swipe up to Confirm" for the rest: delist, release, withdraw, refund, accept,
  decline). Renew is "How long?" then the review; Buy and Extend are the review. Claiming a name
  (`KachatClaimSheet`) is "For how long?" (a button per length with its price; a tap goes on),
  then a costs-only review with the fee's Edit and swipe up to claim. A typed claim fee becomes a
  rate (`customFeerate`, in proportion to the quote's) that the commit and the register both pay
  (`PendingRegistration.customFeerate`). Search results say only Available or Taken: no price
  per year, since a name's first year and later years cost differently.

## Services

- `WalletService` (`Services/WalletService*.swift`): the node connection, the live UTXO
  subscription to the wallet's own addresses (main, spending, cold storage; re-subscribed when a
  cold account or a new primary appears), sending (`WalletService+Sending`) and Kaspa REST reads
  (`WalletService+Transactions`). Live batches go to `AddressActivityNotifier` and a balance
  refresh; without a subscription a 60s poll refreshes the balance and catches up receives.
- `WalletManager`: accounts, keys, spending addresses. `AddressBookManager`, `ColdStorageManager`,
  `PortfolioManager`/`PortfolioViewModel`, `KNSService` and `KachatNames*` as their names say.
- `NextcloudService`: backs up Contacts and the Portfolio, nothing else, as two plain
  JSON files in the `KaChat` folder - never KaChat's `kachat-backup.json`:
  `KaPay Contacts.json` (the contacts export file, `AddressBookManager.ExportFile`,
  with photos) and `KaPay Portfolio.json` (`PortfolioBackupFile`: portfolios,
  transactions, fees and deletion tombstones); a restore falls back to the earlier names
  (`KaPay Address Book.json`, then `KaChat Wallet …`). Connect with an app password. Automatic Backup
  (off by default) uploads a few seconds after either changes and on background, and merges in
  what's on the server when the app opens, at most once a minute (`syncWithServerOnOpen`). Every
  backup merges the server's copies in first (`PortfolioSync.merge`,
  `AddressBookManager.mergeBackup`; newest edit or deletion wins, the Contacts file carries its
  deletions in `deleted`), so two devices don't overwrite each other. A Contacts file uploaded by
  another account (`walletAddress`) isn't merged. Restore and a fresh connection merge both back
  (`AddressBookManager.importExport`, `PortfolioViewModel.importFromArchive`). Contacts and
  Portfolio import/export can also use the KaChat folder.
- `KachatNamesRegistry` reads .kachat names through `AppSettings.indexerURL` (Settings >
  Connection > Domains, editable so anyone can run their own indexer; blank = the network's
  default) while it serves this registry and keeps up, else walks the chain itself; the Domains
  tab shows which.
- `AppSettings` (`Models/Models.swift`) holds only wallet settings; a blob from an older build
  (with KaChat's chat settings) still decodes, every field falling back to its default.

## Logo

`tools/make_logo.py` draws the logo and the app icons (teal wallet, KaChat's backward K - the same shape as KaChat's icon - in the
middle). Variants: `logo` (white rounded square, the in-app `KaChatWalletLogo` image, 512 px) and
the 1024 px app icons `light` (white), `dark` (near-black) and `tinted` (grayscale on black):

```bash
python3 tools/make_logo.py KaChatWallet/Resources/Assets.xcassets/KaChatWalletLogo.imageset/KaChatWalletLogo.png 512 logo
python3 tools/make_logo.py KaChatWallet/Resources/Assets.xcassets/KaChatWalletLogoDark.imageset/KaChatWalletLogoDark.png 512 dark
for v in light dark tinted; do python3 tools/make_logo.py KaChatWallet/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-$v.png 1024 $v; done
```

## Identifiers

- Bundle ID `com.kachat.wallet`, keychain group `$(AppIdentifierPrefix)com.kachat.wallet`, URL
  schemes `kapay` (what KaPost opens to pay a request: `kapay://pay/<address>?...`, the same
  tail as `kachat://pay/`) and `kachatwallet` (its old name, still accepted), background task `com.kachat.wallet.messageFetch` (the name is historical;
  it refreshes the balance). None of these are shared with KaChat, so the two apps never read each
  other's keychain or storage.
- Team `RP4Z22SFSD` (the KaChat developer's Apple team; the wallet ships under that account)
- Version: `KaChatWallet/Version.xcconfig` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`)

## Build

The project uses a file-system-synchronized folder: every file under `KaChatWallet/` is in the
app target automatically (no pbxproj edits for new files). Exceptions (Info.plist, entitlements,
Version.xcconfig) are listed in the project's exception set.

```bash
xcodebuild -project KaChatWallet.xcodeproj -scheme KaChatWallet -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

Claude writes the code and never tests it - no Simulator driving, screenshots or verification
builds; the owner does all testing. When the owner says "rebuild", build with the command above
and install + launch the app in the Simulator, then stop. Device and App Store builds are the
owner's.

## Push

The wallet registers with KaChat's push service for "Received KAS" (its own addresses as
`watch_only_addresses`) and .kachat name events (`primary_address`), with `apns_topic` =
`com.kachat.wallet` - no chats, rooms or KaPosts. "Received" is only for Kaspa from someone
else: a tx with any input from the wallet's own addresses never notifies, including one sent by
another app on the same seed (KaPosts, KaChat). `AddressActivityNotifier` matches inputs the
REST API hasn't resolved yet against the coins the live batches just spent, by outpoint. With remote push
registered the app announces a receive only while it is open (the push covers the rest, and the open
app hides it); the catch-up never re-announces history: only receives newer than each address's floor,
newest first, up to the balance increase. With Address Activity off it stays registered
through `primary_address` alone. Registration and updates are signed like KaChat's
(`PushNotificationManager.buildPushAuth`); the chat fields (`watched_addresses`,
`watched_group_ids`, aliases) are always empty. A `name_event` push has no thread id (the wallet
has no notification extension); a tap routes by its `type` and `name`. Settings > Notifications is one page:
Push Notifications, Address Activity, sound, vibration. It asks for notification permission once, when
its tabs first show. Entitlements carry `aps-environment` (development / production). The service
still has to send on the wallet's topic and skip chat pushes for it: see `PUSH_SERVICE.md`.

## Server hand-offs

This session never changes the server's code. When kachat-indexer
(`/Users/restosaved/KaChat Server/kachat-indexer`, `KaspaSilver/KaChat-Indexer`) needs a change,
write a hand-off doc in that repo's `docs/` (one per change, e.g. `docs/KACHAT_WALLET_PUSH.md`),
in its format: a dated title, "**For:** the indexer session. **From:** the KaPay (KaChat Wallet) iOS
session", then what the app sends and expects, the rule, where in the server it goes, the wallet
commits, and how to test. Commit and push only that doc there; the indexer session builds from it.

## Protocol and servers

Same as KaChat: the node pool for balances and transactions, the Kaspa REST API and CoinGecko for
Portfolio, the KaChat indexer for push and .kachat names. The protocol and server docs live in
KaChat-iPhone (`KACHAT_NAMES.md`, `PUSH_NOTIFICATIONS.md`).

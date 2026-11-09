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
| Wallet | `ProfileView` (`Views/Contacts/ContactsView.swift`, `AppTab.profile`) - the home tab, where the app opens after logging in; as on KaChat's Wallet tab (`WalletView` there), the total balance split into chatting and spending (`WalletBalanceCard`), Send, Receive and Request (`CreatePaymentRequestView`), Backup Hygiene when due, and the Manage Addresses and Chatting Address squares; then Your Domains, Contacts (`AddressBookView`, its own pushed screen) and help. No profile card: those belong to KaChat and KaPost. About is in Settings |
| .kachat | `KachatMarketView` (`Views/Ecosystem/`); dock icon `KachatTabIcon.domainsImage` (name tag with an @) - the full .kachat names marketplace: the logo and four numbered cards (Marketplace, Available, Expired, Activity), each opening its page; only the Marketplace has the name search. Search, buy, claim, sell, offers, activity |
| Settings | `SettingsView(isDockTab: true)` (`Views/Settings/SettingsView.swift`, `AppTab.settings`) - no Done button as a tab; alphabetical rows with no descriptive text, as in KaChat: Account Name, Back Up Account (Complete Your Backup, View 12 or 24 Words, Back Up to NFC Card), Connection, Customization, Diagnostics, Notifications, Security, Storage; then Delete Account (`DeleteAccountSheet`, the warning the sign-in screen's Delete also shows; `WalletManager.deleteCurrentAccount`) and Log Out |

Account setup: `ContentView` -> `OnboardingView` (create / import a seed) -> `MainTabView`. Create
New Account makes an account in one tap: 24 words, no passphrase, the next free default name
(`WalletManager.nextDefaultAccountName`: My Account, My Account 2 and on). "Advanced: Create with a
Passphrase" (`CreateWalletView`) is the only other way: also 24 words, through
`PassphraseOptionView`. Import still takes 12 or 24 words. Creating never shows the seed phrase: an
account made here is owed a backup (`AccountBackupStatus`), and until the backup steps
(`AccountBackupView`: why, get ready, the words six at a time, a check of four random words, the
passphrase and its check if there is one, where to keep them) are finished, every tab shows
`AccountBackupBanner` under the balance and just above each tab's title (`pinnedTabHeader`; .kachat has no title) (red once the account holds funds, spending addresses
included) and the Delete Account warning leads with Back Up Account; deleting is never blocked. The
steps never offer a copy; Settings > Back Up Account > View 12 or 24 Words does. Imported and older accounts are never
owed one. Finishing the steps or importing starts a six-month timer (`AccountBackupStatus`); when
it runs out the Wallet tab shows `BackupHygieneCard` under Send, Receive and Request, and `BackupHygieneView` asks for five
random words in random order on `SeedPhraseKeyboardView`, then the passphrase if the account has
one. Passing, or Can't Complete This and the backup steps again, starts the timer over; closing
leaves the card up. The passphrase entry screen (`PassphraseAddressPreview`) shows the chatting address and its
balance as you type, so someone importing can tell they typed the right one. On import it checks
the first 50 identity addresses, picks the first with funds, lists any others to choose from, and
imports onto the chosen one (`WalletManager.findChattingAddresses`). Every sign-in gets new tabs (`ContentView`'s
`signInSession`, the `MainTabView` id, bumped on sign-out), opening on Wallet; without it SwiftUI
brought the last account's tabs back, on Settings and with no onAppear.

**NFC card backup** (`Services/NFCCard.swift`, in production builds since 2026-11-04;
`NFCCard.isAvailable` hides it where NFC can't read these cards, such as iPad): an extra copy of the words of a seed phrase
the user already has, on a Java Card loaded with
[KaChat-NFC](https://github.com/KaspaSilver/KaChat-NFC) through Kaspa Quick Start's NFC Card page.
Not cold storage: the card never generates or uses a key. The card commands and backup format are
that repo's `docs/PROTOCOL.md`, shared across apps; change them there first. Settings > Back Up
Account > Back Up to NFC Card (`NFCCardBackupView`, behind the seed phrase's biometric gate) only exists for an account
with a passphrase, which is what protects it: it's never written to the card. The Import chooser's
Restore from NFC Card (`NFCCardRestoreView`) reads with the 6-digit PIN, asks for the passphrase and
checks it against the saved chatting address. Saving to a card never clears the backup warning. The
App ID needs Near Field Communication Tag Reading on.

The sign-in screen says "KaPay" with the wallet logo and no tagline. The rename kept every identifier
(bundle ID, keychain group, URL scheme, folder and target names `KaChatWallet`): only what people
read says KaPay. Texts about the KaChat ecosystem (KaChat profiles, .kachat names, the Nextcloud
`KaChat` folder) still say KaChat.

The Wallet tab keeps Your Domains; a profile is edited and shared in KaChat or KaPost, not here. Help has only the .kachat names guide. People read "12 or 24 words" rather than "seed phrase" or "recovery phrase",
as in KaChat; the code keeps its names (`SeedPhrase`, `SeedPhraseView`). The Chatting Address is
address #0, so the legacy chain's first spending slot shows as #1 (`WalletManager.addressNumber`). The bell (`GlobalNotificationCenter`) lists
"Received" and .kachat notifications.

## Send Kaspa (and every other send)

Every screen that moves Kaspa is the same steps, built from the shared pieces in
`Views/Shared/SendKaspaComponents.swift`. Change those pieces, not one screen.

1. **To**: `SendStepScreen` + `SendStepQuestion` ("Who are you sending to?") + `SendRecipientCard`
   (address or name; Paste, Scan QR and Contacts pills under the field). Cancel sits at the
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

**A send with no answer**: a node that took a transaction and never answered gets a longer look-up,
then `SendOutcomeUnknownError`: the screen says "Not confirmed" and offers only Done, since Try Again
could pay twice. A node's answer only counts if its id is the one computed here, and a transaction the
network can't see 5 s later is sent again (same transaction, so it can't pay twice). Only a verdict
rejection (`isVerdict`: not orphan, not "already") cancels another node's lost answer, and the mempool
look-up asks the primary too. After a rejection, a REST `is_accepted` counts only from the built-in
REST server, never one typed into Settings.

**Security**: the words and passphrase are `WhenUnlocked` in the Keychain; other keys stay
`AfterFirstUnlock`, since push sign-in uses the private key while the phone is locked. So anything that
may run locked gets addresses from `DerivedAddressStore`, never the seed. `PrivacyCoverWindow` covers
the app, sheets included, whenever it isn't active. Third-party keyboards are refused app-wide. After a
reinstall (`noteKeysLeftByEarlierInstallIfNeeded`) leftover keys become saved accounts to open or delete,
and are never erased automatically. Biometrics for Account Login is off by default, and switched off once
on existing installs, so a phone with no passcode can still see its account; the words, private keys and
sends still need the phone's lock. A `.kachat` name resolves only if the chain holds its record
(`confirmOnChain`), and Accept Offer checks the on-chain amount against what was shown.
A .kas commit is filed before it's sent (`KNSRevealRecovery`), and if its reveal never went out it
is retried when the app becomes active, for an hour. Every way of removing an account (Delete Account, the sign-in list's Delete, the recovery screen's
Remove) goes through `WalletManager.removeLocalData`: Cold Storage, Portfolio, contacts, bell history,
.kachat reminders, spending-address files and keys, and the Nextcloud login, whose app password is
revoked first. The Secure Enclave key goes only when no saved account and no Keychain snapshot remain.

**Face ID**: `SwipeUpToSendScrollView` asks `DeviceAuth` before every swipe, whether Send Kaspa,
Cold Storage's broadcast or a .kachat transaction (its `authReason`). Declined, the screen settles
back with everything filled in. Both Delete Account sheets ask too. A device with no passcode can't
do either (`DeviceAuth` refuses and says why).

**Fees**: change too small to keep goes to the fee, and the review counts it (`SendFeeEstimate`).
The swipe waits until Max, the fee and a higher tier's own estimate are in, and stays off after a
fee error (either estimate; Try Again works it out again). The shown fee includes the selector's
3-sompi buffer. Max at a speed tier prices the tier's extra from its own send's base fee
(`WalletService.maxSendAmount`), and a Max amount is worked out again when the speed changes. At the
swipe the send is rebuilt from that moment's coins; if it would pay more than the Review showed
(`checkFeeAgainstReview`, 1,000 sompi margin) nothing is sent (`SendFeeChangedError`) and the
Review re-estimates. The Review prices change at the script it will really go to: a primary's or
quantum source's change goes to a fresh quantum slot (35 bytes, `reviewChangeScript`). Only the primary
rotates there; another quantum source just lists the slot. The Receive QR's slot is never given to
change, and a slot that has held change or spent isn't shown again.

**Coins**: whatever `NodePoolService.submitTransaction` or `submitRpcTransaction(_:expectedTxId:)`
sends (every send, .kas and .kachat names, combines, Cold Storage) stays out of the next send, Max
and fee for two minutes (`WalletService.reserveOutpoints`, `unreservedUtxos`), and the UTXO cache is
dropped; name sends pick only unreserved coins. Not after "Not confirmed": a resend then picks the
same coins, so at most one of the two can land. A `.kachat` commit resend likewise ignores the hold. Available,
Compound and Coin Control count the coins a send can spend (`withdrawalSpendable` for the chatting
address); Coin Control greys out the rest, and a selection whose coins are all gone is an error, not
automatic. An address with more than `maxInputsPerTransaction` coins gets a Max (and a Compound) of
its largest coins, one transaction's worth (`WalletService.oneTransactionChunk`), and says so.

**Accounts**: a readable snapshot puts missing keys back before the recovery screen shows; Remove
there works only while that account is still in the slot with no keys, and import or Log Out clears
a recovery left from before. A keychain write that fails part-way puts the slot's previous account
back. The same words on the other network are the same account (`isSameAccount`). A sign-in error
waits in `signInFailureMessage` for the rebuilt accounts screen. The passphrase search gives up after
12 s ("Skip the Search", Search Again). Every account's words item is tightened at launch. A new NFC
PIN is typed twice, and a swapped card stops before a PIN try. The Passcode Required alert has its
own window. A sheet picked from another sheet opens from that sheet's `onDismiss`.
Every single-address page has one `AddressOptionsButton` at the top right, opening `AddressActionsSheet`:
no View Public Key on a quantum address, no View Private Key on a Cold Storage address. The privacy cover
has one window per scene (iPad windows). A submit that never left ("Not connected to", "Circuit
breaker open") isn't a lost answer. `AppLog.log` cuts every address in a line to "…" and its last 8 characters (as KaChat).

## Services

- `WalletService` (`Services/WalletService*.swift`): the node connection, the live UTXO
  subscription to the wallet's own addresses (main, spending, cold storage; re-subscribed when a
  cold account or a new primary appears), sending (`WalletService+Sending`) and Kaspa REST reads
  (`WalletService+Transactions`). Live batches go to `AddressActivityNotifier` and a balance
  refresh; without a subscription a 60s poll refreshes the balance and catches up receives.
- `HotWalletBalance`: the chatting address plus every spending address (hidden ones too, cold
  storage not), or a dash until both are known. The top bar on every tab and the Wallet tab's card
  read it; a single address's screen still shows that address.
- `WalletManager`: accounts, keys, spending addresses. `AddressBookManager`, `ColdStorageManager`,
  `PortfolioManager`/`PortfolioViewModel`, `KNSService` and `KachatNames*` as their names say.
- `NextcloudService`: backs up Contacts and the Portfolio, nothing else. Connect with an app
  password.
  - Contacts: KaChat's way, in the same file with the same key, so a contact added or deleted in
    either app reaches the other: `kachat-contacts.json` in the backup folder (`KaChat` by default;
    found on connect, or chosen in Settings), always in the encrypted v1 envelope (`BackupEnvelope`;
    the key comes from the chatting address's private key). Inside is the contacts export file
    (`AddressBookManager.ExportFile`, with photos and `deleted`). One sync reads, merges (newest edit
    or deletion wins) and writes only if the file is missing something this device has. With
    Automatic Sync on (off by default): 15 s after a contact changes, at most every 90 s (300 s on
    metered networks), on background, and a foreground ETag poll every 30 s (60 s) brings in other
    devices' changes. A file this account can't read throws before any write, except its own damaged
    one, which is replaced. So two accounts on one Nextcloud login need different Backup Folders.
    KaChat's NEXTCLOUD_SYNC.md, "Contacts only", is the contract.
  - The earlier plain files (`KaPay Contacts.json` and the older names, all of them) are merged in once per account
    and never written again. Never KaChat's `kachat-backup.json`.
  - Portfolio: one file per portfolio in the backup folder, encrypted in the same v1 envelope and
    key as the contacts, named what the portfolio is
    named ("Long Term.json"; "Long Term 2.json" only if another file has that name). Never one
    `KaPay Portfolio.json`: that earlier file is merged in once per account and never written again.
    Each file (`PortfolioBackupFile`, `type` "kapay-portfolio") holds that portfolio's transactions
    and fees, every deletion the account knows of, and the owning `walletAddress`. A file this account
    can't decrypt is another account's (or not a portfolio) and is left alone; this account's own
    damaged one may be written over. An earlier plain file of this account's is read, then written
    encrypted with the next backup; after a full backup plain files aren't read again
    (`plainPortfoliosRetiredKey`), since anyone can write one. The old single file without an owner
    goes to the first account on this device to connect with that login. Contacts merged from any
    file can't be dated later than the moment they're read. Without the key nothing is read or written. A renamed or deleted portfolio's old file is removed;
    the other files carry the deletion. With only the untouched "Portfolio 1" left, its file is
    uploaded to carry it (another device's such seed is never taken in), and with nothing uploaded
    no deleted portfolio's file is removed. An edit during an upload keeps the backup owed. With Automatic Sync on they upload a few seconds after a change
    and on background, and merge in what's on the server when the app opens, at most once a minute.
    A CSV export is named the same way ("Long Term.csv"), and Export CSV and Export to Nextcloud
    stay plain CSV, so a spreadsheet can open them. A CSV import replaces a row the portfolio
    already had in the same second (the export writes whole seconds), each at most once; rows of
    the file itself never replace each other. Importing a deleted contact dates it after the deletion.
  - A manual backup merges the server's copy in first, and a fresh connection merges both in once,
    which is why there's no Restore button. Contacts and Portfolio import/export use the `KaChat`
    folder and stay plain. A 401 stops automatic sync (`needsReconnect`) and Settings says so.
    Disconnect revokes the app password on the server.
- `KachatNamesRegistry` reads .kachat names through `AppSettings.indexerURL` (Settings >
  Connection > Domains, editable so anyone can run their own indexer; blank = the network's
  default) while it serves this registry and keeps up, else walks the chain itself; the Domains
  tab shows which. An indexer that fails three requests in a row within two minutes
  (`fromIndexer`, `indexerOutageConfirmed`) moves every read to the chain, market reads included; one
  timeout only fails that read. The chain copy answers only
  once a walk has reached the live UTXOs (`readChainState`, `reachedTip`): before that a read
  fails, so a name never reads as free or unowned and saved names keep showing. While the indexer
  is in use the copy is walked every 30 minutes (2 hours on an expensive connection). Without an
  indexer, other people's profiles come from their own chain records (`chainProfile`). A failed read
  never counts as "none": screens keep what they show, a typed name says it couldn't be looked up, and
  a pending claim waits. `confirmOnChain` always checks the record's live UTXO: a chain copy can be hours old. Anything that
  spends or withdraws on a registry answer first asks `answersAreCurrent`. After a failover the indexer
  isn't tried again for 2 minutes, doubling to 15, until one of its data reads works.
  Balances, coins, sends, open-app receive notices and Portfolio never touch the indexer; push does.
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
  tail as `kachat://pay/`; `kapay://market` opens the .kachat Marketplace page) and `kachatwallet` (its old name, still accepted), background task `com.kachat.wallet.messageFetch` (the name is historical;
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
sends on the wallet's topic and skips chat pushes for it: see `PUSH_SERVICE.md`.

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

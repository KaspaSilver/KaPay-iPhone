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
| Wallet | `ProfileView` (`Views/Contacts/ContactsView.swift`, `AppTab.profile`) - the home tab, where the app opens after logging in; as on KaChat's Wallet tab (`WalletView` there), the total balance split into chatting and spending (`WalletBalanceCard`, which opens Manage Addresses), swiped to a page per token (`TokenBalanceCard`, kUSDT, which opens its screen) with a pill per card under it (`BalancePagePills`: "Kaspa", "kUSDT", the one showing filled, a tap slides to it); `SlidingCardPager` (its own drag, not a paged TabView) slides every change of card with one spring, swipe, flick or pill; each card says "Tap to Manage" (`TapToManageLabel`) and opens on a plain tap gesture, not a NavigationLink or a long-press menu, which held the touch and made the swipe stick. Then three round buttons: Send ("What are you sending?" first: `SendAssetChooser`, Kaspa or kUSDT), Receive and Request (`CreatePaymentRequestView`); Backup Hygiene when due; then the list cards: Chatting Address (its QR page), Your Domains, Swap Stablecoins (`BuyStablecoinsSheet`: "Which stablecoin?", a row per stablecoin KaPay holds, kUSDT today; kUSDT goes straight on to `TrestlyConnectSheet` and the site, in the same sheet; it's the only way into Trestly, owner's call 2026-11-20), then Contacts (`AddressBookView`, its own pushed screen). Notifications is the bell at the top right (`GlobalNotificationListView(isPushed: true)`, pushed; `bell.badge` with a red dot while any are unread). Help is in Settings (`SettingsHelpPage`). Pull to refresh reads the balances every time, then scans the
account's addresses for balances (`AddressScan`, owner's call 2026-11-20: Manage Addresses' Discover
sweep, regular and quantum, then kUSDT's Discover), at most once per account every 10 minutes. New
addresses it finds past the revealed range are shown and counted; one the person hid stays hidden
(`SpendingDiscoveryReveal.newOnly`; only Discover Addresses shows hidden finds again). It carries on
after the spinner. There is one sweep per account at a time (`WalletManager.discoverSpendingAddresses`),
shared by the pull, Discover Addresses, an import and an NFC restore: a second caller waits for the
running one. The sweep asks about name ownership six at a time and remembers "owns no name" for the
session; past the first thousand it goes on 200 at a time while a window shows activity, to 5,000. No profile card: those belong to KaChat and KaPost. About is in Settings |
| .kachat | `KachatMarketView` (`Views/Ecosystem/`); dock icon `KachatTabIcon.domainsImage` (name tag with an @) - the full .kachat names marketplace. The name search sits first under the logo (Claim on a free name); then claims in progress, Your Names (when there are any), and a row each of Available, For sale and Expired plus the latest activity, each with See All for its full page. Your Domains > .kachat's button is "Claim a Name" and switches to this tab (no screen of its own). Its "?" opens `KachatHelpView` full screen: two cards, How It Works (each action, one card each) and Pricing (the claim and renew table by name length, from the registry's params, then where the price goes, the bond and deposit, paying ahead, no marketplace fee, the network fee). Search, buy, claim, sell, offers, activity |
| Settings | `SettingsView(isDockTab: true)` (`Views/Settings/SettingsView.swift`, `AppTab.settings`) - no Done button as a tab; alphabetical rows with no descriptive text, as in KaChat: Account Name, Back Up Account (Complete Your Backup, View 12 or 24 Words, Back Up to NFC Card), Connection, Customization, Diagnostics, Help (moved from the Wallet tab, 2026-11-20), Notifications, Security, Storage; then Delete Account (`DeleteAccountSheet`, the warning the sign-in screen's Delete also shows; `WalletManager.deleteCurrentAccount`) and Log Out |

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
with a passphrase, which is what protects it: it's never written to the card. Import's name screen has
Restore from NFC Card at the bottom (`NFCCardRestoreView`) reads with the 6-digit PIN, asks for the passphrase and
checks it against the saved chatting address. Saving to a card never clears the backup warning. The
App ID needs Near Field Communication Tag Reading on.

The sign-in screen says "KaPay" with the wallet logo and no tagline. The rename kept every identifier
(bundle ID, keychain group, URL scheme, folder and target names `KaChatWallet`): only what people
read says KaPay. Texts about the KaChat ecosystem (KaChat profiles, .kachat names, the Nextcloud
`KaChat` folder) still say KaChat.

The Wallet tab keeps Your Domains (`KNSDomainsListView`: a card per name ending, .kachat, .kas, .k,
then .kaspa, drawn like Connection Settings' cards: the @ in its circle, the ending with who runs it,
how many you hold there, and a chevron; the .kas, .k and .kaspa screens only list your names, with
no "Get a … domain at …" button sending you to the outside services); a profile is edited and shared in KaChat or KaPost, not here. Help has the .kachat names guide and the kUSDT Guide (`TokenGuideView`, pushed: a card each for
what it is, where it lives, the 1.5 KAS per coin, sending, Combine Coins, swapping on Trestly, the
other apps, history and the risks; it shares the About sheet's strings where they say the same). People read "12 or 24 words" rather than "seed phrase" or "recovery phrase",
as in KaChat; the code keeps its names (`SeedPhrase`, `SeedPhraseView`). The Chatting Address is
address #0, so the legacy chain's first spending slot shows as #1 (`WalletManager.addressNumber`). The Notifications card (`GlobalNotificationCenter`) lists
"Received" and .kachat notifications.

## Tokens (kUSDT)

KCC-20 tokens on Kaspa L1, starting with Trestly's kUSDT (owner's call, 2026-11-19; the open code
is `kaspador/kusdt-open`, its SPEC.md the protocol). KaPay has no Swap or Bridge screens: swapping
KAS and kUSDT and adding to KasPool (the only trading KaPay does, owner's call 2026-11-19; no
bridging or redeeming from KaPay) happen on Trestly's own site, opened inside KaPay
(`TrestlyBrowserView`) and connected to the address you choose. KaChat, KaPost and KaPlay, on the same words, only hold and
send. `Views/Tokens/`: the Wallet tab's balance card swipes to a page per token
(`TokenBalanceCard`), which opens `TokenManageView` ("Manage kUSDT", like Manage Addresses: the
total with a "Bridged by Trestly" pill under it (`TokenAboutSheet`: what kUSDT is, the not-audited
warning, the vault link), a row per visible address holding it, and the floating options button at
the bottom right (no Open Trestly since 2026-11-20: Swap Stablecoins on the Wallet tab is the way in): Generate New Address (`TokenWallet.generateFreshAddress`: the next
unused regular address, revealed and checked on in the list, "Address #n is ready."), Discover kUSDT
Addresses (pull to
refresh runs it too, four addresses at a time) (progress in
the sheet, keeps going if it's closed; UI stage walks the addresses and reports the sample) and
kUSDT Address Visibility (`TokenAddressVisibilityView`: the same screen as Kaspa's Non-Quantum
Addresses, every regular address in pages of 50 with #0 the Chatting Address always on, the kUSDT
amount or Unused on the right, a tap saving at once, Hide All; tokens never live on quantum
addresses, so there's no chain to choose). Manage kUSDT's rows carry Manage Addresses' Used (orange) / Unused (green) tag (owner's call,
2026-11-20): the Chatting Address is always Used; another address is Used once it holds kUSDT, has
kUSDT history on this phone, or Manage Addresses knows it as used (`everUsed` or KAS on it). Manage kUSDT lists the Chatting Address, each address
holding kUSDT unless hidden, and any empty address checked on (`listedHoldings`, kept per account
on the phone); hidden ones still count in the total and stay in Send's From. Every address Manage
kUSDT lists is shown in Manage Addresses too (owner's call, 2026-11-20; `TokenWallet.listedSpendingIndices`):
Manage Addresses un-hides one when it loads, its Hide and Address Visibility refuse it ("Hide it from
Manage kUSDT first"), and Hide All leaves those shown. One way only, on purpose: an address using
kUSDT needs KAS on it (fees, the 1.5 KAS per coin), so it must be visible on the Kaspa side; a Kaspa
address doesn't need kUSDT, so Manage kUSDT never has to list it. A row opens
`TokenAddressView` (each regular address row has Manage Addresses' ⋮: Rename, shared with Manage
Addresses, Copy, Show QR Code, Send to Chatting Address (`TokenSendView`'s `prefillRecipient`, opening
on How much), Combine Coins with more than one coin, Hide): that address's balance (`AddressBalanceCard`, the same card as a Kaspa address's page), its history of just kUSDT, Receive and Send at the
bottom (from that address), and the top-right options (Combine Coins, View in Explorer). Done in Trestly's browser goes straight back to the top of the Wallet tab (`.trestlyDone`: the
browser, the address picker and the pushed Manage kUSDT screens all close). `TrestlyConnectSheet` picks the address (Chatting Address, every address holding kUSDT, every regular
address holding KAS, hidden ones too, never a quantum one, then a fresh one; each shows its kUSDT and
under it its KAS) before the site opens. `TokenSendView` is Send Kaspa's steps (To with names, From,
How much on the keypad in the token's decimals, the swipe-up review with Goes With It, the 1.5 KAS
each token coin holds, and the network fee); never to a script address. `TokenReceiveSheet` opens on
Fresh Address (the next regular spending slot, put on the list once copied or shared) with Chatting
Address the other choice, or shows one address (`fixedHolding`) from its page.

Every address page (Chatting Address `ChattingAddressManageView`, a Manage Addresses address `SpendingAddressTransactionHistoryView`, a kUSDT address `TokenAddressView`) opens on
`AddressBalanceCard` (`Views/Shared/AddressBalanceCard.swift`): the address's name, its balance
large, and under it the worth in your currency on mainnet (`KaspaAddressBalanceCard`) or the KAS a
kUSDT address holds with it, in KaPlay's Wallet-tab card look. The Kaspa pages keep History / UTXOs
/ Domains under it; a kUSDT address has just its history. The screens before them show their total
in the same card: Manage Addresses ("Total Balance", chatting plus every spending address) and
Manage kUSDT ("Total Balance", its dollars, Sample Data, Bridged by Trestly). The Chatting Address
page's balance is the wallet's own (the UTXOs' sum only when that isn't known), so it never sits at
0 while UTXOs load.

**Where tokens live** (owner's call, 2026-11-19: privacy from the start): the Chatting Address and
the regular (legacy, P2PK) spending addresses (`TokenHolding`), never a quantum-safe one (sending a
token from a P2SH owner spends its KAS too and reveals its key, and Trestly's builder and pool don't
take one). The Chatting Address shows the .kachat name, so Receive defaults to a fresh address.
Send has a From step ("Where are you sending from?", skipped when one address holds it), and the
KAS for the fee and the 1.5 KAS come from that same address ("KAS Paid From"), so a send links no
other address. Trestly's own wallet only reads the first key (the Chatting Address). `TokenIcon` draws the USDT mark (`USDTMark`, the T and its ring on USDT green #26A17B) in code, not
from an image, with the Kaspa logo (`KaspaLogo`) as a small badge at the corner (the real logo, not a drawn "K", as in KaChat), since kUSDT is bridged USDT on Kaspa, not
Tether's own.

**Connection Settings** (`ConnectionSettingsView`) is a card per connection, each opening its own
screen (`page`) with Save (Node saves as you pick): Push, Node, Domains, Explorer and Trestly. Trestly
holds `AppSettings.trestlyAPIURL` (the coordinator API, kUSDT balances) and `trestlySiteURL` (what
`TrestlyBrowserView` opens, on its `/swap` page), kept per network like the others (`ConnectionProfile`, optional there so
older stashed profiles decode); blank means the network's default (api.trestly.io / trestly.io,
testnet.trestly.io on testnet), and like every field here they must be https.

**Wiring** (2026-11-19, stage 1 of 3: real balances). `Services/Tokens/Kusdt.swift` pins the
deployment (covenant and pool ids per network, 1.5 KAS per coin) and the KCC20 template
(`Resources/kusdt-kcc20-template.json`: prefix and suffix from kusdt-open's artifact, checked against
`templateSHA256` at load), and encodes a coin's 112-byte state and its P2SH script.
`KusdtBalances.fetch` asks Trestly's `GET /tokens?owner=` and keeps a coin only if it's a plain coin
of that address's key and the node (no REST fallback) holds that exact outpoint at the recomputed
script with kUSDT's covenant id, one entry per outpoint: a wrong template or a lying API can hide
coins, never invent or double them. Its lookups use an ephemeral, cookie-less session.
`TokenWallet.refresh` looks up only the Chatting Address and the regular addresses that use kUSDT
(holding it, seen holding it before, `token_indices_<account>`, listed or hidden in Manage kUSDT,
waiting for a coin, or in its history), so the rest of the account isn't sent to Trestly every 90 s
(audit, 2026-11-20); four at a time, one failure fails the refresh, keeping the last good balances
and `lastError`. One refresh at a time per account: a second caller waits for it and one more runs
after if asked meanwhile; an account switch clears the old figures at once. Coins a send from this
app is holding (`WalletService.heldOutpointKeys`) are left out of balances and sends. Discover walks
20 past the last revealed, reveals exactly the furthest slot holding some (`revealSpendingAddress`)
for the account it started for, and a refresh running alongside never overwrites its answer. Received
notifications: a token coin sits at its own contract address, so the Kaspa watch never sees it;
instead every refresh compares coins with those known on this phone (`token_seen_<id>_<account>`)
and announces new ones as "Received 25.50 kUSDT" (local notification + Notifications list, source
`.token`, behind Address Activity; a tap opens Manage kUSDT via `TokenRoute`). Never announced: the
first look, what Discover finds, and own transfers (the tx spent a known coin or an input from one
of your addresses). `startPolling` refreshes every 90 s while the app is open, only for an
account that uses kUSDT (`accountUsesTokens`). Push when closed
needs the indexer (a handoff, later). History is kept on the phone (Trestly's API keeps none, and a
token coin never sits at your own address): `TokenWallet.record` saves this phone's sends, Combine
Coins and kUSDT received from others (`TokenActivity`, Codable, id "txid:holding:kind" so a send
noted twice is one line; `token_activity_<id>_<account>`, 300 at most), shown on each address's
page in an inset-grouped list whose rows (`TokenActivityRow`) are drawn like a Kaspa address's
transactions in Manage Addresses (circled arrow, Received/Sent in green/red, the transaction id, date
and time, the signed amount, "Fee …" when this phone paid it, the explorer mark; a tap opens the
explorer). An account's token data goes with it (`TokenWallet.forgetLocalData`, from
`WalletManager.removeLocalData`). Nothing from before, or from another app on the same words.

**Combine Coins** (`TokenCombineView`, from a row's ⋮ in Manage kUSDT or an address page's options,
when the address holds more than one coin): `KusdtTransfer.prepareCombine` sends the address's
largest coins (3 at most per round) to itself as one coin. Every coin holds 1.5 KAS, so the KAS of
each coin merged away comes back as plain KAS (`Prepared.kasBack`), less the fee it pays; no funding.
Any send whose coins hold more KAS than its outputs (a send of everything from several coins too)
gives the extra back as change, never to the recipient's coin. A kUSDT transaction's KAS change has
no input from your addresses, so `KusdtTransfer.send` marks it handled first
(`AddressActivityNotifier.markOwnTransaction`): never a "Received KAS".

Stage 2, sends (owner's call: Trestly's own builder, not a Swift port, since a KCC-20 input's
unlock script and compute budget come from running the contract): `KusdtCore` runs kusdt-open's
WebAssembly (`Resources/KusdtCore/`: the `.wasm`, its loader shipped as `kusdt_wasm.js.txt`, and
`kusdt-core.html`, all three SHA-256-pinned and checked before loading) in a hidden, non-persistent
`WKWebView` served only by the `kusdt-core://` scheme; `run(command, request)` answers its JSON.
`KusdtTransfer.prepare` follows kusdt-open's `buildTransfer`/`buildFunded`/`checkBuilt`: at most 3
kUSDT coins of the From address (largest first; more is "send a smaller amount"), the recipient's
coin plus a change coin to the sender (1.5 KAS each), plain Schnorr KAS coins of the same address
(unreserved, largest first, one more while the builder asks "add funding" or its fee doesn't
settle, or more than 0.05 KAS of change would go to the fee), feerate 100, the key of that address
only; then every token output must be the approved state at its recomputed script with 1.5 KAS,
every other output must pay the sender, and the fee must be at most 3 KAS. `send` submits through
`NodePoolService.submitRpcTransaction(_:expectedTxId:)` (holds the coins, looks up a lost answer by
id), with `storageMass` filled as .kachat does (the v1 id doesn't cover it). The review builds when
it opens (exact fee), rebuilds if left over 2 minutes, and a lost answer's Try Again resends the
same signed transaction; `TokenWallet.noteSent` drops the spent coins at once, marks the send's
outputs known (once per transaction), and refreshes after 4 s. On "Not confirmed" nothing is dropped:
the coins stay, and `KusdtTransfer.prepare` leads the next send or combine from that address with the
unconfirmed send's token coin and KAS coin (`unknownOutcomeKeys`, `conflictingOutpoint`), so at most
one of the two can land even after Back (the Kaspa rule; audit, 2026-11-20). Before submitting,
`prepare` also checks the transaction it will submit: its outputs one by one against what it
checked, the token outputs bound to kUSDT's covenant and the rest to none, every input a picked coin
or a KAS coin it was given (each once), the fee worked out locally (inputs less outputs, at most
3 KAS), and every builder number read without trapping. The review keeps a build only if it's for
exactly what it shows (`prepareGeneration`, `preparedIsCurrent`), the swipe waits for a running
build, and a review open over 2 minutes is built again and shown again rather than sent (the same in
Combine Coins; KaPost's audit, 2026-11-20). `kusdt-core.html` carries a Content-Security-Policy: the
hidden page reaches only its own files and wss to the public Kaspa nodes. Trestly's list lags a send, so
the coins a send made that are yours (the change, or kUSDT to another of your addresses) are kept as
`pendingCoins` and checked on the node with the listed ones (`KusdtBalances.Expected`) until Trestly
lists them (30 minutes at most); for 2 minutes one the node doesn't show yet still counts in the
balance (not in what can be spent), with a refresh every 5 s, so the balance never dips to 0. A whole send (all the address's kUSDT, no change coin) with no KAS there takes the fee from the
coins' own KAS instead (kusdt-open `feeFromTokenKas`: the recipient's coin gets the inputs' KAS
less 0.02, 0.05, 0.1 or 0.19 KAS, the least the builder takes; `Prepared.feeFromTokenKas`, noted on
the review), so it never needs funding. When a partial send's From address lacks KAS
(`Failure.notEnoughKas(short:forChangeCoin:)`, the button "Add … for Fee and Change Coin" or "… for
the Network Fee";
what it needs plus a 0.2 KAS fee margin, less what's there, 0.1 KAS at least), the review offers
Fund This Address: Send Kaspa with a payment request (signed by the Chatting Address, memo "KAS for
a kUSDT send") locking in that address and amount, so you only pick the source and swipe; when that sheet closes (Done or swiped away) the review
builds again, every 3 s for up to a minute after a send ("Waiting for your KAS to arrive…", no
top-up button meanwhile). If it's still short after a funding send, the review says the KAS hasn't
shown up yet and offers Check Again, with "Add … More" only as a small link, so nobody tops up twice. Still to come: stage 3,
kusdt-open's wallet provider (SPEC section 14) in the Trestly browser for swaps and the pool only.
Stage 3 is built: `Services/Tokens/TrestlyProvider.swift`, installed by `TrestlyWebView`, puts
`window.kusdt` at document start on the Trestly origin's main frame only (the script checks the page's
origin, the bridge the sending frame's), with `methods` on it and on `info`, `info` {KaPay,
com.kachat.wallet, a 96 px logo data URL}, `kusdt:announceProvider` at load and on every
`kusdt:requestProvider`, and `kusdt#initialized`. It answers `kaspa_requestAccounts` (the picked
address), `kaspa_getNetwork`, `kaspa_switchNetwork` (same network only, else 4200), `kusdt_getBalances`
(4100 before connecting; the address's non-covenant KAS from the node and its `TokenWallet` kUSDT, as
decimal strings), `kusdt_capabilities`, and the trades `kusdt_swap`, `kusdt_addLiquidity`,
`kusdt_removeLiquidity`; send and redeem are 4200. **Trades run Trestly's own wallet logic, never a
port** (owner's call, 2026-11-20): `tools/kusdt-wallet` bundles kusdt-open's
`wallet/extension/src/kusdt` (pool checks, quotes, the breaker, merges, builds, races, outcomes) with a
small entry (`src/entry.ts`, what their `screens/Approve.tsx` does around it) into
`Resources/KusdtCore/kusdt-wallet.js.txt`, SHA-256-pinned in `KusdtCore.pinned` and loaded by
`kusdt-core.html` after the WebAssembly (a failure there never stops sends). `KusdtCore.wallet`
calls its `prepare` (quote and checks, no key) and `execute` (the one address's key, for that call
only, and the feerate the sheet showed). `TrestlyApprovalSheet` shows the numbers with Approve and
Decline (closing declines: 4001); a worse quote after the pool moved comes back as a requote and is
prepared again from scratch and shown again. Hardening (audit, 2026-11-20): the browser only ever
shows Trestly's site (`TrestlyWebView.Coordinator`; a tapped link elsewhere opens in Safari); one
trade at a time from first check to end of send (-32002 otherwise), 3 s before a declined page may
ask again, Approve wakes 0.8 s after the sheet appears, `close()` on Done declines what's pending;
the bridge checks method length, JSON-validity and the 4096-character params limit in Swift; a
trade's spent inputs are held like a send's (`execute` returns them). `KusdtCore` hashes its files
off the main thread, gives up on a page that doesn't start in 25 s, restarts after its process is
killed, tries a failed start again after 10 s, and times out calls (run 30 s, prepare 90 s,
execute 240 s). In the hidden page their `fetch` goes through `KusdtNetRelay` (https to the Kaspa
resolvers `<name>.kaspa.stream/.red/.green/.blue` and the Settings Trestly API host only, every
redirect checked again, 64 KB out, reading stops at 4 MB) and their `chrome.storage.local` through
`KusdtStoreRelay` (a 2 MB-capped JSON file in Application Support, keys starting `kusdt.`; an
account's entries are wiped with it via `TokenWallet.forgetLocalData`); their node client opens its
own WebSocket to the resolver's node. To update to a new
kusdt-open release: check it out, `cd tools/kusdt-wallet && npm install && KUSDT_OPEN=… node build.mjs`,
and put the printed SHA-256 in `KusdtCore.pinned` (and the WebAssembly's, if it changed). A completed swap is announced (`TrestlyProvider.announceSwap`, owner's call 2026-11-20): a banner
over the page, "Swapped 10 KAS for 0.26 kUSDT" or "Swapped 10 kUSDT for 380 KAS" ("Swap sent: …" when
the node didn't show it accepted in time), the same line in Notifications (the bell, "Swap Complete" or
"Swap Sent", tap opens Manage kUSDT), and the kUSDT side in that address's history (`noteSwap`:
`.swapped`, green in for a buy, red out for a sell via `TokenActivity.outgoing`). Pool moves aren't in
history yet; TokenWallet refreshes 4 s after any trade. trestly.io is ready for it (its 2026-11-20 build; `TRESTLY_INTEGRATION.md` "Status on trestly.io"
has what was checked): inject `window.kusdt` at document start (on a phone the site never waits),
set `methods` on it and on `info` to what KaPay answers, answer `kusdt_capabilities` with the same
list, give `info` `{name: "KaPay", rdns: "com.kachat.wallet", icon}` (name 40 characters at
most, icon a data: image up to 256 KB), and re-dispatch `kusdt:announceProvider` (detail
`{provider, info}`) whenever the page dispatches `kusdt:requestProvider`. A 4200 on send or redeem
makes the site say "KaPay does not support …". testnet.trestly.io still runs its 2026-11-14 build
without this.

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
- `WithdrawKaspaView` (`Views/Contacts/ContactsView.swift`): the Wallet tab's Send (after `SendAssetChooser`'s Kaspa), an address's
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
  bottom button), Show Request As QR under it (`SendStepScreen`'s secondary button) and Share. The
  QR (`PaymentRequestQRSheet`) is the same signed request as `kapay://pay/<linkTail>`
  (`kapayLinkString`), so an iPhone's camera opens KaPay on Send filled in; a fresh address is
  reserved once, so Copy, Share and the QR all match.
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
network can't see 5 s later is sent again (same transaction, so it can't pay twice); that look-up skips
the node that took the submit. A mempool entry counts only if its transaction's recomputed id matches
and it isn't an orphan. Only a verdict rejection (`isVerdict`: not orphan, not "already") cancels
another node's lost answer, and after one the transaction counts as out only if two nodes' mempools
have it or the built-in REST server says `is_accepted` (never a REST server typed into Settings).
Every recipient must pass `KaspaAddress.isValidOnActiveNetwork` (prefix and payload length too),
names from other services included.

**Security**: the words and passphrase are `WhenUnlocked` in the Keychain; other keys stay
`AfterFirstUnlock`, since push sign-in uses the private key while the phone is locked. So anything that
may run locked gets addresses from `DerivedAddressStore`, never the seed. There is no privacy cover over
the App Switcher (removed, owner's call, 2026-11-19): don't bring one back. Third-party keyboards are refused app-wide. After a
reinstall (`noteKeysLeftByEarlierInstallIfNeeded`) leftover keys become saved accounts to open or delete,
and are never erased automatically. Biometrics for Account Login is off by default, and switched off once
on existing installs, so a phone with no passcode can still see its account; the words and private keys
still need the phone's lock. A `.kachat` name resolves only if the chain holds its record
(`confirmOnChain`), and Accept Offer checks the on-chain amount against what was shown.
A .kas commit is filed before it's sent (`KNSRevealRecovery`), and if its reveal never went out it
is retried when the app becomes active, signed in to that account, for an hour (later it could undo
a newer choice). The record holds the only copy of the redeem script, so it's kept until the commit
is seen spent (a commit never seen on chain is dropped after 30 days and two empty checks). Every way of removing an account (Delete Account, the sign-in list's Delete, the recovery screen's
Remove) goes through `WalletManager.removeLocalData`: Cold Storage, Portfolio, contacts, bell history,
.kachat reminders, spending-address files and keys, and the Nextcloud login, whose app password is
revoked first. The Secure Enclave key goes only when no saved account and no Keychain snapshot remain.

**Face ID**: Kaspa sends never ask (owner's choice, 2026-11-13, same in every iPhone app): Send Kaspa,
Compound, Send from an address and Cold Storage's broadcast go on the swipe, and `startSending`
switching to `.sending` at once stops a second swipe. `DeviceAuth` still guards Delete Account (both
sheets and the recovery screen's Remove), Send Domain, .kas profile and primary-domain changes,
.kachat transactions (`SwipeUpToSendScrollView` asks only when `authReason` is set; declined, the
screen settles back filled in), the Settings biometric toggles, saved-account sign-in, and showing the
words or a private key. A device with no passcode can't do those (`DeviceAuth` refuses and says why).

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

**Receive and Generate** (owner's call, 2026-11-19): Receive always hands out a fresh REGULAR (legacy,
P2PK) address (`WalletManager.freshReceiveAddress`, `lowestUnusedRegularAddress`), the last one while
still unused: a regular address takes kUSDT as well as Kaspa, and a quantum-resistant one can't trade
it, so nobody puts tokens on one by mistake. Quantum-resistant addresses are made on purpose:
Manage Addresses > Address Actions has Generate Non-Quantum Address and Generate Quantum-Resistant
Address (`generateNew(quantum:)`, each recycling a hidden unused row of its own chain first). Each
address row's ⋮ has Rename, Copy, Show QR Code, Send to Chatting Address (Send Kaspa from that
address with the Chatting Address filled in; off with no balance) and Hide. Address Visibility
(`SpendingAddressVisibilityView`) opens on a card per chain, Quantum and Non-Quantum Addresses, drawn
like Connection Settings' cards (icon circle, "n of m shown", the chain's KAS, chevron); each opens
that chain's checklist. Change
still goes to fresh quantum slots. Every receive screen is the one shared screen, `AddressReceiveView`
(`Views/Shared/`, from kUSDT's design): icon and "Receive …", optional choices, the address's name and
balance, the QR on white, the whole address, a privacy note (`ReceiveNotes`: fresh, spending,
chatting, quantum), "Tap anywhere to copy" (the whole screen copies, with a toast; no Copy or Share
buttons), then what may be sent there. Wallet Receive, the Chatting
Address page, a spending address's QR (a quantum one: Kaspa only, no kUSDT), Cold Storage's
(Kaspa only) and kUSDT's Receive all use it. The Chatting Address page (`ChattingAddressQRView`) matches
KaChat's word for word: the chatting privacy note, "Kaspa, and kUSDT on Kaspa, can be sent here." and
"Use for chatting and acquiring .kachat domains."

**Coins**: whatever `NodePoolService.submitTransaction` or `submitRpcTransaction(_:expectedTxId:)`
sends (every send, .kas and .kachat names, combines, Cold Storage) is held from before the submit
and stays out of the next send, Max and fee for ten minutes (`WalletService.reserveOutpoints`,
`unreservedUtxos`), and the UTXO cache is dropped; name sends pick only unreserved coins. A definite
failure releases the hold, except the coins the node named as spent (all of them when it said
"spent" without naming which, `releaseUnlessSpent`). Not after "Not confirmed": the
hold is released and the next automatic send from that address leads with one of that send's coins
(`unknownOutcomeOutpoints`, ten minutes), so at most one of the two can land. Coins carrying a
`covenantId` are never spent by a plain send or Cold Storage ("Locked by a covenant" in Coin
Control), and Cold Storage follows the hold and mining-reward maturity too, and its automatic selection
leads with a "Not confirmed" send's coin like the hot wallet's sends. A `.kachat` commit resend likewise ignores the hold. Available,
Compound and Coin Control count the coins a send can spend (`withdrawalSpendable` for the chatting
address); Coin Control greys out the rest, and a selection whose coins are all gone is an error, not
automatic. An address with more than `maxInputsPerTransaction` coins gets a Max (and a Compound) of
its largest coins, one transaction's worth (`WalletService.oneTransactionChunk`), and says so.

**Accounts**: a readable snapshot puts missing keys back before the recovery screen shows; Remove
there works only while that account is still in the slot with no keys, and import or Log Out clears
a recovery left from before. A keychain write that fails part-way puts the slot's previous account
back. The same words on the other network are the same account (`isSameAccount`). A sign-in error
waits in `signInFailureMessage` for the rebuilt accounts screen. Import has no wallet list: after the words and "Did you use a passphrase?", `findImportAccounts` derives every `WalletSourceFamily` (Standard 0..<50, KDX and OneKey 0..<20, Chainge 0), makes one UTXO call plus a transactions-count per type's #0, keeps those with funds or history, and lists them with the most funded type first ("Your Account", or live under the passphrase field). Nothing found is Standard #0; the search gives up after 12 s ("Skip the Search", Search Again). "See Every Wallet Type" lists each type's #0. Every account's words item is tightened at launch. A new NFC
PIN is typed twice, and a swapped card stops before a PIN try. The Passcode Required alert has its
own window. A sheet picked from another sheet opens from that sheet's `onDismiss`.
Every single-address page has one `AddressOptionsButton` at the top right, opening `AddressActionsSheet`:
no View Public Key on a quantum address, no View Private Key on a Cold Storage address. A submit that never left ("Not connected to", "Circuit
breaker open") isn't a lost answer. `AppLog.log` cuts every address in a line to "…" and its last 8 characters (as KaChat). Logs carry only a transaction id's first 12 characters (offer ids too, which hold one), so a
diagnostics export can't be looked up on chain. A send's fresh change slot is held as in flight
from its probe until the send ends (`WalletManager.claimFreshChangeSlot` / `releaseFreshChange`),
and Request Payment's Fresh Address skips one that is (`isFreshChangeInFlight`), so a request never
names an address a send's change lands on. Copy, Share and Show Request As QR ignore a second tap
while one is still working.

## Services

- `WalletService` (`Services/WalletService*.swift`): the node connection, the live UTXO
  subscription to the wallet's own addresses (main, spending, cold storage; re-subscribed when a
  cold account or a new primary appears), sending (`WalletService+Sending`) and Kaspa REST reads
  (`WalletService+Transactions`). Live batches go to `AddressActivityNotifier` and a balance
  refresh; without a subscription a 60s poll refreshes the balance and catches up receives.
- `HotWalletBalance`: the chatting address plus every spending address (hidden ones too, cold
  storage not), or a dash until both are known. One read at a time, shared by everyone asking
  (a read that started before funds moved is followed by one more). The top bar on every tab and the Wallet tab's card
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
Push Notifications, Address Activity with the current account's spending-address "Notify on receive"
under it (moved from the top of Manage Addresses), sound, vibration. It asks for notification permission once, when
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

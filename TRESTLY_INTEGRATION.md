# KaPay × Trestly: supporting KaPay on trestly.io

For the Trestly team. What KaPay (the KaChat ecosystem's iOS Kaspa wallet) already does with
kUSDT, how KaPay will connect to trestly.io, and the small set of changes that would let the site
work with it. Written 2026-11-19 against kusdt-open `b70707c` (release `mainnet-v0.9.8-rc.25`,
kUSDT Wallet 1.0.0).

## TL;DR: what we're asking

1. **Detect any `window.kusdt` provider**, not only the kUSDT Wallet extension. KaPay injects one
   in its in-app browser before your scripts run.
2. **Handle a provider that supports only some methods.** KaPay answers `kusdt_swap`,
   `kusdt_addLiquidity` and `kusdt_removeLiquidity`, and refuses `kusdt_send` and `kusdt_redeem`
   with `4200`. Please hide or disable whatever needs a refused method, instead of showing an error.
3. **Make `/swap` and `/pool` work at iPhone width** (about 375–430 pt), since KaPay opens the site
   in a phone-sized web view.
4. **Optional:** a way for a provider to name itself (see "Telling the site who it is") so the site
   can show "Connected with KaPay".
5. **Tell us before the provider API (SPEC §14) or the error codes change**, and when a new
   release of the contracts or the WebAssembly core ships.

KaPay does not bridge or redeem, so you don't need WalletConnect or any EVM wallet support for
KaPay users.

## What KaPay does with kUSDT today

KaPay is a self-custody Kaspa wallet. Its kUSDT support is built on kusdt-open and follows your
wallet's rules wherever there's a choice.

- **Balances.** KaPay asks `GET {api}/tokens?owner=` for each of the user's addresses and believes a
  coin only once its node shows it: a plain coin of that key, the locking script recomputed from
  the state and the pinned KCC20 template (prefix and suffix from `bridge/kaspa/artifacts/kusdt.json`,
  checked against its SHA-256 in PROVENANCE.json), and the outpoint live with kUSDT's covenant id.
  Your API can only hide coins from KaPay, never invent them.
- **Which addresses.** kUSDT can live on the Chatting Address (the first key, `m/44'/111111'/0'/0/0`,
  the one your wallet uses) **and** on the user's other regular Schnorr (P2PK) addresses, for
  privacy. KaPay's Receive hands out a fresh regular address by default. KaPay never puts kUSDT on
  a script (P2SH) or quantum-resistant address, and refuses to send kUSDT to one.
- **Sends.** KaPay runs **your own builder**: `bridge/packages/core/pkg-web/kusdt_wasm_bg.wasm`
  (SHA-256 `a7be48e9…54fd53`, as in PROVENANCE.json) and its loader, pinned by hash and loaded from
  the app bundle into a hidden, offline web view. It calls `run("transfer", …)` the way
  `wallet/extension/src/kusdt/tokens.ts` `buildTransfer` does:
  - at most 3 kUSDT inputs, the recipient's coin plus a change coin, each carrying `tokenValue`
    (1.5 KAS);
  - funding from plain Schnorr KAS coins of the **same** address, largest first;
  - feerate 100;
  - `checkBuilt`'s rules before anything is submitted: every token output is the approved state at
    its recomputed script with its 1.5 KAS, every other output pays the sender, and the fee is at
    most 3 KAS.

  When all of an address's kUSDT goes and it holds no KAS, the fee comes out of the tokens' own KAS,
  as your `feeFromTokenKas` does.
- **Received notifications.** Token coins sit at their own P2SH addresses, so KaPay polls `/tokens`
  while open and announces new coins that aren't from the user's own transfers.
- **Trading.** KaPay has **no swap, pool or bridge screens of its own**. For swapping KAS ⇄ kUSDT and
  providing liquidity, it opens trestly.io inside the app (below). That's the only trading KaPay
  does.

## How KaPay opens trestly.io

- **Entry points.** In KaPay, Manage kUSDT > options > **Open Trestly** (or an address's own page >
  Open Trestly With This Address). The user first picks **one address** to work with: the Chatting
  Address, any regular address holding kUSDT, or a fresh one. Only that address is ever shown to
  the site.
- **Where it opens.** A full-screen in-app browser on `https://trestly.io/swap`
  (`https://testnet.trestly.io/swap` on testnet), since swapping is what most users come for first.
  From there your own menu works as usual.
- **The browser itself.** It's a `WKWebView` (WebKit, as in Safari) with:
  - a **non-persistent data store**: nothing kept between sessions, so expect a fresh visitor every
    time (re-show your risk notice if you need to, and don't rely on stored acceptance);
  - a bar above the page saying which address is connected;
  - user agent: iOS Safari's.
- **Base URL.** It's a setting (KaPay > Settings > Connection > Connection Settings > Trestly, along
  with your API URL), so a staging site can be pointed at for testing.

## The `window.kusdt` provider KaPay will inject

KaPay injects the provider described in SPEC §14 at document start, into pages on the Trestly
origins only (`https://trestly.io`, `https://testnet.trestly.io`, or whatever site the user set),
never into other sites or frames. Requests go to KaPay's own code, which builds, shows and signs
every transaction itself; the page never sees a key, as with your extension.

| Method | KaPay's answer |
|---|---|
| `kaspa_requestAccounts` | `[address]`: the one address the user picked for this session, no extra prompt (opening Trestly with it was the approval) |
| `kaspa_getNetwork` | `"mainnet"` or `"testnet-10"`, KaPay's current network |
| `kaspa_switchNetwork` | `4200` unless already on the asked network: KaPay switches networks only in its own settings |
| `kusdt_getBalances` | `{kas, kusdt}` for that address, in sompi and base units, from KaPay's node-checked balances |
| `kusdt_swap` | KaPay builds with your core (`pool-buy` / `pool-sell`), checks the pool on its node as `verify.ts` does, shows the trade in a native approval sheet, signs and submits. Answers `{txid, amountOut, confirmed}` as SPEC §14 says |
| `kusdt_addLiquidity` | Same, with `pool-add` |
| `kusdt_removeLiquidity` | Same, with `pool-remove` |
| `kusdt_send` | `4200` (KaPay sends kUSDT from its own Send screen) |
| `kusdt_redeem` | `4200` (KaPay doesn't redeem or bridge) |

- **Events.** `accountsChanged` and `networkChanged` as SPEC §14 says. The address only changes if
  the user closes Trestly and opens it again with another one, which reloads the page anyway.
- **Errors.** SPEC §14's codes:
  - `4001` when the user declines in KaPay's approval sheet;
  - `4100` before the page is connected;
  - `-32602` for malformed params;
  - `-32002` while another request is waiting;
  - `-32603` for anything that failed on KaPay's side, with a readable `message`.
- **Pool races.** KaPay rebuilds against the newer pool when another trade spends it first, never at
  a worse price than the `minOut` the page asked for. Otherwise it answers an error.

**Status.** Balances, sends and the in-app browser are live in KaPay's TestFlight builds. The
provider above is the next step on our side (stage 3). The site loads in KaPay today but can't
connect until it ships. The answers above are what we're building to, and we'll send a TestFlight
build to test against.

## What needs to change on trestly.io

### 1. Detecting the provider

Please treat a `window.kusdt` object with a `request` function as a wallet, whatever injected it.
If the site checks for the extension specifically (its id, a Chrome-only API,
`chrome.runtime`, a flag only your extension sets) or shows "Get kUSDT Wallet" whenever that's
missing, KaPay users get turned away. KaPay's provider exists before your bundle runs, so a check at
load time finds it.

### 2. Methods a wallet doesn't offer

KaPay answers `4200` (unsupported method) for `kusdt_send`, `kusdt_redeem` and network switching.
Ideally:

- **Bridge in:** the deposit is an Ethereum or BNB Chain transaction, which KaPay can't sign. Keep
  it with the user's EVM wallet as you do today, or show it as unavailable in KaPay.
- **Redeem / Bridge out, Send:** hide or disable them for a provider that refuses them, or show a
  short "not available in this wallet" note, rather than an error after the user has filled in a
  form.

If it's simpler, a capabilities check would work too, for example a `kusdt_capabilities` method
listing what the wallet supports. KaPay would answer it. Tell us which you prefer.

### 3. Mobile layout

The pages KaPay users will use are `/swap` and `/pool` (and `/portfolio`, `/activity` for reading).
On a phone that means:

- no horizontal scrolling;
- inputs and buttons at least 44 pt tall;
- your risk notice dismissable on a small screen;
- the Connect button working with an injected provider and no extension pop-up.

### 4. Telling the site who it is (optional)

So the site can say "Connected with KaPay", KaPay's provider will also carry
`window.kusdt.info = { name: "KaPay", icon: "data:image/png;base64,…", rdns: "com.kachat.wallet" }`
and dispatch a `kusdt:announceProvider` event with the same `info`, in the spirit of EIP-6963.
Use either, or tell us what you'd rather read.

### 5. Staying in step

KaPay pins your contracts' template and your WebAssembly core by hash, so a new release needs a
KaPay update before KaPay can build against it. When you plan to change:

- the KCC20 or pool contracts;
- the core's commands, request or answer formats;
- the provider methods and error codes;
- the API routes KaPay reads (`/tokens`, `/pool`, `/pool/made/:txid`, `/positions`),

please tell us ahead of time, ideally with the release tag, so the KaPay update ships alongside.

## Testing together

1. **Testnet first.** KaPay's Settings > Connection lets a tester switch to testnet-10, where the
   site is `testnet.trestly.io` and the API `testnet.trestly.io/api/v1`.
2. **KaPay's side.** We'll add Trestly's team as TestFlight testers once the provider ships, with a
   build that logs every provider request and answer (never keys) to Settings > Diagnostics.
3. **Your side.** To check detection and the mobile layout before then, open the site in Safari on
   an iPhone and define a stub before your bundle loads:

   ```js
   window.kusdt = {
     request: async ({ method }) => {
       if (method === 'kaspa_requestAccounts') return ['kaspa:q…'];
       if (method === 'kaspa_getNetwork') return 'mainnet';
       throw Object.assign(new Error('unsupported'), { code: 4200 });
     },
     on() {},
     info: { name: 'KaPay', rdns: 'com.kachat.wallet' },
   };
   ```

## Contact

The KaPay iPhone team (KaChat). KaPay's source is `KaspaSilver/KaPay-iPhone`; its kUSDT code is in
`KaChatWallet/Services/Tokens/` and `KaChatWallet/Views/Tokens/`, and `CLAUDE.md` describes how it
fits together.

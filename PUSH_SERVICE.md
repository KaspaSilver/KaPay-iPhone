# Push service: what KaPay needs

Handoff for the KaChat push service (`kachat-indexer/kasia-indexer`, `indexer/src/push.rs` and
`indexer/src/api/v1/push.rs`), the same service and URL KaChat uses (default
`https://indexer.kachat.app`). KaPay is a separate iOS app, bundle id
**`com.kachat.wallet`**, on the same Apple team as KaChat (`RP4Z22SFSD`).

## What the wallet wants pushed

Only two kinds, both already built in the service:

| Push | Already in the service | How the wallet asks for it |
|---|---|---|
| **Received KAS** ("Address Activity", thread `funds:<address>`) | `watch_only_addresses` + `watch_only_tokens` | its own addresses in `watch_only_addresses` |
| **.kachat name events** (`type: name_event`) | `tokens_for_primary_address_str` | its main address in `primary_address` |

Nothing else: no DMs, handshakes, payments-as-chat, inbox (no-handshake) messages, groups,
broadcasts, KaPosts or VoIP rings. The wallet has no notification service extension, so an
encrypted chat push would show as a bare banner.

## What the wallet sends (client side, done)

`POST /v1/push/register` and `PUT /v1/push/update`, same shape and signed auth as KaChat, with:

- `platform`: `"ios"`
- `watched_addresses`: `[]` and `watched_group_ids`: `[]` (the wallet has no chats; the signed
  preimage hashes them, and `aliases`, as empty lists). No other chat or KaPosts field is sent:
  the service's `#[serde(default)]` leaves them empty
- `primary_address`: the wallet's main address
- `watch_only_addresses`: the main address, its spending addresses (while their switch is on)
  and the cold-storage addresses whose account notifies; empty when the user turns
  Address Activity off (the device stays registered for .kachat name events through
  `primary_address`)
- `apns_environment`: `"development"` (Xcode builds) or `"production"` (TestFlight / App Store)
- **`apns_topic`: `"com.kachat.wallet"`** - new field, see below

Older services ignore `apns_topic` (unknown JSON fields are skipped), so this is safe to ship
before the server change.

## Server changes needed

§0 (watch-only part), §1 and §2 are done (kachat-indexer 27f9c57). §0's primary-address case and
§3 are implemented in the indexer checkout (`push.rs`, `block_processor.rs`); check they are deployed.
The hand-off was `docs/KACHAT_WALLET_PUSH.md` in the indexer repo.

### 0. Accept a registration with only watch-only addresses or a primary address (required)

`push.rs` `register` (line ~152) and `update` (line ~468) bail with
`watched_addresses and watched_group_ids must not both be empty`. The wallet sends both empty,
so every wallet register/update got a 400 (seen live on 2026-10-25 from a Simulator
build). kachat-indexer 27f9c57 allows it when `watch_only_addresses` is non-empty; still open:
allow it when only `primary_address` is set - a wallet device whose user turned Address
Activity off, kept for its .kachat name events:

```rust
if addresses.is_empty() && group_ids.is_empty() && normalized_watch_only.is_empty()
    && primary_address.is_none()
{
    anyhow::bail!("nothing to watch: watched_addresses, watched_group_ids, watch_only_addresses and primary_address are all empty");
}
```

(`authenticate_push_request` already accepts an empty watched list - the auth covers the
empty list's hash.) The wallet retries a failed update with backoff (5 s, 30 s, then every
120 s), so it registers by itself once this ships.

### 1. Send each device's pushes on its own APNs topic (required)

Done in kachat-indexer 27f9c57.

Today `ApnsClient` sends every push with the one `APNS_TOPIC` (`com.kachat.app`). Apple rejects a
wallet token on that topic with `DeviceTokenNotForTopic`, which the service treats as a dead
token and prunes - so **no wallet push is delivered until this changes**.

- Accept `apns_topic: Option<String>` on register and update (`api/v1/push.rs`
  `RegisterRequest` / `UpdateRequest`). Keep it outside the auth preimage, like every optional
  field added after LegacyV1, and store it on the `DeviceRegistration` value only.
- Allow only known topics: a new env var, e.g. `APNS_ALLOWED_TOPICS=com.kachat.app,com.kachat.wallet`
  (default: just `APNS_TOPIC`). Anything else is stored as `None`.
- In `ApnsClient` (the alert send, `.header("apns-topic", ...)`), use the device's topic when
  set, else `APNS_TOPIC`. The dispatcher already resolves the token list per send; it needs the
  token -> topic map alongside the token -> platform / environment ones (`platforms_for_tokens`).
- VoIP keeps `APNS_VOIP_TOPIC` / `APNS_TOPIC + ".voip"`; the wallet registers no VoIP token.

No new key is needed: an APNs auth key (`.p8`) works for every app on the team, so the existing
`APNS_KEY_ID` / `APNS_TEAM_ID=RP4Z22SFSD` key signs wallet pushes too. Environment routing
(`apns_environment`, sandbox vs production host) already works per device and needs no change.

### 2. Give wallet devices only Received and .kachat pushes (required)

Done in kachat-indexer 27f9c57.

A wallet device has a `primary_address`, so today it would also match
`matching_tokens_for_inbox` (no-handshake messages hash the primary address). For devices whose
`apns_topic` is `com.kachat.wallet`, skip everything except:

- `address_activity` (watch-only) pushes, and
- `name_event` pushes.

Simplest place: filter the resolved token list in each non-wallet fan-out (DM / handshake /
payment / inbox / group / group control / broadcast / KaPosts / ring) by dropping wallet-topic
tokens - or keep a per-topic allowlist of push kinds next to `APNS_ALLOWED_TOPICS`.

### 3. No "Received" push for a self-send (required)

Only Kaspa from someone else may ping. Anything the owner sends from their own addresses - in
the wallet, or in another app on the same seed (a KaPosts post, a KaChat message) - returns
change to a watched address and today gets a "Received" push (seen on 2026-10-26: a KaPosts
post from the same seed pinged the wallet).

The filter exists (`watch_only_tokens` drops a device that also watches `sender`), but
`emit_funds_received` (`indexer-actors/src/block_processor.rs`) finds `sender` only for the
FIRST input, and only through `tx_id_to_acceptance_partition` - which holds Kasia message txs
only, and its key's `receiver` is that tx's receiver, not the owner of the spent output. A coin
from a plain transfer, a KaPosts post or a coinbase gives `sender = None`, so the push goes out.

Fix: place EVERY input's spent output by its outpoint, not by the previous tx's message record.
For example, keep a partition (or a bounded LRU, a few hours deep) `outpoint (tx_id, index) ->
address payload` for outputs paying a watched (`watch_only_contains`) address, written in the
same pass that reads `tx.outputs`. In `emit_funds_received`, collect the addresses of all inputs
found there into `senders: Vec<AddressPayload>`, and have `watch_only_tokens` drop a device whose
`watch_only_addresses` contain ANY of them. Inputs not in the map are not the device's coins
(every coin a device owns paid one of its watched addresses), so no node lookup is needed. A
device that started watching after the coin was created has it missing from the map - seed the
map when a device registers or adds addresses (`getUtxosByAddresses` for the new addresses), or
accept a rare stray ping until those coins are spent once.

### 4. Optional: one banner per receive

While the wallet is open it shows its own local "Received" notification and hides the push
banner (it suppresses `funds:` threads in the foreground). While it is not open, or for a receive
that landed while it was away, it posts nothing and leaves the banner to the push (wallet, since
2026-10-26). Both can still show when the push arrives just after the app closes, for a receive
the open app already announced. If the service sent an `apns-collapse-id` for address-activity pushes,
the wallet could give its local notification the same identifier and iOS would show one. The
service omits it on purpose today (one tx can credit two addresses); a per-(tx, address) id
would need to fit APNs' 64-byte limit - e.g. the first 48 hex chars of the tx id plus a short
address hash. Not needed to ship.

## Testing

1. Deploy the service with `APNS_ALLOWED_TOPICS=com.kachat.app,com.kachat.wallet`.
2. Install a KaPay build on a phone, allow notifications on first launch (the wallet asks
   once, when its tabs first show). The log shows
   `[Push] Registered with indexer, watching N own addresses`.
3. Send KAS to the wallet's address from another wallet, with KaPay in the background:
   a "Received X KAS" push arrives; tapping it opens that address's history.
4. Server log: the send uses `topic=com.kachat.wallet`; no `DeviceTokenNotForTopic`.
5. KaChat on the same phone still gets its chat pushes (its topic is unchanged).

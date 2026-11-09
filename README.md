# KaPay

A Kaspa wallet for iPhone, from the makers of KaChat.

- **Portfolio** - your balance, its value, price and network charts, and every transaction
- **Cold Storage** - watch and spend funds held on an air-gapped KasSigner device (signing happens on the device, by QR)
- **.kachat** - the .kachat names marketplace: find, claim, buy and sell names
- **Wallet** - receive, send, your addresses, your domains, and Contacts (saved Kaspa
  addresses with names)
- **Settings** - appearance, security, connection, notifications, storage, and a backup of the
  Contacts and Portfolio to your own Nextcloud if you connect one

KaPay (formerly KaChat Wallet) started from KaChat's own wallet code
([KaChat-iPhone](https://github.com/KaspaSilver/KaChat-iPhone)) so KaChat can focus on chats. It
carries no chat code: only the wallet.

## For the server

What KaPay needs from the KaChat server is handed off in the server's own repo,
[KaChat-Indexer](https://github.com/KaspaSilver/KaChat-Indexer), under `docs/` (e.g.
`docs/KACHAT_WALLET_PUSH.md`). The push contract the app follows is
[PUSH_SERVICE.md](PUSH_SERVICE.md).

MIT licensed - see [LICENSE](LICENSE).

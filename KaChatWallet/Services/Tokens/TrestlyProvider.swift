import Foundation
import UIKit
import WebKit

/// The wallet provider Trestly's site talks to inside KaPay (kusdt-open SPEC §14, `window.kusdt`),
/// for the one address picked in Open Trestly. KaPay's own code answers every request; the page
/// never sees a key.
///
/// - Injected at document start, main frame only, and only on the Trestly origin set in Settings
///   (`TrestlyBrowserView.siteURL`): the script checks the page's origin, and the bridge checks the
///   sending frame's origin and that it is the main frame, so another site or an iframe gets nothing.
/// - trestly.io (its 2026-11-20 build) finds it by `window.kusdt`, by `kusdt#initialized` and by
///   `kusdt:announceProvider`, which is dispatched again whenever the page dispatches
///   `kusdt:requestProvider`. It reads what KaPay answers from `methods` (on the provider and on
///   `info`) and `kusdt_capabilities`, and names KaPay from `info`.
/// - Answers: `kaspa_requestAccounts` (the picked address: opening Trestly with it was the approval),
///   `kaspa_getNetwork`, `kaspa_switchNetwork` (only to the network KaPay is on; else 4200, since
///   KaPay switches networks in its own settings), `kusdt_getBalances` (that address's plain KAS
///   from the node and its node-checked kUSDT), `kusdt_capabilities`, and the trades `kusdt_swap`,
///   `kusdt_addLiquidity`, `kusdt_removeLiquidity`: Trestly's own wallet logic (`KusdtCore.wallet`,
///   bundled by tools/kusdt-wallet) checks and quotes, KaPay asks in `TrestlyApprovalSheet`, then the
///   same code builds, signs with this one address's key and sends. Everything else, including
///   `kusdt_send` and `kusdt_redeem`, is 4200, and the site says "KaPay does not support …".
@MainActor
final class TrestlyProvider: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {
    /// The bridge's name: `window.webkit.messageHandlers.kapay`.
    static let handlerName = "kapay"

    /// What KaPay answers, as `methods` and `kusdt_capabilities` say. Send and redeem aren't in it:
    /// the site says KaPay doesn't support them.
    static let methods = [
        "kaspa_requestAccounts", "kaspa_getNetwork", "kaspa_switchNetwork", "kusdt_getBalances",
        "kusdt_swap", "kusdt_addLiquidity", "kusdt_removeLiquidity",
    ]
    static let tradeMethods: Set<String> = ["kusdt_swap", "kusdt_addLiquidity", "kusdt_removeLiquidity"]

    /// The trade waiting for the user's answer, shown by `TrestlyBrowserView` as `TrestlyApprovalSheet`.
    @Published var approval: TrestlyApproval?
    /// One trade at a time, from its first check to the end of its send (audit, 2026-11-20): a second
    /// request while one is being prepared, shown or sent is answered -32002, so a sheet can never be
    /// swapped under the user's finger and two sends never run on one address's coins.
    private var tradeInFlight = false
    /// After Decline the page waits a moment before it can ask again, so sheets can't be popped up
    /// one after another.
    private var declinedAt: Date?
    /// The browser closed: nothing more is shown or signed for this page.
    private var closed = false
    /// "Swapped 10 KAS for 0.26 kUSDT" (or the other way round), shown over the page for a few seconds.
    @Published var banner: String?
    private var bannerToken = UUID()

    /// SPEC §14 error codes.
    enum Code {
        static let rejected = 4001
        static let unauthorized = 4100
        static let unsupported = 4200
        static let busy = -32002
        static let invalid = -32602
        static let failed = -32603
    }

    struct ProviderError: Error {
        let code: Int
        let message: String
    }

    let target: TrestlyTarget
    /// The only origin answered, e.g. "https://trestly.io".
    let allowedOrigin: (host: String, port: Int)
    /// Set once the page asked for the account (SPEC §14: before that, reads are 4100).
    private var connected = false
    /// Requests running now: more than 8 at once is -32002, as kUSDT Wallet does.
    private var running = 0

    init(target: TrestlyTarget, siteURL: URL) {
        self.target = target
        self.allowedOrigin = (siteURL.host?.lowercased() ?? "", siteURL.port ?? 443)
    }

    /// KaPay's network as the provider names it.
    static var networkName: String {
        AppSettings.load().networkType == .mainnet ? "mainnet" : "testnet-10"
    }

    // MARK: Installing

    /// Adds the script and the bridge to a web view's configuration (before the view is made).
    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
    }

    /// The page side: `window.kusdt`, frozen, only on the allowed https origin.
    private var script: String {
        let methodsJSON = Self.jsonString(Self.methods) ?? "[]"
        let info = Self.jsonString([
            "name": "KaPay",
            "rdns": "com.kachat.wallet",
            "icon": Self.iconDataURL ?? "",
        ]) ?? "{}"
        let host = Self.jsonString(allowedOrigin.host) ?? "\"\""
        let port = allowedOrigin.port
        return """
        (() => {
          'use strict';
          try {
            const port = location.port === '' ? 443 : Number(location.port);
            if (location.protocol !== 'https:' || location.hostname.toLowerCase() !== \(host) || port !== \(port)) return;
            if (window.kusdt) return;
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.handlerName);
            if (!bridge) return;
            const methods = Object.freeze(\(methodsJSON));
            const base = \(info);
            if (!base.icon) delete base.icon;
            const info = Object.freeze(Object.assign(base, { methods }));
            const listeners = Object.create(null);
            const fail = (code, message, data) => Object.assign(new Error(message), data === undefined ? { code } : { code, data });
            const provider = {
              isKaPay: true,
              info,
              methods,
              request(args) {
                if (!args || typeof args !== 'object' || typeof args.method !== 'string' || args.method.length > 64) {
                  return Promise.reject(fail(\(Code.invalid), 'Expected { method, params }.'));
                }
                let params = args.params === undefined ? null : args.params;
                let text;
                try { text = JSON.stringify(params); } catch (e) { return Promise.reject(fail(\(Code.invalid), 'Params must be JSON.')); }
                if (text !== undefined && text.length > 4096) return Promise.reject(fail(\(Code.invalid), 'Params are too long.'));
                return bridge.postMessage({ method: args.method, params: text === undefined ? null : JSON.parse(text) }).then((answer) => {
                  if (answer && answer.error) throw fail(answer.error.code, answer.error.message, answer.error.data);
                  return answer ? answer.result : null;
                }, (e) => { throw fail(\(Code.failed), String((e && e.message) || e)); });
              },
              on(event, listener) {
                if (typeof listener !== 'function') return provider;
                (listeners[event] = listeners[event] || []).push(listener);
                return provider;
              },
              removeListener(event, listener) {
                const list = listeners[event];
                if (list) listeners[event] = list.filter((l) => l !== listener);
                return provider;
              },
            };
            provider.off = provider.removeListener;
            Object.freeze(provider);
            Object.defineProperty(window, 'kusdt', { value: provider, writable: false, configurable: false, enumerable: true });
            const announce = () => {
              try { window.dispatchEvent(new CustomEvent('kusdt:announceProvider', { detail: Object.freeze({ provider, info }) })); } catch (e) {}
            };
            window.addEventListener('kusdt:requestProvider', announce);
            announce();
            try { window.dispatchEvent(new Event('kusdt#initialized')); } catch (e) {}
          } catch (e) {}
        })();
        """
    }

    // MARK: Answering

    /// The bridge's reply form (WebKit resolves the page's promise with what this returns).
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        // Only the allowed site's own page, never a frame or another origin.
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        let port = origin.port == 0 ? 443 : origin.port
        guard frame.isMainFrame, origin.protocol == "https", origin.host.lowercased() == allowedOrigin.host, port == allowedOrigin.port else {
            return (Self.errorAnswer(ProviderError(code: Code.unauthorized, message: "This page can't use KaPay.")), nil)
        }
        guard let request = message.body as? [String: Any], let method = request["method"] as? String, method.count <= 64 else {
            return (Self.errorAnswer(ProviderError(code: Code.invalid, message: "Expected { method, params }.")), nil)
        }
        // The page's own wrapper limits params, but a page can post to the bridge directly: the same
        // limits here, and only plain JSON (a Date or NaN would make JSONSerialization raise and
        // crash the app; audit, 2026-11-20).
        let rawParams = request["params"]
        if let rawParams, !(rawParams is NSNull) {
            guard JSONSerialization.isValidJSONObject([rawParams]),
                  let data = try? JSONSerialization.data(withJSONObject: [rawParams]), data.count <= 4096 + 2 else {
                return (Self.errorAnswer(ProviderError(code: Code.invalid, message: "Params must be JSON of at most 4096 characters.")), nil)
            }
        }
        guard running < 8 else {
            return (Self.errorAnswer(ProviderError(code: Code.busy, message: "KaPay is still answering this page's earlier requests.")), nil)
        }
        running += 1
        defer { running -= 1 }
        do {
            let result = try await answer(method, params: rawParams is NSNull ? nil : rawParams)
            return (["result": result ?? NSNull()], nil)
        } catch let error as ProviderError {
            return (Self.errorAnswer(error), nil)
        } catch {
            return (Self.errorAnswer(ProviderError(code: Code.failed, message: error.localizedDescription)), nil)
        }
    }

    private func answer(_ method: String, params: Any?) async throws -> Any? {
        switch method {
        case "kaspa_requestAccounts":
            connected = true
            return [target.address]
        case "kaspa_getNetwork":
            return Self.networkName
        case "kaspa_switchNetwork":
            guard connected else { throw ProviderError(code: Code.unauthorized, message: "Connect KaPay to this site first.") }
            guard let network = (params as? [String: Any])?["network"] as? String,
                  ["mainnet", "testnet-10", "simnet"].contains(network) else {
                throw ProviderError(code: Code.invalid, message: "Expected { network }.")
            }
            guard network == Self.networkName else {
                throw ProviderError(code: Code.unsupported, message: "KaPay changes networks only in its own Settings.")
            }
            return network
        case "kusdt_getBalances":
            guard connected else { throw ProviderError(code: Code.unauthorized, message: "Connect KaPay to this site first.") }
            return try await balances()
        case "kusdt_capabilities":
            return Self.methods
        case _ where Self.tradeMethods.contains(method):
            guard connected else { throw ProviderError(code: Code.unauthorized, message: "Connect KaPay to this site first.") }
            return try await trade(method, params: params)
        default:
            throw ProviderError(code: Code.unsupported, message: "KaPay doesn't support \(method) here.")
        }
    }

    // MARK: Trades (Trestly's own wallet logic, `KusdtCore.wallet`)

    /// A swap, a deposit or a withdrawal: Trestly's code checks the pool and quotes (`prepare`), KaPay
    /// shows it (`TrestlyApprovalSheet`), and only on Approve hands it this address's key to build,
    /// sign and send (`execute`). A pool that moved to a worse quote comes back as a requote, shown
    /// again; their code never goes below the site's minimum.
    private func trade(_ method: String, params: Any?) async throws -> Any? {
        guard !closed else { throw ProviderError(code: Code.unauthorized, message: "KaPay closed this page.") }
        guard !tradeInFlight, approval == nil else {
            throw ProviderError(code: Code.busy, message: "KaPay is already working on a request from this page.")
        }
        if let declinedAt, Date().timeIntervalSince(declinedAt) < 3 {
            throw ProviderError(code: Code.rejected, message: "You declined in KaPay a moment ago.")
        }
        tradeInFlight = true
        defer { tradeInFlight = false }
        guard let owner = Kusdt.schnorrOwner(of: target.address) else {
            throw ProviderError(code: Code.failed, message: "KaPay can't trade from this kind of address.")
        }
        let paramsJSON: Any = params ?? NSNull()
        var wallet: [String: Any] = [
            "network": Self.networkName,
            "address": target.address,
            "ownerHex": Kusdt.hex(owner),
            "apiUrl": AppSettings.load().trestlyAPIURL,
        ]
        var prepared = try await walletCall("prepare", ["method": method, "params": paramsJSON, "wallet": wallet])
        var seen: [String: Any]? = nil

        while true {
            let approved = await ask(TrestlyApproval(method: method, prepared: prepared, seen: seen, from: target.label))
            guard approved, !closed else {
                declinedAt = Date()
                throw ProviderError(code: Code.rejected, message: "You declined in KaPay. Nothing was sent.")
            }

            guard let secret = target.spendingIndex.map({ WalletManager.shared.spendingPrivateKey(at: $0) }) ?? WalletManager.shared.getPrivateKey() else {
                throw ProviderError(code: Code.failed, message: "KaPay couldn't unlock this address's key.")
            }
            wallet["secret"] = Kusdt.hex(secret)
            var request: [String: Any] = ["method": method, "params": paramsJSON, "wallet": wallet,
                                          "shownFeerate": prepared["feerate"] ?? NSNull(),
                                          "acceptedFee": prepared["acceptedFee"] ?? NSNull()]
            if method == "kusdt_removeLiquidity" {
                request["quoted"] = ["kasOut": prepared["kasOut"] ?? NSNull(), "tokensOut": prepared["tokensOut"] ?? NSNull()] as [String: Any]
            } else {
                request["quoted"] = prepared["quote"] ?? NSNull()
            }
            let done = try await walletCall("execute", request)
            wallet["secret"] = nil

            for step in (done["steps"] as? [String]) ?? [] { AddressActivityNotifier.shared.markOwnTransaction(step) }
            // the coins it spent are held like a send's own (10 minutes), so a send from this
            // address right after can't pick them (audit, 2026-11-20)
            let spent = ((done["inputs"] as? [String]) ?? []).filter { $0.count > 65 && $0.count < 80 }
            if !spent.isEmpty { WalletService.shared.reserveOutpoints(spent) }
            if done["requote"] != nil {
                // The pool moved and pays less than approved: nothing was sent. Trestly's code
                // prepares it again from scratch, so the sheet shows the new quote with its own
                // warnings, fee and minimum check, not the first one's (audit, 2026-11-20).
                if method == "kusdt_removeLiquidity" {
                    seen = ["kasOut": prepared["kasOut"] ?? "0", "tokensOut": prepared["tokensOut"] ?? "0"]
                } else {
                    seen = ["quote": prepared["quote"] ?? "0"]
                }
                prepared = try await walletCall("prepare", ["method": method, "params": paramsJSON, "wallet": wallet])
                continue
            }
            guard let result = done["result"] as? [String: Any] else {
                throw ProviderError(code: Code.failed, message: "Trestly's pool code gave no result.")
            }
            if let txid = result["txid"] as? String {
                AddressActivityNotifier.shared.markOwnTransaction(txid)
                if method == "kusdt_swap" { announceSwap(txid: txid, prepared: prepared, result: result, fee: done["fee"]) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await TokenWallet.shared.refresh()
            }
            return result
        }
    }

    /// A swap that went through: a banner over the page, a line in Notifications (the bell), and the
    /// kUSDT side in that address's history. "Swapped" once the node shows it accepted; "Swap sent"
    /// when it went out and wasn't seen accepted in time (it may still be).
    private func announceSwap(txid: String, prepared: [String: Any], result: [String: Any], fee: Any?) {
        guard let amountIn = TrestlyApproval.number(prepared["amountIn"]),
              let amountOut = TrestlyApproval.number(result["amountOut"]) else { return }
        let bought = prepared["side"] as? String == "buy"
        let kas = KaspaUnit.amount(bought ? amountIn : amountOut)
        let kusdt = TokenAmount.amount(bought ? amountOut : amountIn, token: .kusdt)
        let confirmed = result["confirmed"] as? Bool != false
        let text = String(format: AppLocalization.string(confirmed ? "Swapped %@ for %@" : "Swap sent: %@ for %@"),
                          bought ? kas : kusdt, bought ? kusdt : kas)

        Haptics.success()
        let token = UUID()
        bannerToken = token
        banner = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self.bannerToken == token { self.banner = nil }
        }
        GlobalNotificationCenter.shared.record(id: "trestly-swap-\(txid)", source: .token,
                                               title: AppLocalization.string(confirmed ? "Swap Complete" : "Swap Sent"),
                                               body: text, timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                                               targetId: WalletToken.kusdt.id)
        TokenWallet.shared.noteSwap(token: .kusdt, spendingIndex: target.spendingIndex, txid: txid,
                                    units: bought ? amountOut : amountIn, sold: !bought,
                                    fee: TrestlyApproval.number(fee))
    }

    /// One call into Trestly's code; its refusal becomes the provider's error (their message, their code).
    private func walletCall(_ function: String, _ request: [String: Any]) async throws -> [String: Any] {
        let answer: [String: Any]
        do {
            answer = try await KusdtCore.shared.wallet(function, request: request)
        } catch {
            throw ProviderError(code: Code.failed, message: error.localizedDescription)
        }
        if let message = answer["error"] as? String {
            let code = (answer["code"] as? NSNumber)?.intValue ?? Code.failed
            let maybeSent = answer["maybeSent"] as? Bool == true
            throw ProviderError(code: code, message: maybeSent ? message + " " + AppLocalization.string("Check the address's history before trying again.") : message)
        }
        return answer
    }

    /// Shows the approval and waits for Approve or Decline (closing the sheet declines).
    private func ask(_ request: TrestlyApproval) async -> Bool {
        // a page that is gone gets no sheet (it would never be answered)
        guard !closed else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            request.answer = { approved in continuation.resume(returning: approved) }
            approval = request
        }
    }

    /// The browser closed (Done): a sheet still up is declined, and nothing later is shown or signed.
    func close() {
        closed = true
        let pending = approval
        approval = nil
        pending?.respond(false)
    }

    /// `{kas, kusdt}` for the connected address, as decimal strings (sompi and base units): the plain
    /// KAS coins the node shows at it, and its kUSDT as `TokenWallet` checked it on the node.
    private func balances() async throws -> [String: String] {
        let utxos: [UTXO]
        do {
            utxos = try await NodePoolService.shared.getUtxosByAddresses([target.address], allowRestFallback: false)
        } catch {
            throw ProviderError(code: Code.failed, message: "KaPay couldn't read this address's KAS just now.")
        }
        let kas = utxos.filter { $0.covenantId == nil }.reduce(UInt64(0)) { $0 &+ $1.amount }

        let tokens = TokenWallet.shared
        await tokens.refreshIfStale()
        guard tokens.balance(of: .kusdt) != nil else {
            throw ProviderError(code: Code.failed, message: tokens.lastError ?? "KaPay couldn't check this address's kUSDT just now.")
        }
        let kusdt = tokens.holdings(of: .kusdt).first(where: { $0.address == target.address })?.units ?? 0
        return ["kas": String(kas), "kusdt": String(kusdt)]
    }

    // MARK: Helpers

    private static func errorAnswer(_ error: ProviderError) -> [String: Any] {
        ["error": ["code": error.code, "message": error.message]]
    }

    private static func jsonString(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// KaPay's logo as a small PNG data URL for `info.icon` (the site takes up to 256 KB).
    private static let iconDataURL: String? = {
        guard let image = UIImage(named: "KaChatWalletLogo") else { return nil }
        let size = CGSize(width: 96, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard png.count < 200_000 else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }()
}

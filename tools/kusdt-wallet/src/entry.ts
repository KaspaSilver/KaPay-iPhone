// KaPay's entry into Trestly's own kUSDT wallet logic (kusdt-open wallet/extension/src/kusdt): the
// pool checks, quotes, the circuit breaker, merges, builds, races and outcomes are theirs, untouched.
// This file only does what their approval window (screens/Approve.tsx) does around them, for one
// address of KaPay's, and answers in JSON (amounts as decimal strings).
//
// window.kapayWallet.prepare(request) → what the approval sheet shows, or { error }
// window.kapayWallet.execute(request) → the provider's answer (with the inputs it spent, which KaPay
//                                       holds like its own sends'), { requote } when the pool moved to a
//                                       worse quote (the sheet asks again), or { error }
// request: { method, params, wallet: { network, address, ownerHex, apiUrl, secret? }, quoted? }
// The secret key is in `wallet` only for execute, for that one call.
import './shims';
import * as wasm from './kusdt_wasm.js';
import { makeCore } from '@kusdt/core/core';
import { KASPA_NETWORKS } from '@kusdt/kaspa';
import { setCoreLoader, getCore } from '@/lib/core';
import { DEFAULTS, type KaspaNetworkName } from '@/config/defaults';
import { KaspaNodeClient, MaybeSent, type KaspaNodeApi } from '@/kaspa/node';
import { CoordinatorClient } from '@/kusdt/api';
import { kasBalance } from '@/kaspa/kas';
import {
  freshPool, quoteBuy, quoteSellAt, sellNowDaa, largestSellWithin, windowOver, secondsUntilDaa, swap, QuoteChanged,
  maxBuyAcceptedFee, poolFeeAbout, poolFeeShareText, trimToShares, quoteAdd, addRatioProblem, addLiquidity, minimumFor,
  loadPositions, quoteRemove, removeLiquidity,
} from '@/kusdt/pool';
import { inputsOf } from '@/kusdt/pending';
import type { Ctx, Signer } from '@/kusdt/types';

setCoreLoader(() => makeCore(wasm as any));

interface WalletIn { network: KaspaNetworkName; address: string; ownerHex: string; apiUrl: string; secret?: string }
interface Request { method: string; params: any; wallet: WalletIn; quoted?: any; shownFeerate?: number; acceptedFee?: string | null }

const nodes = new Map<string, KaspaNodeApi>();
const nodeFor = (network: KaspaNetworkName): KaspaNodeApi => {
  let n = nodes.get(network);
  if (!n) { n = new KaspaNodeClient(network, ''); nodes.set(network, n); }
  return n;
};

async function ctxFor(w: WalletIn): Promise<Ctx> {
  if (w.network !== 'mainnet' && w.network !== 'testnet-10') throw new Error('KaPay trades only on mainnet and testnet-10.');
  const config = { ...DEFAULTS[w.network], apiUrl: w.apiUrl || DEFAULTS[w.network].apiUrl };
  return {
    core: await getCore(),
    node: nodeFor(w.network),
    api: new CoordinatorClient(config.apiUrl),
    network: w.network,
    net: KASPA_NETWORKS[w.network],
    config,
  };
}

/** One address: it is the owner, the change, the funding and the only key. */
function signerFor(w: WalletIn): Signer {
  return {
    address: w.address,
    ownerHex: w.ownerHex,
    secretFor: (address: string) => (address === w.address && w.secret ? w.secret : null),
  };
}

const nat = (v: unknown, what: string): bigint => {
  if (typeof v === 'number' && Number.isSafeInteger(v) && v >= 0) return BigInt(v);
  if (typeof v === 'string' && /^\d{1,30}$/.test(v)) return BigInt(v);
  throw Object.assign(new Error(`${what} must be a whole number.`), { code: -32602 });
};

const json = (value: unknown): string => JSON.stringify(value, (_k, v) => (typeof v === 'bigint' ? v.toString() : v));

const failure = (e: unknown) => {
  const error = e instanceof Error ? e.message : String(e);
  const code = (e as { code?: unknown })?.code;
  return { error, ...(typeof code === 'number' ? { code } : {}), ...(e instanceof MaybeSent ? { maybeSent: true } : {}) };
};

// ── What the approval sheet shows (screens/Approve.tsx, the same checks) ─────────────────────────

async function prepareSwap(ctx: Ctx, w: WalletIn, p: any) {
  if (p?.side !== 'buy' && p?.side !== 'sell') throw Object.assign(new Error('side must be "buy" or "sell".'), { code: -32602 });
  const amountIn = nat(p.amountIn, 'amountIn'), minOut = nat(p.minOut, 'minOut');
  const [vp, feerate] = await Promise.all([freshPool(ctx), ctx.node.feerate()]);
  if (!vp.reserve || vp.pool.state.totalShares === 0n) throw new Error('The pool has no liquidity yet, so there is nothing to swap with.');
  const state = vp.pool.state;
  const spendable = p.side === 'buy' ? await kasBalance(ctx.node, ctx.network, [w.address]).then(k => k.spendable, () => null) : null;
  const acceptedFee = maxBuyAcceptedFee(ctx, p.side, amountIn, spendable);
  let quote: bigint, breaker: string | null = null;
  if (p.side === 'buy') quote = quoteBuy(ctx, state, amountIn);
  else {
    const nowDaa = sellNowDaa(state, await ctx.node.virtualDaa());
    const s = quoteSellAt(ctx, state, amountIn, nowDaa, vp.pool.utxo.blockDaaScore);
    quote = s.kasOut;
    if (!s.breaker.allowed) {
      const fit = largestSellWithin(ctx, state, s.breaker.maxKasOut, amountIn);
      breaker = JSON.stringify({ maxKasOut: s.breaker.maxKasOut.toString(), fit: fit.toString(), seconds: windowOver(s.breaker.windowEndsDaa, nowDaa) ? 0 : secondsUntilDaa(s.breaker.windowEndsDaa, nowDaa) });
    }
  }
  const feeAbout = poolFeeAbout(feerate);
  return {
    kind: 'swap', side: p.side, amountIn, minOut, quote, feeAbout, feerate, acceptedFee: acceptedFee ?? null,
    tokenValue: BigInt(ctx.config.tokenValue), paused: state.paused, breaker,
    belowMinimum: quote < minOut, feeShare: poolFeeShareText(feeAbout, p.side === 'buy' ? amountIn : quote) !== null,
    blocked: state.paused || breaker !== null || quote < minOut,
  };
}

async function prepareAdd(ctx: Ctx, p: any) {
  const kasIn = nat(p?.kasIn, 'kasIn'), tokensIn = nat(p?.tokensIn, 'tokensIn');
  const [vp, feerate] = await Promise.all([freshPool(ctx), ctx.node.feerate()]);
  if (!vp.reserve || vp.pool.state.totalShares === 0n) throw new Error('The pool has no liquidity yet.');
  const used = trimToShares(vp.pool.state, kasIn, tokensIn);
  const quote = quoteAdd(ctx, vp.pool.state, used.kasIn, used.tokensIn);
  const off = addRatioProblem(vp.pool.state, kasIn, tokensIn);
  const feeAbout = poolFeeAbout(feerate);
  return {
    kind: 'add', kasIn: used.kasIn, tokensIn: used.tokensIn, askedKasIn: kasIn, askedTokensIn: tokensIn, quote, feeAbout, feerate,
    positionValue: BigInt(ctx.config.positionValue), tokenValue: BigInt(ctx.config.tokenValue),
    paused: vp.pool.state.paused, offRatio: off !== null, feeShare: poolFeeShareText(feeAbout, used.kasIn) !== null,
    blocked: vp.pool.state.paused || off !== null,
  };
}

async function prepareRemove(ctx: Ctx, w: WalletIn, p: any) {
  if (typeof p?.position !== 'string') throw Object.assign(new Error('position must be a "txid:index" string.'), { code: -32602 });
  const pos = (await loadPositions(ctx, signerFor(w))).find(x => x.id === p.position);
  if (!pos) throw new Error("That position isn't one of this address's.");
  const [vp, feerate] = await Promise.all([freshPool(ctx), ctx.node.feerate()]);
  const q = quoteRemove(ctx, vp.pool.state, pos.located.state.shares);
  const feeAbout = poolFeeAbout(feerate);
  return {
    kind: 'remove', position: p.position, shares: pos.located.state.shares, kasOut: q.kasOut, tokensOut: q.tokensOut, feeAbout, feerate,
    unread: pos.unread === true, feeShare: poolFeeShareText(feeAbout, q.kasOut) !== null, blocked: false,
  };
}

async function prepare(r: Request) {
  const ctx = await ctxFor(r.wallet);
  if (r.method === 'kusdt_swap') return prepareSwap(ctx, r.wallet, r.params);
  if (r.method === 'kusdt_addLiquidity') return prepareAdd(ctx, r.params);
  if (r.method === 'kusdt_removeLiquidity') return prepareRemove(ctx, r.wallet, r.params);
  throw Object.assign(new Error('Unsupported request.'), { code: 4200 });
}

// ── Doing it, on the numbers the user approved ──────────────────────────────────────────────────

async function execute(r: Request) {
  const w = r.wallet;
  if (!w.secret) throw new Error('No key was given for this address.');
  const ctx = await ctxFor(w);
  const signer = signerFor(w);
  const steps: string[] = [];
  const onStep = (txid: string) => { steps.push(txid); };
  // The feerate the sheet showed: a build at more than half as much again is not sent (their R15-CL-3).
  if (typeof r.shownFeerate !== 'number' || !(r.shownFeerate > 0)) throw new Error('No network fee was shown for this.');
  const feerate = r.shownFeerate;
  try {
    if (r.method === 'kusdt_swap') {
      const p = r.params;
      const amountIn = nat(p.amountIn, 'amountIn'), minOut = nat(p.minOut, 'minOut'), quoted = nat(r.quoted, 'quoted');
      // the fee the sheet showed besides, for a Max buy (as their window passes it)
      const acceptedFee = r.acceptedFee != null ? nat(r.acceptedFee, 'acceptedFee') : undefined;
      const res = await swap(ctx, signer, [w.address], { side: p.side, amountIn, minOut, quoted, shownFeerate: feerate, acceptedFee }, onStep);
      return { result: { txid: res.txid, amountOut: res.amountOut.toString(), confirmed: res.confirmed }, fee: res.built.fee, steps, inputs: inputsOf(res.built.transaction) };
    }
    if (r.method === 'kusdt_addLiquidity') {
      const kasIn = nat(r.params.kasIn, 'kasIn'), tokensIn = nat(r.params.tokensIn, 'tokensIn'), quoted = nat(r.quoted, 'quoted');
      const res = await addLiquidity(ctx, signer, [w.address], { kasIn, tokensIn, minShares: minimumFor(quoted, 100), quoted, shownFeerate: feerate }, onStep);
      return { result: { txid: res.txid, shares: res.shares.toString(), confirmed: res.confirmed }, fee: res.built.fee, steps, inputs: inputsOf(res.built.transaction) };
    }
    if (r.method === 'kusdt_removeLiquidity') {
      const q = { kasOut: nat(r.quoted?.kasOut, 'kasOut'), tokensOut: nat(r.quoted?.tokensOut, 'tokensOut') };
      const res = await removeLiquidity(ctx, signer, [w.address], { position: r.params.position, minKas: minimumFor(q.kasOut, 100), minTokens: minimumFor(q.tokensOut, 100), quoted: q, shownFeerate: feerate });
      return { result: { txid: res.txid, confirmed: res.confirmed }, fee: res.built.fee, steps, inputs: inputsOf(res.built.transaction) };
    }
  } catch (e) {
    if (e instanceof QuoteChanged) return { requote: e.now, seen: e.seen, steps };
    throw e;
  }
  throw Object.assign(new Error('Unsupported request.'), { code: 4200 });
}

(globalThis as any).kapayWallet = Object.freeze({
  prepare: (text: string) => prepare(JSON.parse(text)).then(json, (e) => json(failure(e))),
  execute: (text: string) => execute(JSON.parse(text)).then(json, (e) => json(failure(e))),
});

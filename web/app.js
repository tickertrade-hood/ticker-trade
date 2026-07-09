'use strict';
/* TICKER.TRADE on Robinhood Chain — vanilla dapp + gamification.
   Reads the whole board in one call via TickerLens.snapAll(); falls back to a
   labelled DEMO dataset when CFG.hub/lens are unset so the UI is viewable pre-deploy. */

const CFG = window.CFG;
const E = ethers;
const $ = (s, r = document) => r.querySelector(s);
const el = (t, c, h) => { const n = document.createElement(t); if (c) n.className = c; if (h != null) n.innerHTML = h; return n; };
// escape EVERY chain-derived string before it touches innerHTML — ticker name/
// symbol are attacker-controlled (anyone can launch()), so this blocks stored XSS.
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
const fmtU = (x, d = CFG.usdgDecimals) => Number(E.formatUnits(x ?? 0n, d));
const usd = n => (n >= 1e6 ? '$' + (n/1e6).toFixed(2) + 'M' : n >= 1e3 ? '$' + (n/1e3).toFixed(1) + 'k' : '$' + n.toFixed(2));
const pct = n => (n >= 0 ? '+' : '') + n.toFixed(1) + '%';
const short = a => a ? a.slice(0, 6) + '…' + a.slice(-4) : '';

const LENS_ABI = [
  'function count() view returns (uint256)',
  'function snapAll() view returns (tuple(uint256 id,address token,address vault,address trader,string name,string symbol,uint64 createdAt,bool graduated,bool mintFresh,uint256 price,uint256 nav,uint256 vaultValue,uint256 circ,uint256 marketCap,uint256 exitReserve,uint256 creatorFees,uint256 vaultQuote,uint256 queueDepth,int256 premiumBps)[])',
];
const HUB_ABI = [
  'function launch(string,string,uint256) returns (uint256)',
  'function buy(uint256,uint256,uint256) returns (uint256)',
  'function sell(uint256,uint256,uint256,bool) returns (uint256,bool)',
  'function redeem(uint256,uint256)',
  'function settleQueue(uint256,uint256) returns (uint256)',
  'function claimCreatorFees(uint256) returns (uint256)',
  'function claimSeed(uint256)',
  'function quoteBuy(uint256,uint256) view returns (uint256,uint256,bool)',
  'function quoteSell(uint256,uint256) view returns (uint256,uint256,bool)',
  'function LAUNCH_FEE() view returns (uint256)',
  'function MIN_SEED() view returns (uint256)',
];
const ERC20_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address,address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function mint(address,uint256)', // local mock USDG faucet only
];
const STAKING_ABI = [
  'function stake(uint256)',
  'function unstake(uint256)',
  'function claim() returns (uint256)',
  'function pending(address) view returns (uint256)',
  'function staked(address) view returns (uint256)',
  'function totalStaked() view returns (uint256)',
];

const S = { route: 'board', id: null, side: 'buy', me: null, signer: null, board: [], demo: false, provider: null, loading: true };

/* ---------------- providers ---------------- */
function readProvider() {
  return new E.JsonRpcProvider(CFG.rpc, { chainId: CFG.chainId, name: CFG.chainName });
}
function live() { return CFG.hub && CFG.lens; }

/* ---------------- gamification engine ----------------
   Turns on-chain snapshot data into a trader score, tier, XP level and badges.
   Everything here is derived from objective readable metrics — no hidden inputs. */
const DAY = 86400;
function nowSec() { return Math.floor(Date.now() / 1000); }

function traderScore(t) {
  // AUM (log-scaled), track record (days), graduation, market confidence (premium)
  const aum = fmtU(t.vaultValue);
  const ageD = Math.max(0, (nowSec() - Number(t.createdAt)) / DAY);
  const prem = Number(t.premiumBps) / 100; // %
  const aumPts = aum <= 0 ? 0 : Math.min(50, Math.log10(aum + 1) * 12);      // up to ~50
  const agePts = Math.min(25, ageD * 0.8);                                    // up to 25 (~31d)
  const gradPts = t.graduated ? 15 : 0;
  const confPts = Math.max(-10, Math.min(10, prem / 5));                      // hype, capped ±10
  return Math.max(0, aumPts + agePts + gradPts + confPts);
}
function tierOf(t) {
  const aum = fmtU(t.vaultValue), ageD = (nowSec() - Number(t.createdAt)) / DAY;
  if (t.graduated && aum >= 500000) return { k: 'legend', label: 'Legend' };
  if (t.graduated) return { k: 'grad', label: 'Graduated' };
  if (aum >= 50000 && ageD >= 7) return { k: 'pro', label: 'Pro' };
  return { k: 'rookie', label: 'Rookie' };
}
function xpOf(t) {
  const score = traderScore(t);
  const lvl = Math.max(1, Math.floor(score / 12) + 1);
  const into = (score % 12) / 12;
  return { lvl, into };
}
function badges(t) {
  const b = [];
  const prem = Number(t.premiumBps) / 100;
  const ageD = (nowSec() - Number(t.createdAt)) / DAY;
  if (!t.mintFresh) b.push({ c: 'halt', t: 'FEED STALE', title: 'At-NAV minting paused: stock feed older than 36h (weekend/holiday)' });
  if (prem <= 0) b.push({ c: 'floor', t: 'AT FLOOR', title: 'Trading at/below NAV — buys mint at the floor, no downside vs backing' });
  if (prem >= 40) b.push({ c: 'hot', t: 'HOT', title: 'High premium — strong speculative demand over the floor' });
  if (t.graduated) b.push({ c: '', t: '★ GRAD', title: 'Graduated: $250k+ vault and 30-day track record, lower fees' });
  if (ageD >= 30 && !t.graduated) b.push({ c: '', t: 'VETERAN', title: '30+ day track record' });
  if (Number(t.queueDepth) > 0) b.push({ c: '', t: 'QUEUE ' + t.queueDepth, title: 'Redemptions pending settlement' });
  return b;
}
// avatars are uniform (accent-wash + mono symbol) per the editorial system —
// no rainbow gradients. The .av class carries the styling.
function av(sym) { return `<div class="av">${esc(sym.slice(0, 2))}</div>`; }

/* ---------------- data ---------------- */
async function loadBoard() {
  if (!live()) { S.demo = true; S.loading = false; S.board = demoBoard(); return; }
  S.demo = false;
  S.loading = false;
  const lens = new E.Contract(CFG.lens, LENS_ABI, S.provider);
  const raw = await lens.snapAll();
  S.board = raw.map(r => ({
    id: Number(r.id), token: r.token, vault: r.vault, trader: r.trader,
    name: r.name, symbol: r.symbol, createdAt: Number(r.createdAt),
    graduated: r.graduated, mintFresh: r.mintFresh,
    price: r.price, nav: r.nav, vaultValue: r.vaultValue, circ: r.circ,
    marketCap: r.marketCap, exitReserve: r.exitReserve, creatorFees: r.creatorFees,
    vaultQuote: r.vaultQuote, queueDepth: Number(r.queueDepth), premiumBps: r.premiumBps,
  }));
}

/* ---------------- render: shell ---------------- */
function setRoute(r, id) {
  S.route = r; S.id = id ?? null;
  document.querySelectorAll('.tab').forEach(b => b.classList.toggle('active', b.dataset.nav === r));
  render();
}
function render() {
  const v = $('#view'); v.innerHTML = '';
  $('#mode-badge').className = 'chip ' + (S.demo ? 'warn' : 'live');
  $('#mode-badge').textContent = S.demo ? 'DEMO' : 'LIVE';
  $('#mode-badge').title = S.demo ? 'No contracts configured — showing sample data' : 'Connected to Robinhood Chain';
  if (S.route === 'board') return renderBoard(v);
  if (S.route === 'leaderboard') return renderLeaderboard(v);
  if (S.route === 'stake') return renderStake(v);
  if (S.route === 'portfolio') return renderPortfolio(v);
  if (S.route === 'how') return renderHow(v);
  if (S.route === 'detail') return renderDetail(v);
}

function tvl() { return S.board.reduce((a, t) => a + fmtU(t.vaultValue), 0); }

/* ---------------- board ---------------- */
function renderBoard(v) {
  const hero = el('div', 'hero');
  hero.innerHTML = `
    <div>
      <h1>Back a trader.<br/><span class="hl">The floor is their book.</span></h1>
      <p>Every token here is backed by a real trading vault. Buy in, and you can always cash out for your share of what's actually in it — whatever the price is doing. The trader grows the vault; they can't touch your money.</p>
      <div class="founded">Founded by <a href="https://x.com/altheusresearch" target="_blank" rel="noopener noreferrer">@altheusresearch</a></div>
    </div>
    <div class="stats">
      <div class="stat"><b>${usd(tvl())}</b><span>Total backing</span></div>
      <div class="stat"><b>${S.board.length}</b><span>Tickers</span></div>
    </div>`;
  v.appendChild(hero);

  v.appendChild(headBlock('The board', 'every row is a live on-chain vault — click any to trade'));

  const card = el('div', 'card');
  if (S.loading && !S.board.length) { card.innerHTML = skel(); v.appendChild(card); return; }
  const rows = [...S.board].sort((a, b) => fmtU(b.vaultValue) - fmtU(a.vaultValue)).map(t => {
    const prem = Number(t.premiumBps) / 100;
    const pv = Math.min(100, Math.abs(prem));
    const bd = badges(t).map(x => `<span class="badge ${x.c}" title="${x.title}">${x.t}</span>`).join('');
    return `<tr data-id="${t.id}">
      <td><div class="tk">${av(t.symbol)}
        <div><div class="sym">${esc(t.symbol)} ${bd}</div><div class="nm">${esc(t.name)} · ${esc(short(t.trader))}</div></div></div></td>
      <td class="mono">${usd(fmtU(t.price))}</td>
      <td class="floor">${usd(fmtU(t.nav))}</td>
      <td><span class="prem-cell"><span class="mono ${prem>=0?'up':'down'}">${pct(prem)}</span>
        <span class="pbar ${prem<0?'neg':''}"><i style="width:${pv}%"></i></span></span></td>
      <td class="mono">${usd(fmtU(t.vaultValue))}</td>
      <td>${tierBadge(t)}</td>
    </tr>`;
  }).join('');
  card.innerHTML = `<table><thead><tr>
      <th>Trader ticker</th><th>Price</th><th>Floor (NAV)</th>
      <th>Premium</th><th>Backing</th><th>Tier</th>
    </tr></thead><tbody>${rows || emptyRow()}</tbody></table>`;
  v.appendChild(card);
  card.querySelectorAll('tr[data-id]').forEach(r => r.onclick = () => setRoute('detail', Number(r.dataset.id)));
}
function tierBadge(t) { const x = tierOf(t); return `<span class="tier ${x.k}">${x.label}</span>`; }
function emptyRow() { return `<tr><td colspan="6"><div class="empty">No tickers yet — be the first to <b>Launch yourself</b>.</div></td></tr>`; }
function skel() { return `<div class="skel">${Array(4).fill('<div class="skel-row"></div>').join('')}</div>`; }

/* ---------------- leaderboard ---------------- */
function renderLeaderboard(v) {
  v.appendChild(headBlock('Trader leaderboard', 'Ranked by a composite of assets under management, track record, graduation and market confidence — all read live from chain.'));
  const ranked = [...S.board].map(t => ({ t, score: traderScore(t) })).sort((a, b) => b.score - a.score);
  const card = el('div', 'card');
  const rows = ranked.map((r, i) => {
    const t = r.t, x = xpOf(t), tier = tierOf(t);
    const g = i === 0 ? 'g1' : i === 1 ? 'g2' : i === 2 ? 'g3' : '';
    const roi = fmtU(t.vaultValue); // AUM as the headline number
    return `<tr data-id="${t.id}">
      <td class="rank ${g}">${i+1}</td>
      <td><div class="tk">${av(t.symbol)}
        <div><div class="sym">${esc(t.symbol)} <span class="tier ${tier.k}">${tier.label}</span></div>
        <div class="nm">${esc(short(t.trader))}</div></div></div></td>
      <td class="mono">${usd(roi)}</td>
      <td class="mono ${Number(t.premiumBps)>=0?'up':'down'}">${pct(Number(t.premiumBps)/100)}</td>
      <td><span class="xp"><span class="lvl">Lv ${x.lvl}</span><span class="track"><i style="width:${(x.into*100).toFixed(0)}%"></i></span><span class="lvl mono">${r.score.toFixed(0)}</span></span></td>
    </tr>`;
  }).join('');
  card.innerHTML = `<table><thead><tr>
      <th style="width:26px;text-align:center">#</th><th>Trader</th><th>Backing</th>
      <th>Premium</th><th>Level / score</th>
    </tr></thead><tbody>${rows || emptyRow()}</tbody></table>`;
  v.appendChild(card);
  card.querySelectorAll('tr[data-id]').forEach(r => r.onclick = () => setRoute('detail', Number(r.dataset.id)));
}
function headBlock(h, sub) { const d = el('div', 'section-h'); d.innerHTML = `<h2>${h}</h2><span class="sub">${sub}</span>`; return d; }

/* ---------------- stake $TICK ---------------- */
async function loadStake() {
  const s = { live: !!(CFG.tick && CFG.feeStaking), tvl: 0n, myStake: 0n, myPending: 0n, myBal: 0n };
  if (!s.live) return s;
  try {
    const st = new E.Contract(CFG.feeStaking, STAKING_ABI, S.provider);
    const tk = new E.Contract(CFG.tick, ERC20_ABI, S.provider);
    s.tvl = await st.totalStaked();
    if (S.me) {
      s.myStake = await st.staked(S.me);
      s.myPending = await st.pending(S.me);
      s.myBal = await tk.balanceOf(S.me);
    }
  } catch (e) { console.error(e); }
  return s;
}
function renderStake(v) {
  v.appendChild(headBlock('Stake $TICK', 'stake TICK to earn a share of protocol fees — paid in real USDG, not emissions'));
  if (!CFG.tick || !CFG.feeStaking) {
    const d = el('div', 'panel');
    d.innerHTML = `<h3>Not live yet</h3><p class="dim" style="font-size:13.5px;margin-top:6px">$TICK launches on <b>NOXA</b>. Once it's live, the token + staking addresses drop into the config and this page turns on: stake TICK, earn USDG from every trade and launch on the platform. <span class="mono">70%</span> of protocol fees flow to stakers.</p>`;
    v.appendChild(d); return;
  }
  const wrap = el('div', 'grid2');
  const info = el('div', 'panel');
  info.innerHTML = `<h3>How it works</h3>
    <p class="dim" style="font-size:13.5px">Every trade pays a 1% fee and every launch pays $50 — <b>70% of that flows to $TICK stakers in USDG</b>. Stake, and your share accrues in real time. No lockup, no emissions — this is real yield from real platform revenue. Unstake or claim anytime.</p>
    <div class="quote" id="stake-stats" style="margin-top:14px"><div class="row dim">loading…</div></div>`;
  const box = el('div', 'panel');
  box.innerHTML = `
    <div class="seg"><button class="active" data-st="stake">Stake</button><button data-st="unstake">Unstake</button></div>
    <div class="field"><input id="st-amt" placeholder="0.0" inputmode="decimal"/><span class="unit">TICK</span></div>
    <div id="st-you" class="quote"><div class="row dim">connect a wallet to stake</div></div>
    <button class="btn accent full" id="st-act">Stake</button>
    <button class="btn full" id="st-claim" style="margin-top:8px">Claim USDG rewards</button>`;
  wrap.appendChild(info); wrap.appendChild(box); v.appendChild(wrap);

  let mode = 'stake';
  box.querySelectorAll('[data-st]').forEach(b => b.onclick = () => {
    mode = b.dataset.st; box.querySelectorAll('[data-st]').forEach(x => x.classList.toggle('active', x === b));
    $('#st-act', box).textContent = mode === 'stake' ? 'Stake' : 'Unstake';
    $('#st-act', box).className = 'btn full' + (mode === 'stake' ? ' accent' : '');
  });
  $('#st-act', box).onclick = () => stakeAction(mode);
  $('#st-claim', box).onclick = claimRewards;

  loadStake().then(s => {
    const stats = $('#stake-stats'); if (stats) stats.innerHTML =
      `<div class="row"><span class="dim">Total staked</span><span class="mono">${fmtU(s.tvl,18).toLocaleString(undefined,{maximumFractionDigits:0})} TICK</span></div>`;
    const you = $('#st-you'); if (you) you.innerHTML = S.me
      ? `<div class="row"><span class="dim">Your stake</span><span class="mono">${fmtU(s.myStake,18).toFixed(2)} TICK</span></div>
         <div class="row"><span class="dim">Wallet</span><span class="mono">${fmtU(s.myBal,18).toFixed(2)} TICK</span></div>
         <div class="row"><span class="dim">Claimable</span><span class="mono up">${usd(fmtU(s.myPending))}</span></div>`
      : `<div class="row dim">connect a wallet to stake</div>`;
  });
}
async function stakeAction(mode) {
  if (S.demo) return toast('DEMO — set CFG.feeStaking after deploy.', 'err');
  if (!S.signer) return connect();
  const val = parseFloat($('#st-amt')?.value || '0'); if (!val) return toast('Enter an amount', 'err');
  const amt = E.parseUnits(String(val), 18);
  const st = new E.Contract(CFG.feeStaking, STAKING_ABI, S.signer);
  try {
    if (mode === 'stake') {
      const tk = new E.Contract(CFG.tick, ERC20_ABI, S.signer);
      if (await tk.allowance(S.me, CFG.feeStaking) < amt) { toast('Approve TICK…', 'pending'); await (await tk.approve(CFG.feeStaking, E.MaxUint256)).wait(); }
      toast('Staking…', 'pending'); await (await st.stake(amt)).wait(); toast('Staked');
    } else {
      toast('Unstaking…', 'pending'); await (await st.unstake(amt)).wait(); toast('Unstaked + claimed');
    }
    render();
  } catch (e) { toast((e.reason || e.shortMessage || 'failed').slice(0, 90), 'err'); }
}
async function claimRewards() {
  if (!S.signer) return connect();
  const st = new E.Contract(CFG.feeStaking, STAKING_ABI, S.signer);
  try { toast('Claiming…', 'pending'); await (await st.claim()).wait(); toast('Claimed USDG'); render(); }
  catch (e) { toast((e.reason || e.shortMessage || 'nothing to claim').slice(0, 90), 'err'); }
}

/* ---------------- detail + trade ---------------- */
function renderDetail(v) {
  const t = S.board.find(x => x.id === S.id);
  if (!t) return setRoute('board');
  const prem = Number(t.premiumBps) / 100, x = xpOf(t), tier = tierOf(t);
  const back = el('div', 'back-link', '← Board'); back.onclick = () => setRoute('board'); v.appendChild(back);
  const head = el('div', 'detail-head');
  head.innerHTML = `${av(t.symbol)}
    <div><div class="h2">${esc(t.symbol)} <span class="tier ${tier.k}">${tier.label}</span></div>
    <div class="dim" style="font-size:13px;margin-top:2px">${esc(t.name)} · trader ${esc(short(t.trader))} · <span class="mono">Lv ${x.lvl}</span></div></div>
    <div style="margin-left:auto">${badges(t).map(b=>`<span class="badge ${b.c}" title="${b.title}">${b.t}</span>`).join('')}</div>`;
  v.appendChild(head);

  const m = el('div', 'metrics');
  m.innerHTML = metric('Price', usd(fmtU(t.price)))
    + metric('Floor (NAV)', usd(fmtU(t.nav)), 'up')
    + metric('Premium', pct(prem), prem>=0?'up':'down')
    + metric('Backing (AUM)', usd(fmtU(t.vaultValue)))
    + metric('Market cap', usd(fmtU(t.marketCap)))
    + metric('Instant depth', usd(fmtU(t.exitReserve) + fmtU(t.vaultQuote)));
  v.appendChild(m);

  const grid = el('div', 'grid2');
  const left = el('div', 'panel');
  left.innerHTML = `<h3 style="margin:0 0 6px">Why this floor is real</h3>
    <p class="dim" style="font-size:13.5px">The ${esc(t.symbol)} vault holds ${usd(fmtU(t.vaultValue))} of tokenized stocks + USDG, valued every block by Chainlink. Sells below the floor and big exits route to a redemption queue that pays you NAV — bounded to 20% of supply per day so no one can break the exit. Buys below the floor mint <b>at</b> NAV, so a below-floor price is a free option, not a trap.</p>
    <div style="margin-top:14px" class="quote">
      <div class="row"><span class="dim">At-NAV minting</span><span class="${t.mintFresh?'up':'down'}">${t.mintFresh?'active':'paused (stale feed)'}</span></div>
      <div class="row"><span class="dim">Redemption queue</span><span>${t.queueDepth} pending</span></div>
      <div class="row"><span class="dim">Trader can withdraw?</span><span class="up">never — enforced on-chain</span></div>
    </div>`;
  grid.appendChild(left);
  grid.appendChild(tradePanel(t));
  v.appendChild(grid);
}
function metric(s, b, c) { return `<div class="metric"><b class="${c||''}">${b}</b><span>${s}</span></div>`; }

function tradePanel(t) {
  const p = el('div', 'panel');
  const side = S.side;
  p.innerHTML = `
    <div class="seg">
      <button data-side="buy" class="${side==='buy'?'active':''}">Buy</button>
      <button data-side="sell" class="${side==='sell'?'active':''}">Sell</button>
      <button data-side="redeem" class="${side==='redeem'?'active':''}">Redeem</button>
    </div>
    <div class="field"><input id="amt" placeholder="0.0" inputmode="decimal"/><span class="unit">${side==='buy'?'USDG':esc(t.symbol)}</span></div>
    <div class="chips">${(side==='buy'?['100','500','2500','10000']:['25%','50%','100%']).map(c=>`<button data-chip="${c}">${c}</button>`).join('')}</div>
    <div class="quote" id="quote"><div class="row dim">Enter an amount for a live quote.</div></div>
    <button class="btn accent full" id="act">${side==='buy'?'Buy':side==='sell'?'Sell':'Redeem at NAV'}</button>
    <p class="faint" style="font-size:11.5px;margin:10px 0 0">${S.me?'':'Connect a wallet to trade. '}Slippage guard ${CFG.slippageBps/100}%. ${S.demo?'DEMO mode — actions disabled until contracts are set.':''}</p>`;
  p.querySelectorAll('[data-side]').forEach(b => b.onclick = () => { S.side = b.dataset.side; render(); });
  const amt = $('#amt', p);
  p.querySelectorAll('[data-chip]').forEach(b => b.onclick = () => { amt.value = b.dataset.chip.replace('%',''); doQuote(t); });
  if (amt) amt.oninput = () => doQuote(t);
  $('#act', p).onclick = () => doAction(t);
  return p;
}
async function doQuote(t) {
  const q = $('#quote'); const val = parseFloat($('#amt')?.value || '0');
  if (!val || val <= 0) { q.innerHTML = '<div class="row dim">Enter an amount for a live quote.</div>'; return; }
  if (S.demo) { q.innerHTML = `<div class="row"><span class="dim">Estimated</span><span class="mono">~${(val/fmtU(t.price)).toFixed(2)} ${esc(t.symbol)}</span></div><div class="row dim">DEMO — connect live contracts for exact routing.</div>`; return; }
  try {
    const hub = new E.Contract(CFG.hub, HUB_ABI, S.provider);
    if (S.side === 'buy') {
      const [out, fee, navMint] = await hub.quoteBuy(t.id, E.parseUnits(String(val), CFG.usdgDecimals));
      // an at-NAV mint against a stale feed will revert (StaleForMint); warn instead
      // of showing a fillable quote that fails on submit.
      const staleWarn = (navMint && !t.mintFresh)
        ? `<div class="row down">At-NAV minting paused — stock feed stale (weekend/holiday). This buy will revert; try again when the feed updates.</div>` : '';
      q.innerHTML = `<div class="row"><span class="dim">Route</span><span class="route ${navMint?'floor':''}">${navMint?'AT-NAV MINT (floor)':'curve'}</span></div>
        <div class="row"><span class="dim">You receive</span><span class="mono">${fmtU(out,18).toFixed(3)} ${esc(t.symbol)}</span></div>
        <div class="row"><span class="dim">Fee</span><span class="mono">${usd(fmtU(fee))}</span></div>${staleWarn}`;
    } else {
      const [proceeds, fee, floor] = await hub.quoteSell(t.id, E.parseUnits(String(val), 18));
      q.innerHTML = `<div class="row"><span class="dim">Route</span><span class="route ${floor?'queue':''}">${floor?'REDEMPTION QUEUE (NAV)':'instant curve'}</span></div>
        <div class="row"><span class="dim">You receive</span><span class="mono">${floor?'~NAV on settle':usd(fmtU(proceeds))}</span></div>
        <div class="row"><span class="dim">Fee</span><span class="mono">${usd(fmtU(fee))}</span></div>`;
    }
  } catch (e) { q.innerHTML = `<div class="row down">${(e.reason||e.message||'quote failed').slice(0,80)}</div>`; }
}

/* ---------------- portfolio ---------------- */
function renderPortfolio(v) {
  v.appendChild(headBlock('Your portfolio', S.me ? short(S.me) : 'Connect a wallet to see holdings, floors and creator fees.'));
  if (!S.me) { const d = el('div', 'card'); d.innerHTML = `<div class="empty">Wallet not connected.</div>`; v.appendChild(d); return; }
  const d = el('div', 'card'); d.innerHTML = `<div class="empty">Holdings load from chain once contracts are configured. Your positions, redeemable floor value, and any creator fees show here.</div>`;
  v.appendChild(d);
}

/* ---------------- how ---------------- */
function renderHow(v) {
  v.appendChild(headBlock('How it works', 'Six ideas, no fine print.'));
  const cards = [
    ['Back a trader, not a meme', 'Each ticker is a token whose backing is a real on-chain portfolio the trader runs — tokenized <span class="k">AAPL, TSLA, NVDA, SPY, QQQ</span> priced by Chainlink, settled in USDG.'],
    ['A floor that can\'t lie', 'NAV = the vault\'s live market value ÷ supply. Sells below it route to a queue that pays you NAV. The floor is math, marked every block — not a promise.'],
    ['Buy the dip, literally', 'If price ever falls below the floor, buys mint <span class="k">at NAV</span> straight into the vault. A below-floor price is a free option, never a rug.'],
    ['Run-proof exits', 'Redemptions settle at NAV, capped at <span class="k">20% of supply per day</span>, 6h delay. A stampede can\'t break the vault or jump the line.'],
    ['The trader can\'t drain you', 'The vault has <span class="k">no withdrawal function</span>. The trader only swaps between whitelisted stocks — oracle-bounded to 0.8%, capped at 200%/day turnover. They drive; they can\'t steal.'],
    ['No admin keys', 'No owner, no proxy, no pause. Immutable contracts, verified against 72 tests + a 131k-call invariant campaign, live-checked on Robinhood Chain.'],
  ];
  const wrap = el('div', 'cards');
  wrap.innerHTML = cards.map(c => `<div class="hc"><h3>${c[0]}</h3><p>${c[1]}</p></div>`).join('');
  v.appendChild(wrap);
}

/* ---------------- actions (write) ---------------- */
function toast(msg, kind) { const t = el('div', 'toast ' + (kind||'')); t.textContent = msg; $('#toasts').appendChild(t); setTimeout(() => t.remove(), 6000); return t; }
async function ensureApprove(spender, amount) {
  const usdg = new E.Contract(CFG.usdg, ERC20_ABI, S.signer);
  const cur = await usdg.allowance(S.me, spender);
  if (cur < amount) { toast('Approve USDG…', 'pending'); await (await usdg.approve(spender, E.MaxUint256)).wait(); }
}
async function doAction(t) {
  if (S.demo) return toast('DEMO mode — set CFG.hub / CFG.lens after deploy to trade.', 'err');
  if (!S.signer) return connect();
  const val = parseFloat($('#amt')?.value || '0'); if (!val) return toast('Enter an amount', 'err');
  const hub = new E.Contract(CFG.hub, HUB_ABI, S.signer);
  try {
    if (S.side === 'buy') {
      const wei = E.parseUnits(String(val), CFG.usdgDecimals);
      await ensureApprove(CFG.hub, wei);
      const [out] = await hub.quoteBuy(t.id, wei);
      const minOut = out * BigInt(10000 - CFG.slippageBps) / 10000n;
      toast('Buying ' + t.symbol + '…', 'pending');
      await (await hub.buy(t.id, wei, minOut)).wait();
      toast('Bought ' + t.symbol);
    } else if (S.side === 'sell') {
      const qty = E.parseUnits(String(val), 18);
      // slippage guard on the instant-curve leg: floor proceeds at quote*(1-slip).
      // If it routes to the NAV queue instead, proceeds come later at NAV so the
      // curve floor simply doesn't bind (quoteSell.floorRouted tells us which).
      const [proceeds, , floorRouted] = await hub.quoteSell(t.id, qty);
      const minProceeds = floorRouted ? 0n : proceeds * BigInt(10000 - CFG.slippageBps) / 10000n;
      toast('Selling…', 'pending');
      await (await hub.sell(t.id, qty, minProceeds, true)).wait();
      toast('Sell submitted');
    } else {
      const qty = E.parseUnits(String(val), 18);
      toast('Queuing redemption at NAV…', 'pending');
      await (await hub.redeem(t.id, qty)).wait();
      toast('Redemption queued — settles at NAV');
    }
    await loadBoard(); render();
  } catch (e) { toast((e.reason || e.shortMessage || e.message || 'tx failed').slice(0, 90), 'err'); }
}

/* ---------------- launch modal ---------------- */
function openLaunch() {
  const root = $('#modal-root');
  root.innerHTML = `<div class="scrim"><div class="modal">
    <h2>Launch yourself</h2>
    <p class="dim" style="margin:0 0 6px;font-size:13px">Open a ticker backed by your trading vault. Your seed is locked 30 days — skin in the game.</p>
    <label>Name</label><input id="l-name" placeholder="Alpha Trader"/>
    <label>Symbol</label><input id="l-sym" placeholder="ALPHA"/>
    <label>Seed (USDG, min 500)</label><input id="l-seed" placeholder="1000" inputmode="decimal"/>
    <div style="display:flex;gap:8px;margin-top:16px">
      <button class="btn full" id="l-cancel">Cancel</button>
      <button class="btn accent full" id="l-go">Launch</button>
    </div></div></div>`;
  $('#l-cancel').onclick = () => root.innerHTML = '';
  $('#l-go').onclick = doLaunch;
}
async function doLaunch() {
  if (S.demo) { toast('DEMO mode — set CFG.hub after deploy to launch.', 'err'); return; }
  if (!S.signer) return connect();
  const name = $('#l-name').value.trim(), sym = $('#l-sym').value.trim().toUpperCase(), seed = parseFloat($('#l-seed').value || '0');
  if (!name || !sym || seed < 500) return toast('Name, symbol, and seed ≥ 500 required', 'err');
  const hub = new E.Contract(CFG.hub, HUB_ABI, S.signer);
  try {
    const fee = await hub.LAUNCH_FEE();
    const total = E.parseUnits(String(seed), CFG.usdgDecimals) + fee;
    await ensureApprove(CFG.hub, total);
    toast('Launching ' + sym + '…', 'pending');
    await (await hub.launch(name, sym, E.parseUnits(String(seed), CFG.usdgDecimals))).wait();
    $('#modal-root').innerHTML = ''; toast('Launched ' + sym + ' 🎉');
    await loadBoard(); setRoute('board');
  } catch (e) { toast((e.reason || e.shortMessage || e.message || 'launch failed').slice(0, 90), 'err'); }
}

async function faucet() {
  if (!S.signer) return connect();
  try {
    const usdg = new E.Contract(CFG.usdg, ERC20_ABI, S.signer);
    toast('Minting 100k test USDG…', 'pending');
    await (await usdg.mint(S.me, E.parseUnits('100000', CFG.usdgDecimals))).wait();
    toast('Minted 100k USDG');
  } catch (e) { toast((e.reason || e.message || 'faucet failed').slice(0, 80), 'err'); }
}

/* ---------------- wallet ---------------- */
async function connect() {
  if (!window.ethereum) return toast('No injected wallet found', 'err');
  try {
    const bp = new E.BrowserProvider(window.ethereum);
    await bp.send('eth_requestAccounts', []);
    let net = await bp.getNetwork();
    if (Number(net.chainId) !== CFG.chainId) {
      try { await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CFG.chainIdHex }] }); }
      catch (sw) {
        if (sw && (sw.code === 4902 || String(sw.message||'').includes('Unrecognized'))) {
          await window.ethereum.request({ method: 'wallet_addEthereumChain', params: [{ chainId: CFG.chainIdHex, chainName: CFG.chainName, rpcUrls: [CFG.rpc], nativeCurrency: CFG.nativeCurrency, blockExplorerUrls: [CFG.explorer] }] });
        } else { throw sw; } // user rejected — don't proceed on the wrong chain
      }
      // re-verify: bail if still not on the target chain
      net = await (new E.BrowserProvider(window.ethereum)).getNetwork();
      if (Number(net.chainId) !== CFG.chainId) return toast('Wrong network — switch to ' + CFG.chainName, 'err');
    }
    const bp2 = new E.BrowserProvider(window.ethereum);
    S.signer = await bp2.getSigner(); S.me = await S.signer.getAddress();
    $('#wallet-btn').textContent = short(S.me);
    toast('Connected ' + short(S.me));
    render();
  } catch (e) { toast(e.message || 'connect failed', 'err'); }
}

/* ---------------- boot ---------------- */
function bootChrome() {
  $('#theme-btn').onclick = () => {
    const cur = document.documentElement.getAttribute('data-theme');
    const nx = cur === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', nx); localStorage.tickerTheme = nx;
  };
  if (localStorage.tickerTheme) document.documentElement.setAttribute('data-theme', localStorage.tickerTheme);
  $('#wallet-btn').onclick = connect;
  $('#launch-btn').onclick = openLaunch;
  // local faucet button (mock USDG mint) — only when CFG.faucet
  if (CFG.faucet) {
    const f = el('button', 'btn', 'Faucet');
    f.title = 'Mint 100k test USDG to your wallet';
    f.onclick = faucet;
    $('.topright').insertBefore(f, $('#theme-btn'));
  }
  document.querySelectorAll('[data-nav]').forEach(b => b.onclick = () => setRoute(b.dataset.nav));
  const chip = document.querySelector('.chip.chain'); if (chip) chip.textContent = CFG.chainName;
  $('#net-stats').textContent = live() ? CFG.chainName + ' · ' + short(CFG.hub) : 'DEMO · configure CFG.hub after deploy';
}
async function boot() {
  bootChrome();
  S.provider = readProvider();
  try { await loadBoard(); } catch (e) { console.error(e); S.demo = true; S.board = demoBoard(); toast('RPC read failed — showing demo data', 'err'); }
  setRoute('board');
  // light auto-refresh
  setInterval(async () => { if (S.route === 'board' || S.route === 'leaderboard') { try { await loadBoard(); render(); } catch {} } }, 20000);
}

/* ---------------- demo dataset (labelled, pre-deploy preview) ---------------- */
function demoBoard() {
  const now = nowSec();
  const mk = (id, sym, name, priceC, navC, aum, ageD, grad, q, fresh) => ({
    id, symbol: sym, name, trader: '0x' + (id + 11).toString(16).padStart(40, 'a'),
    token: '0x0', vault: '0x0', createdAt: now - ageD * DAY, graduated: grad, mintFresh: fresh,
    price: E.parseUnits(priceC, 6), nav: E.parseUnits(navC, 6),
    vaultValue: E.parseUnits(String(aum), 6), circ: E.parseUnits('1000000', 18),
    marketCap: E.parseUnits(String(Math.round(parseFloat(priceC) * 1e6)), 6),
    exitReserve: E.parseUnits(String(Math.round(aum * 0.12)), 6), creatorFees: 0n,
    vaultQuote: E.parseUnits(String(Math.round(aum * 0.2)), 6), queueDepth: q,
    premiumBps: BigInt(Math.round((parseFloat(priceC) / parseFloat(navC) - 1) * 10000)),
  });
  return [
    mk(0, 'VOLT', 'Volt Capital', '0.089', '0.071', 512000, 44, true, 0, true),
    mk(1, 'APEX', 'Apex Desk', '0.061', '0.058', 128000, 19, false, 1, true),
    mk(2, 'NOVA', 'Nova Quant', '0.043', '0.045', 74000, 9, false, 0, false),
    mk(3, 'ORCA', 'Orca Swing', '0.031', '0.024', 41000, 6, false, 0, true),
    mk(4, 'ZENO', 'Zeno Macro', '0.018', '0.019', 9800, 2, false, 0, true),
  ];
}

boot();

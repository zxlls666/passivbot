#!/usr/bin/env bash
# Passivbot sandbox bootstrap + BTC basket bull/bear backtest comparison.
#
# Sandbox-local script (see ../AGENTS-sandbox.md). Read-only / backtest only:
# it NEVER runs `passivbot live` and needs no exchange credentials.
#
# Usage (on the target machine, e.g. omarchy/Arch):
#   bash deploy/bootstrap.sh
#
# It will: pick a supported Python (3.12 or 3.14), verify Rust, create .venv,
# install passivbot[full] + test deps, smoke-test the CLI, probe exchange
# reachability, then run two backtest windows (2024H1 bull vs 2022H1 bear) on a
# small coin basket and print a summary.
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(pwd)"
echo "[bootstrap] repo: $ROOT"

COINS="${COINS:-BTC,ETH,SOL}"
BULL_START="${BULL_START:-2024-01-01}"; BULL_END="${BULL_END:-2024-06-30}"
BEAR_START="${BEAR_START:-2022-01-01}"; BEAR_END="${BEAR_END:-2022-06-30}"
CONFIG="${CONFIG:-configs/examples/default_trailing_martingale_long.json}"

# --- 1. Python (3.12 or 3.14; 3.13 is NOT supported by pinned deps) -----------
PY=""
for c in python3.12 python3.14 python3; do
  command -v "$c" >/dev/null 2>&1 || continue
  v="$("$c" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "?")"
  case "$v" in
    3.12|3.14) PY="$c"; break ;;
    3.13) echo "[bootstrap] $c is $v (unsupported), skipping" ;;
    *)   echo "[bootstrap] $c is $v, skipping" ;;
  esac
done
if [ -z "$PY" ]; then
  echo "[bootstrap] ERROR: need Python 3.12 or 3.14 (3.13 unsupported)." >&2
  echo "[bootstrap]        Arch/omarchy tip: use uv -> 'uv python install 3.12' or pyenv." >&2
  exit 1
fi
echo "[bootstrap] python: $PY ($("$PY" --version 2>&1))"

# --- 2. Rust (rust-toolchain.toml pins 1.90.0; rustup installs it on demand) --
command -v rustup >/dev/null 2>&1 || { echo "[bootstrap] ERROR: rustup not found (https://rustup.rs)" >&2; exit 1; }
(cd "$ROOT" && rustup show >/dev/null 2>&1 || true)
echo "[bootstrap] rustc: $(rustc --version 2>/dev/null || echo unknown)"

# --- 3. venv + install --------------------------------------------------------
[ -d .venv ] || "$PY" -m venv .venv
.venv/bin/python -m pip install -q --upgrade pip setuptools wheel
.venv/bin/python -m pip install -e ".[full]"
.venv/bin/python -m pip install -q "pytest>=8.2,<9" "pytest-asyncio>=1.2,<2" "PyYAML==6.0.2"
echo "[bootstrap] passivbot: $(.venv/bin/passivbot --version)"

# --- 4. smoke ----------------------------------------------------------------
.venv/bin/passivbot --help >/dev/null && echo "[bootstrap] CLI smoke: ok (live command present but never invoked)"

# --- 5. exchange reachability ------------------------------------------------
probe() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" || echo 000; }
CANDS="binance|https://fapi.binance.com/fapi/v1/time
bybit|https://api.bybit.com/v5/market/time
bitget|https://api.bitget.com/api/v2/public/time
gateio|https://api.gateio.ws/api/v4/spot/time
kucoin|https://api.kucoin.com/api/v1/timestamp
hyperliquid|https://api.hyperliquid.xyz/info"
EX=""
while IFS='|' read -r id url; do
  [ -n "$id" ] || continue
  code="$(probe "$url")"
  echo "[probe] $id -> $code"
  [ "$code" = "200" ] && [ -z "$EX" ] && EX="$id"
done <<< "$CANDS"
if [ -z "$EX" ]; then echo "[bootstrap] ERROR: no reachable exchange endpoint" >&2; exit 1; fi
echo "[bootstrap] using exchange: $EX"

# --- 6. comparison -----------------------------------------------------------
run_window() {
  label="$1"; sd="$2"; ed="$3"
  echo ""
  echo "=== $label  $sd..$ed  coins=$COINS  exchange=$EX ==="
  # -mcad 0 keeps the same coin universe across windows (perp listing age varies).
  .venv/bin/passivbot backtest "$CONFIG" -s "$COINS" -e "$EX" \
    -sd "$sd" -ed "$ed" --suite n -dp all -mcad 0 2>&1 | tail -35
}

run_window "BULL 2024H1" "$BULL_START" "$BULL_END"
run_window "BEAR 2022H1" "$BEAR_START" "$BEAR_END"

# --- 7. summary --------------------------------------------------------------
echo ""
echo "=== summary (strategy equity, from backtests/$EX) ==="
.venv/bin/python - "$EX" <<'PY'
import csv, glob, gzip, json, os, sys
ex = sys.argv[1]
rows = []
for d in sorted(glob.glob(f"backtests/{ex}/*")):
    be = os.path.join(d, "balance_and_equity.csv.gz")
    if not os.path.exists(be):
        continue
    try:
        cfg = json.load(open(os.path.join(d, "config.json")))["backtest"]
    except Exception:
        cfg = {}
    with gzip.open(be, "rt") as f:
        eq = [float(r["strategy_equity"]) for r in csv.DictReader(f) if r.get("strategy_equity")]
    if not eq:
        continue
    peak, dd = eq[0], 0.0
    for v in eq:
        peak = max(peak, v)
        dd = max(dd, (peak - v) / peak if peak else 0.0)
    fp = os.path.join(d, "fills.csv")
    n = (sum(1 for _ in open(fp)) - 1) if os.path.exists(fp) else -1
    rows.append((cfg.get("start_date", "?"), cfg.get("end_date", "?"), n, eq[0], eq[-1], dd, os.path.basename(d)))
for s, e, n, a, b, dd, name in rows:
    print(f"  {s}..{e}  fills={n:<5} ret={b/a-1:+.2%}  maxDD={dd:.1%}  ({name})")
PY

echo ""
echo "[bootstrap] done. Artifacts under backtests/$EX/ ; data cached under caches/."

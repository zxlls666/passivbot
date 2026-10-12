#!/usr/bin/env bash
# Passivbot sandbox bootstrap + BTC basket bull/bear backtest comparison.
#
# Sandbox-local script (see ../AGENTS-sandbox.md). Read-only / backtest only:
# it NEVER runs `passivbot live` and needs no exchange credentials.
#
# Usage (on the target machine, e.g. omarchy/Arch):
#   PYTHON=python3.12 bash deploy/bootstrap.sh
#
# It will: pick a supported Python (3.12 or 3.14), install/verify Rust, create
# .venv, install passivbot[full] + test deps, smoke-test the CLI, probe exchange
# reachability (with retries), then run two backtest windows (2024H1 bull vs
# 2022H1 bear) on a small coin basket, guard against synthetic-filled datasets,
# and print an equity summary.
#
# Hardening / knobs (all optional, export before running):
#   PYTHON=python3.12      force the interpreter (3.12 or 3.14; 3.13 unsupported)
#   COINS=...              coin basket (default BTC,ETH,SOL)
#   BULL_START/BULL_END/BEAR_START/BEAR_END, CONFIG
#   NO_MIRRORS=1           disable the mirror defaults below
#   RUST_MIRROR=...        rustup/toolchain mirror (default https://rsproxy.cn)
#   PIP_INDEX_URL=...      pip index (default Tsinghua mirror)
#   PROBE_TRIES=N          exchange reachability retries per candidate (default 3)
#   CLEAN_MAC_METADATA=0   skip the ._*/.DS_Store cleanup (default on)
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(pwd)"
echo "[bootstrap] repo: $ROOT"

COINS="${COINS:-BTC,ETH,SOL}"
BULL_START="${BULL_START:-2024-01-01}"; BULL_END="${BULL_END:-2024-06-30}"
BEAR_START="${BEAR_START:-2022-01-01}"; BEAR_END="${BEAR_END:-2022-06-30}"
CONFIG="${CONFIG:-configs/examples/default_trailing_martingale_long.json}"
PROBE_TRIES="${PROBE_TRIES:-3}"

# --- 0. mirrors (defaults for flaky/geo-blocked networks; NO_MIRRORS=1 to disable)
if [ "${NO_MIRRORS:-0}" != "1" ]; then
  RUST_MIRROR="${RUST_MIRROR:-https://rsproxy.cn}"
  export RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-$RUST_MIRROR}"
  export PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
  echo "[bootstrap] mirrors: rust=$RUST_MIRROR pip=$PIP_INDEX_URL"
fi

# --- 0b. self-heal: drop macOS AppleDouble sidecars (break *.py parsing) -------
if [ "${CLEAN_MAC_METADATA:-1}" = "1" ]; then
  n="$(find . \( -name '._*' -o -name '.DS_Store' \) 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -gt 0 ]; then
    find . \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
    echo "[bootstrap] cleaned $n macOS metadata file(s) (._*/.DS_Store)"
  fi
fi

# --- 1. Python (3.12 or 3.14; 3.13 is NOT supported by pinned deps) -----------
_ver() { "$1" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "?"; }
PY="${PYTHON:-}"
if [ -n "$PY" ]; then
  command -v "$PY" >/dev/null 2>&1 || { echo "[bootstrap] ERROR: PYTHON=$PY not found" >&2; exit 1; }
  v="$(_ver "$PY")"
  case "$v" in
    3.12|3.14) ;;
    *) echo "[bootstrap] ERROR: PYTHON=$PY is $v; need 3.12 or 3.14 (3.13 unsupported)" >&2; exit 1 ;;
  esac
else
  for c in python3.12 python3.14 python3; do
    command -v "$c" >/dev/null 2>&1 || continue
    v="$(_ver "$c")"
    case "$v" in
      3.12|3.14) PY="$c"; break ;;
      3.13) echo "[bootstrap] $c is $v (unsupported), skipping" ;;
      *)   echo "[bootstrap] $c is $v, skipping" ;;
    esac
  done
  if [ -z "$PY" ]; then
    echo "[bootstrap] ERROR: need Python 3.12 or 3.14 (3.13 unsupported)." >&2
    echo "[bootstrap]        Arch/omarchy tip: 'uv python install 3.12', then rerun with PYTHON=python3.12." >&2
    exit 1
  fi
fi
echo "[bootstrap] python: $PY ($("$PY" --version 2>&1))"

# --- 2. Rust (rust-toolchain.toml pins 1.90.0) --------------------------------
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v rustup >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64)            TRIPLE=x86_64-unknown-linux-gnu ;;
    aarch64|arm64)     TRIPLE=aarch64-unknown-linux-gnu ;;
    *)                 TRIPLE="" ;;
  esac
  if [ -n "$TRIPLE" ]; then
    if [ "${NO_MIRRORS:-0}" != "1" ]; then
      URL="$RUST_MIRROR/rustup/dist/$TRIPLE/rustup-init"
    else
      URL="https://static.rust-lang.org/rustup/dist/$TRIPLE/rustup-init"
    fi
    echo "[bootstrap] installing rustup from $URL"
    curl -sSfL --retry 3 --retry-delay 2 -o /tmp/rustup-init "$URL"
    chmod +x /tmp/rustup-init
    /tmp/rustup-init -y --profile minimal --default-toolchain none
    export PATH="$HOME/.cargo/bin:$PATH"
  else
    echo "[bootstrap] ERROR: rustup missing and unknown arch; install manually (https://rustup.rs)" >&2
    exit 1
  fi
fi
rustup show >/dev/null 2>&1 || rustup toolchain install 1.90.0 --profile minimal
echo "[bootstrap] rustc: $(rustc --version 2>/dev/null || echo unknown)"

# crates mirror for the extension build (only if none configured yet)
if [ "${NO_MIRRORS:-0}" != "1" ] && [ ! -f "$HOME/.cargo/config.toml" ]; then
  mkdir -p "$HOME/.cargo"
  cat > "$HOME/.cargo/config.toml" <<'EOF'
[source.crates-io]
replace-with = "rsproxy-sparse"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[net]
git-fetch-with-cli = true
EOF
  echo "[bootstrap] wrote ~/.cargo/config.toml (rsproxy crates mirror)"
fi

# --- 3. venv + install --------------------------------------------------------
[ -d .venv ] || "$PY" -m venv .venv
.venv/bin/python -m pip install -q --upgrade pip setuptools wheel
.venv/bin/python -m pip install -e ".[full]"
.venv/bin/python -m pip install -q "pytest>=8.2,<9" "pytest-asyncio>=1.2,<2" "PyYAML==6.0.2"
echo "[bootstrap] passivbot: $(.venv/bin/passivbot --version)"

# --- 4. smoke ----------------------------------------------------------------
.venv/bin/passivbot --help >/dev/null && echo "[bootstrap] CLI smoke: ok (live command present but never invoked)"

# --- 5. exchange reachability (with retries; "000" = unreachable) -------------
probe() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null)" || true
  [ -n "$code" ] || code="000"
  printf '%s' "$code"
}
CANDS="binance|https://fapi.binance.com/fapi/v1/time
bybit|https://api.bybit.com/v5/market/time
bitget|https://api.bitget.com/api/v2/public/time
gateio|https://api.gateio.ws/api/v4/spot/time
kucoin|https://api.kucoin.com/api/v1/timestamp
hyperliquid|https://api.hyperliquid.xyz/info"
EX=""
while IFS='|' read -r id url; do
  [ -n "$id" ] || continue
  code="000"; t=0
  for t in $(seq 1 "$PROBE_TRIES"); do
    code="$(probe "$url")"
    [ "$code" = "200" ] && break
    sleep 2
  done
  echo "[probe] $id -> $code (tries=$t)"
  [ "$code" = "200" ] && [ -z "$EX" ] && EX="$id"
done <<< "$CANDS"
if [ -z "$EX" ]; then echo "[bootstrap] ERROR: no reachable exchange endpoint" >&2; exit 1; fi
echo "[bootstrap] using exchange: $EX"

# --- 6. comparison (capture full logs; guard against synthetic fill) ----------
LOGDIR="backtests/_bootstrap_logs"; mkdir -p "$LOGDIR"
FAILED=""
run_window() {
  local label="$1" sd="$2" ed="$3" slug="$4" log="$LOGDIR/$4.log" st
  echo ""
  echo "=== $label  $sd..$ed  coins=$COINS  exchange=$EX ==="
  # -mcad 0 keeps the same coin universe across windows (perp listing age varies).
  if .venv/bin/passivbot backtest "$CONFIG" -s "$COINS" -e "$EX" \
       -sd "$sd" -ed "$ed" --suite n -dp all -mcad 0 > "$log" 2>&1; then
    st=ok
  else
    st=FAILED; FAILED="$FAILED $label"
  fi
  tail -18 "$log"
  if grep -qaE "synthetic_filled=[1-9]|valid data ends before requested end" "$log"; then
    echo "[bootstrap] !! $label: dataset shows SYNTHETIC fill / short coverage — result NOT trustworthy:" >&2
    grep -aE "synthetic_filled=[1-9]|valid data ends before requested end" "$log" | sed 's/^/    /' >&2
  fi
  echo "[bootstrap] $label: $st (log: $log)"
}

run_window "BULL 2024H1" "$BULL_START" "$BULL_END" "bull"
run_window "BEAR 2022H1" "$BEAR_START" "$BEAR_END" "bear"

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
if [ -n "$FAILED" ]; then echo "[bootstrap] FAILED window(s):$FAILED" >&2; exit 1; fi
echo "[bootstrap] done. Artifacts under backtests/$EX/ ; logs under $LOGDIR/ ; data cached under caches/."

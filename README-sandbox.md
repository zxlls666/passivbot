# Passivbot Sandbox

Independent [Passivbot](https://github.com/enarjord/passivbot) workspace for the `crypto/quant`
engine — a **third-party bot comparison / strategy-adaptation arm**, the passivbot counterpart of
`sandboxes/freqtrade` (freqtrade) and `sandboxes/lean` (QuantConnect LEAN).

**Not** connected to the live crypto execution stack. Read-only inspection, backtests, and
dry-run only. No exchange credentials, no live orders.
Hard rules: [`AGENTS-sandbox.md`](AGENTS-sandbox.md).

> Naming note: upstream ships `README.md` and `AGENTS.md`, so this sandbox keeps its own docs as
> `README-sandbox.md` and `AGENTS-sandbox.md` (the macOS filesystem is case-insensitive and would
> otherwise collide with the upstream files). Upstream's `AGENTS.md` still governs ordinary
> development *of passivbot*; `AGENTS-sandbox.md` adds this workspace's scope/safety boundary.

## Pin record

| Item | Value |
|---|---|
| Upstream | `https://github.com/enarjord/passivbot.git` |
| Clone type | `--depth 1 --single-branch` (shallow, not a fork) |
| Branch | `master` |
| Commit SHA | `82e0edf67a1f037b783d139039021ade8f449478` |
| Commit date | 2026-10-11 13:38:01 -0400 |
| Cloned at | 2026-10-12 |
| Version | `8.2.0.dev0` (unreleased `master`; latest tagged release `v8.1.0`) |
| License | Unlicense (public domain) |
| Size on disk | ~31 MB (`~6.2 MB` in `.git`) |
| Python | `>=3.12,<3.15,!=3.13.*` — Python 3.13 is **not** supported |
| Rust | toolchain `1.90.0` (`rust-toolchain.toml`); native ext `passivbot_rust` via `setuptools-rust`/`maturin` |
| Entry point | console script `passivbot` (`passivbot=passivbot_cli.main:console_main`) |

Re-record this table whenever the clone moves — treat each update as a **new comparison batch**.

## Why this exists

| Goal | How |
|---|---|
| Engine comparison | Run passivbot backtests on curated OHLCV and diff against `quant` |
| Strategy port | Port `quant` StrategySpecs onto passivbot configs (`trailing_martingale`, `ema_anchor`) |
| Tooling evaluation | Assess the optimizer / backtest workflow before deeper investment |

Sibling projects: `../freqtrade/` (IStrategy adapter sandbox), `../lean/` (LEAN engine screening),
`/Users/serge/crypto/quant` (authoritative research + backtest engine).

## Quick start

Prerequisites: Python 3.12 or 3.14 (not 3.13), a [Rust](https://rustup.rs) toolchain (1.90.0), and
`maturin`. Install is local-only; nothing here touches an exchange.

```bash
cd /Users/serge/crypto/sandboxes/passivbot

# one-time setup (local-only venv, gitignored by upstream)
python3.12 -m venv .venv
source .venv/bin/activate

# backtesting / optimization / research workstation profile (builds the Rust extension)
python3 -m pip install -e ".[full]"

# verify the CLI
passivbot --help

# backtest on an example config (offline data cache, no keys, no orders)
passivbot backtest configs/examples/default_trailing_martingale_long.json
```

Live trading (`passivbot live`) is **out of scope** for this sandbox — never run it, and never
supply credentials, without explicit user approval (see [`AGENTS-sandbox.md`](AGENTS-sandbox.md)).

## Layout

```text
src/                 # Python: orchestration, exchange I/O, config, data plumbing
passivbot-rust/      # Rust: order / strategy / risk / unstuck / backtest engine
configs/examples/    # maintained public example configs
docs/                # upstream user + AI docs (docs/ai/ holds the contracts)
tests/ , pytests/    # upstream test suites
.venv/               # local-only, created by setup (never committed)
```

## Updating the clone

Shallow clone — fetch newer code and fast-forward:

```bash
git -C /Users/serge/crypto/sandboxes/passivbot fetch --depth 1 origin master
git -C /Users/serge/crypto/sandboxes/passivbot reset --hard origin/master
```

To select a tagged release or inspect history, unshallow first (`git fetch --unshallow --tags`),
then update the pin table above.

## Deploy on another machine (e.g. omarchy / Arch)

This machine's network is geo-blocked from Binance/Bybit, so the full backtest comparison is
meant to run on a host that can reach the exchanges. The sandbox is pushed to a personal fork:

| Item | Value |
|---|---|
| Fork | `git@github.com:zxlls666/passivbot.git` |
| Branch | `local/sandbox` (sandbox dev line; `master` mirrors upstream) |
| Upstream | `origin` = `git@github.com:enarjord/passivbot.git` (read-only, never push) |

On the target machine:

```bash
git clone -b local/sandbox git@github.com:zxlls666/passivbot.git passivbot
cd passivbot
PYTHON=python3.12 bash deploy/bootstrap.sh   # force 3.12; else it auto-picks 3.12/3.14
```

`deploy/bootstrap.sh` uses a supported Python (3.12 or 3.14), installs `passivbot[full]` plus test
deps into `.venv`, probes exchange reachability (with retries), and runs the two comparison windows
on a small coin basket. Overridable: `COINS=`, `BULL_START=`/`BULL_END=`, `BEAR_START=`/`BEAR_END=`,
`CONFIG=`, `PYTHON=`. It never runs `passivbot live`, and it **flags any run whose dataset was
synthetically filled** (`synthetic_filled` / "valid data ends before requested end") so a
bogus result can't pass silently.

**Flaky / geo-blocked networks.** On a network that truncates large downloads (github packs,
`static.rust-lang.org`, direct pypi), the script defaults to mirrors: rustup + crates from
`https://rsproxy.cn`, pip from the Tsinghua mirror, and it will install rustup itself if absent.
Disable with `NO_MIRRORS=1`; override with `RUST_MIRROR=` / `PIP_INDEX_URL=`.

**Moving the tree between OSes.** `git clone` can fail with `unexpected disconnect` / `early EOF`
on those networks; transferring the working tree over the LAN with `tar` is more reliable — but
macOS `tar` writes AppleDouble `._*` sidecars (which break `*.py` parsing). Either way:

```bash
# from the source machine (macOS), strip AppleDouble + let the script self-heal
COPYFILE_DISABLE=1 tar -cf - --exclude=.venv --exclude=caches --exclude=backtests passivbot \
  | ssh <target> 'mkdir -p ~/passivbot && tar -C ~/passivbot --strip-components=1 -xf -'
```

`bootstrap.sh` also deletes any `._*` / `.DS_Store` it finds (skip with `CLEAN_MAC_METADATA=0`).

## Boundaries

See [`AGENTS-sandbox.md`](AGENTS-sandbox.md). In short: no live or authenticated runs, no
credentials, configs stay dry/backtest, `origin` is read-only (never push), and `quant` signal
logic is never copied into this tree.

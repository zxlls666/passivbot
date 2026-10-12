# AGENTS-sandbox.md — Passivbot Sandbox Rules

This directory is a **third-party-engine sandbox** for the `crypto/quant` workspace: an engine
comparison / strategy-adaptation arm. It is **not** the live execution stack and **not** a
live-trading product.

Upstream ships its own [`AGENTS.md`](AGENTS.md) (rules for developing passivbot itself). That file
continues to govern ordinary code work inside the checkout. This file adds the workspace boundary
rules and takes precedence on **scope / safety** questions.

## Hard rules (MUST NOT)

1. **No live / authenticated runs.** Never `passivbot live`; no authenticated exchange request,
   including read-only account probes; no order create / cancel / modify.
2. **No credentials.** No API keys, `api-keys.json`, `.env`, or account identifiers in this tree or
   in git. If local credentials are ever unavoidable, keep them outside the tracked tree.
3. **Configs stay dry / backtest.** No committed config flips to live / `dry_run:false` without
   explicit user approval.
4. **Never push upstream.** `origin` (`enarjord/passivbot`) is read-only. Do not `git push`.
   Upstream-bound changes go through a fork → PR outside this sandbox.
5. **Do not edit upstream tracked files to store local state.** Add sandbox-local files instead
   (`README-sandbox.md`, `AGENTS-sandbox.md`, local scripts).
6. **Don't copy signal logic.** `quant` (`research/signals/`, StrategySpecs) is the single
   implementation source. Adapters here consume it; they never fork it into this tree.
7. **No runtime state in git.** No caches, `logs/`, backtest / optimizer artifacts, downloaded
   OHLCV, or `.venv`.
8. **Missing or stale market data is unknown** — never a trade signal.

## Precedence

explicit user safety approval > this file > upstream `AGENTS.md` > upstream docs and code.

## Working conventions

- Record batch metadata around runs: `git rev-parse HEAD`, `passivbot --version`, Python + Rust
  versions, and the data window.
- Re-record the pin table in [`README-sandbox.md`](README-sandbox.md) when the clone moves; treat it
  as a new comparison batch.
- Keep a sandbox-own `.venv/`; never `pip install -e` a `quant` package into it (or vice-versa).
- Comparison outputs intended for `quant` are written by `quant`-side scripts into `quant`'s
  evidence area — this sandbox's results are tooling material, not Gate evidence.

## Verification

- Minimal: `passivbot --help` plus a backtest on a `configs/examples/...` config after install.
- Upstream suites (`pytest`, `tests/`, `pytests/`) are the authority for passivbot behavior.
- Reproducibility: same input → same output; on divergence, suspect local edits or nondeterminism
  first.

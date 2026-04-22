# Probability Source

The news-repricing strategy now uses a fixed fallback chain instead of the older generic `prob_source_*` JSON-field mapping setup:

1. `Kalshi WebSocket` is the primary source when `kalshi_api_key` is set and the socket is healthy.
2. `Kalshi REST` is the automatic fallback when the WebSocket is unavailable or connected without usable live estimates yet.
3. `Manifold Markets polling` is used when no `kalshi_api_key` is configured.

## Operator setup

The only runtime setting required for Kalshi mode is:

```text
/config set kalshi_api_key <your-kalshi-api-key>
```

Optional:

```text
/config set prob_source_poll_seconds 60
```

That poll interval controls how often the provider checks its fallback sources. It defaults to `60` seconds and is clamped to `10-3600`.

If `kalshi_api_key` is unset or empty, the engine automatically skips Kalshi and polls Manifold's public market API instead.

## Mapping behavior

No `market_id_field`, `probability_field`, or manual source-schema config is required anymore.

The provider resolves external markets to local Gamma/Polymarket markets automatically:

- `Manifold` matches by `slug` first, then by normalized question text.
- `Kalshi REST` matches by `slug` when present, then by normalized `title` / `question` / `subtitle`.
- `Kalshi WebSocket` reuses ticker mappings learned from Kalshi REST and also still honors `kalshi_market_map` if you already have one configured.

## Data flow

```text
Kalshi WS -> ProbabilityProvider cache -> evaluateNewsSignals()
        \-> Kalshi REST fallback

No kalshi_api_key -> Manifold polling -> ProbabilityProvider cache -> evaluateNewsSignals()
```

All estimates are written into the same mutex-protected in-memory cache, and `evaluateNewsSignals()` always reads from that cache rather than from Polymarket's own `outcome_prices`.

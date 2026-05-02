# Debug Summary

## Problem

The original signing-path problem has narrowed substantially.

Earlier state:

1. False risk rejection:
`MaxPortfolioExposureExceeded` was being triggered even with no real open
orders because stale local `pending` orders were still counted as
exposure/open capacity after restarts.

2. Restart/offline issue:
the bot was crashing in live mode and Docker was restarting `engine`, which
made `control` appear offline when its IPC socket dropped.

Those earlier issues were addressed enough to continue live-signing work. The
current blocker is now specifically Polymarket live order authentication for
this wallet/profile.

## Changes Made

### Earlier runtime fixes already in place

- In `zig/src/db.zig`, open-order count and exposure now only include `placed`
  and `partially_filled`, not stale `pending`.
- In `zig/src/fill_poller.zig`, startup reconciliation now sweeps stale
  `pending` rows into `rejected`.
- In `zig/src/main.zig`, balance fetch can retry using the signer address if
  the primary balance address fails.
- Crash breadcrumbs/instrumentation were added previously for live-path
  debugging.

### New Polymarket V2 migration changes

- In `zig/src/polymarket_auth.zig`:
  - migrated CLOB exchange constants to the V2 exchange addresses
  - changed the exchange EIP-712 domain version from `"1"` to `"2"`
  - updated the signed V2 order struct to:
    - `salt`
    - `maker`
    - `signer`
    - `tokenId`
    - `makerAmount`
    - `takerAmount`
    - `side`
    - `signatureType`
    - `timestamp`
    - `metadata`
    - `builder`
  - kept the existing L1/L2 auth flow intact

- In `zig/src/order_manager.zig`:
  - switched order signing to the V2 digest path
  - added `timestamp`, `metadata`, and `builder` to submitted live orders
  - aligned the posted V2 JSON payload to the official `clob-client-v2`
    serializer shape
  - removed legacy V1-only payload fields from the V2 request body
    (`nonce`, `feeRateBps`)

### Runtime configuration experiments performed

The following live configurations were tested with Docker restarts:

1. `POLYMARKET_SIGNATURE_TYPE=1` with funder equal to signer
2. `POLYMARKET_SIGNATURE_TYPE=2` with funder equal to signer
3. `POLYMARKET_SIGNATURE_TYPE=2` with the official derived Safe address
4. `POLYMARKET_SIGNATURE_TYPE=3` with the official derived deposit wallet

Derived wallet addresses computed from Polymarket’s official relayer/client
logic for signer `0xb25DBF32235Ca0A5A7a3f1B4eFd174f763Cdb77E`:

- Safe address: `0x14a183858FF6CbDce42078751ae28d2A32F03467`
- Proxy address: `0xC3f5e8d2389763E7E016c50521EbD9bD9EC59469`
- Deposit wallet: `0x5b9c05CEF25B76C572ce1CaaFC73a9981c3f4d2A`

## Confirmed Findings

### Protocol/version result

- The old live rejection `400 {"error":"order_version_mismatch"}` is gone.
- This confirms the bot was previously posting/signing the wrong order version
  for current Polymarket production.
- The V2 migration moved the repo past the protocol-version mismatch.

### Remaining live order failure

After the V2 migration, live order attempts now fail with:

- `400 {"error":"invalid signature"}`

This persisted after:

- switching from signature type `1` to `2`
- aligning the V2 wire payload to the official client shape
- trying the derived Safe funder address

This strongly suggests the remaining issue is account/profile-specific rather
than a basic repo-level V2 schema mismatch.

### Funder/authentication findings

For the derived Safe and deposit-wallet paths:

- `GET /balance-allowance?...signature_type=...` returned `401`
- startup diagnostics showed signer-address probe still worked
- the configured derived funder probes failed

Concrete observed behavior:

- derived Safe path:
  - configured funder auth failed with `401`
  - signer-address probe still returned balance successfully

- derived deposit-wallet path:
  - configured funder auth failed with `401`
  - signer-address probe still returned balance successfully
  - engine now pauses live trading automatically because configured
    signer/funder authentication failed

### Secondary live-path issue

At one point after the V2 migration, some live attempts returned:

- `the orderbook <token_id> does not exist`

This indicates there is still a separate token/orderbook mapping issue in some
markets, likely related to the repo’s current `resolveTokenId()` shortcut using
the first token ID unconditionally.

## Current State

Current runtime state after the latest restart:

- `engine`: up and healthy
- `control`: up
- live trading: paused automatically by startup auth validation

Current `.env` state at the end of this pass:

- `POLYMARKET_SIGNATURE_TYPE=3`
- `POLYMARKET_FUNDER_ADDRESS=0x5b9c05CEF25B76C572ce1CaaFC73a9981c3f4d2A`

Current observed startup/log result:

- signer/funder authentication fails for the configured derived deposit wallet
- engine logs:
  - `live trading blocked: signer/funder authentication failed for configured Polymarket wallet`

This is safer than the earlier state because the engine is no longer spamming
invalid live orders under a known-bad configuration.

## Persistent Errors

The errors that remain unresolved at the end of this pass are:

1. Live order signing still fails for this account/profile when using the raw
   local signing path:
   - `400 {"error":"invalid signature"}`

2. Derived non-EOA funder authentication paths fail:
   - `401` on `balance-allowance` for derived Safe / deposit-wallet flows

3. Some markets still map to non-existent orderbooks:
   - `the orderbook <token_id> does not exist`

4. User-channel WebSocket still intermittently disconnects and reconnects:
   - `user-channel WS error: ReadFailed`

## Next Steps

The next step should not be more blind repo-side mutation. The repo-level V2
migration work is now mostly done, and the remaining problem is much more
likely to be one of:

1. the exact official wallet/profile flow this Trust Wallet account uses on
   Polymarket
2. a mismatch between the configured local key and the actual signer Polymarket
   expects for this funded profile
3. a remaining token/funder/profile derivation mismatch that only the official
   client path can disambiguate cleanly

Recommended next pass:

1. Reproduce this exact account in Polymarket’s official client tooling with
   the same private key/profile.
2. Determine which wallet mode actually succeeds for this profile:
   - EOA
   - POLY_PROXY
   - GNOSIS_SAFE
   - POLY_1271 / deposit wallet
3. Confirm the exact expected signer address and funded address from the
   official client.
4. Once wallet mode is confirmed, patch local config/code to match it exactly.
5. Separately fix `resolveTokenId()` so market side and token selection match
   actual orderbook expectations instead of always choosing token index `0`.

## Key Conclusion

This is no longer primarily a repo-wide signing-version bug.

The protocol-level V2 mismatch has been fixed. The remaining blocker is a
much narrower Polymarket account/profile authentication mismatch plus a
secondary market-to-token resolution problem.

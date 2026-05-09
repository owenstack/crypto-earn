## Plan: Phase 2 HL Signing Foundation

Implement only Phase 2 with integration: add MessagePack encoding and Hyperliquid EIP-712 signing/auth modules, wire them into the existing engine startup and order submission path behind HL config toggles, and keep non-Phase-2 systems (market data, fill polling, portfolio/risk rewrites) unchanged. Use chainId 999 (mainnet) and 998 (testnet), with domain/verifying contract values env-configurable.

**Steps**
1. Baseline and branch-safe prep
- Capture current compile/test baseline for Zig to detect regressions from Phase 2 changes.
- Confirm existing order submit/auth path entry points and identify minimal integration points in main and order manager.

2. Add HL Phase 2 configuration surface (blocks steps 3-6)
- Extend environment handling in main for HL_NETWORK, HL_API_PRIVATE_KEY, HL_EIP712_NAME, HL_EIP712_VERSION, HL_EIP712_VERIFIER_MAINNET, HL_EIP712_VERIFIER_TESTNET, and optional HL_CHAIN_ID override.
- Enforce startup validation rules: valid private key hex, HL_NETWORK in {testnet, mainnet}, and required domain settings present.
- Resolve runtime chainId from network: testnet->998, mainnet->999 (unless explicit override).

3. Implement MessagePack module (parallel with step 4)
- Add new msgpack module with deterministic map/field ordering for HL action payloads required by signing.
- Implement primitive encoders needed by order payloads: map, array, string, integer, float, bool, null.
- Provide API shaped for signing path (encodeActionForSigning allocator-safe function returning byte slice).

4. Implement HL auth/signing module (parallel with step 3; depends on step 2 for runtime values)
- Add hl_auth module for key parsing, address derivation plumbing, domain assembly, and digest/signature construction.
- Reuse existing crypto signing primitive and add missing helpers only if required (address derivation utilities or digest helpers).
- Build signature output as JSON-ready r/s/v triplet expected by exchange payload builder.

5. Integrate signing flow into order submission (depends on steps 3-4)
- Refactor order manager submit path to support HL signing payload assembly while preserving current behavior for non-HL paths.
- Inject config/state from main into order manager config so signing code has private key, derived signer address, chainId, and domain/verifier values.
- Keep Phase 2 integration minimal: only submit payload/signing path changes, no orderbook/fill/risk semantic rewrites.

6. Add startup auth observability and safety (depends on steps 2,4)
- Log derived wallet address in checksum format at startup.
- Guarantee no private key leakage in logs/errors.
- Fail fast on malformed/absent credentials with clear operator-facing error messages.

7. Add test coverage for Phase 2 deliverables (depends on steps 3-5)
- Add msgpack test vectors (canonical known bytes for representative HL payloads).
- Add digest/signature tests validating deterministic digest and valid v/r/s shape.
- Add config validation tests for network/chain/domain resolution.
- Add integration-level order payload test to ensure signed action envelope shape and required fields.

8. Verify and document Phase 2 completion criteria
- Run zig test/build commands and record pass/fail deltas.
- Validate that only Phase 2 scope changed and Phase 3+ behavior is explicitly untouched.
- Update planning docs/checklist entries to mark Phase 2 tasks done and open follow-ups deferred.

**Relevant files**
- /home/owenstack/repos/personal/crypto-earn/zig/src/crypto.zig — reuse signEip712 and add only minimal helpers needed for HL auth/address formatting.
- /home/owenstack/repos/personal/crypto-earn/zig/src/main.zig — env parsing, startup validation, chainId resolution, and order manager config wiring.
- /home/owenstack/repos/personal/crypto-earn/zig/src/order_manager.zig — integrate HL signed payload submission path.
- /home/owenstack/repos/personal/crypto-earn/zig/src/tests.zig — register/import new module tests and integration assertions.
- /home/owenstack/repos/personal/crypto-earn/zig/build.zig — ensure new files are included if needed by build/test wiring.
- /home/owenstack/repos/personal/crypto-earn/zig/src/msgpack.zig — new deterministic MessagePack encoder for signing preimage.
- /home/owenstack/repos/personal/crypto-earn/zig/src/hl_auth.zig — new HL auth/domain/signature assembly module.
- /home/owenstack/repos/personal/crypto-earn/.env.example — add Phase 2 HL env contract and defaults.

**Verification**
1. Run zig build and zig build test from /home/owenstack/repos/personal/crypto-earn/zig and confirm no regressions.
2. Execute targeted tests for msgpack and hl_auth vectors and ensure deterministic outputs across reruns.
3. Validate startup failure modes by running with invalid HL_API_PRIVATE_KEY and invalid HL_NETWORK and confirming fail-fast behavior.
4. Validate startup success mode by running with testnet config and confirming derived address log appears without secret leakage.
5. Validate signed order envelope unit/integration test asserts required fields and uses chainId 998 for testnet and 999 for mainnet.

**Decisions**
- Include: Phase 2 plus integration into current submit path.
- Exclude: Phase 1 deletions, Phase 3 market-data rewrites, Phase 5 fill/portfolio rewrites, Phase 6 risk semantics rewrite, dashboard/Telegram updates.
- Chain IDs fixed by user decision: mainnet 999, testnet 998.
- Domain/verifying contract values should be env-configurable in Phase 2.

**Further Considerations**
1. Compatibility approach recommendation: keep existing legacy path behind a switch so Phase 2 integration can be merged safely before full Phase 1/3 rewrites.
2. Test vector source recommendation: pin known-good vectors in-repo to avoid external drift during CI.
3. Security recommendation: treat all signer/domain env vars as required in live mode and optional with strict defaults in dry-run mode.
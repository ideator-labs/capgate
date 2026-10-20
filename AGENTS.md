# AGENTS.md: CapGate handoff

## What this is and the claim
A Rust CLI that reads the top-level imports of a WebAssembly component and compares them with a committed `caps.lock`. Claim: a component update that asks for new host interfaces (sockets, filesystem, env) fails CI with exit 1 and names each new interface, while a WASI version bump alone passes.

## Status
- Real: the CLI (`src/main.rs`, uses `wasmparser` 0.240), two real Rust components built for `wasm32-wasip2`, cross-check against `wasm-tools component wit`.
- Stubbed: nothing at runtime. The "telemetry" in `plugins/v2` is a fake exfiltration to a TEST-NET address (203.0.113.7); it is only compiled, never run by the demo.
- Not built: policy rules, nested component imports, OCI or registry fetch, GitHub Action.

## Data shape
`Caps = BTreeMap<String, String>`: interface (`wasi:sockets/tcp`) to version (`0.2.12`). The interface is the capability; the version is metadata. `caps.lock` is one `iface@version` per line, `#` comments allowed, sorted.
`check` computes three sets: new (in component, not in lock; fails), dropped (in lock, not in component; reported), version-only (same interface, other version; reported).

## Repo map
- `src/main.rs`: whole CLI (`list`, `lock`, `check`). Exit 0 ok, 1 new capability, 2 bad input or not a component.
- `plugins/v1`, `plugins/v2`: `greeter` 1.0.0 and 1.1.0 test components.
- `demo.sh`: the artifact. 6 checks plus `--break`. Writes scratch output to `.demo/`.

## Fresh clone: setup, run, verify
```
rustup target add wasm32-wasip2
cargo install wasm-tools --locked
git clone https://github.com/ideator-labs/capgate && cd capgate
bash demo.sh            # expect "RESULT: 6 passed, 0 failed", "RESULT: PASS", exit 0
bash demo.sh --break    # expect "RESULT: 1 passed, 5 failed", exit 1 (only check 5 passes)
```
Tested with rustc stable (Oct 2026), wasm-tools 1.262.0, components importing WASI 0.2.12.

## Design decisions
- Key on the interface without version, so routine WASI patch bumps do not train people to rubber-stamp the lock. `--break` removes exactly this and the gate becomes noise.
- Exact lockfile, not a policy language: a lock diff in a PR is the review surface.
- Fail closed: a core module or unreadable file is exit 2, never a pass.
- Read the binary, not the WIT source, so what is checked is what ships.

## Limits
- Imports are linked surface, not runtime use. Rust std imports `wasi:cli/environment` in a hello world, and v1.1 picks up UDP and DNS imports it never calls.
- Only top-level component imports; nested and composed internals are not walked.
- No checks on exports, on core modules (WASI preview 1), or on Extism host functions.
- Tested only on Rust-built WASI 0.2 components; WASI 0.3 components untested.

## Next steps (prioritized, each with done-when)
1. GitHub Action wrapper. Done when a sample workflow fails a PR that bumps a plugin to v1.1 and posts the new interfaces in the job summary.
2. WASI 0.3 component test. Done when a `wasm32-wasip2` build with `wstd` on WASI 0.3 passes demo checks 1 to 4.
3. Extism plugins: read core-module imports in the `extism:host/user` namespace. Done when a check fails on a plugin that adds a new host function.
4. OCI input: `capgate check oci://...` for Spin and wasmCloud artifacts. Done when it checks a component pulled from a local registry.
5. Deny list per interface (`wasi:sockets/*` never). Done when a lock with a deny line fails even on re-lock.

## Working rules
Commit as danielgerlag <daniel@gerlag.ca>. Keep `bash demo.sh` green and `--break` red. No em-dashes, no invented links. Labelled stubs only.

## Sources
- Wasmtime 49.0.3 and 49.0.4 security fixes, including a filesystem sandbox escape: https://docs.rs/crate/wasmtime-cli/latest/source/RELEASES.md
- Extism 1.40 and 1.41 releases on Wasmtime 48 and 49: https://github.com/extism/extism/releases
- Write-up on the escape and plugin hosts: https://toddschiller.com/blog/this-week-in-extensibility-2026-10-16.html
- Shell-snippet versions of this check: https://www.systemshardening.com/articles/wasm/wasi-preview-2-capabilities/
- WASI 0.3.2 release: https://github.com/WebAssembly/WASI/releases

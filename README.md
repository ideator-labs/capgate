# CapGate

A plugin you run in Wasmtime, Spin, wasmCloud or Extism can only touch what the host hands it, and a WebAssembly component says up front which host interfaces it imports. CapGate turns that list into a lockfile. CI fails when a new build of a component imports an interface the lock does not have, the way a phone asks again when an app update wants new permissions.

```
capgate lock  plugin.wasm caps.lock   # after review, record what it may import
capgate check plugin.wasm caps.lock   # exit 0 ok, 1 new capability, 2 bad input
capgate list  plugin.wasm             # print imports in lock format
```

A WASI version bump (`wasi:cli/stdout@0.2.6` to `@0.2.12`) is reported but never counts as a new capability.

## Demo

```
bash demo.sh          # 6 checks, exit 0
bash demo.sh --break  # capability keyed on the versioned name; 5 checks fail, exit 1
```

It builds two real Rust `wasm32-wasip2` components. `greeter` 1.0.0 prints a line. 1.1.0 is a patch release that also reads `API_TOKEN` and opens a TCP socket. CapGate blocks 1.1.0 with 10 new interfaces, including `wasi:sockets/tcp` and `wasi:filesystem/preopens`, and its import list matches `wasm-tools component wit` exactly.

Needs Rust with the `wasm32-wasip2` target and `wasm-tools`. Setup, design and limits are in [AGENTS.md](AGENTS.md).

## Honest limits

Imports show what a component links, not what it calls at runtime. Rust std imports `wasi:cli/environment` even in a hello world. Only top-level component imports are read, and there is no policy language yet, only an exact lock. This is a proof of concept, not a released tool.

MIT licensed.

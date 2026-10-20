#!/usr/bin/env bash
# CapGate demo: a plugin patch release quietly asks for sockets and filesystem; the gate catches it.
# Usage: bash demo.sh          (all checks should pass, exit 0)
#        bash demo.sh --break  (capgate keyed on the full versioned name; checks 1-4 and 6 fail, exit 1)
set -uo pipefail
cd "$(dirname "$0")"
OUT=.demo; rm -rf "$OUT"; mkdir -p "$OUT"
for t in cargo wasm-tools; do command -v "$t" >/dev/null || { echo "missing $t (see AGENTS.md setup)"; exit 2; }; done

SRC=.
if [[ "${1:-}" == "--break" ]]; then
  echo "BREAK MODE: capability key includes the version, so a WASI version bump looks like a new capability"
  SRC="$OUT/broken"; mkdir -p "$SRC"; cp -r Cargo.toml src "$SRC"/
  sed -i 's|Some((iface, ver)) => (iface.to_string(), ver.to_string()),|Some((_, ver)) => (name.to_string(), ver.to_string()),|' "$SRC/src/main.rs"
  grep -q 'Some((_, ver)) => (name.to_string()' "$SRC/src/main.rs" || { echo "break patch did not apply"; exit 2; }
fi
cargo build -q --release --manifest-path "$SRC/Cargo.toml" || exit 2
CG="$SRC/target/release/capgate"
for v in v1 v2; do cargo build -q --release --target wasm32-wasip2 --manifest-path plugins/$v/Cargo.toml || exit 2; done
V1=plugins/v1/target/wasm32-wasip2/release/greeter.wasm
V2=plugins/v2/target/wasm32-wasip2/release/greeter.wasm

PASS=0; FAIL=0
check() { if [[ "$2" == ok ]]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

# 1. capgate reads the same imports as an independent tool (wasm-tools component wit).
"$CG" list "$V1" | grep -v '^#' | sort > "$OUT/capgate-v1.txt"
wasm-tools component wit "$V1" | sed -n 's/^  import \(.*\);$/\1/p' | sort > "$OUT/wasmtools-v1.txt"
[[ -s "$OUT/capgate-v1.txt" ]] && diff -q "$OUT/capgate-v1.txt" "$OUT/wasmtools-v1.txt" >/dev/null && r=ok || r=no
check "1 imports match wasm-tools component wit ($(wc -l < "$OUT/capgate-v1.txt") interfaces)" $r

# 2. Lock v1 after review; the same build passes the gate.
"$CG" lock "$V1" "$OUT/caps.lock" >/dev/null
"$CG" check "$V1" "$OUT/caps.lock" > "$OUT/check2.txt"; rc=$?
[[ $rc == 0 ]] && grep -q ' 0 new' "$OUT/check2.txt" && r=ok || r=no
check "2 unchanged plugin passes (exit $rc)" $r

# 3. v1.1 (a patch bump) adds env-token telemetry over TCP: gate exits 1 and names sockets + filesystem.
"$CG" check "$V2" "$OUT/caps.lock" > "$OUT/check3.txt"; rc=$?
[[ $rc == 1 ]] && grep -q 'NEW CAPABILITY  wasi:sockets/tcp$' "$OUT/check3.txt" \
  && grep -q 'NEW CAPABILITY  wasi:filesystem/preopens$' "$OUT/check3.txt" && r=ok || r=no
check "3 patch release asking for new host access is blocked (exit $rc, $(grep -c 'NEW CAPABILITY' "$OUT/check3.txt") new)" $r
grep 'NEW CAPABILITY' "$OUT/check3.txt" | sed 's/^/     /'

# 4. A WASI version bump alone (lock written against 0.2.6) is not a new capability.
sed 's/@0\.2\.[0-9]*$/@0.2.6/' "$OUT/caps.lock" > "$OUT/old.lock"
"$CG" check "$V1" "$OUT/old.lock" > "$OUT/check4.txt"; rc=$?
[[ $rc == 0 ]] && grep -q ' 0 new, 0 dropped, 14 version-only' "$OUT/check4.txt" && r=ok || r=no
check "4 version-only bump passes and is reported ($(tail -1 "$OUT/check4.txt"))" $r

# 5. Fail closed: a core module (not a component) is an error, exit 2, not a silent pass.
echo '(module)' | wasm-tools parse -o "$OUT/core.wasm"
"$CG" check "$OUT/core.wasm" "$OUT/caps.lock" > /dev/null 2>"$OUT/check5.txt"; rc=$?
[[ $rc == 2 ]] && r=ok || r=no
check "5 non-component input fails closed (exit $rc)" $r

# 6. After a human accepts the grant, re-locking makes v1.1 pass, and the lock diff shows exactly what was granted.
cp "$OUT/caps.lock" "$OUT/caps.v1.lock"
"$CG" lock "$V2" "$OUT/caps.lock" >/dev/null
"$CG" check "$V2" "$OUT/caps.lock" >/dev/null; rc=$?
added=$(diff "$OUT/caps.v1.lock" "$OUT/caps.lock" | grep -c '^>')
[[ $rc == 0 && $added == 10 ]] && r=ok || r=no
check "6 accepted grant passes; lock diff adds $added lines" $r

echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }

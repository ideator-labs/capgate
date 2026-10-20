use std::collections::BTreeMap;
use std::process::ExitCode;
use wasmparser::{Parser, Payload};

/// Interface (`wasi:sockets/tcp`) -> version (`0.2.12`). The interface is the capability;
/// the version is metadata, so a version bump alone is never a new capability.
type Caps = BTreeMap<String, String>;

fn split(name: &str) -> (String, String) {
    match name.rsplit_once('@') {
        Some((iface, ver)) => (iface.to_string(), ver.to_string()),
        None => (name.to_string(), String::new()),
    }
}

fn component_imports(bytes: &[u8]) -> Result<Caps, String> {
    let mut caps = Caps::new();
    let mut depth = 0usize;
    let mut saw_component = false;
    for payload in Parser::new(0).parse_all(bytes) {
        match payload.map_err(|e| e.to_string())? {
            Payload::Version { encoding, .. } => {
                if depth == 0 && encoding != wasmparser::Encoding::Component {
                    return Err("not a component (core module); capgate reads component imports".into());
                }
                saw_component = true;
                depth += 1;
            }
            Payload::End(_) => depth -= 1,
            Payload::ComponentImportSection(reader) if depth == 1 => {
                for import in reader {
                    let (iface, ver) = split(import.map_err(|e| e.to_string())?.name.0);
                    caps.insert(iface, ver);
                }
            }
            _ => {}
        }
    }
    if !saw_component {
        return Err("empty input".into());
    }
    Ok(caps)
}

fn read_lock(path: &str) -> Result<Caps, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(split)
        .collect())
}

fn render_lock(caps: &Caps) -> String {
    let mut out = String::from("# capgate lock: host interfaces this component may import. Review changes like a permission grant.\n");
    for (iface, ver) in caps {
        out.push_str(&format!("{iface}@{ver}\n"));
    }
    out
}

fn run(args: &[String]) -> Result<bool, String> {
    let load = |p: &str| std::fs::read(p).map_err(|e| format!("{p}: {e}")).and_then(|b| component_imports(&b));
    match args {
        [cmd, wasm] if cmd == "list" => {
            print!("{}", render_lock(&load(wasm)?));
            Ok(true)
        }
        [cmd, wasm, lock] if cmd == "lock" => {
            std::fs::write(lock, render_lock(&load(wasm)?)).map_err(|e| e.to_string())?;
            println!("wrote {lock}");
            Ok(true)
        }
        [cmd, wasm, lock] if cmd == "check" => {
            let actual = load(wasm)?;
            let allowed = read_lock(lock)?;
            let added: Vec<_> = actual.keys().filter(|k| !allowed.contains_key(*k)).collect();
            let removed: Vec<_> = allowed.keys().filter(|k| !actual.contains_key(*k)).collect();
            let bumped: Vec<_> = actual
                .iter()
                .filter(|(k, v)| allowed.get(*k).is_some_and(|a| a != *v))
                .collect();
            for k in &added {
                println!("NEW CAPABILITY  {k}");
            }
            for k in &removed {
                println!("dropped         {k}");
            }
            for (k, v) in &bumped {
                println!("version only    {k} {} -> {v}", allowed[*k]);
            }
            println!(
                "capgate: {} imports, {} new, {} dropped, {} version-only",
                actual.len(),
                added.len(),
                removed.len(),
                bumped.len()
            );
            Ok(added.is_empty())
        }
        _ => Err("usage: capgate list <component.wasm> | lock <component.wasm> <caps.lock> | check <component.wasm> <caps.lock>".into()),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::from(1),
        Err(e) => {
            eprintln!("capgate: {e}");
            ExitCode::from(2)
        }
    }
}

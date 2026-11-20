use adblock::lists::{FilterSet, ParseOptions, RuleTypes};
use adblock::request::Request;
use adblock::Engine;
use std::ffi::CStr;
use std::fs;
use std::io::Write;
use std::os::raw::c_char;
use std::path::Path;
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};

/// Opaque thread-safe handle exposed over the C ABI to custom WebKit's
/// NetworkProcess and Barc. Uses Brave's FlatBuffers-backed `adblock-rust`
/// engine so all network ad/tracker blocking lives in one compact ~10-15 MB
/// structure inside NetworkProcess instead of duplicating 63 MB of compiled
/// WKContentRuleList DFAs into every WebContent process.
pub struct BarcAdblockEngine {
    engine: Engine,
    rule_count: u64,
    blocked_count: AtomicU64,
}

fn parse_options(load_cosmetics: bool) -> ParseOptions {
    ParseOptions {
        rule_types: if load_cosmetics {
            RuleTypes::All
        } else {
            RuleTypes::NetworkOnly
        },
        ..ParseOptions::default()
    }
}

fn compute_dir_fingerprint(paths: &[std::path::PathBuf], load_cosmetics: bool) -> u64 {
    // FNV-1a over filenames, sizes, and mtimes so cache invalidates whenever
    // Barc refreshes any filter list file.
    let mut hash: u64 = 14_695_981_039_346_656_037 ^ if load_cosmetics { 1 } else { 0 };
    for path in paths {
        if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            for b in name.as_bytes() {
                hash ^= *b as u64;
                hash = hash.wrapping_mul(1_099_511_628_211);
            }
        }
        if let Ok(meta) = fs::metadata(path) {
            let len = meta.len();
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            for v in [len, mtime] {
                for b in v.to_le_bytes() {
                    hash ^= b as u64;
                    hash = hash.wrapping_mul(1_099_511_628_211);
                }
            }
        }
    }
    hash
}

fn load_dir_rules(dir: &Path, load_cosmetics: bool) -> Option<BarcAdblockEngine> {
    let entries = fs::read_dir(dir).ok()?;
    let mut paths: Vec<_> = entries
        .filter_map(|e| e.ok().map(|entry| entry.path()))
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("txt"))
        .collect();
    paths.sort();
    if paths.is_empty() {
        return None;
    }

    let fp = compute_dir_fingerprint(&paths, load_cosmetics);
    let cache_path = dir.join(format!("barc-adblock-v1-{:016x}.dat", fp));

    // Fast path: deserialize prebuilt FlatBuffer directly (~2 ms, ~6-10 MB RAM,
    // avoiding the ~35 MB peak from parsing raw EasyList text inside NetworkProcess).
    if let Ok(bytes) = fs::read(&cache_path) {
        let mut engine = Engine::default();
        if engine.deserialize(&bytes).is_ok() {
            return Some(BarcAdblockEngine {
                engine,
                rule_count: 0,
                blocked_count: AtomicU64::new(0),
            });
        }
    }

    let mut filter_set = FilterSet::new(false);
    let opts = parse_options(load_cosmetics);
    let mut rule_count: u64 = 0;

    for path in &paths {
        if let Ok(text) = fs::read_to_string(path) {
            rule_count += text.lines().count() as u64;
            filter_set.add_filter_list(text, opts);
        }
    }

    if rule_count == 0 {
        return None;
    }

    let engine = Engine::new_with_filter_set(filter_set);

    // Best-effort write of the FlatBuffer cache and cleanup of older cache files.
    let serialized = engine.serialize();
    let tmp = cache_path.with_extension("dat.tmp");
    if fs::write(&tmp, &serialized).is_ok() {
        let _ = fs::rename(&tmp, &cache_path);
        if let Ok(existing) = fs::read_dir(dir) {
            for entry in existing.flatten() {
                let p = entry.path();
                if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                    if name.starts_with("barc-adblock-v1-") && name.ends_with(".dat") && p != cache_path {
                        let _ = fs::remove_file(&p);
                    }
                }
            }
        }
    }

    Some(BarcAdblockEngine {
        engine,
        rule_count,
        blocked_count: AtomicU64::new(0),
    })
}

fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

#[no_mangle]
pub extern "C" fn barc_adblock_new_from_dir(
    filter_lists_dir: *const c_char,
    load_cosmetics: bool,
) -> *mut BarcAdblockEngine {
    let Some(dir_str) = cstr_to_str(filter_lists_dir) else {
        return std::ptr::null_mut();
    };
    match load_dir_rules(Path::new(dir_str), load_cosmetics) {
        Some(engine) => Box::into_raw(Box::new(engine)),
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn barc_adblock_new_from_rules(
    rules_utf8: *const c_char,
    len: usize,
    load_cosmetics: bool,
) -> *mut BarcAdblockEngine {
    if rules_utf8.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { slice::from_raw_parts(rules_utf8 as *const u8, len) };
    let Ok(text) = std::str::from_utf8(bytes) else {
        return std::ptr::null_mut();
    };
    let mut filter_set = FilterSet::new(false);
    let rule_count = text.lines().count() as u64;
    filter_set.add_filter_list(text.to_string(), parse_options(load_cosmetics));
    let engine = Engine::new_with_filter_set(filter_set);
    Box::into_raw(Box::new(BarcAdblockEngine {
        engine,
        rule_count,
        blocked_count: AtomicU64::new(0),
    }))
}

#[no_mangle]
pub extern "C" fn barc_adblock_should_block(
    engine: *const BarcAdblockEngine,
    url: *const c_char,
    source_url: *const c_char,
    request_type: *const c_char,
) -> bool {
    if engine.is_null() {
        return false;
    }
    let Some(url_str) = cstr_to_str(url) else {
        return false;
    };
    let source_str = cstr_to_str(source_url).unwrap_or("");
    let type_str = cstr_to_str(request_type).unwrap_or("other");

    let Ok(req) = Request::new(url_str, source_str, type_str, "GET") else {
        return false;
    };
    let handle = unsafe { &*engine };
    let result = handle.engine.check_network_request(&req);
    if result.should_block() {
        handle.blocked_count.fetch_add(1, Ordering::Relaxed);
        true
    } else {
        false
    }
}

#[no_mangle]
pub extern "C" fn barc_adblock_blocked_count(engine: *const BarcAdblockEngine) -> u64 {
    if engine.is_null() {
        return 0;
    }
    unsafe { &*engine }.blocked_count.load(Ordering::Relaxed)
}

#[no_mangle]
pub extern "C" fn barc_adblock_rule_count(engine: *const BarcAdblockEngine) -> u64 {
    if engine.is_null() {
        return 0;
    }
    unsafe { &*engine }.rule_count
}

#[no_mangle]
pub extern "C" fn barc_adblock_free(engine: *mut BarcAdblockEngine) {
    if !engine.is_null() {
        unsafe {
            drop(Box::from_raw(engine));
        }
    }
}

// MARK: - Out-of-line LZ4 compressed state blobs

#[no_mangle]
pub extern "C" fn barc_state_write(
    path: *const c_char,
    data: *const u8,
    len: usize,
) -> i32 {
    let Some(path_str) = cstr_to_str(path) else {
        return -1;
    };
    if data.is_null() && len > 0 {
        return -2;
    }
    let slice_data = if len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(data, len) }
    };
    let compressed = lz4_flex::compress_prepend_size(slice_data);
    let target = Path::new(path_str);
    if let Some(parent) = target.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let tmp = target.with_extension("tmp");
    let Ok(mut file) = fs::File::create(&tmp) else {
        return -3;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = file.set_permissions(fs::Permissions::from_mode(0o600));
    }
    if file.write_all(&compressed).is_err() || file.flush().is_err() {
        let _ = fs::remove_file(&tmp);
        return -4;
    }
    if fs::rename(&tmp, target).is_err() {
        let _ = fs::remove_file(&tmp);
        return -5;
    }
    0
}

#[no_mangle]
pub extern "C" fn barc_state_read(
    path: *const c_char,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out_data.is_null() || out_len.is_null() {
        return -1;
    }
    let Some(path_str) = cstr_to_str(path) else {
        return -2;
    };
    let Ok(compressed) = fs::read(path_str) else {
        return -3;
    };
    let Ok(mut raw) = lz4_flex::decompress_size_prepended(&compressed) else {
        return -4;
    };
    raw.shrink_to_fit();
    let len = raw.len();
    let ptr = raw.as_mut_ptr();
    std::mem::forget(raw);
    unsafe {
        *out_data = ptr;
        *out_len = len;
    }
    0
}

#[no_mangle]
pub extern "C" fn barc_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        unsafe {
            drop(Vec::from_raw_parts(ptr, len, len));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn blocks_known_ads_and_allows_content() {
        let rules = "||doubleclick.net^\n||google-analytics.com/analytics.js\n@@||allowed.doubleclick.net^\n";
        let eng = barc_adblock_new_from_rules(rules.as_ptr() as *const c_char, rules.len(), false);
        assert!(!eng.is_null());

        let ad = CString::new("https://ads.doubleclick.net/pagead/ads.js").unwrap();
        let src = CString::new("https://example.com/").unwrap();
        let typ = CString::new("script").unwrap();
        assert!(barc_adblock_should_block(eng, ad.as_ptr(), src.as_ptr(), typ.as_ptr()));

        let ok = CString::new("https://example.com/app.js").unwrap();
        assert!(!barc_adblock_should_block(eng, ok.as_ptr(), src.as_ptr(), typ.as_ptr()));

        let exc = CString::new("https://allowed.doubleclick.net/ok.js").unwrap();
        assert!(!barc_adblock_should_block(eng, exc.as_ptr(), src.as_ptr(), typ.as_ptr()));

        assert_eq!(barc_adblock_blocked_count(eng), 1);
        barc_adblock_free(eng);
    }

    #[test]
    fn roundtrips_lz4_state_blob() {
        let dir = std::env::temp_dir().join("barc-core-rs-test");
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("tab-test.state");
        let cpath = CString::new(path.to_str().unwrap()).unwrap();
        let payload = vec![0x42u8; 64 * 1024];

        assert_eq!(barc_state_write(cpath.as_ptr(), payload.as_ptr(), payload.len()), 0);
        let compressed_size = fs::metadata(&path).unwrap().len();
        assert!(compressed_size < 1024, "expected tight LZ4 compression, got {}", compressed_size);

        let mut out_ptr: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        assert_eq!(barc_state_read(cpath.as_ptr(), &mut out_ptr, &mut out_len), 0);
        assert_eq!(out_len, payload.len());
        let restored = unsafe { slice::from_raw_parts(out_ptr, out_len) };
        assert_eq!(restored, payload.as_slice());

        barc_bytes_free(out_ptr, out_len);
        let _ = fs::remove_dir_all(&dir);
    }
}

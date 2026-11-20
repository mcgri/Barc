#ifndef BARC_CORE_H
#define BARC_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque thread-safe Rust adblock engine (Brave adblock-rust).
/// Loaded once inside custom WebKit's NetworkProcess (or Barc) so WebContent
/// processes carry 0 bytes of compiled WKContentRuleList DFA overhead.
typedef struct BarcAdblockEngine BarcAdblockEngine;

/// Loads all `.txt` filter lists from `filter_lists_dir` (e.g. EasyList,
/// EasyPrivacy, uBlock lists) into a single deduplicated Rust engine.
/// When `load_cosmetics` is false, generic/cosmetic rules are skipped to save
/// additional memory (network-only blocking).
BarcAdblockEngine* barc_adblock_new_from_dir(const char* filter_lists_dir, bool load_cosmetics);

/// Builds an engine from an in-memory UTF-8 ABP/uBlock filter text buffer.
BarcAdblockEngine* barc_adblock_new_from_rules(const char* rules_utf8, size_t len, bool load_cosmetics);

/// Returns true if `url` loaded from `source_url` with `request_type`
/// ("script", "image", "stylesheet", "xmlhttprequest", "sub_frame", "other", etc.)
/// should be blocked. Thread-safe (interior RwLock/atomic stats).
bool barc_adblock_should_block(
    const BarcAdblockEngine* engine,
    const char* url,
    const char* source_url,
    const char* request_type
);

/// Total number of requests blocked by this engine instance.
uint64_t barc_adblock_blocked_count(const BarcAdblockEngine* engine);

/// Number of filter lines ingested when building this engine.
uint64_t barc_adblock_rule_count(const BarcAdblockEngine* engine);

/// Destroys the engine and frees its memory.
void barc_adblock_free(BarcAdblockEngine* engine);

/// Compresses `data` with LZ4 and atomically writes it to `path` (mode 0600).
/// Returns 0 on success, non-zero on failure.
int32_t barc_state_write(const char* path, const uint8_t* data, size_t len);

/// Reads and decompresses an LZ4 state blob from `path`.
/// On success returns 0 and populates `*out_data` and `*out_len`; caller frees
/// with `barc_bytes_free(*out_data, *out_len)`.
int32_t barc_state_read(const char* path, uint8_t** out_data, size_t* out_len);

/// Frees a buffer returned by `barc_state_read`.
void barc_bytes_free(uint8_t* ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* BARC_CORE_H */

// The Rust core (`sharedCore/`, built for wasm), shared with the Mac app: sync decisions, merges, invites, file kinds.
import init from "~/wasm/core/core.js";
import coreWasm from "~/wasm/core/core_bg.wasm?url";

await init({ module_or_path: coreWasm });

export * from "~/wasm/core/core.js";

use std::{env, path::PathBuf, process::Command};

fn main() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rerun-if-changed=native/Passkeys.swift");
        let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
        let arch = if env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("aarch64") { "arm64" } else { "x86_64" };
        let object = out.join("Passkeys.o");
        let status = Command::new("swiftc").args(["-parse-as-library", "-emit-object", "-O", "-target", &format!("{arch}-apple-macos12.0"), "native/Passkeys.swift", "-o"]).arg(&object).status().expect("swiftc is required for macOS passkeys");
        assert!(status.success(), "Couldn't compile native passkeys");
        let archive = out.join("libTypewrightPasskeys.a");
        assert!(Command::new("ar").arg("crs").arg(&archive).arg(&object).status().unwrap().success());
        println!("cargo:rustc-link-search=native={}", out.display());
        println!("cargo:rustc-link-lib=static=TypewrightPasskeys");
        let info = Command::new("swiftc").arg("-print-target-info").output().unwrap();
        let info: serde_json::Value = serde_json::from_slice(&info.stdout).unwrap();
        for path in info["paths"]["runtimeLibraryPaths"].as_array().unwrap() {
            println!("cargo:rustc-link-search=native={}", path.as_str().unwrap());
        }
        println!("cargo:rustc-link-search=native=/usr/lib/swift");
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }
    tauri_build::build()
}

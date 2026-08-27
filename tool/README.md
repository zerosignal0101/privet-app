# Tooling

## `build_privetd.sh` — cross-compile the daemon for Android

The Android app bundles a native `privetd` ELF per ABI under
`assets/bin/<abi>/privetd` and spawns it in the app sandbox (it is `exec`'d,
not `dlopen`'d, so each artifact is a plain executable ELF, chmod +x).

```bash
# one ABI first (the spike / risk gate)
ABI=arm64-v8a bash tool/build_privetd.sh
# all three
bash tool/build_privetd.sh
```

The cross-compile targets a Rust workspace that is otherwise built for the
host (`D:\C-Codes\privet`). On Windows the script runs under Git Bash.

### Requirements

- **cargo-ndk** — `cargo install cargo-ndk`
- **Android NDK** — set `ANDROID_NDK_HOME`, or it is auto-detected as the newest
  NDK under the Android SDK (`%LOCALAPPDATA%\Android\sdk\ndk`).
- **Rust Android targets** — `rustup target add aarch64-linux-android
  armv7-linux-androideabi x86_64-linux-android`

The script targets **min API 24** (`cargo ndk -P 24`) — `getifaddrs` (used by the
`if-addrs` crate for interface enumeration) is only in Android libc from API 24,
and cargo-ndk defaults to 21, which links with an undefined symbol. This matches
Flutter's default `minSdkVersion`.

cargo-ndk 4.x only stages `cdylib`/`staticlib` artifacts, so for the `privetd`
bin target the script builds without `-o` and copies the executable out of
`target/<triple>/release/`. On the device, `AndroidDaemonBundle.extract()` sets
the exec bit.

### Verification

The script prints `file` output for each staged binary — it must report an
Android ELF (e.g. `ELF 64-bit LSB pie executable, ARM aarch64`). The binaries
are committed to the repo (a release `privetd` is ~3–6 MB per ABI).

Override the daemon repo with `PRIVET_REPO=/path/to/privet`.

# SOPS Vault

A native macOS app (Swift + SwiftUI, macOS 14+) for viewing and editing secrets encrypted with
[SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age).

![SOPS Vault](docs/screenshot.png)

- Add files or whole repositories (file picker or drag & drop). The app finds SOPS files
  (`*.enc.env`, `*.enc.yaml`, `*.enc.json`, or any YAML/JSON/ENV file containing `sops` metadata)
  and groups them by project (the folder holding `.git`).
- Values are hidden (`••••`) until you reveal them one by one. Copying puts the value on the
  clipboard, marked concealed/transient, and clears it after 30 seconds.
- Search by key name. Add, edit and delete keys, including nested JSON/YAML values and typed values.
- Optional Touch ID / macOS password lock when the app opens, when the Mac sleeps and after
  5 minutes of inactivity.
- The interface is in Spanish.

## Security model

- Decryption and encryption are done by your local `sops` binary. SOPS Vault never implements crypto itself.
- Decrypted values exist **only in memory**. They are never written to disk, `UserDefaults` or
  window restoration state. Locking the app drops them.
- Edits use `sops set` / `sops unset` on a **ciphertext-only** copy in a private `0700` staging
  directory next to the file. The result is decrypted and checked against the intended change, and
  the file is checked for outside changes. Only then is it atomically renamed over the original. No
  plaintext temp files are created, and the existing `.sops.yaml` recipients are kept.
- References are saved as security-scoped bookmarks. SOPS stderr is never shown, because parsers can echo values.
- The `sops` subprocess gets a minimal environment (`SOPS_AGE_KEY_FILE` and `PATH`). It does not inherit cloud credentials.

The lock protects the UI. Your age identity is still a regular file readable by your macOS user.

## Requirements

- macOS 14 Sonoma or later
- `brew install sops age` (SOPS 3.11 or later is needed for editing)
- An age identity, by default at `~/.config/sops/age/keys.txt`. You can change the identity and
  the `sops` path in Settings (⌘,).

## Build

```sh
swift build                 # debug build
./scripts/package.sh        # release build → dist/SOPS Vault.app (ad-hoc signed)
open "dist/SOPS Vault.app"
```

The app is ad-hoc signed, not notarized. The first time, right-click the app → **Open**, or run
`xattr -dr com.apple.quarantine "SOPS Vault.app"` if you downloaded it.

## Tests

Integration tests generate a throwaway age key and fake fixtures in a private temp directory. They
run the real `sops` binary and never touch your real identity.

CI runs only the unit tests (`SOPS_VAULT_SKIP_INTEGRATION=1`), because subprocesses hang inside
Xcode 16.4's test helper on GitHub's macOS 15 runners. Run the full suite locally before sending changes.

```sh
swift test                  # with Xcode
# Command Line Tools only (no Xcode): point the compiler at the Swift Testing macro plugin
swift test --disable-xctest -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

## Project layout

```
Sources/VaultCore   SOPS invocation, discovery, bookmarks, document model (tested)
Sources/SOPSVault   SwiftUI app
Tests/VaultCoreTests
scripts/            packaging and icon generation
```

## License

[MIT](LICENSE)

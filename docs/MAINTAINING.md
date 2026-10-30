# Maintenance and publication

## Public repository contents

Only track the README, license, builder manifest, launcher, scripts, docs, and patch. `.gitignore` uses an allowlist so source downloads, logs, output APKs, caches, and local signing settings are excluded by default. Review `git ls-files` before every push. Do not force-add ignored files. Do not create releases with APK assets or upload build directories.

The standard distributable is GitHub's automatically generated **source ZIP of this small builder repository**. A local `git archive` of its commit is also suitable; do not ZIP the entire working folder after running a build.

## Changing the nightly

1. Identify the newest published release at `https://git.eden-emu.dev/eden-ci/nightly/releases` (or its Forgejo API). Use the release's source commit, not the releases repository's own commit and not a moving master branch.
2. Resolve the complete commit in Eden's mirror. Download its archive directly from upstream and calculate its SHA-256. Update the source revision, URL, archive checksum, and nightly details in `builder.json` together.
3. Review the loader and patch compiler. Check the patch against pristine source and preserve offset, bounds, patch ordering, and fallback behavior. Never ignore failed hunks.
4. Check upstream Gradle's Java, SDK, NDK, CMake, and build-tools requirements. Update tool pins/checksums as needed. The current script expects the current mainline Android build layout; branding edits deliberately fail if their expected source text changes.
5. Run `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build.ps1 -PrepareOnly` to verify setup/patching, then run the normal builder. Inspect the output metadata and test both unmodded and modded startup on a device. Keep the last working APK locally.

The source archive is expanded into a revision-specific folder. An existing prepared folder is checked with reverse patch validation on reruns. Changing the patch for the same source revision requires a new data directory or manually archiving the old prepared source; the builder will not silently overwrite it.

## Local-only settings

`local.settings.json` is optional and ignored. A `dataRoot` property can select an existing absolute data directory containing `build-tools`, `downloads`, and `signing`. `expectedCertificate` can pin the lowercase SHA-256 hash of an existing signing certificate; the build stops if it does not match. The `-DataRoot` PowerShell parameter overrides the local setting.

To reuse an existing signing identity, put its keystore in `<dataRoot>\signing\edennova.keystore` and create `<dataRoot>\signing\key.json` with `alias` and `password` properties. Keep both private. The builder expects equal key/store passwords. Restore the previous `last-version-code.txt` if available. Do not copy credentials into tracked examples or command arguments. The original private test's shared upstream debug certificate can be reused locally for that existing app; it is not a secure private release credential.

The builder's version-code floor is above the first EdenNova test APK and thereafter increases based on time and saved build history. APK verification checks the actual certificate, package, ABI, Android minimum, and version code before delivering output. A matching signer/package and higher version code establish update compatibility, but installation on a user's device remains the final test.

The output includes build-info.json, SHA-256 checksum, signature verification, and APK metadata. These are local artifacts; no remote publication occurs in the script.

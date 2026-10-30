# EdenNova local builder

Build an Android APK with an experimental fix for excessive memory use while loading `.pchtxt` executable mods in Eden. No LLM or programming knowledge is needed to run the builder.

**This repository contains a small patch and build scripts. It does not host Eden's source tree, APKs, signing keys, game files, firmware, or graphics drivers.** Eden source and build tools are downloaded from their upstream providers to your PC. Nothing is uploaded by the builder.

## Start here: Windows

You need a **64-bit Windows 10/11 PC (Intel/AMD)**, an internet connection, approximately **25 GB free disk space**, and preferably **16 GB RAM or more**. This does not build on your Android handheld. The resulting APK targets **ARM64 Android 13 or newer**.

1. On this repository's GitHub page, choose **Code -> Download ZIP**. Right-click the downloaded ZIP -> **Extract All**. Open the extracted folder. Do not run it from inside the ZIP viewer.
2. Double-click **Build EdenNova.cmd**. Read the setup notice and press a key. The script downloads the pinned source and portable tools, applies the patch, and builds the app. No Android Studio or administrator installation is required. Keep the window open; the first build can take **30-60 minutes or longer**. Later runs reuse downloaded tools and build files.
3. When it says **SUCCESS**, the **output** folder opens. Transfer its `.apk` to your handheld and open it to install **EdenNova**. Complete EdenNova setup with your own files and driver. It is separate from official Eden and will not automatically inherit its data.

The script uses Windows PowerShell only for this process; it does not change your system's execution policy. It downloads Java, Portable Git, Android command-line tools/SDK/NDK/CMake, and glslang. Bootstrap downloads have pinned checksums. Gradle and Eden's own dependency manager then fetch their dependencies. Android SDK setup accepts Google's SDK license; read the [Android SDK terms](https://developer.android.com/studio/terms) before starting.

## Which nightly does this build?

**Eden Nightly - Oct 18 2026**, revision `de7e6e01d43e8cf2ec193d74fa053b0d7949955f`.

This was the latest published nightly checked on October 29, 2026. The builder deliberately pins that revision, rather than silently applying a patch to future source changes. Its memory-loader files match the revision used for the original successful Dread test, and the patch applies cleanly. A successful build is not a claim that every game/mod works.

- [Official nightly release](https://git.eden-emu.dev/eden-ci/nightly/releases/tag/v1792353251.de7e6e01d4)
- [Official source repository](https://git.eden-emu.dev/eden-emu/eden)
- [Exact source ZIP from Eden's GitHub mirror](https://github.com/eden-emulator/mirror/archive/de7e6e01d43e8cf2ec193d74fa053b0d7949955f.zip)

**You normally do not need to download source yourself.** If automatic source download fails, open the exact source ZIP link above, create a `source-download` folder next to `Build EdenNova.cmd`, and save the ZIP there as **eden-nightly.zip**. Do not extract that ZIP. Rerun the builder. It verifies the archive checksum, so a different release, the moving `master` archive, or a differently packaged archive will not be accepted.

## Installing future updates without losing data

The APK uses package name `dev.eden.edennova`. The builder creates a **local signing key on your first run**, reuses it afterward, and increases the Android version code with each successful build. Updates made with that same key should install over your existing local build. The script verifies the APK signature, package name, version code, label, and ARM64/API 33 compatibility before putting it in `output`.

**Back up the entire `.local/signing` folder privately**, including `edennova.keystore` and `key.json`. The latter holds the key's local password. If you lose the key or build on another PC without restoring it, Android will reject the APK as an update. Never commit or share the signing folder. Moving the builder folder should include `.local` if you want to preserve the key and caches.

**Already using an EdenNova APK someone else built?** A fresh key cannot update it, even with the same app name. Obtain/restore the signing setup for that build from its builder before replacing anything. Do not uninstall an existing working app just to bypass a signing mismatch. The original private October 10 test used upstream's shared debug certificate; that is not a private production signing identity. This public builder generates an individual key for new users instead.

## Test the fix

For Metroid Dread: use the correct **2.1.0 game update** and matching original **4:3 `.pchtxt`**. First check unmodded startup, then enable only that patch. Keep NSO dumping off and the binary IPS/IPS32 diagnostic and FPS mods disabled for the first comparison. The fast path applies to text-only patch sets; matched binary IPS patches use the original loader.

A log line beginning **`Patched module main in place`** confirms that the new loader ran. The original private test launched Dread with correct 4:3 proportions on an 8 GB Retroid Pocket Nova using its default Qualcomm driver. The matching upstream nightly failed during modded startup. See [the mechanism and limits](docs/MEMORY-FIX.md).

## If something stops

- Read the last message in the window. The full transcript is in **logs**. Do not post logs without checking them for personal file paths or other private details.
- Internet failures: reconnect and run again. If the message says a **cached download has the wrong hash**, move only the named download aside and retry. Do not bypass checksum checks.
- A source or patch mismatch intentionally stops the build. Use the pinned source ZIP above. Don't force a patch onto another revision.
- Windows may block files downloaded from the internet. Review the scripts first. If you trust this repository, right-click the downloaded builder ZIP -> **Properties -> Unblock**, then extract it again. Do not disable antivirus globally.
- Keep the folder on a local drive, not inside a ZIP, network share, or a cloud-synced folder. Short local paths are simplest. The builder temporarily maps a free drive letter to avoid Windows compiler path limits and removes mappings it creates when it exits normally.
- Build out of memory: close memory-heavy apps and retry. The builder uses four parallel jobs by default.
- APK rejected as an update: compare **output/build-info.json** with the previous build. The package and signing certificate must match, and the version code must increase. Preserve the current app and saves.

## Project scope

Unofficial and not affiliated with Eden or Nintendo. The patch and builder were developed with AI assistance. This is a local-build utility, not an upstream contribution or an APK distribution service. The patch includes limited upstream context needed to apply the changes; it is not a full source mirror. No legal immunity is claimed by distributing a patch instead of a complete emulator.

Licensed GPL-3.0-or-later. Eden and downloaded tools retain their own licenses. No GitHub Actions build or upload workflow is included. See [maintenance notes](docs/MAINTAINING.md) for updating the pinned revision and packaging only the public files.

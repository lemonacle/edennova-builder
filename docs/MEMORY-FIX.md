# Executable text-patch memory fix

Eden's NSO loader expands the module to include BSS (zero-initialized data) before applying executable mods. The original route constructs a header-plus-module image, copies it through the patch manager and virtual file wrapper, and reads another writable copy in the text-patch compiler. Several allocations scale with the expanded module size, even when the mod changes only a few bytes.

The original Dread test logged a module size of **1,923,190,784 bytes (1.79 GiB)** for a two-record, eight-byte 4:3 patch. Earlier Android exit history recorded repeated LOW_MEMORY terminations. Those history values are snapshots, not measurements of peak allocation or exact savings.

The patch adds a text-only path that writes enabled records into the already allocated module body. It keeps existing build-ID selection, disabled-mod handling, and mod ordering. It parses selected patches before mutation, translates NSO-header-relative offsets, discards header-only changes, preserves the body portion of header-straddling writes, and clips writes to the module bounds. BSS remains valid patchable memory. Existing record iteration order is retained.

If any matching patch is binary IPS, or NSO dumping is enabled, the original path is used. This prototype does not optimize binary IPS, shrink the normal game allocation, or change graphics drivers. It still parses patch metadata; "no image copies" describes the full executable-image copies avoided by this path, not zero allocations anywhere in Eden.

Validation of the original private version included 10,000 randomized helper comparisons and boundary cases, full Android compilation, APK signature verification, and a user test on an 8 GB Retroid Pocket Nova. The working log confirms in-place patch application and subsequent game execution. The user confirmed correct proportions and intentional exit through Eden's menu. The exit-time panic/assertion is not evidence of an unprompted gameplay crash. Long-term stability, other titles, mixed-patch fallback at runtime, and exact peak RAM reduction have not been established.

The October 18 nightly's five affected existing source files are byte-identical to their October 8 counterparts. The existing patch passes a clean application check. The two upstream revisions can still differ elsewhere. On October 29, Shawn confirmed that the updated APK built from the October 18 nightly works on his Retroid Pocket Nova. This is a single-device confirmation, not a broader compatibility or stability test.

Relevant source files: `src/core/loader/nso.cpp`, `src/core/file_sys/patch_manager.{cpp,h}`, and `src/core/file_sys/ips_layer.{cpp,h}`. The patch also adds `src/core/file_sys/module_patch_write.h`.

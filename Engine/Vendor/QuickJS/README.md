# QuickJS-ng, vendored

The JavaScript engine behind `Sources/Sandbox`, built as the SwiftPM C target `CQuickJS`.

- Source: https://github.com/quickjs-ng/quickjs
- Tag: `v0.18.0` (commit `d7215b0ad3fc2c562e8317fd9bca058fd4863804`, 2026-11-01)
- License: MIT, in `LICENSE` (QuickJS by Fabrice Bellard and Charlie Gordon, QuickJS-ng by its contributors)

Only the engine library is here: `quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`, and the headers they
include, with the public `quickjs.h` in `include/`. Left out on purpose: `quickjs-libc.c` (the `std` and `os`
modules, so a look gets no file, network, timer, or process access), the `qjs` and `qjsc` command line tools,
the REPL, tests, and the build files. The files are copied unmodified. `Package.swift` defines `_GNU_SOURCE`,
as upstream's CMake build does.

To update: clone the new tag, copy the same files over these (add any new header that `quickjs.c` includes),
update the tag and commit above, then run `Engine/scripts/check`. Step counts can change between releases, so
re-check the budgets in `Sources/Sandbox/Sandbox.swift` against the fixtures.

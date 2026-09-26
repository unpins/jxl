# Changelog

## [Unreleased]

## [0.11.2-2] - 2026-09-26

### Fixed

- **Linux and Windows now read and write OpenEXR, which only macOS could.** The
  same binary silently had two different feature sets: `cjxl in.exr out.jxl`
  worked on a Mac and answered "Getting pixel data failed" everywhere else.
  Linux had EXR turned off deliberately, Windows lost it by accident — the
  OpenEXR dependency is dropped for the mingw cross, so CMake found nothing and
  disabled the format without a word, while the binary still carried the
  `libopenjph` that exists only to satisfy OpenEXR.
- README: a program is selected with `--unpin-program=<tool>`, not as a
  positional argument. `unpin jxl cjxl in.png out.jxl` and
  `./result/bin/cjxl` (the binary is `bin/jxl`) never worked.

### Added

- Every build now encodes, decodes and inspects a real image before it is
  accepted, on every target the builder can run: a JPEG must survive
  `cjxl` → `djxl` bit-for-bit, `-d 0` must be lossless on the pixels, and both
  round trips are repeated through stdin/stdout. Until now the build only
  checked that `cjxl --version` printed something.

## [0.11.2-1] - 2026-06-06

Initial release: libjxl 0.11.2's `cjxl`, `djxl` and `jxlinfo` in a single
self-contained binary, with `cjxl.1` and `djxl.1` embedded.

Nine targets: Linux x86_64 / i686 / aarch64 / armv7l / ppc64le / riscv64,
macOS x86_64 / aarch64, and Windows x86_64.

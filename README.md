# jxl

Standalone build of the [libjxl](https://github.com/libjxl/libjxl) command-line programs for the [JPEG XL](https://jpegxl.info/) image format.

[![CI](https://github.com/unpins/jxl/actions/workflows/jxl.yml/badge.svg)](https://github.com/unpins/jxl/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin jxl cjxl input.png output.jxl
unpin jxl djxl output.jxl roundtrip.png
```

To install the programs onto your PATH:

```bash
unpin install jxl
```

`unpin install jxl` creates the `cjxl`, `djxl`, and `jxlinfo` commands.

## Programs

| command | what it does |
| --- | --- |
| `cjxl` | encode to JPEG XL |
| `djxl` | decode JPEG XL |
| `jxlinfo` | inspect a JPEG XL file |

## Build locally

```bash
nix build github:unpins/jxl
./result/bin/cjxl input.png output.jxl
./result/bin/djxl output.jxl roundtrip.png
```

Or run directly:

```bash
nix run github:unpins/jxl -- cjxl input.png output.jxl
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Man pages

`cjxl.1` and `djxl.1` are embedded in the binary — read with `unpin man jxl <tool>`. `jxlinfo` has no upstream man page.

## Manual download

The [Releases](https://github.com/unpins/jxl/releases) page has standalone binaries for manual download.

## Build notes

- **Multicall:** one binary at `bin/jxl` carries all three tools; `cjxl` / `djxl` / `jxlinfo` are dispatched by `argv[0]`. Invoke the bare binary as `jxl <tool> [args]` too.
- **Formats:** reads/writes PNG, JPEG, GIF, PPM/PGM and PFM alongside `.jxl`; lossless JPEG transcoding via [brotli](https://github.com/google/brotli).
- **Windows:** `mingw` cross, single `.exe`, no companion DLLs.
- **macOS:** static `.a` core (libjxl/highway/lcms2) linked in; only system frameworks/libSystem stay dynamic.

The library chain (`libjxl`, `highway`, `brotli`, `lcms2`, …) is the same one wired up for [chafa](https://github.com/unpins/chafa) in [`nix-lib/native-overlay`](https://github.com/unpins/nix-lib/tree/main/native-overlay); here the tools are turned back on and post-linked into the multicall binary.

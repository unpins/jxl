# jxl

The [libjxl](https://github.com/libjxl/libjxl) command-line programs for the [JPEG XL](https://jpegxl.info/) image format, as a single self-contained binary built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/jxl/actions/workflows/jxl.yml/badge.svg)](https://github.com/unpins/jxl/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install jxl`.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin jxl cjxl input.png output.jxl
unpin jxl djxl output.jxl roundtrip.png
```

`unpin install jxl` also creates the commands `cjxl` (encode), `djxl` (decode) and `jxlinfo` (inspect):

```bash
unpin install jxl
```

## Man pages

`cjxl.1` and `djxl.1` are embedded in the binary — read with `unpin man jxl <tool>`. `jxlinfo` has no upstream man page.

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

## Manual download

The [Releases](https://github.com/unpins/jxl/releases) page has standalone binaries for manual download.

## Build notes

- **Multicall:** one binary at `bin/jxl` carries all three tools, dispatched by `argv[0]`; the bare binary also takes the tool as its first arg (`jxl cjxl …`).
- **Formats:** reads/writes PNG, JPEG, GIF, PPM/PGM and PFM alongside `.jxl`; lossless JPEG transcoding via [brotli](https://github.com/google/brotli).
- **Windows:** `mingw` cross, single `.exe`, no companion DLLs.
- **macOS:** static `.a` core (libjxl/highway/lcms2) linked in; only system frameworks/libSystem stay dynamic.

The library chain (`libjxl`, `highway`, `brotli`, `lcms2`, …) is the same one wired up for [chafa](https://github.com/unpins/chafa) in [`nix-lib/native-overlay`](https://github.com/unpins/nix-lib/tree/main/native-overlay); here the tools are turned back on and post-linked into the multicall binary.

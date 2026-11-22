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
unpin jxl --unpin-program=cjxl input.png output.jxl
unpin jxl --unpin-program=djxl output.jxl roundtrip.png
```

Or install them and call each by name, which is usually what you want:

```bash
unpin install jxl
cjxl input.png output.jxl
```

`unpin install jxl` creates the `cjxl`, `djxl`, `jxlinfo` and `benchmark_xl` commands.

## Programs

| command | what it does |
| --- | --- |
| `cjxl` | encode PNG/JPEG/GIF/PPM/PFM/EXR/… → JPEG XL |
| `djxl` | decode JPEG XL → PNG/JPEG/PPM/PFM/EXR/… |
| `jxlinfo` | print a `.jxl` file's size, bit depth and colour space |
| `benchmark_xl` | measure encode/decode speed and quality on a set of images |

## Man pages

`cjxl.1` and `djxl.1` are embedded in the binary — read with `unpin man jxl <tool>`. `jxlinfo` and `benchmark_xl` have no upstream man page.

## Build locally

```bash
nix build github:unpins/jxl
./result/bin/jxl --unpin-program=cjxl input.png output.jxl
./result/bin/jxl --unpin-program=djxl output.jxl roundtrip.png
```

Or run directly:

```bash
nix run github:unpins/jxl -- --unpin-program=cjxl input.png output.jxl
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/jxl/releases) page has standalone binaries for manual download.

## Build notes

- One binary at `bin/jxl` carries all four programs. `unpin install jxl` puts
  them on your PATH; from the bare binary, pick one with
  `--unpin-program=<tool>`. It is not a positional argument.
- **Formats:** PNG/APNG, JPEG, GIF, PPM/PNM/PGX/PAM, PFM and OpenEXR alongside
  `.jxl` — the same set on every platform. A JPEG can be transcoded to `.jxl`
  and back bit-for-bit, via [brotli](https://github.com/google/brotli).
- Where the build can run the result, it encodes, decodes and inspects a real
  image before it is accepted: a JPEG has to survive the round trip
  byte-for-byte, and `-d 0` has to be lossless on the pixels.
- **Tests:** libjxl's own test suite runs on the native Linux builds (except
  i686) and on Apple Silicon, as in nixpkgs, which leaves it off for i686 and
  Intel macOS. The cross targets and Windows only build.
- **Windows:** built with mingw-w64.

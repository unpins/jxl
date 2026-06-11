{
  description = "the JPEG XL tools (cjxl / djxl / jxlinfo) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # libjxl ships its CLI tools (cjxl / djxl / jxlinfo) under JPEGXL_ENABLE_TOOLS.
  # The shared nix-lib overlay used by chafa builds the library tools-off (chafa
  # just wants libjxl.a to read JXL); here we turn the tools back on and
  # post-link them into a single `jxl` binary (multicall.nix). The brotli /
  # highway / lcms2 deps + the PNG/JPEG/GIF image readers are the SAME ones
  # chafa proved across all nine targets, so they are cache hits.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # Curated man set: cjxl + djxl (jxlinfo ships no man page upstream).
      # libjxl renders these from doc/man/*.txt; the shared overlay turns
      # JPEGXL_ENABLE_MANPAGES off to keep the doc toolchain out of the heavy
      # codec build, so we render them in this tiny sidecar instead. We use
      # `asciidoctor` (Ruby), NOT upstream's a2x (`asciidoc`, Python): the pinned
      # nixpkgs marks python3 broken on x86_64-darwin, so an asciidoc sidecar
      # fails to *evaluate* on the Mac native build. asciidoctor is a
      # `nativeBuildInput` → spliced to the BUILD host (x86_64 for the pkgsCross
      # targets, native aarch64/darwin otherwise), never cross-compiled or
      # emulated, and its output is reproducible (SOURCE_DATE_EPOCH pins the
      # date), so all platforms embed byte-identical man. Installed into
      # $out/share/man on EVERY target (native AND windows) so each build
      # harvests its OWN man via withMan — no graft.
      jxlMan = pkgs: pkgs.runCommand "jxl-man" { nativeBuildInputs = [ pkgs.asciidoctor ]; } ''
        mkdir -p $out/share/man/man1
        for t in cjxl djxl; do
          asciidoctor -b manpage -o $out/share/man/man1/$t.1 ${pkgs.libjxl.src}/doc/man/$t.txt
        done
      '';
      # Install the rendered cjxl/djxl man into a built drv's $out. Shared by
      # the native and windows builds; `jxlMan pkgs` renders on the build host.
      withJxlMan = pkgs: drv: drv.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          mkdir -p "$out/share/man/man1"
          install -m644 ${jxlMan pkgs}/share/man/man1/cjxl.1 \
            ${jxlMan pkgs}/share/man/man1/djxl.1 "$out/share/man/man1/"
        '';
      });

      # libjxl with tools ON, on a (static) pkgs scope. The shared nix-lib
      # overlay (`nativeFixes.libjxl`, the one chafa consumes) already does the
      # hard parts: plugins off (the gdk-pixbuf loader is a shared module that
      # can't link under musl-static), examples/doxygen/manpages/benchmark off,
      # gperftools dropped (benchmark-only, fails on ppc64le/mingw), and the
      # darwin FindThreads/FindAtomics cache pre-seed. It builds tools off,
      # though — so we apply it and flip just the tools gate back on, keeping
      # jpegli/devtools off so the build is exactly cjxl/djxl/jxlinfo. Without
      # the overlay the vanilla examples (encode_oneshot) fail the static
      # brotli link, and plugins would try to build a shared loader.
      mkJxlTools = scope:
        let
          lib = scope.lib;
          host = scope.stdenv.hostPlatform;
          # riscv64: libjpeg-turbo's `simdcoverage` helper references RVV
          # `jsimd_can_*` entry points the RISC-V Vector port doesn't declare,
          # so the build aborts with -Wimplicit-function-declaration. The shared
          # overlay drops that unused dispatch-coverage target (the RVV SIMD code
          # in libjpeg.a is untouched). Identity off riscv, so other arches keep
          # the cache-hit libjpeg. (Same fix avif applies via find_package JPEG.)
          p = scope.extend (final: prev:
            lib.optionalAttrs host.isRiscV {
              libjpeg = ulib.nativeFixes."libjpeg-turbo" prev;
            });
          # With plugins off, gdk-pixbuf is dead weight (it only feeds the GDK
          # loader module we disabled), and the make-shell-wrapper-hook it drags
          # in splices to a shell that can't cross-compile. The shared overlay
          # only drops these on mingw (to keep the native/darwin chafa cache);
          # since our tools build rebuilds libjxl anyway, drop them everywhere —
          # otherwise darwin pulls gdk-pixbuf → glib-static, which fails to link.
          dropUnused = lib.filter
            (x: !(builtins.elem (x.pname or x.name or "")
              [ "gdk-pixbuf" "make-shell-wrapper-hook" ]));
          # mingw: the shared overlay drops the format readers (png/jpeg/gif) as
          # dead weight for chafa's decode-only libjxl, and omits winpthreads.
          # The tools need them back: winpthreads resolves jxl_threads' bare
          # `-lpthread`, and the readers give cjxl PNG/JPEG input (incl. lossless
          # JPEG→JXL transcode) + GIF, and djxl PNG output — parity with the
          # native/darwin tools. All three cross fine on mingw (chafa ships them,
          # so they are cache hits).
          mingwExtra = lib.optionals host.isMinGW [
            p.windows.pthreads
            p.windows.mcfgthreads
            p.libpng
            p.libjpeg
            p.giflib
          ];
        in
        (ulib.nativeFixes.libjxl p).overrideAttrs (old: {
          pname = "jxl-tools";
          # gdk-pixbuf rides in nativeBuildInputs AND (propagated)buildInputs;
          # filter all three (pkgsStatic auto-promotes buildInputs to
          # propagated, so a drop from one list alone leaves the other —
          # see [[feedback_pkgsstatic_propagated_buildinputs]]).
          nativeBuildInputs = dropUnused (old.nativeBuildInputs or [ ]);
          # OpenEXR 3.4 (nixpkgs 26.05) added HT (HTJ2K) compression via
          # OpenJPH, so libOpenEXRCore.a references `ojph::…`. cjxl links
          # OpenEXR for .exr I/O, so the static link now needs libopenjph — but
          # OpenEXR's exported cmake/pc deps don't carry it, so cjxl fails with
          # undefined `ojph::codestream::…`. buildInputs adds openjph's -L (it's
          # already built as OpenEXR's own dep, no new cross build); the actual
          # `-lopenjph` comes via NIX_LDFLAGS below. See
          # [[feedback_openexr34_openjph_static_link]].
          buildInputs = dropUnused (old.buildInputs or [ ]) ++ mingwExtra
            ++ [ p.openjph ];
          propagatedBuildInputs = dropUnused (old.propagatedBuildInputs or [ ]);
          # cc-wrapper appends NIX_LDFLAGS at the END of the link, AFTER the
          # cmake-listed libs (incl. libOpenEXRCore.a), so `-lopenjph` here lands
          # in the right order to resolve OpenEXR's ojph refs. Same drv re-runs
          # the multicall fold, so it inherits this too.
          NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -lopenjph";
          # Drop the overlay's `-DJPEGXL_ENABLE_TOOLS=OFF`, turn it on, and pin
          # the adjacent gates off so only cjxl/djxl/jxlinfo are built (jpegli
          # would add cjpegli/djpegli + a hard libjpeg dep; devtools adds a
          # dozen research binaries). benchmark/examples/manpages stay off from
          # the overlay.
          #
          # darwin: also drop `-DJPEGXL_STATIC=ON`. Under it libjxl appends a
          # bare `-static` to CMAKE_EXE_LINKER_FLAGS guarded only by `NOT MSVC`
          # (CMakeLists.txt), so it leaks onto Apple ld, which has no static
          # libc++/libSystem → the tool link dies with `library not found for
          # -lc++`. pkgsStatic still passes `-DBUILD_SHARED_LIBS=OFF`, so the
          # libs stay `.a`; the only things JPEGXL_STATIC adds on darwin are that
          # broken `-static` plus an `-static-libstdc++`/whole-archive pair
          # already guarded off for APPLE. multicall.nix folds libc++ in
          # statically for the final binary via extraLinkFlags.
          cmakeFlags =
            let
              drop = f:
                lib.hasPrefix "-DJPEGXL_ENABLE_TOOLS=" f
                || (host.isDarwin && lib.hasPrefix "-DJPEGXL_STATIC=" f);
            in
            (lib.filter (f: !(drop f)) (old.cmakeFlags or [ ]))
            ++ [
              "-DJPEGXL_ENABLE_TOOLS=ON"
              "-DJPEGXL_ENABLE_JPEGLI=OFF"
              "-DJPEGXL_ENABLE_DEVTOOLS=OFF"
            ];
          # The library-install postInstall (pkg-config/cmake export plumbing)
          # is irrelevant — multicall.nix only consumes the build-tree objects +
          # cjxl's link.txt.
          postInstall = "";
          doCheck = false;
        });

      mk = pkgs: scope: extra:
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          ({ pkgs = scope; libjxlTools = mkJxlTools scope; } // extra);
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "jxl";
      # Embed cjxl/djxl man on every platform: both the native and windows
      # builds install the rendered pages into $out/share/man (withJxlMan), so
      # each harvests its OWN man — no graft.
      # Multicall: `jxl <applet> [args]` dispatches by argv[0]; the bare binary
      # takes the applet as its first arg. Smoke through that form.
      smoke = [ "cjxl" "--version" ];
      smokePattern = "cjxl";

      # Linux pkgsStatic links libstdc++ statically already. darwin: the C++
      # core (libjxl/hwy) pulls `-lc++` → /usr/lib/libc++.1.dylib, which the
      # unpins darwin allowlist rejects; fold libc++ in statically (same branch
      # as avif/vpx/srt/x265/chafa).
      build = pkgs:
        let sp = pkgs.pkgsStatic; in
        withJxlMan pkgs
          (mk pkgs sp (pkgs.lib.optionalAttrs sp.stdenv.hostPlatform.isDarwin {
            extraLinkFlags = "-nostdlib++ ${sp.libcxx}/lib/libc++.a ${sp.libcxx}/lib/libc++abi.a";
          }));

      # mingw cross: -static* folds libgcc/libstdc++ into the .exe so no
      # libstdc++-6 / libgcc_s / libwinpthread DLLs ride alongside. libstdc++
      # here uses the `mcf` thread model, so std::thread (jxl_threads) pulls
      # libmcfgthread — and JPEGXL_STATIC's mingw `link_libraries(… -Wl,-Bdynamic)`
      # resets to dynamic before the driver's implicit `-lmcfgthread`, importing
      # libmcfgthread-2.dll. Force its static archive (mcfgthreads is on the link
      # path via mingwExtra) so the runtime stays inside the .exe.
      windowsBuild = pkgs:
        let cross = ulib.mingwStaticCross pkgs; in
        withJxlMan pkgs (mk pkgs cross {
          extraLinkFlags = "-static -static-libgcc -static-libstdc++ -Wl,-Bstatic -lmcfgthread -Wl,-Bdynamic";
        });
    };
}

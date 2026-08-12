{
  description = "the JPEG XL tools (cjxl / djxl / jxlinfo) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # libjxl ships its CLI tools (cjxl / djxl / jxlinfo) under JPEGXL_ENABLE_TOOLS.
  # The shared nix-lib overlay used by chafa builds the library tools-off (chafa
  # just wants libjxl.a to read JXL); here we turn the tools back on and let the
  # engine self-fold them into a single `jxl` binary. The brotli /
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
      # `eng` ({ lto; elf; }) is the PER-PACKAGE stdenv swap the native path
      # needs: its engine scope is pkgsStatic, where libjxl's tools would
      # otherwise link the SYSTEM highway (libhwy — a C++ SIMD lib built
      # gcc/libstdc++ by default), the tier-2 wall. Rebuild libhwy with the
      # engine (→ libc++) like avif's codec libs; libjxl itself gets the LTO
      # stdenv (bitcode apps for the self-fold). The other deps
      # (brotli/lcms2/png/jpeg/giflib) are C → stay gcc.
      #
      # It stays null on the mingw cross, and that is NOT "no engine": there
      # multicall.windows = true swaps the whole set onto the engine adapter, so
      # every dep — libhwy included — is already libc++ with no per-package
      # override to add. Nothing below may read `eng != null` as "is this the
      # engine"; the two gates that could are keyed on the platform instead.
      mkJxlTools = eng: scope:
        let
          lib = scope.lib;
          host = scope.stdenv.hostPlatform;
          # cjxl's optional .exr I/O. It builds clean under the engine — OpenEXR
          # rides the set-wide stdenv swap, so it is libc++ like everything else
          # (measured on x86_64-linux). darwin and windows therefore keep EXR;
          # linux has it OFF only because turning it back on would move five
          # already-green targets, incl. the ppc64le/riscv64/armv7l crosses, for
          # a niche HDR format — not worth the re-validation. Keyed on the host,
          # not on `eng`, so the mingw cross (engine, `eng` null) keeps EXR.
          noExr = host.isLinux;
          p = scope.extend (final: prev:
            lib.optionalAttrs (eng != null) {
              # Engine-rebuilt libhwy: libjxl only needs libhwy.a, but nixpkgs'
              # libhwy also builds its TEST binaries (HWY_SYSTEM_GTEST=ON), which
              # link the gcc/libstdc++ gtest against engine-libc++ libhwy → the
              # tier-2 wall, inside libhwy's own build. Disable tests/examples;
              # libhwy.a itself builds clean.
              libhwy = (prev.libhwy.override { stdenv = eng.elf; }).overrideAttrs (o: {
                cmakeFlags = (o.cmakeFlags or [ ]) ++ [
                  "-DHWY_ENABLE_TESTS=OFF"
                  "-DHWY_ENABLE_EXAMPLES=OFF"
                  "-DBUILD_TESTING=OFF"
                ];
                doCheck = false;
              });
              libjxl = prev.libjxl.override { stdenv = eng.lto; };
            } // lib.optionalAttrs (eng != null && host.isx86_32) {
              # libjxl links its tools PIE (CMakeLists.txt sets
              # CMAKE_POSITION_INDEPENDENT_CODE after CheckPIESupported), and the
              # unpin driver honours that -pie by emitting a static-PIE — where
              # gcc's `-static -pie` collapsed back to plain static, hiding this.
              # On i386 (only) libjpeg-turbo's NASM SIMD is absolute-addressed
              # unless built PIC, so the PIE link fails on R_386_32. The asm has
              # a PIC path (simd/CMakeLists.txt adds -DPIC); turn it on rather
              # than drop either the SIMD or the PIE.
              libjpeg = prev.libjpeg.overrideAttrs (o: {
                cmakeFlags = (o.cmakeFlags or [ ])
                  ++ [ "-DCMAKE_POSITION_INDEPENDENT_CODE=ON" ];
              });
            });
          # With plugins off, gdk-pixbuf is dead weight (it only feeds the GDK
          # loader module we disabled), and the make-shell-wrapper-hook it drags
          # in splices to a shell that can't cross-compile. The shared overlay
          # only drops these on mingw (to keep the native/darwin chafa cache);
          # since our tools build rebuilds libjxl anyway, drop them everywhere —
          # otherwise darwin pulls gdk-pixbuf → glib-static, which fails to link.
          dropUnused = lib.filter
            (x: !(builtins.elem (x.pname or x.name or "")
              ([ "gdk-pixbuf" "make-shell-wrapper-hook" ]
                # linux: EXR is off (JPEGXL_ENABLE_OPENEXR=OFF below), so drop
                # OpenEXR + its imath helper. darwin and windows keep EXR.
                ++ lib.optionals noExr [ "openexr" "imath" ])));
          # mingw: the shared overlay drops the format readers (png/jpeg/gif) as
          # dead weight for chafa's decode-only libjxl, and omits winpthreads.
          # The tools need them back: winpthreads resolves jxl_threads' bare
          # `-lpthread`, and the readers give cjxl PNG/JPEG input (incl. lossless
          # JPEG→JXL transcode) + GIF, and djxl PNG output — parity with the
          # native/darwin tools. All three cross fine on mingw (chafa ships them,
          # so they are cache hits).
          #
          # mcfgthreads used to ride along here: libstdc++'s mingw build uses the
          # `mcf` thread model, so std::thread pulled -lmcfgthread and the fold
          # forced its static archive to keep libmcfgthread-2.dll out. The engine
          # links libc++ from the unpin sysroot and no libstdc++ at all, so
          # nothing references it anymore.
          mingwExtra = lib.optionals host.isMinGW [
            p.windows.pthreads
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
          # openjph (+ -lopenjph below) only exists to satisfy OpenEXR's HTJ2K
          # refs, so it rides along wherever EXR does.
          buildInputs = dropUnused (old.buildInputs or [ ]) ++ mingwExtra
            ++ lib.optional (!noExr) p.openjph;
          propagatedBuildInputs = dropUnused (old.propagatedBuildInputs or [ ]);
          # cc-wrapper appends NIX_LDFLAGS at the END of the link, AFTER the
          # cmake-listed libs (incl. libOpenEXRCore.a), so `-lopenjph` here lands
          # in the right order to resolve OpenEXR's ojph refs. Same drv re-runs
          # the multicall fold, so it inherits this too.
          NIX_LDFLAGS = (old.NIX_LDFLAGS or "")
            + lib.optionalString (!noExr) " -lopenjph";
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
          # already guarded off for APPLE. requires.cxx folds libc++ in
          # statically for the final binary.
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
            ]
            ++ lib.optional noExr "-DJPEGXL_ENABLE_OPENEXR=OFF";
          # mingw: under JPEGXL_STATIC libjxl force-feeds every target
          # `-Wl,-Bstatic -lstdc++ -lpthread -Wl,-Bdynamic`, and the engine links
          # libc++ — there is no libstdc++ to find ("unable to find library
          # -lstdc++"). The block exists only to defeat a GNU coupling: mingw's
          # libstdc++ calls pthreads itself, so a static libstdc++ paired with a
          # dynamic pthread had to be forced apart by naming -lstdc++ ahead of
          # -lpthread. libc++ has no such tie. Drop the -lstdc++ token and keep
          # the rest: -lpthread still has to be named (jxl_threads asks for a
          # bare -lpthread; winpthreads is in mingwExtra for exactly that).
          #
          # NOT the darwin treatment of dropping -DJPEGXL_STATIC entirely: on
          # mingw that flag also supplies the `-static` and the
          # CMAKE_FIND_LIBRARY_SUFFIXES=.a we want. Only this one line is wrong.
          postPatch = (old.postPatch or "") + lib.optionalString host.isMinGW ''
            substituteInPlace CMakeLists.txt \
              --replace-fail \
                'link_libraries(-Wl,-Bstatic -lstdc++ -lpthread -Wl,-Bdynamic)' \
                'link_libraries(-Wl,-Bstatic -lpthread -Wl,-Bdynamic)'
          '';
          # nixpkgs pins `CXXFLAGS = -mfp16-format=ieee` on aarch32 (gcc defaults
          # to `none`, which hides `__fp16`). clang has no such option — it is
          # always IEEE — and rejects it outright, so CMake's first try-compile
          # dies. Only the engine path sees clang; gcc still needs the flag.
          env = (old.env or { })
            // lib.optionalAttrs (eng != null && host.isAarch32) { CXXFLAGS = ""; };
          # The library-install postInstall (pkg-config/cmake export plumbing)
          # is irrelevant — the self-fold consumes the captured link sidecars and
          # the bitcode module, not the installed library.
          postInstall = "";
          doCheck = false;
        });

      # Engine path (native Linux): two unpin-llvm adapter stdenvs (lto for
      # libjxl's bitcode apps, no-lto ELF for the C++ libhwy codec).
      engStdenvs = pkgs:
        let sp = pkgs.pkgsStatic;
            mkEng = lto: ulib.unpinAdapterStdenv {
              inherit pkgs;
              target = sp.stdenv.hostPlatform.config;
              native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
              cxx = true;
              inherit lto;
              captureLinks = lto;
            };
        in { lto = mkEng true; elf = mkEng false; };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "jxl";
      # Embed cjxl/djxl man on every platform: both the native and windows
      # builds install the rendered pages into $out/share/man (withJxlMan), so
      # each harvests its OWN man — no graft.
      # Multicall: `jxl <applet> [args]` dispatches by argv[0]; the bare binary
      # takes the applet as its first arg. Smoke through that form.
      smoke = [ "--unpin-program=cjxl" "--version" ];
      smokePattern = "cjxl";

      # Engine + bitcode self-fold on every target: libjxl (tools on) → bitcode,
      # cjxl/djxl/jxlinfo self-fold into one `jxl`. C++ from libjxl + the SYSTEM
      # libhwy (libc++ under the engine); requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        programs = [
          { name = "cjxl"; }
          { name = "djxl"; }
          { name = "jxlinfo"; }
        ];
        requires.cxx = true;
      };

      # Native (pkgsStatic, Linux and darwin): libjxl's tools compile to bitcode
      # under the per-package `eng` swap and self-fold. libc++ needs no explicit
      # fold — the engine carries its own and links it statically.
      build = pkgs: withJxlMan pkgs (mkJxlTools (engStdenvs pkgs) pkgs.pkgsStatic);

      # mingw cross: `eng` is null because multicall.windows = true has already
      # swapped the whole set onto the engine adapter (see mkJxlTools).
      windowsBuild = pkgs:
        withJxlMan pkgs (mkJxlTools null (ulib.mingwStaticCross pkgs));
    };
}

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
  # engine self-fold them into a single `jxl` binary. The brotli / highway /
  # lcms2 deps and the PNG/JPEG/GIF readers come from the engine set, like
  # every other dependency.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # 8x8 RGB JPEG (quality 80), the probe the installCheck round-trips. A
      # JPEG rather than a PNG because it is the only input that also exercises
      # cjxl's lossless JPEG transcode, and decoding it gives the pixel
      # reference the rest of the check needs — one constant, both paths.
      probeJpgB64 =
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwB1nDFYtp0N1IlvbWDWkU2SRut4oHuXYjOSFZ17Y4HGcElFFc7darFTp1XC+rso7tJ/ajJ9TuwGX0sXDmqX0009Wf/Z";

      # Curated man set: cjxl + djxl (jxlinfo ships no man page upstream).
      # libjxl renders these from doc/man/*.txt; the shared overlay turns
      # JPEGXL_ENABLE_MANPAGES off to keep the doc toolchain out of the heavy
      # codec build, so we render them in this tiny sidecar instead. We use
      # `asciidoctor` (Ruby), NOT upstream's a2x (`asciidoc`, Python): nixpkgs
      # marks python3 broken for `isStatic && isDarwin`, so an asciidoc sidecar
      # in the static darwin set fails to *evaluate*. asciidoctor is a
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
          # The installCheck below runs the built tools, so it is only wired
          # where the build host can execute them (native, i686-from-x86_64 and
          # darwin; not the crosses, not mingw).
          check = scope.stdenv.buildPlatform.canExecute host;
          # libjxl's own test suite, with nixpkgs' gate: not on i686 or x86_64
          # macOS.
          doCheck = check && !(host.isi686 || host.isDarwin && host.isx86_64);
          p = scope.extend (final: prev:
            lib.optionalAttrs host.isx86_32 {
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
              [ "gdk-pixbuf" "make-shell-wrapper-hook" ]));
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
          # openexr: the overlay drops it for mingw as dead weight for chafa's
          # decode-only libjxl; the tools want it back (see the EXR note on
          # buildInputs below).
          mingwExtra = lib.optionals host.isMinGW [
            p.windows.pthreads
            p.libpng
            p.libjpeg
            p.giflib
            p.openexr
          ];
        in
        (ulib.nativeFixes.libjxl p).overrideAttrs (old: {
          pname = "jxl-tools";
          # gdk-pixbuf rides in nativeBuildInputs AND (propagated)buildInputs;
          # filter all three (pkgsStatic auto-promotes buildInputs to
          # propagated, so a drop from one list alone leaves the other —
          # see [[feedback_pkgsstatic_propagated_buildinputs]]).
          nativeBuildInputs = dropUnused (old.nativeBuildInputs or [ ]);
          # cjxl's .exr I/O is on for EVERY target. It used to be darwin-only in
          # practice: linux had it switched off to avoid re-validating five
          # green targets, and windows lost it silently — the shared overlay
          # drops openexr for the mingw cross, so CMake found nothing and
          # disabled the format without a word, while the build still carried
          # the libopenjph that exists only to serve OpenEXR. One binary, two
          # feature sets: `cjxl in.exr out.jxl` worked on a Mac and answered
          # "Getting pixel data failed" everywhere else. EXR is real HDR I/O in
          # both directions (measured: read, and write from a linear-float
          # image), so the fix is parity. Costs ~1.2 MB.
          #
          # Two libraries have to be named by hand because OpenEXR 3.4 uses them
          # and exports neither in its cmake/pc deps, so a static link fails at
          # the last step:
          #   - openjph: HT (HTJ2K) compression → undefined `ojph::codestream::…`
          #   - libdeflate: DEFLATE scanlines → undefined `libdeflate_free_compressor`
          # buildInputs supplies the -L (both are already OpenEXR's own deps, no
          # new cross build); the `-l`s come via NIX_LDFLAGS below, which the
          # cc-wrapper appends AFTER the cmake-listed libOpenEXRCore.a. Only
          # mingw actually needed libdeflate — native musl resolved it through
          # the propagated closure — but naming it everywhere costs nothing and
          # the next OpenEXR bump will not care which target noticed first. See
          # [[feedback_openexr34_openjph_static_link]].
          buildInputs = dropUnused (old.buildInputs or [ ]) ++ mingwExtra
            ++ [ p.openjph p.libdeflate ];
          propagatedBuildInputs = dropUnused (old.propagatedBuildInputs or [ ]);
          NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -lopenjph -ldeflate";
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
          # benchmark_xl is on too: nixpkgs installs it. The test suite is
          # built where it runs (doCheck below).
          cmakeFlags =
            let
              drop = f:
                lib.hasPrefix "-DJPEGXL_ENABLE_TOOLS=" f
                || lib.hasPrefix "-DJPEGXL_ENABLE_BENCHMARK=" f
                || (doCheck && lib.hasPrefix "-DBUILD_TESTING=" f)
                || (host.isDarwin && lib.hasPrefix "-DJPEGXL_STATIC=" f);
            in
            (lib.filter (f: !(drop f)) (old.cmakeFlags or [ ]))
            ++ [
              "-DJPEGXL_ENABLE_TOOLS=ON"
              "-DJPEGXL_ENABLE_BENCHMARK=ON"
              "-DJPEGXL_ENABLE_JPEGLI=OFF"
              "-DJPEGXL_ENABLE_DEVTOOLS=OFF"
            ];
          # mingw: JPEGXL_STATIC forces -lstdc++, which the engine (libc++)
          # does not have; see the patch.
          # NOT the darwin treatment of dropping -DJPEGXL_STATIC entirely: on
          # mingw that flag also supplies the `-static` and the
          # CMAKE_FIND_LIBRARY_SUFFIXES=.a we want. Only this one line is wrong.
          patches = (old.patches or [ ])
            ++ lib.optionals host.isMinGW [ ./mingw-no-libstdcxx.patch ];
          inherit doCheck;
          # `smoke` runs cjxl --version and nothing else: an encoder that lost
          # its JPEG reconstruction path, a decoder that folded onto the wrong
          # entry, or a stdio left in text mode all print that same line. Run
          # all three tools for real wherever the build host can execute them.
          #
          # One probe drives two round trips that are different code paths:
          #   - JPEG -> JXL -> JPEG must come back BIT-FOR-BIT. That is the
          #     brotli-backed reconstruction data, the one thing here a
          #     pixel comparison cannot see.
          #   - pixels -> JXL (-d 0) -> pixels must come back byte-identical.
          # Both are then repeated through stdout/stdin ('-'), the path a
          # Windows CRT left in text mode corrupts and no file argument covers,
          # and the probe finally goes out to .exr and back so a target that
          # loses OpenEXR fails the build instead of shipping a smaller feature
          # set than its siblings.
          doInstallCheck = check;
          installCheckPhase = ''
            runHook preInstallCheck
            _b="''${bin:-$out}/bin"
            echo '${probeJpgB64}' | base64 -d > p.jpg
            "$_b/cjxl" p.jpg t.jxl
            "$_b/djxl" t.jxl back.jpg
            cmp back.jpg p.jpg || {
              echo "djxl did not reconstruct the original JPEG bit-for-bit"; exit 1; }
            "$_b/djxl" t.jxl ref.ppm
            "$_b/cjxl" -d 0 ref.ppm l.jxl
            "$_b/djxl" l.jxl out.ppm
            cmp out.ppm ref.ppm || { echo "-d 0 is not lossless"; exit 1; }
            "$_b/cjxl" -d 0 ref.ppm - > s.jxl
            cmp s.jxl l.jxl || { echo "cjxl writes a different file to stdout"; exit 1; }
            "$_b/djxl" - so.ppm < l.jxl
            cmp so.ppm ref.ppm || { echo "djxl reads stdin differently"; exit 1; }
            "$_b/jxlinfo" l.jxl | grep -q '8x8' || {
              echo "jxlinfo did not report the image size"; exit 1; }
            # OpenEXR, both directions. EXR takes linear light, so the probe is
            # re-encoded with a linear transfer first; djxl then has to write a
            # real .exr and cjxl has to read it back. Without OpenEXR compiled
            # in, djxl answers "can't decode to the file extension '.exr'" and
            # cjxl "Getting pixel data failed" — which is exactly what the linux
            # and windows binaries used to do while the mac one worked.
            "$_b/cjxl" -d 0 -x color_space=RGB_D65_SRG_Rel_Lin ref.ppm lin.jxl
            "$_b/djxl" lin.jxl e.exr
            "$_b/cjxl" -d 0 e.exr rt.jxl
            echo "installCheck: cjxl/djxl/jxlinfo round-trip, JPEG reconstruction bit-exact, EXR both ways"
            runHook postInstallCheck
          '';
        });

    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "jxl";
      # Embed cjxl/djxl man on every platform: both the native and windows
      # builds install the rendered pages into $out/share/man (withJxlMan), so
      # each harvests its OWN man — no graft.
      # Multicall: the program is chosen by argv[0] (the names `unpin install`
      # puts on PATH) or by `--unpin-program=`; the bare binary lists them. It
      # does NOT take the program as a positional argument.
      #
      # The smoke is one command matched by one grep line, so it can only prove
      # that one program starts. The installCheck above is what runs all three.
      smoke = [ "--unpin-program=cjxl" "--version" ];
      smokePattern = "^cjxl v";

      # Engine + bitcode self-fold on every target: libjxl (tools on) → bitcode,
      # cjxl/djxl/jxlinfo self-fold into one `jxl`. C++ (libjxl, libhwy) links
      # the engine's libc++; requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        programs = [
          { name = "cjxl"; }
          { name = "djxl"; }
          # libjxl installs cjxl.1/djxl.1 and no jxlinfo.1 or benchmark_xl.1.
          { name = "jxlinfo"; noMan = true; }
          { name = "benchmark_xl"; noMan = true; }
        ];
        requires.cxx = true;
      };

      # Native (pkgsStatic, Linux and darwin): the engine set compiles libjxl's
      # tools to bitcode and they self-fold.
      build = pkgs: withJxlMan pkgs (mkJxlTools pkgs.pkgsStatic);

      windowsBuild = pkgs:
        withJxlMan pkgs (mkJxlTools (ulib.mingwStaticCross pkgs));
    };
}

# libjxl builds three CLI tools — cjxl (encode), djxl (decode) and jxlinfo
# (inspect) — under JPEGXL_ENABLE_TOOLS. To honour the unpins one-pkg-one-bin
# rule we post-link them into a single multicall binary at $out/bin/jxl;
# `lib.withAliases` then embeds the tool names as an UNPIN_META block so unpin's
# installer can recreate the argv[0] shims.
#
# Link mechanics (same family as avif/CMake-link.txt, vs libvpx/recursive-make,
# srt/CMake-query, rtmpdump/Makefile):
#
#   * libjxl uses the CMake "Unix Makefiles" generator (no ninja in
#     nativeBuildInputs), so every target gets a `CMakeFiles/<t>.dir/link.txt`
#     holding its exact link command — compiler, flags, object, and the full
#     lib list (libjxl.a, jxl_extras_codec, jxl_threads, jxl_tool, hwy, brotli,
#     lcms2, png/jpeg/gif/webp, zlib, …) resolved for the platform. We reuse
#     cjxl's link.txt (the encoder — it pulls the widest lib set, a superset of
#     what djxl/jxlinfo need) and splice in the other two tools' main objects +
#     the dispatcher, retargeting the output. That sidesteps re-deriving the
#     per-platform lib list by hand (the e2fsprogs landmine).
#
#   * Unlike avif, the target name != the source object name: cjxl←cjxl_main.cc,
#     djxl←djxl_main.cc, jxlinfo←jxlinfo.c. The TOOLS map below carries that.
#     cjxl/djxl are C++; jxlinfo is C — but reusing cjxl's C++ link.txt drives
#     the whole link through g++/clang++, which links the lone C object fine.
#
#   * Each tool's only strong clash is `main` (renamed per-tool below). The
#     shared tool helpers live in the static archives both pull on demand, so
#     they are not duplicated. The iterative pass is insurance against any
#     future strong clash.
#
#   * cjxl/djxl pull hwy/jxl (C++); on darwin clang++ would resolve -lc++ to
#     /usr/lib/libc++.1.dylib (forbidden by the single-binary policy);
#     `extraLinkFlags` folds the static libc++ in. On mingw `-static
#     -static-libgcc -static-libstdc++` keeps the runtime out of companion DLLs.
{ lib }:
{ pkgs, libjxlTools, name ? "jxl", extraLinkFlags ? "" }:
let
  # tool target -> main source basename (object is <src>.<oext>).
  TOOLS = [
    { tool = "cjxl"; src = "cjxl_main.cc"; }
    { tool = "djxl"; src = "djxl_main.cc"; }
    { tool = "jxlinfo"; src = "jxlinfo.c"; }
  ];
  toolsBash = lib.concatMapStringsSep " " (t: "${t.tool}:${t.src}") TOOLS;

  multicall = libjxlTools.overrideAttrs (old: {
    pname = "jxl-multi";

    # Ship only the multicall binary.
    outputs = [ "out" ];
    separateDebugInfo = false;
    postInstall = "";

    postBuild = (old.postBuild or "") + ''
      mkdir -p multicall
      printf '%s\n' ${lib.escapeShellArg toolsBash} | tr ' ' '\n' > multicall/tools.map

      # CMake names compiled objects `.o` on ELF/Mach-O but `.obj` when
      # targeting Windows (mingw). Detect from cjxl's main object.
      oext=o
      [ -n "$(find . -path '*cjxl.dir/cjxl_main.cc.obj' -print -quit)" ] && oext=obj

      # Resolve each tool's main object; existence gates a platform that ever
      # drops a tool. Record the applet list for installPhase/withAliases.
      : > multicall/apps.list
      declare -A OBJ
      while IFS=: read -r tool src; do
        [ -n "$tool" ] || continue
        obj="$(find . -path "*$tool.dir/$src.$oext" | head -1)"
        [ -n "$obj" ] || { echo "multicall: object for $tool ($src.$oext) not found" >&2; exit 1; }
        OBJ[$tool]="$obj"
        echo "$tool" >> multicall/apps.list
      done < multicall/tools.map
      [ -s multicall/apps.list ] || { echo "multicall: no tool objects found" >&2; exit 1; }

      linktxt="$(find . -path '*cjxl.dir/link.txt' | head -1)"
      [ -n "$linktxt" ] || { echo "multicall: cjxl link.txt not found (non-Makefile generator?)" >&2; exit 1; }

      # Symbol prefix (Mach-O leads C symbols with '_'), read once from cjxl.
      if $NM --defined-only "''${OBJ[cjxl]}" | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Distinct entry points: rename each tool's main → <tool>_main.
      while IFS= read -r tool; do
        $OBJCOPY --redefine-sym "''${up}main=''${up}''${tool}_main" "''${OBJ[$tool]}"
      done < multicall/apps.list

      # Dispatcher: basename(argv[0]) → <tool>_main, '.exe' stripped, plus a
      # `${name} <applet> [args]` form so the bare binary stays callable.
      {
        echo '#include <string.h>'
        echo '#include <stdio.h>'
        while IFS= read -r tool; do echo "int ''${tool}_main(int, char **);"; done < multicall/apps.list
        echo 'struct applet { const char *name; int (*fn)(int, char **); };'
        echo 'static const struct applet applets[] = {'
        while IFS= read -r tool; do echo "    {\"$tool\", ''${tool}_main},"; done < multicall/apps.list
        cat <<'CBODY'
    {0, 0}
};
static void copy_basename(char *dst, size_t cap, const char *src) {
    const char *p = src, *s;
    s = strrchr(p, '/'); if (s) p = s + 1;
#ifdef _WIN32
    s = strrchr(p, '\\'); if (s) p = s + 1;
#endif
    size_t n = strlen(p); if (n >= cap) n = cap - 1;
    memcpy(dst, p, n); dst[n] = 0;
    if (n > 4 && strcmp(dst + n - 4, ".exe") == 0) dst[n - 4] = 0;
}
CBODY
        cat <<CBODY
static int usage(const char *a0) {
    fprintf(stderr, "${name}: multicall binary; usage: %s <applet> [args]\n", a0);
    fprintf(stderr, "applets:");
    for (const struct applet *a = applets; a->name; a++)
        fprintf(stderr, " %s", a->name);
    fprintf(stderr, "\n");
    return 1;
}
int main(int argc, char **argv) {
    char base[64];
    const char *a0 = (argc > 0 && argv[0]) ? argv[0] : "${name}";
    copy_basename(base, sizeof base, a0);
    if (strcmp(base, "${name}") == 0) {
        if (argc < 2) return usage(a0);
        copy_basename(base, sizeof base, argv[1]);
        argv++; argc--;
    }
    for (const struct applet *a = applets; a->name; a++)
        if (strcmp(base, a->name) == 0) return a->fn(argc, argv);
    fprintf(stderr, "${name}: unknown applet '%s'\n", base);
    return usage(a0);
}
CBODY
      } > multicall/dispatcher.c
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Reuse cjxl's link command: splice the other tools' main objects + the
      # dispatcher in front of the output, retarget to multicall/${name}, and
      # append the runtime-folding flags. cjxl's object is already in the
      # command (renamed in place); the rest resolve <tool>_main + main.
      #
      # libjxl builds its tools under `tools/`, so cjxl's link.txt holds paths
      # relative to that subdir (CMakeFiles/cjxl.dir/…, ../lib/libjxl.a). Run
      # the link from that dir so they resolve; the objects/dispatcher/output we
      # splice in are made absolute so they survive the cd. (linkdir is `.` for
      # root-built tools like avif, so this stays a no-op generalization.)
      top="$PWD"
      linkdir="''${linktxt%/CMakeFiles/*}"
      out_bin="$top/multicall/${name}"
      disp="$top/multicall/dispatcher.o"
      extra_objs=""
      while IFS= read -r tool; do
        [ "$tool" = cjxl ] && continue
        extra_objs="$extra_objs $top/''${OBJ[$tool]#./}"
      done < multicall/apps.list
      linkbase="$(sed -E "s| -o (\"?)cjxl(\.exe)?(\"?)|$extra_objs $disp -o $out_bin|" "$linktxt") ${extraLinkFlags}"

      # Iterative link: each failed attempt names remaining strong duplicates;
      # rename those per-tool and relink. Normally converges first pass (only
      # `main`, already renamed above).
      converged=0
      for _ in $(seq 1 20); do
        if ( cd "$linkdir" && eval "$linkbase" ) 2>multicall/link.err; then converged=1; break; fi
        cat multicall/link.err >&2
        sed -nE "s/.*multiple definition of [\`']([^']+)'.*/\1/p; s/.*duplicate symbol '([^']+)'.*/\1/p" \
          multicall/link.err | sort -u > multicall/clash.syms
        [ -s multicall/clash.syms ] || { echo "multicall: link failed without a duplicate-symbol diagnostic" >&2; exit 1; }
        while IFS= read -r sym; do
          hit=0
          while IFS= read -r tool; do
            obj="''${OBJ[$tool]}"
            raw=$($NM --defined-only "$obj" | awk -v s="$sym" '$3==s {print $3; exit}')
            [ -n "$raw" ] || continue
            $OBJCOPY --redefine-sym "$raw=''${up}''${tool}__''${raw#"$up"}" "$obj"
            hit=1
          done < multicall/apps.list
          [ "$hit" = 1 ] || { echo "multicall: clashing symbol '$sym' not defined by any tool object" >&2; exit 1; }
        done < multicall/clash.syms
      done
      [ "$converged" = 1 ] || { echo "multicall: link did not converge in 20 passes" >&2; exit 1; }

      # mingw gcc may auto-append .exe; normalize to the suffixless name
      # installPhase + withAliases expect (Windows postFixup re-adds .exe).
      [ -f multicall/${name} ] || mv multicall/${name}.exe multicall/${name}
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 multicall/${name} "$out/bin/${name}"
      while IFS= read -r a; do
        [ -n "$a" ] && ln -s ${name} "$out/bin/$a"
      done < multicall/apps.list
      runHook postInstall
    '';
  });
  aliased = lib.withAliases pkgs
    {
      primary = name;
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if pkgs.stdenv.hostPlatform.isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/${name}" ] && mv "$out/bin/${name}" "$out/bin/${name}.exe"
  '';
})
else aliased

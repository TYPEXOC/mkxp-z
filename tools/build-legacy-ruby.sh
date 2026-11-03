#!/usr/bin/env bash
set -euo pipefail

version="$1"
source_repo="$2"
source_ref="$3"
artifact_dir="$4"
runner_temp="${RUNNER_TEMP:-/tmp}"
if [[ "$runner_temp" =~ ^[A-Za-z]:[\\/] ]]; then
  runner_temp=$(cygpath -u "$runner_temp")
fi
build_root="$runner_temp/mkxp-z-ruby-${version}"
source_dir="$build_root/source"

mkdir -p "$build_root" "$artifact_dir"
git clone --depth 1 --branch "$source_ref" "$source_repo" "$source_dir"
cd "$source_dir"

# These legacy branches keep configure.in in Git but do not check in configure.
autoconf

case "$version" in
  1.8.7)
    build_flags='-O2 -std=gnu89 -w'
    CFLAGS="$build_flags" ./configure \
      --build=i686-w64-mingw32 \
      --host=i686-w64-mingw32 \
      --target=i686-w64-mingw32 \
      --prefix="$artifact_dir/install" \
      --disable-shared \
      --with-static-linked-ext \
      --disable-install-doc

    # The old configure test misses const-correct MinGW declarations and then
    # redeclares these CRT functions with incompatible prototypes.
    for macro in HAVE_STRCHR HAVE_STRRCHR HAVE_STRERROR; do
      grep -q "^#define ${macro} 1$" config.h || \
        sed -i "/^#endif/i #define ${macro} 1" config.h
    done
    # Ruby 1.8's Windows GNUmakefile hard-codes shared mode, so override it
    # on the make command line to select the static-library target.
    library=libruby18.a
    ruby_stdlib_version=1.8
    ;;
  1.9.3)
    build_flags='-O2 -std=gnu99 -Wno-incompatible-pointer-types -Wno-implicit-function-declaration'
    baseruby_compat="$(cygpath -u "$GITHUB_WORKSPACE")/tools/ruby193-baseruby-compat.rb"
    baseruby_wrapper="$build_root/baseruby.sh"
    cat > "$baseruby_wrapper" <<EOF
#!/usr/bin/env bash
exec /mingw64/bin/ruby.exe -r"$baseruby_compat" "\$@"
EOF
    chmod +x "$baseruby_wrapper"

    # Bison 3.x cannot regenerate this Ruby 1.9 parser. Use the known-good
    # generated parser from the MTool compatibility fork, pinned to a commit.
    parser_base=https://raw.githubusercontent.com/zths/mkxp-z-android-mtool/dd5fe85f64d42e939d4eef33c612cd8762eb90f0/app/jni/patches/ruby193files
    curl -fsSL "$parser_base/parse.c" -o parse.c
    curl -fsSL "$parser_base/parse.h" -o parse.h
    touch parse.c parse.h

    CFLAGS="$build_flags" ./configure \
      --build=i686-w64-mingw32 \
      --host=i686-w64-mingw32 \
      --target=i686-w64-mingw32 \
      --prefix="$artifact_dir/install" \
      --disable-shared \
      --disable-install-doc \
      --with-static-linked-ext \
      --with-baseruby=/mingw64/bin/ruby.exe \
      --with-out-ext=ripper,sdbm

    # GCC 16 removed this flag. The parser/extconf probes below compensate for
    # tests in Ruby 1.9.3 that predate current MinGW headers.
    sed -i 's/  DLLWRAP += -mno-cygwin/  # obsolete with current MinGW GCC/' GNUmakefile
    config_header=$(find .ext/include -path '*/ruby/config.h' -print -quit)
    test -n "$config_header"
    for macro in HAVE_FCNTL_H HAVE_STRERROR HAVE_STRCHR HAVE_SETJMP HAVE_LONGJMP; do
      grep -q "^#define ${macro} 1$" "$config_header" || \
        sed -i "/^#endif/i #define ${macro} 1" "$config_header"
    done
    sed -i '/^#define HAVE__SETJMP 1$/d; /^#define HAVE__LONGJMP 1$/d' "$config_header"
    # Ruby's Windows compatibility layer unconditionally defines fseeko;
    # with _FILE_OFFSET_BITS=64 that becomes fseeko64 and collides with the
    # implementation supplied by current MinGW CRTs. Use the CRT version when
    # configure has confirmed it exists.
    perl -0pi -e '
      s{(int\nfseeko\(FILE \*stream, off_t offset, int whence\)\n.*?\n\}\n)(\noff_t\nrb_w32_ftello\(FILE \*stream\))}{#ifndef HAVE_FSEEKO\n$1#endif\n$2}s
        or die "Could not locate Ruby 1.9.3 fseeko compatibility function\n";
    ' win32/win32.c
    sed -i 's/\${LIBOBJDIR}strerror\.o//g; s/\${LIBOBJDIR}strchr\.o//g' Makefile
    sed -i '/\$defs << "-DHAVE_SOCKETPAIR"/d' ext/socket/extconf.rb
    library=libmsvcrt-ruby191-static.a
    ruby_stdlib_version=1.9.1
    ;;
  *)
    echo "Unsupported Ruby version: $version" >&2
    exit 2
    ;;
esac

if [[ "$version" == 1.8.7 ]]; then
  # Ruby 1.8 already compiles zlib.c into its core archive, but the default
  # dmyext.c leaves Init_zlib unregistered. Register the built-in extension
  # exactly as ext/extinit.c would, so require 'zlib' works in the host.
  cat > dmyext.c <<'EOF'
#include "ruby.h"
void Init_zlib(void);
void ruby_init_ext(const char *, void (*)(void));
void Init_ext(void)
{
  ruby_init_ext("zlib.so", Init_zlib);
}
EOF

  # The Ruby 1.8 Windows makefiles make the static archive depend on
  # miniruby.exe/ruby.exp, while those targets also depend on the archive.
  # Build only the configured runtime objects from Makefile, then archive them
  # directly. This avoids the legacy GNUmakefile's circular target graph and
  # does not build the standalone miniruby executable.
  object_list_makefile="$build_root/print-ruby-objects.mk"
  cat > "$object_list_makefile" <<'EOF'
.PHONY: print-ruby-objects
print-ruby-objects:
	@echo $(OBJS) $(DMYEXT)
EOF
  object_list=$(make -s -f Makefile -f "$object_list_makefile" print-ruby-objects)
  read -r -a ruby_objects <<< "$object_list"
  test "${#ruby_objects[@]}" -gt 0
  make -f GNUmakefile -j8 "CFLAGS=$build_flags" "${ruby_objects[@]}"
  rm -f "$library"
  ar rcs "$library" "${ruby_objects[@]}"
  ranlib "$library"
else
  make -j8 "CFLAGS=$build_flags" "BASERUBY=$build_root/baseruby.sh" "$library"

  # Building the static archive target alone omits Ruby's native extensions.
  # Follow Ruby's own extension build targets, selecting zlib as a statically
  # linked module and then add its initializer and object to the host archive.
  make -j8 "CFLAGS=$build_flags" miniruby
  make -j8 "CFLAGS=$build_flags" EXTS=zlib exts
  test -s ext/extinit.o
  test -s ext/zlib/zlib.o
  ar d "$library" dmyext.o
  ar rcs "$library" ext/extinit.o ext/zlib/zlib.o
  ranlib "$library"
fi
test -s "$library"

mkdir -p "$artifact_dir/lib" "$artifact_dir/include/ruby" "$artifact_dir/metadata"
cp "$library" "$artifact_dir/lib/"
if [[ "$version" == 1.9.3 ]]; then
  # Ruby 1.9 installs ruby.h at the include root and the headers referenced as
  # ruby/*.h in a nested directory. Preserve that layout so system headers
  # such as io.h cannot be shadowed by Ruby's own io.h.
  cp include/ruby.h "$artifact_dir/include/"
  cp -R include/ruby/. "$artifact_dir/include/ruby/"
  cp "$config_header" "$artifact_dir/include/ruby/config.h"
else
  # Ruby 1.8.7 keeps its C API headers in the source root rather than
  # include/ruby, unlike the newer Ruby branches. Its Windows headers are
  # included via win32/*.h, so preserve that subdirectory too.
  cp ./*.h "$artifact_dir/include/"
  cp -R win32 "$artifact_dir/include/"
fi
cp ./*.pc "$artifact_dir/metadata/" 2>/dev/null || true
cp config.log Makefile "$artifact_dir/metadata/"
mkdir -p "$artifact_dir/stdlib/lib/ruby/$ruby_stdlib_version"
cp -R lib/. "$artifact_dir/stdlib/lib/ruby/$ruby_stdlib_version/"
if [[ "$version" == 1.9.3 ]]; then
  # ruby_options() runs Ruby 1.9's gem prelude, which requires the
  # configure-generated rbconfig.rb from the Ruby installation.
  test -s rbconfig.rb
  cp rbconfig.rb "$artifact_dir/stdlib/lib/ruby/$ruby_stdlib_version/"
fi
ar t "$artifact_dir/lib/$library" | head -n 25
printf 'Built Ruby %s static runtime: %s\n' "$version" "$artifact_dir/lib/$library"

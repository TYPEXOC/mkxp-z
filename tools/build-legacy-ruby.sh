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
      --disable-install-doc

    # The old configure test misses const-correct MinGW declarations and then
    # redeclares these CRT functions with incompatible prototypes.
    for macro in HAVE_STRCHR HAVE_STRRCHR HAVE_STRERROR; do
      grep -q "^#define ${macro} 1$" config.h || \
        sed -i "/^#endif/i #define ${macro} 1" config.h
    done
    # Ruby 1.8's Windows GNUmakefile hard-codes shared mode, ignoring
    # --disable-shared and making the static-library target circular.
    sed -i 's/^ENABLE_SHARED=yes$/ENABLE_SHARED=no/' GNUmakefile
    library=libruby18.a
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
    sed -i 's/\${LIBOBJDIR}strerror\.o//g; s/\${LIBOBJDIR}strchr\.o//g' Makefile
    sed -i '/\$defs << "-DHAVE_SOCKETPAIR"/d' ext/socket/extconf.rb
    library=libmsvcrt-ruby191-static.a
    ;;
  *)
    echo "Unsupported Ruby version: $version" >&2
    exit 2
    ;;
esac

make -j8 "CFLAGS=$build_flags" "BASERUBY=$build_root/baseruby.sh" "$library"
test -s "$library"

mkdir -p "$artifact_dir/lib" "$artifact_dir/include/ruby" "$artifact_dir/metadata"
cp "$library" "$artifact_dir/lib/"
cp -R include/ruby/. "$artifact_dir/include/ruby/"
if [[ "$version" == 1.9.3 ]]; then
  cp "$config_header" "$artifact_dir/include/ruby/config.h"
else
  cp config.h "$artifact_dir/include/ruby/config.h"
fi
cp ./*.pc "$artifact_dir/metadata/" 2>/dev/null || true
cp config.log Makefile "$artifact_dir/metadata/"
ar t "$artifact_dir/lib/$library" | head -n 25
printf 'Built Ruby %s static runtime: %s\n' "$version" "$artifact_dir/lib/$library"

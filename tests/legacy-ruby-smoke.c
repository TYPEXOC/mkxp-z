#include <ruby.h>
#ifdef LEGACY_RUBY_18
#include <version.h>
#else
#include <ruby/version.h>
#endif

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    char expected_version[32];
    char script[128];
    VALUE load_path;
#ifndef LEGACY_RUBY_18
    int state = 0;
#endif

    if (argc != 3 || strlen(argv[1]) >= sizeof(expected_version))
        return 2;

    strcpy(expected_version, argv[1]);

#if defined(RUBY_API_VERSION_MAJOR) && \
    (RUBY_API_VERSION_MAJOR > 1 || RUBY_API_VERSION_MINOR >= 9)
    ruby_sysinit(&argc, &argv);
    RUBY_INIT_STACK;
#endif

    ruby_init();
#ifndef LEGACY_RUBY_18
    /* Match mkxp-z's RAPI_MAJOR < 2 initialization path. */
    rb_eval_string("$KCODE='U'");
#endif
    load_path = rb_gv_get("$:");
    if (TYPE(load_path) != T_ARRAY)
        return 3;
    rb_ary_clear(load_path);
    rb_ary_push(load_path, rb_str_new2(argv[2]));
    snprintf(script, sizeof(script),
             "require 'monitor'; abort unless RUBY_VERSION == '%s' && defined?(Monitor)",
             expected_version);
#ifndef LEGACY_RUBY_18
    rb_eval_string_protect(script, &state);
    if (state)
        return 4;
#else
    rb_eval_string(script);
#endif

    printf("Ruby %s initialized and loaded monitor.rb\n", expected_version);
    return 0;
}

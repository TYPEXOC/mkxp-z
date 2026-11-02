#include <ruby.h>
#include <version.h>

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    char expected_version[32];
    char script[128];

    if (argc != 2 || strlen(argv[1]) >= sizeof(expected_version))
        return 2;

    strcpy(expected_version, argv[1]);

#if defined(RUBY_API_VERSION_MAJOR) && RUBY_API_VERSION_MINOR >= 9
    ruby_sysinit(&argc, &argv);
    RUBY_INIT_STACK;
#endif

    ruby_init();
    snprintf(script, sizeof(script),
             "require 'date'; abort unless RUBY_VERSION == '%s'",
             expected_version);
    rb_eval_string(script);

    printf("Ruby %s initialized and loaded date.rb\n", expected_version);
    return 0;
}

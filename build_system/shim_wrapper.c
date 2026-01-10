#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    unsetenv("LD_LIBRARY_PATH");
    unsetenv("PYTHONHOME");
    unsetenv("PYTHONPATH");
    
    char *tool_name = argv[0];
    char *last_slash = strrchr(tool_name, '/');
    if (last_slash) {
        tool_name = last_slash + 1;
    }
    
    char *real_tool = NULL;
    if (strcmp(tool_name, "x86_64-gemini-linux-gnu-gcc") == 0) real_tool = "/usr/bin/gcc";
    else if (strcmp(tool_name, "x86_64-gemini-linux-gnu-g++") == 0) real_tool = "/usr/bin/g++";
    else if (strcmp(tool_name, "x86_64-gemini-linux-gnu-ar") == 0) real_tool = "/usr/bin/ar";
    else if (strcmp(tool_name, "x86_64-gemini-linux-gnu-ranlib") == 0) real_tool = "/usr/bin/ranlib";
    else if (strcmp(tool_name, "x86_64-gemini-linux-gnu-readelf") == 0) real_tool = "/usr/bin/readelf";
    else if (strcmp(tool_name, "x86_64-gemini-linux-gnu-objdump") == 0) real_tool = "/usr/bin/objdump";
    else if (strcmp(tool_name, "x86_64-gemini-linux-gnu-strip") == 0) real_tool = "/usr/bin/strip";
    else if (strcmp(tool_name, "msgfmt") == 0) real_tool = "/usr/bin/msgfmt";
    else if (strcmp(tool_name, "msginit") == 0) real_tool = "/usr/bin/msginit";
    else if (strcmp(tool_name, "msgmerge") == 0) real_tool = "/usr/bin/msgmerge";
    else if (strcmp(tool_name, "xgettext") == 0) real_tool = "/usr/bin/xgettext";
    else if (strcmp(tool_name, "python3") == 0) {
        static char python_path[1024];
        char *home = getenv("HOME");
        if (home) {
            snprintf(python_path, sizeof(python_path), "%s/.pyenv/versions/3.11.9/bin/python3", home);
            real_tool = python_path;
        } else {
            real_tool = "/usr/bin/python3";
        }
    }
    else if (strcmp(tool_name, "sh") == 0) real_tool = "/bin/sh";
    else if (strcmp(tool_name, "ldd") == 0) {
        static char script_path[1024];
        ssize_t len = readlink("/proc/self/exe", script_path, sizeof(script_path)-1);
        if (len != -1) {
            script_path[len] = '\0';
            char *last_slash_script = strrchr(script_path, '/');
            if (last_slash_script) {
                strcpy(last_slash_script + 1, "ldd.sh");
                real_tool = script_path;
            }
        }
        if (!real_tool) real_tool = "/geminios/build_system/wrap_bin/ldd.sh";
    }
    
    if (!real_tool) {
        fprintf(stderr, "Unknown tool: %s\n", tool_name);
        return 1;
    }

    // Inject --sysroot for cross-compilers
    if (strstr(tool_name, "x86_64-gemini-linux-gnu-gcc") || strstr(tool_name, "x86_64-gemini-linux-gnu-g++")) {
        char *rootfs = getenv("ROOTFS");
        if (!rootfs) {
             rootfs = "/geminios/rootfs"; // Fallback, though likely wrong if env is missing
        }
        
        // Allocate new argv: real_tool + --sysroot=... + args + NULL
        // We need enough space.
        char **new_argv = malloc((argc + 2) * sizeof(char*));
        new_argv[0] = real_tool;
        
        // Construct --sysroot string
        char *sysroot_arg = malloc(strlen(rootfs) + 11); // "--sysroot=" is 10 chars + null
        sprintf(sysroot_arg, "--sysroot=%s", rootfs);
        new_argv[1] = sysroot_arg;
        
        for (int i = 1; i < argc; i++) {
            new_argv[i + 1] = argv[i];
        }
        new_argv[argc + 1] = NULL;
        argv = new_argv;
    } else {
        argv[0] = real_tool;
    }

    execv(real_tool, argv);
    
    perror("execv");
    return 1;
}

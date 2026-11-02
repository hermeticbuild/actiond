// SPDX-License-Identifier: Apache-2.0
// Copyright The Monogon Project Authors.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <io.h>
#include <process.h>
#define execvp _execvp
#define chmod _chmod
#else
#include <unistd.h>
#endif

static char *suffix(const char *path, const char *ending) {
    char *result = malloc(strlen(path) + strlen(ending) + 1);
    if (!result) {
        perror("malloc");
        exit(1);
    }
    strcpy(result, path);
    strcat(result, ending);
    return result;
}

static void write_text(const char *path, const char *text) {
    FILE *out = fopen(path, "wb");
    if (!out) {
        perror(path);
        exit(1);
    }
    int failed = fputs(text, out) == EOF;
    if (fclose(out)) failed = 1;
    if (failed || chmod(path, 0644)) {
        perror(path);
        exit(1);
    }
}

static int append_runtime(FILE *out, char **args) {
    const char *kind = args[0], *name = args[1], *arch = args[2];
    const char *entries = args[3], *manifest = args[4];
    char *root = suffix(manifest, "");
    char *slash = strrchr(root, '/');
    if (slash) *slash = 0;
    else strcpy(root, ".");
    FILE *in = fopen(entries, "rb");
    if (!in) {
        perror(entries);
        free(root);
        return 0;
    }
    fprintf(out, "/%s/%s/%s/runtime_manifest.json l %s\n", kind, name, arch, manifest);
    char line[65536];
    while (fgets(line, sizeof(line), in)) {
        size_t length = strcspn(line, "\r\n");
        if (!line[length] && !feof(in)) {
            fprintf(stderr, "%s: entry too long\n", entries);
            fclose(in);
            free(root);
            return 0;
        }
        line[length] = 0;
        char *relative = strchr(line, '\t');
        if (!relative) continue;
        *relative++ = 0;
        char *target = strchr(relative, '\t');
        if (target) *target++ = 0;
        if (!strcmp(line, "d")) {
            fprintf(out, "/%s/%s/%s/root/%s D 0 0755 0 0\n", kind, name, arch, relative);
        } else if (!strcmp(line, "f")) {
            fprintf(out, "/%s/%s/%s/root/%s l %s/root/%s\n", kind, name, arch, relative, root, relative);
        } else if (!strcmp(line, "s") && target) {
            fprintf(out, "/%s/%s/%s/root/%s S 0 0777 0 0 %s\n", kind, name, arch, relative, target);
        }
    }
    int failed = ferror(in);
    if (fclose(in)) failed = 1;
    free(root);
    return !failed;
}

int main(int argc, char **argv) {
    if (argc < 3 || (argc - 3) % 5) {
        fprintf(stderr, "usage: runtime_squashfs MKSQUASHFS OUTPUT [KIND NAME ARCH ENTRIES MANIFEST]...\n");
        return 2;
    }
    char *pseudo = suffix(argv[2], ".pseudo");
    char *hosts = suffix(argv[2], ".hosts");
    char *nsswitch = suffix(argv[2], ".nsswitch");
    write_text(hosts, "127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n");
    write_text(nsswitch, "passwd: files\ngroup: files\nhosts: files dns\n");
    FILE *out = fopen(pseudo, "wb");
    if (!out) {
        perror(pseudo);
        return 1;
    }
    fprintf(out, "/common/root/etc/hosts l %s\n/common/root/etc/nsswitch.conf l %s\n", hosts, nsswitch);
    for (int i = 3; i < argc; i += 5) {
        if (!append_runtime(out, argv + i)) {
            fclose(out);
            return 1;
        }
    }
    int failed = ferror(out);
    if (fclose(out)) failed = 1;
    if (failed) {
        perror(pseudo);
        return 1;
    }
    char *command[] = {
        argv[1], "-", argv[2], "-pf", pseudo, "-pd", "D 0 0755 0 0",
        "-noappend", "-no-recovery", "-no-progress", "-quiet", "-comp", "zstd",
        "-Xcompression-level", "22", "-repro-time", "0", "-all-root", "-no-xattrs", "-no-exports", NULL,
    };
    execvp(command[0], command);
    perror(command[0]);
    return 127;
}

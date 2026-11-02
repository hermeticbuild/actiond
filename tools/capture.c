// SPDX-License-Identifier: Apache-2.0
// Copyright The Monogon Project Authors.

#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <process.h>
#define execvp _execvp
#else
#include <unistd.h>
#endif

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: capture INPUT|- OUTPUT COMMAND [ARGS...]\n");
        return 2;
    }
    if (strcmp(argv[1], "-") && !freopen(argv[1], "rb", stdin)) {
        perror(argv[1]);
        return 1;
    }
    if (!freopen(argv[2], "wb", stdout)) {
        perror(argv[2]);
        return 1;
    }
    execvp(argv[3], argv + 3);
    perror(argv[3]);
    return 127;
}

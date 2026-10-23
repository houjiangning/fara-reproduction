/* 独立测试 fara-resident.c 内置 SHA-256 实现是否符合标准 */
#define main resident_main
#include "fara-resident.c"
#undef main

int main(int argc, char **argv)
{
    char hex[65];
    if (argc < 2) { fprintf(stderr, "usage: %s <file>\n", argv[0]); return 1; }
    if (sha256_file(argv[1], hex) != 0) return 2;
    printf("%s  %s\n", hex, argv[1]);
    return 0;
}

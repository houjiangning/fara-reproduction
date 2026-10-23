/* mem_sha <memfile> <offset> <len>
 * 从任意内存文件（/dev/mem、/proc/<pid>/mem）按偏移读取并算 sha256。
 * 复用 fara-resident.c 的 sha256 实现（已修正 h[2] 累加 bug）。
 */
#define main resident_main
#include "fara-resident.c"
#undef main

int main(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage: %s <memfile> <offset> <len>\n", argv[0]); return 1; }
    const char *path = argv[1];
    unsigned long long off = strtoull(argv[2], NULL, 0);
    size_t n = (size_t)strtoull(argv[3], NULL, 0);

    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror(path); return 2; }

    static uint8_t chunk[1 << 20];
    sha256_ctx c; uint8_t d[32]; char hex[65];
    sha256_init(&c);

    size_t done = 0;
    while (done < n) {
        size_t want = n - done;
        if (want > sizeof chunk) want = sizeof chunk;
        ssize_t got = pread(fd, chunk, want, (off_t)(off + done));
        if (got <= 0) { perror("pread"); return 3; }
        sha256_update(&c, chunk, (size_t)got);
        done += (size_t)got;
    }
    sha256_final(&c, d);
    sha256_hex(d, hex);
    printf("%s\n", hex);
    return 0;
}

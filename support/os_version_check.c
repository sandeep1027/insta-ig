#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>

/* compiler-rt builtins that clang emits for @available(...). The Linux iOS
 * toolchain does not link libclang_rt, so provide them for Linux-hosted builds. */

static int g_os_major = 15;
static int g_os_minor = 0;
static int g_os_patch = 0;
static int g_ready;

static void init_os_version(void) {
    char buf[64];
    size_t size;
    int major, minor, patch;

    if (g_ready)
        return;

    memset(buf, 0, sizeof(buf));
    size = sizeof(buf);
    if (sysctlbyname("kern.osproductversion", buf, &size, NULL, 0) == 0) {
        major = 0;
        minor = 0;
        patch = 0;
        if (sscanf(buf, "%d.%d.%d", &major, &minor, &patch) >= 1) {
            g_os_major = major;
            g_os_minor = minor;
            g_os_patch = patch;
        }
    }
    g_ready = 1;
}

__attribute__((visibility("hidden")))
int32_t __isOSVersionAtLeast(int32_t major, int32_t minor, int32_t subminor) {
    init_os_version();
    if (g_os_major != major)
        return g_os_major > major;
    if (g_os_minor != minor)
        return g_os_minor > minor;
    return g_os_patch >= subminor;
}

__attribute__((visibility("hidden")))
int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major,
                                   uint32_t minor, uint32_t subminor) {
    (void)platform;
    return __isOSVersionAtLeast((int32_t)major, (int32_t)minor, (int32_t)subminor);
}

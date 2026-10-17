/*
 * unit-mnt - change the read-only flag of whole trees of mounts at once, for
 * unit-sandbox (ProtectSystem=, ReadOnlyPaths=, ReadWritePaths=, …).
 *
 *   unit-mnt ro PATH…       PATH and every mount below it read-only
 *   unit-mnt rw PATH…       … writable again
 *   unit-mnt strict [ROOT]  everything under ROOT (/) read-only but its
 *                           dev, proc and sys
 *
 * A path that is not a mount point is made one first (a bind mount of itself),
 * so that the flag belongs to that path and not to the file system it is on.
 * One mount_setattr(2) does a whole tree; on kernels without it every mount
 * is remounted in turn.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/mount.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef AT_RECURSIVE
#define AT_RECURSIVE 0x8000
#endif
#ifndef MOUNT_ATTR_RDONLY
#define MOUNT_ATTR_RDONLY 0x00000001
#endif
#ifndef STATX_ATTR_MOUNT_ROOT
#define STATX_ATTR_MOUNT_ROOT 0x00002000
#endif

struct attr {
  unsigned long long attr_set, attr_clr, propagation, userns_fd;
};

static int is_mount_root(const char *path) {
  struct statx sx;
  if (statx(AT_FDCWD, path, AT_NO_AUTOMOUNT | AT_SYMLINK_NOFOLLOW, 0, &sx) < 0) return -1;
  return (sx.stx_attributes & STATX_ATTR_MOUNT_ROOT) ? 1 : 0;
}

/* Fallback: remount every mount at or below `base`, from mountinfo. */
static int remount_each(const char *base, int ro) {
  FILE *f = fopen("/proc/self/mountinfo", "r");
  if (!f) return -1;
  char line[8192];
  size_t bl = strlen(base);
  while (bl > 1 && base[bl - 1] == '/') bl--;
  while (fgets(line, sizeof line, f)) {
    char *p = line;
    for (int i = 0; i < 4 && p; i++) p = strchr(p, ' '), p = p ? p + 1 : p;
    if (!p) continue;
    char *e = strchr(p, ' ');
    if (!e) continue;
    *e = 0;
    /* octal escapes: \040 is a space */
    char mp[4096];
    size_t n = 0;
    for (char *c = p; *c && n + 1 < sizeof mp; c++) {
      if (c[0] == '\\' && c[1] >= '0' && c[1] <= '7' && c[2] && c[3]) {
        mp[n++] = (char)(((c[1] - '0') << 6) | ((c[2] - '0') << 3) | (c[3] - '0'));
        c += 3;
      } else {
        mp[n++] = *c;
      }
    }
    mp[n] = 0;
    if (!(strcmp(base, "/") == 0 || strncmp(mp, base, bl) == 0)) continue;
    if (bl > 1 && mp[bl] != 0 && mp[bl] != '/') continue;
    mount(NULL, mp, NULL, MS_REMOUNT | MS_BIND | (ro ? MS_RDONLY : 0), NULL);
  }
  fclose(f);
  return 0;
}

static int set(const char *path, int ro) {
  int r = is_mount_root(path);
  if (r < 0) {
    fprintf(stderr, "unit-mnt: %s: %s\n", path, strerror(errno));
    return -1;
  }
  if (r == 0 && mount(path, path, NULL, MS_BIND | MS_REC, NULL) < 0) {
    fprintf(stderr, "unit-mnt: cannot bind %s: %s\n", path, strerror(errno));
    return -1;
  }
  struct attr a = { .attr_set = ro ? MOUNT_ATTR_RDONLY : 0, .attr_clr = ro ? 0 : MOUNT_ATTR_RDONLY };
  if (syscall(SYS_mount_setattr, AT_FDCWD, path, AT_RECURSIVE, &a, sizeof a) == 0) return 0;
  if (errno != ENOSYS && errno != EINVAL) {
    fprintf(stderr, "unit-mnt: %s: %s\n", path, strerror(errno));
    return -1;
  }
  return remount_each(path, ro);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fputs("usage: unit-mnt ro|rw PATH… | strict\n", stderr);
    return 100;
  }
  int rc = 0;
  if (!strcmp(argv[1], "strict")) {
    const char *root = argc > 2 ? argv[2] : "/";
    size_t rl = strlen(root);
    while (rl > 1 && root[rl - 1] == '/') rl--;
    if (set(root, 1) < 0) return 1;
    /* the API file systems stay as they are */
    static const char *api[] = { "/dev", "/proc", "/sys" };
    for (size_t i = 0; i < sizeof api / sizeof *api; i++) {
      char path[4096];
      snprintf(path, sizeof path, "%.*s%s", (int)(rl == 1 ? 0 : rl), root, api[i]);
      if (access(path, F_OK) == 0 && set(path, 0) < 0) rc = 1;
    }
    return rc;
  }
  int ro;
  if (!strcmp(argv[1], "ro")) ro = 1;
  else if (!strcmp(argv[1], "rw")) ro = 0;
  else {
    fprintf(stderr, "unit-mnt: unknown command %s\n", argv[1]);
    return 100;
  }
  for (int i = 2; i < argc; i++)
    if (set(argv[i], ro) < 0) rc = 1;
  return rc;
}

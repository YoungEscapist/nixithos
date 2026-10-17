/*
 * unit-chroot - enter the root directory of a unit (RootDirectory=) and run
 * its command there.
 *
 *   unit-chroot [-k] [-B CAP]… [-d DIR] ROOT -- COMMAND [ARGUMENTS…]
 *
 * Runs after setpriv has dropped privileges to the unit's user, with
 * CAP_SYS_CHROOT as an ambient capability for the moment this takes
 * (unit-runtime arranges that).  Once the chroot is done, CAP_SYS_CHROOT is
 * taken away again, from every set, unless the unit asked for it (-k): a
 * service that is confined should not be able to chroot again.
 *
 * A root service gets its capabilities back from the bounding set at the
 * next exec, so for one whose bounding set does not have CAP_SYS_CHROOT,
 * unit-runtime puts it there for the moment, with CAP_SETPCAP, and names
 * them with -B (sys_chroot, setpcap): they are taken out of the bounding
 * set after the chroot, CAP_SETPCAP last.  The command starts in DIR of
 * the new root (/ by default).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <linux/capability.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef PR_CAP_AMBIENT
#define PR_CAP_AMBIENT 47
#define PR_CAP_AMBIENT_LOWER 3
#endif

static int drop_chroot_capability(void) {
  struct __user_cap_header_struct hdr = { .version = _LINUX_CAPABILITY_VERSION_3, .pid = 0 };
  struct __user_cap_data_struct data[2];
  if (syscall(SYS_capget, &hdr, data) < 0) return -1;
  unsigned bit = 1u << (CAP_SYS_CHROOT % 32);
  int idx = CAP_SYS_CHROOT / 32;
  data[idx].effective &= ~bit;
  data[idx].permitted &= ~bit;
  data[idx].inheritable &= ~bit;
  if (syscall(SYS_capset, &hdr, data) < 0) return -1;
  /* (the ambient set cannot hold what is not permitted and inheritable;
   * lowering is harmless if it is already gone) */
  prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_LOWER, CAP_SYS_CHROOT, 0, 0);
  return 0;
}

int main(int argc, char **argv) {
  int keep = 0, i = 1, drop_chroot = 0, drop_setpcap = 0;
  const char *dir = "/";
  while (i < argc && argv[i][0] == '-' && argv[i][1] && strcmp(argv[i], "--") != 0) {
    if (!strcmp(argv[i], "-k")) {
      keep = 1;
      i++;
    } else if (!strcmp(argv[i], "-d") && i + 1 < argc) {
      dir = argv[i + 1];
      i += 2;
    } else if (!strcmp(argv[i], "-B") && i + 1 < argc) {
      if (!strcmp(argv[i + 1], "sys_chroot")) drop_chroot = 1;
      else if (!strcmp(argv[i + 1], "setpcap")) drop_setpcap = 1;
      else {
        fprintf(stderr, "unit-chroot: -B %s: not one of sys_chroot, setpcap\n", argv[i + 1]);
        return 100;
      }
      i += 2;
    } else {
      break;
    }
  }
  if (i + 2 >= argc || strcmp(argv[i + 1], "--") != 0) {
    fputs("usage: unit-chroot [-k] [-B CAP]… [-d DIR] ROOT -- COMMAND [ARGUMENTS…]\n", stderr);
    return 100;
  }
  const char *root = argv[i];
  if (chroot(root) < 0) {
    fprintf(stderr, "unit-chroot: chroot %s: %s\n", root, strerror(errno));
    return 226;
  }
  /* a root handed over as a descriptor (unit-sandbox moved the directory
   * onto the namespace's /): not for the service to keep */
  if (strncmp(root, "/proc/self/fd/", 14) == 0) close(atoi(root + 14));
  if (chdir(dir) < 0 && chdir("/") < 0) {
    fprintf(stderr, "unit-chroot: chdir %s: %s\n", dir, strerror(errno));
    return 226;
  }
  if (!keep && drop_chroot_capability() < 0) {
    fprintf(stderr, "unit-chroot: cannot give up CAP_SYS_CHROOT: %s\n", strerror(errno));
    return 226;
  }
  if ((drop_chroot && prctl(PR_CAPBSET_DROP, CAP_SYS_CHROOT, 0, 0, 0) < 0) ||
      (drop_setpcap && prctl(PR_CAPBSET_DROP, CAP_SETPCAP, 0, 0, 0) < 0)) {
    fprintf(stderr, "unit-chroot: cannot take capabilities out of the bounding set: %s\n", strerror(errno));
    return 226;
  }
  execvp(argv[i + 2], argv + i + 2);
  fprintf(stderr, "unit-chroot: %s: %s\n", argv[i + 2], strerror(errno));
  return errno == ENOENT ? 127 : 126;
}

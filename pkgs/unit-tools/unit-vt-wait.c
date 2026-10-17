/*
 * unit-vt-wait - wait until a virtual console is the one on the screen.
 *
 *   unit-vt-wait ttyN
 *
 * What systemd-logind does for the gettys of tty2 and up (autovt): they are
 * started when someone switches to their console, not at boot, so that a
 * configuration with automatic login does not log the user in six times
 * over (the session logind would pick as the user's own is then one that is
 * not on the screen, and polkit says no to it).  Returns at once if the
 * console is already on the screen, and when there are no virtual consoles
 * to wait for.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/vt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 2) {
    fputs("usage: unit-vt-wait ttyN\n", stderr);
    return 100;
  }
  const char *name = argv[1];
  if (strncmp(name, "/dev/", 5) == 0) name += 5;
  if (strncmp(name, "tty", 3) != 0) return 0;
  char *end;
  long n = strtol(name + 3, &end, 10);
  if (*end || n < 1 || n > 63) return 0;

  int fd = open("/dev/tty0", O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (fd < 0) return 0;
  for (;;) {
    if (ioctl(fd, VT_WAITACTIVE, (int)n) == 0) return 0;
    if (errno != EINTR) {
      fprintf(stderr, "unit-vt-wait: VT_WAITACTIVE %ld: %s\n", n, strerror(errno));
      return 0;
    }
  }
}

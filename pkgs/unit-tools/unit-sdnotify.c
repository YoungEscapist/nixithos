/*
 * unit-sdnotify - send sd_notify(3) messages without libsystemd.
 *
 *   unit-sdnotify READY=1 "STATUS=up and running"
 *
 * Each argument becomes one line of a single datagram sent to
 * $NOTIFY_SOCKET.  Exits 0 without doing anything when the variable is not
 * set, like sd_notify() returns 0.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int main(int argc, char **argv) {
  const char *path = getenv("NOTIFY_SOCKET");
  if (!path || !*path) return 0;
  if (argc < 2) {
    fputs("usage: unit-sdnotify VARIABLE=VALUE…\n", stderr);
    return 100;
  }

  struct sockaddr_un un = { .sun_family = AF_UNIX };
  size_t len = strlen(path);
  if (len >= sizeof un.sun_path) {
    fputs("unit-sdnotify: NOTIFY_SOCKET is too long\n", stderr);
    return 111;
  }
  memcpy(un.sun_path, path, len);
  if (path[0] == '@') un.sun_path[0] = 0;

  char buf[4096];
  size_t n = 0;
  for (int i = 1; i < argc; i++) {
    size_t l = strlen(argv[i]);
    if (n + l + 1 > sizeof buf) {
      fputs("unit-sdnotify: message too long\n", stderr);
      return 100;
    }
    memcpy(buf + n, argv[i], l);
    n += l;
    buf[n++] = '\n';
  }

  int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) { perror("unit-sdnotify: socket"); return 111; }
  if (sendto(fd, buf, n, MSG_NOSIGNAL, (struct sockaddr *)&un,
             (socklen_t)(offsetof(struct sockaddr_un, sun_path) + len)) < 0) {
    perror("unit-sdnotify: sendto");
    return 111;
  }
  return 0;
}

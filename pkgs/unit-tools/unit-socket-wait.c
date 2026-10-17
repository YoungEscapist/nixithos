/*
 * unit-socket-wait - wait until one of the listening sockets of a unit has
 * something for its service: a connection to take, a datagram to read.
 *
 *   unit-socket-wait -n N
 *
 * The sockets are descriptors 3 to 3+N-1 (as LISTEN_FDS has them).  Nothing
 * is taken off them: the service does that once it is started.  Exits 0
 * when one is ready, 111 on an error.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int n = 0, opt;
  /* The shell that runs us (socket-activate) is what s6 stops; nothing
   * else would stop us, and we would stay behind holding the sockets (the
   * user's last logout did not end with nothing of theirs left). */
  pid_t parent = getppid();
  if (prctl(PR_SET_PDEATHSIG, SIGTERM) < 0 || getppid() != parent || parent == 1)
    return 111;
  while ((opt = getopt(argc, argv, "n:")) != -1) {
    if (opt == 'n') n = atoi(optarg);
    else n = 0;
  }
  if (n <= 0 || n > 1024) {
    fputs("usage: unit-socket-wait -n N\n", stderr);
    return 100;
  }
  struct pollfd *p = calloc((size_t)n, sizeof *p);
  if (!p) return 111;
  for (int i = 0; i < n; i++) {
    p[i].fd = 3 + i;
    p[i].events = POLLIN;
  }
  for (;;) {
    int r = poll(p, (nfds_t)n, -1);
    if (r < 0) {
      if (errno == EINTR) continue;
      fprintf(stderr, "unit-socket-wait: poll: %s\n", strerror(errno));
      return 111;
    }
    for (int i = 0; i < n; i++) {
      if (p[i].revents & POLLIN) return 0;
      if (p[i].revents & (POLLERR | POLLNVAL)) {
        fprintf(stderr, "unit-socket-wait: descriptor %d is not usable\n", p[i].fd);
        return 111;
      }
    }
  }
}

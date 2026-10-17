/*
 * unit-accept - the "Accept=yes" half of a socket unit: accept connections
 * on listening sockets and start one command per connection.
 *
 *   unit-accept [-n SOCKETS] [-m MAX] -- COMMAND [ARGUMENTS…]
 *
 * The listening sockets are on descriptors 3 … 3+SOCKETS-1, as for any
 * socket-activated program (SOCKETS defaults to $LISTEN_FDS).  For every
 * connection COMMAND runs with it on descriptor 3 and
 *
 *   UNIT_ACCEPT_INSTANCE  the name systemd gives the instance:
 *                         COUNTER-LOCAL-REMOTE, or COUNTER-PID-UID for AF_UNIX
 *   REMOTE_ADDR, REMOTE_PORT   of the peer, for IP sockets
 *
 * in its environment.  More than MAX connections at a time are refused.
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t children_exited;

static void on_chld(int sig) {
  (void)sig;
  children_exited = 1;
}

static int reap(void) {
  int n = 0, status;
  while (waitpid(-1, &status, WNOHANG) > 0) n++;
  return n;
}

static void describe(int conn, char *name, size_t size, unsigned long counter) {
  struct sockaddr_storage local, remote;
  socklen_t ll = sizeof local, rl = sizeof remote;
  char lh[INET6_ADDRSTRLEN] = "", rh[INET6_ADDRSTRLEN] = "";
  int lp = 0, rp = 0;

  memset(&local, 0, sizeof local);
  memset(&remote, 0, sizeof remote);
  if (getsockname(conn, (struct sockaddr *)&local, &ll) == 0 &&
      getpeername(conn, (struct sockaddr *)&remote, &rl) == 0) {
    if (local.ss_family == AF_INET) {
      struct sockaddr_in *l = (void *)&local, *r = (void *)&remote;
      inet_ntop(AF_INET, &l->sin_addr, lh, sizeof lh);
      inet_ntop(AF_INET, &r->sin_addr, rh, sizeof rh);
      lp = ntohs(l->sin_port);
      rp = ntohs(r->sin_port);
      snprintf(name, size, "%lu-%s:%d-%s:%d", counter, lh, lp, rh, rp);
      setenv("REMOTE_ADDR", rh, 1);
      char port[16];
      snprintf(port, sizeof port, "%d", rp);
      setenv("REMOTE_PORT", port, 1);
      return;
    }
    if (local.ss_family == AF_INET6) {
      struct sockaddr_in6 *l = (void *)&local, *r = (void *)&remote;
      inet_ntop(AF_INET6, &l->sin6_addr, lh, sizeof lh);
      inet_ntop(AF_INET6, &r->sin6_addr, rh, sizeof rh);
      lp = ntohs(l->sin6_port);
      rp = ntohs(r->sin6_port);
      snprintf(name, size, "%lu-%s:%d-%s:%d", counter, lh, lp, rh, rp);
      setenv("REMOTE_ADDR", rh, 1);
      char port[16];
      snprintf(port, sizeof port, "%d", rp);
      setenv("REMOTE_PORT", port, 1);
      return;
    }
  }
  struct ucred cred;
  socklen_t cl = sizeof cred;
  if (getsockopt(conn, SOL_SOCKET, SO_PEERCRED, &cred, &cl) == 0)
    snprintf(name, size, "%lu-%ld-%ld", counter, (long)cred.pid, (long)cred.uid);
  else
    snprintf(name, size, "%lu", counter);
}

int main(int argc, char **argv) {
  int nsock = -1, max = 64, opt;
  while ((opt = getopt(argc, argv, "n:m:")) != -1) {
    switch (opt) {
      case 'n': nsock = atoi(optarg); break;
      case 'm': max = atoi(optarg); break;
      default: nsock = 0; break;
    }
  }
  if (nsock < 0) {
    const char *e = getenv("LISTEN_FDS");
    nsock = e ? atoi(e) : 0;
  }
  if (nsock <= 0 || optind >= argc || nsock > 64) {
    fputs("usage: unit-accept [-n SOCKETS] [-m MAX] -- COMMAND [ARGUMENTS…]\n", stderr);
    return 100;
  }
  if (max <= 0) max = 64;

  struct sigaction sa = { .sa_handler = on_chld };
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  sigaction(SIGCHLD, &sa, NULL);

  unsigned long counter = 0;
  int active = 0;
  struct pollfd pfd[64];
  for (int i = 0; i < nsock; i++) {
    pfd[i].fd = 3 + i;
    pfd[i].events = POLLIN;
  }

  for (;;) {
    if (children_exited) {
      children_exited = 0;
      active -= reap();
      if (active < 0) active = 0;
    }
    int r = poll(pfd, (nfds_t)nsock, 1000);
    if (r < 0) {
      if (errno == EINTR) continue;
      perror("unit-accept: poll");
      return 111;
    }
    if (r == 0) {
      active -= reap();
      if (active < 0) active = 0;
      continue;
    }
    for (int i = 0; i < nsock; i++) {
      if (!(pfd[i].revents & POLLIN)) continue;
      int conn = accept4(pfd[i].fd, NULL, NULL, 0);
      if (conn < 0) {
        if (errno != EAGAIN && errno != EINTR && errno != ECONNABORTED) perror("unit-accept: accept");
        continue;
      }
      if (active >= max) {
        fprintf(stderr, "unit-accept: too many connections (%d), refusing one\n", active);
        close(conn);
        continue;
      }
      char name[256];
      describe(conn, name, sizeof name, counter++);
      pid_t pid = fork();
      if (pid < 0) {
        perror("unit-accept: fork");
        close(conn);
        continue;
      }
      if (pid == 0) {
        struct sigaction dfl = { .sa_handler = SIG_DFL };
        sigemptyset(&dfl.sa_mask);
        sigaction(SIGCHLD, &dfl, NULL);
        if (conn != 3) {
          dup2(conn, 3);
          close(conn);
        }
        for (int fd = 4; fd < 4 + nsock + 3; fd++) close(fd);
        int flags = fcntl(3, F_GETFD);
        if (flags >= 0) fcntl(3, F_SETFD, flags & ~FD_CLOEXEC);
        setenv("UNIT_ACCEPT_INSTANCE", name, 1);
        unsetenv("LISTEN_FDS");
        unsetenv("LISTEN_PID");
        execvp(argv[optind], argv + optind);
        perror("unit-accept: exec");
        _exit(127);
      }
      close(conn);
      active++;
    }
  }
}

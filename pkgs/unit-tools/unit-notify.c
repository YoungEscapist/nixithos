/*
 * unit-notify - receive sd_notify(3) messages on behalf of a supervisor that
 * does not speak that protocol.
 *
 *   unit-notify -s SOCKET [-p PID] [-u UID] [-w] [-k]
 *
 * Binds a datagram socket at SOCKET (the caller exports its path as
 * NOTIFY_SOCKET), then detaches and returns: when the command exits, the
 * socket is ready to receive.  The detached half waits for "READY=1" and
 * answers it by writing a newline to its standard output, which is how s6
 * services announce readiness.
 *
 * It exits once it has done so, or when process PID is gone.  With -k it
 * stays to drain later messages (STATUS=, WATCHDOG=) for as long as PID
 * lives; without it those sends simply fail on the client side, which every
 * sd_notify() caller tolerates.
 *
 * Daemons that drop privileges themselves (chronyd, named, …) notify as
 * another user than the one the socket was made for, so with -w the socket
 * is open to everybody, as systemd's is.  What makes that safe is who the
 * kernel says the sender is: READY=1 counts if it comes from root, from PID
 * itself or from a process in the same control group.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static void die(const char *what) {
  fprintf(stderr, "unit-notify: %s: %s\n", what, strerror(errno));
  exit(111);
}

static int has_ready(const char *buf, size_t len) {
  const char *p = buf, *end = buf + len;
  while (p < end) {
    const char *nl = memchr(p, '\n', (size_t)(end - p));
    size_t l = nl ? (size_t)(nl - p) : (size_t)(end - p);
    if (l == 7 && !memcmp(p, "READY=1", 7)) return 1;
    if (!nl) break;
    p = nl + 1;
  }
  return 0;
}

/* The control group line of a process ("0::/units/nginx"), without the
 * newline; empty if it cannot be read. */
static void cgroup_of(pid_t pid, char *out, size_t size) {
  char path[64];
  out[0] = 0;
  snprintf(path, sizeof path, "/proc/%ld/cgroup", (long)pid);
  FILE *f = fopen(path, "r");
  if (!f) return;
  if (fgets(out, (int)size, f)) out[strcspn(out, "\n")] = 0;
  fclose(f);
}

/* Is the sender somebody this service's readiness is theirs to announce? */
static int trusted(const struct ucred *cred, pid_t watch) {
  if (cred->uid == 0) return 1;
  if (watch > 0 && cred->pid == watch) return 1;
  if (watch > 0) {
    char a[256], b[256];
    cgroup_of(cred->pid, a, sizeof a);
    cgroup_of(watch, b, sizeof b);
    /* (the root group is where everybody is: it vouches for nobody) */
    if (a[0] && !strcmp(a, b) && strcmp(a, "0::/")) return 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  const char *path = NULL;
  pid_t watch = 0;
  long uid = -1;
  int keep = 0, world = 0, opt;

  while ((opt = getopt(argc, argv, "s:p:u:kw")) != -1) {
    switch (opt) {
      case 's': path = optarg; break;
      case 'p': watch = (pid_t)atol(optarg); break;
      case 'u': uid = atol(optarg); break;
      case 'k': keep = 1; break;
      case 'w': world = 1; break;
      default: path = NULL; optind = argc; break;
    }
  }
  if (!path) {
    fputs("usage: unit-notify -s SOCKET [-p PID] [-u UID] [-w] [-k]\n", stderr);
    return 100;
  }

  struct sockaddr_un un = { .sun_family = AF_UNIX };
  if (strlen(path) >= sizeof un.sun_path) { errno = ENAMETOOLONG; die(path); }
  strcpy(un.sun_path, path);

  int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) die("socket");
  int on = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_PASSCRED, &on, sizeof on) < 0) die("SO_PASSCRED");
  unlink(path);
  mode_t old = umask(0177);
  if (bind(fd, (struct sockaddr *)&un, sizeof un) < 0) die("bind");
  umask(old);
  if (uid >= 0 && chown(path, (uid_t)uid, (gid_t)-1) < 0) die("chown");
  if (world && chmod(path, 0666) < 0) die("chmod");
  /* what is ours to remove at the end: by then the path may be a socket of
   * the service's next start */
  struct stat bound;
  if (stat(path, &bound) < 0) die("stat");

  /* Detach, so that the service does not end up with a child it never forked. */
  pid_t child = fork();
  if (child < 0) die("fork");
  if (child > 0) {
    int status;
    waitpid(child, &status, 0);
    return 0;
  }
  child = fork();
  if (child < 0) _exit(111);
  if (child > 0) _exit(0);

  setsid();
  signal(SIGPIPE, SIG_IGN);

  int pidfd = -1;
#ifdef SYS_pidfd_open
  if (watch > 0) pidfd = (int)syscall(SYS_pidfd_open, watch, 0);
#endif

  int notified = 0;
  for (;;) {
    struct pollfd pfd[2] = {
      { .fd = fd, .events = POLLIN },
      { .fd = pidfd, .events = POLLIN },
    };
    int r = poll(pfd, pidfd >= 0 ? 2 : 1, 1000);
    if (r < 0 && errno != EINTR) break;
    if (r > 0 && (pfd[0].revents & POLLIN)) {
      char buf[4096];
      union {
        char bytes[CMSG_SPACE(sizeof(struct ucred))];
        struct cmsghdr align;
      } control;
      struct iovec iov = { .iov_base = buf, .iov_len = sizeof buf };
      struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = control.bytes,
        .msg_controllen = sizeof control.bytes,
      };
      ssize_t n = recvmsg(fd, &msg, MSG_DONTWAIT);
      int ok = !world;
      if (n > 0 && world) {
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
          if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_CREDENTIALS) {
            struct ucred cred;
            memcpy(&cred, CMSG_DATA(c), sizeof cred);
            ok = trusted(&cred, watch);
          }
        }
      }
      if (n > 0 && ok && !notified && has_ready(buf, (size_t)n)) {
        notified = 1;
        if (write(1, "\n", 1) < 0) { /* the supervisor is gone; nothing to do */ }
        close(1);
        if (!keep) break;
      }
      continue;
    }
    if (pidfd >= 0) {
      if (r > 0 && pfd[1].revents) break;
    } else if (watch > 0 && kill(watch, 0) < 0 && errno == ESRCH) {
      break;
    }
  }
  struct stat now;
  if (stat(path, &now) == 0 && now.st_dev == bound.st_dev && now.st_ino == bound.st_ino)
    unlink(path);
  return 0;
}

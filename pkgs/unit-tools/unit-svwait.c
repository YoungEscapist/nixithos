/*
 * unit-svwait - waits for a unit-supervise to have its service ready.
 *
 *   unit-svwait [-d DIR] [-t SECONDS] [-r] ATOM PIDFILE
 *
 * For a service manager that starts unit-supervise and has nothing to read
 * its readiness from (OpenRC's start-stop-daemon, which only gets the
 * supervisor going): the supervisor of ATOM, whose process id is in PIDFILE,
 * says in DIR/ATOM (default /run/units/.sv) when its service is up and ready.
 * What an earlier supervisor left there is not looked at: only a status
 * written by that very process counts.  Without -r a service that has no way
 * to say it is ready (no -n for the supervisor) is up when its process is.
 *
 * Exits 0 when the service is ready (or has been, and ended for good: the
 * supervisor stays), 1 when the supervisor has gone without it ever having
 * been, 2 when it took longer
 * than SECONDS (0: no limit), after the supervisor was told to give up (as
 * dinit does with a start that times out) and has.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static long long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void nap(long ms) {
  struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}

/* a zombie counts as gone: the supervisor of a service is a child of whoever
 * started it, which may be nobody who waits */
static int running(pid_t pid) {
  char path[64], buf[256];
  snprintf(path, sizeof path, "/proc/%d/stat", (int)pid);
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  size_t n = fread(buf, 1, sizeof buf - 1, f);
  fclose(f);
  buf[n] = 0;
  char *p = strrchr(buf, ')');
  return p && p[1] == ' ' && p[2] != 'Z' && p[2] != 'X';
}

int main(int argc, char **argv) {
  const char *dir = "/run/units/.sv";
  long limit = 0;
  int opt, need_ready = 0;
  while ((opt = getopt(argc, argv, "d:t:r")) != -1) {
    switch (opt) {
      case 'd': dir = optarg; break;
      case 't': limit = atol(optarg); break;
      case 'r': need_ready = 1; break;
      default:
        fprintf(stderr, "usage: unit-svwait [-d DIR] [-t SECONDS] [-r] ATOM PIDFILE\n");
        return 100;
    }
  }
  if (argc - optind != 2) {
    fprintf(stderr, "usage: unit-svwait [-d DIR] [-t SECONDS] [-r] ATOM PIDFILE\n");
    return 100;
  }
  const char *atom = argv[optind], *pidfile = argv[optind + 1];
  long long start = now_ms();
  long long deadline = limit > 0 ? start + limit * 1000 : 0;

  /* the supervisor's process id (start-stop-daemon has written it by now,
   * but not necessarily before it is looked for) */
  pid_t pid = 0;
  for (int i = 0; i < 200 && pid <= 0; i++) {
    FILE *f = fopen(pidfile, "r");
    if (f) {
      if (fscanf(f, "%d", (int *)&pid) != 1) pid = 0;
      fclose(f);
    }
    if (pid <= 0) nap(10);
  }
  if (pid <= 0) {
    fprintf(stderr, "unit-svwait: no process id in %s\n", pidfile);
    return 1;
  }

  char path[2 * PATH_MAX];
  snprintf(path, sizeof path, "%s/%s", dir, atom);
  for (;;) {
    if (!running(pid)) return 1;
    FILE *f = fopen(path, "r");
    if (f) {
      int up, ready, p, svpid;
      char want, phase[16];
      if (fscanf(f, "%d %d %d %c %d %15s", &up, &ready, &p, &want, &svpid, phase) == 6 &&
          svpid == (int)pid) {
        fclose(f);
        if (up && (ready || !need_ready)) return 0;
        if (!strcmp(phase, "exit")) return 1;
        /* (a supervisor that is done with its service, and stays, has told
         * its manager that it was up: with -m, one that never was exits) */
        if (!strcmp(phase, "idle")) return 0;
      } else {
        fclose(f);
      }
    }
    if (deadline && now_ms() >= deadline) {
      fprintf(stderr, "unit-svwait: %s: not ready after %ld seconds\n", atom, limit);
      kill(pid, SIGINT);
      for (int i = 0; i < 500 && running(pid); i++) nap(20);
      if (running(pid)) kill(pid, SIGKILL);
      return 2;
    }
    nap(20);
  }
}

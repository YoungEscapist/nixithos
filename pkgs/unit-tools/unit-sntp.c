/*
 * unit-sntp - a small SNTP client that keeps the clock right, in the place
 * of systemd-timesyncd.
 *
 *   unit-sntp [-c CONFIG] [-s STATEDIR] [-r RUNDIR] [-1]
 *
 * Reads NTP= and FallbackNTP= (and PollIntervalMinSec=, PollIntervalMaxSec=)
 * from the [Time] section of CONFIG (timesyncd.conf).  The clock is first
 * moved forward to the time of the stamp file in STATEDIR, for machines that
 * start without a battery-backed clock; every answer then steps the clock if
 * it is far off or slews it if it is close, the stamp file is touched, and
 * RUNDIR/synchronized appears, as systemd-time-wait-sync expects.
 * With -1 it exits after the first successful synchronization.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdarg.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define NTP_EPOCH_OFFSET 2208988800UL /* seconds from 1900 to 1970 */
#define MAXSERVERS 32

static char *servers[MAXSERVERS];
static int nservers;
static char *fallbacks[MAXSERVERS];
static int nfallbacks;
static long poll_min = 32, poll_max = 2048;

static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...) {
  va_list ap;
  fputs("timesyncd: ", stderr);
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
}

static void add_words(char *list, char **to, int *n) {
  for (char *w = strtok(list, " \t"); w && *n < MAXSERVERS; w = strtok(NULL, " \t"))
    to[(*n)++] = strdup(w);
}

static void read_config(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return;
  char line[1024];
  int in_time = 0;
  while (fgets(line, sizeof line, f)) {
    line[strcspn(line, "\n")] = 0;
    char *p = line;
    while (*p == ' ' || *p == '\t') p++;
    if (*p == 0 || *p == '#' || *p == ';') continue;
    if (*p == '[') { in_time = !strncmp(p, "[Time]", 6); continue; }
    if (!in_time) continue;
    char *eq = strchr(p, '=');
    if (!eq) continue;
    *eq = 0;
    char *v = eq + 1;
    if (!strcmp(p, "NTP")) { nservers = 0; add_words(v, servers, &nservers); }
    else if (!strcmp(p, "FallbackNTP")) { nfallbacks = 0; add_words(v, fallbacks, &nfallbacks); }
    else if (!strcmp(p, "PollIntervalMinSec")) poll_min = atol(v) > 0 ? atol(v) : poll_min;
    else if (!strcmp(p, "PollIntervalMaxSec")) poll_max = atol(v) > 0 ? atol(v) : poll_max;
  }
  fclose(f);
}

static double now_real(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static void put_ts(unsigned char *b, double t) {
  double s = t + NTP_EPOCH_OFFSET;
  unsigned long sec = (unsigned long)s;
  unsigned long frac = (unsigned long)((s - (double)sec) * 4294967296.0);
  b[0] = sec >> 24; b[1] = sec >> 16; b[2] = sec >> 8; b[3] = sec;
  b[4] = frac >> 24; b[5] = frac >> 16; b[6] = frac >> 8; b[7] = frac;
}

static double get_ts(const unsigned char *b) {
  unsigned long sec = ((unsigned long)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  unsigned long frac = ((unsigned long)b[4] << 24) | (b[5] << 16) | (b[6] << 8) | b[7];
  return (double)sec - NTP_EPOCH_OFFSET + (double)frac / 4294967296.0;
}

/* One exchange with one server; returns 0 and fills offset/delay. */
static int query(const char *host, double *offset, double *delay) {
  struct addrinfo hints = { .ai_socktype = SOCK_DGRAM }, *res = NULL;
  if (getaddrinfo(host, "123", &hints, &res) != 0 || !res) return -1;
  int rc = -1;
  for (struct addrinfo *ai = res; ai && rc != 0; ai = ai->ai_next) {
    int fd = socket(ai->ai_family, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) continue;
    unsigned char pkt[48], reply[128];
    memset(pkt, 0, sizeof pkt);
    pkt[0] = (0 << 6) | (4 << 3) | 3; /* LI 0, version 4, client */
    double t1 = now_real();
    /* a random low part: the answer has to repeat it */
    put_ts(pkt + 40, t1);
    for (int i = 44; i < 48; i++) pkt[i] = (unsigned char)(random() & 0xff);
    unsigned char sent[8];
    memcpy(sent, pkt + 40, 8);
    if (sendto(fd, pkt, sizeof pkt, 0, ai->ai_addr, ai->ai_addrlen) == (ssize_t)sizeof pkt) {
      struct pollfd pfd = { .fd = fd, .events = POLLIN };
      if (poll(&pfd, 1, 3000) > 0) {
        ssize_t n = recv(fd, reply, sizeof reply, 0);
        double t4 = now_real();
        if (n >= 48 && (reply[0] & 7) == 4 && (reply[0] >> 6) != 3 && reply[1] != 0 &&
            memcmp(reply + 24, sent, 8) == 0) {
          double t2 = get_ts(reply + 32), t3 = get_ts(reply + 40);
          if (t3 != 0) {
            *offset = ((t2 - t1) + (t3 - t4)) / 2.0;
            *delay = (t4 - t1) - (t3 - t2);
            rc = 0;
          }
        }
      }
    }
    close(fd);
  }
  freeaddrinfo(res);
  return rc;
}

static void touch_file(const char *path) {
  int fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
  if (fd >= 0) {
    futimens(fd, NULL);
    close(fd);
  }
}

int main(int argc, char **argv) {
  const char *config = "/etc/systemd/timesyncd.conf", *statedir = "/var/lib/systemd/timesync",
             *rundir = "/run/systemd/timesync";
  int once = 0, opt;
  while ((opt = getopt(argc, argv, "c:s:r:1")) != -1) {
    switch (opt) {
      case 'c': config = optarg; break;
      case 's': statedir = optarg; break;
      case 'r': rundir = optarg; break;
      case '1': once = 1; break;
      default: return 100;
    }
  }
  srandom((unsigned)(time(NULL) ^ getpid()));
  read_config(config);
  if (!nservers && !nfallbacks) {
    logmsg("no servers configured");
    return 1;
  }
  if (poll_max < poll_min) poll_max = poll_min;

  char stamp[512], synced[512];
  snprintf(stamp, sizeof stamp, "%s/clock", statedir);
  snprintf(synced, sizeof synced, "%s/synchronized", rundir);
  unlink(synced);

  /* A clock behind the last time we knew is wrong. */
  struct stat st;
  if (stat(stamp, &st) == 0) {
    double have = now_real();
    if ((double)st.st_mtime > have) {
      struct timespec ts = { .tv_sec = st.st_mtime };
      if (clock_settime(CLOCK_REALTIME, &ts) == 0) logmsg("clock set to the time of the last synchronization");
    }
  } else {
    touch_file(stamp);
  }

  signal(SIGPIPE, SIG_IGN);
  long interval = poll_min;
  int failures = 0;
  for (;;) {
    int ok = 0;
    double offset = 0, delay = 0;
    char **lists[2] = { servers, fallbacks };
    int counts[2] = { nservers, nfallbacks };
    for (int l = 0; l < 2 && !ok; l++) {
      for (int i = 0; i < counts[l] && !ok; i++) {
        if (query(lists[l][i], &offset, &delay) == 0) {
          ok = 1;
          logmsg("%s: offset %+.6fs, delay %.6fs", lists[l][i], offset, delay);
        }
      }
    }
    if (ok) {
      failures = 0;
      if (offset > 0.4 || offset < -0.4) {
        struct timespec ts;
        double t = now_real() + offset;
        ts.tv_sec = (time_t)t;
        ts.tv_nsec = (long)((t - (double)ts.tv_sec) * 1e9);
        if (clock_settime(CLOCK_REALTIME, &ts) < 0) logmsg("cannot set the clock: %s", strerror(errno));
        else logmsg("clock stepped by %+.3fs", offset);
        interval = poll_min;
      } else {
        struct timeval d;
        d.tv_sec = (time_t)offset;
        d.tv_usec = (suseconds_t)((offset - (double)d.tv_sec) * 1e6);
        if (adjtime(&d, NULL) < 0) logmsg("cannot slew the clock: %s", strerror(errno));
        interval = interval * 2 > poll_max ? poll_max : interval * 2;
      }
      touch_file(stamp);
      touch_file(synced);
      if (once) return 0;
      sleep((unsigned)interval);
    } else {
      failures++;
      logmsg("no server answered (%d)", failures);
      /* the network may not be up yet: ask again soon, a little less often each time */
      long wait = 5L << (failures < 6 ? failures : 6);
      if (wait > poll_max) wait = poll_max;
      sleep((unsigned)wait);
    }
  }
}

/*
 * unit-timer - run a command when a systemd .timer unit would fire.
 *
 *   unit-timer [--name NAME] [--stamp FILE] SETTING=VALUE… -- command [args…]
 *   unit-timer --check SETTING=VALUE…
 *   unit-timer --next 'CALENDAR EXPRESSION'
 *
 * The settings are those of the [Timer] section (systemd.timer(5)):
 * OnCalendar=, OnActiveSec=, OnBootSec=, OnStartupSec=, OnUnitActiveSec=,
 * OnUnitInactiveSec=, Persistent=, RandomizedDelaySec=, FixedRandomDelay=.
 * AccuracySec= and WakeSystem= are accepted and have no effect: the timer
 * fires on time, and does not wake the machine.
 *
 * One process per timer, meant to be supervised.  It sleeps until the next
 * elapse, runs the command and waits for it, then starts over; a timer never
 * runs its command twice at the same time.
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static const char *prog_name = "unit-timer";

static void msg(const char *fmt, ...) {
  va_list ap;
  fprintf(stderr, "%s: ", prog_name);
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
}

/* ---------------------------------------------------------------------- */
/* time spans: "15min", "1h 30min", "2.5s", "90" (seconds)                  */

static int parse_span(const char *s, double *out) {
  static const struct { const char *name; double mult; } units[] = {
    {"usec", 1e-6}, {"us", 1e-6}, {"msec", 1e-3}, {"ms", 1e-3},
    {"seconds", 1}, {"second", 1}, {"sec", 1}, {"s", 1},
    {"minutes", 60}, {"minute", 60}, {"min", 60}, {"m", 60},
    {"hours", 3600}, {"hour", 3600}, {"hr", 3600}, {"h", 3600},
    {"days", 86400}, {"day", 86400}, {"d", 86400},
    {"weeks", 604800}, {"week", 604800}, {"w", 604800},
    {"months", 2629800}, {"month", 2629800}, {"M", 2629800},
    {"years", 31557600}, {"year", 31557600}, {"y", 31557600},
  };
  double total = 0;
  int any = 0;
  while (*s) {
    while (isspace((unsigned char)*s)) s++;
    if (!*s) break;
    char *end;
    double v = strtod(s, &end);
    if (end == s) return -1;
    s = end;
    while (isspace((unsigned char)*s)) s++;
    const char *u = s;
    while (isalpha((unsigned char)*s)) s++;
    size_t ul = (size_t)(s - u);
    double mult = 1;
    if (ul) {
      size_t i, n = sizeof units / sizeof *units;
      for (i = 0; i < n; i++)
        if (strlen(units[i].name) == ul && !strncmp(units[i].name, u, ul)) { mult = units[i].mult; break; }
      if (i == n) return -1;
    }
    total += v * mult;
    any = 1;
  }
  if (!any) return -1;
  *out = total;
  return 0;
}

static int parse_bool(const char *s) {
  return !strcasecmp(s, "yes") || !strcasecmp(s, "true") || !strcasecmp(s, "on") || !strcmp(s, "1");
}

/* ---------------------------------------------------------------------- */
/* calendar expressions                                                     */

/* A set of small non-negative integers, plus "last day" offsets for days. */
struct field {
  int any;                 /* "*" */
  unsigned char set[64];   /* values 0..63 (year - 1970 is clamped elsewhere) */
};

struct calendar {
  unsigned weekdays;       /* bit 0 = Monday … bit 6 = Sunday; 0 = any */
  int year_any;
  int year_from, year_to, year_step;   /* simple forms only */
  struct field month, day, hour, minute, second;
  int day_from_end;        /* "~": day counts back from the end of the month */
  char tz[64];             /* "" = local time */
};

static int weekday_index(const char *s, size_t n) {
  static const char *names[] = {"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"};
  for (int i = 0; i < 7; i++)
    if (n >= 3 && n <= strlen(names[i]) && !strncasecmp(s, names[i], n) && (n == 3 || n == strlen(names[i])))
      return i;
  return -1;
}

/* Parse one date or time component into f: a value, a range a..b, a list
 * a,b,c, "*", and any of these followed by /STEP. */
static int parse_field(const char *s, size_t len, int min, int max, struct field *f) {
  memset(f, 0, sizeof *f);
  char buf[128];
  if (len >= sizeof buf) return -1;
  memcpy(buf, s, len);
  buf[len] = 0;
  char *save = NULL;
  for (char *tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
    int from, to, step = 0;
    char *slash = strchr(tok, '/');
    if (slash) {
      *slash = 0;
      step = atoi(slash + 1);
      if (step <= 0) return -1;
    }
    if (!strcmp(tok, "*")) {
      if (!step) { f->any = 1; continue; }
      from = min; to = max;
    } else {
      char *dots = strstr(tok, "..");
      char *end;
      if (dots) {
        *dots = 0;
        from = (int)strtol(tok, &end, 10);
        if (*end) return -1;
        to = (int)strtol(dots + 2, &end, 10);
        if (*end) return -1;
      } else {
        from = (int)strtol(tok, &end, 10);
        /* seconds may carry a fraction; whole seconds are all we fire on */
        if (*end == '.') { end++; while (isdigit((unsigned char)*end)) end++; }
        if (*end || end == tok) return -1;
        to = step ? max : from;
      }
    }
    if (from < min || to > max || from > to) return -1;
    if (!step) step = 1;
    for (int v = from; v <= to; v += step) f->set[v] = 1;
  }
  return 0;
}

static int field_has(const struct field *f, int v) {
  return f->any || (v >= 0 && v < 64 && f->set[v]);
}

static void field_all(struct field *f) { memset(f, 0, sizeof *f); f->any = 1; }
static void field_one(struct field *f, int v) { memset(f, 0, sizeof *f); f->set[v] = 1; }

static int parse_calendar(const char *expr, struct calendar *c) {
  memset(c, 0, sizeof *c);
  c->year_any = 1;
  field_all(&c->month); field_all(&c->day);
  field_one(&c->hour, 0); field_one(&c->minute, 0); field_one(&c->second, 0);

  char buf[256];
  if (strlen(expr) >= sizeof buf) return -1;
  strcpy(buf, expr);

  /* shorthands */
  static const struct { const char *name; const char *expansion; } shorthands[] = {
    {"minutely", "*-*-* *:*:00"}, {"hourly", "*-*-* *:00:00"}, {"daily", "*-*-* 00:00:00"},
    {"monthly", "*-*-01 00:00:00"}, {"weekly", "Mon *-*-* 00:00:00"},
    {"yearly", "*-01-01 00:00:00"}, {"annually", "*-01-01 00:00:00"},
    {"quarterly", "*-01,04,07,10-01 00:00:00"}, {"semiannually", "*-01,07-01 00:00:00"},
  };

  char *words[8];
  int nw = 0;
  char *save = NULL;
  for (char *w = strtok_r(buf, " \t", &save); w && nw < 8; w = strtok_r(NULL, " \t", &save)) words[nw++] = w;
  if (!nw) return -1;

  /* trailing time zone */
  if (nw > 1) {
    const char *last = words[nw - 1];
    if (!strcmp(last, "UTC") || (isalpha((unsigned char)last[0]) && strchr(last, '/'))) {
      snprintf(c->tz, sizeof c->tz, "%s", last);
      nw--;
    }
  }
  if (nw == 1) {
    for (size_t i = 0; i < sizeof shorthands / sizeof *shorthands; i++)
      if (!strcasecmp(words[0], shorthands[i].name)) {
        char tz[64];
        snprintf(tz, sizeof tz, "%s", c->tz);
        int r = parse_calendar(shorthands[i].expansion, c);
        snprintf(c->tz, sizeof c->tz, "%s", tz);
        return r;
      }
  }

  int have_date = 0, have_time = 0, have_wd = 0;
  for (int i = 0; i < nw; i++) {
    char *w = words[i];
    if (isalpha((unsigned char)w[0])) {
      /* weekdays: Mon,Tue  Mon..Fri  Sat,Sun */
      if (have_wd || have_date || have_time) return -1;
      have_wd = 1;
      char *s2 = NULL;
      for (char *tok = strtok_r(w, ",", &s2); tok; tok = strtok_r(NULL, ",", &s2)) {
        char *dots = strstr(tok, "..");
        if (dots) {
          int a = weekday_index(tok, (size_t)(dots - tok));
          int b = weekday_index(dots + 2, strlen(dots + 2));
          if (a < 0 || b < 0) return -1;
          for (int d = a;; d = (d + 1) % 7) { c->weekdays |= 1u << d; if (d == b) break; }
        } else {
          int a = weekday_index(tok, strlen(tok));
          if (a < 0) return -1;
          c->weekdays |= 1u << a;
        }
      }
    } else if (strchr(w, ':')) {
      if (have_time) return -1;
      have_time = 1;
      char *p1 = strchr(w, ':');
      char *p2 = strchr(p1 + 1, ':');
      if (parse_field(w, (size_t)(p1 - w), 0, 23, &c->hour) < 0) return -1;
      if (p2) {
        if (parse_field(p1 + 1, (size_t)(p2 - p1 - 1), 0, 59, &c->minute) < 0) return -1;
        if (parse_field(p2 + 1, strlen(p2 + 1), 0, 59, &c->second) < 0) return -1;
      } else {
        if (parse_field(p1 + 1, strlen(p1 + 1), 0, 59, &c->minute) < 0) return -1;
      }
    } else {
      /* date: [YEAR-]MONTH-DAY, with "~" before the day to count from the end */
      if (have_date || have_time) return -1;
      have_date = 1;
      char *daysep = strrchr(w, '~');
      if (daysep) c->day_from_end = 1;
      else daysep = strrchr(w, '-');
      if (!daysep) return -1;
      *daysep = 0;
      if (parse_field(daysep + 1, strlen(daysep + 1), c->day_from_end ? 1 : 1, 31, &c->day) < 0) return -1;
      char *monsep = strrchr(w, '-');
      const char *mon = monsep ? monsep + 1 : w;
      if (parse_field(mon, strlen(mon), 1, 12, &c->month) < 0) return -1;
      if (monsep) {
        *monsep = 0;
        if (strcmp(w, "*")) {
          char *end, *dots = strstr(w, "..");
          char *slash = strchr(w, '/');
          c->year_any = 0;
          c->year_step = 1;
          if (slash) { *slash = 0; c->year_step = atoi(slash + 1); if (c->year_step <= 0) return -1; }
          if (dots) {
            *dots = 0;
            c->year_from = (int)strtol(w, &end, 10);
            if (*end) return -1;
            c->year_to = (int)strtol(dots + 2, &end, 10);
            if (*end) return -1;
          } else if (!strcmp(w, "*")) {
            c->year_from = 1970; c->year_to = 2199;
          } else {
            c->year_from = (int)strtol(w, &end, 10);
            if (*end) return -1;
            c->year_to = slash ? 2199 : c->year_from;
          }
        }
      }
    }
  }
  return 0;
}

static int year_matches(const struct calendar *c, int year) {
  if (c->year_any) return 1;
  if (year < c->year_from || year > c->year_to) return 0;
  return (year - c->year_from) % c->year_step == 0;
}

static int days_in_month(int year, int mon /* 0-11 */) {
  static const int d[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  if (mon == 1 && ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0)) return 29;
  return d[mon];
}

/* First matching instant strictly after `after`, or (time_t)-1. */
static time_t calendar_next(const struct calendar *c, time_t after) {
  char *oldtz = NULL;
  if (c->tz[0]) {
    const char *cur = getenv("TZ");
    if (cur) oldtz = strdup(cur);
    setenv("TZ", c->tz, 1);
    tzset();
  }
  time_t t = after + 1, result = (time_t)-1;
  for (int guard = 0; guard < 200000; guard++) {
    struct tm tm;
    localtime_r(&t, &tm);
    int year = tm.tm_year + 1900;
    if (year > 2199) break;
    if (!year_matches(c, year)) {
      tm.tm_year++; tm.tm_mon = 0; tm.tm_mday = 1; tm.tm_hour = tm.tm_min = tm.tm_sec = 0; tm.tm_isdst = -1;
      t = mktime(&tm);
      continue;
    }
    if (!field_has(&c->month, tm.tm_mon + 1)) {
      tm.tm_mon++; tm.tm_mday = 1; tm.tm_hour = tm.tm_min = tm.tm_sec = 0; tm.tm_isdst = -1;
      t = mktime(&tm);
      continue;
    }
    int day = c->day_from_end ? days_in_month(year, tm.tm_mon) - tm.tm_mday + 1 : tm.tm_mday;
    int wd = (tm.tm_wday + 6) % 7;      /* Monday = 0 */
    if (!field_has(&c->day, day) || (c->weekdays && !(c->weekdays & (1u << wd)))) {
      tm.tm_mday++; tm.tm_hour = tm.tm_min = tm.tm_sec = 0; tm.tm_isdst = -1;
      t = mktime(&tm);
      continue;
    }
    if (!field_has(&c->hour, tm.tm_hour)) {
      tm.tm_hour++; tm.tm_min = tm.tm_sec = 0; tm.tm_isdst = -1;
      time_t n = mktime(&tm);
      t = n > t ? n : t + 3600;       /* guard against DST folds */
      continue;
    }
    if (!field_has(&c->minute, tm.tm_min)) {
      tm.tm_min++; tm.tm_sec = 0; tm.tm_isdst = -1;
      time_t n = mktime(&tm);
      t = n > t ? n : t + 60;
      continue;
    }
    if (!field_has(&c->second, tm.tm_sec)) { t++; continue; }
    result = t;
    break;
  }
  if (c->tz[0]) {
    if (oldtz) { setenv("TZ", oldtz, 1); free(oldtz); } else unsetenv("TZ");
    tzset();
  }
  return result;
}

/* ---------------------------------------------------------------------- */

#define MAX_SPECS 32

enum kind { ON_CALENDAR, ON_ACTIVE, ON_BOOT, ON_UNIT_ACTIVE, ON_UNIT_INACTIVE };

struct spec {
  enum kind kind;
  struct calendar cal;
  double span;
};

static struct spec specs[MAX_SPECS];
static int nspecs;
static int persistent, fixed_random;
static double random_delay;

static double boottime(void) {
  struct timespec ts;
  clock_gettime(CLOCK_BOOTTIME, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static double realtime(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int add_setting(const char *arg) {
  const char *eq = strchr(arg, '=');
  if (!eq) return -1;
  size_t kl = (size_t)(eq - arg);
  const char *val = eq + 1;
#define KEY(k) (kl == strlen(k) && !strncmp(arg, k, kl))
  if (KEY("OnCalendar")) {
    if (nspecs >= MAX_SPECS) return -1;
    specs[nspecs].kind = ON_CALENDAR;
    if (parse_calendar(val, &specs[nspecs].cal) < 0) return -1;
    nspecs++;
    return 0;
  }
  enum kind k;
  if (KEY("OnActiveSec")) k = ON_ACTIVE;
  else if (KEY("OnBootSec") || KEY("OnStartupSec")) k = ON_BOOT;
  else if (KEY("OnUnitActiveSec")) k = ON_UNIT_ACTIVE;
  else if (KEY("OnUnitInactiveSec")) k = ON_UNIT_INACTIVE;
  else if (KEY("Persistent")) { persistent = parse_bool(val); return 0; }
  else if (KEY("FixedRandomDelay")) { fixed_random = parse_bool(val); return 0; }
  else if (KEY("RandomizedDelaySec")) return parse_span(val, &random_delay);
  else if (KEY("AccuracySec") || KEY("WakeSystem") || KEY("RemainAfterElapse") || KEY("OnClockChange")
           || KEY("OnTimezoneChange") || KEY("RandomizedOffsetSec") || KEY("DeferReactivation")) return 0;
  else return -1;
#undef KEY
  if (nspecs >= MAX_SPECS) return -1;
  specs[nspecs].kind = k;
  if (parse_span(val, &specs[nspecs].span) < 0) return -1;
  nspecs++;
  return 0;
}

static volatile sig_atomic_t stop;
static void on_term(int sig) { (void)sig; stop = 1; }

static double read_stamp(const char *path) {
  struct stat st;
  if (!path || stat(path, &st) < 0) return 0;
  return (double)st.st_mtim.tv_sec;
}

static void touch_stamp(const char *path) {
  if (!path) return;
  int fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
  if (fd < 0) return;
  futimens(fd, NULL);
  close(fd);
}

int main(int argc, char **argv) {
  const char *name = NULL, *stamp = NULL;
  int check = 0, i;

  for (i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--")) { i++; break; }
    if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
    else if (!strcmp(argv[i], "--stamp") && i + 1 < argc) stamp = argv[++i];
    else if (!strcmp(argv[i], "--check")) check = 1;
    else if (!strcmp(argv[i], "--next") && i + 1 < argc) {
      struct calendar c;
      if (parse_calendar(argv[++i], &c) < 0) { msg("cannot parse '%s'", argv[i]); return 1; }
      time_t n = calendar_next(&c, time(NULL));
      if (n == (time_t)-1) { puts("never"); return 0; }
      char buf[64];
      struct tm tm;
      localtime_r(&n, &tm);
      strftime(buf, sizeof buf, "%a %Y-%m-%d %H:%M:%S %Z", &tm);
      puts(buf);
      return 0;
    } else if (add_setting(argv[i]) < 0) {
      msg("cannot parse '%s'", argv[i]);
      return check ? 1 : 100;
    }
  }
  if (check) return 0;
  if (name) prog_name = name;
  if (i >= argc) { msg("usage: unit-timer [--name N] [--stamp F] SETTING=VALUE… -- command…"); return 100; }
  if (!nspecs) { msg("no timer setting given, nothing will ever happen"); }

  struct sigaction sa = { .sa_handler = on_term };
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);

  srandom((unsigned)(time(NULL) ^ getpid()));
  double fixed_offset = random_delay > 0 ? ((double)random() / RAND_MAX) * random_delay : 0;
  if (fixed_random && name) {
    /* the same delay on every boot: derive it from the timer's name */
    unsigned h = 5381;
    for (const char *p = name; *p; p++) h = h * 33 + (unsigned char)*p;
    fixed_offset = ((double)(h % 100000) / 100000.0) * random_delay;
  }

  double started_boot = boottime();
  double last_active = 0, last_inactive = 0;   /* in boot time; 0 = never */
  int boot_fired = 0, active_fired = 0;
  double last_trigger_real = read_stamp(stamp);

  for (;;) {
    /* Work out the next elapse as a point on the realtime clock. */
    double now_real = realtime(), now_boot = boottime();
    double next = -1;
    for (int s = 0; s < nspecs; s++) {
      double cand = -1;
      switch (specs[s].kind) {
        case ON_CALENDAR: {
          double base = now_real;
          if (persistent && last_trigger_real > 0 && last_trigger_real < now_real) base = last_trigger_real;
          time_t n = calendar_next(&specs[s].cal, (time_t)base);
          if (n != (time_t)-1) cand = (double)n;
          break;
        }
        case ON_ACTIVE:
          if (!active_fired) cand = now_real + (started_boot + specs[s].span - now_boot);
          break;
        case ON_BOOT:
          if (!boot_fired) cand = now_real + (specs[s].span - now_boot);
          break;
        case ON_UNIT_ACTIVE:
          if (last_active > 0) cand = now_real + (last_active + specs[s].span - now_boot);
          break;
        case ON_UNIT_INACTIVE:
          if (last_inactive > 0) cand = now_real + (last_inactive + specs[s].span - now_boot);
          break;
      }
      if (cand >= 0 && (next < 0 || cand < next)) next = cand;
    }

    if (next < 0) {
      /* nothing scheduled: stay around so that the supervisor sees us up */
      while (!stop) pause();
      return 0;
    }
    if (random_delay > 0)
      next += fixed_random ? fixed_offset : ((double)random() / RAND_MAX) * random_delay;

    /* Sleep in short steps: clock changes and suspend are noticed that way. */
    while (!stop) {
      double remaining = next - realtime();
      if (remaining <= 0) break;
      struct timespec ts;
      double step = remaining > 60 ? 60 : remaining;
      ts.tv_sec = (time_t)step;
      ts.tv_nsec = (long)((step - (double)ts.tv_sec) * 1e9);
      nanosleep(&ts, NULL);
    }
    if (stop) return 0;

    boot_fired = active_fired = 1;
    last_active = boottime();
    last_trigger_real = realtime();
    touch_stamp(stamp);

    pid_t pid = fork();
    if (pid < 0) {
      msg("fork: %s", strerror(errno));
      sleep(5);
      continue;
    }
    if (pid == 0) {
      signal(SIGTERM, SIG_DFL);
      signal(SIGINT, SIG_DFL);
      execvp(argv[i], argv + i);
      msg("exec %s: %s", argv[i], strerror(errno));
      _exit(127);
    }
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
      if (stop) kill(pid, SIGTERM);
    }
    last_inactive = boottime();
    if (stop) return 0;
  }
}

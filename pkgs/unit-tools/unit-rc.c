/*
 * unit-rc - the service graph of the machine, for runit.
 *
 * runit starts and supervises processes (runsvdir, runsv) but knows nothing of
 * what a service needs: this is what does, with the descriptions unitc writes
 * (runit/ in the unit database; the syntax and the properties are dinit's, of
 * which only a few are read).  The processes of a service are run by runsv,
 * under unit-supervise (which says in /run/units/.sv/ATOM whether they are
 * up and ready), the rest - oneshots, the stop commands - by this program.
 *
 *   unit-rc daemon [-t SERVICE] [options]    the service manager
 *   unit-rc prepare [options]                (before runsvdir) the service
 *                                            directories of the database
 *   unit-rc [-p SOCKET] [--quiet] COMMAND [options] [SERVICE]
 *                                            talk to it, dinitctl's way:
 *       list
 *       status SERVICE
 *       start [--no-wait] SERVICE      with what it requires and waits for
 *       stop [--force] [--ignore-unstarted] [--no-wait] SERVICE
 *                                      with what requires it
 *       restart [--force] SERVICE      and what required it
 *       reload SERVICE                 read its description again
 *       unload SERVICE                 forget it (when stopped)
 *       rescan                         the database has changed: directories
 *                                      for the new processes, none for the
 *                                      ones that are gone
 *
 * Options (daemon, prepare):
 *   -d DIR   descriptions (default /run/units/.db/runit)
 *   -r DIR   runsvdir's service directory (default /run/units/rsv)
 *   -s DIR   unit-supervise's status directory (default /run/units/.sv)
 *   -p SOCK  control socket (default /run/rcctl)
 *   -b SH    shell for the run scripts (default /bin/sh)
 *
 * A requirement (depends-on) that fails fails what needs it; a waits-for or
 * an after does not: the first starts its target and waits for it, the
 * second only waits if the target is being started anyway.  Stopping a
 * service stops what depends on it first.  What a service needs is not
 * stopped with it.
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static const char *desc_dir = "/run/units/.db/runit";
static const char *rsv_dir = "/run/units/rsv";
static const char *sv_dir = "/run/units/.sv";
static const char *sock_path = "/run/rcctl";
static const char *sh_path = "/bin/sh";

enum { T_INTERNAL, T_SCRIPTED, T_PROCESS };
enum { D_HARD, D_SOFT, D_AFTER };
enum { ST_STOPPED, ST_WAITDEPS, ST_STARTING, ST_STARTED, ST_STOPWAIT, ST_STOPPING };

typedef struct svc svc;
struct dep {
  char *name;
  int kind;
  svc *s;
};
struct rdep {
  svc *s;
  int kind;
};
struct svc {
  char *name;
  int type;
  char **cmd, **stop_cmd, **log_cmd;
  char *workdir, *logfile, *consumer_of, *atom;
  int ready, log_pipe;
  long start_ms, stop_ms;
  struct dep *deps;
  int ndeps;
  struct rdep *rdeps;
  int nrdeps, caprdeps;
  int state, want, failed, restart_after, queued, explicit_;
  char *why;
  /* the action in progress */
  pid_t pid;
  long long since, deadline, hard_deadline;
  int sent, timed_out;
  int loaded_ok;
};

static svc **svcs;
static int nsvcs, capsvcs;
static svc **queue;
static int nqueue, capqueue;

static long long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void say(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "unit-rc: ");
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
}

static int debug;
#define dbg(...) do { if (debug) say(__VA_ARGS__); } while (0)

static void *xrealloc(void *p, size_t n) {
  p = realloc(p, n ? n : 1);
  if (!p) { say("out of memory"); exit(111); }
  return p;
}
static char *xstrdup(const char *s) {
  char *r = strdup(s);
  if (!r) { say("out of memory"); exit(111); }
  return r;
}

/* ---------------------------------------------------------------------- */
/* descriptions */

static char *trim(char *s) {
  while (isspace((unsigned char)*s)) s++;
  char *e = s + strlen(s);
  while (e > s && isspace((unsigned char)e[-1])) *--e = 0;
  return s;
}

/* A dinit command line as an argument vector: words separated by blanks;
 * "…" holds blanks; \x is x; $$ is $. */
static char **parse_cmd(const char *s) {
  char **argv = NULL;
  int n = 0;
  char *w = xrealloc(NULL, strlen(s) + 1);
  for (;;) {
    while (*s == ' ' || *s == '\t') s++;
    if (!*s) break;
    size_t l = 0;
    int q = 0;
    while (*s && (q || (*s != ' ' && *s != '\t'))) {
      if (*s == '"') { q = !q; s++; }
      else if (*s == '\\' && s[1]) { w[l++] = s[1]; s += 2; }
      else if (*s == '$' && s[1] == '$') { w[l++] = '$'; s += 2; }
      else w[l++] = *s++;
    }
    w[l] = 0;
    argv = xrealloc(argv, (n + 2) * sizeof *argv);
    argv[n++] = xstrdup(w);
  }
  free(w);
  if (!argv) return NULL;
  argv[n] = NULL;
  return argv;
}

static long ms_of(const char *v) {
  double d = atof(v);
  return d > 0 ? (long)(d * 1000.0 + 0.5) : 0;
}

static svc *new_svc(const char *name) {
  svc *s = xrealloc(NULL, sizeof *s);
  memset(s, 0, sizeof *s);
  s->name = xstrdup(name);
  return s;
}

static void free_argv(char **a) {
  if (!a) return;
  for (char **p = a; *p; p++) free(*p);
  free(a);
}

static void clear_desc(svc *s) {
  free_argv(s->cmd); free_argv(s->stop_cmd); free_argv(s->log_cmd);
  free(s->workdir); free(s->logfile); free(s->consumer_of); free(s->atom);
  for (int i = 0; i < s->ndeps; i++) free(s->deps[i].name);
  free(s->deps);
  s->cmd = s->stop_cmd = s->log_cmd = NULL;
  s->workdir = s->logfile = s->consumer_of = s->atom = NULL;
  s->deps = NULL;
  s->ndeps = 0;
  s->ready = s->log_pipe = 0;
  s->start_ms = s->stop_ms = 0;
}

/* Reads DESC/NAME into S.  0, or -1 when it cannot be read. */
static int read_desc(svc *s) {
  char path[PATH_MAX];
  snprintf(path, sizeof path, "%s/%s", desc_dir, s->name);
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  clear_desc(s);
  s->type = T_INTERNAL;
  char *line = NULL;
  size_t cap = 0;
  while (getline(&line, &cap, f) >= 0) {
    char *l = trim(line);
    if (!*l || *l == '#') continue;
    static const struct { const char *kw; int kind; } kws[] = {
      {"depends-on:", D_HARD}, {"depends-ms:", D_HARD}, {"waits-for:", D_SOFT}, {"after:", D_AFTER},
    };
    int isdep = 0;
    for (size_t i = 0; i < sizeof kws / sizeof *kws; i++) {
      size_t n = strlen(kws[i].kw);
      if (!strncmp(l, kws[i].kw, n)) {
        s->deps = xrealloc(s->deps, (s->ndeps + 1) * sizeof *s->deps);
        s->deps[s->ndeps].name = xstrdup(trim(l + n));
        s->deps[s->ndeps].kind = kws[i].kind;
        s->deps[s->ndeps].s = NULL;
        s->ndeps++;
        isdep = 1;
        break;
      }
    }
    if (isdep) continue;
    char *eq = strchr(l, '=');
    if (!eq) continue;
    *eq = 0;
    char *k = trim(l), *v = trim(eq + 1);
    if (!strcmp(k, "type")) {
      s->type = !strcmp(v, "process") ? T_PROCESS : !strcmp(v, "scripted") ? T_SCRIPTED : T_INTERNAL;
    } else if (!strcmp(k, "command")) { free_argv(s->cmd); s->cmd = parse_cmd(v); }
    else if (!strcmp(k, "stop-command")) { free_argv(s->stop_cmd); s->stop_cmd = parse_cmd(v); }
    else if (!strcmp(k, "log-command")) { free_argv(s->log_cmd); s->log_cmd = parse_cmd(v); }
    else if (!strcmp(k, "working-dir")) { free(s->workdir); s->workdir = xstrdup(v); }
    else if (!strcmp(k, "logfile")) { free(s->logfile); s->logfile = xstrdup(v); }
    else if (!strcmp(k, "consumer-of")) { free(s->consumer_of); s->consumer_of = xstrdup(v); }
    else if (!strcmp(k, "ready-notification")) s->ready = 1;
    else if (!strcmp(k, "log-type")) s->log_pipe = !strcmp(v, "pipe");
    else if (!strcmp(k, "start-timeout")) s->start_ms = ms_of(v);
    else if (!strcmp(k, "stop-timeout")) s->stop_ms = ms_of(v);
  }
  free(line);
  fclose(f);
  if (s->type != T_INTERNAL && !s->cmd) s->type = T_INTERNAL;
  /* the name unit-supervise knows a process by: its -a */
  if (s->type == T_PROCESS) {
    for (char **p = s->cmd; *p; p++)
      if (!strcmp(*p, "-a") && p[1]) { s->atom = xstrdup(p[1]); break; }
    if (!s->atom) s->atom = xstrdup(s->name);
  }
  return 0;
}

static svc *find(const char *name) {
  for (int i = 0; i < nsvcs; i++)
    if (!strcmp(svcs[i]->name, name)) return svcs[i];
  return NULL;
}

static void add_rdep(svc *to, svc *from, int kind) {
  if (to->nrdeps == to->caprdeps) {
    to->caprdeps = to->caprdeps ? to->caprdeps * 2 : 4;
    to->rdeps = xrealloc(to->rdeps, to->caprdeps * sizeof *to->rdeps);
  }
  to->rdeps[to->nrdeps].s = from;
  to->rdeps[to->nrdeps].kind = kind;
  to->nrdeps++;
}

static void del_rdeps_of(svc *from) {
  for (int i = 0; i < from->ndeps; i++) {
    svc *d = from->deps[i].s;
    if (!d) continue;
    for (int j = 0; j < d->nrdeps;)
      if (d->rdeps[j].s == from) d->rdeps[j] = d->rdeps[--d->nrdeps];
      else j++;
    from->deps[i].s = NULL;
  }
}

/* Resolves the dependencies of S, loading what is not loaded.  0, or -1 when
 * one of them has no description. */
static svc *load(const char *name);
static int link_deps(svc *s) {
  int rc = 0;
  for (int i = 0; i < s->ndeps; i++) {
    if (s->deps[i].s) continue;
    svc *d = load(s->deps[i].name);
    if (!d) { rc = -1; continue; }
    s->deps[i].s = d;
    add_rdep(d, s, s->deps[i].kind);
  }
  return rc;
}

static svc *load(const char *name) {
  svc *s = find(name);
  if (s) return s;
  if (strchr(name, '/') || name[0] == '.' || !*name) return NULL;
  s = new_svc(name);
  if (read_desc(s) < 0) { free(s->name); free(s); return NULL; }
  if (nsvcs == capsvcs) {
    capsvcs = capsvcs ? capsvcs * 2 : 256;
    svcs = xrealloc(svcs, capsvcs * sizeof *svcs);
  }
  svcs[nsvcs++] = s;
  /* (its dependencies: loaded now, each in turn) */
  link_deps(s);
  return s;
}

/* ---------------------------------------------------------------------- */
/* runsv's service directories */

static void sq_put(FILE *f, const char *s) {
  fputc('\'', f);
  for (; *s; s++) {
    if (*s == '\'') fputs("'\\''", f);
    else fputc(*s, f);
  }
  fputc('\'', f);
}

static int write_script(const char *path, const char *shell, const svc *s, char **cmd, int piped) {
  char tmp[PATH_MAX + 8];
  snprintf(tmp, sizeof tmp, "%s.new", path);
  FILE *f = fopen(tmp, "w");
  if (!f) return -1;
  fprintf(f, "#!%s\n", shell);
  if (s->workdir && strcmp(s->workdir, "/")) {
    fputs("cd ", f);
    sq_put(f, s->workdir);
    fputs(" || exit 111\n", f);
  }
  if (piped) fputs("exec 2>&1\n", f);
  else if (s->logfile) {
    fputs("exec >>", f);
    sq_put(f, s->logfile);
    fputs(" 2>&1\n", f);
  }
  fputs("exec", f);
  for (char **p = cmd; *p; p++) { fputc(' ', f); sq_put(f, *p); }
  fputc('\n', f);
  if (fchmod(fileno(f), 0755) < 0) {}
  if (fclose(f)) return -1;
  return rename(tmp, path);
}

/* The directory runsv is to supervise P in, and the logger's inside it.
 * It starts with a `down` file: nothing runs until it is asked to. */
static void make_rsv(const svc *p, const svc *logger) {
  char dir[PATH_MAX], path[PATH_MAX + 32], tmp[PATH_MAX];
  snprintf(dir, sizeof dir, "%s/%s", rsv_dir, p->name);
  snprintf(tmp, sizeof tmp, "%s/.new.%s", rsv_dir, p->name);
  struct stat st;
  int exists = stat(dir, &st) == 0;
  const char *where = exists ? dir : tmp;
  int piped = logger && logger->log_cmd;
  if (!exists) {
    mkdir(rsv_dir, 0755);
    mkdir(tmp, 0755);
    snprintf(path, sizeof path, "%s/down", tmp);
    int fd = open(path, O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) close(fd);
  }
  snprintf(path, sizeof path, "%s/run", where);
  if (write_script(path, sh_path, p, p->cmd, piped) < 0) say("%s: %s", path, strerror(errno));
  if (piped) {
    svc plain;
    memset(&plain, 0, sizeof plain);
    snprintf(path, sizeof path, "%s/log", where);
    mkdir(path, 0755);
    snprintf(path, sizeof path, "%s/log/run", where);
    if (write_script(path, sh_path, &plain, logger->log_cmd, 0) < 0) say("%s: %s", path, strerror(errno));
  }
  if (!exists && rename(tmp, dir) < 0) say("%s: %s", dir, strerror(errno));
}

static svc *logger_of(const svc *p) {
  if (!p->log_pipe) return NULL;
  for (int i = 0; i < p->ndeps; i++)
    if (p->deps[i].s && p->deps[i].s->consumer_of && !strcmp(p->deps[i].s->consumer_of, p->name))
      return p->deps[i].s;
  return NULL;
}

/* Directories for every process of the database, none for what is gone.  A
 * temporary service table does for it: nothing is started. */
static void sync_rsv(void) {
  DIR *d = opendir(desc_dir);
  if (!d) { say("%s: %s", desc_dir, strerror(errno)); return; }
  struct dirent *e;
  svc **all = NULL;
  int n = 0;
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    svc *s = new_svc(e->d_name);
    if (read_desc(s) < 0) { free(s->name); free(s); continue; }
    all = xrealloc(all, (n + 1) * sizeof *all);
    all[n++] = s;
  }
  closedir(d);
  mkdir(rsv_dir, 0755);
  for (int i = 0; i < n; i++) {
    svc *p = all[i], *logger = NULL;
    if (p->type != T_PROCESS) continue;
    if (p->log_pipe) {
      for (int j = 0; j < n; j++)
        if (all[j]->consumer_of && !strcmp(all[j]->consumer_of, p->name)) { logger = all[j]; break; }
    }
    make_rsv(p, logger);
  }
  /* what has no description (or none for a process) any more */
  d = opendir(rsv_dir);
  if (d) {
    while ((e = readdir(d))) {
      if (e->d_name[0] == '.' || !strcmp(e->d_name, "unit-rc")) continue;
      int keep = 0;
      for (int i = 0; i < n; i++)
        if (all[i]->type == T_PROCESS && !strcmp(all[i]->name, e->d_name)) { keep = 1; break; }
      if (keep) continue;
      /* (runsvdir stops its runsv once the directory is gone) */
      char cmd[PATH_MAX + 16], ctl[PATH_MAX + 32];
      snprintf(ctl, sizeof ctl, "%s/%s/supervise/control", rsv_dir, e->d_name);
      int fd = open(ctl, O_WRONLY | O_NONBLOCK);
      if (fd >= 0) { if (write(fd, "dx", 2) < 0) {} close(fd); }
      snprintf(cmd, sizeof cmd, "%s/%s", rsv_dir, e->d_name);
      char gone[PATH_MAX + 16];
      snprintf(gone, sizeof gone, "%s/.gone.%s", rsv_dir, e->d_name);
      rename(cmd, gone);
    }
    closedir(d);
  }
  for (int i = 0; i < n; i++) { clear_desc(all[i]); free(all[i]->name); free(all[i]); }
  free(all);
}

static int rsv_ctl(const svc *s, char c) {
  char path[PATH_MAX + 32];
  snprintf(path, sizeof path, "%s/%s/supervise/control", rsv_dir, s->name);
  int fd = open(path, O_WRONLY | O_NONBLOCK);
  if (fd < 0) return -1;
  ssize_t r = write(fd, &c, 1);
  close(fd);
  return r == 1 ? 0 : -1;
}

/* the `down` file keeps a runsv that is started again from starting it */
static void rsv_down_file(const svc *s, int on) {
  char path[PATH_MAX + 32];
  snprintf(path, sizeof path, "%s/%s/down", rsv_dir, s->name);
  if (on) {
    int fd = open(path, O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) close(fd);
  } else {
    unlink(path);
  }
}

/* "run", "down" or "finish" - runsv's say; NULL if it is not there */
static int rsv_is_down(const svc *s) {
  char path[PATH_MAX + 32], buf[32] = "";
  snprintf(path, sizeof path, "%s/%s/supervise/stat", rsv_dir, s->name);
  int fd = open(path, O_RDONLY);
  if (fd < 0) return 1;
  ssize_t n = read(fd, buf, sizeof buf - 1);
  close(fd);
  if (n <= 0) return 0;
  return !strncmp(buf, "down", 4);
}

/* unit-supervise's status of a process: UP READY PID WANT SVPID PHASE */
struct sv_stat { int up, ready, pid, svpid; char phase[16]; };
static int sv_read(const svc *s, struct sv_stat *st) {
  char path[PATH_MAX + 32], line[128];
  snprintf(path, sizeof path, "%s/%s", sv_dir, s->atom);
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  char want = 0;
  memset(st, 0, sizeof *st);
  int n = 0;
  if (fgets(line, sizeof line, f))
    n = sscanf(line, "%d %d %d %c %d %15s", &st->up, &st->ready, &st->pid, &want, &st->svpid, st->phase);
  fclose(f);
  return n == 6 ? 0 : -1;
}

/* ---------------------------------------------------------------------- */
/* the graph */

static void poke(svc *s) {
  if (s->queued) return;
  s->queued = 1;
  if (nqueue == capqueue) {
    capqueue = capqueue ? capqueue * 2 : 64;
    queue = xrealloc(queue, capqueue * sizeof *queue);
  }
  queue[nqueue++] = s;
}

static void changed(svc *s) {
  /* what needs it, and what it needs (which may be waiting for it to stop) */
  for (int i = 0; i < s->nrdeps; i++) poke(s->rdeps[i].s);
  for (int i = 0; i < s->ndeps; i++) if (s->deps[i].s) poke(s->deps[i].s);
  poke(s);
}

static void settle_stopped(svc *s) {
  dbg("%s: stopped%s", s->name, s->restart_after ? " (to be started again)" : "");
  s->state = ST_STOPPED;
  s->pid = 0;
  s->since = 0;
  if (s->restart_after) {
    s->restart_after = 0;
    s->want = 1;
    s->failed = 0;
  }
  changed(s);
}

static void fail(svc *s, const char *why) {
  say("%s: %s", s->name, why);
  free(s->why);
  s->why = xstrdup(why);
  if (s->type == T_PROCESS && s->state != ST_STOPPED) {
    rsv_down_file(s, 1);
    rsv_ctl(s, 'd');
  }
  s->want = 0;
  s->failed = 1;
  s->restart_after = 0;
  s->state = ST_STOPPED;
  s->pid = 0;
  changed(s);
}

static pid_t spawn(const svc *s, char **argv) {
  pid_t pid = fork();
  if (pid != 0) return pid;
  /* the child */
  sigset_t none;
  sigemptyset(&none);
  sigprocmask(SIG_SETMASK, &none, NULL);
  for (int i = 1; i < NSIG; i++) signal(i, SIG_DFL);
  setsid();
  int fd = open("/dev/null", O_RDONLY);
  if (fd >= 0) { dup2(fd, 0); if (fd > 2) close(fd); }
  if (s->logfile) {
    fd = open(s->logfile, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); if (fd > 2) close(fd); }
  }
  if (chdir(s->workdir && *s->workdir ? s->workdir : "/") < 0) { if (chdir("/") < 0) {} }
  execvp(argv[0], argv);
  fprintf(stderr, "unit-rc: %s: %s\n", argv[0], strerror(errno));
  _exit(127);
}

static void begin_start(svc *s) {
  long long now = now_ms();
  dbg("%s: starting", s->name);
  s->since = now;
  s->timed_out = 0;
  s->sent = 0;
  s->deadline = s->start_ms > 0 ? now + s->start_ms : 0;
  s->hard_deadline = 0;
  switch (s->type) {
    case T_INTERNAL:
      s->state = ST_STARTED;
      changed(s);
      return;
    case T_SCRIPTED:
      s->state = ST_STARTING;
      s->pid = spawn(s, s->cmd);
      if (s->pid < 0) { s->pid = 0; fail(s, "cannot fork"); }
      return;
    case T_PROCESS: {
      s->state = ST_STARTING;
      /* the directory may be new (a database that was switched to) */
      char dir[PATH_MAX];
      struct stat st;
      snprintf(dir, sizeof dir, "%s/%s", rsv_dir, s->name);
      if (stat(dir, &st) < 0) make_rsv(s, logger_of(s));
      return;
    }
  }
}

/* Starting a process: told runsv to start it, then waiting for the status.
 * Called every tick. */
static void tick_start_process(svc *s, long long now) {
  if (!s->sent) {
    /* (what is there is from an earlier run) */
    char path[PATH_MAX + 32];
    snprintf(path, sizeof path, "%s/%s", sv_dir, s->atom);
    /* (the run before this one is over: its supervisor writes its status
     * as it goes, and must not do it over the new one's) */
    if (!rsv_is_down(s)) return;
    if (rsv_ctl(s, 'u') == 0) {
      unlink(path);
      /* (the directory of a service that was started with the file there
       * stays up if runsv is started again) */
      rsv_down_file(s, 0);
      /* (u again: the file may have been removed before runsv looked) */
      rsv_ctl(s, 'u');
      s->sent = 1;
      s->since = now;
      return;
    }
    if (now - s->since > 40000) fail(s, "runsv did not come up");
    return;
  }
  struct sv_stat st;
  int have = sv_read(s, &st) == 0;
  if (have && !strcmp(st.phase, "exit")) {
    fail(s, s->timed_out ? "timed out" : "the supervisor ended before the service was up");
    return;
  }
  if (have) {
    int ok = s->ready ? st.ready : (st.up || !strcmp(st.phase, "idle"));
    if (ok) {
      dbg("%s: started", s->name);
      s->state = ST_STARTED;
      s->deadline = 0;
      changed(s);
      return;
    }
  }
  if (s->deadline && now >= s->deadline && !s->timed_out) {
    /* start-timeout: as dinit does it, an interrupt for the supervisor (which
     * says it was that); runsv is told not to start it again */
    s->timed_out = 1;
    if (have && st.svpid > 1) kill(st.svpid, SIGINT);
    rsv_down_file(s, 1);
    rsv_ctl(s, 'd');
    s->hard_deadline = now + 20000;
  }
  if (s->timed_out && rsv_is_down(s)) { fail(s, "timed out"); return; }
  if (s->hard_deadline && now >= s->hard_deadline) {
    rsv_ctl(s, 'k');
    s->hard_deadline = 0;
    fail(s, "timed out");
  }
}

static void begin_stop(svc *s) {
  long long now = now_ms();
  dbg("%s: stopping", s->name);
  s->since = now;
  s->sent = 0;
  s->deadline = s->stop_ms > 0 ? now + s->stop_ms : 0;
  s->hard_deadline = 0;
  switch (s->type) {
    case T_INTERNAL:
      settle_stopped(s);
      return;
    case T_SCRIPTED:
      if (!s->stop_cmd) { settle_stopped(s); return; }
      s->state = ST_STOPPING;
      s->pid = spawn(s, s->stop_cmd);
      if (s->pid < 0) { s->pid = 0; settle_stopped(s); }
      return;
    case T_PROCESS:
      s->state = ST_STOPPING;
      rsv_down_file(s, 1);
      if (rsv_ctl(s, 'd') < 0) { settle_stopped(s); return; }
      s->sent = 1;
      return;
  }
}

static void tick_stop_process(svc *s, long long now) {
  struct sv_stat st;
  int have = sv_read(s, &st) == 0;
  int gone = !have || !strcmp(st.phase, "exit");
  if (gone && rsv_is_down(s)) { settle_stopped(s); return; }
  if (s->deadline && now >= s->deadline) {
    rsv_ctl(s, 'k');
    s->deadline = 0;
  }
  if (now - s->since > 300000) { say("%s: did not stop", s->name); settle_stopped(s); }
}

static void evaluate(svc *s) {
  if (s->want) {
    switch (s->state) {
      case ST_STOPPED: {
        s->state = ST_WAITDEPS;
        free(s->why);
        s->why = NULL;
        if (link_deps(s) < 0) { fail(s, "a dependency has no description"); return; }
        for (int i = 0; i < s->ndeps; i++) {
          svc *d = s->deps[i].s;
          if (s->deps[i].kind == D_AFTER) continue;
          /* (one that is being restarted is coming back as it is) */
          if (!d->want && !d->restart_after) { d->want = 1; d->failed = 0; }
          poke(d);
        }
      }
      /* fall through */
      case ST_WAITDEPS:
        for (int i = 0; i < s->ndeps; i++) {
          svc *d = s->deps[i].s;
          if (!d) { fail(s, "a dependency is missing"); return; }
          switch (s->deps[i].kind) {
            case D_HARD:
              if (d->state == ST_STARTED) break;
              if (d->state == ST_STOPPED && !d->want) { fail(s, "a dependency failed"); return; }
              return;
            case D_SOFT:
            case D_AFTER:
              if (d->state == ST_WAITDEPS || d->state == ST_STARTING || d->state == ST_STOPWAIT || d->state == ST_STOPPING) return;
              if (d->state == ST_STOPPED && d->want) return;
              break;
          }
        }
        begin_start(s);
        return;
      case ST_STOPWAIT:
        /* asked for again while it waited for what depends on it */
        s->state = ST_STARTED;
        return;
      default:
        return;
    }
  } else {
    switch (s->state) {
      case ST_WAITDEPS:
        s->state = ST_STOPPED;
        changed(s);
        return;
      case ST_STARTING:
        if (s->type == T_PROCESS) begin_stop(s);
        return;
      case ST_STARTED:
        s->state = ST_STOPWAIT;
        /* fall through */
      case ST_STOPWAIT: {
        int wait = 0;
        for (int i = 0; i < s->nrdeps; i++) {
          svc *r = s->rdeps[i].s;
          /* (one that waits to start has nothing running to stop; it goes on
           * waiting, and fails if this does not come back) */
          if (s->rdeps[i].kind != D_HARD || r->state == ST_STOPPED || r->state == ST_WAITDEPS) continue;
          if (r->want) { r->want = 0; r->failed = 0; }
          poke(r);
          wait = 1;
        }
        if (!wait) begin_stop(s);
        return;
      }
      default:
        return;
    }
  }
}

static void run_queue(void) {
  while (nqueue) {
    svc *s = queue[--nqueue];
    s->queued = 0;
    evaluate(s);
  }
}

/* The tick: processes that are starting or stopping are looked at. */
static int busy(void) {
  for (int i = 0; i < nsvcs; i++) {
    svc *s = svcs[i];
    if (s->type == T_PROCESS && (s->state == ST_STARTING || s->state == ST_STOPPING)) return 1;
  }
  return 0;
}

static void tick(void) {
  long long now = now_ms();
  for (int i = 0; i < nsvcs; i++) {
    svc *s = svcs[i];
    if (s->type == T_PROCESS) {
      if (s->state == ST_STARTING) tick_start_process(s, now);
      else if (s->state == ST_STOPPING) tick_stop_process(s, now);
    } else if (s->type == T_SCRIPTED && s->pid > 0 && s->deadline && now >= s->deadline) {
      say("%s: timed out", s->name);
      kill(-s->pid, SIGKILL);
      s->deadline = 0;
    }
  }
}

static void reap(void) {
  int status;
  pid_t pid;
  while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
    for (int i = 0; i < nsvcs; i++) {
      svc *s = svcs[i];
      if (s->pid != pid) continue;
      s->pid = 0;
      if (s->state == ST_STARTING) {
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
          s->state = ST_STARTED;
          changed(s);
        } else {
          char why[64];
          if (WIFSIGNALED(status)) snprintf(why, sizeof why, "killed by signal %d", WTERMSIG(status));
          else snprintf(why, sizeof why, "exited with status %d", WEXITSTATUS(status));
          fail(s, why);
        }
      } else if (s->state == ST_STOPPING) {
        settle_stopped(s);
      }
      break;
    }
  }
}

/* ---------------------------------------------------------------------- */
/* clients */

enum { W_START, W_STOP, W_RESTART };
struct client {
  int fd;
  char buf[512];
  size_t len;
  svc *wait;
  int kind;
};
static struct client *clients;
static int nclients;

static void reply(int fd, const char *fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  if (n > (int)sizeof buf - 1) n = sizeof buf - 1;
  if (write(fd, buf, n) < 0) {}
}

static void drop_client(int i) {
  close(clients[i].fd);
  clients[i] = clients[--nclients];
}

static const char *state_name(const svc *s) {
  switch (s->state) {
    case ST_STOPPED: return "stopped";
    case ST_WAITDEPS: case ST_STARTING: return "starting";
    case ST_STARTED: return "started";
    default: return "stopping";
  }
}

static void do_list(int fd) {
  for (int i = 0; i < nsvcs; i++) {
    svc *s = svcs[i];
    const char *l;
    switch (s->state) {
      case ST_STARTED: l = s->explicit_ ? "[{+}     ]" : "[[+]     ]"; break;
      case ST_WAITDEPS: case ST_STARTING: l = s->explicit_ ? "[{ }<<   ]" : "[[ ]<<   ]"; break;
      case ST_STOPWAIT: case ST_STOPPING: l = "[{ }  >> ]"; break;
      default: l = "[     {-}]"; break;
    }
    reply(fd, "%s %s\n", l, s->name);
  }
  reply(fd, "+OK\n");
}

static void do_status(int fd, svc *s) {
  reply(fd, "Service: %s\n    State: %s\n", s->name, state_name(s));
  reply(fd, "    Type: %s\n", s->type == T_PROCESS ? "process" : s->type == T_SCRIPTED ? "scripted" : "internal");
  if (s->failed && s->why) reply(fd, "    Stopped because: %s\n", s->why);
  if (s->type == T_PROCESS) {
    struct sv_stat st;
    if (sv_read(s, &st) == 0)
      reply(fd, "    Supervisor: %d, process: %d, up: %d, ready: %d, %s\n", st.svpid, st.pid, st.up, st.ready, st.phase);
  }
  for (int i = 0; i < s->ndeps; i++)
    reply(fd, "    %s: %s\n", s->deps[i].kind == D_HARD ? "depends-on" : s->deps[i].kind == D_SOFT ? "waits-for" : "after", s->deps[i].name);
  reply(fd, "+OK\n");
}

static void request_start(svc *s) {
  if (s->state == ST_STOPPED) s->failed = 0;
  s->want = 1;
  s->explicit_ = 1;
  poke(s);
}

static void collect_rdeps(svc *s, svc **set, int *n, int cap) {
  for (int i = 0; i < s->nrdeps; i++) {
    svc *r = s->rdeps[i].s;
    if (s->rdeps[i].kind != D_HARD) continue;
    int seen = 0;
    for (int j = 0; j < *n; j++) if (set[j] == r) { seen = 1; break; }
    if (seen || *n >= cap) continue;
    set[(*n)++] = r;
    collect_rdeps(r, set, n, cap);
  }
}

/* One request.  Returns 1 when the client has to wait for the answer. */
static int handle(struct client *c, char *line) {
  char cmd[32], name[PATH_MAX] = "";
  int nowait = 0, force = 0, ign = 0;
  int n = sscanf(line, "%31s %d %d %d %4095[^\n]", cmd, &nowait, &force, &ign, name);
  if (n < 1) { reply(c->fd, "-ERR bad request\n"); return 0; }
  if (!strcmp(cmd, "list")) { do_list(c->fd); return 0; }
  if (!strcmp(cmd, "rescan")) { sync_rsv(); reply(c->fd, "+OK\n"); return 0; }
  if (n < 5) { reply(c->fd, "-ERR no service named\n"); return 0; }
  svc *s;
  if (!strcmp(cmd, "unload")) {
    s = find(name);
    if (!s) { reply(c->fd, "-ERR service not loaded: %s\n", name); return 0; }
    if (s->state != ST_STOPPED || s->want) { reply(c->fd, "-ERR service is not stopped: %s\n", name); return 0; }
    if (s->nrdeps) {
      /* something loaded still refers to it */
      reply(c->fd, "-ERR service is needed by %s\n", s->rdeps[0].s->name);
      return 0;
    }
    del_rdeps_of(s);
    for (int i = 0; i < nsvcs; i++) if (svcs[i] == s) { svcs[i] = svcs[--nsvcs]; break; }
    clear_desc(s);
    free(s->name);
    free(s);
    reply(c->fd, "+OK\n");
    return 0;
  }
  if (!strcmp(cmd, "reload")) {
    s = find(name);
    if (!s) { reply(c->fd, "-ERR service not loaded: %s\n", name); return 0; }
    int type = s->type;
    svc *tmp = new_svc(name);
    if (read_desc(tmp) < 0) { free(tmp->name); free(tmp); reply(c->fd, "-ERR no description for %s\n", name); return 0; }
    if (s->state != ST_STOPPED && tmp->type != type) {
      clear_desc(tmp); free(tmp->name); free(tmp);
      reply(c->fd, "-ERR cannot change the type of a running service: %s\n", name);
      return 0;
    }
    /* take over what was read */
    del_rdeps_of(s);
    clear_desc(s);
    s->type = tmp->type; s->cmd = tmp->cmd; s->stop_cmd = tmp->stop_cmd; s->log_cmd = tmp->log_cmd;
    s->workdir = tmp->workdir; s->logfile = tmp->logfile; s->consumer_of = tmp->consumer_of; s->atom = tmp->atom;
    s->ready = tmp->ready; s->log_pipe = tmp->log_pipe; s->start_ms = tmp->start_ms; s->stop_ms = tmp->stop_ms;
    s->deps = tmp->deps; s->ndeps = tmp->ndeps;
    free(tmp->name); free(tmp);
    if (link_deps(s) < 0) { reply(c->fd, "-ERR a dependency of %s has no description\n", name); return 0; }
    if (s->type == T_PROCESS) make_rsv(s, logger_of(s));
    if (s->consumer_of) {
      /* (a logger: the producer's directory has its run script) */
      svc *p = find(s->consumer_of);
      if (p && p->type == T_PROCESS) make_rsv(p, s);
    }
    reply(c->fd, "+OK\n");
    return 0;
  }
  s = load(name);
  if (!s) { reply(c->fd, "-ERR service not found: %s\n", name); return 0; }
  if (!strcmp(cmd, "status")) { do_status(c->fd, s); return 0; }
  if (!strcmp(cmd, "start")) {
    if (s->state == ST_STARTED && s->want) { reply(c->fd, "+OK\n"); return 0; }
    request_start(s);
    if (nowait) { reply(c->fd, "+OK\n"); return 0; }
    c->wait = s; c->kind = W_START;
    return 1;
  }
  if (!strcmp(cmd, "stop")) {
    if (s->state == ST_STOPPED && !s->want) {
      if (ign) reply(c->fd, "+OK\n"); else reply(c->fd, "-ERR service already stopped: %s\n", name);
      return 0;
    }
    s->want = 0;
    s->explicit_ = 0;
    poke(s);
    if (nowait) { reply(c->fd, "+OK\n"); return 0; }
    c->wait = s; c->kind = W_STOP;
    return 1;
  }
  if (!strcmp(cmd, "restart")) {
    if (s->state == ST_STOPPED && !s->want) {
      request_start(s);
      if (nowait) { reply(c->fd, "+OK\n"); return 0; }
      c->wait = s; c->kind = W_START;
      return 1;
    }
    svc *set[256];
    int cnt = 0;
    set[cnt++] = s;
    collect_rdeps(s, set, &cnt, 256);
    for (int i = 0; i < cnt; i++) {
      if (set[i]->state == ST_STOPPED && !set[i]->want) continue;
      set[i]->restart_after = 1;
      set[i]->want = 0;
      poke(set[i]);
    }
    if (nowait) { reply(c->fd, "+OK\n"); return 0; }
    c->wait = s; c->kind = W_RESTART;
    return 1;
  }
  reply(c->fd, "-ERR unknown command %s\n", cmd);
  return 0;
}

static void check_waiters(void) {
  for (int i = 0; i < nclients;) {
    struct client *c = &clients[i];
    if (c->wait) {
      svc *s = c->wait;
      int done = 0, ok = 1;
      switch (c->kind) {
        case W_START:
          if (s->state == ST_STARTED && s->want) done = 1;
          else if (s->state == ST_STOPPED && !s->want) { done = 1; ok = 0; }
          break;
        case W_STOP:
          if (s->state == ST_STOPPED && !s->want) done = 1;
          break;
        case W_RESTART:
          if (s->state == ST_STARTED && s->want && !s->restart_after) done = 1;
          else if (s->state == ST_STOPPED && !s->want && !s->restart_after) { done = 1; ok = 0; }
          break;
      }
      if (done) {
        if (ok) reply(c->fd, "+OK\n");
        else reply(c->fd, "-ERR service failed to start: %s (%s)\n", s->name, s->why ? s->why : "stopped");
        drop_client(i);
        continue;
      }
    }
    i++;
  }
}

/* ---------------------------------------------------------------------- */
/* daemon */

static volatile sig_atomic_t quit;

static int daemon_main(const char *target) {
  mkdir("/run/units", 0755);
  mkdir(rsv_dir, 0755);
  int sfd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
  struct sockaddr_un sa = {.sun_family = AF_UNIX};
  snprintf(sa.sun_path, sizeof sa.sun_path, "%s", sock_path);
  unlink(sock_path);
  if (sfd < 0 || bind(sfd, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(sfd, 64) < 0) {
    say("%s: %s", sock_path, strerror(errno));
    return 111;
  }
  chmod(sock_path, 0600);

  sigset_t mask;
  sigemptyset(&mask);
  sigaddset(&mask, SIGCHLD);
  sigaddset(&mask, SIGTERM);
  sigaddset(&mask, SIGINT);
  sigprocmask(SIG_BLOCK, &mask, NULL);
  int sigfd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
  signal(SIGPIPE, SIG_IGN);

  sync_rsv();
  debug = getenv("UNIT_RC_DEBUG") != NULL;
  if (target && *target) {
    svc *t = load(target);
    if (!t) say("no service %s", target);
    else request_start(t);
  }
  run_queue();

  for (;;) {
    struct pollfd *fds = xrealloc(NULL, (2 + nclients) * sizeof *fds);
    fds[0] = (struct pollfd){sfd, POLLIN, 0};
    fds[1] = (struct pollfd){sigfd, POLLIN, 0};
    for (int i = 0; i < nclients; i++) fds[2 + i] = (struct pollfd){clients[i].fd, POLLIN, 0};
    int timeout = -1;
    long long now = now_ms();
    if (busy()) timeout = 25;
    for (int i = 0; i < nsvcs; i++) {
      svc *s = svcs[i];
      if (s->type == T_SCRIPTED && s->pid > 0 && s->deadline) {
        long long d = s->deadline - now;
        int t = d < 0 ? 0 : d > 60000 ? 60000 : (int)d;
        if (timeout < 0 || t < timeout) timeout = t;
      }
    }
    int npolled = nclients;
    int r = poll(fds, 2 + npolled, timeout);
    if (r < 0 && errno != EINTR) { say("poll: %s", strerror(errno)); return 111; }

    if (r > 0 && (fds[1].revents & POLLIN)) {
      struct signalfd_siginfo si;
      while (read(sigfd, &si, sizeof si) == sizeof si) {
        if (si.ssi_signo == SIGTERM || si.ssi_signo == SIGINT) quit = 1;
      }
      reap();
    }
    if (quit) break;
    if (r > 0 && (fds[0].revents & POLLIN)) {
      for (;;) {
        int cfd = accept4(sfd, NULL, NULL, SOCK_CLOEXEC);
        if (cfd < 0) break;
        clients = xrealloc(clients, (nclients + 1) * sizeof *clients);
        memset(&clients[nclients], 0, sizeof clients[nclients]);
        clients[nclients++].fd = cfd;
      }
    }
    /* (the clients that were polled; each is looked up again, as the array
     * moves when one goes) */
    for (int j = 0; j < npolled; j++) {
      if (!(fds[2 + j].revents & (POLLIN | POLLHUP | POLLERR))) continue;
      int k;
      for (k = 0; k < nclients; k++) if (clients[k].fd == fds[2 + j].fd) break;
      if (k == nclients) continue;
      struct client *c = &clients[k];
      if (c->wait) {
        /* it hung up while waiting */
        char b[8];
        ssize_t n = recv(c->fd, b, sizeof b, MSG_DONTWAIT);
        if (n == 0) drop_client(k);
        continue;
      }
      ssize_t n = read(c->fd, c->buf + c->len, sizeof c->buf - 1 - c->len);
      if (n <= 0) { drop_client(k); continue; }
      c->len += n;
      c->buf[c->len] = 0;
      char *nl = strchr(c->buf, '\n');
      if (!nl) continue;
      *nl = 0;
      if (!handle(c, c->buf)) drop_client(k);
    }
    free(fds);
    run_queue();
    tick();
    run_queue();
    check_waiters();
  }
  unlink(sock_path);
  return 0;
}

/* ---------------------------------------------------------------------- */
/* client */

static int client_main(int argc, char **argv) {
  const char *cmd = NULL, *name = NULL;
  int quiet = 0, nowait = 0, force = 0, ign = 0;
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (!strcmp(a, "-p") && i + 1 < argc) sock_path = argv[++i];
    else if (!strcmp(a, "--quiet") || !strcmp(a, "-q")) quiet = 1;
    else if (!strcmp(a, "--no-wait")) nowait = 1;
    else if (!strcmp(a, "--force") || !strcmp(a, "-f")) force = 1;
    else if (!strcmp(a, "--ignore-unstarted")) ign = 1;
    else if (a[0] == '-' && a[1]) { /* (dinitctl's other options mean nothing here) */ }
    else if (!cmd) cmd = a;
    else if (!name) name = a;
  }
  if (!cmd) {
    fprintf(stderr, "usage: unit-rc [-p SOCKET] [--quiet] list|status|start|stop|restart|reload|unload|rescan [SERVICE]\n");
    return 1;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  struct sockaddr_un sa = {.sun_family = AF_UNIX};
  snprintf(sa.sun_path, sizeof sa.sun_path, "%s", sock_path);
  if (fd < 0 || connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
    fprintf(stderr, "unit-rc: cannot connect to %s: %s\n", sock_path, strerror(errno));
    return 1;
  }
  char req[PATH_MAX + 64];
  int n = snprintf(req, sizeof req, "%s %d %d %d %s\n", cmd, nowait, force, ign, name ? name : "");
  if (write(fd, req, n) != n) return 1;
  char buf[4096];
  size_t len = 0;
  int rc = 1;
  for (;;) {
    ssize_t r = read(fd, buf + len, sizeof buf - 1 - len);
    if (r <= 0) break;
    len += r;
    buf[len] = 0;
    char *start = buf, *nl;
    int end = 0;
    while ((nl = strchr(start, '\n'))) {
      *nl = 0;
      if (!strcmp(start, "+OK")) {
        rc = 0; end = 1;
        if (!quiet && name && strcmp(cmd, "status") && strcmp(cmd, "list")) {
          const char *what = !strcmp(cmd, "start") ? "started" : !strcmp(cmd, "stop") ? "stopped" : !strcmp(cmd, "restart") ? "restarted" : "done";
          printf("Service '%s' %s.\n", name, what);
        }
      } else if (!strncmp(start, "-ERR ", 5)) {
        fprintf(stderr, "unit-rc: %s\n", start + 5);
        rc = 1; end = 1;
      } else {
        puts(start);
      }
      start = nl + 1;
    }
    if (end) break;
    len = strlen(start);
    memmove(buf, start, len + 1);
  }
  return rc;
}

int main(int argc, char **argv) {
  if (argc >= 2 && (!strcmp(argv[1], "daemon") || !strcmp(argv[1], "prepare"))) {
    const char *target = NULL;
    int prepare = !strcmp(argv[1], "prepare");
    optind = 2;
    int opt;
    while ((opt = getopt(argc, argv, "d:r:s:p:b:t:")) != -1) {
      switch (opt) {
        case 'd': desc_dir = optarg; break;
        case 'r': rsv_dir = optarg; break;
        case 's': sv_dir = optarg; break;
        case 'p': sock_path = optarg; break;
        case 'b': sh_path = optarg; break;
        case 't': target = optarg; break;
        default: return 100;
      }
    }
    if (prepare) { sync_rsv(); return 0; }
    return daemon_main(target);
  }
  return client_main(argc, argv);
}

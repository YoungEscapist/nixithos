/*
 * unit-supervise - the supervisor of one service, for a service manager that
 * supervises this process in turn (dinit): what s6-supervise is for s6.
 *
 *   unit-supervise [-a ATOM] [-n FD] [-s SIGNAL] [-k MS] [-f MS] [-d DIR] [-h]
 *                  -- RUNTIME VERB DATA
 *
 * Runs `RUNTIME VERB DATA`.  For VERB `run` (a unit's main process) the
 * contract is s6-supervise's: when it ends, `RUNTIME finish DATA CODE SIGNUM`
 * runs (CODE is 256 if the process was killed by SIGNUM), and the service is
 * started again unless finish exits 125 or the service is wanted down.  Any
 * other VERB (timers, path units, the loops of sockets) is just started again
 * whenever it ends.  Two starts are at least a second apart, as with
 * s6-supervise.
 *
 *   -a ATOM    the service's name: the status goes to DIR/ATOM
 *   -d DIR     where the status goes (default: /run/units/.sv, or the user
 *              manager's units/.sv with UNIT_SCOPE=user)
 *   -n FD      readiness: the process gets a pipe on FD and writes a line to
 *              it when it is ready; the first time that happens, a line goes
 *              to the service manager's pipe: the descriptor the environment
 *              variable UNIT_SV_READY_FD names (dinit's `ready-notification =
 *              pipevar:UNIT_SV_READY_FD`), or else FD of this program
 *              (pipefd:FD)
 *   -s SIGNAL  what stops the process (KillSignal=; default TERM)
 *   -k MS      after that long, SIGKILL (0: never)
 *   -f MS      how long finish may take (default 90000)
 *   -h         the unit has ExecStop=: before the process is stopped, run
 *              `RUNTIME stop-hook DATA` and wait for it (s6 has an atom of
 *              its own for this, the unit's -hooks)
 *
 * Control, by signals to this program:
 *
 *   TERM, INT  the service is wanted down: stop the process, run finish, exit
 *   USR2       the same, but stay (the service is down, the supervisor is not)
 *   USR1       the service is wanted up: start it if it is not running
 *   HUP        stop the process with SIGTERM; it is started again as usual
 *              (`systemctl restart` from inside the unit)
 *
 * A service that has ended for good (finish said 125, or a run that ended by
 * itself under -n before it was ever ready) does not take the supervisor with
 * it, as long as the service manager has been told it was up: that is how a
 * unit that is not running stays "started" for what requires it, as systemd
 * does not stop units that require one that exited.  One that never came up
 * makes this program exit 1: the start failed.
 *
 * The status, rewritten whenever something changes, is one line:
 *
 *   UP READY PID WANT SVPID PHASE
 *
 * UP and READY are 0 or 1, PID is the process or -1, WANT is u or d, SVPID is
 * this program, PHASE one of run, finish, wait (the next start is due),
 * idle (ended for good) and exit (this program has gone).
 */

#define _GNU_SOURCE
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
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum phase { P_WAIT, P_RUN, P_FINISH, P_IDLE };

static const char *atom = "service";
static char status_path[2 * PATH_MAX], status_tmp[2 * PATH_MAX + 8];
static int nfd = -1;           /* the descriptor the process gets its pipe on */
static int mgr_fd = -1;        /* the service manager's pipe, until told */
static int kill_sig = SIGTERM;
static long kill_ms = 0, finish_ms = 90000;
static char *runtime, *verb, *data;
static int with_finish, with_hook, hook_done;

static enum phase phase = P_WAIT;
static pid_t child = -1;       /* run, or finish */
static int want_up = 1, stay = 0, ready = 0, told = 0;
/* dinit gave up waiting for the start (start-timeout: SIGINT before the
 * service was ready): finish hears "timeout", and the unit failed */
static int timed_out = 0;
static int ready_fd = -1;      /* read end of the process's pipe */
static long long last_start = 0, kill_at = 0, next_start = 0;

static long long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void say(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "unit-supervise: %s: ", atom);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
}

static void mkdirs(char *path) {
  for (char *p = path + 1; *p; p++) {
    if (*p != '/') continue;
    *p = 0;
    mkdir(path, 0755);
    *p = '/';
  }
  mkdir(path, 0755);
}

static void write_status(int gone) {
  static const char *names[] = {"wait", "run", "finish", "idle"};
  char line[128];
  int up = phase == P_RUN && child > 0;
  int n = snprintf(line, sizeof line, "%d %d %d %c %d %s\n", up, up && ready,
                   up ? (int)child : -1, want_up ? 'u' : 'd', (int)getpid(),
                   gone ? "exit" : names[phase]);
  int fd = open(status_tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) return;
  if (write(fd, line, n) == n) rename(status_tmp, status_path);
  close(fd);
}

/* the service manager hears about the first readiness only */
static void tell_manager(void) {
  if (mgr_fd < 0) return;
  if (write(mgr_fd, "\n", 1) < 0) {}
  close(mgr_fd);
  mgr_fd = -1;
  told = 1;
}

static void child_signals(void) {
  sigset_t none;
  sigemptyset(&none);
  sigprocmask(SIG_SETMASK, &none, NULL);
  for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);
}

static void start_run(void) {
  int p[2] = {-1, -1};
  if (nfd >= 0 && pipe2(p, O_CLOEXEC) < 0) {
    say("pipe: %s", strerror(errno));
    p[0] = p[1] = -1;
  }
  pid_t pid = fork();
  if (pid < 0) {
    say("fork: %s", strerror(errno));
    if (p[0] >= 0) { close(p[0]); close(p[1]); }
    phase = P_WAIT;
    next_start = now_ms() + 1000;
    return;
  }
  if (pid == 0) {
    child_signals();
    setsid();
    if (p[1] >= 0) {
      if (p[1] == nfd) fcntl(nfd, F_SETFD, 0);
      else dup2(p[1], nfd);
    }
    if (chdir("/") < 0) {}
    execl(runtime, runtime, verb, data, (char *)NULL);
    _exit(127);
  }
  if (p[1] >= 0) close(p[1]);
  /* (only this end: the process's stays a blocking pipe) */
  if (p[0] >= 0) fcntl(p[0], F_SETFL, O_NONBLOCK);
  ready_fd = p[0];
  child = pid;
  ready = 0;
  hook_done = 0;
  phase = P_RUN;
  kill_at = 0;
  last_start = now_ms();
  write_status(0);
}

static void start_finish(int code, int signum) {
  char c[16], s[16];
  snprintf(c, sizeof c, "%d", code);
  snprintf(s, sizeof s, "%d", signum);
  pid_t pid = fork();
  if (pid < 0) {
    say("fork: %s", strerror(errno));
    child = -1;
    phase = P_WAIT;
    next_start = now_ms() + 1000;
    return;
  }
  if (pid == 0) {
    child_signals();
    setsid();
    if (chdir("/") < 0) {}
    /* (unit-runtime keeps this one of the environment) */
    setenv("UNIT_SV_WANT", timed_out ? "timeout" : want_up ? "up" : "down", 1);
    execl(runtime, runtime, "finish", data, c, s, (char *)NULL);
    _exit(127);
  }
  child = pid;
  phase = P_FINISH;
  kill_at = finish_ms > 0 ? now_ms() + finish_ms : 0;
  write_status(0);
}

/* what comes after a run, and after its finish */
static void next(int finish_code) {
  if (!want_up) {
    if (!stay) {
      write_status(1);
      exit(0);
    }
    phase = P_IDLE;
    write_status(0);
    return;
  }
  if (finish_code == 125) {
    if (!told && mgr_fd >= 0) {
      /* never up: as far as the service manager goes, the start failed */
      write_status(1);
      exit(1);
    }
    phase = P_IDLE;
    write_status(0);
    return;
  }
  long long at = last_start + 1000;
  if (at <= now_ms()) {
    start_run();
  } else {
    phase = P_WAIT;
    next_start = at;
    write_status(0);
  }
}

/* ExecStop=, while the process still runs (as systemd does: the commands
 * first, then the signal for whatever is left) */
static void run_hook(void) {
  if (!with_hook || hook_done || phase != P_RUN || child <= 0) return;
  hook_done = 1;
  pid_t pid = fork();
  if (pid < 0) {
    say("fork: %s", strerror(errno));
    return;
  }
  if (pid == 0) {
    child_signals();
    if (chdir("/") < 0) {}
    execl(runtime, runtime, "stop-hook", data, (char *)NULL);
    _exit(127);
  }
  while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}

static void stop_child(int sig) {
  if (phase != P_RUN || child <= 0) return;
  kill(child, sig);
  kill(child, SIGCONT);
  if (kill_ms > 0 && !kill_at) kill_at = now_ms() + kill_ms;
}

static void on_exit_status(int status) {
  int code, signum = 0;
  if (WIFSIGNALED(status)) {
    code = 256;
    signum = WTERMSIG(status);
  } else {
    code = WEXITSTATUS(status);
  }
  if (phase == P_RUN) {
    if (ready_fd >= 0) {
      /* (what the process wrote just before it went counts) */
      char buf[64];
      ssize_t n;
      while ((n = read(ready_fd, buf, sizeof buf)) > 0) {
        ready = 1;
        tell_manager();
      }
      close(ready_fd);
      ready_fd = -1;
    }
    child = -1;
    kill_at = 0;
    if (with_finish) {
      start_finish(code, signum);
    } else {
      next(0);
    }
  } else if (phase == P_FINISH) {
    child = -1;
    kill_at = 0;
    next(code);
  }
}

static void usage(void) {
  fprintf(stderr, "usage: unit-supervise [-a ATOM] [-n FD] [-s SIG] [-k MS] [-f MS] [-d DIR] [-h] -- RUNTIME VERB DATA\n");
  exit(100);
}

static int parse_signal(const char *s) {
  static const struct { const char *name; int sig; } sigs[] = {
    {"HUP", SIGHUP}, {"INT", SIGINT}, {"QUIT", SIGQUIT}, {"KILL", SIGKILL},
    {"USR1", SIGUSR1}, {"USR2", SIGUSR2}, {"TERM", SIGTERM}, {"CONT", SIGCONT},
    {"STOP", SIGSTOP}, {"WINCH", SIGWINCH}, {"PWR", SIGPWR}, {"ABRT", SIGABRT},
    {"ALRM", SIGALRM}, {"PIPE", SIGPIPE}, {"CHLD", SIGCHLD}, {"URG", SIGURG},
  };
  if (!strncmp(s, "SIG", 3)) s += 3;
  for (size_t i = 0; i < sizeof sigs / sizeof *sigs; i++)
    if (!strcmp(s, sigs[i].name)) return sigs[i].sig;
  int n = atoi(s);
  if (!strncmp(s, "RTMIN+", 6)) n = SIGRTMIN + atoi(s + 6);
  return n > 0 && n < NSIG ? n : SIGTERM;
}

int main(int argc, char **argv) {
  const char *dir = NULL;
  int opt;
  while ((opt = getopt(argc, argv, "a:n:s:k:f:d:h")) != -1) {
    switch (opt) {
      case 'a': atom = optarg; break;
      case 'n': nfd = atoi(optarg); break;
      case 's': kill_sig = parse_signal(optarg); break;
      case 'k': kill_ms = atol(optarg); break;
      case 'f': finish_ms = atol(optarg); break;
      case 'd': dir = optarg; break;
      case 'h': with_hook = 1; break;
      default: usage();
    }
  }
  if (argc - optind != 3) usage();
  runtime = argv[optind];
  verb = argv[optind + 1];
  data = argv[optind + 2];
  with_finish = !strcmp(verb, "run");

  char base[PATH_MAX];
  if (dir) {
    snprintf(base, sizeof base, "%s", dir);
  } else {
    const char *scope = getenv("UNIT_SCOPE");
    if (scope && !strcmp(scope, "user")) {
      const char *st = getenv("UNIT_USER_STATE");
      if (!st || !*st) st = getenv("XDG_RUNTIME_DIR");
      if (!st || !*st) { say("no UNIT_USER_STATE for a user's service"); return 100; }
      snprintf(base, sizeof base, "%s/units/.sv", st);
    } else {
      snprintf(base, sizeof base, "/run/units/.sv");
    }
  }
  mkdirs(base);
  snprintf(status_path, sizeof status_path, "%s/%s", base, atom);
  snprintf(status_tmp, sizeof status_tmp, "%s/.%s.new", base, atom);

  /* The service manager's pipe, out of the way of the process's: the
   * descriptor that UNIT_SV_READY_FD names (dinit's `ready-notification =
   * pipevar:UNIT_SV_READY_FD`), or else FD of -n itself (pipefd:FD).  dinit
   * 0.22 loses a forced descriptor when the write end of the service's log
   * pipe has that number in dinit (run_child_proc moves it over stdout and
   * closes it): with pipevar it picks the number itself, and that does not
   * happen. */
  int mfd = nfd;
  const char *rv = getenv("UNIT_SV_READY_FD");
  if (rv && *rv) {
    mfd = atoi(rv);
    unsetenv("UNIT_SV_READY_FD");
  }
  if (mfd >= 0 && fcntl(mfd, F_GETFD) >= 0) {
    mgr_fd = fcntl(mfd, F_DUPFD_CLOEXEC, 100);
    close(mfd);
  }

  sigset_t mask;
  sigemptyset(&mask);
  int handled[] = {SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGUSR1, SIGUSR2};
  for (size_t i = 0; i < sizeof handled / sizeof *handled; i++) sigaddset(&mask, handled[i]);
  sigprocmask(SIG_BLOCK, &mask, NULL);
  int sfd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
  if (sfd < 0) { say("signalfd: %s", strerror(errno)); return 111; }
  signal(SIGPIPE, SIG_IGN);

  start_run();

  for (;;) {
    long long now = now_ms(), deadline = -1;
    if (kill_at) deadline = kill_at;
    if (phase == P_WAIT && (deadline < 0 || next_start < deadline)) deadline = next_start;
    int timeout = deadline < 0 ? -1 : (deadline > now ? (int)(deadline - now) : 0);

    struct pollfd fds[2] = {{sfd, POLLIN, 0}, {ready_fd, POLLIN, 0}};
    int nf = ready_fd >= 0 ? 2 : 1;
    int r = poll(fds, nf, timeout);
    if (r < 0 && errno != EINTR) { say("poll: %s", strerror(errno)); return 111; }
    now = now_ms();

    if (nf == 2 && fds[1].revents) {
      char buf[64];
      ssize_t n = read(ready_fd, buf, sizeof buf);
      if (n > 0) {
        if (!ready) {
          ready = 1;
          tell_manager();
          write_status(0);
        }
      } else if (n == 0 || (errno != EAGAIN && errno != EINTR)) {
        close(ready_fd);
        ready_fd = -1;
      }
    }

    if (fds[0].revents) {
      struct signalfd_siginfo si;
      while (read(sfd, &si, sizeof si) == sizeof si) {
        switch (si.ssi_signo) {
          case SIGCHLD: {
            int status;
            pid_t pid;
            while ((pid = waitpid(-1, &status, WNOHANG)) > 0)
              if (pid == child) on_exit_status(status);
            break;
          }
          case SIGINT:
            if (!told && mgr_fd >= 0) timed_out = 1;
            /* fall through */
          case SIGTERM:
          case SIGUSR2:
            want_up = 0;
            stay = si.ssi_signo == SIGUSR2;
            if (phase == P_RUN) {
              run_hook();
              stop_child(kill_sig);
              write_status(0);
            } else if (phase == P_WAIT || phase == P_IDLE) {
              next(0);
            } else {
              write_status(0);
            }
            break;
          case SIGUSR1:
            want_up = 1;
            stay = 0;
            if (phase == P_IDLE || phase == P_WAIT) {
              /* (a start asked for by hand does not wait for the second) */
              start_run();
            } else {
              write_status(0);
            }
            break;
          case SIGHUP:
            if (phase == P_RUN) stop_child(SIGTERM);
            break;
        }
      }
    }

    if (kill_at && now >= kill_at && child > 0) {
      say(phase == P_FINISH ? "finish took too long, killing it" : "not stopped in time, killing it");
      if (phase == P_FINISH) kill(-child, SIGKILL);
      kill(child, SIGKILL);
      kill_at = 0;
    }
    if (phase == P_WAIT && now >= next_start && want_up) start_run();
  }
}

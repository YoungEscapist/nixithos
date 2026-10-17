/*
 * unit-pam - PAMName=: run a command inside a PAM session.
 *
 *   unit-pam -s SERVICE -u USER [-t TTY] -- COMMAND [ARGUMENTS…]
 *
 * Opens a session of PAM service SERVICE for USER (account management,
 * credentials, session), adds the environment the modules set (elogind's
 * XDG_RUNTIME_DIR, XDG_SESSION_ID, XDG_SEAT, …) to the command's, and runs
 * the command as a child.  When it ends, the session is closed and unit-pam
 * exits as the command did.  It stays root to be able to close the session;
 * dropping privileges is for what comes after it in COMMAND (setpriv), as
 * with systemd, whose "(sd-pam)" process does the same.  Signals it gets
 * are passed on to the command.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <security/pam_appl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* Nobody is there to answer: prompts fail, messages go to standard error. */
static int conv(int n, const struct pam_message **msg, struct pam_response **resp, void *data) {
  (void)data;
  struct pam_response *r = calloc((size_t)n, sizeof *r);
  if (!r) return PAM_BUF_ERR;
  for (int i = 0; i < n; i++) {
    switch (msg[i]->msg_style) {
      case PAM_ERROR_MSG:
      case PAM_TEXT_INFO:
        fprintf(stderr, "unit-pam: %s\n", msg[i]->msg);
        break;
      default:
        free(r);
        return PAM_CONV_ERR;
    }
  }
  *resp = r;
  return PAM_SUCCESS;
}

static void fail(pam_handle_t *h, const char *what, int rc) {
  fprintf(stderr, "unit-pam: %s: %s\n", what, pam_strerror(h, rc));
}

int main(int argc, char **argv) {
  const char *service = NULL, *user = NULL, *tty = NULL;
  int opt;
  while ((opt = getopt(argc, argv, "+s:u:t:")) != -1) {
    switch (opt) {
      case 's': service = optarg; break;
      case 'u': user = optarg; break;
      case 't': tty = optarg; break;
      default: service = NULL; optind = argc; break;
    }
  }
  if (optind < argc && !strcmp(argv[optind], "--")) optind++;
  if (!service || !user || optind >= argc) {
    fputs("usage: unit-pam -s SERVICE -u USER [-t TTY] -- COMMAND [ARGUMENTS…]\n", stderr);
    return 100;
  }

  struct pam_conv c = { conv, NULL };
  pam_handle_t *h = NULL;
  int rc = pam_start(service, user, &c, &h);
  if (rc != PAM_SUCCESS) { fprintf(stderr, "unit-pam: pam_start failed\n"); return 1; }
  if (tty) {
    /* (as the modules expect it: tty1, not /dev/tty1) */
    if (!strncmp(tty, "/dev/", 5)) tty += 5;
    pam_set_item(h, PAM_TTY, tty);
  }
  if ((rc = pam_acct_mgmt(h, PAM_SILENT)) != PAM_SUCCESS) { fail(h, "account", rc); pam_end(h, rc); return 1; }
  if ((rc = pam_setcred(h, PAM_ESTABLISH_CRED | PAM_SILENT)) != PAM_SUCCESS) { fail(h, "credentials", rc); pam_end(h, rc); return 1; }
  if ((rc = pam_open_session(h, PAM_SILENT)) != PAM_SUCCESS) {
    fail(h, "session", rc);
    pam_setcred(h, PAM_DELETE_CRED | PAM_SILENT);
    pam_end(h, rc);
    return 1;
  }

  /* what the parent waits for, taken as they come */
  sigset_t set, old;
  sigemptyset(&set);
  int forwarded[] = { SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2, SIGCONT, SIGWINCH };
  for (size_t i = 0; i < sizeof forwarded / sizeof *forwarded; i++) sigaddset(&set, forwarded[i]);
  sigaddset(&set, SIGCHLD);
  sigprocmask(SIG_BLOCK, &set, &old);

  pid_t child = fork();
  if (child < 0) {
    perror("unit-pam: fork");
    pam_close_session(h, PAM_SILENT);
    pam_setcred(h, PAM_DELETE_CRED | PAM_SILENT);
    pam_end(h, PAM_SUCCESS);
    return 1;
  }
  if (child == 0) {
    char **env = pam_getenvlist(h);
    if (env)
      for (char **e = env; *e; e++) putenv(*e);
    sigprocmask(SIG_SETMASK, &old, NULL);
    execvp(argv[optind], argv + optind);
    fprintf(stderr, "unit-pam: %s: %s\n", argv[optind], strerror(errno));
    _exit(errno == ENOENT ? 127 : 126);
  }

  int status = 0;
  for (;;) {
    int sig;
    if (sigwait(&set, &sig) != 0) continue;
    if (sig != SIGCHLD) {
      kill(child, sig);
      continue;
    }
    pid_t p = waitpid(child, &status, WNOHANG);
    if (p == child) break;
  }

  pam_close_session(h, PAM_SILENT);
  pam_setcred(h, PAM_DELETE_CRED | PAM_SILENT);
  pam_end(h, PAM_SUCCESS);

  if (WIFSIGNALED(status)) {
    /* die the same way, for the supervisor to see */
    int sig = WTERMSIG(status);
    signal(sig, SIG_DFL);
    sigprocmask(SIG_SETMASK, &old, NULL);
    sigset_t one;
    sigemptyset(&one);
    sigaddset(&one, sig);
    sigprocmask(SIG_UNBLOCK, &one, NULL);
    kill(getpid(), sig);
    return 128 + sig;
  }
  return WEXITSTATUS(status);
}

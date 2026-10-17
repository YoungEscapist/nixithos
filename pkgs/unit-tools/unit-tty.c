/*
 * unit-tty - give a command its terminal the way systemd does for
 * StandardInput=tty.
 *
 *   unit-tty [-h] [-r] TTY COMMAND [ARG]...
 *
 * systemd makes the terminal of StandardInput=tty the controlling terminal
 * of the service: the process becomes the leader of a new session and takes
 * the terminal (TIOCSCTTY, stealing it from whoever has it).  A shell
 * redirection does not, and a program that needs one dies without it - ly
 * panics with "reached unreachable code".  agetty takes it by itself, which
 * is why the gettys never needed this.
 *
 *   -h  TTYVHangup=: hang the terminal up first, so that what the previous
 *       session left on it loses it
 *   -r  TTYReset=: put the terminal back into a sane state first (text mode,
 *       unicode keyboard, the terminal attributes of a fresh console)
 *
 * The descriptors 0, 1 and 2 that are the same terminal are opened anew on
 * it (a hangup leaves the old ones dead).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/kd.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

static void reset_tty(int fd) {
  struct termios t;
  ioctl(fd, KDSETMODE, KD_TEXT);
  ioctl(fd, KDSKBMODE, K_UNICODE);
  if (tcgetattr(fd, &t) == 0) {
    /* what systemd's terminal_reset_ioctl() sets */
    t.c_iflag &= ~(IGNBRK | BRKINT | ISTRIP | INLCR | IGNCR | IUCLC);
    t.c_iflag |= ICRNL | IMAXBEL | IUTF8;
    t.c_oflag |= ONLCR | OPOST;
    t.c_cflag |= CREAD;
    t.c_lflag = ISIG | ICANON | IEXTEN | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE;
    t.c_cc[VINTR] = 03;
    t.c_cc[VQUIT] = 034;
    t.c_cc[VERASE] = 0177;
    t.c_cc[VKILL] = 025;
    t.c_cc[VEOF] = 04;
    t.c_cc[VSTART] = 021;
    t.c_cc[VSTOP] = 023;
    t.c_cc[VSUSP] = 032;
    t.c_cc[VLNEXT] = 026;
    t.c_cc[VWERASE] = 027;
    t.c_cc[VREPRINT] = 022;
    t.c_cc[VEOL] = 0;
    t.c_cc[VEOL2] = 0;
    t.c_cc[VTIME] = 0;
    t.c_cc[VMIN] = 1;
    tcsetattr(fd, TCSANOW, &t);
  }
  tcflush(fd, TCIOFLUSH);
}

int main(int argc, char **argv) {
  int hangup = 0, reset = 0, i = 1;
  for (; i < argc && argv[i][0] == '-' && argv[i][1]; i++) {
    if (!strcmp(argv[i], "-h")) hangup = 1;
    else if (!strcmp(argv[i], "-r")) reset = 1;
    else if (!strcmp(argv[i], "--")) { i++; break; }
    else break;
  }
  if (argc - i < 2) {
    fputs("usage: unit-tty [-h] [-r] TTY COMMAND [ARG]...\n", stderr);
    return 100;
  }
  const char *path = argv[i];
  char **cmd = argv + i + 1;

  struct stat tty_st;
  if (stat(path, &tty_st) != 0) {
    fprintf(stderr, "unit-tty: %s: %s\n", path, strerror(errno));
    return 203;
  }
  /* which of 0, 1, 2 are this terminal (to be opened again on it) */
  int same[3] = {0, 0, 0};
  for (int d = 0; d < 3; d++) {
    struct stat st;
    if (fstat(d, &st) == 0 && S_ISCHR(st.st_mode) && st.st_rdev == tty_st.st_rdev) same[d] = 1;
  }

  /* (fails when already the leader of a session, as s6-supervise makes it) */
  setsid();

  int fd = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, "unit-tty: %s: %s\n", path, strerror(errno));
    return 203;
  }
  if (reset) reset_tty(fd);
  if (hangup) {
    /* (the hangup sends SIGHUP to the session that has the terminal, which
     * may well be this one: the shell's redirection took it already) */
    struct sigaction ign = {.sa_handler = SIG_IGN}, old;
    sigaction(SIGHUP, &ign, &old);
    ioctl(fd, TIOCVHANGUP);
    sigaction(SIGHUP, &old, NULL);
    close(fd);
    fd = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (fd < 0) {
      fprintf(stderr, "unit-tty: %s: %s\n", path, strerror(errno));
      return 203;
    }
  }
  if (ioctl(fd, TIOCSCTTY, 1) != 0)
    fprintf(stderr, "unit-tty: TIOCSCTTY %s: %s\n", path, strerror(errno));
  for (int d = 0; d < 3; d++)
    if (same[d]) dup2(fd, d);
  close(fd);

  execvp(cmd[0], cmd);
  fprintf(stderr, "unit-tty: %s: %s\n", cmd[0], strerror(errno));
  return 203;
}

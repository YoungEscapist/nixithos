/*
 * unit-socket - create one listening socket the way a systemd .socket unit
 * describes it, put it on stdin and exec a program.
 *
 *   unit-socket --stream ADDR [options] -- prog [args…]
 *
 * The program is normally s6-fdholder-store, which parks the descriptor in
 * the fd holder until the service asks for it.
 *
 * Address syntax follows systemd.socket(5): an absolute path is an AF_UNIX
 * socket, @name an abstract one, a bare number a port on all addresses,
 * a.b.c.d:port and [v6]:port what you would expect.
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/netlink.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static void die(const char *fmt, ...) {
  va_list ap;
  int e = errno;
  fputs("unit-socket: ", stderr);
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  if (e) fprintf(stderr, ": %s", strerror(e));
  fputc('\n', stderr);
  exit(111);
}

static void diex(const char *fmt, ...) {
  va_list ap;
  fputs("unit-socket: ", stderr);
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(100);
}

static void mkdir_parents(const char *path, mode_t mode) {
  char buf[4096];
  size_t len = strlen(path);
  if (len >= sizeof buf) diex("path too long: %s", path);
  memcpy(buf, path, len + 1);
  for (char *p = buf + 1; *p; p++) {
    if (*p != '/') continue;
    *p = 0;
    if (mkdir(buf, mode) < 0 && errno != EEXIST) die("mkdir %s", buf);
    *p = '/';
  }
}

static uid_t parse_user(const char *s) {
  char *end;
  unsigned long v = strtoul(s, &end, 10);
  if (*s && !*end) return (uid_t)v;
  struct passwd *pw = getpwnam(s);
  if (!pw) diex("unknown user %s", s);
  return pw->pw_uid;
}

static gid_t parse_group(const char *s) {
  char *end;
  unsigned long v = strtoul(s, &end, 10);
  if (*s && !*end) return (gid_t)v;
  struct group *gr = getgrnam(s);
  if (!gr) diex("unknown group %s", s);
  return gr->gr_gid;
}

static int netlink_family(const char *name) {
  static const struct { const char *name; int id; } families[] = {
    {"route", NETLINK_ROUTE}, {"firewall", NETLINK_FIREWALL},
    {"inet-diag", NETLINK_INET_DIAG}, {"nflog", NETLINK_NFLOG},
    {"xfrm", NETLINK_XFRM}, {"selinux", NETLINK_SELINUX},
    {"iscsi", NETLINK_ISCSI}, {"audit", NETLINK_AUDIT},
    {"fib-lookup", NETLINK_FIB_LOOKUP}, {"connector", NETLINK_CONNECTOR},
    {"netfilter", NETLINK_NETFILTER}, {"ip6-fw", NETLINK_IP6_FW},
    {"dnrtmsg", NETLINK_DNRTMSG}, {"kobject-uevent", NETLINK_KOBJECT_UEVENT},
    {"generic", NETLINK_GENERIC}, {"scsitransport", NETLINK_SCSITRANSPORT},
    {"ecryptfs", NETLINK_ECRYPTFS}, {"rdma", NETLINK_RDMA},
  };
  for (size_t i = 0; i < sizeof families / sizeof *families; i++)
    if (!strcmp(name, families[i].name)) return families[i].id;
  char *end;
  long v = strtol(name, &end, 10);
  if (*name && !*end) return (int)v;
  diex("unknown netlink family %s", name);
  return -1;
}

enum kind { K_NONE, K_STREAM, K_DGRAM, K_SEQPACKET, K_FIFO, K_NETLINK, K_SPECIAL };

int main(int argc, char **argv) {
  enum kind kind = K_NONE;
  const char *addr = NULL, *user = NULL, *group = NULL, *v6only = "default";
  mode_t mode = 0666, dir_mode = 0755;
  int backlog = SOMAXCONN, reuse_port = 0, free_bind = 0, pass_cred = 0;
  int i;

  for (i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (!strcmp(a, "--")) { i++; break; }
#define ARG() (i + 1 < argc ? argv[++i] : (diex("%s needs an argument", a), (char *)0))
    if (!strcmp(a, "--stream")) { kind = K_STREAM; addr = ARG(); }
    else if (!strcmp(a, "--dgram")) { kind = K_DGRAM; addr = ARG(); }
    else if (!strcmp(a, "--seqpacket")) { kind = K_SEQPACKET; addr = ARG(); }
    else if (!strcmp(a, "--fifo")) { kind = K_FIFO; addr = ARG(); }
    else if (!strcmp(a, "--netlink")) { kind = K_NETLINK; addr = ARG(); }
    else if (!strcmp(a, "--special")) { kind = K_SPECIAL; addr = ARG(); }
    else if (!strcmp(a, "--mode")) mode = (mode_t)strtoul(ARG(), NULL, 8);
    else if (!strcmp(a, "--dir-mode")) dir_mode = (mode_t)strtoul(ARG(), NULL, 8);
    else if (!strcmp(a, "--user")) user = ARG();
    else if (!strcmp(a, "--group")) group = ARG();
    else if (!strcmp(a, "--backlog")) backlog = atoi(ARG());
    else if (!strcmp(a, "--ipv6-only")) v6only = ARG();
    else if (!strcmp(a, "--reuse-port")) reuse_port = 1;
    else if (!strcmp(a, "--free-bind")) free_bind = 1;
    else if (!strcmp(a, "--pass-cred")) pass_cred = 1;
    else diex("unknown option %s", a);
#undef ARG
  }
  if (kind == K_NONE || !addr || i >= argc)
    diex("usage: unit-socket --stream|--dgram|--seqpacket|--fifo|--netlink|--special ADDR [options] -- prog…");

  int fd = -1;
  int one = 1;
  uid_t uid = user ? parse_user(user) : (uid_t)-1;
  gid_t gid = group ? parse_group(group) : (gid_t)-1;

  if (kind == K_FIFO) {
    mkdir_parents(addr, dir_mode);
    mode_t old = umask(0);
    if (mkfifo(addr, mode) < 0 && errno != EEXIST) die("mkfifo %s", addr);
    umask(old);
    fd = open(addr, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) die("open %s", addr);
    if (user || group) if (fchown(fd, uid, gid) < 0) die("chown %s", addr);
  } else if (kind == K_SPECIAL) {
    fd = open(addr, O_RDONLY | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) die("open %s", addr);
  } else if (kind == K_NETLINK) {
    char family[64];
    unsigned groups = 0;
    if (sscanf(addr, "%63s %u", family, &groups) < 1) diex("bad netlink address %s", addr);
    struct sockaddr_nl nl = { .nl_family = AF_NETLINK, .nl_groups = groups };
    fd = socket(AF_NETLINK, SOCK_RAW, netlink_family(family));
    if (fd < 0) die("socket");
    if (pass_cred) setsockopt(fd, SOL_SOCKET, SO_PASSCRED, &one, sizeof one);
    if (bind(fd, (struct sockaddr *)&nl, sizeof nl) < 0) die("bind netlink %s", addr);
  } else {
    int type = kind == K_STREAM ? SOCK_STREAM : kind == K_DGRAM ? SOCK_DGRAM : SOCK_SEQPACKET;
    if (addr[0] == '/' || addr[0] == '@') {
      struct sockaddr_un un = { .sun_family = AF_UNIX };
      size_t len = strlen(addr);
      if (len >= sizeof un.sun_path) diex("socket path too long: %s", addr);
      memcpy(un.sun_path, addr, len);
      socklen_t slen = offsetof(struct sockaddr_un, sun_path) + len;
      if (addr[0] == '@') {
        un.sun_path[0] = 0;
      } else {
        slen++;
        mkdir_parents(addr, dir_mode);
        if (unlink(addr) < 0 && errno != ENOENT) die("unlink %s", addr);
      }
      fd = socket(AF_UNIX, type, 0);
      if (fd < 0) die("socket");
      if (pass_cred) setsockopt(fd, SOL_SOCKET, SO_PASSCRED, &one, sizeof one);
      mode_t old = umask(~mode & 0777);
      if (bind(fd, (struct sockaddr *)&un, slen) < 0) die("bind %s", addr);
      umask(old);
      if (addr[0] == '/') {
        if (chmod(addr, mode) < 0) die("chmod %s", addr);
        if (user || group) if (chown(addr, uid, gid) < 0) die("chown %s", addr);
      }
    } else {
      struct sockaddr_storage ss;
      socklen_t slen;
      memset(&ss, 0, sizeof ss);
      const char *colon = strrchr(addr, ':');
      const char *portstr = colon ? colon + 1 : addr;
      char *end;
      unsigned long port = strtoul(portstr, &end, 10);
      if (!*portstr || *end || port > 65535) diex("bad port in %s", addr);
      if (!colon) {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)&ss;
        in6->sin6_family = AF_INET6;
        in6->sin6_port = htons((unsigned short)port);
        slen = sizeof *in6;
      } else if (addr[0] == '[') {
        char host[128];
        size_t hl = (size_t)(colon - addr);
        if (hl < 2 || addr[hl - 1] != ']' || hl - 2 >= sizeof host) diex("bad address %s", addr);
        memcpy(host, addr + 1, hl - 2);
        host[hl - 2] = 0;
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)&ss;
        char *pct = strchr(host, '%');
        if (pct) { *pct = 0; in6->sin6_scope_id = if_nametoindex(pct + 1); }
        in6->sin6_family = AF_INET6;
        in6->sin6_port = htons((unsigned short)port);
        if (inet_pton(AF_INET6, host, &in6->sin6_addr) != 1) diex("bad IPv6 address %s", addr);
        slen = sizeof *in6;
      } else {
        char host[64];
        size_t hl = (size_t)(colon - addr);
        if (hl >= sizeof host) diex("bad address %s", addr);
        memcpy(host, addr, hl);
        host[hl] = 0;
        struct sockaddr_in *in = (struct sockaddr_in *)&ss;
        in->sin_family = AF_INET;
        in->sin_port = htons((unsigned short)port);
        if (inet_pton(AF_INET, host, &in->sin_addr) != 1) diex("bad IPv4 address %s", addr);
        slen = sizeof *in;
      }
      fd = socket(ss.ss_family, type, 0);
      if (fd < 0 && ss.ss_family == AF_INET6 && !colon && errno == EAFNOSUPPORT) {
        /* no IPv6 in this kernel: fall back to 0.0.0.0:port */
        struct sockaddr_in *in = (struct sockaddr_in *)&ss;
        memset(&ss, 0, sizeof ss);
        in->sin_family = AF_INET;
        in->sin_port = htons((unsigned short)port);
        slen = sizeof *in;
        fd = socket(AF_INET, type, 0);
      }
      if (fd < 0) die("socket");
      setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
      if (reuse_port) setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
      if (free_bind) setsockopt(fd, IPPROTO_IP, IP_FREEBIND, &one, sizeof one);
      if (ss.ss_family == AF_INET6) {
        int v = -1;
        if (!strcmp(v6only, "ipv6-only")) v = 1;
        else if (!strcmp(v6only, "both")) v = 0;
        if (v >= 0) setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v, sizeof v);
      }
      if (bind(fd, (struct sockaddr *)&ss, slen) < 0) die("bind %s", addr);
    }
    if (type != SOCK_DGRAM)
      if (listen(fd, backlog) < 0) die("listen %s", addr);
  }

  if (fd != 0) {
    if (dup2(fd, 0) < 0) die("dup2");
    close(fd);
  }
  execvp(argv[i], argv + i);
  die("exec %s", argv[i]);
  return 111;
}

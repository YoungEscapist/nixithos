/*
 * unit-seccomp - the system call restrictions of a unit: SystemCallFilter=,
 * SystemCallErrorNumber=, SystemCallArchitectures=, RestrictAddressFamilies=,
 * RestrictNamespaces=, RestrictRealtime=, RestrictSUIDSGID=,
 * MemoryDenyWriteExecute= and LockPersonality= of systemd.exec(5).
 *
 *   unit-seccomp [OPTIONS] -- COMMAND [ARGUMENTS…]
 *
 * Builds the filters with libseccomp, loads them and executes the command, as
 * systemd does in the process that is about to exec the service.  So it runs
 * last, after setpriv has dropped privileges and after the root directory
 * is entered (unit-chroot loads them itself, from the same code, for a unit
 * with a root of its own: the store is not there afterwards).  As systemd
 * does, it sets no_new_privs unless the process has CAP_SYS_ADMIN.
 *
 * Options (the values are those of the settings, as they are written):
 *   --syscall-filter LIST    SystemCallFilter=; once for each assignment (an
 *                            empty value resets what came before).  Names,
 *                            @groups (the table of systemd's seccomp-util.c,
 *                            syscall-groups.inc), "~" in front of the list
 *                            for a deny list, ":ERRNO" after an item
 *   --syscall-errno ERRNO    SystemCallErrorNumber= (a name or a number): an
 *                            error instead of killing the process
 *   --arch LIST              SystemCallArchitectures= (native, x86, x86-64,
 *                            x32, arm, arm64, …); once for each assignment
 *   --address-families LIST  RestrictAddressFamilies=; once for each assignment
 *   --restrict-namespaces V  RestrictNamespaces= (yes, or a list, or ~list)
 *   --restrict-realtime      RestrictRealtime=yes
 *   --restrict-suid-sgid     RestrictSUIDSGID=yes
 *   --mdwe                   MemoryDenyWriteExecute=yes
 *   --lock-personality       LockPersonality=yes
 *   --dry-run                build the filters, do not load them, do not exec
 *   --list-groups            print the groups and what is in them
 *
 * A system call that is not allowed kills the process with SIGSYS, unless an
 * error number was asked for.  Names that this architecture has no system
 * call of (and groups that are not there) are left out, as with systemd.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <sched.h>
#include <seccomp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/personality.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef PR_SET_MDWE
#define PR_SET_MDWE 65
#define PR_MDWE_REFUSE_EXEC_GAIN 1
#endif
#ifndef CLONE_NEWTIME
#define CLONE_NEWTIME 0x00000080
#endif
#ifndef SHM_EXEC
#define SHM_EXEC 0100000
#endif
#ifndef SCMP_ACT_KILL_PROCESS
#define SCMP_ACT_KILL_PROCESS SCMP_ACT_KILL
#endif

#define EXIT_SECCOMP 232

static void say(const char *what, const char *arg) {
  fprintf(stderr, "unit-seccomp: %s%s%s\n", what, arg ? ": " : "", arg ? arg : "");
}

/* ---------------------------------------------------------------------- */
/* the syscall groups */

struct group { const char *name; const char *members; };

static const struct group groups[] = {
#include "syscall-groups.inc"
};
#define N_GROUPS (sizeof groups / sizeof groups[0])

static const struct group *find_group(const char *name) {
  for (size_t i = 0; i < N_GROUPS; i++)
    if (!strcmp(groups[i].name, name)) return &groups[i];
  return NULL;
}

/* ---------------------------------------------------------------------- */
/* error numbers */

static const struct { const char *name; int value; } errnos[] = {
#define E(n) { #n, n },
  E(EPERM) E(ENOENT) E(ESRCH) E(EINTR) E(EIO) E(ENXIO) E(E2BIG) E(ENOEXEC)
  E(EBADF) E(ECHILD) E(EAGAIN) E(ENOMEM) E(EACCES) E(EFAULT) E(ENOTBLK)
  E(EBUSY) E(EEXIST) E(EXDEV) E(ENODEV) E(ENOTDIR) E(EISDIR) E(EINVAL)
  E(ENFILE) E(EMFILE) E(ENOTTY) E(ETXTBSY) E(EFBIG) E(ENOSPC) E(ESPIPE)
  E(EROFS) E(EMLINK) E(EPIPE) E(EDOM) E(ERANGE) E(EDEADLK) E(ENAMETOOLONG)
  E(ENOLCK) E(ENOSYS) E(ENOTEMPTY) E(ELOOP) E(ENOMSG) E(EIDRM) E(ENOSTR)
  E(ENODATA) E(ETIME) E(ENOSR) E(ENOLINK) E(EPROTO) E(EBADMSG) E(EOVERFLOW)
  E(EILSEQ) E(EUSERS) E(ENOTSOCK) E(EDESTADDRREQ) E(EMSGSIZE) E(EPROTOTYPE)
  E(ENOPROTOOPT) E(EPROTONOSUPPORT) E(ESOCKTNOSUPPORT) E(EOPNOTSUPP)
  E(EPFNOSUPPORT) E(EAFNOSUPPORT) E(EADDRINUSE) E(EADDRNOTAVAIL)
  E(ENETDOWN) E(ENETUNREACH) E(ENETRESET) E(ECONNABORTED) E(ECONNRESET)
  E(ENOBUFS) E(EISCONN) E(ENOTCONN) E(ESHUTDOWN) E(ETOOMANYREFS)
  E(ETIMEDOUT) E(ECONNREFUSED) E(EHOSTDOWN) E(EHOSTUNREACH) E(EALREADY)
  E(EINPROGRESS) E(ESTALE) E(EDQUOT) E(ECANCELED) E(EOWNERDEAD)
  E(ENOTRECOVERABLE) E(ERFKILL) E(EHWPOISON) E(EWOULDBLOCK) E(ENOTSUP)
  E(EDEADLOCK) E(ENOKEY) E(EKEYEXPIRED) E(EKEYREVOKED) E(EKEYREJECTED)
  E(ENOMEDIUM) E(EMEDIUMTYPE) E(EREMOTE) E(EREMOTEIO) E(ENOPKG) E(ENONET)
  E(EADV) E(ESRMNT) E(ECOMM) E(EMULTIHOP) E(EDOTDOT) E(ENOTUNIQ) E(EBADFD)
  E(EREMCHG) E(ELIBACC) E(ELIBBAD) E(ELIBSCN) E(ELIBMAX) E(ELIBEXEC)
  E(ERESTART) E(ESTRPIPE) E(EUCLEAN) E(ENOTNAM) E(ENAVAIL) E(EISNAM)
  E(ECHRNG) E(EL2NSYNC) E(EL3HLT) E(EL3RST) E(ELNRNG) E(EUNATCH) E(ENOCSI)
  E(EL2HLT) E(EBADE) E(EBADR) E(EXFULL) E(ENOANO) E(EBADRQC) E(EBADSLT)
  E(EBFONT)
#undef E
};

/* -1 if it is neither */
static int parse_errno(const char *s) {
  if (!*s) return -1;
  char *end;
  long n = strtol(s, &end, 10);
  if (!*end) return n > 0 && n < 4096 ? (int)n : -1;
  for (size_t i = 0; i < sizeof errnos / sizeof errnos[0]; i++)
    if (!strcmp(errnos[i].name, s)) return errnos[i].value;
  return -1;
}

/* ---------------------------------------------------------------------- */
/* the sets of names (with an error number of their own, or -1) */

struct entry { char *name; int err; };
struct set { struct entry *v; size_t n, cap; };

static struct entry *set_find(struct set *s, const char *name) {
  for (size_t i = 0; i < s->n; i++)
    if (!strcmp(s->v[i].name, name)) return &s->v[i];
  return NULL;
}

static void set_add(struct set *s, const char *name, int err) {
  struct entry *e = set_find(s, name);
  if (e) { e->err = err; return; }
  if (s->n == s->cap) {
    s->cap = s->cap ? s->cap * 2 : 128;
    s->v = realloc(s->v, s->cap * sizeof *s->v);
    if (!s->v) { say("out of memory", NULL); exit(EXIT_SECCOMP); }
  }
  s->v[s->n].name = strdup(name);
  s->v[s->n].err = err;
  s->n++;
}

static void set_del(struct set *s, const char *name) {
  struct entry *e = set_find(s, name);
  if (!e) return;
  free(e->name);
  *e = s->v[--s->n];
}

static void set_clear(struct set *s) {
  for (size_t i = 0; i < s->n; i++) free(s->v[i].name);
  s->n = 0;
}

/* Adds (or takes out) a name, or all that is in a group. */
static void expand(struct set *s, const char *word, int add, int err, int depth) {
  if (word[0] != '@') {
    if (add) set_add(s, word, err); else set_del(s, word);
    return;
  }
  if (depth > 8) return;
  if (!strcmp(word, "@known")) {
    for (size_t i = 0; i < N_GROUPS; i++) expand(s, groups[i].name, add, err, depth + 1);
    return;
  }
  const struct group *g = find_group(word);
  if (!g) { say("unknown system call group (ignored)", word); return; }
  for (const char *m = g->members; *m; m += strlen(m) + 1) expand(s, m, add, err, depth + 1);
}

/* ---------------------------------------------------------------------- */
/* the architectures */

static const struct { const char *name; uint32_t token; } arch_names[] = {
  { "x86", SCMP_ARCH_X86 }, { "x86-64", SCMP_ARCH_X86_64 }, { "x32", SCMP_ARCH_X32 },
  { "arm", SCMP_ARCH_ARM }, { "arm64", SCMP_ARCH_AARCH64 }, { "aarch64", SCMP_ARCH_AARCH64 },
  { "riscv64", SCMP_ARCH_RISCV64 }, { "ppc64-le", SCMP_ARCH_PPC64LE },
  { "ppc64", SCMP_ARCH_PPC64 }, { "s390x", SCMP_ARCH_S390X }, { "s390", SCMP_ARCH_S390 },
};

/* the architectures a process of this machine can make system calls of */
static const uint32_t local_archs[] = {
#if defined(__x86_64__)
  SCMP_ARCH_X86_64, SCMP_ARCH_X86, SCMP_ARCH_X32,
#elif defined(__aarch64__)
  SCMP_ARCH_AARCH64, SCMP_ARCH_ARM,
#else
  0,
#endif
};

struct archs { uint32_t v[16]; size_t n; };

static void archs_add(struct archs *a, uint32_t t) {
  for (size_t i = 0; i < a->n; i++) if (a->v[i] == t) return;
  if (a->n < 16) a->v[a->n++] = t;
}

/* ---------------------------------------------------------------------- */
/* what to do */

static struct set filter;
static int have_filter, allow_list, default_errno = -1;
static struct archs wanted;          /* SystemCallArchitectures=, if any */
static int have_archs;
static struct set families;          /* RestrictAddressFamilies= */
static int have_families, families_allow;
static uint32_t ns_forbidden;
static int restrict_rt, restrict_suid, mdwe, lock_pers, dry_run;

static const struct { const char *name; int value; } af_names[] = {
#define AF(n, v) { #n, v },
  AF(AF_UNSPEC, 0) AF(AF_UNIX, 1) AF(AF_LOCAL, 1) AF(AF_INET, 2) AF(AF_AX25, 3)
  AF(AF_IPX, 4) AF(AF_APPLETALK, 5) AF(AF_NETROM, 6) AF(AF_BRIDGE, 7)
  AF(AF_ATMPVC, 8) AF(AF_X25, 9) AF(AF_INET6, 10) AF(AF_ROSE, 11)
  AF(AF_DECnet, 12) AF(AF_NETBEUI, 13) AF(AF_SECURITY, 14) AF(AF_KEY, 15)
  AF(AF_NETLINK, 16) AF(AF_ROUTE, 16) AF(AF_PACKET, 17) AF(AF_ASH, 18)
  AF(AF_ECONET, 19) AF(AF_ATMSVC, 20) AF(AF_RDS, 21) AF(AF_SNA, 22)
  AF(AF_IRDA, 23) AF(AF_PPPOX, 24) AF(AF_WANPIPE, 25) AF(AF_LLC, 26)
  AF(AF_IB, 27) AF(AF_MPLS, 28) AF(AF_CAN, 29) AF(AF_TIPC, 30)
  AF(AF_BLUETOOTH, 31) AF(AF_IUCV, 32) AF(AF_RXRPC, 33) AF(AF_ISDN, 34)
  AF(AF_PHONET, 35) AF(AF_IEEE802154, 36) AF(AF_CAIF, 37) AF(AF_ALG, 38)
  AF(AF_NFC, 39) AF(AF_VSOCK, 40) AF(AF_KCM, 41) AF(AF_QIPCRTR, 42)
  AF(AF_SMC, 43) AF(AF_XDP, 44) AF(AF_MCTP, 45)
#undef AF
};
#define AF_UNKNOWN_FROM 64      /* above it: every family there is not */

static const struct { const char *name; uint32_t flag; } ns_names[] = {
  { "cgroup", CLONE_NEWCGROUP }, { "ipc", CLONE_NEWIPC }, { "net", CLONE_NEWNET },
  { "mnt", CLONE_NEWNS }, { "pid", CLONE_NEWPID }, { "user", CLONE_NEWUSER },
  { "uts", CLONE_NEWUTS }, { "time", CLONE_NEWTIME },
};
#define N_NS (sizeof ns_names / sizeof ns_names[0])

static uint32_t ns_all(void) {
  uint32_t m = 0;
  for (size_t i = 0; i < N_NS; i++) m |= ns_names[i].flag;
  return m;
}

/* Splits "a b\tc" in place; calls fn for each word. */
#define FOR_WORDS(buf, w) \
  for (char *_save = NULL, *w = strtok_r(buf, " \t\n", &_save); w; w = strtok_r(NULL, " \t\n", &_save))

static void parse_filter(const char *value) {
  char *buf = strdup(value);
  char *p = buf;
  while (*p == ' ' || *p == '\t') p++;
  if (!*p) {                           /* an empty assignment: start again */
    set_clear(&filter);
    have_filter = 0;
    free(buf);
    return;
  }
  int invert = *p == '~';
  if (invert) p++;
  if (!have_filter) {
    have_filter = 1;
    allow_list = !invert;
  }
  int add = invert != allow_list;
  FOR_WORDS(p, w) {
    int err = -1;
    char *colon = strchr(w, ':');
    if (colon) {
      *colon = 0;
      err = parse_errno(colon + 1);
      if (err < 0) { say("unknown error number (ignored)", colon + 1); continue; }
    }
    expand(&filter, w, add, err, 0);
  }
  free(buf);
}

static void parse_arch(const char *value) {
  char *buf = strdup(value);
  char *p = buf;
  while (*p == ' ' || *p == '\t') p++;
  if (!*p) { wanted.n = 0; have_archs = 0; free(buf); return; }
  have_archs = 1;
  FOR_WORDS(p, w) {
    if (!strcmp(w, "native")) { archs_add(&wanted, SCMP_ARCH_NATIVE); continue; }
    int found = 0;
    for (size_t i = 0; i < sizeof arch_names / sizeof arch_names[0]; i++)
      if (!strcmp(arch_names[i].name, w)) { archs_add(&wanted, arch_names[i].token); found = 1; }
    if (!found) say("unknown architecture (ignored)", w);
  }
  free(buf);
}

static void parse_families(const char *value) {
  char *buf = strdup(value);
  char *p = buf;
  while (*p == ' ' || *p == '\t') p++;
  if (!*p) { set_clear(&families); have_families = 0; free(buf); return; }
  int invert = *p == '~';
  if (invert) p++;
  if (!have_families) { have_families = 1; families_allow = !invert; }
  int add = invert != families_allow;
  FOR_WORDS(p, w) {
    int known = 0;
    for (size_t i = 0; i < sizeof af_names / sizeof af_names[0]; i++)
      if (!strcmp(af_names[i].name, w)) known = 1;
    if (!known) { say("unknown address family (ignored)", w); continue; }
    if (add) set_add(&families, w, -1); else set_del(&families, w);
  }
  free(buf);
}

static void parse_namespaces(const char *value) {
  char *buf = strdup(value);
  char *p = buf;
  while (*p == ' ' || *p == '\t') p++;
  uint32_t all = ns_all(), allowed;
  if (!*p || !strcmp(p, "no") || !strcmp(p, "false") || !strcmp(p, "0") || !strcmp(p, "off")) {
    ns_forbidden = 0;
    free(buf);
    return;
  }
  if (!strcmp(p, "yes") || !strcmp(p, "true") || !strcmp(p, "1") || !strcmp(p, "on")) {
    ns_forbidden = all;
    free(buf);
    return;
  }
  int invert = *p == '~';
  if (invert) p++;
  uint32_t listed = 0;
  FOR_WORDS(p, w) {
    int found = 0;
    for (size_t i = 0; i < N_NS; i++)
      if (!strcmp(ns_names[i].name, w)) { listed |= ns_names[i].flag; found = 1; }
    if (!found) say("unknown namespace type (ignored)", w);
  }
  allowed = invert ? all & ~listed : listed;
  ns_forbidden = all & ~allowed;
  free(buf);
}

/* ---------------------------------------------------------------------- */
/* the filters */

/* A filter for one architecture; the default action of what it does not
 * mention.  (Other architectures than that one are passed by it: one
 * filter each, as systemd loads them, and SystemCallArchitectures= for what
 * should not make system calls at all.) */
static scmp_filter_ctx new_ctx(uint32_t def, uint32_t arch) {
  scmp_filter_ctx c = seccomp_init(def);
  if (!c) return NULL;
  if (arch != SCMP_ARCH_NATIVE && arch != seccomp_arch_native()) {
    if (seccomp_arch_add(c, arch) < 0) { seccomp_release(c); return NULL; }
    seccomp_arch_remove(c, seccomp_arch_native());
  }
  seccomp_attr_set(c, SCMP_FLTATR_ACT_BADARCH, SCMP_ACT_ALLOW);
  seccomp_attr_set(c, SCMP_FLTATR_CTL_NNP, 0);
  return c;
}

static uint32_t kill_action(void) {
  return default_errno >= 0 ? SCMP_ACT_ERRNO(default_errno) : SCMP_ACT_KILL_PROCESS;
}

static int nnp_done;

/* seccomp_load() needs CAP_SYS_ADMIN or no_new_privs */
static void need_nnp(void) {
  if (nnp_done) return;
  nnp_done = 1;
  struct __user_cap_header_struct hdr = { .version = _LINUX_CAPABILITY_VERSION_3, .pid = 0 };
  struct __user_cap_data_struct data[2];
  if (syscall(SYS_capget, &hdr, data) == 0 && (data[0].effective & (1u << CAP_SYS_ADMIN)))
    return;
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) {
    say("cannot set no_new_privs", strerror(errno));
    exit(EXIT_SECCOMP);
  }
}

static int load(scmp_filter_ctx c, const char *what) {
  int r;
  if (dry_run) r = 0;
  else {
    need_nnp();
    r = seccomp_load(c);
  }
  seccomp_release(c);
  if (r < 0) {
    say(what, strerror(-r));
    return -1;
  }
  return 0;
}

static int resolve(uint32_t arch, const char *name) {
  int nr = seccomp_syscall_resolve_name_arch(arch == SCMP_ARCH_NATIVE ? seccomp_arch_native() : arch, name);
  return nr;
}

/* the list of architectures the filters are for */
static void filter_archs(struct archs *out) {
  out->n = 0;
  if (have_archs) {
    for (size_t i = 0; i < wanted.n; i++) archs_add(out, wanted.v[i]);
    return;
  }
  for (size_t i = 0; i < sizeof local_archs / sizeof local_archs[0]; i++)
    if (local_archs[i]) archs_add(out, local_archs[i]);
  if (!out->n) archs_add(out, SCMP_ARCH_NATIVE);
}

static int apply_archs(void) {
  scmp_filter_ctx c = seccomp_init(SCMP_ACT_ALLOW);
  if (!c) return -1;
  /* (the native architecture is in it; the ones that are not asked for go) */
  int native_wanted = 0;
  for (size_t i = 0; i < wanted.n; i++)
    if (wanted.v[i] == SCMP_ARCH_NATIVE || wanted.v[i] == seccomp_arch_native()) native_wanted = 1;
  for (size_t i = 0; i < wanted.n; i++)
    if (wanted.v[i] != SCMP_ARCH_NATIVE && wanted.v[i] != seccomp_arch_native())
      seccomp_arch_add(c, wanted.v[i]);
  if (!native_wanted) seccomp_arch_remove(c, seccomp_arch_native());
  seccomp_attr_set(c, SCMP_FLTATR_ACT_BADARCH, SCMP_ACT_KILL_PROCESS);
  seccomp_attr_set(c, SCMP_FLTATR_CTL_NNP, 0);
  return load(c, "cannot load the architecture filter");
}

static int apply_syscall_filter(const struct archs *archs) {
  /* an allow list has what every program needs in it */
  struct set s = { 0 };
  if (allow_list) expand(&s, "@default", 1, -1, 0);
  for (size_t i = 0; i < filter.n; i++) {
    /* (a group's names come with the error number of the group) */
    set_add(&s, filter.v[i].name, filter.v[i].err);
  }
  for (size_t a = 0; a < archs->n; a++) {
    uint32_t arch = archs->v[a];
    scmp_filter_ctx c = new_ctx(allow_list ? kill_action() : SCMP_ACT_ALLOW, arch);
    if (!c) { say("cannot make a filter", NULL); set_clear(&s); return -1; }
    for (size_t i = 0; i < s.n; i++) {
      int nr = resolve(arch, s.v[i].name);
      if (nr == __NR_SCMP_ERROR) continue;
      uint32_t act;
      if (allow_list)
        act = s.v[i].err >= 0 ? SCMP_ACT_ERRNO(s.v[i].err) : SCMP_ACT_ALLOW;
      else
        act = s.v[i].err >= 0 ? SCMP_ACT_ERRNO(s.v[i].err) : kill_action();
      /* (not there on this architecture, or not to be told apart: left out) */
      seccomp_rule_add(c, act, nr, 0);
    }
    if (load(c, "cannot load the system call filter") < 0) { set_clear(&s); return -1; }
  }
  set_clear(&s);
  return 0;
}

#define EPERM_ACT SCMP_ACT_ERRNO(EPERM)

static void rule(scmp_filter_ctx c, uint32_t act, uint32_t arch, const char *name,
                 unsigned n, struct scmp_arg_cmp a, struct scmp_arg_cmp b) {
  int nr = resolve(arch, name);
  if (nr == __NR_SCMP_ERROR) return;
  if (n == 0) seccomp_rule_add_exact(c, act, nr, 0);
  else if (n == 1) seccomp_rule_add_exact(c, act, nr, 1, a);
  else seccomp_rule_add_exact(c, act, nr, 2, a, b);
}

static const struct scmp_arg_cmp none;

static void restrict_families(scmp_filter_ctx c, uint32_t arch) {
  static const char *const calls[] = { "socket", "socketpair" };
  uint32_t act = SCMP_ACT_ERRNO(EAFNOSUPPORT);
  for (size_t k = 0; k < 2; k++) {
    if (families_allow) {
      /* every family there is, but the ones named, is refused */
      for (int af = 0; af < AF_UNKNOWN_FROM; af++) {
        int named = 0;
        for (size_t i = 0; i < sizeof af_names / sizeof af_names[0]; i++)
          if (af_names[i].value == af && set_find(&families, af_names[i].name)) named = 1;
        if (!named) rule(c, act, arch, calls[k], 1, SCMP_A0(SCMP_CMP_EQ, af), none);
      }
      rule(c, act, arch, calls[k], 1, SCMP_A0(SCMP_CMP_GE, AF_UNKNOWN_FROM), none);
    } else {
      for (size_t i = 0; i < families.n; i++)
        for (size_t j = 0; j < sizeof af_names / sizeof af_names[0]; j++)
          if (!strcmp(af_names[j].name, families.v[i].name))
            rule(c, act, arch, calls[k], 1, SCMP_A0(SCMP_CMP_EQ, af_names[j].value), none);
    }
  }
}

static void restrict_namespaces(scmp_filter_ctx c, uint32_t arch) {
  for (size_t i = 0; i < N_NS; i++) {
    uint32_t f = ns_names[i].flag;
    if (!(ns_forbidden & f)) continue;
    rule(c, EPERM_ACT, arch, "unshare", 1, SCMP_A0(SCMP_CMP_MASKED_EQ, f, f), none);
    rule(c, EPERM_ACT, arch, "clone", 1, SCMP_A0(SCMP_CMP_MASKED_EQ, f, f), none);
    rule(c, EPERM_ACT, arch, "setns", 1, SCMP_A1(SCMP_CMP_MASKED_EQ, f, f), none);
  }
  if (ns_forbidden) {
    /* (clone3 takes its flags in a structure: let glibc fall back to clone;
     * setns() of a type that is whatever the descriptor has) */
    rule(c, SCMP_ACT_ERRNO(ENOSYS), arch, "clone3", 0, none, none);
    rule(c, EPERM_ACT, arch, "setns", 1, SCMP_A1(SCMP_CMP_EQ, 0), none);
  }
}

static void restrict_suid_sgid(scmp_filter_ctx c, uint32_t arch) {
  static const unsigned bits[] = { S_ISUID, S_ISGID };
  for (size_t i = 0; i < 2; i++) {
    unsigned m = bits[i];
    rule(c, EPERM_ACT, arch, "chmod", 1, SCMP_A1(SCMP_CMP_MASKED_EQ, m, m), none);
    rule(c, EPERM_ACT, arch, "fchmod", 1, SCMP_A1(SCMP_CMP_MASKED_EQ, m, m), none);
    rule(c, EPERM_ACT, arch, "fchmodat", 1, SCMP_A2(SCMP_CMP_MASKED_EQ, m, m), none);
    rule(c, EPERM_ACT, arch, "fchmodat2", 1, SCMP_A2(SCMP_CMP_MASKED_EQ, m, m), none);
    rule(c, EPERM_ACT, arch, "open", 2, SCMP_A1(SCMP_CMP_MASKED_EQ, O_CREAT, O_CREAT),
         SCMP_A2(SCMP_CMP_MASKED_EQ, m, m));
    rule(c, EPERM_ACT, arch, "openat", 2, SCMP_A2(SCMP_CMP_MASKED_EQ, O_CREAT, O_CREAT),
         SCMP_A3(SCMP_CMP_MASKED_EQ, m, m));
  }
}

static void lock_personality_rules(scmp_filter_ctx c, uint32_t arch) {
  /* (the one it has: any other is refused, as systemd does) */
  unsigned long cur = (unsigned long)personality(0xffffffff);
  rule(c, EPERM_ACT, arch, "personality", 1, SCMP_A0(SCMP_CMP_NE, cur), none);
}

static void mdwe_rules(scmp_filter_ctx c, uint32_t arch) {
  rule(c, EPERM_ACT, arch, "mmap", 1, SCMP_A2(SCMP_CMP_MASKED_EQ, PROT_EXEC | PROT_WRITE, PROT_EXEC | PROT_WRITE), none);
  rule(c, EPERM_ACT, arch, "mmap2", 1, SCMP_A2(SCMP_CMP_MASKED_EQ, PROT_EXEC | PROT_WRITE, PROT_EXEC | PROT_WRITE), none);
  rule(c, EPERM_ACT, arch, "mprotect", 1, SCMP_A2(SCMP_CMP_MASKED_EQ, PROT_EXEC, PROT_EXEC), none);
  rule(c, EPERM_ACT, arch, "pkey_mprotect", 1, SCMP_A2(SCMP_CMP_MASKED_EQ, PROT_EXEC, PROT_EXEC), none);
  rule(c, EPERM_ACT, arch, "shmat", 1, SCMP_A2(SCMP_CMP_MASKED_EQ, SHM_EXEC, SHM_EXEC), none);
}

/* The restrictions that are rules about arguments, on the filters of every
 * architecture (what they allow they allow; they refuse with an error). */
static int apply_restrictions(const struct archs *archs, int use_mdwe_rules) {
  if (!(families.n || have_families || ns_forbidden || restrict_rt || restrict_suid ||
        lock_pers || use_mdwe_rules))
    return 0;
  for (size_t a = 0; a < archs->n; a++) {
    uint32_t arch = archs->v[a];
    scmp_filter_ctx c = new_ctx(SCMP_ACT_ALLOW, arch);
    if (!c) { say("cannot make a filter", NULL); return -1; }
    if (have_families) restrict_families(c, arch);
    if (ns_forbidden) restrict_namespaces(c, arch);
    if (restrict_rt) {
      static const int policies[] = { 1 /* FIFO */, 2 /* RR */, 6 /* DEADLINE */ };
      for (size_t i = 0; i < 3; i++)
        rule(c, EPERM_ACT, arch, "sched_setscheduler", 1, SCMP_A1(SCMP_CMP_EQ, policies[i]), none);
    }
    if (restrict_suid) restrict_suid_sgid(c, arch);
    if (lock_pers) lock_personality_rules(c, arch);
    if (use_mdwe_rules) mdwe_rules(c, arch);
    if (load(c, "cannot load the restrictions") < 0) return -1;
  }
  return 0;
}

static int apply_all(void) {
  struct archs archs;
  filter_archs(&archs);
  if (have_archs && apply_archs() < 0) return -1;
  int use_mdwe_rules = 0;
  if (mdwe) {
    if (!dry_run && prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN, 0, 0, 0) < 0)
      use_mdwe_rules = 1;                /* an older kernel: rules instead */
  }
  if (have_filter && apply_syscall_filter(&archs) < 0) return -1;
  if (apply_restrictions(&archs, use_mdwe_rules) < 0) return -1;
  return 0;
}

/* One option of the command line (also what unit-chroot is handed with -S);
 * returns the number of arguments used, 0 if it is not one of ours. */
static int take_option(int argc, char **argv) {
  const char *a = argv[0];
  if (!strcmp(a, "--restrict-realtime")) { restrict_rt = 1; return 1; }
  if (!strcmp(a, "--restrict-suid-sgid")) { restrict_suid = 1; return 1; }
  if (!strcmp(a, "--mdwe")) { mdwe = 1; return 1; }
  if (!strcmp(a, "--lock-personality")) { lock_pers = 1; return 1; }
  if (!strcmp(a, "--dry-run")) { dry_run = 1; return 1; }
  if (argc < 2) return 0;
  if (!strcmp(a, "--syscall-filter")) { parse_filter(argv[1]); return 2; }
  if (!strcmp(a, "--syscall-errno")) {
    default_errno = parse_errno(argv[1]);
    if (default_errno < 0 && *argv[1]) say("unknown error number (ignored)", argv[1]);
    return 2;
  }
  if (!strcmp(a, "--arch")) { parse_arch(argv[1]); return 2; }
  if (!strcmp(a, "--address-families")) { parse_families(argv[1]); return 2; }
  if (!strcmp(a, "--restrict-namespaces")) { parse_namespaces(argv[1]); return 2; }
  return 0;
}

#ifndef UNIT_SECCOMP_LIBRARY
static void list_groups(void) {
  for (size_t i = 0; i < N_GROUPS; i++) {
    printf("%s\n", groups[i].name);
    for (const char *m = groups[i].members; *m; m += strlen(m) + 1) printf("  %s\n", m);
  }
}

int main(int argc, char **argv) {
  int i = 1;
  while (i < argc) {
    if (!strcmp(argv[i], "--")) { i++; break; }
    if (!strcmp(argv[i], "--list-groups")) { list_groups(); return 0; }
    int n = take_option(argc - i, argv + i);
    if (!n) { say("unknown option", argv[i]); return 2; }
    i += n;
  }
  if (apply_all() < 0) return EXIT_SECCOMP;
  if (i >= argc) {
    if (dry_run) return 0;
    say("no command", NULL);
    return 2;
  }
  if (dry_run) return 0;
  execvp(argv[i], argv + i);
  fprintf(stderr, "unit-seccomp: cannot execute %s: %s\n", argv[i], strerror(errno));
  return errno == ENOENT ? 127 : 126;
}
#endif

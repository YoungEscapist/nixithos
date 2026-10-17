/*
 * pam_s6_env - the session's environment that pam_systemd would set.
 *
 *   session optional pam_s6_env.so
 *
 * Runs after the hook that starts the user's service manager and waits for
 * it (user-manager hook), as pam_systemd runs after user@UID.service is up:
 *
 *   XDG_RUNTIME_DIR           /run/user/UID, if it is there;
 *   DBUS_SESSION_BUS_ADDRESS  unix:path=/run/user/UID/bus, if the user's
 *                             session bus is listening there.
 *
 * Neither is touched if the session has it already (pam_elogind sets the
 * first, and the second when the bus was up before it ran).
 */

#define PAM_SM_SESSION
#define _GNU_SOURCE
#include <pwd.h>
#include <security/pam_ext.h>
#include <security/pam_modules.h>
#include <stdio.h>
#include <sys/stat.h>

static void put(pam_handle_t *pamh, const char *name, const char *value) {
  char buf[256];
  if (pam_getenv(pamh, name)) return;
  if (snprintf(buf, sizeof buf, "%s=%s", name, value) >= (int)sizeof buf) return;
  pam_putenv(pamh, buf);
}

PAM_EXTERN int pam_sm_open_session(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  const char *user = NULL;
  struct passwd *pw;
  struct stat st;
  char dir[64], bus[96], addr[128];

  if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || !user) return PAM_SUCCESS;
  pw = getpwnam(user);
  if (!pw) return PAM_SUCCESS;

  snprintf(dir, sizeof dir, "/run/user/%u", (unsigned)pw->pw_uid);
  if (stat(dir, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != pw->pw_uid) return PAM_SUCCESS;
  put(pamh, "XDG_RUNTIME_DIR", dir);

  snprintf(bus, sizeof bus, "%s/bus", dir);
  if (stat(bus, &st) == 0 && S_ISSOCK(st.st_mode)) {
    snprintf(addr, sizeof addr, "unix:path=%s", bus);
    put(pamh, "DBUS_SESSION_BUS_ADDRESS", addr);
  }
  return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_close_session(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  return PAM_SUCCESS;
}

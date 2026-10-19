/*
 * nixith-installer: the installer of NixithOS, in the console.
 *
 * A wizard over ncurses: the steps of the old Calamares installer (time
 * zone, language, keyboard, user, desktop, login, shell, boot loader,
 * unfree software, disk), with a network step in front of them that does
 * what nmtui does, only simpler: the wired network by itself, a list of
 * Wi-Fi networks, and a form for a connection that needs more than a
 * password (802.1X, a hidden network, PPPoE, an address by hand).  Like
 * Calamares, it shows a screenshot of each desktop, login screen, shell and
 * boot loader, and slides while it installs.  Nothing touches the disk until
 * the summary is confirmed; then ./install.sh does the work (partitioning,
 * the configuration, `nixith install`) and its output is shown as it goes.
 *
 *   nixith-installer            the installer (as root)
 *   nixith-installer --dry      the same, but install.sh only prints its plan
 *   nixith-net                  only the network step, for any system
 *
 * The interface speaks English or Russian, chosen on the first screen.
 */
#define _GNU_SOURCE
#include <crypt.h>
#include <ctype.h>
#include <curses.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/kd.h>
#include <linux/vt.h>
#include <locale.h>
#include <math.h>
#include <arpa/inet.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

/* the screenshots are JPEG files (default.nix makes them) */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wsign-compare"
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#include <stb_image.h>
#pragma GCC diagnostic pop

#ifndef INSTALL_SH
#define INSTALL_SH "./install.sh"
#endif
#ifndef LOGO_TXT
#define LOGO_TXT "/etc/nixithos/logo.txt"
#endif
#ifndef SHOTS
#define SHOTS "./screenshots"
#endif

enum { NEXT = 1, STAY = 0, BACK = -1, QUIT = -2 };

static int ru;  /* the interface's language: 0 English, 1 Russian */
#define T(en, r) (ru ? (r) : (en))

static int dry, net_only, utf8;

/* --- what the user chose ------------------------------------------------- */

static struct {
    int online;
    char tz[64];
    int locale, kb;
    char fullname[160], user[64], host[64];
    char pw1[128], pw2[128], rpw1[128], rpw2[128];
    int rootsame, autologin, user_edited;
    int desktop, dm, shell, loader, unfree;
    char disk[64], disk_desc[200];
    int manual, fs, efi;
} S = { .rootsame = 1, .host = "nixith" };

struct opt {
    const char *id, *name, *en, *ru;
};

static const struct opt desktops[] = {
    { "parallax", "Parallax",
      "A Wayland compositor where the windows live on one infinite canvas and the screen is a camera looking at it. Desks, an overview, a wallpaper-coloured theme, its own bar and tray. NixithOS's own.",
      "Wayland-композитор, где окна живут на одном бесконечном холсте, а экран — камера, которая на него смотрит. Столы, обзор, тема в цвет обоев, своя панель и трей. Собственный стол NixithOS." },
    { "gnome", "GNOME",
      "GNOME, the session and its settings, with Files, Console, Text Editor and System Monitor (other GNOME apps can be added later).",
      "GNOME: сеанс и настройки, Файлы, Консоль, Текстовый редактор и Системный монитор (остальные приложения GNOME можно добавить потом)." },
    { "plasma", "KDE Plasma",
      "KDE Plasma 6 with its usual applications: Dolphin, Konsole, Kate, Spectacle...",
      "KDE Plasma 6 с привычными приложениями: Dolphin, Konsole, Kate, Spectacle..." },
    { "hyprland", "Hyprland",
      "A dynamic tiling Wayland compositor with animations, kitty as the terminal and wofi for programs (Super+Q a terminal, Super+R programs, Super+M leaves).",
      "Динамический тайловый Wayland-композитор с анимациями, терминал kitty, программы через wofi (Super+Q терминал, Super+R программы, Super+M выход)." },
    { "niri", "niri",
      "A scrollable-tiling Wayland compositor: windows in columns on an endless strip, with alacritty, fuzzel and waybar (Super+T a terminal, Super+D programs).",
      "Wayland-композитор с прокручиваемой лентой: окна колонками на бесконечной полосе, alacritty, fuzzel и waybar (Super+T терминал, Super+D программы)." },
    { "dwl", "dwl",
      "A small tiling Wayland compositor with foot as the terminal and fuzzel to start programs.",
      "Маленький тайловый Wayland-композитор, терминал foot и fuzzel для запуска программ." },
    { "none", NULL,
      "A console system without a graphical session. A desktop can be added later: nixithos.desktop.<name>.enable = true; in /etc/nixith/configuration.nix and `sudo nixith switch`.",
      "Консольная система без графического сеанса. Стол можно добавить позже: nixithos.desktop.<имя>.enable = true; в /etc/nixith/configuration.nix и `sudo nixith switch`." },
};
#define NDESKTOPS (int)(sizeof desktops / sizeof *desktops)

static const struct opt dms[] = {
    { "ly", "ly",
      "A display manager in the console: the user, the password and the session on one screen, with an animation behind them.",
      "Менеджер входа в консоли: пользователь, пароль и сеанс на одном экране, с анимацией позади." },
    { "greetd", "greetd (tuigreet)",
      "A plain text greeter that remembers the last user and session.",
      "Простой текстовый вход, который помнит последнего пользователя и сеанс." },
    { "none", NULL,
      "No display manager: log in on the console and start the session yourself.",
      "Без менеджера входа: вход в консоли, сеанс запускается вручную." },
};
#define NDMS (int)(sizeof dms / sizeof *dms)

static const struct opt shells[] = {
    { "bash", "Bash", "The usual shell of Linux, and the one NixithOS's own scripts are written in.",
      "Привычная оболочка Linux; на ней написаны скрипты самой NixithOS." },
    { "zsh", "Zsh", "Bash-like, with better completion and a great many plugins and themes.",
      "Похожа на Bash, но с лучшим дополнением и множеством плагинов и тем." },
    { "fish", "fish", "The friendly interactive shell: suggestions as you type, colours and completion out of the box. Not POSIX.",
      "Дружелюбная оболочка: подсказки при наборе, цвета и дополнение из коробки. Не POSIX." },
    { "nushell", "Nushell", "Commands pass tables and records rather than text. Not POSIX.",
      "Команды передают друг другу таблицы и записи, а не текст. Не POSIX." },
};
#define NSHELLS (int)(sizeof shells / sizeof *shells)

static const struct opt loaders[] = {
    { "systemd-boot", "systemd-boot",
      "A simple menu of the system's generations on the EFI partition. (The only piece of systemd NixithOS installs: its bootctl.)",
      "Простое меню поколений системы на EFI-разделе. (Единственная часть systemd, которую ставит NixithOS: её bootctl.)" },
    { "limine", "Limine", "A small, fast boot loader with a menu of the generations; it can also start other systems' loaders.",
      "Маленький быстрый загрузчик с меню поколений; умеет запускать загрузчики других систем." },
    { "grub", "GRUB", "The most widespread one; finds the other systems on the disks and puts them in its menu.",
      "Самый распространённый; находит другие системы на дисках и добавляет их в меню." },
    { "refind", "rEFInd", "A menu that finds the systems on the disks by itself.",
      "Меню, которое само находит системы на дисках." },
};
#define NLOADERS (int)(sizeof loaders / sizeof *loaders)

static const struct opt locales[] = {
    { "en_US.UTF-8", "English (United States)" }, { "en_GB.UTF-8", "English (United Kingdom)" },
    { "ru_RU.UTF-8", "Русский" }, { "uk_UA.UTF-8", "Українська" }, { "be_BY.UTF-8", "Беларуская" },
    { "kk_KZ.UTF-8", "Қазақ тілі" }, { "de_DE.UTF-8", "Deutsch" }, { "fr_FR.UTF-8", "Français" },
    { "es_ES.UTF-8", "Español" }, { "it_IT.UTF-8", "Italiano" }, { "pt_BR.UTF-8", "Português (Brasil)" },
    { "pt_PT.UTF-8", "Português" }, { "pl_PL.UTF-8", "Polski" }, { "cs_CZ.UTF-8", "Čeština" },
    { "nl_NL.UTF-8", "Nederlands" }, { "sv_SE.UTF-8", "Svenska" }, { "fi_FI.UTF-8", "Suomi" },
    { "tr_TR.UTF-8", "Türkçe" }, { "zh_CN.UTF-8", "中文 (简体)" }, { "ja_JP.UTF-8", "日本語" },
    { "ko_KR.UTF-8", "한국어" },
};
#define NLOCALES (int)(sizeof locales / sizeof *locales)

/* id: the xkb layout; name; en: the console keymap; ru: non-Latin (with us) */
static const struct opt keyboards[] = {
    { "us", "English (US)", "us", "" }, { "gb", "English (UK)", "uk", "" },
    { "ru", "Русская (+ English)", "ru", "x" }, { "ua", "Українська (+ English)", "ua", "x" },
    { "by", "Беларуская (+ English)", "by", "x" }, { "kz", "Қазақша (+ English)", "kazakh", "x" },
    { "de", "Deutsch", "de", "" }, { "fr", "Français", "fr", "" }, { "es", "Español", "es", "" },
    { "it", "Italiano", "it", "" }, { "pt", "Português", "pt-latin1", "" },
    { "br", "Português (Brasil)", "br-abnt2", "" }, { "pl", "Polski", "pl", "" },
    { "cz", "Čeština", "cz", "" }, { "se", "Svenska", "se-latin1", "" }, { "fi", "Suomi", "fi", "" },
    { "no", "Norsk", "no", "" }, { "dk", "Dansk", "dk", "" }, { "tr", "Türkçe", "trq", "" },
    { "jp", "日本語", "jp106", "" },
};
#define NKEYBOARDS (int)(sizeof keyboards / sizeof *keyboards)

static const char *optname(const struct opt *o)
{
    if (o->name)
        return o->name;
    if (o == &desktops[NDESKTOPS - 1])
        return T("No desktop (a console system)", "Без рабочего стола (консольная система)");
    if (o == &dms[NDMS - 1])
        return T("The console (no display manager)", "Консоль (без менеджера входа)");
    return "?";
}

/* --- the steps ------------------------------------------------------------ */

enum {
    ST_WELCOME, ST_GUIDE, ST_NETWORK, ST_TZ, ST_LOCALE, ST_KEYBOARD, ST_USER,
    ST_DESKTOP, ST_LOGIN, ST_SHELL, ST_LOADER, ST_UNFREE, ST_DISK, ST_SUMMARY,
    ST_INSTALL, NSTEPS
};

static const char *step_name(int i)
{
    static const char *en[] = { "Welcome", "Guide", "Network", "Time zone", "Language",
        "Keyboard", "User", "Desktop", "Login", "Shell", "Boot loader", "Software",
        "Disk", "Summary", "Install" };
    static const char *r[] = { "Приветствие", "Справка", "Сеть", "Часовой пояс", "Язык",
        "Клавиатура", "Пользователь", "Рабочий стол", "Вход", "Оболочка", "Загрузчик",
        "Программы", "Диск", "Итог", "Установка" };
    return ru ? r[i] : en[i];
}

/* --- drawing -------------------------------------------------------------- */

enum { C_NORMAL = 1, C_DIM, C_SEL, C_ERR, C_OK, C_HEAD, C_PIC };
static int CY, CX, CW, CH; /* the content area */

/* the display width of a UTF-8 string */
static int dwidth(const char *s)
{
    wchar_t w[1024];
    size_t n = mbstowcs(w, s, 1023);
    if (n == (size_t)-1)
        return (int)strlen(s);
    int width = wcswidth(w, n);
    return width < 0 ? (int)n : width;
}

/* s padded with spaces to w columns, then rest */
static void padded(char *out, size_t size, const char *s, int w, const char *rest)
{
    int n = snprintf(out, size, "%s", s);
    for (int k = dwidth(s); k < w && n < (int)size - 1; k++)
        out[n++] = ' ';
    out[n] = 0;
    snprintf(out + n, size - n, "%s", rest);
}

/* drop the last character of a UTF-8 string */
static void utf8_pop(char *s)
{
    int n = strlen(s);
    while (n > 0 && (s[n - 1] & 0xC0) == 0x80)
        n--;
    if (n > 0)
        s[n - 1] = 0;
}

/* print at most maxw columns of s */
static void put(int y, int x, const char *s, int maxw)
{
    wchar_t w[1024];
    size_t n = mbstowcs(w, s, 1023);
    if (n == (size_t)-1) {
        mvaddnstr(y, x, s, maxw);
        return;
    }
    int used = 0, k = 0;
    for (; k < (int)n; k++) {
        int cw = wcwidth(w[k]);
        if (cw < 0)
            cw = 1;
        if (used + cw > maxw)
            break;
        used += cw;
    }
    mvaddnwstr(y, x, w, k);
}

/* word-wrap text into w columns from (y, x), up to row maxy; '\n' breaks */
static int wrap(int y, int x, int w, int maxy, const char *text)
{
    char line[1024] = "", word[512];
    const char *p = text;
    while (*p && y <= maxy) {
        int n = 0;
        while (*p && *p != ' ' && *p != '\n' && n < (int)sizeof word - 1)
            word[n++] = *p++;
        word[n] = 0;
        char trial[1600];
        snprintf(trial, sizeof trial, "%s%s%s", line, *line ? " " : "", word);
        if (dwidth(trial) > w && *line) {
            put(y++, x, line, w);
            snprintf(line, sizeof line, "%s", word);
        } else {
            snprintf(line, sizeof line, "%s", trial);
        }
        if (*p == '\n') {
            if (y <= maxy)
                put(y++, x, line, w);
            line[0] = 0;
            p++;
            while (*p == '\n' && y <= maxy) {
                y++;
                p++;
            }
        } else if (*p == ' ') {
            p++;
        }
    }
    if (*line && y <= maxy)
        put(y++, x, line, w);
    return y;
}

static int wrapped_lines(int w, const char *text)
{
    /* count by drawing nowhere: wrap into a scratch pad */
    WINDOW *saved = stdscr;
    WINDOW *pad = newpad(200, w + 1);
    stdscr = pad;
    int n = wrap(0, 0, w, 199, text);
    stdscr = saved;
    delwin(pad);
    return n;
}

/* --- pictures --------------------------------------------------------------- */

/*
 * The screenshots of NixithOS that Calamares showed (../../branding/
 * screenshots, as JPEG files at 16:10 on black): one for each choice of a
 * desktop, a login screen, a shell and a boot loader, and some in the slides
 * while the system installs.
 *
 * On the Linux console they are drawn straight onto its framebuffer, as fbi
 * and w3m do it, over cells the screen keeps for them: spaces in a colour
 * pair of their own (C_PIC), black on black.  Not blank to ncurses, so it
 * never clears a line through the picture, and it does not write them again
 * until the picture goes, when they become blank and that clears it away.
 * In a terminal with 24-bit colour they are half blocks instead; anywhere
 * else (a serial console, 256 colours) there are none, and that is all.
 */

enum { PIC_NONE, PIC_FB, PIC_HALF };
static int pic_mode;

static struct {
    int fd, vt, tty;  /* the framebuffer; the console's number, and it open */
    int relayed;      /* the screen is written through sudo's terminal */
    unsigned char *mem;
    size_t len;
    struct fb_var_screeninfo v;
    struct fb_fix_screeninfo f;
} fb = { .fd = -1, .tty = -1 };

/* a picture's place on the screen, in cells */
struct place {
    char name[48];
    int y, x, h, w;
};
static struct place want, shown; /* this screen's; the one on the screen */
static time_t drawn_at;

/* the virtual console of a process's standard input, or 0 */
static int vt_of(pid_t pid)
{
    char path[64];
    struct stat st;
    snprintf(path, sizeof path, "/proc/%d/fd/0", (int)pid);
    if (stat(path, &st) != 0 || !S_ISCHR(st.st_mode) || major(st.st_rdev) != 4 ||
        minor(st.st_rdev) < 1 || minor(st.st_rdev) > 63)
        return 0;
    return minor(st.st_rdev);
}

/* the console this runs on: its own terminal, or, as sudo runs a command on
 * a pseudo-terminal of its own (use_pty) and passes the screen on, the one
 * of sudo above it */
static int find_vt(void)
{
    pid_t pid = getpid();
    for (int depth = 0; depth < 4; depth++) {
        int vt = vt_of(pid);
        if (vt)
            return vt;
        char path[64], stat_[512], comm[64] = "";
        snprintf(path, sizeof path, "/proc/%d/stat", (int)pid);
        FILE *f = fopen(path, "r");
        if (!f)
            return 0;
        size_t n = fread(stat_, 1, sizeof stat_ - 1, f);
        fclose(f);
        stat_[n] = 0;
        char *close_ = strrchr(stat_, ')'); /* "pid (comm) state ppid ..." */
        int ppid = 0;
        if (!close_ || sscanf(close_ + 2, "%*c %d", &ppid) != 1 || ppid <= 1)
            return 0;
        snprintf(path, sizeof path, "/proc/%d/comm", ppid);
        if ((f = fopen(path, "r"))) {
            if (!fgets(comm, sizeof comm, f))
                comm[0] = 0;
            fclose(f);
        }
        if (strcmp(comm, "sudo\n"))
            return 0;
        pid = ppid;
        fb.relayed = 1;
    }
    return 0;
}

static void pic_init(void)
{
    if (getenv("NIXITH_NO_PICTURES"))
        return;
    char tty[32];
    if ((fb.vt = find_vt())) {
        /* a virtual console: its framebuffer, if it is one to draw on */
        snprintf(tty, sizeof tty, "/dev/tty%d", fb.vt);
        fb.tty = open(tty, O_RDONLY | O_NOCTTY | O_CLOEXEC);
        fb.fd = open("/dev/fb0", O_RDWR | O_CLOEXEC);
        if (fb.fd < 0 || fb.tty < 0)
            return;
        if (ioctl(fb.fd, FBIOGET_VSCREENINFO, &fb.v) == 0 && ioctl(fb.fd, FBIOGET_FSCREENINFO, &fb.f) == 0 &&
            fb.f.type == FB_TYPE_PACKED_PIXELS && fb.f.visual == FB_VISUAL_TRUECOLOR &&
            (fb.v.bits_per_pixel == 16 || fb.v.bits_per_pixel == 24 || fb.v.bits_per_pixel == 32) &&
            fb.v.red.length <= 8 && fb.v.green.length <= 8 && fb.v.blue.length <= 8 && fb.v.transp.length <= 8) {
            fb.len = fb.f.smem_len;
            fb.mem = mmap(NULL, fb.len, PROT_READ | PROT_WRITE, MAP_SHARED, fb.fd, 0);
            if (fb.mem != MAP_FAILED) {
                pic_mode = PIC_FB;
                return;
            }
            fb.mem = NULL;
        }
        close(fb.fd);
        fb.fd = -1;
        return;
    }
    const char *ct = getenv("COLORTERM");
    if (utf8 && ct && (strstr(ct, "truecolor") || strstr(ct, "24bit")))
        pic_mode = PIC_HALF;
}

/* the size of a cell in the picture's pixels: a half block is two of them,
 * one above the other */
static void cell(int *cw, int *ch)
{
    if (pic_mode == PIC_FB && COLS > 0 && LINES > 0) {
        *cw = fb.v.xres / COLS;
        *ch = fb.v.yres / LINES;
    } else {
        *cw = 1;
        *ch = 2;
    }
}

/* src (sw x sh, RGB) at dw x dh: a tent filter as wide as the step, so that
 * making a picture smaller averages its pixels and making it bigger blends
 * them; first along the rows, then down the columns */
static unsigned char *resample(const unsigned char *src, int sw, int sh, int dw, int dh)
{
    float *mid = malloc(sizeof *mid * dw * sh * 3);
    unsigned char *out = malloc((size_t)dw * dh * 3);
    if (!mid || !out) {
        free(mid);
        free(out);
        return NULL;
    }
    for (int pass = 0; pass < 2; pass++) {
        int n_in = pass ? sh : sw, n_out = pass ? dh : dw, lines = pass ? dw : sh;
        float s = (float)n_in / n_out, r = s > 1 ? s : 1;
        for (int o = 0; o < n_out; o++) {
            float c = (o + 0.5f) * s - 0.5f;
            int lo = (int)ceilf(c - r), hi = (int)floorf(c + r);
            for (int l = 0; l < lines; l++) {
                float acc[3] = { 0, 0, 0 }, ws = 0;
                for (int k = lo; k <= hi; k++) {
                    float w = 1 - fabsf(k - c) / r;
                    if (w <= 0)
                        continue;
                    int kk = k < 0 ? 0 : k >= n_in ? n_in - 1 : k;
                    for (int q = 0; q < 3; q++)
                        acc[q] += w * (pass ? mid[((size_t)kk * dw + l) * 3 + q] : src[((size_t)l * sw + kk) * 3 + q]);
                    ws += w;
                }
                for (int q = 0; q < 3; q++) {
                    float v = ws > 0 ? acc[q] / ws : 0;
                    if (pass)
                        out[((size_t)o * dw + l) * 3 + q] = v <= 0 ? 0 : v >= 255 ? 255 : (unsigned char)(v + 0.5f);
                    else
                        mid[((size_t)l * dw + o) * 3 + q] = v;
                }
            }
        }
    }
    free(mid);
    return out;
}

/* screenshots fitted to a box, kept for when they are shown again */
struct pix {
    char name[48];
    int bw, bh; /* the box */
    int w, h;
    unsigned char *rgb;
};
static struct pix pixes[16];
static int npix, pix_next;

static struct pix *pix_get(const char *name, int bw, int bh)
{
    for (int i = 0; i < npix; i++)
        if (pixes[i].bw == bw && pixes[i].bh == bh && !strcmp(pixes[i].name, name))
            return pixes[i].rgb ? &pixes[i] : NULL;
    struct pix *p = &pixes[pix_next];
    pix_next = (pix_next + 1) % 16;
    if (npix < 16)
        npix++;
    free(p->rgb);
    memset(p, 0, sizeof *p);
    snprintf(p->name, sizeof p->name, "%s", name);
    p->bw = bw;
    p->bh = bh;
    char path[512];
    snprintf(path, sizeof path, "%s/%s.jpg", getenv("NIXITH_SHOTS") ? getenv("NIXITH_SHOTS") : SHOTS, name);
    int sw, sh, n;
    unsigned char *src = bw > 0 && bh > 0 ? stbi_load(path, &sw, &sh, &n, 3) : NULL;
    if (!src)
        return NULL; /* (and is not looked for again) */
    int w = bw, h = (int)((long)sh * bw / sw);
    if (h > bh) {
        h = bh;
        w = (int)((long)sw * bh / sh);
    }
    if (w > 0 && h > 0 && (p->rgb = resample(src, sw, sh, w, h))) {
        p->w = w;
        p->h = h;
    }
    stbi_image_free(src);
    return p->rgb ? p : NULL;
}

/* n pixels of a row of the framebuffer from (x, y): rgb, or all of one colour */
static void fb_put(int x, int y, int n, const unsigned char *rgb, const unsigned char *one)
{
    int bpp = fb.v.bits_per_pixel / 8;
    if (y < 0 || y >= (int)fb.v.yres || x < 0)
        return;
    if (x + n > (int)fb.v.xres)
        n = fb.v.xres - x;
    size_t off = (size_t)(y + fb.v.yoffset) * fb.f.line_length + (size_t)(x + fb.v.xoffset) * bpp;
    if (n <= 0 || off + (size_t)n * bpp > fb.len)
        return;
    uint32_t alpha = fb.v.transp.length ? ((1u << fb.v.transp.length) - 1) << fb.v.transp.offset : 0;
    unsigned char *d = fb.mem + off;
    for (int i = 0; i < n; i++, d += bpp) {
        const unsigned char *c = rgb ? rgb + i * 3 : one;
        uint32_t v = alpha | (uint32_t)(c[0] >> (8 - fb.v.red.length)) << fb.v.red.offset |
                     (uint32_t)(c[1] >> (8 - fb.v.green.length)) << fb.v.green.offset |
                     (uint32_t)(c[2] >> (8 - fb.v.blue.length)) << fb.v.blue.offset;
        if (bpp == 4) {
            memcpy(d, &v, 4);
        } else if (bpp == 2) {
            uint16_t s = v;
            memcpy(d, &s, 2);
        } else {
            d[0] = v;
            d[1] = v >> 8;
            d[2] = v >> 16;
        }
    }
}

static void pic_draw(const struct place *p)
{
    static const unsigned char black[3] = { 0, 0, 0 }, frame[3] = { 0x2a, 0x2a, 0x2a };
    if (!p->name[0])
        return;
    int cw, ch;
    cell(&cw, &ch);
    if (pic_mode == PIC_FB) {
        struct vt_stat vs;
        int mode = KD_TEXT;
        if (ioctl(fb.tty, VT_GETSTATE, &vs) != 0 || vs.v_active != fb.vt)
            return; /* another console is on the screen */
        if (ioctl(fb.tty, KDGETMODE, &mode) == 0 && mode != KD_TEXT)
            return; /* a graphical session has it */
        int X = p->x * cw, Y = p->y * ch, W = p->w * cw, H = p->h * ch;
        struct pix *im = pix_get(p->name, W - 2, H - 2);
        /* the screenshot in a thin frame, at the top of its cells and in the
         * middle across; the rest of them black (painted around it, not
         * under it: that would flicker) */
        int fw = im ? im->w + 2 : 0, fh = im ? im->h + 2 : 0, fx = X + (W - fw) / 2;
        for (int y = 0; y < H; y++) {
            if (y >= fh) {
                fb_put(X, Y + y, W, NULL, black);
                continue;
            }
            fb_put(X, Y + y, fx - X, NULL, black);
            fb_put(fx + fw, Y + y, X + W - fx - fw, NULL, black);
            if (y == 0 || y == fh - 1) {
                fb_put(fx, Y + y, fw, NULL, frame);
            } else {
                fb_put(fx, Y + y, 1, NULL, frame);
                fb_put(fx + 1, Y + y, im->w, im->rgb + (size_t)(y - 1) * im->w * 3, NULL);
                fb_put(fx + fw - 1, Y + y, 1, NULL, frame);
            }
        }
    } else if (pic_mode == PIC_HALF) {
        struct pix *im = pix_get(p->name, p->w, p->h * 2);
        if (!im)
            return;
        int x0 = p->x + (p->w - im->w) / 2;
        printf("\0337");
        for (int r = 0; r < (im->h + 1) / 2; r++) {
            printf("\033[%d;%dH", p->y + r + 1, x0 + 1);
            for (int x = 0; x < im->w; x++) {
                const unsigned char *t = im->rgb + ((size_t)2 * r * im->w + x) * 3;
                if (2 * r + 1 < im->h) {
                    const unsigned char *b = t + (size_t)im->w * 3;
                    printf("\033[38;2;%d;%d;%d;48;2;%d;%d;%dm▀", t[0], t[1], t[2], b[0], b[1], b[2]);
                } else {
                    printf("\033[38;2;%d;%d;%d;49m▀", t[0], t[1], t[2]);
                }
            }
            printf("\033[0m");
        }
        printf("\0338");
        fflush(stdout);
    }
    drawn_at = time(NULL);
}

/* this screen's picture: the screenshot `name` in h rows by w columns from
 * (y, x); after chrome(), which takes the last screen's away */
static void pic(const char *name, int y, int x, int h, int w)
{
    memset(&want, 0, sizeof want);
    if (!pic_mode || !name || h < 4 || w < 12)
        return;
    snprintf(want.name, sizeof want.name, "%s", name);
    want.y = y;
    want.x = x;
    want.h = h;
    want.w = w;
    attron(COLOR_PAIR(C_PIC));
    for (int r = 0; r < h; r++)
        mvhline(y + r, x, ' ', w);
    attroff(COLOR_PAIR(C_PIC));
}

/* the picture away, its cells blank again: for a dialog over the screen */
static void pic_hide(void)
{
    if (!want.name[0])
        return;
    attr_t a;
    short pair;
    attr_get(&a, &pair, NULL);
    attrset(A_NORMAL);
    for (int r = 0; r < want.h; r++)
        mvhline(want.y + r, want.x, ' ', want.w);
    attr_set(a, pair, NULL);
    memset(&want, 0, sizeof want);
}

/* the screen as drawn, and then its picture: again only when it is another,
 * or once a second (the console paints over it when it comes back from
 * another one) */
static void present(void)
{
    int moved = want.y != shown.y || want.x != shown.x || want.h != shown.h || want.w != shown.w || !shown.name[0];
    refresh();
    if (want.name[0] && (moved || strcmp(want.name, shown.name) || time(NULL) != drawn_at)) {
        if (moved && fb.relayed && pic_mode == PIC_FB) {
            /* the picture's blank cells were just written, and go through
             * sudo on their way to the console: the picture after them */
            tcdrain(1);
            usleep(50000);
        }
        pic_draw(&want);
    }
    shown = want;
}

/* get_wch(), with the picture drawn again every second while it waits */
static int key(wint_t *c)
{
    for (;;) {
        timeout(pic_mode == PIC_FB && shown.name[0] ? 1000 : -1);
        int r = get_wch(c);
        if (r != ERR || !(pic_mode == PIC_FB && shown.name[0])) {
            timeout(-1);
            return r;
        }
        pic_draw(&shown);
    }
}

static int cur_step;

static void chrome(const char *keys)
{
    erase();
    memset(&want, 0, sizeof want);
    int sw = 20;
    /* the header */
    attron(COLOR_PAIR(C_HEAD));
    mvhline(0, 0, ' ', COLS);
    put(0, 2, net_only ? T("NixithOS · network", "NixithOS · сеть")
                       : T("NixithOS · installer", "NixithOS · установка"), COLS - 4);
    if (!net_only) {
        char pos[48];
        snprintf(pos, sizeof pos, T("step %d of %d", "шаг %d из %d"), cur_step + 1, NSTEPS);
        put(0, COLS - dwidth(pos) - 2, pos, dwidth(pos));
    }
    attroff(COLOR_PAIR(C_HEAD));

    if (!net_only) {
        /* the steps down the left */
        for (int i = 0; i < NSTEPS && 2 + i < LINES - 2; i++) {
            if (i == cur_step) {
                attron(COLOR_PAIR(C_SEL));
                mvhline(2 + i, 0, ' ', sw);
                mvaddch(2 + i, 1, ACS_RARROW);
                put(2 + i, 3, step_name(i), sw - 4);
                attroff(COLOR_PAIR(C_SEL));
            } else if (i < cur_step) {
                attron(COLOR_PAIR(C_NORMAL));
                mvaddch(2 + i, 1, ACS_BULLET);
                put(2 + i, 3, step_name(i), sw - 4);
                attroff(COLOR_PAIR(C_NORMAL));
            } else {
                attron(COLOR_PAIR(C_DIM) | A_BOLD);
                put(2 + i, 3, step_name(i), sw - 4);
                attroff(COLOR_PAIR(C_DIM) | A_BOLD);
            }
        }
        attron(COLOR_PAIR(C_DIM) | A_BOLD);
        mvvline(1, sw + 1, ACS_VLINE, LINES - 2);
        attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        CX = sw + 4;
    } else {
        CX = 3;
    }
    CY = 2;
    CW = COLS - CX - 3;
    CH = LINES - 4;

    /* the keys at the bottom */
    attron(COLOR_PAIR(C_DIM) | A_BOLD);
    mvhline(LINES - 2, 0, ACS_HLINE, COLS);
    put(LINES - 1, 2, keys, COLS - 4);
    attroff(COLOR_PAIR(C_DIM) | A_BOLD);
}

static void title(int *y, const char *t)
{
    attron(A_BOLD);
    put((*y)++, CX, t, CW);
    attroff(A_BOLD);
    (*y)++;
}

static int too_small(void)
{
    if (COLS >= 72 && LINES >= 22)
        return 0;
    erase();
    memset(&want, 0, sizeof want);
    put(0, 0, T("The terminal is too small (72x22 at least).",
                "Терминал слишком мал (нужно хотя бы 72x22)."), COLS);
    present();
    return 1;
}

/* --- dialogs -------------------------------------------------------------- */

/* a box in the middle; returns the chosen button (Esc: the last one) */
static int dialog(const char *head, const char *text, const char *b1, const char *b2, const char *b3)
{
    const char *btn[3] = { b1, b2, b3 };
    int nb = b3 ? 3 : b2 ? 2 : 1, sel = 0;
    for (;;) {
        pic_hide();
        int w = COLS - 8 < 64 ? COLS - 8 : 64;
        int h = wrapped_lines(w - 4, text) + 6;
        if (h > LINES - 2)
            h = LINES - 2;
        int y0 = (LINES - h) / 2, x0 = (COLS - w) / 2;
        attron(COLOR_PAIR(C_NORMAL));
        for (int y = y0; y < y0 + h; y++)
            mvhline(y, x0, ' ', w);
        attron(A_BOLD);
        mvhline(y0, x0, ACS_HLINE, w);
        mvhline(y0 + h - 1, x0, ACS_HLINE, w);
        mvvline(y0, x0, ACS_VLINE, h);
        mvvline(y0, x0 + w - 1, ACS_VLINE, h);
        mvaddch(y0, x0, ACS_ULCORNER);
        mvaddch(y0, x0 + w - 1, ACS_URCORNER);
        mvaddch(y0 + h - 1, x0, ACS_LLCORNER);
        mvaddch(y0 + h - 1, x0 + w - 1, ACS_LRCORNER);
        char ht[160];
        snprintf(ht, sizeof ht, " %s ", head);
        put(y0, x0 + 2, ht, w - 4);
        attroff(A_BOLD);
        wrap(y0 + 2, x0 + 2, w - 4, y0 + h - 4, text);
        int bx = x0 + w - 2;
        for (int i = nb - 1; i >= 0; i--) {
            char b[80];
            snprintf(b, sizeof b, "  %s  ", btn[i]);
            bx -= dwidth(b) + 1;
            if (i == sel)
                attron(COLOR_PAIR(C_SEL));
            put(y0 + h - 2, bx, b, dwidth(b));
            if (i == sel)
                attroff(COLOR_PAIR(C_SEL));
        }
        attroff(COLOR_PAIR(C_NORMAL));
        present();
        wint_t c;
        int r = key(&c);
        if (r == KEY_CODE_YES) {
            if (c == KEY_LEFT || c == KEY_BTAB)
                sel = (sel + nb - 1) % nb;
            else if (c == KEY_RIGHT)
                sel = (sel + 1) % nb;
            else if (c == KEY_ENTER)
                return sel;
        } else if (r == OK) {
            if (c == '\t')
                sel = (sel + 1) % nb;
            else if (c == '\n' || c == '\r')
                return sel;
            else if (c == 27)
                return nb - 1;
        }
    }
}

static void msg(const char *head, const char *text)
{
    dialog(head, text, T("OK", "Хорошо"), NULL, NULL);
}

static void quit_installer(void)
{
    pic_hide();
    present();
    endwin();
    if (!net_only)
        printf("%s\n", T("The installer is closed. `sudo nixith-installer` starts it again.",
                         "Установщик закрыт. `sudo nixith-installer` запустит его снова."));
    exit(0);
}

static int ask_quit(void)
{
    if (dialog(T("Quit", "Выход"),
               net_only ? T("Close the network settings?", "Закрыть настройку сети?")
                        : T("Quit the installer? Nothing has been written to the disk.",
                            "Выйти из установщика? На диск ничего не записано."),
               T("Quit", "Выйти"), T("Stay", "Остаться"), NULL) == 0)
        quit_installer();
    return STAY;
}

/* --- a list to choose from ------------------------------------------------ */

struct menu {
    const char *title, *intro;
    const char **art;
    int nart;
    const char **items;
    int n;
    const char *(*desc)(int);
    int search;     /* typing narrows the list */
    const char *keys;
    const char *(*pic)(int); /* the screenshot of a choice, or NULL */
};

/* the screenshot `name` on the right of the content area from row y, in
 * share percent of its width and at most maxh rows; the text keeps the rest
 * of CW.  Only on a screen wide enough for both. */
static void pic_right(const char *name, int y, int share, int maxh)
{
    if (!pic_mode || !name || CW < 84)
        return;
    int cw, ch;
    cell(&cw, &ch);
    int pw = CW * share / 100;
    int ph = ((pw * cw - 2) * 10 / 16 + 2 + ch - 1) / ch; /* 16:10, framed */
    if (ph > maxh) {
        ph = maxh;
        pw = ((ph * ch - 2) * 16 / 10 + 2 + cw - 1) / cw;
    }
    pic(name, y, CX + CW - pw, ph, pw);
    if (want.name[0])
        CW -= pw + 3;
}

static int run_menu(struct menu *m, int *sel)
{
    char q[64] = "";
    int top = 0;
    int *vis = malloc(sizeof(int) * (m->n + 1));
    for (;;) {
        if (too_small()) {
            wint_t c;
            key(&c);
            continue;
        }
        /* what matches the search */
        int nv = 0, vsel = 0;
        for (int i = 0; i < m->n; i++)
            if (!*q || strcasestr(m->items[i], q)) {
                if (i == *sel)
                    vsel = nv;
                vis[nv++] = i;
            }
        if (nv && (vsel >= nv || vis[vsel] != *sel))
            *sel = vis[vsel];

        chrome(m->keys ? m->keys
                       : m->search ? T("↑↓ move   type to search   Enter: next   Esc: back   F10: quit",
                                       "↑↓ выбор   набор: поиск   Enter: далее   Esc: назад   F10: выход")
                                   : T("↑↓ move   Enter: next   Esc: back   F10: quit",
                                       "↑↓ выбор   Enter: далее   Esc: назад   F10: выход"));
        if (m->pic && nv)
            pic_right(m->pic(*sel), CY, 55, CH - 1);
        int y = CY;
        int need = (m->title ? 2 : 0) + (m->intro ? wrapped_lines(CW, m->intro) + 1 : 0) + m->n;
        if (m->art && m->nart + 1 + need <= CH) {
            int aw = 0;
            for (int i = 0; i < m->nart; i++)
                if (dwidth(m->art[i]) > aw)
                    aw = dwidth(m->art[i]);
            int ax = CX + (CW - aw) / 2;
            attron(A_BOLD);
            for (int i = 0; i < m->nart; i++)
                put(y++, ax < CX ? CX : ax, m->art[i], CW);
            attroff(A_BOLD);
            y++;
        }
        if (m->title)
            title(&y, m->title);
        if (m->intro) {
            y = wrap(y, CX, CW, CY + CH - 4, m->intro);
            y++;
        }
        int descrows = 0;
        if (m->desc && nv)
            descrows = wrapped_lines(CW, m->desc(*sel)) + 1;
        if (descrows > 6)
            descrows = 6;
        int bottom = CY + CH - 1 - descrows - (m->search ? 2 : 0);
        int rows = bottom - y + 1;
        if (rows < 3)
            rows = 3;
        if (vsel < top)
            top = vsel;
        if (vsel >= top + rows)
            top = vsel - rows + 1;
        for (int r = 0; r < rows && top + r < nv; r++) {
            int i = vis[top + r];
            if (i == *sel) {
                attron(COLOR_PAIR(C_SEL));
                mvhline(y + r, CX, ' ', CW);
                mvaddch(y + r, CX + 1, ACS_RARROW);
            }
            put(y + r, CX + 3, m->items[i], CW - 4);
            if (i == *sel)
                attroff(COLOR_PAIR(C_SEL));
        }
        if (top > 0) {
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            mvaddch(y, CX + CW - 1, ACS_UARROW);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        }
        if (top + rows < nv) {
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            mvaddch(y + rows - 1, CX + CW - 1, ACS_DARROW);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        }
        if (!nv) {
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            put(y, CX + 3, T("nothing matches", "ничего не найдено"), CW - 4);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        }
        if (m->search) {
            char s[128];
            snprintf(s, sizeof s, "%s %s", T("Search:", "Поиск:"), q);
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            put(bottom + 2 > CY + CH - 1 - descrows ? bottom + 1 : bottom + 2, CX, s, CW);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        }
        if (m->desc && nv) {
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            mvhline(CY + CH - descrows, CX, ACS_HLINE, CW);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
            wrap(CY + CH - descrows + 1, CX, CW, CY + CH, m->desc(*sel));
        }
        present();

        wint_t c;
        int r = key(&c);
        if (r == KEY_CODE_YES) {
            switch (c) {
            case KEY_UP: if (vsel > 0) *sel = vis[vsel - 1]; break;
            case KEY_DOWN: if (vsel + 1 < nv) *sel = vis[vsel + 1]; break;
            case KEY_PPAGE: *sel = vis[vsel - rows > 0 ? vsel - rows : 0]; break;
            case KEY_NPAGE: if (nv) *sel = vis[vsel + rows < nv ? vsel + rows : nv - 1]; break;
            case KEY_HOME: if (nv) *sel = vis[0]; break;
            case KEY_END: if (nv) *sel = vis[nv - 1]; break;
            case KEY_ENTER: if (nv) { free(vis); return NEXT; } break;
            case KEY_F(10): ask_quit(); break;
            case KEY_BACKSPACE: utf8_pop(q); break;
            }
        } else if (r == OK) {
            if (c == '\n' || c == '\r') {
                if (nv) {
                    free(vis);
                    return NEXT;
                }
            } else if (c == 27) {
                if (*q)
                    q[0] = 0;
                else {
                    free(vis);
                    return BACK;
                }
            } else if (c == 127 || c == 8) {
                if (*q)
                    utf8_pop(q);
            } else if (m->search && c > 32 && c != 127) {
                char mb[8];
                mbstate_t st = { 0 };
                size_t k = wcrtomb(mb, c, &st);
                if (k != (size_t)-1 && strlen(q) + k < sizeof q) {
                    mb[k] = 0;
                    strcat(q, mb);
                }
                top = 0;
            } else if (!m->search && (c == 'k' || c == 'j')) {
                if (c == 'k' && vsel > 0)
                    *sel = vis[vsel - 1];
                if (c == 'j' && vsel + 1 < nv)
                    *sel = vis[vsel + 1];
            }
        }
    }
}

/* --- commands -------------------------------------------------------------- */

/* run argv, collect its output (stdout and stderr); returns the exit code */
static int run(char *const argv[], char *out, size_t size)
{
    int fd[2];
    if (pipe(fd) < 0)
        return -1;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(fd[1], 1);
        dup2(fd[1], 2);
        close(fd[0]);
        close(fd[1]);
        int nul = open("/dev/null", O_RDONLY);
        if (nul >= 0)
            dup2(nul, 0);
        setenv("LC_ALL", "C", 1);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(fd[1]);
    size_t n = 0;
    ssize_t k;
    char sink[4096];
    while ((k = read(fd[0], out && n < size - 1 ? out + n : sink,
                     out && n < size - 1 ? size - 1 - n : sizeof sink)) > 0)
        if (out && n < size - 1)
            n += k;
    if (out)
        out[n] = 0;
    close(fd[0]);
    int st;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* a whole-screen message while something slow runs */
static void busy(const char *text)
{
    chrome("");
    int y = CY;
    title(&y, text);
    attron(COLOR_PAIR(C_DIM) | A_BOLD);
    put(y, CX, T("Please wait...", "Подождите..."), CW);
    attroff(COLOR_PAIR(C_DIM) | A_BOLD);
    present();
}

/* the user's shell, then back to the screen */
static void shell(const char *note)
{
    pic_hide();
    present();
    def_prog_mode();
    endwin();
    printf("\n%s\n%s\n\n", note, T("Type `exit` to return to the installer.",
                                     "Наберите `exit`, чтобы вернуться в установщик."));
    fflush(stdout);
    if (system("${SHELL:-bash} -l") == -1)
        perror("bash");
    reset_prog_mode();
    present();
}

/* --- 1. welcome ------------------------------------------------------------- */

static const char *art[32];
static int nart;

static void load_art(void)
{
    FILE *f = fopen(getenv("NIXITH_LOGO") ? getenv("NIXITH_LOGO") : LOGO_TXT, "r");
    if (!f)
        return;
    char line[256];
    while (nart < 32 && fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        art[nart++] = strdup(line);
    }
    fclose(f);
}

static int step_welcome(void)
{
    static const char *langs[] = { "English", "Русский" };
    int sel = ru;
    struct menu m = {
        .title = T("Welcome to NixithOS", "Добро пожаловать в NixithOS"),
        .intro = T("NixOS without systemd: the same packages and configuration, with s6-rc running the system. Choose the language of the installer.",
                   "NixOS без systemd: те же пакеты и конфигурация, а систему запускает s6-rc. Выберите язык установщика."),
        .art = art, .nart = nart, .items = langs, .n = 2,
        .keys = "↑↓  Enter  F10",
    };
    int r = run_menu(&m, &sel);
    if (r == NEXT) {
        ru = sel;
        if (!S.locale)
            S.locale = ru ? 2 : 0;
        if (!S.kb)
            S.kb = ru ? 2 : 0;
        if (!*S.tz)
            snprintf(S.tz, sizeof S.tz, "%s", ru ? "Europe/Moscow" : "UTC");
    }
    return r == BACK ? STAY : r;
}

/* --- 2. guide --------------------------------------------------------------- */

static int step_guide(void)
{
    for (;;) {
        chrome(T("Enter: next   Esc: back   F10: quit", "Enter: далее   Esc: назад   F10: выход"));
        int y = CY;
        title(&y, T("How it goes", "Как это работает"));
        y = wrap(y, CX, CW, CY + CH, T(
            "The installer asks a few questions, one per step: the list on the left shows where you are. Nothing is written to the disk until the very last step, after the summary.\n\n"
            "Keys:\n"
            "  ↑ ↓       move through a list\n"
            "  Enter     choose and go on\n"
            "  Esc       go back a step (answers are kept)\n"
            "  Tab       the next field of a form\n"
            "  Space     tick a box\n"
            "  letters   search in long lists (time zones)\n"
            "  F10       quit\n\n"
            "Next comes the network: the installation downloads the desktop you choose, so connect to the internet if you can. A cable works by itself; for Wi-Fi pick the network and type its password. A network with a login (802.1X), a hidden one, PPPoE and an address by hand are there too.\n\n"
            "Need a shell? Alt+F2 opens another console.",
            "Установщик задаёт несколько вопросов, по одному на шаг; список слева показывает, где вы сейчас. На диск ничего не пишется до самого последнего шага, после итога.\n\n"
            "Клавиши:\n"
            "  ↑ ↓       ходить по списку\n"
            "  Enter     выбрать и идти дальше\n"
            "  Esc       шаг назад (ответы сохраняются)\n"
            "  Tab       следующее поле формы\n"
            "  Пробел    поставить галочку\n"
            "  буквы     поиск в длинных списках (часовые пояса)\n"
            "  F10       выход\n\n"
            "Дальше — сеть: установка скачивает выбранный рабочий стол, поэтому подключитесь к интернету, если можете. Кабель работает сам; для Wi-Fi выберите сеть и введите пароль. Там же — сети с логином (802.1X), скрытые сети, PPPoE и адрес вручную.\n\n"
            "Нужна консоль? Alt+F2 открывает ещё одну."));
        present();
        wint_t c;
        int r = key(&c);
        if (r == OK && (c == '\n' || c == '\r'))
            return NEXT;
        if (r == KEY_CODE_YES && c == KEY_ENTER)
            return NEXT;
        if (r == OK && c == 27)
            return BACK;
        if (r == KEY_CODE_YES && c == KEY_F(10))
            ask_quit();
    }
}

/* --- forms ------------------------------------------------------------------- */

enum { F_TEXT, F_PASS, F_CHECK, F_CHOICE };
struct field {
    const char *label;
    char *buf;
    int size, kind, *flag, hidden;
    const char **opts; /* F_CHOICE: what to choose from; *flag is the choice */
    int nopts;
    const char *hint;  /* shown greyed in an empty field: "optional", an example */
    int gap;           /* an empty row before it */
};

static void edit_utf8(char *buf, int size, wint_t c)
{
    if (c == 127 || c == 8 || c == KEY_BACKSPACE) {
        int n = strlen(buf);
        while (n > 0 && (buf[n - 1] & 0xC0) == 0x80)
            n--;
        if (n > 0)
            buf[n - 1] = 0;
        return;
    }
    char mb[8];
    mbstate_t st = { 0 };
    size_t k = wcrtomb(mb, c, &st);
    if (k != (size_t)-1 && strlen(buf) + k < (size_t)size) {
        mb[k] = 0;
        strcat(buf, mb);
    }
}

/* one round of a form: its fields under a title, then a key.  Tab and the
 * arrows go through the fields, Space ticks a box, ← → and Space change a
 * choice, F2 shows the passwords.  NEXT on Enter (from any field), BACK on
 * Esc, STAY on anything else.  It scrolls when it is longer than the screen. */
static int form_round(const char *head, const char *intro, struct field *f, int nf, int *cur,
                      const char *err, const char *keys)
{
    static int show_pw, top;
    for (int i = 0; i < nf && f[*cur].hidden; i++)
        *cur = (*cur + 1) % nf;
    if (too_small()) {
        wint_t c;
        key(&c);
        return STAY;
    }
    chrome(keys);
    int y = CY;
    title(&y, head);
    if (intro) {
        y = wrap(y, CX, CW, CY + CH - 6, intro);
        y++;
    }
    int lw = 0;
    for (int i = 0; i < nf; i++)
        if (!f[i].hidden && f[i].kind != F_CHECK && dwidth(f[i].label) > lw)
            lw = dwidth(f[i].label);
    lw += 2;
    int iw = CW - lw - 2 < 46 ? CW - lw - 2 : 46;
    int ry[32] = { 0 }, rows = 0;
    for (int i = 0; i < nf && i < 32; i++) {
        if (f[i].hidden)
            continue;
        if (f[i].gap && rows)
            rows++;
        ry[i] = rows++;
    }
    int errrows = err ? wrapped_lines(CW, err) + 1 : 0;
    int avail = CY + CH - y - errrows;
    if (avail < 3)
        avail = 3;
    if (rows <= avail || ry[*cur] < top)
        top = rows <= avail ? 0 : ry[*cur];
    if (ry[*cur] >= top + avail)
        top = ry[*cur] - avail + 1;
    int cy = y, cx = CX;
    for (int i = 0; i < nf && i < 32; i++) {
        if (f[i].hidden || ry[i] < top || ry[i] >= top + avail)
            continue;
        int yy = y + ry[i] - top, on = i == *cur;
        if (f[i].kind == F_CHECK) {
            if (on)
                attron(A_BOLD);
            put(yy, CX, *f[i].flag ? "[x]" : "[ ]", 3);
            put(yy, CX + 4, f[i].label, CW - 4);
            if (on) {
                attroff(A_BOLD);
                cy = yy;
                cx = CX + 1;
            }
            continue;
        }
        if (on)
            attron(A_BOLD);
        put(yy, CX, f[i].label, lw);
        if (on)
            attroff(A_BOLD);
        char txt[300];
        if (f[i].kind == F_CHOICE) {
            snprintf(txt, sizeof txt, "< %s >", f[i].opts[*f[i].flag]);
        } else if (f[i].kind == F_PASS && !show_pw) {
            int n = dwidth(f[i].buf), k = 0;
            for (; k < n && k < 290; k++)
                txt[k] = '*';
            txt[k] = 0;
        } else {
            snprintf(txt, sizeof txt, "%s", f[i].buf);
        }
        /* (the line of an empty field begins after its hint) */
        int skip = !*txt && f[i].hint && !on ? dwidth(f[i].hint) + 1 : 0;
        attron(on ? COLOR_PAIR(C_SEL) : COLOR_PAIR(C_DIM) | A_BOLD);
        if (on)
            mvhline(yy, CX + lw, ' ', iw);
        else if (f[i].kind != F_CHOICE && iw - 1 - skip > 0)
            mvhline(yy, CX + lw + 1 + skip, '_', iw - 1 - skip);
        attroff(on ? COLOR_PAIR(C_SEL) : COLOR_PAIR(C_DIM) | A_BOLD);
        if (!*txt && f[i].hint && !on) {
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            put(yy, CX + lw + 1, f[i].hint, iw - 2);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        } else {
            const char *vis = txt; /* the end of a long one in sight */
            while (on && f[i].kind != F_CHOICE && dwidth(vis) > iw - 2 && *vis)
                vis++;
            if (on)
                attron(COLOR_PAIR(C_SEL));
            put(yy, CX + lw + 1, vis, iw - 2);
            if (on) {
                attroff(COLOR_PAIR(C_SEL));
                cy = yy;
                cx = CX + lw + 1 + (f[i].kind == F_CHOICE ? 0 : dwidth(vis) < iw - 2 ? dwidth(vis) : iw - 2);
            }
        }
    }
    attron(COLOR_PAIR(C_DIM) | A_BOLD);
    if (top > 0)
        mvaddch(y, CX + CW - 1, ACS_UARROW);
    if (rows > top + avail)
        mvaddch(y + avail - 1, CX + CW - 1, ACS_DARROW);
    attroff(COLOR_PAIR(C_DIM) | A_BOLD);
    if (err) {
        attron(COLOR_PAIR(C_ERR) | A_BOLD);
        wrap(CY + CH - errrows + 1, CX, CW, CY + CH, err);
        attroff(COLOR_PAIR(C_ERR) | A_BOLD);
    }
    struct field *fc = &f[*cur];
    move(cy, cx);
    curs_set(fc->kind == F_TEXT || fc->kind == F_PASS);
    present();
    wint_t c;
    int r = key(&c);
    curs_set(0);
    int dir = 0;
    if (r == KEY_CODE_YES) {
        switch (c) {
        case KEY_UP:
        case KEY_BTAB: dir = -1; break;
        case KEY_DOWN: dir = 1; break;
        case KEY_LEFT:
        case KEY_RIGHT:
            if (fc->kind == F_CHOICE)
                *fc->flag = (*fc->flag + (c == KEY_RIGHT ? 1 : fc->nopts - 1)) % fc->nopts;
            break;
        case KEY_ENTER: return NEXT;
        case KEY_F(2): show_pw = !show_pw; break;
        case KEY_F(10): ask_quit(); break;
        case KEY_BACKSPACE:
            if (fc->buf)
                edit_utf8(fc->buf, fc->size, c);
            break;
        }
    } else if (r == OK) {
        if (c == '\t')
            dir = 1;
        else if (c == 27)
            return BACK;
        else if (c == '\n' || c == '\r')
            return NEXT;
        else if (c == ' ' && fc->kind == F_CHECK)
            *fc->flag = !*fc->flag;
        else if (c == ' ' && fc->kind == F_CHOICE)
            *fc->flag = (*fc->flag + 1) % fc->nopts;
        else if (fc->buf && (c == 127 || c == 8 || c >= 32))
            edit_utf8(fc->buf, fc->size, c);
    }
    if (dir) {
        do
            *cur = (*cur + dir + nf) % nf;
        while (f[*cur].hidden);
    }
    return STAY;
}

/* --- 3. network (what nmtui does, simpler) ---------------------------------- */

struct wifi {
    char ssid[96], security[48];
    int signal, inuse;
};
static struct wifi nets[64];
static int nnets, wifi_dev;
static char wired[160], eth[32], net_line[200];

/* the connections made here that the installed system is to keep */
static struct {
    char uuid[40], name[100];
} kept[8];
static int nkept;

static int have_nmcli(void)
{
    char *a[] = { "nmcli", "--version", NULL };
    return run(a, NULL, 0) == 0;
}

static void net_scan(int rescan)
{
    char out[16384];
    /* the devices: what is connected, and the cable's one */
    char *dev[] = { "nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", NULL };
    wired[0] = eth[0] = 0;
    wifi_dev = 0;
    if (run(dev, out, sizeof out) == 0) {
        for (char *l = strtok(out, "\n"); l; l = strtok(NULL, "\n")) {
            char *f[4] = { 0 };
            int k = 0;
            for (char *p = l; k < 4; k++) {
                f[k] = p;
                char *c = strchr(p, ':');
                if (!c)
                    break;
                *c = 0;
                p = c + 1;
            }
            if (!f[1] || !f[2])
                continue;
            if (!strcmp(f[1], "wifi"))
                wifi_dev = 1;
            if (!strcmp(f[1], "ethernet")) {
                int up = !strncmp(f[2], "connected", 9);
                if (!*eth || up)
                    snprintf(eth, sizeof eth, "%s", f[0]);
                if (up)
                    snprintf(wired, sizeof wired, "%s", f[0]);
            }
        }
    }
    char *chk[] = { "nmcli", "networking", "connectivity", "check", NULL };
    run(chk, out, sizeof out);
    S.online = !strncmp(out, "full", 4) || !strncmp(out, "limited", 7);

    nnets = 0;
    if (!wifi_dev)
        return;
    char *list[] = { "nmcli", "-t", "-f", "IN-USE,SIGNAL,SECURITY,SSID", "device", "wifi", "list",
                     "--rescan", rescan ? "yes" : "auto", NULL };
    if (run(list, out, sizeof out) != 0)
        return;
    for (char *l = strtok(out, "\n"); l && nnets < 64; l = strtok(NULL, "\n")) {
        /* fields separated by unescaped ':'; the SSID last, with \: and \\ */
        char *f[4];
        int k = 0;
        char *p = l;
        f[k++] = p;
        while (*p && k < 4) {
            if (*p == '\\' && p[1]) {
                p += 2;
                continue;
            }
            if (*p == ':') {
                *p = 0;
                f[k++] = p + 1;
            }
            p++;
        }
        if (k < 4 || !*f[3])
            continue;
        char ssid[96];
        int j = 0;
        for (char *s = f[3]; *s && j < 95; s++) {
            if (*s == '\\' && s[1])
                s++;
            ssid[j++] = *s;
        }
        ssid[j] = 0;
        int dup = -1;
        for (int i = 0; i < nnets; i++)
            if (!strcmp(nets[i].ssid, ssid))
                dup = i;
        int sig = atoi(f[1]);
        if (dup >= 0) {
            if (sig > nets[dup].signal)
                nets[dup].signal = sig;
            if (*f[0] == '*')
                nets[dup].inuse = 1;
            continue;
        }
        struct wifi *w = &nets[nnets++];
        snprintf(w->ssid, sizeof w->ssid, "%s", ssid);
        snprintf(w->security, sizeof w->security, "%s", strcmp(f[2], "--") ? f[2] : "");
        w->signal = sig;
        w->inuse = *f[0] == '*';
    }
    /* the strongest first */
    for (int i = 0; i < nnets; i++)
        for (int k2 = i + 1; k2 < nnets; k2++)
            if (nets[k2].signal > nets[i].signal) {
                struct wifi t = nets[i];
                nets[i] = nets[k2];
                nets[k2] = t;
            }
}

/* a connection as the form below describes it: what it needs besides a
 * password */
enum { NK_WIFI, NK_WIRED, NK_PPPOE };
enum { SEC_OPEN, SEC_PSK, SEC_SAE, SEC_EAP, SEC_WEP };
static const char *eaps[] = { "peap", "ttls", "pwd" };
static const char *phase2s[] = { "mschapv2", "pap", "gtc", "md5" };

struct netcfg {
    int kind, hidden;
    char ssid[96];
    int sec, eap, phase2;
    char pw[128];                                      /* Wi-Fi's password or key; 802.1X's; PPPoE's */
    char login[128], anon[128], ca[256], domain[128]; /* 802.1X; the login is PPPoE's too */
    char service[64];                                  /* PPPoE */
    int more, manual, keep;
    char addr[64], gw[64], dns[160], mac[40];
};
static struct netcfg last; /* the last form, filled in again for another try */

static void net_new(struct netcfg *c, int kind)
{
    memset(c, 0, sizeof *c);
    c->kind = kind;
    c->keep = 1;
    c->more = kind == NK_WIRED; /* (what that form is for) */
}

/* the security of a network, as `nmcli device wifi list` puts it */
static int sec_of(const char *s)
{
    if (!*s)
        return SEC_OPEN;
    if (strstr(s, "802.1X"))
        return SEC_EAP;
    if (strstr(s, "WEP"))
        return SEC_WEP;
    if (strstr(s, "WPA3") && !strstr(s, "WPA2") && !strstr(s, "WPA1"))
        return SEC_SAE;
    return SEC_PSK;
}

static int hex_len(const char *s)
{
    for (const char *p = s; *p; p++)
        if (!isxdigit((unsigned char)*p))
            return -1;
    return strlen(s);
}

/* an IPv4 address; with prefix_ok, a /prefix after it may follow */
static int valid_ip4(const char *s, int prefix_ok)
{
    char a[64];
    snprintf(a, sizeof a, "%s", s);
    char *slash = strchr(a, '/');
    if (slash) {
        char *e;
        long p = strtol(slash + 1, &e, 10);
        if (!prefix_ok || e == slash + 1 || *e || p < 0 || p > 32)
            return 0;
        *slash = 0;
    }
    struct in_addr in;
    return inet_pton(AF_INET, a, &in) == 1;
}

static int valid_dns(const char *s)
{
    char a[200];
    snprintf(a, sizeof a, "%s", s);
    int n = 0;
    for (char *t = strtok(a, " ,"); t; t = strtok(NULL, " ,"), n++)
        if (!valid_ip4(t, 0))
            return 0;
    return n > 0;
}

static int valid_mac(const char *s)
{
    if (!strcmp(s, "random") || !strcmp(s, "stable") || !strcmp(s, "permanent") || !strcmp(s, "preserve"))
        return 1;
    if (strlen(s) != 17)
        return 0;
    for (int i = 0; i < 17; i++)
        if (i % 3 == 2 ? s[i] != ':' && s[i] != '-' : !isxdigit((unsigned char)s[i]))
            return 0;
    return 1;
}

static const char *net_check(const struct netcfg *c)
{
    size_t n = strlen(c->pw);
    if (c->kind == NK_WIFI) {
        if (!*c->ssid)
            return T("Type the name of the network.", "Введите имя сети.");
        if ((c->sec == SEC_PSK || c->sec == SEC_SAE) && !(n >= 8 && n <= 63) && hex_len(c->pw) != 64)
            return T("A WPA password is 8 to 63 characters long (or 64 hexadecimal digits).",
                     "Пароль WPA — от 8 до 63 символов (или 64 шестнадцатеричные цифры).");
        if (c->sec == SEC_WEP && n != 5 && n != 13 && hex_len(c->pw) != 10 && hex_len(c->pw) != 26)
            return T("A WEP key is 5 or 13 characters, or 10 or 26 hexadecimal digits.",
                     "Ключ WEP — 5 или 13 символов либо 10 или 26 шестнадцатеричных цифр.");
        if (c->sec == SEC_EAP && !*c->login)
            return T("Type the login (identity) you were given for this network.",
                     "Введите логин (identity), выданный для этой сети.");
        if (c->sec == SEC_EAP && *c->ca && access(c->ca, R_OK) != 0)
            return T("There is no such file of a CA certificate.", "Файла сертификата CA с таким путём нет.");
    }
    if (c->kind == NK_PPPOE && !*c->login)
        return T("Type the login from your contract with the provider.", "Введите логин из договора с провайдером.");
    if (c->more) {
        if (c->manual && c->kind != NK_PPPOE && !valid_ip4(c->addr, 1))
            return T("The address: four numbers with dots, and the prefix after a slash, as 192.168.1.50/24.",
                     "Адрес: четыре числа через точку и префикс через косую черту, например 192.168.1.50/24.");
        if (c->manual && c->kind != NK_PPPOE && *c->gw && !valid_ip4(c->gw, 0))
            return T("The gateway: an address such as 192.168.1.1.", "Шлюз: адрес вида 192.168.1.1.");
        if (*c->dns && !valid_dns(c->dns))
            return T("DNS servers: addresses such as 1.1.1.1, separated by spaces.",
                     "DNS-серверы: адреса вида 1.1.1.1 через пробел.");
        if (*c->mac && !valid_mac(c->mac))
            return T("The MAC address: six pairs of hexadecimal digits, as 00:11:22:33:44:55 (or random).",
                     "MAC-адрес: шесть пар шестнадцатеричных цифр, например 00:11:22:33:44:55 (или random).");
    }
    return NULL;
}

/* what nmcli said, under what it means */
static void net_fail(const char *what, char *out)
{
    out[strcspn(out, "\n")] = 0;
    char text[2400];
    snprintf(text, sizeof text, "%s\n\n%s", what, !strncmp(out, "Error: ", 7) ? out + 7 : out);
    msg(T("Network", "Сеть"), text);
}

/* the connection made, as a NetworkManager profile (saved, so that the
 * installed system can keep it), and brought up; 1 if it is up */
static int net_apply(struct netcfg *c)
{
    char name[100], head[200];
    if (c->kind == NK_WIFI)
        snprintf(name, sizeof name, "%s", c->ssid);
    else
        snprintf(name, sizeof name, "%s", c->kind == NK_PPPOE ? "PPPoE" : T("Wired", "Проводное"));
    snprintf(head, sizeof head, T("Connecting to %s", "Подключение к %s"), name);
    busy(head);

    /* a profile of the same name (an earlier try) gives way */
    for (int i = 0; i < 4; i++) {
        char *del[] = { "nmcli", "connection", "delete", "id", name, NULL };
        if (run(del, NULL, 0) != 0)
            break;
    }

    char addr[80], dns[200], mac[40], *a[64];
    int n = 0;
#define A(...)                                                                  \
    do {                                                                        \
        char *v_[] = { __VA_ARGS__ };                                           \
        for (size_t i_ = 0; i_ < sizeof v_ / sizeof *v_ && n < 62; i_++)        \
            a[n++] = v_[i_];                                                    \
    } while (0)
    A("nmcli", "connection", "add", "con-name", name);
    if (c->kind == NK_WIFI) {
        A("type", "wifi", "ssid", c->ssid);
        if (c->hidden)
            A("wifi.hidden", "yes");
        switch (c->sec) {
        case SEC_PSK: A("wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", c->pw); break;
        case SEC_SAE: A("wifi-sec.key-mgmt", "sae", "wifi-sec.psk", c->pw); break;
        case SEC_WEP: A("wifi-sec.key-mgmt", "none", "wifi-sec.wep-key-type", "key", "wifi-sec.wep-key0", c->pw); break;
        case SEC_EAP:
            A("wifi-sec.key-mgmt", "wpa-eap", "802-1x.eap", (char *)eaps[c->eap], "802-1x.identity", c->login);
            if (*c->pw)
                A("802-1x.password", c->pw);
            if (c->eap != 2) { /* (PWD has no inner one) */
                A("802-1x.phase2-auth", (char *)phase2s[c->phase2]);
                if (*c->anon)
                    A("802-1x.anonymous-identity", c->anon);
            }
            if (*c->ca)
                A("802-1x.ca-cert", c->ca);
            if (*c->domain)
                A("802-1x.domain-suffix-match", c->domain);
            break;
        }
    } else if (c->kind == NK_WIRED) {
        A("type", "ethernet", "ifname", eth);
    } else {
        A("type", "pppoe", "pppoe.parent", eth, "pppoe.username", c->login);
        if (*c->pw)
            A("pppoe.password", c->pw);
        if (*c->service)
            A("pppoe.service", c->service);
    }
    if (c->more) {
        if (c->manual && c->kind != NK_PPPOE) {
            snprintf(addr, sizeof addr, strchr(c->addr, '/') ? "%s" : "%s/24", c->addr);
            A("ipv4.method", "manual", "ipv4.addresses", addr);
            if (*c->gw)
                A("ipv4.gateway", c->gw);
        }
        if (*c->dns) {
            snprintf(dns, sizeof dns, "%s", c->dns);
            for (char *p = dns; *p; p++)
                if (*p == ',')
                    *p = ' ';
            if (!c->manual || c->kind == NK_PPPOE)
                A("ipv4.ignore-auto-dns", "yes"); /* these, not the ones DHCP gives */
            A("ipv4.dns", dns);
        }
        if (*c->mac) {
            snprintf(mac, sizeof mac, "%s", c->mac);
            for (char *p = mac; *p; p++)
                if (*p == '-')
                    *p = ':';
            A(c->kind == NK_WIFI ? "wifi.cloned-mac-address" : "ethernet.cloned-mac-address", mac);
        }
    }
#undef A
    a[n] = NULL;

    char out[2048], uuid[40] = "";
    int r = run(a, out, sizeof out);
    /* "Connection 'NAME' (UUID) successfully added." */
    const char *e = strstr(out, ") successfully added");
    if (r == 0 && e) {
        const char *b = e;
        while (b > out && *b != '(')
            b--;
        if (*b == '(' && e - b < (int)sizeof uuid)
            snprintf(uuid, e - b, "%s", b + 1);
    }
    if (r != 0 || !*uuid) {
        net_fail(T("NetworkManager did not take these settings.", "NetworkManager не принял эти настройки."), out);
        return 0;
    }
    char *up[] = { "nmcli", "--wait", "45", "connection", "up", "uuid", uuid, NULL };
    if (run(up, out, sizeof out) != 0) {
        /* (not left to be tried again and again by itself) */
        char *del[] = { "nmcli", "connection", "delete", "uuid", uuid, NULL };
        run(del, NULL, 0);
        net_fail(c->kind == NK_WIFI ? T("Could not connect. Check the password and the other settings, and try again.",
                                        "Не удалось подключиться. Проверьте пароль и остальные настройки и попробуйте ещё раз.")
                                    : T("Could not connect. Check the cable and the settings, and try again.",
                                        "Не удалось подключиться. Проверьте кабель и настройки и попробуйте ещё раз."),
                 out);
        return 0;
    }
    memset(c->pw, 0, sizeof c->pw);
    if (c->keep && !net_only) {
        int i = 0;
        while (i < nkept && strcmp(kept[i].name, name))
            i++;
        if (i < 8) {
            snprintf(kept[i].uuid, sizeof kept[i].uuid, "%s", uuid);
            snprintf(kept[i].name, sizeof kept[i].name, "%s", name);
            if (i == nkept)
                nkept++;
        }
    }
    net_scan(0);
    return 1;
}

/* the form of a connection; 1 when it is up */
static int net_form(struct netcfg *c)
{
    const char *secs[] = {
        [SEC_OPEN] = T("None (an open network)", "Нет (открытая сеть)"),
        [SEC_PSK] = "WPA/WPA2 Personal",
        [SEC_SAE] = "WPA3 Personal",
        [SEC_EAP] = T("WPA Enterprise (802.1X, a login)", "WPA Enterprise (802.1X, логин)"),
        [SEC_WEP] = T("WEP (an old one)", "WEP (устаревшая)"),
    };
    const char *ipv4s[] = { T("Automatic (DHCP)", "Автоматически (DHCP)"), T("By hand", "Вручную") };
    static const char *eapn[] = { "PEAP", "TTLS", "PWD" };
    static const char *ph2n[] = { "MSCHAPv2", "PAP", "GTC", "MD5" };
    const char *optional = T("optional", "необязательно");
    enum { W_SSID, W_SEC, W_EAP, W_PH2, W_LOGIN, W_PW, W_ANON, W_CA, W_DOMAIN, P_SERVICE,
           N_MORE, N_IPV4, N_ADDR, N_GW, N_DNS, N_MAC, N_KEEP, NF };
    struct field f[NF] = {
        [W_SSID] = { .label = T("Network name", "Имя сети"), .buf = c->ssid, .size = sizeof c->ssid, .kind = F_TEXT },
        [W_SEC] = { .label = T("Security", "Защита"), .kind = F_CHOICE, .flag = &c->sec, .opts = secs, .nopts = 5 },
        [W_EAP] = { .label = T("Authentication", "Проверка подлинности"), .kind = F_CHOICE, .flag = &c->eap, .opts = eapn, .nopts = 3 },
        [W_PH2] = { .label = T("Inner authentication", "Внутренняя проверка"), .kind = F_CHOICE, .flag = &c->phase2, .opts = ph2n, .nopts = 4 },
        [W_LOGIN] = { .buf = c->login, .size = sizeof c->login, .kind = F_TEXT },
        [W_PW] = { .buf = c->pw, .size = sizeof c->pw, .kind = F_PASS },
        [W_ANON] = { .label = T("Anonymous identity", "Анонимная identity"), .buf = c->anon, .size = sizeof c->anon, .kind = F_TEXT, .hint = optional },
        [W_CA] = { .label = T("CA certificate", "Сертификат CA"), .buf = c->ca, .size = sizeof c->ca, .kind = F_TEXT,
                   .hint = T("optional: a file, /path/ca.pem", "необязательно: файл, /путь/ca.pem") },
        [W_DOMAIN] = { .label = T("Domain", "Домен"), .buf = c->domain, .size = sizeof c->domain, .kind = F_TEXT,
                       .hint = T("optional: example.org", "необязательно: example.org") },
        [P_SERVICE] = { .label = T("Service name", "Имя службы"), .buf = c->service, .size = sizeof c->service, .kind = F_TEXT, .hint = optional },
        [N_MORE] = { .label = T("Set the address, DNS or MAC by hand", "Задать адрес, DNS или MAC вручную"), .kind = F_CHECK, .flag = &c->more, .gap = 1 },
        [N_IPV4] = { .label = T("IPv4 address", "Адрес IPv4"), .kind = F_CHOICE, .flag = &c->manual, .opts = ipv4s, .nopts = 2 },
        [N_ADDR] = { .label = T("Address/prefix", "Адрес/префикс"), .buf = c->addr, .size = sizeof c->addr, .kind = F_TEXT,
                     .hint = T("e.g. 192.168.1.50/24", "например, 192.168.1.50/24") },
        [N_GW] = { .label = T("Gateway", "Шлюз"), .buf = c->gw, .size = sizeof c->gw, .kind = F_TEXT,
                   .hint = T("e.g. 192.168.1.1", "например, 192.168.1.1") },
        [N_DNS] = { .label = T("DNS servers", "DNS-серверы"), .buf = c->dns, .size = sizeof c->dns, .kind = F_TEXT },
        [N_MAC] = { .label = T("MAC address", "MAC-адрес"), .buf = c->mac, .size = sizeof c->mac, .kind = F_TEXT,
                    .hint = T("optional: 00:11:22:33:44:55, random", "необязательно: 00:11:22:33:44:55, random") },
        [N_KEEP] = { .label = T("Keep this connection in the installed system", "Сохранить подключение в установленной системе"),
                     .kind = F_CHECK, .flag = &c->keep, .gap = 1 },
    };
    char head[160];
    const char *intro;
    if (c->kind == NK_WIFI) {
        if (c->hidden)
            snprintf(head, sizeof head, "%s", T("A hidden Wi-Fi network", "Скрытая сеть Wi-Fi"));
        else
            snprintf(head, sizeof head, "Wi-Fi: %s", c->ssid);
        intro = T("Type the password and press Enter. Networks of companies and universities (802.1X) ask for a login as well; the address and DNS can be set by hand below.",
                  "Введите пароль и нажмите Enter. Сети компаний и университетов (802.1X) просят ещё и логин; адрес и DNS можно задать вручную ниже.");
    } else if (c->kind == NK_WIRED) {
        snprintf(head, sizeof head, T("Wired connection (%s)", "Проводное подключение (%s)"), eth);
        intro = T("For a network without DHCP, or a provider that expects a fixed address or a particular MAC address. Enter connects.",
                  "Для сети без DHCP или провайдера, который ждёт постоянный адрес или определённый MAC-адрес. Enter — подключиться.");
    } else {
        snprintf(head, sizeof head, T("DSL and PPPoE (over %s)", "DSL и PPPoE (через %s)"), eth);
        intro = T("Many home connections work so: a cable from the provider, or a DSL modem in bridge mode. The login and the password are in the contract.",
                  "Так работают многие домашние подключения: кабель провайдера или DSL-модем в режиме моста. Логин и пароль — в договоре.");
    }
    int cur = c->kind == NK_WIRED ? N_IPV4 : c->kind == NK_PPPOE ? W_LOGIN
            : c->hidden ? W_SSID : c->sec == SEC_EAP ? W_LOGIN : c->sec == SEC_OPEN ? N_MORE : W_PW;
    const char *err = NULL;
    for (;;) {
        int wifi = c->kind == NK_WIFI, ppp = c->kind == NK_PPPOE, eap = wifi && c->sec == SEC_EAP;
        f[W_SSID].hidden = !(wifi && c->hidden);
        f[W_SEC].hidden = !wifi;
        f[W_EAP].hidden = f[W_CA].hidden = f[W_DOMAIN].hidden = !eap;
        f[W_PH2].hidden = f[W_ANON].hidden = !eap || c->eap == 2;
        f[W_LOGIN].hidden = !(eap || ppp);
        f[W_PW].hidden = !(ppp || (wifi && c->sec != SEC_OPEN));
        f[P_SERVICE].hidden = !ppp;
        f[N_MORE].hidden = c->kind == NK_WIRED;
        f[N_IPV4].hidden = !c->more || ppp;
        f[N_ADDR].hidden = f[N_GW].hidden = !c->more || ppp || !c->manual;
        f[N_DNS].hidden = f[N_MAC].hidden = !c->more;
        f[N_KEEP].hidden = net_only;
        f[W_LOGIN].label = ppp ? T("Login", "Логин") : T("Login (identity)", "Логин (identity)");
        f[W_PW].label = wifi && c->sec == SEC_WEP ? T("Key", "Ключ") : T("Password", "Пароль");
        f[N_DNS].hint = c->manual && !ppp ? T("e.g. 1.1.1.1 8.8.8.8", "например, 1.1.1.1 8.8.8.8")
                                          : T("optional: 1.1.1.1 8.8.8.8", "необязательно: 1.1.1.1 8.8.8.8");
        int r = form_round(head, intro, f, NF, &cur, err,
                           T("Tab ↑↓: field   ←→ Space: change   F2: passwords   Enter: connect   Esc: back",
                             "Tab ↑↓: поле   ←→ Пробел: выбор   F2: пароли   Enter: подключить   Esc: назад"));
        if (r == BACK)
            return 0;
        if (r == STAY) {
            err = NULL;
            continue;
        }
        err = net_check(c);
        if (!err && net_apply(c))
            return 1;
    }
}

enum { K_GO, K_NET, K_HIDDEN, K_WIRED, K_PPPOE, K_RESCAN, K_SKIP };
static int net_kind[72], net_idx[72];

static const char *net_desc(int i)
{
    static char d[300];
    switch (net_kind[i]) {
    case K_NET: {
        const struct wifi *w = &nets[net_idx[i]];
        snprintf(d, sizeof d, T("%s, the signal %d%%. Enter: the password (or a login), and the address by hand if it is needed.",
                                "%s, сигнал %d%%. Enter: пароль (или логин), при необходимости адрес вручную."),
                 *w->security ? w->security : T("Open", "Открытая"), w->signal);
        return d;
    }
    case K_HIDDEN:
        return T("A network that does not show its name: type the name, choose the security, type the password.",
                 "Сеть, которая не показывает имя: введите имя, выберите защиту, введите пароль.");
    case K_WIRED:
        return T("For a cable without DHCP: a fixed address, the gateway and DNS servers; or the MAC address the provider expects.",
                 "Для кабеля без DHCP: постоянный адрес, шлюз и DNS-серверы; или MAC-адрес, которого ждёт провайдер.");
    case K_PPPOE:
        return T("A connection with a login and a password from the provider (PPPoE): its cable, or a DSL modem in bridge mode.",
                 "Подключение по логину и паролю от провайдера (PPPoE): его кабель или DSL-модем в режиме моста.");
    }
    return net_line;
}

static int step_network(void)
{
    if (!have_nmcli()) {
        msg(T("Network", "Сеть"), T("NetworkManager (nmcli) is not available here.", "NetworkManager (nmcli) здесь недоступен."));
        return NEXT;
    }
    busy(T("Looking for networks", "Поиск сетей"));
    net_scan(0);
    int sel = 0;
    for (;;) {
        static char labels[72][160];
        static const char *items[72];
        int n = 0;
        if (S.online || net_only) {
            snprintf(labels[n], sizeof labels[n], "%s", S.online ? T("Continue: you are online", "Далее: интернет есть")
                                                                 : T("Close", "Закрыть"));
            net_kind[n++] = K_GO;
        }
        for (int i = 0; i < nnets && n < 64; i++) {
            int bars = nets[i].signal >= 75 ? 4 : nets[i].signal >= 50 ? 3 : nets[i].signal >= 25 ? 2 : 1;
            const char *b = utf8 ? (bars == 4 ? "▂▄▆█" : bars == 3 ? "▂▄▆ " : bars == 2 ? "▂▄  " : "▂   ")
                                 : (bars == 4 ? "####" : bars == 3 ? "### " : bars == 2 ? "##  " : "#   ");
            snprintf(labels[n], sizeof labels[n], "%-28.28s %s  %s", nets[i].ssid, b,
                     nets[i].inuse ? T("connected", "подключено")
                     : sec_of(nets[i].security) == SEC_EAP ? T("login", "логин")
                     : *nets[i].security ? T("password", "пароль") : T("open", "открытая"));
            net_kind[n] = K_NET;
            net_idx[n++] = i;
        }
        if (wifi_dev) {
            snprintf(labels[n], sizeof labels[n], "%s", T("Another network (hidden)...", "Другая сеть (скрытая)..."));
            net_kind[n++] = K_HIDDEN;
        }
        if (*eth) {
            snprintf(labels[n], sizeof labels[n], "%s", T("Cable: the address, DNS, MAC by hand...", "Кабель: адрес, DNS, MAC вручную..."));
            net_kind[n++] = K_WIRED;
            snprintf(labels[n], sizeof labels[n], "%s", T("DSL / PPPoE: a login from the provider...", "DSL / PPPoE: логин от провайдера..."));
            net_kind[n++] = K_PPPOE;
        }
        snprintf(labels[n], sizeof labels[n], "%s", T("Search again", "Искать снова"));
        net_kind[n++] = K_RESCAN;
        if (!S.online && !net_only) {
            snprintf(labels[n], sizeof labels[n], "%s", T("Continue without the internet", "Продолжить без интернета"));
            net_kind[n++] = K_SKIP;
        }
        for (int i = 0; i < n; i++)
            items[i] = labels[i];
        if (sel >= n)
            sel = 0;

        char intro[400];
        const char *air = NULL;
        for (int i = 0; i < nnets; i++)
            if (nets[i].inuse)
                air = nets[i].ssid;
        if (S.online && *wired)
            snprintf(intro, sizeof intro, T("Connected to the internet by cable (%s).", "Подключено к интернету по кабелю (%s)."), wired);
        else if (S.online && air)
            snprintf(intro, sizeof intro, T("Connected to the internet over Wi-Fi: %s.", "Подключено к интернету по Wi-Fi: %s."), air);
        else if (S.online)
            snprintf(intro, sizeof intro, "%s", T("Connected to the internet.", "Подключено к интернету."));
        else
            snprintf(intro, sizeof intro, "%s", wifi_dev
                         ? T("Not connected. Plug in a cable, or choose a Wi-Fi network below.",
                             "Нет подключения. Подключите кабель или выберите сеть Wi-Fi ниже.")
                         : T("Not connected, and no Wi-Fi adapter was found. Plug in a cable and choose «Search again».",
                             "Нет подключения, и адаптер Wi-Fi не найден. Подключите кабель и выберите «Искать снова»."));
        snprintf(net_line, sizeof net_line, "%s",
                 S.online ? T("Everything is ready: go on.", "Всё готово, можно идти дальше.")
                          : T("Without the internet only what is on this image can be installed: a console system or Parallax.",
                              "Без интернета ставится только то, что есть на образе: консольная система или Parallax."));
        struct menu m = {
            .title = T("Network", "Сеть"), .intro = intro, .items = items, .n = n, .desc = net_desc,
        };
        int r = run_menu(&m, &sel);
        if (r != NEXT)
            return r == BACK && net_only ? (ask_quit(), STAY) : r;
        struct netcfg c;
        switch (net_kind[sel]) {
        case K_GO:
            if (net_only)
                quit_installer();
            return NEXT;
        case K_SKIP:
            return NEXT;
        case K_RESCAN:
            busy(T("Looking for networks", "Поиск сетей"));
            net_scan(1);
            continue;
        case K_NET: {
            const struct wifi *w = &nets[net_idx[sel]];
            if (last.kind == NK_WIFI && !last.hidden && !strcmp(last.ssid, w->ssid)) {
                c = last;
            } else {
                net_new(&c, NK_WIFI);
                snprintf(c.ssid, sizeof c.ssid, "%s", w->ssid);
                c.sec = sec_of(w->security);
            }
            break;
        }
        case K_HIDDEN:
            if (last.kind == NK_WIFI && last.hidden) {
                c = last;
            } else {
                net_new(&c, NK_WIFI);
                c.hidden = 1;
                c.sec = SEC_PSK;
            }
            break;
        default: { /* K_WIRED, K_PPPOE */
            int kind = net_kind[sel] == K_WIRED ? NK_WIRED : NK_PPPOE;
            if (last.kind == kind)
                c = last;
            else
                net_new(&c, kind);
            break;
        }
        }
        int ok = net_form(&c);
        last = c;
        if (ok && S.online)
            sel = 0;
    }
}

/* the files of the connections the installed system keeps, a line each */
static void kept_files(char *out, size_t size)
{
    out[0] = 0;
    if (!nkept)
        return;
    static char list[16384];
    char *a[] = { "nmcli", "-t", "-f", "UUID,FILENAME", "connection", "show", NULL };
    if (run(a, list, sizeof list) != 0)
        return;
    for (char *l = strtok(list, "\n"); l; l = strtok(NULL, "\n")) {
        char *colon = strchr(l, ':');
        if (!colon)
            continue;
        *colon = 0;
        for (int i = 0; i < nkept; i++) {
            if (strcmp(l, kept[i].uuid))
                continue;
            /* (terse output escapes ':' and '\' in the name of the file) */
            char file[512];
            int n = 0;
            for (char *p = colon + 1; *p && n < 511; p++) {
                if (*p == '\\' && p[1])
                    p++;
                file[n++] = *p;
            }
            file[n] = 0;
            /* (one kept only in memory, under /run, is not one to copy) */
            if (!strncmp(file, "/etc/", 5) && strlen(out) + n + 2 < size)
                strcat(strcat(out, file), "\n");
        }
    }
}

/* --- 4. time zone ----------------------------------------------------------- */

static char *zones[700];
static int nzones;

static int cmpstr(const void *a, const void *b)
{
    return strcmp(*(char *const *)a, *(char *const *)b);
}

static void load_zones(void)
{
    if (nzones)
        return;
    const char *dir = getenv("TZDIR") ? getenv("TZDIR") : "/etc/zoneinfo";
    char path[256];
    snprintf(path, sizeof path, "%s/zone1970.tab", dir);
    FILE *f = fopen(path, "r");
    if (f) {
        char line[512];
        while (nzones < 690 && fgets(line, sizeof line, f)) {
            if (*line == '#')
                continue;
            char *t1 = strchr(line, '\t'), *t2 = t1 ? strchr(t1 + 1, '\t') : NULL;
            if (!t2)
                continue;
            char *z = t2 + 1;
            z[strcspn(z, "\t\n")] = 0;
            zones[nzones++] = strdup(z);
        }
        fclose(f);
    }
    qsort(zones, nzones, sizeof *zones, cmpstr);
    zones[nzones++] = strdup("UTC");
}

static const char *tz_desc(int i)
{
    static char d[128];
    setenv("TZ", zones[i], 1);
    tzset();
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char hm[16];
    strftime(hm, sizeof hm, "%H:%M", &tm);
    snprintf(d, sizeof d, T("The time there now: %s", "Сейчас там: %s"), hm);
    unsetenv("TZ");
    tzset();
    return d;
}

static int step_tz(void)
{
    load_zones();
    int sel = 0;
    for (int i = 0; i < nzones; i++)
        if (!strcmp(zones[i], S.tz))
            sel = i;
    struct menu m = {
        .title = T("Time zone", "Часовой пояс"),
        .intro = T("Where the computer is. Type a city to find it: \"berlin\", \"moscow\", \"new_york\".",
                   "Где находится компьютер. Начните набирать город: «moscow», «berlin», «new_york»."),
        .items = (const char **)zones, .n = nzones, .desc = tz_desc, .search = 1,
    };
    int r = run_menu(&m, &sel);
    if (r == NEXT)
        snprintf(S.tz, sizeof S.tz, "%s", zones[sel]);
    return r;
}

/* --- 5. language, 6. keyboard ---------------------------------------------- */

static int step_locale(void)
{
    static char labels[NLOCALES][96];
    static const char *items[NLOCALES];
    for (int i = 0; i < NLOCALES; i++) {
        padded(labels[i], sizeof labels[i], locales[i].name, 27, locales[i].id);
        items[i] = labels[i];
    }
    struct menu m = {
        .title = T("Language of the system", "Язык системы"),
        .intro = T("The language of programs, dates and numbers in the installed system.",
                   "Язык программ, дат и чисел в установленной системе."),
        .items = items, .n = NLOCALES, .search = 1,
    };
    return run_menu(&m, &S.locale);
}

static const char *kb_desc(int i)
{
    static char d[300];
    if (*keyboards[i].ru)
        snprintf(d, sizeof d, T("Together with English; Alt+Shift switches between the two. In the console: the \"%s\" keymap.",
                                "Вместе с английской; Alt+Shift переключает между ними. В консоли: раскладка «%s»."),
                 keyboards[i].en);
    else
        snprintf(d, sizeof d, T("In the console: the \"%s\" keymap.", "В консоли: раскладка «%s»."), keyboards[i].en);
    return d;
}

static int step_keyboard(void)
{
    static char labels[NKEYBOARDS][96];
    static const char *items[NKEYBOARDS];
    for (int i = 0; i < NKEYBOARDS; i++) {
        padded(labels[i], sizeof labels[i], keyboards[i].name, 27, keyboards[i].id);
        items[i] = labels[i];
    }
    struct menu m = {
        .title = T("Keyboard", "Клавиатура"),
        .intro = T("The keyboard layout of the installed system.", "Раскладка клавиатуры в установленной системе."),
        .items = items, .n = NKEYBOARDS, .desc = kb_desc, .search = 1,
    };
    return run_menu(&m, &S.kb);
}

/* --- 7. user ----------------------------------------------------------------- */

/* a login out of a full name: Latin letters, Cyrillic transliterated */
static void login_from(const char *name, char *out, int size)
{
    static const char *cyr[][2] = {
        {"а","a"},{"б","b"},{"в","v"},{"г","g"},{"д","d"},{"е","e"},{"ё","e"},{"ж","zh"},{"з","z"},
        {"и","i"},{"й","y"},{"к","k"},{"л","l"},{"м","m"},{"н","n"},{"о","o"},{"п","p"},{"р","r"},
        {"с","s"},{"т","t"},{"у","u"},{"ф","f"},{"х","h"},{"ц","ts"},{"ч","ch"},{"ш","sh"},{"щ","sch"},
        {"ы","y"},{"э","e"},{"ю","yu"},{"я","ya"},{"і","i"},{"ї","i"},{"є","e"},{"ў","u"},
        {"А","a"},{"Б","b"},{"В","v"},{"Г","g"},{"Д","d"},{"Е","e"},{"Ё","e"},{"Ж","zh"},{"З","z"},
        {"И","i"},{"Й","y"},{"К","k"},{"Л","l"},{"М","m"},{"Н","n"},{"О","o"},{"П","p"},{"Р","r"},
        {"С","s"},{"Т","t"},{"У","u"},{"Ф","f"},{"Х","h"},{"Ц","ts"},{"Ч","ch"},{"Ш","sh"},{"Щ","sch"},
        {"Ы","y"},{"Э","e"},{"Ю","yu"},{"Я","ya"},
    };
    int n = 0;
    for (const char *p = name; *p && *p != ' ' && n < size - 4;) {
        if (isalnum((unsigned char)*p)) {
            out[n++] = tolower((unsigned char)*p++);
            continue;
        }
        int hit = 0;
        for (size_t i = 0; i < sizeof cyr / sizeof *cyr; i++) {
            size_t l = strlen(cyr[i][0]);
            if (!strncmp(p, cyr[i][0], l)) {
                for (const char *t = cyr[i][1]; *t && n < size - 1; t++)
                    out[n++] = *t;
                p += l;
                hit = 1;
                break;
            }
        }
        if (!hit)
            p++;
    }
    out[n] = 0;
    if (n && isdigit((unsigned char)out[0]))
        memmove(out + 1, out, n + 1), out[0] = 'u';
}

static int valid_login(const char *u)
{
    if (!*u || strlen(u) > 31 || !(islower((unsigned char)*u) || *u == '_'))
        return 0;
    for (const char *p = u; *p; p++)
        if (!(islower((unsigned char)*p) || isdigit((unsigned char)*p) || *p == '_' || *p == '-'))
            return 0;
    static const char *taken[] = { "root", "nixith", "nobody", "daemon", "bin", "messagebus", "sshd", "nixbld", NULL };
    for (int i = 0; taken[i]; i++)
        if (!strcmp(u, taken[i]))
            return 0;
    return 1;
}

static int valid_host(const char *h)
{
    if (!*h || strlen(h) > 63 || *h == '-')
        return 0;
    for (const char *p = h; *p; p++)
        if (!(islower((unsigned char)*p) || isdigit((unsigned char)*p) || *p == '-'))
            return 0;
    return 1;
}

static const char *user_check(void)
{
    if (!*S.fullname)
        return T("Type your name.", "Введите имя.");
    if (!valid_login(S.user))
        return T("The login: small Latin letters, digits, - and _, starting with a letter (and not root).",
                 "Логин: маленькие латинские буквы, цифры, - и _, начиная с буквы (и не root).");
    if (!*S.pw1)
        return T("Choose a password.", "Придумайте пароль.");
    if (strcmp(S.pw1, S.pw2))
        return T("The passwords do not match.", "Пароли не совпадают.");
    if (!S.rootsame) {
        if (!*S.rpw1)
            return T("Choose a password for root.", "Придумайте пароль для root.");
        if (strcmp(S.rpw1, S.rpw2))
            return T("The root passwords do not match.", "Пароли root не совпадают.");
    }
    if (!valid_host(S.host))
        return T("The computer's name: small Latin letters, digits and -.",
                 "Имя компьютера: маленькие латинские буквы, цифры и -.");
    return NULL;
}

static int step_user(void)
{
    struct field f[] = {
        { T("Your name", "Ваше имя"), S.fullname, sizeof S.fullname, F_TEXT, NULL, 0 },
        { T("Login", "Логин"), S.user, sizeof S.user, F_TEXT, NULL, 0 },
        { T("Password", "Пароль"), S.pw1, sizeof S.pw1, F_PASS, NULL, 0 },
        { T("Repeat it", "Ещё раз"), S.pw2, sizeof S.pw2, F_PASS, NULL, 0 },
        { T("The same password for root", "Тот же пароль для root"), NULL, 0, F_CHECK, &S.rootsame, 0 },
        { T("Root's password", "Пароль root"), S.rpw1, sizeof S.rpw1, F_PASS, NULL, 0 },
        { T("Repeat it", "Ещё раз"), S.rpw2, sizeof S.rpw2, F_PASS, NULL, 0 },
        { T("Computer's name", "Имя компьютера"), S.host, sizeof S.host, F_TEXT, NULL, 0 },
        { T("Log in automatically", "Входить автоматически"), NULL, 0, F_CHECK, &S.autologin, 0 },
    };
    int nf = sizeof f / sizeof *f, cur = 0;
    const char *err = NULL;
    for (;;) {
        f[5].hidden = f[6].hidden = S.rootsame;
        if (f[cur].hidden)
            cur = cur < 5 ? 4 : 7;
        if (too_small()) {
            wint_t c;
            key(&c);
            continue;
        }
        chrome(T("↑↓ Tab: field   Space: tick   Enter: next   Esc: back   F10: quit",
                 "↑↓ Tab: поле   Пробел: галочка   Enter: далее   Esc: назад   F10: выход"));
        int y = CY;
        title(&y, T("Who will use this computer", "Кто будет пользоваться компьютером"));
        int lw = 0;
        for (int i = 0; i < nf; i++)
            if (f[i].kind != F_CHECK && dwidth(f[i].label) > lw)
                lw = dwidth(f[i].label);
        lw += 2;
        int iw = CW - lw - 2 < 40 ? CW - lw - 2 : 40;
        int cy = 0, cx = 0;
        for (int i = 0; i < nf; i++) {
            if (f[i].hidden)
                continue;
            if (i == 2 || i == 7)
                y++;
            if (f[i].kind == F_CHECK) {
                if (i == cur)
                    attron(A_BOLD);
                put(y, CX, *f[i].flag ? "[x]" : "[ ]", 3);
                put(y, CX + 4, f[i].label, CW - 4);
                if (i == cur) {
                    attroff(A_BOLD);
                    cy = y;
                    cx = CX + 1;
                }
            } else {
                if (i == cur)
                    attron(A_BOLD);
                put(y, CX, f[i].label, lw);
                if (i == cur)
                    attroff(A_BOLD);
                char shown[256];
                if (f[i].kind == F_PASS) {
                    int n = dwidth(f[i].buf), k = 0;
                    for (; k < n && k < 250; k++)
                        shown[k] = '*';
                    shown[k] = 0;
                } else {
                    snprintf(shown, sizeof shown, "%s", f[i].buf);
                }
                attron(i == cur ? COLOR_PAIR(C_SEL) : COLOR_PAIR(C_DIM) | A_BOLD);
                if (i == cur)
                    mvhline(y, CX + lw, ' ', iw);
                else
                    mvhline(y, CX + lw + 1, '_', iw - 1);
                attroff(i == cur ? COLOR_PAIR(C_SEL) : COLOR_PAIR(C_DIM) | A_BOLD);
                if (i == cur)
                    attron(COLOR_PAIR(C_SEL));
                put(y, CX + lw + 1, shown, iw - 2);
                if (i == cur) {
                    attroff(COLOR_PAIR(C_SEL));
                    cy = y;
                    cx = CX + lw + 1 + (dwidth(shown) < iw - 2 ? dwidth(shown) : iw - 2);
                }
            }
            y++;
        }
        y++;
        attron(COLOR_PAIR(C_DIM) | A_BOLD);
        y = wrap(y, CX, CW, CY + CH - 2, T("The login is made from your name; it can be changed. Root is the administrator; with sudo your user can do what root does.",
                                           "Логин составляется из имени; его можно поменять. Root — администратор; через sudo ваш пользователь может всё, что может root."));
        attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        if (err) {
            attron(COLOR_PAIR(C_ERR) | A_BOLD);
            wrap(y + 1, CX, CW, CY + CH, err);
            attroff(COLOR_PAIR(C_ERR) | A_BOLD);
        }
        move(cy, cx);
        curs_set(f[cur].kind == F_CHECK ? 0 : 1);
        present();
        wint_t c;
        int r = key(&c);
        curs_set(0);
        int move_dir = 0;
        if (r == KEY_CODE_YES) {
            if (c == KEY_UP || c == KEY_BTAB)
                move_dir = -1;
            else if (c == KEY_DOWN)
                move_dir = 1;
            else if (c == KEY_ENTER)
                c = '\n', r = OK;
            else if (c == KEY_F(10))
                ask_quit();
            else if (c == KEY_BACKSPACE && f[cur].kind != F_CHECK)
                edit_utf8(f[cur].buf, f[cur].size, c);
        }
        if (r == OK) {
            if (c == '\t')
                move_dir = 1;
            else if (c == 27)
                return BACK;
            else if (c == '\n' || c == '\r') {
                int last = nf - 1;
                if (cur == last) {
                    err = user_check();
                    if (!err)
                        return NEXT;
                } else {
                    move_dir = 1;
                }
            } else if (f[cur].kind == F_CHECK) {
                if (c == ' ')
                    *f[cur].flag = !*f[cur].flag;
            } else if (c == 127 || c == 8 || c >= 32) {
                edit_utf8(f[cur].buf, f[cur].size, c);
                if (cur == 0 && !S.user_edited)
                    login_from(S.fullname, S.user, sizeof S.user);
                if (cur == 1)
                    S.user_edited = 1;
                err = NULL;
            }
        }
        if (move_dir) {
            do
                cur = (cur + move_dir + nf) % nf;
            while (f[cur].hidden);
        }
    }
}

/* --- 8.-12. desktop, login, shell, boot loader, software -------------------- */

static const struct opt *desc_table;

static const char *opt_desc(int i)
{
    return ru ? desc_table[i].ru : desc_table[i].en;
}

/* the screenshot of a choice, as Calamares had them (default.nix makes them
 * of ../../branding/screenshots) */
static const char *opt_pic(int i)
{
    static char name[48];
    const struct opt *o = &desc_table[i];
    if (desc_table == desktops)
        snprintf(name, sizeof name, "%s", !strcmp(o->id, "none") ? "nodesktop" : !strcmp(o->id, "plasma") ? "plasma6" : o->id);
    else if (desc_table == dms)
        snprintf(name, sizeof name, "dm-%s", o->id);
    else if (desc_table == shells)
        snprintf(name, sizeof name, "shell-%s", o->id);
    else if (desc_table == loaders || !strcmp(o->id, "grub"))
        snprintf(name, sizeof name, "boot-%s", o->id);
    else
        return NULL;
    return name;
}

static int choose(const char *head, const char *intro, const struct opt *o, int n, int *sel)
{
    static const char *items[16];
    for (int i = 0; i < n; i++)
        items[i] = optname(&o[i]);
    desc_table = o;
    struct menu m = { .title = head, .intro = intro, .items = items, .n = n, .desc = opt_desc, .pic = opt_pic };
    return run_menu(&m, sel);
}

static int step_desktop(void)
{
    return choose(T("Desktop", "Рабочий стол"),
                  T("What you will see after logging in. Parallax is on this image; the others are downloaded during the installation.",
                    "Что вы увидите после входа. Parallax есть на этом образе, остальные скачиваются во время установки."),
                  desktops, NDESKTOPS, &S.desktop);
}

static int step_login(void)
{
    if (!strcmp(desktops[S.desktop].id, "none")) {
        S.dm = NDMS - 1;
        return NEXT;
    }
    return choose(T("Login", "Вход"),
                  T("How you log in to the desktop. (GDM and SDDM are not offered: they need systemd.)",
                    "Как вы будете входить в систему. (GDM и SDDM не предлагаются: им нужен systemd.)"),
                  dms, NDMS, &S.dm);
}

static int step_shell(void)
{
    return choose(T("Shell", "Оболочка"), T("The command line of your user.", "Командная строка вашего пользователя."),
                  shells, NSHELLS, &S.shell);
}

static int step_loader(void)
{
    if (!S.efi) {
        static const struct opt grub[] = { { "grub", "GRUB",
            "This computer started the installer in BIOS mode, and on BIOS NixithOS uses GRUB.",
            "Компьютер запустил установщик в режиме BIOS, а на BIOS NixithOS ставит GRUB." } };
        int one = 0;
        return choose(T("Boot loader", "Загрузчик"), NULL, grub, 1, &one);
    }
    return choose(T("Boot loader", "Загрузчик"),
                  T("What starts the system when the computer is turned on.",
                    "Что запускает систему при включении компьютера."),
                  loaders, NLOADERS, &S.loader);
}

static int step_unfree(void)
{
    static const struct opt sw[] = {
        { "free", NULL,
          "Only free software. Some hardware may then not work, or not work as well: NVIDIA graphics, some Wi-Fi chips.",
          "Только свободные программы. Тогда часть железа может не работать или работать хуже: видеокарты NVIDIA, некоторые чипы Wi-Fi." },
        { "unfree", NULL,
          "Allow unfree software: programs whose licences do not let you study or share them (NVIDIA drivers, Steam, Discord, firmware).",
          "Разрешить несвободные программы: те, чьи лицензии не дают изучать или распространять их (драйверы NVIDIA, Steam, Discord, прошивки)." },
    };
    static const char *items[2];
    items[0] = T("Only free software", "Только свободные программы");
    items[1] = T("Allow unfree software", "Разрешить несвободные программы");
    desc_table = sw;
    struct menu m = {
        .title = T("Software", "Программы"),
        .intro = T("NixithOS, like NixOS, is open source, but some programs and drivers are not.",
                   "NixithOS, как и NixOS, открыта, но некоторые программы и драйверы — нет."),
        .items = items, .n = 2, .desc = opt_desc,
    };
    return run_menu(&m, &S.unfree);
}

/* --- 13. disk ---------------------------------------------------------------- */

struct disk {
    char dev[64], label[200], desc[200];
};
static struct disk disks[32];
static int ndisks;

/* the value of KEY="value" in a line of `lsblk -P` */
static void pval(const char *line, const char *key, char *out, int size)
{
    char k[32];
    snprintf(k, sizeof k, "%s=\"", key);
    const char *p = strstr(line, k);
    out[0] = 0;
    if (!p)
        return;
    p += strlen(k);
    int n = 0;
    while (*p && *p != '"' && n < size - 1)
        out[n++] = *p++;
    out[n] = 0;
}

static void load_disks(void)
{
    char out[16384], live[64] = "";
    /* the disk this image runs from is not offered */
    char *fm[] = { "findmnt", "-nvo", "SOURCE", "/iso", NULL };
    if (run(fm, out, sizeof out) == 0 && *out) {
        out[strcspn(out, "\n")] = 0;
        char *pk[] = { "lsblk", "-ndo", "PKNAME", out, NULL };
        char dev[64];
        snprintf(dev, sizeof dev, "%s", out);
        if (run(pk, out, sizeof out) == 0 && *out && *out != '\n') {
            out[strcspn(out, "\n")] = 0;
            snprintf(live, sizeof live, "/dev/%s", out);
        } else {
            snprintf(live, sizeof live, "%s", dev);
        }
    }
    char *ls[] = { "lsblk", "-dnpbP", "-o", "NAME,SIZE,TYPE,RO,MODEL,TRAN", NULL };
    ndisks = 0;
    if (run(ls, out, sizeof out) != 0)
        return;
    for (char *l = strtok(out, "\n"); l && ndisks < 32; l = strtok(NULL, "\n")) {
        char name[64], size[32], type[16], ro[8], model[96], tran[16];
        pval(l, "NAME", name, sizeof name);
        pval(l, "SIZE", size, sizeof size);
        pval(l, "TYPE", type, sizeof type);
        pval(l, "RO", ro, sizeof ro);
        pval(l, "MODEL", model, sizeof model);
        pval(l, "TRAN", tran, sizeof tran);
        if (strcmp(type, "disk") || !strcmp(ro, "1") || !strcmp(name, live) || strstr(name, "zram"))
            continue;
        double gib = atof(size) / (1024.0 * 1024 * 1024);
        if (gib < 1)
            continue;
        struct disk *d = &disks[ndisks++];
        snprintf(d->dev, sizeof d->dev, "%s", name);
        char sz[32];
        if (gib >= 1024)
            snprintf(sz, sizeof sz, "%.1f TiB", gib / 1024);
        else
            snprintf(sz, sizeof sz, "%.1f GiB", gib);
        snprintf(d->label, sizeof d->label, "%-14s %10s   %s%s%s%s", name + 5, sz, *model ? model : T("disk", "диск"),
                 *tran ? " (" : "", tran, *tran ? ")" : "");
        snprintf(d->desc, sizeof d->desc, "%s (%s, %s)", name, *model ? model : T("disk", "диск"), sz);
    }
}

static const char *disk_desc(int i)
{
    if (i < ndisks)
        return T("The whole disk is erased: a boot partition and one partition for the system.",
                 "Диск стирается целиком: загрузочный раздел и один раздел под систему.");
    return T("Partition the disk yourself and mount the system on /mnt (and the EFI partition on /mnt/boot); a shell is opened for that.",
             "Разметить диск самому и смонтировать систему в /mnt (а EFI-раздел в /mnt/boot); для этого откроется консоль.");
}

static int step_disk(void)
{
    busy(T("Looking for disks", "Поиск дисков"));
    load_disks();
    static const char *items[34];
    for (int i = 0; i < ndisks; i++)
        items[i] = disks[i].label;
    items[ndisks] = T("Manual partitioning...", "Разметить вручную...");
    int n = ndisks + 1;
    int sel = 0;
    for (int i = 0; i < ndisks; i++)
        if (!strcmp(disks[i].dev, S.disk))
            sel = i;
    if (S.manual)
        sel = ndisks;
    for (;;) {
        struct menu m = {
            .title = T("Disk", "Диск"),
            .intro = ndisks ? T("Where to install NixithOS.", "Куда установить NixithOS.")
                            : T("No disk was found. Partition by hand, or check the cables and come back.",
                                "Дисков не найдено. Разметьте вручную или проверьте подключение и вернитесь."),
            .items = items, .n = n, .desc = disk_desc,
        };
        int r = run_menu(&m, &sel);
        if (r != NEXT)
            return r;
        if (sel < ndisks) {
            S.manual = 0;
            snprintf(S.disk, sizeof S.disk, "%s", disks[sel].dev);
            snprintf(S.disk_desc, sizeof S.disk_desc, "%s", disks[sel].desc);
            static const struct opt fss[] = {
                { "ext4", "ext4", "The usual, proven file system of Linux.", "Привычная проверенная файловая система Linux." },
                { "btrfs", "btrfs", "Compression, snapshots and checksums of the data.", "Сжатие, снимки и контрольные суммы данных." },
            };
            r = choose(T("File system", "Файловая система"), NULL, fss, 2, &S.fs);
            if (r == NEXT)
                return NEXT;
            continue;
        }
        /* by hand */
        static const char *mi[3];
        mi[0] = T("Open a shell to partition and mount", "Открыть консоль для разметки");
        mi[1] = T("Done: the system is mounted on /mnt", "Готово: система смонтирована в /mnt");
        int ms = 0;
        for (;;) {
            struct menu mm = {
                .title = T("Manual partitioning", "Ручная разметка"),
                .intro = S.efi ? T("Make the partitions (cfdisk, parted), create the file systems, mount the system's root on /mnt and the EFI system partition on /mnt/boot.",
                                   "Создайте разделы (cfdisk, parted) и файловые системы, смонтируйте корень системы в /mnt, а EFI-раздел — в /mnt/boot.")
                               : T("Make the partitions (cfdisk, parted) and file systems and mount the system's root on /mnt. GRUB is installed on the disk chosen next.",
                                   "Создайте разделы (cfdisk, parted) и файловые системы и смонтируйте корень системы в /mnt. GRUB ставится на диск, выбранный следом."),
                .items = mi, .n = 2,
            };
            r = run_menu(&mm, &ms);
            if (r != NEXT)
                break;
            if (ms == 0) {
                shell(T("Partition, format and mount on /mnt.", "Разметьте, отформатируйте и смонтируйте в /mnt."));
                continue;
            }
            char *mp[] = { "mountpoint", "-q", "/mnt", NULL };
            if (!dry && run(mp, NULL, 0) != 0) {
                msg(T("Disk", "Диск"), T("Nothing is mounted on /mnt yet.", "В /mnt пока ничего не смонтировано."));
                continue;
            }
            S.manual = 1;
            if (!S.efi && ndisks) {
                /* GRUB needs a disk */
                int gs = 0;
                struct menu gm = { .title = T("The disk for GRUB", "Диск для GRUB"), .items = items, .n = ndisks };
                if (run_menu(&gm, &gs) != NEXT)
                    continue;
                snprintf(S.disk, sizeof S.disk, "%s", disks[gs].dev);
            }
            return NEXT;
        }
    }
}

/* --- 14. summary ------------------------------------------------------------- */

static int step_summary(void)
{
    for (;;) {
        chrome(T("Enter: install   Esc: back   F10: quit", "Enter: установить   Esc: назад   F10: выход"));
        int y = CY;
        title(&y, T("Everything is ready", "Всё готово"));
        struct { const char *k; char v[256]; } rows[12];
        int n = 0;
#define ROW(key, ...) do { rows[n].k = key; snprintf(rows[n].v, sizeof rows[n].v, __VA_ARGS__); n++; } while (0)
        char names[200] = "";
        for (int i = 0; i < nkept; i++)
            snprintf(names + strlen(names), sizeof names - strlen(names), "%s%s%s%s", i ? ", " : "",
                     T("\"", "«"), kept[i].name, T("\"", "»"));
        ROW(T("Network", "Сеть"), "%s%s%s", S.online ? T("online", "есть") : T("offline", "нет"),
            nkept ? T("; the installed system keeps ", "; в установленной системе останется ") : "", names);
        ROW(T("Time zone", "Часовой пояс"), "%s", S.tz);
        ROW(T("Language", "Язык"), "%s", locales[S.locale].name);
        ROW(T("Keyboard", "Клавиатура"), "%s", keyboards[S.kb].name);
        ROW(T("User", "Пользователь"), "%s (%s)%s", S.fullname, S.user, S.autologin ? T(", logs in automatically", ", входит автоматически") : "");
        ROW(T("Computer", "Компьютер"), "%s", S.host);
        ROW(T("Desktop", "Рабочий стол"), "%s", optname(&desktops[S.desktop]));
        if (strcmp(desktops[S.desktop].id, "none"))
            ROW(T("Login", "Вход"), "%s", optname(&dms[S.dm]));
        ROW(T("Shell", "Оболочка"), "%s", shells[S.shell].name);
        ROW(T("Boot loader", "Загрузчик"), "%s", S.efi ? loaders[S.loader].name : "GRUB (BIOS)");
        ROW(T("Software", "Программы"), "%s", S.unfree ? T("unfree allowed", "несвободные разрешены") : T("only free", "только свободные"));
        if (S.manual)
            ROW(T("Disk", "Диск"), "%s", T("mounted on /mnt by hand", "смонтирован в /mnt вручную"));
        else
            ROW(T("Disk", "Диск"), "%s, %s", S.disk_desc, S.fs ? "btrfs" : "ext4");
#undef ROW
        int kw = 0;
        for (int i = 0; i < n; i++)
            if (dwidth(rows[i].k) > kw)
                kw = dwidth(rows[i].k);
        for (int i = 0; i < n && y < CY + CH - 4; i++) {
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            put(y, CX, rows[i].k, kw);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
            put(y++, CX + kw + 3, rows[i].v, CW - kw - 3);
        }
        y++;
        if (!S.manual) {
            char warn[300];
            snprintf(warn, sizeof warn,
                     T("Everything on %s will be erased.", "Всё, что есть на %s, будет стёрто."), S.disk);
            attron(COLOR_PAIR(C_ERR) | A_BOLD);
            wrap(y, CX, CW, CY + CH, warn);
            attroff(COLOR_PAIR(C_ERR) | A_BOLD);
        }
        present();
        wint_t c;
        int r = key(&c);
        if ((r == OK && (c == '\n' || c == '\r')) || (r == KEY_CODE_YES && c == KEY_ENTER)) {
            char q[300];
            if (S.manual)
                snprintf(q, sizeof q, "%s", T("Install NixithOS on what is mounted on /mnt?", "Установить NixithOS в то, что смонтировано в /mnt?"));
            else
                snprintf(q, sizeof q, T("Erase %s and install NixithOS on it? This cannot be undone.",
                                        "Стереть %s и установить на него NixithOS? Это нельзя отменить."), S.disk);
            if (dialog(T("Install", "Установка"), q, T("Install", "Установить"), T("Back", "Назад"), NULL) == 0)
                return NEXT;
        } else if (r == OK && c == 27) {
            return BACK;
        } else if (r == KEY_CODE_YES && c == KEY_F(10)) {
            ask_quit();
        }
    }
}

/* --- 15. install ------------------------------------------------------------- */

static void hash(const char *pw, char *out, int size)
{
    const char *salt = crypt_gensalt(NULL, 0, NULL, 0);
    const char *h = salt ? crypt(pw, salt) : NULL;
    snprintf(out, size, "%s", h && *h != '*' ? h : "!");
}

static void setenv_choices(void)
{
    char h[256];
    setenv("NI_MODE", S.manual ? "manual" : "erase", 1);
    setenv("NI_DISK", S.disk, 1);
    setenv("NI_FS", S.fs ? "btrfs" : "ext4", 1);
    setenv("NI_FIRMWARE", S.efi ? "efi" : "bios", 1);
    setenv("NI_TZ", S.tz, 1);
    setenv("NI_LOCALE", locales[S.locale].id, 1);
    const struct opt *k = &keyboards[S.kb];
    char layout[32];
    snprintf(layout, sizeof layout, *k->ru ? "us,%s" : "%s", k->id);
    setenv("NI_KB_LAYOUT", layout, 1);
    setenv("NI_KB_OPTIONS", *k->ru ? "grp:alt_shift_toggle" : "", 1);
    setenv("NI_CONSOLE_KEYMAP", k->en, 1);
    int cyr = *k->ru || !strncmp(locales[S.locale].id, "ru", 2) || !strncmp(locales[S.locale].id, "uk", 2) ||
              !strncmp(locales[S.locale].id, "be", 2) || !strncmp(locales[S.locale].id, "kk", 2);
    setenv("NI_CYRILLIC", cyr ? "1" : "0", 1);
    setenv("NI_FULLNAME", S.fullname, 1);
    setenv("NI_USER", S.user, 1);
    hash(S.pw1, h, sizeof h);
    setenv("NI_USER_HASH", h, 1);
    hash(S.rootsame ? S.pw1 : S.rpw1, h, sizeof h);
    setenv("NI_ROOT_HASH", h, 1);
    setenv("NI_HOST", S.host, 1);
    setenv("NI_AUTOLOGIN", S.autologin ? "1" : "0", 1);
    setenv("NI_DESKTOP", desktops[S.desktop].id, 1);
    setenv("NI_DM", dms[S.dm].id, 1);
    setenv("NI_SHELL", shells[S.shell].id, 1);
    setenv("NI_LOADER", loaders[S.loader].id, 1);
    setenv("NI_UNFREE", S.unfree ? "1" : "0", 1);
    char files[4096];
    kept_files(files, sizeof files);
    setenv("NI_NM_KEEP", files, 1);
    setenv("NI_DRY", dry ? "1" : "0", 1);
}

#define NLOG 400
static char *loglines[NLOG];
static int nlog;

static void log_add(const char *l)
{
    if (nlog == NLOG) {
        free(loglines[0]);
        memmove(loglines, loglines + 1, sizeof *loglines * (NLOG - 1));
        nlog--;
    }
    loglines[nlog++] = strdup(l);
}

/* the slides while it installs: those of Calamares (../calamares-nixithos/
 * show.qml), a tip each about what the installed system has, some with a
 * screenshot; [0] English, [1] Russian */
static const struct tip {
    const char *kicker[2], *title[2], *body[2], *cmd, *img;
} tips[] = {
    { { "NixithOS", "NixithOS" }, { "NixOS, without systemd", "NixOS без systemd" },
      { "PID 1 is s6-linux-init, services run under s6-rc, devices are eudev's and logs s6-log's. The packages, the modules and configuration.nix are NixOS's own.",
        "PID 1 — s6-linux-init, службы работают под s6-rc, устройства — от eudev, журналы — от s6-log. Пакеты, модули и configuration.nix — те же, что в NixOS." },
      "cat /proc/1/comm      # s6-svscan", NULL },
    { { "Configuration", "Конфигурация" }, { "One file describes the whole system", "Вся система описана одним файлом" },
      { "Users, services, desktop, packages: everything is in /etc/nixith/configuration.nix. Change it, then build and switch to it in one go.",
        "Пользователи, службы, рабочий стол, пакеты — всё в /etc/nixith/configuration.nix. Измените его, а потом соберите систему и переключитесь на неё одной командой." },
      "sudo nixith switch", NULL },
    { { "Configuration", "Конфигурация" }, { "Rebuild only the part you changed", "Пересобрать только изменённое" },
      { "--only takes an option or a group of them; everything else stays exactly as in the running system, even half-done edits elsewhere in the file.",
        "--only принимает опцию или группу опций; всё остальное остаётся точно таким, как в работающей системе, даже недописанные правки в других местах файла." },
      "sudo nixith switch --only services.openssh", NULL },
    { { "Generations", "Поколения" }, { "Every change can be undone", "Любое изменение можно отменить" },
      { "Each switch is a new generation, and the boot menu lists them all. Something broke? Go back to the previous one, or pick it when the machine starts.",
        "Каждый switch — новое поколение, и меню загрузки показывает их все. Что-то сломалось? Вернитесь к предыдущему или выберите его при включении." },
      "nixith generations\nsudo nixith rollback", "dwl" },
    { { "Generations", "Поколения" }, { "Try a configuration before keeping it", "Попробовать конфигурацию, прежде чем оставить" },
      { "build-vm builds the same system into a script that starts it in QEMU, without touching the one you are running.",
        "build-vm собирает ту же систему в скрипт, который запускает её в QEMU, не трогая работающую." },
      "nixith build-vm && ./result/bin/run-*-vm", NULL },
    { { "Services", "Службы" }, { "systemctl still works", "systemctl по-прежнему работает" },
      { "It is a thin wrapper over s6-rc: start, stop, restart, status. The native tools are there too.",
        "Это тонкая обёртка над s6-rc: start, stop, restart, status. Родные инструменты тоже на месте." },
      "systemctl restart sshd\ns6-rc -a list", NULL },
    { { "Services", "Службы" }, { "Logs are plain files", "Журналы — обычные файлы" },
      { "Every service writes to /var/log/s6/<service>/ through its own logger; journalctl -u reads those directories.",
        "Каждая служба пишет в /var/log/s6/<служба>/ через свой логгер; journalctl -u читает эти каталоги." },
      "journalctl -u sshd -f\ntail -F /var/log/s6/sshd/current", NULL },
    { { "Packages", "Пакеты" }, { "Over 140 000 packages, from the cache", "Больше 140 000 пакетов, из кэша" },
      { "NixithOS uses the same nixpkgs and the same binaries as NixOS; only libsystemd and libudev are swapped for elogind's and eudev's under them. Nothing is compiled.",
        "NixithOS берёт те же nixpkgs и те же готовые пакеты, что и NixOS; под ними подменены только libsystemd и libudev — на elogind и eudev. Ничего не компилируется." },
      NULL, "parallax" },
    { { "Packages", "Пакеты" }, { "Use a program without installing it", "Программа без установки" },
      { "nix-shell gives you a shell with the packages you name; when you leave it, nothing has changed in the system.",
        "nix-shell даёт оболочку с названными пакетами; после выхода из неё в системе ничего не меняется." },
      "nix-shell -p htop ripgrep", NULL },
    { { "Packages", "Пакеты" }, { "Install for good", "Установить насовсем" },
      { "Add the package to environment.systemPackages (for everyone) or to users.users.<you>.packages, and switch. search.nixos.org has the names.",
        "Добавьте пакет в environment.systemPackages (для всех) или в users.users.<вы>.packages и сделайте switch. Имена — на search.nixos.org." },
      "environment.systemPackages = [ pkgs.btop ];", NULL },
    { { "Desktops", "Рабочие столы" }, { "Add another desktop at any time", "Ещё один стол — в любой момент" },
      { "Parallax, GNOME, Plasma, Hyprland, niri and dwl are one line each; every one you enable shows up in the login screen's list of sessions.",
        "Parallax, GNOME, Plasma, Hyprland, niri и dwl — по одной строке; каждый включённый появляется в списке сеансов на экране входа." },
      "nixithos.desktop.niri.enable = true;", "dm-ly" },
    { { "Desktops", "Рабочие столы" }, { "The first keys to know", "Первые клавиши" },
      { "Hyprland: Super+Q a terminal, Super+R programs, Super+M log out.\nniri: Super+T, Super+D, Super+Shift+/ for all the keys.\ndwl: Super+Shift+Enter, Super+P, Super+Shift+Q.",
        "Hyprland: Super+Q — терминал, Super+R — программы, Super+M — выход.\nniri: Super+T, Super+D, Super+Shift+/ — все клавиши.\ndwl: Super+Shift+Enter, Super+P, Super+Shift+Q." },
      NULL, "hyprland" },
    { { "Shells", "Оболочки" }, { "Another shell later", "Другая оболочка — потом" },
      { "bash, zsh, fish or nushell: the shell is a line in the configuration too, per user.",
        "bash, zsh, fish или nushell: оболочка — тоже строка в конфигурации, у каждого пользователя своя." },
      "programs.fish.enable = true;\nusers.users.<you>.shell = pkgs.fish;", "shell-fish" },
    { { "Network", "Сеть" }, { "Wi-Fi from the terminal", "Wi-Fi из терминала" },
      { "NetworkManager is on; nmtui finds the networks and asks for the password. Desktops show it in their panels as well. The connection made in this installer is already there.",
        "NetworkManager включён; nmtui находит сети и спрашивает пароль. Рабочие столы показывают сеть и на своих панелях. Подключение, сделанное в установщике, уже там." },
      "nmtui", NULL },
    { { "Flakes", "Флейки" }, { "Flakes work, with your own nixpkgs", "Флейки работают, со своими nixpkgs" },
      { "nixith builds nixithConfigurations.<host> (or nixosConfigurations.<host>) of a flake as readily as configuration.nix.",
        "nixith собирает nixithConfigurations.<хост> (или nixosConfigurations.<хост>) из флейка так же легко, как configuration.nix." },
      "sudo nixith switch --flake /etc/nixith#box", NULL },
    { { "Housekeeping", "Уборка" }, { "Free the disk of old generations", "Освободить диск от старых поколений" },
      { "Old generations keep their packages in the store until you collect them; the next build tidies the boot menu.",
        "Старые поколения держат свои пакеты в хранилище, пока их не соберут; следующая сборка приведёт в порядок меню загрузки." },
      "sudo nix-collect-garbage -d\nsudo nixith boot", NULL },
    { { "Almost there", "Почти готово" }, { "When it is done", "Когда всё закончится" },
      { "Remove the installation medium and restart. The boot menu will show NixithOS; your configuration is waiting in /etc/nixith.",
        "Извлеките установочный носитель и перезагрузитесь. В меню загрузки будет NixithOS; ваша конфигурация ждёт в /etc/nixith." },
      "nixith parts      # what the system was built from", NULL },
};
#define NTIPS (int)(sizeof tips / sizeof *tips)

/* a slide from row y to row bottom: the tip, and its screenshot beside it */
static void draw_tip(int i, int y, int bottom)
{
    const struct tip *t = &tips[i];
    if (t->img)
        pic_right(t->img, y, 50, bottom - y + 1);
    char pos[16];
    snprintf(pos, sizeof pos, "%d / %d", i + 1, NTIPS);
    attron(COLOR_PAIR(C_DIM) | A_BOLD);
    put(y, CX, t->kicker[ru], CW - 8);
    put(y, CX + CW - dwidth(pos), pos, dwidth(pos));
    attroff(COLOR_PAIR(C_DIM) | A_BOLD);
    y += 2;
    attron(A_BOLD);
    y = wrap(y, CX, CW, bottom, t->title[ru]);
    attroff(A_BOLD);
    y = wrap(y + 1, CX, CW, bottom, t->body[ru]);
    if (t->cmd && y + 1 <= bottom) {
        /* the command, as in a terminal: a bar on its left */
        char line[256];
        y++;
        for (const char *p = t->cmd; *p && y <= bottom;) {
            int n = strcspn(p, "\n");
            snprintf(line, sizeof line, "%.*s", n, p);
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            mvaddch(y, CX, ACS_VLINE);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
            attron(A_BOLD);
            put(y++, CX + 2, line, CW - 2);
            attroff(A_BOLD);
            p += n + (p[n] == '\n');
        }
    }
}

static int step_install(void)
{
    static const char *stages_en[] = { "Preparing the disk", "Creating file systems", "Writing the configuration",
                                       "Installing NixithOS", "Finishing" };
    static const char *stages_ru[] = { "Подготовка диска", "Файловые системы", "Конфигурация",
                                       "Установка NixithOS", "Завершение" };
    setenv_choices();
    FILE *logf = fopen("/tmp/nixith-install.log", "w");
    int fd[2];
    if (pipe(fd) < 0)
        return STAY;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(fd[1], 1);
        dup2(fd[1], 2);
        close(fd[0]);
        close(fd[1]);
        int nul = open("/dev/null", O_RDONLY);
        if (nul >= 0)
            dup2(nul, 0);
        const char *sh = getenv("NIXITH_INSTALL_SH") ? getenv("NIXITH_INSTALL_SH") : INSTALL_SH;
        execlp("bash", "bash", sh, (char *)NULL);
        _exit(127);
    }
    close(fd[1]);
    fcntl(fd[0], F_SETFL, O_NONBLOCK);
    int stage = 0, done = 0, failed = 0, spin = 0, eof = 0, drawn_final = 0;
    char failmsg[512] = "", part[4096] = "";
    time_t t0 = time(NULL), tip_t = t0;
    int tip = 0, show_log = 0;
    nodelay(stdscr, TRUE);
    for (;;) {
        /* read what came */
        struct pollfd p = { fd[0], POLLIN, 0 };
        if (!eof && poll(&p, 1, 150) > 0) {
            char buf[4096];
            ssize_t k = read(fd[0], buf, sizeof buf - 1);
            if (k <= 0) {
                eof = 1;
            } else {
                buf[k] = 0;
                if (logf)
                    fputs(buf, logf), fflush(logf);
                strncat(part, buf, sizeof part - strlen(part) - 1);
                char *nl;
                while ((nl = strchr(part, '\n'))) {
                    *nl = 0;
                    if (!strncmp(part, "::step ", 7))
                        stage = atoi(part + 7) - 1;
                    else if (!strcmp(part, "::done"))
                        done = 1;
                    else if (!strncmp(part, "::fail ", 7))
                        snprintf(failmsg, sizeof failmsg, "%s", part + 7), failed = 1;
                    else
                        log_add(part);
                    memmove(part, nl + 1, strlen(nl + 1) + 1);
                }
                if (strlen(part) > sizeof part - 200) { /* a line without end (progress bars) */
                    log_add(part);
                    part[0] = 0;
                }
            }
        }
        /* the keys: the slides back and forth, the whole log; a slide goes
         * on by itself after 11 seconds, as in Calamares */
        wint_t c;
        int kr;
        while ((kr = get_wch(&c)) != ERR) {
            if (kr == KEY_CODE_YES && (c == KEY_RIGHT || c == KEY_LEFT)) {
                tip = (tip + (c == KEY_RIGHT ? 1 : NTIPS - 1)) % NTIPS;
                tip_t = time(NULL);
            } else if (kr == OK && (c == '\t' || c == 'l' || c == 'L')) {
                show_log = !show_log;
            }
        }
        if (time(NULL) - tip_t >= 11) {
            tip = (tip + 1) % NTIPS;
            tip_t = time(NULL);
        }
        /* draw */
        chrome(done || failed ? ""
                              : T("←→ slides   Tab: the log   Please do not turn the computer off while it installs.",
                                  "←→ слайды   Tab: журнал   Не выключайте компьютер, пока идёт установка."));
        int y = CY;
        title(&y, done ? T("NixithOS is installed", "NixithOS установлена")
                       : failed ? T("The installation failed", "Установка не удалась")
                                : T("Installing NixithOS", "Установка NixithOS"));
        static const char spinner[] = "|/-\\";
        for (int i = 0; i < 5; i++) {
            if (S.manual && (i == 0 || i == 1) && i != stage)
                continue;
            const char *mark;
            char sp[8];
            if (i < stage || done) {
                mark = "[ ok ]";
                attron(COLOR_PAIR(C_OK) | A_BOLD);
            } else if (i == stage) {
                if (failed) {
                    mark = "[fail]";
                    attron(COLOR_PAIR(C_ERR) | A_BOLD);
                } else {
                    snprintf(sp, sizeof sp, "[ %c%c ]", spinner[spin % 4], spinner[(spin + 2) % 4]);
                    mark = sp;
                    attron(A_BOLD);
                }
            } else {
                mark = "[    ]";
                attron(COLOR_PAIR(C_DIM) | A_BOLD);
            }
            put(y, CX, mark, 6);
            put(y, CX + 7, ru ? stages_ru[i] : stages_en[i], CW - 7);
            attroff(COLOR_PAIR(C_OK) | COLOR_PAIR(C_ERR) | COLOR_PAIR(C_DIM) | A_BOLD);
            y++;
        }
        char el[64];
        int secs = (int)(time(NULL) - t0);
        snprintf(el, sizeof el, "%d:%02d", secs / 60, secs % 60);
        attron(COLOR_PAIR(C_DIM) | A_BOLD);
        put(CY, CX + CW - dwidth(el), el, dwidth(el));
        y++;
        mvhline(y++, CX, ACS_HLINE, CW);
        attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        int rows = CY + CH - y - (done || failed ? 2 : 0);
        if (!show_log && !done && !failed && rows >= 10) {
            /* a slide, and under it the last lines of the log */
            int tail = rows >= 18 ? 3 : 1, cw = CW;
            draw_tip(tip, y + 1, y + rows - tail - 3);
            CW = cw;
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            mvhline(y + rows - tail - 1, CX, ACS_HLINE, CW);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
            y += rows - tail;
            rows = tail;
        }
        for (int i = 0; i < rows; i++) {
            int li = nlog - rows + i;
            if (li < 0)
                continue;
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            put(y + i, CX, loglines[li], CW);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        }
        present();
        spin++;
        if (eof && drawn_final)
            break;
        if (eof) {
            int st;
            waitpid(pid, &st, 0);
            if (!done && !failed) {
                failed = 1;
                snprintf(failmsg, sizeof failmsg, T("The installation stopped (exit code %d).", "Установка прервалась (код %d)."),
                         WIFEXITED(st) ? WEXITSTATUS(st) : -1);
            }
            drawn_final = 1; /* once more, with the result */
        }
    }
    nodelay(stdscr, FALSE);
    close(fd[0]);
    if (logf)
        fclose(logf);
    for (;;) {
        int b;
        if (done && !failed) {
            b = dialog(T("Done", "Готово"),
                       dry ? T("The plan was printed (--dry): nothing was changed.", "План показан (--dry): ничего не изменено.")
                           : T("NixithOS is installed. Take out the installation medium and restart the computer.",
                               "NixithOS установлена. Извлеките установочный носитель и перезагрузите компьютер."),
                       T("Restart", "Перезагрузить"), T("Shell", "Консоль"), T("Exit", "Выйти"));
            if (b == 0 && !dry) {
                endwin();
                execlp("reboot", "reboot", (char *)NULL);
            }
        } else {
            char text[800];
            snprintf(text, sizeof text, "%s\n\n%s", failmsg,
                     T("The whole log is in /tmp/nixith-install.log.", "Весь журнал — в /tmp/nixith-install.log."));
            b = dialog(T("Error", "Ошибка"), text, T("Back", "Назад"), T("Shell", "Консоль"), T("Exit", "Выйти"));
            if (b == 0)
                return BACK;
        }
        if (b == 1)
            shell(T("The installed system is on /mnt (`nixith enter --root /mnt` enters it).",
                    "Установленная система — в /mnt (`nixith enter --root /mnt` входит в неё)."));
        if (b == 2)
            quit_installer();
    }
}

/* --- main -------------------------------------------------------------------- */

int main(int argc, char **argv)
{
    setlocale(LC_ALL, "");
    setlocale(LC_NUMERIC, "C"); /* 3.8 GiB, not 3,8 */
    const char *cs = getenv("LANG");
    utf8 = cs && (strstr(cs, "UTF-8") || strstr(cs, "utf8"));
    const char *base = strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    net_only = !strcmp(base, "nixith-net");
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dry"))
            dry = 1;
        else if (!strcmp(argv[i], "--net"))
            net_only = 1;
        else if (!strcmp(argv[i], "--ru"))
            ru = 1;
        else {
            fprintf(stderr, "usage: %s [--dry] [--net] [--ru]\n", argv[0]);
            return 2;
        }
    }
    if (cs && !strncmp(cs, "ru", 2))
        ru = 1;
    if (!dry && !net_only && geteuid() != 0) {
        fprintf(stderr, "%s\n", ru ? "Нужны права root: sudo nixith-installer" : "This needs root: sudo nixith-installer");
        return 1;
    }
    S.efi = access("/sys/firmware/efi", F_OK) == 0;
    load_art();
    pic_init();

    setenv("ESCDELAY", "25", 1);
    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    /* (no shifting of characters along a line: that would shift a part of a
     * picture on the framebuffer with them) */
    idcok(stdscr, FALSE);
    if (has_colors()) {
        start_color();
        use_default_colors();
        init_pair(C_NORMAL, COLOR_WHITE, -1);
        init_pair(C_DIM, COLOR_BLACK, -1);
        init_pair(C_SEL, COLOR_BLACK, COLOR_WHITE);
        init_pair(C_ERR, COLOR_RED, -1);
        init_pair(C_OK, COLOR_GREEN, -1);
        init_pair(C_HEAD, COLOR_BLACK, COLOR_WHITE);
        init_pair(C_PIC, COLOR_BLACK, COLOR_BLACK);
    } else {
        pic_mode = PIC_NONE; /* (no colour pair of its own to keep the cells) */
    }
    bkgd(COLOR_PAIR(C_NORMAL));

    if (net_only) {
        for (;;)
            step_network();
    }

    int (*steps[NSTEPS])(void) = {
        step_welcome, step_guide, step_network, step_tz, step_locale, step_keyboard, step_user,
        step_desktop, step_login, step_shell, step_loader, step_unfree, step_disk, step_summary,
        step_install,
    };
    for (cur_step = 0; cur_step < NSTEPS;) {
        int r = steps[cur_step]();
        if (r == NEXT)
            cur_step++;
        else if (r == BACK && cur_step > 0) {
            cur_step--;
            /* a step that passes by itself is passed going back too */
            if (cur_step == ST_LOGIN && !strcmp(desktops[S.desktop].id, "none"))
                cur_step--;
        }
    }
    quit_installer();
    return 0;
}

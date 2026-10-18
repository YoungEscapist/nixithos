/*
 * nixith-installer: the installer of NixithOS, in the console.
 *
 * A wizard over ncurses: the steps of the old Calamares installer (time
 * zone, language, keyboard, user, desktop, login, shell, boot loader,
 * unfree software, disk), with a network step in front of them that does
 * what nmtui does, only simpler: the wired network by itself, a list of
 * Wi-Fi networks, a password.  Nothing touches the disk until the summary is
 * confirmed; then ./install.sh does the work (partitioning, the
 * configuration, `nixith install`) and its output is shown as it goes.
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
#include <locale.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

#ifndef INSTALL_SH
#define INSTALL_SH "./install.sh"
#endif
#ifndef LOGO_TXT
#define LOGO_TXT "/etc/nixithos/logo.txt"
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

enum { C_NORMAL = 1, C_DIM, C_SEL, C_ERR, C_OK, C_HEAD };
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

static int cur_step;

static void chrome(const char *keys)
{
    erase();
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
    put(0, 0, T("The terminal is too small (72x22 at least).",
                "Терминал слишком мал (нужно хотя бы 72x22)."), COLS);
    refresh();
    return 1;
}

/* --- dialogs -------------------------------------------------------------- */

/* a box in the middle; returns the chosen button (Esc: the last one) */
static int dialog(const char *head, const char *text, const char *b1, const char *b2, const char *b3)
{
    const char *btn[3] = { b1, b2, b3 };
    int nb = b3 ? 3 : b2 ? 2 : 1, sel = 0;
    for (;;) {
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
        refresh();
        wint_t c;
        int r = get_wch(&c);
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

/* a line of text, typed in a box; returns 1 if entered, 0 if cancelled */
static int ask_line(const char *head, const char *prompt, char *buf, int size, int secret)
{
    int show = 0;
    for (;;) {
        int w = COLS - 8 < 60 ? COLS - 8 : 60, h = 9;
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
        put(y0 + 2, x0 + 2, prompt, w - 4);
        char shown[512];
        if (secret && !show) {
            int n = dwidth(buf), k = 0;
            for (; k < n && k < 500; k++)
                shown[k] = '*';
            shown[k] = 0;
        } else {
            snprintf(shown, sizeof shown, "%s", buf);
        }
        attron(COLOR_PAIR(C_SEL));
        mvhline(y0 + 4, x0 + 2, ' ', w - 4);
        int sw = dwidth(shown);
        const char *vis = shown;
        while (sw > w - 6 && *vis) { /* keep the end in sight */
            vis++;
            sw = dwidth(vis);
        }
        put(y0 + 4, x0 + 3, vis, w - 6);
        attroff(COLOR_PAIR(C_SEL));
        attron(COLOR_PAIR(C_DIM) | A_BOLD);
        put(y0 + 6, x0 + 2,
            secret ? T("Enter: OK   Esc: cancel   F2: show/hide", "Enter: готово   Esc: отмена   F2: показать")
                   : T("Enter: OK   Esc: cancel", "Enter: готово   Esc: отмена"),
            w - 4);
        attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        attroff(COLOR_PAIR(C_NORMAL));
        move(y0 + 4, x0 + 3 + dwidth(vis));
        curs_set(1);
        refresh();
        wint_t c;
        int r = get_wch(&c);
        curs_set(0);
        if (r == KEY_CODE_YES) {
            if (c == KEY_ENTER)
                return 1;
            if (c == KEY_F(2))
                show = !show;
            if (c == KEY_BACKSPACE) {
                int n = strlen(buf);
                while (n > 0 && (buf[n - 1] & 0xC0) == 0x80)
                    n--;
                if (n > 0)
                    buf[n - 1] = 0;
            }
        } else if (r == OK) {
            if (c == '\n' || c == '\r')
                return 1;
            if (c == 27)
                return 0;
            if (c == 127 || c == 8) {
                int n = strlen(buf);
                while (n > 0 && (buf[n - 1] & 0xC0) == 0x80)
                    n--;
                if (n > 0)
                    buf[n - 1] = 0;
            } else if (c >= 32) {
                char mb[8];
                mbstate_t st = { 0 };
                size_t k = wcrtomb(mb, c, &st);
                if (k != (size_t)-1 && strlen(buf) + k < (size_t)size) {
                    mb[k] = 0;
                    strcat(buf, mb);
                }
            }
        }
    }
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
};

static int run_menu(struct menu *m, int *sel)
{
    char q[64] = "";
    int top = 0;
    int *vis = malloc(sizeof(int) * (m->n + 1));
    for (;;) {
        if (too_small()) {
            wint_t c;
            get_wch(&c);
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
        refresh();

        wint_t c;
        int r = get_wch(&c);
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
    refresh();
}

/* the user's shell, then back to the screen */
static void shell(const char *note)
{
    def_prog_mode();
    endwin();
    printf("\n%s\n%s\n\n", note, T("Type `exit` to return to the installer.",
                                     "Наберите `exit`, чтобы вернуться в установщик."));
    fflush(stdout);
    if (system("${SHELL:-bash} -l") == -1)
        perror("bash");
    reset_prog_mode();
    refresh();
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
            "Next comes the network: the installation downloads the desktop you choose, so connect to the internet if you can. A cable works by itself; for Wi-Fi pick the network and type its password.\n\n"
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
            "Дальше — сеть: установка скачивает выбранный рабочий стол, поэтому подключитесь к интернету, если можете. Кабель работает сам; для Wi-Fi выберите сеть и введите пароль.\n\n"
            "Нужна консоль? Alt+F2 открывает ещё одну."));
        refresh();
        wint_t c;
        int r = get_wch(&c);
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

/* --- 3. network (what nmtui does, simpler) ---------------------------------- */

struct wifi {
    char ssid[96], security[48];
    int signal, inuse;
};
static struct wifi nets[64];
static int nnets, wifi_dev;
static char wired[160], net_line[200];

static int have_nmcli(void)
{
    char *a[] = { "nmcli", "--version", NULL };
    return run(a, NULL, 0) == 0;
}

static void net_scan(int rescan)
{
    char out[16384];
    /* the devices: what is connected */
    char *dev[] = { "nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", NULL };
    wired[0] = 0;
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
            if (!strcmp(f[1], "ethernet") && !strncmp(f[2], "connected", 9))
                snprintf(wired, sizeof wired, "%s", f[0]);
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

static int net_connect(const char *ssid, const char *security, int hidden)
{
    char pw[128] = "";
    if (*security || hidden) {
        char prompt[200];
        snprintf(prompt, sizeof prompt, T("The password of \"%s\":", "Пароль сети «%s»:"), ssid);
        if (!ask_line(T("Wi-Fi", "Wi-Fi"), prompt, pw, sizeof pw, 1))
            return 0;
    }
    char head[160];
    snprintf(head, sizeof head, T("Connecting to %s", "Подключение к %s"), ssid);
    busy(head);
    char *argv[12];
    int a = 0;
    argv[a++] = "nmcli";
    argv[a++] = "device";
    argv[a++] = "wifi";
    argv[a++] = "connect";
    argv[a++] = (char *)ssid;
    if (*pw) {
        argv[a++] = "password";
        argv[a++] = pw;
    }
    if (hidden) {
        argv[a++] = "hidden";
        argv[a++] = "yes";
    }
    argv[a] = NULL;
    char out[2048];
    int r = run(argv, out, sizeof out);
    memset(pw, 0, sizeof pw);
    if (r != 0) {
        char text[2400];
        out[strcspn(out, "\n")] = 0;
        snprintf(text, sizeof text, "%s\n\n%s",
                 T("Could not connect. Check the password and try again.",
                   "Не удалось подключиться. Проверьте пароль и попробуйте ещё раз."),
                 out);
        msg(T("Wi-Fi", "Wi-Fi"), text);
        return 0;
    }
    net_scan(0);
    return 1;
}

static const char *net_desc(int i)
{
    (void)i;
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
        int kind[72], idx[72], n = 0;
        enum { K_GO, K_NET, K_HIDDEN, K_RESCAN, K_SKIP };
        if (S.online || net_only) {
            snprintf(labels[n], sizeof labels[n], "%s", S.online ? T("Continue: you are online", "Далее: интернет есть")
                                                                 : T("Close", "Закрыть"));
            kind[n++] = K_GO;
        }
        for (int i = 0; i < nnets && n < 64; i++) {
            int bars = nets[i].signal >= 75 ? 4 : nets[i].signal >= 50 ? 3 : nets[i].signal >= 25 ? 2 : 1;
            const char *b = utf8 ? (bars == 4 ? "▂▄▆█" : bars == 3 ? "▂▄▆ " : bars == 2 ? "▂▄  " : "▂   ")
                                 : (bars == 4 ? "####" : bars == 3 ? "### " : bars == 2 ? "##  " : "#   ");
            snprintf(labels[n], sizeof labels[n], "%-28.28s %s  %s", nets[i].ssid, b,
                     nets[i].inuse ? T("connected", "подключено")
                     : *nets[i].security ? T("password", "пароль") : T("open", "открытая"));
            kind[n] = K_NET;
            idx[n++] = i;
        }
        if (wifi_dev) {
            snprintf(labels[n], sizeof labels[n], "%s", T("Another network (hidden)...", "Другая сеть (скрытая)..."));
            kind[n++] = K_HIDDEN;
            snprintf(labels[n], sizeof labels[n], "%s", T("Search again", "Искать снова"));
            kind[n++] = K_RESCAN;
        }
        if (!S.online && !net_only) {
            snprintf(labels[n], sizeof labels[n], "%s", T("Continue without the internet", "Продолжить без интернета"));
            kind[n++] = K_SKIP;
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
        switch (kind[sel]) {
        case K_GO:
            if (net_only)
                quit_installer();
            return NEXT;
        case K_SKIP:
            return NEXT;
        case K_RESCAN:
            busy(T("Looking for networks", "Поиск сетей"));
            net_scan(1);
            break;
        case K_HIDDEN: {
            char ssid[96] = "";
            if (ask_line(T("Hidden network", "Скрытая сеть"), T("The name of the network:", "Имя сети:"), ssid, sizeof ssid, 0) && *ssid)
                net_connect(ssid, "", 1);
            break;
        }
        case K_NET:
            if (net_connect(nets[idx[sel]].ssid, nets[idx[sel]].security, 0) && S.online)
                sel = 0;
            break;
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

enum { F_TEXT, F_PASS, F_CHECK };
struct field {
    const char *label;
    char *buf;
    int size, kind, *flag, hidden;
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
            get_wch(&c);
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
        refresh();
        wint_t c;
        int r = get_wch(&c);
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

static int choose(const char *head, const char *intro, const struct opt *o, int n, int *sel)
{
    static const char *items[16];
    for (int i = 0; i < n; i++)
        items[i] = optname(&o[i]);
    desc_table = o;
    struct menu m = { .title = head, .intro = intro, .items = items, .n = n, .desc = opt_desc };
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
        ROW(T("Network", "Сеть"), "%s", S.online ? T("online", "есть") : T("offline", "нет"));
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
        refresh();
        wint_t c;
        int r = get_wch(&c);
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
    setenv("NI_DRY", dry ? "1" : "0", 1);
}

#define NLOG 400
static char *logl[NLOG];
static int nlog;

static void log_add(const char *l)
{
    if (nlog == NLOG) {
        free(logl[0]);
        memmove(logl, logl + 1, sizeof *logl * (NLOG - 1));
        nlog--;
    }
    logl[nlog++] = strdup(l);
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
    time_t t0 = time(NULL);
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
        /* draw */
        chrome(done || failed ? ""
                              : T("The installation is running; please do not turn the computer off.",
                                  "Идёт установка; не выключайте компьютер."));
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
        for (int i = 0; i < rows; i++) {
            int li = nlog - rows + i;
            if (li < 0)
                continue;
            attron(COLOR_PAIR(C_DIM) | A_BOLD);
            put(y + i, CX, logl[li], CW);
            attroff(COLOR_PAIR(C_DIM) | A_BOLD);
        }
        refresh();
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

    setenv("ESCDELAY", "25", 1);
    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    if (has_colors()) {
        start_color();
        use_default_colors();
        init_pair(C_NORMAL, COLOR_WHITE, -1);
        init_pair(C_DIM, COLOR_BLACK, -1);
        init_pair(C_SEL, COLOR_BLACK, COLOR_WHITE);
        init_pair(C_ERR, COLOR_RED, -1);
        init_pair(C_OK, COLOR_GREEN, -1);
        init_pair(C_HEAD, COLOR_BLACK, COLOR_WHITE);
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

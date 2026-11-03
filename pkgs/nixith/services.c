/*
 * nixith-services: the units of the running system in a console list.
 *
 *   nixith services            the list (ncurses)
 *   nixith services --list     the same as plain lines, for scripts
 *
 *   up down j k PgUp PgDn g G  move
 *   /                          filter by name (Enter keeps it, Esc clears it)
 *   f                          show all / active / failed / inactive units
 *   Enter                      status and the end of the log
 *   w                          (in the status) why the unit runs: nixith why
 *   s x r                      start, stop (asks), restart (asks)
 *   R                          read the list again (it does every 3 seconds)
 *   q                          quit
 *
 * The units and their states are read with `systemctl list-units --all`, and
 * started, stopped and restarted with systemctl, so it works the same under
 * s6 and dinit.  Changing a unit takes root.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <curses.h>
#include <locale.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

#define NAME_MAX_ 128
#define DESC_MAX 160

struct unit {
    char name[NAME_MAX_];
    char active[24];
    char sub[24];
    char desc[DESC_MAX];
};

static struct unit *units;
static int nunits, capunits;
static int *view; /* indices into units that pass the filter */
static int nview;
static char name_filter[64];
static int state_mode; /* 0 all, 1 active, 2 failed, 3 inactive */
static const char *mode_name[] = {"all", "active", "failed", "inactive"};

static void load_units(void)
{
    FILE *p = popen("systemctl list-units --all --no-legend 2>/dev/null", "r");
    char line[1024];
    nunits = 0;
    if (!p)
        return;
    while (fgets(line, sizeof line, p)) {
        struct unit u;
        char load[24];
        int n = 0;
        line[strcspn(line, "\n")] = 0;
        if (sscanf(line, "%127s %23s %23s %23s %n", u.name, load, u.active, u.sub, &n) < 4)
            continue;
        snprintf(u.desc, sizeof u.desc, "%s", line + n);
        if (nunits == capunits) {
            capunits = capunits ? capunits * 2 : 256;
            units = realloc(units, capunits * sizeof *units);
            view = realloc(view, capunits * sizeof *view);
        }
        units[nunits++] = u;
    }
    pclose(p);
}

static int cmp_units(const void *a, const void *b)
{
    return strcmp(((const struct unit *)a)->name, ((const struct unit *)b)->name);
}

static int match(const struct unit *u)
{
    if (state_mode == 1 && strcmp(u->active, "active"))
        return 0;
    if (state_mode == 2 && strcmp(u->active, "failed"))
        return 0;
    if (state_mode == 3 && strcmp(u->active, "inactive"))
        return 0;
    if (name_filter[0] && !strcasestr(u->name, name_filter) && !strcasestr(u->desc, name_filter))
        return 0;
    return 1;
}

static void apply_filter(void)
{
    nview = 0;
    for (int i = 0; i < nunits; i++)
        if (match(&units[i]))
            view[nview++] = i;
}

static void list_plain(void)
{
    load_units();
    qsort(units, nunits, sizeof *units, cmp_units);
    apply_filter();
    for (int i = 0; i < nview; i++) {
        struct unit *u = &units[view[i]];
        printf("%-44s %-10s %-10s %s\n", u->name, u->active, u->sub, u->desc);
    }
}

/* the text of a command's output, line by line */
static char **lines;
static int nlines, caplines;

static void free_lines(void)
{
    for (int i = 0; i < nlines; i++)
        free(lines[i]);
    nlines = 0;
}

static void run_text(const char *cmd)
{
    FILE *p = popen(cmd, "r");
    char buf[2048];
    free_lines();
    if (!p)
        return;
    while (fgets(buf, sizeof buf, p)) {
        buf[strcspn(buf, "\n")] = 0;
        /* tabs and the like would shift the screen */
        for (char *c = buf; *c; c++)
            if (*c == '\t')
                *c = ' ';
            else if ((unsigned char)*c < 32 && *c != 0)
                *c = ' ';
        if (nlines == caplines) {
            caplines = caplines ? caplines * 2 : 128;
            lines = realloc(lines, caplines * sizeof *lines);
        }
        lines[nlines++] = strdup(buf);
    }
    pclose(p);
}

/* text at (y, x), at most `cols` columns, cut on a character */
static void put(int y, int x, const char *s, int cols)
{
    wchar_t w[512];
    size_t n = mbstowcs(w, s, 511);
    if (n == (size_t)-1) {
        mvaddnstr(y, x, s, cols);
        return;
    }
    if ((int)n > cols)
        n = cols;
    mvaddnwstr(y, x, w, (int)n);
}

static int pair_for(const char *active)
{
    if (!strcmp(active, "failed"))
        return 1;
    if (!strcmp(active, "active"))
        return 2;
    if (!strcmp(active, "activating") || !strcmp(active, "deactivating") || !strcmp(active, "reloading"))
        return 3;
    return 4;
}

static char message[256];

static void say(const char *fmt, const char *a, const char *b)
{
    snprintf(message, sizeof message, fmt, a, b);
}

/* run `systemctl VERB UNIT`; the message is its outcome */
static void act(const char *verb, const char *unit)
{
    char cmd[512], buf[512] = "";
    FILE *p;
    int rc;
    snprintf(cmd, sizeof cmd, "systemctl %s '%s' 2>&1", verb, unit);
    p = popen(cmd, "r");
    if (!p) {
        say("cannot run systemctl", "", "");
        return;
    }
    if (fgets(buf, sizeof buf, p))
        buf[strcspn(buf, "\n")] = 0;
    rc = pclose(p);
    if (rc == 0)
        say("%s: %s done", unit, verb);
    else if (geteuid() != 0)
        say("%s: %s failed - changing units takes root (sudo nixith services)", unit, verb);
    else
        say("%s", buf[0] ? buf : "the command failed", "");
}

static int ask(const char *what)
{
    int h, w, c;
    getmaxyx(stdscr, h, w);
    (void)w;
    move(h - 1, 0);
    clrtoeol();
    attron(A_REVERSE);
    printw(" %s (y/N) ", what);
    attroff(A_REVERSE);
    refresh();
    timeout(-1);
    c = getch();
    timeout(1000);
    return c == 'y' || c == 'Y';
}

/* the status (or why) of a unit, scrollable */
static void detail(const char *unit)
{
    char cmd[512];
    int top = 0, why = 0, reload = 1;
    for (;;) {
        int h, w, c;
        if (reload) {
            if (why)
                snprintf(cmd, sizeof cmd, "NO_COLOR=1 nixith why '%s' 2>&1", unit);
            else
                snprintf(cmd, sizeof cmd, "systemctl status --lines=60 '%s' 2>&1", unit);
            run_text(cmd);
            reload = 0;
        }
        getmaxyx(stdscr, h, w);
        erase();
        attron(A_REVERSE);
        mvhline(0, 0, ' ', w);
        mvprintw(0, 1, "%s - %s", unit, why ? "why" : "status");
        attroff(A_REVERSE);
        if (top > nlines - (h - 2))
            top = nlines - (h - 2);
        if (top < 0)
            top = 0;
        for (int i = 0; i < h - 2 && top + i < nlines; i++)
            put(1 + i, 0, lines[top + i], w);
        attron(A_REVERSE);
        mvhline(h - 1, 0, ' ', w);
        mvprintw(h - 1, 1, "%s", message[0] ? message : "arrows scroll  w why/status  s start  x stop  r restart  g reread  q back");
        attroff(A_REVERSE);
        refresh();
        c = getch();
        message[0] = 0;
        switch (c) {
        case ERR: break;
        case 'q': case 27: case '\n': case KEY_ENTER: case KEY_LEFT: return;
        case KEY_UP: case 'k': top--; break;
        case KEY_DOWN: case 'j': top++; break;
        case KEY_PPAGE: top -= h - 3; break;
        case KEY_NPAGE: case ' ': top += h - 3; break;
        case KEY_HOME: top = 0; break;
        case KEY_END: top = nlines; break;
        case 'w': why = !why; top = 0; reload = 1; break;
        case 'g': reload = 1; break;
        case 's': act("start", unit); reload = 1; break;
        case 'x': if (ask("stop it?")) { act("stop", unit); reload = 1; } break;
        case 'r': if (ask("restart it?")) { act("restart", unit); reload = 1; } break;
        }
    }
}

static void draw(int sel, int top, int editing)
{
    int h, w, nfailed = 0;
    getmaxyx(stdscr, h, w);
    erase();
    for (int i = 0; i < nunits; i++)
        if (!strcmp(units[i].active, "failed"))
            nfailed++;
    attron(A_REVERSE);
    mvhline(0, 0, ' ', w);
    mvprintw(0, 1, "nixith services   %d units, %d failed   show: %s   filter: %s%s", nunits, nfailed,
             mode_name[state_mode], name_filter, editing ? "_" : "");
    attroff(A_REVERSE);
    attron(A_DIM);
    mvprintw(1, 1, "%-40s %-11s %-10s %s", "UNIT", "ACTIVE", "SUB", "DESCRIPTION");
    attroff(A_DIM);
    for (int i = 0; i < h - 3 && top + i < nview; i++) {
        struct unit *u = &units[view[top + i]];
        int y = 2 + i, pair = pair_for(u->active);
        char row[64];
        if (top + i == sel)
            attron(A_REVERSE);
        mvhline(y, 0, ' ', w);
        snprintf(row, sizeof row, "%.40s", u->name);
        mvprintw(y, 1, "%-40s", row);
        if (top + i != sel)
            attron(COLOR_PAIR(pair));
        mvprintw(y, 42, "%-11.11s %-10.10s", u->active, u->sub);
        if (top + i != sel)
            attroff(COLOR_PAIR(pair));
        if (w > 66)
            put(y, 65, u->desc, w - 66);
        if (top + i == sel)
            attroff(A_REVERSE);
    }
    attron(A_REVERSE);
    mvhline(h - 1, 0, ' ', w);
    if (message[0])
        mvprintw(h - 1, 1, "%.*s", w - 2, message);
    else if (editing)
        mvprintw(h - 1, 1, "type the filter; Enter keeps it, Esc clears it");
    else
        mvprintw(h - 1, 1, "Enter status  / filter  f show  s start  x stop  r restart  R reread  q quit");
    attroff(A_REVERSE);
    refresh();
}

static void tui(void)
{
    int sel = 0, top = 0, editing = 0;
    time_t last = 0;
    char keep[NAME_MAX_] = "";

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    if (has_colors()) {
        start_color();
        use_default_colors();
        init_pair(1, COLOR_RED, -1);
        init_pair(2, COLOR_GREEN, -1);
        init_pair(3, COLOR_YELLOW, -1);
        init_pair(4, COLOR_BLUE, -1);
    }
    timeout(1000);

    for (;;) {
        int h, w, c;
        getmaxyx(stdscr, h, w);
        (void)w;
        if (time(NULL) - last >= 3 && !editing) {
            if (sel < nview)
                snprintf(keep, sizeof keep, "%s", units[view[sel]].name);
            load_units();
            qsort(units, nunits, sizeof *units, cmp_units);
            apply_filter();
            for (int i = 0; i < nview && keep[0]; i++)
                if (!strcmp(units[view[i]].name, keep)) {
                    sel = i;
                    break;
                }
            last = time(NULL);
        }
        if (sel >= nview)
            sel = nview - 1;
        if (sel < 0)
            sel = 0;
        if (sel < top)
            top = sel;
        if (sel >= top + h - 3)
            top = sel - (h - 3) + 1;
        if (top < 0)
            top = 0;
        draw(sel, top, editing);
        c = getch();
        if (c == ERR)
            continue;
        message[0] = 0;
        if (editing) {
            size_t n = strlen(name_filter);
            if (c == '\n' || c == KEY_ENTER)
                editing = 0;
            else if (c == 27) {
                name_filter[0] = 0;
                editing = 0;
            } else if ((c == KEY_BACKSPACE || c == 127 || c == 8) && n)
                name_filter[n - 1] = 0;
            else if (c >= 32 && c < 127 && n < sizeof name_filter - 1) {
                name_filter[n] = c;
                name_filter[n + 1] = 0;
            }
            apply_filter();
            sel = top = 0;
            keep[0] = 0;
            continue;
        }
        switch (c) {
        case 'q': case 27: endwin(); return;
        case KEY_UP: case 'k': sel--; break;
        case KEY_DOWN: case 'j': sel++; break;
        case KEY_PPAGE: sel -= h - 3; break;
        case KEY_NPAGE: sel += h - 3; break;
        case KEY_HOME: case 'g': sel = 0; break;
        case KEY_END: case 'G': sel = nview - 1; break;
        case '/': editing = 1; break;
        case 'f': state_mode = (state_mode + 1) % 4; apply_filter(); sel = top = 0; break;
        case 'R': last = 0; break;
        case '\n': case KEY_ENTER: case KEY_RIGHT:
            if (nview) {
                detail(units[view[sel]].name);
                last = 0;
            }
            break;
        case 's':
            if (nview) { act("start", units[view[sel]].name); last = 0; }
            break;
        case 'x':
            if (nview && ask("stop it?")) { act("stop", units[view[sel]].name); last = 0; }
            break;
        case 'r':
            if (nview && ask("restart it?")) { act("restart", units[view[sel]].name); last = 0; }
            break;
        }
        if (nview && sel >= 0 && sel < nview)
            snprintf(keep, sizeof keep, "%s", units[view[sel]].name);
    }
}

int main(int argc, char **argv)
{
    int plain = 0;
    setlocale(LC_ALL, "");
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--list") || !strcmp(argv[i], "-l"))
            plain = 1;
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            puts("Usage: nixith services [--list] [FILTER]\n"
                 "The units of the running system: / filter, Enter status and log,\n"
                 "s start, x stop, r restart, w why, f show all/active/failed/inactive, q quit.");
            return 0;
        } else
            snprintf(name_filter, sizeof name_filter, "%s", argv[i]);
    }
    if (plain || !isatty(0) || !isatty(1)) {
        list_plain();
        return 0;
    }
    tui();
    return 0;
}

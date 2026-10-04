#define _GNU_SOURCE
#include "api.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* Record sizes written by ledger.cob (see its header comment). */
#define LEN_DETAIL 74 /* M and Y */
#define LEN_TRAILER 67
#define LINE_BUF 256
#define REL_EXE "/bin/legacy_app"
#define REL_BIN "/bin"
#define REL_DAT "/data/store/cobol/cb_data.dat"

/* ---------------------------------------------------------------- misc */

const char *lg_version(void) { return "1.0.0"; }

const char *lg_strerror(int status)
{
    switch (status) {
    case LG_OK:                 return "ok";
    case LG_ERR_COBOL_INPUT:    return "legacy_app: cannot open input CSV";
    case LG_ERR_COBOL_OUTPUT:   return "legacy_app: cannot write output .dat";
    case LG_WARN_REJECTED:      return "done, some input lines were rejected";
    case LG_ERR_COBOL_OVERFLOW: return "legacy_app: amount overflow";
    case LG_ERR_NOT_FOUND:      return "legacy_app not found";
    case LG_ERR_SPAWN:          return "cannot start legacy_app";
    case LG_ERR_SIGNAL:         return "legacy_app killed by a signal";
    case LG_ERR_DATA:           return "output .dat missing or invalid";
    case LG_ERR_ARG:            return "invalid argument";
    case LG_ERR_CAPACITY:       return "output array too small";
    case LG_ERR_HOME:           return "cannot determine legacy home";
    case LG_ERR_UNEXPECTED:     return "unexpected exit code from legacy_app";
    default:                    return "unknown status";
    }
}

int lg_format_cents(int64_t cents, char *buf, size_t size)
{
    if (!buf)
        return LG_ERR_ARG;
    uint64_t mag = cents < 0 ? 0 - (uint64_t)cents : (uint64_t)cents;
    int n = snprintf(buf, size, "%s%llu.%02llu", cents < 0 ? "-" : "",
                     (unsigned long long)(mag / 100),
                     (unsigned long long)(mag % 100));
    return (n < 0 || (size_t)n >= size) ? LG_ERR_ARG : LG_OK;
}

/* ---------------------------------------------------------- home path */

static const char anchor = 0; /* data address inside this library */

/* <home> = $LEGACY_HOME, else dirname(dirname(path of this library)). */
int lg_home(char *buf, size_t size)
{
    char tmp[PATH_MAX];
    const char *env = getenv("LEGACY_HOME");

    if (!buf || size == 0)
        return LG_ERR_ARG;

    if (env && *env) {
        if (!realpath(env, tmp))
            return LG_ERR_HOME;
    } else {
        Dl_info info;
        char lib[PATH_MAX];
        if (!dladdr(&anchor, &info) || !info.dli_fname ||
            !realpath(info.dli_fname, lib))
            return LG_ERR_HOME;
        for (int i = 0; i < 2; i++) { /* strip file, then its folder */
            char *slash = strrchr(lib, '/');
            if (!slash)
                return LG_ERR_HOME;
            *slash = '\0';
        }
        snprintf(tmp, sizeof tmp, "%s", lib[0] ? lib : "/");
    }
    int n = snprintf(buf, size, "%s", tmp);
    return (n < 0 || (size_t)n >= size) ? LG_ERR_HOME : LG_OK;
}

static int build_path(const char *home, const char *rel, char *out, size_t size)
{
    int n = snprintf(out, size, "%s%s", home, rel);
    return (n < 0 || (size_t)n >= size) ? LG_ERR_HOME : LG_OK;
}

/* ------------------------------------------------------------ lg_run */

int lg_run(char *log, size_t log_size)
{
    char home[PATH_MAX], exe[PATH_MAX], bindir[PATH_MAX];
    int rc;

    if ((rc = lg_home(home, sizeof home)) != LG_OK ||
        (rc = build_path(home, REL_EXE, exe, sizeof exe)) != LG_OK ||
        (rc = build_path(home, REL_BIN, bindir, sizeof bindir)) != LG_OK)
        return rc;
    if (access(exe, X_OK) != 0)
        return LG_ERR_NOT_FOUND;
    if (log && log_size)
        log[0] = '\0';

    int pfd[2];
    if (pipe2(pfd, O_CLOEXEC) != 0)
        return LG_ERR_SPAWN;

    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]);
        close(pfd[1]);
        return LG_ERR_SPAWN;
    }
    if (pid == 0) { /* child: async-signal-safe calls only */
        int nul = open("/dev/null", O_RDONLY);
        char *argv[] = {"legacy_app", NULL};
        if (nul < 0 || dup2(nul, STDIN_FILENO) < 0 ||
            dup2(pfd[1], STDOUT_FILENO) < 0 ||
            dup2(pfd[1], STDERR_FILENO) < 0 || chdir(bindir) != 0)
            _exit(127);
        execv(exe, argv);
        _exit(127);
    }

    close(pfd[1]);
    size_t used = 0;
    char chunk[512];
    ssize_t r;
    while ((r = read(pfd[0], chunk, sizeof chunk)) != 0) {
        if (r < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (log && log_size && used + 1 < log_size) { /* keep draining */
            size_t room = log_size - 1 - used;
            size_t take = (size_t)r < room ? (size_t)r : room;
            memcpy(log + used, chunk, take);
            used += take;
        }
    }
    close(pfd[0]);
    if (log && log_size)
        log[used] = '\0';

    int st;
    while (waitpid(pid, &st, 0) < 0)
        if (errno != EINTR)
            return LG_ERR_SPAWN;
    if (WIFSIGNALED(st))
        return LG_ERR_SIGNAL;
    int code = WEXITSTATUS(st);
    if (code == 127)
        return LG_ERR_SPAWN;
    if (code > LG_ERR_COBOL_OVERFLOW)
        return LG_ERR_UNEXPECTED;
    return code;
}

/* ----------------------------------------------------------- lg_load */

/* Fixed-width field readers; return 0 on success, -1 on bad content. */
static int get_uint(const char *s, size_t off, size_t len, int32_t *v)
{
    int64_t acc = 0;
    for (size_t i = 0; i < len; i++) {
        char c = s[off + i];
        if (c < '0' || c > '9')
            return -1;
        acc = acc * 10 + (c - '0');
    }
    *v = (int32_t)acc; /* at most 7 digits in this layout */
    return 0;
}

/* PIC -9(11).99 : sign(1) 11 digits '.' 2 digits = 15 bytes */
static int get_money(const char *s, size_t off, int64_t *v)
{
    const char *p = s + off;
    int64_t acc = 0;
    if ((p[0] != ' ' && p[0] != '-') || p[12] != '.')
        return -1;
    for (int i = 1; i <= 14; i++) {
        if (i == 12)
            continue;
        if (p[i] < '0' || p[i] > '9')
            return -1;
        acc = acc * 10 + (p[i] - '0');
    }
    *v = (p[0] == '-') ? -acc : acc;
    return 0;
}

static int parse_detail(const char *s, lg_record *r)
{
    memset(r, 0, sizeof *r);
    r->kind = s[0];
    if (get_uint(s, 1, 4, &r->year) || get_uint(s, 5, 2, &r->month) ||
        get_money(s, 7, &r->debit_cents) ||
        get_money(s, 22, &r->credit_cents) ||
        get_money(s, 37, &r->balance_cents) ||
        get_money(s, 52, &r->cumulative_cents) ||
        get_uint(s, 67, 7, &r->entries))
        return -1;
    if (r->debit_cents - r->credit_cents != r->balance_cents)
        return -1;
    return 0;
}

static int parse_trailer(const char *s, lg_summary *t)
{
    memset(t, 0, sizeof *t);
    if (get_uint(s, 1, 7, &t->lines_read) ||
        get_uint(s, 8, 7, &t->lines_accepted) ||
        get_uint(s, 15, 7, &t->lines_rejected) ||
        get_money(s, 22, &t->debit_cents) ||
        get_money(s, 37, &t->credit_cents) ||
        get_money(s, 52, &t->balance_cents))
        return -1;
    return 0;
}

int lg_load(lg_record *out, size_t max, size_t *count, lg_summary *summary)
{
    char home[PATH_MAX], path[PATH_MAX], line[LINE_BUF];
    size_t n = 0;
    int rc;

    if (!count || !summary || (!out && max))
        return LG_ERR_ARG;
    *count = 0;
    memset(summary, 0, sizeof *summary);
    if ((rc = lg_home(home, sizeof home)) != LG_OK ||
        (rc = build_path(home, REL_DAT, path, sizeof path)) != LG_OK)
        return rc;

    FILE *f = fopen(path, "r");
    if (!f)
        return LG_ERR_DATA;

    int have_trailer = 0;
    int64_t month_entries = 0;
    rc = LG_OK;
    while (rc == LG_OK && fgets(line, sizeof line, f)) {
        size_t len = strcspn(line, "\r\n");
        if (line[len] == '\0' && !feof(f)) { /* line longer than buffer */
            rc = LG_ERR_DATA;
            break;
        }
        line[len] = '\0';
        if (len == 0)
            continue;
        if (have_trailer) { /* nothing may follow the trailer */
            rc = LG_ERR_DATA;
            break;
        }
        if ((line[0] == 'M' || line[0] == 'Y') && len == LEN_DETAIL) {
            if (n >= max) {
                rc = LG_ERR_CAPACITY;
                break;
            }
            if (parse_detail(line, &out[n]) != 0) {
                rc = LG_ERR_DATA;
                break;
            }
            if (line[0] == 'M')
                month_entries += out[n].entries;
            n++;
        } else if (line[0] == 'T' && len == LEN_TRAILER) {
            if (parse_trailer(line, summary) != 0) {
                rc = LG_ERR_DATA;
                break;
            }
            have_trailer = 1;
        } else {
            rc = LG_ERR_DATA;
        }
    }
    fclose(f);
    *count = n;

    if (rc == LG_OK && (!have_trailer ||
                        month_entries != summary->lines_accepted))
        rc = LG_ERR_DATA; /* truncated file, or totals do not agree */
    return rc;
}

/* -------------------------------------------------------- lg_process */

int lg_process(lg_record *out, size_t max, size_t *count,
               lg_summary *summary, char *log, size_t log_size)
{
    if (!count || !summary)
        return LG_ERR_ARG;
    *count = 0;
    int run = lg_run(log, log_size);
    if (run != LG_OK && run != LG_WARN_REJECTED)
        return run;
    int load = lg_load(out, max, count, summary);
    return load != LG_OK ? load : run;
}

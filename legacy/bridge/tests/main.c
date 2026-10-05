/*
 * c_api_test - drives legacy_app through lib_c_api.
 *
 * Part 1 runs on the real tree (shipped sample data).
 * Part 2 copies bin/lib/data to a temp dir and points LEGACY_HOME at it,
 * so error scenarios never touch the real data. As a side effect this
 * also proves the tree works after being moved.
 */
#define _GNU_SOURCE
#include "api.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ------------------------------------------------------------ global */
static int g_checks, g_failed;

/* ------------------------------------------------------------ helper */
#define CHECK(cond, msg)                                             \
    do {                                                             \
        g_checks++;                                                  \
        if (!(cond)) {                                               \
            g_failed++;                                              \
            printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, (msg)); \
        }                                                            \
    } while (0)

#define MAXREC 64

static void write_file(const char* path, const char* text)
{
    FILE* f = fopen(path, "w");
    if (f) {
        fputs(text, f);
        fclose(f);
    }
}

static void print_report(const lg_record* r, size_t n, const lg_summary* s)
{
    char d[32], c[32], b[32], u[32];
    printf("  K %-7s %14s %14s %14s %14s %4s\n", "period", "debit", "credit",
        "balance", "cumulative", "n");
    for (size_t i = 0; i < n; i++) {
        lg_format_cents(r[i].debit_cents, d, sizeof d);
        lg_format_cents(r[i].credit_cents, c, sizeof c);
        lg_format_cents(r[i].balance_cents, b, sizeof b);
        lg_format_cents(r[i].cumulative_cents, u, sizeof u);
        printf("  %c %04d-%02d %14s %14s %14s %14s %4d\n", r[i].kind,
            r[i].year, r[i].month, d, c, b, u, r[i].entries);
    }
    printf("  read=%d accepted=%d rejected=%d\n", s->lines_read,
        s->lines_accepted, s->lines_rejected);
}

/* ------------------------------------------------------------ main */
static void test_real_tree(void);
static void test_scenarios(void);

int main(void)
{
    test_real_tree();
    test_scenarios();
    printf("\n%d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}

/* ------------------------------------------------------------ part 1 */

static void test_real_tree(void)
{
    lg_record rec[MAXREC];
    lg_summary sum;
    size_t n = 0;
    char home[PATH_MAX], log[1024];

    puts("[1] real tree, sample data");
    unsetenv("LEGACY_HOME");
    CHECK(lg_home(home, sizeof home) == LG_OK, "lg_home");
    printf("  home = %s (lib %s)\n", home, lg_version());

    int rc = lg_process(rec, MAXREC, &n, &sum, log, sizeof log);
    CHECK(rc == LG_OK, lg_strerror(rc));
    CHECK(n == 7, "7 records (5 M + 2 Y)");
    if (n == 7) {
        print_report(rec, n, &sum);
        CHECK(rec[1].kind == 'M' && rec[1].year == 2023 && rec[1].month == 12,
            "rec[1] is 2023-12");
        CHECK(rec[1].balance_cents == -48935, "Dec 2023 balance -489.35");
        CHECK(rec[1].cumulative_cents == 1031015, "Dec 2023 cumulative");
        CHECK(rec[2].kind == 'Y' && rec[2].month == 0, "rec[2] is year 2023");
        CHECK(rec[2].debit_cents == 1582075, "2023 debit 15820.75");
        CHECK(rec[2].credit_cents == 551060, "2023 credit 5510.60");
        CHECK(rec[6].kind == 'Y' && rec[6].year == 2024, "rec[6] is year 2024");
        CHECK(rec[6].cumulative_cents == 3263000, "final cumulative 32630.00");
    }
    CHECK(sum.lines_read == 10 && sum.lines_accepted == 10 && sum.lines_rejected == 0,
        "10 read / 10 accepted / 0 rejected");
    CHECK(sum.debit_cents == 4412100 && sum.credit_cents == 1149100,
        "grand totals 44121.00 / 11491.00");

    char s[32];
    CHECK(lg_format_cents(-48935, s, sizeof s) == LG_OK && strcmp(s, "-489.35") == 0,
        "format -489.35");
    CHECK(lg_format_cents(5, s, sizeof s) == LG_OK && strcmp(s, "0.05") == 0,
        "format 0.05");
}

/* ------------------------------------------------------------ part 2 */

static void test_scenarios(void)
{
    char real[PATH_MAX], tmp[] = "/tmp/legacy_test_XXXXXX";
    char empty[] = "/tmp/legacy_empty_XXXXXX";
    char cmd[PATH_MAX * 4 + 128], csv[PATH_MAX + 64], dat[PATH_MAX + 64];
    lg_record rec[MAXREC];
    lg_summary sum;
    size_t n;
    char log[1024];

    puts("[2] scenarios on a relocated copy (LEGACY_HOME)");
    unsetenv("LEGACY_HOME");
    CHECK(lg_home(real, sizeof real) == LG_OK, "lg_home");
    CHECK(mkdtemp(tmp) != NULL && mkdtemp(empty) != NULL, "mkdtemp");
    snprintf(cmd, sizeof cmd, "cp -R '%s/bin' '%s/lib' '%s/data' '%s/'", real,
        real, real, tmp);
    CHECK(system(cmd) == 0, "copy tree");
    setenv("LEGACY_HOME", tmp, 1);
    snprintf(csv, sizeof csv, "%s/data/input/cobol/cb_data.csv", tmp);
    snprintf(dat, sizeof dat, "%s/data/store/cobol/cb_data.dat", tmp);

    /* capacity: sample data needs 7 records */
    int rc = lg_process(rec, 3, &n, &sum, log, sizeof log);
    CHECK(rc == LG_ERR_CAPACITY, "capacity error with max=3");
    CHECK(n == 3, "3 records stored before the error");

    /* corrupt / truncated .dat */
    write_file(dat, "garbage\n");
    CHECK(lg_load(rec, MAXREC, &n, &sum) == LG_ERR_DATA, "garbage .dat");
    write_file(dat, "");
    CHECK(lg_load(rec, MAXREC, &n, &sum) == LG_ERR_DATA, "empty .dat");

    /* rejected lines: ok data is still delivered, status = warning */
    write_file(csv, "2024-01-10,1000,D,100.00,ok\n"
                    "2024-02-30,1000,D,50.00,bad day\n"
                    "2024-01-20,1000,C,40.25,ok\n");
    rc = lg_process(rec, MAXREC, &n, &sum, log, sizeof log);
    CHECK(rc == LG_WARN_REJECTED, lg_strerror(rc));
    CHECK(n == 2 && rec[0].balance_cents == 5975, "month 2024-01 = 59.75");
    CHECK(sum.lines_read == 3 && sum.lines_accepted == 2 && sum.lines_rejected == 1,
        "3 read / 2 accepted / 1 rejected");
    CHECK(strstr(log, "LINE 0000002 REJECTED") != NULL, "log names line 2");

    /* overflow: aborted run leaves no valid .dat */
    write_file(csv, "2024-01-01,1,D,99999999999.99,a\n"
                    "2024-01-02,1,D,1.00,b\n");
    rc = lg_process(rec, MAXREC, &n, &sum, log, sizeof log);
    CHECK(rc == LG_ERR_COBOL_OVERFLOW, lg_strerror(rc));
    CHECK(n == 0, "nothing loaded after overflow");
    CHECK(lg_load(rec, MAXREC, &n, &sum) == LG_ERR_DATA,
        "partial .dat is refused (no trailer)");

    /* missing input: stale .dat must not be loaded */
    unlink(csv);
    rc = lg_process(rec, MAXREC, &n, &sum, log, sizeof log);
    CHECK(rc == LG_ERR_COBOL_INPUT, lg_strerror(rc));
    CHECK(n == 0, "nothing loaded when input is missing");

    /* wrong home */
    setenv("LEGACY_HOME", empty, 1);
    CHECK(lg_run(NULL, 0) == LG_ERR_NOT_FOUND, "no legacy_app in empty home");
    setenv("LEGACY_HOME", "/nonexistent/legacy", 1);
    CHECK(lg_run(NULL, 0) == LG_ERR_HOME, "invalid LEGACY_HOME");
    CHECK(lg_load(NULL, 0, NULL, &sum) == LG_ERR_ARG, "NULL count");

    unsetenv("LEGACY_HOME");
    snprintf(cmd, sizeof cmd, "rm -rf -- '%s' '%s'", tmp, empty);
    if (strncmp(tmp, "/tmp/legacy_test_", 17) == 0 && strncmp(empty, "/tmp/legacy_empty_", 18) == 0)
        CHECK(system(cmd) == 0, "remove temp dirs");
}

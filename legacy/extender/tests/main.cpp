// legacy/extender/tests/main.cpp
//
// Part 1  Analytics on synthetic records (no COBOL): hand-checked numbers.
// Part 2  The real tree: COBOL -> bridge -> C++ core, shipped sample data.
// Part 3  Scenarios on a COPY of the tree (LEGACY_HOME): errors, rejected
//         lines, gaps, a very deep path. The real data is never touched.
// Part 4  The C ABI (lgx_*) must agree with the C++ core, byte for byte.

#include "extender.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits.h>
#include <string>
#include <unistd.h>
#include <utility>
#include <vector>

using namespace Legacy;
using std::int64_t;

static int g_checks;
static int g_failed;

#define CHECK(cond, msg)                                                  \
    do {                                                                  \
        ++g_checks;                                                       \
        if (!(cond)) {                                                    \
            ++g_failed;                                                   \
            std::printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, (msg)); \
        }                                                                 \
    } while (0)

static auto money(int64_t cents) -> std::string
{
    auto s = LedgerClient::format_cents(cents);
    return s ? *s : "ERR";
}

// ---------------------------------------------------------- synthetic data

static auto month_rec(int y, int m, int64_t d, int64_t c, int64_t cum, int e) -> Record
{
    Record r {};
    r.kind = 'M';
    r.year = y;
    r.month = m;
    r.debit_cents = d;
    r.credit_cents = c;
    r.balance_cents = d - c;
    r.cumulative_cents = cum;
    r.entries = e;
    return r;
}

static auto year_rec(int y, int64_t d, int64_t c, int64_t cum, int e) -> Record
{
    Record r {};
    r.kind = 'Y';
    r.year = y;
    r.debit_cents = d;
    r.credit_cents = c;
    r.balance_cents = d - c;
    r.cumulative_cents = cum;
    r.entries = e;
    return r;
}

static auto trailer(int64_t d, int64_t c, int64_t bal, int read, int acc, int rej) -> Summary
{
    Summary t {};
    t.debit_cents = d;
    t.credit_cents = c;
    t.balance_cents = bal;
    t.lines_read = read;
    t.lines_accepted = acc;
    t.lines_rejected = rej;
    return t;
}

// 2023-11, 2023-12, [2024-01 has no entries], 2024-02
static auto sample_records() -> std::vector<Record>
{
    return {
        month_rec(2023, 11, 100000, 40000, 60000, 2),
        month_rec(2023, 12, 20000, 50000, 30000, 2),
        year_rec(2023, 120000, 90000, 30000, 4),
        month_rec(2024, 2, 90000, 0, 120000, 1),
        year_rec(2024, 90000, 0, 120000, 1),
    };
}

static void test_analytics()
{
    std::puts("[1] analytics on synthetic data");
    const auto recs = sample_records();
    const Summary t = trailer(210000, 90000, 120000, 5, 5, 0);

    auto months = Analytics::monthly_series(recs, t, 3);
    CHECK(months.has_value(), "series builds");
    if (months) {
        const auto& s = *months;
        CHECK(s.size() == 4, "4 calendar months (January filled in)");
        if (s.size() == 4) {
            CHECK(s[2].year == 2024 && s[2].month == 1 && s[2].entries == 0, "gap month is 2024-01, no entries");
            CHECK(s[2].cumulative_cents == 30000 && s[2].balance_cents == 0, "gap month carries the balance");
            CHECK(s[0].moving_avg_cents == 60000 && s[0].window_used == 1, "ma[0]");
            CHECK(s[1].moving_avg_cents == 15000 && s[1].window_used == 2, "ma[1] = (60000-30000)/2");
            CHECK(s[2].moving_avg_cents == 10000 && s[2].window_used == 3, "ma[2] = 30000/3");
            CHECK(s[3].moving_avg_cents == 20000, "ma[3] = (-30000+0+90000)/3");
            CHECK(!s[0].growth_valid, "no growth for the first month");
            CHECK(s[1].growth_valid && s[1].growth_bp == -5000, "Dec: -50.00%");
            CHECK(s[2].growth_valid && s[2].growth_bp == 0, "Jan: 0 bp");
            CHECK(s[3].growth_valid && s[3].growth_bp == 30000, "Feb: +300.00%");
        }

        auto years = Analytics::yearly_report(s, recs);
        CHECK(years.has_value() && years->size() == 2, "2 years");
        if (years && years->size() == 2) {
            const Year& y3 = (*years)[0];
            const Year& y4 = (*years)[1];
            CHECK(y3.year == 2023 && y3.months == 2 && y3.entries == 4, "2023 shape");
            CHECK(y3.balance_cents == 30000 && y3.avg_monthly_cents == 15000, "2023 balance / average");
            CHECK(!y3.growth_valid, "no growth for the first year");
            CHECK(y4.year == 2024 && y4.months == 2 && y4.entries == 1, "2024 shape (Jan counts)");
            CHECK(y4.balance_cents == 90000 && y4.avg_monthly_cents == 45000, "2024 balance / average");
            CHECK(y4.growth_valid && y4.growth_bp == 20000, "2024 vs 2023: +200.00%");
            CHECK(y4.cumulative_cents == 120000, "2024 running balance");
        }

        auto stats = Analytics::summarize(s, t);
        CHECK(stats.has_value(), "summary builds");
        if (stats) {
            CHECK(stats->months == 4 && stats->active_months == 3, "4 months, 3 active");
            CHECK(stats->avg_monthly_cents == 30000, "average 120000/4");
            CHECK(stats->best_cents == 90000 && stats->best_year == 2024 && stats->best_month == 2, "best month");
            CHECK(stats->worst_cents == -30000 && stats->worst_year == 2023 && stats->worst_month == 12, "worst month");
            CHECK(stats->balance_cents == 120000 && stats->lines_accepted == 5, "totals from the trailer");
        }

        auto p3 = Analytics::project(s, 3, 3);
        CHECK(p3.has_value() && p3->size() == 3, "3 projected months");
        if (p3 && p3->size() == 3) {
            CHECK((*p3)[0].balance_cents == 20000, "basis 3: (-30000+0+90000)/3");
            CHECK((*p3)[0].year == 2024 && (*p3)[0].month == 3, "first projected month is 2024-03");
            CHECK((*p3)[0].cumulative_cents == 140000 && (*p3)[2].cumulative_cents == 180000, "cumulative grows");
        }
        auto p2 = Analytics::project(s, 2, 1);
        CHECK(p2 && (*p2)[0].balance_cents == 45000 && (*p2)[0].cumulative_cents == 165000, "basis 2");
        auto pall = Analytics::project(s, 10, 1);
        CHECK(pall && (*pall)[0].balance_cents == 30000, "basis larger than the series uses all months");
        auto pyear = Analytics::project(s, 3, 11);
        CHECK(pyear && pyear->back().year == 2025 && pyear->back().month == 1, "projection rolls over the year");
    }

    // rounding: half away from zero, in both directions
    auto g = Analytics::growth_bp(3, 4);
    CHECK(g && *g == 3333, "10000/3 -> 3333");
    g = Analytics::growth_bp(20000, 20001);
    CHECK(g && *g == 1, "0.5 rounds away from zero -> 1");
    g = Analytics::growth_bp(20000, 19999);
    CHECK(g && *g == -1, "-0.5 rounds away from zero -> -1");
    g = Analytics::growth_bp(-20000, -19999);
    CHECK(g && *g == 1, "negative base: improvement is positive");
    g = Analytics::growth_bp(-3, -4);
    CHECK(g && *g == -3333, "negative base, worse");

    // errors
    g = Analytics::growth_bp(0, 5);
    CHECK(!g && g.error().code == StatusCode::OutOfRange, "growth from zero");
    g = Analytics::growth_bp(1, INT64_MAX);
    CHECK(!g && g.error().code == StatusCode::ArithmeticOverflow, "growth overflow");
    g = Analytics::growth_bp(INT64_MIN, 0);
    CHECK(!g && g.error().code == StatusCode::ArithmeticOverflow, "INT64_MIN base");

    auto none = Analytics::monthly_series({}, trailer(0, 0, 0, 0, 0, 0), 3);
    CHECK(!none && none.error().code == StatusCode::NoData, "empty ledger -> NoData");
    auto w0 = Analytics::monthly_series(recs, t, 0);
    CHECK(!w0 && w0.error().code == StatusCode::OutOfRange, "window 0");
    auto w121 = Analytics::monthly_series(recs, t, 121);
    CHECK(!w121 && w121.error().code == StatusCode::OutOfRange, "window 121");

    auto bad = sample_records();
    bad[1].cumulative_cents = 31000; // running balance no longer adds up
    auto r = Analytics::monthly_series(bad, t, 3);
    CHECK(!r && r.error().code == StatusCode::DataError, "wrong running balance is detected");

    bad = sample_records();
    std::swap(bad[0], bad[1]); // months out of order
    r = Analytics::monthly_series(bad, t, 3);
    CHECK(!r && r.error().code == StatusCode::DataError, "months out of order");

    r = Analytics::monthly_series(recs, trailer(999, 90000, 120000, 5, 5, 0), 3);
    CHECK(!r && r.error().code == StatusCode::DataError, "totals differ from the trailer");

    bad = sample_records();
    bad[2].debit_cents = 1; // the COBOL yearly record disagrees with the months
    auto ok_series = Analytics::monthly_series(bad, t, 3);
    CHECK(ok_series.has_value(), "monthly data is still consistent");
    if (ok_series) {
        auto y = Analytics::yearly_report(*ok_series, bad);
        CHECK(!y && y.error().code == StatusCode::DataError, "yearly record mismatch is detected");
    }
    auto pr = Analytics::project(*Analytics::monthly_series(recs, t, 3), 0, 3);
    CHECK(!pr && pr.error().code == StatusCode::OutOfRange, "basis 0");
}

// ------------------------------------------------------------- real tree

static void test_real_tree()
{
    std::puts("[2] real tree: COBOL -> bridge -> C++ core");
    unsetenv("LEGACY_HOME");

    auto home = LedgerClient::get_home();
    CHECK(home.has_value(), "get_home");
    if (home) {
        std::printf("  home = %s | bridge %s | extender %s\n", home->c_str(),
            LedgerClient::version().c_str(), extender_version().c_str());
    }

    auto ledger = LedgerClient::process();
    CHECK(ledger.has_value(), "process()");
    if (!ledger) {
        std::printf("  %s (%s)\n", ledger.error().message.c_str(), ledger.error().detail.c_str());
        return;
    }
    CHECK(ledger->records.size() == 7, "5 M + 2 Y records");
    CHECK(ledger->status == StatusCode::Ok, "no rejected lines");
    CHECK(ledger->log.find("ACCEPTED=0000010") != std::string::npos, "the cobol_app log is kept");
    CHECK(ledger->summary.lines_accepted == 10 && ledger->summary.balance_cents == 3263000, "trailer");

    auto small = LedgerClient::load_data(1); // starts with room for one record
    CHECK(small && small->records.size() == 7, "record array grows by itself");

    auto report = Analytics::analyze(*ledger, 3);
    CHECK(report.has_value(), "analyze()");
    if (!report) {
        return;
    }
    CHECK(report->months.size() == 5, "5 months, no gaps");
    CHECK(report->stats.avg_monthly_cents == 652600, "average monthly balance 6526.00");
    CHECK(report->stats.best_cents == 1101960 && report->stats.best_year == 2024 && report->stats.best_month == 3, "best: 2024-03");
    CHECK(report->stats.worst_cents == -48935 && report->stats.worst_month == 12, "worst: 2023-12");
    CHECK(report->months[1].growth_bp == -453, "Dec 2023 running balance: -4.53%");
    CHECK(report->months[4].moving_avg_cents == 743995, "3-month average at 2024-03");
    CHECK(report->years.size() == 2 && report->years[1].growth_bp == 11648, "2024 vs 2023: +116.48%");

    std::puts("  month    balance   running  moving-avg  growth");
    for (const Month& m : report->months) {
        char growth[32] = "n/a";
        if (m.growth_valid) {
            std::snprintf(growth, sizeof growth, "%+.2f%%", static_cast<double>(m.growth_bp) / 100.0);
        }
        std::printf("  %04d-%02d %9s %9s %10s  %s\n", m.year, m.month, money(m.balance_cents).c_str(),
            money(m.cumulative_cents).c_str(), money(m.moving_avg_cents).c_str(), growth);
    }
}

// -------------------------------------------------- scenarios on a copy

static void write_file(const std::string& path, const char* text)
{
    if (FILE* f = std::fopen(path.c_str(), "w")) {
        std::fputs(text, f);
        std::fclose(f);
    }
}

static auto copy_tree(const std::string& from, const std::string& to) -> bool
{
    const std::string cmd = "cp -R '" + from + "/bin' '" + from + "/lib' '" + from + "/data' '" + to + "/'";
    return std::system(cmd.c_str()) == 0;
}

static void remove_tree(const std::string& dir)
{
    if (dir.rfind("/tmp/legacy_ext_", 0) == 0) { // never remove anything else
        const std::string cmd = "rm -rf -- '" + dir + "'";
        if (std::system(cmd.c_str()) != 0) {
            std::puts("  (could not remove the temporary tree)");
        }
    }
}

static void test_scenarios(const std::string& real_home)
{
    std::puts("[3] scenarios on a copy of the tree (LEGACY_HOME)");
    char tmpl[] = "/tmp/legacy_ext_XXXXXX";
    const char* made = mkdtemp(tmpl);
    CHECK(made != nullptr, "mkdtemp");
    if (!made) {
        return;
    }
    const std::string tmp = made;
    CHECK(copy_tree(real_home, tmp), "copy the tree");
    setenv("LEGACY_HOME", tmp.c_str(), 1);
    const std::string csv = tmp + "/data/input/cobol/cb_data.csv";

    // input CSV missing: exit 1 must be an ERROR, with the log as detail
    std::remove(csv.c_str());
    auto run = LedgerClient::run_app();
    CHECK(!run && run.error().code == StatusCode::CobolInputError, "missing CSV is an error, not a success");
    CHECK(!run && run.error().detail.find("CANNOT OPEN INPUT") != std::string::npos, "the log explains why");
    auto proc = LedgerClient::process();
    CHECK(!proc && proc.error().code == StatusCode::CobolInputError, "process() does not read a stale .dat");

    // amount overflow: exit 4
    write_file(csv, "2024-01-01,1,D,99999999999.99,a\n2024-01-02,1,D,1.00,b\n");
    run = LedgerClient::run_app();
    CHECK(!run && run.error().code == StatusCode::CobolOverflow, "overflow is an error");

    // rejected lines: a warning, the valid data is delivered
    write_file(csv, "2024-01-10,1,D,100.00,ok\n2024-02-30,1,D,50.00,bad day\n2024-01-20,1,C,40.25,ok\n");
    run = LedgerClient::run_app();
    CHECK(run && run->status == StatusCode::WarningRejected, "rejected lines are a warning");
    CHECK(run && run->log.find("LINE 0000002 REJECTED") != std::string::npos, "the rejection reason is kept");
    proc = LedgerClient::process();
    CHECK(proc && proc->status == StatusCode::WarningRejected && proc->summary.lines_rejected == 1, "process() reports the rejection");
    auto rep = proc ? Analytics::analyze(*proc, 3) : std::unexpected(Error::from_c(LGX_ERR_UNEXPECTED));
    CHECK(rep && rep->months.size() == 1 && rep->months[0].balance_cents == 5975, "valid lines are still analysed: 59.75");

    // gaps, through the real COBOL: Jan and Apr have entries, Feb and Mar do not
    write_file(csv, "2024-01-10,1,D,100.00,a\n2024-04-05,1,C,40.00,b\n");
    proc = LedgerClient::process();
    rep = proc ? Analytics::analyze(*proc, 3) : std::unexpected(Error::from_c(LGX_ERR_UNEXPECTED));
    CHECK(rep && rep->months.size() == 4, "calendar series has 4 months");
    if (rep && rep->months.size() == 4) {
        CHECK(rep->months[1].entries == 0 && rep->months[2].entries == 0, "Feb and Mar are filled in");
        CHECK(rep->months[1].cumulative_cents == 10000 && rep->months[3].cumulative_cents == 6000, "balance carried across the gap");
        CHECK(rep->stats.active_months == 2 && rep->stats.months == 4, "2 active of 4");
        CHECK(rep->stats.avg_monthly_cents == 1500, "average 60.00 / 4 = 15.00");
    }

    // FFI face of the same failure: error code and log text come through
    std::remove(csv.c_str());
    char log[256] = {};
    CHECK(lgx_refresh(log, sizeof log) == LGX_ERR_COBOL_INPUT, "lgx_refresh reports the COBOL error");
    CHECK(std::strstr(log, "CANNOT OPEN INPUT") != nullptr, "lgx_refresh fills the log on error");

    // wrong homes
    char empty[] = "/tmp/legacy_ext_XXXXXX";
    const char* e = mkdtemp(empty);
    if (e) {
        setenv("LEGACY_HOME", e, 1);
        auto r = LedgerClient::run_app();
        CHECK(!r && r.error().code == StatusCode::NotFound, "no cobol_app in an empty home");
        remove_tree(e);
    }
    setenv("LEGACY_HOME", "/nonexistent/legacy", 1);
    auto bad_home = LedgerClient::get_home();
    CHECK(!bad_home && bad_home.error().code == StatusCode::HomeError, "invalid LEGACY_HOME");

    // a tree under a very deep directory (the old 512-byte buffer failed here)
    std::string deep = tmp + "/deep";
    for (int i = 0; i < 6; ++i) {
        deep += "/" + std::string(100, 'd');
    }
    const std::string mk = "mkdir -p '" + deep + "'";
    CHECK(std::system(mk.c_str()) == 0, "create a deep directory");
    CHECK(copy_tree(real_home, deep), "copy the tree into it");
    write_file(deep + "/data/input/cobol/cb_data.csv", "2024-01-10,1,D,100.00,ok\n");
    setenv("LEGACY_HOME", deep.c_str(), 1);
    auto dh = LedgerClient::get_home();
    CHECK(dh && dh->size() > 512, "home longer than 512 bytes is resolved");
    CHECK(LedgerClient::process().has_value(), "the pipeline runs from a deep path");

    unsetenv("LEGACY_HOME");
    remove_tree(tmp);
}

// ---------------------------------------------------------------- C ABI

template <typename T>
static auto same_bytes(const std::vector<T>& a, const std::vector<T>& b) -> bool
{
    return a.size() == b.size() && (a.empty() || std::memcmp(a.data(), b.data(), a.size() * sizeof(T)) == 0);
}

static void test_c_abi()
{
    std::puts("[4] C ABI (lgx_*) agrees with the C++ core");
    unsetenv("LEGACY_HOME");
    CHECK(std::strcmp(lgx_version(), "0.1.0") == 0, "lgx_version");
    CHECK(std::strlen(lgx_strerror(LGX_ERR_CAPACITY)) > 0 && std::strlen(lgx_strerror(-999)) > 0, "lgx_strerror is never empty");

    char log[512] = {};
    CHECK(lgx_refresh(log, sizeof log) == LGX_OK, "lgx_refresh");
    CHECK(std::strstr(log, "ACCEPTED=0000010") != nullptr, "refresh log");

    auto ledger = LedgerClient::load_data();
    auto expect = ledger ? Analytics::analyze(*ledger, 3) : std::unexpected(Error::from_c(LGX_ERR_UNEXPECTED));
    CHECK(expect.has_value(), "reference report");
    if (!expect) {
        return;
    }

    // sizing protocol: max = 0 returns CAPACITY and the required length
    std::size_t n = 0;
    CHECK(lgx_monthly_series(3, nullptr, 0, &n) == LGX_ERR_CAPACITY && n == 5, "size query: 5 months");
    std::vector<lgx_month> months(n);
    CHECK(lgx_monthly_series(3, months.data(), months.size(), &n) == LGX_OK && n == 5, "monthly series");
    CHECK(same_bytes(months, expect->months), "monthly series == C++ core, byte for byte");

    std::vector<lgx_year> years(2);
    CHECK(lgx_yearly_report(years.data(), years.size(), &n) == LGX_OK && n == 2, "yearly report");
    CHECK(same_bytes(years, expect->years), "yearly report == C++ core");

    lgx_summary s {};
    CHECK(lgx_ledger_summary(&s) == LGX_OK && std::memcmp(&s, &expect->stats, sizeof s) == 0, "summary == C++ core");

    std::vector<lgx_projection> proj(3);
    CHECK(lgx_project(3, 3, proj.data(), proj.size(), &n) == LGX_OK && n == 3, "projection");
    auto cpp_proj = Analytics::project(expect->months, 3, 3);
    CHECK(cpp_proj && same_bytes(proj, *cpp_proj), "projection == C++ core");

    char buf[64] = {};
    CHECK(lgx_home(buf, sizeof buf) == LGX_OK || lgx_home(buf, sizeof buf) == LGX_ERR_CAPACITY, "lgx_home");

    int64_t bp = 0;
    CHECK(lgx_growth_bp(20000, 20001, &bp) == LGX_OK && bp == 1, "lgx_growth_bp");
    CHECK(lgx_growth_bp(0, 1, &bp) == LGX_ERR_RANGE, "growth from zero -> RANGE");
    CHECK(lgx_growth_bp(1, INT64_MAX, &bp) == LGX_ERR_OVERFLOW, "overflow -> OVERFLOW");

    // argument errors never crash
    CHECK(lgx_monthly_series(0, months.data(), months.size(), &n) == LGX_ERR_RANGE, "window 0");
    CHECK(lgx_monthly_series(3, months.data(), months.size(), nullptr) == LGX_ERR_ARG, "null count");
    CHECK(lgx_monthly_series(3, nullptr, 5, &n) == LGX_ERR_ARG, "null array with max > 0");
    CHECK(lgx_monthly_series(3, months.data(), 2, &n) == LGX_ERR_CAPACITY && n == 5, "array too small");
    CHECK(lgx_ledger_summary(nullptr) == LGX_ERR_ARG, "null summary");
    CHECK(lgx_project(0, 3, proj.data(), proj.size(), &n) == LGX_ERR_RANGE, "basis 0");
    CHECK(lgx_project(3, 999, proj.data(), proj.size(), &n) == LGX_ERR_RANGE, "horizon 999");
    CHECK(lgx_growth_bp(1, 2, nullptr) == LGX_ERR_ARG, "null out_bp");
}

int main()
{
    test_analytics();
    test_real_tree();

    unsetenv("LEGACY_HOME");
    auto home = LedgerClient::get_home();
    if (home) {
        test_scenarios(*home);
    } else {
        CHECK(false, "cannot locate the tree for the scenarios");
    }
    test_c_abi();

    std::printf("\n%d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}

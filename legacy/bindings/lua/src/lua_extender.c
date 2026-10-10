// legacy/bindings/lua/src/lua_extender.c

/*
 * Native core of the Lua bindings: a Lua 5.4 module over the C ABI of the
 * extender (lib/lib_cpp_api.so, header extender.h).
 *
 *     local core = require("lua_extender_core")
 *
 *     core.version()            -> string
 *     core.strerror(status)     -> string
 *     core.refresh()            -> status, log
 *     core.monthly_series(win)  -> status, table      (status, nil on failure)
 *
 * It does no interpretation: every function returns the raw lgx_status number
 * and the data. Turning a status into an error, formatting money, adding
 * helpers: that is binding.lua, in Lua, where it is easy to change.
 *
 * Money stays integer cents (Lua 5.4 integers are 64 bit). growth_bp is left
 * out of the month table (nil) when it is undefined.
 */

#include "extender.h" // lib_cpp_api.so

#include <lauxlib.h>
#include <lua.h>

#include <limits.h>
#include <stdint.h>

/* The module is built with hidden visibility: only luaopen_* is exported. */
#define MODULE_EXPORT __attribute__((visibility("default")))

#define LOG_SIZE 4096
#define FETCH_ATTEMPTS 3

/* ------------------------------------------------------------- helpers */

/* t[name] = value, with the table on top of the stack. */
static void set_integer(lua_State* L, const char* name, lua_Integer value)
{
    lua_pushinteger(L, value);
    lua_setfield(L, -2, name);
}

/* Pushes (status, nil): the shape of every failure. */
static int push_failure(lua_State* L, int status)
{
    lua_pushinteger(L, status);
    lua_pushnil(L);
    return 2;
}

/* Pushes one lgx_month as a table. */
static void push_month(lua_State* L, const lgx_month* m)
{
    lua_createtable(L, 0, 11);
    set_integer(L, "year", m->year);
    set_integer(L, "month", m->month);
    set_integer(L, "entries", m->entries);
    set_integer(L, "debit_cents", m->debit_cents);
    set_integer(L, "credit_cents", m->credit_cents);
    set_integer(L, "balance_cents", m->balance_cents);
    set_integer(L, "cumulative_cents", m->cumulative_cents);
    set_integer(L, "moving_avg_cents", m->moving_avg_cents);
    set_integer(L, "window_used", m->window_used);
    if (m->growth_valid) {
        set_integer(L, "growth_bp", m->growth_bp);
    }
}

/* Pushes an array table of `count` months. */
static void push_months(lua_State* L, const lgx_month* months, size_t count)
{
    lua_createtable(L, (int)count, 0);
    for (size_t i = 0; i < count; ++i) {
        push_month(L, &months[i]);
        lua_seti(L, -2, (lua_Integer)i + 1);
    }
}

/* -------------------------------------------------------- Lua functions */

static int core_version(lua_State* L)
{
    lua_pushstring(L, lgx_version());
    return 1;
}

static int core_strerror(lua_State* L)
{
    const lua_Integer status = luaL_checkinteger(L, 1);
    luaL_argcheck(L, status >= INT_MIN && status <= INT_MAX, 1, "status out of range");
    lua_pushstring(L, lgx_strerror((int)status));
    return 1;
}

static int core_refresh(lua_State* L)
{
    char log[LOG_SIZE];
    log[0] = '\0';
    const int status = lgx_refresh(log, sizeof log);

    lua_pushinteger(L, status);
    lua_pushstring(L, log);
    return 2;
}

/*
 * The sizing protocol of the C ABI: ask for the length (out = NULL, max = 0),
 * allocate, fetch. If the data grew in between the second call reports
 * CAPACITY again and we start over.
 */
static int core_monthly_series(lua_State* L)
{
    const lua_Integer window = luaL_checkinteger(L, 1);
    luaL_argcheck(L, window >= INT32_MIN && window <= INT32_MAX, 1, "window out of range");

    for (int attempt = 0; attempt < FETCH_ATTEMPTS; ++attempt) {
        size_t count = 0;
        int status = lgx_monthly_series((int32_t)window, NULL, 0, &count);
        if (status != LGX_OK && status != LGX_ERR_CAPACITY) {
            return push_failure(L, status);
        }
        if (count == 0) {
            lua_pushinteger(L, LGX_OK);
            lua_newtable(L);
            return 2;
        }
        if (count > SIZE_MAX / sizeof(lgx_month)) {
            return luaL_error(L, "monthly series too large");
        }

        /* Lua owns the buffer (userdata): if anything below raises an error
         * it is collected, never leaked. */
        lgx_month* months = lua_newuserdatauv(L, count * sizeof *months, 0);
        size_t fetched = 0;
        status = lgx_monthly_series((int32_t)window, months, count, &fetched);
        if (status == LGX_ERR_CAPACITY) {
            lua_pop(L, 1); /* grew in between: ask again */
            continue;
        }
        if (status != LGX_OK) {
            lua_pop(L, 1);
            return push_failure(L, status);
        }

        push_months(L, months, fetched);
        lua_pushinteger(L, LGX_OK);
        lua_insert(L, -2); /* status below the table: returns status, table */
        return 2;
    }
    return push_failure(L, LGX_ERR_CAPACITY);
}

/* ----------------------------------------------------------- module */

static const luaL_Reg core_functions[] = {
    { "version", core_version },
    { "strerror", core_strerror },
    { "refresh", core_refresh },
    { "monthly_series", core_monthly_series },
    { NULL, NULL },
};

/* require("lua_extender_core") looks for exactly this name. */
MODULE_EXPORT int luaopen_lua_extender_core(lua_State* L)
{
    luaL_newlib(L, core_functions);
    return 1;
}

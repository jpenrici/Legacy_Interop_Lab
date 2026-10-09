// legacy/bindings/lua/src/lua_extender.c

#include "extender.h" // lib_cpp_api.so
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <stdlib.h>

static int l_lgx_version(lua_State* L)
{
    const char* ver = lgx_version();
    lua_pushstring(L, ver);
    return 1;
}

static int l_lgx_strerror(lua_State* L)
{
    int status = (int)luaL_checkinteger(L, 1);
    const char* msg = lgx_strerror(status);
    lua_pushstring(L, msg);
    return 1;
}

static int l_lgx_refresh(lua_State* L)
{
    char log_buf[4096] = { 0 };
    int status = lgx_refresh(log_buf, sizeof(log_buf));

    lua_pushinteger(L, status);
    lua_pushstring(L, log_buf);
    return 2;
}

static int l_lgx_monthly_series(lua_State* L)
{
    int32_t window = (int32_t)luaL_checkinteger(L, 1);

    size_t count = 0;
    // Discover the necessary size (passing out = NULL, max = 0)
    int status = lgx_monthly_series(window, NULL, 0, &count);

    if (status != LGX_OK && status != LGX_ERR_CAPACITY) {
        lua_pushinteger(L, status);
        lua_pushnil(L);
        return 2;
    }

    // Dynamically allocate the necessary buffer
    lgx_month* months = malloc(count * sizeof(lgx_month));
    if (!months) {
        return luaL_error(L, "Out of memory allocating monthly series buffer");
    }

    status = lgx_monthly_series(window, months, count, &count);
    if (status != LGX_OK) {
        free(months);
        lua_pushinteger(L, status);
        lua_pushnil(L);
        return 2;
    }

    // Convert the C array into a Lua Table
    lua_newtable(L);
    for (size_t i = 0; i < count; i++) {
        lua_newtable(L); // Tabela do mês

        lua_pushstring(L, "debit_cents");
        lua_pushinteger(L, months[i].debit_cents);
        lua_settable(L, -3);
        lua_pushstring(L, "credit_cents");
        lua_pushinteger(L, months[i].credit_cents);
        lua_settable(L, -3);
        lua_pushstring(L, "balance_cents");
        lua_pushinteger(L, months[i].balance_cents);
        lua_settable(L, -3);
        lua_pushstring(L, "cumulative_cents");
        lua_pushinteger(L, months[i].cumulative_cents);
        lua_settable(L, -3);
        lua_pushstring(L, "moving_avg_cents");
        lua_pushinteger(L, months[i].moving_avg_cents);
        lua_settable(L, -3);
        lua_pushstring(L, "growth_bp");
        lua_pushinteger(L, months[i].growth_bp);
        lua_settable(L, -3);
        lua_pushstring(L, "year");
        lua_pushinteger(L, months[i].year);
        lua_settable(L, -3);
        lua_pushstring(L, "month");
        lua_pushinteger(L, months[i].month);
        lua_settable(L, -3);
        lua_pushstring(L, "entries");
        lua_pushinteger(L, months[i].entries);
        lua_settable(L, -3);
        lua_pushstring(L, "window_used");
        lua_pushinteger(L, months[i].window_used);
        lua_settable(L, -3);
        lua_pushstring(L, "growth_valid");
        lua_pushinteger(L, months[i].growth_valid);
        lua_settable(L, -3);

        lua_seti(L, -2, (lua_Integer)i + 1); // Insert the main table into position i+1
    }

    free(months);
    lua_pushinteger(L, LGX_OK);
    lua_insert(L, -2); // Place the status before the table in the stack
    return 2;
}

/* Registration of Lua module functions */
static const struct luaL_Reg lua_extender_core_fns[] = {
    { "version", l_lgx_version },
    { "strerror", l_lgx_strerror },
    { "refresh", l_lgx_refresh },
    { "monthly_series", l_lgx_monthly_series },
    { NULL, NULL }
};

int luaopen_lua_extender_core(lua_State* L)
{
    luaL_newlib(L, lua_extender_core_fns);
    return 1;
}

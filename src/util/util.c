#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include <signal.h>
#include <stdbool.h>

#include "util.h"
#include "uint256.h"

int nanoutil_unpack_account_with_checksum(lua_State *L) {
  static const char b32[] = "13456789abcdefghijkmnopqrstuwxyz";
  char           out[65];
  int            i;
  char          *cur=&out[64];
  
  const char    *acct_str, *checksum_str;
  uint256_t      acct;
  uint64_t       checksum = 0;
  size_t         acct_len, checksum_len;
  
  luaL_argcheck(L, lua_gettop(L) == 2, 0, "incorrect number of arguments: must have raw_acct, 5_byte_hash");
  acct_str =     luaL_checklstring(L, 1, &acct_len);
  checksum_str = luaL_checklstring(L, 2, &checksum_len);
  if(acct_len != 32)
    return luaL_argerror(L, 1, "account length must be 32");
  if(checksum_len != 5)
    return luaL_argerror(L, 1, "checksum length must be 5");
  
  memcpy(&checksum, checksum_str, 5);
  
  readu256BE((uint8_t *)acct_str, &acct);
  memcpy(out, "xrb_", 4); //start of outstring, and prime that cache while we're at it
  *cur--='\0';
  //from right to left -- hash, then account  
  for(i=0; i<8; i++) {//hash first
    *cur-- = b32[checksum & 0x1F];
    checksum >>= 5;
  }
  for(i=0; i<52; i++) {//account
    //printf("0x%016lx\n", LOWER(LOWER(acct)));
    *cur-- = b32[LOWER(LOWER(acct)) & 0x1F];
    shiftr256(&acct, 5, &acct);
  }
  
  lua_pushstring(L, out);
  return 1;
}

#define RETURN_FAIL(Lua, errmsg) \
  lua_pushnil(Lua); \
  lua_pushstring(L, errmsg); \
  return 2

int nanoutil_pack_account_with_checksum(lua_State *L) {
  static const char decode32[] =  "\x00\xFF\x01\x02\x03\x04\x05\x06"
                                  "\x07\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
                                  "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
                                  "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
                                  "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
                                  "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
                                  "\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F"
                                  "\x10\x11\x12\xFF\x13\x14\x15\x16"
                                  "\x17\x18\x19\x1A\x1B\xFF\x1C\x1D"
                                  "\x1E\x1F\xFF";
  
  const char    *acct_in;
  uint256_t      acct;
  char           acct_out[32];
  uint64_t       checksum = 0;
  clear256(&acct);
  
  unsigned char  chr;
  uint8_t        val;
  int            i;
  
  luaL_argcheck(L, lua_gettop(L) == 1, 0, "incorrect number of arguments: must have just encoded_acct");
  acct_in = luaL_checkstring(L, 1);
  if(acct_in[0] != 'x' || acct_in[1] != 'r' || acct_in[2] != 'b' || !(acct_in[3] == '_' || acct_in[3] == '-')) {
    RETURN_FAIL(L, "invalid_account");
  }
  
  //assume length is 64
  for(i=4; i<64; i++) {
    chr = acct_in[i];
    if(chr < 0x31 || chr >= 0x80 ) {
      RETURN_FAIL(L, "invalid_account");
    }
    val = decode32[chr-0x31];
    if(val == 0xFF) { //invalid
      RETURN_FAIL(L, "invalid_account");
    }
    if(i<56) {
      shiftl256(&acct, 5, &acct);
      LOWER(LOWER(acct)) |= val;
      //printf("acct val=%u, 0x%016lx\n", val, LOWER(LOWER(acct)));
    }
    else {
      checksum <<= 5;
      checksum |= val;
      //printf("chk val=%u, 0x%016lx\n", val, checksum);
    }
  }
  
  torawstring256(&acct, acct_out);
  lua_pushlstring(L, (const char*)acct_out, 32);
  
  lua_pushlstring(L, (const char*)&checksum, 5);
  
  return 2;
}

static int nanoutil_unpack_balance_raw(lua_State *L) {
  char        out[40];
  const char *in;
  uint128_t   balance;
  
  luaL_argcheck(L, lua_gettop(L) == 1, 0, "incorrect number of arguments: must have just encoded_acct");
  in = luaL_checkstring(L, 1);  
  //assume length is 16
  
  readu128BE((uint8_t *)in, &balance);
  if(tostring128(&balance, 10, out, 40) == false) {
    RETURN_FAIL(L, "invalid balance");
  }
  
  lua_pushstring(L, out);
  return 1;
}

static int nanoutil_pack_balance_raw(lua_State *L) {
  //not yet implemented
  return luaL_error(L, "not implemented");
}

static void bin_to_strhex(const unsigned char *bin, size_t bin_len, unsigned char *out) {
  unsigned char     hex_str[]= "0123456789abcdef";
  unsigned int      i;
  for (i = 0; i < bin_len; i++) {
    out[i * 2 + 0] = hex_str[(bin[i] >> 4) & 0x0F];
    out[i * 2 + 1] = hex_str[(bin[i]     ) & 0x0F];
  }
  out[bin_len * 2] = 0;
}

static int nanoutil_print_hex(lua_State *L) {
  const char   *in;
  size_t        sz;
  int           i;
  in = luaL_checklstring(L, 1, &sz);
  for(i=0; i < sz; i++) {
    printf("%02x ", in[i]);
    if((i+1) % 16 == 0)
      printf("\n");
    else if ((i+1)%8 == 0)
      printf(" ");
  }
  printf("\n");
  
  return 0;
}

static int nanoutil_to_hex(lua_State *L) {
  char         *out;
  const char   *in;
  size_t        sz;
  in = luaL_checklstring(L, 1, &sz);
  if((out = malloc(sz*2 + 1)) == NULL) {
    return luaL_error(L, "unable to allocate tmp buf for hex dump of binary string");
  }
  bin_to_strhex((const unsigned char *)in, sz, (unsigned char *)out);
  lua_pushstring(L, out);
  free(out);
  return 1;
}

static int nanoutil_from_hex(lua_State *L) {
  char         *out;
  const char   *in;
  size_t        len, i, j;
  in = luaL_checklstring(L, 1, &len);
  if(len % 2 != 0) {
    RETURN_FAIL(L, "from_hex input must have an even number of chars");
  }
  if((out = malloc(len/2+1)) == NULL) {
    luaL_error(L, "unable to allocate tmp buf for hex load of binary string");
  }
  size_t final_len = len / 2;
  for (i=0, j=0; j<final_len; i+=2, j++)
    out[j] = (in[i] % 32 + 9) % 25 * 16 + (in[i+1] % 32 + 9) % 25;
  out[final_len] = '\0';
  
  lua_pushlstring(L, out, final_len);
  free(out);
  return 1;
}

// from luasocket
/*-------------------------------------------------------------------------*\
* Gets time in s, relative to January 1, 1970 (UTC)
* Returns
*   time in s.
\*-------------------------------------------------------------------------*/
#ifdef _WIN32
#include <windows.h>
static double timeout_gettime(void) {
    FILETIME ft;
    double t;
    GetSystemTimeAsFileTime(&ft);
    /* Windows file time (time since January 1, 1601 (UTC)) */
    t  = ft.dwLowDateTime/1.0e7 + ft.dwHighDateTime*(4294967296.0/1.0e7);
    /* convert to Unix Epoch time (time since January 1, 1970 (UTC)) */
    return (t - 11644473600.0);
}
#else
#include <time.h>
#include <sys/time.h>
static double timeout_gettime(void) {
    struct timeval v;
    gettimeofday(&v, (struct timezone *) NULL);
    /* Unix Epoch time (time since January 1, 1970 (UTC)) */
    return v.tv_sec + v.tv_usec/1.0e6;
}
#endif

static int nanoutil_gettime(lua_State *L) {
  lua_pushnumber(L, timeout_gettime());
  return 1;
}

static const struct luaL_Reg prailude_util_functions[] = {
  { "unpack_account_with_checksum", nanoutil_unpack_account_with_checksum },
  { "pack_account_with_checksum", nanoutil_pack_account_with_checksum },
  { "unpack_balance_raw", nanoutil_unpack_balance_raw },
  { "pack_balance_raw", nanoutil_pack_balance_raw },
  { "bytes_to_hex", nanoutil_to_hex },
  { "hex_to_bytes", nanoutil_from_hex },
  { "print_hex", nanoutil_print_hex },
  
  { "gettime", nanoutil_gettime },
  
  { NULL, NULL }
};

int luaopen_prailude_util_lowlevel(lua_State* lua) {
  lua_newtable(lua);
#if LUA_VERSION_NUM > 501
  luaL_setfuncs(lua,prailude_util_functions,0);
#else
  luaL_register(lua, NULL, prailude_util_functions);
#endif
  return 1;
}

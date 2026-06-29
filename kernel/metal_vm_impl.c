// ============================================================================
// metal_vm_impl.c — Freestanding MetalVM for SageOS-RV
// ============================================================================
// Zero libc, zero malloc, zero OS, zero libgcc soft-float.
// Numbers stored as Q32.32 fixed-point (int64_t).
// Compiles with: -ffreestanding -nostdlib -DSAGE_BARE_METAL -DSAGE_METAL_VM
// ============================================================================

#ifdef SAGELANG_METAL_VM_H_PATH
#  include SAGELANG_METAL_VM_H_PATH
#else
#  include "metal_vm.h"
#endif

// ---------------------------------------------------------------------------
// Q32.32 fixed-point
//   1 Q32.32 unit = 2^-32  (~2.33e-10)
//   Range: -2147483647.999... to +2147483647.999...
// ---------------------------------------------------------------------------
#define FP_SHIFT   32
#define FP_ONE     ((int64_t)1 << FP_SHIFT)       // 1.0 in Q32.32
#define FP_HALF    (FP_ONE >> 1)                   // 0.5

// Convert integer to Q32.32
static inline int64_t fp_from_int(int64_t i)  { return i << FP_SHIFT; }
// Convert Q32.32 to integer (truncate)
static inline int64_t fp_to_int(int64_t f)    { return f >> FP_SHIFT; }
// Q32.32 multiply:  (a * b) >> 32
static inline int64_t fp_mul(int64_t a, int64_t b) {
    // Use 128-bit intermediate via __int128 — no libgcc helper needed
    return (int64_t)(((__int128)a * (__int128)b) >> FP_SHIFT);
}
// Q32.32 divide:  (a << 32) / b
static inline int64_t fp_div(int64_t a, int64_t b) {
    if (b == 0) return 0;
    return (int64_t)(((__int128)a << FP_SHIFT) / (__int128)b);
}
// Q32.32 modulo:  a - b * floor(a/b)
static inline int64_t fp_mod(int64_t a, int64_t b) {
    if (b == 0) return 0;
    int64_t q = fp_div(a, b);
    // floor: strip fractional part
    q = (q >> FP_SHIFT) << FP_SHIFT;
    return a - fp_mul(q, b);
}

// Convert IEEE 754 double bits to Q32.32
// We never do floating-point arithmetic — this is only used when loading
// .sgvm constant pools that encode numbers as 64-bit IEEE 754.
static int64_t fp_from_ieee754(uint64_t bits) {
    if (bits == 0) return 0;
    // Extract sign, exponent, mantissa
    int     sign = (bits >> 63) ? -1 : 1;
    int     exp  = (int)((bits >> 52) & 0x7FF) - 1023;
    int64_t mant = (int64_t)((bits & 0x000FFFFFFFFFFFFFULL) | 0x0010000000000000ULL);
    // mant is a 53-bit integer representing 1.fraction * 2^exp
    // We want result in Q32.32, i.e. multiply by 2^32
    // So: result = sign * mant * 2^(exp - 52 + 32) = sign * mant * 2^(exp - 20)
    int shift = exp - 20; // exp-52+32
    int64_t result;
    if (shift >= 0) {
        if (shift >= 63) return sign > 0 ? (int64_t)0x7FFFFFFFFFFFFFFFLL : (int64_t)0x8000000000000000LL;
        result = mant << shift;
    } else {
        int rshift = -shift;
        if (rshift >= 64) return 0;
        result = mant >> rshift;
    }
    return sign > 0 ? result : -result;
}

// ---------------------------------------------------------------------------
// Freestanding helpers (no string.h, no stdlib.h)
// ---------------------------------------------------------------------------

static void bm_memset(void *dst, int val, unsigned long n) {
    unsigned char *p = (unsigned char *)dst;
    while (n--) *p++ = (unsigned char)val;
}

static void bm_memcpy(void *dst, const void *src, unsigned long n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
}

static int bm_strcmp(const char *a, const char *b) {
    while (*a && (*a == *b)) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

static int bm_strncmp(const char *a, const char *b, unsigned long n) {
    while (n-- && *a && (*a == *b)) { a++; b++; }
    if (n == (unsigned long)-1) return 0;
    return (unsigned char)*a - (unsigned char)*b;
}

static unsigned long bm_strlen(const char *s) {
    unsigned long n = 0;
    while (*s++) n++;
    return n;
}

// FNV-1a 32-bit hash
static int fnv1a(const char *s, int len) {
    unsigned int h = 2166136261u;
    for (int i = 0; i < len; i++) { h ^= (unsigned char)s[i]; h *= 16777619u; }
    return (int)h;
}

// Print a signed integer via write_char
static void bm_print_int(MetalVM *vm, int64_t v) {
    if (!vm->write_char) return;
    if (v < 0) { vm->write_char('-'); v = -v; }
    if (v == 0) { vm->write_char('0'); return; }
    char buf[24]; int i = 0;
    while (v > 0) { buf[i++] = '0' + (int)(v % 10); v /= 10; }
    for (int j = i - 1; j >= 0; j--) vm->write_char(buf[j]);
}

// Print a Q32.32 fixed-point number as decimal with up to 6 fractional digits
static void bm_print_fixed(MetalVM *vm, int64_t fp) {
    if (!vm->write_char) return;
    if (fp < 0) { vm->write_char('-'); fp = -fp; }
    int64_t ipart = fp_to_int(fp);
    bm_print_int(vm, ipart);
    int64_t frac = fp & (FP_ONE - 1);  // fractional bits
    if (frac != 0) {
        vm->write_char('.');
        // Print up to 6 decimal digits
        for (int i = 0; i < 6 && frac != 0; i++) {
            frac *= 10;
            int64_t digit = fp_to_int(frac);
            vm->write_char((char)('0' + digit));
            frac &= (FP_ONE - 1);
        }
    }
}

// ---------------------------------------------------------------------------
// SGVM binary format constants
// ---------------------------------------------------------------------------
#define SGVM_MAGIC_0  0x53
#define SGVM_MAGIC_1  0x47
#define SGVM_MAGIC_2  0x56
#define SGVM_MAGIC_3  0x4D
#define SGVM_SECTION_CODE      0x01
#define SGVM_SECTION_CONSTANTS 0x02
#define SGVM_SECTION_CHUNKS    0x03

static unsigned short bm_read_u16(const unsigned char *p) {
    return (unsigned short)((unsigned int)p[0] | ((unsigned int)p[1] << 8));
}
static unsigned int bm_read_u32(const unsigned char *p) {
    return (unsigned int)p[0] | ((unsigned int)p[1]<<8) |
           ((unsigned int)p[2]<<16) | ((unsigned int)p[3]<<24);
}
static uint64_t bm_read_u64(const unsigned char *p) {
    return (uint64_t)bm_read_u32(p) | ((uint64_t)bm_read_u32(p+4) << 32);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void metal_vm_init(MetalVM *vm) {
    bm_memset(vm, 0, sizeof(MetalVM));
}

void metal_vm_load(MetalVM *vm, const unsigned char *code, int length) {
    vm->code        = code;
    vm->code_length = length;
    vm->ip          = 0;
    vm->halted      = 0;
    vm->error       = 0;
}

int metal_vm_load_binary(MetalVM *vm, const unsigned char *data, int size) {
    if (size < 8) return 0;
    if (data[0] != SGVM_MAGIC_0 || data[1] != SGVM_MAGIC_1 ||
        data[2] != SGVM_MAGIC_2 || data[3] != SGVM_MAGIC_3) {
        metal_vm_load(vm, data, size);
        return 1;
    }
    int pos = 8;
    const unsigned char *main_code = data;
    int main_length = 0;
    while (pos + 5 <= size) {
        unsigned char sid = data[pos];
        unsigned int  slen = bm_read_u32(data + pos + 1);
        pos += 5;
        if ((int)(pos + slen) > size) break;
        if (sid == SGVM_SECTION_CODE) {
            main_code   = data + pos;
            main_length = (int)slen;
        } else if (sid == SGVM_SECTION_CONSTANTS) {
            int cpos = 0;
            if ((int)slen < 2) { pos += (int)slen; continue; }
            int count = (int)bm_read_u16(data + pos);
            cpos = 2;
            for (int i = 0; i < count && cpos + 9 <= (int)slen; i++) {
                unsigned char vtype = data[pos + cpos]; cpos++;
                MetalValue mv; mv.type = MV_NIL; mv.as.number = 0;
                if (vtype == 1) {
                    // IEEE754 double bits -> Q32.32
                    uint64_t bits = bm_read_u64(data + pos + cpos);
                    mv = mv_num_fp(fp_from_ieee754(bits));
                } else if (vtype == 2) {
                    mv = mv_bool(data[pos + cpos] ? 1 : 0);
                } else if (vtype == 3) {
                    if (cpos + 2 <= (int)slen) {
                        int slen2 = (int)bm_read_u16(data + pos + cpos + 1);
                        if (cpos + 3 + slen2 <= (int)slen)
                            mv = mv_str(vm, (const char *)(data + pos + cpos + 3), slen2);
                        cpos += 2 + slen2;
                    }
                }
                cpos += 8;
                metal_vm_add_constant(vm, mv);
            }
        } else if (sid == SGVM_SECTION_CHUNKS) {
            int cpos = 0;
            while (cpos + 5 <= (int)slen && vm->chunk_count < 1024) {
                unsigned int clen = bm_read_u32(data + pos + cpos); cpos += 4;
                if (cpos + (int)clen > (int)slen) break;
                vm->chunks[vm->chunk_count]        = data + pos + cpos;
                vm->chunk_lengths[vm->chunk_count] = (int)clen;
                vm->chunk_count++;
                cpos += (int)clen;
            }
        }
        pos += (int)slen;
    }
    metal_vm_load(vm, main_code, main_length);
    return 1;
}

int metal_vm_verify(MetalVM *vm) {
    if (!vm->code || vm->code_length <= 0) return 0;
    int ip = 0;
    while (ip < vm->code_length) {
        unsigned char op = vm->code[ip++];
        if (op == OP_HALT) return 1;
        if (op == OP_CONSTANT    || op == OP_GET_GLOBAL   ||
            op == OP_DEFINE_GLOBAL || op == OP_SET_GLOBAL ||
            op == OP_CALL        || op == OP_ARRAY        ||
            op == OP_TUPLE       || op == OP_DICT         ||
            op == OP_GET_PROPERTY || op == OP_SET_PROPERTY ||
            op == OP_LOAD_FUNCTION || op == OP_DEFINE_FN  ||
            op == OP_CLASS       || op == OP_METHOD       ||
            op == OP_CALL_METHOD) {
            if (ip >= vm->code_length) return 0;
            ip++;
        } else if (op == OP_JUMP || op == OP_JUMP_IF_FALSE || op == OP_LOOP_BACK) {
            if (ip + 2 > vm->code_length) return 0;
            ip += 2;
        }
    }
    return 1;
}

int metal_vm_add_constant(MetalVM *vm, MetalValue value) {
    if (vm->const_count >= METAL_CONST_POOL) return -1;
    vm->constants[vm->const_count] = value;
    return vm->const_count++;
}

// ---------------------------------------------------------------------------
// Value constructors
// ---------------------------------------------------------------------------

MetalValue mv_nil(void) {
    MetalValue v; v.type = MV_NIL; v.as.number = 0; return v;
}

// Construct from raw Q32.32 integer
MetalValue mv_num_fp(int64_t fp) {
    MetalValue v; v.type = MV_NUM; v.as.number = fp; return v;
}

// Convenience: construct from plain C integer
MetalValue mv_num(int64_t i) {
    return mv_num_fp(fp_from_int(i));
}

MetalValue mv_bool(int b) {
    MetalValue v; v.type = MV_BOOL; v.as.boolean = b ? 1 : 0; return v;
}

MetalValue mv_ptr(void *p) {
    MetalValue v; v.type = MV_PTR; v.as.ptr = p; return v;
}

MetalValue mv_str(MetalVM *vm, const char *s, int len) {
    int idx = metal_string_intern(vm, s, len);
    MetalValue v; v.type = MV_STR; v.as.str_idx = idx; return v;
}

// ---------------------------------------------------------------------------
// Stack
// ---------------------------------------------------------------------------

int metal_vm_push(MetalVM *vm, MetalValue value) {
    if (vm->sp >= METAL_STACK_SIZE) {
        vm->error = 1; vm->error_msg = "stack overflow"; return 0;
    }
    vm->stack[vm->sp++] = value;
    return 1;
}

MetalValue metal_vm_pop(MetalVM *vm) {
    if (vm->sp <= 0) {
        vm->error = 1; vm->error_msg = "stack underflow"; return mv_nil();
    }
    return vm->stack[--vm->sp];
}

MetalValue metal_vm_peek(MetalVM *vm, int distance) {
    int idx = vm->sp - 1 - distance;
    if (idx < 0) return mv_nil();
    return vm->stack[idx];
}

// ---------------------------------------------------------------------------
// String pool
// ---------------------------------------------------------------------------

int metal_string_intern(MetalVM *vm, const char *s, int len) {
    int pos = 0, idx = 0;
    while (pos < vm->string_used) {
        const char *entry = vm->strings + pos;
        int elen = (int)bm_strlen(entry);
        if (elen == len && bm_strncmp(entry, s, (unsigned long)len) == 0)
            return idx;
        pos += elen + 1; idx++;
    }
    if (vm->string_used + len + 1 > METAL_STRING_POOL) {
        vm->error = 1; vm->error_msg = "string pool exhausted"; return -1;
    }
    int new_idx = idx;
    bm_memcpy(vm->strings + vm->string_used, s, (unsigned long)len);
    vm->strings[vm->string_used + len] = '\0';
    vm->string_used += len + 1;
    return new_idx;
}

const char *metal_string_get(MetalVM *vm, int idx) {
    int pos = 0, cur = 0;
    while (pos < vm->string_used) {
        if (cur == idx) return vm->strings + pos;
        pos += (int)bm_strlen(vm->strings + pos) + 1;
        cur++;
    }
    return "";
}

// ---------------------------------------------------------------------------
// Array pool
// ---------------------------------------------------------------------------

int metal_array_new(MetalVM *vm) {
    int max = METAL_POOL_SIZE / 8;
    for (int i = 0; i < max; i++) {
        if (!vm->arrays[i].in_use) {
            bm_memset(&vm->arrays[i], 0, sizeof(MetalArray));
            vm->arrays[i].in_use = 1;
            if (i >= vm->array_count) vm->array_count = i + 1;
            return i;
        }
    }
    vm->error = 1; vm->error_msg = "array pool exhausted"; return -1;
}

void metal_array_push(MetalVM *vm, int arr_idx, MetalValue val) {
    if (arr_idx < 0 || arr_idx >= vm->array_count) return;
    MetalArray *arr = &vm->arrays[arr_idx];
    if (arr->count >= METAL_ARRAY_MAX_ELEMS) {
        vm->error = 1; vm->error_msg = "array full"; return;
    }
    arr->elems[arr->count++] = val;
}

MetalValue metal_array_get(MetalVM *vm, int arr_idx, int index) {
    if (arr_idx < 0 || arr_idx >= vm->array_count) return mv_nil();
    MetalArray *arr = &vm->arrays[arr_idx];
    if (index < 0 || index >= arr->count) return mv_nil();
    return arr->elems[index];
}

int metal_array_len(MetalVM *vm, int arr_idx) {
    if (arr_idx < 0 || arr_idx >= vm->array_count) return 0;
    return vm->arrays[arr_idx].count;
}

// ---------------------------------------------------------------------------
// Print
// ---------------------------------------------------------------------------

void metal_print_value(MetalVM *vm, MetalValue value) {
    if (!vm->write_char) return;
    switch (value.type) {
    case MV_NIL:  { const char *s = "nil";   while (*s) vm->write_char(*s++); break; }
    case MV_BOOL: { const char *s = value.as.boolean ? "true" : "false";
                    while (*s) vm->write_char(*s++); break; }
    case MV_NUM:  bm_print_fixed(vm, value.as.number); break;
    case MV_STR:  { const char *s = metal_string_get(vm, value.as.str_idx);
                    while (*s) vm->write_char(*s++); break; }
    case MV_PTR:  { const char *pfx = "<ptr:0x"; while (*pfx) vm->write_char(*pfx++);
                    unsigned long addr = (unsigned long)(unsigned long long)value.as.ptr;
                    char buf[18]; int i = 0;
                    if (addr == 0) { vm->write_char('0'); }
                    else { while (addr) { int d=(int)(addr&0xF); buf[i++]=(char)(d<10?'0'+d:'a'+d-10); addr>>=4; }
                           for (int j=i-1;j>=0;j--) vm->write_char(buf[j]); }
                    vm->write_char('>'); break; }
    case MV_ARR:  { const char *s = "<array>"; while (*s) vm->write_char(*s++); break; }
    case MV_DICT: { const char *s = "<dict>";  while (*s) vm->write_char(*s++); break; }
    case MV_FN:   { const char *s = "<fn>";    while (*s) vm->write_char(*s++); break; }
    }
}

// ---------------------------------------------------------------------------
// Scope helpers
// ---------------------------------------------------------------------------

static int scope_get(MetalVM *vm, int hash, MetalValue *out) {
    for (int d = vm->scope_depth - 1; d >= 0; d--) {
        MetalScope *sc = &vm->scopes[d];
        for (int i = 0; i < sc->count; i++)
            if (sc->name_hash[i] == hash) { *out = sc->values[i]; return 1; }
    }
    return 0;
}

static int scope_set(MetalVM *vm, int hash, MetalValue val) {
    for (int d = vm->scope_depth - 1; d >= 0; d--) {
        MetalScope *sc = &vm->scopes[d];
        for (int i = 0; i < sc->count; i++)
            if (sc->name_hash[i] == hash) { sc->values[i] = val; return 1; }
    }
    return 0;
}

static int scope_define(MetalVM *vm, int hash, MetalValue val) {
    if (vm->scope_depth <= 0) return 0;
    MetalScope *sc = &vm->scopes[vm->scope_depth - 1];
    if (sc->count >= METAL_VARS_PER_SCOPE) {
        vm->error = 1; vm->error_msg = "scope full"; return 0;
    }
    sc->name_hash[sc->count] = hash;
    sc->values[sc->count]    = val;
    sc->count++;
    return 1;
}

// ---------------------------------------------------------------------------
// Dispatch macros
// ---------------------------------------------------------------------------

#define READ_BYTE() (vm->ip < vm->code_length ? vm->code[vm->ip++] : (vm->halted=1,(unsigned char)OP_HALT))
#define READ_U16()  (vm->ip+2<=vm->code_length ? \
    (unsigned short)((unsigned short)vm->code[vm->ip++] | ((unsigned short)vm->code[vm->ip++]<<8)) \
    : (vm->halted=1,0))

static void push_call_frame(MetalVM *vm, int new_ip, const unsigned char *new_code, int new_len) {
    if (vm->csp >= METAL_CALL_STACK_SIZE) {
        vm->error = 1; vm->error_msg = "call stack overflow"; return;
    }
    vm->call_stack[vm->csp].ip          = vm->ip;
    vm->call_stack[vm->csp].code        = vm->code;
    vm->call_stack[vm->csp].code_length = vm->code_length;
    vm->csp++;
    vm->code = new_code; vm->code_length = new_len; vm->ip = new_ip;
}

static void pop_call_frame(MetalVM *vm) {
    if (vm->csp <= 0) { vm->halted = 1; return; }
    vm->csp--;
    vm->ip          = vm->call_stack[vm->csp].ip;
    vm->code        = vm->call_stack[vm->csp].code;
    vm->code_length = vm->call_stack[vm->csp].code_length;
}

// ---------------------------------------------------------------------------
// Single-step execution
// ---------------------------------------------------------------------------

int metal_vm_step(MetalVM *vm) {
    if (vm->halted || vm->error) return 0;
    if (vm->ip >= vm->code_length) { vm->halted = 1; return 0; }

    unsigned char op = READ_BYTE();

    switch (op) {
    case OP_HALT: vm->halted = 1; return 0;

    case OP_CONSTANT: {
        unsigned char idx = READ_BYTE();
        metal_vm_push(vm, idx < vm->const_count ? vm->constants[idx] : mv_nil());
        break;
    }
    case OP_NIL:   metal_vm_push(vm, mv_nil());    break;
    case OP_TRUE:  metal_vm_push(vm, mv_bool(1));  break;
    case OP_FALSE: metal_vm_push(vm, mv_bool(0));  break;
    case OP_POP:   metal_vm_pop(vm);               break;
    case OP_DUP:   metal_vm_push(vm, metal_vm_peek(vm, 0)); break;

    // ---- Globals -------------------------------------------------------
    case OP_DEFINE_GLOBAL: {
        unsigned char idx = READ_BYTE();
        const char *name = (idx < vm->const_count && vm->constants[idx].type == MV_STR)
            ? metal_string_get(vm, vm->constants[idx].as.str_idx) : "";
        scope_define(vm, fnv1a(name, (int)bm_strlen(name)), metal_vm_pop(vm));
        break;
    }
    case OP_GET_GLOBAL: {
        unsigned char idx = READ_BYTE();
        const char *name = (idx < vm->const_count && vm->constants[idx].type == MV_STR)
            ? metal_string_get(vm, vm->constants[idx].as.str_idx) : "";
        MetalValue val = mv_nil();
        scope_get(vm, fnv1a(name, (int)bm_strlen(name)), &val);
        metal_vm_push(vm, val);
        break;
    }
    case OP_SET_GLOBAL: {
        unsigned char idx = READ_BYTE();
        const char *name = (idx < vm->const_count && vm->constants[idx].type == MV_STR)
            ? metal_string_get(vm, vm->constants[idx].as.str_idx) : "";
        MetalValue val = metal_vm_peek(vm, 0);
        int hash = fnv1a(name, (int)bm_strlen(name));
        if (!scope_set(vm, hash, val)) scope_define(vm, hash, val);
        break;
    }

    // ---- Scopes --------------------------------------------------------
    case OP_PUSH_ENV:
        if (vm->scope_depth >= METAL_ENV_DEPTH) {
            vm->error = 1; vm->error_msg = "scope depth exceeded"; break;
        }
        bm_memset(&vm->scopes[vm->scope_depth++], 0, sizeof(MetalScope));
        break;
    case OP_POP_ENV:
        if (vm->scope_depth > 0) vm->scope_depth--;
        break;

    // ---- Arithmetic (Q32.32) ------------------------------------------
    case OP_ADD: {
        MetalValue b = metal_vm_pop(vm), a = metal_vm_pop(vm);
        if (a.type == MV_NUM && b.type == MV_NUM)
            metal_vm_push(vm, mv_num_fp(a.as.number + b.as.number));
        else if (a.type == MV_STR && b.type == MV_STR) {
            const char *sa = metal_string_get(vm, a.as.str_idx);
            const char *sb = metal_string_get(vm, b.as.str_idx);
            int la = (int)bm_strlen(sa), lb = (int)bm_strlen(sb);
            if (vm->heap_used + la + lb + 1 <= METAL_HEAP_SIZE) {
                char *buf = (char *)(vm->heap + vm->heap_used);
                bm_memcpy(buf, sa, (unsigned long)la);
                bm_memcpy(buf + la, sb, (unsigned long)lb);
                buf[la + lb] = '\0';
                vm->heap_used += la + lb + 1;
                metal_vm_push(vm, mv_str(vm, buf, la + lb));
            } else metal_vm_push(vm, mv_nil());
        } else metal_vm_push(vm, mv_nil());
        break;
    }
    case OP_SUB: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?mv_num_fp(a.as.number-b.as.number):mv_nil()); break; }
    case OP_MUL: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?mv_num_fp(fp_mul(a.as.number,b.as.number)):mv_nil()); break; }
    case OP_DIV: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM&&b.as.number!=0)?mv_num_fp(fp_div(a.as.number,b.as.number)):mv_nil()); break; }
    case OP_MOD: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM&&b.as.number!=0)?mv_num_fp(fp_mod(a.as.number,b.as.number)):mv_nil()); break; }
    case OP_NEGATE: { MetalValue a=metal_vm_pop(vm);
        metal_vm_push(vm,a.type==MV_NUM?mv_num_fp(-a.as.number):mv_nil()); break; }
    case OP_NOT: { MetalValue a=metal_vm_pop(vm);
        metal_vm_push(vm,mv_bool(a.type==MV_NIL||(a.type==MV_BOOL&&!a.as.boolean))); break; }
    case OP_TRUTHY: { MetalValue a=metal_vm_pop(vm);
        metal_vm_push(vm,mv_bool(!(a.type==MV_NIL||(a.type==MV_BOOL&&!a.as.boolean)))); break; }

    // ---- Bitwise (operate on integer part of Q32.32) -------------------
    case OP_BIT_AND: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?
            mv_num(fp_to_int(a.as.number)&fp_to_int(b.as.number)):mv_nil()); break; }
    case OP_BIT_OR:  { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?
            mv_num(fp_to_int(a.as.number)|fp_to_int(b.as.number)):mv_nil()); break; }
    case OP_BIT_XOR: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?
            mv_num(fp_to_int(a.as.number)^fp_to_int(b.as.number)):mv_nil()); break; }
    case OP_BIT_NOT: { MetalValue a=metal_vm_pop(vm);
        metal_vm_push(vm,a.type==MV_NUM?mv_num(~fp_to_int(a.as.number)):mv_nil()); break; }
    case OP_SHIFT_LEFT:  { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?
            mv_num(fp_to_int(a.as.number)<<(int)fp_to_int(b.as.number)):mv_nil()); break; }
    case OP_SHIFT_RIGHT: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?
            mv_num(fp_to_int(a.as.number)>>(int)fp_to_int(b.as.number)):mv_nil()); break; }

    // ---- Comparisons ---------------------------------------------------
    case OP_EQUAL: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        int eq=0;
        if(a.type==b.type){
            if(a.type==MV_NIL)  eq=1;
            else if(a.type==MV_BOOL) eq=(a.as.boolean==b.as.boolean);
            else if(a.type==MV_NUM)  eq=(a.as.number==b.as.number);
            else if(a.type==MV_STR)  eq=(bm_strcmp(metal_string_get(vm,a.as.str_idx),metal_string_get(vm,b.as.str_idx))==0);
            else if(a.type==MV_PTR)  eq=(a.as.ptr==b.as.ptr);
        }
        metal_vm_push(vm,mv_bool(eq)); break; }
    case OP_NOT_EQUAL: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        int eq=0;
        if(a.type==b.type){
            if(a.type==MV_NIL)  eq=1;
            else if(a.type==MV_BOOL) eq=(a.as.boolean==b.as.boolean);
            else if(a.type==MV_NUM)  eq=(a.as.number==b.as.number);
            else if(a.type==MV_STR)  eq=(bm_strcmp(metal_string_get(vm,a.as.str_idx),metal_string_get(vm,b.as.str_idx))==0);
        }
        metal_vm_push(vm,mv_bool(!eq)); break; }
    case OP_GREATER:       { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?mv_bool(a.as.number>b.as.number):mv_bool(0)); break; }
    case OP_GREATER_EQUAL: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?mv_bool(a.as.number>=b.as.number):mv_bool(0)); break; }
    case OP_LESS:          { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?mv_bool(a.as.number<b.as.number):mv_bool(0)); break; }
    case OP_LESS_EQUAL:    { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?mv_bool(a.as.number<=b.as.number):mv_bool(0)); break; }

    // ---- Control flow --------------------------------------------------
    case OP_JUMP: { unsigned short off=READ_U16(); vm->ip+=(int)(short)off; break; }
    case OP_JUMP_IF_FALSE: {
        unsigned short off=READ_U16();
        MetalValue c=metal_vm_peek(vm,0);
        if(c.type==MV_NIL||(c.type==MV_BOOL&&!c.as.boolean)) vm->ip+=(int)(short)off;
        break;
    }
    case OP_LOOP_BACK: { unsigned short off=READ_U16(); vm->ip-=(int)(unsigned short)off; break; }
    case OP_BREAK:    vm->halted=1; break;
    case OP_CONTINUE: break;

    // ---- Functions -----------------------------------------------------
    case OP_DEFINE_FN:
    case OP_LOAD_FUNCTION: {
        unsigned char fn_idx=READ_BYTE();
        MetalValue v; v.type=MV_FN; v.as.fn_idx=fn_idx;
        metal_vm_push(vm,v); break;
    }
    case OP_CALL: {
        unsigned char argc=READ_BYTE(); (void)argc;
        MetalValue callee=metal_vm_pop(vm);
        if(callee.type==MV_FN){
            int fi=callee.as.fn_idx;
            if(fi>=0&&fi<vm->fn_count){
                MetalFunction *fn=&vm->functions[fi];
                push_call_frame(vm,fn->code_offset,vm->code,vm->code_length);
                if(vm->scope_depth<METAL_ENV_DEPTH){
                    bm_memset(&vm->scopes[vm->scope_depth++],0,sizeof(MetalScope));
                }
            }
        }
        break;
    }
    case OP_RETURN: {
        if(vm->scope_depth>0) vm->scope_depth--;
        if(vm->csp==0){vm->halted=1;break;}
        pop_call_frame(vm);
        break;
    }

    // ---- Arrays --------------------------------------------------------
    case OP_ARRAY: {
        unsigned char count=READ_BYTE();
        int arr_idx=metal_array_new(vm);
        if(arr_idx<0) break;
        for(int i=count-1;i>=0;i--) vm->arrays[arr_idx].elems[i]=metal_vm_pop(vm);
        vm->arrays[arr_idx].count=(int)count;
        MetalValue v; v.type=MV_ARR; v.as.arr_idx=arr_idx;
        metal_vm_push(vm,v); break;
    }
    case OP_ARRAY_LEN: {
        MetalValue a=metal_vm_pop(vm);
        metal_vm_push(vm,mv_num((a.type==MV_ARR)?metal_array_len(vm,a.as.arr_idx):0)); break;
    }
    case OP_GET_INDEX: {
        MetalValue idx=metal_vm_pop(vm),obj=metal_vm_pop(vm);
        if(obj.type==MV_ARR&&idx.type==MV_NUM)
            metal_vm_push(vm,metal_array_get(vm,obj.as.arr_idx,(int)fp_to_int(idx.as.number)));
        else if(obj.type==MV_STR&&idx.type==MV_NUM){
            const char *s=metal_string_get(vm,obj.as.str_idx);
            int i=(int)fp_to_int(idx.as.number), slen=(int)bm_strlen(s);
            if(i>=0&&i<slen){ char ch[1]; ch[0]=s[i]; metal_vm_push(vm,mv_str(vm,ch,1)); }
            else metal_vm_push(vm,mv_nil());
        } else metal_vm_push(vm,mv_nil());
        break;
    }
    case OP_SET_INDEX: {
        MetalValue val=metal_vm_pop(vm),idx=metal_vm_pop(vm),obj=metal_vm_pop(vm);
        if(obj.type==MV_ARR&&idx.type==MV_NUM){
            int i=(int)fp_to_int(idx.as.number);
            if(i>=0&&i<METAL_ARRAY_MAX_ELEMS) vm->arrays[obj.as.arr_idx].elems[i]=val;
        }
        metal_vm_push(vm,val); break;
    }

    // ---- Tuples --------------------------------------------------------
    case OP_TUPLE: {
        unsigned char count=READ_BYTE();
        int arr_idx=metal_array_new(vm);
        if(arr_idx<0) break;
        for(int i=count-1;i>=0;i--) vm->arrays[arr_idx].elems[i]=metal_vm_pop(vm);
        vm->arrays[arr_idx].count=(int)count;
        MetalValue v; v.type=MV_ARR; v.as.arr_idx=arr_idx;
        metal_vm_push(vm,v); break;
    }

    // ---- Dicts ---------------------------------------------------------
    case OP_DICT: {
        unsigned char count=READ_BYTE();
        int max=METAL_POOL_SIZE/16, di=-1;
        for(int i=0;i<max;i++){
            if(!vm->dicts[i].in_use){
                bm_memset(&vm->dicts[i],0,sizeof(MetalDict));
                vm->dicts[i].in_use=1;
                if(i>=vm->dict_count) vm->dict_count=i+1;
                di=i; break;
            }
        }
        if(di<0){metal_vm_push(vm,mv_nil());break;}
        for(int i=0;i<(int)count;i++){
            MetalValue val=metal_vm_pop(vm),key=metal_vm_pop(vm);
            if(vm->dicts[di].count<METAL_DICT_MAX_ENTRIES){
                vm->dicts[di].key_str_idx[vm->dicts[di].count]=(key.type==MV_STR)?key.as.str_idx:-1;
                vm->dicts[di].values[vm->dicts[di].count]=val;
                vm->dicts[di].count++;
            }
        }
        MetalValue v; v.type=MV_DICT; v.as.dict_idx=di;
        metal_vm_push(vm,v); break;
    }
    case OP_GET_PROPERTY: {
        unsigned char idx=READ_BYTE();
        MetalValue key=(idx<vm->const_count)?vm->constants[idx]:mv_nil();
        MetalValue obj=metal_vm_pop(vm);
        if(obj.type==MV_DICT&&key.type==MV_STR){
            MetalDict *d=&vm->dicts[obj.as.dict_idx];
            MetalValue found=mv_nil();
            for(int i=0;i<d->count;i++) if(d->key_str_idx[i]==key.as.str_idx){found=d->values[i];break;}
            metal_vm_push(vm,found);
        } else metal_vm_push(vm,mv_nil());
        break;
    }
    case OP_SET_PROPERTY: {
        unsigned char idx=READ_BYTE();
        MetalValue key=(idx<vm->const_count)?vm->constants[idx]:mv_nil();
        MetalValue val=metal_vm_pop(vm),obj=metal_vm_peek(vm,0);
        if(obj.type==MV_DICT&&key.type==MV_STR){
            MetalDict *d=&vm->dicts[obj.as.dict_idx];
            int found=0;
            for(int i=0;i<d->count;i++) if(d->key_str_idx[i]==key.as.str_idx){d->values[i]=val;found=1;break;}
            if(!found&&d->count<METAL_DICT_MAX_ENTRIES){
                d->key_str_idx[d->count]=key.as.str_idx;
                d->values[d->count]=val;
                d->count++;
            }
        }
        break;
    }

    // ---- Print ---------------------------------------------------------
    case OP_PRINT: {
        MetalValue v=metal_vm_pop(vm);
        metal_print_value(vm,v);
        if(vm->write_char) vm->write_char('\n');
        break;
    }

    // ---- Exception handling --------------------------------------------
    case OP_SETUP_TRY: {
        unsigned short off=READ_U16();
        if(vm->hsp<128){
            vm->handlers[vm->hsp].ip=vm->ip+(int)(short)off;
            vm->handlers[vm->hsp].stack_size=vm->sp;
            vm->hsp++;
        }
        break;
    }
    case OP_END_TRY: if(vm->hsp>0) vm->hsp--; break;
    case OP_RAISE: {
        vm->exception_value=metal_vm_pop(vm);
        vm->is_throwing=1;
        if(vm->hsp>0){
            vm->hsp--;
            vm->ip=vm->handlers[vm->hsp].ip;
            vm->sp=vm->handlers[vm->hsp].stack_size;
            metal_vm_push(vm,vm->exception_value);
            vm->is_throwing=0;
        } else { vm->error=1; vm->error_msg="unhandled exception"; }
        break;
    }

    // ---- Stubs ---------------------------------------------------------
    case OP_IMPORT:      { READ_BYTE(); break; }
    case OP_CLASS:       { READ_BYTE(); break; }
    case OP_METHOD:      { READ_BYTE(); break; }
    case OP_CALL_METHOD: { READ_BYTE(); break; }
    case OP_INHERIT:     break;
    case OP_SLICE:       break;
    case OP_EXEC_AST_STMT: break;

    // ---- GPU no-ops on bare-metal RV64 ---------------------------------
    case OP_GPU_POLL_EVENTS:         break;
    case OP_GPU_WINDOW_SHOULD_CLOSE: metal_vm_push(vm,mv_bool(0)); break;
    case OP_GPU_GET_TIME:            metal_vm_push(vm,mv_num(0)); break;
    case OP_GPU_KEY_PRESSED:         metal_vm_push(vm,mv_bool(0)); break;
    case OP_GPU_KEY_DOWN:            metal_vm_push(vm,mv_bool(0)); break;
    case OP_GPU_MOUSE_POS:           metal_vm_push(vm,mv_num(0)); metal_vm_push(vm,mv_num(0)); break;
    case OP_GPU_MOUSE_DELTA:         metal_vm_push(vm,mv_num(0)); metal_vm_push(vm,mv_num(0)); break;
    case OP_GPU_UPDATE_INPUT:        break;
    case OP_GPU_BEGIN_COMMANDS:      break;
    case OP_GPU_END_COMMANDS:        break;
    case OP_GPU_CMD_BEGIN_RP:        break;
    case OP_GPU_CMD_END_RP:          break;
    case OP_GPU_CMD_DRAW:            break;
    case OP_GPU_CMD_BIND_GP:         break;
    case OP_GPU_CMD_BIND_DS:         break;
    case OP_GPU_CMD_SET_VP:          break;
    case OP_GPU_CMD_SET_SC:          break;
    case OP_GPU_CMD_BIND_VB:         break;
    case OP_GPU_CMD_BIND_IB:         break;
    case OP_GPU_CMD_DRAW_IDX:        break;
    case OP_GPU_SUBMIT_SYNC:         break;
    case OP_GPU_ACQUIRE_IMG:         break;
    case OP_GPU_PRESENT:             break;
    case OP_GPU_WAIT_FENCE:          break;
    case OP_GPU_RESET_FENCE:         break;
    case OP_GPU_UPDATE_UNIFORM:      break;
    case OP_GPU_CMD_PUSH_CONST:      break;
    case OP_GPU_CMD_DISPATCH:        break;

    default:
        vm->error = 1; vm->error_msg = "unknown opcode"; vm->halted = 1; break;
    }

    return !vm->halted && !vm->error;
}

// ---------------------------------------------------------------------------
// Run loop
// ---------------------------------------------------------------------------

int metal_vm_run(MetalVM *vm) {
    if (vm->scope_depth == 0) {
        bm_memset(&vm->scopes[0], 0, sizeof(MetalScope));
        vm->scope_depth = 1;
    }
    while (!vm->halted && !vm->error)
        metal_vm_step(vm);
    return vm->error ? 0 : 1;
}

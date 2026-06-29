// ============================================================================
// metal_vm_impl.c — Freestanding MetalVM implementation for SageOS-RV
// ============================================================================
// Implements every function declared in metal_vm.h.
// Zero libc, zero malloc, zero OS. Compiles with:
//   -ffreestanding -nostdlib -DSAGE_BARE_METAL -DSAGE_METAL_VM
// ============================================================================

#ifdef SAGELANG_METAL_VM_H_PATH
#  include SAGELANG_METAL_VM_H_PATH
#else
#  include "metal_vm.h"
#endif

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

// FNV-1a 32-bit hash for variable name lookup
static int fnv1a(const char *s, int len) {
    unsigned int h = 2166136261u;
    for (int i = 0; i < len; i++) {
        h ^= (unsigned char)s[i];
        h *= 16777619u;
    }
    return (int)h;
}

// Simple itoa for metal_print_value (decimal, no libc)
static void bm_print_int(MetalVM *vm, long long v) {
    if (!vm->write_char) return;
    if (v < 0) { vm->write_char('-'); v = -v; }
    if (v == 0) { vm->write_char('0'); return; }
    char buf[24];
    int i = 0;
    while (v > 0) { buf[i++] = '0' + (int)(v % 10); v /= 10; }
    for (int j = i - 1; j >= 0; j--) vm->write_char(buf[j]);
}

// Print a double using write_char — integer + up to 6 decimal digits
static void bm_print_double(MetalVM *vm, double v) {
    if (!vm->write_char) return;
    if (v < 0) { vm->write_char('-'); v = -v; }
    long long ipart = (long long)v;
    bm_print_int(vm, ipart);
    double frac = v - (double)ipart;
    if (frac > 0.0) {
        vm->write_char('.');
        for (int i = 0; i < 6; i++) {
            frac *= 10.0;
            int d = (int)frac;
            vm->write_char('0' + d);
            frac -= d;
            if (frac < 1e-9) break;
        }
    }
}

// ---------------------------------------------------------------------------
// SGVM binary format constants
// ---------------------------------------------------------------------------

#define SGVM_MAGIC_0  0x53  // 'S'
#define SGVM_MAGIC_1  0x47  // 'G'
#define SGVM_MAGIC_2  0x56  // 'V'
#define SGVM_MAGIC_3  0x4D  // 'M'

#define SGVM_SECTION_CODE      0x01
#define SGVM_SECTION_CONSTANTS 0x02
#define SGVM_SECTION_CHUNKS    0x03

static unsigned short bm_read_u16(const unsigned char *p) {
    return (unsigned short)((unsigned int)p[0] | ((unsigned int)p[1] << 8));
}

static unsigned int bm_read_u32(const unsigned char *p) {
    return (unsigned int)p[0] |
           ((unsigned int)p[1] << 8) |
           ((unsigned int)p[2] << 16) |
           ((unsigned int)p[3] << 24);
}

// ---------------------------------------------------------------------------
// Public API implementation
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
    // Verify magic: 'S','G','V','M'
    if (data[0] != SGVM_MAGIC_0 || data[1] != SGVM_MAGIC_1 ||
        data[2] != SGVM_MAGIC_2 || data[3] != SGVM_MAGIC_3) {
        // No magic header — treat entire buffer as raw bytecode
        metal_vm_load(vm, data, size);
        return 1;
    }
    // Skip 4-byte magic + 2-byte version + 2-byte flags
    int pos = 8;
    const unsigned char *main_code = data;
    int main_length = 0;
    while (pos + 5 <= size) {
        unsigned char section_id = data[pos];
        unsigned int section_len = bm_read_u32(data + pos + 1);
        pos += 5;
        if ((int)(pos + section_len) > size) break;
        if (section_id == SGVM_SECTION_CODE) {
            main_code   = data + pos;
            main_length = (int)section_len;
        } else if (section_id == SGVM_SECTION_CONSTANTS) {
            // Constant pool: [count:u16][type:u8 value:8bytes] ...
            int cpos = 0;
            if ((int)section_len < 2) { pos += (int)section_len; continue; }
            int count = (int)bm_read_u16(data + pos);
            cpos = 2;
            for (int i = 0; i < count && cpos + 9 <= (int)section_len; i++) {
                unsigned char vtype = data[pos + cpos]; cpos++;
                MetalValue mv;
                mv.type = MV_NIL;
                if (vtype == 1) { // number
                    // 8 bytes little-endian IEEE 754 double
                    unsigned long long bits = 0;
                    for (int b = 0; b < 8; b++)
                        bits |= ((unsigned long long)data[pos + cpos + b]) << (b * 8);
                    // type-pun u64 -> double
                    double d;
                    bm_memcpy(&d, &bits, 8);
                    mv = mv_num(d);
                } else if (vtype == 2) { // bool
                    mv = mv_bool(data[pos + cpos] ? 1 : 0);
                } else if (vtype == 3) { // string — next 2 bytes are length
                    if (cpos + 2 <= (int)section_len) {
                        int slen = (int)bm_read_u16(data + pos + cpos + 1);
                        if (cpos + 3 + slen <= (int)section_len)
                            mv = mv_str(vm, (const char *)(data + pos + cpos + 3), slen);
                        cpos += 2 + slen;
                    }
                }
                cpos += 8;
                metal_vm_add_constant(vm, mv);
            }
        } else if (section_id == SGVM_SECTION_CHUNKS) {
            // Additional function chunks
            int cpos = 0;
            while (cpos + 5 <= (int)section_len && vm->chunk_count < 1024) {
                unsigned int clen = bm_read_u32(data + pos + cpos); cpos += 4;
                if (cpos + (int)clen > (int)section_len) break;
                vm->chunks[vm->chunk_count]        = data + pos + cpos;
                vm->chunk_lengths[vm->chunk_count] = (int)clen;
                vm->chunk_count++;
                cpos += (int)clen;
            }
        }
        pos += (int)section_len;
    }
    metal_vm_load(vm, main_code, main_length);
    return 1;
}

int metal_vm_verify(MetalVM *vm) {
    if (!vm->code || vm->code_length <= 0) return 0;
    // Basic sanity: walk bytecode looking for out-of-range jumps
    int ip = 0;
    while (ip < vm->code_length) {
        unsigned char op = vm->code[ip++];
        if (op == OP_HALT) return 1;
        // opcodes with 1-byte operand
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
        }
        // opcodes with 2-byte jump offset
        else if (op == OP_JUMP || op == OP_JUMP_IF_FALSE || op == OP_LOOP_BACK) {
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
    MetalValue v; v.type = MV_NIL; v.as.number = 0.0; return v;
}

MetalValue mv_num(double n) {
    MetalValue v; v.type = MV_NUM; v.as.number = n; return v;
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
        vm->error = 1;
        vm->error_msg = "stack overflow";
        return 0;
    }
    vm->stack[vm->sp++] = value;
    return 1;
}

MetalValue metal_vm_pop(MetalVM *vm) {
    if (vm->sp <= 0) {
        vm->error = 1;
        vm->error_msg = "stack underflow";
        return mv_nil();
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
    // Search existing strings first
    int pos = 0;
    int idx = 0;
    while (pos < vm->string_used) {
        const char *entry = vm->strings + pos;
        int elen = (int)bm_strlen(entry);
        if (elen == len && bm_strncmp(entry, s, (unsigned long)len) == 0)
            return idx;
        pos += elen + 1;
        idx++;
    }
    // Intern new string
    if (vm->string_used + len + 1 > METAL_STRING_POOL) {
        vm->error = 1;
        vm->error_msg = "string pool exhausted";
        return -1;
    }
    int new_idx = idx;
    bm_memcpy(vm->strings + vm->string_used, s, (unsigned long)len);
    vm->strings[vm->string_used + len] = '\0';
    vm->string_used += len + 1;
    return new_idx;
}

const char *metal_string_get(MetalVM *vm, int idx) {
    int pos = 0;
    int cur = 0;
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
    vm->error = 1;
    vm->error_msg = "array pool exhausted";
    return -1;
}

void metal_array_push(MetalVM *vm, int arr_idx, MetalValue val) {
    if (arr_idx < 0 || arr_idx >= vm->array_count) return;
    MetalArray *arr = &vm->arrays[arr_idx];
    if (arr->count >= METAL_ARRAY_MAX_ELEMS) {
        vm->error = 1;
        vm->error_msg = "array full";
        return;
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
    case MV_NIL:
        { const char *s = "nil"; while (*s) vm->write_char(*s++); break; }
    case MV_BOOL:
        { const char *s = value.as.boolean ? "true" : "false";
          while (*s) vm->write_char(*s++); break; }
    case MV_NUM:
        bm_print_double(vm, value.as.number);
        break;
    case MV_STR:
        { const char *s = metal_string_get(vm, value.as.str_idx);
          while (*s) vm->write_char(*s++); break; }
    case MV_PTR:
        { const char *pfx = "<ptr:0x";
          while (*pfx) vm->write_char(*pfx++);
          unsigned long addr = (unsigned long)(unsigned long long)value.as.ptr;
          // Print hex
          char buf[18]; int i = 0;
          if (addr == 0) { vm->write_char('0'); }
          else {
              while (addr) {
                  int d = (int)(addr & 0xF);
                  buf[i++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
                  addr >>= 4;
              }
              for (int j = i-1; j >= 0; j--) vm->write_char(buf[j]);
          }
          vm->write_char('>'); break; }
    case MV_ARR:
        { const char *s = "<array>"; while (*s) vm->write_char(*s++); break; }
    case MV_DICT:
        { const char *s = "<dict>";  while (*s) vm->write_char(*s++); break; }
    case MV_FN:
        { const char *s = "<fn>";    while (*s) vm->write_char(*s++); break; }
    }
}

// ---------------------------------------------------------------------------
// Scope helpers
// ---------------------------------------------------------------------------

static int scope_get(MetalVM *vm, int hash, MetalValue *out) {
    for (int d = vm->scope_depth - 1; d >= 0; d--) {
        MetalScope *sc = &vm->scopes[d];
        for (int i = 0; i < sc->count; i++) {
            if (sc->name_hash[i] == hash) { *out = sc->values[i]; return 1; }
        }
    }
    return 0;
}

static int scope_set(MetalVM *vm, int hash, MetalValue val) {
    for (int d = vm->scope_depth - 1; d >= 0; d--) {
        MetalScope *sc = &vm->scopes[d];
        for (int i = 0; i < sc->count; i++) {
            if (sc->name_hash[i] == hash) { sc->values[i] = val; return 1; }
        }
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
// Dispatch helpers
// ---------------------------------------------------------------------------

#define READ_BYTE()  (vm->ip < vm->code_length ? vm->code[vm->ip++] : (vm->halted=1, (unsigned char)OP_HALT))
#define READ_U16()   (vm->ip+2<=vm->code_length ? (unsigned short)((unsigned short)vm->code[vm->ip++] | ((unsigned short)vm->code[vm->ip++]<<8)) : (vm->halted=1,0))

static void push_call_frame(MetalVM *vm, int new_ip, const unsigned char *new_code, int new_len) {
    if (vm->csp >= METAL_CALL_STACK_SIZE) {
        vm->error = 1; vm->error_msg = "call stack overflow"; return;
    }
    vm->call_stack[vm->csp].ip          = vm->ip;
    vm->call_stack[vm->csp].code        = vm->code;
    vm->call_stack[vm->csp].code_length = vm->code_length;
    vm->csp++;
    vm->code        = new_code;
    vm->code_length = new_len;
    vm->ip          = new_ip;
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
    // ----------------------------------------------------------------
    case OP_HALT:
        vm->halted = 1;
        return 0;

    // ----------------------------------------------------------------
    case OP_CONSTANT: {
        unsigned char idx = READ_BYTE();
        if (idx < vm->const_count)
            metal_vm_push(vm, vm->constants[idx]);
        else
            metal_vm_push(vm, mv_nil());
        break;
    }
    case OP_NIL:   metal_vm_push(vm, mv_nil());    break;
    case OP_TRUE:  metal_vm_push(vm, mv_bool(1));  break;
    case OP_FALSE: metal_vm_push(vm, mv_bool(0));  break;

    // ----------------------------------------------------------------
    case OP_POP:   metal_vm_pop(vm);               break;
    case OP_DUP:   metal_vm_push(vm, metal_vm_peek(vm, 0)); break;

    // ----------------------------------------------------------------
    case OP_DEFINE_GLOBAL: {
        unsigned char idx = READ_BYTE();
        const char *name = (idx < vm->const_count && vm->constants[idx].type == MV_STR)
                         ? metal_string_get(vm, vm->constants[idx].as.str_idx) : "";
        int hash = fnv1a(name, (int)bm_strlen(name));
        MetalValue val = metal_vm_pop(vm);
        scope_define(vm, hash, val);
        break;
    }
    case OP_GET_GLOBAL: {
        unsigned char idx = READ_BYTE();
        const char *name = (idx < vm->const_count && vm->constants[idx].type == MV_STR)
                         ? metal_string_get(vm, vm->constants[idx].as.str_idx) : "";
        int hash = fnv1a(name, (int)bm_strlen(name));
        MetalValue val = mv_nil();
        scope_get(vm, hash, &val);
        metal_vm_push(vm, val);
        break;
    }
    case OP_SET_GLOBAL: {
        unsigned char idx = READ_BYTE();
        const char *name = (idx < vm->const_count && vm->constants[idx].type == MV_STR)
                         ? metal_string_get(vm, vm->constants[idx].as.str_idx) : "";
        int hash = fnv1a(name, (int)bm_strlen(name));
        MetalValue val = metal_vm_peek(vm, 0); // leave on stack
        if (!scope_set(vm, hash, val))
            scope_define(vm, hash, val);
        break;
    }

    // ----------------------------------------------------------------
    case OP_PUSH_ENV:
        if (vm->scope_depth >= METAL_ENV_DEPTH) {
            vm->error = 1; vm->error_msg = "scope depth exceeded"; break;
        }
        bm_memset(&vm->scopes[vm->scope_depth], 0, sizeof(MetalScope));
        vm->scope_depth++;
        break;
    case OP_POP_ENV:
        if (vm->scope_depth > 0) vm->scope_depth--;
        break;

    // ----------------------------------------------------------------
    // Arithmetic
    // ----------------------------------------------------------------
    case OP_ADD: {
        MetalValue b = metal_vm_pop(vm);
        MetalValue a = metal_vm_pop(vm);
        if (a.type == MV_NUM && b.type == MV_NUM)
            metal_vm_push(vm, mv_num(a.as.number + b.as.number));
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
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?mv_num(a.as.number-b.as.number):mv_nil()); break; }
    case OP_MUL: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?mv_num(a.as.number*b.as.number):mv_nil()); break; }
    case OP_DIV: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        if(a.type==MV_NUM&&b.type==MV_NUM&&b.as.number!=0.0) metal_vm_push(vm,mv_num(a.as.number/b.as.number));
        else metal_vm_push(vm,mv_nil()); break; }
    case OP_MOD: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        if(a.type==MV_NUM&&b.type==MV_NUM&&b.as.number!=0.0) {
            long long ia=(long long)a.as.number,ib=(long long)b.as.number;
            metal_vm_push(vm,mv_num((double)(ia%ib)));
        } else metal_vm_push(vm,mv_nil()); break; }
    case OP_NEGATE: { MetalValue a=metal_vm_pop(vm);
        metal_vm_push(vm,a.type==MV_NUM?mv_num(-a.as.number):mv_nil()); break; }
    case OP_NOT: { MetalValue a=metal_vm_pop(vm);
        metal_vm_push(vm,mv_bool(a.type==MV_NIL||(a.type==MV_BOOL&&!a.as.boolean))); break; }
    case OP_TRUTHY: { MetalValue a=metal_vm_pop(vm);
        metal_vm_push(vm,mv_bool(!(a.type==MV_NIL||(a.type==MV_BOOL&&!a.as.boolean)))); break; }

    // ----------------------------------------------------------------
    // Bitwise
    // ----------------------------------------------------------------
    case OP_BIT_AND: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?
            mv_num((double)((long long)a.as.number&(long long)b.as.number)):mv_nil()); break; }
    case OP_BIT_OR:  { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?
            mv_num((double)((long long)a.as.number|(long long)b.as.number)):mv_nil()); break; }
    case OP_BIT_XOR: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?
            mv_num((double)((long long)a.as.number^(long long)b.as.number)):mv_nil()); break; }
    case OP_BIT_NOT: { MetalValue a=metal_vm_pop(vm);
        metal_vm_push(vm,a.type==MV_NUM?mv_num((double)(~(long long)a.as.number)):mv_nil()); break; }
    case OP_SHIFT_LEFT:  { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?
            mv_num((double)((long long)a.as.number<<(int)b.as.number)):mv_nil()); break; }
    case OP_SHIFT_RIGHT: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        metal_vm_push(vm,(a.type==MV_NUM&&b.type==MV_NUM)?
            mv_num((double)((long long)a.as.number>>(int)b.as.number)):mv_nil()); break; }

    // ----------------------------------------------------------------
    // Comparison
    // ----------------------------------------------------------------
    case OP_EQUAL: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        int eq=0;
        if(a.type==b.type){
            if(a.type==MV_NIL) eq=1;
            else if(a.type==MV_BOOL)   eq=(a.as.boolean==b.as.boolean);
            else if(a.type==MV_NUM)    eq=(a.as.number==b.as.number);
            else if(a.type==MV_STR)    eq=(bm_strcmp(metal_string_get(vm,a.as.str_idx),metal_string_get(vm,b.as.str_idx))==0);
            else if(a.type==MV_PTR)    eq=(a.as.ptr==b.as.ptr);
        }
        metal_vm_push(vm,mv_bool(eq)); break; }
    case OP_NOT_EQUAL: { MetalValue b=metal_vm_pop(vm),a=metal_vm_pop(vm);
        int eq=0;
        if(a.type==b.type){
            if(a.type==MV_NIL) eq=1;
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

    // ----------------------------------------------------------------
    // Control flow
    // ----------------------------------------------------------------
    case OP_JUMP: {
        unsigned short offset = READ_U16();
        vm->ip += (int)(short)offset;
        break;
    }
    case OP_JUMP_IF_FALSE: {
        unsigned short offset = READ_U16();
        MetalValue cond = metal_vm_peek(vm, 0);
        if (cond.type == MV_NIL || (cond.type == MV_BOOL && !cond.as.boolean))
            vm->ip += (int)(short)offset;
        break;
    }
    case OP_LOOP_BACK: {
        unsigned short offset = READ_U16();
        vm->ip -= (int)(unsigned short)offset;
        break;
    }
    case OP_BREAK:    vm->halted = 1; break; // host handles break context
    case OP_CONTINUE: break;                 // host handles continue context

    // ----------------------------------------------------------------
    // Functions
    // ----------------------------------------------------------------
    case OP_DEFINE_FN:
    case OP_LOAD_FUNCTION: {
        unsigned char fn_idx = READ_BYTE();
        MetalValue v; v.type = MV_FN; v.as.fn_idx = fn_idx;
        metal_vm_push(vm, v);
        break;
    }
    case OP_CALL: {
        unsigned char argc = READ_BYTE();
        (void)argc;
        MetalValue callee = metal_vm_pop(vm);
        if (callee.type == MV_FN) {
            int fi = callee.as.fn_idx;
            if (fi >= 0 && fi < vm->fn_count) {
                MetalFunction *fn = &vm->functions[fi];
                push_call_frame(vm, fn->code_offset, vm->code, vm->code_length);
                // push new scope
                if (vm->scope_depth < METAL_ENV_DEPTH) {
                    bm_memset(&vm->scopes[vm->scope_depth], 0, sizeof(MetalScope));
                    vm->scope_depth++;
                }
            }
        }
        break;
    }
    case OP_RETURN: {
        if (vm->scope_depth > 0) vm->scope_depth--;
        if (vm->csp == 0) { vm->halted = 1; break; }
        pop_call_frame(vm);
        break;
    }

    // ----------------------------------------------------------------
    // Arrays
    // ----------------------------------------------------------------
    case OP_ARRAY: {
        unsigned char count = READ_BYTE();
        int arr_idx = metal_array_new(vm);
        if (arr_idx < 0) break;
        // elements were pushed in order; pop in reverse, insert in order
        for (int i = count - 1; i >= 0; i--) {
            vm->arrays[arr_idx].elems[i] = metal_vm_pop(vm);
        }
        vm->arrays[arr_idx].count = (int)count;
        MetalValue v; v.type = MV_ARR; v.as.arr_idx = arr_idx;
        metal_vm_push(vm, v);
        break;
    }
    case OP_ARRAY_LEN: {
        MetalValue a = metal_vm_pop(vm);
        int len = (a.type == MV_ARR) ? metal_array_len(vm, a.as.arr_idx) : 0;
        metal_vm_push(vm, mv_num((double)len));
        break;
    }
    case OP_GET_INDEX: {
        MetalValue idx = metal_vm_pop(vm);
        MetalValue obj = metal_vm_pop(vm);
        if (obj.type == MV_ARR && idx.type == MV_NUM)
            metal_vm_push(vm, metal_array_get(vm, obj.as.arr_idx, (int)idx.as.number));
        else if (obj.type == MV_STR && idx.type == MV_NUM) {
            const char *s = metal_string_get(vm, obj.as.str_idx);
            int i = (int)idx.as.number;
            int slen = (int)bm_strlen(s);
            if (i >= 0 && i < slen) {
                char ch[1]; ch[0] = s[i];
                metal_vm_push(vm, mv_str(vm, ch, 1));
            } else metal_vm_push(vm, mv_nil());
        } else metal_vm_push(vm, mv_nil());
        break;
    }
    case OP_SET_INDEX: {
        MetalValue val = metal_vm_pop(vm);
        MetalValue idx = metal_vm_pop(vm);
        MetalValue obj = metal_vm_pop(vm);
        if (obj.type == MV_ARR && idx.type == MV_NUM) {
            int i = (int)idx.as.number;
            if (i >= 0 && i < METAL_ARRAY_MAX_ELEMS)
                vm->arrays[obj.as.arr_idx].elems[i] = val;
        }
        metal_vm_push(vm, val);
        break;
    }

    // ----------------------------------------------------------------
    // Tuples — treated as arrays
    // ----------------------------------------------------------------
    case OP_TUPLE: {
        unsigned char count = READ_BYTE();
        int arr_idx = metal_array_new(vm);
        if (arr_idx < 0) break;
        for (int i = count - 1; i >= 0; i--)
            vm->arrays[arr_idx].elems[i] = metal_vm_pop(vm);
        vm->arrays[arr_idx].count = (int)count;
        MetalValue v; v.type = MV_ARR; v.as.arr_idx = arr_idx;
        metal_vm_push(vm, v);
        break;
    }

    // ----------------------------------------------------------------
    // Dicts
    // ----------------------------------------------------------------
    case OP_DICT: {
        unsigned char count = READ_BYTE();
        int max = METAL_POOL_SIZE / 16;
        int di = -1;
        for (int i = 0; i < max; i++) {
            if (!vm->dicts[i].in_use) {
                bm_memset(&vm->dicts[i], 0, sizeof(MetalDict));
                vm->dicts[i].in_use = 1;
                if (i >= vm->dict_count) vm->dict_count = i + 1;
                di = i; break;
            }
        }
        if (di < 0) { metal_vm_push(vm, mv_nil()); break; }
        for (int i = 0; i < (int)count; i++) {
            MetalValue val = metal_vm_pop(vm);
            MetalValue key = metal_vm_pop(vm);
            if (vm->dicts[di].count < METAL_DICT_MAX_ENTRIES) {
                int ki = (key.type == MV_STR) ? key.as.str_idx : -1;
                vm->dicts[di].key_str_idx[vm->dicts[di].count] = ki;
                vm->dicts[di].values[vm->dicts[di].count]      = val;
                vm->dicts[di].count++;
            }
        }
        MetalValue v; v.type = MV_DICT; v.as.dict_idx = di;
        metal_vm_push(vm, v);
        break;
    }
    case OP_GET_PROPERTY: {
        unsigned char idx = READ_BYTE();
        MetalValue key = (idx < vm->const_count) ? vm->constants[idx] : mv_nil();
        MetalValue obj = metal_vm_pop(vm);
        if (obj.type == MV_DICT && key.type == MV_STR) {
            MetalDict *d = &vm->dicts[obj.as.dict_idx];
            MetalValue found = mv_nil();
            for (int i = 0; i < d->count; i++) {
                if (d->key_str_idx[i] == key.as.str_idx) { found = d->values[i]; break; }
            }
            metal_vm_push(vm, found);
        } else metal_vm_push(vm, mv_nil());
        break;
    }
    case OP_SET_PROPERTY: {
        unsigned char idx = READ_BYTE();
        MetalValue key = (idx < vm->const_count) ? vm->constants[idx] : mv_nil();
        MetalValue val = metal_vm_pop(vm);
        MetalValue obj = metal_vm_peek(vm, 0);
        if (obj.type == MV_DICT && key.type == MV_STR) {
            MetalDict *d = &vm->dicts[obj.as.dict_idx];
            int found = 0;
            for (int i = 0; i < d->count; i++) {
                if (d->key_str_idx[i] == key.as.str_idx) { d->values[i] = val; found = 1; break; }
            }
            if (!found && d->count < METAL_DICT_MAX_ENTRIES) {
                d->key_str_idx[d->count] = key.as.str_idx;
                d->values[d->count] = val;
                d->count++;
            }
        }
        break;
    }

    // ----------------------------------------------------------------
    // Print
    // ----------------------------------------------------------------
    case OP_PRINT: {
        MetalValue v = metal_vm_pop(vm);
        metal_print_value(vm, v);
        if (vm->write_char) vm->write_char('\n');
        break;
    }

    // ----------------------------------------------------------------
    // Exception handling stubs
    // ----------------------------------------------------------------
    case OP_SETUP_TRY: {
        unsigned short offset = READ_U16();
        if (vm->hsp < 128) {
            vm->handlers[vm->hsp].ip         = vm->ip + (int)(short)offset;
            vm->handlers[vm->hsp].stack_size = vm->sp;
            vm->hsp++;
        }
        break;
    }
    case OP_END_TRY:
        if (vm->hsp > 0) vm->hsp--;
        break;
    case OP_RAISE: {
        vm->exception_value = metal_vm_pop(vm);
        vm->is_throwing = 1;
        if (vm->hsp > 0) {
            vm->hsp--;
            vm->ip = vm->handlers[vm->hsp].ip;
            vm->sp = vm->handlers[vm->hsp].stack_size;
            metal_vm_push(vm, vm->exception_value);
            vm->is_throwing = 0;
        } else {
            vm->error = 1;
            vm->error_msg = "unhandled exception";
        }
        break;
    }

    // ----------------------------------------------------------------
    // Import / class / method / inherit — stubs (no dynamic loader)
    // ----------------------------------------------------------------
    case OP_IMPORT:     { READ_BYTE(); break; }
    case OP_CLASS:      { READ_BYTE(); break; }
    case OP_METHOD:     { READ_BYTE(); break; }
    case OP_CALL_METHOD:{ READ_BYTE(); break; }
    case OP_INHERIT:    break;
    case OP_SLICE:      break;
    case OP_EXEC_AST_STMT: break;

    // ----------------------------------------------------------------
    // GPU opcodes — no-op on bare-metal rv64 without a GPU
    // ----------------------------------------------------------------
    case OP_GPU_POLL_EVENTS:          break;
    case OP_GPU_WINDOW_SHOULD_CLOSE:  metal_vm_push(vm, mv_bool(0)); break;
    case OP_GPU_GET_TIME:             metal_vm_push(vm, mv_num(0.0)); break;
    case OP_GPU_KEY_PRESSED:          metal_vm_push(vm, mv_bool(0)); break;
    case OP_GPU_KEY_DOWN:             metal_vm_push(vm, mv_bool(0)); break;
    case OP_GPU_MOUSE_POS:            metal_vm_push(vm, mv_num(0.0)); metal_vm_push(vm, mv_num(0.0)); break;
    case OP_GPU_MOUSE_DELTA:          metal_vm_push(vm, mv_num(0.0)); metal_vm_push(vm, mv_num(0.0)); break;
    case OP_GPU_UPDATE_INPUT:         break;
    case OP_GPU_BEGIN_COMMANDS:       break;
    case OP_GPU_END_COMMANDS:         break;
    case OP_GPU_CMD_BEGIN_RP:         break;
    case OP_GPU_CMD_END_RP:           break;
    case OP_GPU_CMD_DRAW:             break;
    case OP_GPU_CMD_BIND_GP:          break;
    case OP_GPU_CMD_BIND_DS:          break;
    case OP_GPU_CMD_SET_VP:           break;
    case OP_GPU_CMD_SET_SC:           break;
    case OP_GPU_CMD_BIND_VB:          break;
    case OP_GPU_CMD_BIND_IB:          break;
    case OP_GPU_CMD_DRAW_IDX:         break;
    case OP_GPU_SUBMIT_SYNC:          break;
    case OP_GPU_ACQUIRE_IMG:          break;
    case OP_GPU_PRESENT:              break;
    case OP_GPU_WAIT_FENCE:           break;
    case OP_GPU_RESET_FENCE:          break;
    case OP_GPU_UPDATE_UNIFORM:       break;
    case OP_GPU_CMD_PUSH_CONST:       break;
    case OP_GPU_CMD_DISPATCH:         break;

    default:
        // Unknown opcode — halt gracefully
        vm->error = 1;
        vm->error_msg = "unknown opcode";
        vm->halted = 1;
        break;
    }

    return !vm->halted && !vm->error;
}

// ---------------------------------------------------------------------------
// Run loop
// ---------------------------------------------------------------------------

int metal_vm_run(MetalVM *vm) {
    // Ensure at least one scope exists
    if (vm->scope_depth == 0) {
        bm_memset(&vm->scopes[0], 0, sizeof(MetalScope));
        vm->scope_depth = 1;
    }
    while (!vm->halted && !vm->error)
        metal_vm_step(vm);
    return vm->error ? 0 : 1;
}

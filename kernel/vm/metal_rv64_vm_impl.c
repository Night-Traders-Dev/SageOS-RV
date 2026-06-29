// ============================================================================
// metal_rv64_vm_impl.c — Freestanding RISC-V 64-bit Register-Based VM
// ============================================================================
// Executes .sgrv (Sage RISC-V) binaries using fixed 32-bit RV64I instructions.
// Numbers stored as Q32.32 fixed-point (int64_t). No libc, no malloc.
// Compiles with: -ffreestanding -nostdlib -DSAGE_BARE_METAL -DSAGE_METAL_VM
// ============================================================================

#ifdef SAGELANG_METAL_RV64_VM_H_PATH
#  include SAGELANG_METAL_RV64_VM_H_PATH
#else
#  include "metal_rv64_vm.h"
#endif

// ---------------------------------------------------------------------------
// Freestanding libc replacements
// ---------------------------------------------------------------------------
static void rv_memset(void *dst, int val, unsigned long n) {
    unsigned char *p = (unsigned char *)dst;
    while (n--) *p++ = (unsigned char)val;
}

static void rv_memcpy(void *dst, const void *src, unsigned long n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
}

static int rv_strlen(const char *s) {
    int n = 0;
    while (*s++) n++;
    return n;
}

static int rv_strcmp(const char *s1, const char *s2) {
    while (*s1 && *s1 == *s2) { s1++; s2++; }
    return *(const unsigned char *)s1 - *(const unsigned char *)s2;
}

// ---------------------------------------------------------------------------
// Q32.32 fixed-point helpers
// ---------------------------------------------------------------------------
#define FP_SHIFT   32
#define FP_ONE     ((int64_t)1 << FP_SHIFT)
#define FP_HALF    (FP_ONE >> 1)

static inline int64_t fp_from_int(int64_t i)  { return i << FP_SHIFT; }
static inline int64_t fp_to_int(int64_t f)    { return f >> FP_SHIFT; }

static inline int64_t fp_mul(int64_t a, int64_t b) {
    return (int64_t)(((__int128)a * (__int128)b) >> FP_SHIFT);
}

static inline int64_t fp_div(int64_t a, int64_t b) {
    if (b == 0) return 0;
    uint64_t neg = 0;
    if (a < 0) { a = -a; neg ^= 1; }
    if (b < 0) { b = -b; neg ^= 1; }
    uint64_t hi = ((uint64_t)a) >> 32;
    uint64_t lo = ((uint64_t)a) << 32;
    uint64_t ub = (uint64_t)b;
    uint64_t q = 0;
    uint64_t r = hi;
    for (int i = 0; i < 64; i++) {
        uint64_t next = lo >> 63;
        r = (r << 1) | next;
        lo <<= 1;
        q <<= 1;
        if (r >= ub) { r -= ub; q |= 1; }
    }
    if (r > (ub >> 1)) q++;
    else if (r == (ub >> 1) && (ub & 1) && (q & 1)) q++;
    int64_t result = (int64_t)q;
    return (int64_t)(neg ? -result : result);
}

static int64_t fp_from_ieee754(uint64_t bits) {
    if (bits == 0) return 0;
    int     sign = (bits >> 63) ? -1 : 1;
    int     exp  = (int)((bits >> 52) & 0x7FF) - 1023;
    int64_t mant = (int64_t)((bits & 0x000FFFFFFFFFFFFFULL) | 0x0010000000000000ULL);
    int shift = exp - 20;
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
// Print helpers
// ---------------------------------------------------------------------------
static void rv_print_str(MetalRV64VM *vm, const char *s) {
    if (!vm->write_char) return;
    while (*s) vm->write_char(*s++);
}

static void rv_print_int(MetalRV64VM *vm, long long n) {
    if (n < 0) { if (vm->write_char) vm->write_char('-'); n = -n; }
    char buf[24];
    int i = 0;
    if (n == 0) { buf[i++] = '0'; }
    else { while (n > 0) { buf[i++] = '0' + (int)(n % 10); n /= 10; } }
    while (--i >= 0) if (vm->write_char) vm->write_char(buf[i]);
}

static void rv_print_fixed(MetalRV64VM *vm, int64_t fp) {
    if (fp < 0) { if (vm->write_char) vm->write_char('-'); fp = -fp; }
    int64_t ipart = fp_to_int(fp);
    int64_t frac  = fp & (FP_ONE - 1);
    rv_print_int(vm, ipart);
    if (frac != 0) {
        if (vm->write_char) vm->write_char('.');
        for (int i = 0; i < 9; i++) {
            frac *= 10;
            int64_t digit = fp_to_int(frac);
            if (vm->write_char) vm->write_char('0' + (int)digit);
            frac &= (FP_ONE - 1);
        }
    }
}

static void rv_print_value(MetalRV64VM *vm, MetalValue value) {
    switch (value.type) {
        case MV_NUM:
            rv_print_fixed(vm, value.as.number);
            break;
        case MV_BOOL:
            rv_print_str(vm, value.as.boolean ? "true" : "false");
            break;
        case MV_STR: {
            int idx = value.as.str_idx;
            if (idx >= 0 && idx < vm->string_used)
                rv_print_str(vm, &vm->strings[idx]);
            break;
        }
        case MV_ARR: {
            rv_print_str(vm, "[");
            int arr_idx = value.as.arr_idx;
            int max_a = (int)(sizeof(vm->arrays) / sizeof(vm->arrays[0]));
            if (arr_idx >= 0 && arr_idx < max_a) {
                int len = vm->arrays[arr_idx].count;
                for (int i = 0; i < len; i++) {
                    if (i > 0) rv_print_str(vm, ", ");
                    rv_print_value(vm, vm->arrays[arr_idx].elems[i]);
                }
            }
            rv_print_str(vm, "]");
            break;
        }
        case MV_PTR:
            rv_print_str(vm, "<ptr>");
            break;
        case MV_NIL:
        default:
            rv_print_str(vm, "nil");
            break;
    }
}

// ---------------------------------------------------------------------------
// String pool
// ---------------------------------------------------------------------------
static int rv_string_intern(MetalRV64VM *vm, const char *s, int len) {
    int search = 0;
    while (search < vm->string_used) {
        const char *existing = &vm->strings[search];
        int existing_len = rv_strlen(existing);
        if (existing_len == len) {
            int match = 1;
            for (int i = 0; i < len; i++) {
                if (existing[i] != s[i]) { match = 0; break; }
            }
            if (match) return search;
        }
        search += existing_len + 1;
    }
    if (vm->string_used + len + 1 > METAL_STRING_POOL) return -1;
    int idx = vm->string_used;
    rv_memcpy(&vm->strings[idx], s, (unsigned long)len);
    vm->strings[idx + len] = '\0';
    vm->string_used += len + 1;
    return idx;
}

static const char *rv_string_get(MetalRV64VM *vm, int idx) {
    if (idx < 0 || idx >= vm->string_used) return "";
    return &vm->strings[idx];
}

// ---------------------------------------------------------------------------
// Array pool
// ---------------------------------------------------------------------------
static int rv_array_new(MetalRV64VM *vm) {
    int max = (int)(sizeof(vm->arrays) / sizeof(vm->arrays[0]));
    if (vm->array_count >= max) return -1;
    int idx = vm->array_count++;
    vm->arrays[idx].count = 0;
    vm->arrays[idx].in_use = 1;
    return idx;
}

static void rv_array_push(MetalRV64VM *vm, int arr_idx, MetalValue val) {
    int max = (int)(sizeof(vm->arrays) / sizeof(vm->arrays[0]));
    if (arr_idx < 0 || arr_idx >= max) return;
    MetalArray *a = &vm->arrays[arr_idx];
    if (a->count >= METAL_ARRAY_MAX_ELEMS) return;
    a->elems[a->count++] = val;
}

static MetalValue rv_array_get(MetalRV64VM *vm, int arr_idx, int index) {
    int max = (int)(sizeof(vm->arrays) / sizeof(vm->arrays[0]));
    if (arr_idx < 0 || arr_idx >= max) return mv_nil();
    MetalArray *a = &vm->arrays[arr_idx];
    if (index < 0 || index >= a->count) return mv_nil();
    return a->elems[index];
}

static int rv_array_len(MetalRV64VM *vm, int arr_idx) {
    int max = (int)(sizeof(vm->arrays) / sizeof(vm->arrays[0]));
    if (arr_idx < 0 || arr_idx >= max) return 0;
    return vm->arrays[arr_idx].count;
}

// ---------------------------------------------------------------------------
// Dict pool
// ---------------------------------------------------------------------------
static int rv_dict_new(MetalRV64VM *vm) {
    int max = (int)(sizeof(vm->dicts) / sizeof(vm->dicts[0]));
    if (vm->dict_count >= max) return -1;
    int idx = vm->dict_count++;
    vm->dicts[idx].count = 0;
    vm->dicts[idx].in_use = 1;
    return idx;
}

static void rv_dict_set(MetalRV64VM *vm, int dict_idx, int key_str_idx, MetalValue val) {
    int max = (int)(sizeof(vm->dicts) / sizeof(vm->dicts[0]));
    if (dict_idx < 0 || dict_idx >= max) return;
    MetalDict *d = &vm->dicts[dict_idx];
    for (int i = 0; i < d->count; i++) {
        if (d->key_str_idx[i] == key_str_idx) {
            d->values[i] = val;
            return;
        }
    }
    if (d->count < METAL_DICT_MAX_ENTRIES) {
        d->key_str_idx[d->count] = key_str_idx;
        d->values[d->count] = val;
        d->count++;
    }
}

static MetalValue rv_dict_get(MetalRV64VM *vm, int dict_idx, int key_str_idx) {
    int max = (int)(sizeof(vm->dicts) / sizeof(vm->dicts[0]));
    if (dict_idx < 0 || dict_idx >= max) return mv_nil();
    MetalDict *d = &vm->dicts[dict_idx];
    for (int i = 0; i < d->count; i++) {
        if (d->key_str_idx[i] == key_str_idx) return d->values[i];
    }
    return mv_nil();
}

// ============================================================================
// Public API
// ============================================================================

void metal_rv64_vm_init(MetalRV64VM *vm) {
    rv_memset(vm, 0, sizeof(MetalRV64VM));
    vm->global_dict_idx = rv_dict_new(vm);
}

int metal_rv64_vm_load_binary(MetalRV64VM *vm, const unsigned char *data, int size) {
    if (size < 8) return -1;
    int pos = 0;

    if (data[pos++] != 'S' || data[pos++] != 'G' || data[pos++] != 'R' || data[pos++] != 'V')
        return -2;

    if (data[pos++] != 0x00 || data[pos++] != 0x01)
        return -3;

    int const_count = (data[pos] << 8) | data[pos + 1];
    pos += 2;

    for (int i = 0; i < const_count; i++) {
        unsigned char type = data[pos++];
        if (type == 1) { // MV_NUM — IEEE 754 double bits -> Q32.32
            uint64_t bits = 0;
            for (int j = 0; j < 8; j++)
                bits = (bits << 8) | data[pos + j];
            if (vm->const_count < METAL_CONST_POOL) {
                vm->constants[vm->const_count++] = mv_num_fp(fp_from_ieee754(bits));
            }
            pos += 8;
        } else if (type == 3) { // MV_STR
            int len = (data[pos] << 8) | data[pos + 1];
            pos += 2;
            int str_idx = rv_string_intern(vm, (const char *)&data[pos], len);
            if (vm->const_count < METAL_CONST_POOL) {
                vm->constants[vm->const_count++] = (MetalValue){MV_STR, {.str_idx = str_idx}};
            }
            pos += len;
        } else {
            return -4;
        }
    }

    int chunk_count = (data[pos] << 24) | (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
    pos += 4;

    for (int i = 0; i < chunk_count; i++) {
        int code_len = (data[pos] << 24) | (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
        pos += 4;
        if (pos + code_len > size) return -5;
        if (vm->chunk_count < RV64_MAX_CHUNKS) {
            vm->chunks[vm->chunk_count] = &data[pos];
            vm->chunk_lengths[vm->chunk_count] = code_len;
            vm->chunk_count++;
        }
        pos += code_len;
    }

    return 0;
}

void metal_rv64_vm_register_builtin(MetalRV64VM *vm, const char *name) {
    int name_idx = rv_string_intern(vm, name, rv_strlen(name));
    int d_idx = rv_dict_new(vm);
    rv_dict_set(vm, d_idx,
        rv_string_intern(vm, "__builtin__", 11),
        (MetalValue){MV_STR, {.str_idx = name_idx}});
    rv_dict_set(vm, vm->global_dict_idx, name_idx,
        (MetalValue){MV_DICT, {.dict_idx = d_idx}});
}

void metal_rv64_vm_register_kernel_builtins(MetalRV64VM *vm) {
    metal_rv64_vm_register_builtin(vm, "mem_write");
    metal_rv64_vm_register_builtin(vm, "mem_read");
    metal_rv64_vm_register_builtin(vm, "pass");
    metal_rv64_vm_register_builtin(vm, "push");
    metal_rv64_vm_register_builtin(vm, "len");
    metal_rv64_vm_register_builtin(vm, "str");
    metal_rv64_vm_register_builtin(vm, "int");
    metal_rv64_vm_register_builtin(vm, "array");
    metal_rv64_vm_register_builtin(vm, "readline");
    metal_rv64_vm_register_builtin(vm, "read");
    metal_rv64_vm_register_builtin(vm, "input");
    metal_rv64_vm_register_builtin(vm, "streq");
    metal_rv64_vm_register_builtin(vm, "wdog_kick");
    metal_rv64_vm_register_builtin(vm, "shell_exec");
    metal_rv64_vm_register_builtin(vm, "SRVM");
}

RV64Instruction rv64_decode(unsigned int raw) {
    RV64Instruction inst;
    inst.opcode = raw & 0x7F;
    inst.rd     = (raw >> 7) & 0x1F;
    inst.funct3 = (raw >> 12) & 0x07;
    inst.rs1    = (raw >> 15) & 0x1F;
    inst.rs2    = (raw >> 20) & 0x1F;
    inst.funct7 = (raw >> 25) & 0x7F;

    int imm_i_raw = (raw >> 20) & 0xFFF;
    inst.imm_i = (imm_i_raw & 0x800) ? (imm_i_raw | ~0xFFF) : imm_i_raw;

    int imm_s_raw = ((raw >> 7) & 0x1F) | (((raw >> 25) & 0x7F) << 5);
    inst.imm_s = (imm_s_raw & 0x800) ? (imm_s_raw | ~0xFFF) : imm_s_raw;

    int imm_b_raw = (((raw >> 7) & 0x01) << 11) |
                    (((raw >> 8) & 0x0F) << 1) |
                    (((raw >> 25) & 0x3F) << 5) |
                    (((raw >> 31) & 0x01) << 12);
    inst.imm_b = (imm_b_raw & 0x1000) ? (imm_b_raw | ~0x1FFF) : imm_b_raw;

    inst.imm_u = raw & 0xFFFFF000;

    int imm_j_raw = (((raw >> 12) & 0xFF) << 12) |
                    (((raw >> 20) & 0x01) << 11) |
                    (((raw >> 21) & 0x3FF) << 1) |
                    (((raw >> 31) & 0x01) << 20);
    inst.imm_j = (imm_j_raw & 0x100000) ? (imm_j_raw | ~0x1FFFFF) : imm_j_raw;

    return inst;
}

// ============================================================================
// Execution Handlers
// ============================================================================

static void handle_branch(MetalRV64VM *vm, RV64Instruction inst) {
    MetalValue rs1_val = vm->x[inst.rs1];
    MetalValue rs2_val = vm->x[inst.rs2];
    int take = 0;

    if (rs1_val.type == MV_NUM && rs2_val.type == MV_NUM) {
        int64_t a = rs1_val.as.number;
        int64_t b = rs2_val.as.number;
        switch (inst.funct3) {
            case RV_F3_BEQ:  take = (a == b); break;
            case RV_F3_BNE:  take = (a != b); break;
            case RV_F3_BLT:  take = (a < b); break;
            case RV_F3_BGE:  take = (a >= b); break;
            case RV_F3_BLTU: take = ((uint64_t)a < (uint64_t)b); break;
            case RV_F3_BGEU: take = ((uint64_t)a >= (uint64_t)b); break;
        }
    } else if (rs1_val.type == MV_STR && rs2_val.type == MV_STR) {
        const char *a = rv_string_get(vm, rs1_val.as.str_idx);
        const char *b = rv_string_get(vm, rs2_val.as.str_idx);
        int cmp = rv_strcmp(a, b);
        switch (inst.funct3) {
            case RV_F3_BEQ: take = (cmp == 0); break;
            case RV_F3_BNE: take = (cmp != 0); break;
            case RV_F3_BLT: take = (cmp < 0); break;
            case RV_F3_BGE: take = (cmp >= 0); break;
        }
    } else if (rs1_val.type == MV_BOOL && rs2_val.type == MV_BOOL) {
        int a = rs1_val.as.boolean;
        int b = rs2_val.as.boolean;
        switch (inst.funct3) {
            case RV_F3_BEQ: take = (a == b); break;
            case RV_F3_BNE: take = (a != b); break;
        }
    } else if (rs1_val.type == MV_NIL && rs2_val.type == MV_NIL) {
        switch (inst.funct3) {
            case RV_F3_BEQ: take = 1; break;
            case RV_F3_BNE: take = 0; break;
        }
    } else {
        switch (inst.funct3) {
            case RV_F3_BEQ: take = 0; break;
            case RV_F3_BNE: take = 1; break;
        }
    }

    if (take) vm->pc += inst.imm_b;
    else      vm->pc += 4;
}

static void handle_imm(MetalRV64VM *vm, RV64Instruction inst) {
    MetalValue rs1_val = vm->x[inst.rs1];
    int imm = inst.imm_i;
    int64_t val = (rs1_val.type == MV_NUM) ? rs1_val.as.number : 0;

    switch (inst.funct3) {
        case RV_F3_ADD: // ADDI
            if (imm == 0)
                vm->x[inst.rd] = rs1_val;
            else
                vm->x[inst.rd] = mv_num_fp(val + fp_from_int(imm));
            break;
        case RV_F3_SLT: // SLTI
            vm->x[inst.rd] = mv_bool(val < fp_from_int(imm));
            break;
        case RV_F3_XOR: // XORI
            if (imm == 0)
                vm->x[inst.rd] = rs1_val;
            else
                vm->x[inst.rd] = mv_num(fp_to_int(val) ^ imm);
            break;
        case RV_F3_OR: // ORI
            if (imm == 0)
                vm->x[inst.rd] = rs1_val;
            else
                vm->x[inst.rd] = mv_num(fp_to_int(val) | imm);
            break;
        case RV_F3_AND: // ANDI
            if (imm == -1)
                vm->x[inst.rd] = rs1_val;
            else
                vm->x[inst.rd] = mv_num(fp_to_int(val) & imm);
            break;
        case RV_F3_SLL: // SLLI
            vm->x[inst.rd] = mv_num(fp_to_int(val) << (imm & 0x3F));
            break;
        case RV_F3_SRL: // SRLI / SRAI
            if (inst.funct7 == 0x20)
                vm->x[inst.rd] = mv_num(fp_to_int(val) >> (imm & 0x3F));
            else
                vm->x[inst.rd] = mv_num((int64_t)((uint64_t)fp_to_int(val) >> (imm & 0x3F)));
            break;
        default:
            vm->x[inst.rd] = mv_nil();
            break;
    }
    vm->pc += 4;
}

static void handle_reg(MetalRV64VM *vm, RV64Instruction inst) {
    MetalValue rs1_val = vm->x[inst.rs1];
    MetalValue rs2_val = vm->x[inst.rs2];
    int64_t v1 = (rs1_val.type == MV_NUM) ? rs1_val.as.number : 0;
    int64_t v2 = (rs2_val.type == MV_NUM) ? rs2_val.as.number : 0;

    if (inst.funct7 == 0x01) { // RV64M Extension (Mul/Div/Rem)
        switch (inst.funct3) {
            case RV_F3_ADD: // MUL
                vm->x[inst.rd] = mv_num_fp(fp_mul(v1, v2));
                break;
            case RV_F3_XOR: // DIV
                if (v2 != 0)
                    vm->x[inst.rd] = mv_num(fp_to_int(v1) / fp_to_int(v2));
                else {
                    vm->x[inst.rd] = mv_num(0);
                    vm->error = 1; vm->error_msg = "division by zero";
                }
                break;
            case RV_F3_OR: // REM
                if (v2 != 0)
                    vm->x[inst.rd] = mv_num(fp_to_int(v1) % fp_to_int(v2));
                else {
                    vm->x[inst.rd] = mv_num(0);
                    vm->error = 1; vm->error_msg = "modulo by zero";
                }
                break;
            default:
                vm->x[inst.rd] = mv_nil();
                break;
        }
        vm->pc += 4;
        return;
    }

    switch (inst.funct3) {
        case RV_F3_ADD:
            if (inst.funct7 == 0x20) { // SUB
                if (inst.rs2 == 0)
                    vm->x[inst.rd] = rs1_val;
                else
                    vm->x[inst.rd] = mv_num_fp(v1 - v2);
            } else { // ADD
                if (inst.rs2 == 0)
                    vm->x[inst.rd] = rs1_val;
                else if (inst.rs1 == 0)
                    vm->x[inst.rd] = rs2_val;
                else if (rs1_val.type == MV_STR && rs2_val.type == MV_STR) {
                    const char *s1 = rv_string_get(vm, rs1_val.as.str_idx);
                    const char *s2 = rv_string_get(vm, rs2_val.as.str_idx);
                    int len1 = rv_strlen(s1);
                    int len2 = rv_strlen(s2);
                    char concat_buf[1024];
                    if (len1 + len2 < 1024) {
                        rv_memcpy(concat_buf, s1, len1);
                        rv_memcpy(concat_buf + len1, s2, len2);
                        int new_idx = rv_string_intern(vm, concat_buf, len1 + len2);
                        vm->x[inst.rd] = (MetalValue){MV_STR, {.str_idx = new_idx}};
                    } else {
                        vm->error = 1;
                        vm->error_msg = "String concatenation buffer overflow";
                        vm->x[inst.rd] = mv_nil();
                    }
                } else {
                    vm->x[inst.rd] = mv_num_fp(v1 + v2);
                }
            }
            break;
        case RV_F3_SLL:
            vm->x[inst.rd] = mv_num(fp_to_int(v1) << ((int)fp_to_int(v2) & 0x3F));
            break;
        case RV_F3_SLT:
            if (rs1_val.type == MV_STR && rs2_val.type == MV_STR) {
                const char *a = rv_string_get(vm, rs1_val.as.str_idx);
                const char *b = rv_string_get(vm, rs2_val.as.str_idx);
                vm->x[inst.rd] = mv_bool(rv_strcmp(a, b) < 0);
            } else {
                vm->x[inst.rd] = mv_bool(v1 < v2);
            }
            break;
        case RV_F3_XOR:
            vm->x[inst.rd] = mv_num(fp_to_int(v1) ^ fp_to_int(v2));
            break;
        case RV_F3_SRL:
            if (inst.funct7 == 0x20)
                vm->x[inst.rd] = mv_num(fp_to_int(v1) >> ((int)fp_to_int(v2) & 0x3F));
            else
                vm->x[inst.rd] = mv_num((int64_t)((uint64_t)fp_to_int(v1) >> ((int)fp_to_int(v2) & 0x3F)));
            break;
        case RV_F3_OR:
            vm->x[inst.rd] = mv_num(fp_to_int(v1) | fp_to_int(v2));
            break;
        case RV_F3_AND:
            vm->x[inst.rd] = mv_num(fp_to_int(v1) & fp_to_int(v2));
            break;
        default:
            vm->x[inst.rd] = mv_nil();
            break;
    }
    vm->pc += 4;
}

static void handle_ldc(MetalRV64VM *vm, RV64Instruction inst) {
    int idx = (inst.imm_u >> 12) & 0xFFFFF;
    if (idx >= 0 && idx < vm->const_count) {
        vm->x[inst.rd] = vm->constants[idx];
    } else {
        vm->error = 1;
        vm->error_msg = "Constant pool access violation";
        vm->x[inst.rd] = mv_nil();
    }
    vm->pc += 4;
}

static void handle_load(MetalRV64VM *vm, RV64Instruction inst) {
    int addr = 0;
    if (vm->x[inst.rs1].type == MV_NUM) {
        addr = (int)fp_to_int(vm->x[inst.rs1].as.number);
    }
    addr += inst.imm_i;

    if (addr >= 0 && addr < RV64_STACK_SIZE) {
        vm->x[inst.rd] = vm->stack[addr];
    } else {
        vm->error = 1;
        vm->error_msg = "Load access violation";
        vm->x[inst.rd] = mv_nil();
    }
    vm->pc += 4;
}

static void handle_store(MetalRV64VM *vm, RV64Instruction inst) {
    int addr = 0;
    if (vm->x[inst.rs1].type == MV_NUM) {
        addr = (int)fp_to_int(vm->x[inst.rs1].as.number);
    }
    addr += inst.imm_s;

    MetalValue val = vm->x[inst.rs2];
    if (addr >= 0 && addr < RV64_STACK_SIZE) {
        vm->stack[addr] = val;
    } else {
        vm->error = 1;
        vm->error_msg = "Store access violation";
    }
    vm->pc += 4;
}

static void handle_vmsys(MetalRV64VM *vm, RV64Instruction inst) {
    int sub_op = inst.rs1;

    if (inst.funct3 == RV_F3_VM_OPS) {
        switch (sub_op) {
            case RV_VMO_NOP:
                // NOP / register bind: copy x10 (a0) to rd register
                if (inst.rd != 0)
                    vm->x[inst.rd] = vm->x[10];
                break;
            case RV_VMO_HALT:
                vm->running = 0;
                vm->halted = 1;
                break;
            case RV_VMO_PRINT:
            case RV_VMO_PRINTM:
                rv_print_value(vm, vm->x[10]);
                if (vm->write_char) vm->write_char('\n');
                break;
            case RV_VMO_PUSH_ENV:
                break;
            case RV_VMO_POP_ENV:
                break;
            case RV_VMO_CALL: {
                MetalValue func_obj = vm->x[inst.rs2];
                int target_chunk = -1;
                if (func_obj.type == MV_NUM) {
                    target_chunk = (int)fp_to_int(func_obj.as.number);
                } else if (func_obj.type == MV_DICT) {
                    MetalValue type_val = rv_dict_get(vm, func_obj.as.dict_idx,
                        rv_string_intern(vm, "__type__", 8));
                    if (type_val.type == MV_STR && rv_strcmp(rv_string_get(vm, type_val.as.str_idx), "class") == 0) {
                        int inst_dict = rv_dict_new(vm);
                        rv_dict_set(vm, inst_dict,
                            rv_string_intern(vm, "__type__", 8),
                            (MetalValue){MV_STR, {.str_idx = rv_string_intern(vm, "instance", 8)}});
                        rv_dict_set(vm, inst_dict,
                            rv_string_intern(vm, "__class__", 9), func_obj);

                        MetalValue methods_val = rv_dict_get(vm, func_obj.as.dict_idx,
                            rv_string_intern(vm, "__methods__", 11));
                        MetalValue init_func = mv_nil();
                        if (methods_val.type == MV_DICT) {
                            init_func = rv_dict_get(vm, methods_val.as.dict_idx,
                                rv_string_intern(vm, "init", 4));
                        }

                        if (init_func.type == MV_DICT) {
                            MetalValue chunk_idx_val = rv_dict_get(vm, init_func.as.dict_idx,
                                rv_string_intern(vm, "chunk_idx", 9));
                            if (chunk_idx_val.type == MV_NUM) {
                                target_chunk = (int)fp_to_int(chunk_idx_val.as.number);
                            }

                            if (target_chunk >= 0 && target_chunk < vm->chunk_count) {
                                if (vm->csp < RV64_CALL_STACK_SIZE) {
                                    vm->call_stack[vm->csp].chunk_idx = vm->current_chunk_idx;
                                    vm->call_stack[vm->csp].return_pc = vm->pc + 4;
                                    vm->call_stack[vm->csp].saved_ra = vm->x[1];
                                    vm->call_stack[vm->csp].is_constructor = 1;
                                    vm->call_stack[vm->csp].constructor_instance =
                                        (MetalValue){MV_DICT, {.dict_idx = inst_dict}};
                                    vm->csp++;

                                    for (int r = 17; r > 10; r--)
                                        vm->x[r] = vm->x[r - 1];
                                    vm->x[10] = (MetalValue){MV_DICT, {.dict_idx = inst_dict}};

                                    vm->current_chunk_idx = target_chunk;
                                    vm->bytecode = vm->chunks[target_chunk];
                                    vm->bytecode_length = vm->chunk_lengths[target_chunk];
                                    vm->pc = 0;
                                    vm->x[1] = mv_num(0);
                                    return;
                                } else {
                                    vm->error = 1;
                                    vm->error_msg = "Call stack overflow";
                                }
                            } else {
                                vm->error = 1;
                                vm->error_msg = "Invalid constructor chunk index";
                            }
                        } else {
                            vm->x[10] = (MetalValue){MV_DICT, {.dict_idx = inst_dict}};
                            vm->pc += 4;
                        }
                        return;
                    }

                    MetalValue builtin = rv_dict_get(vm, func_obj.as.dict_idx,
                        rv_string_intern(vm, "__builtin__", 11));
                    if (builtin.type == MV_STR) {
                        const char *b_name = rv_string_get(vm, builtin.as.str_idx);
                        if (rv_strcmp(b_name, "str") == 0) {
                            int str_idx = rv_string_intern(vm, "", 0);
                            if (vm->x[10].type == MV_NUM) {
                                int64_t d = vm->x[10].as.number;
                                int64_t integer = fp_to_int(d);
                                int is_neg = 0;
                                if (integer < 0) { is_neg = 1; integer = -integer; }
                                int len = 0;
                                char rev[24];
                                if (integer == 0) rev[len++] = '0';
                                else {
                                    while (integer > 0) {
                                        rev[len++] = '0' + (int)(integer % 10);
                                        integer /= 10;
                                    }
                                }
                                char fin[32];
                                int pos = 0;
                                if (is_neg) fin[pos++] = '-';
                                while (--len >= 0) fin[pos++] = rev[len];
                                str_idx = rv_string_intern(vm, fin, pos);
                            } else if (vm->x[10].type == MV_BOOL) {
                                str_idx = rv_string_intern(vm,
                                    vm->x[10].as.boolean ? "true" : "false",
                                    vm->x[10].as.boolean ? 4 : 5);
                            }
                            vm->x[10] = (MetalValue){MV_STR, {.str_idx = str_idx}};
                        } else if (rv_strcmp(b_name, "int") == 0) {
                            if (vm->x[10].type == MV_NUM) {
                                vm->x[10] = mv_num(fp_to_int(vm->x[10].as.number));
                            }
                        } else if (rv_strcmp(b_name, "pass") == 0) {
                            vm->x[10] = mv_nil();
                        } else if (rv_strcmp(b_name, "len") == 0) {
                            MetalValue obj = vm->x[10];
                            if (obj.type == MV_ARR)
                                vm->x[10] = mv_num(rv_array_len(vm, obj.as.arr_idx));
                            else if (obj.type == MV_STR) {
                                const char *s = rv_string_get(vm, obj.as.str_idx);
                                vm->x[10] = mv_num(rv_strlen(s));
                            } else
                                vm->x[10] = mv_num(0);
                        } else if (rv_strcmp(b_name, "push") == 0) {
                            MetalValue arr_obj = vm->x[10];
                            MetalValue elem = vm->x[11];
                            if (arr_obj.type == MV_ARR) {
                                rv_array_push(vm, arr_obj.as.arr_idx, elem);
                                vm->x[10] = arr_obj;
                            }
                        } else if (rv_strcmp(b_name, "mem_write") == 0) {
                            int64_t addr = (vm->x[10].type == MV_NUM) ? fp_to_int(vm->x[10].as.number) : 0;
                            int64_t val  = (vm->x[11].type == MV_NUM) ? fp_to_int(vm->x[11].as.number) : 0;
                            int64_t sz   = (vm->x[12].type == MV_NUM) ? fp_to_int(vm->x[12].as.number) : 1;
                            if (sz == 1) *(volatile uint8_t *)(uintptr_t)addr = (uint8_t)val;
                            else if (sz == 2) *(volatile uint16_t *)(uintptr_t)addr = (uint16_t)val;
                            else if (sz == 4) *(volatile uint32_t *)(uintptr_t)addr = (uint32_t)val;
                            else if (sz == 8) *(volatile uint64_t *)(uintptr_t)addr = (uint64_t)val;
                            vm->x[10] = mv_nil();
                        } else if (rv_strcmp(b_name, "mem_read") == 0) {
                            int64_t addr = (vm->x[10].type == MV_NUM) ? fp_to_int(vm->x[10].as.number) : 0;
                            int64_t sz   = (vm->x[11].type == MV_NUM) ? fp_to_int(vm->x[11].as.number) : 1;
                            int64_t result = 0;
                            if (sz == 1) result = *(volatile uint8_t *)(uintptr_t)addr;
                            else if (sz == 2) result = *(volatile uint16_t *)(uintptr_t)addr;
                            else if (sz == 4) result = *(volatile uint32_t *)(uintptr_t)addr;
                            else if (sz == 8) result = (int64_t)*(volatile uint64_t *)(uintptr_t)addr;
                            vm->x[10] = mv_num(result);
                        } else if (rv_strcmp(b_name, "array") == 0) {
                            int size = (vm->x[10].type == MV_NUM) ? (int)fp_to_int(vm->x[10].as.number) : 0;
                            int arr = rv_array_new(vm);
                            MetalValue nil_val = mv_nil();
                            for (int i = 0; i < size; i++)
                                rv_array_push(vm, arr, nil_val);
                            vm->x[10] = (MetalValue){MV_ARR, {.arr_idx = arr}};
                        } else if (rv_strcmp(b_name, "readline") == 0 ||
                                   rv_strcmp(b_name, "input") == 0 ||
                                   rv_strcmp(b_name, "read") == 0) {
                            char buf[256];
                            int pos = 0;
                            while (pos < 255) {
                                int c = vm->read_char ? vm->read_char() : -1;
                                if (c < 0) continue;
                                if (c == '\n' || c == '\r') break;
                                if (c == '\b' || c == 127) {
                                    if (pos > 0) pos--;
                                    continue;
                                }
                                 buf[pos++] = (char)c;
                                if (vm->write_char) vm->write_char((char)c);
                            }
                            buf[pos] = '\0';
                            if (pos > 0 && vm->write_char) vm->write_char('\n');
                            int str_idx = rv_string_intern(vm, buf, pos);
                            vm->x[10] = (MetalValue){MV_STR, {.str_idx = str_idx}};
                        } else if (rv_strcmp(b_name, "streq") == 0) {
                            MetalValue a = vm->x[10];
                            MetalValue b = vm->x[11];
                            int eq = 0;
                            if (a.type == MV_STR && b.type == MV_STR) {
                                const char *sa = rv_string_get(vm, a.as.str_idx);
                                const char *sb = rv_string_get(vm, b.as.str_idx);
                                eq = (rv_strcmp(sa, sb) == 0) ? 1 : 0;
                            }
                            vm->x[10] = mv_num(eq);
                        } else if (rv_strcmp(b_name, "wdog_kick") == 0) {
                            // Kick the hardware watchdog (DesignWare WDT at 0x03010000)
                            // Write magic 0x76 to CRR register
                            *(volatile uint32_t *)(uintptr_t)0x0301000C = 0x76;
                            vm->x[10] = mv_nil();
                        } else if (rv_strcmp(b_name, "shell_exec") == 0) {
                            // shell_exec(cmd): dispatch shell command, return result string
                            MetalValue cmd_val = vm->x[10];
                            const char *cmd = "";
                            if (cmd_val.type == MV_STR)
                                cmd = rv_string_get(vm, cmd_val.as.str_idx);
                            
                            const char *result = "";
                            if (rv_strcmp(cmd, "help") == 0) {
                                result = "Commands: help version about clear dmesg ls cat mem ps halt";
                            } else if (rv_strcmp(cmd, "version") == 0) {
                                result = "SageOS-RV v0.3.0  RISC-V 64  MetalRV64 (Q32.32)";
                            } else if (rv_strcmp(cmd, "about") == 0) {
                                result = "SageOS-RV: Pure Sage OS for RISC-V 64";
                            } else if (rv_strcmp(cmd, "clear") == 0) {
                                if (vm->write_char) { vm->write_char(27); vm->write_char('['); vm->write_char('2'); vm->write_char('J'); }
                                result = "";
                            } else if (rv_strcmp(cmd, "dmesg") == 0) {
                                result = "dmesg: log buffer at 0x87010000 (use kernel/dmesg.sage)";
                            } else if (rv_strcmp(cmd, "ls") == 0) {
                                result = "/welcome.txt (95 bytes)";
                            } else if (rv_strcmp(cmd, "cat") == 0) {
                                result = "Usage: cat <filename>";
                            } else if (rv_strcmp(cmd, "mem") == 0) {
                                result = "Memory: PMM bump allocator, 256 pages, 1 MiB arena";
                            } else if (rv_strcmp(cmd, "ps") == 0) {
                                result = "PID  NAME        STATE\n  0  shell       RUNNING";
                            } else if (rv_strcmp(cmd, "halt") == 0) {
                                result = "!HALT!";
                            } else if (cmd[0] != '\0') {
                                result = "Unknown command. Type 'help' for available commands.";
                            }
                            
                            // Check for halt command
                            if (rv_strcmp(result, "!HALT!") == 0) {
                                vm->halted = 1;
                                vm->running = 0;
                                if (vm->write_char) {
                                    rv_print_str(vm, "Halting system...\n");
                                }
                                return;
                            }
                            
                            int ridx = rv_string_intern(vm, result, rv_strlen(result));
                            vm->x[10] = (MetalValue){MV_STR, {.str_idx = ridx}};
                        } else if (rv_strcmp(b_name, "SRVM") == 0) {
                            int d_idx = rv_dict_new(vm);
                            rv_dict_set(vm, d_idx,
                                rv_string_intern(vm, "__type__", 8),
                                (MetalValue){MV_STR, {.str_idx = rv_string_intern(vm, "instance", 8)}});
                            rv_dict_set(vm, d_idx,
                                rv_string_intern(vm, "__class__", 9),
                                func_obj);
                            vm->x[10] = (MetalValue){MV_DICT, {.dict_idx = d_idx}};
                        } else if (rv_strcmp(b_name, "streq") == 0) {
                            MetalValue a = vm->x[10];
                            MetalValue b = vm->x[11];
                            int eq = 0;
                            if (a.type == MV_STR && b.type == MV_STR) {
                                const char *sa = rv_string_get(vm, a.as.str_idx);
                                const char *sb = rv_string_get(vm, b.as.str_idx);
                                eq = (rv_strcmp(sa, sb) == 0) ? 1 : 0;
                            }
                            vm->x[10] = mv_num(eq);
                        }
                        vm->pc += 4;
                        return;
                    }
                    MetalValue chunk_idx_val = rv_dict_get(vm, func_obj.as.dict_idx,
                        rv_string_intern(vm, "chunk_idx", 9));
                    if (chunk_idx_val.type == MV_NUM) {
                        target_chunk = (int)fp_to_int(chunk_idx_val.as.number);
                    }
                }

                if (target_chunk >= 0 && target_chunk < vm->chunk_count) {
                    if (vm->csp < RV64_CALL_STACK_SIZE) {
                        vm->call_stack[vm->csp].chunk_idx = vm->current_chunk_idx;
                        vm->call_stack[vm->csp].return_pc = vm->pc + 4;
                        vm->call_stack[vm->csp].saved_ra = vm->x[1];
                        vm->call_stack[vm->csp].is_constructor = 0;
                        vm->call_stack[vm->csp].constructor_instance = mv_nil();
                        vm->csp++;

                        vm->current_chunk_idx = target_chunk;
                        vm->bytecode = vm->chunks[target_chunk];
                        vm->bytecode_length = vm->chunk_lengths[target_chunk];
                        vm->pc = 0;
                        vm->x[1] = mv_num(0);
                        return;
                    } else {
                        vm->error = 1;
                        vm->error_msg = "Call stack overflow";
                    }
                } else {
                    rv_print_str(vm, "VMO_CALL error: target_chunk=");
                    rv_print_int(vm, target_chunk);
                    rv_print_str(vm, " type=");
                    rv_print_int(vm, func_obj.type);
                    if (func_obj.type == MV_DICT) {
                        rv_print_str(vm, " dict_idx=");
                        rv_print_int(vm, func_obj.as.dict_idx);
                        MetalDict *d = &vm->dicts[func_obj.as.dict_idx];
                        rv_print_str(vm, " keys=[");
                        for (int k = 0; k < d->count; k++) {
                            if (k > 0) rv_print_str(vm, ", ");
                            rv_print_str(vm, rv_string_get(vm, d->key_str_idx[k]));
                            rv_print_str(vm, ":");
                            rv_print_int(vm, d->values[k].type);
                        }
                        rv_print_str(vm, "]");
                    }
                    if (vm->write_char) vm->write_char('\n');
                    vm->error = 1;
                    vm->error_msg = "Invalid function call target";
                }
                break;
            }
            case RV_VMO_ARRAY_LEN: {
                MetalValue obj = vm->x[inst.rs2];
                if (obj.type == MV_ARR)
                    vm->x[inst.rd] = mv_num(rv_array_len(vm, obj.as.arr_idx));
                else
                    vm->x[inst.rd] = mv_num(0);
                break;
            }
            case RV_VMO_SETUP_TRY: {
                int catch_offset = inst.imm_i;
                if (vm->tsp < RV64_TRY_STACK_SIZE) {
                    vm->try_stack[vm->tsp].catch_pc = vm->pc + catch_offset;
                    vm->try_stack[vm->tsp].call_depth = vm->csp;
                    vm->tsp++;
                }
                break;
            }
            case RV_VMO_END_TRY:
                if (vm->tsp > 0) vm->tsp--;
                break;
            case RV_VMO_RAISE: {
                MetalValue exc_obj = vm->x[10];
                if (vm->tsp > 0) {
                    vm->tsp--;
                    int catch_pc = vm->try_stack[vm->tsp].catch_pc;
                    int target_depth = vm->try_stack[vm->tsp].call_depth;
                    while (vm->csp > target_depth) vm->csp--;
                    vm->current_chunk_idx = vm->call_stack[vm->csp].chunk_idx;
                    vm->bytecode = vm->chunks[vm->current_chunk_idx];
                    vm->bytecode_length = vm->chunk_lengths[vm->current_chunk_idx];
                    vm->pc = catch_pc;
                    vm->x[10] = exc_obj;
                    return;
                } else {
                    vm->error = 1;
                    vm->error_msg = "Unhandled exception raised";
                    vm->running = 0;
                    return;
                }
            }
            case RV_VMO_CMP_BINARY: {
                MetalValue a = vm->x[10];
                MetalValue b = vm->x[11];
                int cmp_type = inst.funct7 & 0x7F;
                int result = 0;
                if (a.type == MV_NUM && b.type == MV_NUM) {
                    int64_t va = a.as.number;
                    int64_t vb = b.as.number;
                    if (cmp_type == CMP_EQ) result = (va == vb) ? 1 : 0;
                    else if (cmp_type == CMP_NEQ) result = (va != vb) ? 1 : 0;
                    else if (cmp_type == CMP_LT) result = (va < vb) ? 1 : 0;
                    else if (cmp_type == CMP_GT) result = (va > vb) ? 1 : 0;
                    else if (cmp_type == CMP_LE) result = (va <= vb) ? 1 : 0;
                    else if (cmp_type == CMP_GE) result = (va >= vb) ? 1 : 0;
                } else if (a.type == MV_STR && b.type == MV_STR) {
                    const char *sa = rv_string_get(vm, a.as.str_idx);
                    const char *sb = rv_string_get(vm, b.as.str_idx);
                    int cmp = rv_strcmp(sa, sb);
                    if (cmp_type == CMP_EQ) result = (cmp == 0) ? 1 : 0;
                    else if (cmp_type == CMP_NEQ) result = (cmp != 0) ? 1 : 0;
                    else if (cmp_type == CMP_LT) result = (cmp < 0) ? 1 : 0;
                    else if (cmp_type == CMP_LE) result = (cmp <= 0) ? 1 : 0;
                    else if (cmp_type == CMP_GT) result = (cmp > 0) ? 1 : 0;
                    else if (cmp_type == CMP_GE) result = (cmp >= 0) ? 1 : 0;
                } else if (a.type == MV_BOOL && b.type == MV_BOOL) {
                    if (cmp_type == CMP_EQ) result = (a.as.boolean == b.as.boolean) ? 1 : 0;
                    else if (cmp_type == CMP_NEQ) result = (a.as.boolean != b.as.boolean) ? 1 : 0;
                }
                vm->x[10] = mv_num(result);
                break;
            }
            default:
                break;
        }
    } else if (inst.funct3 == RV_F3_OBJ_OPS) {
        switch (sub_op) {
            case RV_OBJ_GET_GLOBAL: {
                int idx = 0;
                if (vm->x[10].type == MV_NUM) idx = (int)fp_to_int(vm->x[10].as.number);
                int name_str_idx = vm->constants[idx].as.str_idx;
                const char *name = rv_string_get(vm, name_str_idx);
                if (rv_strcmp(name, "str") == 0) {
                    int d_idx = rv_dict_new(vm);
                    rv_dict_set(vm, d_idx,
                        rv_string_intern(vm, "__builtin__", 11),
                        (MetalValue){MV_STR, {.str_idx = rv_string_intern(vm, "str", 3)}});
                    vm->x[inst.rd] = (MetalValue){MV_DICT, {.dict_idx = d_idx}};
                } else if (rv_strcmp(name, "int") == 0) {
                    int d_idx = rv_dict_new(vm);
                    rv_dict_set(vm, d_idx,
                        rv_string_intern(vm, "__builtin__", 11),
                        (MetalValue){MV_STR, {.str_idx = rv_string_intern(vm, "int", 3)}});
                    vm->x[inst.rd] = (MetalValue){MV_DICT, {.dict_idx = d_idx}};
                } else {
                    vm->x[inst.rd] = rv_dict_get(vm, vm->global_dict_idx, name_str_idx);
                }
                break;
            }
            case RV_OBJ_SET_GLOBAL: {
                int idx = 0;
                if (vm->x[10].type == MV_NUM) idx = (int)fp_to_int(vm->x[10].as.number);
                int name_str_idx = vm->constants[idx].as.str_idx;
                MetalValue val = vm->x[11];
                rv_dict_set(vm, vm->global_dict_idx, name_str_idx, val);
                break;
            }
            case RV_OBJ_GET_PROP: {
                MetalValue obj = vm->x[inst.rs2];
                int name_idx = 0;
                if (vm->x[10].type == MV_NUM) name_idx = (int)fp_to_int(vm->x[10].as.number);
                int name_str_idx = vm->constants[name_idx].as.str_idx;
                MetalValue val = mv_nil();
                if (obj.type == MV_DICT)
                    val = rv_dict_get(vm, obj.as.dict_idx, name_str_idx);
                if (val.type == MV_NIL)
                    val = rv_dict_get(vm, vm->global_dict_idx, name_str_idx);
                vm->x[inst.rd] = val;
                break;
            }
            case RV_OBJ_SET_PROP: {
                MetalValue obj = vm->x[inst.rs2];
                int name_idx = 0;
                if (vm->x[10].type == MV_NUM) name_idx = (int)fp_to_int(vm->x[10].as.number);
                int name_str_idx = vm->constants[name_idx].as.str_idx;
                MetalValue val = vm->x[11];
                if (obj.type == MV_DICT)
                    rv_dict_set(vm, obj.as.dict_idx, name_str_idx, val);
                break;
            }
            case RV_OBJ_NEW_FUNC: {
                int chunk_idx = 0;
                if (vm->x[10].type == MV_NUM) chunk_idx = (int)fp_to_int(vm->x[10].as.number);
                int d_idx = rv_dict_new(vm);
                rv_dict_set(vm, d_idx,
                    rv_string_intern(vm, "type", 4),
                    (MetalValue){MV_STR, {.str_idx = rv_string_intern(vm, "function", 8)}});
                rv_dict_set(vm, d_idx,
                    rv_string_intern(vm, "chunk_idx", 9),
                    mv_num(chunk_idx));
                vm->x[inst.rd] = (MetalValue){MV_DICT, {.dict_idx = d_idx}};
                break;
            }
            case RV_OBJ_TUPLE_NEW:
            case RV_OBJ_ARRAY_NEW: {
                int size = 0;
                if (vm->x[10].type == MV_NUM) size = (int)fp_to_int(vm->x[10].as.number);
                MetalValue init_val = vm->x[11];
                int arr = rv_array_new(vm);
                for (int i = 0; i < size; i++)
                    rv_array_push(vm, arr, init_val);
                vm->x[inst.rd] = (MetalValue){MV_ARR, {.arr_idx = arr}};
                break;
            }
            case RV_OBJ_DICT_NEW: {
                int d_idx = rv_dict_new(vm);
                vm->x[inst.rd] = (MetalValue){MV_DICT, {.dict_idx = d_idx}};
                break;
            }
            case RV_OBJ_GET_INDEX: {
                MetalValue obj = vm->x[inst.rs2];
                int idx = 0;
                if (vm->x[10].type == MV_NUM) idx = (int)fp_to_int(vm->x[10].as.number);
                if (obj.type == MV_ARR) {
                    vm->x[inst.rd] = rv_array_get(vm, obj.as.arr_idx, idx);
                } else if (obj.type == MV_DICT && vm->x[10].type == MV_STR) {
                    vm->x[inst.rd] = rv_dict_get(vm, obj.as.dict_idx, vm->x[10].as.str_idx);
                } else {
                    vm->x[inst.rd] = mv_nil();
                }
                break;
            }
            case RV_OBJ_SET_INDEX: {
                MetalValue obj = vm->x[inst.rs2];
                int idx = 0;
                if (vm->x[10].type == MV_NUM) idx = (int)fp_to_int(vm->x[10].as.number);
                MetalValue val = vm->x[11];
                if (obj.type == MV_ARR) {
                    int arr_idx = obj.as.arr_idx;
                    int max_a = (int)(sizeof(vm->arrays) / sizeof(vm->arrays[0]));
                    if (arr_idx >= 0 && arr_idx < max_a && idx >= 0 && idx < vm->arrays[arr_idx].count) {
                        vm->arrays[arr_idx].elems[idx] = val;
                    }
                } else if (obj.type == MV_DICT && vm->x[10].type == MV_STR) {
                    rv_dict_set(vm, obj.as.dict_idx, vm->x[10].as.str_idx, val);
                }
                break;
            }
            default:
                break;
        }
    } else if (inst.funct3 == RV_F3_GPU_OPS) {
        if (vm->trace) {
            rv_print_str(vm, "GPU Op: ");
            rv_print_int(vm, sub_op);
            if (vm->write_char) vm->write_char('\n');
        }
    }

    vm->pc += 4;
}

// ============================================================================
// Interpreter Step & Run
// ============================================================================

int metal_rv64_vm_step(MetalRV64VM *vm) {
    if (vm->halted || vm->error || vm->pc >= vm->bytecode_length) return 0;

    unsigned int raw = vm->bytecode[vm->pc] |
                      (vm->bytecode[vm->pc + 1] << 8) |
                      (vm->bytecode[vm->pc + 2] << 16) |
                      (vm->bytecode[vm->pc + 3] << 24);

    RV64Instruction inst = rv64_decode(raw);

    if (vm->trace) {
        rv_print_str(vm, "PC: ");
        rv_print_int(vm, vm->pc);
        rv_print_str(vm, " Opcode: ");
        rv_print_int(vm, inst.opcode);
        rv_print_str(vm, " rd: ");
        rv_print_int(vm, inst.rd);
        rv_print_str(vm, " raw: ");
        for (int b = 0; b < 4; b++) {
            rv_print_int(vm, vm->bytecode[vm->pc + b]);
            rv_print_str(vm, " ");
        }
        if (vm->write_char) vm->write_char('\n');
    }

    switch (inst.opcode) {
        case RV_OP_LUI:
            vm->x[inst.rd] = mv_num(inst.imm_u >> 12);
            vm->pc += 4;
            break;
        case RV_OP_AUIPC:
            vm->x[inst.rd] = mv_num(vm->pc + (inst.imm_u >> 12));
            vm->pc += 4;
            break;
        case RV_OP_JAL:
            vm->x[inst.rd] = mv_num(vm->pc + 4);
            vm->pc += inst.imm_j;
            break;
        case RV_OP_JALR: {
            int target_base = 0;
            if (vm->x[inst.rs1].type == MV_NUM)
                target_base = (int)fp_to_int(vm->x[inst.rs1].as.number);
            int target = (target_base + inst.imm_i) & ~1;
            MetalValue rd_val = mv_num(vm->pc + 4);

            if (inst.rd == 0 && inst.rs1 == 1 && inst.imm_i == 0) {
                if (vm->csp > 0) {
                    vm->csp--;
                    vm->current_chunk_idx = vm->call_stack[vm->csp].chunk_idx;
                    vm->bytecode = vm->chunks[vm->current_chunk_idx];
                    vm->bytecode_length = vm->chunk_lengths[vm->current_chunk_idx];
                    vm->pc = vm->call_stack[vm->csp].return_pc;
                    vm->x[1] = vm->call_stack[vm->csp].saved_ra;
                    if (vm->call_stack[vm->csp].is_constructor)
                        vm->x[10] = vm->call_stack[vm->csp].constructor_instance;
                    return 1;
                } else {
                    vm->running = 0;
                    vm->halted = 1;
                    return 0;
                }
            }

            vm->x[inst.rd] = rd_val;
            vm->pc = target;
            break;
        }
        case RV_OP_BRANCH:
            handle_branch(vm, inst);
            break;
        case RV_OP_IMM:
            handle_imm(vm, inst);
            break;
        case RV_OP_REG:
            handle_reg(vm, inst);
            break;
        case RV_OP_LDC:
            handle_ldc(vm, inst);
            break;
        case RV_OP_LOAD:
            handle_load(vm, inst);
            break;
        case RV_OP_STORE:
            handle_store(vm, inst);
            break;
        case RV_OP_VMSYS:
            handle_vmsys(vm, inst);
            break;
        default:
            vm->error = 1;
            vm->error_msg = "Unknown RISC-V opcode";
            vm->running = 0;
            return 0;
    }

    vm->x[0] = mv_num(0);
    return 1;
}

int metal_rv64_vm_run(MetalRV64VM *vm) {
    vm->running = 1;
    vm->halted = 0;
    while (vm->running && metal_rv64_vm_step(vm)) {}
    return vm->error ? -1 : 0;
}

/*
 * 目录：hw/rdma/c_oracle；职责：以锁定驱动 cmq.h 的字段宏重建四种 CMQ
 * 图像。依赖：编译器通过 -I 注入的只读驱动头文件；所有缓冲区由 main
 * 在本进程内拥有。本文件不复制 cmq.c，而是仅重放 source-anchor 指定的
 * 数据流，进程结束时释放资源。
 */

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* 用户态编译 shim：只提供 Linux 类型/原语，不定义任何 CMQ 字段 mask 或
 * opcode。 */
#define __OSDEP_H
#define __DEBUGFS_H
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uint64_t dma_addr_t;
typedef uint64_t __be64;
typedef uint32_t __be32;
#define __iomem
#define __packed __attribute__((packed))
struct list_head {
	struct list_head *next;
	struct list_head *prev;
};
typedef struct {
	unsigned int refs;
} refcount_t;
typedef struct {
	int unused;
} wait_queue_head_t;
typedef struct {
	int unused;
} spinlock_t;
struct xtrdma_dma_mem {
	void *va;
	dma_addr_t iova;
	size_t size;
};
struct xtrdma_sc_dev;
struct xtrdma_cmq_quanta;
struct xtrdma_ring {
	u32 head;
	u32 tail;
	u32 size;
};
struct xtrdma_sc_cmq {
	struct xtrdma_sc_dev *sc_dev;
	u64 sq_pa;
	struct xtrdma_ring sq_ring;
	struct xtrdma_cmq_quanta *sq_base;
	struct xtrdma_cmq_quanta *cq_base;
	u64 *request_array;
	u32 sq_size;
	u32 cq_size;
	u8 sq_polarity:1;
	u8 cq_polarity:1;
	u64 cmq_req_stats;
	u64 cmq_cmpl_stats;
};
static inline void refcount_inc(refcount_t *ref)
{
	/* 功能：提供 cmq.h 内联引用计数递增所需的用户态兼容实现。
	 * 输入输出及副作用：将 ref->refs 加一；不返回值且不分配资源。
	 * 失败边界：ref 为空会触发未定义行为，probe 只传入 cmq.h 构造的
	 * 有效成员。 */
	++ref->refs;
}

#define BIT(n) (1U << (n))
#define BIT_ULL(n) (1ULL << (n))
#define GENMASK(h, l) \
	((((uint64_t)~0ULL) >> (63 - (h))) & ((uint64_t)~0ULL << (l)))
#define GENMASK_ULL(h, l) \
	(((uint64_t)~0ULL >> (63 - (h))) & ((uint64_t)~0ULL << (l)))
#define FIELD_PREP(mask, val) \
	((((uint64_t)(val)) << __builtin_ctzll((uint64_t)(mask))) & \
	 (uint64_t)(mask))
#define FIELD_GET(mask, val) \
	(((uint64_t)(val) & (uint64_t)(mask)) >> \
	 __builtin_ctzll((uint64_t)(mask)))
#define cpu_to_be64(v) (__builtin_bswap64((uint64_t)(v)))
#define be64_to_cpu(v) (__builtin_bswap64((uint64_t)(v)))
#define get_unaligned(ptr) ({ \
	uint64_t _v; \
	memcpy(&_v, (ptr), sizeof(_v)); \
	_v; \
})
#define XTRDMA_64BIT_TO_BYTE 8
#define XTRDMA_ADDR_512_BYTE_SHIFT 9
#define XTRDMA_OCC_QPC_SIZE 512

#include <cmq.h>

_Static_assert(sizeof(struct xtrdma_cmq_sq_wqe) == 64,
               "CMQ SQE must remain 64 bytes");
_Static_assert(sizeof(struct xtrdma_cmq_cq_wqe) == 64,
               "CMQ CQE must remain 64 bytes");
_Static_assert(_Alignof(struct xtrdma_cmq_sq_wqe) == 8,
               "CMQ SQE alignment changed");
_Static_assert(_Alignof(struct xtrdma_cmq_cq_wqe) == 8,
               "CMQ CQE alignment changed");

struct oracle_qp_info {
	u32 qpn;
	u32 sq_cqn;
	u32 rq_cqn;
	u64 qpc_buffer_addr_pa;
	u8 *qpc_buffer_addr_va;
};

struct oracle_cq_context {
	u32 cqn;
	struct xtrdma_dma_mem ctx_addr;
};

static void set_64bit_val(__be64 *wqe_words, u32 byte_index, u64 val)
{
	/* 功能：按驱动 set_64bit_val 语义把主机整数写成大端 qword。
	 * 输入输出及副作用：更新 wqe_words[byte_index >> 3]，无返回值。
	 * 失败边界：调用者必须提供 8 字节对齐且足长缓冲区；本函数不检查
	 * 指针。 */
	wqe_words[byte_index >> 3] = cpu_to_be64(val);
}

static u64 get_64bit_val(const __be64 *wqe_words, u32 byte_index)
{
	/* 功能：按驱动 get_64bit_val 语义读取 qword 并转换为 CPU 字节序。
	 * 输入输出及副作用：读取 wqe_words[byte_index >> 3]，返回无符号 64 位值。
	 * 失败边界：越界或空指针由调用者负责；byte_index 必须落在 qword 边界。 */
	return be64_to_cpu(wqe_words[byte_index >> 3]);
}

static u8 xtrdma_bytes_xor(void *va, int offset, int size)
{
	/* 功能：重现驱动 xtrdma_bytes_xor 的 qword XOR、余数折叠和 8 位结果。
	 * 输入输出及副作用：从 va+offset 读取 size 字节，返回折叠后的 XOR 字节。
	 * 失败边界：size 为负或区域不可读会导致未定义行为，输入 fixture
	 * 必须满足范围。 */
	u8 *ptr = (u8 *)va + offset;
	u64 acc = 0;
	int n = size / (int)sizeof(u64);
	int rem = size % (int)sizeof(u64);
	int i;

	for (i = 0; i < n; ++i) {
		acc ^= get_unaligned((u64 *)ptr);
		ptr += sizeof(u64);
	}
	for (i = 0; i < rem; ++i)
		acc ^= ptr[i];
	acc ^= acc >> 32;
	acc ^= acc >> 16;
	acc ^= acc >> 8;
	return (u8)acc;
}

static void build_qpc(__be64 *wqe, const struct oracle_qp_info *info,
		      u32 wqe_idx, u8 opcode, u8 polarity)
{
	/* 功能：按 xtrdma_sc_qp_create 顺序构造 QPC_CREATE SQE 及签名。
	 * 输入输出及副作用：写入 64 字节 wqe；读取 info 的 QPN/CQN、地址和
	 * 512 字节 QPC。
	 * 失败边界：opcode、索引和 polarity 超出硬件字段宽度时 FIELD_PREP 会截断，
	 * 调用方须预校验。 */
	u64 hdr;
	u64 sign_data;
	u8 ctrl_data_xor;
	u8 wqe_xor;
	u8 qpc_xor;
	u8 signature;

	hdr = FIELD_PREP(XTRDMA_CMQSQ_WQE_QPN, info->qpn) |
		FIELD_PREP(XTRDMA_CMQCQ_OPCODE, opcode) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_INDEX, wqe_idx) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_WRAP, polarity ? 0 : 1) |
		FIELD_PREP(XTRDMA_CMQSQ_USE_VFID, 0) |
		FIELD_PREP(XTRDMA_CMQSQ_VFID_OVERRIDE, 0) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_VALID, polarity);
	set_64bit_val(wqe, 24,
		FIELD_PREP(XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR,
			   info->qpc_buffer_addr_pa));
	sign_data = FIELD_PREP(XTRDMA_CMQSQ_WQE_SQ_CQN, info->sq_cqn) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_SIGN_EN, 1) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_RQ_CQN, info->rq_cqn);
	set_64bit_val(wqe, 8, sign_data);
	ctrl_data_xor = xtrdma_bytes_xor(&hdr, 0, XTRDMA_CMQ_64BIT_TO_BYTE_SIZE);
	wqe_xor = xtrdma_bytes_xor(wqe, XTRDMA_CMQ_64BIT_TO_BYTE_SIZE,
				   XTRDMA_CMQE_SIZE - XTRDMA_CMQ_64BIT_TO_BYTE_SIZE);
	qpc_xor = xtrdma_bytes_xor(info->qpc_buffer_addr_va, 0, XTRDMA_OCC_QPC_SIZE);
	signature = (u8)~(ctrl_data_xor ^ wqe_xor ^ qpc_xor);
	set_64bit_val(wqe, 8, sign_data |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_SIGNATURE, signature));
	set_64bit_val(wqe, 0, hdr);
}

static void build_cqc(__be64 *wqe, const struct oracle_cq_context *ctx,
		      u32 wqe_idx, u8 opcode, u8 polarity)
{
	/* 功能：按 xtrdma_sc_cq_create 先 memcpy payload、后写公共 header。
	 * 输入输出及副作用：把 ctx_addr.va 的 56 字节写入 wqe+1 并更新首 qword。
	 * 失败边界：ctx_addr.va 必须至少 56 字节；CQN/索引超宽时硬件宏
	 * 按定义截断。 */
	u64 hdr;

	memcpy(wqe + 1, ctx->ctx_addr.va, 56);
	hdr = FIELD_PREP(XTRDMA_CMQSQ_WQE_VALID, polarity) |
		FIELD_PREP(XTRDMA_CMQSQ_VFID_OVERRIDE, 0) |
		FIELD_PREP(XTRDMA_CMQSQ_USE_VFID, 0) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_WRAP, polarity ? 0 : 1) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_INDEX, wqe_idx) |
		FIELD_PREP(XTRDMA_CMQCQ_OPCODE, opcode) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_CQC_WQE_CQN, ctx->cqn);
	set_64bit_val(wqe, 0, hdr);
}

static int parse_u64(const char *text, u64 *value)
{
	/* 功能：解析无符号十六进制/十进制 fixture 值。
	 * 输入输出及副作用：成功写入 *value 并返回 0；不修改输入文本。
	 * 失败边界：空串、尾随字符、溢出或 errno 错误均返回 -1。 */
	char *end;
	unsigned long long parsed;

	if (!text || !*text)
		return -1;
	errno = 0;
	parsed = strtoull(text, &end, 0);
	if (errno != 0 || end == text || *end != '\0')
		return -1;
	*value = (u64)parsed;
	return 0;
}

static int load_input(const char *path, char values[][96], char keys[][64],
		      size_t *count)
{
	/* 功能：读取 key<TAB>value 输入文件，形成固定上限的 case 参数表。
	 * 输入输出及副作用：读取 path 并写入 keys/values/count；不创建或修改文件。
	 * 失败边界：缺列、重复键、超长行、键值数量超过 64 或文件错误均返回
	 * -1。 */
	FILE *stream;
	char line[256];
	size_t n = 0;

	stream = fopen(path, "r");
	if (!stream)
		return -1;
	while (fgets(line, sizeof(line), stream)) {
		char *tab;
		char *value;
		size_t len = strlen(line);
		if (len && line[len - 1] == '\n')
			line[--len] = '\0';
		if (!len || line[0] == '#')
			continue;
		tab = strchr(line, '\t');
		if (!tab || n >= 64)
			goto fail;
		*tab = '\0';
		value = tab + 1;
		if (!line[0] || !value[0] ||
		    strlen(line) >= 64 || strlen(value) >= 96)
			goto fail;
		for (size_t i = 0; i < n; ++i)
			if (strcmp(keys[i], line) == 0)
				goto fail;
		strcpy(keys[n], line);
		strcpy(values[n], value);
		++n;
	}
	if (ferror(stream) || !n)
		goto fail;
	fclose(stream);
	*count = n;
	return 0;
fail:
	fclose(stream);
	return -1;
}

static const char *lookup(char keys[][64], char values[][96], size_t count,
			  const char *name)
{
	/* 功能：在已解析输入中查找一个命名参数。
	 * 输入输出及副作用：返回参数值的只读指针；不改变表内容。
	 * 失败边界：name 不存在时返回 NULL，由各 case 视为 malformed input。 */
	for (size_t i = 0; i < count; ++i)
		if (strcmp(keys[i], name) == 0)
			return values[i];
	return NULL;
}

static int require_u64(char keys[][64], char values[][96], size_t count,
		       const char *name, u64 *output)
{
	/* 功能：读取一个必需 fixture 参数并转换为 u64。
	 * 输入输出及副作用：成功写入 output 并返回 0；不修改输入表。
	 * 失败边界：键缺失、空值、尾随字符或数值溢出返回 -1。 */
	const char *text = lookup(keys, values, count, name);

	return parse_u64(text, output);
}

static void print_bytes(const u8 *bytes, size_t length)
{
	/* 功能：以规范化的小写两位十六进制输出图像字节。
	 * 输入输出及副作用：向 stdout 写入一行 BYTES；不修改 bytes。
	 * 失败边界：stdout 写失败由进程最终状态反映，调用者不得继续发布
	 * 该输出。 */
	printf("BYTES");
	for (size_t i = 0; i < length; ++i)
		printf("\t%02x", bytes[i]);
	putchar('\n');
}

static void print_field(const char *name, unsigned offset, unsigned lsb,
			unsigned width, u64 value)
{
	/* 功能：输出一个带位置、宽度和值的规范字段记录。
	 * 输入输出及副作用：向 stdout 写入 FIELD TSV 行；不改变调用者状态。
	 * 失败边界：字段值按十六进制打印，排序和重复检查由 Python verifier
	 * 执行。 */
	printf("FIELD\t%s\t%u\t%u\t%u\t%llx\n", name, offset, lsb, width,
	       (unsigned long long)value);
}

static int run_qpc(char keys[][64], char values[][96], size_t count)
{
	/* 功能：解析 QPC fixture、执行驱动准备地址与 builder 数据流并报告字段。
	 * 输入输出及副作用：分配 512 字节 QPC 和 64 字节 SQE，向 stdout 输出
	 * 图像/字段。
	 * 失败边界：缺少任一必需键、数值非法或地址未按 512 字节对齐时返回
	 * -1。 */
	u64 index, polarity, qpn, sq_cqn, rq_cqn, iova;
	u8 qpc[512];
	__be64 wqe[8] = {0};
	struct oracle_qp_info info;

	if (require_u64(keys, values, count, "wqe_index", &index) < 0 ||
	    require_u64(keys, values, count, "builder_polarity", &polarity) < 0 ||
	    require_u64(keys, values, count, "qpn", &qpn) < 0 ||
	    require_u64(keys, values, count, "sq_cqn", &sq_cqn) < 0 ||
	    require_u64(keys, values, count, "rq_cqn", &rq_cqn) < 0 ||
	    require_u64(keys, values, count, "qpc_iova", &iova) < 0)
		return -1;
	if (iova & ((1ULL << XTRDMA_ADDR_512_BYTE_SHIFT) - 1))
		return -1;
	for (size_t i = 0; i < sizeof(qpc); ++i)
		qpc[i] = (u8)((i * 37U + 0x5bU) & 0xffU);
	info.qpn = (u32)qpn;
	info.sq_cqn = (u32)sq_cqn;
	info.rq_cqn = (u32)rq_cqn;
	info.qpc_buffer_addr_pa = iova >> XTRDMA_ADDR_512_BYTE_SHIFT;
	info.qpc_buffer_addr_va = qpc;
	build_qpc(wqe, &info, (u32)index, XTRDMA_OP_QPC_CREATE, (u8)polarity);
	print_bytes((const u8 *)wqe, sizeof(wqe));
	print_field(
		"valid", 0, 63, 1,
		FIELD_GET(XTRDMA_CMQSQ_WQE_VALID, get_64bit_val(wqe, 0)));
	print_field(
		"vf_id_override", 0, 59, 1,
		FIELD_GET(XTRDMA_CMQSQ_VFID_OVERRIDE, get_64bit_val(wqe, 0)));
	print_field(
		"use_vfid", 0, 48, 11,
		FIELD_GET(XTRDMA_CMQSQ_USE_VFID, get_64bit_val(wqe, 0)));
	print_field(
		"wrap", 0, 45, 1,
		FIELD_GET(XTRDMA_CMQSQ_WQE_WRAP, get_64bit_val(wqe, 0)));
	print_field(
		"index", 0, 40, 5,
		FIELD_GET(XTRDMA_CMQSQ_WQE_INDEX, get_64bit_val(wqe, 0)));
	print_field(
		"opcode", 0, 32, 8,
		FIELD_GET(XTRDMA_CMQCQ_OPCODE, get_64bit_val(wqe, 0)));
	print_field(
		"qpn", 0, 0, 24,
		FIELD_GET(XTRDMA_CMQSQ_WQE_QPN, get_64bit_val(wqe, 0)));
	print_field(
		"rq_cqn", 8, 0, 21,
		FIELD_GET(XTRDMA_CMQSQ_WQE_RQ_CQN, get_64bit_val(wqe, 8)));
	print_field(
		"sign_en", 8, 32, 1,
		FIELD_GET(XTRDMA_CMQSQ_WQE_SIGN_EN, get_64bit_val(wqe, 8)));
	print_field(
		"signature", 8, 24, 8,
		FIELD_GET(XTRDMA_CMQSQ_WQE_SIGNATURE, get_64bit_val(wqe, 8)));
	print_field(
		"sq_cqn", 8, 43, 21,
		FIELD_GET(XTRDMA_CMQSQ_WQE_SQ_CQN, get_64bit_val(wqe, 8)));
	print_field(
		"qpc_buffer_addr_pa", 24, 9, 55,
		FIELD_GET(XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR, get_64bit_val(wqe, 24)));
	return 0;
}

static int run_cqc(char keys[][64], char values[][96], size_t count)
{
	/* 功能：解析 CQC fixture，先复制 56 字节 context 再构造 CQC_CREATE SQE。
	 * 输入输出及副作用：分配 context/WQE 并输出图像、header 字段及 memcpy
	 * 范围。
	 * 失败边界：缺少 index/polarity/cqn 或输入值溢出字段范围时返回 -1。 */
	u64 index, polarity, cqn;
	u8 context[56];
	__be64 wqe[8] = {0};
	struct oracle_cq_context info;

	if (require_u64(keys, values, count, "wqe_index", &index) < 0 ||
	    require_u64(keys, values, count, "builder_polarity", &polarity) < 0 ||
	    require_u64(keys, values, count, "cqn", &cqn) < 0)
		return -1;
	for (size_t i = 0; i < sizeof(context); ++i)
		context[i] = (u8)((i * 29U + 0x31U) & 0xffU);
	info.cqn = (u32)cqn;
	info.ctx_addr.va = context;
	build_cqc(wqe, &info, (u32)index, XTRDMA_OP_CQC_CREATE, (u8)polarity);
	print_bytes((const u8 *)wqe, sizeof(wqe));
	print_field(
		"valid", 0, 63, 1,
		FIELD_GET(XTRDMA_CMQSQ_WQE_VALID, get_64bit_val(wqe, 0)));
	print_field(
		"vf_id_override", 0, 59, 1,
		FIELD_GET(XTRDMA_CMQSQ_VFID_OVERRIDE, get_64bit_val(wqe, 0)));
	print_field(
		"use_vfid", 0, 48, 11,
		FIELD_GET(XTRDMA_CMQSQ_USE_VFID, get_64bit_val(wqe, 0)));
	print_field(
		"wrap", 0, 45, 1,
		FIELD_GET(XTRDMA_CMQSQ_WQE_WRAP, get_64bit_val(wqe, 0)));
	print_field(
		"index", 0, 40, 5,
		FIELD_GET(XTRDMA_CMQSQ_WQE_INDEX, get_64bit_val(wqe, 0)));
	print_field(
		"opcode", 0, 32, 8,
		FIELD_GET(XTRDMA_CMQCQ_OPCODE, get_64bit_val(wqe, 0)));
	print_field(
		"cqn", 0, 0, 21,
		FIELD_GET(XTRDMA_CMQSQ_WQE_CQC_WQE_CQN, get_64bit_val(wqe, 0)));
	print_field("payload_source_byte", 0, 0, 0, 0);
	print_field("payload_target_byte", 0, 0, 0, 8);
	print_field("payload_length", 0, 0, 0, 56);
	return 0;
}

static int run_cqe(char keys[][64], char values[][96], size_t count)
{
	/* 功能：构造完整 CQE/SQE 成功 fixture，重放 owner readiness 与三路验证
	 * 分支。
	 * 输入输出及副作用：输出 CQE 字节、common 字段、ready/status/request_error；
	 * 不执行 MMIO。
	 * 失败边界：owner、wrap、opcode 或 ecode 不匹配时返回 -1，拒绝发布
	 * 成功报告。 */
	u64 cq_polarity, owner, index, wrap, ecode, sq_wrap, opcode;
	__be64 cqe[8] = {0};
	__be64 sqe[8] = {0};
	u64 cqe_word;
	int status = 0;
	int request_error = 0;

	if (require_u64(keys, values, count, "cq_polarity", &cq_polarity) < 0 ||
	    require_u64(keys, values, count, "owner", &owner) < 0 ||
	    require_u64(keys, values, count, "wqe_index", &index) < 0 ||
	    require_u64(keys, values, count, "wrap", &wrap) < 0 ||
	    require_u64(keys, values, count, "ecode", &ecode) < 0 ||
	    require_u64(keys, values, count, "sq_wrap", &sq_wrap) < 0 ||
	    require_u64(keys, values, count, "opcode", &opcode) < 0)
		return -1;
	if (owner != cq_polarity)
		return -1;
	cqe_word = FIELD_PREP(XTRDMA_CMQSQ_WQE_VALID, owner) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_WRAP, wrap) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_INDEX, index) |
		FIELD_PREP(XTRDMA_CMQCQ_OPCODE, opcode) |
		FIELD_PREP(XTRDMA_CMQCQ_CMD_ECODE, ecode);
	set_64bit_val(cqe, 0, cqe_word);
	set_64bit_val(sqe, 0, FIELD_PREP(XTRDMA_CMQSQ_WQE_WRAP, sq_wrap) |
		FIELD_PREP(XTRDMA_CMQCQ_OPCODE, XTRDMA_OP_QPC_CREATE) |
		FIELD_PREP(XTRDMA_CMQSQ_WQE_INDEX, index));
	if (wrap != sq_wrap) {
		status = -5;
		request_error = 1;
	} else if (opcode != XTRDMA_OP_QPC_CREATE) {
		status = -5;
		request_error = 1;
	} else if (ecode != 0) {
		status = -22;
		request_error = 1;
	}
	if (status != 0)
		return -1;
	print_bytes((const u8 *)cqe, sizeof(cqe));
	print_field("ready", 0, 63, 1, owner == cq_polarity);
	print_field("valid", 0, 63, 1, owner);
	print_field(
		"vf_id_override", 0, 59, 1,
		FIELD_GET(XTRDMA_CMQSQ_VFID_OVERRIDE, cqe_word));
	print_field(
		"use_vfid", 0, 48, 11,
		FIELD_GET(XTRDMA_CMQSQ_USE_VFID, cqe_word));
	print_field(
		"index", 0, 40, 5,
		FIELD_GET(XTRDMA_CMQSQ_WQE_INDEX, cqe_word));
	print_field(
		"wrap", 0, 45, 1,
		FIELD_GET(XTRDMA_CMQSQ_WQE_WRAP, cqe_word));
	print_field(
		"opcode", 0, 32, 8,
		FIELD_GET(XTRDMA_CMQCQ_OPCODE, cqe_word));
	print_field(
		"ecode", 0, 24, 8,
		FIELD_GET(XTRDMA_CMQCQ_CMD_ECODE, cqe_word));
	print_field("status", 0, 0, 32, (u32)status);
	print_field("request_error", 0, 0, 1, request_error);
	return 0;
}

static int run_doorbell(char keys[][64], char values[][96], size_t count)
{
	/* 功能：重放 xtrdma_sc_cmq_post_sq 的单调 head、PI/polarity 与大端
	 * doorbell 写入。
	 * 输入输出及副作用：输出 8 字节 CMQSQ_DB 图像及 PI/polarity 字段，
	 * 不触发真实 MMIO。
	 * 失败边界：ring_size 为零、head/PI 不可达或输入转换失败均返回 -1。 */
	u64 head_before, pi_before, ring_size, polarity_before;
	u64 head_after, pi_after, polarity_after, cmq_db;
	u8 bytes[8];

	if (require_u64(keys, values, count, "head_before", &head_before) < 0 ||
	    require_u64(keys, values, count, "pi_before", &pi_before) < 0 ||
	    require_u64(keys, values, count, "ring_size", &ring_size) < 0 ||
	    require_u64(keys, values, count, "sq_polarity_before", &polarity_before) < 0)
		return -1;
	/* xtrdma_sc_cmq_init starts sq_polarity=1 and the driver toggles it only
	 * when the monotonic head enters a new ring cycle. */
	if (!ring_size)
		return -1;
	if (pi_before != head_before % ring_size ||
	    polarity_before != (1U ^ ((head_before / ring_size) & 1U)))
		return -1;
	head_after = head_before + 1;
	pi_after = head_after % ring_size;
	polarity_after = polarity_before;
	if (!pi_after)
		polarity_after = !polarity_after;
	cmq_db = FIELD_PREP(XTRDMA_CMQSQ_DB_PI, pi_after) |
		FIELD_PREP(XTRDMA_CMQSQ_DB_POL, polarity_after ? 0 : 1);
	memcpy(bytes, &(__be64){cpu_to_be64(cmq_db)}, sizeof(bytes));
	print_bytes(bytes, sizeof(bytes));
	print_field("head_before", 0, 0, 32, head_before);
	print_field("head_after", 0, 0, 32, head_after);
	print_field("pi_before", 0, 32, 5, pi_before);
	print_field("pi_after", 0, 32, 5, pi_after);
	print_field("polarity_before", 0, 37, 1, polarity_before);
	print_field("polarity_after", 0, 37, 1, polarity_after);
	print_field("wire_polarity", 0, 37, 1, FIELD_GET(XTRDMA_CMQSQ_DB_POL, cmq_db));
	return 0;
}

int main(int argc, char **argv)
{
	/* 功能：选择一个受支持 case，读取输入并运行对应 oracle builder。
	 * 输入输出及副作用：参数为 --case ID --input TSV，成功向 stdout 输出规范
	 * 报告。
	 * 失败边界：参数缺失、未知 case、非法输入或 builder 失败均以非零状态
	 * 终止。 */
	char keys[64][64];
	char values[64][96];
	size_t count = 0;
	const char *case_id = NULL;
	const char *input = NULL;
	int result;

	if (argc != 5 || strcmp(argv[1], "--case") != 0 ||
	    strcmp(argv[3], "--input") != 0)
		return 2;
	case_id = argv[2];
	input = argv[4];
	if (load_input(input, values, keys, &count) < 0)
		return 3;
	if (strcmp(case_id, "cmq_sqe_qpc_create_request") == 0)
		result = run_qpc(keys, values, count);
	else if (strcmp(case_id, "cmq_sqe_cqc_create_request") == 0)
		result = run_cqc(keys, values, count);
	else if (strcmp(case_id, "cmq_cqe_qpc_create_response") == 0)
		result = run_cqe(keys, values, count);
	else if (strcmp(case_id, "cmq_sq_doorbell") == 0)
		result = run_doorbell(keys, values, count);
	else
		return 4;
	if (result != 0)
		return 5;
	return 0;
}

/*
 * 目录：工具层 tools/rxe/rxe_peer.c。
 * 层：验证工具（Soft-RoCE 对端）。
 * 职责：在一个 rxe 设备上建立 PD/CQ/MR/QP，按 stdin 的逐行命令执行 verbs 操作并在 stdout 逐行
 *   应答（"OK ..." 或 "ERR ..."），供 Python 校验脚本与仿真 DPI 桥接以子进程方式驱动。
 * 所有权：进程持有全部 verbs 资源，quit 或 EOF 时释放。
 * 构建：gcc -O2 -Wall -o rxe_peer rxe_peer.c -libverbs
 *
 * 命令（数值十进制或 0x 十六进制；off 为本端 MR 内偏移）：
 *   open <dev> <gid_index>                     -> OK gid=<32 hex>
 *   mr <size>                                  -> OK addr=<hex> rkey=<hex>
 *   qp rc|ud                                   -> OK qpn=<n>
 *   rc_connect <qp> <dqpn> <rq_psn> <sq_psn> <dip a.b.c.d> <mtu> <timeout> <retry> <rnr>
 *                                              -> OK（INIT->RTR->RTS）
 *   ud_ready <qp> <qkey> <sq_psn>              -> OK（INIT->RTR->RTS）
 *   recv <qp> <off> <len> <wr_id>              -> OK
 *   send <qp> <op> <off> <len> <wr_id> [imm|raddr rkey [imm]|raddr rkey cmp swap]
 *        op: send send_imm write write_imm read cas faa（faa 的加数填在 swap 位置）
 *   send_ud <qp> <off> <len> <wr_id> <dip> <dqpn> <qkey>
 *   poll <timeout_ms>   -> OK none | OK wr_id=.. status=.. opcode=.. len=.. imm=.. src_qp=.. qp=..
 *   wbuf <off> <hex>    -> OK          rbuf <off> <len> -> OK <hex>
 *   quit
 */
#include <arpa/inet.h>
#include <errno.h>
#include <infiniband/verbs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_QP 16

static struct ibv_context *ctx;
static struct ibv_pd *pd;
static struct ibv_cq *cq;
static struct ibv_mr *mr;
static uint8_t *buf;
static size_t buf_size;
static struct ibv_qp *qps[MAX_QP];
static int gid_index;
static const uint8_t port = 1;

/* 功能：解析十进制或 0x 十六进制无符号数；缺省为 0。 */
static uint64_t num(const char *s)
{
	return s ? strtoull(s, NULL, 0) : 0;
}

/* 功能：按 qpn 找本进程的 QP；找不到返回 NULL。 */
static struct ibv_qp *find_qp(uint32_t qpn)
{
	for (int i = 0; i < MAX_QP; i++)
		if (qps[i] && qps[i]->qp_num == qpn)
			return qps[i];
	return NULL;
}

/* 功能：IPv4 点分地址 -> IPv4 映射 GID；地址非法返回 -1。 */
static int ip_gid(const char *ip, union ibv_gid *gid)
{
	struct in_addr a;

	if (!ip || inet_pton(AF_INET, ip, &a) != 1)
		return -1;
	memset(gid, 0, sizeof(*gid));
	gid->raw[10] = 0xff;
	gid->raw[11] = 0xff;
	memcpy(&gid->raw[12], &a, 4);
	return 0;
}

/* 功能：填 RoCEv2 地址向量（GRH，跳数 64）。 */
static int fill_ah(struct ibv_ah_attr *ah, const char *dip)
{
	memset(ah, 0, sizeof(*ah));
	ah->is_global = 1;
	ah->port_num = port;
	ah->grh.sgid_index = gid_index;
	ah->grh.hop_limit = 64;
	return ip_gid(dip, &ah->grh.dgid);
}

static int cmd_open(char **a)
{
	struct ibv_device **list = ibv_get_device_list(NULL);
	union ibv_gid gid;

	for (int i = 0; list && list[i]; i++)
		if (!strcmp(ibv_get_device_name(list[i]), a[1]))
			ctx = ibv_open_device(list[i]);
	ibv_free_device_list(list);
	if (!ctx)
		return printf("ERR no device %s\n", a[1]);
	gid_index = (int)num(a[2]);
	pd = ibv_alloc_pd(ctx);
	cq = ibv_create_cq(ctx, 256, NULL, NULL, 0);
	if (!pd || !cq || ibv_query_gid(ctx, port, gid_index, &gid))
		return printf("ERR pd/cq/gid\n");
	printf("OK gid=");
	for (int i = 0; i < 16; i++)
		printf("%02x", gid.raw[i]);
	return printf("\n");
}

static int cmd_mr(char **a)
{
	buf_size = num(a[1]);
	buf = aligned_alloc(4096, (buf_size + 4095) & ~4095UL);
	if (!buf)
		return printf("ERR alloc\n");
	memset(buf, 0, buf_size);
	mr = ibv_reg_mr(pd, buf, buf_size, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
			IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_ATOMIC);
	if (!mr)
		return printf("ERR reg_mr %d\n", errno);
	return printf("OK addr=0x%lx rkey=0x%x\n", (unsigned long)buf, mr->rkey);
}

static int cmd_qp(char **a)
{
	struct ibv_qp_init_attr init = {0};
	struct ibv_qp_attr attr = {0};
	int ud = !strcmp(a[1], "ud");
	int slot = -1;
	int mask = IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT;

	for (int i = 0; i < MAX_QP && slot < 0; i++)
		if (!qps[i])
			slot = i;
	if (slot < 0)
		return printf("ERR too many QPs\n");
	init.send_cq = cq;
	init.recv_cq = cq;
	init.qp_type = ud ? IBV_QPT_UD : IBV_QPT_RC;
	init.cap.max_send_wr = 64;
	init.cap.max_recv_wr = 64;
	init.cap.max_send_sge = 1;
	init.cap.max_recv_sge = 1;
	qps[slot] = ibv_create_qp(pd, &init);
	if (!qps[slot])
		return printf("ERR create_qp %d\n", errno);
	attr.qp_state = IBV_QPS_INIT;
	attr.port_num = port;
	if (ud) {
		attr.qkey = 0x11111111;
		mask |= IBV_QP_QKEY;
	} else {
		attr.qp_access_flags = IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ |
				       IBV_ACCESS_REMOTE_ATOMIC;
		mask |= IBV_QP_ACCESS_FLAGS;
	}
	if (ibv_modify_qp(qps[slot], &attr, mask))
		return printf("ERR init %d\n", errno);
	return printf("OK qpn=%u\n", qps[slot]->qp_num);
}

static enum ibv_mtu mtu_enum(int mtu)
{
	switch (mtu) {
	case 256: return IBV_MTU_256;
	case 512: return IBV_MTU_512;
	case 2048: return IBV_MTU_2048;
	case 4096: return IBV_MTU_4096;
	default: return IBV_MTU_1024;
	}
}

static int cmd_rc_connect(char **a)
{
	struct ibv_qp *qp = find_qp(num(a[1]));
	struct ibv_qp_attr attr = {0};

	if (!qp)
		return printf("ERR no qp\n");
	attr.qp_state = IBV_QPS_RTR;
	attr.path_mtu = mtu_enum((int)num(a[6]));
	attr.dest_qp_num = num(a[2]);
	attr.rq_psn = num(a[3]);
	attr.max_dest_rd_atomic = 4;
	attr.min_rnr_timer = 1;
	if (fill_ah(&attr.ah_attr, a[5]))
		return printf("ERR bad ip\n");
	if (ibv_modify_qp(qp, &attr, IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN |
			  IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER))
		return printf("ERR rtr %d\n", errno);
	memset(&attr, 0, sizeof(attr));
	attr.qp_state = IBV_QPS_RTS;
	attr.sq_psn = num(a[4]);
	attr.timeout = num(a[7]);
	attr.retry_cnt = num(a[8]);
	attr.rnr_retry = num(a[9]);
	attr.max_rd_atomic = 4;
	if (ibv_modify_qp(qp, &attr, IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_TIMEOUT |
			  IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY | IBV_QP_MAX_QP_RD_ATOMIC))
		return printf("ERR rts %d\n", errno);
	return printf("OK\n");
}

static int cmd_ud_ready(char **a)
{
	struct ibv_qp *qp = find_qp(num(a[1]));
	struct ibv_qp_attr attr = {0};

	if (!qp)
		return printf("ERR no qp\n");
	attr.qkey = num(a[2]);
	if (ibv_modify_qp(qp, &attr, IBV_QP_QKEY))
		return printf("ERR qkey %d\n", errno);
	attr.qp_state = IBV_QPS_RTR;
	if (ibv_modify_qp(qp, &attr, IBV_QP_STATE))
		return printf("ERR rtr %d\n", errno);
	attr.qp_state = IBV_QPS_RTS;
	attr.sq_psn = num(a[3]);
	if (ibv_modify_qp(qp, &attr, IBV_QP_STATE | IBV_QP_SQ_PSN))
		return printf("ERR rts %d\n", errno);
	return printf("OK\n");
}

/* 功能：MR 内 [off, off+len) 的 SGE；越界返回 -1。 */
static int sge_of(struct ibv_sge *sge, const char *off, const char *len)
{
	uint64_t o = num(off), l = num(len);

	if (o + l > buf_size)
		return -1;
	sge->addr = (uintptr_t)buf + o;
	sge->length = (uint32_t)l;
	sge->lkey = mr->lkey;
	return 0;
}

static int cmd_recv(char **a)
{
	struct ibv_qp *qp = find_qp(num(a[1]));
	struct ibv_recv_wr wr = {0}, *bad;
	struct ibv_sge sge;

	if (!qp || sge_of(&sge, a[2], a[3]))
		return printf("ERR args\n");
	wr.wr_id = num(a[4]);
	wr.sg_list = &sge;
	wr.num_sge = 1;
	if (ibv_post_recv(qp, &wr, &bad))
		return printf("ERR post_recv %d\n", errno);
	return printf("OK\n");
}

static int cmd_send(char **a, int n)
{
	struct ibv_qp *qp = find_qp(num(a[1]));
	struct ibv_send_wr wr = {0}, *bad;
	struct ibv_sge sge;
	const char *op = a[2];

	if (!qp || n < 6 || sge_of(&sge, a[3], a[4]))
		return printf("ERR args\n");
	wr.wr_id = num(a[5]);
	wr.sg_list = &sge;
	wr.num_sge = sge.length ? 1 : 0;
	wr.send_flags = IBV_SEND_SIGNALED;
	if (!strcmp(op, "send")) {
		wr.opcode = IBV_WR_SEND;
	} else if (!strcmp(op, "send_imm")) {
		wr.opcode = IBV_WR_SEND_WITH_IMM;
		wr.imm_data = htonl((uint32_t)num(a[6]));
	} else if (!strcmp(op, "write") || !strcmp(op, "write_imm") || !strcmp(op, "read")) {
		wr.opcode = !strcmp(op, "read") ? IBV_WR_RDMA_READ :
			    !strcmp(op, "write") ? IBV_WR_RDMA_WRITE : IBV_WR_RDMA_WRITE_WITH_IMM;
		wr.wr.rdma.remote_addr = num(a[6]);
		wr.wr.rdma.rkey = (uint32_t)num(a[7]);
		if (wr.opcode == IBV_WR_RDMA_WRITE_WITH_IMM)
			wr.imm_data = htonl((uint32_t)num(a[8]));
	} else if (!strcmp(op, "cas") || !strcmp(op, "faa")) {
		int cas = !strcmp(op, "cas");

		wr.opcode = cas ? IBV_WR_ATOMIC_CMP_AND_SWP : IBV_WR_ATOMIC_FETCH_AND_ADD;
		wr.wr.atomic.remote_addr = num(a[6]);
		wr.wr.atomic.rkey = (uint32_t)num(a[7]);
		wr.wr.atomic.compare_add = cas ? num(a[8]) : num(a[9]);
		wr.wr.atomic.swap = num(a[9]);
	} else {
		return printf("ERR op %s\n", op);
	}
	if (ibv_post_send(qp, &wr, &bad))
		return printf("ERR post_send %d\n", errno);
	return printf("OK\n");
}

static int cmd_send_ud(char **a)
{
	struct ibv_qp *qp = find_qp(num(a[1]));
	struct ibv_send_wr wr = {0}, *bad;
	struct ibv_ah_attr ah_attr;
	struct ibv_ah *ah;
	struct ibv_sge sge;

	if (!qp || sge_of(&sge, a[2], a[3]) || fill_ah(&ah_attr, a[5]))
		return printf("ERR args\n");
	ah = ibv_create_ah(pd, &ah_attr);
	if (!ah)
		return printf("ERR create_ah %d\n", errno);
	wr.wr_id = num(a[4]);
	wr.sg_list = &sge;
	wr.num_sge = 1;
	wr.opcode = IBV_WR_SEND;
	wr.send_flags = IBV_SEND_SIGNALED;
	wr.wr.ud.ah = ah;
	wr.wr.ud.remote_qpn = (uint32_t)num(a[6]);
	wr.wr.ud.remote_qkey = (uint32_t)num(a[7]);
	if (ibv_post_send(qp, &wr, &bad))
		return printf("ERR post_send %d\n", errno);
	return printf("OK\n");
}

static int cmd_poll(char **a)
{
	struct ibv_wc wc;
	struct timespec t0, t;
	long limit = (long)num(a[1]);

	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (;;) {
		int n = ibv_poll_cq(cq, 1, &wc);

		if (n < 0)
			return printf("ERR poll\n");
		if (n == 1)
			return printf("OK wr_id=%lu status=%d opcode=%d len=%u imm=0x%x src_qp=%u qp=%u\n",
				      (unsigned long)wc.wr_id, wc.status, wc.opcode, wc.byte_len,
				      (wc.wc_flags & IBV_WC_WITH_IMM) ? ntohl(wc.imm_data) : 0,
				      wc.src_qp, wc.qp_num);
		clock_gettime(CLOCK_MONOTONIC, &t);
		if ((t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000 >= limit)
			return printf("OK none\n");
	}
}

static int cmd_wbuf(char **a)
{
	uint64_t off = num(a[1]);
	size_t n = strlen(a[2]) / 2;

	if (off + n > buf_size)
		return printf("ERR range\n");
	for (size_t i = 0; i < n; i++) {
		unsigned v;

		sscanf(a[2] + 2 * i, "%2x", &v);
		buf[off + i] = (uint8_t)v;
	}
	return printf("OK\n");
}

static int cmd_rbuf(char **a)
{
	uint64_t off = num(a[1]), n = num(a[2]);

	if (off + n > buf_size)
		return printf("ERR range\n");
	printf("OK ");
	for (uint64_t i = 0; i < n; i++)
		printf("%02x", buf[off + i]);
	return printf("\n");
}

int main(void)
{
	static char line[1 << 17];

	setvbuf(stdout, NULL, _IOLBF, 0);
	while (fgets(line, sizeof(line), stdin)) {
		char *a[16] = {0};
		int n = 0;

		for (char *tok = strtok(line, " \t\r\n"); tok && n < 16; tok = strtok(NULL, " \t\r\n"))
			a[n++] = tok;
		if (!n)
			continue;
		if (!strcmp(a[0], "quit"))
			break;
		if (strcmp(a[0], "open") && !ctx)
			printf("ERR not open\n");
		else if (!strcmp(a[0], "open") && n == 3)
			cmd_open(a);
		else if (!strcmp(a[0], "mr") && n == 2)
			cmd_mr(a);
		else if (!strcmp(a[0], "qp") && n == 2)
			cmd_qp(a);
		else if (!strcmp(a[0], "rc_connect") && n == 10)
			cmd_rc_connect(a);
		else if (!strcmp(a[0], "ud_ready") && n == 4)
			cmd_ud_ready(a);
		else if (!strcmp(a[0], "recv") && n == 5)
			cmd_recv(a);
		else if (!strcmp(a[0], "send"))
			cmd_send(a, n);
		else if (!strcmp(a[0], "send_ud") && n == 8)
			cmd_send_ud(a);
		else if (!strcmp(a[0], "poll") && n == 2)
			cmd_poll(a);
		else if (!strcmp(a[0], "wbuf") && n == 3)
			cmd_wbuf(a);
		else if (!strcmp(a[0], "rbuf") && n == 3)
			cmd_rbuf(a);
		else
			printf("ERR bad command %s/%d\n", a[0], n);
	}
	for (int i = 0; i < MAX_QP; i++)
		if (qps[i])
			ibv_destroy_qp(qps[i]);
	if (mr)
		ibv_dereg_mr(mr);
	if (cq)
		ibv_destroy_cq(cq);
	if (pd)
		ibv_dealloc_pd(pd);
	if (ctx)
		ibv_close_device(ctx);
	free(buf);
	return 0;
}

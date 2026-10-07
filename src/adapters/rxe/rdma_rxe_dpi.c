/*
 * 目录：外部适配器实现层 adapters/rxe/rdma_rxe_dpi.c。
 * 层：外部适配器（DPI-C）。
 * 职责：仿真与 Linux Soft-RoCE（rdma_rxe）互打的宿主机接口：
 *   - 持久 TAP 网卡（tools/rxe/rxe_tap_setup.sh 建立，属主为当前用户）的打开与原始以太网帧收发；
 *   - rxe_peer 子进程（tools/rxe/rxe_peer.c）的启动、逐行命令/应答与退出。
 * 所有权：TAP 文件描述符与子进程管道归本文件的静态表；仿真结束时由 SV 调用 stop/close 释放。
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "svdpi.h"

#define MAX_PEERS 4
#define FRAME_MAX 16384

struct peer {
	pid_t pid;
	FILE *to;
	FILE *from;
};

static struct peer peers[MAX_PEERS];
static char reply[1 << 17];

/* 功能：打开已存在的持久 TAP 网卡（IFF_TAP | IFF_NO_PI，非阻塞）。失败返回 -1。 */
int rdma_rxe_tap_open(const char *name)
{
	struct ifreq ifr;
	int fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK);

	if (fd < 0)
		return -1;
	memset(&ifr, 0, sizeof(ifr));
	ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
	strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
	if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

/* 功能：关闭 TAP。 */
void rdma_rxe_tap_close(int fd)
{
	if (fd >= 0)
		close(fd);
}

/* 功能：发送 data[0..len) 为一个以太网帧。返回写出的字节数，失败返回 -1。 */
int rdma_rxe_tap_send(int fd, const svOpenArrayHandle data, int len)
{
	unsigned char frame[FRAME_MAX];

	if (len <= 0 || len > FRAME_MAX)
		return -1;
	for (int i = 0; i < len; i++)
		frame[i] = *(unsigned char *)svGetArrElemPtr1(data, i);
	return (int)write(fd, frame, (size_t)len);
}

/* 功能：等待最多 timeout_us 微秒（真实时间）读一个帧到 buf（容量为 buf 元素数，超出截断）。
 * 返回帧长；超时或无帧返回 0。 */
int rdma_rxe_tap_recv(int fd, const svOpenArrayHandle buf, int timeout_us)
{
	unsigned char frame[FRAME_MAX];
	struct pollfd p = { .fd = fd, .events = POLLIN };
	struct timespec t = { .tv_sec = timeout_us / 1000000,
			      .tv_nsec = (long)(timeout_us % 1000000) * 1000 };
	int cap = svSize(buf, 1);
	ssize_t n;

	if (ppoll(&p, 1, &t, NULL) <= 0)
		return 0;
	n = read(fd, frame, sizeof(frame));
	if (n <= 0)
		return 0;
	if (n > cap)
		n = cap;
	for (int i = 0; i < n; i++)
		*(unsigned char *)svGetArrElemPtr1(buf, i) = frame[i];
	return (int)n;
}

/* 功能：启动 rxe_peer 子进程（stdin/stdout 接管道）。返回句柄（>=0），失败返回 -1。 */
int rdma_rxe_peer_start(const char *path)
{
	int in[2], out[2];
	int h = -1;

	for (int i = 0; i < MAX_PEERS && h < 0; i++)
		if (!peers[i].pid)
			h = i;
	if (h < 0 || pipe(in) || pipe(out))
		return -1;
	signal(SIGPIPE, SIG_IGN);
	peers[h].pid = fork();
	if (peers[h].pid < 0) {
		peers[h].pid = 0;
		return -1;
	}
	if (!peers[h].pid) {
		dup2(in[0], 0);
		dup2(out[1], 1);
		close(in[1]);
		close(out[0]);
		execl(path, path, (char *)NULL);
		_exit(127);
	}
	close(in[0]);
	close(out[1]);
	peers[h].to = fdopen(in[1], "w");
	peers[h].from = fdopen(out[0], "r");
	return h;
}

/* 功能：向 rxe_peer 发一行命令并读回一行应答（去掉换行）。子进程不可用时返回 "ERR peer ..."。 */
const char *rdma_rxe_peer_cmd(int h, const char *line)
{
	if (h < 0 || h >= MAX_PEERS || !peers[h].pid)
		return "ERR peer not started";
	if (fprintf(peers[h].to, "%s\n", line) < 0 || fflush(peers[h].to))
		return "ERR peer write";
	if (!fgets(reply, sizeof(reply), peers[h].from))
		return "ERR peer exited";
	reply[strcspn(reply, "\r\n")] = 0;
	return reply;
}

/* 功能：让 rxe_peer 退出并回收子进程。 */
void rdma_rxe_peer_stop(int h)
{
	if (h < 0 || h >= MAX_PEERS || !peers[h].pid)
		return;
	fprintf(peers[h].to, "quit\n");
	fclose(peers[h].to);
	fclose(peers[h].from);
	waitpid(peers[h].pid, NULL, 0);
	peers[h].pid = 0;
}

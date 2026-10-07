"""目录：工具层 tools/rxe/roce_frame.py。

层：验证工具（RoCEv2 参考实现）。
职责：按 IBTA Annex A17 构造与解析 RoCEv2（IPv4）以太网帧，计算 ICRC（与 Linux rxe 的
  rxe_icrc_hdr/rxe_crc32 一致：前置 8 字节 0xFF，IPv4 TOS/TTL/首部校验和、UDP 校验和、BTH resv8a
  置全 1，CRC32 反射多项式，取反后按小端写在负载与 pad 之后）；打开持久 TAP 网卡收发原始帧。
所有权：纯函数与一个 TAP 文件描述符包装；不持有其它资源。
"""
import fcntl
import os
import select
import struct
import time
import zlib

ROCE_PORT = 4791
TUNSETIFF = 0x400454CA
IFF_TAP = 0x0002
IFF_NO_PI = 0x1000

OP_RC_SEND_ONLY = 0x04
OP_RC_SEND_ONLY_IMM = 0x05
OP_RC_WRITE_ONLY = 0x0A
OP_RC_READ_REQ = 0x0C
OP_RC_READ_RESP_ONLY = 0x10
OP_RC_ACK = 0x11
OP_UD_SEND_ONLY = 0x64


def ext_len(opcode):
    """功能：BTH 之后的扩展头字节数（DETH/RETH/AETH/AtomicETH/AtomicAckETH/ImmDt）。"""
    low = opcode & 0x1F
    n = 8 if opcode >> 5 == 3 else 0
    if low in (0x06, 0x0A, 0x0B, 0x0C):
        n += 16
    if low in (0x0D, 0x0F, 0x10, 0x11, 0x12):
        n += 4
    if low in (0x13, 0x14):
        n += 28
    if low == 0x12:
        n += 8
    if low in (0x03, 0x05, 0x09, 0x0B):
        n += 4
    return n


def ipv4_checksum(hdr):
    """功能：IPv4 首部校验和（输入中校验和字段须为 0）。"""
    s = sum(struct.unpack("!10H", hdr[:20]))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def icrc(body):
    """功能：ICRC 值（u32，线上按小端写出）。body 为以太网头起到 pad 结束（不含 ICRC）的字节。

    rxe：crc = crc32_le(0xdebb20e3 = 8 字节 0xFF 之后的寄存器, 屏蔽后的 IP..pad)，icrc = ~crc；
    等价于 zlib.crc32(8 字节 0xFF + 屏蔽后的 IP..pad)。
    """
    ip = bytearray(body[14:])
    ihl = (ip[0] & 0x0F) * 4
    ip[1] = 0xFF
    ip[8] = 0xFF
    ip[10:12] = b"\xff\xff"
    ip[ihl + 6:ihl + 8] = b"\xff\xff"
    ip[ihl + 8 + 4] = 0xFF
    return zlib.crc32(b"\xff" * 8 + bytes(ip)) & 0xFFFFFFFF


def mac_bytes(mac):
    return bytes(int(x, 16) for x in mac.split(":"))


def build(src_mac, dst_mac, src_ip, dst_ip, opcode, dqpn, psn, payload=b"", ext=b"",
          ack_req=True, pkey=0xFFFF, se=False, sport=0xC000, bad_icrc=False, ttl=64):
    """功能：构造完整 RoCEv2 帧：Eth/IPv4/UDP/BTH/扩展头/负载/pad/ICRC（UDP 校验和为 0）。

    ext 为调用方按 opcode 组好的扩展头字节（长度须等于 ext_len(opcode)）。
    """
    if len(ext) != ext_len(opcode):
        raise ValueError(f"opcode {opcode:#x} needs {ext_len(opcode)}B ext, got {len(ext)}")
    pad = (4 - len(payload) % 4) % 4
    bth = struct.pack("!BBHII", opcode, (int(se) << 7) | (pad << 4), pkey, dqpn & 0xFFFFFF,
                      ((1 << 31) if ack_req else 0) | (psn & 0xFFFFFF))
    roce = bth + ext + payload + b"\x00" * pad
    udp_len = 8 + len(roce) + 4
    udp = struct.pack("!HHHH", sport, ROCE_PORT, udp_len, 0)
    ip = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + udp_len, 0, 0x4000, ttl, 17, 0,
                               bytes(map(int, src_ip.split("."))),
                               bytes(map(int, dst_ip.split(".")))))
    ip[10:12] = struct.pack("!H", ipv4_checksum(bytes(ip)))
    body = mac_bytes(dst_mac) + mac_bytes(src_mac) + b"\x08\x00" + bytes(ip) + udp + roce
    value = icrc(body) ^ (1 if bad_icrc else 0)
    return body + struct.pack("<I", value)


def parse(frame):
    """功能：解析 RoCEv2 IPv4 帧；非 RoCEv2 返回 None。按 IP 总长去掉以太网最小帧补齐。"""
    if len(frame) < 14 + 20 + 8 + 12 + 4 or frame[12:14] != b"\x08\x00":
        return None
    ihl = (frame[14] & 0x0F) * 4
    if frame[14 + 9] != 17:
        return None
    udp = 14 + ihl
    if struct.unpack("!H", frame[udp + 2:udp + 4])[0] != ROCE_PORT:
        return None
    end = 14 + struct.unpack("!H", frame[16:18])[0]
    bth = udp + 8
    opcode, flags, pkey, dqpn, apsn = struct.unpack("!BBHII", frame[bth:bth + 12])
    n = ext_len(opcode)
    pad = (flags >> 4) & 3
    body_end = end - 4
    got = struct.unpack("<I", frame[body_end:end])[0]
    return {
        "opcode": opcode, "dqpn": dqpn & 0xFFFFFF, "resv8a": dqpn >> 24,
        "psn": apsn & 0xFFFFFF, "ack_req": apsn >> 31, "pad": pad, "se": flags >> 7,
        "tver": flags & 0xF, "pkey": pkey, "ext": frame[bth + 12:bth + 12 + n],
        "payload": frame[bth + 12 + n:body_end - pad], "icrc": got,
        "icrc_ok": icrc(frame[:body_end]) == got,
        "src_ip": ".".join(map(str, frame[26:30])), "dst_ip": ".".join(map(str, frame[30:34])),
        "ttl": frame[22], "udp_csum": struct.unpack("!H", frame[udp + 6:udp + 8])[0],
        "sport": struct.unpack("!H", frame[udp:udp + 2])[0],
        "src_mac": ":".join(f"{b:02x}" for b in frame[6:12]),
        "dst_mac": ":".join(f"{b:02x}" for b in frame[0:6]),
    }


class Tap:
    """持久 TAP 网卡（IFF_TAP | IFF_NO_PI）的收发包装。"""

    def __init__(self, name):
        self.fd = os.open("/dev/net/tun", os.O_RDWR | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, TUNSETIFF, struct.pack("16sH", name.encode(), IFF_TAP | IFF_NO_PI))
        self.log = []  # 收到的全部 RoCEv2 帧（供导出黄金向量）

    def send(self, frame):
        os.write(self.fd, frame)

    def recv_roce(self, timeout=1.0):
        """功能：读下一个 RoCEv2 帧（跳过其它报文）；超时返回 (None, None)。"""
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None, None
            r, _, _ = select.select([self.fd], [], [], left)
            if not r:
                return None, None
            f = os.read(self.fd, 65536)
            p = parse(f)
            if p is not None:
                self.log.append(f)
                return f, p

    def drain(self):
        while self.recv_roce(0.05)[0] is not None:
            pass

    def close(self):
        os.close(self.fd)

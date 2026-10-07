#!/usr/bin/env python3
"""目录：工具层 tools/rxe/rxe_icrc_check.py。

层：验证工具（P0：RoCEv2 线上格式与 ICRC 对真实 rxe 的在线校验）。
职责：经 TAP 扮演“仿真侧”主机，用 roce_frame 构造 RoCEv2 帧注入 Soft-RoCE，并解析 rxe 发出的帧：
  - 注入：RC SEND（含 pad）、WRITE、READ、FETCH_ADD、UD SEND，rxe 完成且数据正确 → 我方帧格式与
    ICRC 被 rxe 接受；错误 ICRC 被 rxe 丢弃。
  - 接收：rxe 的 ACK/READ 响应/ATOMIC ACK/RC SEND/UD SEND 的 ICRC 用同一算法校验通过 → 算法与
    rxe 一致；同时记录 rxe 的线上字段（AckReq、pad、TTL、UDP 校验和、源端口、AETH）。
  - AckReq=0 的 SEND：观察 rxe 是否回 ACK（决定设备请求方是否必须置 AckReq）。
前置：tools/rxe/rxe_tap_setup.sh up 已建立 rtap0/rxe_rtap0；rxe_peer 已编译。
用法：rxe_icrc_check.py <rxe_peer 路径> [tap] [rxe_dev] [gid_index] [--dump <文件>]
  --dump：把 rxe 发出的全部 RoCEv2 帧按行写成十六进制（net_packet ICRC 测试的黄金向量）。
"""
import struct
import subprocess
import sys

import roce_frame as rf

SIM_MAC = "02:00:00:00:79:01"
SIM_IP = "10.79.0.1"
RXE_IP = "10.79.0.2"
SIM_QPN = 0x100
SIM_UD_QPN = 0x101
QKEY = 0x11111111


class Peer:
    """rxe_peer 子进程：逐行命令/应答。"""

    def __init__(self, path):
        self.p = subprocess.Popen([path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, bufsize=1)

    def cmd(self, line):
        """功能：发一条命令；返回 key=value 字典，或 OK 之后的文本（无 key=value 时）。"""
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        reply = self.p.stdout.readline().strip()
        if not reply.startswith("OK"):
            raise RuntimeError(f"{line} -> {reply}")
        pairs = dict(kv.split("=", 1) for kv in reply.split()[1:] if "=" in kv)
        return pairs if pairs else reply[3:]

    def close(self):
        self.p.stdin.write("quit\n")
        self.p.stdin.flush()
        self.p.wait(5)


results = []


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}")


def describe(p):
    if p is None:
        return "no frame"
    return (f"op={p['opcode']:#04x} psn={p['psn']:#x} ackreq={p['ack_req']} pad={p['pad']} "
            f"ttl={p['ttl']} udp_csum={p['udp_csum']:#06x} sport={p['sport']:#06x} "
            f"pkey={p['pkey']:#06x} tver={p['tver']} icrc={p['icrc']:#010x} ext={p['ext'].hex()}")


def main():
    dump = None
    if "--dump" in sys.argv:
        i = sys.argv.index("--dump")
        dump = sys.argv[i + 1]
        del sys.argv[i:i + 2]
    peer_path = sys.argv[1]
    tap_name = sys.argv[2] if len(sys.argv) > 2 else "rtap0"
    dev = sys.argv[3] if len(sys.argv) > 3 else "rxe_rtap0"
    gid = sys.argv[4] if len(sys.argv) > 4 else "1"
    rxe_mac = open(f"/sys/class/net/{tap_name}/address").read().strip()
    tap = rf.Tap(tap_name)
    peer = Peer(peer_path)
    peer.cmd(f"open {dev} {gid}")
    m = peer.cmd("mr 65536")
    addr, rkey = int(m["addr"], 16), int(m["rkey"], 16)
    qpn = int(peer.cmd("qp rc")["qpn"])
    ud_qpn = int(peer.cmd("qp ud")["qpn"])
    peer.cmd(f"rc_connect {qpn} {SIM_QPN} 0x10 0x200 {SIM_IP} 1024 14 7 7")
    peer.cmd(f"ud_ready {ud_qpn} {QKEY} 0x300")
    tap.drain()

    def to_rxe(opcode, psn, payload=b"", ext=b"", dq=qpn, **kw):
        tap.send(rf.build(SIM_MAC, rxe_mac, SIM_IP, RXE_IP, opcode, dq, psn, payload, ext, **kw))

    psn = 0x10
    # A/B：SEND ONLY，pad 0 与 pad 3。
    for size, wr in ((100, 1), (101, 2)):
        peer.cmd(f"recv {qpn} 0 1024 {wr}")
        data = bytes((i * 7 + size) & 0xFF for i in range(size))
        to_rxe(rf.OP_RC_SEND_ONLY, psn, data)
        wc = peer.cmd("poll 1000")
        _, ack = tap.recv_roce(1.0)
        got = bytes.fromhex(peer.cmd(f"rbuf 0 {size}"))
        check(f"SEND {size}B accepted", wc != "none" and wc.get("wr_id") == str(wr) and
              wc.get("status") == "0" and got == data, str(wc))
        check(f"SEND {size}B ACK ICRC", ack is not None and ack["opcode"] == rf.OP_RC_ACK and
              ack["icrc_ok"] and ack["psn"] == psn and ack["dqpn"] == SIM_QPN, describe(ack))
        psn += 1

    # C：错误 ICRC 被丢弃（无完成、无 ACK），随后同 PSN 的正确帧被接受。
    peer.cmd(f"recv {qpn} 0 1024 3")
    to_rxe(rf.OP_RC_SEND_ONLY, psn, b"bad-icrc", bad_icrc=True)
    wc = peer.cmd("poll 300")
    _, ack = tap.recv_roce(0.3)
    check("bad ICRC dropped", wc == "none" and ack is None, str(wc))
    to_rxe(rf.OP_RC_SEND_ONLY, psn, b"good-icr")
    wc = peer.cmd("poll 1000")
    tap.recv_roce(1.0)
    check("same PSN accepted after drop", wc != "none" and wc.get("wr_id") == "3", str(wc))
    psn += 1

    # D：AckReq=0 的 SEND：rxe 完成接收，但是否回 ACK？
    peer.cmd(f"recv {qpn} 0 1024 4")
    to_rxe(rf.OP_RC_SEND_ONLY, psn, b"no-ackreq", ack_req=False)
    wc = peer.cmd("poll 1000")
    _, ack = tap.recv_roce(0.5)
    print(f"INFO AckReq=0 SEND: completion={wc} ack={describe(ack) if ack else 'none'}")
    psn += 1

    # F：WRITE ONLY（RETH）→ ACK，数据落到 MR+0x1000。
    data = bytes(range(64))
    to_rxe(rf.OP_RC_WRITE_ONLY, psn, data, struct.pack("!QII", addr + 0x1000, rkey, len(data)))
    _, ack = tap.recv_roce(1.0)
    got = bytes.fromhex(peer.cmd("rbuf 0x1000 64"))
    check("WRITE accepted", ack is not None and ack["opcode"] == rf.OP_RC_ACK and ack["icrc_ok"]
          and got == data, describe(ack))
    psn += 1

    # G：READ 请求 → READ RESPONSE ONLY。
    peer.cmd("wbuf 0x2000 " + bytes(range(100, 140)).hex())
    to_rxe(rf.OP_RC_READ_REQ, psn, b"", struct.pack("!QII", addr + 0x2000, rkey, 40))
    _, rsp = tap.recv_roce(1.0)
    check("READ response", rsp is not None and rsp["opcode"] == rf.OP_RC_READ_RESP_ONLY and
          rsp["icrc_ok"] and rsp["payload"] == bytes(range(100, 140)), describe(rsp))
    psn += 1

    # I：FETCH_ADD → ATOMIC ACKNOWLEDGE（原值 40，内存加 5）。
    peer.cmd("wbuf 0x3000 " + struct.pack("<Q", 40).hex())
    to_rxe(0x14, psn, b"", struct.pack("!QIQQ", addr + 0x3000, rkey, 5, 0))
    _, rsp = tap.recv_roce(1.0)
    after = struct.unpack("<Q", bytes.fromhex(peer.cmd("rbuf 0x3000 8")))[0]
    orig = struct.unpack("!Q", rsp["ext"][4:12])[0] if rsp else None
    check("FETCH_ADD", rsp is not None and rsp["opcode"] == 0x12 and rsp["icrc_ok"] and
          orig == 40 and after == 45, f"orig={orig} after={after} {describe(rsp)}")
    psn += 1

    # E：rxe 作为请求方发 SEND → 校验其帧，回 ACK（AETH 0x1F 无限信用，MSN 1）→ rxe 发送完成。
    peer.cmd("wbuf 0x4000 " + bytes(range(50)).hex())
    peer.cmd(f"send {qpn} send 0x4000 50 9")
    _, req = tap.recv_roce(1.0)
    check("rxe SEND frame ICRC", req is not None and req["opcode"] == rf.OP_RC_SEND_ONLY and
          req["icrc_ok"] and req["payload"] == bytes(range(50)) and req["dqpn"] == SIM_QPN,
          describe(req))
    if req:
        to_rxe(rf.OP_RC_ACK, req["psn"], b"", struct.pack("!I", (0x1F << 24) | 1),
               ack_req=False)
    wc = peer.cmd("poll 1000")
    check("rxe SEND completes on our ACK", wc != "none" and wc.get("wr_id") == "9" and
          wc.get("status") == "0", str(wc))

    # H：UD SEND ONLY（DETH）→ rxe UD QP 收到，缓冲前 40B 为 GRH；rxe UD SEND 的 DETH 校验。
    peer.cmd(f"recv {ud_qpn} 0x8000 1064 11")
    to_rxe(rf.OP_UD_SEND_ONLY, 0x40, b"ud-payload-from-sim",
           struct.pack("!II", QKEY, SIM_UD_QPN), dq=ud_qpn)
    wc = peer.cmd("poll 1000")
    got = bytes.fromhex(peer.cmd("rbuf 0x8028 19"))
    check("UD SEND accepted", wc != "none" and wc.get("len") == str(40 + 19) and
          wc.get("src_qp") == str(SIM_UD_QPN) and got == b"ud-payload-from-sim", str(wc))
    peer.cmd("wbuf 0x9000 " + b"ud-from-rxe".hex())
    peer.cmd(f"send_ud {ud_qpn} 0x9000 11 12 {SIM_IP} {SIM_UD_QPN} {QKEY}")
    _, req = tap.recv_roce(1.0)
    peer.cmd("poll 1000")
    deth = struct.unpack("!II", req["ext"]) if req else (0, 0)
    check("rxe UD frame", req is not None and req["opcode"] == rf.OP_UD_SEND_ONLY and
          req["icrc_ok"] and deth == (QKEY, ud_qpn) and req["payload"] == b"ud-from-rxe",
          describe(req))

    peer.close()
    if dump:
        with open(dump, "w") as out:
            for f in tap.log:
                out.write(f.hex() + "\n")
    tap.close()
    print(f"SUMMARY {sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())

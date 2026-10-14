#!/usr/bin/env python3
# 目录：工具层 tools/generate_rdma_qpc_manual_ppt.py。
# 职责：使用 LibreOffice UNO 生成 RDMA QPC 生命周期与数据路径 PPT 手册，内容与当前
#   feature/rdma-arch-slim 分支的 driver、device、codec 和 tb 实现对应。
# 依赖：系统 LibreOffice/pyuno；不读取外部凭据，不修改源码，不访问外部仓库。
# 所有权与生命周期：脚本只创建输出 PPTX 和临时 LibreOffice profile；输出文件由调用方拥有，
#   LibreOffice 进程在生成结束后关闭，临时 profile 随进程退出后由系统回收。

"""生成可审阅的 RDMA QPC 技术手册 PPTX。"""

from __future__ import annotations

import argparse
import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path

import uno
from com.sun.star.awt import Point, Size
from com.sun.star.beans import PropertyValue
from com.sun.star.drawing import HomogenMatrix3


W = 33_867
H = 19_050
FONT = "Noto Sans CJK SC"
MONO = "Noto Sans Mono CJK SC"
NAVY = 0x102A43
BLUE = 0x1565C0
TEAL = 0x00897B
CYAN = 0x00ACC1
GREEN = 0x2E7D32
ORANGE = 0xEF6C00
RED = 0xC62828
PURPLE = 0x6A1B9A
INK = 0x243B53
MUTED = 0x52606D
PALE = 0xF0F4F8
PALE_BLUE = 0xE3F2FD
PALE_TEAL = 0xE0F2F1
PALE_ORANGE = 0xFFF3E0
PALE_RED = 0xFFEBEE
WHITE = 0xFFFFFF
BLACK = 0x111111


def prop(name: str, value):
    # 功能：构造 LibreOffice UNO 属性值，供文档加载、保存和页面设置接口使用。
    # 输入/输出及副作用：name/value 为输入；返回一个 PropertyValue，不修改文档或外部资源。
    # 失败/边界：调用者必须传入当前 UNO 服务接受的属性名和值类型，未知属性在调用端报错。
    item = PropertyValue()
    item.Name = name
    item.Value = value
    return item


def point(x: int, y: int) -> Point:
    # 功能：把 PPT 画布坐标转换成 UNO Point，统一使用 1/100 mm 的绝对坐标。
    # 输入/输出及副作用：x/y 为非负坐标；返回新 Point，不创建图形对象。
    # 失败/边界：坐标超出页面不会在此处拒绝，超界结果由 LibreOffice 裁剪或隐藏。
    value = Point()
    value.X = x
    value.Y = y
    return value


def size(width: int, height: int) -> Size:
    # 功能：把宽高转换成 UNO Size，供文本框、矩形和表格单元设置尺寸。
    # 输入/输出及副作用：width/height 为 1/100 mm 尺寸；返回新 Size，不修改调用方。
    # 失败/边界：零或负尺寸可能被 LibreOffice 拒绝，调用方应在布局阶段保证正数。
    value = Size()
    value.Width = width
    value.Height = height
    return value


def connect_office(port: int):
    # 功能：启动隔离的无界面 LibreOffice Impress 服务并建立 UNO 连接。
    # 输入/输出及副作用：port 为本地监听端口；返回 (process, context, desktop, profile_dir)，
    #   会启动一个短生命周期外部进程和临时用户 profile。
    # 失败/边界：端口无法监听、UNO 服务未在 30 秒内出现或 desktop 创建失败时抛出 RuntimeError；
    #   调用方必须在 finally 中终止 process。
    profile_dir = tempfile.mkdtemp(prefix="rdma-qpc-ppt-profile-")
    profile_url = uno.systemPathToFileUrl(profile_dir)
    command = [
        "soffice",
        "--headless",
        "--norestore",
        "--nofirststartwizard",
        f"-env:UserInstallation={profile_url}",
        f"--accept=socket,host=127.0.0.1,port={port};urp;StarOffice.ComponentContext",
    ]
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    local_ctx = uno.getComponentContext()
    resolver = local_ctx.ServiceManager.createInstanceWithContext(
        "com.sun.star.bridge.UnoUrlResolver", local_ctx
    )
    deadline = time.time() + 30
    last_error = None
    while time.time() < deadline:
        try:
            context = resolver.resolve(
                f"uno:socket,host=127.0.0.1,port={port};urp;StarOffice.ComponentContext"
            )
            desktop = context.ServiceManager.createInstanceWithContext(
                "com.sun.star.frame.Desktop", context
            )
            return process, context, desktop, profile_dir
        except Exception as exc:  # pragma: no cover - depends on local soffice startup timing.
            last_error = exc
            time.sleep(0.25)
    process.terminate()
    raise RuntimeError(f"LibreOffice UNO startup timed out: {last_error}")


def set_page_style(page) -> None:
    # 功能：把单张 Impress 页面固定为 16:9 横向画布，并清除默认页面边距，保证代码和时序图可用。
    # 输入/输出及副作用：page 为 DrawPage；原地修改页面 Width/Height/Border 属性，不返回值。
    # 失败/边界：页面对象必须支持尺寸属性；不同 LibreOffice 版本不暴露 PageStyles 时仍可用此直接设置路径。
    page.Width = W
    page.Height = H
    page.BorderTop = 0
    page.BorderBottom = 0
    page.BorderLeft = 0
    page.BorderRight = 0


def apply_text(shape, text: str, font_size: float = 17, color: int = INK,
               bold: bool = False, font: str = FONT, align: int = 0,
               valign: int = 0) -> None:
    # 功能：将字符串写入图形并设置统一的中英文/代码字体、字号、颜色和对齐方式。
    # 输入/输出及副作用：shape/text/font_size 等为输入；修改 shape 的文本属性，不拥有外部对象。
    # 失败/边界：过长文本不会自动拆页，调用者必须按布局控制行数；不支持的字体由 LibreOffice 回退。
    shape.String = text
    shape.CharFontName = font
    shape.CharHeight = font_size
    shape.CharColor = color
    shape.CharWeight = 150 if bold else 100
    shape.ParaAdjust = align
    shape.TextVerticalAdjust = valign
    shape.TextLeftDistance = 180
    shape.TextRightDistance = 180
    shape.TextUpperDistance = 110
    shape.TextLowerDistance = 110
    shape.TextAutoGrowHeight = False
    shape.TextAutoGrowWidth = False


def add_box(document, page, x: int, y: int, width: int, height: int,
            text: str = "", fill: int = WHITE, line: int = WHITE,
            font_size: float = 16, color: int = INK, bold: bool = False,
            radius: bool = False, font: str = FONT, align: int = 0,
            valign: int = 0):
    # 功能：在页面上创建带背景、边框和可选文字的矩形/圆角矩形，用于卡片、表格单元和流程节点。
    # 输入/输出及副作用：坐标、尺寸、文本和颜色为输入；返回新图形并加入 page，页面获得其所有权。
    # 失败/边界：尺寸必须为正；文字超出固定区域时会被裁剪，因此详细内容应拆分为多个 box。
    kind = "com.sun.star.drawing.RectangleShape"
    shape = document.createInstance(kind)
    shape.Position = point(x, y)
    shape.Size = size(width, height)
    # com.sun.star.drawing.FillStyle.SOLID 的枚举值为 1；显式设置才能让背景色在 PPTX/PDF
    # 导出后保持可见，不能依赖默认填充样式。
    shape.FillStyle = 1
    shape.FillColor = fill
    shape.LineStyle = 0
    shape.LineColor = line
    shape.LineWidth = 20
    page.add(shape)
    if text:
        apply_text(shape, text, font_size, color, bold, font, align, valign)
    return shape


def add_line(document, page, x1: int, y1: int, x2: int, y2: int,
             color: int = BLUE, width: int = 55):
    # 功能：绘制流程图连接线，表达状态、数据或资源的方向关系。
    # 输入/输出及副作用：端点和样式为输入；创建并加入 page 的 LineShape，返回图形引用。
    # 失败/边界：线端点在页面外时由 LibreOffice 裁剪；箭头语义由相邻文字“→”补充，避免版本差异。
    shape = document.createInstance("com.sun.star.drawing.LineShape")
    shape.Position = point(x1, y1)
    shape.Size = size(x2 - x1, y2 - y1)
    shape.LineColor = color
    shape.LineWidth = width
    page.add(shape)
    return shape


def add_table(document, page, x: int, y: int, width: int, row_height: int,
              headers: list[str], rows: list[list[str]], header_fill: int = NAVY,
              body_fill: int = WHITE, font_size: float = 13,
              widths: list[int] | None = None):
    # 功能：使用矩形单元格绘制稳定的技术表格，支持字段、动作、失败条件等多列映射。
    # 输入/输出及副作用：headers/rows 为二维文字输入；在 page 中创建单元格集合并返回总高度。
    # 失败/边界：每行列数不足时补空字符串，列宽总和不等于 width 时按比例归一，超长单元格需调用方拆行。
    count = len(headers)
    if widths is None or len(widths) != count:
        widths = [width // count] * count
        widths[-1] += width - sum(widths)
    elif sum(widths) != width:
        scale = width / sum(widths)
        widths = [int(v * scale) for v in widths]
        widths[-1] += width - sum(widths)
    all_rows = [headers] + rows
    for r, values in enumerate(all_rows):
        cx = x
        for c in range(count):
            cell_text = values[c] if c < len(values) else ""
            fill = header_fill if r == 0 else body_fill
            color = WHITE if r == 0 else INK
            add_box(document, page, cx, y + r * row_height, widths[c], row_height,
                    cell_text, fill, 0xCFD8E3, font_size, color, r == 0,
                    font=FONT, valign=0)
            cx += widths[c]
    return len(all_rows) * row_height


def add_code(document, page, x: int, y: int, width: int, height: int, text: str,
             font_size: float = 12):
    # 功能：添加深色等宽代码块，展示实际函数调用、字段写入和错误回滚伪代码。
    # 输入/输出及副作用：text 为代码快照；创建代码框，不修改源码文件。
    # 失败/边界：代码行过长会影响可读性，调用方应在 100 字符以内拆行；代码框不执行任何命令。
    return add_box(document, page, x, y, width, height, text, 0x172B4D, 0x172B4D,
                   font_size, 0xE6F1FF, False, font=MONO, valign=0)


def add_title(document, page, title: str, section: str, number: int) -> None:
    # 功能：为普通内容页添加统一深色标题栏、章节标签和页码，建立 PPT 的可导航层次。
    # 输入/输出及副作用：title/section/number 为输入；向 page 添加标题、章节和页码图形。
    # 失败/边界：标题过长时应由调用方缩短；页码从 1 开始且不参与正文布局。
    add_box(document, page, 0, 0, W, 1_450, "", NAVY, NAVY)
    add_box(document, page, 900, 160, 5_100, 520, section.upper(), NAVY, NAVY,
            11, 0x9FB3C8, True, font=FONT, valign=1)
    add_box(document, page, 900, 590, W - 2_000, 760, title, NAVY, NAVY,
            25, WHITE, True, font=FONT, valign=1)
    add_box(document, page, 900, H - 620, W - 1_800, 300,
            "RDMA QPC 生命周期与数据路径手册  ·  feature/rdma-arch-slim",
            WHITE, WHITE, 9, MUTED, False, font=FONT)
    add_box(document, page, W - 2_000, H - 650, 1_100, 360, f"{number:02d}",
            WHITE, WHITE, 11, MUTED, True, font=MONO, align=3)


def add_cover(document, page) -> None:
    # 功能：创建封面，说明手册主题、代码基线和阅读目标。
    # 输入/输出及副作用：page 为首张 Impress 页面；添加封面图形，不改变源码或配置。
    # 失败/边界：封面只承载摘要，不替代正文中的状态、分配和回滚说明。
    add_box(document, page, 0, 0, W, H, "", NAVY, NAVY)
    add_box(document, page, 1_300, 1_450, 6_000, 520, "RDMA / QPC", NAVY, NAVY,
            17, 0x8FD3FF, True, font=MONO)
    add_box(document, page, 1_300, 2_550, 28_000, 2_500,
            "从 QP 创建到报文发送\nQPC 生命周期与数据路径手册", NAVY, NAVY,
            34, WHITE, True, font=FONT)
    add_box(document, page, 1_300, 5_650, 25_000, 1_250,
            "面向代码审查、环境搭建、真实 DUT 对接和 QPC 字段验证\n"
            "覆盖 QPN / SQ / RQ / SGB / ORQ / EIRQ / UAQ / HMC / QPC / CQE",
            NAVY, NAVY, 18, 0xD9E2EC, False, font=FONT)
    add_box(document, page, 1_300, 15_300, 20_000, 650,
            "代码基线：feature/rdma-arch-slim  ·  以当前 driver/dev/tb 实现为准",
            NAVY, NAVY, 12, 0x9FB3C8, False, font=FONT)
    add_box(document, page, 29_000, 15_050, 2_900, 900, "QPC\n512 B", TEAL, TEAL,
            20, WHITE, True, font=MONO, align=3, valign=1)


def add_bullets(document, page, x: int, y: int, width: int, height: int,
                lines: list[str], font_size: float = 16, color: int = INK,
                fill: int = WHITE, accent: int = BLUE):
    # 功能：以带左侧强调条的段落卡片承载步骤说明、约束和观察点。
    # 输入/输出及副作用：lines 为已拆分的短句；在 page 中创建卡片，不返回业务数据。
    # 失败/边界：每个卡片建议不超过 8 行；超过时应拆成多卡片而不是压缩字号。
    add_box(document, page, x, y, width, height, "", fill, fill)
    add_box(document, page, x, y, 140, height, "", accent, accent)
    text = "\n".join(f"• {line}" for line in lines)
    return add_box(document, page, x + 230, y + 80, width - 340, height - 160,
                   text, fill, fill, font_size, color, False, font=FONT)


def add_flow(document, page, y: int, nodes: list[tuple[str, int]],
             x: int = 1_000, width: int = 31_800, height: int = 1_250,
             font_size: float = 16):
    # 功能：绘制横向流程节点，把状态、资源或数据面阶段串成一条可讲解时序。
    # 输入/输出及副作用：nodes 为 (文字, 颜色) 列表；创建节点和连接符，不修改文档外对象；
    #   font_size 用于节点文字，允许时间线等窄节点降低字号。
    # 失败/边界：节点过多会导致文字拥挤，调用方应限制在 7 个以内或拆成多条流程；
    #   多行标签必须配合足够的 height/font_size，否则会被裁剪。
    gap = 360
    node_w = (width - gap * (len(nodes) - 1)) // len(nodes)
    for i, (label, fill) in enumerate(nodes):
        nx = x + i * (node_w + gap)
        add_box(document, page, nx, y, node_w, height, label, fill, fill,
                font_size, WHITE, True, radius=True, valign=1, align=3)
        if i < len(nodes) - 1:
            add_box(document, page, nx + node_w + 70, y + height // 2 - 170, gap - 140,
                    340, "→", WHITE, WHITE, 24, MUTED, True, font=MONO, align=3,
                    valign=1)


def make_slides():
    # 功能：返回手册所有页面的结构化内容，按资源、状态、数据面、异常和调试顺序组织。
    # 输入/输出及副作用：无输入；返回由 title/section/kind/body 等字段组成的列表，不启动 UNO。
    # 失败/边界：内容中的代码路径是当前分支基线；若源码重排，生成前需重新核对行号和字段名。
    slides = []
    slides.append({"kind": "cover"})
    slides.extend([
        {
            "title": "如何阅读这份手册",
            "section": "00 · 读图方法",
            "kind": "bullets",
            "body": [
                {
                    "title": "状态驱动行为",
                    "body": "本手册关注状态如何驱动行为，而不是只罗列 QPC 字段。",
                    "fill": PALE_BLUE,
                    "accent": BLUE,
                },
                {
                    "title": "四个观察面",
                    "body": "每一页同时给出：调用入口、内存/对象变化、硬件可见结果、失败回滚。",
                    "fill": PALE_TEAL,
                    "accent": TEAL,
                },
                {
                    "title": "按代码基线阅读",
                    "body": "代码基线以 .worktrees/rdma-arch-slim 为准；行号用于快速定位实现。",
                    "fill": PALE_ORANGE,
                    "accent": ORANGE,
                },
            ],
            "note": "主线：资源创建 → QPC 镜像 → QP 状态 → SQ/RQ 数据面 → 报文 → CQE → 销毁。",
        },
        {
            "title": "全局对象关系：谁拥有资源，谁只读快照",
            "section": "01 · 环境总览",
            "kind": "table",
            "headers": ["对象/层", "主要职责", "拥有/借用的资源", "关键接口"],
            "rows": [
                ["Function / drv", "控制面、CMQ、QP 生命周期", "拥有 QPN、SQ/RQ、side buffer、QPC 镜像", "create_qp / modify / destroy"],
                ["PD / MR / CQ / SRQ", "权限、内存和完成队列", "各自 backing；QP 只保存借用引用", "create / register / post / poll"],
                ["HMC / QPC", "把 QPN 映射到 512B context", "QPC slot、shadow、PBA", "locate / QPC_CREATE / MODIFY"],
                ["dev_cmq / dev_nic", "消费 CMQ、读取 QPC、执行 NIC", "设备侧 context/runtime", "qpc_written / drain_sq / handle_request"],
                ["net_packet / dut_link", "wire 编解码与 DUT 边界", "raw frame 副本；不拥有 QPC", "encode / decode / endpoint"],
            ],
            "note": "核心不变量：QPC 是硬件上下文权威；netpacket 只能校验并投影，不能反向覆盖 QPC。",
        },
        {
            "title": "从环境启动到一次业务完成",
            "section": "01 · 环境总览",
            "kind": "flow",
            "nodes": [("Function\nprobe / BAR", NAVY), ("PD / MR / CQ", BLUE), ("QP create\nQPC_CREATE", TEAL), ("INIT→RTR→RTS", GREEN), ("WQE / doorbell", ORANGE), ("NIC / wire", PURPLE), ("CQE / poll", RED)],
            "note": "真实 DUT 对接时，最后一段由 rdma_dut_link endpoint 替换模型 loopback；控制面仍由 driver/dev 负责。",
        },
        {
            "title": "create_qp 的输入前提与所有权边界",
            "section": "02 · create_qp",
            "kind": "two",
            "left_title": "调用方必须准备",
            "left": [
                "PD 非空：决定 QPC_PD_IDX 与本地/远端权限上下文。",
                "send_cq、recv_cq 非空；URC 可能创建 frag CQ。",
                "max_send_wr / max_recv_wr / SGE / inline 等能力参数。",
                "Function 已 probe，dev.hw、HMC、CMQ 可用。",
            ],
            "right_title": "create_qp 接管/借用",
            "right": [
                "QP 拥有 QPN、SQ/RQ backing、SGB、side buffer、QPC slot。",
                "CQ、PD、SRQ 是借用引用，不在 QP 中释放其主体。",
                "失败时按分配逆序释放；成功后放入 dev.qp_table。",
                "入口：src/drv/rdma_drv_qp.sv:create_qp()。",
            ],
            "note": "先有 Function/PD/CQ/MR 等资源，QP 才能把高层引用固化为 QPC 中的数值。",
        },
        {
            "title": "create_qp①：参数检查、QPN 和 qp_sn",
            "section": "02 · create_qp",
            "kind": "detail",
            "steps": [
                ("1", "检查 max_send_sge/max_recv_sge ≤ 32、max_inline ≤ 512、WR ≤ 32768。", BLUE),
                ("2", "检查 PD、send_cq、recv_cq 非空；URC 不允许携带 SRQ。", BLUE),
                ("3", "根据 cfg.rc_to_urc + qp_type 决定 urc 标志；RC 可能转 URC。", TEAL),
                ("4", "dev.qp_ids.alloc_next(qp.qpn)：从 Function 的 QPN 分配器取得 QPN。", ORANGE),
                ("5", "dev.qp_sn[qpn] 不存在则置 0；qp.qp_sn 取当前值，再自增保存下次序号。", ORANGE),
            ],
            "code": "if (!dev.qp_ids.alloc_next(qp.qpn))\n  return RESOURCE_EXHAUSTED;\n\nif (!dev.qp_sn.exists(qp.qpn))\n  dev.qp_sn[qp.qpn] = 0;\nqp.qp_sn = dev.qp_sn[qp.qpn]++;",
            "ref": "rdma_drv_qp.sv:216-248；QPN 是 Function 内资源身份，qp_sn 用于 WQE/doorbell 匹配。",
        },
        {
            "title": "create_qp②：队列深度如何计算",
            "section": "02 · create_qp",
            "kind": "table",
            "headers": ["参数", "普通 RC/UD", "URC", "实现行为"],
            "rows": [
                ["最小深度", "256", "8", "低于下限时提升到下限"],
                ["最大深度", "32768", "32768", "超过上限直接 INVALID_ARGUMENT"],
                ["最终深度", "2 的幂", "2 的幂", "1 << $clog2(requested)"],
                ["SQ/RQ backing", "depth × 64B WQE/RQE", "同样按 depth 分配", "kbuf 按页/大页策略申请"],
                ["环状态", "head/tail/polarity", "head/tail/polarity", "QP 软件对象和 device runtime 各持一份"],
            ],
            "note": "round_depth() 只计算深度；真正 DMA backing 在 alloc_buffers() 中申请，失败由上层统一回滚。",
        },
        {
            "title": "create_qp③：SQ/RQ backing 分配",
            "section": "02 · create_qp",
            "kind": "flow",
            "nodes": [("round_depth", BLUE), ("sq_kbuf.alloc", TEAL), ("rq_kbuf.alloc\n无 SRQ 时", GREEN), ("初始化 head/tail\npolarity", ORANGE), ("写入 QPC\nSQ/RQ PBA", PURPLE)],
            "note": "SQ 一定由 QP 自己拥有；没有 SRQ 时 RQ 由 QP 拥有，有 SRQ 时 QPC_RQ_PBA 指向 SRQ backing。",
        },
        {
            "title": "create_qp④：SGB 为什么存在，如何分配",
            "section": "02 · create_qp",
            "kind": "detail",
            "steps": [
                ("触发条件", "UD 一律启用 SGB；RC/URC 在 max_send_sge 或 max_recv_sge > 2 时启用。", BLUE),
                ("页大小", "每页 4096B、4096B 对齐；一个 SGB page 切成 8 个 512B slot。", TEAL),
                ("页数", "SQ：sq_depth / 8；RQ：rq_depth / 8（无 SRQ 时）。", GREEN),
                ("槽地址", "page[idx/8].iova + (idx%8)×512；写入 WQE 的 SGB_PA 为地址 >> 9。", ORANGE),
                ("用途", "存放超过 WQE 内嵌区域的 SGE 描述符或 inline 数据，并参与 WQE 签名。", PURPLE),
            ],
            "code": "for i < sq_depth / 8:\n  alloc_dma(4096, align=4096, sq_sgb[i])\n\nsgb_page = sq_sgb[idx / 8]\nsgb_pa   = page.iova + (idx % 8) * 512",
            "ref": "rdma_drv_qp.sv:391-425、sgb_addr()；rdma_drv_wr.sv:268-303。",
        },
        {
            "title": "SGB 的内存布局：一个页如何服务 8 个 WQE",
            "section": "02 · create_qp",
            "kind": "sgb",
            "note": "SGB 不替代 SQ/RQ 环；它是 WQE/RQE 的扩展数据区，环槽仍位于 sq_kbuf/rq_kbuf。",
        },
        {
            "title": "create_qp⑤：RC / UD / URC side buffer",
            "section": "02 · create_qp",
            "kind": "table",
            "headers": ["QP 类型", "side_bufs 数量/顺序", "QPC 使用字段", "用途"],
            "rows": [
                ["UD", "1：UAQ", "UAQ_PBA / UAQ_SIZE", "异常/异步队列"],
                ["RC", "4：UAQ、ORQ、EIRQ、EIRQ_EXTRA", "ORQ_PBA、EIRQ_PBA、EIRQ_PBA_EXTRA", "读请求、异常/重试与异步状态"],
                ["URC", "4：UAQ、RSQ、RDSQ、DSQ；DSQ 为 8KiB", "RSQ/RDSQ/DSQ PBA 与 fetch/PSN 字段", "URC 请求、数据和重排状态"],
            ],
            "note": "RC 的 ORQ_PBA 与 URC 的 RSQ_PBA 共用 QPC 重叠区域；service type 决定设备按哪套语义解释。",
        },
        {
            "title": "create_qp⑥：HMC QPC slot 与 shadow",
            "section": "02 · create_qp",
            "kind": "two",
            "left_title": "HMC 定位",
            "left": [
                "dev.hmc[HMC_QPC].locate(qpn, ctx_page, ctx_offset)。",
                "ctx_page/ctx_offset 是该 QPN 对应的 QPC 物理存储位置。",
                "先写 512B 全零，避免旧 context 残留。",
                "QPC shadow 位于 context 页内 +504 附近。",
            ],
            "right_title": "shadow 的运行时作用",
            "right": [
                "QPC+504：SQ 的 HW_DROP_DB_CNT。",
                "QPC+510：RQ 的 PI|wrap。",
                "driver 用 shadow 判断是否能再次敲 doorbell。",
                "device 用 shadow 发布消费/处理进度。",
            ],
            "note": "QPC 镜像不仅是静态配置，也是 driver/dev 之间的运行时协作内存。",
        },
        {
            "title": "create_qp⑦：fill_qpc 写入哪些公共字段",
            "section": "02 · create_qp",
            "kind": "table",
            "headers": ["字段组", "典型字段", "来源/计算", "写入目的"],
            "rows": [
                ["身份", "HOST_ID / VF_ID / QPN / QP_SN", "dev.cfg、分配器、qp_sn 表", "Function 隔离与请求归属"],
                ["基础", "PKEY / ICOS / endian / fence", "驱动固定值或配置", "协议和 DMA 访问约束"],
                ["状态", "QP_ST=INIT / PMTU / RNR_RETRY", "qpc_state、MTU 编码、默认阈值", "设备初始准入与分片"],
                ["权限/关联", "PD_IDX / SRFQ / SQ_CQN / RQ_CQN", "PD/CQ/SRQ handle 映射", "完成和内存权限路径"],
                ["地址", "SHADOW_PBA / SQ_PBA / RQ_PBA", "ctx、kbuf、SRQ 的 IOVA >> 对齐位", "设备 DMA 读取队列和 shadow"],
                ["网络", "DSCP / HOPLIMIT / UDP_SPORT", "默认/随机源端口", "RoCE 外层发送属性"],
            ],
            "note": "QPC 地址字段保存的是硬件可用的对齐后 PBA，不是 SystemVerilog 对象句柄。",
        },
        {
            "title": "create_qp⑧：RC、UD、URC 的 QPC 初始差异",
            "section": "02 · create_qp",
            "kind": "three",
            "cards": [
                ("RC", ["SERVICE_TYPE=RC", "ORQ / EIRQ / EIRQ_EXTRA", "FC_EN=1、ECN=2", "RQ 可指向私有 RQ 或 SRQ"], BLUE),
                ("UD", ["SERVICE_TYPE=UD(3)", "只分配 UAQ", "QKEY 在 INIT 写入", "报文接收校验 QKEY"], TEAL),
                ("URC", ["SERVICE_TYPE=URC(6)", "RSQ / RDSQ / DSQ", "起始 RBSN/RPSN=0x1000", "frag CQ + URC threshold"], PURPLE),
            ],
            "note": "URC 仍复用 RC 的 QP 生命周期，但 QPC 的运行时队列和异常完成路径不同。",
        },
        {
            "title": "create_qp⑨：QPC_CREATE 与失败回滚",
            "section": "02 · create_qp",
            "kind": "detail",
            "steps": [
                ("写 context", "fill_qpc() 后，必要时设置 URC CQC flag，再把 512B QPC 写入 cmdq buffer。", BLUE),
                ("签名提交", "QPC_CREATE 使用 signed CMQ；SQE 携带 QPC buffer 地址，签名覆盖 QPC 镜像。", TEAL),
                ("设备建表", "dev_cmq 保存 QPC 原始字节，dev_nic 后续通过 QPN 查询它。", GREEN),
                ("成功发布", "URC 设置运行时 frag 信息，初始化 wr_id/ring_head 数组，写 dev.qp_table[qpn]。", ORANGE),
                ("失败回滚", "free_buffers → drop_frags(URC) → free QPN；不发布半成品 QP。", RED),
            ],
            "code": "fill_qpc(dev);\nif (urc) set_cqc_urc(...);\nhw_qpc_cmd(QPC_CREATE, full=1);\n\nif (!status.ok()) {\n  free_buffers(dev); drop_frags(dev);\n  dev.qp_ids.free(qpn);\n}",
            "ref": "rdma_drv_qp.sv:260-303；QPC_CREATE 失败不能留下 QPN、DMA 或 context 泄漏。",
        },
        {
            "title": "QPC 状态字段：软件状态与硬件编码不是一一对应",
            "section": "03 · 状态与 QPC",
            "kind": "table",
            "headers": ["软件状态", "QP_ST", "设备行为", "当前实现注意点"],
            "rows": [
                ["RESET", "无独立编码；映射 4", "不接收、不发送；实际复用走 destroy/recreate", "QPC context 删除后不存在"],
                ["INIT", "1", "不取 SQE；入站丢弃", "写 QKEY 或 access"],
                ["RTR", "2", "可接收；不取新的 SQE", "初始化 expected_psn"],
                ["RTS", "3", "正常 drain SQ、处理请求", "初始化 send_psn"],
                ["SQD/SQE", "5", "SQ 暂停；SQD 允许入站", "SQE 未独立建模"],
                ["ERR", "4", "flush SQ；入站静默丢弃", "终止当前 protocol epoch"],
            ],
            "note": "QPC 不存在时设备查询可返回 0；这个 0 不是当前 driver 的有效 RESET 编码。",
        },
        {
            "title": "状态迁移①：RESET → INIT",
            "section": "03 · 状态与 QPC",
            "kind": "detail",
            "steps": [
                ("控制入口", "rdma_ctrl_agent::modify() 构造 M_STATE；连接流程通常对两端依次执行。", BLUE),
                ("UD 分支", "追加 M_QKEY，把 qp.qkey 写入 QPC_UD_QKEY_H/L。", TEAL),
                ("RC/URC 分支", "追加 M_ACCESS，把远端读/写/原子权限写入 QPC_QP_ACCESS_FLAG。", GREEN),
                ("CMQ", "INIT 只更新 QPC 状态/属性，不需要 INIT→RTR 那样的完整签名修改。", ORANGE),
                ("准入结果", "软件状态变为 INIT，但设备仍不接受业务报文。", RED),
            ],
            "ref": "rdma_ctrl_agent.sv:230-240；rdma_drv_qp.sv:647-664。",
        },
        {
            "title": "状态迁移②：INIT → RTR",
            "section": "03 · 状态与 QPC",
            "kind": "table",
            "headers": ["写入项", "QPC/属性", "来源", "设备运行时变化"],
            "rows": [
                ["对端身份", "DST_QPN", "peer.id", "确定接收/响应对象"],
                ["接收 PSN", "EPSN_REQ / EIRQ_PSN_MAX", "rq_psn", "qpc_written 初始化 expected_psn"],
                ["路径", "PMTU / DMAC / dest_ip", "qp.mtu / peer.mac / AV", "决定分片和外层投影"],
                ["RNR", "LOCAL_RNR_CODE", "env.cfg.min_rnr", "无 RQE 时回 RNR 或等待"],
                ["状态", "QP_ST=2", "qpc_state(RTR)", "接收准入打开，发送仍未启动"],
            ],
            "note": "INIT→RTR 是完整 QPC 修改（full=1），因为远端路径和接收运行态同时建立。",
        },
        {
            "title": "状态迁移③：RTR → RTS",
            "section": "03 · 状态与 QPC",
            "kind": "table",
            "headers": ["写入项", "QPC 字段", "作用", "设备结果"],
            "rows": [
                ["发送 PSN", "CUR_SQ_PSN / LAST_READ_PSN / RETRY_PSN", "定义首个发送序号和重传边界", "初始化 send_psn"],
                ["超时", "RTO_CODE", "响应超时指数映射为硬件编码", "控制请求重试触发"],
                ["重试", "PSN_RETRY_TH / RNR_RETRY_TH", "序列错误与 RNR 的最大重试", "耗尽后 CQE/ERR"],
                ["状态", "QP_ST=3", "RTS", "drain_sq 允许读取新 SQE"],
            ],
            "note": "RTR→RTS 同样是 full QPC modify；之后才是可发送状态。",
        },
        {
            "title": "RTS 正常运行：一次 SEND 的最短路径",
            "section": "04 · SQ 数据面",
            "kind": "flow",
            "nodes": [("post_send", BLUE), ("写 WQE / SGB", TEAL), ("更新 head", GREEN), ("SQ doorbell", ORANGE), ("dev drain_sq", PURPLE), ("encode / wire", RED)],
            "note": "post_send 只负责构造队列项；协议分段、PSN、ACK/NAK 和 CQE 由 device NIC 数据路径完成。",
        },
        {
            "title": "post_send①：状态、队列满和 SGE 检查",
            "section": "04 · SQ 数据面",
            "kind": "detail",
            "steps": [
                ("状态门控", "RESET/INIT/RTR 直接返回 INVALID_STATE；RTS/SQD/ERR 可进入后续分支。", RED),
                ("队列满", "sq_head - sq_tail >= sq_depth 返回 QUEUE_FULL。", ORANGE),
                ("统计", "遍历非零 SGE，计算 sge_num 和 payload 总长度。", BLUE),
                ("能力", "payload ≤ 0x8000_0000 且 sge_num ≤ max_send_sge。", TEAL),
                ("inline", "inline_data 且非 atomic 时，检查 payload 与 max_inline。", GREEN),
            ],
            "code": "if (state inside {RESET, INIT, RTR}) reject;\nif (sq_head - sq_tail >= depth) QUEUE_FULL;\nforeach (wr.sges[i])\n  if (length != 0) { sge_num++; payload += length; }",
            "ref": "rdma_drv_wr.sv:210-258。",
        },
        {
            "title": "post_send②：inline、WQE 内嵌和 SGB 选择",
            "kind": "table",
            "section": "04 · SQ 数据面",
            "headers": ["条件", "数据去向", "WQE 标记", "典型场景"],
            "rows": [
                ["inline 且小于内嵌上限", "写入 WQE payload 区", "INLINE_LOCAL_QPC_RD=1", "短 SEND / 小 WRITE"],
                ["RC 非 atomic，SGE > 2", "写 SQ SGB slot", "SGB_PA + SIGN_EN", "多 SGE 描述符"],
                ["UD", "使用 SQ SGB（即使 SGE 较少）", "UD 固定扩展路径", "UD SEND/GRH/目的字段"],
                ["atomic", "原子 VA/key/操作数直接写 WQE", "不走 inline 数据", "CAS / FAA"],
            ],
            "note": "SGB slot 的选择与 create 阶段的 page[idx/8]、offset[idx%8] 完全一致。",
        },
        {
            "title": "post_send③：WQE 头、业务字段和签名",
            "section": "04 · SQ 数据面",
            "kind": "two",
            "left_title": "WQE 头部",
            "left": [
                "QPN、QP_SN、opcode、index、wrap、valid。",
                "RC 追加 ICOS；CE 根据 signaled/sig_all 决定。",
                "SE 只对 solicited 的 SEND/WRITE_WITH_IMM 等生效。",
                "URC READ+SGB 额外写 total packet number。",
            ],
            "right_title": "业务字段",
            "right": [
                "RC SEND/WRITE/READ：长度、SGE、remote VA/rkey、imm。",
                "RC atomic：compare/swap 或 add、local/remote VA/key。",
                "UD：dest IP、hoplimit、dest QPN、QKEY、PD、DMAC。",
                "签名：头 + WQE 余部 + 有效 SGB 做逐字节 XOR 反码。",
            ],
            "note": "写 WQE 成功后才推进 sq_head；写失败不会发布半条队列项。",
        },
        {
            "title": "post_send④：shadow 与 SQ doorbell",
            "section": "04 · SQ 数据面",
            "kind": "detail",
            "steps": [
                ("写环槽", "sq_kbuf.write(idx × 64B, wqe)，保存 sq_wr_id[idx] 和 sq_ring_head[idx]。", BLUE),
                ("推进软件", "sq_head++；idx=old_head % sq_depth；idx=0 时翻转 sq_polarity。", TEAL),
                ("读 shadow", "读取 QPC+504 的 HW_DROP_DB_CNT[54:48]。", GREEN),
                ("门铃节流", "(hw_drop - sw_ring_db_cnt) 的 bit6 表示上一门铃是否仍在处理。", ORANGE),
                ("敲门铃", "可发送时写 RDMA_DB_SQ_OFFSET，携带 WQE header。", PURPLE),
            ],
            "note": "shadow 是 driver/dev 的流控点；不是每次 post_send 都一定产生一次 MMIO doorbell。",
        },
        {
            "title": "post_recv：RQE、RQ SGB 与 PI/wrap",
            "section": "05 · RQ 数据面",
            "kind": "detail",
            "steps": [
                ("检查", "SGE 数不超过 max_recv_sge；rq_head-rq_tail 不得等于 rq_depth。", BLUE),
                ("描述符", "SGE ≤ 2 写入 RQE byte 32 起；更多 SGE 写入 RQ SGB slot。", TEAL),
                ("头部", "QPN、QP_SN、RQE opcode、index、wrap、valid、SGE_NUM、payload_len。", GREEN),
                ("签名", "使用 SGB 时写 SIGN_EN 并对头/WQE/SGB 计算签名。", ORANGE),
                ("发布", "写 rq_kbuf，保存 wr_id，rq_head++，更新 QPC+510 的 PI|wrap。", PURPLE),
                ("通知", "写 RQ doorbell：QPN、ICOS、PI、wrap。", RED),
            ],
            "ref": "rdma_drv_wr.sv:427-508；post_recv 不负责判断网络状态，设备接收入口负责 RTR/RTS/SQD 准入。",
        },
        {
            "title": "设备端 drain_sq：什么时候真正消费 SQE",
            "section": "06 · device NIC",
            "kind": "detail",
            "steps": [
                ("唤醒", "SQ doorbell 按 QPN 将任务送入 sq_kicks；设备查找 QPC/runtime。", BLUE),
                ("取槽", "按 rt.sq_ci 计算 SQ slot，DMA 读取 64B WQE。", TEAL),
                ("valid", "检查 WQE polarity/valid 与设备消费圈一致。", GREEN),
                ("状态门控", "只有 QPC_QP_ST==RTS 才 process_sqe；SQD/SQE 留在环上。", ORANGE),
                ("ERR", "非 URC 的 ERR 会为未完成 SQ WQE 生成 SQ_FLUSH_ERR CQE。", RED),
                ("完成", "处理后 rt.sq_ci++，最后把已见 doorbell 数写回 shadow。", PURPLE),
            ],
            "ref": "rdma_dev_nic.sv:901-940。",
        },
        {
            "title": "设备端 handle_request：报文如何被 QPC 准入",
            "section": "06 · device NIC",
            "kind": "flow",
            "nodes": [("收到 frame", BLUE), ("按 QPN 查 QPC", TEAL), ("状态准入", GREEN), ("RC/UD/URC", ORANGE), ("PSN/QKEY/MR", PURPLE), ("写内存/CQE", RED)],
            "note": "RESET/INIT/ERR 丢包；RTR/RTS/SQD 进入协议检查。UD 先校验 QKEY，RC/URC 先检查 PSN 和分段。",
        },
        {
            "title": "RC 报文处理：QPC 字段如何参与可靠传输",
            "section": "07 · RC / UD / URC",
            "kind": "table",
            "headers": ["QPC 字段", "报文/运行时作用", "异常结果"],
            "rows": [
                ["EPSN_REQ / expected_psn", "校验入站 BTH.PSN，驱动接收序列", "sequence NAK 或不推进"],
                ["CUR_SQ_PSN / send_psn", "构造出站 BTH.PSN，跨分段递增", "重试从 ACK/NAK 指定位置恢复"],
                ["RTO_CODE", "等待 ACK/READ/ATOMIC 响应的超时", "超时重试，耗尽生成错误完成"],
                ["PSN_RETRY_TH", "序列 NAK/RTO 重试预算", "耗尽 0x16/0x18 并进入 ERR"],
                ["LOCAL_RNR_CODE / RNR_RETRY_TH", "RQ 无可用接收 WQE 时的等待和重试", "耗尽 0xB7"],
                ["QP_ACCESS_FLAG / MR key", "WRITE/READ/ATOMIC 远端访问权限", "remote access NAK"],
            ],
            "note": "QPC 是 transport 状态的权威来源；netpacket 只携带 wire 字段，不负责改变 retry/PSN 运行态。",
        },
        {
            "title": "UD 与 URC：同一生命周期，不同的资源和协议",
            "section": "07 · RC / UD / URC",
            "kind": "three",
            "cards": [
                ("UD", ["INIT 写 QKEY", "RTR/RTS 主要是启用 QP", "入站校验 DETH.QKEY", "无 RC ACK/重传"], TEAL),
                ("RC", ["ORQ/EIRQ/UAQ", "PSN/ACK/NAK", "READ/ATOMIC", "可靠完成"], BLUE),
                ("URC", ["RSQ/RDSQ/DSQ", "frag CQ", "URC RBSN/RPSN", "异常可 CEQE/AEQE"], PURPLE),
            ],
            "note": "URC 的 service type=6；RC/UD/URC 的 QPC 重叠字段必须按 service type 解释，不能只看 bit 名。",
        },
        {
            "title": "RTS → SQD：安全暂停发送",
            "section": "08 · 暂停与错误",
            "kind": "flow",
            "nodes": [("QPC_MODIFY\nQP_ST=5", BLUE), ("RTS2SQD\ndoorbell", TEAL), ("drain 在途 WQE", GREEN), ("AEQE\n0x2E DONE", ORANGE), ("保持 SQD", PURPLE)],
            "note": "驱动等待对应 QPN 的 RTS2SQD_DONE；其它 AEQ 事件放回 backlog，不能被等待逻辑吞掉。",
        },
        {
            "title": "SQD → RTS：恢复发送与状态不匹配",
            "section": "08 · 暂停与错误",
            "kind": "table",
            "headers": ["操作", "前置 QPC 状态", "设备动作", "错误码"],
            "rows": [
                ["SQD2RTS doorbell", "QPC 已先修改为 RTS", "重新投递 sq_kicks，恢复 drain_sq", "成功"],
                ["RTS2SQD doorbell", "QPC 不是 SQD", "不执行 drain，写 AEQE", "0x2C"],
                ["SQD2RTS doorbell", "QPC 不是 RTS", "不恢复，写 AEQE", "0x2F"],
                ["SQD 中 post_send", "软件允许入队", "设备暂不消费新 SQE", "恢复 RTS 后继续"],
            ],
            "note": "SQD 是可恢复的发送暂停；不要把它当作 ERR 或 destroy。",
        },
        {
            "title": "ERR：主动错误、被动错误与 flush",
            "section": "08 · 暂停与错误",
            "kind": "two",
            "left_title": "进入 ERR 的来源",
            "left": [
                "软件 modify_qp(state=ERR)。",
                "RC/URC 致命 NAK。",
                "重试次数耗尽或响应超时。",
                "数据面协议/访问错误。",
            ],
            "right_title": "进入 ERR 的可观察结果",
            "right": [
                "清理当前协议 epoch 与分段上下文。",
                "写 QPC_QP_ST=4，敲 QP_FLUSH。",
                "未完成 SQ WQE 产生 flush CQE。",
                "入站报文 state_drops 增加且不回 ACK。",
            ],
            "note": "错误后的恢复不是继续使用旧 QPC 运行态；通常应销毁、释放、重建或按新的 RTR epoch 恢复。",
        },
        {
            "title": "CQE / poll_cq：业务完成如何回到 driver",
            "section": "09 · 完成与回收",
            "kind": "detail",
            "steps": [
                ("设备发布", "dev_nic 写 32B CQE：QPN、WQE index、SQ/RQ 方向、ecode、长度、imm。", BLUE),
                ("driver 读取", "poll_cq 按 polarity 读取 CQE；未知 QPN 返回 INVALID_STATE。", TEAL),
                ("回查 WR", "以 CQE 的 WQE_INDEX 回查 sq_wr_id/rq_wr_id，更新 sq_tail/rq_tail。", GREEN),
                ("错误映射", "0x08/0x8F→FLUSH；0xB9+syndrome→remote invalid/access/op。", ORANGE),
                ("推进 CI", "消费 CQE 后更新 CQ tail/polarity，并写 CQC shadow CI。", PURPLE),
            ],
            "ref": "rdma_drv_wr.sv:500+；完成状态是“设备 CQE → driver WC”而不是直接由 packet checker 生成。",
        },
        {
            "title": "destroy：从 ERR 到资源完全释放",
            "section": "09 · 完成与回收",
            "kind": "flow",
            "nodes": [("to ERR", RED), ("OCC_FLUSH\nEIRQE/ORQE/UAQE", ORANGE), ("QPC_DELETE", PURPLE), ("clean CQ/frag", BLUE), ("free backing", TEAL), ("free QPN\n删 qp_table", GREEN)],
            "note": "destroy 的顺序保证在删除 QPC 前，设备已收到 flush 语义；失败时不会盲目释放仍被硬件引用的资源。",
        },
        {
            "title": "端到端时序：从 QP 创建到报文发送",
            "section": "10 · 端到端串讲",
            "kind": "timeline",
            "note": "真实 DUT 时，模型 TX frame 经 rdma_dut_link endpoint 出站；DUT 入站 frame 解码后才进入 checker/观察路径。",
        },
        {
            "title": "调试时应该观察哪些对象",
            "section": "11 · 调试与检查",
            "kind": "table",
            "headers": ["阶段", "首要观察点", "异常定位线索"],
            "rows": [
                ["create_qp", "qpn、qp_sn、sq_depth/rq_depth、side_bufs", "资源不足、深度取整、回滚是否完整"],
                ["QPC_CREATE", "QPC 512B、QPC_ST、SQ/RQ PBA、shadow", "签名、对齐、service type、重叠字段"],
                ["modify", "attr.mask、full/partial、QPC_ST", "非法迁移或字段未写入"],
                ["post_send", "sq_head/tail、WQE valid/wrap、SGB slot", "QUEUE_FULL、签名、门铃节流"],
                ["device", "state_drops、qkey_drops、PSN/NAK、runtime", "状态准入、QPC 读取、协议 epoch"],
                ["completion", "CQE ecode、WQE index、WC 状态", "flush、远端错误、CQ shadow"],
            ],
            "note": "建议先查 QPC image，再查 doorbell/WQE，最后查 frame；不要从 wire 反推所有 QPC 内部状态。",
        },
        {
            "title": "当前实现边界：哪些已经贯通，哪些仍需补齐",
            "section": "12 · 边界与路线",
            "kind": "two",
            "left_title": "已经具备",
            "left": [
                "driver-shaped create/modify/destroy 与设备 QPC context。",
                "RC/UD/URC 的主要 SQ/RQ/完成路径。",
                "QPC snapshot、netpacket 一致性和 DUT link 抽象。",
                "QPC 字段矩阵和重叠区域文档。",
            ],
            "right_title": "仍需补齐",
            "right": [
                "QPC 512B 全字段逐 bit golden 闭环。",
                "IPv6、完整 VLAN/tunnel/FWD 和全部 wire opcode。",
                "真实 TAP/VPI/VIP/DUT endpoint。",
                "SD/VLD/PBA 组合穷举与最新 VCS 53 回归。",
            ],
            "note": "当前 PPT 解释的是模型真实已实现路径；未实现项会明确标注，不把抽象 endpoint 当成真实 DUT。",
        },
        {
            "title": "代码索引：讲解时从哪里跳转",
            "section": "13 · 代码索引",
            "kind": "table",
            "headers": ["主题", "文件", "入口/观察函数"],
            "rows": [
                ["QP 状态/资源", "src/drv/rdma_drv_qp.sv", "create_qp / modify / transition_ok / destroy"],
                ["WQE/RQE", "src/drv/rdma_drv_wr.sv", "post_send / post_recv / poll_cq / notify_sq_db"],
                ["CMQ/QPC 存储", "src/dev/rdma_dev_cmq.sv", "execute_qp / qp_state / qpc_written"],
                ["NIC 数据面", "src/dev/rdma_dev_nic.sv", "drain_sq / handle_request / enter_error"],
                ["控制流程", "src/tb/rdma_ctrl_agent.sv", "connect_pair / modify"],
                ["wire/DUT", "src/adapters/net_packet、src/tb/rdma_dut_link.sv", "encode/decode / endpoint"],
                ["字段矩阵", "docs/rdma_qpc_field_matrix.xlsx", "逐 qword/bit/RC-UD-URC 重叠说明"],
            ],
            "note": "建议按本 PPT 顺序打开文件：先 drv_qp，再 drv_wr，再 dev_cmq/dev_nic，最后看 codec/link。",
        },
        {
            "title": "一句话总结：QPC 是资源、状态和数据面的共同契约",
            "section": "14 · 总结",
            "kind": "summary",
            "note": "QPC 不是孤立的 512B 表，而是 driver 分配的资源身份、QP 状态机、队列 backing、协议运行态和设备 DMA 的交汇点。",
        },
    ])
    return slides


def render_slide(document, page, spec: dict, number: int) -> None:
    # 功能：按 spec 类型渲染一页普通内容页，组合标题、表格、流程图、代码块和说明卡片。
    # 输入/输出及副作用：document/page/spec/number 为输入；向 page 添加全部图形，不返回值。
    # 失败/边界：未知 kind 直接抛出 ValueError；各类布局使用固定坐标，内容必须遵守 make_slides 的长度约束。
    add_title(document, page, spec["title"], spec["section"], number)
    kind = spec["kind"]
    if kind == "bullets":
        y = 2_050
        for card in spec["body"]:
            x = 1_200
            width = 31_400
            height = 2_350
            add_box(document, page, x, y, width, height, "", card["fill"], card["fill"])
            add_box(document, page, x, y, width, 560, card["title"], card["accent"],
                    card["accent"], 16, WHITE, True, valign=1)
            add_box(document, page, x + 260, y + 720, width - 520, height - 900,
                    card["body"], card["fill"], card["fill"], 16, INK, False)
            y += 2_700
        add_box(document, page, 1_300, 15_900, 31_000, 650, spec["note"], PALE_ORANGE,
                PALE_ORANGE, 13, INK, True)
        return
    if kind == "flow":
        add_flow(document, page, 5_000, spec["nodes"])
        add_box(document, page, 1_250, 2_250, 31_300, 1_500,
                "把每个节点理解成一次“资源/状态/数据所有权变化”，不要只把它当成函数调用顺序。",
                PALE_BLUE, PALE_BLUE, 17, INK, True)
        add_box(document, page, 1_250, 8_100, 31_300, 3_350, spec["note"], PALE_TEAL,
                PALE_TEAL, 17, INK, False)
        return
    if kind == "table":
        add_table(document, page, 1_000, 2_050, 31_900, 1_350, spec["headers"], spec["rows"],
                  NAVY, WHITE, 12, spec.get("widths"))
        add_box(document, page, 1_150, 15_500, 31_600, 1_200, spec["note"], PALE_ORANGE,
                PALE_ORANGE, 14, INK, True)
        return
    if kind == "two":
        add_box(document, page, 1_000, 2_050, 15_250, 550, spec["left_title"], BLUE, BLUE, 17, WHITE, True)
        add_box(document, page, 17_600, 2_050, 15_250, 550, spec["right_title"], TEAL, TEAL, 17, WHITE, True)
        add_bullets(document, page, 1_000, 2_650, 15_250, 8_250, spec["left"], 15, INK, PALE_BLUE, BLUE)
        add_bullets(document, page, 17_600, 2_650, 15_250, 8_250, spec["right"], 15, INK, PALE_TEAL, TEAL)
        add_box(document, page, 1_100, 12_000, 31_500, 2_100, spec["note"], PALE_ORANGE,
                PALE_ORANGE, 16, INK, True)
        return
    if kind == "detail":
        y = 2_000
        for idx, (tag, text, accent) in enumerate(spec["steps"]):
            add_box(document, page, 1_050, y, 1_350, 850, tag, accent, accent, 15, WHITE, True,
                    font=MONO, align=3, valign=1)
            add_box(document, page, 2_650, y, 16_800, 850, text, WHITE, 0xD9E2EC, 14, INK, False)
            y += 1_000
        code = spec.get("code", "")
        reference = spec.get("ref", spec.get("note", ""))
        if code:
            add_code(document, page, 20_000, 2_000, 12_800, 5_200, code, 12)
        else:
            add_box(document, page, 20_000, 2_000, 12_800, 5_200,
                    "本页以状态/字段动作表为主\n\n关键代码入口见右下角引用。",
                    PALE_BLUE, PALE_BLUE, 18, BLUE, True, font=FONT, align=3, valign=1)
        add_box(document, page, 20_000, 7_450, 12_800, 2_250, reference, PALE_TEAL,
                PALE_TEAL, 13, INK, False)
        add_box(document, page, 1_100, 12_100, 31_500, 1_650,
                "讲解重点：先说输入和所有权，再说写入了哪块内存，最后说失败时谁负责回滚。",
                PALE_ORANGE, PALE_ORANGE, 16, INK, True)
        return
    if kind == "three":
        cards = spec["cards"]
        x = 1_000
        for title, lines, fill in cards:
            add_box(document, page, x, 2_400, 10_000, 650, title, fill, fill, 19, WHITE, True,
                    align=3, valign=1)
            add_bullets(document, page, x, 3_050, 10_000, 7_200, lines, 15, INK, WHITE, fill)
            x += 10_900
        add_box(document, page, 1_200, 12_200, 31_200, 1_700, spec["note"], PALE_ORANGE,
                PALE_ORANGE, 16, INK, True)
        return
    if kind == "sgb":
        add_box(document, page, 1_000, 2_250, 31_800, 1_000,
                "4 KiB SGB page = 8 × 512 B slot", PALE_BLUE, PALE_BLUE, 20, BLUE, True,
                font=MONO, align=3, valign=1)
        for i in range(8):
            x = 1_100 + (i % 4) * 7_900
            y = 4_000 + (i // 4) * 3_150
            fill = TEAL if i % 2 else BLUE
            add_box(document, page, x, y, 6_900, 2_200,
                    f"slot {i}\npage + {i} × 512B\nSGB_PA = IOVA >> 9", fill, fill,
                    15, WHITE, True, font=MONO, align=3, valign=1)
        add_box(document, page, 1_200, 11_500, 31_200, 1_700, spec["note"], PALE_ORANGE,
                PALE_ORANGE, 16, INK, True)
        return
    if kind == "timeline":
        labels = [
            ("t0\nFunction probe", NAVY), ("t1\nPD/CQ/MR", BLUE), ("t2\nQPN + buffers", TEAL),
            ("t3\nQPC_CREATE", PURPLE), ("t4\nINIT/RTR/RTS", GREEN),
            ("t5\nWQE + DB", ORANGE), ("t6\nframe/CQE", RED),
        ]
        add_flow(document, page, 4_100, labels, x=700, width=32_500, height=1_700,
                 font_size=13)
        add_line(document, page, 2_000, 8_000, 31_000, 8_000, MUTED, 50)
        events = [
            (2_000, "QPC image\nctx_page"), (7_000, "SQ/RQ\nPBA"), (12_000, "QP_ST\nINIT"),
            (17_000, "PSN / AV\nRTR"), (22_000, "doorbell\nRTS"), (27_000, "wire\nACK/CQE"),
        ]
        for x, label in events:
            add_box(document, page, x - 1_100, 8_350, 2_200, 1_350, label, PALE_TEAL,
                    PALE_TEAL, 11, INK, True, font=MONO, align=3, valign=1)
        add_box(document, page, 1_250, 11_200, 31_300, 1_850, spec["note"], PALE_ORANGE,
                PALE_ORANGE, 16, INK, True)
        return
    if kind == "summary":
        add_box(document, page, 2_000, 3_000, 29_900, 4_100,
                "QPC = 资源身份\n       + 生命周期状态\n       + 队列 backing\n       + 协议运行态\n       + 设备 DMA 契约",
                NAVY, NAVY, 20, WHITE, True, font=MONO, align=3, valign=1)
        add_box(document, page, 2_300, 9_400, 29_300, 2_100,
                "讲清楚 QPC，必须把 create、modify、WQE、doorbell、device runtime、报文和 CQE 串成一条链。",
                PALE_TEAL, PALE_TEAL, 19, INK, True, align=3, valign=1)
        add_box(document, page, 1_500, 13_000, 30_800, 1_300, spec["note"], PALE_ORANGE,
                PALE_ORANGE, 16, INK, True)
        return
    raise ValueError(f"unknown slide kind: {kind}")


def build_deck(output: Path) -> int:
    # 功能：创建 Impress 文档，渲染全部页面，并将结果导出为 PowerPoint 2007+ PPTX。
    # 输入/输出及副作用：output 为目标文件路径；写入 PPTX，返回生成页数；会启动并关闭临时 LibreOffice。
    # 失败/边界：输出目录不存在、UNO 导出失败或页面渲染异常时抛出异常；不会删除既有输出，除非导出成功覆盖。
    output.parent.mkdir(parents=True, exist_ok=True)
    port = 20_000 + (os.getpid() % 10_000)
    process, context, desktop, profile_dir = connect_office(port)
    document = None
    try:
        document = desktop.loadComponentFromURL("private:factory/simpress", "_blank", 0, ())
        pages = document.getDrawPages()
        specs = make_slides()
        for index, spec in enumerate(specs):
            page = pages.getByIndex(0) if index == 0 else pages.insertNewByIndex(pages.getCount())
            set_page_style(page)
            if spec["kind"] == "cover":
                add_cover(document, page)
            else:
                render_slide(document, page, spec, index)
        document.storeAsURL(
            uno.systemPathToFileUrl(str(output.resolve())),
            (prop("FilterName", "Impress MS PowerPoint 2007 XML"), prop("Overwrite", True)),
        )
        return len(specs)
    finally:
        if document is not None:
            try:
                document.close(True)
            except Exception:
                pass
        try:
            process.terminate()
            process.wait(timeout=10)
        except Exception:
            process.kill()
        shutil.rmtree(profile_dir, ignore_errors=True)


def main() -> int:
    # 功能：解析命令行参数并生成 QPC PPT 手册，向 stdout 输出页数和文件路径。
    # 输入/输出及副作用：--output 是输出 PPTX；成功返回 0，失败由异常向上暴露并返回非零。
    # 失败/边界：缺少输出路径或 LibreOffice 不可用时命令失败，不生成不完整的成功提示。
    parser = argparse.ArgumentParser(description="Generate the RDMA QPC lifecycle PPT manual")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    count = build_deck(args.output)
    print(f"generated {count} slides: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""
目录：tools/generate_rdma_qpc_field_matrix.py。
职责：读取 rdma_defs.svh 的 QPC 字段定义，生成可筛选的 Excel 字段矩阵，明确 RC/UD/URC
复用字段、bit 范围、生命周期、配置所有权和当前实现差距。
依赖：Python 标准库；不依赖 openpyxl/xlsxwriter，直接生成最小 XLSX 容器。
所有权与生命周期：脚本只生成 docs/rdma_qpc_field_matrix.xlsx 与同名 CSV；不修改源码。
"""

from __future__ import annotations

import re
import zipfile
from collections import defaultdict
from pathlib import Path
from xml.etree import ElementTree as ET


FIELD_RE = re.compile(
    r"`RDMA_FIELD\((RDMA_QPC2?_[A-Za-z0-9_]+),\s*(\d+),\s*(\d+),\s*(\d+)\)"
)


def field_text(name: str) -> tuple[str, str, str, str]:
    """功能：根据 QPC 字段名推导服务类型、所有权、使用阶段和中文描述。
    输入/输出及副作用：输入宏字段名；返回四个字符串，不修改解析状态。
    失败/边界：未知字段使用可定位的字段名回退描述，避免矩阵遗漏字段。
    """
    exact = {
        "RDMA_QPC_TVER": ("公共", "硬件/环境", "QPC_CREATE", "QPC 镜像格式版本。"),
        "RDMA_QPC_MIG": ("公共", "测试参数", "QPC_CREATE/MODIFY", "是否允许路径迁移。"),
        "RDMA_QPC_SERVICE_TYPE": ("公共", "测试参数", "QPC_CREATE", "QP 服务类型，决定 RC/UD/URC 字段复用。"),
        "RDMA_QPC_HOST_ID": ("公共", "平台自动", "QPC_CREATE", "所属 Host 标识，由 topology/dpu_common 提供。"),
        "RDMA_QPC_VF_ID": ("公共", "平台自动/负向可配", "QPC_CREATE", "所属 VF 标识；错误 VF 用于权限/地址负向测试。"),
        "RDMA_QPC_ICOS": ("公共", "测试参数", "QPC_CREATE", "内部服务或调度类别。"),
        "RDMA_QPC_QPN": ("公共", "环境自动", "QPC_CREATE", "本地 QP 编号；通常由设备/资源 resolver 分配。"),
        "RDMA_QPC_STAT_IDX": ("公共", "环境自动", "QPC_CREATE", "统计索引，通常与 QP 资源自动关联。"),
        "RDMA_QPC_UD_QKEY_H": ("UD", "测试参数", "QPC_CREATE/MODIFY", "UD Q_Key 高 8 位；与 RC/URC 的同位段复用。"),
        "RDMA_QPC_UD_QKEY_L": ("UD", "测试参数", "QPC_CREATE/MODIFY", "UD Q_Key 低 24 位；与 RC/URC 的同位段复用。"),
        "RDMA_QPC_PKEY": ("RC/UD/URC", "测试参数", "QPC_CREATE/MODIFY", "分区键，用于端到端分区/权限匹配。"),
        "RDMA_QPC_SHADOW_PBA": ("公共", "环境自动", "QPC_CREATE", "QP runtime shadow 的物理基址。"),
        "RDMA_QPC_QP_ST": ("公共", "状态机/driver", "QPC_MODIFY", "QP 状态：RESET、INIT、RTR、RTS、SQD、ERR 等。"),
        "RDMA_QPC_PMTU": ("RC/UD/URC", "测试参数", "INIT→RTR", "路径 MTU 编码，影响报文分段。"),
        "RDMA_QPC_QP_SN": ("公共", "环境自动", "QPC_CREATE", "QP sequence 编号，不等同于线上 PSN。"),
        "RDMA_QPC_PD_IDX": ("公共", "资源自动", "QPC_CREATE", "所属 PD 索引；必须与 MR/CQ 关联一致。"),
        "RDMA_QPC_QP_ACCESS_FLAG": ("RC/UD/URC", "测试参数", "QPC_CREATE/MODIFY", "本地/远端读写及 atomic 访问权限。"),
        "RDMA_QPC_PSN_RETRY_TH": ("RC/URC", "测试参数", "RTR→RTS", "PSN 错误或响应缺失时的重试次数。"),
        "RDMA_QPC_RTO_CODE": ("RC/URC", "测试参数", "RTR→RTS", "响应超时编码；0 通常表示不启用超时。"),
        "RDMA_QPC_VLAN": ("路径", "测试参数", "QPC_CREATE/MODIFY", "VLAN 能力开关；开启后应与 VLAN wire 配置一致。"),
        "RDMA_QPC_IPV6": ("路径", "测试参数", "QPC_CREATE/MODIFY", "IPv6 路径能力开关。"),
        "RDMA_QPC_TUNNEL": ("路径", "测试参数", "QPC_CREATE/MODIFY", "RDMA 隧道能力开关。"),
        "RDMA_QPC_LAG": ("路径", "测试参数", "QPC_CREATE/MODIFY", "是否经 LAG/聚合端口转发。"),
        "RDMA_QPC_FWD": ("路径", "测试参数", "QPC_CREATE/MODIFY", "硬件转发方式；保留编码应由 resolver 拒绝。"),
        "RDMA_QPC_DST_VPORT_ID": ("路径", "测试参数", "QPC_CREATE/MODIFY", "目标虚拟端口。"),
        "RDMA_QPC_SRC_ADDR_IDX": ("路径", "资源/测试参数", "QPC_CREATE/MODIFY", "源地址表索引。"),
        "RDMA_QPC_DST_PORT": ("路径", "测试参数", "QPC_CREATE/MODIFY", "目标端口或路径端口编码。"),
        "RDMA_QPC_DST_QPN": ("路径", "建链/resolver", "INIT→RTR", "对端 QPN，必须关联 peer 的 local QPN。"),
        "RDMA_QPC_DMAC": ("路径", "测试参数/resolver", "INIT→RTR", "目标 MAC；link 路由和 wire 外层目的 MAC 的权威来源。"),
        "RDMA_QPC_PRI": ("路径", "测试参数", "QPC_CREATE/MODIFY", "VLAN 优先级 PCP。"),
        "RDMA_QPC_CFI": ("路径", "测试参数", "QPC_CREATE/MODIFY", "VLAN CFI/DEI 位。"),
        "RDMA_QPC_VLAN_ID": ("路径", "测试参数", "QPC_CREATE/MODIFY", "VLAN ID；VLAN 开关开启时参与一致性检查。"),
        "RDMA_QPC_FLOW_LABEL": ("路径", "测试参数", "QPC_CREATE/MODIFY", "IPv6 flow label。"),
        "RDMA_QPC_SRC_VPORT_ID": ("路径", "测试参数", "QPC_CREATE/MODIFY", "源虚拟端口。"),
        "RDMA_QPC_DSCP": ("路径", "测试参数", "QPC_CREATE/MODIFY", "IP DSCP。"),
        "RDMA_QPC_ECN": ("路径", "测试参数", "QPC_CREATE/MODIFY", "IP ECN。"),
        "RDMA_QPC_HOPLIMIT": ("路径", "测试参数", "QPC_CREATE/MODIFY", "IPv6 hop limit。"),
        "RDMA_QPC_CUR_UDP_SPORT": ("路径", "测试参数", "QPC_CREATE/MODIFY", "当前 UDP 源端口。"),
        "RDMA_QPC_RC_TPE_CUR_SQ_PSN": ("RC", "运行时", "数据面", "RC 当前发送 SQ PSN。"),
        "RDMA_QPC_RC_LAST_READ_PSN": ("RC", "运行时", "数据面", "最近一次 RC READ PSN。"),
        "RDMA_QPC_SQ_PBA": ("RC/UD/URC", "环境自动", "QPC_CREATE", "发送队列 backing 物理基址。"),
        "RDMA_QPC_SQ_SIZE": ("RC/UD/URC", "环境自动/测试参数", "QPC_CREATE", "发送队列深度编码。"),
        "RDMA_QPC_SQ_OM": ("RC/UD/URC", "环境自动/测试参数", "QPC_CREATE", "发送队列组织模式。"),
        "RDMA_QPC_SQ_CQN": ("RC/UD/URC", "资源自动", "QPC_CREATE", "发送完成队列编号。"),
        "RDMA_QPC_RQ_PBA": ("RC/UD/URC", "环境自动", "QPC_CREATE", "接收队列 backing 物理基址。"),
        "RDMA_QPC_RQ_SIZE": ("RC/UD/URC", "环境自动/测试参数", "QPC_CREATE", "接收队列深度编码。"),
        "RDMA_QPC_RQ_OM": ("RC/UD/URC", "环境自动/测试参数", "QPC_CREATE", "接收队列组织模式。"),
        "RDMA_QPC_RQ_CQN": ("RC/UD/URC", "资源自动", "QPC_CREATE", "接收完成队列编号。"),
        "RDMA_QPC_RUNTIME_SHADOW": ("公共", "运行时", "数据面/readback", "runtime shadow 中的硬件计数、PI 和 wrap 状态。"),
        "RDMA_QPC_DEST_IP": ("路径", "测试参数/resolver", "INIT→RTR", "目标 IP；当前 codec 主要使用 IPv4，字段可容纳 IPv6。"),
    }
    if name in exact:
        return exact[name]
    if "URC_" in name:
        service, owner, phase = "URC", "环境自动/运行时", "QPC_CREATE/数据面"
    elif "RC_" in name:
        service, owner, phase = "RC", "环境自动/运行时", "QPC_CREATE/数据面"
    elif "ORQ" in name or "EIRQ" in name or "UAQ" in name:
        service, owner, phase = "RC/UD", "环境自动", "QPC_CREATE"
    else:
        service, owner, phase = "公共/复用", "需按服务类型判断", "QPC_CREATE/MODIFY 或数据面"
    short = name.removeprefix("RDMA_QPC_")
    return service, owner, phase, f"字段 {short}；具体语义取决于 service type 和复用布局。"


def parse_fields(defs_path: Path) -> list[dict[str, object]]:
    """功能：按源码出现顺序解析 QPC 宏，并追加 128-bit 目标 IP 与 runtime shadow 行。
    输入/输出及副作用：读取 defs_path；返回字段字典列表，不写源码。
    失败/边界：找不到 QPC 起止标记或宏格式异常时抛出 ValueError，避免生成不完整矩阵。
    """
    lines = defs_path.read_text(encoding="utf-8").splitlines()
    start = next((i for i, line in enumerate(lines) if "QPC logical qwords" in line), None)
    stop = next((i for i, line in enumerate(lines[start + 1:], start + 1)
                 if "固定 QPC runtime shadow" in line), None)
    if start is None or stop is None:
        raise ValueError("cannot find QPC definition section")
    fields: list[dict[str, object]] = []
    for lineno in range(start, stop):
        match = FIELD_RE.search(lines[lineno])
        if not match:
            continue
        name, word_byte, lsb, width = match.groups()
        word_byte_i, lsb_i, width_i = int(word_byte), int(lsb), int(width)
        service, owner, phase, desc = field_text(name)
        fields.append({
            "name": name,
            "word_byte": word_byte_i,
            "byte_range": f"{word_byte_i}-{word_byte_i + 7}",
            "bit_range": f"{lsb_i + width_i - 1}:{lsb_i}",
            "width": width_i,
            "service": service,
            "owner": owner,
            "phase": phase,
            "description": desc,
            "source": f"src/codec/rdma/rdma_defs.svh:{lineno + 1}",
            "lsb": lsb_i,
            "line": lineno,
        })
    fields.append({
        "name": "RDMA_QPC_DEST_IP",
        "word_byte": 80,
        "byte_range": "80-95",
        "bit_range": "127:0",
        "width": 128,
        "service": "路径",
        "owner": "测试参数/resolver",
        "phase": "INIT→RTR",
        "description": field_text("RDMA_QPC_DEST_IP")[3],
        "source": "src/codec/rdma/rdma_defs.svh:396-397",
        "lsb": 0,
        "line": 10**9,
    })
    fields.append({
        "name": "RDMA_QPC_RUNTIME_SHADOW",
        "word_byte": 504,
        "byte_range": "504-511",
        "bit_range": "63:0",
        "width": 64,
        "service": "公共",
        "owner": "运行时/readback",
        "phase": "数据面/readback",
        "description": field_text("RDMA_QPC_RUNTIME_SHADOW")[3],
        "source": "src/codec/rdma/rdma_defs.svh:449-451",
        "lsb": 0,
        "line": 10**9 + 1,
    })
    return sorted(fields, key=lambda row: (int(row["word_byte"]), -int(row["lsb"]), int(row["line"])))


def add_overlap_groups(fields: list[dict[str, object]]) -> list[dict[str, object]]:
    """功能：按逻辑 qword 和 bit 区间计算复用连通分组，并回填重叠说明。
    输入/输出及副作用：修改字段字典中的 overlap_group/overlap_detail；返回同一列表。
    失败/边界：不同 qword 的同名或相邻字段不视为重叠；单字段组的说明为空。
    """
    groups: dict[int, list[int]] = defaultdict(list)
    for idx, field in enumerate(fields):
        groups[int(field["word_byte"])].append(idx)
    for word_byte, indexes in groups.items():
        parent = {idx: idx for idx in indexes}

        def find(item: int) -> int:
            while parent[item] != item:
                parent[item] = parent[parent[item]]
                item = parent[item]
            return item

        def union(left: int, right: int) -> None:
            root_l, root_r = find(left), find(right)
            if root_l != root_r:
                parent[root_r] = root_l

        for pos, left_idx in enumerate(indexes):
            left = fields[left_idx]
            left_lo = int(left["lsb"])
            left_hi = left_lo + int(left["width"]) - 1
            for right_idx in indexes[pos + 1:]:
                right = fields[right_idx]
                right_lo = int(right["lsb"])
                right_hi = right_lo + int(right["width"]) - 1
                if left_lo <= right_hi and right_lo <= left_hi:
                    union(left_idx, right_idx)
        members: dict[int, list[int]] = defaultdict(list)
        for idx in indexes:
            members[find(idx)].append(idx)
        for serial, member_indexes in enumerate(members.values(), start=1):
            if len(member_indexes) < 2:
                continue
            group_id = f"W{word_byte:03d}_O{serial:02d}"
            names = [str(fields[idx]["name"]) for idx in member_indexes]
            detail = "；".join(names)
            semantic = "同一 qword 的 bit 区间复用，必须按 SERVICE_TYPE/QP 类型选择唯一语义。"
            if any("UD_QKEY" in name for name in names) and any("ORQ_PBA" in name for name in names):
                if word_byte == 0:
                    semantic = "部分重叠：UD 的 QKEY[31:24] 使用 qword0[7:0]；RC 的 ORQ_PBA 高段只使用 qword0[3:0]，URC 的 RSQ_PBA 高段同样只使用 qword0[3:0]，qword0[7:4] 不属于这两个 PBA 字段。"
                else:
                    semantic = "部分重叠：UD 的 QKEY[23:0] 使用 qword8[63:40]；RC 的 ORQ_PBA、URC 的 RSQ_PBA 使用 qword8[63:16]，因此 qword8[63:40] 是重叠区，qword8[39:16] 只属于 PBA。"
            elif any("UD_QKEY" in name for name in names) and any("RSQ_PBA" in name for name in names):
                semantic = "UD 与 URC 复用同一 qword 区域：UD 解释为 QKEY，URC 解释为 RSQ_PBA；具体有效 bit 以表中每个字段的 bit 范围为准。"
            elif any("RDSQ_PBA" in name for name in names) and any("EIRQ_PBA" in name for name in names):
                semantic = "URC：该 bit 区间表示 RDSQ_PBA；RC/UD：同一 bit 区间表示 EIRQ_PBA。"
            elif any("ORQ_SIZE" in name for name in names) and any("RSQ_SIZE" in name for name in names):
                semantic = "URC：该 bit 区间表示 RSQ_SIZE；RC：同一 bit 区间表示 ORQ_SIZE。"
            elif any("URC_" in name for name in names) and any("RC_" in name for name in names):
                semantic = "URC 与 RC/UD 的队列或运行字段复用；以 SERVICE_TYPE 决定解释。"
            for idx in member_indexes:
                fields[idx]["overlap_group"] = group_id
                fields[idx]["overlap_detail"] = f"{semantic} 复用字段：{detail}"
    for field in fields:
        field.setdefault("overlap_group", "")
        field.setdefault("overlap_detail", "")
    return fields


def text_cell(row: ET.Element, col: int, value: object, style: str = "2") -> None:
    """功能：向 worksheet row 追加一个可换行的 inline string 单元格。
    输入/输出及副作用：修改 XML row；值统一转义为文本，避免字段名被当作公式。
    失败/边界：None 转为空串；超长文本由 Excel 自己处理，不截断语义说明。
    """
    cell = ET.SubElement(row, "c", {"r": f"{column_name(col)}{row.get('r')}", "t": "inlineStr", "s": style})
    inline = ET.SubElement(cell, "is")
    text = ET.SubElement(inline, "t")
    text.text = "" if value is None else str(value)


def column_name(index: int) -> str:
    """功能：把从 1 开始的列序号转换为 Excel 列名。
    输入/输出及副作用：返回纯函数结果，不访问文件或全局状态。
    失败/边界：index 小于 1 时抛出 ValueError；支持超过 Z 的列。
    """
    if index < 1:
        raise ValueError("Excel columns are 1-based")
    result = ""
    while index:
        index, remainder = divmod(index - 1, 26)
        result = chr(65 + remainder) + result
    return result


def worksheet_xml(headers: list[str], rows: list[list[object]], widths: list[int]) -> bytes:
    """功能：生成单个带筛选、冻结首行和换行样式的 worksheet XML。
    输入/输出及副作用：返回 UTF-8 XML 字节，不创建外部文件。
    失败/边界：headers 为空仍生成空表；每行缺列按空文本补齐。
    """
    root = ET.Element("worksheet", {"xmlns": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"})
    views = ET.SubElement(root, "sheetViews")
    view = ET.SubElement(views, "sheetView", {"workbookViewId": "0"})
    ET.SubElement(view, "pane", {"ySplit": "1", "topLeftCell": "A2", "activePane": "bottomLeft", "state": "frozen"})
    ET.SubElement(view, "selection", {"pane": "bottomLeft", "activeCell": "A2", "sqref": "A2"})
    ET.SubElement(root, "sheetFormatPr", {"defaultRowHeight": "30"})
    cols = ET.SubElement(root, "cols")
    for idx, width in enumerate(widths, start=1):
        ET.SubElement(cols, "col", {"min": str(idx), "max": str(idx), "width": str(width), "customWidth": "1"})
    data = ET.SubElement(root, "sheetData")
    all_rows = [headers] + rows
    for row_idx, values in enumerate(all_rows, start=1):
        row = ET.SubElement(data, "row", {"r": str(row_idx)})
        for col_idx in range(1, len(headers) + 1):
            text_cell(row, col_idx, values[col_idx - 1] if col_idx <= len(values) else "", "1" if row_idx == 1 else "2")
    if headers:
        ET.SubElement(root, "autoFilter", {"ref": f"A1:{column_name(len(headers))}{len(all_rows)}"})
    ET.SubElement(root, "pageMargins", {"left": "0.25", "right": "0.25", "top": "0.5", "bottom": "0.5", "header": "0.2", "footer": "0.2"})
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def styles_xml() -> bytes:
    """功能：生成 Excel 表头、普通文本和换行样式。
    输入/输出及副作用：返回样式 XML 字节，不访问运行期资源。
    失败/边界：样式固定为本工具使用的三个 cellXf，避免依赖第三方库。
    """
    return b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <numFmts count="0"/><fonts count="2"><font><sz val="10"/><name val="Arial"/></font><font><b/><sz val="10"/><name val="Arial"/></font></fonts>
  <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="D9EAF7"/><bgColor indexed="64"/></patternFill></fill></fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>'''


def workbook_files(sheets: list[tuple[str, list[str], list[list[object]], list[int]]]) -> dict[str, bytes]:
    """功能：组装 XLSX 所需的 workbook、关系、内容类型和 worksheet 文件。
    输入/输出及副作用：返回归档路径到 XML 字节的映射，不写磁盘。
    失败/边界：至少一个 sheet 时生成稳定的 sheetId 和关系编号；sheet 名由调用者保证唯一。
    """
    content = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
               '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
               '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
               '<Default Extension="xml" ContentType="application/xml"/>',
               '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
               '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>']
    rels = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>',
            '</Relationships>']
    workbook = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
                '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
                '<sheets>']
    workbook_rels = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
                     '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">']
    files: dict[str, bytes] = {}
    for index, (name, headers, rows, widths) in enumerate(sheets, start=1):
        workbook.append(f'<sheet name="{name}" sheetId="{index}" r:id="rId{index}"/>')
        workbook_rels.append(f'<Relationship Id="rId{index}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{index}.xml"/>')
        content.append(f'<Override PartName="/xl/worksheets/sheet{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>')
        files[f"xl/worksheets/sheet{index}.xml"] = worksheet_xml(headers, rows, widths)
    workbook.append('</sheets></workbook>')
    workbook_rels.append('</Relationships>')
    content.append('</Types>')
    files.update({
        "[Content_Types].xml": "".join(content).encode("utf-8"),
        "_rels/.rels": "".join(rels).encode("utf-8"),
        "xl/workbook.xml": "".join(workbook).encode("utf-8"),
        "xl/_rels/workbook.xml.rels": "".join(workbook_rels).encode("utf-8"),
        "xl/styles.xml": styles_xml(),
    })
    return files


def write_outputs(root: Path, fields: list[dict[str, object]]) -> tuple[Path, Path]:
    """功能：根据字段和说明数据生成 XLSX 与 UTF-8 CSV 两份可审查产物。
    输入/输出及副作用：写入 docs/rdma_qpc_field_matrix.xlsx/csv；返回两个绝对路径。
    失败/边界：父目录不存在时创建；已有文件被本次生成结果完整替换。
    """
    from csv import writer

    headers = ["序号", "字段", "字节偏移", "字节范围", "bit范围", "宽度", "生效类型", "配置所有权", "使用阶段", "中文描述", "重叠组", "重叠说明", "源码"]
    table_rows = []
    for idx, field in enumerate(fields, start=1):
        table_rows.append([idx, field["name"], field["word_byte"], field["byte_range"], field["bit_range"], field["width"], field["service"], field["owner"], field["phase"], field["description"], field["overlap_group"], field["overlap_detail"], field["source"]])
    overlap_headers = ["重叠组", "字节/qword", "字段集合", "复用规则", "使用建议"]
    overlap_rows = []
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for field in fields:
        if field["overlap_group"]:
            grouped[str(field["overlap_group"])].append(field)
    for group_id, group_fields in sorted(grouped.items()):
        if len(group_fields) < 2:
            continue
        names = [str(field["name"]) for field in group_fields]
        detail = str(group_fields[0]["overlap_detail"])
        usage = "先读取 SERVICE_TYPE/QP 类型，再只编码该服务有效的字段；禁止把复用字段同时当作多个语义写入。"
        overlap_rows.append([group_id, group_fields[0]["word_byte"], "\n".join(names), detail, usage])
    instruction_headers = ["主题", "说明"]
    instruction_rows = [
        ["镜像大小", "QPC 固定 512B；字段的 WORD_BYTE_OFFSET 是逻辑 qword 的字节偏移，bit 范围按 qword 内 LSB 计算，最终按大端序列化。"],
        ["复用原则", "Byte 0～55 等区域存在 RC/UD/URC 复用；例如 UD_QKEY_H/L 与 RC_ORQ_PBA_H/L、URC_RSQ_PBA_H/L 使用相同 bit 区间，必须由 SERVICE_TYPE 决定解释。"],
        ["QPC 配置顺序", "先创建 PD/CQ/SRQ/MR/HMC/PBL 等资源，再分配 QPN/backing/shadow，生成 QPC_CREATE，随后按 RESET→INIT→RTR→RTS 修改状态。"],
        ["自动字段", "qp_h、local_qpn、CQN、PD/CQ handle、SQ/RQ backing、QPC shadow、PBL/PBLE、AEQ/CEQ/UAQ、HMC PBA 和运行时 PSN 应由 resolver/driver 管理。"],
        ["显式字段", "QP 类型、depth、MTU、PKEY/QKEY、PSN、DST_QPN、DMAC/IP、VLAN/FWD/tunnel、retry/RTO、CQ/EQ 参数和 SD page_size/VLD/VF_ID 可由 profile 传参。"],
        ["netpacket 边界", "netpacket 只描述外层封装和业务内容；QPC 是硬件上下文唯一来源。同名字段默认必须一致，故意不一致只能通过显式 fault override。"],
        ["当前实现差距", "当前 rdma_drv_qp_attr 只开放 QPC 子集；VLAN/FWD/tunnel/IPv6、完整 SD page_size/VLD 和部分 RC/URC 运行字段仍需继续贯通。"],
    ]
    gap_headers = ["范围", "当前状态", "后续动作", "源码/证据"]
    gap_rows = [
        ["QPC 位域", "rdma_defs.svh 已定义完整 512B 位域和复用字段", "profile/resolver 与 CMQ image 逐字段映射", "src/codec/rdma/rdma_defs.svh:334"],
        ["driver attr", "rdma_drv_qp_attr 目前是高层子集", "扩展 mask/attr 或由 resolver 直接生成完整 QPC image", "src/drv/rdma_drv_qp.sv:70"],
        ["QPC path", "DMAC/dest_ip 已有；VLAN/FWD/tunnel 等未完全贯通", "同步 driver、dev、codec、link、checker", "src/dev/rdma_dev_nic.sv"],
        ["HMC/SD", "page size 当前主要固定 4KiB，SD 表含 PBA/VF_ID/VLD", "增加 page_size/VLD/PBA 对齐 knob 与负向组合", "src/codec/rdma/rdma_defs.svh:576; src/drv/rdma_drv_mem.sv"],
        ["runtime shadow", "偏移 504、readback mask 已定义", "只读比较，不允许 profile 覆盖运行时值", "src/codec/rdma/rdma_defs.svh:449"],
    ]
    docs_dir = root / "docs"
    docs_dir.mkdir(parents=True, exist_ok=True)
    csv_path = docs_dir / "rdma_qpc_field_matrix.csv"
    with csv_path.open("w", encoding="utf-8-sig", newline="") as handle:
        out = writer(handle)
        out.writerow(headers)
        out.writerows(table_rows)
    sheets = [
        ("QPC字段总表", headers, table_rows, [7, 31, 11, 13, 11, 8, 16, 18, 20, 42, 14, 72, 38]),
        ("重叠字段", overlap_headers, overlap_rows, [14, 13, 48, 90, 42]),
        ("使用说明", instruction_headers, instruction_rows, [20, 110]),
        ("实现差距", gap_headers, gap_rows, [18, 44, 58, 52]),
    ]
    xlsx_path = docs_dir / "rdma_qpc_field_matrix.xlsx"
    with zipfile.ZipFile(xlsx_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in workbook_files(sheets).items():
            archive.writestr(name, data)
    return xlsx_path, csv_path


def main() -> int:
    """功能：解析当前 QPC 定义并生成字段矩阵。
    输入/输出及副作用：读取源码、写入 docs 下 XLSX/CSV，成功时返回 0。
    失败/边界：源码缺失或生成失败抛出异常并返回非零，避免发布半成品文档。
    """
    root = Path(__file__).resolve().parents[1]
    fields = add_overlap_groups(parse_fields(root / "src/codec/rdma/rdma_defs.svh"))
    xlsx_path, csv_path = write_outputs(root, fields)
    print(f"generated {xlsx_path}")
    print(f"generated {csv_path}")
    print(f"fields={len(fields)} overlap_groups={len({f['overlap_group'] for f in fields if f['overlap_group']})}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

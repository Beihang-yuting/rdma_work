#!/usr/bin/env python3
"""目录：tools；职责：检查变更 SystemVerilog 的稀疏中文注释和单语句风格。
依赖：Git 命令和 Python 标准库；本脚本只读取提交、索引及工作树，不拥有或改写
RTL 文件生命周期，诊断供 Make 门禁和代码审查使用。
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import re
from pathlib import Path
import subprocess
import sys


LABELS = ("功能：", "输入/输出及副作用：", "失败/边界：")
# SystemVerilog allows declaration qualifiers such as ``pure virtual`` and
# ``extern static`` before the function/task keyword.  Keep the recognizer
# deliberately qualifier-only so it cannot mistake arbitrary identifiers for
# methods; the body/termination scan remains responsible for the range.
METHOD_RE = re.compile(
    r"^\s*(?:(?:pure|virtual|automatic|protected|local|static|extern)\s+)*(function|task)\b"
)
END_RE = re.compile(r"^\s*end(function|task)\b")
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


@dataclass
class ChangeSet:
    """功能：保存单个提交范围内的 SV 文件、变更行和新增文件状态。
    输入输出及副作用：字段由 Git diff 解析器填充，供后续只读检查；不持有文件句柄。
    失败边界：路径缺少 hunk 或内容无法解码时由调用层生成稳定诊断。
    """

    lines: dict[str, set[int]] = field(default_factory=dict)
    new_files: set[str] = field(default_factory=set)


@dataclass
class Diagnostic:
    """功能：表示一个可排序的硬错误或 soft-limit 审查提示。
    输入输出及副作用：保存路径、行号和文本，输出阶段格式化为一行；不修改输入。
    失败边界：行号可为零表示文件级错误，消息必须保持稳定以便 CI 比较。
    """

    path: str
    line: int
    message: str
    hard: bool = True


def run_git(root: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    """功能：在指定仓库以参数数组执行 Git 并返回原始文本结果。
    输入输出及副作用：输入 root 和 argv，输出 CompletedProcess；Git 只读操作不会改写源码。
    失败边界：调用者必须处理非零状态、空输出和解码错误，禁止通过 shell 拼接参数。
    """

    return subprocess.run(["git", *args], cwd=root, text=True, capture_output=True, check=False)


def resolve_revision(root: Path, revision: str, label: str) -> str:
    """功能：将 base/head 参数解析为可用于读取提交对象的完整提交哈希。
    输入输出及副作用：输入用户修订名和标签，返回 40 位哈希；仅查询 Git 对象数据库。
    失败边界：修订不存在、不是 commit 或 Git 出错时抛出带 label 的 ValueError。
    """

    result = run_git(root, ["rev-parse", "--verify", f"{revision}^{{commit}}"])
    value = result.stdout.strip()
    if result.returncode != 0 or not re.fullmatch(r"[0-9a-fA-F]{40}", value):
        detail = result.stderr.strip() or "revision is not a commit"
        raise ValueError(f"invalid {label} commit {revision!r}: {detail}")
    return value


def parse_diff(text: str) -> ChangeSet:
    """功能：从 unified=0 diff 提取 SV 路径及新文件中的新增行号。
    输入输出及副作用：输入 Git diff 文本，返回 ChangeSet；不解析或写回源文件。
    失败边界：非 SV、删除行和无 hunk 元数据被忽略，异常 hunk 仅停止该段解析。
    """

    changes = ChangeSet()
    current: str | None = None
    new_line = 0
    for raw in text.splitlines():
        if raw.startswith("+++ b/"):
            current = raw[6:]
            if not current.endswith(".sv"):
                current = None
            elif current not in changes.lines:
                changes.lines[current] = set()
            continue
        match = HUNK_RE.match(raw)
        if match:
            old_line = int(match.group(1))
            new_line = int(match.group(2))
            if old_line == 0:
                if current:
                    changes.new_files.add(current)
            continue
        if current is None or not raw:
            continue
        marker = raw[0]
        if marker == "+":
            if new_line:
                changes.lines[current].add(new_line)
            new_line += 1
        elif marker == " ":
            new_line += 1
    return changes


def add_untracked(root: Path, changes: ChangeSet) -> None:
    """功能：把工作树中未跟踪的 SV 文件作为全量新增内容加入 ChangeSet。
    输入输出及副作用：输入仓库和已有变更，原地加入路径及每一行号；仅读取 Git 清单和文件。
    失败边界：Git 清单失败或路径无法读取时交由主流程报告，非 SV 文件永不加入。
    """

    result = run_git(root, ["ls-files", "--others", "--exclude-standard", "--", "*.sv"])
    if result.returncode != 0:
        raise ValueError(f"cannot list untracked SV files: {result.stderr.strip()}")
    for name in result.stdout.splitlines():
        if not name.endswith(".sv"):
            continue
        path = root / name
        try:
            count = len(path.read_text(encoding="utf-8").splitlines())
        except (OSError, UnicodeError) as exc:
            raise ValueError(f"cannot read {name}: {exc}") from exc
        changes.lines[name] = set(range(1, count + 1))
        changes.new_files.add(name)


@dataclass
class _SanitizeState:
    """功能：保存跨行 SystemVerilog 注释和字符串的词法状态。
    输入输出及副作用：状态由源文扫描器逐行更新，输出只影响后续空格替换；不持有文件资源。
    失败边界：SystemVerilog 不支持嵌套块注释，遇到未闭合字符串或注释时状态延续到文件末尾。
    """

    in_block_comment: bool = False
    in_string: bool = False


def _blank_character(character: str) -> str:
    """功能：将注释或字符串中的字符替换为空白，同时保留换行边界。
    输入输出及副作用：输入单个源字符，返回等长替代字符；纯函数不修改扫描状态。
    失败边界：仅保留 CR/LF，其他控制字符统一变为空格以维持列号和行号稳定。"""

    return character if character in "\r\n" else " "


def _sanitize_line(line: str, state: _SanitizeState) -> str:
    """功能：按共享词法状态移除一行中的注释和字符串，保留可计数语法。
    输入输出及副作用：输入原始行和可变 state，返回与原行等长的净化行并更新跨行状态。
    失败边界：行注释截断本行；块注释、转义引号和跨行字符串继续扫描，未闭合结构延续到 EOF。"""

    output: list[str] = []
    index = 0
    while index < len(line):
        if state.in_block_comment:
            if line.startswith("*/", index):
                output.extend((" ", " "))
                index += 2
                state.in_block_comment = False
            else:
                output.append(_blank_character(line[index]))
                index += 1
            continue

        if state.in_string:
            character = line[index]
            output.append(_blank_character(character))
            index += 1
            if character == "\\" and index < len(line):
                output.append(_blank_character(line[index]))
                index += 1
            elif character == '"':
                state.in_string = False
            continue

        if line.startswith("//", index):
            output.extend(_blank_character(character) for character in line[index:])
            break
        if line.startswith("/*", index):
            output.extend((" ", " "))
            index += 2
            state.in_block_comment = True
            continue
        character = line[index]
        if character == '"':
            output.append(" ")
            index += 1
            state.in_string = True
            continue
        output.append(character)
        index += 1
    return "".join(output)


def sanitize_source(lines: list[str]) -> list[str]:
    """功能：以单一词法状态净化完整 SV 源文，供所有结构扫描共享。
    输入输出及副作用：输入按行源文，返回等长净化行列表；不修改原始行或工作树文件。
    失败边界：跨行块注释和字符串会正确延续，未闭合结构只抑制其后文本而不伪造语法。"""

    state = _SanitizeState()
    return [_sanitize_line(line, state) for line in lines]


def strip_comments_and_strings(line: str) -> str:
    """功能：为单行调用者提供注释/字符串净化兼容入口。
    输入输出及副作用：输入一行文本，返回等长净化文本；独立调用不会跨外部行保存状态。
    失败边界：需要跨行语义的检查必须调用 sanitize_source，单行入口不承诺跨调用状态。"""

    return sanitize_source([line])[0]


def source_lines(root: Path, revision: str | None, path: str) -> list[str]:
    """功能：读取指定模式下的完整 SV 源文，保证 head 模式使用提交 blob。
    输入输出及副作用：revision 为哈希时返回 git show 内容，否则读取工作树 UTF-8 文本。
    失败边界：blob 不存在、文件不可读或不是 UTF-8 时抛出 ValueError，不回退到另一来源。
    """

    if revision is None:
        try:
            return (root / path).read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as exc:
            raise ValueError(f"cannot read {path}: {exc}") from exc
    result = run_git(root, ["show", f"{revision}:{path}"])
    if result.returncode != 0:
        raise ValueError(f"cannot read {revision}:{path}: {result.stderr.strip()}")
    return result.stdout.splitlines()


def is_comment(line: str) -> bool:
    """功能：判断一行是否为可用于方法邻接块的单行注释。
    输入输出及副作用：输入源文一行，返回是否去空白后以 // 开头；不产生副作用。
    失败边界：块注释和代码尾随注释不算邻接注释，空行也会返回 False。
    """

    return line.strip().startswith("//")


def method_ranges(cleaned_lines: list[str]) -> list[tuple[int, int, int]]:
    """功能：在已净化的完整源文中定位 function/task 声明及其结束行。
    输入输出及副作用：输入 sanitize_source 的行列表，返回 (声明行、结束行、索引) 元组；不修改源文。
    失败边界：未闭合方法延伸到文件末尾；块注释和字符串已被净化，不会产生伪方法。"""

    methods: list[tuple[int, int, int]] = []
    for index, line in enumerate(cleaned_lines):
        if not METHOD_RE.match(line):
            continue

        # `pure`/`extern` declarations end at a prototype semicolon and do not
        # own an endfunction/endtask body.  Treating them as body-bearing
        # methods would extend their range to EOF and make an unrelated later
        # change appear to require comments on an untouched declaration.
        keyword_match = re.search(r"\b(function|task)\b", line)
        qualifier_prefix = line[:keyword_match.start()] if keyword_match else ""
        declaration_only = bool(re.search(r"\b(?:pure|extern)\b", qualifier_prefix))
        if declaration_only:
            end = len(cleaned_lines)
            for cursor in range(index, len(cleaned_lines)):
                if ";" in cleaned_lines[cursor]:
                    end = cursor + 1
                    break
            methods.append((index + 1, end, index))
            continue

        end = len(cleaned_lines)
        for cursor in range(index + 1, len(cleaned_lines)):
            if END_RE.match(cleaned_lines[cursor]):
                end = cursor + 1
                break
        methods.append((index + 1, end, index))
    return methods


def check_method_comments(
    path: str,
    lines: list[str],
    changed: set[int],
    diagnostics: list[Diagnostic],
    cleaned_lines: list[str] | None = None,
) -> None:
    """功能：为包含变更行的每个 function/task 检查独占且紧邻的三段中文注释。
    输入输出及副作用：输入源文和变更行集合，向 diagnostics 添加缺失注释错误；不修改源文。
    失败边界：空行、代码行或已被另一方法使用的注释块都会终止/拒绝邻接搜索。
    """

    claimed: dict[tuple[int, int], int] = {}
    cleaned = cleaned_lines if cleaned_lines is not None else sanitize_source(lines)
    for start, end, declaration_index in method_ranges(cleaned):
        if not any(start <= line <= end for line in changed):
            continue
        cursor = declaration_index - 1
        block: list[int] = []
        while cursor >= 0 and is_comment(lines[cursor]):
            block.append(cursor)
            cursor -= 1
        block.reverse()
        key = (block[0], block[-1]) if block else (-1, -1)
        labels = "".join(lines[item] for item in block)
        valid = bool(block) and all(label in labels for label in LABELS)
        if key in claimed or not valid:
            diagnostics.append(Diagnostic(path, start, "function/task lacks adjacent 功能/输入输出及副作用/失败边界 comments"))
        elif block:
            claimed[key] = start


def check_file_header(path: str, lines: list[str], diagnostics: list[Diagnostic]) -> None:
    """功能：验证新增 SV 文件开头的目录层次、职责、依赖和所有权生命周期说明。
    输入输出及副作用：输入文件路径和完整源文，按缺失项目添加文件头错误；不写文件。
    失败边界：首个代码行之后的注释不算文件头，四项均须出现在连续前导注释区域。
    """

    header: list[str] = []
    for line in lines:
        if line.strip() == "" or is_comment(line):
            header.append(line)
        else:
            break
    text = "\n".join(header)
    checks = (
        ("directory/layer", "目录" in text and "层" in text),
        ("responsibility", "职责" in text),
        ("primary dependencies", "依赖" in text),
        ("ownership/lifetime", "所有权" in text and "生命周期" in text),
    )
    for item, present in checks:
        if not present:
            diagnostics.append(Diagnostic(path, 1, f"file header lacks {item}"))


def check_changed_lines(
    path: str,
    lines: list[str],
    changed: set[int],
    diagnostics: list[Diagnostic],
    cleaned_lines: list[str] | None = None,
) -> None:
    """功能：检查新增行的尾随空白、长度、单语句及单行 if-return 约束。
    输入输出及副作用：输入路径、源文和新增行号，添加硬错误或 soft-limit 提示；不改写文本。
    失败边界：for 头恰好两个分隔分号是唯一多分号例外，完整源文净化后注释/字符串分号不计入语句。
    """

    cleaned = cleaned_lines if cleaned_lines is not None else sanitize_source(lines)
    for number in sorted(changed):
        if number < 1 or number > len(lines):
            continue
        original = lines[number - 1]
        cleaned_line = cleaned[number - 1]
        if original.rstrip("\n\r").endswith((" ", "\t")):
            diagnostics.append(Diagnostic(path, number, "changed SV line has trailing whitespace"))
        if len(original) > 100:
            diagnostics.append(Diagnostic(path, number, "soft-limit: changed SV line exceeds 100 columns", hard=False))
        if re.search(r"\bif\s*\([^)]*\)\s*return\b", cleaned_line):
            diagnostics.append(Diagnostic(path, number, "single-line if return is not allowed"))
        semicolons = cleaned_line.count(";")
        is_for = bool(re.match(r"^\s*for\s*\(", cleaned_line))
        if semicolons > 1 and not (is_for and semicolons == 2):
            diagnostics.append(Diagnostic(path, number, "changed SV line contains multiple statements"))


def check_cases(
    path: str,
    lines: list[str],
    changed: set[int],
    diagnostics: list[Diagnostic],
    cleaned_lines: list[str] | None = None,
) -> None:
    """功能：检查变更 case 块是否有 default，并拒绝无 begin/end 的多语句分支。
    输入输出及副作用：输入源文和变更行，按 case 块添加稳定诊断；不改变 case 结构。
    失败边界：仅包含变更行的 case 才检查，嵌套 case 按最近 endcase 收束，注释字符串已剥离。
    """

    cleaned = cleaned_lines if cleaned_lines is not None else sanitize_source(lines)
    index = 0
    while index < len(lines):
        if not re.search(r"\bcase(?:z|x)?\s*\(", cleaned[index]):
            index += 1
            continue
        end = index + 1
        depth = 1
        while end < len(lines) and depth:
            token = cleaned[end]
            if re.search(r"\bcase(?:z|x)?\s*\(", token):
                depth += 1
            if re.search(r"\bendcase\b", token):
                depth -= 1
            end += 1
        block_changed = any(index + 1 <= line <= end for line in changed)
        if block_changed:
            block = lines[index:end]
            if not any(re.search(r"\bdefault\s*:", cleaned[item_index]) for item_index in range(index, end)):
                diagnostics.append(Diagnostic(path, index + 1, "changed case lacks explicit default"))
            branch_start: int | None = None
            branch_has_begin = False
            branch_statements = 0
            for offset in range(index + 1, end):
                token = cleaned[offset]
                if re.search(r"\bendcase\b", token):
                    break
                # A class/package scope operator (`::`) is not a case-item
                # delimiter.  Keep the lightweight case parser, but require
                # the matched colon to have neither colon neighbour.
                label = re.match(
                    r"^\s*(?:default\s*:|[^:]+(?<!:):(?!:))", token
                )
                if label:
                    if branch_start is not None and branch_statements > 1 and not branch_has_begin:
                        diagnostics.append(Diagnostic(path, branch_start, "multi-statement case branch requires begin/end"))
                    branch_start = offset + 1
                    branch_has_begin = "begin" in token
                    branch_statements = token[token.find(":") + 1 :].count(";")
                elif branch_start is not None:
                    branch_has_begin = branch_has_begin or "begin" in token
                    branch_statements += token.count(";")
            if branch_start is not None and branch_statements > 1 and not branch_has_begin:
                diagnostics.append(Diagnostic(path, branch_start, "multi-statement case branch requires begin/end"))
        index = max(end, index + 1)


def run_checks(root: Path, changes: ChangeSet, revision: str | None) -> list[Diagnostic]:
    """功能：读取所有受影响 SV 上下文并汇总语法、注释和文件头诊断。
    输入输出及副作用：输入仓库、ChangeSet 和可选提交哈希，返回排序后的诊断；只读源文。
    失败边界：单个文件读取失败转换为文件级错误，其他文件仍继续检查以保持批量反馈。
    """

    diagnostics: list[Diagnostic] = []
    for path in sorted(changes.lines):
        try:
            lines = source_lines(root, revision, path)
        except ValueError as exc:
            diagnostics.append(Diagnostic(path, 1, str(exc)))
            continue
        changed = changes.lines[path]
        cleaned = sanitize_source(lines)
        check_changed_lines(path, lines, changed, diagnostics, cleaned)
        check_method_comments(path, lines, changed, diagnostics, cleaned)
        check_cases(path, lines, changed, diagnostics, cleaned)
        if path in changes.new_files:
            check_file_header(path, lines, diagnostics)
    return sorted(diagnostics, key=lambda item: (item.path, item.line, item.message))


def parse_args(argv: list[str]) -> argparse.Namespace:
    """功能：解析 checker 的 base 和可选 head 命令行参数。
    输入输出及副作用：输入 argv，返回 argparse 命名空间；不访问 Git 或修改文件。
    失败边界：缺少必需 base 或重复选项由 argparse 以非零状态退出。
    """

    parser = argparse.ArgumentParser(description="check changed SystemVerilog style")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """功能：执行 diff-aware SV 风格门禁并输出稳定诊断及退出状态。
    输入输出及副作用：输入 CLI 参数，stdout/stderr 输出诊断；仅读取 Git、工作树和提交 blob。
    失败边界：提交解析或输入读取失败返回 2；硬诊断返回 1，只有 soft-limit 时返回 0。
    """

    args = parse_args(sys.argv[1:] if argv is None else argv)
    root_result = subprocess.run(["git", "rev-parse", "--show-toplevel"], text=True, capture_output=True, check=False)
    if root_result.returncode != 0:
        print("not inside a Git repository", file=sys.stderr)
        return 2
    root = Path(root_result.stdout.strip())
    try:
        base = resolve_revision(root, args.base, "base")
        head = resolve_revision(root, args.head, "head") if args.head else None
        if head:
            diff_result = run_git(root, ["diff", "--unified=0", "--no-ext-diff", "--diff-filter=ACMR", f"{base}..{head}", "--"])
        else:
            diff_result = run_git(root, ["diff", "--unified=0", "--no-ext-diff", "--diff-filter=ACMR", base, "--"])
        if diff_result.returncode != 0:
            raise ValueError(f"cannot inspect diff: {diff_result.stderr.strip()}")
        changes = parse_diff(diff_result.stdout)
        if head is None:
            add_untracked(root, changes)
        diagnostics = run_checks(root, changes, head)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    for diagnostic in diagnostics:
        stream = sys.stderr
        print(f"{diagnostic.path}:{diagnostic.line}: {diagnostic.message}", file=stream)
    return 1 if any(item.hard for item in diagnostics) else 0


if __name__ == "__main__":
    raise SystemExit(main())

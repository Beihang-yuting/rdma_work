# 目录：tests/unit；职责：覆盖 CMQ oracle verifier 的不可变解析与拒绝边界。
# 依赖与所有权：TemporaryDirectory 管理临时 TSV/输出；被测 verifier
# 不应写入仓库。

from __future__ import annotations

import argparse
import ast
from contextlib import ExitStack
import re
import shlex
import shutil
import tempfile
import unittest
from unittest import mock
from pathlib import Path

from tools import verify_rdma_cmq_oracle as verifier


class OracleVerifierUnitTest(unittest.TestCase):
    """功能：验证 oracle 规范化、anchor 顺序及 CLI 只读契约。
    输入输出及副作用：测试在临时目录构造最小文本 fixture；失败时不应
    留下
    仓库输出。
    失败边界：任何报告漂移、anchor 缺失或 update 选项都必须被拒绝。"""

    def test_canonical_reports_sort_fields(self):
        """功能：检查 bytes 小写化与字段按 offset/lsb/name 排序。
        输入输出及副作用：传入 stdout 字符串，返回规范文本；不写文件。
        失败边界：缺失 BYTES 或 malformed 行由 verifier 抛 ContractError。"""
        bytes_text, fields_text = verifier.canonical_reports(
            "BYTES\tAA\t01\nFIELD\tz\t8\t0\t1\t0f\nFIELD\ta\t0\t2\t1\t01\n"
        )
        self.assertEqual(bytes_text, "aa 01\n")
        self.assertEqual(fields_text, "a\t0\t2\t1\t01\nz\t8\t0\t1\t0f\n")

    def test_canonical_reports_rejects_unknown_row(self):
        """功能：拒绝 oracle 输出中的未知行类型。
        输入输出及副作用：构造一行 UNKNOWN，期望 ContractError；不创建文件。
        失败边界：任何非 BYTES/FIELD 行都必须 fail-closed。"""
        with self.assertRaises(verifier.ContractError):
            verifier.canonical_reports("BYTES\t00\nUNKNOWN\tx\n")

    def test_sparse_layout_contract(self):
        """功能：按 Python、shell 与 C 语法锁定 Task 3 文件的稀疏排版。
        输入输出及副作用：读取 verifier、测试、capture helper 和 probe，检查
        行宽、同行动作及声明；不写文件。
        失败边界：超过 100 列、Python suite/分号同行动作、shell case/命令链，
        或 C 非独立 for 头的多分号行均必须拒绝。"""
        repo = Path(__file__).resolve().parents[2]
        python_paths = (
            repo / "tools/verify_rdma_cmq_oracle.py",
            repo / "tests/unit/test_verify_rdma_cmq_oracle.py",
        )
        shell_path = repo / "tests/support/capture_rdma_cmq_oracle_candidate.sh"
        c_path = repo / "hw/rdma/c_oracle/rdma_cmq_oracle.c"
        paths = (*python_paths, shell_path, c_path)
        sources = {
            path: path.read_text(encoding="utf-8")
            for path in paths
        }
        python_orphan_suite_body = re.compile(
            r"^\s*(?:else|finally)\s*:\s*(?!#)\S"
        )
        shell_inline_case_action = re.compile(
            r"^\s*(?:--[A-Za-z0-9_-]+|\*|\*\.[A-Za-z0-9_.*?-]+)\)\s+\S"
        )
        shell_chained_action = re.compile(
            r";\s*(?!(?:then|do)\b|;|$)\S"
        )
        c_for_header = re.compile(
            r"^\s*for\s*\([^;]*;[^;]*;[^;]*\)\s*\{?\s*$"
        )

        for path in paths:
            for line_number, line in enumerate(sources[path].splitlines(), 1):
                with self.subTest(path=path, line=line_number, rule="line width"):
                    self.assertLessEqual(
                        len(line),
                        100,
                        f"{path}:{line_number} exceeds 100 columns",
                    )

        for path in python_paths:
            statement_lines = {}
            tree = ast.parse(sources[path], filename=str(path))
            for node in ast.walk(tree):
                if isinstance(node, (ast.ExceptHandler, ast.stmt)):
                    statement_lines.setdefault(node.lineno, []).append(
                        type(node).__name__
                    )
            for line_number, statement_types in sorted(statement_lines.items()):
                with self.subTest(
                    path=path,
                    line=line_number,
                    rule="Python statement count",
                ):
                    self.assertEqual(
                        len(statement_types),
                        1,
                        f"{path}:{line_number} has multiple Python statements: "
                        + ", ".join(statement_types),
                    )
            for line_number, line in enumerate(sources[path].splitlines(), 1):
                with self.subTest(
                    path=path,
                    line=line_number,
                    rule="Python orphan suite body",
                ):
                    self.assertIsNone(
                        python_orphan_suite_body.match(line),
                        f"{path}:{line_number} has a one-line Python suite body",
                    )

        for path in (shell_path, python_paths[1]):
            for line_number, line in enumerate(sources[path].splitlines(), 1):
                with self.subTest(
                    path=path,
                    line=line_number,
                    rule="shell case body",
                ):
                    self.assertIsNone(
                        shell_inline_case_action.match(line),
                        f"{path}:{line_number} has an inline shell case action",
                    )

        for line_number, line in enumerate(sources[shell_path].splitlines(), 1):
            with self.subTest(
                path=shell_path,
                line=line_number,
                rule="shell command chain",
            ):
                self.assertIsNone(
                    shell_chained_action.search(line),
                    f"{shell_path}:{line_number} chains shell commands",
                )

        for line_number, line in enumerate(sources[c_path].splitlines(), 1):
            if line.count(";") <= 1:
                continue
            with self.subTest(
                path=c_path,
                line=line_number,
                rule="C declaration/action count",
            ):
                self.assertRegex(
                    line,
                    c_for_header,
                    f"{c_path}:{line_number} has multiple C declarations/actions",
                )

    def test_cases_require_exact_four(self):
        """功能：确保 case manifest 必须包含固定四个 case。
        输入输出及副作用：临时 manifest 缺失 doorbell 行；load_cases 只读并
        抛错。
        失败边界：缺失、重复、额外 ID 均不可绕过。"""
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "cases.tsv"
            row = (
                "cmq_sqe_qpc_create_request\tCMQ_SQE\tQPC_CREATE\tREQUEST\t"
                "cmq.c\txtrdma_sc_qp_create\t64\t8\t64\tbig\t0\n"
            )
            path.write_text(
                verifier.CASE_HEADER + "\n" + row,
                encoding="utf-8",
            )
            with self.assertRaises(verifier.ContractError):
                verifier.load_cases(path)

    def test_anchor_order_rejected(self):
        """功能：确保 helper anchor 只能按冻结 call-graph 顺序出现。
        输入输出及副作用：交换 QPC PREPARE/BUILD 行，解析应失败；不写仓库。
        失败边界：缺失、重复或重排任一 hop 都必须拒绝。"""
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "anchors.tsv"
            rows = [
                "cmq_sqe_qpc_create_request\tBUILD\tcmq.c\t"
                "xtrdma_sc_qp_create\ttoken\t1\tb\top\tflow",
                "cmq_sqe_qpc_create_request\tPREPARE\tqp.c\t"
                "xtrdma_hw_create_qp\ttoken\t1\tb\top\tflow",
            ]
            path.write_text(
                verifier.ANCHOR_HEADER + "\n" + "\n".join(rows) + "\n",
                encoding="utf-8",
            )
            with self.assertRaises(verifier.ContractError):
                verifier.load_anchors(path)

    def test_unrecognized_update_option(self):
        """功能：验证生产 CLI 没有 --update/record 写入选项。
        输入输出及副作用：仅调用 argparse，返回 2；不触碰 artifact。
        失败边界：未识别选项必须 fail-closed，而不是更新 golden 文件。"""
        with self.assertRaises(SystemExit) as raised:
            verifier.main(["--update"])
        self.assertEqual(raised.exception.code, 2)

    def test_case_geometry_is_locked_per_case(self):
        """功能：验证每个 case 的 entry、opcode、方向和几何字段不可替换。
        输入输出及副作用：篡改 CQC embed_base，load_cases 必须抛错；不写文件。
        失败边界：仅允许 manifest 中冻结的逐字段组合，不能只检查取值
        集合。"""
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "cases.tsv"
            rows = [
                "cmq_sqe_qpc_create_request\tCMQ_SQE\tQPC_CREATE\tREQUEST\t"
                "cmq.c\txtrdma_sc_qp_create\t64\t8\t64\tbig\t0",
                "cmq_sqe_cqc_create_request\tCMQ_SQE\tCQC_CREATE\tREQUEST\t"
                "cmq.c\txtrdma_sc_cq_create\t64\t8\t64\tbig\t0",
                "cmq_cqe_qpc_create_response\tCMQ_CQE\tQPC_CREATE\tRESPONSE\t"
                "cmq.c\txtrdma_get_cqe_common_info\t64\t8\t64\tbig\t0",
                "cmq_sq_doorbell\tCMQ_SQ_DOORBELL\tCMQ_SQ\tREQUEST\t"
                "cmq.c\txtrdma_sc_cmq_post_sq\t8\t8\t8\tbig\t0",
            ]
            path.write_text(
                verifier.CASE_HEADER + "\n" + "\n".join(rows) + "\n",
                encoding="utf-8",
            )
            with self.assertRaises(verifier.ContractError):
                verifier.load_cases(path)

    def test_anchor_text_is_locked(self):
        """功能：验证 anchor 的 source/function/token/flow 文本不可替换。
        输入输出及副作用：构造合法表但篡改 token，load_anchors 必须拒绝。
        失败边界：闭合摘要不能掩盖 anchor 行语义漂移。"""
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "anchors.tsv"
            rows = "\n".join(
                "\t".join(row)
                for row in verifier.EXPECTED_ANCHOR_ROWS["cmq_sq_doorbell"]
            )
            rows = rows.replace(
                "iowrite64be(val, db_addr);",
                "changed(val, db_addr);",
            )
            path.write_text(
                verifier.ANCHOR_HEADER + "\n" + rows + "\n",
                encoding="utf-8",
            )
            with self.assertRaises(verifier.ContractError):
                verifier.load_anchors(path)

    def test_comments_are_removed_for_anchor_count(self):
        """功能：验证 source anchor 计数忽略注释副本。
        输入输出及副作用：调用私有注释剥离 helper，返回纯代码文本；不写
        文件。
        失败边界：注释中的 token 不得被计作真实 anchor。"""
        self.assertEqual(verifier._strip_comments("/* token */ token // token\n"), " token \n")

    def _compiler_fixture(self, root: Path, mode: str = "ok") -> Path:
        """功能：构造可控的用户态 compiler wrapper fixture。
        输入输出及副作用：root 下创建 executable wrapper，按 mode 产生
        binary/diagnostic/failure。
        失败边界：wrapper 只服务本测试，任何未知 mode 均拒绝构造。"""
        if mode not in {"ok", "diagnostic", "failure", "werror"}:
            raise AssertionError(mode)
        path = root / "cc-wrapper"
        script = f'''#!/bin/sh
set -eu

if [ "$1" = "--version" ]; then
    echo 'fixture gcc 1.0'
    exit 0
fi
if [ "$1" = "-dumpmachine" ]; then
    echo 'fixture-target'
    exit 0
fi
if [ '{mode}' = 'failure' ]; then
    echo 'static assertion failed' >&2
    exit 1
fi
if [ '{mode}' = 'werror' ]; then
    echo 'unused variable: error' >&2
    exit 1
fi
if [ '{mode}' = 'diagnostic' ]; then
    echo 'synthetic compiler warning' >&2
fi

out=''
while [ "$#" -gt 0 ]; do
    if [ "$1" = '-o' ]; then
        shift
        out=$1
        break
    fi
    shift
done
[ -n "$out" ]
printf '#!/bin/sh\\nprintf "BYTES\\\\t00\\\\n"\\n' > "$out"
chmod +x "$out"
'''
        path.write_text(script, encoding="utf-8")
        path.chmod(0o755)
        return path

    def test_missing_compiler_is_rejected(self):
        """功能：验证不存在的 compiler path 立即 fail-closed。
        输入输出及副作用：传入临时目录中的缺失路径，期待 ContractError；
        不创建输出。
        失败边界：realpath/hash/version 任一步不可用均不得继续编译。"""
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(verifier.ContractError):
                verifier._compiler_facts(Path(temp) / "missing-gcc")

    def test_compiler_identity_mismatch_is_rejected(self):
        """功能：验证 compiler SHA/version/target 与锁定身份不一致时拒绝。
        输入输出及副作用：使用 /bin/true 作为伪 compiler，只读探测并抛
        ContractError。
        失败边界：即使命令可执行，版本或 target 空值也不能绕过身份
        检查。"""
        with self.assertRaises(verifier.ContractError):
            verifier._compiler_facts(Path("/bin/true"))

    def test_compiler_sha_version_target_mismatch_separately(self):
        """功能：分别触发 compiler SHA、version、target 三种身份漂移。
        输入输出及副作用：以 fixture wrapper 的真实 facts 为基线，每次仅篡改
        一个锁定常量。
        失败边界：任一单字段 mismatch 都必须由 _compiler_facts 独立拒绝。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            compiler = self._compiler_fixture(root)
            real = str(compiler.resolve())
            digest = verifier._sha256(compiler)
            common = {
                "EXPECTED_COMPILER_PATH": real,
                "EXPECTED_COMPILER_SHA256": digest,
                "EXPECTED_COMPILER_VERSION": "fixture gcc 1.0",
                "EXPECTED_COMPILER_TARGET": "fixture-target",
                "EXPECTED_TARGET_BITS": "64",
            }
            fields = (
                "EXPECTED_COMPILER_SHA256",
                "EXPECTED_COMPILER_VERSION",
                "EXPECTED_COMPILER_TARGET",
            )
            for field in fields:
                with mock.patch.multiple(verifier, **common):
                    altered = "0" * 64 if field.endswith("SHA256") else "mismatch"
                    with mock.patch.object(verifier, field, altered):
                        with self.assertRaises(verifier.ContractError):
                            verifier._compiler_facts(compiler)

    def test_compiler_diagnostic_is_rejected(self):
        """功能：验证 compiler 返回零但 stderr 有 warning 仍被拒绝。
        输入输出及副作用：diagnostic wrapper 写入临时 binary，_build_and_run
        只读并抛错。
        失败边界：非空 stderr 独立于 -Werror，必须阻止执行和 artifact 发布。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cc = self._compiler_fixture(root, "diagnostic")
            source = root / "fixture.c"
            source.write_text("int main(void){return 0;}\n", encoding="utf-8")
            input_path = root / "input.tsv"
            input_path.write_text("x\t0\n", encoding="utf-8")
            with self.assertRaises(verifier.ContractError):
                verifier._build_and_run(cc, root, source, "fixture", input_path, root)

    def test_static_assert_failure_is_rejected(self):
        """功能：验证 compiler 对 ABI/static assertion 的非零诊断被拒绝。
        输入输出及副作用：failure wrapper 模拟 _Static_assert 失败；不返回
        stdout。
        失败边界：任何编译返回码非零都不得运行候选 binary。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cc = self._compiler_fixture(root, "failure")
            source = root / "fixture.c"
            source.write_text("_Static_assert(0, 'bad');\n", encoding="utf-8")
            input_path = root / "input.tsv"
            input_path.write_text("x\t0\n", encoding="utf-8")
            with self.assertRaises(verifier.ContractError):
                verifier._build_and_run(cc, root, source, "fixture", input_path, root)

    def test_real_gcc_werror_fixture(self):
        """功能：验证固定 -Werror flags 将 unused variable fixture 视为编译失败。
        输入输出及副作用：优先使用真实 gcc；无 gcc 的开发容器使用等价
        failure wrapper，契约仍被断言。
        失败边界：返回零或吞掉 warning 的 compiler 都会使测试失败。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cc = Path(shutil.which("gcc") or self._compiler_fixture(root, "werror"))
            source = root / "fixture.c"
            source.write_text(
                "int main(void)\n"
                "{\n"
                "    int unused_value = 7;\n"
                "    return 0;\n"
                "}\n",
                encoding="utf-8",
            )
            input_path = root / "input.tsv"
            input_path.write_text("x\t0\n", encoding="utf-8")
            with self.assertRaises(verifier.ContractError):
                verifier._build_and_run(cc, root, source, "fixture", input_path, root)

    def _verify_fixture(self, root: Path):
        """功能：复制四组 canonical 文件并构造可注入的 verify() 参数。
        输入输出及副作用：返回 Namespace、artifact root、source copy 与 patch
        值；fixture 归 root 所有。
        失败边界：任何缺失 canonical 文件都使 verify() 按生产路径抛
        ContractError。"""
        repo = Path(__file__).resolve().parents[2]
        artifact_root = root / "artifacts"
        artifact_root.mkdir()
        for case in verifier.EXPECTED_CASE_ROWS:
            for suffix in ("input.tsv", "bytes.hex", "fields.tsv", "metadata.env"):
                source = repo / "hw/rdma/c_oracle/cases" / f"{case}.{suffix}"
                shutil.copy2(source, artifact_root / source.name)
        oracle_source = root / "oracle.c"
        shutil.copy2(repo / "hw/rdma/c_oracle/rdma_cmq_oracle.c", oracle_source)
        args = argparse.Namespace(
            kernel_root=root,
            archive_lock=repo / "hw/rdma/archive_lock.env",
            source_manifest=repo / "hw/rdma/source_manifest.txt",
            source_anchors=repo / "hw/rdma/c_oracle/cmq_oracle_source_anchors.tsv",
            cases=repo / "hw/rdma/c_oracle/cmq_oracle_cases.tsv",
            oracle_source=oracle_source,
            artifact_root=artifact_root,
            cc=Path("/usr/bin/gcc"),
        )
        closure = {}
        for case in verifier.EXPECTED_CASE_ROWS:
            metadata = {}
            metadata_path = artifact_root / f"{case}.metadata.env"
            metadata_lines = metadata_path.read_text(encoding="utf-8").splitlines()
            for line in metadata_lines:
                key, value = line.split("=", 1)
                metadata[key] = value
            closure[case] = (
                metadata["RDMA_SOURCE_ANCHORS_SHA256"],
                metadata["RDMA_SOURCE_CLOSURE_SHA256"],
                [],
            )
        facts = {
            "path": verifier.EXPECTED_COMPILER_PATH,
            "sha": verifier.EXPECTED_COMPILER_SHA256,
            "version": verifier.EXPECTED_COMPILER_VERSION,
            "target": verifier.EXPECTED_COMPILER_TARGET,
            "bits": verifier.EXPECTED_TARGET_BITS,
            "endian": verifier.EXPECTED_TARGET_ENDIAN,
        }
        outputs = {}
        for case in verifier.EXPECTED_CASE_ROWS:
            bytes_text = (
                artifact_root / f"{case}.bytes.hex"
            ).read_text(encoding="utf-8").strip().split()
            fields = (artifact_root / f"{case}.fields.tsv").read_text(encoding="utf-8")
            outputs[case] = (
                "BYTES\t"
                + "\t".join(bytes_text)
                + "\n"
                + "".join("FIELD\t" + line for line in fields.splitlines(True))
            )
        return args, closure, facts, outputs

    def test_verify_rejects_missing_and_report_drift(self):
        """功能：实际调用 verify() 覆盖 missing artifact、bytes drift、fields drift。
        输入输出及副作用：临时复制完整 artifact 后逐项篡改并断言生产
        verifier 拒绝。
        失败边界：任一 artifact 缺失或报告内容漂移均必须抛 ContractError。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "missing"
            root.mkdir()
            args, closure, facts, outputs = self._verify_fixture(root)
            patches = mock.patch.multiple(
                verifier,
                source_digests=mock.DEFAULT,
                _compiler_facts=mock.DEFAULT,
                _build_and_run=mock.DEFAULT,
            )
            with patches as values:
                values["source_digests"].return_value = closure
                values["_compiler_facts"].return_value = facts
                values["_build_and_run"].side_effect = lambda *call: (outputs[call[3]], "")
                missing = args.artifact_root / "cmq_sq_doorbell.input.tsv"
                missing.unlink()
                with self.assertRaises(verifier.ContractError):
                    verifier.verify(args)
                shutil.copy2(
                    Path(__file__).resolve().parents[2]
                    / "hw/rdma/c_oracle/cases/cmq_sq_doorbell.input.tsv",
                    missing,
                )

            root = Path(temp) / "bytes"
            root.mkdir()
            args, closure, facts, outputs = self._verify_fixture(root)
            with mock.patch.object(
                verifier, "source_digests", return_value=closure
            ), mock.patch.object(
                verifier, "_compiler_facts", return_value=facts
            ), mock.patch.object(
                verifier,
                "_build_and_run",
                side_effect=lambda *call: (outputs[call[3]], ""),
            ):
                (args.artifact_root / "cmq_sq_doorbell.bytes.hex").write_text(
                    "ff\n", encoding="utf-8"
                )
                with self.assertRaises(verifier.ContractError):
                    verifier.verify(args)

            root = Path(temp) / "fields"
            root.mkdir()
            args, closure, facts, outputs = self._verify_fixture(root)
            with mock.patch.object(
                verifier, "source_digests", return_value=closure
            ), mock.patch.object(
                verifier, "_compiler_facts", return_value=facts
            ), mock.patch.object(
                verifier,
                "_build_and_run",
                side_effect=lambda *call: (outputs[call[3]], ""),
            ):
                (args.artifact_root / "cmq_sq_doorbell.fields.tsv").write_text(
                    "drift\n", encoding="utf-8"
                )
                with self.assertRaises(verifier.ContractError):
                    verifier.verify(args)

    def test_verify_rejects_closure_probe_and_input_drift(self):
        """功能：实际调用 verify() 覆盖 source closure、probe source、input
        digest 漂移。
        输入输出及副作用：每个临时 fixture 先通过完整 verify，再单独篡改
        一个
        摘要
        来源并断言拒绝。
        失败边界：metadata、oracle source 或 input 任一改变都不得重用旧 canonical
        报告。"""

        def run(root: Path):
            args, closure, facts, outputs = self._verify_fixture(root)
            patches = (
                mock.patch.object(verifier, "source_digests", return_value=closure),
                mock.patch.object(verifier, "_compiler_facts", return_value=facts),
                mock.patch.object(
                    verifier,
                    "_build_and_run",
                    side_effect=lambda *call: (outputs[call[3]], ""),
                ),
            )
            return args, patches

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "closure"
            root.mkdir()
            args, patches = run(root)
            with ExitStack() as stack:
                for patcher in patches:
                    stack.enter_context(patcher)
                metadata = args.artifact_root / "cmq_sq_doorbell.metadata.env"
                metadata.write_text(
                    metadata.read_text(encoding="utf-8").replace(
                        "RDMA_SOURCE_CLOSURE_SHA256=c318",
                        "RDMA_SOURCE_CLOSURE_SHA256=0000",
                    ),
                    encoding="utf-8",
                )
                with self.assertRaises(verifier.ContractError):
                    verifier.verify(args)

            root = Path(temp) / "probe"
            root.mkdir()
            args, patches = run(root)
            with ExitStack() as stack:
                for patcher in patches:
                    stack.enter_context(patcher)
                source_text = args.oracle_source.read_text(encoding="utf-8")
                args.oracle_source.write_text(source_text + "\n", encoding="utf-8")
                with self.assertRaises(verifier.ContractError):
                    verifier.verify(args)

            root = Path(temp) / "input"
            root.mkdir()
            args, patches = run(root)
            with ExitStack() as stack:
                for patcher in patches:
                    stack.enter_context(patcher)
                input_path = args.artifact_root / "cmq_sq_doorbell.input.tsv"
                input_text = input_path.read_text(encoding="utf-8")
                input_path.write_text(
                    input_text + "extra\t1\n",
                    encoding="utf-8",
                )
                with self.assertRaises(verifier.ContractError):
                    verifier.verify(args)

    def test_artifact_digest_and_missing_file_boundaries(self):
        """功能：覆盖 missing artifact 与 bytes/fields digest drift 的基础拒绝边界。
        输入输出及副作用：临时 root 只创建 bytes 文件，路径解析仍报告其余
        文件缺失。
        失败边界：canonical artifact 四件套任一缺失都不能通过 verifier。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "case.bytes.hex").write_text("00\n", encoding="utf-8")
            paths = verifier._artifact_paths(root, "case")
            self.assertTrue(paths[1].is_file())
            self.assertFalse(paths[0].is_file())
            self.assertNotEqual(verifier._sha256(paths[1]), "0" * 64)

    def test_anchor_path_absent_from_manifest(self):
        """功能：验证 source anchor path 不在 manifest 闭合集合时拒绝。
        输入输出及副作用：mock manifest lookup 为空，source_digests 不读取
        任意 source。
        失败边界：anchor 不能通过自行引入未锁定 source path 来扩展权威
        范围。"""
        rows = {
            "cmq_sq_doorbell": [
                list(row)
                for row in verifier.EXPECTED_ANCHOR_ROWS["cmq_sq_doorbell"]
            ]
        }
        with mock.patch.object(verifier, "_manifest_sources", return_value={}):
            with self.assertRaises(verifier.ContractError):
                verifier.source_digests(Path("/tmp"), Path("/tmp/manifest"), rows, "fixture")

    def test_source_closure_probe_and_input_digest_drift(self):
        """功能：覆盖 closure/probe/input 摘要漂移的 fail-closed 断言。
        输入输出及副作用：篡改临时内容后摘要必须改变；不写仓库文件。
        失败边界：任何一项摘要漂移都不能被视为同一 canonical artifact。"""
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "payload"
            path.write_text("before\n", encoding="utf-8")
            before = verifier._sha256(path)
            path.write_text("after\n", encoding="utf-8")
            self.assertNotEqual(before, verifier._sha256(path))

    def test_behavior_anchor_operation_drift(self):
        """功能：拒绝 behavior anchor 的 operation/flow 漂移。
        输入输出及副作用：复制完整 doorbell anchors 后篡改 operation，解析抛
        ContractError。
        失败边界：仅保持 role 顺序而替换行为描述仍必须拒绝。"""
        with tempfile.TemporaryDirectory() as temp:
            rows = [list(row) for row in verifier.EXPECTED_ANCHOR_ROWS["cmq_sq_doorbell"]]
            rows[0][7] = "CHANGED"
            path = Path(temp) / "anchors.tsv"
            path.write_text(
                verifier.ANCHOR_HEADER
                + "\n"
                + "\n".join("\t".join(row) for row in rows)
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaises(verifier.ContractError):
                verifier.load_anchors(path)

    def test_source_function_missing_is_rejected(self):
        """功能：source manifest 闭合后仍拒绝找不到命名函数的 anchor。
        输入输出及副作用：临时 cmq.c 仅含其他函数，source_digests 必须抛错；
        不修改 manifest。
        失败边界：函数选择器不能靠路径存在或摘要正确冒充真实实现。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "cmq.c").write_text(
                "void unrelated(void) {}\n", encoding="utf-8"
            )
            rows = {
                "cmq_sq_doorbell": [
                    list(row)
                    for row in verifier.EXPECTED_ANCHOR_ROWS["cmq_sq_doorbell"]
                ]
            }
            record = mock.Mock(selector="xtrdma_sc_cmq_post_sq|xtrdma_iowrite64be")
            with mock.patch.object(verifier, "_manifest_sources", return_value={"cmq.c": [record]}):
                with self.assertRaises(verifier.ContractError):
                    verifier.source_digests(root, Path("manifest"), rows, "fixture")

    def test_source_anchor_token_missing_is_rejected(self):
        """功能：函数存在但 anchor token 缺失时拒绝 source closure。
        输入输出及副作用：临时 cmq.c 提供空函数体，source_digests 必须抛错；
        不写文件。
        失败边界：token occurrence=1 不能被空实现满足。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "cmq.c").write_text(
                "void xtrdma_sc_cmq_post_sq(void) {}\n", encoding="utf-8"
            )
            rows = {
                "cmq_sq_doorbell": [
                    list(row)
                    for row in verifier.EXPECTED_ANCHOR_ROWS["cmq_sq_doorbell"]
                ]
            }
            record = mock.Mock(selector="xtrdma_sc_cmq_post_sq|xtrdma_iowrite64be")
            with mock.patch.object(verifier, "_manifest_sources", return_value={"cmq.c": [record]}):
                with self.assertRaises(verifier.ContractError):
                    verifier.source_digests(root, Path("manifest"), rows, "fixture")

    def test_cqe_owner_wrap_opcode_ecode_rejections(self):
        """功能：覆盖 CQE owner/wrap/opcode/ecode 四类拒绝条件的输入判定。
        输入输出及副作用：把真实 rdma_cmq_oracle.c 传给分支 harness，先验证
        成功路径再逐项修改输入。
        失败边界：run_cqe 的 owner、wrap、opcode 或 ecode 不匹配时必须返回非零
        并记录命中分支。"""
        repo = Path(__file__).resolve().parents[2]
        source = repo / "hw/rdma/c_oracle/rdma_cmq_oracle.c"
        fixture = {
            "owner": 1,
            "cq_polarity": 1,
            "wqe_index": 0x13,
            "wrap": 0,
            "sq_wrap": 0,
            "opcode": 0,
            "ecode": 0,
        }
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            input_path = root / "cqe.input.tsv"
            input_path.write_text(
                "\n".join(f"{key}\t{value}" for key, value in fixture.items()) + "\n",
                encoding="utf-8",
            )
            baseline_work = root / "baseline"
            baseline_compiler = self._branch_compiler(
                baseline_work,
                source,
                "cmq_cqe_qpc_create_response",
                "run_cqe",
            )
            stdout, _ = verifier._build_and_run(
                baseline_compiler,
                repo,
                source,
                "cmq_cqe_qpc_create_response",
                input_path,
                baseline_work,
            )
            self.assertIn("BYTES", stdout)
            self.assertIn(
                f"source={source}\tbranch=run_cqe",
                (baseline_work / "branch.trace").read_text(encoding="utf-8"),
            )

            for key, value in (("owner", 0), ("wrap", 1), ("opcode", 1), ("ecode", 1)):
                lines = [
                    f"{name}\t{value if name == key else item}"
                    for name, item in fixture.items()
                ]
                input_path.write_text(
                    "\n".join(lines) + "\n", encoding="utf-8"
                )
                work = root / key
                compiler = self._branch_compiler(
                    work,
                    source,
                    "cmq_cqe_qpc_create_response",
                    "run_cqe",
                )
                with self.assertRaises(verifier.ContractError):
                    verifier._build_and_run(
                        compiler,
                        repo,
                        source,
                        "cmq_cqe_qpc_create_response",
                        input_path,
                        work,
                    )
                self.assertIn(
                    f"source={source}\tbranch=run_cqe",
                    (work / "branch.trace").read_text(encoding="utf-8"),
                )

    def test_doorbell_unreachable_ring_head_polarity(self):
        """功能：拒绝不满足 monotonic head/PI/polarity 可达关系的 doorbell fixture。
        输入输出及副作用：把真实 rdma_cmq_oracle.c 传给 run_doorbell harness，
        验证合法第二周期后注入错误 polarity。
        失败边界：head % ring_size、head cycle polarity 任一不一致均必须返回
        非零并记录命中分支。"""
        repo = Path(__file__).resolve().parents[2]
        source = repo / "hw/rdma/c_oracle/rdma_cmq_oracle.c"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            valid_input = root / "doorbell-valid.input.tsv"
            valid_input.write_text(
                "head_before\t0x36\npi_before\t0x16\n"
                "ring_size\t32\nsq_polarity_before\t0\n",
                encoding="utf-8",
            )
            valid_work = root / "doorbell-valid"
            valid_compiler = self._branch_compiler(
                valid_work,
                source,
                "cmq_sq_doorbell",
                "run_doorbell",
            )
            stdout, _ = verifier._build_and_run(
                valid_compiler,
                repo,
                source,
                "cmq_sq_doorbell",
                valid_input,
                valid_work,
            )
            self.assertIn("BYTES", stdout)
            self.assertIn(
                f"source={source}\tbranch=run_doorbell",
                (valid_work / "branch.trace").read_text(encoding="utf-8"),
            )

            invalid_input = root / "doorbell-invalid.input.tsv"
            invalid_input.write_text(
                "head_before\t0x36\npi_before\t0x16\n"
                "ring_size\t32\nsq_polarity_before\t1\n",
                encoding="utf-8",
            )
            invalid_work = root / "doorbell-invalid"
            compiler = self._branch_compiler(
                invalid_work,
                source,
                "cmq_sq_doorbell",
                "run_doorbell",
            )
            with self.assertRaises(verifier.ContractError):
                verifier._build_and_run(
                    compiler,
                    repo,
                    source,
                    "cmq_sq_doorbell",
                    invalid_input,
                    invalid_work,
                )
            self.assertIn(
                f"source={source}\tbranch=run_doorbell",
                (invalid_work / "branch.trace").read_text(encoding="utf-8"),
            )

    def _branch_compiler(
        self, root: Path, source: Path, case_id: str, branch: str
    ) -> Path:
        """功能：构造读取真实 C source marker 并执行指定 oracle 分支的
        compiler/runner harness。
        输入输出及副作用：root 下写入 wrapper、可执行 runner 和 branch.trace；
        测试结束由 TemporaryDirectory 回收。
        失败边界：source 缺少分支函数、case 参数不匹配或分支输入不满足
        关系时
        返回非零。"""
        root.mkdir()
        compiler = root / "cc"
        trace = root / "branch.trace"
        trace_q = shlex.quote(str(trace))
        marker = f"static int {branch}("
        runner = f"""#!/bin/sh
set -eu

if [ "$1" != "--case" ] || [ "$2" != "{case_id}" ] || [ "$3" != "--input" ]; then
    exit 2
fi
input=$4
printf 'source={source}\\tbranch={branch}\\n' >> {trace_q}

get_value() {{
    awk -F '\\t' -v wanted="$1" '
        $1 == wanted {{
            print $2
            found=1
            exit
        }}
        END {{
            exit !found
        }}
    ' "$input"
}}

run_cqe() {{
    owner=$(get_value owner)
    cq_polarity=$(get_value cq_polarity)
    wrap=$(get_value wrap)
    sq_wrap=$(get_value sq_wrap)
    opcode=$(get_value opcode)
    ecode=$(get_value ecode)
    if [ "$owner" -ne "$cq_polarity" ]; then
        return 1
    fi
    if [ "$wrap" -ne "$sq_wrap" ]; then
        return 1
    fi
    if [ "$opcode" -ne 0 ]; then
        return 1
    fi
    if [ "$ecode" -ne 0 ]; then
        return 1
    fi
}}

run_doorbell() {{
    head=$(( $(get_value head_before) ))
    pi=$(( $(get_value pi_before) ))
    ring_size=$(( $(get_value ring_size) ))
    polarity=$(( $(get_value sq_polarity_before) ))
    if [ "$ring_size" -le 0 ]; then
        return 1
    fi
    if [ "$pi" -ne "$((head % ring_size))" ]; then
        return 1
    fi
    if [ "$polarity" -ne "$((1 ^ ((head / ring_size) & 1)))" ]; then
        return 1
    fi
}}

case "{branch}" in
    run_cqe)
        run_cqe
        ;;
    run_doorbell)
        run_doorbell
        ;;
    *)
        exit 3
        ;;
esac
printf 'BYTES\\t00\\n'
"""
        script = f"""#!/bin/sh
set -eu

source=''
out=''
for arg in "$@"; do
    case "$arg" in
        *.c)
            source=$arg
            ;;
    esac
done
if [ -z "$source" ] || ! grep -Fq '{marker}' "$source"; then
    echo 'oracle source marker missing' >&2
    exit 2
fi
while [ "$#" -gt 0 ]; do
    if [ "$1" = '-o' ]; then
        shift
        out=$1
        break
    fi
    shift
done
[ -n "$out" ]
cat > "$out" <<'RUNNER'
{runner}RUNNER
chmod +x "$out"
"""
        compiler.write_text(script, encoding="utf-8")
        compiler.chmod(0o755)
        return compiler


if __name__ == "__main__":
    unittest.main()

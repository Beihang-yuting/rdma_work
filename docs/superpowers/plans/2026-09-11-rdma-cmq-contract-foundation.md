# RDMA CMQ Contract Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立可由真实 0.1.34 驱动归档重建的 CMQ wire 门禁，并在不迁移 MR、
queue、QP 调用方的前提下，为 CMQ 增加每次调用独占的 submission evidence、
batch journal、submission fence 和可审计恢复入口。

**Architecture:** 阶段 0 先锁定归档、源码、C oracle、字段 ownership、capability
和逐 bit closed evidence，任何缺失都 fail-closed。阶段 1A 保留
`rdma_cmq_engine` 作为唯一锁和状态 owner，只增加 detached value、scheduler
observed 结果、薄 transport facade，以及 engine 内部 journal；legacy API 通过单向
wrapper 保持兼容，真实 consumer 迁移和物理类拆分留给后续独立计划。

**Tech Stack:** Python 3 `unittest`、Bash、GNU Make、C11/GCC 9.4.0、
SystemVerilog、UVM 1.2、Synopsys VCS W-2024.09-SP1。

**Spec:** `docs/superpowers/specs/2026-09-11-rdma-engine-contract-refactoring-design.md`

## Global Constraints

- 执行前必须使用 `superpowers:using-git-worktrees`，从“只新增本计划文件、且 first parent 为 `cc07586`”的计划提交建立隔离 worktree；不得直接从 `cc07586` 开工，也不得复制当前工作树中 `rdma_cmq_codecs.sv`、`rdma_cmq_engine.sv`、adapter 或 control-plane 的未提交补丁。
- 原始驱动 wire ABI 是唯一权威；任何受支持结构的 size、alignment、byte/qword offset、lsb、width、端序、overlay discriminator 和 embed base 均不得从 SV/Python mask 反向推导。
- 锁定归档为 `/home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz`：SHA-256 `c9d9286dde389f681f9bd1c29fff14f52c4c1ce11fa5f73a5f1f57da9f827522`，字节数 `289668`，唯一 prefix `dpu_kernel_rdma-version_0.1.34`，规范化 74 项 member-list SHA-256 `d27331088fff104e4f101357a7b0b490b1d33e66396cb060ec421cc94ab68797`。
- C oracle 固定使用 `/usr/bin/gcc`，二进制 SHA-256 `6cb2d84ccd9fd3485d4e47ba032e626be65692601c38fad46866a6b565f3100f`，版本 `gcc 9.4.0 (Ubuntu 9.4.0-1ubuntu1~20.04.2)`，target `x86_64-linux-gnu`，64-bit little-endian。
- 所有 VCS 编译与仿真只通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 的 login bash 中执行；凭据只能由调用环境临时提供，不得写入脚本、URL、配置、文档或提交。
- `host_mem` suite 显式传入 53 上已锁定的
  `HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem`；`integration` suite 只传入
  Task 6A 经 owner 批准并导出的 `DPU_COMMON_ROOT`，不得自动发现或回退到另一目录。
- 阶段 1A 不修改 `rdma_control_plane.sv`、MR consumer、queue lifecycle consumer、QP lifecycle consumer，不修 OCC/CQC/AEQ/RQE/QPC wire 缺陷，也不拆其他 engine。
- 阶段 1A 的 production observed API 不读写共享 `last_*` 证据；但 legacy production `execute()` 必须继续维护 `last_execute_no_submit_proven`，直到 MR control-plane、queue lifecycle、QP lifecycle 三个 Phase 1B consumer 全部迁移后才允许删除并令 accessor 恒 false。
- 阶段 1A 只创建薄 `rdma_cmq_transport.sv` 转发边界；snapshot、ring math、ledger 的物理抽取属于阶段 2，journal 首次引入时仍由现有 engine 内部状态拥有。
- `rdma_cmq_engine` 继续拥有唯一 `engine_lock`、slot/token/registry/cursor/lifecycle；锁序保持 `engine_lock -> scheduler Function transport lock`。
- MMIO observer 回调不得分配、等待、取锁、调用外部 service 或重入 engine/scheduler；它只能更新已经预分配的 journal/index/cursor。
- recovery 的 mapping 权威必须通过 adapter-owned opaque allocation capability 重验；公开 mapping 字段和 digest 即使完全相同也不能证明是同一次分配。
- reset 在外部 backing release 前只能构造不改状态的完整 candidate；release 失败保持 journal/fence/runtime/FIFO/counter/state 原样，release 成功后才执行 allocation-free/no-fail commit 并立即清旧 runtime 与 fence。
- 所有 result 与 status 在每条返回路径都必须非空；handle、ticket、completion、command、owner、DMA context、SQE 和 dependency image 必须是 detached value。
- `submit_batch_observed()` 的 results 必须与 commands 等长同序；只有 recovery batch/attempt 无法定位或 item list 结构非法时，recovery results 才为空。
- `attempt_effect` 只能由本次实际执行阶段推进，禁止从 `rdma_status.code`、空 ticket 或空 completion 推断；`submission_effect` 只能用本计划冻结的跨 attempt fold 规则累计，retry 的 `PRE_SUBMIT_REJECTED` 不得抹掉已有 Host/MMIO/`UNOBSERVED` 证据。只有初始调用已证明 `PRE_SUBMIT_REJECTED` 且没有旧 journal 时，才可映射为 hardware presence `ABSENT`。
- `RDMA_SC_RESOURCE_BUSY` 已在 `src/types/rdma_enum_types.sv` 定义为 `5'd15`，fence 直接使用该值，不新增或重排 status code。
- 每个新增或修改的 function、task、constructor、accessor、probe 和测试 helper，紧邻位置都要有准确中文“功能 / 输入输出及副作用 / 失败边界”三段注释。
- 声明、输出初始化、validation、snapshot、staging、外部 I/O、commit、recovery 之间使用空行分隔；新增/修改行以 100 列为软上限；一行只做一个动作。
- 每个功能任务严格 RED → GREEN → REFACTOR，并单独提交；wire artifact、状态机、结构移动和纯排版不得混入同一提交。
- Task 8–18 的每个 GREEN 之后、commit 之前，执行者必须从文件头到 EOF 人工复审该 Task `Files` 中每个已触及的 SV 源码与测试文件；逐文件核对目录定位、职责、依赖、所有权/生命周期、每个 function/task 的三段中文注释、错误/复位/锁序和稀疏排版。每个提交必须用第二段 commit message 记录 `Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved.`；Task 19 的最终复审不能替代任何前序任务的逐提交记录。
- `rdma_cmq_engine_test` 在 53 上的历史 VCS SIGSEGV 是阻断项；若仍复现，保留最小复现与日志并先解决工具链问题，禁止从 gate 删除测试或删业务逻辑掩盖。

## Design refinements and Phase 1A execution approval gate

本计划以当前批准规格为基线，但 Phase 1A 为闭合 X/Z、跨 retry、reset 原子性和 legacy
迁移窗口，包含下列明确的设计修订。Task 1–7 可以按现规格执行；**Task 8–18 在项目
owner 对下表逐项给出显式批准之前全部暂停**。批准记录必须标识本计划路径与 commit，
并逐项写明接受或拒绝；沉默、开始编码或测试通过都不视为批准。唯一有效载体是下述
受版本控制的 approval artifact；聊天记录或 commit message 不能代替它。任一项被拒绝
时，先修订本计划和规格并重新评审，禁止让实现自行选择语义。

| 首次落地任务 | 相对当前规格的修订 | 批准后同步规格的位置 |
| --- | --- | --- |
| Task 8 | `rdma_submission_effect_e` 从二态 `enum bit` 改为四态 `enum logic`，所有持久/恢复证据在比较或索引前显式拒绝 X/Z。 | Task 8 的代码提交同步修改 §5.1。 |
| Task 9 | completion 追加且不重编号 `RDMA_CMQ_COMPLETION_UNOBSERVED`；execution result 增加独立、非空 `observation_status`；workflow/action/completion/submission/proof-state enum 与 action mask 使用四态并 fail-closed；冻结 current `attempt_effect` 与累计 `submission_effect`、`recovery_required` 生命周期表、journal-retained completion、batch/proof digest 与完整 recovery-owner 语义。 | Task 9 的 value-model 提交同步修改 §5.1、§5.2 及相关值表。 |
| Task 17 | reset 顺序改为 mutation-free candidate → 已验证 failure-atomic backing release → allocation-free/no-fail journal commit 并立即清旧 runtime/fence → 可选 reprepare → READY proof → owner confirmation；proof 只驻留 retained batch journal record，不建第二 authority registry；legacy sentinel 在 release commit 解决，concrete owner 等 permitted confirm。 | Task 17 的生命周期提交同步修改 §4.4.1、§5.2、§9 和 §10.2，并消除现有两处 fence-clear 时点冲突。 |
| Task 18 | production observed API 不读写共享 `last_*`，但 legacy production `execute()` 暂时继续维护 `last_execute_no_submit_proven`；只有 MR control-plane、queue lifecycle、QP lifecycle 三个 Phase 1B consumer 全部迁移后才删除该 seam。 | Task 18 的路由提交同步修改 §5.2、§7.6、§9 和 §10.2。 |

Approval artifact 固定为
`docs/superpowers/approvals/2026-09-11-rdma-cmq-contract-foundation-phase1a.env`，
使用严格 `KEY=VALUE`、无空行/注释、以下顺序和取值语法：

| Key | Required value |
| --- | --- |
| `APPROVAL_SCHEMA` | 精确 `1` |
| `PLAN_PATH` | 精确 `docs/superpowers/plans/2026-09-11-rdma-cmq-contract-foundation.md` |
| `PLAN_COMMIT` | 含本计划且只新增本计划文件的 40 位小写 Git commit；其 first parent 精确为 `cc07586` |
| `PLAN_BLOB_SHA256` | `PLAN_COMMIT:PLAN_PATH` 原始 blob 字节的 64 位小写 SHA-256 |
| `APPROVER_ID` | 匹配 `[A-Za-z0-9][A-Za-z0-9._@-]{0,63}` 的项目 owner 身份 |
| `APPROVED_AT_UTC` | 严格 UTC `YYYY-MM-DDTHH:MM:SSZ` |
| `TASK8_FOUR_STATE_EFFECT` | 精确 `APPROVED` |
| `TASK9_EXECUTION_AND_DIGEST` | 精确 `APPROVED` |
| `TASK17_RESET_ORDER` | 精确 `APPROVED` |
| `TASK18_LEGACY_SEAM` | 精确 `APPROVED` |

`python3 tools/check_rdma_phase1a_approval.py` fail-closed 验证：artifact 已 tracked
且相对 `HEAD` 无改动；key 集合/顺序/值严格匹配；`PLAN_COMMIT` 存在且是 `HEAD`
祖先；先将 `cc07586^{commit}` 解析为完整 40 位基线，再要求该 commit 的 first
parent 等于这个完整基线且 diff-tree 只有 `PLAN_PATH`；记录的
blob SHA-256 同时等于 `git show PLAN_COMMIT:PLAN_PATH` 和当前计划文件；四项 decision
全部为 `APPROVED`。Task 8–18 每个任务在自己的 Step 1 前都必须重新运行该命令，任何
缺失、未提交、plan drift、非祖先 commit 或 decision 不一致都立即停止且不得编译 SV。

这里的批准只授权上述冻结语义，不扩大本计划的代码范围。Task 8、9、17、18 各自在
首次实现对应语义的同一提交中更新规格，避免“实现已变、规格稍后补”的窗口；Task 16
依赖 Task 9/17 的 owner、digest 和 proof 语义，因此同样受本 gate 约束。当前计划文档的
提交本身不修改批准规格，也不代表上述修订已获批准。

## Scope and file ownership

| File or directory | Responsibility in this plan |
| --- | --- |
| `hw/rdma/archive_lock.env` | 锁定 driver archive identity，不重复字段坐标。 |
| `hw/rdma/c_oracle/` | 保存可在锁定归档上重建的 C probe 输入、bytes、field report 和 metadata。 |
| `hw/rdma/field_ownership.tsv` | 记录 source field 到 model consumer 的 ownership 关系，不手写坐标。 |
| `hw/rdma/field_exclusions.tsv` | 逐项记录经审阅但明确不进入首批 wire 范围的驱动字段及理由。 |
| `hw/rdma/cmq_capabilities.tsv` | 区分 registered、request encodable 和 response decodable。 |
| `hw/rdma/cmq_field_mutation.tsv` | 保存 C report + ownership checker 导出的逐 bit 动态或静态 closed-evidence 期望。 |
| `hw/rdma/external_dependencies.tsv` | 锁定已批准外部依赖；未批准依赖显式 fail-closed。 |
| `docs/superpowers/approvals/2026-09-11-rdma-cmq-contract-foundation-phase1a.env` | 将 Phase 1A 四项设计修订绑定到唯一计划 blob 和显式 owner 批准。 |
| `tools/rdma_driver_contract.py` | 提供 archive/source/oracle manifest 的严格 parser 与共享 hash helper。 |
| `tools/verify_rdma_archive.py` | 验证 archive 后安全解包并输出唯一 kernel root。 |
| `tools/verify_rdma_cmq_oracle.py` | 在临时目录重编译 C probe并比较 immutable artifacts。 |
| `tools/check_rdma_field_ownership.py` | 从锁定 C source 推导坐标、验证 consumer/capability 并重建 mutation report。 |
| `tools/check_external_dependency_lock.py` | 采集并验证外部只读依赖的 commit 与被消费文件 hash。 |
| `tools/check_changed_sv_style.py` | 只检查本次新增/修改 SV 行的注释邻接和稀疏排版。 |
| `tools/check_rdma_phase1a_approval.py` | 在任何 Phase 1A 编译前验证已提交 approval artifact、计划 ancestry/blob 和四项 decision。 |
| `sim/cmq_gate.list` | 保存 CMQ 专用 UVM gate 的精确测试集合与顺序。 |
| `src/model/rdma_submission_evidence.sv` | 定义唯一跨 engine 共享的 submission-effect 词汇。 |
| `src/model/rdma_cmq_execution_models.sv` | 定义 CMQ execution result、journal snapshot 与 recovery request 值对象。 |
| `src/model/rdma_function_binding.sv` | 提供不经 UVM factory/clone 的 status-returning identity/binding 完整快照，供 journal 与 digest 使用。 |
| `src/core/rdma_doorbell_scheduler.sv` | 产生 per-call effect，并在 MMIO 前调用 nullable observer。 |
| `src/core/rdma_cmq_transport.sv` | 不拥有状态的 observed scheduler 转发 facade。 |
| `src/core/rdma_cmq_engine.sv` | 1A journal/fence/retry/timeout/reset 的唯一可变 owner。 |
| `src/core/rdma_cmq_port.sv` | legacy port 到 observed result 的保守单向 fallback。 |
| `src/core/rdma_cmq_engine_port_adapter.sv` | production observed 路由与 legacy output 投影。 |

## Pre-execution evidence checkpoint

在隔离 worktree 建立后，先在 53 上重复以下只读命令；输出必须与 Global Constraints 的 archive/compiler 值逐项相同。该步骤不生成或提交文件：

```bash
archive='/home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz'
sha256sum "$archive"
stat -c '%s' "$archive"
tar -tzf "$archive" | LC_ALL=C sort | sha256sum
tar -tzf "$archive" | awk -F/ 'NF {print $1}' | LC_ALL=C sort -u
command -v gcc
sha256sum /usr/bin/gcc
gcc --version | sed -n '1p'
gcc -dumpmachine
getconf LONG_BIT
python3 -c 'import sys; print(sys.byteorder)'
```

任何值变化都停止执行并另开 archive/toolchain baseline 评审；不得自动更新 lock 或 artifacts。

---

## Phase 0 — Restore trustworthy gates

### Task 1: Lock and verify the RDMA driver archive

**Files:**

- Create: `hw/rdma/archive_lock.env`
- Create: `tools/rdma_driver_contract.py`
- Create: `tools/verify_rdma_archive.py`
- Create: `tests/unit/test_verify_rdma_archive.py`
- Modify: `sim/Makefile`
- Modify: `tests/unit/test_check_rdma_profile_names.py`

**Interfaces:**

- Produces immutable `ArchiveLock` and `SourceManifestRecord` values.
- Produces a verifier CLI that prints exactly one already-verified kernel root on stdout.
- `sim/Makefile` consumes the verifier output; it no longer unpacks an unverified archive itself.

`hw/rdma/archive_lock.env` contains exactly:

```text
RDMA_ARCHIVE_ID=rdma-driver-0.1.34
RDMA_ARCHIVE_SHA256=c9d9286dde389f681f9bd1c29fff14f52c4c1ce11fa5f73a5f1f57da9f827522
RDMA_ARCHIVE_SIZE_BYTES=289668
RDMA_ARCHIVE_PREFIX=dpu_kernel_rdma-version_0.1.34
RDMA_ARCHIVE_MEMBER_LIST_SHA256=d27331088fff104e4f101357a7b0b490b1d33e66396cb060ec421cc94ab68797
RDMA_ARCHIVE_MEMBER_COUNT=74
```

The shared parser exposes these exact Python values and implementations; the
archive verifier adds extraction policy on top of these side-effect-free
parsers:

```python
from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path, PurePosixPath
import re


class ContractError(RuntimeError):
    """受版本控制的驱动契约输入无效或彼此不一致。"""


@dataclass(frozen=True)
class ArchiveLock:
    archive_id: str
    sha256: str
    size_bytes: int
    prefix: str
    member_list_sha256: str
    member_count: int


@dataclass(frozen=True)
class SourceManifestRecord:
    archive_id: str
    path: str
    selector: str
    sha256: str


_ARCHIVE_KEYS = {
    "RDMA_ARCHIVE_ID",
    "RDMA_ARCHIVE_SHA256",
    "RDMA_ARCHIVE_SIZE_BYTES",
    "RDMA_ARCHIVE_PREFIX",
    "RDMA_ARCHIVE_MEMBER_LIST_SHA256",
    "RDMA_ARCHIVE_MEMBER_COUNT",
}
_LOWER_SHA256 = re.compile(r"[0-9a-f]{64}")


def _load_exact_env(path: Path, expected_keys: set[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.count("=") != 1:
            raise ContractError(f"{path}:{line_number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        if key not in expected_keys:
            raise ContractError(f"{path}:{line_number}: unknown key {key}")
        if key in values:
            raise ContractError(f"{path}:{line_number}: duplicate key {key}")
        if not value:
            raise ContractError(f"{path}:{line_number}: empty value for {key}")
        values[key] = value

    missing = expected_keys - values.keys()
    if missing:
        raise ContractError(f"{path}: missing keys {sorted(missing)}")
    return values


def _require_lower_sha256(label: str, value: str) -> str:
    if _LOWER_SHA256.fullmatch(value) is None:
        raise ContractError(f"{label} must be 64 lowercase hex digits")
    return value


def _require_positive_decimal(label: str, value: str) -> int:
    if re.fullmatch(r"[1-9][0-9]*", value) is None:
        raise ContractError(f"{label} must be a positive decimal integer")
    return int(value, 10)


def _require_relative_member_path(label: str, value: str) -> str:
    pure_path = PurePosixPath(value)
    raw_parts = value.split("/")
    if pure_path.is_absolute() or value in {"", "."}:
        raise ContractError(f"{label} must be a non-empty relative path")
    if "\\" in value or "\x00" in value:
        raise ContractError(f"{label} contains a non-POSIX separator/control")
    if any(part in {"", ".", ".."} for part in raw_parts):
        raise ContractError(f"{label} contains an unsafe path component")
    return value


def load_archive_lock(path: Path) -> ArchiveLock:
    values = _load_exact_env(path, _ARCHIVE_KEYS)
    prefix = _require_relative_member_path(
        "RDMA_ARCHIVE_PREFIX", values["RDMA_ARCHIVE_PREFIX"]
    )
    if "/" in prefix:
        raise ContractError("RDMA_ARCHIVE_PREFIX must be one top-level name")

    return ArchiveLock(
        archive_id=values["RDMA_ARCHIVE_ID"],
        sha256=_require_lower_sha256(
            "RDMA_ARCHIVE_SHA256", values["RDMA_ARCHIVE_SHA256"]
        ),
        size_bytes=_require_positive_decimal(
            "RDMA_ARCHIVE_SIZE_BYTES", values["RDMA_ARCHIVE_SIZE_BYTES"]
        ),
        prefix=prefix,
        member_list_sha256=_require_lower_sha256(
            "RDMA_ARCHIVE_MEMBER_LIST_SHA256",
            values["RDMA_ARCHIVE_MEMBER_LIST_SHA256"],
        ),
        member_count=_require_positive_decimal(
            "RDMA_ARCHIVE_MEMBER_COUNT", values["RDMA_ARCHIVE_MEMBER_COUNT"]
        ),
    )


def load_source_manifest(path: Path) -> list[SourceManifestRecord]:
    records: list[SourceManifestRecord] = []
    identities: set[tuple[str, str, str]] = set()

    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        columns = line.split()
        if len(columns) != 4:
            raise ContractError(f"{path}:{line_number}: expected four columns")

        archive_id, relative_path, selector, digest = columns
        relative_path = _require_relative_member_path(
            f"{path}:{line_number}: source path", relative_path
        )
        digest = _require_lower_sha256(
            f"{path}:{line_number}: source sha256", digest
        )
        if not archive_id or not selector:
            raise ContractError(
                f"{path}:{line_number}: archive ID and selector are required"
            )

        identity = (archive_id, relative_path, selector)
        if identity in identities:
            raise ContractError(f"{path}:{line_number}: duplicate manifest row")
        identities.add(identity)
        records.append(
            SourceManifestRecord(
                archive_id=archive_id,
                path=relative_path,
                selector=selector,
                sha256=digest,
            )
        )

    if not records:
        raise ContractError(f"{path}: source manifest has no records")
    return records


def canonical_member_list_digest(member_names: list[str]) -> str:
    if not member_names:
        raise ContractError("archive member list is empty")
    if len(member_names) != len(set(member_names)):
        raise ContractError("archive member list contains duplicate entries")

    payload = "\n".join(
        sorted(member_names, key=lambda name: name.encode("utf-8"))
    ) + "\n"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()
```

The `member_names` argument uses GNU `tar -tzf` spelling: regular files have
their exact POSIX member name, while every directory has exactly one trailing
`/`. `TarInfo.name` on Python 3.8 removes that slash, so the verifier must form
`member.name + "/"` for `member.isdir()` before computing the digest. This
reconstructs the frozen `d273...` value; hashing raw `TarInfo.name` would
incorrectly produce a different identity.

- [ ] **Step 1: Write archive-verifier failure tests**

  In `test_verify_rdma_archive.py`, build small temporary tar archives and add
  named tests for a valid archive, wrong SHA, wrong size, wrong prefix, two
  top-level directories, member-list drift, wrong member count, duplicate
  member name, missing manifest member, absolute member path, `..` traversal,
  empty/`.` path components, backslashes, all symbolic/hard links (including a
  link declared before its target), FIFO/device members, and extraction failure
  atomicity. The locked archive contains only 66 regular files and eight
  directories, so links are unnecessary input rather than a compatibility
  requirement.

  The valid fixture must use the same canonicalization as production:

  ```python
  if len(member_names) != len(set(member_names)):
      raise AssertionError("fixture member names must be unique")
  payload = "\n".join(
      sorted(member_names, key=lambda name: name.encode("utf-8"))
  ) + "\n"
  expected_digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
  ```

- [ ] **Step 2: Run the focused RED test**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_verify_rdma_archive -v
  ```

  Expected: FAIL because `tools.rdma_driver_contract` and `tools/verify_rdma_archive.py` do not exist.

- [ ] **Step 3: Implement the strict parser and archive checks**

  Copy the complete parser bodies from **Interfaces** into
  `rdma_driver_contract.py`. In `verify_rdma_archive.py`, open the archive with
  `tarfile.open(..., mode="r:gz")`, reject duplicate names, raw path components
  outside the strict parser rule, and every member other than a regular file or
  directory. Before extraction, compare the archive byte hash/size, exact
  member count, the canonical GNU-tar spelling
  (`member.name + "/"` for directories) through
  `canonical_member_list_digest()`, the single top-level component, and every
  `f"{lock.prefix}/{record.path}"` required by the source manifest.

  Python on host 53 is 3.8.10, so do not use the newer `tarfile` extraction
  filter API and do not call `extractall()`. Create a private staging directory
  under the explicit extraction root, create validated directories with
  `mkdir(parents=True)`, and copy each validated regular member from
  `extractfile()` to an exclusive `open("xb")` destination. Resolve/check every
  parent against the staging root immediately before opening. On any exception,
  delete only that private staging directory. After all bytes and required
  source hashes succeed, atomically rename the staged prefix to the previously
  absent final prefix and print its resolved path exactly once.

- [ ] **Step 4: Route `rdma_defs` through the verified root**

  Keep the restricted `/tmp/rdma_profile_ref.XXXXXX` cleanup in `sim/Makefile`, but replace direct `tar`/`unzip` extraction with:

  ```make
	kernel_root=$$(python3 ../tools/verify_rdma_archive.py \
		--archive "$(RDMA_ARCHIVE)" \
		--lock ../hw/rdma/archive_lock.env \
		--source-manifest ../hw/rdma/source_manifest.txt \
		--extract-dir "$$ref_dir" \
		--print-kernel-root); \
	python3 ../tools/check_rdma_profile_names.py --kernel-root "$$kernel_root"
  ```

  Do not duplicate archive SHA, size, prefix or member-list hash in the Makefile.

- [ ] **Step 5: Run GREEN tests**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_verify_rdma_archive -v
  python3 -m unittest tests.unit.test_check_rdma_profile_names.MakefileCleanupTest -v
  ```

  Expected: PASS; command failure status is preserved, and cleanup failure remains visible.

- [ ] **Step 6: Commit the archive gate**

  ```bash
  git add hw/rdma/archive_lock.env tools/rdma_driver_contract.py \
    tools/verify_rdma_archive.py tests/unit/test_verify_rdma_archive.py \
    sim/Makefile tests/unit/test_check_rdma_profile_names.py
  git commit -m "test: lock and verify RDMA driver archive"
  ```

### Task 2: Make the source manifest the frozen ABI authority

**Files:**

- Modify: `tools/check_rdma_profile_names.py`
- Modify: `tools/rdma_driver_contract.py`
- Modify: `hw/rdma/source_manifest.txt`
- Modify: `tests/unit/test_check_rdma_profile_names.py`
- Modify: `sim/Makefile`

**Interfaces:**

- Consumes Task 1 `ArchiveLock` and `SourceManifestRecord`.
- Preserves profile-only mode when `--kernel-root` is absent.
- Frozen-source mode requires all three of `--kernel-root`, `--archive-lock` and `--source-manifest`.

The source manifest keeps its four data columns and changes only its schema comment:

```text
# archive_identifier path selector sha256
```

- [ ] **Step 1: Write failing source-identity tests**

  Add a temporary kernel root whose locked source bytes match the fixture but whose `.git/HEAD` contains an unrelated valid Git SHA. Assert frozen-source validation succeeds. Add separate failures for source digest drift, selector mismatch, archive identifier mismatch and missing source.

- [ ] **Step 2: Run the source-identity RED test**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_check_rdma_profile_names \
    -k 'git_head or source_manifest or archive_lock' -v
  ```

  Expected: FAIL because the current checker compares an extracted tree to the non-commit string `rdma-driver-0.1.34` and still trusts built-in source hashes.

- [ ] **Step 3: Remove Git HEAD and duplicated hashes from ABI identity**

  Delete `FIXED_COMMIT`, `validate_git_head()`, built-in `SOURCE_HASHES`, and `validate_source_hash_contract()` as identity authorities. Parse records through `load_source_manifest()` and enforce:

  ```python
  if record.archive_id != archive_lock.archive_id:
      raise ContractError("source manifest archive identifier mismatch")
  if sha256_file(kernel_root / record.path) != record.sha256:
      raise ContractError(f"source digest mismatch: {record.path}")
  if not selector_matches(source_text, record.selector):
      raise ContractError(
          f"source selector matches no locked symbol/text: {record.path}"
      )
  ```

  `selector_matches()` keeps the existing manifest grammar: split `|` into
  alternatives, use `fnmatch.fnmatchcase()` for `*` macro families, recognize
  enum tags/functions as tokens, and use an exact escaped text search for a
  non-glob descriptive selector. A selector is a coverage expression, not a
  literal substring and not a uniqueness anchor; uniqueness belongs to the
  manifest `(archive_id, path, selector)` row and to Task 3/4 source anchors.
  Require at least one alternative to match, require every row for the same
  path to carry the same digest, and keep required path/selector coverage as a
  second check. Never duplicate source digests in Python constants.

- [ ] **Step 4: Give the `rdma_defs` test name real semantics**

  Add this guard before the recipe performs any archive work:

  ```make
	@if [[ "$(TEST)" != "rdma_cmq_driver_contract_test" ]]; then \
		echo "rdma_defs requires TEST=rdma_cmq_driver_contract_test" >&2; \
		exit 2; \
	fi
  ```

  Pass both manifests to the checker:

  ```make
	python3 ../tools/check_rdma_profile_names.py \
		--kernel-root "$$kernel_root" \
		--archive-lock ../hw/rdma/archive_lock.env \
		--source-manifest ../hw/rdma/source_manifest.txt
  ```

- [ ] **Step 5: Run GREEN tests**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_check_rdma_profile_names -v
  python3 tools/check_rdma_profile_names.py
  ```

  Expected: PASS; profile-only mode prints `rdma profile naming: PASS`, unrelated Git metadata has no effect, and every archive/source/selector drift fails frozen-source mode.

- [ ] **Step 6: Commit the source-identity correction**

  ```bash
  git add tools/check_rdma_profile_names.py tools/rdma_driver_contract.py \
    hw/rdma/source_manifest.txt tests/unit/test_check_rdma_profile_names.py \
    sim/Makefile
  git commit -m "fix: derive frozen RDMA ABI from source manifest"
  ```

### Task 3: Add a rebuildable C oracle and immutable canonical artifacts

**Files:**

- Create: `hw/rdma/c_oracle/rdma_cmq_oracle.c`
- Create: `hw/rdma/c_oracle/cmq_oracle_cases.tsv`
- Create: `hw/rdma/c_oracle/cmq_oracle_source_anchors.tsv`
- Create: `hw/rdma/c_oracle/cases/cmq_sqe_qpc_create_request.input.tsv`
- Create: `hw/rdma/c_oracle/cases/cmq_sqe_qpc_create_request.bytes.hex`
- Create: `hw/rdma/c_oracle/cases/cmq_sqe_qpc_create_request.fields.tsv`
- Create: `hw/rdma/c_oracle/cases/cmq_sqe_qpc_create_request.metadata.env`
- Create: `hw/rdma/c_oracle/cases/cmq_sqe_cqc_create_request.input.tsv`
- Create: `hw/rdma/c_oracle/cases/cmq_sqe_cqc_create_request.bytes.hex`
- Create: `hw/rdma/c_oracle/cases/cmq_sqe_cqc_create_request.fields.tsv`
- Create: `hw/rdma/c_oracle/cases/cmq_sqe_cqc_create_request.metadata.env`
- Create: `hw/rdma/c_oracle/cases/cmq_cqe_qpc_create_response.input.tsv`
- Create: `hw/rdma/c_oracle/cases/cmq_cqe_qpc_create_response.bytes.hex`
- Create: `hw/rdma/c_oracle/cases/cmq_cqe_qpc_create_response.fields.tsv`
- Create: `hw/rdma/c_oracle/cases/cmq_cqe_qpc_create_response.metadata.env`
- Create: `hw/rdma/c_oracle/cases/cmq_sq_doorbell.input.tsv`
- Create: `hw/rdma/c_oracle/cases/cmq_sq_doorbell.bytes.hex`
- Create: `hw/rdma/c_oracle/cases/cmq_sq_doorbell.fields.tsv`
- Create: `hw/rdma/c_oracle/cases/cmq_sq_doorbell.metadata.env`
- Create: `tools/verify_rdma_cmq_oracle.py`
- Create: `tests/support/capture_rdma_cmq_oracle_candidate.sh`
- Create: `tests/unit/test_verify_rdma_cmq_oracle.py`
- Modify: `hw/rdma/source_manifest.txt`
- Modify: `sim/Makefile`

**Interfaces:**

- Consumes Task 1 verified kernel root and Task 2 manifest records.
- The probe includes the locked driver `cmq.h`; where a static kernel builder cannot be linked, it uses the original driver macros/structs and a unique `cmq.c` data-flow anchor.
- Normal verification has no update/record option: it recompiles in a temporary directory and compares stdout-derived bytes/fields with committed artifacts.
- The maintainer capture helper accepts the explicit `--archive`, `--archive-lock`,
  `--source-manifest`, `--source-anchors`, `--cases`, `--oracle-source`,
  `--output-dir` and `--cc` arguments shown in Step 5; it rejects omitted,
  duplicated or worktree-local output paths and prints the candidate directory
  plus every generated hash.

`cmq_oracle_source_anchors.tsv` records every semantic source hop rather than
pretending one case has only one source. It includes the request preparation,
builder, endian load/store, checksum, completion readiness/validation and MMIO
write helpers used by the four cases. Its exact schema is:

```text
case_id	role	source_path	source_function	anchor_token	token_occurrence	buffer_expression	operation	target_flow
```

`role` accepts only `PREPARE`, `BUILD`, `STORE`, `CHECKSUM`, `READY`,
`LOOKUP`, `PARSE`, `VALIDATE_WRAP`, `VALIDATE_OPCODE`, `VALIDATE_ECODE`,
`LOAD`, `POST` and `WRITE`; the verifier requires the exact per-case dependency
order shown below and rejects a missing, duplicate or extra hop. The order is a
call-graph order, not a claim that a nested helper executes after its caller:
the CQE `LOAD` row is the `rdma_type.h:get_64bit_val` helper invoked by the
`PARSE` row, so it deliberately follows that outer call in the table while
remaining before the three validation branches in the driver's execution.

The QPC request has a `PREPARE` row for
`qp.c:xtrdma_hw_create_qp` anchored at the sole assignment to
`create_qp_info.qpc_buffer_addr_pa`, plus a `BUILD` row for
`cmq.c:xtrdma_sc_qp_create`. The CQC request has a `PREPARE` row for
`cq.c:xtrdma_hw_create_cq` and a `BUILD` row for
`cmq.c:xtrdma_sc_cq_create`; its `memcpy(wqe + 1, ..., 56)` operation must be
the unique BUILD anchor. The CQE case separately records owner readiness,
big-endian load, common-field extraction and the wrap/opcode/ecode validation
branches. The doorbell case records both value construction and the final
big-endian MMIO write helper. The verifier resolves every path through the
source manifest, requires each function/token occurrence to be unique after
comment stripping, and includes the ordered anchor rows and all participating
source hashes in `RDMA_SOURCE_CLOSURE_SHA256`.

Use these exact normalized anchors; `token_occurrence=1` is counted inside the
named function after comment stripping, not across the whole file:

```text
cmq_sqe_qpc_create_request	PREPARE	qp.c	xtrdma_hw_create_qp	create_qp_info.qpc_buffer_addr_pa = xtqp->cmdq_qpc_buf.iova >> XTRDMA_ADDR_512_BYTE_SHIFT;	1	create_qp_info.qpc_buffer_addr_pa	ASSIGN_SHIFT_RIGHT	xtqp->cmdq_qpc_buf.iova -> create_qp_info.qpc_buffer_addr_pa -> cmq_request->req_param
cmq_sqe_qpc_create_request	BUILD	cmq.c	xtrdma_sc_qp_create	set_64bit_val(wqe, 24, FIELD_PREP(XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR, info->qpc_buffer_addr_pa));	1	wqe	SET_64BIT_FIELD_PREP	info->qpn/sq_cqn/rq_cqn/qpc_buffer_addr_{pa,va} -> hdr/sign_data/signature -> wqe[0,8,24]
cmq_sqe_qpc_create_request	STORE	defs.h	set_64bit_val	wqe_words[byte_index >> 3] = cpu_to_be64(val);	1	wqe_words	CPU_TO_BE64_STORE	val -> cpu_to_be64 -> wqe_words[byte_index >> 3]
cmq_sqe_qpc_create_request	CHECKSUM	defs.h	xtrdma_bytes_xor	acc ^= get_unaligned((u64 *)ptr);	1	ptr	XOR_U64_REMAINDER_FOLD	hdr/wqe/qpc bytes -> acc -> folded u8 -> complemented signature
cmq_sqe_cqc_create_request	PREPARE	cq.c	xtrdma_hw_create_cq	cmq_request->req_param = (void *)&xt_cq->cq_ctx;	1	cmq_request->req_param	ASSIGN_ADDRESS	xt_cq->cq_ctx -> cmq_request->req_param -> cq_ctx->ctx_addr.va
cmq_sqe_cqc_create_request	BUILD	cmq.c	xtrdma_sc_cq_create	memcpy(wqe + 1, cq_ctx->ctx_addr.va, 56);	1	wqe + 1	MEMCPY	cq_ctx->ctx_addr.va[0:56] -> wqe[8:64]
cmq_sqe_cqc_create_request	STORE	defs.h	set_64bit_val	wqe_words[byte_index >> 3] = cpu_to_be64(val);	1	wqe_words	CPU_TO_BE64_STORE	hdr -> cpu_to_be64 -> wqe[0]
cmq_cqe_qpc_create_response	READY	cmq.c	xtrdma_sc_cmq_next_cqe_valid	get_64bit_val(cqe, 0, &temp1);	1	cqe	GET_64BIT_FIELD_GET	cq_base[CI].elem -> temp1 -> polarity -> cq_polarity -> ready/not-ready
cmq_cqe_qpc_create_response	LOOKUP	cmq.c	xtrdma_sc_cmq_next_cqe_valid	*cmq_request = (struct xtrdma_cmq_request *)sc_cmq->request_array[wqe_idx];	1	sc_cmq->request_array	INDEX_LOOKUP	cqe.index -> request_array[wqe_idx] -> cmq_request
cmq_cqe_qpc_create_response	PARSE	cmq.c	xtrdma_get_cqe_common_info	get_64bit_val(*cqe, 0, &temp);	1	*cqe	GET_64BIT	(sc_cmq->cq_base[CI].elem -> *cqe -> temp) -> FIELD_GET(opcode,ecode,wrap,index)
cmq_cqe_qpc_create_response	LOAD	rdma_type.h	get_64bit_val	*val = be64_to_cpu(wqe_words[byte_index >> 3]);	1	wqe_words	BE64_TO_CPU_LOAD	wqe_words[byte_index >> 3] -> be64_to_cpu -> val
cmq_cqe_qpc_create_response	VALIDATE_WRAP	cmq.c	xtrdma_get_cqe_common_info	cq_wqe_wrap != sq_wqe_wrap	1	status	COMPARE_WRAP	cqe.wrap/sqe.wrap -> status/request_error
cmq_cqe_qpc_create_response	VALIDATE_OPCODE	cmq.c	xtrdma_get_cqe_common_info	opcode != cmq_request->cmq_cmd	1	status	COMPARE_OPCODE	cqe.opcode/request.opcode -> status/request_error
cmq_cqe_qpc_create_response	VALIDATE_ECODE	cmq.c	xtrdma_get_cqe_common_info	ecode != 0	1	status	COMPARE_ECODE	cqe.ecode -> status/request_error
cmq_sq_doorbell	POST	cmq.c	xtrdma_sc_cmq_post_sq	cmq_db = FIELD_PREP(XTRDMA_CMQSQ_DB_PI, XTRDMA_RING_CURRENT_PI(sc_cmq->sq_ring)) |	1	cmq_db	FIELD_PREP_OR	sc_cmq->sq_ring/sq_polarity -> cmq_db -> xtrdma_iowrite64be
cmq_sq_doorbell	WRITE	rdma_main.h	xtrdma_iowrite64be	iowrite64be(val, db_addr);	1	db_addr	IOWRITE64BE	cmq_db -> iowrite64be -> CMQ doorbell MMIO bytes
```

Extend `source_manifest.txt` so the `cmq.h` enum coverage explicitly includes
`TRDMA_OP_SRFQC_MODIFY` in addition to the enum-tag row, and so this closure
also locks `qp.c` selector
`xtrdma_hw_create_qp`, `cq.c` selector `xtrdma_hw_create_cq`, and `cmq.c`
selectors
`xtrdma_sc_qp_create|xtrdma_sc_cq_create|xtrdma_sc_cmq_next_cqe_valid|xtrdma_get_cqe_common_info|xtrdma_sc_cmq_post_sq`.
Also add `osdep.h` selector `XTRDMA_64BIT_TO_BYTE`, `defs.h` selectors
`set_64bit_val|xtrdma_bytes_xor`, `rdma_main.h` selector
`xtrdma_iowrite64be`, `debugfs.h` selector
`XTRDMA_OCC_QPC_SIZE`, `cmq.h` selectors
`XTRDMA_CMQ_SQ_WQE_CARRIED_SD_NUM|XTRDMA_CMQ_EVENT_QUEUE_CTX_INFO_SIZE_IN_DWORD|XTRDMA_CMQ_SRFQ_CTX_INFO_SIZE_IN_DWORD`,
and `rdma_type.h` selectors `xtrdma_sc_cmq|XTRDMA_RING_*|get_64bit_val`.
The QPC closure continues to include `qp.h:XTRDMA_ADDR_512_BYTE_SHIFT`.
These rows are verified by Task 2 before the probe compiles; the inline shim
may substitute their user-space compile form but may not become their source
authority.

`cmq_oracle_cases.tsv` has this exact header and four rows:

```text
case_id	entry	opcode	direction	source_path	source_function	total_bytes	c_type_alignment	image_required_alignment	endian	embed_base
cmq_sqe_qpc_create_request	CMQ_SQE	QPC_CREATE	REQUEST	cmq.c	xtrdma_sc_qp_create	64	8	64	big	0
cmq_sqe_cqc_create_request	CMQ_SQE	CQC_CREATE	REQUEST	cmq.c	xtrdma_sc_cq_create	64	8	64	big	8
cmq_cqe_qpc_create_response	CMQ_CQE	QPC_CREATE	RESPONSE	cmq.c	xtrdma_get_cqe_common_info	64	8	64	big	0
cmq_sq_doorbell	CMQ_SQ_DOORBELL	CMQ_SQ	REQUEST	cmq.c	xtrdma_sc_cmq_post_sq	8	8	8	big	0
```

Each metadata file has exactly these keys; their digest values are captured from the files generated in this task and are never copied from Python/SV golden tables:

```text
RDMA_ARCHIVE_SHA256
RDMA_SOURCE_CLOSURE_SHA256
RDMA_ARCHIVE_PREFIX
RDMA_PRIMARY_SOURCE_ANCHOR
RDMA_SOURCE_ANCHORS_SHA256
RDMA_PROBE_SOURCE_SHA256
RDMA_COMPILER_PATH
RDMA_COMPILER_SHA256
RDMA_COMPILER_VERSION
RDMA_COMPILER_TARGET
RDMA_TARGET_ENDIAN
RDMA_TARGET_BITS
RDMA_COMPILER_FLAGS
RDMA_INPUT_SHA256
RDMA_BYTES_SHA256
RDMA_FIELDS_SHA256
```

`RDMA_PRIMARY_SOURCE_ANCHOR` is the case-manifest
`source_path:source_function`. For one case, canonical anchor bytes are each
selected nine-column row joined by one tab and terminated by LF, in the exact
role order above; `RDMA_SOURCE_ANCHORS_SHA256` hashes their concatenation.
`RDMA_SOURCE_CLOSURE_SHA256` hashes this exact UTF-8 payload:

```text
anchors=<RDMA_SOURCE_ANCHORS_SHA256>\n
<source_path>\0<lowercase_source_sha256>\n
...
```

In this notation `\n` is one LF byte and `\0` is one NUL byte; they are not
literal two-character escape sequences. The source rows are unique by path and
sorted by UTF-8 bytes. The verifier rebuilds all three values from the
explicitly supplied manifest and anchor table; metadata never chooses its own
source paths.

The compiler identity fields are fixed to the values in Global Constraints. The normalized flags are:

```text
-std=gnu11 -O2 -Wall -Wextra -Werror -fno-common -fno-strict-aliasing
```

- [ ] **Step 1: Write failing oracle-verifier tests**

  Use a temporary minimal C fixture to cover missing compiler, compiler
  SHA/version/target mismatch, compiler diagnostics, `_Static_assert` failure,
  byte drift, field-report drift, source-closure/probe/input digest drift,
  missing/reordered helper or behavior anchor, anchor path absent from the
  source manifest, a CQE fixture rejected by owner/wrap/opcode/ecode checks, an
  unreachable ring-head/polarity tuple, missing artifact, and an attempted
  unrecognized `--update` option.

  The diagnostic test invokes a fixture compiler wrapper that emits
  `synthetic compiler warning` on stderr and then exits zero; expect the
  verifier to reject non-empty compiler stderr independently of `-Werror`.
  A separate real-GCC fixture compiles this source with the fixed warning
  flags and expects GCC itself to exit nonzero:

  ```c
  int main(void)
  {
      int unused_value = 7;
      return 0;
  }
  ```

- [ ] **Step 2: Run the oracle RED test**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_verify_rdma_cmq_oracle -v
  ```

  Expected: FAIL because the probe, case manifest and verifier do not exist.

- [ ] **Step 3: Implement the minimal driver-bound probe**

  Compile `rdma_cmq_oracle.c` against the verified kernel root. Do not compile
  or extract a private copy of `cmq.c`, `qp.c` or `cq.c`: on 53 the original
  translation unit requires unavailable kernel `linux/io.h`, while an extracted
  static builder would become an unlocked second implementation. Instead place
  one `oracle_kernel_compat` preamble in the probe itself, before the original
  `<cmq.h>` include, so `RDMA_PROBE_SOURCE_SHA256` covers the entire shim:

  ```c
  #include <stdint.h>
  #include <stdbool.h>
  #include <stddef.h>
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>

  #define __OSDEP_H
  #define __DEBUGFS_H
  /* generic user-space kernel compatibility declarations only */

  #include <cmq.h>
  ```

  The preamble defines `u8/u16/u32/u64`, `__be64`, `dma_addr_t`, `bool`,
  `__iomem`, `__packed`; minimal dummy `xtrdma_dma_mem`, `list_head`,
  `refcount_t`, `wait_queue_head_t`, `spinlock_t`, `xtrdma_ring`,
  `xtrdma_sc_cmq`, and forward declarations for `xtrdma_sc_dev` and
  `xtrdma_cmq_quanta`. It supplies generic parameterized `BIT`, `BIT_ULL`,
  `GENMASK`, `GENMASK_ULL`, `FIELD_PREP`, `FIELD_GET`, endian conversions,
  `set_64bit_val`, `get_64bit_val` and byte-XOR helpers. It may repeat only the
  four compile constants locked by the new manifest rows; it must contain no
  `XTRDMA_CMQ*` field mask or opcode value.

  Build with this exact argv after substituting absolute verified paths:

  ```bash
  /usr/bin/gcc \
    -std=gnu11 -O2 -Wall -Wextra -Werror -fno-common \
    -fno-strict-aliasing \
    -I "$kernel_root" \
    "$repo_root/hw/rdma/c_oracle/rdma_cmq_oracle.c" \
    -o "$build_dir/rdma_cmq_oracle"
  ```

  The source must contain these hard assertions and must terminate nonzero on
  an unknown case or malformed input:

  ```c
  _Static_assert(sizeof(struct xtrdma_cmq_sq_wqe) == 64,
                 "CMQ SQE must remain 64 bytes");
  _Static_assert(sizeof(struct xtrdma_cmq_cq_wqe) == 64,
                 "CMQ CQE must remain 64 bytes");
  _Static_assert(_Alignof(struct xtrdma_cmq_sq_wqe) == 8,
                 "CMQ SQE alignment changed");
  _Static_assert(_Alignof(struct xtrdma_cmq_cq_wqe) == 8,
                 "CMQ CQE alignment changed");
  ```

  `c_type_alignment` is the C ABI result above. It is deliberately distinct
  from `image_required_alignment`: the existing SV CMQ SQE/CQE metadata
  contract requires 64-byte image alignment, while the 8-byte doorbell image
  requires 8. Oracle verification checks the first value; the UVM contract
  reader checks the second. Neither value may be substituted for the other.

  Use asymmetric inputs. QPC create uses WQE index `0x15`, builder polarity
  `1`, QPN `0x00a1b2c3`, SQ CQN `0x155555`, RQ CQN `0x0a3c5d`, raw QPC IOVA
  `0x0123456789abc000`, shifted builder address
  `0x000091a2b3c4d5e0`, and a 512-byte pattern
  `(index * 37 + 0x5b) & 0xff`. CQC create uses WQE index `0x12`, builder
  polarity `1`, CQN `0x15a5a5`, and a 56-byte context pattern
  `(index * 29 + 0x31) & 0xff`. The CQE is a complete driver-accepted success
  fixture: `cq_polarity=1`, owner/valid `1`, index `0x13`, wrap `0`,
  QPC_CREATE opcode, ecode `0`, zero VF fields, and a matching synthetic SQE
  header with index `0x13`, wrap `0` and QPC_CREATE opcode. The doorbell input
  records monotonic `head_before=0x36`, derived PI-before `0x16`,
  `ring_size=32` and `sq_polarity_before=0`; after the driver's `MOVE_PI`
  transition the monotonic head is `0x37`, reported PI is `0x17`, and encoded
  wire polarity is `1`. This is the reachable second-cycle state, not an
  impossible first-cycle polarity combination.

  Reproduce only the anchored operations using original driver macros. QPC
  follows `xtrdma_sc_qp_create` write order, including the shifted IOVA,
  big-endian stores and the complete 512-byte XOR/fold signature algorithm;
  CQC performs the anchored `memcpy(wqe + 1, ..., 56)` before writing its
  common header. CQE input is built from original public-header macros, then
  runs the anchored owner readiness, big-endian load and wrap/opcode/ecode
  validation rules against the matching SQE/request fixture. Doorbell performs
  the anchored monotonic-head PI/polarity transition and big-endian write-byte
  projection without issuing real MMIO. The QPC/CQE cases report every public
  header field; the CQE case also reports driver readiness, common status class
  and `request_error`. The CQC case additionally reports
  `payload_source_byte=0`, `payload_target_byte=8` and `payload_length=56`.
  The doorbell reports PI and polarity from `XTRDMA_CMQSQ_DB_PI` and
  `XTRDMA_CMQSQ_DB_POL`.

- [ ] **Step 4: Implement immutable rebuild/compare verification**

  The verifier must check the exact compiler realpath, binary SHA, first version line, target, target bits, endian and normalized flags before running it. It creates a private temporary build directory, builds with `-Werror`, executes all four cases, canonicalizes lowercase two-digit bytes separated by one space and TSV fields sorted by `(byte_offset, lsb, name)`, then compares those results byte-for-byte with committed artifacts. It only writes under its private temporary directory.

- [ ] **Step 5: Capture and review the four artifacts once**

  On 53, run the verifier's separately installed maintainer helper
  with this exact input set:

  ```bash
  rdma_archive='/home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz'
  rdma_oracle_candidate=$(mktemp -d /tmp/rdma_cmq_oracle.XXXXXX)
  tests/support/capture_rdma_cmq_oracle_candidate.sh \
    --archive "$rdma_archive" \
    --archive-lock hw/rdma/archive_lock.env \
    --source-manifest hw/rdma/source_manifest.txt \
    --source-anchors hw/rdma/c_oracle/cmq_oracle_source_anchors.tsv \
    --cases hw/rdma/c_oracle/cmq_oracle_cases.tsv \
    --oracle-source hw/rdma/c_oracle/rdma_cmq_oracle.c \
    --output-dir "$rdma_oracle_candidate" \
    --cc /usr/bin/gcc
  ```

  The helper uses the same read-only parser/compiler path but refuses an output
  below the Git worktree. It prints the candidate directory and all hashes.
  Compare its four
  metadata files against archive lock, ordered source-anchor closure,
  probe/input/bytes/fields hashes and fixed compiler facts. Add the reviewed
  canonical files listed in **Files** with `apply_patch`; the production
  verifier itself has no repository-writing/update option.

- [ ] **Step 6: Chain the oracle after source verification**

  In `sim/Makefile`, run archive verification, profile/source verification, then:

  ```make
	python3 ../tools/verify_rdma_cmq_oracle.py \
		--kernel-root "$$kernel_root" \
		--archive-lock ../hw/rdma/archive_lock.env \
		--source-manifest ../hw/rdma/source_manifest.txt \
		--source-anchors ../hw/rdma/c_oracle/cmq_oracle_source_anchors.tsv \
		--cases ../hw/rdma/c_oracle/cmq_oracle_cases.tsv \
		--oracle-source ../hw/rdma/c_oracle/rdma_cmq_oracle.c \
		--artifact-root ../hw/rdma/c_oracle/cases \
		--cc /usr/bin/gcc
  ```

- [ ] **Step 7: Run GREEN verification**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_verify_rdma_cmq_oracle -v
  scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test
  ```

  Expected: the Python suite passes; the 53 gate prints archive/source/probe/input/bytes/fields hashes and compiler facts, and all four rebuilt reports equal the committed artifacts.

- [ ] **Step 8: Commit the C oracle**

  ```bash
  git add hw/rdma/c_oracle/rdma_cmq_oracle.c \
    hw/rdma/c_oracle/cmq_oracle_cases.tsv \
    hw/rdma/c_oracle/cmq_oracle_source_anchors.tsv \
    hw/rdma/c_oracle/cases/cmq_sqe_qpc_create_request.input.tsv \
    hw/rdma/c_oracle/cases/cmq_sqe_qpc_create_request.bytes.hex \
    hw/rdma/c_oracle/cases/cmq_sqe_qpc_create_request.fields.tsv \
    hw/rdma/c_oracle/cases/cmq_sqe_qpc_create_request.metadata.env \
    hw/rdma/c_oracle/cases/cmq_sqe_cqc_create_request.input.tsv \
    hw/rdma/c_oracle/cases/cmq_sqe_cqc_create_request.bytes.hex \
    hw/rdma/c_oracle/cases/cmq_sqe_cqc_create_request.fields.tsv \
    hw/rdma/c_oracle/cases/cmq_sqe_cqc_create_request.metadata.env \
    hw/rdma/c_oracle/cases/cmq_cqe_qpc_create_response.input.tsv \
    hw/rdma/c_oracle/cases/cmq_cqe_qpc_create_response.bytes.hex \
    hw/rdma/c_oracle/cases/cmq_cqe_qpc_create_response.fields.tsv \
    hw/rdma/c_oracle/cases/cmq_cqe_qpc_create_response.metadata.env \
    hw/rdma/c_oracle/cases/cmq_sq_doorbell.input.tsv \
    hw/rdma/c_oracle/cases/cmq_sq_doorbell.bytes.hex \
    hw/rdma/c_oracle/cases/cmq_sq_doorbell.fields.tsv \
    hw/rdma/c_oracle/cases/cmq_sq_doorbell.metadata.env \
    tools/verify_rdma_cmq_oracle.py \
    tests/support/capture_rdma_cmq_oracle_candidate.sh \
    tests/unit/test_verify_rdma_cmq_oracle.py hw/rdma/source_manifest.txt \
    sim/Makefile
  git commit -m "test: add reproducible CMQ C oracle"
  ```

### Task 4: Gate CMQ field ownership, capability and mutation evidence

**Files:**

- Create: `hw/rdma/field_ownership.tsv`
- Create: `hw/rdma/field_exclusions.tsv`
- Create: `hw/rdma/cmq_capabilities.tsv`
- Create: `hw/rdma/cmq_field_mutation.tsv`
- Create: `tools/check_rdma_field_ownership.py`
- Create: `tests/unit/test_check_rdma_field_ownership.py`
- Modify: `sim/Makefile`

**Interfaces:**

- Consumes Task 1/2 archive and source identity plus Task 3 C bytes/field reports.
- Produces no SV masks. It proves field coordinates from locked C and verifies the model consumer named by each row.
- This bootstrap enables only the four Task 3 case directions. Every other registered opcode/direction remains explicitly unsupported until the separate phase 1C wire plan.

`field_ownership.tsv` expands manifest identity and source anchors into
machine-parseable columns; `-` is permitted only for an anchor column that is
not applicable to a macro-derived coordinate:

```text
archive_id	source_path	source_selector	source_sha256	macro_name	anchor_function	anchor_token	anchor_occurrence	anchor_container	anchor_buffer	anchor_operation	anchor_base	anchor_length	anchor_target_flow	entry_kind	opcode_or_variant	direction	ownership	capability	model_field_or_raw_slice	owning_codec	overlay_group	discriminator	oracle_case_id
```

`ownership` accepts only `HOST_TYPED`, `HOST_FIXED`, `HW_TYPED`, `HW_OPAQUE`
and `RESERVED_ZERO`; `capability` accepts only `SUPPORTED` and `UNSUPPORTED`.
`HOST_FIXED` means the driver builder authors a command-specific constant; it
must not be mislabeled as caller-writable or as an unnamed reserved bit.

Every target macro family member absent from `field_ownership.tsv` must have
one row in `field_exclusions.tsv`:

```text
archive_id	source_path	source_selector	source_sha256	macro_name	exclusion_reason
```

An exclusion reason must be non-empty and may not be a generic `unused` or
`not needed`; duplicate ownership/exclusion or a macro present in neither file
is a hard failure.

`cmq_capabilities.tsv` uses:

```text
driver_symbol	opcode	opcode_value	direction	registered	request_encodable	response_decodable	oracle_case_id	owning_codec	blocker
```

`driver_symbol` preserves the exact C enumerator spelling and `opcode_value`
preserves its parsed numeric value. The driver typo
`TRDMA_OP_SRFQC_MODIFY = 0x36` is therefore a required registered row rather
than disappearing behind an `XTRDMA_OP_*` name filter. The synthetic
`CMQ_SQ_DOORBELL` capability alone uses `-` for both driver columns because it
is a register write, not an enum opcode.

`cmq_field_mutation.tsv` uses:

```text
case_id	entry	opcode	direction	byte_offset	qword_index	bit_index	expected_class	expected_field	evidence_mode	correlation_group	driver_result_class	model_consumer	expected_outcome	expected_status_code	expected_ready	expected_value_delta	oracle_case_id
```

`evidence_mode` accepts exactly `TYPED_RECOMPOSE`, `CORRELATED_RECOMPOSE`,
`DRIVER_FIXED_REJECT`, `STATIC_CANONICAL`, `STATIC_UNWRITABLE` and
`RAW_DECODE_MUTATION`. The typed, correlated, fixed-reject and raw-decode modes
execute a real production path. `correlation_group` is `-` except that the QPC
VALID/WRAP rows both use `QPC_POLARITY_VALID_WRAP`; one legal polarity
transition must account for the two-bit XOR rather than pretending either bit
is independently writable. Static modes never pretend that a raw request or
doorbell image can be passed to a typed encoder. For static rows only,
`expected_status_code` and `expected_ready` are exactly `-`, and
`expected_value_delta` is zero.

`driver_result_class` and `model_consumer` keep unlike layers separate. For a
legal QPC/doorbell typed or correlated row the driver class is `ENCODED`; the
twelve hardcoded QPC VFID rows use `FIXED_ZERO`; a QPC opcode/SIGN_EN
`STATIC_CANONICAL` row uses `STATIC_CANONICAL`; and every
`STATIC_UNWRITABLE` request bit uses `STATIC_UNWRITABLE`. These two static
classes are driver-result classifications, not executable model statuses: the
checker proves the canonical bit and the absence of an enabled writer instead
of passing a raw image to a typed API. For a CQE mutation, the checker
reproduces the locked driver order
`owner readiness -> request-array index -> SQE wrap -> opcode -> ecode` and
records one of `NOT_READY`, `REQUEST_LOOKUP_CHANGED`, `WRAP_MISMATCH`,
`OPCODE_MISMATCH`, `ECODE_ERROR` or `READY_OK`. `expected_outcome`, status and
ready describe only the named model consumer (`CMQ_REQUEST_COMPOSER`,
`CMQ_COMPLETION_CODEC` or `CMQ_DOORBELL_ENCODER`). A raw codec may publish a
nonzero ecode for the profile/engine to resolve even though the Linux driver
sets `request_error`; the row records both facts and never asserts that the
two layers return the same status type. The complete allowed
`driver_result_class` set is `ENCODED`, `FIXED_ZERO`, `STATIC_CANONICAL`,
`STATIC_UNWRITABLE`, `NOT_READY`, `REQUEST_LOOKUP_CHANGED`, `WRAP_MISMATCH`,
`OPCODE_MISMATCH`, `ECODE_ERROR` and `READY_OK`; the checker rejects any other
class and checks its permitted pairing with `evidence_mode`.
The pairing is exact: `TYPED_RECOMPOSE` and `CORRELATED_RECOMPOSE` use
`ENCODED`; `DRIVER_FIXED_REJECT` uses `FIXED_ZERO`; `STATIC_CANONICAL` and
`STATIC_UNWRITABLE` use their same-named static class; and
`RAW_DECODE_MUTATION` uses only the six CQE classes listed above.

- [ ] **Step 1: Write failing ownership-checker fixtures**

  Add one named fixture for each rejection: `BIT`/`GENMASK` drift, malformed
  expanded manifest/anchor columns, zero-match anchor, multi-match anchor,
  comment-only match, wrong-buffer data flow, omitted codec consumer, target
  macro with neither ownership nor reasoned exclusion, generic exclusion,
  undeclared overlap, missing/illegal discriminator, host encode writing
  HW/reserved bits, decode dropping opaque bits, nonzero reserved accepted,
  unsupported direction marked encodable/decodable, missing oracle case, and
  mutation report drift. Add explicit failures for filtering an enum member by
  the `XTRDMA_OP_` prefix (the locked source contains
  `TRDMA_OP_SRFQC_MODIFY`), collapsing driver result and model-consumer status
  into one column, a one-row/malformed correlation group, and enabling a
  request encoder from decoder-only evidence.

- [ ] **Step 2: Run the ownership RED test**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_check_rdma_field_ownership -v
  ```

  Expected: FAIL because the matrix, checker and mutation evidence do not exist.

- [ ] **Step 3: Implement driver-derived coordinates and source anchors**

  Parse `BIT()`, `BIT_ULL()`, `GENMASK()` and `GENMASK_ULL()` from the verified
  headers. Derive container byte offsets from unique `set_64bit_val()`,
  `get_64bit_val()`, `memcpy()` or `offsetof()` calls in the locked C source.
  Rebuild the manifest four-tuple from the first four TSV columns and require
  an exact manifest row. A non-macro anchor row must prove its function,
  normalized token occurrence number, container/buffer expression, operation,
  base/length and data flow into the declared target image. Python proves
  provenance, coordinates and static consumer references only; Task 5 UVM is
  the authority for production encode/decode behavior.

  For the CQE case, also validate the complete ordered READY/LOOKUP/PARSE/
  VALIDATE/LOAD anchor set and reproduce the driver result class from the
  canonical `cq_polarity`, expected request index, SQE wrap, opcode and ecode.
  The driver result is an independent report column; never copy the model
  consumer's expected status into it. For the doorbell, require both POST and
  WRITE anchors so a field mask alone cannot stand in for the big-endian MMIO
  byte contract.

  The checker must never import `word_byte_offset`, `BODY_TRANSLATIONS`, Python golden masks, `rdma_cmq_opcode_descriptor.request_qword_masks` or `response_qword_masks` as expected coordinates.

- [ ] **Step 4: Record candidate capabilities without enabling them**

  Parse every enumerator structurally from the body of
  `enum xtrdma_cmq_opcode` and record it exactly once per REQUEST and RESPONSE
  direction; do not select members by an `XTRDMA_OP_*` prefix. Preserve the
  literal `TRDMA_OP_SRFQC_MODIFY` symbol and value `0x36`. Treat
  `XTRDMA_OP_MAX` as the enum bound, not an executable opcode.
  `registered=1` means only that the driver assigned an opcode. In this task
  every `request_encodable` and `response_decodable` bit
  remains zero because the production-path closed-evidence test does not exist
  yet. Use `MISSING_PRODUCTION_PATH_EVIDENCE` in `blocker` for the QPC request,
  QPC response and doorbell candidates. Use
  `CONTEXT_EMBED_BASE_MISMATCH` for CQC_CREATE REQUEST: the driver oracle proves
  `embed_base=8`, while the current composer merges the local context at byte
  zero. Use `MISSING_CLOSED_EVIDENCE` for all other directions. The doorbell is
  one separate `CMQ_SQ_DOORBELL` record, not a fabricated CMQ opcode.

  Task 5 alone may change the three proven candidate bits to one. CQC_CREATE
  remains unsupported until the Phase 1C wire-contract plan implements and
  proves production `embed_at(8)`.

- [ ] **Step 5: Generate and byte-compare the candidate closed-evidence report**

  Generate exactly 1,088 data rows: 512 for the QPC_CREATE SQE, 512 for the
  QPC_CREATE CQE, and 64 for the CMQ SQ doorbell. CQC_CREATE is excluded because
  its production request path does not honor the C-derived embed base. For each
  logical C qword bit, derive the memory coordinate as
  `byte_offset = 8 * qword_index + 7 - (bit_index // 8)` and retain
  `bit_index % 8` within that byte. Expected class/field and driver result come
  from the locked C fields, behavior anchors and ownership rows. Model outcome,
  status, ready and value delta come from the explicitly named consumer policy;
  the checker rejects any row that substitutes one layer for the other.

  The QPC request rows have these exact evidence counts, derived from the
  locked C fields rather than the existing SV masks:

  ```text
  TYPED_RECOMPOSE       134
  CORRELATED_RECOMPOSE    2
  DRIVER_FIXED_REJECT    12
  STATIC_CANONICAL        9
  STATIC_UNWRITABLE     355
  ```

  The arithmetic is fixed by the driver macros: typed bits are
  `INDEX(5) + QPN(24) + SQ_CQN(21) + RQ_CQN(21) + QPC_BUFFER_ADDR(55) +
  SIGNATURE(8) = 134`; the one polarity input accounts for the two correlated
  `VALID`/`WRAP` bits; driver-fixed `VFID_OVERRIDE(1) + USE_VFID(11) = 12`;
  `OPCODE(8) + SIGN_EN(1) = 9` are canonical-static; the remaining 355 bits
  are static-unwritable. The same calculation gives doorbell
  `PI(5) + POL(1) = 6` typed and 58 static-unwritable bits.

  `TYPED_RECOMPOSE` covers INDEX, QPN, SQ_CQN, RQ_CQN, QPC_BUFFER_ADDR and
  SIGNATURE. VALID and WRAP are the two `CORRELATED_RECOMPOSE` rows: the driver
  derives both from one polarity input, so one legal state transition must
  change exactly that two-row group. `DRIVER_FIXED_REJECT` covers
  VFID_OVERRIDE and USE_VFID. `xtrdma_sc_qp_create` hardcodes all twelve bits to
  zero; Task 5 must make the model's QPC_CREATE compose path reject any nonzero
  value before it can claim driver-bound request capability. The eight OPCODE
  case-selector bits and the QPC_CREATE-fixed SIGN_EN bit are
  `STATIC_CANONICAL`: changing an opcode bit selects a different typed command
  contract, while SIGN_EN has no caller-writable field. All remaining request
  bits are
  `STATIC_UNWRITABLE`. The checker must prove those bits are zero in the C
  canonical image, absent from every typed field writer for this case, and not
  enabled by an ownership/capability row; it must not generate a raw-image
  injection that `compose_request()` cannot consume.

  All 512 response rows are `RAW_DECODE_MUTATION` against the production raw
  completion codec. Flipping the owner bit may produce `status=OK, ready=0`;
  an opcode bit may select another registered opcode or return
  `UNSUPPORTED_OPCODE` rather than a generic codec error. Independently, the
  driver-result column applies owner, request-index, wrap, opcode and ecode
  checks to the same mutated bytes. A raw codec's successful publication of a
  nonzero ecode is not mislabeled as Linux-driver success.

  The doorbell request direction has six `TYPED_RECOMPOSE` rows for PI[4:0]
  and wire polarity plus 58 `STATIC_UNWRITABLE` rows. Each typed mutation uses
  a pair of reachable monotonic ring states and calls the production doorbell
  encoder; no decoder-only mutation may enable `request_encodable`. Unknown/
  unregistered response bits are `REJECT`, opaque bits retain their raw delta,
  and overlay rows require exactly one legal discriminator.

  Require these whole-report counts:

  ```text
  TYPED_RECOMPOSE       140
  CORRELATED_RECOMPOSE    2
  DRIVER_FIXED_REJECT    12
  RAW_DECODE_MUTATION   512
  STATIC_CANONICAL        9
  STATIC_UNWRITABLE     413
  EXECUTED_TOTAL        666
  STATIC_TOTAL          422
  GRAND_TOTAL          1088
  ```

- [ ] **Step 6: Chain ownership verification into `rdma_defs`**

  Append this command after the C oracle verifier:

  ```make
	python3 ../tools/check_rdma_field_ownership.py \
		--kernel-root "$$kernel_root" \
		--archive-lock ../hw/rdma/archive_lock.env \
		--source-manifest ../hw/rdma/source_manifest.txt \
		--ownership ../hw/rdma/field_ownership.tsv \
		--exclusions ../hw/rdma/field_exclusions.tsv \
		--capabilities ../hw/rdma/cmq_capabilities.tsv \
		--oracle-root ../hw/rdma/c_oracle/cases \
		--mutation-manifest ../hw/rdma/cmq_field_mutation.tsv \
		--sv-root ../src
  ```

  Prepend the complete Phase 0 Python definition suite so the fixed driver
  entry is the promised combined gate rather than a collection of commands an
  operator must remember:

  ```make
	cd .. && python3 -m unittest \
		tests.unit.test_verify_rdma_archive \
		tests.unit.test_check_rdma_profile_names \
		tests.unit.test_verify_rdma_cmq_oracle \
		tests.unit.test_check_rdma_field_ownership -v
  ```

- [ ] **Step 7: Run GREEN verification**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_check_rdma_field_ownership -v
  scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test
  ```

  Expected: PASS; changing any archive/source/anchor/C artifact/consumer/capability/mutation row makes `rdma_defs` exit nonzero.

- [ ] **Step 8: Commit the field gate**

  ```bash
  git add hw/rdma/field_ownership.tsv hw/rdma/field_exclusions.tsv \
    hw/rdma/cmq_capabilities.tsv \
    hw/rdma/cmq_field_mutation.tsv tools/check_rdma_field_ownership.py \
    tests/unit/test_check_rdma_field_ownership.py sim/Makefile
  git commit -m "test: gate CMQ field ownership and capabilities"
  ```

### Task 5: Add the dedicated CMQ UVM gate and driver-derived mutation test

**Files:**

- Create: `sim/cmq_gate.list`
- Create: `tests/support/rdma_cmq_contract_reader.sv`
- Create: `tests/unit/rdma_cmq_driver_field_mutation_test.sv`
- Create: `tests/unit/test_cmq_gate_manifest.py`
- Modify: `hw/rdma/field_ownership.tsv`
- Modify: `hw/rdma/cmq_capabilities.tsv`
- Modify: `src/codec/rdma/rdma_cmq_hw_profile.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `tests/unit/rdma_cmq_profile_test.sv`
- Modify: `scripts/run_vcs53.sh`
- Modify: `scripts/run_queue_lifecycle_regression53.sh`
- Modify: `sim/Makefile`

**Interfaces:**

- Consumes Task 3 canonical bytes and Task 4's 1,088-row closed-evidence
  report through one strict, read-only SV artifact reader.
- QPC request recomposition rows mutate the legal slot state, QPC command body
  or composer-consumed QPC signature source, then run the real typed body
  builder and production composer. Its driver-fixed VFID rows exercise an
  opcode-scoped rejection before composition. Static request rows prove
  canonical/fixed or unwriteable bits without feeding a raw full SQE to an API
  that cannot consume one.
- Response rows flip raw images because response capability is a decode
  direction. Each row keeps the locked driver's result class distinct from the
  named model consumer's result. Doorbell request rows call the production
  encoder for PI/polarity and statically close its 58 unwritable bits; a
  decoder-only test cannot enable request capability.
- CQC_CREATE request remains explicitly unsupported because the current
  production composer lacks `embed_at(8)`; no injected codec or shifted test
  payload may conceal that defect.
- Produces the fixed `cmq_gate` suite; no test may silently disappear when the
  general core regression list changes.

`sim/cmq_gate.list` contains exactly these non-comment rows, in this order:

```text
rdma_cmq_codec_test
rdma_cmq_completion_test
rdma_cmq_profile_test
rdma_doorbell_codec_test
rdma_cmq_engine_test
rdma_cmq_driver_field_mutation_test
```

- [ ] **Step 1: Write the RED manifest and mutation tests**

  `test_cmq_gate_manifest.py` must parse non-comment rows and assert exact list
  equality, uniqueness, inclusion in `rdma_unit_test_pkg.sv`, and inclusion of
  `rdma_cmq_driver_field_mutation_test` in `CORE_TESTS`.

  In `rdma_cmq_driver_field_mutation_test.sv`, add these test helpers, each with
  the required adjacent Chinese three-part comment:

  ```systemverilog
  function automatic rdma_hw_image load_canonical_image(
    input string relative_path,
    input rdma_image_kind_e image_kind,
    input int unsigned length
  );

  task automatic check_request_case(
    input string case_id,
    input bit [7:0] opcode
  );

  function automatic bit mutate_qpc_request_inputs(
    input rdma_cmq_field_evidence_row row,
    input rdma_cmq_command_desc baseline_command,
    input rdma_cmq_slot_context baseline_slot,
    output rdma_cmq_command_desc mutated_command,
    output rdma_cmq_slot_context mutated_slot,
    output string failure_reason
  );

  task automatic check_qpc_polarity_group(input string case_id);

  task automatic check_qpc_driver_fixed_rejection(
    input rdma_cmq_field_evidence_row row
  );

  task automatic check_request_static_row(
    input rdma_cmq_field_evidence_row row,
    input rdma_hw_image canonical_request
  );

  task automatic check_completion_case(
    input string case_id,
    input bit [7:0] opcode
  );

  task automatic check_doorbell_request_case(input string case_id);

  task automatic check_cqc_embed_blocker();
  ```

  The test must parse every data row of `../hw/rdma/cmq_field_mutation.tsv`,
  reject malformed/duplicate/out-of-range rows, and finish with exactly 1,088
  visited bits and these per-case counts:

  ```systemverilog
  expected_rows["cmq_sqe_qpc_create_request"] = 512;
  expected_rows["cmq_cqe_qpc_create_response"] = 512;
  expected_rows["cmq_sq_doorbell"] = 64;
  ```

  `rdma_cmq_contract_reader.sv` declares
  `rdma_cmq_field_evidence_row` with one typed field for every TSV column,
  parses exact columns, rejects comments after a data token, duplicate
  case/coordinate rows, unknown enums/evidence modes, non-canonical hex, wrong
  row counts, malformed correlation groups, unknown driver result classes,
  invalid driver-result/evidence pairings, layer/status conflation and
  inconsistent qword/byte mapping. It requires
  exactly 140 `TYPED_RECOMPOSE`, two `CORRELATED_RECOMPOSE`, 12
  `DRIVER_FIXED_REJECT`, nine `STATIC_CANONICAL`, 413
  `STATIC_UNWRITABLE` and 512 `RAW_DECODE_MUTATION` rows. It never imports SV
  masks to construct expected values.

  For `QPC_CREATE`, construct the exact asymmetric command, slot and QPC
  signature source from Task 3, call the production
  `rdma_hw_cmq_hw_profile::compose_sqe()` path, and compare all 64 produced
  bytes plus
  `length=64`, `alignment=64`, big endian and generation metadata with the C
  artifact. `check_cqc_embed_blocker()` verifies the C case declares base 8,
  the capability row remains zero with `CONTEXT_EMBED_BASE_MISMATCH`, and no
  CQC mutation row exists; it does not execute or normalize the known-wrong
  composer path.

  For each request row, compare the C-derived expected class/evidence mode with
  the production envelope/body ownership decision. Do not derive the expected
  result from `RDMA_CMQ_*_MASK` or the descriptor under test.

  For each ordinary QPC `TYPED_RECOMPOSE` row, construct two independently
  owned valid command/slot graphs: a field-local baseline and a mutant. Flip
  exactly the named semantic input bit and dispatch by the ownership-row
  `expected_field`:

  ```text
  XTRDMA_CMQSQ_WQE_INDEX           -> slot.sq_index[bit]
  XTRDMA_CMQSQ_WQE_QPN             -> body.qp_h.object_id[bit]
  XTRDMA_CMQSQ_WQE_SQ_CQN          -> body.send_cq_h.object_id[bit]
  XTRDMA_CMQSQ_WQE_RQ_CQN          -> body.recv_cq_h.object_id[bit]
  XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR -> body.qpc_buffer.value[bit + 9]
  XTRDMA_CMQSQ_WQE_SIGNATURE       -> command.qpc_signature_source PD-index bit
  ```

  VALID and WRAP do not enter this table. Execute their exact two-row
  `QPC_POLARITY_VALID_WRAP` group once with two legal slot wrap states through
  `compose_sqe()`: the C-derived XOR must contain both coordinates and no
  others. Mark both rows visited atomically; a test that changes only
  `envelope.valid` or only `envelope.wrap` is invalid because the driver has one
  polarity source for both fields.

  For every `DRIVER_FIXED_REJECT` row, keep a valid QPC_CREATE graph and set the
  named VFID bit nonzero. USE_VFID tests also set `vfid_override=1` so they pass
  the generic envelope relationship and reach the opcode-specific rule. The
  production profile must return `RDMA_SC_INVALID_ARGUMENT` before body/image
  publication, leave all input graphs unchanged and make no Host-memory/MMIO
  call. The all-zero VFID baseline must still reproduce the C image.

  QPN mutation also changes the typed QPC signature-source model's QP identity
  so the production identity check remains valid. Signature rows decode the
  field-local source with the production QPC codec, change one of the eight
  low PD-index bits, and re-encode it; they never mutate the final 64-byte SQE.
  Run the production profile for both graphs. Outside the
  derived signature byte, the final-image XOR must equal only the C-derived
  target coordinate; the signature byte must equal the driver-anchored
  complement-XOR for each full input, so its induced delta is checked rather
  than hidden.

  For each `STATIC_CANONICAL` QPC request row, compare the C bit with the
  canonical production-composed image and verify the ownership checker tied it
  only to the immutable opcode case selector or fixed SIGN_EN writer; its
  `driver_result_class` is `STATIC_CANONICAL`. For each
  QPC `STATIC_UNWRITABLE` row, require the C and production canonical bits to be
  zero and require Task 4's source walk to prove that no semantic body writer
  or enabled capability owns the coordinate; its `driver_result_class` is
  `STATIC_UNWRITABLE`. Do not fabricate a body token,
  inject a shifted codec, mutate an authenticated body image, or claim a
  runtime rejection from an unconsumed raw request image.

  For every `RAW_DECODE_MUTATION` CQE row, clone the driver-accepted canonical
  response, flip exactly one memory bit using the recorded big-endian
  coordinate, and call
  `rdma_hw_cmq_completion_codec::inspect_completion()`. Compare exact model
  `expected_outcome`, status, ready and typed/raw value delta. Separately check
  that the row's `driver_result_class` equals the Task 4 reproduction; do not
  demand equality between Linux request-error handling and raw-codec status.
  Add explicit ecode coverage proving the raw codec retains the ecode while the
  production profile publishes its mapped non-OK command status.

  For the six typed doorbell rows, call the production profile's
  `encode_doorbell()` on two reachable `(final_pi, wire_polarity)` states and
  require the final-image XOR to equal only the C-derived target coordinate.
  Use the second-cycle canonical state `(0x17, 1)` from Task 3; every PI-bit
  mutant remains nonzero and reachable in that cycle, while the polarity
  mutant `(0x17, 0)` is reachable in the first cycle. For the other 58 doorbell
  rows, require the C and production image bits to be zero and prove the
  selected encode mask cannot author them. Never use the doorbell decoder as
  request-encoding evidence.
  The principal classes remain:

  ```text
  HOST_TYPED -> the real request path admits the named field and reproduces C bytes
  HOST_FIXED -> the driver-authored constant is reproduced; exposed nonzero input is rejected
  HW_TYPED   -> decode outcome/status/ready and named field delta equal the row
  HW_OPAQUE  -> decode succeeds and the raw slice retains the exact bit delta
  RESERVED_ZERO / unregistered -> the recorded rejection status is returned
  ```

- [ ] **Step 2: Run the RED tests**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_cmq_gate_manifest -v
  scripts/run_vcs53.sh core rdma_cmq_driver_field_mutation_test
  ```

  Expected: the Python test fails because the manifest/registration is absent;
  VCS fails because the UVM test class is undefined.

- [ ] **Step 3: Register the mutation test and dedicated gate**

  Include the new test immediately after `rdma_cmq_profile_test.sv` in
  `tests/rdma_unit_test_pkg.sv`, and add its class name immediately after
  `rdma_cmq_profile_test` in `CORE_TESTS`.

  Add a `cmq_gate` Make target that validates every manifest row against
  `^[A-Za-z_][A-Za-z0-9_]*$`, rejects duplicates/extra columns/empty manifests,
  builds the core image once, runs every test in order, and passes every log to
  `scripts/check_uvm_summary.sh`. Add `cmq_gate` to the allowed suite case in
  `scripts/run_vcs53.sh`; the fixed invocation is:

  ```bash
  scripts/run_vcs53.sh cmq_gate regression
  ```

- [ ] **Step 4: Enforce the driver-fixed QPC VFID contract**

  In `rdma_hw_cmq_hw_profile::compose_sqe()`, after resolving the eight-bit
  opcode and before building any body/image, reject QPC_CREATE when
  `command.vfid_override != 0` or `command.use_vfid != 0`. Return
  `RDMA_SC_INVALID_ARGUMENT`, publish null SQE/expected response and perform no
  body encode, Host-memory or MMIO operation. This is opcode-scoped: do not
  silently remove the generic envelope fields from other future contracts.

  Add focused profile tests for all-zero success, override-only rejection and
  each of the eleven USE_VFID bits with override enabled. Update the complete
  three-part Chinese comment on the touched method and keep validation,
  snapshot and encode stages separated by blank lines.

- [ ] **Step 5: Activate only directions proven by closed production evidence**

  First run the profile and evidence tests with all candidate capability bits
  still zero:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_profile_test
  scripts/run_vcs53.sh core rdma_cmq_driver_field_mutation_test
  ```

  Expected: PASS; QPC nonzero VFID is rejected, the zero-VFID canonical image
  matches C, response driver/model results remain distinct, and doorbell proof
  uses only the encoder.

  Then change exactly these records and their matching ownership rows from
  candidate to supported:

  ```text
  QPC_CREATE REQUEST  request_encodable=1   blocker=-
  QPC_CREATE RESPONSE response_decodable=1  blocker=-
  CMQ_SQ_DOORBELL REQUEST request_encodable=1 blocker=-
  ```

  Leave `CQC_CREATE REQUEST request_encodable=0` with
  `CONTEXT_EMBED_BASE_MISMATCH`; leave every other unproved direction zero.
  Rerun the Python ownership checker before the UVM gate so a capability cannot
  be enabled without its complete dynamic-plus-static 512/64-row proof.

- [ ] **Step 6: Run GREEN verification**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_cmq_gate_manifest -v
  scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test
  scripts/run_vcs53.sh cmq_gate regression
  ```

  Expected: the manifest test and driver gate pass; all six UVM logs have
  exactly zero warning/error/fatal reports. The evidence test reports 140
  ordinary typed recompositions, two correlated recompositions, 12
  driver-fixed rejections, 512 raw response decodes, nine canonical-static and
  413 unwritable-static rows: 666 executed plus 422 static, exactly 1,088
  total. The three proven capability directions are enabled, and CQC_CREATE
  REQUEST remains explicitly blocked.

- [ ] **Step 7: Review and commit the dedicated gate**

  Review every touched SV file from header to EOF against `AGENTS.md`, including
  the pre-existing methods around each changed call path. Resolve comment,
  ownership, failure-path and sparse-layout findings before staging.

  ```bash
  git add hw/rdma/field_ownership.tsv hw/rdma/cmq_capabilities.tsv \
    sim/cmq_gate.list sim/Makefile scripts/run_vcs53.sh \
    scripts/run_queue_lifecycle_regression53.sh tests/rdma_unit_test_pkg.sv \
    src/codec/rdma/rdma_cmq_hw_profile.sv \
    tests/support/rdma_cmq_contract_reader.sv \
    tests/unit/rdma_cmq_driver_field_mutation_test.sv \
    tests/unit/rdma_cmq_profile_test.sv \
    tests/unit/test_cmq_gate_manifest.py
  git commit -m "fix(cmq): gate driver-bound wire capabilities" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 6: Centralize approved external pins and exclude non-input sync data

**Files:**

- Create: `hw/rdma/external_dependencies.tsv`
- Create: `tools/check_external_dependency_lock.py`
- Create: `tests/unit/test_external_dependency_lock.py`
- Create: `tests/unit/test_run_vcs53_sync.py`
- Modify: `sim/Makefile`
- Modify: `scripts/run_vcs53.sh`
- Modify: `README.md`
- Modify: `docs/rdma-0.1.34-gap-closure-verification.md`

**Interfaces:**

- `verify` resolves the actual direct-plus-recursive-include closure and checks
  it against one approved dependency record set. A Git checkout is identified
  by exact HEAD plus clean/tracked consumed paths; a non-Git snapshot is
  identified by the same per-file hashes plus canonical tree digest.
- `capture` writes one canonical `0600` candidate below `/tmp`, using temp-file
  + `fsync` + atomic rename. It never edits the lock/repository, never changes
  `UNAPPROVED`, and never treats an arbitrary checkout found on 53 as approved.
- `dpu_common` and `pcie_work` remain `UNAPPROVED`; integration and pcie
  preflights intentionally fail closed until a separately reviewed baseline
  commit replaces those rows.
- Task 6A must approve one exact `dpu_common` closure before Phase 1A starts,
  because Task 17 and final acceptance execute the integration suite.
  `pcie_work` remains unapproved because no task in this plan consumes it.

The lock has this exact TSV schema:

```text
dependency	approval	root_env	git_commit	snapshot_tree_sha256	include_dirs	input_kind	relative_path	sha256
```

`approval` is `APPROVED|UNAPPROVED`; `input_kind` is `DIRECT|INCLUDE`.
`include_dirs` is an ordered semicolon-separated list of normalized
root-relative directories. For one dependency, approval/root-env/commit/tree
digest/include-dirs must be identical on every row, and
`(dependency, relative_path)` is unique. Every dependency has at least one
`DIRECT` row. An approved row contains a 40-hex commit, 64-hex tree digest and
64-hex file digest; an unapproved seed uses `-` for all three identities.

The canonical tree digest is:

```text
SHA256(concat(
  for row in rows sorted by UTF-8 bytes of relative_path:
    relative_path + "\\0" + lowercase_file_sha256 + "\\n"
))
```

Freeze these approved group identities:

```text
host_mem   HOST_MEM_ROOT  3b9e000d5df4d10efbb3029f43605e0362e0caca  6f9f6c3cf9ea3a9b99086c0b91d74ce680389f75d2d8ef15d68fe9750e8c87da  src
net_packet NET_PACKET_ROOT 6766c4f042484814548481065328ffbcffab590f  0bb2641d4c1e09505af9138d22e0cf4f9f191d36936000d72d74b68e666ce2d7  src;src/core;src/common;src/protocols
```

The approved file rows are exactly the two host files and the 41-file
net-packet closure below; when writing the lock, repeat the matching group
identity columns on each row:

```text
host_mem	DIRECT	src/host_mem_manager.sv	8dd5ca3ba3abcfae4808c8ea10c34ced279316bebdc04f6f8e0ae5e55e337a9d
host_mem	DIRECT	src/host_mem_pkg.sv	d2ba57918a3b605525274433008142c80921b6205b0848c76bef8f1fc0d0bba5
net_packet	INCLUDE	src/common/packet_defines.sv	f8b3cdcb668c1462141b98e3fa76aa5b03281cb433c3b191a51cadb51f1ab001
net_packet	INCLUDE	src/common/packet_utils.sv	89ef86e6782233380a9854c656f797891fd14d0f4e8e433beee02828bd380fb5
net_packet	DIRECT	src/core/packet.sv	1ded8ff5ca49d4dc2906a9c701b7dc93e23e1a802d576bb43f60be8b733e83c8
net_packet	INCLUDE	src/core/protocol_graph.sv	a228ea5240aa84d608b1376ee9e2a6633e5dd889b34d79f87c20acacb95cba40
net_packet	INCLUDE	src/core/template_registry.sv	86e61339ed9706d245ba43494951ff7fe7682084881578bb704aed3775835e17
net_packet	INCLUDE	src/protocols/app/ptp_header.sv	7fe28e239936337d06f25a7fdf189ea8fa139cf6a0a36f87f409f9fb23101126
net_packet	INCLUDE	src/protocols/l2/eth_header.sv	4c8b874828571b033793d52beafa509332c576db476fa63ec5bf8d4e95cd7a6e
net_packet	INCLUDE	src/protocols/l2/lacp_header.sv	95977ca6129cd776d4d4bb67d8d2f7e69eebf3de97b6d7cacbaff416cce2d9cd
net_packet	INCLUDE	src/protocols/l2/lldp_header.sv	e7d357e45a398e11e69afb882890b9ab869f8a4291ae27c011a52b1c2423a2e8
net_packet	INCLUDE	src/protocols/l2/mac_control_header.sv	550c8248e134df2ca16ad38c7d75e85920e87a062f99e969339fe61c541c85d2
net_packet	INCLUDE	src/protocols/l2/mpls_header.sv	187ae2bd4212d07b107687be5751fa48666d669ef329c3d6284499fa40873716
net_packet	INCLUDE	src/protocols/l2/stp_header.sv	538252929c82d9a3a5fc34ed9b719e1c89ce6e8233ceb0129f0f6647a7c35ee4
net_packet	INCLUDE	src/protocols/l2/vlan_header.sv	79e84a1f034ec77bc7303ed0e8940c4cb1b081d6e4b3ca1030b88c0980ce06c4
net_packet	INCLUDE	src/protocols/l3/arp_header.sv	0f8b8e1f828761be84ac265b28f08a3ad4a6517cbdae59f82e0887acd8161b3e
net_packet	INCLUDE	src/protocols/l3/ipv4_header.sv	40309b4ff9eb8490aa2ae546b06393df816c26bcbee2fd75d1946ea93d22813e
net_packet	INCLUDE	src/protocols/l3/ipv6_ext_header.sv	6a8a0f44b88b8d009a39d7653783fc80a56bcb055e5bd61d44b539fdd07ea0b2
net_packet	INCLUDE	src/protocols/l3/ipv6_header.sv	db005c0f6511fdad77b59995dca782ac860e87ecaee99b0d9467a82e50d32f84
net_packet	INCLUDE	src/protocols/l4/bfd_header.sv	aa2c28f5e114e266e8acc2303c832f0abaead5ec35fff1084d2a42d2f2359737
net_packet	INCLUDE	src/protocols/l4/dhcp_header.sv	703e4d13b95a032c9fe475402685166fca6b7620abbedbfb9c5ccc7a6666ccc7c7
net_packet	INCLUDE	src/protocols/l4/dhcpv6_header.sv	e35e959466aa9c1f3a69bad7c4365a16caf06e4e9856b1ef8ded49d00b5efffb
net_packet	INCLUDE	src/protocols/l4/dns_header.sv	6739dd788510c6386f4e05dcabf0ba4b0a754dab52fc9166cf5fda0869824878
net_packet	INCLUDE	src/protocols/l4/icmp_header.sv	affe32f59ef32dbf5a42ec8bffd355dc93f36eedf8f07c0f18041c09b80d85f6
net_packet	INCLUDE	src/protocols/l4/icmpv6_header.sv	e98835c141602be609da1026638ab1244518d823df9b8303d20b27d97347eeea
net_packet	INCLUDE	src/protocols/l4/igmp_header.sv	d6888d82bbd0aaf637f98caeccdf2a34f2fc619352934db215c296c72f4471bf
net_packet	INCLUDE	src/protocols/l4/sctp_header.sv	f4e4152760ab05d57d1b3d5ff6ea20b1b469ed9b365ae1d5827a167691528023
net_packet	INCLUDE	src/protocols/l4/tcp_header.sv	02591a170dd51d24bfe475402685166fca6b7620abbedbfb9c5ccc640589378e
net_packet	INCLUDE	src/protocols/l4/udp_header.sv	be220fce9a517d01b641b9d42216c2cd245a960d64d830723419c9571e74b197
net_packet	INCLUDE	src/protocols/protocol_base.sv	22c4e5d43708e63876dc0733c358a9bc03c09d95dfee2728aac186889cf95ba4
net_packet	INCLUDE	src/protocols/rdma/iwarp_header.sv	cae60f761c393fe44c621c427493135944102e7478d563e663e491d2f98c290a
net_packet	INCLUDE	src/protocols/rdma/nvme_rdma_header.sv	cb19c814e17cc4d46c3f7d7f06f70e407bc009a27141d420a57f56b596dc0ea7
net_packet	INCLUDE	src/protocols/rdma/rocev2_header.sv	740d04ce6845d44de5476a97d8900b4465158f004137bc76434e02cd106a6aa0
net_packet	INCLUDE	src/protocols/storage/iscsi_header.sv	5092cd60632c492a96978538e2103bab621c9fac28cf8f26e9ad03aab34a84f8
net_packet	INCLUDE	src/protocols/storage/nvme_tcp_header.sv	894e55e7c180bc39b8d70491ccebe493ec8b94e4a79442a514ba936a4ea9879e
net_packet	INCLUDE	src/protocols/tunnel/erspan_header.sv	d32aede0d497011bd599be3820be779ab24e17d92fa9f792356fb9fbb3a9a7a2
net_packet	INCLUDE	src/protocols/tunnel/esp_header.sv	5bcb78a53805bdc74867c1e20b4e72057f3be0cd6dfc614ae681beef088be110
net_packet	INCLUDE	src/protocols/tunnel/geneve_header.sv	5dc6c7721cb9eed47e1d81dcb0f7821c9464228cc59ac46818cf84d6274048bf
net_packet	INCLUDE	src/protocols/tunnel/gre_header.sv	3429ddfd40051e035139ed912ad7b4353ed55b8caa0b444c77fbe43b43a246f0
net_packet	INCLUDE	src/protocols/tunnel/gtp_header.sv	e3583e240cf27cf1a93a8875af8eac2f30c9e480c2bb2d843e17afcb78eb4846
net_packet	INCLUDE	src/protocols/tunnel/ip_in_ip_header.sv	52377fc5751da2774b370b4690ea9a7edc813f8e4d5d215ae503649ef8ae3fc6
net_packet	INCLUDE	src/protocols/tunnel/vxlan_gpe_header.sv	dde35feefa451b189998c43aa104d6d3e97886317d98eafe2455a76cf749a45b
net_packet	INCLUDE	src/protocols/tunnel/vxlan_header.sv	cc8abe753ad9cf4de378e6aef5e8b718ef104f3e7ed4a6a9d6effabbb3a06812
```

Keep only these unapproved direct seeds; their candidate recursive closures
are not copied into the approved lock:

```text
dpu_common	UNAPPROVED	DPU_COMMON_ROOT	-	-	src	DIRECT	src/dpu_resource_pkg.sv	-
pcie_work	UNAPPROVED	PCIE_WORK_ROOT	-	-	pcie_tl_vip/src;pcie_tl_vip/src/types;pcie_tl_vip/src/shared;pcie_tl_vip/src/agent;pcie_tl_vip/src/env;pcie_tl_vip/src/adapter;pcie_tl_vip/src/topology;pcie_tl_vip/src/switch;pcie_tl_vip/src/seq/base;pcie_tl_vip/src/seq/constraints;pcie_tl_vip/src/seq/scenario;pcie_tl_vip/src/seq/virtual	DIRECT	pcie_tl_vip/src/pcie_tl_if.sv	-
pcie_work	UNAPPROVED	PCIE_WORK_ROOT	-	-	pcie_tl_vip/src;pcie_tl_vip/src/types;pcie_tl_vip/src/shared;pcie_tl_vip/src/agent;pcie_tl_vip/src/env;pcie_tl_vip/src/adapter;pcie_tl_vip/src/topology;pcie_tl_vip/src/switch;pcie_tl_vip/src/seq/base;pcie_tl_vip/src/seq/constraints;pcie_tl_vip/src/seq/scenario;pcie_tl_vip/src/seq/virtual	DIRECT	pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv	-
pcie_work	UNAPPROVED	PCIE_WORK_ROOT	-	-	pcie_tl_vip/src;pcie_tl_vip/src/types;pcie_tl_vip/src/shared;pcie_tl_vip/src/agent;pcie_tl_vip/src/env;pcie_tl_vip/src/adapter;pcie_tl_vip/src/topology;pcie_tl_vip/src/switch;pcie_tl_vip/src/seq/base;pcie_tl_vip/src/seq/constraints;pcie_tl_vip/src/seq/scenario;pcie_tl_vip/src/seq/virtual	DIRECT	pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv	-
pcie_work	UNAPPROVED	PCIE_WORK_ROOT	-	-	pcie_tl_vip/src;pcie_tl_vip/src/types;pcie_tl_vip/src/shared;pcie_tl_vip/src/agent;pcie_tl_vip/src/env;pcie_tl_vip/src/adapter;pcie_tl_vip/src/topology;pcie_tl_vip/src/switch;pcie_tl_vip/src/seq/base;pcie_tl_vip/src/seq/constraints;pcie_tl_vip/src/seq/scenario;pcie_tl_vip/src/seq/virtual	DIRECT	pcie_tl_vip/src/topology/pcie_topology_pkg.sv	-
pcie_work	UNAPPROVED	PCIE_WORK_ROOT	-	-	pcie_tl_vip/src;pcie_tl_vip/src/types;pcie_tl_vip/src/shared;pcie_tl_vip/src/agent;pcie_tl_vip/src/env;pcie_tl_vip/src/adapter;pcie_tl_vip/src/topology;pcie_tl_vip/src/switch;pcie_tl_vip/src/seq/base;pcie_tl_vip/src/seq/constraints;pcie_tl_vip/src/seq/scenario;pcie_tl_vip/src/seq/virtual	DIRECT	pcie_tl_vip/src/pcie_tl_pkg.sv	-
```

The repeated pcie rows intentionally spell out the complete ordered include
directory list. Angle-bracket shorthand is not valid parser input.

- [ ] **Step 1: Write RED lock and sync tests**

  In `test_external_dependency_lock.py`, use temporary Git repositories and
  plain snapshots to cover unknown/missing columns, duplicate paths, metadata
  disagreement, invalid approval/kind/hash/path, absolute/empty/`.`/`..` or
  backslash paths, no direct seed, and approved `-` fields. Cover clean Git,
  wrong HEAD, staged/unstaged drift, untracked consumed files, ignored or
  untracked include-shadow files, hash drift, direct/include symlink,
  realpath escape, unresolved include, and closure set drift. Cover clean
  non-Git snapshot, tree/file drift, added shadow and refusal to treat a Git
  checkout as snapshot mode. The only unresolved toolchain include allowlist
  entry is `uvm_macros.svh`.

  Assert `UNAPPROVED` fails before checkout identity inspection with:

  ```text
  external dependency is not approved: dpu_common
  ```

  Assert `capture` writes bytewise-sorted TSV rows to an explicit `/tmp`
  candidate, preserves `UNAPPROVED`, and leaves the input lock and every file
  under the repository byte-for-byte unchanged.

  In `test_run_vcs53_sync.py`, source a guarded `sync_repo` helper and run real
  `rsync -a --dry-run --itemize-changes` between temporary trees. Seed `.git/`,
  `.worktrees/`, `sim/build/`, root/nested `__pycache__/`, `*.pyc`, plus retained
  `hw/rdma`, `src`, `tests`, `tools`, `sim/filelists` and a path containing a
  space. Assert itemized output contains only retained inputs and destination
  stays empty after dry-run. Source the script once and prove the guarded
  `main()` performs no SSH/rsync work merely because the helper is imported.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_external_dependency_lock \
    tests.unit.test_run_vcs53_sync -v
  ```

  Expected: FAIL because the lock/checker and explicit rsync exclusion array
  do not exist.

- [ ] **Step 3: Implement strict verify/capture modes**

  The checker accepts only these forms:

  ```bash
  python3 tools/check_external_dependency_lock.py verify \
    --lock hw/rdma/external_dependencies.tsv \
    --dependency host_mem --root "$HOST_MEM_ROOT"

  python3 tools/check_external_dependency_lock.py capture \
    --lock hw/rdma/external_dependencies.tsv \
    --dependency dpu_common --root "$DPU_COMMON_ROOT" \
    --candidate /tmp/rdma-external-dpu_common.candidate.tsv
  ```

  Resolve root strictly. Walk every path component with `lstat`, reject symlink
  components/special files, require each final realpath remain below root, and
  parse recursive `` `include `` resolution using the recorded include-dir
  order. Recomputed closure must equal the lock row set exactly. In Git mode,
  require exact HEAD, every closure path tracked, clean staged/unstaged paths,
  and no untracked/ignored file anywhere under an include dir. In snapshot
  mode, require the canonical tree digest; both modes verify every file hash
  and reject shadow/unresolved includes.

  `capture` starts from only the registered direct seeds and include dirs,
  expands the closure, then writes the explicit `/tmp` candidate with mode
  `0600`, `fsync` and atomic rename. Reject repository-relative or symlinked
  candidate destinations. It records actual HEAD in Git mode or `-` in
  snapshot mode, but keeps approval `UNAPPROVED`.

- [ ] **Step 4: Route Make preflights through the lock**

  Remove duplicated host/net commit/hash constants from `sim/Makefile`. Make
  `host_mem_preflight`, `net_packet_preflight`, `dpu_common_preflight`, and
  `pcie_work_preflight` call the checker with their corresponding root. The
  pcie preflight verifies both `host_mem` and `pcie_work`. Keep
  the existing readability checks before the checker so missing files retain
  actionable diagnostics.

  Freeze target dependencies as:

  ```make
  host_mem: host_mem_preflight
  net_packet: net_packet_preflight
  pcie_work: pcie_work_preflight
  integration: dpu_common_preflight
  e2e: host_mem_preflight net_packet_preflight dpu_common_preflight
  ```

  The pcie readability list includes all five PCIe direct sources from
  `sim/filelists/pcie_work.f` plus both host_mem direct sources. `e2e` does not
  consume `PCIE_WORK_ROOT`, so it must not invent a pcie preflight.

  Replace the stale `365b7553...` active pin in `README.md` with
  `3b9e000d...`. In the verification document, preserve the old run as
  historical evidence but label it explicitly as superseded; add the current
  active lock path instead of rewriting a past result.

- [ ] **Step 5: Add sparse rsync exclusions**

  Move script execution into `main()` guarded by
  `[[ ${BASH_SOURCE[0]} == "$0" ]]`, then define `sync_repo <source>
  <destination> [--dry-run]` with exact argument validation and array-based
  option construction:

  ```bash
  readonly RSYNC_EXCLUDES=(
    --exclude=/.git/
    --exclude=/.worktrees/
    --exclude=/sim/build/
    --exclude='**/__pycache__/'
    --exclude='__pycache__/'
    --exclude='*.pyc'
  )

  sync_repo() {
    if [[ $# -lt 2 || $# -gt 3 ]]; then
      printf 'Usage: sync_repo <source> <destination> [--dry-run]\n' >&2
      return 2
    fi

    local source=$1
    local destination=$2
    local mode_arg=${3:-}
    local -a rsync_args=(-a --itemize-changes)

    case "$mode_arg" in
      "")
        ;;

      --dry-run)
        rsync_args+=(--dry-run)
        ;;

      *)
        printf 'Unsupported sync mode: %s\n' "$mode_arg" >&2
        return 2
        ;;
    esac

    rsync "${rsync_args[@]}" "${RSYNC_EXCLUDES[@]}" \
      "$source/" "$destination/"
  }
  ```

  Normal mode therefore omits an empty option, while tests pass `--dry-run`
  explicitly. The production main calls
  `sync_repo "$repo_root" "$REMOTE_HOST:$remote_dir"`; tests call it with
  local paths and `--dry-run`. Move, but otherwise preserve, the current
  allowlisted `remote_env` forwarding and login-shell command construction;
  `HOST_MEM_ROOT`, `DPU_COMMON_ROOT`, `PCIE_WORK_ROOT`, `NET_PACKET_ROOT` and
  `AXIS_VIP_ROOT` remain the only forwarded root variables.

  Do not exclude `hw/rdma`, `tests`, `tools`, `src`, `sim/filelists`, or any
  other simulation input.

- [ ] **Step 6: Run GREEN and capture unapproved candidates**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_external_dependency_lock \
    tests.unit.test_run_vcs53_sync -v
  scripts/run_vcs53.sh core rdma_smoke_test
  ```

  Expected: unit tests and core smoke pass; approved host/net roots verify in
  Git and snapshot fixtures; dpu/pcie preflights exit nonzero with the exact
  unapproved message. This deliberate fail-closed state is not waived.

  On 53, the operator explicitly selects one dpu root and one pcie root, then
  runs `capture` into a new `/tmp/rdma_dependency_candidate.XXXXXX` directory
  and presents exact reports for human review. Multiple different candidate
  checkouts exist on 53, so discovery is never approval. This task does not
  change the `UNAPPROVED` rows.
  Approval is a separate baseline-only commit after explicit user acceptance.

- [ ] **Step 7: Commit the lock mechanism and known pins**

  ```bash
  git add hw/rdma/external_dependencies.tsv \
    tools/check_external_dependency_lock.py \
    tests/unit/test_external_dependency_lock.py \
    tests/unit/test_run_vcs53_sync.py sim/Makefile scripts/run_vcs53.sh \
    README.md docs/rdma-0.1.34-gap-closure-verification.md
  git commit -m "build: lock approved RDMA simulation dependencies"
  ```

### Task 6A: Approve the exact dpu_common input required by integration

**Files:**

- Modify: `hw/rdma/external_dependencies.tsv`

**Interfaces:**

- Consumes Task 6's strict `capture`/`verify` modes and only the
  project-owner-selected `DPU_COMMON_ROOT` candidate.
- Produces one reviewed `APPROVED` dpu_common record set bound to its exact
  commit or snapshot identity, recursive include closure, tree digest and
  per-file hashes.
- Does not approve or modify `pcie_work`, and does not change any external
  repository.

- [ ] **Step 1: Re-capture the candidate and stop for owner approval**

  From the clean implementation worktree mirrored on 53, select the intended
  absolute dpu_common root explicitly and run:

  ```bash
  : "${DPU_COMMON_ROOT:?set the selected absolute 53 dpu_common path}"
  rdma_candidate_dir=$(mktemp -d /tmp/rdma_dependency_candidate.XXXXXX)
  rdma_candidate_path="$rdma_candidate_dir/dpu_common.tsv"
  python3 tools/check_external_dependency_lock.py capture \
    --lock hw/rdma/external_dependencies.tsv \
    --dependency dpu_common \
    --root "$DPU_COMMON_ROOT" \
    --candidate "$rdma_candidate_path"
  sha256sum "$rdma_candidate_path"
  ```

  Present the candidate bytes, root, Git commit or snapshot identity, ordered
  include directories, complete recursive closure, tree digest and every file
  digest to the project owner. Request approval of that exact candidate;
  repository discovery, an old candidate, or approval of a different
  commit/path is not transferable. Preserve the printed candidate path as
  `APPROVED_DPU_CANDIDATE` only after approval.

  Expected: one explicit approve/reject decision tied to the complete
  candidate bytes. Missing or rejected approval blocks this task and all of
  Phase 1A; it is not replaced by a successful compile.

- [ ] **Step 2: Write the approved lock rows without trusting the candidate**

  Immediately before editing, re-run `capture` against the same root and
  byte-compare it with the owner-approved candidate:

  ```bash
  : "${APPROVED_DPU_CANDIDATE:?export the owner-approved candidate path}"
  : "${DPU_COMMON_ROOT:?reuse the approved dpu_common root}"
  rdma_recheck_dir=$(mktemp -d /tmp/rdma_dependency_recheck.XXXXXX)
  rdma_recheck_path="$rdma_recheck_dir/dpu_common.tsv"
  python3 tools/check_external_dependency_lock.py capture \
    --lock hw/rdma/external_dependencies.tsv \
    --dependency dpu_common \
    --root "$DPU_COMMON_ROOT" \
    --candidate "$rdma_recheck_path"
  cmp -- "$APPROVED_DPU_CANDIDATE" "$rdma_recheck_path"
  ```

  Replace only the single dpu_common `UNAPPROVED` seed with that candidate's
  complete rows, changing `approval` to `APPROVED`; transcribe the reviewed
  values with `apply_patch`, not by copying an unchecked temporary file. Keep
  every pcie_work row exactly `UNAPPROVED`.

- [ ] **Step 3: Verify the selected dependency and integration baseline**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_external_dependency_lock -v
  : "${DPU_COMMON_ROOT:?export the exact owner-approved 53 path from Step 1}"
  export DPU_COMMON_ROOT
  scripts/run_vcs53.sh integration rdma_host_mem_router_test
  ```

  Expected: the checker unit suite passes; the integration preflight verifies
  the exact approved dpu_common closure and the existing router test passes
  with zero UVM warning/error/fatal reports. A different root, commit, source
  byte, include shadow or closure fails before compilation.

- [ ] **Step 4: Commit only the approved baseline**

  ```bash
  git add hw/rdma/external_dependencies.tsv
  git commit -m "build: approve dpu_common simulation baseline"
  ```

### Task 7: Enforce sparse Chinese-comment style on changed SV methods

**Files:**

- Create: `tools/check_changed_sv_style.py`
- Create: `tests/unit/test_check_changed_sv_style.py`
- Modify: `sim/Makefile`

**Interfaces:**

- CLI: `python3 tools/check_changed_sv_style.py --base <commit> [--head <commit>]`.
- With no `--head`, the checker examines tracked and untracked `.sv` changes
  against `--base`; with `--head`, it examines the committed range.
- It inspects only added/modified methods and added lines, but loads surrounding
  source context to validate comment adjacency. It never rewrites source.

- [ ] **Step 1: Write RED parser/style tests**

  In a temporary Git repository, add named tests for:

  - a compliant constructor, accessor, task, probe and test helper;
  - missing each of `功能：`, `输入/输出及副作用：`, `失败/边界：`;
  - one shared comment block used for two methods;
  - a changed body whose existing method comment is separated by one blank
    line, proving that blank lines terminate adjacency;
  - a newly added `.sv` file missing each required file-header item: directory/
    layer, responsibility, primary dependencies, and ownership/lifetime;
  - trailing whitespace and an added line over 100 columns; the former is a
    hard error while the latter is a reported soft-limit warning;
  - two assignments/calls/returns on one line;
  - a single-line `if (...) return ...;` even though it contains one returned
    expression;
  - a legal `for (...; ...; ...)` header with exactly two separator semicolons,
    plus semicolons inside a string/comment;
  - a multi-statement `case` branch without `begin/end`;
  - a changed `case` statement with no explicit `default`;
  - a changed `.py` file and an untouched historical long SV line, both ignored;
  - untracked `.sv` input and an invalid/missing base commit;
  - `--head` whose committed blob differs from the current worktree, proving
    that comment context and line contents come from the named commit.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_check_changed_sv_style -v
  ```

  Expected: FAIL because the checker does not exist.

- [ ] **Step 3: Implement diff-aware checks**

  Resolve and validate `--base` and optional `--head` with `git rev-parse
  --verify <rev>^{commit}`. Without `--head`, parse
  `git diff --unified=0 --no-ext-diff --diff-filter=ACMR <base> --` plus
  `git ls-files --others --exclude-standard -- '*.sv'`, and read context from
  the working tree. With `--head`, parse the committed `<base>..<head>` diff
  and read every source context using `git show <head>:<path>`; never inspect
  the possibly different working-tree file in this mode.

  Strip comments and string literals before counting statements. A legal
  `for (init; condition; step)` header has two separator semicolons and is the
  only multi-semicolon statement exception. Reject a one-line
  `if (...) return ...;`, multiple assignments/calls/returns on one line,
  multi-statement `case` branches without `begin/end`, and every changed
  `case` block lacking an explicit `default`.

  For every method containing a changed line, require a contiguous,
  method-exclusive comment block immediately above the declaration. The block
  contains all three exact labels and may use consecutive continuation comment
  lines, but the first blank or code line terminates the search. For every new
  `.sv`, separately validate the complete leading file header contains the
  directory/layer, file responsibility, primary dependencies, and ownership/
  lifetime statements required by `AGENTS.md`.

  Emit one stable diagnostic per violation:

  ```text
  path/to/file.sv:123: changed SV line contains multiple statements
  path/to/file.sv:456: function/task lacks adjacent 功能/输入输出及副作用/失败边界 comments
  ```

  Hard diagnostics exit nonzero. Lines over 100 columns emit a stable
  `soft-limit` diagnostic for reviewer attention but do not alone change the
  exit code; the checker does not invent a tab ban or waiver syntax absent from
  `AGENTS.md`. `git diff --check` remains the authority for trailing
  whitespace.

- [ ] **Step 4: Add the Make gate and run GREEN**

  Add:

  ```make
  sv_style:
	python3 ../tools/check_changed_sv_style.py --base "$${STYLE_BASE:?STYLE_BASE is required}"
	git diff --check "$${STYLE_BASE}"
  ```

  Run:

  ```bash
  python3 -m unittest tests.unit.test_check_changed_sv_style -v
  make -C sim sv_style STYLE_BASE=cc07586
  ```

  Expected: unit tests pass. The repository-wide invocation may initially
  report precise violations in already dirty, non-plan changes; do not edit or
  stage those user-owned files. During execution, run the gate from the clean
  isolated worktree required by Global Constraints.

- [ ] **Step 5: Commit the style gate**

  ```bash
  git add tools/check_changed_sv_style.py \
    tests/unit/test_check_changed_sv_style.py sim/Makefile
  git commit -m "test: enforce sparse style on changed SystemVerilog"
  ```

### Task 7A: Add the fail-closed Phase 1A approval preflight

**Files:**

- Create: `tools/check_rdma_phase1a_approval.py`
- Create: `tests/unit/test_check_rdma_phase1a_approval.py`

**Interfaces:**

- CLI: `python3 tools/check_rdma_phase1a_approval.py [--staged]`.
- Default mode validates the committed artifact and current plan; `--staged`
  validates the index candidate immediately before the one-file approval
  commit. Neither mode creates or modifies a file.
- The parser exposes an immutable `Phase1AApproval` value and accepts exactly
  the ten ordered keys defined by the approval table above.

- [ ] **Step 1: Write RED parser, Git-binding and CLI tests**

  Test a valid synthetic approval through an injected read-only Git command
  runner. Add separate failures for missing/untracked/dirty artifact, blank or
  comment line, unknown/missing/duplicate/reordered key, CRLF, whitespace
  around `=`, malformed commit/hash/approver/timestamp, any decision other than
  exact `APPROVED`, missing plan commit, non-ancestor commit, wrong first
  parent, extra path in the plan commit, wrong plan path, committed-blob hash
  drift and current-plan hash drift.

  In default mode require `git ls-files --error-unmatch` success and no
  worktree/index diff for the artifact. In `--staged` mode require the artifact
  to be the only staged path and read its bytes from `git show :<path>`; still
  require the plan itself to be tracked, clean and byte-equal to the recorded
  commit. Mock only the command runner, not parser/hash behavior, so byte and
  ordering tests exercise production code.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_check_rdma_phase1a_approval -v
  ```

  Expected: FAIL because the checker does not exist.

- [ ] **Step 3: Implement strict parsing and Git evidence checks**

  Read files as bytes, reject UTF-8 BOM/CRLF/non-UTF-8, require one terminal
  LF and no other blank/comment lines, then parse the exact ordered key set.
  Use `hashlib.sha256` on raw plan bytes. Invoke Git with argument arrays and
  capture raw stdout: resolve the recorded commit with
  `rev-parse --verify <commit>^{commit}`, require
  `merge-base --is-ancestor <commit> HEAD`; resolve `cc07586^{commit}` and
  compare its full 40-hex result with the recorded commit's first parent; then
  require `diff-tree --no-commit-id --name-only -r <commit>` to contain only the
  exact plan path. Read the frozen blob with
  `git show <commit>:<path>` and never through a shell.

  Default mode reads the tracked worktree artifact only after proving both
  index and worktree clean. `--staged` reads the index blob and requires
  `git diff --cached --name-only` to contain only the artifact. Both modes emit
  one stable diagnostic on stderr and exit nonzero for every failure; success
  prints the plan commit, plan SHA-256, approver and four approved decisions.
  No option may waive ancestry, plan-byte or decision checks.

- [ ] **Step 4: Run GREEN**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_check_rdma_phase1a_approval -v
  ```

  Expected: all parser, Git-binding and CLI tests pass. Do not run the default
  checker against the real repository yet; the deliberately absent approval
  artifact must remain a hard failure until the next checkpoint.

- [ ] **Step 5: Commit the approval checker**

  ```bash
  git add tools/check_rdma_phase1a_approval.py \
    tests/unit/test_check_rdma_phase1a_approval.py
  git commit -m "test: gate CMQ Phase 1A on design approval"
  ```

### Approval checkpoint: Record explicit Phase 1A refinement approval

**Files:**

- Create: `docs/superpowers/approvals/2026-09-11-rdma-cmq-contract-foundation-phase1a.env`

Create this file only after explicit project-owner approval.

- [ ] **Step 1: Present the exact refinement matrix and stop for approval**

  Present the four rows in **Design refinements and Phase 1A execution approval
  gate**, the exact plan commit/hash obtained from read-only Git commands, and
  request an explicit project-owner identity plus an approve/reject decision
  for every row. Do not infer approval from earlier discussion. A rejection or
  missing answer ends execution before Task 8.

- [ ] **Step 2: Create and stage the bound artifact**

  Recheck that `git rev-parse --verify cc07586^{commit}` returns the expected
  full 40-hex baseline, that the plan commit has that exact first parent,
  changes only this plan path, is an ancestor of current `HEAD`, and that the
  current plan bytes equal that commit's blob. Use `apply_patch` to create the
  ten-line artifact
  in the exact key order and grammar above, inserting the actual approved
  commit, SHA-256, owner ID and UTC timestamp. Do not record a password, token,
  free-form comment or unapproved decision.

  Stage only the artifact, then run:

  ```bash
  git add \
    docs/superpowers/approvals/2026-09-11-rdma-cmq-contract-foundation-phase1a.env
  python3 tools/check_rdma_phase1a_approval.py --staged
  git diff --cached --check
  git diff --cached --name-only
  ```

  Expected: the checker succeeds and `name-only` prints exactly the approval
  artifact path.

- [ ] **Step 3: Commit and revalidate the durable approval**

  ```bash
  git commit -m "docs: approve CMQ Phase 1A refinements"
  python3 tools/check_rdma_phase1a_approval.py
  ```

  Expected: committed mode prints the same plan commit/hash, approver and four
  decisions. Any later change to the plan or artifact closes the gate again
  and requires a newly reviewed plan plus a new approval record; do not amend
  values automatically.

---

## Phase 1A — Per-call submission evidence and batch journal

Before Step 1 of every Task 8–18, run:

```bash
python3 tools/check_rdma_phase1a_approval.py
```

Expected: PASS against the committed, clean artifact and the unchanged plan
blob. Failure stops that task before any source edit, compile or simulation.

### Task 8: Add the shared submission-effect value vocabulary

**Files:**

- Create: `src/model/rdma_submission_evidence.sv`
- Modify: `src/model/rdma_model_pkg.sv`
- Modify: `tests/unit/rdma_cmq_engine_models_test.sv`
- Modify: `docs/superpowers/specs/2026-09-11-rdma-engine-contract-refactoring-design.md`

**Interfaces:**

```systemverilog
typedef enum logic [2:0] {
  RDMA_SUBMIT_EFFECT_UNOBSERVED,
  RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
  RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
  RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
  RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED,
  RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
  RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
} rdma_submission_effect_e;

function automatic bit rdma_submission_effect_is_monotonic(
  input rdma_submission_effect_e before_effect,
  input rdma_submission_effect_e after_effect
);
```

`UNOBSERVED` and `PRE_SUBMIT_REJECTED` are terminal branches. Only the five
Host-memory/MMIO stages can advance numerically; no value can regress.

- [ ] **Step 1: Add RED ordering tests**

  Add `check_submission_effect_ordering()` and call it from `run_phase()`:

  ```systemverilog
  if (!rdma_submission_effect_is_monotonic(
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
        RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE))
    `uvm_error("EFFECT_FORWARD", "forward effect was rejected")

  if (rdma_submission_effect_is_monotonic(
        RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED))
    `uvm_error("EFFECT_REGRESSION", "effect regression was accepted")

  if (rdma_submission_effect_is_monotonic(
        RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE))
    `uvm_error("EFFECT_TERMINAL", "pre-submit rejection was reopened")

  if (rdma_submission_effect_is_monotonic(
        RDMA_SUBMIT_EFFECT_UNOBSERVED,
        RDMA_SUBMIT_EFFECT_MMIO_VISIBLE))
    `uvm_error("EFFECT_UNOBSERVED", "unknown evidence was promoted")

  unknown_effect = rdma_submission_effect_e'(3'bx);
  if (rdma_submission_effect_is_monotonic(
        unknown_effect, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE) ||
      rdma_submission_effect_is_monotonic(
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN, unknown_effect))
    `uvm_error("EFFECT_X", "four-state unknown evidence was accepted")
  ```

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_models_test
  ```

  Expected: compile failure because the enum and helper are undefined.

- [ ] **Step 3: Implement the pure value contract**

  Add the four-state enum and reject `$isunknown(before_effect)` or
  `$isunknown(after_effect)` before the explicit `case`:

  ```systemverilog
  case (before_effect)
    RDMA_SUBMIT_EFFECT_UNOBSERVED:
      return after_effect == RDMA_SUBMIT_EFFECT_UNOBSERVED;

    RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED:
      return after_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;

    default: begin
      if (!(after_effect inside {
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED,
            RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
            RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
          }))
        return 1'b0;

      return after_effect >= before_effect;
    end
  endcase
  ```

  Include `rdma_submission_evidence.sv` immediately after
  `rdma_context_models.sv` and before `rdma_cmq_engine_models.sv`.
  Amend spec section 5.1 from `enum bit` to `enum logic` in this commit and
  state that the four-state base is intentional: persisted/recovery-facing
  evidence must reject X/Z rather than silently coerce it to UNOBSERVED.

- [ ] **Step 4: Run GREEN**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_models_test
  ```

  Expected: PASS with zero UVM warning/error/fatal reports.

- [ ] **Step 5: Commit the shared vocabulary**

  ```bash
  git add src/model/rdma_submission_evidence.sv src/model/rdma_model_pkg.sv \
    tests/unit/rdma_cmq_engine_models_test.sv \
    docs/superpowers/specs/2026-09-11-rdma-engine-contract-refactoring-design.md
  git commit -m "feat: add RDMA submission effect evidence" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 9: Add recovery owner, execution, journal and recovery value models

**Files:**

- Create: `src/model/rdma_cmq_execution_models.sv`
- Modify: `src/model/rdma_cmq_engine_models.sv`
- Modify: `src/model/rdma_function_binding.sv`
- Modify: `src/model/rdma_model_pkg.sv`
- Modify: `src/codec/rdma_cmq_hw_profile.sv`
- Modify: `src/codec/rdma/rdma_cmq_hw_profile.sv`
- Modify: `tests/unit/rdma_cmq_engine_models_test.sv`
- Modify: `tests/unit/rdma_cmq_profile_test.sv`
- Modify: `tests/unit/rdma_function_identity_test.sv`
- Modify: `docs/superpowers/specs/2026-09-11-rdma-engine-contract-refactoring-design.md`

**Interfaces:**

Define these declarations before `rdma_cmq_command_desc` in
`rdma_cmq_engine_models.sv`, because the command owns a nullable field of the
new owner type:

```systemverilog
typedef enum logic [2:0] {
  RDMA_CMQ_WORKFLOW_INVALID,
  RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED,
  RDMA_CMQ_WORKFLOW_MR,
  RDMA_CMQ_WORKFLOW_QUEUE,
  RDMA_CMQ_WORKFLOW_QP
} rdma_cmq_recovery_workflow_e;

typedef enum logic [1:0] {
  RDMA_CMQ_RECOVERY_INVALID,
  RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
  RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION
} rdma_cmq_submission_recovery_action_e;

class rdma_cmq_recovery_owner extends uvm_object;
  rdma_cmq_recovery_workflow_e workflow;
  rdma_handle resource_h;
  longint unsigned transaction_id;
  logic [2:0] allowed_actions;
  rdma_function_identity function_identity;
  longint unsigned admission_attempt_id;
  bit frozen;

  static function rdma_cmq_recovery_owner legacy_unmigrated();
  function rdma_status validate_for_admission();
  function rdma_status freeze_for_journal(
    input rdma_function_identity identity,
    input longint unsigned frozen_admission_attempt_id
  );
  function rdma_status validate_frozen(
    input rdma_function_identity expected_identity,
    input longint unsigned expected_admission_attempt_id
  );
  function bit permits(input rdma_cmq_submission_recovery_action_e action);
endclass
```

`rdma_cmq_command_desc` gains:

```systemverilog
rdma_cmq_recovery_owner recovery_owner;

function rdma_status validate_for_journal(
  input rdma_function_identity expected_identity,
  input longint unsigned expected_admission_attempt_id
);
```

Its constructor assigns `legacy_unmigrated()`, `do_copy()` deep-copies the
owner, and `validate()` rejects a null/invalid owner. The sentinel is valid for
ordinary admission, has null resource/identity, zero transaction/attempt,
`allowed_actions == 0`, and can never be promoted from opcode or status.
`validate_for_journal()` validates the existing command fields without
reapplying the unfrozen admission rule, then accepts either the exact unchanged
legacy sentinel or a concrete owner whose `validate_frozen()` matches the
expected identity/admission attempt.

Create the remaining values in `rdma_cmq_execution_models.sv`:

```systemverilog
typedef enum logic [2:0] {
  RDMA_CMQ_COMPLETION_NONE,
  RDMA_CMQ_COMPLETION_PENDING,
  RDMA_CMQ_COMPLETION_TERMINAL,
  RDMA_CMQ_COMPLETION_TIMEOUT,
  RDMA_CMQ_COMPLETION_RESET_CANCELLED,
  RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
  RDMA_CMQ_COMPLETION_UNOBSERVED
} rdma_cmq_completion_phase_e;

typedef enum logic [3:0] {
  RDMA_CMQ_SUBMISSION_STAGED,
  RDMA_CMQ_SUBMISSION_PENDING_EFFECT,
  RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED,
  RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
  RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED,
  RDMA_CMQ_SUBMISSION_COMPLETED,
  RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
  RDMA_CMQ_SUBMISSION_LATE_COMPLETED,
  RDMA_CMQ_SUBMISSION_RESET_QUARANTINED
} rdma_cmq_submission_state_e;

typedef bit [255:0] rdma_cmq_journal_digest_t;

typedef class rdma_cmq_reset_isolation_proof;
```

Add factory-registered value classes with these exact owned fields:

```systemverilog
class rdma_cmq_command_identity extends uvm_object;
  rdma_resource_kind_e function_kind;
  longint unsigned function_uid;
  int unsigned global_function_id;
  int unsigned generation;
  string profile_name;
  bit [31:0] opcode;
  string variant;

  function bit capture_from(
    input rdma_cmq_command_desc command,
    output string failure_reason
  );
endclass

class rdma_cmq_execution_result extends uvm_object;
  rdma_cmq_ticket ticket;
  rdma_cmq_completion completion;
  rdma_status status;
  rdma_status observation_status;
  rdma_cmq_command_identity command_identity;
  rdma_cmq_recovery_owner recovery_owner;
  rdma_dma_request_context dma_context;
  rdma_submission_effect_e submission_effect;
  rdma_submission_effect_e attempt_effect;
  rdma_cmq_completion_phase_e completion_phase;
  string batch_key;
  longint unsigned batch_id;
  longint unsigned attempt_id;
  bit recovery_required;
endclass

class rdma_cmq_batch_submission_item_record extends uvm_object;
  int unsigned request_index;
  rdma_cmq_command_desc command;
  rdma_cmq_ticket ticket;
  rdma_cmq_recovery_owner recovery_owner;
  rdma_dma_request_context dma_context;
  rdma_hw_image sqe_image;
  rdma_dma_mapping dependency_mapping;
  longint unsigned dependency_offset;
  rdma_hw_image dependency_image;
  longint unsigned slot_sequence;
  int unsigned slot_index;
  bit slot_wrap;
  bit [4:0] command_token;
  bit [58:0] token_incarnation;
  string entry_key;
  rdma_cmq_journal_digest_t image_digest;
  rdma_cmq_journal_digest_t authority_digest;
  bit dependency_replay_safe;
  rdma_cmq_submission_state_e state;
  rdma_submission_effect_e submission_effect;
  rdma_submission_effect_e attempt_effect;
  rdma_cmq_completion_phase_e completion_phase;
  bit reset_isolation_confirmed;
  bit recovery_required;
  rdma_cmq_completion completion;
  rdma_status status;
endclass

class rdma_cmq_batch_submission_record extends uvm_object;
  string batch_key;
  longint unsigned batch_id;
  longint unsigned attempt_id;
  longint unsigned engine_instance_id;
  longint unsigned engine_incarnation;
  rdma_function_identity function_identity;
  rdma_function_binding binding;
  rdma_handle cmq_h;
  longint unsigned start_sequence;
  longint unsigned end_sequence;
  rdma_hw_image doorbell_image;
  int unsigned final_pi;
  bit final_polarity;
  rdma_cmq_journal_digest_t batch_digest;
  rdma_cmq_submission_state_e state;
  rdma_submission_effect_e submission_effect;
  rdma_submission_effect_e attempt_effect;
  bit observer_armed;
  bit publication_retry_safe;
  rdma_cmq_batch_submission_item_record items[$];
  rdma_cmq_reset_isolation_proof reset_isolation_proof;
endclass

class rdma_cmq_submission_recovery_item extends uvm_object;
  int unsigned request_index;
  rdma_cmq_command_desc command;
  rdma_cmq_ticket ticket;
  rdma_cmq_recovery_owner recovery_owner;
  rdma_dma_request_context dma_context;
  rdma_hw_image sqe_image;
  rdma_dma_mapping dependency_mapping;
  longint unsigned dependency_offset;
  rdma_hw_image dependency_image;
  rdma_cmq_journal_digest_t image_digest;
  rdma_cmq_journal_digest_t authority_digest;
endclass

typedef enum logic [1:0] {
  RDMA_CMQ_RESET_PROOF_INVALID,
  RDMA_CMQ_RESET_PROOF_AWAITING_REBIND,
  RDMA_CMQ_RESET_PROOF_READY
} rdma_cmq_reset_isolation_proof_state_e;

class rdma_cmq_reset_isolation_proof extends uvm_object;
  string proof_key;
  longint unsigned proof_id;
  string batch_key;
  longint unsigned batch_id;
  longint unsigned attempt_id;
  longint unsigned engine_instance_id;
  longint unsigned engine_incarnation;
  rdma_function_identity isolated_identity;
  rdma_function_identity replacement_identity;
  rdma_cmq_journal_digest_t batch_digest;
  int unsigned isolated_request_indices[$];
  rdma_cmq_journal_digest_t isolated_image_digests[$];
  rdma_cmq_journal_digest_t isolated_authority_digests[$];
  rdma_cmq_recovery_owner isolated_recovery_owners[$];
  rdma_cmq_journal_digest_t proof_digest;
  rdma_cmq_reset_isolation_proof_state_e state;
  bit backing_release_confirmed;
endclass

class rdma_cmq_submission_recovery_request extends uvm_object;
  string batch_key;
  longint unsigned batch_id;
  longint unsigned expected_attempt_id;
  rdma_function_identity expected_function_identity;
  rdma_function_binding binding;
  rdma_handle cmq_h;
  longint unsigned start_sequence;
  longint unsigned end_sequence;
  rdma_hw_image doorbell_image;
  int unsigned final_pi;
  bit final_polarity;
  rdma_cmq_journal_digest_t batch_digest;
  rdma_cmq_submission_recovery_action_e action;
  rdma_cmq_reset_isolation_proof reset_isolation_proof;
  rdma_cmq_submission_recovery_item items[$];
endclass

class rdma_cmq_canonical_writer;
  protected byte unsigned buffer[$];

  function new();
  function void clear();
  function bit append_u8(input logic [7:0] value);
  function bit append_u16(input logic [15:0] value);
  function bit append_u32(input logic [31:0] value);
  function bit append_u64(input logic [63:0] value);
  function bit append_digest(input logic [255:0] value);
  function bit append_raw(input byte unsigned value[]);
  function bit append_counted_bytes(input byte unsigned value[]);
  function bit append_string(input string value);
  function bit append_object_header(
    input logic present,
    input string schema_tag
  );
  function void snapshot(output byte unsigned value[]);
endclass

function automatic rdma_cmq_journal_digest_t rdma_cmq_digest_bytes(
  input byte unsigned canonical_bytes[]
);

function automatic rdma_status rdma_cmq_compute_item_digests(
  input rdma_cmq_command_desc command,
  input string command_body_schema_tag,
  input byte unsigned command_body_field_bytes[],
  input rdma_cmq_ticket ticket,
  input rdma_cmq_recovery_owner recovery_owner,
  input rdma_function_identity function_identity,
  input rdma_dma_request_context dma_context,
  input rdma_hw_image sqe_image,
  input rdma_dma_mapping dependency_mapping,
  input longint unsigned dependency_offset,
  input rdma_hw_image dependency_image,
  output rdma_cmq_journal_digest_t image_digest,
  output rdma_cmq_journal_digest_t authority_digest
);

function automatic rdma_status rdma_cmq_compute_batch_digest(
  input rdma_function_identity function_identity,
  input rdma_function_binding binding,
  input rdma_handle cmq_h,
  input rdma_hw_image doorbell_image,
  input int unsigned final_pi,
  input bit final_polarity,
  input longint unsigned start_sequence,
  input longint unsigned end_sequence,
  input int unsigned request_indices[$],
  input rdma_cmq_journal_digest_t image_digests[$],
  input rdma_cmq_journal_digest_t authority_digests[$],
  output rdma_cmq_journal_digest_t batch_digest
);

function automatic rdma_status rdma_cmq_compute_reset_proof_digest(
  input string proof_key,
  input longint unsigned proof_id,
  input string batch_key,
  input longint unsigned batch_id,
  input longint unsigned attempt_id,
  input longint unsigned engine_instance_id,
  input longint unsigned engine_incarnation,
  input rdma_function_identity isolated_identity,
  input rdma_cmq_journal_digest_t batch_digest,
  input int unsigned request_indices[$],
  input rdma_cmq_journal_digest_t image_digests[$],
  input rdma_cmq_journal_digest_t authority_digests[$],
  input rdma_cmq_recovery_owner recovery_owners[$],
  output rdma_cmq_journal_digest_t proof_digest
);

function automatic rdma_status rdma_cmq_reduce_batch_state(
  input rdma_cmq_batch_submission_item_record items[$],
  output rdma_cmq_submission_state_e state
);

function automatic bit rdma_cmq_fold_attempt_effect(
  input rdma_submission_effect_e prior_cumulative,
  input rdma_submission_effect_e current_attempt,
  output rdma_submission_effect_e cumulative
);

function automatic rdma_status rdma_cmq_classify_recovery_required(
  input rdma_cmq_submission_state_e state,
  input rdma_cmq_completion_phase_e completion_phase,
  input rdma_submission_effect_e submission_effect,
  input bit reset_isolation_confirmed,
  input bit legacy_unmigrated,
  output bit recovery_required
);

class rdma_cmq_nonfatal_snapshot_context;
  protected rdma_status status_snapshots[rdma_status];
  protected rdma_cmq_ticket ticket_snapshots[rdma_cmq_ticket];
  protected rdma_cmq_recovery_owner owner_snapshots[rdma_cmq_recovery_owner];

  function new();

  function bit try_snapshot_required_status(
    input rdma_status source,
    output rdma_status snapshot,
    output string failure_reason
  );

  function bit try_snapshot_optional_ticket(
    input rdma_cmq_ticket source,
    output rdma_cmq_ticket snapshot,
    output string failure_reason
  );

  function bit try_snapshot_recovery_owner(
    input rdma_cmq_recovery_owner source,
    output rdma_cmq_recovery_owner snapshot,
    output string failure_reason
  );

  function bit try_snapshot_completion_shell(
    input rdma_cmq_completion source,
    input uvm_object detached_payload,
    output rdma_cmq_completion snapshot,
    output string failure_reason
  );
endclass
```

The base `rdma_cmq_hw_profile` also gains the only layer-legal polymorphic
canonicalization seam; model helpers never cast to concrete codec-layer body
types:

```systemverilog
virtual function rdma_status canonicalize_command_body(
  input rdma_hw_model source,
  output string schema_tag,
  output byte unsigned canonical_field_bytes[]
);
```

The base implementation clears both outputs and returns
`RDMA_SC_UNSUPPORTED_OPCODE`. The production RDMA profile recognizes exactly
the five body schemas frozen below, validates the typed value, and returns only
the bytes after the stable type tag. Callers obtain these outputs afresh from
the actual request-owned or journal-owned body and pass them to
`rdma_cmq_compute_item_digests()`; no carried tag/byte array is trusted.

`rdma_function_binding` gains the layer-local, status-returning accessors needed
to detach its protected identity and complete value without a fatal factory
path:

```systemverilog
function rdma_status snapshot_identity_nonfatal(
  output rdma_function_identity snapshot
);

function rdma_status snapshot_complete_nonfatal(
  output rdma_function_binding snapshot
);
```

Both clear the output on entry, direct-construct every nested value, validate
the finished candidate and publish only on success. The existing legacy
`function_identity_snapshot()/identity_snapshot()/get_identity()` signatures
remain compatible but delegate to the nonfatal identity seam and return null
on failure; they no longer invoke `clone()` or emit UVM fatal.

The complete snapshot preserves the supported runtime type of `owner_h`:
direct-construct `rdma_function_handle` for that subtype and base
`rdma_handle` for an exact base handle. Reject any other subtype nonfatally;
never flatten a Function handle into the base type merely because its public
fields compare equal. Only the constructor-owned default identity, PCIe value
and six BAR values stop participating in factory override. Callers may still
factory-create the outer binding, and lazy legacy/configuration paths outside
these two snapshot accessors retain their existing factory behavior.

Every constructor that owns `status` or `observation_status` direct-constructs
each value and initializes category, code, severity, hardware/source identity
and message to one explicit `RDMA_SC_INVALID_STATE` fail-closed shape. The
current `rdma_status::new()` default is OK and therefore is not an acceptable
result-model default. Only a completed operation or completed evidence capture
may replace the corresponding field with OK. `status` is the detached
command/legacy operation result; `observation_status` reports whether the
observed envelope and all evidence fields were captured faithfully. A payload
snapshot failure must not overwrite a valid operation status.

Freeze the production observation table independently of operation outcome:

| Production path | operation `status` | `observation_status` |
| --- | --- | --- |
| Reliable success or reliable command/hardware failure | exact operation result | `OK` |
| Reliable timeout, reset cancellation or late diagnostic | exact lifecycle result | `OK` |
| Null/malformed result, status, snapshot or observed envelope after delegation | preserve any valid operation result; otherwise fail-closed `INVALID_STATE` | `INVALID_STATE` |
| Observer/effect/state contradiction | preserve scheduler/operation status | `INVALID_STATE` |

Observation failure never overwrites operation status, never changes either
effect, and never fabricates a completion phase. Later completion, timeout,
late or reset lifecycle updates may change status/phase/recovery state but
must not rewrite the retained `submission_effect` or `attempt_effect`.

Classes that contain a polymorphic command body or completion payload must not
claim that generic UVM `copy()/clone()/do_copy()` is a nonfatal deep-copy
boundary: those methods have neither a profile argument nor a status return.
Production journal/result/query/recovery paths use the explicit status-returning
typed snapshot boundary introduced below and in Task 13. Leaf values may
implement direct-new `do_copy()`, but no production control path relies on it.

`recovery_required` means the caller may not treat the operation as proven
absent or fully resolved. It does not by itself promise that automatic engine
recovery is available: `recover_submission_observed()` additionally requires
nonzero batch/attempt identity, a concrete frozen recovery owner and matching
journal authority. Thus a legacy `UNOBSERVED` result sets the bit but remains a
manual/conservative reconcile case.

The bit is stored on both each journal item and each returned result and is
derived from lifetime state, never from status or the current attempt alone:

| Lifetime state / phase | `recovery_required` |
| --- | --- |
| Initial local `PRE_SUBMIT_REJECTED/NONE` with no retained journal | `0` |
| `HOST_VISIBLE_NOT_PUBLISHED/NONE` | `1` |
| `PUBLISH_AMBIGUOUS` or `PUBLISH_CONFIRMED` with `PENDING` | `1` |
| `TIMED_OUT_QUARANTINED/TIMEOUT` | `1` |
| `RESET_QUARANTINED/RESET_CANCELLED` with a concrete owner and proof AWAITING_REBIND or READY but unconfirmed | `1` |
| `RESET_QUARANTINED/RESET_CANCELLED` for the exact legacy sentinel after confirmed backing release | `0` |
| `COMPLETED/TERMINAL`, `LATE_COMPLETED/DIAGNOSTIC_ONLY`, or successful reset-isolation confirmation | `0` |
| Any `UNOBSERVED` result or malformed/degraded post-delegation evidence | `1` |

Each journal item also owns the authoritative detached lifecycle
`completion`. It is null only while phase is `NONE` or `PENDING`; TERMINAL,
TIMEOUT, RESET_CANCELLED and DIAGNOSTIC_ONLY retain the exact non-null
completion that public wait/reconcile/execute projections snapshot. FIFO rows
may remain delivery-order indexes, but popping a FIFO must never destroy this
journal evidence.

A retry rejected before I/O keeps the retained item's prior value; in
particular, `attempt_effect=PRE_SUBMIT_REJECTED` cannot clear a recovery bit
belonging to an earlier Host-visible or UNOBSERVED attempt.

For a normal initial scheduler envelope,
`submission_effect == attempt_effect`. If that envelope is null/malformed after
an authentic arm callback, raw `attempt_effect=UNOBSERVED` records the envelope
loss while cumulative `submission_effect` incorporates the callback's
`MMIO_MAYBE_VISIBLE` evidence. On recovery, `attempt_effect` describes only the
scheduler attempt made by that API call, while `submission_effect` is the
cumulative conservative high-water evidence for the command lifetime. A retry
rejected before I/O may report
`attempt_effect=PRE_SUBMIT_REJECTED`, but it cannot regress an earlier
Host-visible `submission_effect` or make hardware presence absent. Journal item
and batch records retain both values.

`recovery_owner.admission_attempt_id` is immutable provenance: it identifies
the first attempt that admitted and froze that owner. Later CAS retries advance
the batch/current attempt ID but never rewrite the owner. The exact
`LEGACY_UNMIGRATED` sentinel stays unfrozen with admission attempt zero and
permits no automated recovery action.

`rdma_cmq_nonfatal_snapshot_context` is constructed with direct `new`; it is
not factory registered. Its methods reset both output arguments on entry, use
direct `new` plus explicit scalar/byte copying, and never call the existing
fatal clone helpers. A required null status returns `0` with a stable non-empty
reason. A null optional ticket and a null completion each return `1`, publish a
null snapshot and leave the reason empty. The context caches status and ticket
snapshots by source object identity, so a source graph where
`outer_ticket == completion.ticket` or `outer_status == completion.status`
retains that alias topology inside the detached destination graph.

`try_snapshot_completion_shell()` receives an already detached payload from a
typed caller hook. It requires null source payload to pair with null detached
payload, and non-null source payload to pair with a non-null, non-aliased
detached payload. It copies the completion shell, canonical ticket/status and
raw CQE bytes without cloning the polymorphic object. Production engine paths
continue using the profile's checked payload snapshot before constructing
their observed result.

`try_snapshot_recovery_owner()` is the corresponding canonicalization seam for
frozen owner nodes. It direct-constructs the owner, resource handle and
Function identity, validates the complete frozen value before publication, and
caches by source handle. When a journal item command and its item-level
`recovery_owner` refer to one source node, a detached query therefore refers to
one new owner node in both places; that node never aliases the source graph.

`RDMA_CMQ_COMPLETION_UNOBSERVED` is appended without renumbering the six values
already frozen in spec section 5.1. This is an explicit design refinement for
any wrapper that lacks trustworthy lifecycle evidence: a legacy `execute()`
result and a production post-delegation null/malformed result both use it.
`NONE` remains reserved for a path that positively knows no completion exists,
including a pre-engine rejection or unarmed Host-visible journal state. Task 9
must append the same value and rationale to the design spec in the value-model
commit. In the same spec change, section 5.2 adds the
non-null detached `observation_status` field and freezes its separation from
the operation `status`: observation failure never erases valid legacy outputs,
and neither status is used to infer submission effect or completion phase.

- [ ] **Step 1: Run the existing binding/PCIe characterization baseline**

  Before editing any Task 9 source or test, run:

  ```bash
  scripts/run_vcs53.sh core rdma_model_test
  ```

  Expected: PASS with the existing binding, PCIe, six-BAR and typed Function
  handle construction/clone behavior intact. A failure is a pre-existing
  blocker; do not begin the RED edit until it is understood.

- [ ] **Step 2: Write RED owner and value-model tests**

  Add `check_recovery_owner_contract()` and
  `check_execution_value_defaults()`, `check_journal_digest_contract()`,
  `check_batch_state_reducer()`, `check_attempt_effect_fold()`,
  `check_recovery_required_classifier()` and `check_reset_proof_value()`.
  Cover the exact
  sentinel shape, concrete MR/queue/QP owners, duplicate freeze, zero attempt,
  identity/resource mismatch, the reserved INVALID/spare enum encodings, and
  action denial. Freeze the workflow/resource-kind matrix as MR -> MR,
  QP -> QP, and QUEUE -> one of CQ/SRQ/CEQ/AEQ. Reject every cross-workflow
  combination plus FUNCTION, PD, CMQ and MW. Cover `allowed_actions[0]`
  illegally set for INVALID, an unknown bit in the four-state mask, no legal
  bit set, an X/Z action and a cast spare action value `2'b11`; `permits()`
  must reject unknown/INVALID/spare before indexing the three-bit mask.
  Include these assertions:

  ```systemverilog
  owner = rdma_cmq_recovery_owner::legacy_unmigrated();
  expect_status("LEGACY_OWNER_VALID",
                owner.validate_for_admission(), RDMA_SC_OK);

  owner.allowed_actions[RDMA_CMQ_RECOVERY_RETRY_PUBLISH] = 1'b1;
  expect_status("LEGACY_OWNER_NO_ACTION",
                owner.validate_for_admission(), RDMA_SC_INVALID_ARGUMENT);

  result = new("uninitialized_result");
  if (result.status == null || result.status.ok() ||
      result.status.code != RDMA_SC_INVALID_STATE ||
      result.observation_status == null ||
      result.observation_status.ok() ||
      result.observation_status.code != RDMA_SC_INVALID_STATE)
    `uvm_error("EXECUTION_DEFAULT",
               "new execution result defaulted to success or null status")
  ```

  Repeat the default-status assertion for every new class that owns a status.
  Full graph detachment—including polymorphic command body and completion
  payload—is tested against Task 13's status-returning engine snapshot seam,
  not generic UVM `copy()`. Exercise
  mixed item states (`COMPLETED + PUBLISH_CONFIRMED`,
  `TIMED_OUT_QUARANTINED + COMPLETED`, all completed, completed + late, and
  reset quarantine), plus impossible pre-MMIO/published mixtures.

  Exercise all seven completion-phase encodings, reject spare numeric value
  `3'b111`, and reject an X/Z phase before any array/state indexing; in
  particular, do not alias `UNOBSERVED` to `NONE`.

  Exercise every row of the recovery-required table through
  `rdma_cmq_classify_recovery_required()`, including RESET_QUARANTINED before
  READY, after READY but before confirmation, and after successful
  confirmation. Pre-seed the output and prove unknown/spare state, phase or
  effect returns non-OK without changing it.

  For the cross-attempt fold, assert: prior concrete Host/MMIO plus current
  `PRE_SUBMIT_REJECTED` or `UNOBSERVED` keeps prior; two concrete Host/MMIO
  values select their numeric maximum; prior `UNOBSERVED` plus a concrete
  Host/MMIO value selects the concrete value; prior `UNOBSERVED` plus current
  PRE/UNOBSERVED stays `UNOBSERVED`. Reject prior `PRE_SUBMIT_REJECTED`, spare
  enums and unknown bits without changing a pre-seeded output.

  Construct one `rdma_cmq_nonfatal_snapshot_context` directly and pre-seed
  every output/reason before each call. Required status null must fail with a
  null output and non-empty stable reason; optional ticket null and completion
  null must succeed with null output and empty reason. A null-payload
  completion must copy every scalar/raw byte. For a non-null payload, pass the
  same source handle, null, and a separately direct-copied typed value: the
  first two fail without UVM fatal or partial shell, while the third succeeds.
  Reuse one source ticket/status as both outer result fields and completion
  fields and assert the context returns one canonical detached handle for each.

  Install counting raw-factory wrappers modelled on
  `rdma_queue_runtime_factory_fault_wrapper` for status, ticket, image and
  completion types only after constructing the source graph. Each wrapper may
  return null or an incompatible object from raw `create_object()`. Assert all
  context methods make zero wrapper calls because they use direct `new`; do not
  call typed `type_id::create()` under such an override because UVM upgrades a
  null/wrong typed factory result to `FCTTYP` fatal. Include a self-cloning
  payload test (`detached_payload == source.decoded_response`) and require a
  stable nonfatal rejection.

  Freeze one concrete owner, call `try_snapshot_recovery_owner()` twice through
  one context, and require both outputs to be the same detached handle,
  unequal to the source handle, value-equal and accepted by
  `validate_frozen()`. Mutating the detached node must not change the source.

  In `rdma_function_identity_test.sv`, construct a fully populated binding
  with six BARs, queue DMA/capabilities, two interrupt vectors, owner and
  immutable identity. Install hostile raw-factory overrides for binding,
  identity, PCIe identity, BAR and handle types only after the source exists.
  Both new nonfatal accessors must make zero factory calls, return non-null OK
  status and a complete detached value. Mutate every nested destination field
  and prove the source unchanged. Require `$cast` of the copied ACTIVE
  `owner_h` back to `rdma_function_handle`, and separately prove an exact base
  `rdma_handle` remains base; an unknown subtype is rejected without partial
  publication. Null/invalid protected identity, PCIe/BAR or owner topology
  must return a non-null failure status and null output without UVM fatal;
  legacy identity accessors return null on the same injected snapshot failure.

  In `rdma_cmq_profile_test.sv`, install equivalent hostile factory overrides
  for every supported concrete CMQ body and `rdma_hw_cmq_completion`. Call the
  real profile's `snapshot_command_body()` and
  `snapshot_completion_payload()` for non-null typed values, and call
  `canonicalize_command_body()` for each of the five supported bodies. Both
  snapshots must remain value-equal, graph-detached and nonfatal, and the
  wrappers must record zero calls. Canonicalization returns the exact stable
  tag and field order frozen below without retaining a source handle. Unknown
  body/payload types return a non-null `INVALID_ARGUMENT` with null snapshot,
  empty tag and empty byte array.

  The byte digest has these exact known answers, packed as
  `{lane3, lane2, lane1, lane0}`:

  ```systemverilog
  expect_digest("DIGEST_EMPTY", new[0],
    256'hd6e8feb86659fd939e3779b97f4a7c1584222325cbf29ce4cbf29ce484222325);

  digest_bytes = '{8'h00, 8'h01, 8'h7f, 8'h80, 8'hff};
  expect_digest("DIGEST_ASYMMETRIC", digest_bytes,
    256'hc4dd9f5b971ab9405e8f446e17f9bf86a7d453fabd35e4b5a5bcd1d1065f84b6);
  ```

  Unit-test the canonical writer before testing domain digests. Require
  `u16(16'h0102) -> 01 02`, `u32(32'h0102_0304) -> 01 02 03 04`,
  string `"A" -> 00 00 00 01 41`, absent optional object `-> 00`, present
  `u8(8'h7f) -> 01 7f`, and byte queue `'{8'h80, 8'hff} ->
  00 00 00 02 80 ff`. Also require UTF-8 bytes `e4 b8 ad` to serialize with
  length three and reject truncated, overlong, surrogate and out-of-range
  sequences without changing the writer. Assert the five command-body fixtures
  emit their exact stable tags above and an unknown subtype returns non-null
  `RDMA_SC_INVALID_ARGUMENT` without bytes or digest. For each V1 nested schema,
  mutate every listed field once and prove the enclosing digest changes unless
  that field is explicitly excluded. Changing only an adapter-private
  allocation token must leave `DMA-MAPPING-PUBLIC-V1` bytes unchanged, while
  the separate opaque capability-equivalence check must reject the mapping.

  Build matching record/recovery-request projections and require identical
  batch digests. Change Function identity, binding, CMQ handle, one doorbell
  metadata field/byte, final PI, polarity, start/end sequence, request order,
  item image digest and item authority digest one at a time; every digest must
  change. Changing current attempt, state, effects, phase, status or
  `recovery_required` must not change it. Reject empty/unequal tuple arrays.
  Likewise freeze an asymmetric reset proof, check its proof digest, mutate
  every included scalar/tuple/owner field, and prove replacement identity/state
  transitions alone do not alter that stable isolation digest.

- [ ] **Step 3: Run RED**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_models_test
  scripts/run_vcs53.sh core rdma_cmq_profile_test
  scripts/run_vcs53.sh core rdma_function_identity_test
  ```

  Expected: compile failure for the new enums/classes/command field and
  nonfatal binding snapshot interfaces.

- [ ] **Step 4: Implement owner validation and detached values**

  `validate_for_admission()` accepts only the exact legacy sentinel or a
  non-legacy owner with non-null resource, nonzero transaction, at least one
  allowed action, null pre-freeze identity, zero admission attempt and
  `frozen == 0`.
  For a concrete owner, bit zero of `allowed_actions` must be clear, no bit may
  be unknown, and `(allowed_actions & 3'b110) != 0`; workflow must be one of
  MR/QUEUE/QP. MR requires `resource_h.kind == RDMA_RESOURCE_MR`, QP requires
  `RDMA_RESOURCE_QP`, and QUEUE accepts only CQ/SRQ/CEQ/AEQ. Reject every
  cross-workflow kind and FUNCTION/PD/CMQ/MW before freeze. `permits()` first
  rejects X/Z, INVALID and spare action values and only then indexes the mask.
  `freeze_for_journal()` rejects an already-frozen owner, zero attempt, invalid
  identity, or resource Function UID/generation mismatch; on success it clones
  identity, records the immutable admission attempt and sets `frozen`. The
  exact legacy sentinel is stored unchanged and never passed to
  `freeze_for_journal()`.
  `validate_frozen()` is the only repeated-validation entry for concrete
  journal owners: it rechecks the workflow/kind/action matrix, `frozen==1`,
  complete stored identity equality and immutable nonzero admission attempt.
  It never calls the admission validator or freezes again. Digest, retry,
  reset-proof and query code must call it; an exact legacy sentinel is handled
  as a separate no-action case. `rdma_cmq_command_desc::validate_for_journal()`
  uses that rule without rejecting a legitimately frozen command.

  `rdma_cmq_command_identity::capture_from()` copies only immutable scalar
  Function/opcode identity; it never retains the command, body, handle or
  opcode-key object. Implement the snapshot-context methods by direct
  construction and explicit field/byte copying. Clear output handles/reasons
  before validation, use the handle-keyed maps to canonicalize repeated
  ticket/status sources, and insert into a map only after a complete valid
  candidate exists. `try_snapshot_completion_shell()` delegates nested
  ticket/status copying back through the same context and assigns only the
  caller-supplied detached payload. Do not call `clone()`, `do_copy()`,
  `type_id::create()` or `rdma_cmq_clone_*` in these methods, because those
  paths cannot satisfy call-level nonfatal fallback semantics.

  Strengthen the base `rdma_cmq_hw_profile` comments so its two snapshot
  methods are explicitly status-returning, nonfatal polymorphic boundaries.
  Rewrite the production `rdma_hw_cmq_hw_profile` implementations without
  `source_wrapper.create_object()`, `copy()`, `clone()` or
  `type_id::create()`. Dispatch by the five supported command-body types
  (QPC, object-ID, MR-deregister, OCC-flush and empty), direct-construct the
  matching concrete body, direct-copy every scalar/array, and direct-construct
  each nested handle before publication. Direct-construct and explicitly copy
  `rdma_hw_cmq_completion` plus its byte queue. Validate source immutability,
  value equality and graph detachment before assigning either output.
  Implement `canonicalize_command_body()` in the same explicit five-type
  dispatch, emitting the stable tag plus the ordered field bytes frozen below;
  it must not expose concrete codec types to the model package, consult factory
  names, or retain the source handle.

  Every new status-bearing constructor overwrites the base `rdma_status` OK
  default with the exact fail-closed INVALID_STATE shape before returning.
  Do not implement production graph detachment by calling generic
  `rdma_cmq_execution_result::copy()` or journal/recovery `clone()`. Task 13
  introduces the engine/profile-aware snapshot boundary that can return a
  nonfatal status and preserve repeated-node alias topology.

  In `rdma_function_binding.sv`, change only owned-value construction in
  `rdma_pcie_identity::new()` and `rdma_function_binding::new()` from factory
  creation to typed direct `new`; this removes factory override only from those
  constructor-owned child defaults. Callers may still factory-create the outer
  binding, and `configure_identity()`/legacy lazy paths retain their current
  factory semantics. Implement `snapshot_identity_nonfatal()` by explicit
  scalar/packed copy into a direct-new identity. Implement
  `snapshot_complete_nonfatal()` with a local candidate: direct-copy identity,
  PCIe/BDF, all six BARs, queue DMA/capability structs, interrupt-vector queue,
  owner handle, mirrors and validity/state flags in declaration order. Preserve
  an exact base `rdma_handle` or supported `rdma_function_handle` dynamic type,
  and reject every other owner subtype. Validate complete equality, dynamic
  type and detachment before assigning the output. Construct failure statuses
  directly, never call `copy()/clone()/type_id::create()`, and never expose the
  protected source identity. Retarget the three legacy identity accessors
  through the new identity helper without changing their signatures.

  Implement `rdma_cmq_canonical_writer` once in the model package and use it
  from both model digest helpers and the codec-layer profile body seam.
  `append_u*()`/`append_digest()` reject X/Z before changing `buffer`;
  `append_string()` rejects malformed UTF-8 (including overlong, surrogate,
  truncated and values above U+10FFFF), and it plus counted bytes reject
  lengths above `32'hffff_ffff`;
  `append_object_header()` accepts only present 0 with an empty tag or present
  1 with a nonempty stable tag. Complex encoders build into a local child
  writer and append its raw bytes only after the entire child validates, so a
  failure never leaves a partially canonicalized parent stream. `snapshot()`
  returns detached bytes and does not clear the writer.

  Implement `rdma_cmq_digest_bytes()` as four independent 64-bit FNV-1a lanes
  over canonical bytes, with seeds
  `cbf29ce484222325`, `84222325cbf29ce4`, `9e3779b97f4a7c15`, and
  `d6e8feb86659fd93`, and multiplier `00000100000001b3`. Recovery must later
  pack the return as `{lane3, lane2, lane1, lane0}`.

  Canonical serialization is schema-closed and versioned; neither UVM field
  automation nor `sprint()/pack_bytes()` is allowed. Domain tags below are the
  literal ASCII bytes including their final NUL and have no length prefix.
  `u8/u16/u32/u64` are unsigned big-endian widths; a narrower packed scalar is
  zero-extended into its named width. A boolean or enum is one `u8` and is
  rejected before encoding if it contains X/Z or a spare value. A string is
  `u32 byte_count` followed by its validated UTF-8/`getc()` bytes. Every object
  is `u8 present`, then a length-prefixed stable type tag and its fields; a
  required object's present byte must be one, while a permitted null ends at
  zero. A dynamic queue/array is `u32 element_count` followed by elements in
  index order; fixed arrays have no count and use ascending index. A stored
  256-bit digest contributes exactly 32 bytes from bit 255 down to bit 0,
  most-significant byte first. There is no
  alignment padding, host-endian integer, UVM instance name or implicit
  `get_type_name()` anywhere in the byte stream.

  The following V1 nested schemas freeze every serialized field and its order.
  Adding, removing or reordering a field requires a V2 domain/tag rather than
  silently changing V1:

  - `HANDLE-V1`: `kind(u8)`, `function_uid(u64)`, `object_id(u32)`,
    `generation(u32)`. A Function handle uses the same schema after its runtime
    subtype has been validated.
  - `BDF-V1`: `segment(u16)`, `bus(u8)`, `device(u8)`,
    `function_num(u8)`. `ROUTE-V1`: `host_topology_key(u32)`, `root_id(u16)`,
    `segment(u16)`, then `BDF-V1 bdf`.
  - `FUNCTION-IDENTITY-V1`: `key.root_id(u16)`,
    `key.host_topology_key(u32)`, `key.function_kind(u8)`,
    `BDF-V1 key.parent_pf_bdf`, `key.vf_index(u16)`, `BDF-V1 key.bdf`,
    `global_function_id(u32)`, `function_uid(u64)`, `generation(u32)`,
    `reset_epoch(u64)`.
  - `OPCODE-KEY-V1`: `profile_name(string)`, `opcode(u32)`,
    `variant(string)`. `RECOVERY-OWNER-V1`: `workflow(u8)`,
    `resource_h(HANDLE-V1 nullable only for the exact legacy sentinel)`,
    `transaction_id(u64)`, `allowed_actions(u8)`,
    `function_identity(FUNCTION-IDENTITY-V1 nullable only for the sentinel)`,
    `admission_attempt_id(u64)`, `frozen(u8)`.
  - `IMAGE-V1`: `length(u64)`, `alignment(u32)`, `endian(u8)`,
    `image_kind(u8)`, `hardware_version(u32)`,
    `function_generation(u32)`, `write_target_kind(u8)`,
    `backing_target.value(u64)`, `hmc_target.value(u64)`,
    `bar_target.value(u64)`, `bytes(queue<u8>)`, then
    `field_summary(queue<string>)`. Validation requires `bytes.size()==length`.
  - `CMQ-COMMAND-V1`: `function_h(HANDLE-V1)`,
    `opcode_key(OPCODE-KEY-V1)`, the exact polymorphic body tag/schema below,
    `qpc_signature_source(IMAGE-V1 nullable)`, `vfid_override(u8)`,
    `use_vfid(u16)`, `timeout(u64)`, then
    `recovery_owner(RECOVERY-OWNER-V1)`. The runtime body tag is never derived
    from a factory name:
    - `CMQ-BODY-QPC-V1`: `qp_h`, `send_cq_h`, `recv_cq_h` as nullable
      `HANDLE-V1`, `qpc_buffer.value(u64)`, `next_state(u8)`,
      `full_modify(u8)`, `partial_modify(u8)`,
      `wbe_template_count(u8)`, then for indices 0 through 3 the triple
      `modify_start_qword(u8)`, `modify_wbe(u8)`, `modify_data(u64)`.
    - `CMQ-BODY-OBJECT-ID-V1`: `object_h(HANDLE-V1)`.
    - `CMQ-BODY-MR-DEREGISTER-V1`: `mr_h(HANDLE-V1)`, `stag_key(u8)`,
      `next_state(u8)`.
    - `CMQ-BODY-OCC-FLUSH-V1`: `vf_flush`, `mr_serial_flush`, `qpc`, `cqc`,
      `mrt`, `pble`, `sqrqe`, `sgb_irqe`, `eirqe`, `orqe`, `uaqe`, `pd`
      as twelve ordered `u8` values, followed by `qpn(u32)`,
      `mr_serial(u16)`, `pd_backing.value(u64)`.
    - `CMQ-BODY-EMPTY-V1`: no fields after the tag. Any other body subtype is
      rejected rather than assigned a fallback tag.
  - `CMQ-TICKET-V1`: `command_id(u64)`, `function_h(HANDLE-V1)`,
    `cmq_h(HANDLE-V1)`, `slot_sequence(u64)`, `sq_index(u32)`, `sq_wrap(u8)`,
    `opcode_key(OPCODE-KEY-V1)`, `absolute_deadline(u64)`.
  - `DMA-CONTEXT-V1`: `function_h(HANDLE-V1)`, `BDF-V1 requester_bdf`,
    `pasid_valid(u8)`, `pasid(u32)`, `dma_domain_valid(u8)`,
    `dma_domain_id(u32)`, `ROUTE-V1 route`, `reset_epoch(u64)`,
    `route_valid(u8)`, `epoch_valid(u8)`, `owner_h(HANDLE-V1 nullable)`,
    `queue_role_valid(u8)`, `queue_role(u32)`.
  - `DMA-MAPPING-PUBLIC-V1`: `function_h(HANDLE-V1)`,
    `BDF-V1 requester_bdf`, `pasid_valid(u8)`, `pasid(u32)`,
    `dma_domain_valid(u8)`, `dma_domain_id(u32)`, `ROUTE-V1 route`,
    `reset_epoch(u64)`, `route_valid(u8)`, `epoch_valid(u8)`,
    `backing_addr.value(u64)`, `iova.value(u64)`, `size(u64)`,
    `direction(u8)`, `permissions.device_read(u8)`,
    `permissions.device_write(u8)`, `permissions.atomic(u8)`, `state(u8)`,
    `owner_h(HANDLE-V1 nullable)`, `umem_backed(u8)`,
    `umem_page_count(u32)`. `umem_ref`, `pbl_ref`, `mw_ref`, concrete subtype,
    adapter token and all opaque allocation identity are deliberately excluded;
    retry authority is separately proven by opaque capability equivalence.
  - `FUNCTION-BINDING-V1`: `function_uid(u64)`, the detached
    `FUNCTION-IDENTITY-V1` returned by the binding snapshot accessor,
    `pcie.bdf(BDF-V1)`, `pcie.parent_pf_bdf(BDF-V1)`, `pcie.vf_index(u32)`,
    `pcie.mse(u8)`, `pcie.bme(u8)`, then six ascending BAR entries
    `{bar_id(u8), base.value(u64), size(u64), enabled(u8)}`;
    `notify_bar_id(u8)`, `notify_base.value(u64)`, `notify_size(u64)`,
    `notify_table_sel(u32)`, `notify_table_index(u32)`, `host_id(u32)`,
    `pfvf_id(u32)`, `rdma_vf_id(u32)`, `global_function_id(u32)`,
    `vsi_id(u32)`; queue-DMA fields `requester_bdf(BDF-V1)`,
    `pasid_valid(u8)`, `pasid(u32)`, `dma_domain_valid(u8)`,
    `dma_domain_id(u32)`; queue-capability fields `min_cq_depth(u32)`,
    `max_cq_depth(u32)`, `min_srq_depth(u32)`, `max_srq_depth(u32)`,
    `max_ceq_depth(u32)`, `max_aeq_depth(u32)`, `max_wq_sge(u32)`,
    `max_queue_ring_bytes(u64)`, `max_sgb_bytes(u64)`; the interrupt-vector
    queue entries `function_local_vector(u32)`, `hardware_eq_vector(u32)`,
    `msix_table_index(u32)`, `enabled(u8)`; then `state(u8)`, `generation(u32)`,
    `owner_h(HANDLE-V1 nullable)`, `notify_valid(u8)`, `notify_ready(u8)`,
    `dmi_valid(u8)`, `dmi_ready(u8)`, `vft_valid(u8)`, `vft_ready(u8)`.

  The image domain is `CMQ-IMAGE-V1\0`, then `IMAGE-V1 sqe_image` and
  `IMAGE-V1 dependency_image`. The authority domain is `CMQ-AUTH-V1\0`, then
  in this exact order: `CMQ-COMMAND-V1 command`, `CMQ-TICKET-V1 ticket`,
  `RECOVERY-OWNER-V1 recovery_owner`,
  `FUNCTION-IDENTITY-V1 function_identity`, `DMA-CONTEXT-V1 dma_context`,
  `DMA-MAPPING-PUBLIC-V1 dependency_mapping`, and `dependency_offset(u64)`.
  `rdma_cmq_compute_item_digests()` inserts the supplied body tag and field
  bytes at the body position in `CMQ-COMMAND-V1`; engine callers must first
  obtain them from the profile seam for that exact command body.
  Reject null required values, X/Z bits, invalid metadata, a command whose
  embedded owner is not the same canonical source value as the item owner, and
  invalid/non-frozen concrete owner state before returning either digest.

  Implement `rdma_cmq_compute_batch_digest()` over the exact canonical domain
  `CMQ-BATCH-V1\0`, then `FUNCTION-IDENTITY-V1 function_identity`,
  `FUNCTION-BINDING-V1 binding`, `HANDLE-V1 cmq_h`,
  `IMAGE-V1 doorbell_image`, `final_pi(u32)`, `final_polarity(u8)`,
  `start_sequence(u64)`, `end_sequence(u64)`, and the ordered equal-length
  tuples `{request_index(u32), image_digest(32 raw bytes),
  authority_digest(32 raw bytes)}`. The record and recovery
  request both carry this digest and all values needed to recompute it. The
  helper first obtains a complete detached binding and its protected
  identity through the two nonfatal binding seams; null/non-OK snapshot status
  rejects the digest without partial bytes. Current attempt ID, item/batch
  state, both effects, completion phase, status and
  `recovery_required` are deliberately excluded because a legitimate retry or
  completion changes them without changing shared doorbell authority. The
  retained completion and `reset_isolation_confirmed` bit are excluded for the
  same reason.

  Implement `rdma_cmq_compute_reset_proof_digest()` over
  `CMQ-RESET-PROOF-V1\0`, then `proof_key(string)`, `proof_id(u64)`,
  `batch_key(string)`, `batch_id(u64)`, `attempt_id(u64)`,
  `engine_instance_id(u64)`, `engine_incarnation(u64)`,
  `FUNCTION-IDENTITY-V1 isolated_identity`, `batch_digest(32 raw bytes)`, and
  each ordered `{request_index(u32), image_digest(32 raw bytes),
  authority_digest(32 raw bytes), RECOVERY-OWNER-V1 recovery_owner}` tuple.
  The mutable replacement identity, proof state and release-confirmation bit
  are excluded and are checked independently against the retained journal
  proof value and legal transition table.
  Reject zero IDs, invalid identity/owner values, unequal/empty tuple arrays and
  X/Z data before publishing either digest.

  “Independent recomputation” means running this one frozen canonical encoder
  and one FNV implementation once over the request-owned graph and separately
  over the journal-owned graph; it does not mean maintaining a second hash
  implementation that could drift. Recovery validates each graph's recomputed
  item/batch/proof digest against that graph's carried digest, compares the two
  verified recomputations, and only then compares every complete detached value.
  A digest match can never authorize retry by itself. The reset proof is a
  frozen value minted only by engine state transitions: its public constructor
  creates `INVALID`, and merely constructing matching-looking fields does not
  install proof authority on an engine journal record. `AWAITING_REBIND`
  requires a confirmed
  backing release and old identity; `READY` additionally requires a validated
  replacement identity with the same immutable Function and a strictly larger
  reset epoch. Its ordered item tuple is
  `{request_index, image_digest, authority_digest, full recovery_owner}`; all
  four arrays have the same nonzero length and order. Its carried batch and
  proof digests must equal separate recomputation from the retained journal
  record. Even if a caller changes one included field and supplies a freshly
  matching digest, full equality with the authoritative retained value rejects
  it. Replacement identity, proof state and release-confirmation do not change
  the stable proof digest, but full proof equality plus the legal-transition
  validator still rejects forged readiness. Full tuple/value equality remains
  mandatory after every digest check.

  `rdma_cmq_reduce_batch_state()` never authorizes a transition; it only derives
  a diagnostic aggregate. Reject impossible pre-MMIO/published mixtures.
  Otherwise select, in conservative order: `RESET_QUARANTINED`,
  `HOST_VISIBLE_NOT_PUBLISHED`, `PUBLISH_AMBIGUOUS`,
  `TIMED_OUT_QUARANTINED`, `PENDING_EFFECT`, `STAGED`, then
  `PUBLISH_CONFIRMED` while any item remains pending. Return `COMPLETED` when
  all items completed, or `LATE_COMPLETED` when all are terminal and at least
  one completed late.

  Implement `rdma_cmq_fold_attempt_effect()` with explicit enum cases. Its only
  concrete ordered domain is the five Host-memory/MMIO values; it never uses
  numeric ordering for `UNOBSERVED` or `PRE_SUBMIT_REJECTED`. Task 8's
  monotonic helper remains the rule inside one attempt, while this helper folds
  evidence from distinct attempts according to the RED matrix above.

  Implement `rdma_cmq_classify_recovery_required()` as the single exhaustive
  state/phase table above. It clears the output only for resolved terminal
  combinations, a confirmed reset-isolation proof, or the exact legacy
  sentinel after confirmed backing release; it forces it for
  UNOBSERVED, staged/pending/host-visible/published/timeout/unconfirmed-reset
  states, and returns non-OK without modifying a pre-seeded output for any X/Z,
  spare or impossible combination. Initial pre-submit rejection has no journal
  item and is assigned zero directly by the admission result path.

  Include `rdma_cmq_execution_models.sv` immediately after
  `rdma_cmq_engine_models.sv` and before `rdma_control_plane_models.sv`.
  Append `RDMA_CMQ_COMPLETION_UNOBSERVED` and its unknown-evidence rationale to
  spec section 5.1. Change the new workflow/action/completion/state/proof-state
  enums and `allowed_actions` to four-state logic in the spec, with explicit
  X/Z rejection before indexing or transition. Amend section 5.2 so every
  execution result owns non-null
  detached operation `status` and `observation_status` values, defines
  `observation_status` as envelope/evidence-capture health, and forbids an
  observation failure from overwriting a valid operation result. Freeze
  `attempt_effect` as current-call evidence distinct from cumulative
  `submission_effect`, and rename recovery-owner provenance to immutable
  `admission_attempt_id` while the batch current attempt advances independently.
  Freeze
  `recovery_required` as the exhaustive lifetime-state table above and add it
  to each journal item; it is a conservative unresolved-presence bit rather
  than a promise of automatic retry. Automatic recovery still requires
  complete journal authority. Freeze the exact V1 canonical primitive/object/
  polymorphic-body serialization, the profile-owned body canonicalization seam,
  the rule that opaque allocation identity is excluded from digest authority,
  and the request-graph/journal-graph separate-recomputation order. Freeze the
  reset proof's ordered four-field item tuple, including image digest, plus the
  stable batch/proof digest domains.
  Add the batch-level authority projection to recovery request/record, and add
  the authoritative retained lifecycle completion to each journal item so FIFO
  delivery cannot erase wait/reconcile evidence. Freeze the production
  observation-status table and the rule that lifecycle transitions never
  rewrite either effect. Relax the existing DMA-context null rule only
  for the
  legacy `UNOBSERVED + recovery_required` manual-reconcile shape; that shape
  has zero batch/attempt IDs and can never authorize engine retry. Make these
  spec edits in this same design-refinement change.

- [ ] **Step 5: Run GREEN**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_models_test
  scripts/run_vcs53.sh core rdma_cmq_profile_test
  scripts/run_vcs53.sh core rdma_function_identity_test
  scripts/run_vcs53.sh core rdma_model_test
  ```

  Expected: PASS; owner kinds/actions, four-state enums, fail-closed defaults,
  digests, reducers and the recovery-required table match the frozen values;
  existing binding/PCIe construction and clone behavior remains compatible.

- [ ] **Step 6: Commit the value models**

  ```bash
  git add src/model/rdma_cmq_execution_models.sv \
    src/model/rdma_cmq_engine_models.sv \
    src/model/rdma_function_binding.sv src/model/rdma_model_pkg.sv \
    src/codec/rdma_cmq_hw_profile.sv \
    src/codec/rdma/rdma_cmq_hw_profile.sv \
    tests/unit/rdma_cmq_engine_models_test.sv \
    tests/unit/rdma_cmq_profile_test.sv \
    tests/unit/rdma_function_identity_test.sv \
    docs/superpowers/specs/2026-09-11-rdma-engine-contract-refactoring-design.md
  git commit -m "feat(cmq): add observed execution and recovery values" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 10: Add a one-way observed fallback to the CMQ port

**Files:**

- Modify: `src/core/rdma_cmq_port.sv`
- Modify: `tests/unit/rdma_cmq_port_test.sv`
- Modify: `tests/mocks/rdma_mock_control_plane.sv`

**Interfaces:**

```systemverilog
virtual task execute_observed(
  input rdma_cmq_command_desc command,
  output rdma_cmq_execution_result result
);

protected virtual function bit try_snapshot_legacy_decoded_response(
  input uvm_object source,
  output uvm_object snapshot,
  output string failure_reason
);
```

The base implementation calls legacy `execute()` exactly once and publishes a
detached non-null result with `submission_effect=UNOBSERVED`. It never calls
`execute_observed()` from the base `execute()` declaration. The payload hook
resets both outputs, accepts a null source as success/null, and rejects every
non-null source with a stable nonfatal reason by default. A legacy subclass may
override it only when it can direct-copy its concrete payload type without a
factory, clone or engine/profile dependency. The production adapter bypasses
this fallback by overriding `execute_observed()`.

- [ ] **Step 1: Add RED recursion/fallback tests**

  Add a local `rdma_legacy_only_cmq_port` subclass extending the existing
  concrete `rdma_mock_cmq_port`; override only `execute()`, increment
  `execute_calls`, and return deterministic ticket/completion/status. Inherited
  `rdma_mock_cmq_port::reconcile()` satisfies the base port's second pure
  virtual method, so this probe really compiles. Assert:

  ```systemverilog
  port.execute_observed(command, result);

  if (legacy_port.execute_calls != 1 ||
      result == null || result.status == null ||
      result.observation_status == null ||
      result.submission_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED)
    `uvm_error("PORT_OBSERVED_FALLBACK", "legacy fallback is incomplete")
  ```

  Make the legacy override mutate the input command identity and recovery owner
  during `execute()`, then mutate its outputs again after return. The observed
  result must retain the command/owner snapshot taken before virtual dispatch
  and detached output values. Add null status and null, normal, timeout, and
  reset-cancelled completion cases. A null status must become
  `RDMA_SC_INVALID_STATE` in both result status fields; every legacy case uses
  `RDMA_CMQ_COMPLETION_UNOBSERVED` because the wrapper has no lifecycle
  transition evidence. It must never infer `TERMINAL`, `TIMEOUT` or
  `RESET_CANCELLED` from a non-null object or status code.

  Add a legacy completion with non-null `decoded_response` and no hook
  override. The fallback must preserve the independently detached outer ticket
  and operation status, return null completion, set non-null
  `observation_status` to `RDMA_SC_INVALID_STATE`, retain `UNOBSERVED`, and
  trigger no UVM fatal. Add a second subclass whose hook direct-copies one known
  test payload type; it must preserve a fully detached completion. In both
  paths, set the source outer ticket/status equal to the completion's nested
  handles and assert the successful snapshot keeps the same internal aliases.

  Install counting raw-factory wrappers for execution result, status, ticket,
  image and completion after building the legacy source values. The fallback
  must make zero wrapper calls and still return non-null envelope/status values
  because it uses direct `new`; never invoke a typed `type_id::create()` under
  a null/wrong-type override, which would produce UVM `FCTTYP` fatal.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  scripts/run_vcs53.sh core rdma_cmq_port_test
  ```

  Expected: compile failure because `execute_observed()` is absent.

- [ ] **Step 3: Implement the conservative base wrapper**

  Directly construct `result`, operation `status`, `observation_status` and one
  `rdma_cmq_nonfatal_snapshot_context` before virtual dispatch. Capture scalar
  command identity and a complete directly copied recovery owner before calling
  legacy `execute()` because an `input` class handle does not stop an override
  from mutating the pointed-to object. Do not depend on UVM factory success.

  Call `execute()` exactly once. Snapshot its outer status and optional ticket
  independently through the context. Call
  `try_snapshot_legacy_decoded_response()` for a non-null completion payload,
  then pass that detached payload to `try_snapshot_completion_shell()`. Never
  call an existing `rdma_cmq_clone_*` helper. Successful fields survive an
  unrelated capture failure: in particular, unsupported payload sets
  `completion=null` and a direct-new `RDMA_SC_INVALID_STATE`
  `observation_status`, but preserves the detached outer ticket and operation
  status. A missing/malformed outer status installs direct-new
  `RDMA_SC_INVALID_STATE` in `result.status` and records the same capture fault
  in `observation_status`. First failure wins only for observation diagnostics;
  it never erases an independently completed snapshot.

  On every legacy return set:

  ```systemverilog
  result.submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
  result.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
  result.completion_phase = RDMA_CMQ_COMPLETION_UNOBSERVED;
  result.batch_key = "";
  result.batch_id = 0;
  result.attempt_id = 0;
  result.recovery_required = 1'b1;
  result.dma_context = null;
  ```

  Here `recovery_required=1` means unknown presence must be conservatively
  reconciled; zero batch/attempt and null DMA context explicitly prohibit
  automatic `recover_submission_observed()` retry. Preserve a detached legacy
  completion when its shell and typed payload can both be captured, but never
  use its presence or status to classify lifecycle phase. Every directly
  constructed status initializes `category`, `code`, `severity` and message
  explicitly; calling `rdma_status::make()` is not a fallback because its
  factory create may also return null.

  Keep `rdma_mock_cmq_port`'s protected legacy
  `last_execute_no_submit_proven` seam for existing MR/queue/QP tests in 1A;
  do not use that shared bit to populate an observed result. Its removal belongs
  to the corresponding 1B consumer migrations.

- [ ] **Step 4: Run GREEN**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_port_test
  scripts/run_vcs53.sh core rdma_control_plane_test
  scripts/run_vcs53.sh core rdma_queue_lifecycle_test
  scripts/run_vcs53.sh core rdma_qp_lifecycle_test
  ```

  Expected: fallback tests pass and legacy consumer tests retain their existing
  observable behavior.

- [ ] **Step 5: Commit the port fallback**

  ```bash
  git add src/core/rdma_cmq_port.sv tests/unit/rdma_cmq_port_test.sv \
    tests/mocks/rdma_mock_control_plane.sv
  git commit -m "feat(cmq): add conservative observed port fallback" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 11: Publish scheduler per-call effects and arm a nullable MMIO observer

**Files:**

- Modify: `src/core/rdma_doorbell_scheduler.sv`
- Modify: `tests/unit/rdma_doorbell_scheduler_test.sv`

**Interfaces:**

Define before `rdma_doorbell_scheduler` in the same core file:

```systemverilog
virtual class rdma_doorbell_submission_observer extends uvm_object;
  pure virtual function void before_mmio_maybe_visible();
endclass

class rdma_doorbell_submission_result extends uvm_object;
  `uvm_object_utils(rdma_doorbell_submission_result)

  rdma_doorbell_result doorbell_result;
  rdma_status status;
  rdma_submission_effect_e submission_effect;
  int unsigned dependency_count;
  bit before_mmio_maybe_visible_called;

  function bit try_project_legacy(
    output rdma_doorbell_result projected_result,
    output rdma_status projected_status,
    output string failure_reason
  );
endclass
```

Add this virtual entry and retain the old signature as a one-way projection:

```systemverilog
virtual task submit_observed(
  input rdma_function_binding binding,
  input rdma_doorbell_desc desc,
  input rdma_doorbell_submission_observer observer,
  output rdma_doorbell_submission_result result
);

task submit(
  input rdma_function_binding binding,
  input rdma_doorbell_desc desc,
  output rdma_doorbell_result result,
  output rdma_status status
);
```

- [ ] **Step 1: Add RED effect-matrix and observer tests**

  Add a counting observer and extend the existing injected failures with this
  exact matrix:

  | Injection | Expected effect | Observer calls |
  | --- | --- | --- |
  | argument/snapshot/preflight/Function-lock deadline | `PRE_SUBMIT_REJECTED` | 0 |
  | first or later dependency write | `HOST_MEMORY_MAYBE_VISIBLE` | 0 |
  | DMA barrier | `HOST_MEMORY_WRITTEN` | 0 |
  | MMIO barrier | `HOST_MEMORY_ORDERED` | 0 |
  | deadline expires after barriers but before PCIe entry | `HOST_MEMORY_ORDERED` | 0 |
  | MMIO error/timeout | `MMIO_MAYBE_VISIBLE` | 1 |
  | MMIO success | `MMIO_VISIBLE` | 1 |

  Cover zero dependencies and all four barrier policies. For every case assert
  `result != null`, `result.status != null`, exact dependency count, and a
  detached status/result. A null observer must still return exact effects and
  must leave `before_mmio_maybe_visible_called == 0`.

  Freeze `dependency_count` as the declared queue length seen at public entry:
  null `desc` records zero; every non-null descriptor records
  `desc.dependencies.size()` before snapshot/preflight, including null/invalid
  dependency elements. First/middle write failure must not reduce it to the
  number of successful writes. Add null-desc, invalid-third-dependency and
  second-write-failure assertions that distinguish those cases.

  Add factory/clone fault injection for both the observed envelope and nested
  doorbell/status values. Before the first external call, the fallback is
  `PRE_SUBMIT_REJECTED`; after a dependency write or MMIO begins, construction
  failure must preserve the already reached scalar effect and must never
  regress to pre-submit rejection. The envelope and status remain non-null via
  direct `new` construction.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_doorbell_scheduler_test
  ```

  Expected: compile failure for the observer/result/observed API.

- [ ] **Step 3: Implement the observed scheduler path**

  Directly construct one call-local observed result and its initial
  invalid-state status before validation; factory-register the class for normal
  UVM use, but do not depend on factory creation for the non-null guarantee.
  Before any snapshot or validation, set `dependency_count` to zero for a null
  descriptor or to the descriptor's declared dependency queue length. Never
  increment it while writes complete and never derive it from a staging loop.
  Convert `submit_locked()` and `write_dependency_stage()` to receive that
  result. Update effect immediately around actual operations, never from status
  codes:

  ```systemverilog
  // Inside write_dependency_stage(), immediately before every
  // host_mem.write() call and after all local preparation for that write.
  result.submission_effect =
    RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;

  // After every dependency write succeeds, including an empty set.
  result.submission_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN;

  // After a required DMA barrier succeeds, or immediately when none is needed.
  result.submission_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;

  // Inside mmio_write_before_deadline(), after its final deadline check and
  // immediately before launching the worker that calls PCIe MMIO.
  result.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
  if (observer != null) begin
    result.before_mmio_maybe_visible_called = 1'b1;
    observer.before_mmio_maybe_visible();
  end

  // Only after PCIe reports success.
  result.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
  ```

  For non-empty dependencies, assign `HOST_MEMORY_MAYBE_VISIBLE` immediately
  before each individual `host_mem.write()` in `write_dependency_stage()`, not
  at the stage-helper call site. This keeps image-copy and other local helper
  failures pre-submit. Only after both dependency stages finish does
  `submit_locked()` advance to `HOST_MEMORY_WRITTEN`; for zero dependencies it
  advances there directly. Initialize a non-null failure status on entry. All
  failures before external I/O return `PRE_SUBMIT_REJECTED`; once any write or
  barrier begins, no path may return that value.

  Pass observer/result into `mmio_write_before_deadline()`. That helper first
  runs its final `deadline_remaining()` check; only after it succeeds does it
  set `MMIO_MAYBE_VISIBLE`, invoke the observer, and launch the worker that
  calls `pcie.mmio_write()`. A deadline already expired there returns
  `HOST_MEMORY_ORDERED` with zero observer calls, preserving the legal
  host-visible-not-published recovery path. The observer is called at most
  once, synchronously, and cannot report failure. It must not allocate, wait,
  acquire a lock, call an adapter/service, or re-enter engine/scheduler. A
  nested result/status construction failure after external I/O uses direct
  `new`, retains the scalar effect already reached, and reports
  `INVALID_STATE` without claiming absence.

  Implement deep `do_copy()` for ordinary UVM values, plus
  `try_project_legacy()` using only direct `new` and explicit scalar/handle
  field copies so a bad factory cannot issue fatal during projection. Legacy
  `submit()` calls `submit_observed(binding, desc, null, observed)` exactly once
  and invokes that nonfatal projection; it stores no `last_*` member. A
  null observed `doorbell_result` is a valid legacy failure shape:
  `try_project_legacy()` returns `projected_result=null` while independently
  copying the observed status. Only a null/malformed observed status or a
  failed non-null doorbell-result copy installs a directly constructed
  invalid-state legacy status; no projection path rewrites the already reached
  observed effect.

- [ ] **Step 4: Run GREEN**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_doorbell_scheduler_test
  scripts/run_vcs53.sh core rdma_queue_data_engine_post_test
  ```

  Expected: PASS; observer count and every failure-stage effect match the table,
  and the existing queue-data scheduler consumer retains its legacy result.

- [ ] **Step 5: Commit scheduler evidence**

  ```bash
  git add src/core/rdma_doorbell_scheduler.sv \
    tests/unit/rdma_doorbell_scheduler_test.sv
  git commit -m "feat(doorbell): publish per-call submission evidence" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 12: Introduce a stateless CMQ transport facade

**Files:**

- Create: `src/core/rdma_cmq_transport.sv`
- Modify: `src/core/rdma_core_pkg.sv`
- Modify: `src/core/rdma_cmq_engine.sv`
- Modify: `tests/unit/rdma_cmq_engine_test.sv`

**Interfaces:**

```systemverilog
class rdma_cmq_transport extends uvm_object;
  protected rdma_doorbell_scheduler scheduler;
  protected bit configured;

  function rdma_status configure(
    input rdma_doorbell_scheduler scheduler_arg
  );

  task submit_observed(
    input rdma_function_binding binding,
    input rdma_doorbell_desc desc,
    input rdma_doorbell_submission_observer observer,
    output rdma_doorbell_submission_result result
  );
endclass
```

The facade owns only a non-owning scheduler reference. It owns no lock,
Host-memory/PCIe adapter, mapping, binding, ring, ticket, ledger or recovery
state. `configure()` is one-shot for a transport instance; engine reset does
not reconfigure an old facade.

- [ ] **Step 1: Add RED transport tests**

  In `rdma_cmq_engine_test.sv`, add a scheduler test double overriding
  `submit_observed()` and recording binding/descriptor/observer identities.
  Assert an unconfigured transport returns a non-null result/status with
  `RDMA_SC_INVALID_STATE + PRE_SUBMIT_REJECTED`; configured transport delegates
  exactly once, forwards the observer unchanged, and transfers the scheduler's
  call-local result without cloning it.

  Add three post-delegation failures: scheduler returns null result, non-null
  result with null status, and non-null result whose scalar effect is
  `MMIO_MAYBE_VISIBLE`. A null result must become direct-new
  `INVALID_STATE + UNOBSERVED` because I/O may already have happened. A null
  status preserves the returned scalar effect and installs a direct-new
  invalid-state status; neither path may claim `PRE_SUBMIT_REJECTED` after a
  delegate call.

  Characterize lifecycle use through the existing engine probe: initial
  `prepare()` installs a configured transport, failed prepare leaves no facade,
  reset/shutdown discards it, and a later successful reprepare creates a
  distinct transport object configured with the new scheduler. Existing
  `check_prepared_shutdown_lifecycle()` remains green.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: compile failure because `rdma_cmq_transport` is undefined.

- [ ] **Step 3: Implement and place the facade**

  `configure()` rejects null or repeated configuration without changing the
  stored reference. `submit_observed()` directly constructs its fallback
  envelope/status before validation, rejects an unconfigured/null stored
  scheduler before I/O as `PRE_SUBMIT_REJECTED`, and delegates once otherwise.
  The scheduler result is already per-call and detached, so transfer it instead
  of cloning after possible I/O. If the delegate returns null, publish
  `UNOBSERVED`; if only its status is null, retain its scalar effect and install
  a direct-new invalid-state status. No post-delegation path may assert
  pre-submit rejection unless a non-null scheduler result itself reported that
  effect.

  Add a protected `rdma_cmq_transport transport` member to engine. During every
  `prepare()`, before Host-memory allocation or zero-write, create a fresh
  candidate and call its one-shot `configure(scheduler)`. A null candidate or
  failed configure aborts prepare before external I/O. Install the candidate
  only in the existing successful prepare commit block. `clear_configuration()`
  sets `transport=null`, so reset/shutdown/failed prepare never retain a stale
  facade; reprepare always creates a different object. Task 15 will route
  submission through this installed facade; Task 12 moves no ring state.

  Add only this include between `rdma_control_plane.sv` and
  `rdma_cmq_engine.sv`:

  ```systemverilog
  `include "rdma_control_plane.sv"
  `include "rdma_cmq_transport.sv"
  `include "rdma_cmq_engine.sv"
  ```

  Do not create snapshot/ring/ledger files in Phase 1A and do not move any
  engine state.

- [ ] **Step 4: Run GREEN**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: PASS; all existing engine probe signatures remain unchanged, and
  prepare/reset/reprepare proves one transport instance is never configured
  twice or reused across engine incarnations.

- [ ] **Step 5: Commit the facade**

  ```bash
  git add src/core/rdma_cmq_transport.sv src/core/rdma_core_pkg.sv \
    src/core/rdma_cmq_engine.sv \
    tests/unit/rdma_cmq_engine_test.sv
  git commit -m "refactor(cmq): add stateless transport facade" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 13: Add engine-owned journal storage and stable identities

**Files:**

- Modify: `src/core/rdma_cmq_engine.sv`
- Modify: `tests/unit/rdma_cmq_engine_test.sv`

**Interfaces:**

Keep the journal inside the existing engine file in Phase 1A. Add these public
read-only tasks; both acquire the existing `engine_lock` and return detached
snapshots:

```systemverilog
task query_submission_journal(
  input string batch_key,
  output rdma_cmq_batch_submission_record record,
  output rdma_status status
);

task query_submission_journal_by_ticket(
  input rdma_cmq_ticket ticket,
  output rdma_cmq_batch_submission_record record,
  output rdma_status status
);

task query_submission_fence(
  output bit active,
  output string batch_key,
  output string reason,
  output rdma_status status
);
```

All graphs that enter or leave the journal use these engine-owned,
status-returning snapshot seams. They are protected, non-virtual production
helpers; the existing engine probe exposes only narrow test wrappers:

```systemverilog
protected function rdma_status snapshot_command_for_journal_locked(
  input rdma_cmq_command_desc source,
  input rdma_cmq_recovery_owner detached_owner,
  input rdma_cmq_nonfatal_snapshot_context context,
  output rdma_cmq_command_desc snapshot
);

protected function rdma_status snapshot_completion_for_result_locked(
  input rdma_cmq_completion source,
  input rdma_cmq_nonfatal_snapshot_context context,
  output rdma_cmq_completion snapshot
);

protected function rdma_status snapshot_execution_result_locked(
  input rdma_cmq_execution_result source,
  output rdma_cmq_execution_result snapshot
);

protected function rdma_status snapshot_journal_record_locked(
  input rdma_cmq_batch_submission_record source,
  output rdma_cmq_batch_submission_record snapshot
);

protected function rdma_status snapshot_recovery_request_locked(
  input rdma_cmq_submission_recovery_request source,
  output rdma_cmq_submission_recovery_request snapshot
);

protected function rdma_status snapshot_reset_proof_locked(
  input rdma_cmq_reset_isolation_proof source,
  output rdma_cmq_reset_isolation_proof snapshot
);
```

Each top-level helper creates one direct-new
`rdma_cmq_nonfatal_snapshot_context`, clears its output on entry, and publishes
only a complete graph. The command helper receives the already canonicalized
owner so `item.command.recovery_owner` and `item.recovery_owner` remain one
node inside a detached record. The completion helper first asks the profile to
snapshot a non-null typed `decoded_response`, then passes that detached payload
to `try_snapshot_completion_shell()`; null payload remains null by contract.

Add two engine-internal, preallocated publication values before
`rdma_cmq_engine`; they are not a second ledger and own no lock:

```systemverilog
class rdma_cmq_preallocated_publish_item extends uvm_object;
  int unsigned request_index;
  rdma_cmq_slot_record slot_record;
  string command_key;
  string entry_key;
  bit [4:0] command_token;
endclass

class rdma_cmq_preallocated_publish_batch extends uvm_object;
  string batch_key;
  longint unsigned attempt_id;
  longint unsigned final_sequence;
  bit profile_format_valid;
  rdma_byte_endian_e profile_endian;
  int unsigned profile_hardware_version;
  rdma_cmq_preallocated_publish_item items[$];
endclass
```

The engine owns these members under `engine_lock`:

```systemverilog
longint unsigned engine_instance_id;
longint unsigned engine_incarnation;
longint unsigned batch_id_counter;
longint unsigned attempt_id_counter;
longint unsigned reset_proof_id_counter;
rdma_cmq_batch_submission_record submission_journal[string];
string journal_batch_by_ticket[string];
rdma_cmq_preallocated_publish_batch preallocated_publish_batches[string];
string fenced_batch_key;
string submission_fence_reason;
```

Add a nonfatal formatter with this exact interface:

```systemverilog
function automatic bit rdma_cmq_format_batch_key(
  input rdma_function_identity identity,
  input longint unsigned engine_instance_id,
  input longint unsigned engine_incarnation,
  input longint unsigned batch_id,
  output string batch_key,
  output string failure_reason
);
```

It validates the complete identity and nonzero engine/incarnation/batch values,
resets outputs on entry, and emits this exact fixed-width lowercase form:

```text
root=<4hex>|host=<8hex>|kind=<1hex>|parent=<4hex>:<2hex>:<2hex>.<1hex>|vf=<4hex>|bdf=<4hex>:<2hex>:<2hex>.<1hex>|gfid=<8hex>|uid=<16hex>|gen=<8hex>|reset=<16hex>|engine=<16hex>|inc=<16hex>|batch=<16hex>
```

The fields are, in order, every member used by
`rdma_function_identity::same_incarnation()`, followed by this UVM object's
immutable instance ID, engine incarnation and batch counter. `engine_instance_id`
is the zero-extended `get_inst_id()` captured once immediately after
`super.new()`; it is never reset or copied from another engine. This prevents
two engine objects prepared for the same Function from producing the same
external journal key. Do not use `route_key()` as a shortcut because it omits
parent/vf/global ID/UID/generation/reset identity.

Batch, attempt and reset-proof counters start at zero and publish
`counter + 1`; none of the four counters, including `engine_incarnation`, is
reset or reused. `engine_incarnation` advances only in the successful prepare
commit, but its overflow is checked before Host-memory allocation. Initialize
each new batch record's `reset_isolation_proof` to null so Task 16 can safely
reject unavailable proof authority before Task 17 begins minting it. Proof
lookup by proof key later scans retained journal records and requires exactly
one match; it does not maintain a second associative authority index.

- [ ] **Step 1: Add RED identity, storage and query tests**

  Extend the existing engine probe with narrow wrappers for counter seeding,
  identity allocation, journal installation and fence seeding. Test two
  batches in one incarnation, reset/reprepare into a new incarnation, and
  prove keys/IDs remain unique and nonzero. Build two engine objects with the
  same Function/counter inputs and prove their `engine=` fields differ. Hold
  route/BDF constant while varying parent PF, VF index, global Function ID,
  Function UID, generation and reset epoch one at a time; every canonical key
  must differ. Compare one complete fixture against an exact literal string.
  Seed each counter to
  `64'hffff_ffff_ffff_ffff`; allocation or prepare must return
  `RDMA_SC_RESOURCE_EXHAUSTED` before any Host-memory/scheduler call.

  Install a two-item record and its preallocated publication batch. Query by
  batch and both tickets, mutate every returned nested value, then query again;
  engine state must remain unchanged. Duplicate batch key, duplicate ticket
  index, item/ticket cardinality mismatch, and a partial preallocated batch
  must fail atomically. Fence query must return the exact key/reason without
  exposing a mutable journal handle. Query a retained old ticket while the
  engine is UNCONFIGURED after reset and again after a newer incarnation is
  ACTIVE; both queries must return the old quarantined detached record.

  Give one item a supported non-null polymorphic command body and a retained
  terminal completion with a supported non-null polymorphic
  `decoded_response`. Make the source command owner and item owner the same
  frozen handle. Query the record and require both polymorphic values to be
  non-null, value-equal and graph-detached; require
  `snapshot.items[i].command.recovery_owner ==
  snapshot.items[i].recovery_owner`, while that shared snapshot node is not the
  source owner. Preserve the corresponding ticket/status aliases within the
  returned graph. Mutation of the query snapshot must change neither the
  source fixture nor a second query.

  After building that complete source graph, install hostile raw-factory
  overrides for the outer command/completion/result/record/proof types and for
  every supported polymorphic body/payload type. Exercise journal install,
  both queries, recovery-request snapshot and result snapshot. The operation
  must return a non-null status without `FCTTYP`/fatal, make zero raw-factory
  calls for snapshot construction, and either publish the whole detached graph
  or null—never a partial result. Unknown polymorphic body/payload types fail
  nonfatally with stable `INVALID_ARGUMENT` evidence.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: compile failure for the new storage/query/probe interfaces.

- [ ] **Step 3: Implement stable allocation and detached queries**

  Initialize the immutable instance ID, counters and associative arrays in
  `new()`, but never clear any identity counter in reset/shutdown. Validate the
  candidate incarnation before
  the first prepare I/O and commit it only with the successful transport/
  runtime candidate from Task 12.

  Implement `_locked` helpers for identity allocation, atomic record/index/
  preallocated-batch installation, removal, and invariant checking. They assume
  `engine_lock` is already held and acquire no lock. Finish every allocation,
  clone, key construction, capacity check and collision check before inserting
  any associative-array row. Query tasks directly construct a non-null status,
  acquire only `engine_lock`, and either return one complete detached snapshot
  or null plus a specific non-null error; no partial graph escapes.

  Implement every snapshot seam above without generic UVM
  `copy()/clone()/do_copy()` and without the existing fatal
  `rdma_cmq_clone_*` helpers. The engine direct-constructs and explicitly copies
  command shells, handles, identities, DMA contexts, public mapping values,
  images, results, journal items/records, recovery requests and reset proofs.
  The profile is the only polymorphic body/payload copy boundary and must
  return a detached typed snapshot plus non-null status. Preserve repeated-node
  aliases through one snapshot context per graph and validate complete value
  equality/detachment before publishing. For an adapter-owned mapping whose
  private allocation identity cannot be copied as public scalars, obtain its
  detached opaque authority through `snapshot_release_authority()` and verify
  the non-mutating equivalence contract with `release_authority_status()`. Use
  that verified detached authority object as the graph's mapping snapshot
  rather than slicing it to a base-class public-field copy; never substitute
  public-field equality or a digest for that authority.

  `query_submission_journal_by_ticket()` validates the detached ticket's own
  shape, uses its stable ticket key only to look up `journal_batch_by_ticket`,
  and then requires full equality with the indexed journal item. It must not
  call current-runtime `ticket_has_engine_authority()` or
  `ticket_trust_status()`: old tickets remain valid diagnostic keys after the
  engine resets, releases backing and activates a newer Function incarnation.

  `clear_configuration()` may clear active transport/runtime authority, but it
  must not reset identity counters or silently delete a journal record. Task 17
  defines reset quarantine and proof retention before live records use that
  path.

  Record installation validates each item digest and the batch digest against
  complete candidate values before publishing any index, obtaining the body
  tag/field bytes from the profile seam rather than casting codec types in the
  model or engine. Every query repeats that profile canonicalization and the
  independent recomputation before snapshotting; a corrupt stored value or
  carried digest returns null plus nonfatal `INVALID_STATE`, never a
  self-consistent-looking partial graph.

- [ ] **Step 4: Run GREEN**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: PASS with stable IDs, atomic storage, detached queries and no new
  semaphore.

- [ ] **Step 5: Commit journal storage**

  ```bash
  git add src/core/rdma_cmq_engine.sv tests/unit/rdma_cmq_engine_test.sv
  git commit -m "feat(cmq): add engine-owned submission journal storage" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 14: Preallocate and authenticate the MMIO arm capability

**Files:**

- Modify: `src/core/rdma_cmq_engine.sv`
- Modify: `tests/unit/rdma_cmq_engine_test.sv`

**Interfaces:**

Forward-declare the engine, declare the observer before it, and place the
callback implementation after the complete engine class:

```systemverilog
typedef class rdma_cmq_engine;

class rdma_cmq_mmio_arm_observer
  extends rdma_doorbell_submission_observer;
  local rdma_cmq_engine owner;
  local string capability_key;
  local string batch_key;
  local longint unsigned attempt_id;
  local longint unsigned engine_incarnation;
  local bit configured;

  function rdma_status configure(
    input rdma_cmq_engine owner_arg,
    input string capability_key_arg,
    input string batch_key_arg,
    input longint unsigned attempt_id_arg,
    input longint unsigned engine_incarnation_arg
  );

  function bit is_configured();
  function rdma_cmq_engine owner_handle();
  function string get_capability_key();
  function string get_batch_key();
  function longint unsigned get_attempt_id();
  function longint unsigned get_engine_incarnation();

  extern virtual function void before_mmio_maybe_visible();
endclass

class rdma_cmq_engine extends uvm_object;
  function void arm_submission_for_mmio(
    input rdma_cmq_mmio_arm_observer observer
  );
endclass

function void
rdma_cmq_mmio_arm_observer::before_mmio_maybe_visible();
  owner.arm_submission_for_mmio(this);
endfunction
```

Engine keeps `rdma_cmq_mmio_arm_observer arm_observers[string]`. A capability
is authentic only when the registry contains its key, the registered object is
the exact same class handle, and batch/attempt/incarnation match the journal.
Knowledge of the string fields alone never grants authority. The accessors are
non-virtual read-only value/handle projections; only one-shot `configure()` may
write the local fields. An unconfigured callback reports one stable error and
returns without dereferencing a null owner.

- [ ] **Step 1: Add RED valid, forged and duplicate-arm tests**

  Seed a complete `PENDING_EFFECT` journal and preallocated publication batch,
  register one observer, and call it while the test already holds
  `engine_lock`. Assert it installs every preallocated slot/token/command/entry
  index, advances `publish_seq` once, sets item/batch state to
  `PUBLISH_AMBIGUOUS`, sets effect `MMIO_MAYBE_VISIBLE`, and marks
  `observer_armed=1` without calling scheduler or allocating another object.
  It atomically consumes both the observer registry row and the preallocated
  publication row after transferring their already-created handles into live
  slot/token/command/entry ownership.

  Construct a second observer with copied strings but no registry identity,
  plus wrong batch/attempt/incarnation, missing preallocation, stale-state and
  duplicate-call and unconfigured/null-owner cases. Catch the stable UVM error
  for invalid use and assert
  journal, cursors and registries are byte-for-byte unchanged. Add a re-entry
  probe proving the valid callback does not acquire `engine_lock` or scheduler
  lock and cannot wait.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: compile failure because the CMQ arm observer and entry are absent.

- [ ] **Step 3: Implement the no-fail locked arm transition**

  During staging, create/configure/register the observer and every journal,
  slot and index object before transport can run. `configure()` is one-shot and
  saves non-owning owner plus immutable scalar keys. The valid callback performs
  only associative lookups, exact object-identity comparisons, scalar writes,
  installation of already-created handles and removal of its registry row. It
  performs no `new`, clone, string formatting, wait, semaphore operation,
  adapter call, service call or scheduler re-entry.

  Authenticate through the non-virtual accessors: require `is_configured()`,
  `owner_handle()==this`, exact registered observer object identity, and exact
  batch/attempt/incarnation fields before touching state. After all checks,
  transfer the preallocated handles, advance the cursor and state, then delete
  the capability and preallocation rows in the same allocation-free function.

  `arm_submission_for_mmio()` is public only because the separately declared
  callback must reach it. Invalid/forged calls emit one stable diagnostic and
  return without mutation. A valid staged capability is an invariant and has
  no recoverable failure result; after it commits, duplicate invocation cannot
  advance a cursor twice.

- [ ] **Step 4: Run GREEN**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: PASS; valid arm is one-shot and allocation-free, while every forged
  or stale observer leaves engine state unchanged.

- [ ] **Step 5: Commit the arm capability**

  ```bash
  git add src/core/rdma_cmq_engine.sv tests/unit/rdma_cmq_engine_test.sv
  git commit -m "feat(cmq): authenticate the pre-MMIO arm transition" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 15: Publish observed single and batch submission results

**Files:**

- Modify: `src/core/rdma_cmq_engine.sv`
- Modify: `tests/unit/rdma_cmq_engine_test.sv`

**Interfaces:**

```systemverilog
task submit_batch_observed(
  input rdma_cmq_command_desc commands[],
  output rdma_cmq_execution_result results[],
  output rdma_status batch_status
);

task submit_observed(
  input rdma_cmq_command_desc command,
  output rdma_cmq_execution_result result
);
```

Legacy `submit_batch()` and `submit()` become one-way projections from these
entries. The observed batch result remains indexed by original request index;
the journal contains only successfully admitted items and records each
`request_index` explicitly.

- [ ] **Step 1: Add RED observed-batch and failure-stage tests**

  Freeze the four batch-table cases from spec section 5.2: empty input, all
  local rejection, mixed rejected/admitted items, and batch-level transport
  failure. Assert `results.size()==commands.size()` and every result, operation
  status and observation status is non-null; locally rejected items keep null ticket,
  `submission_effect=attempt_effect=PRE_SUBMIT_REJECTED`, completion phase
  `NONE`, their original index and exact failure. Empty/all-local
  batches call transport zero times and return orchestration `OK`.

  Exercise empty input while the engine is unconfigured, poisoned and fenced.
  It is an unconditional fast path before ACTIVE/fence/authority checks: every
  case returns an empty result array and direct non-null `OK` batch status with
  no ID allocation, journal mutation, lock-dependent adapter call or scheduler
  I/O.

  Replace existing `check_all_transport_failure_rollbacks()` (which currently
  expects host/DMA/MMIO failures to erase tickets/ledger) with
  `check_observed_transport_failure_retention()` implementing the matrix below,
  and replace its `run_phase()` call in the same test commit. Update the empty
  branch of `check_empty_invalid_and_state_rejections()` from prepared-state
  `INVALID_STATE` to unconditional `OK`, then add the unconfigured/poisoned/
  fenced cases there. These are intentional characterization changes required
  by the new journal contract, not failures to preserve.

  For a three-item admitted batch, inject failure at the first, middle and last
  dependency write, DMA barrier, MMIO barrier, deadline immediately before
  MMIO, MMIO error and MMIO success. Before calling transport, assert the full
  record and all preallocated nodes already exist in `PENDING_EFFECT`. Expected
  outcomes are:

  | Scheduler effect/observer | Journal/result state and cumulative effect | Completion phase |
  | --- | --- | --- |
  | `PRE_SUBMIT_REJECTED`, not armed | remove record/reservations; returned tickets null | `NONE` |
  | `HOST_MEMORY_MAYBE_VISIBLE` through `HOST_MEMORY_ORDERED`, not armed | `HOST_VISIBLE_NOT_PUBLISHED`; retain tickets/record; exact effect; install fence | `NONE` |
  | `MMIO_MAYBE_VISIBLE`, armed | `PUBLISH_AMBIGUOUS`; retain published indices; clear pre-MMIO fence | `PENDING` |
  | `MMIO_VISIBLE`, armed | `PUBLISH_CONFIRMED`; retain published indices; clear pre-MMIO fence | `PENDING` |
  | null/degraded result after delegation, observer not armed | `HOST_VISIBLE_NOT_PUBLISHED`; cumulative/attempt effect `UNOBSERVED`; retain preallocation/tickets and install fence; no index/cursor publication | `NONE` |
  | null/degraded result after delegation, observer armed | retain callback-established `PUBLISH_AMBIGUOUS`; cumulative effect at least `MMIO_MAYBE_VISIBLE`, attempt effect `UNOBSERVED`; never roll back | `PENDING` |

  Assert `recovery_required=0` only for initial local PRE rejection with no
  journal. Every Host-visible, pending/published or post-delegation UNOBSERVED
  row sets it to one. Reliable operation failures keep observation status OK;
  only degraded envelopes or observer/effect contradictions set observation
  INVALID_STATE, without changing operation status or either effect.

  For every admitted fixture, independently recompute all item digests and the
  batch digest from the record and require the stored values to match. Mutate
  caller commands/results after return and prove the retained item and batch
  digests plus their complete source values remain unchanged.

  Inject the two null-result branches independently: one scheduler returns null
  before invoking the observer after a possible dependency write, and one
  invokes the authentic observer then returns null. In the first branch assert
  `publish_seq`, slot/command/entry indices and observer registry remain
  uncommitted; in the second assert they were committed exactly once by the
  callback. Also inject an inconsistent result that reports an MMIO effect
  without arming, and one that arms then reports a pre-MMIO effect. The former
  fences as `HOST_VISIBLE_NOT_PUBLISHED` without late publication, records
  cumulative/attempt `UNOBSERVED` and sets `publication_retry_safe=0`; the
  latter stays `PUBLISH_AMBIGUOUS` with cumulative effect at least
  `MMIO_MAYBE_VISIBLE`. Both return non-null invalid observation evidence.

  While fenced, a second batch must return each item as
  `RDMA_SC_RESOURCE_BUSY + PRE_SUBMIT_REJECTED` without scheduler I/O; journal
  query, poll, wait, recovery and reset probes remain callable. Verify
  caller-side mutation of commands/results cannot mutate the journal. Retain a
  handle to the initial observer and call it after every synchronous unarmed
  transport return; it must have been removed from the registry and the stale
  call must leave all state unchanged. A retry registers a distinct capability
  for its new attempt.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: compile failure for the observed submit APIs.

- [ ] **Step 3: Refactor staging into the observed transaction**

  Handle empty input first, then initialize the full result array and
  direct-new operation/observation statuses before taking the lock. Preserve
  existing per-item admission and compressed-one-doorbell
  semantics, but replace the eight parallel tentative arrays with one
  preallocated batch/item object graph. Capture command identity and detach the
  full command, ticket, owner, DMA context, SQE, mapping and dependency image;
  freeze each concrete MR/queue/QP owner with the allocated admission attempt
  ID. Validate and store an exact `LEGACY_UNMIGRATED` sentinel unchanged; do not
  freeze or grant recovery actions to it. Set
  `dependency_replay_safe=1` only when mapping identity is the engine's
  exclusively owned CMQ backing, bytes/offset are exact snapshots, and Function
  generation/reset epoch match.

  Allocate batch/attempt IDs and build the final doorbell/observer before I/O.
  Ask the profile to canonicalize each exact detached command body and pass
  its returned V1 tag/field bytes to the Task 9 item helper; an unsupported or
  malformed body fails before journal publication or I/O. Compute each item
  image/authority digest, then compute the batch digest from
  complete frozen Function/binding/CMQ/doorbell/PI/polarity/sequence authority
  and ordered item digests. Copy the same complete batch projection and digest
  into detached recovery requests; never recompute it from mutable
  state/effect/status fields.
  Atomically install journal plus ticket index as `PENDING_EFFECT`, then call
  the Task 12 transport with the Task 14 observer while still following
  `engine_lock -> scheduler Function transport lock`. Classify only the
  returned per-call effect and the engine journal's authenticated
  `observer_armed` state according to the table; never trust the scheduler's
  boolean alone and never inspect status code, ticket nullness or completion
  nullness to infer effect. The Task 14 callback is the only code allowed to
  install slot/command/entry indices or advance `publish_seq`; Task 15 must not
  reconstruct or perform that transition after transport returns.
  Once any Host-memory write may be visible, no error cleanup may release the
  journal, slot reservation, token, ticket or preallocated publication batch.

  A host-visible, unarmed pre-MMIO failure installs exactly one
  `fenced_batch_key` and reason; a proven `PRE_SUBMIT_REJECTED` performs atomic
  local rollback instead. A null/invalid transport result after delegation is
  never treated as proven rejection. Check the fence before allocating IDs or
  calling scheduler for every new submit. Arm removes that fence as part of the
  no-fail cursor/index commit. Populate
  each admitted result from its journal item, preserving the original result
  index and returning the current batch/attempt IDs and `recovery_required`.
  On the initial attempt, set cumulative `submission_effect` and
  `attempt_effect` to the same classified value except a degraded envelope,
  whose attempt effect stays `UNOBSERVED` and whose cumulative effect follows
  the table. Populate item/result completion phase in that same transition;
  only an authentic arm creates `PENDING`. Set batch
  `publication_retry_safe=1` only for an unarmed
  `HOST_VISIBLE_NOT_PUBLISHED` batch whose observer absence proves MMIO was not
  entered and whose every dependency item is replay-safe. A legacy-owner item can still
  require conservative reconciliation, but automatic retry remains forbidden
  because its owner permits no action.
  Call the Task 9 recovery-required classifier on every stored/returned item:
  initial PRE rollback publishes zero, and every retained Host-visible,
  pending/published or degraded UNOBSERVED lifetime publishes one. Operation
  status and observation status follow their independent frozen table; neither
  status may alter the classified effects.
  Batch status describes orchestration only and never overwrites an item status.

  As soon as transport returns synchronously without an authentic arm, delete
  that attempt's observer registry row. Proven pre-submit rejection removes its
  journal and preallocation too; Host-visible/unknown unarmed outcomes retain
  journal plus preallocation behind the fence, but the stale observer handle is
  no longer capable. The fresh retry path in Task 16 must create/register a new
  observer before I/O.

  `submit_observed()` constructs a one-item array and calls
  `submit_batch_observed()` exactly once. Legacy `submit_batch()` projects
  ticket/status arrays with nonfatal direct copies; legacy `submit()` calls the
  one-item observed entry exactly once. No wrapper stores call-level evidence.

- [ ] **Step 4: Run GREEN and compatibility tests**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  scripts/run_vcs53.sh core rdma_cmq_port_test
  ```

  Expected: observed and legacy outputs match field-for-field on successful,
  local-reject and timeout setup paths; all injected post-write failures retain
  recoverable journal ownership.

- [ ] **Step 5: Commit observed submission**

  ```bash
  git add src/core/rdma_cmq_engine.sv tests/unit/rdma_cmq_engine_test.sv
  git commit -m "feat(cmq): journal observed batch submission" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 16: Add CAS-guarded retry of a fenced publication

**Files:**

- Modify: `src/core/rdma_cmq_engine.sv`
- Modify: `tests/unit/rdma_cmq_engine_test.sv`

**Interfaces:**

```systemverilog
task recover_submission_observed(
  input rdma_cmq_submission_recovery_request request,
  output rdma_cmq_execution_result results[],
  output rdma_status status
);
```

The recovery implementation uses two narrow, non-virtual comparison helpers;
the engine probe may expose them without adding a production fault hook:

```systemverilog
protected function rdma_status validate_recovery_item_match_locked(
  input rdma_cmq_submission_recovery_item request_item,
  input rdma_cmq_batch_submission_item_record journal_item,
  input rdma_cmq_journal_digest_t recomputed_request_image_digest,
  input rdma_cmq_journal_digest_t recomputed_request_authority_digest,
  input rdma_cmq_journal_digest_t recomputed_journal_image_digest,
  input rdma_cmq_journal_digest_t recomputed_journal_authority_digest
);

protected function rdma_status validate_recovery_batch_match_locked(
  input rdma_cmq_submission_recovery_request request,
  input rdma_cmq_batch_submission_record journal_record,
  input rdma_cmq_journal_digest_t recomputed_request_batch_digest,
  input rdma_cmq_journal_digest_t recomputed_journal_batch_digest
);
```

`RETRY_PUBLISH` reuses the original batch/slot/ticket/bytes and obtains one new
global attempt ID. `CONFIRM_RESET_ISOLATION` is parsed and validated here but
cannot succeed until Task 17 has minted a READY proof in the authoritative
journal record field created by Task 13; Task 16 never manufactures or
auto-promotes a proof. After
the common locate/cardinality/order checks, the two actions enter separate
authority pipelines. RETRY validates the live fence, replay-safe mapping and
scheduler capability; CONFIRM validates only retained reset-proof/journal
authority and never falls through to retry mapping, observer or I/O logic.
CONFIRM still CAS-checks the request's expected current attempt, but allocates
no new attempt ID and never advances `attempt_id_counter`.

- [ ] **Step 1: Add RED request-shape, authority and CAS tests**

  Assert null request, unknown batch, wrong batch ID/key, missing/extra/
  duplicate/reordered items and wrong Function identity return empty results,
  a non-null `INVALID_ARGUMENT`/`INVALID_STATE`, and no mutation. For a located
  structurally valid batch, stale expected attempt returns results equal and in
  order with request items, each operation/observation status non-null and
  message exactly
  `stale CMQ recovery attempt`, with zero scheduler calls.

  Invalid/spare/unknown recovery action and a well-shaped
  `CONFIRM_RESET_ISOLATION` request whose proof is absent/not READY are located
  failures: results remain equal in cardinality/order to request items, every
  result is non-null, and journal/fence/counters remain unchanged. Only failures
  that cannot locate or structurally align a batch return an empty result array.

  For RETRY, mutate each request-supplied item or batch digest in isolation.
  Independently tamper one journal value while retaining its stored digest,
  tamper one stored journal item/batch digest while retaining its value, and
  tamper both sides to different values. Every case fails before I/O. The
  validation order is frozen: recompute all request item/batch digests and
  compare them with request-carried values; independently recompute all
  journal item/batch digests and compare them with journal-carried values;
  compare the two sets of recomputed digests; only then compare every complete
  detached request/journal value field-for-field.

  Do not search for or claim a real 256-bit collision. Through a narrow probe
  wrapper around the two production comparison helpers, pass identical
  synthetic recomputed/carried digests while changing the complete request
  command, ticket, owner, DMA context, SQE byte, mapping, offset, dependency
  byte or batch Function identity, binding, CMQ handle, doorbell metadata/byte,
  final PI, final polarity, start sequence or end sequence. Full-value comparison must still
  reject every case. Digest equality alone never authorizes retry. Also reject current binding/
  generation/reset-epoch drift, non-exclusive mapping,
  `dependency_replay_safe=0`, observer already armed, any state except
  `HOST_VISIBLE_NOT_PUBLISHED`, `publication_retry_safe=0`, a prior cumulative
  effect outside the explicit set `{UNOBSERVED, HOST_MEMORY_MAYBE_VISIBLE,
  HOST_MEMORY_WRITTEN, HOST_MEMORY_ORDERED}`, an
  active fence key different from this batch, or a still-registered stale
  observer from the prior attempt.

  Give request and journal mappings identical public Function/route/address/
  length/permission fields but different concrete adapter allocation tokens.
  Require `snapshot_release_authority()` plus the mapping's read-only
  `release_authority_status()` equivalence check to reject the request before
  CAS/I/O; public equality and matching digests are insufficient.

  For every aligned item, corrupt `owner.frozen`, immutable admission attempt,
  identity, workflow/resource kind or allowed-action mask and require
  `owner.validate_frozen()` followed by `owner.permits(request.action)` to
  reject it. In a mixed MR/QP/queue-owner batch, deny the action on only the
  middle owner and prove the whole request returns aligned per-item failures
  with reliable observation OK, retained `recovery_required=1`, and no
  counter/CAS, scheduler I/O, journal/fence/observer or owner mutation.
  Specifically send CONFIRM with a RETRY-only owner and RETRY with a
  CONFIRM-only owner; both are aligned authorization failures rather than
  structural empty-result failures.

  Launch two recoveries with the same `expected_attempt_id` against a blocking
  scheduler. Exactly one increments the attempt and performs dependency/MMIO
  I/O; after it releases the engine lock, the other returns stale. Seed attempt
  counter overflow and inject descriptor/result/owner/observer construction,
  configure and registry-collision failures; all must return before the global
  attempt counter, record attempt or capability registry changes and before
  Host-memory/scheduler I/O.

  Make an earlier attempt reach `HOST_MEMORY_ORDERED`, then have a retry fail
  pre-submit. Its result must report
  `attempt_effect=PRE_SUBMIT_REJECTED` while cumulative
  `submission_effect=HOST_MEMORY_ORDERED`; presence can never become absent.
  Also drive `null result + unarmed` to cumulative `UNOBSERVED`, then make its
  retry authentically arm: the retry result must retain
  `attempt_effect=UNOBSERVED` only if its own envelope is degraded, while
  cumulative evidence advances to at least `MMIO_MAYBE_VISIBLE` from the real
  arm callback.
  Add the complete three-attempt chain
  `UNOBSERVED -> PRE_SUBMIT_REJECTED -> authentic arm`: after the first retry,
  `attempt_effect` is PRE, the current attempt ID advances, cumulative effect
  and `recovery_required` remain UNOBSERVED/one, the fence remains recoverable
  and no old observer becomes capable. The next retry obtains another attempt
  ID; an authentic arm advances cumulative evidence to at least
  `MMIO_MAYBE_VISIBLE` while preserving that attempt's raw effect and the
  frozen owner's original `admission_attempt_id`.
  Check that every retry first requires all reused ticket absolute deadlines to
  be strictly greater than `$time`, then sets the shared doorbell timeout to
  the exact minimum remaining duration
  `min(ticket.absolute_deadline - $time)`. An expired/zero/unknown remaining
  interval returns aligned timeout/invalid results with no CAS/I/O. Every
  original `ticket.absolute_deadline` remains byte-for-byte unchanged.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: compile failure because the recovery entry is absent.

- [ ] **Step 3: Implement full-value CAS retry**

  Directly initialize top-level status and output array. Locate and validate
  batch/item structure under `engine_lock`; structural identity failures return
  empty results. For a located, well-shaped request, allocate one result per
  request item before any possible return, including stale/action/transport
  failures.

  Canonicalize every request-owned body and every journal-owned body through
  separate profile calls; do not reuse or trust bytes obtained for the other
  graph. Recompute every request item image/authority digest and its batch
  digest from request-carried full values, then compare them with the corresponding
  request-carried digests. Independently recompute the same item and batch
  domains from the journal and compare them with the journal-carried digests.
  Next compare request recomputations with journal recomputations, then call
  the narrow helpers to compare every full detached item and batch field in a
  stable order. Never compare a request digest directly with an unverified
  stored journal digest. The batch comparison includes binding, CMQ handle,
  doorbell image/metadata, final PI/polarity, start/end sequence and ordered
  item digests. The item helper also requires
  `command.recovery_owner == recovery_owner` as the canonical internal alias,
  `owner.validate_frozen()` against immutable Function/admission provenance and
  `owner.permits(request.action)` for every item before either action may
  mutate state.

  For RETRY only, compare current engine binding/Function identity to the
  journal and prove the current mapping is the same opaque allocation: obtain
  a detached authority with `snapshot_release_authority()` and call the
  concrete mapping's non-mutating `release_authority_status()` equivalence
  check. Matching public mapping fields or digests never replace that check.
  Require the active fence key to equal this batch and require no prior
  capability row. Complete validation and staging for all items before any
  CAS; one denied mixed-batch owner rejects the request atomically.

  Treat `attempt_id_counter + 1` as a candidate only. Before mutating any
  counter/record/registry, validate every item and concrete recovery owner,
  direct-construct all aligned results and statuses, rebuild/validate the full
  descriptor, validate every reused absolute deadline and compute its minimum
  strictly positive remaining interval, prepare all
  snapshots, configure a fresh observer for the candidate ID, and check every
  key/capacity/collision. Legacy sentinels cannot RETRY because they permit no
  action. Only after every fallible local step succeeds does one locked CAS
  block recheck `expected_attempt_id`, commit the global counter and journal
  current attempt, update the retained preallocated batch attempt, initialize
  every item/result current-attempt status/effect, and insert the new observer
  as one atomic state change. Journal, preallocation, observer and returned
  result must all carry the same current attempt ID; the frozen owner's
  `admission_attempt_id` never changes.

  Rebuild the descriptor only from journal binding/CMQ/doorbell/dependency
  snapshots and reuse the exact existing preallocated slot/ticket graph. The
  descriptor's scheduler timeout is the minimum remaining duration of the
  original tickets at the locked pre-CAS check. Do not restart a command timeout
  from recovery call entry and do not modify or extend any ticket absolute
  deadline. The new attempt writes `attempt_effect`.
  Cumulative `submission_effect` retains the prior Host-visible high-water on
  `PRE_SUBMIT_REJECTED`/unarmed unknown results and otherwise advances only to a
  later proven stage through `rdma_cmq_fold_attempt_effect()`. For a degraded
  armed result, feed the authentic callback's `MMIO_MAYBE_VISIBLE` evidence to
  the fold while retaining raw `attempt_effect=UNOBSERVED` for diagnostics.
  `rdma_submission_effect_is_monotonic()` applies inside one attempt, not when
  merging separate attempts. Never compare the numeric enum value of
  `UNOBSERVED` to a Host-memory stage. A retry that remains pre-MMIO keeps the fence and revokes
  its now-stale observer when transport returns; arm transitions through the
  existing Task 14 path, consumes the capability/preallocation and clears the
  fence. Return cumulative effect, current-attempt effect and the new current
  attempt ID in every item whether transport succeeds or fails.

  Recompute `recovery_required` from retained lifetime state after each retry.
  A current PRE attempt never clears a prior Host-visible or UNOBSERVED bit;
  authentic publication, timeout and unconfirmed reset keep it set until the
  corresponding terminal/late/reset-confirm transition resolves authority.

  For `CONFIRM_RESET_ISOLATION`, switch into a distinct no-I/O pipeline after
  common alignment and owner permission checks. Validate the request-carried
  batch digest, the exact unique READY proof value retained on the journal
  record, proof-carried batch
  digest, recomputed proof digest and every full ordered tuple. After the
  stable proof-digest checks, compare the complete request proof with the
  retained proof, including excluded readiness fields `replacement_identity`,
  `state` and `backing_release_confirmed`, and validate the legal transition;
  recomputing a matching digest for changed included fields still fails this
  full-value comparison. Do not compare
  the released old mapping with a replacement mapping, inspect RETRY replay
  safety, require an active submission fence, allocate an observer, call
  scheduler/reset, or clear a submission fence. Until Task 17 mints a proof,
  return aligned non-null invalid-state results without mutation; a
  matching-looking unregistered proof is never authority. Once Task 17 provides
  READY authority, recheck `expected_attempt_id` in the same locked commit,
  set each authorized item's `reset_isolation_confirmed=1` and
  `recovery_required=0`, and retain record/proof diagnostics. Do not allocate or
  advance an attempt ID for this action.

- [ ] **Step 4: Run GREEN**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: PASS; one CAS winner performs I/O, collisions/authority drift are
  rejected, and every failed retry preserves the fenced journal.

- [ ] **Step 5: Commit controlled recovery**

  ```bash
  git add src/core/rdma_cmq_engine.sv tests/unit/rdma_cmq_engine_test.sv
  git commit -m "feat(cmq): add CAS-guarded publication recovery" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 17: Integrate timeout, late completion and reset-isolation proofs

**Files:**

- Modify: `src/adapter/rdma_host_mem_api.sv`
- Modify: `src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv`
- Modify: `src/integration/rdma_host_mem_router.sv`
- Modify: `src/core/rdma_cmq_engine.sv`
- Modify: `tests/mocks/rdma_mock_adapters.sv`
- Modify: `tests/integration/rdma_host_mem_adapter_test.sv`
- Modify: `tests/unit/rdma_host_mem_router_test.sv`
- Modify: `tests/unit/rdma_cmq_engine_test.sv`
- Modify: `docs/superpowers/specs/2026-09-11-rdma-engine-contract-refactoring-design.md`

**Interfaces:**

Strengthen the in-project Host-memory adapter contract with one read-only
capability check; no external dependency repository changes:

```systemverilog
virtual function rdma_status validate_failure_atomic_release(
  input rdma_dma_mapping mapping
);
```

The base implementation returns `RDMA_SC_UNSUPPORTED_OPCODE`. A concrete
adapter returns OK only when `release_opaque(mapping)` obeys this frozen
contract: null/non-OK release leaves the allocation active, readable through
the same opaque authority and retryable; OK means backing and release authority
are fully retired exactly once. The validator itself performs no release or
state mutation. The production Host-memory adapter, router and mock implement
the check for the exact mapping/manager selected by opaque allocation identity.

```systemverilog
task reset_observed(
  output rdma_cmq_completion completions[$],
  output rdma_cmq_reset_isolation_proof proofs[],
  output rdma_status status
);

task query_reset_isolation_proof(
  input string proof_key,
  output rdma_cmq_reset_isolation_proof proof,
  output rdma_status status
);
```

Reset uses an engine-internal candidate rather than the destructive current
`cancel_generation_locked()` path:

```systemverilog
class rdma_cmq_reset_item_candidate extends uvm_object;
  string batch_key;
  int unsigned request_index;
  int unsigned slot_index;
  string command_key;
  string entry_key;
  rdma_cmq_completion cancellation_completion;
endclass

class rdma_cmq_reset_batch_candidate extends uvm_object;
  string batch_key;
  rdma_cmq_batch_submission_record quarantined_record;
  rdma_cmq_reset_isolation_proof journal_proof;
  rdma_cmq_reset_isolation_proof returned_proof;
endclass

class rdma_cmq_reset_candidate extends uvm_object;
  rdma_function_identity isolated_identity;
  rdma_dma_mapping backing_release_authority;
  rdma_cmq_reset_item_candidate items[$];
  rdma_cmq_reset_batch_candidate batches[$];
  rdma_cmq_completion returned_completions[$];
endclass

protected function rdma_status stage_reset_candidate_locked(
  output rdma_cmq_reset_candidate candidate
);

protected function void commit_reset_candidate_locked(
  input rdma_cmq_reset_candidate candidate
);
```

Engine stores the authoritative proof on its already-existing retained batch
record and queries proof keys by a uniqueness-checked journal scan; no second
proof authority table is inserted during reset. Old-entry diagnostic lookup
uses the same retained-journal scan keyed by complete old Function incarnation
plus entry key and requires exactly one match; reset does not install another
associative index. Each proof carries equal-length ordered request-index,
image-digest,
authority-digest and full-owner arrays plus the journal `batch_digest` and its
own canonical `proof_digest`; together with its batch/attempt/engine/Function
fields, those values identify every isolated item rather than collapsing a
mixed-owner batch into one digest. Legacy `reset()` calls `reset_observed()`
once and projects only the historical completion/status outputs.

Freeze legacy `reconcile_ticket()` as a read-only journal projection. It first
locates the retained record by stable ticket index and full ticket equality;
current-runtime authority is consulted only for an authentically published
item in the active incarnation. Its behavior is:

| Journal state / phase | `reconcile_ticket()` result |
| --- | --- |
| `HOST_VISIBLE_NOT_PUBLISHED/NONE` | `terminal_known=0`, null completion, detached exact item operation status; no poll, retry or doorbell |
| `PUBLISH_AMBIGUOUS` or `PUBLISH_CONFIRMED/PENDING` in current active incarnation | run ordinary expire/poll once, then re-read this journal item |
| `COMPLETED/TERMINAL` | `terminal_known=1`, detached retained terminal completion/status |
| `TIMED_OUT_QUARANTINED/TIMEOUT` | `terminal_known=1`, detached retained timeout completion/status |
| `LATE_COMPLETED/DIAGNOSTIC_ONLY` | `terminal_known=1`, detached retained late-final completion/status |
| `RESET_QUARANTINED/RESET_CANCELLED` | `terminal_known=1`, detached retained reset completion/status, including after reprepare |
| `STAGED` or `PENDING_EFFECT` | fail-closed observation error; no external I/O or state change |

The terminal rows are idempotent snapshots; removing a delivery-order FIFO row
does not remove the journal completion. Reconcile never invokes
`RETRY_PUBLISH`, never rings a doorbell, and never rejects an old reset ticket
merely because the current runtime now belongs to a newer incarnation.

- [ ] **Step 1: Add RED item-lifecycle and proof tests**

  First add Host-memory contract tests for the production adapter, router and
  mock. A valid active mapping must pass
  `validate_failure_atomic_release()` without mutation; unknown/default,
  released and wrong-manager mappings fail. Inject non-null failure and null
  status before release and prove mapping state, opaque allocation equivalence,
  router ledger, release-completion seal and read access remain unchanged and a
  second release can succeed. The engine must reject an adapter that does not
  advertise this contract before reset staging/backing I/O.

  Submit mixed batches and drive one item through normal completion, one through
  timeout then same-epoch late completion, and one through reset. Assert
  item-level states/phases are respectively `COMPLETED/TERMINAL`,
  `TIMED_OUT_QUARANTINED/TIMEOUT` then
  `LATE_COMPLETED/DIAGNOSTIC_ONLY`, and
  `RESET_QUARANTINED/RESET_CANCELLED`. Aggregate state must come only from the
  Task 9 reducer. Timeout retains old slot/entry/ticket/token incarnation and
  does not make the slot reusable. Require `recovery_required` to be zero for
  normal completion and resolved late completion, one for timeout, one for a
  concrete-owner unconfirmed reset proof, and zero for the exact legacy
  sentinel immediately after confirmed backing release.

  Exercise every reconcile table row, including an unarmed fenced ticket,
  terminal/timeout/late/reset evidence after its legacy FIFO row was consumed,
  and an old reset ticket after a newer incarnation becomes ACTIVE. Repeated
  terminal reconcile returns value-equal but separately detached completion
  graphs. The unarmed row performs zero scheduler/MMIO calls, and
  STAGED/PENDING_EFFECT returns observation failure without changing either
  effect or `recovery_required`.

  Expire the absolute deadline inside `wait_for()` and require non-null
  `RDMA_SC_TIMEOUT`; `INVALID_STATE` is forbidden. Block a waiter, perform a
  complete reset/reprepare/activate, seed valid-looking bytes in the new CQ
  backing, then wake the old waiter. On every unlock/relock it must revalidate
  journal batch, engine incarnation, Function generation/reset epoch and
  ticket before reading CQ or expiring; the old waiter returns only retained
  reset evidence and cannot consume the new bytes.

  Do not claim that a CQE itself carries reset epoch—it does not. Verify the
  released old mapping rejects further Host-memory access and the new backing
  is independently zeroed/owned. For old-entry diagnostic bookkeeping, use a
  narrow protected probe that supplies an already detached old identity,
  old-entry key and raw CQE to the retained-journal uniqueness scan; label this
  as an out-of-band test seam, not as wire decoding. Its output may append old
  diagnostic evidence but must not change the new slot/token/cursor/result.

  Exercise reset release failure/null status and prove no proof is minted and
  no old journal, fence, preallocation, observer, slot/token/index, cursor,
  terminal/late FIFO, proof counter, engine state or backing-authority handle
  changes. Snapshot every structure before reset and compare it after failure;
  `cancel_generation_locked()`, `clear_configuration()` and completion
  publication must not run on this branch. In
  `check_reset_fifo_retry_and_reprepare()`, replace the old release-failure
  expectations `terminal_fifo_count()==1` and `outstanding_count()==0` (and the
  corresponding null-release expectations) with exact preservation of the
  pre-call FIFO/outstanding counts, slot/index/cursors and ACTIVE/POISONED state.

  Successful logical cancellation plus backing release creates one
  `AWAITING_REBIND` proof per affected batch. Verify each proof carries the
  journal batch digest and equal-length ordered request-index/image-digest/
  authority-digest/full-owner arrays, and that independent recomputation of its
  proof digest matches the carried value. A forged matching-looking object with
  no corresponding journal-resident proof is rejected. Same/lower epoch or a
  different immutable Function cannot make a proof READY; successful activation
  of the same immutable Function at a strictly greater reset epoch records
  replacement identity and changes it to READY. Reset N affected batches with
  the proof counter at `UINT64_MAX-N` (success) and `UINT64_MAX-N+1` (reject
  before reset I/O).

  Mutate/reorder independently every immutable proof-digest input: proof
  key/ID, batch key/ID/digest, attempt ID, engine instance/incarnation, isolated
  Function identity, request index, image digest, authority digest and full
  recovery owner. Test both a stale carried digest and a recomputed matching
  digest for each changed included value; final complete equality rejects the
  latter without pretending to find a hash collision. Separately mutate
  replacement identity, proof state and release-confirmation bit. Those three
  readiness fields intentionally do not change the stable proof digest, so the
  journal-authoritative full-value comparison and legal-transition validator
  must reject them. Also mutate `proof_digest` itself. Every case fails before
  journal state changes.

  Retain the journal-resident proof and cancellation completion, but return
  separately detached snapshots from `reset_observed()`. Mutate every nested
  field in the returned proof/completion arrays, then query the proof and read
  the retained terminal/reset evidence again; journal values, internal alias
  topology and later wait/reconcile results must be unchanged.

  After successful release, assert old runtime/preallocation/capability backing
  is discarded, the submission fence is cleared immediately and the engine can
  prepare a replacement mapping before proof confirmation. Exact legacy-owner
  sentinel items become resolved (`recovery_required=0`) at release. Concrete
  owners remain `recovery_required=1` through AWAITING_REBIND and READY, then
  become zero only after their permitted CONFIRM action succeeds. Confirm with
  the independently allocated replacement mapping present: it must not compare
  that mapping with the released old allocation, require/re-clear a fence, call
  scheduler/reset/Host-memory, or advance attempt ID. RETRY-only owners and a
  mixed batch containing one owner that denies CONFIRM fail atomically.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem \
    scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
  : "${DPU_COMMON_ROOT:?export the Task 6A approved 53 path}"
  export DPU_COMMON_ROOT
  scripts/run_vcs53.sh integration rdma_host_mem_router_test
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: lifecycle/proof assertions fail because journal transitions and
  observed reset are not connected.

- [ ] **Step 3: Wire lifecycle transitions and proof publication**

  Add `validate_failure_atomic_release()` to the base API with fail-closed
  default, and implement it in the production adapter, router and mock by
  locating the exact opaque allocation without changing state. Tighten their
  `release_opaque()` contract and null-status handling: every validation or
  injected backend failure returns before completion sealing/free/ledger
  deletion; success performs all three exactly once. The router keeps its own
  ledger until a non-null successful manager result. `reset_observed()` requires
  validator OK before constructing a candidate or calling release; an
  unsupported adapter is a local reset refusal, not evidence that backing was
  isolated.

  Store batch key/item index on each published slot record. On normal poll,
  timeout, late completion and cancellation, update that exact journal item
  under `engine_lock`, set phase from the actual transition, then call the
  pure reducer and Task 9 recovery-required classifier. Never derive phase from
  completion presence or status code. These lifecycle updates retain both
  attempt and cumulative effects unchanged.
  `wait_for()` deadline calls the existing timeout constructor and returns the
  generated `RDMA_SC_TIMEOUT` value while retaining quarantine ownership.

  Rework `reconcile_ticket()` to use the journal-by-ticket index before current
  runtime validation and implement the frozen table above. Poll/expire only an
  active-incarnation PENDING item; all terminal/timeout/late/reset rows snapshot
  the item's retained completion through the Task 13 nonfatal seam. Do not pop
  or transfer the journal completion handle, and do not call current-runtime
  `ticket_has_engine_authority()` for an unarmed or old-quarantined ticket.

  `stage_reset_candidate_locked()` is a mutation-free phase. It counts affected
  batches N, requires `N <= UINT64_MAX - reset_proof_id_counter`, snapshots the
  old opaque backing release authority, and direct-constructs every
  cancellation completion, journal proof, separately detached returned
  proof/completion, key and ordered tuple before external release. It also
  sizes and fills the task's caller-output arrays while they remain
  unobservable inside the blocked task; a release failure clears those outputs
  before returning. For each proof it copies the journal
  `batch_digest`, fills equal nonzero request-index/image-digest/
  authority-digest/full-owner arrays in exact request order, computes
  `proof_digest`, and revalidates all complete values. The stage function does
  not call `cancel_generation_locked()`, insert/delete an engine container row,
  push a FIFO, clear an index/cursor, advance a counter, change engine state or
  publish an internally reachable handle.

  `reset_observed()` then invokes backing release against the staged opaque
  authority. Null/failing release discards only the local candidate and returns
  an error; journal/fence/preallocation/capability/slot/token/index/cursors,
  completion FIFOs, counters, engine state and backing handle remain exactly as
  before the call. Do not call the existing destructive
  `cancel_generation_locked()` before release, and remove/refactor its use from
  this reset path.

  Only after release succeeds does `commit_reset_candidate_locked()` perform
  an allocation-free, no-fail commit. It writes scalar state/phase/flags and
  prebuilt completion/proof handles only into already-existing journal batch/
  item objects; the proof is stored in that batch's
  `reset_isolation_proof` field. It does not insert or replace an associative
  row and does not push a queue. Existing delivery FIFOs may be deleted because
  every completion is already retained on its journal item and the caller
  outputs were staged before release. The same commit advances the proof
  counter by N and only deletes/clears released old-epoch runtime,
  preallocation, capability, slot/token/index/cursor authority, the submission
  fence and active configuration so a new prepare may allocate independent
  backing. No post-release path calls `new`, `new[]`, factory, clone, profile,
  string/key formatting, queue `push_back`, associative insertion or external
  service, and `commit_reset_candidate_locked()` has no status return.

  At this release commit, exact legacy-sentinel items become resolved with
  `reset_isolation_confirmed=1` and `recovery_required=0`. Concrete-owner items
  retain `reset_isolation_confirmed=0` and `recovery_required=1`; backing
  release proves hardware isolation but does not prove that the owning
  MR/QP/queue workflow has reconciled its resource.

  In `wait_for()`, after every wait window that releases and reacquires
  `engine_lock`, revalidate the original journal lookup, engine incarnation,
  complete Function identity and ticket authority before any poll/CQ-memory
  access or timeout transition. If reset won the race, route the waiter to the
  retained old record/reset completion; never call current-runtime ticket
  authority helpers or read the newly active backing for the old ticket.

  During a later prepare/activate, precompute replacement identity snapshots;
  only successful ACTIVE establishment for the same `same_function()` identity
  with a strictly larger reset epoch moves matching proofs to READY. Query
  and `reset_observed()` both return snapshots detached from journal authority
  and retained completion nodes. Update Task 16 confirm action to require a
  unique journal-resident authoritative proof, carried/recomputed batch and
  proof digests, complete tuple equality,
  READY state and per-item owner permission. On success it only marks the
  concrete quarantined item/workflow evidence resolved, sets
  `reset_isolation_confirmed=1` and `recovery_required=0`; old runtime backing
  and the global fence were already released by reset. It must not require the
  replacement mapping to equal the released mapping, clear a fence, or invoke
  reset/I/O. Retain the detached diagnostic/proof record.

  In the same commit, amend spec sections 4.4.1, 5.2, 9 Phase 1A/1B and 10.2 to
  freeze this order: mutation-free staging -> confirmed backing release ->
  allocation-free reset commit/fence clear -> optional replacement prepare ->
  READY proof -> workflow confirmation. Remove text that assigns old backing
  or fence release to `CONFIRM_RESET_ISOLATION`; document the exact legacy
  sentinel release rule and concrete-owner `recovery_required` lifetime. Also
  freeze journal-owned retained completion evidence and the read-only,
  old-epoch-safe `reconcile_ticket()` table so FIFO delivery is not recovery
  authority.

- [ ] **Step 4: Run GREEN**

  Run:

  ```bash
  HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem \
    scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
  : "${DPU_COMMON_ROOT:?export the Task 6A approved 53 path}"
  export DPU_COMMON_ROOT
  scripts/run_vcs53.sh integration rdma_host_mem_router_test
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  ```

  Expected: PASS; timeout, late and reset remain item-specific, proof readiness
  follows real reset/rebind order, and old epoch traffic cannot affect the new
  incarnation.

- [ ] **Step 5: Commit lifecycle integration**

  ```bash
  git add src/adapter/rdma_host_mem_api.sv \
    src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv \
    src/integration/rdma_host_mem_router.sv \
    src/core/rdma_cmq_engine.sv \
    tests/mocks/rdma_mock_adapters.sv \
    tests/integration/rdma_host_mem_adapter_test.sv \
    tests/unit/rdma_host_mem_router_test.sv \
    tests/unit/rdma_cmq_engine_test.sv \
    docs/superpowers/specs/2026-09-11-rdma-engine-contract-refactoring-design.md
  git commit -m "feat(cmq): preserve journal evidence across timeout and reset" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 18: Route production port execution through per-call evidence

**Files:**

- Modify: `src/core/rdma_cmq_engine.sv`
- Modify: `src/core/rdma_cmq_engine_port_adapter.sv`
- Modify: `tests/unit/rdma_cmq_engine_test.sv`
- Modify: `tests/unit/rdma_cmq_port_test.sv`
- Modify: `tests/unit/rdma_control_plane_cmq_engine_test.sv`
- Modify: `tests/mocks/rdma_mock_control_plane.sv`
- Modify: `docs/superpowers/specs/2026-09-11-rdma-engine-contract-refactoring-design.md`

**Interfaces:**

```systemverilog
// rdma_cmq_engine
task execute_observed(
  input rdma_cmq_command_desc command,
  output rdma_cmq_execution_result result
);

// rdma_cmq_engine_port_adapter override
virtual task execute_observed(
  input rdma_cmq_command_desc command,
  output rdma_cmq_execution_result result
);
```

The production direction is fixed:

```text
adapter.execute() -> adapter.execute_observed() -> engine.execute_observed()
  -> engine.submit_observed() -> engine wait/journal transition
```

Base-port legacy subclasses continue to use the opposite one-way Task 10
fallback. No concrete class inherits both default directions.

After `submit_observed()` returns, `engine.execute_observed()` re-reads the
exact journal item under `engine_lock`; ticket presence is never its wait
predicate:

| Journal state / phase at the decision point | execute behavior |
| --- | --- |
| `PUBLISH_AMBIGUOUS` or `PUBLISH_CONFIRMED/PENDING` | enter `wait_for()` for the exact journal/ticket authority |
| `HOST_VISIBLE_NOT_PUBLISHED/NONE` | return immediately with ticket, exact recovery evidence and null completion |
| `COMPLETED/TERMINAL` | return a nonfatal detached snapshot of retained terminal completion |
| `TIMED_OUT_QUARANTINED/TIMEOUT` | return retained timeout completion without another wait |
| `LATE_COMPLETED/DIAGNOSTIC_ONLY` | return retained late-final completion without consuming diagnostic authority |
| `RESET_QUARANTINED/RESET_CANCELLED` | return retained reset completion, including after reprepare |
| `STAGED` or `PENDING_EFFECT` | return fail-closed observation error; preserve operation status/effects and do no I/O |

This table also covers the race in which poll, timeout, reconcile or reset
changes the item after submit returns but before execute acquires the lock. The
journal-owned completion—not a destructively popped FIFO row—is the source for
all already-terminal projections.

Phase 1A retains the production adapter's shared
`last_execute_no_submit_proven` compatibility seam because MR control-plane,
queue lifecycle and QP lifecycle still call legacy `execute()` followed by the
accessor. Only production legacy `execute()` may reset/write this member, using
the exact call-local observed result; production `execute_observed()` neither
reads nor writes it. Per-call isolation and concurrency assertions apply to the
observed API. The legacy shared accessor remains deprecated and is removed or
made constant false only after all three Phase 1B consumer migrations.

- [ ] **Step 1: Add RED routing, recursion and concurrency tests**

  Compare production adapter legacy and observed calls for success, local
  rejection, queue full, host-write failure, pre-MMIO fence, MMIO timeout,
  command timeout, reset cancellation and late diagnostic. Ticket, completion,
  status code/message and all available identity fields must match; observed
  effect/phase must equal journal transitions rather than a status mapping.

  Count calls through base legacy-only mock, production adapter and engine.
  Each public invocation reaches its intended downstream entry exactly once
  and never recurses between `execute()` and `execute_observed()`; explicitly
  prove the production override never calls `super.execute_observed()`. Run two
  Functions and two adjacent observed calls on one Function concurrently;
  every result keeps its own command/ticket/batch/attempt/owner/DMA/status with
  no shared-seam cross-talk.

  Seed the compatibility member, call production `execute_observed()`, and
  prove it is unchanged. Call legacy production `execute()` for exact local
  PRE rejection and for Host-visible/UNOBSERVED outcomes; only that wrapper
  resets/updates the member, and the accessor reports true only for the former.
  Keep the three current legacy consumer regressions green. Do not assert that
  concurrent legacy accessor calls are isolated—the shared ABI limitation is
  removed only by the three Phase 1B migrations.

  Force adapter validation rejection, missing binding, null engine result and
  null engine-result status. Pre-engine rejection is direct-new
  `submission_effect=attempt_effect=PRE_SUBMIT_REJECTED`; after engine
  delegation, null evidence sets both effects and completion phase to
  `UNOBSERVED` and sets `recovery_required=1`, while a non-null result with null
  status preserves both returned scalar effects and never asserts absence.
  Every branch returns non-null operation and observation statuses. Apply the
  Task 9 observation table: reliable operation failure/timeout/reset keeps
  observation OK; only malformed envelope/snapshot or observer/effect
  contradiction makes observation INVALID_STATE, without overwriting operation
  status or either effect.

  Return one real supported typed `decoded_response` from the engine. Require
  observed and legacy completion payloads to remain non-null and value-equal,
  to preserve ticket/status alias topology, and to be detached from engine/
  journal source nodes. Mutate both caller outputs and query/reconcile again;
  retained evidence is unchanged and no generic payload clone/factory path was
  called.

  Add a host-visible/unarmed result with a non-null ticket and phase `NONE`.
  `engine.execute_observed()` must return it without calling `wait_for()`. Add
  an armed `PUBLISH_AMBIGUOUS/PENDING` result and prove it does wait. Ticket
  presence alone is never the wait predicate. Race poll, timeout, late
  completion, reset and reconcile into the interval after submit returns but
  before execute takes the decision lock; exercise every row of the frozen
  table. Each terminal row returns the exact retained journal completion even
  if another consumer removed a legacy FIFO entry. STAGED/PENDING_EFFECT
  returns observation error with no wait/I/O/state mutation.

- [ ] **Step 2: Run RED**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_port_test
  ```

  Expected: production adapter still lacks the observed override/engine entry.

- [ ] **Step 3: Implement the production observed route and legacy projection**

  `engine.execute_observed()` calls `submit_observed()` once, then uses the
  locked state/phase table above. It waits only for an exact authentically
  armed PENDING journal item; unarmed Host-visible returns immediately, and an
  already terminal/timeout/late/reset item is projected from its retained
  journal completion. STAGED/PENDING_EFFECT is observation failure, not a wait.
  The wait path uses Task 17's revalidation after every unlock/relock and reads
  only the exact journal item to publish completion phase. Poll/reconcile/reset
  races cannot consume the authoritative result before execute snapshots it.
  The method never infers phase or wait eligibility from ticket/completion
  nullness or status code and never rewrites either effect during a lifecycle
  update.

  Update the original call-local result through Task 13's nonfatal complete-
  graph seam. For a non-null typed `decoded_response`, the engine/profile path
  returns a value-equal, source-detached payload and preserves internal
  ticket/status/owner alias topology. No production journal/query/recovery/
  result path uses generic UVM cloning or the fatal clone helpers.

  Adapter `execute_observed()` directly creates a fallback result/status and
  never calls `super.execute_observed()`. It
  performs only pre-engine command/binding validation itself, then transfers
  the engine's call-local result. A null result after delegation becomes
  `submission_effect=attempt_effect=UNOBSERVED`, completion phase
  `UNOBSERVED` and `recovery_required=1`; a null operation or
  observation status preserves both returned scalar effects and installs only
  the missing direct-new invalid-state status. Apply the observation table
  without overwriting a valid operation failure. For a complete returned graph,
  transfer its call-local handles; do not generic-clone a decoded payload. The
  adapter and engine retain no reference to that call-local result after return.

  Production legacy `execute()` invokes the observed override exactly once,
  transfers the already detached ticket/completion/status handles to legacy
  outputs, then alone updates `last_execute_no_submit_proven`. Set it true only
  for a call-local initial `PRE_SUBMIT_REJECTED` result with zero batch identity,
  no retained journal and `recovery_required==0`; reset it false on entry and
  for every null/malformed/Host/MMIO/UNOBSERVED result. The observed override
  never reads or writes this member. Keep
  `last_execute_definitive_no_submit()` returning the compatibility value until
  MR control-plane, queue lifecycle and QP lifecycle are each migrated in
  Phase 1B; only then may the member be deleted and accessor become constant
  false.

  Amend spec sections 5.2, 7.6, 9 Phase 1A/1B and 10.2 in the same commit so
  “production has no shared last state” applies to observed execution now, but
  legacy production `execute()` retains the deprecated compatibility seam until
  all three named consumers migrate. Freeze the terminal decision table,
  post-delegation UNOBSERVED/recovery rule and typed decoded-payload ownership.

- [ ] **Step 4: Run GREEN and unmigrated-consumer regression**

  Run:

  ```bash
  scripts/run_vcs53.sh core rdma_cmq_engine_test
  scripts/run_vcs53.sh core rdma_cmq_port_test
  scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test
  scripts/run_vcs53.sh core rdma_control_plane_test
  scripts/run_vcs53.sh core rdma_queue_lifecycle_test
  scripts/run_vcs53.sh core rdma_qp_lifecycle_test
  ```

  Expected: the real control-plane → production adapter → engine direction is
  exercised, production evidence is per-call and exact, and unmigrated legacy
  consumers retain their current exact PRE-only compatibility behavior until
  their three Phase 1B plans replace the deprecated shared accessor.

- [ ] **Step 5: Commit production routing**

  ```bash
  git add src/core/rdma_cmq_engine.sv \
    src/core/rdma_cmq_engine_port_adapter.sv \
    tests/unit/rdma_cmq_engine_test.sv \
    tests/unit/rdma_cmq_port_test.sv \
    tests/unit/rdma_control_plane_cmq_engine_test.sv \
    tests/mocks/rdma_mock_control_plane.sv \
    docs/superpowers/specs/2026-09-11-rdma-engine-contract-refactoring-design.md
  git commit -m "feat(cmq): route production execution through observed results" \
    -m "Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved."
  ```

### Task 19: Extend the CMQ gate, document evidence and run final acceptance

**Files:**

- Modify: `sim/cmq_gate.list`
- Modify: `tests/unit/test_cmq_gate_manifest.py`
- Modify: `README.md`
- Modify: `docs/rdma-0.1.34-gap-closure-verification.md`
- Create: `docs/rdma-cmq-contract-foundation-verification.md`

**Interfaces:**

The final CMQ manifest contains these exact rows in this order:

```text
rdma_cmq_engine_models_test
rdma_cmq_codec_test
rdma_cmq_completion_test
rdma_cmq_profile_test
rdma_doorbell_codec_test
rdma_doorbell_scheduler_test
rdma_queue_data_engine_post_test
rdma_cmq_engine_test
rdma_cmq_port_test
rdma_control_plane_cmq_engine_test
rdma_cmq_driver_field_mutation_test
```

This task records evidence only; it does not change wire masks, engine state
machines or external dependency approval.

- [ ] **Step 1: Add RED final-manifest assertions**

  Update the manifest test to require exact set, order and uniqueness above;
  require every row be registered in `tests/rdma_unit_test_pkg.sv` and present
  in the applicable core runner set. Add a documentation check that README
  names the driver archive gate, observed API, journal/fence semantics and
  links the verification record.

- [ ] **Step 2: Run the manifest RED test**

  Run:

  ```bash
  python3 -m unittest tests.unit.test_cmq_gate_manifest -v
  ```

  Expected: FAIL because the Phase 1A model/scheduler/port rows and final
  documentation are absent.

- [ ] **Step 3: Update documentation without broadening scope**

  Describe the implemented chain, state/effect tables, stable IDs, query and
  recovery APIs, lock order, reset proof lifecycle and the precisely bounded
  Phase 1A compatibility seam. State that production `execute_observed()` uses
  no shared evidence, while legacy production `execute()` still updates
  `last_execute_no_submit_proven` for exactly these three Phase 1B consumers:
  `src/core/rdma_control_plane.sv`,
  `src/core/rdma_queue_lifecycle_executor.sv` and
  `src/core/rdma_qp_lifecycle_executor.sv`. The accessor becomes constant false
  only after all three migrate. Record the exact archive/source/compiler/
  artifact hashes and approved host/net/dpu dependency identities from Phase 0,
  the validated Phase 1A approval plan commit/blob SHA-256/approver/timestamp/
  decisions, and the exact command/log/exit result for each acceptance run.

  Keep separate follow-up boundaries explicit: MR control-plane, queue
  lifecycle and QP lifecycle each require their own Phase 1B spec/plan; CQC
  embed-at-8, OCC and other wire fixes require Phase 1C; physical snapshot/ring/
  ledger extraction requires Phase 2; queue-data, queue-runtime,
  resource-manager, control-plane and lifecycle engines each require an
  independent spec and plan. Do not mix AEQ/CEQ/CQE/RQE/QPC mask changes or
  other engine refactors into this CMQ commit series.

- [ ] **Step 4: Run local static gates**

  Run from the clean isolated worktree:

  ```bash
  python3 -m unittest \
    tests.unit.test_verify_rdma_archive \
    tests.unit.test_check_rdma_profile_names \
    tests.unit.test_verify_rdma_cmq_oracle \
    tests.unit.test_check_rdma_field_ownership \
    tests.unit.test_external_dependency_lock \
    tests.unit.test_run_vcs53_sync \
    tests.unit.test_check_changed_sv_style \
    tests.unit.test_check_rdma_phase1a_approval \
    tests.unit.test_cmq_gate_manifest -v
  python3 tools/check_rdma_phase1a_approval.py
  make -C sim sv_style STYLE_BASE=cc07586
  git diff --check cc07586
  ```

  Expected: all Python tests pass, style hard errors are zero, soft line-width
  reports are reviewed, and no generated candidate/cache/build file is staged.

- [ ] **Step 5: Run the fixed 53 driver and CMQ gates**

  Run only through the login-shell wrapper:

  ```bash
  scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test
  scripts/run_vcs53.sh cmq_gate regression
  ```

  Expected: archive/source/oracle/ownership/capability/mutation verification
  passes; all eleven UVM logs have exactly zero warning/error/fatal reports; the
  mutation test closes exactly 666 executed rows plus 422 static rows = 1,088
  closed-evidence rows with the exact six-mode split frozen in Task 4, and
  keeps CQC_CREATE REQUEST unsupported. This fixed
  eleven-row manifest is the complete targeted CMQ execution; Step 6 adds
  compatibility consumers and the full core regression rather than redefining
  that target set.

- [ ] **Step 6: Run compatibility and full core regression**

  Run:

  ```bash
  HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem \
    scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
  : "${DPU_COMMON_ROOT:?export the Task 6A approved 53 path}"
  export DPU_COMMON_ROOT
  scripts/run_vcs53.sh integration rdma_host_mem_router_test
  scripts/run_vcs53.sh core rdma_queue_data_engine_post_test
  scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test
  scripts/run_vcs53.sh core rdma_control_plane_test
  scripts/run_vcs53.sh core rdma_queue_lifecycle_test
  scripts/run_vcs53.sh core rdma_qp_lifecycle_test
  scripts/run_vcs53.sh core regression
  ```

  Expected: every command exits zero and every log passes the existing strict
  UVM summary gate. Any VCS crash, missing summary, warning, error or fatal is a
  completion blocker; no test is removed to obtain a pass.

- [ ] **Step 7: Review changed files and commit evidence**

  Review every touched source from its file header through all changed methods
  for truthful Chinese three-part comments, sparse stage separation, ownership,
  reset/error paths and lock order. Verify `git status --short` contains no
  external candidate, cache or unrelated formatting. Then commit only the
  documentation and manifest updates from this task:

  ```bash
  git add sim/cmq_gate.list tests/unit/test_cmq_gate_manifest.py README.md \
    docs/rdma-0.1.34-gap-closure-verification.md \
    docs/rdma-cmq-contract-foundation-verification.md
  git commit -m "docs: record CMQ contract foundation verification"
  ```

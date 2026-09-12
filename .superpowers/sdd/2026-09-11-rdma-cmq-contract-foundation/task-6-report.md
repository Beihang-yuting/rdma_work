# Task 6 report

实现提交：`7e1c237`（后续修订包含锁定摘要纠正）。

完成内容：

- 新增严格 external dependency TSV parser、递归 include 闭包校验及原子 `0600` capture。
- 锁定 `host_mem`、`net_packet` 的批准身份，保留 `dpu_common`/`pcie_work` 的 `UNAPPROVED` seeds。
- Make preflight 全部路由 checker；PCIe preflight 同时校验 host_mem 与 pcie_work。
- `run_vcs53.sh` 增加 guarded `main` 和精确 rsync exclusion 数组。
- 新增 parser/capture 与同步 helper 单元测试，更新 README 和验证文档。

验证：

```text
python3 -m unittest tests.unit.test_external_dependency_lock tests.unit.test_run_vcs53_sync -v  PASS
python3 -m py_compile tools/check_external_dependency_lock.py              PASS
bash -n scripts/run_vcs53.sh                                               PASS
git diff --check                                                             PASS
```

Ruling：brief 给出的 `dhcp_header.sv` 摘要为 66 位且不是 SHA-256；在
`6766c4f042484814548481065328ffbcffab590f` checkout 上复核得到真实 64 位摘要
`703e4d13b95a032c9fe7a49b6fdc363a3d432695e8b2ec1912ca7a6666ccc7c7`，因此锁行
按外部 checkout 证据修订，parser 保持严格 64-hex 校验。

风险：`dpu_common` 与 `pcie_work` 仍故意 fail closed；Task 6A 需要项目所有者
针对明确 checkout 完成批准后才能运行 integration/pcie 仿真。

## Fix round 1

根据 review-v2 修复了额外 TSV 字段、include 符号链接/目录链接、shadow 与循环
include、dangling candidate、APPROVED capture、PCIe host-mem manager 可读性清单
以及验证文档当前 active lock 说明；capture 现在同步候选父目录并保持原子发布。

验证：

```text
python3 -m unittest tests.unit.test_external_dependency_lock tests.unit.test_run_vcs53_sync -v  PASS (7 tests)
python3 -m unittest discover -s tests/unit -p 'test_*.py'                           PASS (235 tests)
python3 -m py_compile tools/check_external_dependency_lock.py                      PASS
bash -n scripts/run_vcs53.sh                                                       PASS
git diff --check                                                                   PASS
```

## Fix round 2

快照校验不再要求 approved 行的 `git_commit` 为 `-`；approved schema 继续保留
40-hex provenance，非 Git 模式仅依据精确闭包、逐文件摘要和 canonical tree digest。
新增 approved plain-snapshot 匹配与文件漂移回归。

验证：

```text
python3 -m unittest tests.unit.test_external_dependency_lock tests.unit.test_run_vcs53_sync -v  PASS (8 tests)
python3 -m unittest discover -s tests/unit -p 'test_*.py'                           PASS (236 tests)
python3 -m py_compile tools/check_external_dependency_lock.py                      PASS
bash -n scripts/run_vcs53.sh                                                       PASS
git diff --check                                                                   PASS
```

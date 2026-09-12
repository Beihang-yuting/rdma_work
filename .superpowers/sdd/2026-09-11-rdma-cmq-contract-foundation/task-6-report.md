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

# 目录：sim/Makefile，仿真构建层入口。
# 职责：定义 core、env、pcie_work 与 rxe 的编译、预检和 UVM 运行流程。所有 suite 编译同一份 RDMA 源码
#   （filelists/rdma.f + tests.f，含外部 host_mem 与 net_packet）；pcie_work、rxe 另加各自的 filelist。
# 依赖与所有权：依赖 VCS、仓库 filelist 及外部只读源码树；本文件仅管理 build 输出目录，不拥有外部依赖生命周期。

BUILD ?= build/core
# 外部组件（dpu_common、host_mem、net_packet、pcie_work）由使用者经 *_ROOT 指定，直接引用、不锁版本。
override RDMA_ARCHIVE := /home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz
TEST ?= rdma_smoke_test
VCS ?= vcs
# Work around a VCS W-2024.09-SP1 class-codegen miscompile; not an RTL requirement.
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -debug_access+class
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
CORE_LOGICAL_RUNNER := ../scripts/run_core_logical_test.sh
# dpu_common（Host/PF/VF、BDF、BAR 的逻辑设备配置）：所有编译 tests/rdma_unit_test_pkg 的 suite 都需要；
# 由 rdma_dpu_adapter_pkg 投影给驱动/设备模型。
DPU_COMMON_SRC = +incdir+$(DPU_COMMON_ROOT)/src $(DPU_COMMON_ROOT)/src/dpu_resource_pkg.sv

# 功能：在 build 目录 $(1) 生成外部组件路径展开后的 filelist（VCS 不替换 filelist 中的 Make 变量），并
#   编译 tb_top 为 $(1)/simv；$(2) 为附加的 suite filelist（rxe、pcie_work）与选项。
# 输入输出及副作用：写 $(1) 下的 *.f 与 simv。
# 失败边界：编译失败返回非零。
define RDMA_COMPILE
	mkdir -p $(1); \
	for list in rdma tests pcie_work rxe; do \
		sed -e 's|@HOST_MEM_ROOT@|$(HOST_MEM_ROOT)|g' -e 's|@NET_PACKET_ROOT@|$(NET_PACKET_ROOT)|g' \
		    -e 's|@PCIE_WORK_ROOT@|$(PCIE_WORK_ROOT)|g' filelists/$$list.f > $(1)/$$list.f; \
	done; \
	$(VCS) $(VCS_FLAGS) $(DPU_COMMON_SRC) -f $(1)/rdma.f $(2) -f $(1)/tests.f -top tb_top -o $(1)/simv
endef

# 功能：把一个 core UVM test 转交给统一 runner 执行并检查 summary。
# 输入输出及副作用：参数 1 是 UVM test，参数 2 是含 simv 的 build 目录；写独立 log。
# 失败边界：controller 对参数、manifest、simulator 或 summary 任一失败返回
#   非零；Make 不保留第二份 fan-out 逻辑。
define RUN_CORE_LOGICAL_TEST
	"$(CORE_LOGICAL_RUNNER)" \
		"$(strip $(1))" \
		"$(strip $(2))" \
		"../scripts/check_uvm_summary.sh"
endef

.PHONY: dpu_common_preflight core cmq_gate sv_style host_mem_preflight rdma_defs env net_packet_preflight pcie_work pcie_work_preflight rxe regression

dpu_common_preflight:
	@if [[ -z "$(DPU_COMMON_ROOT)" || ! -r "$(DPU_COMMON_ROOT)/src/dpu_resource_pkg.sv" ]]; then \
		echo "DPU_COMMON_ROOT must point at a dpu_common checkout" >&2; exit 2; fi

# 变更 SV 的注释/单语句门禁与 Git 空白检查共用明确的基线提交，避免隐式读取工作树历史。
sv_style:
	python3 ../tools/check_changed_sv_style.py --base "$${STYLE_BASE:?STYLE_BASE is required}"
	git diff --check "$${STYLE_BASE}"

# 通过统一 run_vcs53.sh 入口逐项执行回归清单；每行必须是 suite/test/tags 三字段。
regression:
	set -euo pipefail; \
	manifest=regression.list; \
	[[ -r "$$manifest" ]] || { echo "regression manifest is missing: $$manifest" >&2; exit 2; }; \
	pass=0; fail=0; total=0; \
	while read -r suite test tags extra; do \
		[[ -z "$$suite" || "$${suite:0:1}" == "#" ]] && continue; \
		if [[ -z "$$suite" || -z "$$test" || -z "$$tags" || -n "$$extra" || \
		      "$$suite" == axis_vip || "$$test" == *axis* ]]; then \
			echo "invalid regression manifest row" >&2; exit 2; \
		fi; \
		if [[ ! "$$suite" =~ ^(core|env|pcie_work|rdma_defs)$$ || \
		      ! "$$test" =~ ^[A-Za-z_][A-Za-z0-9_]*$$ ]]; then \
			echo "invalid suite/test in regression manifest: $$suite $$test" >&2; exit 2; \
		fi; \
		total=$$((total + 1)); \
		echo "REGRESSION test=$$test suite=$$suite seed=$${SEED:-default} tags=$$tags"; \
		if ../scripts/run_vcs53.sh "$$suite" "$$test"; then \
			pass=$$((pass + 1)); echo "REGRESSION PASS test=$$test"; \
		else \
			fail=$$((fail + 1)); echo "REGRESSION FAIL test=$$test" >&2; \
		fi; \
	done < "$$manifest"; \
	if (( total == 0 )); then echo "regression manifest is empty" >&2; exit 2; fi; \
	echo "REGRESSION SUMMARY total=$$total pass=$$pass fail=$$fail"; \
	(( fail == 0 ))

core: dpu_common_preflight host_mem_preflight net_packet_preflight
	set -euo pipefail; \
	$(call RDMA_COMPILE,$(BUILD),); \
	if [[ "$(TEST)" == regression ]]; then \
		mapfile -t suite_tests < <(sed -n '/^readonly CORE_TESTS=(/,/^)/p' ../scripts/run_queue_lifecycle_regression53.sh | sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*$$/\1/p'); \
		if (( $${#suite_tests[@]} == 0 )); then echo "core regression manifest is empty" >&2; exit 2; fi; \
		for test_name in "$${suite_tests[@]}"; do \
			$(call RUN_CORE_LOGICAL_TEST,$$test_name,$(BUILD)); \
		done; \
	else \
		$(call RUN_CORE_LOGICAL_TEST,$(TEST),$(BUILD)); \
	fi

cmq_gate:
	set -euo pipefail; \
	manifest=cmq_gate.list; \
	[[ -r "$$manifest" ]] || { echo "CMQ gate manifest is missing" >&2; exit 2; }; \
	mapfile -t cmq_tests < <(sed -e 's/[[:space:]]*#.*$$//' -e '/^[[:space:]]*$$/d' "$$manifest"); \
	(( $${#cmq_tests[@]} == 5 )) || { echo "CMQ gate requires exactly five tests" >&2; exit 2; }; \
	declare -A seen=(); \
	for test_name in "$${cmq_tests[@]}"; do \
		[[ "$$test_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$$ ]] || { echo "invalid CMQ test name" >&2; exit 2; }; \
		[[ -z "$${seen[$$test_name]+x}" ]] || { echo "duplicate CMQ test" >&2; exit 2; }; \
		seen[$$test_name]=1; \
	done; \
	$(MAKE) BUILD=$(BUILD) TEST=rdma_smoke_test core >/dev/null; \
	for test_name in "$${cmq_tests[@]}"; do \
		$(call RUN_CORE_LOGICAL_TEST,$$test_name,$(BUILD)); \
	done

rdma_defs:
	@if [[ "$(TEST)" != "rdma_cmq_driver_contract_test" ]]; then \
		echo "rdma_defs requires TEST=rdma_cmq_driver_contract_test" >&2; \
		exit 2; \
	fi
	@cd .. && python3 -m unittest \
		tests.unit.test_verify_rdma_archive \
		tests.unit.test_check_rdma_profile_names \
		tests.unit.test_verify_rdma_cmq_oracle -v
	@set -euo pipefail; ref_dir=$$(mktemp -d /tmp/rdma_profile_ref.XXXXXX); \
	if [[ ! "$$ref_dir" =~ ^/tmp/rdma_profile_ref\.[A-Za-z0-9]{6}$$ ]]; then \
		echo "Refusing unexpected RDMA reference directory: $$ref_dir" >&2; \
		exit 2; \
	fi; \
	cleanup() { \
		command_status=$$?; \
		cleanup_status=0; \
		trap - EXIT; \
		if [[ "$$ref_dir" =~ ^/tmp/rdma_profile_ref\.[A-Za-z0-9]{6}$$ && -d "$$ref_dir" ]]; then \
			if ! rm -rf -- "$$ref_dir"; then \
				echo "Failed to remove RDMA reference directory: $$ref_dir" >&2; \
				cleanup_status=1; \
			fi; \
		else \
			echo "Refusing to remove unexpected RDMA reference directory: $$ref_dir" >&2; \
			cleanup_status=1; \
		fi; \
		if [[ "$$command_status" != 0 ]]; then \
			exit $$command_status; \
		fi; \
		exit $$cleanup_status; \
	}; \
	trap cleanup EXIT; \
	kernel_root=$$(python3 ../tools/verify_rdma_archive.py \
		--archive "$(RDMA_ARCHIVE)" \
		--lock ../hw/rdma/archive_lock.env \
		--source-manifest ../hw/rdma/source_manifest.txt \
		--extract-dir "$$ref_dir" \
		--print-kernel-root); \
	python3 ../tools/check_rdma_profile_names.py \
		--kernel-root "$$kernel_root" \
		--archive-lock ../hw/rdma/archive_lock.env \
		--source-manifest ../hw/rdma/source_manifest.txt; \
	python3 ../tools/verify_rdma_cmq_oracle.py \
		--kernel-root "$$kernel_root" \
		--archive-lock ../hw/rdma/archive_lock.env \
		--source-manifest ../hw/rdma/source_manifest.txt \
		--source-anchors ../hw/rdma/c_oracle/cmq_oracle_source_anchors.tsv \
		--cases ../hw/rdma/c_oracle/cmq_oracle_cases.tsv \
		--oracle-source ../hw/rdma/c_oracle/rdma_cmq_oracle.c \
		--artifact-root ../hw/rdma/c_oracle/cases \
		--cc /usr/bin/gcc; \
	python3 ../tools/gen_cmq_request_fields.py --driver-root "$$kernel_root" --check \
		--tsv ../hw/rdma/cmq_request_fields.tsv \
		--svh ../src/codec/rdma/rdma_cmq_request_fields.svh; \
	python3 ../tools/cmq_request_oracle.py --driver-root "$$kernel_root" --check \
		--golden ../hw/rdma/golden_vectors/cmq_requests.hex --cc /usr/bin/gcc; \
	python3 ../tools/cmq_dedicated_oracle.py --driver-root "$$kernel_root" --check \
		--golden ../hw/rdma/golden_vectors/cmq_requests_dedicated.hex \
		--context ../hw/rdma/golden_vectors/context.hex --cc /usr/bin/gcc; \
	python3 ../tools/cmq_response_oracle.py --driver-root "$$kernel_root" --check \
		--golden ../hw/rdma/golden_vectors/cmq_responses.hex --cc /usr/bin/gcc; \
	python3 ../tools/check_cmq_capabilities.py --driver-root "$$kernel_root" --check --repo ..

host_mem_preflight:
	@if [[ -z "$(HOST_MEM_ROOT)" || ! -r "$(HOST_MEM_ROOT)/src/host_mem_pkg.sv" || \
	      ! -r "$(HOST_MEM_ROOT)/src/host_mem_manager.sv" ]]; then \
		echo "HOST_MEM_ROOT must point at a host_mem checkout" >&2; exit 2; fi

net_packet_preflight:
	@if [[ -z "$(NET_PACKET_ROOT)" || ! -r "$(NET_PACKET_ROOT)/src/core/packet.sv" ]]; then \
		echo "NET_PACKET_ROOT must point at a net_packet checkout" >&2; exit 2; fi

# env suite：UVM env 的全部场景。
ENV_TESTS := rdma_env_basic_test rdma_env_netpkt_test rdma_env_high_traffic_test \
	rdma_env_errors_test rdma_env_reliability_test rdma_env_srq_test rdma_env_lifecycle_test \
	rdma_env_multifunc_test rdma_env_random_test

env: dpu_common_preflight host_mem_preflight net_packet_preflight
	set -euo pipefail; \
	$(call RDMA_COMPILE,build/env,); \
	tests="$(TEST)"; \
	if [[ "$$tests" == regression ]]; then tests="$(ENV_TESTS)"; fi; \
	rm -rf build/env/simv.vdb/snps/coverage/db/testdata build/env/cov; \
	for test_name in $$tests; do \
		build/env/simv +UVM_TESTNAME=$$test_name -cm_name $$test_name | tee build/env/$$test_name.log; \
		../scripts/check_uvm_summary.sh build/env/$$test_name.log; \
	done; \
	: "各测试的功能覆盖率经 urg 合并，打印合并后的总分（RDMA_COV merged）"; \
	urg -dir build/env/simv.vdb -format text -report build/env/cov > build/env/urg.log 2>&1; \
	echo "RDMA_COV merged=$$(awk '/Total Groups Coverage Summary/ {getline; getline; print $$1; exit}' build/env/cov/groups.txt)"

pcie_work_preflight:
	@if [[ -z "$(PCIE_WORK_ROOT)" || ! -r "$(PCIE_WORK_ROOT)/pcie_tl_vip/src/pcie_tl_pkg.sv" ]]; then \
		echo "PCIE_WORK_ROOT must point at a pcie_work checkout" >&2; exit 2; fi

pcie_work: dpu_common_preflight host_mem_preflight net_packet_preflight pcie_work_preflight
	set -euo pipefail; \
	$(call RDMA_COMPILE,build/pcie_work,+define+RDMA_PCIE_WORK_TEST -f build/pcie_work/pcie_work.f); \
	test_name=$(TEST); \
	if [[ "$$test_name" == regression ]]; then test_name=rdma_env_pcie_test; fi; \
	build/pcie_work/simv +UVM_TESTNAME=$$test_name | tee build/pcie_work/$$test_name.log; \
	../scripts/check_uvm_summary.sh build/pcie_work/$$test_name.log

# Soft-RoCE 互打：需先在本机运行 tools/rxe/rxe_tap_setup.sh up（TAP 网卡 + rxe 设备，需 sudo）。
RXE_TAP ?= rtap0

rxe: dpu_common_preflight host_mem_preflight net_packet_preflight
	set -euo pipefail; \
	if [[ ! -e /sys/class/net/$(RXE_TAP) ]]; then \
		echo "TAP $(RXE_TAP) is missing: run tools/rxe/rxe_tap_setup.sh up" >&2; exit 2; fi; \
	mkdir -p build/rxe; \
	gcc -O2 -Wall -o build/rxe/rxe_peer ../tools/rxe/rxe_peer.c -libverbs; \
	$(call RDMA_COMPILE,build/rxe,+define+RDMA_RXE_TEST -f build/rxe/rxe.f ../src/adapters/rxe/rdma_rxe_dpi.c); \
	tests=$(TEST); \
	if [[ "$$tests" == regression ]]; then tests="rdma_rxe_test rdma_rxe_fault_test rdma_env_rxe_test"; fi; \
	for test_name in $$tests; do \
		build/rxe/simv +UVM_TESTNAME=$$test_name +RXE_TAP=$(RXE_TAP) +RXE_PEER=$$(pwd)/build/rxe/rxe_peer | tee build/rxe/$$test_name.log; \
		../scripts/check_uvm_summary.sh build/rxe/$$test_name.log; \
	done

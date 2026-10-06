# 目录：sim/Makefile，仿真构建层入口。
# 职责：定义 core、host_mem、pcie_work、net_packet 与 e2e 的编译、预检和 UVM 运行流程。
# 依赖与所有权：依赖 VCS、仓库 filelist 及外部只读源码树；本文件仅管理 build 输出目录，不拥有外部依赖生命周期。

BUILD ?= build/core
HOST_MEM_BUILD ?= build/host_mem
E2E_BUILD ?= build/e2e
# 53 机上的 /home/ubuntu/workspace/host_mem 是真实 pinned backing 的只读
# checkout；固定 commit/hash 使 E2E 可复现，同时不把外部源码复制进本仓库。
override RDMA_ARCHIVE := /home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz
# 6766c4f is the net_packet master snapshot that contains packet.sv and the
# RoCEv2/iWARP protocol headers consumed by this adapter.
TEST ?= rdma_smoke_test
VCS ?= vcs
# Work around a VCS W-2024.09-SP1 class-codegen miscompile; not an RTL requirement.
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -debug_access+class
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
CORE_LOGICAL_RUNNER := ../scripts/run_core_logical_test.sh

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

.PHONY: core cmq_gate sv_style host_mem_preflight host_mem rdma_defs net_packet net_packet_preflight pcie_work pcie_work_preflight e2e regression

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
		if [[ ! "$$suite" =~ ^(core|host_mem|pcie_work|net_packet|e2e|rdma_defs)$$ || \
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

core:
	set -euo pipefail; \
	mkdir -p $(BUILD); \
	$(VCS) $(VCS_FLAGS) -f filelists/core.f -top tb_top -o $(BUILD)/simv; \
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
	(( $${#cmq_tests[@]} == 12 )) || { echo "CMQ gate requires exactly twelve tests" >&2; exit 2; }; \
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
		tests.unit.test_verify_rdma_cmq_oracle \
		tests.unit.test_check_rdma_field_ownership -v
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
	python3 ../tools/check_rdma_field_ownership.py \
		--kernel-root "$$kernel_root" \
		--archive-lock ../hw/rdma/archive_lock.env \
		--source-manifest ../hw/rdma/source_manifest.txt \
		--ownership ../hw/rdma/field_ownership.tsv \
		--exclusions ../hw/rdma/field_exclusions.tsv \
		--oracle-root ../hw/rdma/c_oracle/cases \
		--mutation-manifest ../hw/rdma/cmq_field_mutation.tsv \
		--sv-root ../src; \
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
	@if [[ -z "$(HOST_MEM_ROOT)" ]]; then \
		echo "HOST_MEM_ROOT is required for the host_mem target" >&2; \
		exit 2; \
	fi
	@for dependency in \
		"$(HOST_MEM_ROOT)/src/host_mem_pkg.sv" \
		"$(HOST_MEM_ROOT)/src/host_mem_manager.sv"; do \
		if [[ ! -r "$$dependency" ]]; then \
			echo "Required host_mem dependency is not readable: $$dependency" >&2; \
			exit 2; \
		fi; \
	done
	@python3 ../tools/check_external_dependency_lock.py verify --lock ../hw/rdma/external_dependencies.tsv --dependency host_mem --root "$(HOST_MEM_ROOT)"

host_mem: host_mem_preflight
	set -euo pipefail; \
	mkdir -p $(HOST_MEM_BUILD); \
	$(VCS) $(VCS_FLAGS) +define+RDMA_HOST_MEM_TEST \
		+incdir+$(HOST_MEM_ROOT)/src \
		$(HOST_MEM_ROOT)/src/host_mem_pkg.sv \
		-f filelists/host_mem.f -top tb_top -o $(HOST_MEM_BUILD)/simv; \
	if [[ "$(TEST)" == regression ]]; then \
		mapfile -t suite_tests < <(sed -n '/^readonly host_mem_tests=(/,/^)/p' ../scripts/run_host_mem_regression53.sh | sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*$$/\1/p'); \
		if (( $${#suite_tests[@]} == 0 )); then echo "host_mem regression manifest is empty" >&2; exit 2; fi; \
		for test_name in "$${suite_tests[@]}"; do \
			$(HOST_MEM_BUILD)/simv +UVM_TESTNAME=$$test_name | tee $(HOST_MEM_BUILD)/$$test_name.log; \
			../scripts/check_uvm_summary.sh $(HOST_MEM_BUILD)/$$test_name.log; \
		done; \
	else \
		$(HOST_MEM_BUILD)/simv +UVM_TESTNAME=$(TEST) | tee $(HOST_MEM_BUILD)/$(TEST).log; \
		../scripts/check_uvm_summary.sh $(HOST_MEM_BUILD)/$(TEST).log; \
	fi

net_packet_preflight:
	@if [[ -z "$(NET_PACKET_ROOT)" ]]; then echo "NET_PACKET_ROOT is required for net_packet" >&2; exit 2; fi
	@preflight_failed=0; \
	for dependency in \
		"$(NET_PACKET_ROOT)/src/core/packet.sv" \
		"../src/adapters/net_packet/rdma_net_packet_adapter_pkg.sv" \
		"../src/adapters/net_packet/rdma_net_packet_bridge.sv" \
		"../tests/integration/rdma_net_packet_adapter_test.sv"; do \
		if [[ ! -r "$$dependency" ]]; then echo "Required net_packet dependency is not readable: $$dependency" >&2; preflight_failed=1; fi; \
	done; \
	if [[ "$$preflight_failed" != 0 ]]; then exit 2; fi
	@python3 ../tools/check_external_dependency_lock.py verify --lock ../hw/rdma/external_dependencies.tsv --dependency net_packet --root "$(NET_PACKET_ROOT)"

net_packet: net_packet_preflight
	set -euo pipefail; \
	mkdir -p build/net_packet; \
	: "VCS 不会替换 filelist 中的 GNU make 变量，先生成只读依赖路径展开后的临时 filelist"; \
	sed 's|\$$(NET_PACKET_ROOT)|$(NET_PACKET_ROOT)|g' filelists/net_packet.f > build/net_packet/net_packet.expanded.f; \
	$(VCS) $(VCS_FLAGS) +define+RDMA_NET_PACKET +incdir+$(NET_PACKET_ROOT)/src +incdir+$(NET_PACKET_ROOT)/src/common +incdir+$(NET_PACKET_ROOT)/src/protocols -f build/net_packet/net_packet.expanded.f -top tb_top -o build/net_packet/simv; \
	test_name=$(TEST); \
	if [[ "$$test_name" == regression ]]; then test_name=rdma_net_packet_adapter_test; fi; \
	build/net_packet/simv +UVM_TESTNAME=$$test_name | tee build/net_packet/$$test_name.log; \
	../scripts/check_uvm_summary.sh build/net_packet/$$test_name.log

pcie_work_preflight:
	@if [[ -z "$(PCIE_WORK_ROOT)" ]]; then echo "PCIE_WORK_ROOT is required for pcie_work" >&2; exit 2; fi
	@if [[ -z "$(HOST_MEM_ROOT)" ]]; then echo "HOST_MEM_ROOT is required for pcie_work" >&2; exit 2; fi
	@for dependency in \
		"$(PCIE_WORK_ROOT)/pcie_tl_vip/src/pcie_tl_if.sv" \
		"$(PCIE_WORK_ROOT)/pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv" \
		"$(PCIE_WORK_ROOT)/pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv" \
		"$(PCIE_WORK_ROOT)/pcie_tl_vip/src/topology/pcie_topology_pkg.sv" \
		"$(PCIE_WORK_ROOT)/pcie_tl_vip/src/pcie_tl_pkg.sv" \
		"$(HOST_MEM_ROOT)/src/host_mem_pkg.sv" \
		"$(HOST_MEM_ROOT)/src/host_mem_manager.sv"; do \
		if [[ ! -r "$$dependency" ]]; then echo "Required pcie_work dependency is not readable: $$dependency" >&2; exit 2; fi; \
		done
	@python3 ../tools/check_external_dependency_lock.py verify --lock ../hw/rdma/external_dependencies.tsv --dependency host_mem --root "$(HOST_MEM_ROOT)"
	@python3 ../tools/check_external_dependency_lock.py verify --lock ../hw/rdma/external_dependencies.tsv --dependency pcie_work --root "$(PCIE_WORK_ROOT)"

pcie_work: pcie_work_preflight
	set -euo pipefail; \
	mkdir -p build/pcie_work; \
	: "VCS 不会替换 filelist 中的 GNU make 变量，先生成只读依赖路径展开后的临时 filelist"; \
	sed -e 's|@HOST_MEM_ROOT@|$(HOST_MEM_ROOT)|g' \
	    -e 's|@PCIE_WORK_ROOT@|$(PCIE_WORK_ROOT)|g' \
	    filelists/pcie_work.f > build/pcie_work/pcie_work.expanded.f; \
	$(VCS) $(VCS_FLAGS) +define+RDMA_PCIE_WORK_TEST \
		-f build/pcie_work/pcie_work.expanded.f -top tb_top -o build/pcie_work/simv; \
	test_name=$(TEST); \
	if [[ "$$test_name" == regression ]]; then test_name=rdma_pcie_work_adapter_test; fi; \
	build/pcie_work/simv +UVM_TESTNAME=$$test_name | tee build/pcie_work/$$test_name.log; \
	../scripts/check_uvm_summary.sh build/pcie_work/$$test_name.log

e2e: host_mem_preflight net_packet_preflight
	set -euo pipefail; \
	mkdir -p $(E2E_BUILD); \
	: "VCS 不会替换 filelist 中的 Make 变量，先生成只读依赖路径展开后的临时 filelist"; \
	sed -e 's|@HOST_MEM_ROOT@|$(HOST_MEM_ROOT)|g' \
	    -e 's|@NET_PACKET_ROOT@|$(NET_PACKET_ROOT)|g' \
	    filelists/e2e.f > $(E2E_BUILD)/e2e.expanded.f; \
	$(VCS) $(VCS_FLAGS) +define+RDMA_HOST_MEM_TEST +define+RDMA_NET_PACKET \
		$(HOST_MEM_ROOT)/src/host_mem_pkg.sv \
		-f $(E2E_BUILD)/e2e.expanded.f -top tb_top -o $(E2E_BUILD)/simv; \
	test_name=$(TEST); \
	if [[ "$$test_name" == regression ]]; then test_name=rdma_tb_e2e_test; fi; \
	$(E2E_BUILD)/simv +UVM_TESTNAME=$$test_name | tee $(E2E_BUILD)/$$test_name.log; \
	../scripts/check_uvm_summary.sh $(E2E_BUILD)/$$test_name.log

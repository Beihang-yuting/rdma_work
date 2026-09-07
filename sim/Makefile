# 目录：sim/Makefile，仿真构建层入口。
# 职责：定义 core、integration、host_mem 与可选 net_packet 的编译、预检和 UVM 运行流程。
# 依赖与所有权：依赖 VCS、仓库 filelist 及外部只读源码树；本文件仅管理 build 输出目录，不拥有外部依赖生命周期。

BUILD ?= build/core
HOST_MEM_BUILD ?= build/host_mem
E2E_BUILD ?= build/e2e
# 53 机上的 host_mem_latest 是驱动更新后的只读 checkout；固定 commit/hash
# 使 E2E 使用的真实 host-memory 实现可复现，同时不把外部源码复制进本仓库。
override HOST_MEM_PINNED_COMMIT := 365b7553fc7dac6b4ad55886a8e4869153607c28
override HOST_MEM_PKG_SHA256 := e874491da16334b12d9299355a3148275309a0c5a2c3303cda2fc7c3382ed74f
override HOST_MEM_MANAGER_SHA256 := 6b5eb9bbd94d410b1382a665ddb60347132558fc7882cbed1115f69fa0c1d410
override RDMA_ARCHIVE := /home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz
override RDMA_ARCHIVE_PREFIX := dpu_kernel_rdma-version_0.1.34
# 6766c4f is the net_packet master snapshot that contains packet.sv and the
# RoCEv2/iWARP protocol headers consumed by this adapter.
override NET_PACKET_PINNED_COMMIT := 6766c4f042484814548481065328ffbcffab590f
TEST ?= rdma_smoke_test
VCS ?= vcs
# Work around a VCS W-2024.09-SP1 class-codegen miscompile; not an RTL requirement.
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -debug_access+class
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: core host_mem_preflight host_mem rdma_defs integration net_packet net_packet_preflight pcie_work pcie_work_preflight e2e regression

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
		if [[ ! "$$suite" =~ ^(core|integration|host_mem|pcie_work|net_packet|e2e|rdma_defs)$$ || \
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
			$(BUILD)/simv +UVM_TESTNAME=$$test_name | tee $(BUILD)/$$test_name.log; \
			../scripts/check_uvm_summary.sh $(BUILD)/$$test_name.log; \
		done; \
	else \
		$(BUILD)/simv +UVM_TESTNAME=$(TEST) | tee $(BUILD)/$(TEST).log; \
		../scripts/check_uvm_summary.sh $(BUILD)/$(TEST).log; \
	fi

rdma_defs:
	@ref_dir=$$(mktemp -d /tmp/rdma_profile_ref.XXXXXX); \
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
	case "$(RDMA_ARCHIVE)" in \
		*.tar.gz|*.tar*.gz|*.tgz) tar -xzf "$(RDMA_ARCHIVE)" -C "$$ref_dir" "$(RDMA_ARCHIVE_PREFIX)" ;; \
		*.zip) unzip -q "$(RDMA_ARCHIVE)" "$(RDMA_ARCHIVE_PREFIX)/*" -d "$$ref_dir" ;; \
		*) echo "Unsupported RDMA archive format: $(RDMA_ARCHIVE)" >&2; exit 2 ;; \
	esac; \
	python3 ../tools/check_rdma_profile_names.py \
		--kernel-root "$$ref_dir/$(RDMA_ARCHIVE_PREFIX)"

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
	@preflight_failed=0; \
	git_metadata_available=0; \
	if git -C "$(HOST_MEM_ROOT)" rev-parse --is-inside-work-tree \
		>/dev/null 2>&1; then \
		git_metadata_available=1; \
		actual_head=$$(git -C "$(HOST_MEM_ROOT)" rev-parse HEAD); \
		if [[ "$$actual_head" != "$(HOST_MEM_PINNED_COMMIT)" ]]; then \
			echo "host_mem preflight failed: HEAD $$actual_head does not match pinned commit $(HOST_MEM_PINNED_COMMIT)" >&2; \
			preflight_failed=1; \
		else \
			if ! git -C "$(HOST_MEM_ROOT)" diff --cached \
				--no-ext-diff --quiet "$(HOST_MEM_PINNED_COMMIT)" -- \
				src/host_mem_pkg.sv src/host_mem_manager.sv; then \
				echo "host_mem preflight failed: pinned source index differs from commit $(HOST_MEM_PINNED_COMMIT) (staged change)" >&2; \
				preflight_failed=1; \
			fi; \
			if ! git -C "$(HOST_MEM_ROOT)" diff --no-ext-diff --quiet -- \
				src/host_mem_pkg.sv src/host_mem_manager.sv; then \
				echo "host_mem preflight failed: pinned source worktree differs from the index (unstaged change)" >&2; \
				preflight_failed=1; \
			fi; \
		fi; \
	fi; \
	pkg_hash=$$(sha256sum "$(HOST_MEM_ROOT)/src/host_mem_pkg.sv"); \
	pkg_hash=$${pkg_hash%% *}; \
	manager_hash=$$(sha256sum "$(HOST_MEM_ROOT)/src/host_mem_manager.sv"); \
	manager_hash=$${manager_hash%% *}; \
	if [[ "$$pkg_hash" != "$(HOST_MEM_PKG_SHA256)" ]]; then \
		echo "host_mem preflight failed: host_mem_pkg.sv SHA-256 $$pkg_hash does not match pinned $(HOST_MEM_PKG_SHA256)" >&2; \
		preflight_failed=1; \
	fi; \
	if [[ "$$manager_hash" != "$(HOST_MEM_MANAGER_SHA256)" ]]; then \
		echo "host_mem preflight failed: host_mem_manager.sv SHA-256 $$manager_hash does not match pinned $(HOST_MEM_MANAGER_SHA256)" >&2; \
		preflight_failed=1; \
	fi; \
	if [[ "$$preflight_failed" != 0 ]]; then \
		exit 1; \
	fi; \
	if [[ "$$git_metadata_available" == 1 ]]; then \
		echo "host_mem preflight passed: pinned git checkout and source hashes match"; \
	else \
		echo "host_mem preflight passed: git metadata unavailable; pinned source hashes match"; \
	fi

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

integration:
	@if [[ -z "$(DPU_COMMON_ROOT)" ]]; then echo "DPU_COMMON_ROOT is required for integration" >&2; exit 2; fi
	set -euo pipefail; \
	mkdir -p build/integration; \
	$(VCS) $(VCS_FLAGS) +define+RDMA_DPU_INTEGRATION +incdir+$(DPU_COMMON_ROOT)/src $(DPU_COMMON_ROOT)/src/dpu_resource_pkg.sv -f filelists/integration.f -top tb_top -o build/integration/simv; \
	if [[ "$(TEST)" == regression ]]; then \
		mapfile -t suite_tests < <(sed -n '/^readonly INTEGRATION_TESTS=(/,/^)/p' ../scripts/run_queue_lifecycle_regression53.sh | sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*$$/\1/p'); \
		if (( $${#suite_tests[@]} == 0 )); then echo "integration regression manifest is empty" >&2; exit 2; fi; \
		for test_name in "$${suite_tests[@]}"; do \
			build/integration/simv +UVM_TESTNAME=$$test_name | tee build/integration/$$test_name.log; \
			../scripts/check_uvm_summary.sh build/integration/$$test_name.log; \
		done; \
	else \
		build/integration/simv +UVM_TESTNAME=$(TEST) | tee build/integration/$(TEST).log; \
		../scripts/check_uvm_summary.sh build/integration/$(TEST).log; \
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
	@if git -C "$(NET_PACKET_ROOT)" rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
		actual_head=$$(git -C "$(NET_PACKET_ROOT)" rev-parse HEAD); \
		if [[ "$$actual_head" != "$(NET_PACKET_PINNED_COMMIT)" ]]; then echo "net_packet preflight failed: HEAD $$actual_head does not match pinned commit $(NET_PACKET_PINNED_COMMIT)" >&2; exit 1; fi; \
		if ! git -C "$(NET_PACKET_ROOT)" diff --cached --no-ext-diff --quiet "$(NET_PACKET_PINNED_COMMIT)" -- src/core/packet.sv; then echo "net_packet preflight failed: staged source diff detected" >&2; exit 1; fi; \
		if ! git -C "$(NET_PACKET_ROOT)" diff --no-ext-diff --quiet -- src/core/packet.sv; then echo "net_packet preflight failed: unstaged source diff detected" >&2; exit 1; fi; \
	else echo "net_packet preflight failed: NET_PACKET_ROOT is not a git checkout" >&2; exit 1; fi

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
		"$(PCIE_WORK_ROOT)/pcie_tl_vip/src/pcie_tl_pkg.sv" \
		"$(PCIE_WORK_ROOT)/pcie_tl_vip/src/shared/pcie_tl_func_manager.sv" \
		"$(PCIE_WORK_ROOT)/pcie_tl_vip/src/shared/pcie_tl_bar_decoder.sv" \
		"$(HOST_MEM_ROOT)/src/host_mem_pkg.sv"; do \
		if [[ ! -r "$$dependency" ]]; then echo "Required pcie_work dependency is not readable: $$dependency" >&2; exit 2; fi; \
	done

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
	if [[ "$$test_name" == regression ]]; then test_name=rdma_end_to_end_dual_env_test; fi; \
	$(E2E_BUILD)/simv +UVM_TESTNAME=$$test_name | tee $(E2E_BUILD)/$$test_name.log; \
	../scripts/check_uvm_summary.sh $(E2E_BUILD)/$$test_name.log

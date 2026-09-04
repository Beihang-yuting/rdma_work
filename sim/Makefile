# 目录：sim/Makefile，仿真构建层入口。
# 职责：定义 core、integration、host_mem 与可选 net_packet 的编译、预检和 UVM 运行流程。
# 依赖与所有权：依赖 VCS、仓库 filelist 及外部只读源码树；本文件仅管理 build 输出目录，不拥有外部依赖生命周期。

BUILD ?= build/core
HOST_MEM_BUILD ?= build/host_mem
override HOST_MEM_PINNED_COMMIT := 3b9e000d5df4d10efbb3029f43605e0362e0caca
override HOST_MEM_PKG_SHA256 := d2ba57918a3b605525274433008142c80921b6205b0848c76bef8f1fc0d0bba5
override HOST_MEM_MANAGER_SHA256 := 8dd5ca3ba3abcfae4808c8ea10c34ced279316bebdc04f6f8e0ae5e55e337a9d
override RDMA_ARCHIVE := /home/ubuntu/workspace/Desktop.zip
override RDMA_ARCHIVE_PREFIX := dpu_kernel_rdma-version_0.1.34
override NET_PACKET_PINNED_COMMIT := e2af70204f53ede65e366c7a65f695c59acdbbc5
TEST ?= rdma_smoke_test
VCS ?= vcs
# Work around a VCS W-2024.09-SP1 class-codegen miscompile; not an RTL requirement.
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -debug_access+class
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: core host_mem_preflight host_mem rdma_defs integration net_packet net_packet_preflight

core:
	mkdir -p $(BUILD)
	$(VCS) $(VCS_FLAGS) -f filelists/core.f -top tb_top -o $(BUILD)/simv
	$(BUILD)/simv +UVM_TESTNAME=$(TEST) | tee $(BUILD)/$(TEST).log
	../scripts/check_uvm_summary.sh $(BUILD)/$(TEST).log

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
	unzip -q "$(RDMA_ARCHIVE)" "$(RDMA_ARCHIVE_PREFIX)/*" -d "$$ref_dir"; \
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
	mkdir -p $(HOST_MEM_BUILD)
	$(VCS) $(VCS_FLAGS) +define+RDMA_HOST_MEM_TEST \
		+incdir+$(HOST_MEM_ROOT)/src \
		$(HOST_MEM_ROOT)/src/host_mem_pkg.sv \
		-f filelists/host_mem.f -top tb_top -o $(HOST_MEM_BUILD)/simv
	$(HOST_MEM_BUILD)/simv +UVM_TESTNAME=$(TEST) | \
		tee $(HOST_MEM_BUILD)/$(TEST).log
	../scripts/check_uvm_summary.sh $(HOST_MEM_BUILD)/$(TEST).log

integration:
	@if [[ -z "$(DPU_COMMON_ROOT)" ]]; then echo "DPU_COMMON_ROOT is required for integration" >&2; exit 2; fi
	mkdir -p build/integration
	$(VCS) $(VCS_FLAGS) +define+RDMA_DPU_INTEGRATION +incdir+$(DPU_COMMON_ROOT)/src $(DPU_COMMON_ROOT)/src/dpu_resource_pkg.sv -f filelists/integration.f -top tb_top -o build/integration/simv
	build/integration/simv +UVM_TESTNAME=$(TEST) | tee build/integration/$(TEST).log
	../scripts/check_uvm_summary.sh build/integration/$(TEST).log

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
	mkdir -p build/net_packet
	$(VCS) $(VCS_FLAGS) +define+RDMA_NET_PACKET +incdir+$(NET_PACKET_ROOT)/src -f filelists/net_packet.f -top tb_top -o build/net_packet/simv
	build/net_packet/simv +UVM_TESTNAME=$(TEST) | tee build/net_packet/$(TEST).log
	../scripts/check_uvm_summary.sh build/net_packet/$(TEST).log

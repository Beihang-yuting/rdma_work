BUILD ?= build/core
HOST_MEM_BUILD ?= build/host_mem
HOST_MEM_PINNED_COMMIT := 3b9e000d5df4d10efbb3029f43605e0362e0caca
HOST_MEM_PKG_SHA256 := d2ba57918a3b605525274433008142c80921b6205b0848c76bef8f1fc0d0bba5
HOST_MEM_MANAGER_SHA256 := 8dd5ca3ba3abcfae4808c8ea10c34ced279316bebdc04f6f8e0ae5e55e337a9d
TEST ?= rdma_smoke_test
VCS ?= vcs
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: core host_mem_preflight host_mem

core:
	mkdir -p $(BUILD)
	$(VCS) $(VCS_FLAGS) -f filelists/core.f -top tb_top -o $(BUILD)/simv
	$(BUILD)/simv +UVM_TESTNAME=$(TEST) | tee $(BUILD)/$(TEST).log
	../scripts/check_uvm_summary.sh $(BUILD)/$(TEST).log

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
	@if git -C "$(HOST_MEM_ROOT)" rev-parse --is-inside-work-tree \
		>/dev/null 2>&1; then \
		actual_head=$$(git -C "$(HOST_MEM_ROOT)" rev-parse HEAD); \
		if [[ "$$actual_head" != "$(HOST_MEM_PINNED_COMMIT)" ]]; then \
			echo "host_mem preflight failed: HEAD $$actual_head does not match pinned commit $(HOST_MEM_PINNED_COMMIT)" >&2; \
			exit 1; \
		fi; \
		if ! git -C "$(HOST_MEM_ROOT)" diff --no-ext-diff --quiet \
			"$(HOST_MEM_PINNED_COMMIT)" -- \
			src/host_mem_pkg.sv src/host_mem_manager.sv; then \
			echo "host_mem preflight failed: pinned source files differ from commit $(HOST_MEM_PINNED_COMMIT)" >&2; \
			exit 1; \
		fi; \
		echo "host_mem preflight passed: pinned git checkout is clean"; \
	else \
		pkg_hash=$$(sha256sum \
			"$(HOST_MEM_ROOT)/src/host_mem_pkg.sv"); \
		pkg_hash=$${pkg_hash%% *}; \
		manager_hash=$$(sha256sum \
			"$(HOST_MEM_ROOT)/src/host_mem_manager.sv"); \
		manager_hash=$${manager_hash%% *}; \
		if [[ "$$pkg_hash" != "$(HOST_MEM_PKG_SHA256)" ]]; then \
			echo "host_mem preflight failed: host_mem_pkg.sv SHA-256 $$pkg_hash does not match pinned $(HOST_MEM_PKG_SHA256)" >&2; \
			exit 1; \
		fi; \
		if [[ "$$manager_hash" != "$(HOST_MEM_MANAGER_SHA256)" ]]; then \
			echo "host_mem preflight failed: host_mem_manager.sv SHA-256 $$manager_hash does not match pinned $(HOST_MEM_MANAGER_SHA256)" >&2; \
			exit 1; \
		fi; \
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

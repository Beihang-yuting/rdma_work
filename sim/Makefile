BUILD ?= build/core
HOST_MEM_BUILD ?= build/host_mem
override HOST_MEM_PINNED_COMMIT := 3b9e000d5df4d10efbb3029f43605e0362e0caca
override HOST_MEM_PKG_SHA256 := d2ba57918a3b605525274433008142c80921b6205b0848c76bef8f1fc0d0bba5
override HOST_MEM_MANAGER_SHA256 := 8dd5ca3ba3abcfae4808c8ea10c34ced279316bebdc04f6f8e0ae5e55e337a9d
override XTR_V1_ARCHIVE := /home/ubuntu/workspace/Desktop.zip
override XTR_V1_ARCHIVE_PREFIX := dpu_kernel_rdma-version_0.1.32
TEST ?= rdma_smoke_test
VCS ?= vcs
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: core host_mem_preflight host_mem xtr_defs

core:
	mkdir -p $(BUILD)
	$(VCS) $(VCS_FLAGS) -f filelists/core.f -top tb_top -o $(BUILD)/simv
	$(BUILD)/simv +UVM_TESTNAME=$(TEST) | tee $(BUILD)/$(TEST).log
	../scripts/check_uvm_summary.sh $(BUILD)/$(TEST).log

xtr_defs:
	@ref_dir=$$(mktemp -d /tmp/rdma_xtr_v1_ref.XXXXXX); \
	if [[ ! "$$ref_dir" =~ ^/tmp/rdma_xtr_v1_ref\.[A-Za-z0-9]{6}$$ ]]; then \
		echo "Refusing unexpected xtr_v1 reference directory: $$ref_dir" >&2; \
		exit 2; \
	fi; \
	cleanup() { \
		command_status=$$?; \
		trap - EXIT; \
		if [[ "$$ref_dir" =~ ^/tmp/rdma_xtr_v1_ref\.[A-Za-z0-9]{6}$$ && -d "$$ref_dir" ]]; then \
			rm -rf -- "$$ref_dir"; \
		else \
			echo "Refusing to remove unexpected xtr_v1 reference directory: $$ref_dir" >&2; \
			command_status=1; \
		fi; \
		exit $$command_status; \
	}; \
	trap cleanup EXIT; \
	unzip -q "$(XTR_V1_ARCHIVE)" "$(XTR_V1_ARCHIVE_PREFIX)/*" -d "$$ref_dir"; \
	python3 ../tools/check_xtr_v1_defs.py \
		--kernel-root "$$ref_dir/$(XTR_V1_ARCHIVE_PREFIX)"

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

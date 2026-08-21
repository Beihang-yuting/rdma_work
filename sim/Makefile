BUILD ?= build/core
HOST_MEM_BUILD ?= build/host_mem
TEST ?= rdma_smoke_test
VCS ?= vcs
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: core host_mem

core:
	mkdir -p $(BUILD)
	$(VCS) $(VCS_FLAGS) -f filelists/core.f -top tb_top -o $(BUILD)/simv
	$(BUILD)/simv +UVM_TESTNAME=$(TEST) | tee $(BUILD)/$(TEST).log
	../scripts/check_uvm_summary.sh $(BUILD)/$(TEST).log

host_mem:
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
	mkdir -p $(HOST_MEM_BUILD)
	$(VCS) $(VCS_FLAGS) +define+RDMA_HOST_MEM_TEST \
		+incdir+$(HOST_MEM_ROOT)/src \
		$(HOST_MEM_ROOT)/src/host_mem_pkg.sv \
		-f filelists/host_mem.f -top tb_top -o $(HOST_MEM_BUILD)/simv
	$(HOST_MEM_BUILD)/simv +UVM_TESTNAME=$(TEST) | \
		tee $(HOST_MEM_BUILD)/$(TEST).log
	../scripts/check_uvm_summary.sh $(HOST_MEM_BUILD)/$(TEST).log

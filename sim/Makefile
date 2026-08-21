BUILD ?= build/core
TEST ?= rdma_smoke_test
VCS ?= vcs
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: core

core:
	mkdir -p $(BUILD)
	$(VCS) $(VCS_FLAGS) -f filelists/core.f -top tb_top -o $(BUILD)/simv
	$(BUILD)/simv +UVM_TESTNAME=$(TEST) | tee $(BUILD)/$(TEST).log
	../scripts/check_uvm_summary.sh $(BUILD)/$(TEST).log

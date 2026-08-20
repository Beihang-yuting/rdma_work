BUILD ?= build/core
TEST ?= rdma_smoke_test
VCS ?= vcs
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps

.PHONY: core

core:
	mkdir -p $(BUILD)
	$(VCS) $(VCS_FLAGS) -f filelists/core.f -top tb_top -o $(BUILD)/simv
	$(BUILD)/simv +UVM_TESTNAME=$(TEST)

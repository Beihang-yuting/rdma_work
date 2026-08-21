// Deliberately excluded from normal regressions.  This probe verifies that the
// simulation harness rejects a pristine compile/run containing one UVM error.
class rdma_harness_expected_failure_probe extends uvm_test;
  `uvm_component_utils(rdma_harness_expected_failure_probe)

  function new(string name = "rdma_harness_expected_failure_probe",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_error("HARNESS_EXPECTED_FAILURE",
               "intentional single-error runner status probe")
    phase.drop_objection(this);
  endtask
endclass

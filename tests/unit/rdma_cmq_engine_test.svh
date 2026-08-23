typedef enum int unsigned {
  RDMA_CMQ_TEST_SQE_GOOD,
  RDMA_CMQ_TEST_SQE_NULL,
  RDMA_CMQ_TEST_SQE_SHORT,
  RDMA_CMQ_TEST_SQE_BAD_ALIGNMENT,
  RDMA_CMQ_TEST_SQE_BAD_KIND,
  RDMA_CMQ_TEST_SQE_STALE_GENERATION,
  RDMA_CMQ_TEST_SQE_BAD_TARGET_KIND,
  RDMA_CMQ_TEST_SQE_BAD_TARGET_ADDRESS,
  RDMA_CMQ_TEST_EXPECTED_NULL,
  RDMA_CMQ_TEST_EXPECTED_INVALID,
  RDMA_CMQ_TEST_SQE_INACTIVE_HMC,
  RDMA_CMQ_TEST_SQE_INACTIVE_BAR,
  RDMA_CMQ_TEST_SQE_CLONE_SELF,
  RDMA_CMQ_TEST_SQE_CLONE_MUTATE,
  RDMA_CMQ_TEST_EXPECTED_CLONE_SELF,
  RDMA_CMQ_TEST_EXPECTED_CLONE_MUTATE
} rdma_cmq_test_sqe_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_DB_GOOD,
  RDMA_CMQ_TEST_DB_NULL,
  RDMA_CMQ_TEST_DB_BAD_LENGTH,
  RDMA_CMQ_TEST_DB_BAD_KIND,
  RDMA_CMQ_TEST_DB_STALE_GENERATION,
  RDMA_CMQ_TEST_DB_BAD_TARGET_KIND,
  RDMA_CMQ_TEST_DB_INACTIVE_BACKING,
  RDMA_CMQ_TEST_DB_INACTIVE_HMC,
  RDMA_CMQ_TEST_DB_CLONE_SELF,
  RDMA_CMQ_TEST_DB_CLONE_MUTATE
} rdma_cmq_test_doorbell_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_DB_INPUT_GOOD,
  RDMA_CMQ_TEST_DB_INPUT_MUTATE_SUCCESS,
  RDMA_CMQ_TEST_DB_INPUT_MUTATE_FAILURE,
  RDMA_CMQ_TEST_DB_INPUT_MUTATE_NULL
} rdma_cmq_test_doorbell_input_fault_e;

typedef enum bit [2:0] {
  RDMA_CMQ_TEST_CLONE_GOOD,
  RDMA_CMQ_TEST_CLONE_NULL,
  RDMA_CMQ_TEST_CLONE_SELF,
  RDMA_CMQ_TEST_CLONE_MUTATE,
  RDMA_CMQ_TEST_CLONE_WRONG_TYPE,
  RDMA_CMQ_TEST_CLONE_ALIAS
} rdma_cmq_test_clone_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_HOOK_GOOD,
  RDMA_CMQ_TEST_HOOK_NULL_STATUS,
  RDMA_CMQ_TEST_HOOK_NONOK_STATUS,
  RDMA_CMQ_TEST_HOOK_NULL_OUTPUT,
  RDMA_CMQ_TEST_HOOK_WRONG_TYPE,
  RDMA_CMQ_TEST_HOOK_SELF_OUTPUT,
  RDMA_CMQ_TEST_HOOK_MUTATED_OUTPUT,
  RDMA_CMQ_TEST_HOOK_ALIASED_OUTPUT,
  RDMA_CMQ_TEST_HOOK_NULL_VALIDATION,
  RDMA_CMQ_TEST_HOOK_FAILED_VALIDATION,
  RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT,
  RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT,
  RDMA_CMQ_TEST_HOOK_MUTATE_SOURCE
} rdma_cmq_test_hook_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_DECODED_CONTRACT_GOOD,
  RDMA_CMQ_TEST_DECODED_ZERO_NONOK,
  RDMA_CMQ_TEST_DECODED_ZERO_HARDWARE_VALID,
  RDMA_CMQ_TEST_DECODED_NONZERO_OK,
  RDMA_CMQ_TEST_DECODED_NONZERO_HARDWARE_INVALID,
  RDMA_CMQ_TEST_DECODED_HARDWARE_MISMATCH,
  RDMA_CMQ_TEST_DECODED_CATEGORY_MISMATCH,
  RDMA_CMQ_TEST_DECODED_SEVERITY_MISMATCH,
  RDMA_CMQ_TEST_DECODED_NONZERO_WARNING,
  RDMA_CMQ_TEST_DECODED_NONZERO_FATAL
} rdma_cmq_test_decoded_contract_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_EMPTY_LEDGER_COUNTER,
  RDMA_CMQ_TEST_EMPTY_LEDGER_SLOT,
  RDMA_CMQ_TEST_EMPTY_LEDGER_TOKEN,
  RDMA_CMQ_TEST_EMPTY_LEDGER_REGISTRY
} rdma_cmq_test_empty_ledger_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_POISON_RESERVED_BIT,
  RDMA_CMQ_TEST_POISON_UNSUPPORTED_OPCODE,
  RDMA_CMQ_TEST_POISON_OPCODE_MISMATCH,
  RDMA_CMQ_TEST_POISON_UNKNOWN_ENTRY,
  RDMA_CMQ_TEST_POISON_NULL_DECODED,
  RDMA_CMQ_TEST_POISON_NULL_COMMAND_STATUS,
  RDMA_CMQ_TEST_POISON_SLOT_INCARNATION
} rdma_cmq_test_poison_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_EXTENSION_GOOD,
  RDMA_CMQ_TEST_EXTENSION_DROP_SCALAR,
  RDMA_CMQ_TEST_EXTENSION_ALIAS_EDGE,
  RDMA_CMQ_TEST_EXTENSION_NULL_OUTPUT,
  RDMA_CMQ_TEST_EXTENSION_MUTATE_SOURCE
} rdma_cmq_test_extension_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_DIRECT_HANDLE_GOOD,
  RDMA_CMQ_TEST_DIRECT_HANDLE_DROP_SCALAR,
  RDMA_CMQ_TEST_DIRECT_HANDLE_ALIAS_EDGE,
  RDMA_CMQ_TEST_DIRECT_HANDLE_SAME_DRIFT,
  RDMA_CMQ_TEST_DIRECT_HANDLE_DETACH_DRIFT
} rdma_cmq_test_direct_handle_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_ABORT_SLOT_CONTEXT,
  RDMA_CMQ_TEST_ABORT_TICKET,
  RDMA_CMQ_TEST_ABORT_SLOT_RECORD,
  RDMA_CMQ_TEST_ABORT_DEPENDENCY,
  RDMA_CMQ_TEST_ABORT_DOORBELL_DESC,
  RDMA_CMQ_TEST_ABORT_PROFILE_OUTPUT
} rdma_cmq_test_abort_fault_e;

class rdma_cmq_clone_fault_function_handle extends rdma_function_handle;
  `uvm_object_utils(rdma_cmq_clone_fault_function_handle)

  local static int unsigned fault_clone_calls;
  rdma_cmq_test_clone_fault_e clone_fault;
  rdma_function_handle alias_target;
  bit alias_once;

  function new(string name = "rdma_cmq_clone_fault_function_handle");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
    alias_target = null;
    alias_once = 1'b0;
  endfunction

  static function void clear_fault_clone_calls();
    fault_clone_calls = 0;
  endfunction

  static function int unsigned fault_clone_call_count();
    return fault_clone_calls;
  endfunction

  virtual function uvm_object clone();
    if (clone_fault != RDMA_CMQ_TEST_CLONE_GOOD)
      fault_clone_calls++;
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        object_id++;
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong Function clone type");
      RDMA_CMQ_TEST_CLONE_ALIAS: begin
        if (alias_once) begin
          alias_once = 1'b0;
          return alias_target;
        end
        return super.clone();
      end
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_handle extends rdma_handle;
  `uvm_object_utils(rdma_cmq_clone_fault_handle)

  rdma_cmq_test_clone_fault_e clone_fault;
  rdma_handle alias_target;

  function new(string name = "rdma_cmq_clone_fault_handle");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
    alias_target = null;
  endfunction

  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        object_id++;
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong handle clone type");
      RDMA_CMQ_TEST_CLONE_ALIAS: return alias_target;
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_qpc extends rdma_qpc_model;
  `uvm_object_utils(rdma_cmq_clone_fault_qpc)

  rdma_cmq_test_clone_fault_e clone_fault;

  function new(string name = "rdma_cmq_clone_fault_qpc");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        host_id++;
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong QPC clone type");
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_scalar_extension_qpc extends rdma_qpc_model;
  `uvm_object_utils(rdma_cmq_scalar_extension_qpc)

  local static int unsigned hostile_clone_calls;

  int unsigned extension_value;

  function new(string name = "rdma_cmq_scalar_extension_qpc");
    super.new(name);
    extension_value = 0;
  endfunction

  static function void clear_hostile_clone_calls();
    hostile_clone_calls = 0;
  endfunction

  static function int unsigned clone_call_count();
    return hostile_clone_calls;
  endfunction

  virtual function uvm_object clone();
    rdma_cmq_scalar_extension_qpc result;

    hostile_clone_calls++;
    result = rdma_cmq_scalar_extension_qpc::type_id::create(
      "lossy_scalar_extension_clone"
    );
    result.copy(this);
    return result;
  endfunction
endclass

class rdma_cmq_edge_extension_qpc extends rdma_qpc_model;
  `uvm_object_utils(rdma_cmq_edge_extension_qpc)

  local static int unsigned hostile_clone_calls;

  rdma_handle extension_h;

  function new(string name = "rdma_cmq_edge_extension_qpc");
    super.new(name);
    extension_h = null;
  endfunction

  static function void clear_hostile_clone_calls();
    hostile_clone_calls = 0;
  endfunction

  static function int unsigned clone_call_count();
    return hostile_clone_calls;
  endfunction

  virtual function uvm_object clone();
    rdma_cmq_edge_extension_qpc result;

    hostile_clone_calls++;
    result = rdma_cmq_edge_extension_qpc::type_id::create(
      "aliasing_edge_extension_clone"
    );
    result.copy(this);
    result.extension_h = extension_h;
    return result;
  endfunction
endclass

class rdma_cmq_scalar_extension_function_handle
    extends rdma_function_handle;
  `uvm_object_utils(rdma_cmq_scalar_extension_function_handle)

  int unsigned extension_value;

  function new(
    string name = "rdma_cmq_scalar_extension_function_handle"
  );
    super.new(name);
    extension_value = 0;
  endfunction
endclass

class rdma_cmq_edge_extension_handle extends rdma_handle;
  `uvm_object_utils(rdma_cmq_edge_extension_handle)

  rdma_handle extension_h;

  function new(string name = "rdma_cmq_edge_extension_handle");
    super.new(name);
    extension_h = null;
  endfunction
endclass

class rdma_cmq_clone_fault_page_layout extends rdma_page_table_layout;
  `uvm_object_utils(rdma_cmq_clone_fault_page_layout)

  rdma_cmq_test_clone_fault_e clone_fault;

  function new(string name = "rdma_cmq_clone_fault_page_layout");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong page-layout clone type");
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_mr_page_layout extends rdma_mr_page_layout;
  `uvm_object_utils(rdma_cmq_clone_fault_mr_page_layout)

  rdma_cmq_test_clone_fault_e clone_fault;

  function new(string name = "rdma_cmq_clone_fault_mr_page_layout");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong MR-layout clone type");
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_ring extends rdma_ring_position;
  `uvm_object_utils(rdma_cmq_clone_fault_ring)

  rdma_cmq_test_clone_fault_e clone_fault;
  rdma_ring_position alias_target;

  function new(string name = "rdma_cmq_clone_fault_ring");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
    alias_target = null;
  endfunction

  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        index++;
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong ring clone type");
      RDMA_CMQ_TEST_CLONE_ALIAS: return alias_target;
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_aeqc extends rdma_aeqc_model;
  `uvm_object_utils(rdma_cmq_clone_fault_aeqc)

  rdma_cmq_test_clone_fault_e clone_fault;

  function new(string name = "rdma_cmq_clone_fault_aeqc");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    if (clone_fault == RDMA_CMQ_TEST_CLONE_MUTATE) begin
      vector_id++;
      return super.clone();
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_unknown_body extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_unknown_body)

  function new(string name = "rdma_cmq_unknown_body");
    super.new(name);
  endfunction

  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return "unknown CMQ body";
  endfunction
endclass

class rdma_cmq_profile_hook_body extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_profile_hook_body)

  local static int unsigned hostile_clone_calls;

  int unsigned value;
  rdma_handle nested_h;
  bit validation_returns_null;
  bit validation_fails;
  bit first_clone_succeeds;
  int unsigned clone_calls;

  function new(string name = "rdma_cmq_profile_hook_body");
    super.new(name);
    value = 0;
    nested_h = null;
    validation_returns_null = 1'b0;
    validation_fails = 1'b0;
    first_clone_succeeds = 1'b0;
    clone_calls = 0;
  endfunction

  static function void clear_hostile_clone_calls();
    hostile_clone_calls = 0;
  endfunction

  static function int unsigned clone_call_count();
    return hostile_clone_calls;
  endfunction

  virtual function uvm_object clone();
    rdma_cmq_profile_hook_body result;

    hostile_clone_calls++;
    clone_calls++;
    if (first_clone_succeeds && clone_calls == 1) begin
      result = rdma_cmq_profile_hook_body::type_id::create(
        "stateful_hook_snapshot"
      );
      result.value = value;
      result.nested_h = rdma_handle::type_id::create(
        "stateful_hook_snapshot_nested"
      );
      if (nested_h != null) begin
        result.nested_h.kind = nested_h.kind;
        result.nested_h.function_uid = nested_h.function_uid;
        result.nested_h.object_id = nested_h.object_id;
        result.nested_h.generation = nested_h.generation;
      end
      return result;
    end
    `uvm_fatal("RDMA_COPY_TYPE",
               "hostile custom CMQ body clone must not be called")
    return null;
  endfunction

  virtual function rdma_status validate();
    if (validation_returns_null)
      return null;
    if (validation_fails)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "injected custom CMQ body snapshot validation failure"
      );
    if (nested_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "custom CMQ body handle is null");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf("custom hook body value=%0d", value);
  endfunction
endclass

class rdma_cmq_copy_fatal_catcher extends uvm_report_catcher;
  int unsigned caught_count;

  function new(string name = "rdma_cmq_copy_fatal_catcher");
    super.new(name);
    caught_count = 0;
  endfunction

  virtual function action_e catch();
    if (get_severity() == UVM_FATAL && get_id() == "RDMA_COPY_TYPE") begin
      caught_count++;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class rdma_cmq_clone_fault_opcode_key extends rdma_cmq_opcode_key;
  `uvm_object_utils(rdma_cmq_clone_fault_opcode_key)

  rdma_cmq_test_clone_fault_e clone_fault;

  function new(string name = "rdma_cmq_clone_fault_opcode_key");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        variant = {variant, "_mutated"};
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong opcode clone type");
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_body extends rdma_cmq_sqe_model;
  `uvm_object_utils(rdma_cmq_clone_fault_body)

  rdma_cmq_test_clone_fault_e clone_fault;

  function new(string name = "rdma_cmq_clone_fault_body");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        flags++;
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong body clone type");
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_image extends rdma_hw_image;
  `uvm_object_utils(rdma_cmq_clone_fault_image)

  rdma_cmq_test_clone_fault_e clone_fault;

  function new(string name = "rdma_cmq_clone_fault_image");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        if (bytes.size() == 0)
          length++;
        else
          bytes[0] ^= 8'hff;
        return super.clone();
      end
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_poll_raw_self_image extends rdma_hw_image;
  `uvm_object_utils(rdma_cmq_poll_raw_self_image)

  local static bit arm_next_raw_self_clone;
  local static bit arm_next_raw_stateful_clone;
  local static int unsigned total_clone_calls;
  bit self_clone;
  bit stateful_clone;
  int unsigned stateful_clone_calls;

  function new(string name = "rdma_cmq_poll_raw_self_image");
    super.new(name);
    self_clone = 1'b0;
    stateful_clone = 1'b0;
    stateful_clone_calls = 0;
    if (name == "cmq_raw_cqe" && arm_next_raw_self_clone) begin
      self_clone = 1'b1;
      arm_next_raw_self_clone = 1'b0;
    end
    else if (name == "cmq_raw_cqe" && arm_next_raw_stateful_clone) begin
      stateful_clone = 1'b1;
      arm_next_raw_stateful_clone = 1'b0;
    end
  endfunction

  static function void arm_next_raw();
    arm_next_raw_self_clone = 1'b1;
  endfunction

  static function void arm_next_raw_stateful();
    arm_next_raw_stateful_clone = 1'b1;
  endfunction

  static function void clear_clone_calls();
    total_clone_calls = 0;
  endfunction

  static function int unsigned clone_call_count();
    return total_clone_calls;
  endfunction

  static function void disarm();
    arm_next_raw_self_clone = 1'b0;
    arm_next_raw_stateful_clone = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_poll_raw_self_image rhs_image;

    super.do_copy(rhs);
    if (!$cast(rhs_image, rhs))
      `uvm_fatal("RDMA_COPY_TYPE",
                 "poll raw image copy type mismatch")
    self_clone = rhs_image.self_clone;
    stateful_clone = rhs_image.stateful_clone;
    stateful_clone_calls = rhs_image.stateful_clone_calls;
  endfunction

  virtual function uvm_object clone();
    uvm_object cloned_object;

    if (self_clone)
      return this;
    if (stateful_clone) begin
      total_clone_calls++;
      stateful_clone_calls++;
      if (stateful_clone_calls == 2 && bytes.size() != 0)
        bytes[0] ^= 8'hff;
      cloned_object = super.clone();
      if (stateful_clone_calls == 1)
        stateful_clone = 1'b0;
      return cloned_object;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_self_clone_completion_payload extends uvm_object;
  `uvm_object_utils(rdma_cmq_self_clone_completion_payload)

  int unsigned value;
  rdma_handle nested_h;

  function new(string name = "rdma_cmq_self_clone_completion_payload");
    super.new(name);
    value = 0;
    nested_h = null;
  endfunction

  virtual function uvm_object clone();
    return this;
  endfunction
endclass

class rdma_cmq_clone_fault_expected extends rdma_cmq_expected_response;
  `uvm_object_utils(rdma_cmq_clone_fault_expected)

  rdma_cmq_test_clone_fault_e clone_fault;

  function new(string name = "rdma_cmq_clone_fault_expected");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        variant = {variant, "_mutated"};
        return super.clone();
      end
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_failing_slot_context extends rdma_cmq_slot_context;
  `uvm_object_utils(rdma_cmq_failing_slot_context)

  local static bit arm_failure;

  function new(string name = "rdma_cmq_failing_slot_context");
    super.new(name);
  endfunction

  static function void arm();
    arm_failure = 1'b1;
  endfunction

  static function void disarm();
    arm_failure = 1'b0;
  endfunction

  static function bit armed();
    return arm_failure;
  endfunction

  virtual function uvm_object clone();
    if (arm_failure && sq_index == 1) begin
      arm_failure = 1'b0;
      return this;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_failing_ticket extends rdma_cmq_ticket;
  `uvm_object_utils(rdma_cmq_failing_ticket)

  local static bit arm_failure;

  function new(string name = "rdma_cmq_failing_ticket");
    super.new(name);
  endfunction

  static function void arm();
    arm_failure = 1'b1;
  endfunction

  static function void disarm();
    arm_failure = 1'b0;
  endfunction

  static function bit armed();
    return arm_failure;
  endfunction

  virtual function uvm_object clone();
    if (arm_failure && sq_index == 1) begin
      arm_failure = 1'b0;
      return this;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_failing_slot_record extends rdma_cmq_slot_record;
  `uvm_object_utils(rdma_cmq_failing_slot_record)

  local static bit arm_failure;

  function new(string name = "rdma_cmq_failing_slot_record");
    super.new(name);
  endfunction

  static function void arm();
    arm_failure = 1'b1;
  endfunction

  static function void disarm();
    arm_failure = 1'b0;
  endfunction

  static function bit armed();
    return arm_failure;
  endfunction

  virtual function uvm_object clone();
    if (arm_failure && sq_index == 1) begin
      arm_failure = 1'b0;
      return this;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_failing_dependency extends rdma_doorbell_dependency;
  `uvm_object_utils(rdma_cmq_failing_dependency)

  local static bit arm_failure;
  local static bit capture_armed;
  local static longint unsigned captured_dependency_id;

  function new(string name = "rdma_cmq_failing_dependency");
    super.new(name);
  endfunction

  static function void arm();
    arm_failure = 1'b1;
  endfunction

  static function void disarm();
    arm_failure = 1'b0;
  endfunction

  static function bit armed();
    return arm_failure;
  endfunction

  static function void arm_capture();
    capture_armed = 1'b1;
    captured_dependency_id = '0;
  endfunction

  static function void disarm_capture();
    capture_armed = 1'b0;
    captured_dependency_id = '0;
  endfunction

  static function bit take_captured_dependency_id(
    output longint unsigned dependency_id
  );
    dependency_id = captured_dependency_id;
    return !capture_armed;
  endfunction

  virtual function uvm_object clone();
    if (capture_armed) begin
      capture_armed = 1'b0;
      captured_dependency_id = dependency_id;
    end
    if (arm_failure && relative_offset == 64) begin
      arm_failure = 1'b0;
      return this;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_failing_doorbell_desc extends rdma_doorbell_desc;
  `uvm_object_utils(rdma_cmq_failing_doorbell_desc)

  local static bit arm_failure;

  function new(string name = "rdma_cmq_failing_doorbell_desc");
    super.new(name);
  endfunction

  static function void arm();
    arm_failure = 1'b1;
  endfunction

  static function void disarm();
    arm_failure = 1'b0;
  endfunction

  static function bit armed();
    return arm_failure;
  endfunction

  virtual function uvm_object clone();
    if (arm_failure) begin
      arm_failure = 1'b0;
      return this;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_test_profile extends rdma_cmq_hw_profile;
  `uvm_object_utils(rdma_cmq_test_profile)

  localparam bit [31:0] TEST_OPCODE = 32'h0000_0010;
  localparam bit [31:0] TEST_OPCODE_A = 32'h0000_0010;
  localparam bit [31:0] TEST_OPCODE_B = 32'h0000_0020;
  localparam bit [31:0] TEST_OPCODE_UNSUPPORTED = 32'h0000_00ee;
  localparam longint unsigned TEST_DOORBELL_OFFSET = 64'h80;

  bit fail_validation;
  bit return_null_status;
  int unsigned validation_calls;
  rdma_cmq_test_sqe_fault_e sqe_fault;
  int unsigned sqe_fault_compose_call;
  rdma_cmq_test_doorbell_fault_e doorbell_fault;
  rdma_cmq_test_doorbell_input_fault_e doorbell_input_fault;
  bit [31:0] fail_compose_opcode;
  int unsigned null_compose_call;
  rdma_status_code_e compose_failure_code;
  bit fail_doorbell_encode;
  rdma_status_code_e doorbell_failure_code;
  rdma_byte_endian_e sqe_endian;
  int unsigned sqe_hardware_version;
  bit alternate_sqe_format_for_opcode_b;
  rdma_byte_endian_e alternate_sqe_endian;
  int unsigned alternate_sqe_hardware_version;
  int unsigned compose_calls;
  int unsigned doorbell_calls;
  int unsigned last_final_pi;
  bit last_polarity;
  rdma_handle last_doorbell_target;
  rdma_handle last_doorbell_input;
  rdma_cmq_expected_response last_expected_alias;
  bit mutate_raw_cqe_input;
  bit use_self_clone_completion_payload;
  rdma_cmq_self_clone_completion_payload last_completion_payload_source;
  rdma_cmq_test_hook_fault_e completion_payload_hook_fault;
  int unsigned completion_payload_same_calls;
  int unsigned completion_payload_detach_calls;
  rdma_cmq_test_decoded_contract_fault_e decoded_contract_fault;
  bit return_null_decoded;
  bit return_null_command_status;
  int unsigned inspect_calls;
  int unsigned inspect_failure_call;
  rdma_status_code_e inspect_failure_code;
  rdma_xtr_v1_cmq_completion_codec completion_codec;
  rdma_xtr_v1_error_codec error_codec;

  function new(string name = "rdma_cmq_test_profile");
    super.new(name);
    fail_validation = 1'b0;
    return_null_status = 1'b0;
    validation_calls = 0;
    sqe_fault = RDMA_CMQ_TEST_SQE_GOOD;
    sqe_fault_compose_call = 0;
    doorbell_fault = RDMA_CMQ_TEST_DB_GOOD;
    doorbell_input_fault = RDMA_CMQ_TEST_DB_INPUT_GOOD;
    fail_compose_opcode = '0;
    null_compose_call = 0;
    compose_failure_code = RDMA_SC_CODEC_ERROR;
    fail_doorbell_encode = 1'b0;
    doorbell_failure_code = RDMA_SC_CODEC_ERROR;
    sqe_endian = RDMA_ENDIAN_BIG;
    sqe_hardware_version = 7;
    alternate_sqe_format_for_opcode_b = 1'b0;
    alternate_sqe_endian = RDMA_ENDIAN_LITTLE;
    alternate_sqe_hardware_version = 8;
    compose_calls = 0;
    doorbell_calls = 0;
    last_final_pi = 0;
    last_polarity = 1'b0;
    last_doorbell_target = null;
    last_doorbell_input = null;
    last_expected_alias = null;
    mutate_raw_cqe_input = 1'b0;
    use_self_clone_completion_payload = 1'b0;
    last_completion_payload_source = null;
    completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_GOOD;
    completion_payload_same_calls = 0;
    completion_payload_detach_calls = 0;
    decoded_contract_fault = RDMA_CMQ_TEST_DECODED_CONTRACT_GOOD;
    return_null_decoded = 1'b0;
    return_null_command_status = 1'b0;
    inspect_calls = 0;
    inspect_failure_call = 0;
    inspect_failure_code = RDMA_SC_CODEC_ERROR;
    completion_codec = rdma_xtr_v1_cmq_completion_codec::type_id::create(
      "engine_test_completion_codec"
    );
    error_codec = rdma_xtr_v1_error_codec::type_id::create(
      "engine_test_error_codec"
    );
  endfunction

  virtual function string profile_name();
    return "cmq_engine_test";
  endfunction

  virtual function rdma_status validate_profile();
    validation_calls++;
    if (return_null_status)
      return null;
    if (fail_validation)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "test CMQ profile validation failed");
    return rdma_status::success();
  endfunction

  protected function void set_cqe_qword(
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] value
  );
    int unsigned base;

    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[base + i] = value[63 - (i * 8) -: 8];
  endfunction

  function rdma_hw_image make_cqe(
    string name,
    bit owner,
    bit [31:0] hardware_opcode,
    bit [31:0] hardware_ecode,
    int unsigned wqe_index,
    bit wqe_wrap,
    int unsigned function_generation
  );
    rdma_hw_image image;
    bit [63:0] qword0;

    image = rdma_hw_image::type_id::create(name);
    repeat (64)
      image.bytes.push_back(8'h00);
    image.length = 64;
    image.alignment = 64;
    image.endian = sqe_endian;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = sqe_hardware_version;
    image.function_generation = function_generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    qword0 = '0;
    qword0[63] = owner;
    qword0[45] = wqe_wrap;
    qword0[44:40] = wqe_index[4:0];
    qword0[39:32] = hardware_opcode[7:0];
    qword0[31:24] = hardware_ecode[7:0];
    set_cqe_qword(image, 0, qword0);
    return image;
  endfunction

  virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );
    rdma_cmq_sqe_model body;
    rdma_cmq_clone_fault_image clone_fault_image;
    rdma_cmq_clone_fault_expected clone_fault_expected;

    sqe = null;
    expected = null;
    compose_calls++;
    if (command == null || command.opcode_key == null ||
        command.opcode_key.profile_name != profile_name())
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "test profile name is unsupported");
    if (!(command.opcode_key.opcode inside {TEST_OPCODE_A,
                                            TEST_OPCODE_B}))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "test profile opcode is unsupported");
    if (slot == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test profile slot is null");
    if (null_compose_call != 0 && compose_calls == null_compose_call) begin
      null_compose_call = 0;
      return null;
    end
    if (fail_compose_opcode != 0 &&
        command.opcode_key.opcode == fail_compose_opcode)
      return rdma_status::make(compose_failure_code,
                               "injected test profile compose failure");
    if (!$cast(body, command.body))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test profile body type is invalid");
    if (sqe_fault == RDMA_CMQ_TEST_SQE_NULL)
      return rdma_status::success();
    sqe = rdma_hw_image::type_id::create("test_sqe");
    for (int unsigned i = 0; i < 64; i++)
      sqe.bytes.push_back(byte'(command.opcode_key.opcode[7:0] + i));
    sqe.bytes[0] = command.opcode_key.opcode[7:0];
    sqe.bytes[1] = body.flags[7:0];
    sqe.bytes[2] = (command.qpc_signature_source == null ||
                    command.qpc_signature_source.bytes.size() == 0) ?
                   8'h00 : command.qpc_signature_source.bytes[0];
    sqe.bytes[3] = command.function_h.object_id[7:0];
    sqe.bytes[4] = slot.sq_index[7:0];
    sqe.bytes[5] = {6'b0, !slot.sq_wrap, slot.sq_wrap};
    sqe.bytes[6] = slot.slot_sequence[7:0];
    sqe.bytes[7] = body.command_id[7:0];
    sqe.length = 64;
    sqe.alignment = 64;
    sqe.endian = (alternate_sqe_format_for_opcode_b &&
                  command.opcode_key.opcode == TEST_OPCODE_B) ?
                 alternate_sqe_endian : sqe_endian;
    sqe.image_kind = RDMA_IMAGE_CMQ_SQE;
    sqe.hardware_version =
      (alternate_sqe_format_for_opcode_b &&
       command.opcode_key.opcode == TEST_OPCODE_B) ?
      alternate_sqe_hardware_version : sqe_hardware_version;
    sqe.function_generation = command.function_h.generation;
    sqe.write_target_kind = RDMA_HW_TARGET_BACKING;
    sqe.backing_target.value = slot.backing_addr.value +
                               slot.relative_offset;
    expected = rdma_cmq_expected_response::type_id::create(
      "test_expected"
    );
    expected.hardware_opcode = command.opcode_key.opcode;
    expected.variant = $sformatf("expected_%02h_%02h",
                                 command.opcode_key.opcode[7:0],
                                 body.flags[7:0]);
    last_expected_alias = expected;
    if (sqe_fault_compose_call == 0 ||
        compose_calls == sqe_fault_compose_call) begin
      case (sqe_fault)
        RDMA_CMQ_TEST_SQE_SHORT: begin
          void'(sqe.bytes.pop_back());
          sqe.length = 63;
        end
        RDMA_CMQ_TEST_SQE_BAD_ALIGNMENT: sqe.alignment = 32;
        RDMA_CMQ_TEST_SQE_BAD_KIND: sqe.image_kind = RDMA_IMAGE_CMQ_CQE;
        RDMA_CMQ_TEST_SQE_STALE_GENERATION:
          sqe.function_generation++;
        RDMA_CMQ_TEST_SQE_BAD_TARGET_KIND:
          sqe.write_target_kind = RDMA_HW_TARGET_BAR;
        RDMA_CMQ_TEST_SQE_BAD_TARGET_ADDRESS:
          sqe.backing_target.value++;
        RDMA_CMQ_TEST_EXPECTED_NULL: expected = null;
        RDMA_CMQ_TEST_EXPECTED_INVALID: expected.variant = "";
        RDMA_CMQ_TEST_SQE_INACTIVE_HMC:
          sqe.hmc_target.value = 64'h40;
        RDMA_CMQ_TEST_SQE_INACTIVE_BAR:
          sqe.bar_target.value = 64'h80;
        RDMA_CMQ_TEST_SQE_CLONE_SELF,
        RDMA_CMQ_TEST_SQE_CLONE_MUTATE: begin
          clone_fault_image = rdma_cmq_clone_fault_image::type_id::create(
            "test_sqe_clone_fault"
          );
          clone_fault_image.copy(sqe);
          clone_fault_image.clone_fault =
            (sqe_fault == RDMA_CMQ_TEST_SQE_CLONE_SELF) ?
              RDMA_CMQ_TEST_CLONE_SELF : RDMA_CMQ_TEST_CLONE_MUTATE;
          sqe = clone_fault_image;
        end
        RDMA_CMQ_TEST_EXPECTED_CLONE_SELF,
        RDMA_CMQ_TEST_EXPECTED_CLONE_MUTATE: begin
          clone_fault_expected =
            rdma_cmq_clone_fault_expected::type_id::create(
              "test_expected_clone_fault"
            );
          clone_fault_expected.copy(expected);
          clone_fault_expected.clone_fault =
            (sqe_fault == RDMA_CMQ_TEST_EXPECTED_CLONE_SELF) ?
              RDMA_CMQ_TEST_CLONE_SELF : RDMA_CMQ_TEST_CLONE_MUTATE;
          expected = clone_fault_expected;
          last_expected_alias = expected;
        end
        default: begin
        end
      endcase
    end
    return rdma_status::success();
  endfunction

  virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );
    rdma_status status;
    rdma_status command_status;
    rdma_hw_image codec_raw_cqe;
    rdma_xtr_v1_cmq_completion completion;
    rdma_xtr_v1_cmq_completion payload;
    rdma_cmq_self_clone_completion_payload hostile_payload;
    uvm_object cloned_object;

    inspect_calls++;
    ready = 1'b0;
    decoded = null;
    if (inspect_failure_call != 0 &&
        inspect_calls == inspect_failure_call)
      return rdma_status::make(
        inspect_failure_code, "injected test profile inspection failure"
      );
    if (completion_codec == null || error_codec == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test profile completion codecs are unavailable"
      );
    codec_raw_cqe = rdma_cmq_clone_image_value(
      raw_cqe, "test profile XTR codec input"
    );
    if (codec_raw_cqe == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test profile could not snapshot its raw CQE input"
      );
    // The synthetic profile deliberately advertises a non-XTR format to
    // exercise engine neutrality.  Only its private test codec adapter owns
    // the XTR v1 metadata required to decode the borrowed wire layout.
    codec_raw_cqe.endian = RDMA_ENDIAN_BIG;
    codec_raw_cqe.hardware_version = XTR_V1_HW_VERSION;
    status = completion_codec.inspect_completion(
      codec_raw_cqe, expected_owner, ready, completion
    );
    if (status == null || !status.ok() || !ready)
      return status;
    if (completion == null) begin
      ready = 1'b0;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test completion codec returned null decoded data"
      );
    end
    status = error_codec.decode_status(
      completion.command_ecode, RDMA_ENGINE_CMQ, command_status
    );
    if (status == null || !status.ok() || command_status == null) begin
      ready = 1'b0;
      return (status == null) ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "test error codec returned null status"
        ) : status;
    end
    cloned_object = completion.clone();
    if (cloned_object == null || !$cast(payload, cloned_object)) begin
      ready = 1'b0;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test completion payload clone failed"
      );
    end
    decoded = rdma_cmq_decoded_cqe::type_id::create(
      "engine_test_decoded_cqe"
    );
    if (decoded == null) begin
      ready = 1'b0;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test decoded CQE allocation failed"
      );
    end
    decoded.hardware_opcode = {24'h0, completion.opcode};
    decoded.wqe_index = completion.wqe_index;
    decoded.wqe_wrap = completion.wrap;
    decoded.hardware_ecode = {24'h0, completion.command_ecode};
    decoded.command_status = command_status;
    if (return_null_decoded) begin
      decoded = null;
      return rdma_status::success();
    end
    if (return_null_command_status) begin
      decoded.command_status = null;
      return rdma_status::success();
    end
    case (decoded_contract_fault)
      RDMA_CMQ_TEST_DECODED_ZERO_NONOK: begin
        decoded.hardware_ecode = '0;
        decoded.command_status.code = RDMA_SC_INVALID_STATE;
        decoded.command_status.category =
          rdma_status::category_for(decoded.command_status.code);
        decoded.command_status.hardware_code = '0;
        decoded.command_status.hardware_code_valid = 1'b0;
        decoded.command_status.severity = RDMA_SEVERITY_INFO;
      end
      RDMA_CMQ_TEST_DECODED_ZERO_HARDWARE_VALID: begin
        decoded.hardware_ecode = '0;
        decoded.command_status.code = RDMA_SC_OK;
        decoded.command_status.category =
          rdma_status::category_for(decoded.command_status.code);
        decoded.command_status.hardware_code = 32'h1;
        decoded.command_status.hardware_code_valid = 1'b1;
        decoded.command_status.severity = RDMA_SEVERITY_INFO;
      end
      RDMA_CMQ_TEST_DECODED_NONZERO_OK: begin
        decoded.hardware_ecode = 32'h1;
        decoded.command_status.code = RDMA_SC_OK;
        decoded.command_status.category =
          rdma_status::category_for(decoded.command_status.code);
        decoded.command_status.hardware_code = decoded.hardware_ecode;
        decoded.command_status.hardware_code_valid = 1'b1;
        decoded.command_status.severity = RDMA_SEVERITY_ERROR;
      end
      RDMA_CMQ_TEST_DECODED_NONZERO_HARDWARE_INVALID: begin
        decoded.hardware_ecode = 32'h1;
        decoded.command_status.hardware_code = decoded.hardware_ecode;
        decoded.command_status.hardware_code_valid = 1'b0;
      end
      RDMA_CMQ_TEST_DECODED_HARDWARE_MISMATCH: begin
        decoded.hardware_ecode = 32'h1;
        decoded.command_status.hardware_code = 32'h2;
        decoded.command_status.hardware_code_valid = 1'b1;
      end
      RDMA_CMQ_TEST_DECODED_CATEGORY_MISMATCH: begin
        decoded.hardware_ecode = 32'h1;
        decoded.command_status.category =
          (rdma_status::category_for(decoded.command_status.code) ==
             RDMA_STATUS_STATE) ?
          RDMA_STATUS_CONFIGURATION : RDMA_STATUS_STATE;
      end
      RDMA_CMQ_TEST_DECODED_SEVERITY_MISMATCH: begin
        decoded.hardware_ecode = 32'h1;
        decoded.command_status.severity = RDMA_SEVERITY_INFO;
      end
      RDMA_CMQ_TEST_DECODED_NONZERO_WARNING: begin
        decoded.command_status.severity = RDMA_SEVERITY_WARNING;
      end
      RDMA_CMQ_TEST_DECODED_NONZERO_FATAL: begin
        decoded.command_status.severity = RDMA_SEVERITY_FATAL;
      end
      default: begin
      end
    endcase
    if (use_self_clone_completion_payload) begin
      hostile_payload =
        rdma_cmq_self_clone_completion_payload::type_id::create(
          "retained_self_clone_completion_payload"
        );
      hostile_payload.value = completion.object_payload.size();
      hostile_payload.nested_h = rdma_handle::type_id::create(
        "retained_self_clone_completion_payload_handle"
      );
      hostile_payload.nested_h.kind = RDMA_RESOURCE_CQ;
      hostile_payload.nested_h.function_uid = 64'h1234_5678_90ab_cdef;
      hostile_payload.nested_h.object_id = 32'h1357_2468;
      hostile_payload.nested_h.generation = raw_cqe.function_generation;
      decoded.response_payload = hostile_payload;
      last_completion_payload_source = hostile_payload;
    end
    else begin
      decoded.response_payload = payload;
      last_completion_payload_source = null;
    end
    status = decoded.validate();
    if (!status.ok()) begin
      decoded = null;
      ready = 1'b0;
      return status;
    end
    if (mutate_raw_cqe_input && raw_cqe.bytes.size() > 1)
      raw_cqe.bytes[1] ^= 8'hff;
    return rdma_status::success();
  endfunction

  virtual function rdma_status snapshot_completion_payload(
    uvm_object source,
    output uvm_object snapshot
  );
    rdma_cmq_self_clone_completion_payload source_hostile;
    rdma_cmq_self_clone_completion_payload snapshot_hostile;
    rdma_xtr_v1_cmq_completion source_xtr;
    rdma_xtr_v1_cmq_completion snapshot_xtr;

    snapshot = null;
    case (completion_payload_hook_fault)
      RDMA_CMQ_TEST_HOOK_NULL_STATUS: return null;
      RDMA_CMQ_TEST_HOOK_NONOK_STATUS:
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "injected completion payload snapshot rejection"
        );
      RDMA_CMQ_TEST_HOOK_NULL_OUTPUT: return rdma_status::success();
      RDMA_CMQ_TEST_HOOK_WRONG_TYPE: begin
        snapshot = rdma_status::success("wrong completion payload type");
        return rdma_status::success();
      end
      RDMA_CMQ_TEST_HOOK_SELF_OUTPUT: begin
        snapshot = source;
        return rdma_status::success();
      end
      default: begin
      end
    endcase
    if ($cast(source_hostile, source)) begin
      snapshot_hostile =
        rdma_cmq_self_clone_completion_payload::type_id::create(
          "explicit_completion_payload_snapshot"
        );
      snapshot_hostile.value = source_hostile.value;
      if (source_hostile.nested_h != null) begin
        snapshot_hostile.nested_h = rdma_handle::type_id::create(
          "explicit_completion_payload_handle_snapshot"
        );
        snapshot_hostile.nested_h.kind = source_hostile.nested_h.kind;
        snapshot_hostile.nested_h.function_uid =
          source_hostile.nested_h.function_uid;
        snapshot_hostile.nested_h.object_id = source_hostile.nested_h.object_id;
        snapshot_hostile.nested_h.generation =
          source_hostile.nested_h.generation;
      end
      case (completion_payload_hook_fault)
        RDMA_CMQ_TEST_HOOK_MUTATED_OUTPUT: snapshot_hostile.value++;
        RDMA_CMQ_TEST_HOOK_ALIASED_OUTPUT:
          snapshot_hostile.nested_h = source_hostile.nested_h;
        RDMA_CMQ_TEST_HOOK_MUTATE_SOURCE: source_hostile.value++;
        default: begin
        end
      endcase
      snapshot = snapshot_hostile;
      return rdma_status::success();
    end
    if ($cast(source_xtr, source)) begin
      snapshot_xtr = rdma_xtr_v1_cmq_completion::type_id::create(
        "explicit_xtr_completion_payload_snapshot"
      );
      snapshot_xtr.owner = source_xtr.owner;
      snapshot_xtr.opcode = source_xtr.opcode;
      snapshot_xtr.command_ecode = source_xtr.command_ecode;
      snapshot_xtr.wqe_index = source_xtr.wqe_index;
      snapshot_xtr.wrap = source_xtr.wrap;
      snapshot_xtr.object_payload = source_xtr.object_payload;
      case (completion_payload_hook_fault)
        RDMA_CMQ_TEST_HOOK_MUTATED_OUTPUT: snapshot_xtr.opcode++;
        RDMA_CMQ_TEST_HOOK_MUTATE_SOURCE: source_xtr.opcode++;
        default: begin
        end
      endcase
      snapshot = snapshot_xtr;
      return rdma_status::success();
    end
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      "test profile completion payload type is unsupported"
    );
  endfunction

  virtual function bit same_completion_payload_value(
    uvm_object lhs,
    uvm_object rhs
  );
    rdma_cmq_self_clone_completion_payload lhs_hostile;
    rdma_cmq_self_clone_completion_payload rhs_hostile;
    rdma_xtr_v1_cmq_completion lhs_xtr;
    rdma_xtr_v1_cmq_completion rhs_xtr;

    completion_payload_same_calls++;
    if (completion_payload_hook_fault ==
          RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT &&
        completion_payload_same_calls > 1)
      return 1'b0;
    if ($cast(lhs_hostile, lhs) && $cast(rhs_hostile, rhs)) begin
      if (lhs_hostile.nested_h == null || rhs_hostile.nested_h == null)
        return 1'b0;
      return lhs_hostile.value == rhs_hostile.value &&
             lhs_hostile.nested_h.same_instance(rhs_hostile.nested_h);
    end
    if ($cast(lhs_xtr, lhs) && $cast(rhs_xtr, rhs)) begin
      if (lhs_xtr.object_payload.size() != rhs_xtr.object_payload.size())
        return 1'b0;
      foreach (lhs_xtr.object_payload[i])
        if (lhs_xtr.object_payload[i] != rhs_xtr.object_payload[i])
          return 1'b0;
      return lhs_xtr.owner == rhs_xtr.owner &&
             lhs_xtr.opcode == rhs_xtr.opcode &&
             lhs_xtr.command_ecode == rhs_xtr.command_ecode &&
             lhs_xtr.wqe_index == rhs_xtr.wqe_index &&
             lhs_xtr.wrap == rhs_xtr.wrap;
    end
    return 1'b0;
  endfunction

  virtual function bit completion_payload_graph_detached(
    uvm_object source,
    uvm_object snapshot
  );
    rdma_cmq_self_clone_completion_payload source_hostile;
    rdma_cmq_self_clone_completion_payload snapshot_hostile;
    rdma_xtr_v1_cmq_completion source_xtr;
    rdma_xtr_v1_cmq_completion snapshot_xtr;

    completion_payload_detach_calls++;
    if (completion_payload_hook_fault ==
          RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT &&
        completion_payload_detach_calls > 1)
      return 1'b0;
    if ($cast(source_hostile, source) &&
        $cast(snapshot_hostile, snapshot))
      return source_hostile != snapshot_hostile &&
             source_hostile.nested_h != null &&
             snapshot_hostile.nested_h != null &&
             source_hostile.nested_h != snapshot_hostile.nested_h;
    if ($cast(source_xtr, source) && $cast(snapshot_xtr, snapshot))
      return source_xtr != snapshot_xtr;
    return 1'b0;
  endfunction

  virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
    byte unsigned payload[8];
    rdma_cmq_clone_fault_image clone_fault_image;

    image = null;
    doorbell_calls++;
    last_final_pi = final_pi;
    last_polarity = polarity;
    last_doorbell_input = cmq_h;
    last_doorbell_target = rdma_clone_handle_value(
      cmq_h, "test profile doorbell target"
    );
    if (doorbell_input_fault != RDMA_CMQ_TEST_DB_INPUT_GOOD) begin
      cmq_h.object_id++;
      case (doorbell_input_fault)
        RDMA_CMQ_TEST_DB_INPUT_MUTATE_FAILURE:
          return rdma_status::make(
            RDMA_SC_CODEC_ERROR,
            "injected mutating doorbell encode failure"
          );
        RDMA_CMQ_TEST_DB_INPUT_MUTATE_NULL: return null;
        default: begin
        end
      endcase
    end
    if (fail_doorbell_encode)
      return rdma_status::make(doorbell_failure_code,
                               "injected doorbell encode failure");
    if (doorbell_fault == RDMA_CMQ_TEST_DB_NULL)
      return rdma_status::success();
    payload = '{byte'(final_pi), byte'(polarity),
                byte'(cmq_h.object_id[7:0]),
                byte'(cmq_h.object_id[15:8]),
                8'ha5, 8'h5a, 8'hc3, 8'h3c};
    image = rdma_hw_image::type_id::create("test_doorbell");
    foreach (payload[i]) image.bytes.push_back(payload[i]);
    image.length = $size(payload);
    image.alignment = 8;
    image.endian = RDMA_ENDIAN_LITTLE;
    image.image_kind = RDMA_IMAGE_DOORBELL;
    image.hardware_version = 9;
    image.function_generation = cmq_h.generation;
    image.write_target_kind = RDMA_HW_TARGET_BAR;
    image.bar_target.value = TEST_DOORBELL_OFFSET;
    case (doorbell_fault)
      RDMA_CMQ_TEST_DB_BAD_LENGTH: image.length = 7;
      RDMA_CMQ_TEST_DB_BAD_KIND: image.image_kind = RDMA_IMAGE_CMQ_SQE;
      RDMA_CMQ_TEST_DB_STALE_GENERATION:
        image.function_generation++;
      RDMA_CMQ_TEST_DB_BAD_TARGET_KIND:
        image.write_target_kind = RDMA_HW_TARGET_BACKING;
      RDMA_CMQ_TEST_DB_INACTIVE_BACKING:
        image.backing_target.value = 64'h40;
      RDMA_CMQ_TEST_DB_INACTIVE_HMC:
        image.hmc_target.value = 64'h80;
      RDMA_CMQ_TEST_DB_CLONE_SELF,
      RDMA_CMQ_TEST_DB_CLONE_MUTATE: begin
        clone_fault_image = rdma_cmq_clone_fault_image::type_id::create(
          "test_doorbell_clone_fault"
        );
        clone_fault_image.copy(image);
        clone_fault_image.clone_fault =
          (doorbell_fault == RDMA_CMQ_TEST_DB_CLONE_SELF) ?
            RDMA_CMQ_TEST_CLONE_SELF : RDMA_CMQ_TEST_CLONE_MUTATE;
        image = clone_fault_image;
      end
      default: begin
      end
    endcase
    return rdma_status::success();
  endfunction
endclass

class rdma_cmq_profile_hook_fault_profile extends rdma_cmq_test_profile;
  `uvm_object_utils(rdma_cmq_profile_hook_fault_profile)

  rdma_cmq_test_hook_fault_e snapshot_fault;
  rdma_cmq_test_extension_fault_e extension_fault;
  rdma_cmq_test_direct_handle_fault_e direct_handle_fault;
  int unsigned snapshot_calls;
  int unsigned same_calls;
  int unsigned detach_calls;

  function new(string name = "rdma_cmq_profile_hook_fault_profile");
    super.new(name);
    snapshot_fault = RDMA_CMQ_TEST_HOOK_GOOD;
    extension_fault = RDMA_CMQ_TEST_EXTENSION_GOOD;
    direct_handle_fault = RDMA_CMQ_TEST_DIRECT_HANDLE_GOOD;
    snapshot_calls = 0;
    same_calls = 0;
    detach_calls = 0;
  endfunction

  protected function rdma_handle copy_nested_handle(rdma_handle source);
    rdma_handle result;

    if (source == null)
      return null;
    result = rdma_handle::type_id::create("hook_snapshot_handle");
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return result;
  endfunction

  protected function rdma_function_handle copy_function_handle(
    rdma_function_handle source
  );
    rdma_function_handle result;

    if (source == null)
      return null;
    result = rdma_function_handle::type_id::create(
      "hook_snapshot_function_handle"
    );
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return result;
  endfunction

  protected function bit same_nested_handle_value(
    rdma_handle lhs,
    rdma_handle rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  protected function bit same_sqe_base_value(
    rdma_cmq_sqe_model lhs,
    rdma_cmq_sqe_model rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.opcode == rhs.opcode &&
           lhs.command_id == rhs.command_id &&
           lhs.flags == rhs.flags &&
           same_nested_handle_value(lhs.function_h, rhs.function_h) &&
           same_nested_handle_value(lhs.target_h, rhs.target_h) &&
           lhs.context_model == null && rhs.context_model == null;
  endfunction

  protected function void append_sqe_graph_nodes(
    rdma_cmq_sqe_model sqe,
    uvm_object extension_edge,
    ref uvm_object nodes[$]
  );
    if (sqe == null)
      return;
    nodes.push_back(sqe);
    if (sqe.function_h != null) nodes.push_back(sqe.function_h);
    if (sqe.target_h != null) nodes.push_back(sqe.target_h);
    if (sqe.context_model != null) nodes.push_back(sqe.context_model);
    if (extension_edge != null) nodes.push_back(extension_edge);
  endfunction

  protected function bit sqe_graphs_are_detached(
    rdma_cmq_sqe_model source,
    uvm_object source_extension_edge,
    rdma_cmq_sqe_model snapshot,
    uvm_object snapshot_extension_edge
  );
    uvm_object source_nodes[$];
    uvm_object snapshot_nodes[$];

    append_sqe_graph_nodes(source, source_extension_edge, source_nodes);
    append_sqe_graph_nodes(snapshot, snapshot_extension_edge,
                           snapshot_nodes);
    foreach (source_nodes[i])
      foreach (snapshot_nodes[j])
        if (source_nodes[i] == snapshot_nodes[j])
          return 1'b0;
    return source_nodes.size() != 0 && snapshot_nodes.size() != 0;
  endfunction

  protected function bit same_qpc_base_value(
    rdma_qpc_model lhs,
    rdma_qpc_model rhs
  );
    if (lhs == null || rhs == null ||
        lhs.address_vector == null || rhs.address_vector == null ||
        lhs.behavior == null || rhs.behavior == null ||
        lhs.transport_ext == null || rhs.transport_ext == null)
      return 1'b0;
    return same_nested_handle_value(lhs.qp_h, rhs.qp_h) &&
           same_nested_handle_value(lhs.pd_h, rhs.pd_h) &&
           same_nested_handle_value(lhs.send_cq_h, rhs.send_cq_h) &&
           same_nested_handle_value(lhs.recv_cq_h, rhs.recv_cq_h) &&
           same_nested_handle_value(lhs.srq_h, rhs.srq_h) &&
           lhs.transport == rhs.transport && lhs.state == rhs.state &&
           lhs.host_id == rhs.host_id && lhs.vf_id == rhs.vf_id &&
           lhs.stat_index == rhs.stat_index && lhs.pkey == rhs.pkey &&
           lhs.qp_sequence == rhs.qp_sequence &&
           lhs.access == rhs.access &&
           lhs.path_mtu_bytes == rhs.path_mtu_bytes &&
           lhs.sq_depth == rhs.sq_depth && lhs.rq_depth == rhs.rq_depth &&
           lhs.sq_backing.value == rhs.sq_backing.value &&
           lhs.rq_backing.value == rhs.rq_backing.value &&
           lhs.context_backing.value == rhs.context_backing.value &&
           lhs.sq_mode == rhs.sq_mode && lhs.rq_mode == rhs.rq_mode &&
           lhs.signature_enable == rhs.signature_enable &&
           lhs.tx_flow_control == rhs.tx_flow_control &&
           lhs.rx_flow_control == rhs.rx_flow_control &&
           lhs.address_vector.describe() == rhs.address_vector.describe() &&
           lhs.behavior.describe() == rhs.behavior.describe() &&
           lhs.transport_ext.get_type_name() ==
             rhs.transport_ext.get_type_name() &&
           lhs.transport_ext.describe() == rhs.transport_ext.describe();
  endfunction

  protected function void append_qpc_graph_nodes(
    rdma_qpc_model qpc,
    uvm_object extension_edge,
    ref uvm_object nodes[$]
  );
    rdma_qpc_urc_ext urc_ext;

    if (qpc == null)
      return;
    nodes.push_back(qpc);
    if (qpc.qp_h != null) nodes.push_back(qpc.qp_h);
    if (qpc.pd_h != null) nodes.push_back(qpc.pd_h);
    if (qpc.send_cq_h != null) nodes.push_back(qpc.send_cq_h);
    if (qpc.recv_cq_h != null) nodes.push_back(qpc.recv_cq_h);
    if (qpc.srq_h != null) nodes.push_back(qpc.srq_h);
    if (qpc.address_vector != null) nodes.push_back(qpc.address_vector);
    if (qpc.behavior != null) nodes.push_back(qpc.behavior);
    if (qpc.transport_ext != null) nodes.push_back(qpc.transport_ext);
    if ($cast(urc_ext, qpc.transport_ext) && urc_ext.queues != null)
      nodes.push_back(urc_ext.queues);
    if (extension_edge != null) nodes.push_back(extension_edge);
  endfunction

  protected function bit qpc_graphs_are_detached(
    rdma_qpc_model source,
    uvm_object source_extension_edge,
    rdma_qpc_model snapshot,
    uvm_object snapshot_extension_edge
  );
    uvm_object source_nodes[$];
    uvm_object snapshot_nodes[$];

    append_qpc_graph_nodes(source, source_extension_edge, source_nodes);
    append_qpc_graph_nodes(snapshot, snapshot_extension_edge, snapshot_nodes);
    foreach (source_nodes[i])
      foreach (snapshot_nodes[j])
        if (source_nodes[i] == snapshot_nodes[j])
          return 1'b0;
    return source_nodes.size() != 0 && snapshot_nodes.size() != 0;
  endfunction

  virtual function rdma_status snapshot_command_body(
    rdma_hw_model source,
    output rdma_hw_model snapshot
  );
    rdma_cmq_profile_hook_body source_body;
    rdma_cmq_profile_hook_body snapshot_body;
    rdma_cmq_scalar_extension_qpc source_scalar;
    rdma_cmq_scalar_extension_qpc snapshot_scalar;
    rdma_cmq_edge_extension_qpc source_edge;
    rdma_cmq_edge_extension_qpc snapshot_edge;
    rdma_cmq_sqe_model source_sqe;
    rdma_cmq_sqe_model snapshot_sqe;
    rdma_cmq_scalar_extension_function_handle source_scalar_handle;
    rdma_cmq_scalar_extension_function_handle snapshot_scalar_handle;
    rdma_cmq_edge_extension_handle source_edge_handle;
    rdma_cmq_edge_extension_handle snapshot_edge_handle;
    uvm_object cloned_object;

    snapshot = null;
    if ($cast(source_sqe, source) &&
        ($cast(source_scalar_handle, source_sqe.function_h) ||
         $cast(source_edge_handle, source_sqe.target_h))) begin
      snapshot_calls++;
      snapshot_sqe = rdma_cmq_sqe_model::type_id::create(
        "profile_direct_handle_sqe_snapshot"
      );
      snapshot_sqe.opcode = source_sqe.opcode;
      snapshot_sqe.command_id = source_sqe.command_id;
      snapshot_sqe.flags = source_sqe.flags;
      if (source_scalar_handle != null) begin
        snapshot_scalar_handle =
          rdma_cmq_scalar_extension_function_handle::type_id::create(
            "profile_scalar_function_snapshot"
          );
        snapshot_scalar_handle.kind = source_scalar_handle.kind;
        snapshot_scalar_handle.function_uid =
          source_scalar_handle.function_uid;
        snapshot_scalar_handle.object_id = source_scalar_handle.object_id;
        snapshot_scalar_handle.generation = source_scalar_handle.generation;
        snapshot_scalar_handle.extension_value =
          source_scalar_handle.extension_value;
        if (direct_handle_fault == RDMA_CMQ_TEST_DIRECT_HANDLE_DROP_SCALAR)
          snapshot_scalar_handle.extension_value = 0;
        snapshot_sqe.function_h = snapshot_scalar_handle;
      end
      else begin
        snapshot_sqe.function_h = copy_function_handle(
          source_sqe.function_h
        );
      end
      if (source_edge_handle != null) begin
        snapshot_edge_handle =
          rdma_cmq_edge_extension_handle::type_id::create(
            "profile_edge_target_snapshot"
          );
        snapshot_edge_handle.kind = source_edge_handle.kind;
        snapshot_edge_handle.function_uid = source_edge_handle.function_uid;
        snapshot_edge_handle.object_id = source_edge_handle.object_id;
        snapshot_edge_handle.generation = source_edge_handle.generation;
        snapshot_edge_handle.extension_h = copy_nested_handle(
          source_edge_handle.extension_h
        );
        if (direct_handle_fault == RDMA_CMQ_TEST_DIRECT_HANDLE_ALIAS_EDGE)
          snapshot_edge_handle.extension_h = source_edge_handle.extension_h;
        snapshot_sqe.target_h = snapshot_edge_handle;
      end
      else begin
        snapshot_sqe.target_h = copy_nested_handle(source_sqe.target_h);
      end
      snapshot_sqe.context_model = null;
      snapshot = snapshot_sqe;
      return rdma_status::success();
    end
    if ($cast(source_scalar, source)) begin
      snapshot_calls++;
      if (extension_fault == RDMA_CMQ_TEST_EXTENSION_NULL_OUTPUT)
        return rdma_status::success();
      snapshot_scalar = rdma_cmq_scalar_extension_qpc::type_id::create(
        "profile_scalar_extension_snapshot"
      );
      snapshot_scalar.copy(source_scalar);
      snapshot_scalar.extension_value = source_scalar.extension_value;
      case (extension_fault)
        RDMA_CMQ_TEST_EXTENSION_DROP_SCALAR:
          snapshot_scalar.extension_value = 0;
        RDMA_CMQ_TEST_EXTENSION_MUTATE_SOURCE:
          source_scalar.extension_value++;
        default: begin
        end
      endcase
      snapshot = snapshot_scalar;
      return rdma_status::success();
    end
    if ($cast(source_edge, source)) begin
      snapshot_calls++;
      if (extension_fault == RDMA_CMQ_TEST_EXTENSION_NULL_OUTPUT)
        return rdma_status::success();
      snapshot_edge = rdma_cmq_edge_extension_qpc::type_id::create(
        "profile_edge_extension_snapshot"
      );
      snapshot_edge.copy(source_edge);
      snapshot_edge.extension_h = copy_nested_handle(source_edge.extension_h);
      if (extension_fault == RDMA_CMQ_TEST_EXTENSION_ALIAS_EDGE)
        snapshot_edge.extension_h = source_edge.extension_h;
      snapshot = snapshot_edge;
      return rdma_status::success();
    end
    if (!$cast(source_body, source))
      return super.snapshot_command_body(source, snapshot);
    snapshot_calls++;
    if (snapshot_fault inside {
          RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT,
          RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT
        }) begin
      cloned_object = source.clone();
      if (cloned_object == null || !$cast(snapshot_body, cloned_object) ||
          snapshot_body == source_body) begin
        snapshot = null;
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "injected stateful custom body preflight clone failed"
        );
      end
      snapshot = snapshot_body;
      return rdma_status::success();
    end
    case (snapshot_fault)
      RDMA_CMQ_TEST_HOOK_NULL_STATUS:
        return null;
      RDMA_CMQ_TEST_HOOK_NONOK_STATUS:
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "injected ordinary custom body snapshot rejection"
        );
      RDMA_CMQ_TEST_HOOK_NULL_OUTPUT:
        return rdma_status::success();
      RDMA_CMQ_TEST_HOOK_WRONG_TYPE: begin
        snapshot = rdma_cmq_unknown_body::type_id::create(
          "hook_wrong_type_output"
        );
        return rdma_status::success();
      end
      RDMA_CMQ_TEST_HOOK_SELF_OUTPUT: begin
        snapshot = source;
        return rdma_status::success();
      end
      default: begin
        snapshot_body = rdma_cmq_profile_hook_body::type_id::create(
          "hook_snapshot_output"
        );
        snapshot_body.value = source_body.value;
        snapshot_body.nested_h = copy_nested_handle(source_body.nested_h);
        case (snapshot_fault)
          RDMA_CMQ_TEST_HOOK_MUTATED_OUTPUT:
            snapshot_body.value++;
          RDMA_CMQ_TEST_HOOK_ALIASED_OUTPUT:
            snapshot_body.nested_h = source_body.nested_h;
          RDMA_CMQ_TEST_HOOK_NULL_VALIDATION:
            snapshot_body.validation_returns_null = 1'b1;
          RDMA_CMQ_TEST_HOOK_FAILED_VALIDATION:
            snapshot_body.validation_fails = 1'b1;
          default: begin
          end
        endcase
        snapshot = snapshot_body;
        return rdma_status::success();
      end
    endcase
  endfunction

  virtual function bit same_command_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    rdma_cmq_profile_hook_body lhs_body;
    rdma_cmq_profile_hook_body rhs_body;
    rdma_cmq_scalar_extension_qpc lhs_scalar;
    rdma_cmq_scalar_extension_qpc rhs_scalar;
    rdma_cmq_edge_extension_qpc lhs_edge;
    rdma_cmq_edge_extension_qpc rhs_edge;
    rdma_cmq_sqe_model lhs_sqe;
    rdma_cmq_sqe_model rhs_sqe;
    rdma_cmq_scalar_extension_function_handle lhs_scalar_handle;
    rdma_cmq_scalar_extension_function_handle rhs_scalar_handle;
    rdma_cmq_edge_extension_handle lhs_edge_handle;
    rdma_cmq_edge_extension_handle rhs_edge_handle;
    bit same_value;

    if ($cast(lhs_sqe, lhs) && $cast(rhs_sqe, rhs)) begin
      if ($cast(lhs_scalar_handle, lhs_sqe.function_h) &&
          $cast(rhs_scalar_handle, rhs_sqe.function_h)) begin
        same_calls++;
        same_value = same_sqe_base_value(lhs_sqe, rhs_sqe) &&
                     lhs_scalar_handle.extension_value ==
                       rhs_scalar_handle.extension_value;
        if (direct_handle_fault ==
              RDMA_CMQ_TEST_DIRECT_HANDLE_DROP_SCALAR &&
            same_calls == 1)
          return same_sqe_base_value(lhs_sqe, rhs_sqe);
        if (direct_handle_fault ==
              RDMA_CMQ_TEST_DIRECT_HANDLE_SAME_DRIFT &&
            same_calls > 1)
          return 1'b0;
        return same_value;
      end
      if ($cast(lhs_edge_handle, lhs_sqe.target_h) &&
          $cast(rhs_edge_handle, rhs_sqe.target_h)) begin
        same_calls++;
        same_value = same_sqe_base_value(lhs_sqe, rhs_sqe) &&
                     same_nested_handle_value(
                       lhs_edge_handle.extension_h,
                       rhs_edge_handle.extension_h
                     );
        return same_value;
      end
    end
    if ($cast(lhs_scalar, lhs) && $cast(rhs_scalar, rhs)) begin
      same_calls++;
      return same_qpc_base_value(lhs_scalar, rhs_scalar) &&
             lhs_scalar.extension_value == rhs_scalar.extension_value;
    end
    if ($cast(lhs_edge, lhs) && $cast(rhs_edge, rhs)) begin
      same_calls++;
      return same_qpc_base_value(lhs_edge, rhs_edge) &&
             same_nested_handle_value(lhs_edge.extension_h,
                                      rhs_edge.extension_h);
    end
    if (!$cast(lhs_body, lhs) || !$cast(rhs_body, rhs) ||
        lhs_body.nested_h == null || rhs_body.nested_h == null)
      return 1'b0;
    same_calls++;
    same_value = lhs_body.value == rhs_body.value &&
                 lhs_body.nested_h.kind == rhs_body.nested_h.kind &&
                 lhs_body.nested_h.function_uid ==
                   rhs_body.nested_h.function_uid &&
                 lhs_body.nested_h.object_id == rhs_body.nested_h.object_id &&
                 lhs_body.nested_h.generation == rhs_body.nested_h.generation;
    if (snapshot_fault == RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT &&
        same_calls > 1)
      return 1'b0;
    return same_value;
  endfunction

  virtual function bit command_body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    rdma_cmq_profile_hook_body source_body;
    rdma_cmq_profile_hook_body snapshot_body;
    rdma_cmq_scalar_extension_qpc source_scalar;
    rdma_cmq_scalar_extension_qpc snapshot_scalar;
    rdma_cmq_edge_extension_qpc source_edge;
    rdma_cmq_edge_extension_qpc snapshot_edge;
    rdma_cmq_sqe_model source_sqe;
    rdma_cmq_sqe_model snapshot_sqe;
    rdma_cmq_scalar_extension_function_handle source_scalar_handle;
    rdma_cmq_scalar_extension_function_handle snapshot_scalar_handle;
    rdma_cmq_edge_extension_handle source_edge_handle;
    rdma_cmq_edge_extension_handle snapshot_edge_handle;
    bit detached;

    if ($cast(source_sqe, source) && $cast(snapshot_sqe, snapshot)) begin
      if ($cast(source_scalar_handle, source_sqe.function_h) &&
          $cast(snapshot_scalar_handle, snapshot_sqe.function_h)) begin
        detach_calls++;
        detached = sqe_graphs_are_detached(source_sqe, null,
                                           snapshot_sqe, null);
        if (direct_handle_fault ==
              RDMA_CMQ_TEST_DIRECT_HANDLE_DETACH_DRIFT &&
            detach_calls > 1)
          return 1'b0;
        return detached;
      end
      if ($cast(source_edge_handle, source_sqe.target_h) &&
          $cast(snapshot_edge_handle, snapshot_sqe.target_h)) begin
        detach_calls++;
        detached = sqe_graphs_are_detached(
          source_sqe, source_edge_handle.extension_h,
          snapshot_sqe, snapshot_edge_handle.extension_h
        );
        if (direct_handle_fault ==
              RDMA_CMQ_TEST_DIRECT_HANDLE_ALIAS_EDGE &&
            detach_calls == 1)
          return 1'b1;
        if (direct_handle_fault ==
              RDMA_CMQ_TEST_DIRECT_HANDLE_DETACH_DRIFT &&
            detach_calls > 1)
          return 1'b0;
        return detached;
      end
    end
    if ($cast(source_scalar, source) &&
        $cast(snapshot_scalar, snapshot)) begin
      detach_calls++;
      return qpc_graphs_are_detached(source_scalar, null,
                                     snapshot_scalar, null);
    end
    if ($cast(source_edge, source) && $cast(snapshot_edge, snapshot)) begin
      detach_calls++;
      return qpc_graphs_are_detached(
        source_edge, source_edge.extension_h,
        snapshot_edge, snapshot_edge.extension_h
      );
    end

    if (!$cast(source_body, source) || !$cast(snapshot_body, snapshot) ||
        source_body == snapshot_body || source_body.nested_h == null ||
        snapshot_body.nested_h == null)
      return 1'b0;
    detach_calls++;
    if (snapshot_fault == RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT &&
        detach_calls > 1)
      return 1'b0;
    return source_body.nested_h != snapshot_body.nested_h;
  endfunction
endclass

class rdma_cmq_test_pcie extends rdma_mock_pcie;
  `uvm_object_utils(rdma_cmq_test_pcie)

  function new(string name = "rdma_cmq_test_pcie");
    super.new(name);
  endfunction

  virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    rdma_mock_call_trace saved_trace;

    saved_trace = call_trace;
    call_trace = null;
    void'(record_call("dma_visibility_barrier", '0, '0, '0, '0,
                      function_h));
    call_trace = saved_trace;
    if (call_trace != null)
      call_trace.record("pcie_dma_barrier");
    status = take_failure("dma_visibility_barrier");
    if (status == null)
      status = rdma_status::success();
  endtask

  virtual task mmio_ordering_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    rdma_mock_call_trace saved_trace;

    saved_trace = call_trace;
    call_trace = null;
    void'(record_call("mmio_ordering_barrier", '0, '0, '0, '0,
                      function_h));
    call_trace = saved_trace;
    if (call_trace != null)
      call_trace.record("pcie_mmio_barrier");
    status = take_failure("mmio_ordering_barrier");
    if (status == null)
      status = rdma_status::success();
  endtask
endclass

class rdma_cmq_test_blocking_pcie extends rdma_cmq_test_pcie;
  `uvm_object_utils(rdma_cmq_test_blocking_pcie)

  bit block_dma_barrier;
  bit dma_barrier_entered;
  bit release_dma_barrier;

  function new(string name = "rdma_cmq_test_blocking_pcie");
    super.new(name);
    block_dma_barrier = 1'b0;
    dma_barrier_entered = 1'b0;
    release_dma_barrier = 1'b0;
  endfunction

  virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    rdma_mock_call_trace saved_trace;

    saved_trace = call_trace;
    call_trace = null;
    void'(record_call("dma_visibility_barrier", '0, '0, '0, '0,
                      function_h));
    call_trace = saved_trace;
    if (call_trace != null)
      call_trace.record("pcie_dma_barrier");
    status = take_failure("dma_visibility_barrier");
    if (status != null)
      return;
    if (block_dma_barrier) begin
      dma_barrier_entered = 1'b1;
      wait (release_dma_barrier);
    end
    status = rdma_status::success();
  endtask
endclass

class rdma_cmq_bad_clone_command extends rdma_cmq_command_desc;
  `uvm_object_utils(rdma_cmq_bad_clone_command)

  bit return_wrong_type;
  bit return_self;

  function new(string name = "rdma_cmq_bad_clone_command");
    super.new(name);
    return_wrong_type = 1'b0;
    return_self = 1'b0;
  endfunction

  virtual function uvm_object clone();
    if (return_wrong_type)
      return rdma_status::success("wrong command clone type");
    if (return_self)
      return this;
    return null;
  endfunction
endclass

class rdma_cmq_runtime_clone_failure_engine extends rdma_cmq_engine;
  `uvm_object_utils(rdma_cmq_runtime_clone_failure_engine)

  function new(string name = "rdma_cmq_runtime_clone_failure_engine");
    super.new(name);
  endfunction

  virtual function rdma_status publish_runtime_snapshot(
    rdma_cmq_runtime_desc source,
    output rdma_cmq_runtime_desc snapshot
  );
    snapshot = null;
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "injected runtime descriptor clone failure");
  endfunction
endclass

class rdma_cmq_runtime_build_failure_engine extends rdma_cmq_engine;
  `uvm_object_utils(rdma_cmq_runtime_build_failure_engine)

  bit return_null_status;

  function new(string name = "rdma_cmq_runtime_build_failure_engine");
    super.new(name);
    return_null_status = 1'b0;
  endfunction

  virtual function rdma_status build_runtime_desc(
    rdma_dma_request_context request_context,
    rdma_cmq cmq,
    rdma_dma_mapping mapping,
    output rdma_cmq_runtime_desc runtime
  );
    runtime = null;
    if (return_null_status)
      return null;
    return rdma_status::make(RDMA_SC_CODEC_ERROR,
                             "injected runtime construction failure");
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_TAMPER_FUNCTION_KIND,
  RDMA_CMQ_TAMPER_FUNCTION_UID,
  RDMA_CMQ_TAMPER_FUNCTION_OBJECT,
  RDMA_CMQ_TAMPER_FUNCTION_GENERATION,
  RDMA_CMQ_TAMPER_BDF,
  RDMA_CMQ_TAMPER_PASID_VALID,
  RDMA_CMQ_TAMPER_PASID,
  RDMA_CMQ_TAMPER_OWNER_NULL,
  RDMA_CMQ_TAMPER_OWNER_KIND,
  RDMA_CMQ_TAMPER_OWNER_UID,
  RDMA_CMQ_TAMPER_OWNER_OBJECT,
  RDMA_CMQ_TAMPER_OWNER_GENERATION,
  RDMA_CMQ_TAMPER_DIRECTION,
  RDMA_CMQ_TAMPER_STATE,
  RDMA_CMQ_TAMPER_SIZE,
  RDMA_CMQ_TAMPER_PERMISSION_READ,
  RDMA_CMQ_TAMPER_PERMISSION_WRITE,
  RDMA_CMQ_TAMPER_IOVA_ALIGNMENT,
  RDMA_CMQ_TAMPER_BACKING_ALIGNMENT,
  RDMA_CMQ_TAMPER_IOVA_RANGE,
  RDMA_CMQ_TAMPER_BACKING_RANGE,
  RDMA_CMQ_TAMPER_PERMISSION_ATOMIC,
  RDMA_CMQ_TAMPER_COUNT
} rdma_cmq_mapping_tamper_e;

class rdma_cmq_engine_probe extends rdma_cmq_engine;
  `uvm_object_utils(rdma_cmq_engine_probe)

  function new(string name = "rdma_cmq_engine_probe");
    super.new(name);
  endfunction

  function void restore_mapping(rdma_dma_mapping source);
    if (backing_mapping != null && source != null)
      backing_mapping.copy(source);
  endfunction

  function void seed_runtime_counters();
    publish_seq = 11;
    retire_seq = 7;
    cq_consume_seq = 5;
  endfunction

  function void seed_ring_counters(
    longint unsigned seeded_publish_seq,
    longint unsigned seeded_retire_seq
  );
    publish_seq = seeded_publish_seq;
    retire_seq = seeded_retire_seq;
  endfunction

  function int unsigned tokens_in_use_count();
    int unsigned count;

    count = 0;
    foreach (token_in_use[i])
      if (token_in_use[i])
        count++;
    return count;
  endfunction

  function int unsigned slot_record_count();
    int unsigned count;

    count = 0;
    foreach (slots[i])
      if (slots[i] != null)
        count++;
    return count;
  endfunction

  function int unsigned command_registry_count();
    return command_registry.num();
  endfunction

  function int unsigned entry_registry_count();
    return entry_registry.num();
  endfunction

  function int unsigned terminal_fifo_count();
    return terminal_fifo.size();
  endfunction

  function int unsigned diagnostic_fifo_count();
    return diagnostic_fifo.size();
  endfunction

  function rdma_cmq_slot_state_e slot_state_at(int unsigned sq_index);
    if (sq_index >= 32 || slots[sq_index] == null)
      return CMQ_SLOT_FREE;
    return slots[sq_index].state;
  endfunction

  function bit install_slot_ticket_function_clone_fault(
    int unsigned sq_index,
    rdma_cmq_test_clone_fault_e clone_fault
  );
    rdma_function_handle source;
    rdma_cmq_clone_fault_function_handle fault_function;

    if (sq_index >= 32 || slots[sq_index] == null ||
        slots[sq_index].ticket == null ||
        slots[sq_index].ticket.function_h == null)
      return 1'b0;
    source = slots[sq_index].ticket.function_h;
    fault_function = rdma_cmq_clone_fault_function_handle::type_id::create(
      $sformatf("timeout_fault_function_%0d", sq_index)
    );
    if (fault_function == null)
      return 1'b0;
    fault_function.kind = source.kind;
    fault_function.function_uid = source.function_uid;
    fault_function.object_id = source.object_id;
    fault_function.generation = source.generation;
    fault_function.clone_fault = clone_fault;
    slots[sq_index].ticket.function_h = fault_function;
    return 1'b1;
  endfunction

  function bit set_slot_ticket_function_clone_fault(
    int unsigned sq_index,
    rdma_cmq_test_clone_fault_e clone_fault
  );
    rdma_cmq_clone_fault_function_handle fault_function;

    if (sq_index >= 32 || slots[sq_index] == null ||
        slots[sq_index].ticket == null ||
        !$cast(fault_function, slots[sq_index].ticket.function_h))
      return 1'b0;
    fault_function.clone_fault = clone_fault;
    return 1'b1;
  endfunction

  function bit token_in_use_at(int unsigned token_index);
    if (token_index >= 32)
      return 1'b0;
    return token_in_use[token_index];
  endfunction

  function bit [58:0] token_incarnation_at(int unsigned token_index);
    if (token_index >= 32)
      return '0;
    return token_incarnation[token_index];
  endfunction

  function void seed_token_incarnation(
    int unsigned token_index,
    bit [58:0] incarnation
  );
    if (token_index < 32)
      token_incarnation[token_index] = incarnation;
  endfunction

  function void seed_all_token_incarnations(bit [58:0] incarnation);
    foreach (token_incarnation[i])
      token_incarnation[i] = incarnation;
  endfunction

  function void seed_terminal_completion(rdma_cmq_completion completion);
    terminal_fifo.push_back(completion);
  endfunction

  function void tamper_empty_ledger(
    rdma_cmq_test_empty_ledger_fault_e fault
  );
    rdma_cmq_slot_record stray_record;

    case (fault)
      RDMA_CMQ_TEST_EMPTY_LEDGER_COUNTER: cq_consume_seq++;
      RDMA_CMQ_TEST_EMPTY_LEDGER_SLOT: begin
        stray_record = rdma_cmq_slot_record::type_id::create(
          "empty_ledger_stray_slot"
        );
        slots[0] = stray_record;
      end
      RDMA_CMQ_TEST_EMPTY_LEDGER_TOKEN: token_in_use[0] = 1'b1;
      RDMA_CMQ_TEST_EMPTY_LEDGER_REGISTRY: begin
        stray_record = rdma_cmq_slot_record::type_id::create(
          "empty_ledger_stray_registry"
        );
        command_registry["empty_ledger_stray"] = stray_record;
        entry_registry["empty_ledger_stray"] = stray_record;
      end
      default: begin
      end
    endcase
  endfunction

  function bit tamper_slot_incarnation(int unsigned sq_index);
    if (sq_index >= 32 || slots[sq_index] == null)
      return 1'b0;
    slots[sq_index].slot_sequence++;
    return 1'b1;
  endfunction

  function bit tamper_slot_retirement_incarnation(int unsigned sq_index);
    rdma_cmq_slot_record record;
    string old_entry_key;

    if (sq_index >= 32 || slots[sq_index] == null ||
        slots[sq_index].ticket == null)
      return 1'b0;
    record = slots[sq_index];
    old_entry_key = entry_key(record.sq_index, record.sq_wrap);
    if (!entry_registry.exists(old_entry_key) ||
        entry_registry[old_entry_key] != record)
      return 1'b0;
    entry_registry.delete(old_entry_key);
    record.slot_sequence += 32;
    record.sq_wrap = !record.sq_wrap;
    record.ticket.slot_sequence += 32;
    record.ticket.sq_wrap = record.sq_wrap;
    entry_registry[entry_key(record.sq_index, record.sq_wrap)] = record;
    return 1'b1;
  endfunction

  function string slot_expected_variant(int unsigned sq_index);
    if (sq_index >= 32 || slots[sq_index] == null ||
        slots[sq_index].expected == null)
      return "";
    return slots[sq_index].expected.variant;
  endfunction

  function bit probe_same_handle(rdma_handle lhs, rdma_handle rhs);
    return same_handle(lhs, rhs);
  endfunction

  function bit probe_same_opcode(
    rdma_cmq_opcode_key lhs,
    rdma_cmq_opcode_key rhs
  );
    return same_opcode_value(lhs, rhs);
  endfunction

  function bit probe_same_image(rdma_hw_image lhs, rdma_hw_image rhs);
    return same_image_value(lhs, rhs);
  endfunction

  function string probe_body_value_key(rdma_hw_model body);
    return body_value_key(body);
  endfunction

  function bit probe_authority_handle_matches(rdma_handle expected);
    return cmq_snapshot != null && cmq_snapshot.handle != null &&
           same_handle(cmq_snapshot.handle, expected);
  endfunction

  function bit probe_is_authority_handle(rdma_handle candidate);
    return candidate != null && cmq_snapshot != null &&
           candidate == cmq_snapshot.handle;
  endfunction

  function longint unsigned slot_ticket_command_id(int unsigned sq_index);
    if (sq_index >= 32 || slots[sq_index] == null ||
        slots[sq_index].ticket == null)
      return 0;
    return slots[sq_index].ticket.command_id;
  endfunction

  function bit retry_only_poisoned();
    return engine_state == RDMA_CMQ_ENGINE_POISONED &&
           host_mem != null && backing_mapping != null &&
           prepared_binding == null && dma_context == null &&
           cmq_snapshot == null && scheduler == null && profile == null &&
           publish_seq == 0 && retire_seq == 0 && cq_consume_seq == 0;
  endfunction

  function void drop_host_mem_authority();
    host_mem = null;
  endfunction

  function void restore_host_mem_authority(rdma_host_mem_api source);
    host_mem = source;
  endfunction

  function bit missing_host_mem_poisoned();
    return engine_state == RDMA_CMQ_ENGINE_POISONED &&
           host_mem == null && backing_mapping != null &&
           prepared_binding == null && dma_context == null &&
           cmq_snapshot == null && scheduler == null && profile == null &&
           publish_seq == 0 && retire_seq == 0 && cq_consume_seq == 0;
  endfunction

  function void tamper_mapping(rdma_cmq_mapping_tamper_e kind);
    if (backing_mapping == null)
      return;
    case (kind)
      RDMA_CMQ_TAMPER_FUNCTION_KIND:
        backing_mapping.function_h.kind = RDMA_RESOURCE_QP;
      RDMA_CMQ_TAMPER_FUNCTION_UID:
        backing_mapping.function_h.function_uid++;
      RDMA_CMQ_TAMPER_FUNCTION_OBJECT:
        backing_mapping.function_h.object_id++;
      RDMA_CMQ_TAMPER_FUNCTION_GENERATION:
        backing_mapping.function_h.generation++;
      RDMA_CMQ_TAMPER_BDF:
        backing_mapping.requester_bdf.bus++;
      RDMA_CMQ_TAMPER_PASID_VALID:
        backing_mapping.pasid_valid = !backing_mapping.pasid_valid;
      RDMA_CMQ_TAMPER_PASID:
        backing_mapping.pasid++;
      RDMA_CMQ_TAMPER_OWNER_NULL:
        backing_mapping.owner_h = null;
      RDMA_CMQ_TAMPER_OWNER_KIND:
        backing_mapping.owner_h.kind = RDMA_RESOURCE_CQ;
      RDMA_CMQ_TAMPER_OWNER_UID:
        backing_mapping.owner_h.function_uid++;
      RDMA_CMQ_TAMPER_OWNER_OBJECT:
        backing_mapping.owner_h.object_id++;
      RDMA_CMQ_TAMPER_OWNER_GENERATION:
        backing_mapping.owner_h.generation++;
      RDMA_CMQ_TAMPER_DIRECTION:
        backing_mapping.direction = RDMA_DMA_DEVICE_READ;
      RDMA_CMQ_TAMPER_STATE:
        backing_mapping.state = RDMA_MAPPING_FROZEN;
      RDMA_CMQ_TAMPER_SIZE:
        backing_mapping.size--;
      RDMA_CMQ_TAMPER_PERMISSION_READ:
        backing_mapping.permissions.device_read = 1'b0;
      RDMA_CMQ_TAMPER_PERMISSION_WRITE:
        backing_mapping.permissions.device_write = 1'b0;
      RDMA_CMQ_TAMPER_IOVA_ALIGNMENT:
        backing_mapping.iova.value++;
      RDMA_CMQ_TAMPER_BACKING_ALIGNMENT:
        backing_mapping.backing_addr.value++;
      RDMA_CMQ_TAMPER_IOVA_RANGE:
        backing_mapping.iova.value = 64'hffff_ffff_ffff_f800;
      RDMA_CMQ_TAMPER_BACKING_RANGE:
        backing_mapping.backing_addr.value = 64'hffff_ffff_ffff_f800;
      RDMA_CMQ_TAMPER_PERMISSION_ATOMIC:
        backing_mapping.permissions.atomic = 1'b1;
      default: return;
    endcase
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_BAD_MAPPING_ATOMIC,
  RDMA_CMQ_BAD_MAPPING_IOVA_ALIGNMENT,
  RDMA_CMQ_BAD_MAPPING_BACKING_ALIGNMENT,
  RDMA_CMQ_BAD_MAPPING_IOVA_RANGE,
  RDMA_CMQ_BAD_MAPPING_BACKING_RANGE
} rdma_cmq_bad_mapping_kind_e;

class rdma_cmq_bad_mapping_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_bad_mapping_mem)

  rdma_cmq_bad_mapping_kind_e bad_kind;

  function new(string name = "rdma_cmq_bad_mapping_mem");
    super.new(name);
    bad_kind = RDMA_CMQ_BAD_MAPPING_ATOMIC;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    int region_index;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (!status.ok() || mapping == null)
      return status;
    region_index = regions.size() - 1;
    case (bad_kind)
      RDMA_CMQ_BAD_MAPPING_ATOMIC: begin
        mapping.permissions.atomic = 1'b1;
        regions[region_index].mapping.permissions.atomic = 1'b1;
      end
      RDMA_CMQ_BAD_MAPPING_IOVA_ALIGNMENT: begin
        mapping.iova.value++;
        regions[region_index].mapping.iova.value++;
      end
      RDMA_CMQ_BAD_MAPPING_BACKING_ALIGNMENT: begin
        mapping.backing_addr.value++;
        regions[region_index].mapping.backing_addr.value++;
      end
      RDMA_CMQ_BAD_MAPPING_IOVA_RANGE: begin
        mapping.iova.value = 64'hffff_ffff_ffff_f800;
        regions[region_index].mapping.iova.value = mapping.iova.value;
      end
      RDMA_CMQ_BAD_MAPPING_BACKING_RANGE: begin
        mapping.backing_addr.value = 64'hffff_ffff_ffff_f800;
        regions[region_index].mapping.backing_addr.value =
          mapping.backing_addr.value;
      end
    endcase
    return status;
  endfunction
endclass

class rdma_cmq_upper_boundary_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_upper_boundary_mem)

  function new(string name = "rdma_cmq_upper_boundary_mem");
    super.new(name);
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    int region_index;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (!status.ok() || mapping == null)
      return status;
    region_index = regions.size() - 1;
    mapping.iova.value = 64'hffff_ffff_ffff_f000;
    mapping.backing_addr.value = 64'hffff_ffff_ffff_f000;
    regions[region_index].mapping.iova = mapping.iova;
    regions[region_index].mapping.backing_addr = mapping.backing_addr;
    return status;
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE,
  RDMA_CMQ_ALLOCATE_NULL_WITH_CANDIDATE,
  RDMA_CMQ_ALLOCATE_FAILURE_WITH_CANDIDATE
} rdma_cmq_allocate_result_e;

class rdma_cmq_allocate_result_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_allocate_result_mem)

  rdma_cmq_allocate_result_e result_kind;

  function new(string name = "rdma_cmq_allocate_result_mem");
    super.new(name);
    result_kind = RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;

    if (result_kind == RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE) begin
      mapping = null;
      record_call("allocate", request_context, null, size, alignment,
                  direction);
      return null;
    end
    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (!status.ok() || mapping == null)
      return status;
    if (result_kind == RDMA_CMQ_ALLOCATE_NULL_WITH_CANDIDATE)
      return null;
    return rdma_status::make(
      RDMA_SC_RESOURCE_EXHAUSTED,
      "injected allocation failure with candidate"
    );
  endfunction
endclass

class rdma_cmq_null_write_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_null_write_mem)

  function new(string name = "rdma_cmq_null_write_mem");
    super.new(name);
  endfunction

  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    rdma_status status;

    status = super.write(mapping, offset, data);
    if (!status.ok())
      return status;
    return null;
  endfunction
endclass

class rdma_cmq_null_release_once_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_null_release_once_mem)

  bit return_null_once;

  function new(string name = "rdma_cmq_null_release_once_mem");
    super.new(name);
    return_null_once = 1'b1;
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    if (return_null_once) begin
      return_null_once = 1'b0;
      record_call("release", null, mapping);
      return null;
    end
    return super.\release (mapping);
  endfunction
endclass

class rdma_cmq_short_mapping_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_short_mapping_mem)

  function new(string name = "rdma_cmq_short_mapping_mem");
    super.new(name);
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (status.ok() && mapping != null) begin
      mapping.size = size - 1'b1;
      regions[regions.size() - 1].mapping.size = size - 1'b1;
    end
    return status;
  endfunction
endclass

class rdma_cmq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_engine_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h1234_5678_90ab_cdef;
  localparam int unsigned TEST_FUNCTION_ID = 32'h1020_3040;
  localparam int unsigned TEST_GENERATION = 32'd9;
  localparam int unsigned TEST_CMQ_ID = 32'h5566_7788;
  localparam longint unsigned TEST_CQ_OFFSET = 64'd2048;

  function new(string name = "rdma_cmq_engine_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void configure_submission_factory_faults();
    uvm_factory factory;

    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_cmq_slot_context::get_type(),
      rdma_cmq_failing_slot_context::get_type()
    );
    factory.set_type_override_by_type(
      rdma_cmq_ticket::get_type(), rdma_cmq_failing_ticket::get_type()
    );
    factory.set_type_override_by_type(
      rdma_cmq_slot_record::get_type(),
      rdma_cmq_failing_slot_record::get_type()
    );
    factory.set_type_override_by_type(
      rdma_doorbell_dependency::get_type(),
      rdma_cmq_failing_dependency::get_type()
    );
    factory.set_type_override_by_type(
      rdma_doorbell_desc::get_type(),
      rdma_cmq_failing_doorbell_desc::get_type()
    );
  endfunction

  function automatic void disarm_submission_factory_faults();
    rdma_cmq_failing_slot_context::disarm();
    rdma_cmq_failing_ticket::disarm();
    rdma_cmq_failing_slot_record::disarm();
    rdma_cmq_failing_dependency::disarm();
    rdma_cmq_failing_dependency::disarm_capture();
    rdma_cmq_failing_doorbell_desc::disarm();
  endfunction

  function automatic bit submission_factory_fault_armed();
    return rdma_cmq_failing_slot_context::armed() ||
           rdma_cmq_failing_ticket::armed() ||
           rdma_cmq_failing_slot_record::armed() ||
           rdma_cmq_failing_dependency::armed() ||
           rdma_cmq_failing_doorbell_desc::armed();
  endfunction

  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null) begin
      `uvm_error(label, "engine returned a null status")
      return;
    end
    if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  function automatic rdma_function_binding make_binding(
    string name,
    rdma_binding_state_e binding_state
  );
    rdma_function_binding binding;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = TEST_FUNCTION_UID;
    binding.global_function_id = TEST_FUNCTION_ID;
    binding.generation = TEST_GENERATION;
    binding.pcie.bdf = '{segment:16'h0001, bus:8'h42,
                         device:5'h03, function_num:3'h1};
    binding.pcie.bar[0].base.value = 64'h0000_0000_8000_0000;
    binding.pcie.bar[0].size = 64'h0001_0000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 0;
    binding.notify_base.value = 64'h0000_0000_8000_2000;
    binding.notify_size = 64'h2000;
    binding.state = binding_state;
    binding.owner_h = binding.make_handle();
    binding.dma_domain_valid = 1'b1;
    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
    return binding;
  endfunction

  function automatic rdma_cmq make_cmq(
    string name,
    rdma_function_binding binding,
    int unsigned depth = 32
  );
    rdma_cmq cmq;

    cmq = rdma_cmq::type_id::create(name);
    cmq.handle = rdma_handle::type_id::create({name, "_handle"});
    cmq.handle.kind = RDMA_RESOURCE_CMQ;
    cmq.handle.function_uid = binding.function_uid;
    cmq.handle.object_id = TEST_CMQ_ID;
    cmq.handle.generation = binding.generation;
    cmq.owner = binding.make_handle();
    cmq.state = RDMA_RESOURCE_ALLOCATED;
    cmq.depth = depth;
    return cmq;
  endfunction

  function automatic rdma_cmq_command_desc make_command(
    string name,
    rdma_function_binding binding,
    bit [31:0] opcode,
    byte unsigned marker,
    time timeout_value = 1us
  );
    rdma_cmq_command_desc command;
    rdma_cmq_sqe_model body;
    rdma_handle target_h;

    command = rdma_cmq_command_desc::type_id::create(name);
    command.function_h = binding.make_handle();
    command.opcode_key = rdma_cmq_opcode_key::type_id::create(
      {name, "_key"}
    );
    command.opcode_key.profile_name = "cmq_engine_test";
    command.opcode_key.opcode = opcode;
    command.opcode_key.variant = $sformatf("variant_%02h", opcode[7:0]);
    target_h = rdma_handle::type_id::create({name, "_target"});
    target_h.kind = RDMA_RESOURCE_CMQ;
    target_h.function_uid = binding.function_uid;
    target_h.object_id = TEST_CMQ_ID;
    target_h.generation = binding.generation;
    body = rdma_cmq_sqe_model::type_id::create({name, "_body"});
    body.opcode = RDMA_CMQ_QUERY;
    body.command_id = longint'(marker) + 1'b1;
    body.function_h = binding.make_handle();
    body.target_h = target_h;
    body.flags = marker;
    command.body = body;
    command.qpc_signature_source = rdma_hw_image::type_id::create(
      {name, "_signature"}
    );
    command.qpc_signature_source.bytes.push_back(marker ^ 8'hff);
    command.qpc_signature_source.length = 1;
    command.qpc_signature_source.alignment = 1;
    command.qpc_signature_source.endian = RDMA_ENDIAN_LITTLE;
    command.qpc_signature_source.image_kind = RDMA_IMAGE_QPC;
    command.qpc_signature_source.hardware_version = 1;
    command.qpc_signature_source.function_generation = binding.generation;
    command.timeout = timeout_value;
    return command;
  endfunction

  function automatic rdma_cmq_profile_hook_body make_profile_hook_body(
    string name,
    rdma_function_binding binding,
    int unsigned value
  );
    rdma_cmq_profile_hook_body body;

    body = rdma_cmq_profile_hook_body::type_id::create(name);
    body.value = value;
    body.nested_h = rdma_handle::type_id::create({name, "_nested"});
    body.nested_h.kind = RDMA_RESOURCE_CMQ;
    body.nested_h.function_uid = binding.function_uid;
    body.nested_h.object_id = TEST_CMQ_ID;
    body.nested_h.generation = binding.generation;
    return body;
  endfunction

  function automatic rdma_handle make_context_handle(
    string name,
    rdma_function_binding binding,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = binding.function_uid;
    handle.object_id = object_id;
    handle.generation = binding.generation;
    return handle;
  endfunction

  function automatic rdma_qpc_model make_qpc_context(
    string name,
    rdma_function_binding binding
  );
    rdma_qpc_model qpc;
    rdma_qpc_rc_ext rc_ext;

    qpc = rdma_qpc_model::type_id::create(name);
    qpc.qp_h = make_context_handle({name, "_qp"}, binding,
                                   RDMA_RESOURCE_QP, 32'h101);
    qpc.pd_h = make_context_handle({name, "_pd"}, binding,
                                   RDMA_RESOURCE_PD, 32'h202);
    qpc.send_cq_h = make_context_handle({name, "_scq"}, binding,
                                        RDMA_RESOURCE_CQ, 32'h303);
    qpc.recv_cq_h = make_context_handle({name, "_rcq"}, binding,
                                        RDMA_RESOURCE_CQ, 32'h304);
    qpc.transport = RDMA_TRANSPORT_RC;
    qpc.state = RDMA_QPS_RTS;
    qpc.path_mtu_bytes = 1024;
    qpc.sq_depth = 64;
    qpc.rq_depth = 32;
    qpc.sq_backing.value = 64'h0000_0000_1000_0000;
    qpc.rq_backing.value = 64'h0000_0000_1100_0000;
    qpc.context_backing.value = 64'h0000_0000_1200_0000;
    rc_ext = rdma_qpc_rc_ext::type_id::create({name, "_rc_ext"});
    rc_ext.remote_qpn = 24'h654321;
    qpc.transport_ext = rc_ext;
    return qpc;
  endfunction

  function automatic rdma_cmq_scalar_extension_qpc
      make_scalar_extension_qpc(
        string name,
        rdma_function_binding binding,
        int unsigned extension_value
      );
    rdma_qpc_model base_qpc;
    rdma_cmq_scalar_extension_qpc qpc;

    base_qpc = make_qpc_context({name, "_base"}, binding);
    qpc = rdma_cmq_scalar_extension_qpc::type_id::create(name);
    qpc.copy(base_qpc);
    qpc.extension_value = extension_value;
    return qpc;
  endfunction

  function automatic rdma_cmq_edge_extension_qpc make_edge_extension_qpc(
    string name,
    rdma_function_binding binding
  );
    rdma_qpc_model base_qpc;
    rdma_cmq_edge_extension_qpc qpc;

    base_qpc = make_qpc_context({name, "_base"}, binding);
    qpc = rdma_cmq_edge_extension_qpc::type_id::create(name);
    qpc.copy(base_qpc);
    qpc.extension_h = make_context_handle(
      {name, "_extension"}, binding, RDMA_RESOURCE_CMQ, TEST_CMQ_ID
    );
    return qpc;
  endfunction

  function automatic rdma_page_table_layout make_context_page_layout(
    string name
  );
    rdma_page_table_layout layout;

    layout = rdma_page_table_layout::type_id::create(name);
    layout.mode = RDMA_OBJECT_INDIRECT_4K;
    layout.sd_base.value = 64'h0000_0000_0100_0000;
    layout.current_base.value = 64'h0000_0000_0200_0000;
    layout.current_valid = 1'b1;
    layout.next_base.value = 64'h0000_0000_0300_0000;
    layout.next_valid = 1'b1;
    return layout;
  endfunction

  function automatic rdma_ring_position make_context_ring(
    string name,
    int unsigned index
  );
    rdma_ring_position ring;

    ring = rdma_ring_position::type_id::create(name);
    ring.index = index;
    return ring;
  endfunction

  function automatic rdma_cqc_model make_cqc_context(
    string name,
    rdma_function_binding binding
  );
    rdma_cqc_model cqc;

    cqc = rdma_cqc_model::type_id::create(name);
    cqc.cq_h = make_context_handle({name, "_cq"}, binding,
                                   RDMA_RESOURCE_CQ, 32'h301);
    cqc.ceq_h = make_context_handle({name, "_ceq"}, binding,
                                    RDMA_RESOURCE_CEQ, 32'h701);
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.depth = 64;
    cqc.cqe_size_bytes = 64;
    cqc.threshold = 8;
    cqc.page_layout = make_context_page_layout({name, "_layout"});
    cqc.producer = make_context_ring({name, "_producer"}, 9);
    cqc.consumer = make_context_ring({name, "_consumer"}, 3);
    cqc.shadow_backing.value = 64'h0000_0000_1300_0000;
    return cqc;
  endfunction

  function automatic rdma_mrt_model make_mrt_context(
    string name,
    rdma_function_binding binding
  );
    rdma_mrt_model mrt;

    mrt = rdma_mrt_model::type_id::create(name);
    mrt.mr_h = make_context_handle({name, "_mr"}, binding,
                                   RDMA_RESOURCE_MR, 32'h000123);
    mrt.pd_h = make_context_handle({name, "_pd"}, binding,
                                   RDMA_RESOURCE_PD, 32'h000202);
    mrt.state = RDMA_CONTEXT_VALID;
    mrt.iova.value = 64'h0000_0000_8000_0000;
    mrt.length = 64'h2000;
    mrt.lkey = 32'h0001_235a;
    mrt.rkey = mrt.lkey;
    mrt.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b1, memory_window_bind:1'b0,
                   remote_atomic:1'b0};
    mrt.object_type = 2'd1;
    mrt.page_layout.pba0.value = 64'h0000_0000_0400_0000;
    return mrt;
  endfunction

  function automatic rdma_srqc_model make_srqc_context(
    string name,
    rdma_function_binding binding
  );
    rdma_srqc_model srqc;

    srqc = rdma_srqc_model::type_id::create(name);
    srqc.srq_h = make_context_handle({name, "_srq"}, binding,
                                     RDMA_RESOURCE_SRQ, 32'h501);
    srqc.pd_h = make_context_handle({name, "_pd"}, binding,
                                    RDMA_RESOURCE_PD, 32'h202);
    srqc.state = RDMA_CONTEXT_VALID;
    srqc.depth = 32;
    srqc.load_pi_threshold = 4;
    srqc.limit_threshold = 8;
    srqc.srfq_backing.value = 64'h0000_0000_1400_0000;
    srqc.shadow_backing.value = 64'h0000_0000_1500_0000;
    srqc.producer = make_context_ring({name, "_producer"}, 5);
    return srqc;
  endfunction

  function automatic rdma_ceqc_model make_ceqc_context(
    string name,
    rdma_function_binding binding
  );
    rdma_ceqc_model ceqc;

    ceqc = rdma_ceqc_model::type_id::create(name);
    ceqc.ceq_h = make_context_handle({name, "_ceq"}, binding,
                                     RDMA_RESOURCE_CEQ, 32'h701);
    ceqc.state = RDMA_CONTEXT_VALID;
    ceqc.depth = 32;
    ceqc.vector_id = 11;
    ceqc.page_layout = make_context_page_layout({name, "_layout"});
    ceqc.producer = make_context_ring({name, "_producer"}, 7);
    ceqc.consumer = make_context_ring({name, "_consumer"}, 2);
    return ceqc;
  endfunction

  function automatic rdma_aeqc_model make_aeqc_context(
    string name,
    rdma_function_binding binding
  );
    rdma_aeqc_model aeqc;

    aeqc = rdma_aeqc_model::type_id::create(name);
    aeqc.aeq_h = make_context_handle({name, "_aeq"}, binding,
                                     RDMA_RESOURCE_AEQ, 32'h801);
    aeqc.state = RDMA_CONTEXT_VALID;
    aeqc.depth = 32;
    aeqc.vector_id = 12;
    aeqc.page_layout = make_context_page_layout({name, "_layout"});
    aeqc.producer = make_context_ring({name, "_producer"}, 8);
    aeqc.consumer = make_context_ring({name, "_consumer"}, 1);
    return aeqc;
  endfunction

  function automatic void clear_submit_observation(
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    mem.calls.delete();
    pcie.calls.delete();
    trace.clear();
  endfunction

  function automatic void expect_submit_trace(
    string label,
    rdma_mock_call_trace trace,
    string expected[]
  );
    if (trace.calls.size() != expected.size()) begin
      `uvm_error(label,
                 $sformatf("trace has %0d calls, expected %0d",
                           trace.calls.size(), expected.size()))
      return;
    end
    foreach (expected[i]) begin
      if (trace.calls[i] != expected[i])
        `uvm_error(label,
                   $sformatf("trace[%0d] is %s, expected %s", i,
                             trace.calls[i], expected[i]))
    end
  endfunction

  function automatic void expect_no_submit_side_effects(
    string label,
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    if (mem.calls.size() != 0 || pcie.calls.size() != 0 ||
        trace.calls.size() != 0)
      `uvm_error(label, "submission rejection caused adapter side effects")
  endfunction

  task automatic prepare_active(
    string label,
    rdma_cmq_engine engine,
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_doorbell_scheduler scheduler,
    rdma_cmq_test_profile profile,
    rdma_function_binding prepared_binding,
    rdma_function_binding active_binding,
    rdma_cmq cmq,
    output rdma_cmq_runtime_desc runtime_desc
  );
    rdma_status status;

    status = scheduler.configure(mem, pcie);
    expect_status({label, "_SCHEDULER"}, status, RDMA_SC_OK);
    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567, mem,
                   scheduler, profile, runtime_desc, status);
    expect_status({label, "_PREPARE"}, status, RDMA_SC_OK);
    engine.activate(active_binding, status);
    expect_status({label, "_ACTIVATE"}, status, RDMA_SC_OK);
  endtask

  function automatic int unsigned count_host_calls(
    rdma_mock_host_mem mem,
    string method_name
  );
    int unsigned result;

    result = 0;
    foreach (mem.calls[i]) begin
      if (mem.calls[i].method_name == method_name)
        result++;
    end
    return result;
  endfunction

  function automatic int host_call_index(
    rdma_mock_host_mem mem,
    string method_name,
    int unsigned ordinal
  );
    int unsigned match_count;

    match_count = 0;
    foreach (mem.calls[i]) begin
      if (mem.calls[i].method_name != method_name)
        continue;
      if (match_count == ordinal)
        return i;
      match_count++;
    end
    return -1;
  endfunction

  task automatic write_profile_cqe(
    string label,
    rdma_mock_host_mem mem,
    rdma_dma_mapping mapping,
    rdma_cmq_test_profile profile,
    longint unsigned cq_sequence,
    bit owner,
    rdma_cmq_ticket ticket,
    bit [31:0] hardware_ecode,
    output rdma_hw_image raw_cqe
  );
    byte data[];
    rdma_status status;

    raw_cqe = null;
    if (mem == null || mapping == null || profile == null ||
        ticket == null || ticket.function_h == null ||
        ticket.opcode_key == null) begin
      `uvm_error(label, "CQE write prerequisites are incomplete")
      return;
    end
    raw_cqe = profile.make_cqe(
      {label, "_raw_cqe"}, owner, ticket.opcode_key.opcode,
      hardware_ecode, ticket.sq_index, ticket.sq_wrap,
      ticket.function_h.generation
    );
    if (raw_cqe == null || raw_cqe.bytes.size() != 64) begin
      `uvm_error(label, "profile did not produce a 64-byte CQE")
      raw_cqe = null;
      return;
    end
    data = new[64];
    foreach (data[i])
      data[i] = raw_cqe.bytes[i];
    status = mem.write(
      mapping,
      TEST_CQ_OFFSET + ((cq_sequence % 32) * 64),
      data
    );
    expect_status({label, "_WRITE"}, status, RDMA_SC_OK);
  endtask

  task automatic overwrite_profile_cqe(
    string label,
    rdma_mock_host_mem mem,
    rdma_dma_mapping mapping,
    longint unsigned cq_sequence,
    rdma_hw_image raw_cqe
  );
    byte data[];
    rdma_status status;

    if (mem == null || mapping == null || raw_cqe == null ||
        raw_cqe.bytes.size() != 64) begin
      `uvm_error(label, "raw CQE overwrite prerequisites are incomplete")
      return;
    end
    data = new[64];
    foreach (data[i])
      data[i] = raw_cqe.bytes[i];
    status = mem.write(
      mapping,
      TEST_CQ_OFFSET + ((cq_sequence % 32) * 64),
      data
    );
    expect_status({label, "_WRITE"}, status, RDMA_SC_OK);
  endtask

  function automatic void expect_poll_read_geometry(
    string label,
    rdma_mock_host_mem mem,
    longint unsigned first_cq_sequence,
    int unsigned expected_count
  );
    int call_index;
    longint unsigned expected_offset;

    if (count_host_calls(mem, "read") != expected_count) begin
      `uvm_error(label,
                 $sformatf("poll issued %0d reads, expected %0d",
                           count_host_calls(mem, "read"),
                           expected_count))
      return;
    end
    for (int unsigned i = 0; i < expected_count; i++) begin
      call_index = host_call_index(mem, "read", i);
      expected_offset = TEST_CQ_OFFSET +
                        (((first_cq_sequence + i) % 32) * 64);
      if (call_index < 0 || mem.calls[call_index].size != 64 ||
          mem.calls[call_index].offset != expected_offset)
        `uvm_error(label,
                   $sformatf("read %0d was not an exact 64B CQ slot read",
                             i))
    end
  endfunction

  task automatic expect_empty_poll_without_read(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_mock_host_mem mem
  );
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_status status;
    longint unsigned before_publish;
    longint unsigned before_retire;
    longint unsigned before_consume;

    before_publish = engine.published_count();
    before_retire = engine.retired_count();
    before_consume = engine.cq_consumed_count();
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        count_host_calls(mem, "read") != 0 ||
        engine.state() != RDMA_CMQ_ENGINE_ACTIVE ||
        engine.published_count() != before_publish ||
        engine.retired_count() != before_retire ||
        engine.cq_consumed_count() != before_consume ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0 ||
        engine.terminal_fifo_count() != 0)
      `uvm_error(label, "empty poll changed authority or read host memory")
  endtask

  task automatic expect_inconsistent_empty_poll_without_read(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_mock_host_mem mem
  );
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_status status;

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status({label, "_STATUS"}, status, RDMA_SC_INVALID_STATE);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        count_host_calls(mem, "read") != 0 ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        engine.last_poison_snapshot() != null)
      `uvm_error(
        label,
        "inconsistent empty ledger did not fail closed before host access"
      )
  endtask

  function automatic void expect_polled_completion(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_cmq_completion completion,
    rdma_cmq_ticket expected_ticket,
    rdma_hw_image expected_raw,
    bit expected_owner,
    bit [31:0] expected_hardware_ecode,
    rdma_status_code_e expected_code
  );
    rdma_xtr_v1_cmq_completion payload;
    rdma_status validation_status;

    if (completion == null || expected_ticket == null ||
        expected_ticket.function_h == null ||
        expected_ticket.cmq_h == null ||
        expected_ticket.opcode_key == null || expected_raw == null) begin
      `uvm_error(label, "completion comparison prerequisites are null")
      return;
    end
    validation_status = completion.validate();
    expect_status({label, "_VALIDATE"}, validation_status, RDMA_SC_OK);
    if (completion.ticket == null || completion.ticket == expected_ticket ||
        completion.ticket.function_h == expected_ticket.function_h ||
        completion.ticket.cmq_h == expected_ticket.cmq_h ||
        completion.ticket.opcode_key == expected_ticket.opcode_key ||
        completion.ticket.command_id != expected_ticket.command_id ||
        completion.ticket.slot_sequence != expected_ticket.slot_sequence ||
        completion.ticket.sq_index != expected_ticket.sq_index ||
        completion.ticket.sq_wrap != expected_ticket.sq_wrap ||
        completion.ticket.opcode_key.opcode !=
          expected_ticket.opcode_key.opcode)
      `uvm_error(label, "completion ticket is aliased or mismatched")
    expect_status({label, "_COMMAND_STATUS"}, completion.status,
                  expected_code);
    if (completion.status == null)
      return;
    if (completion.status.source_engine != RDMA_ENGINE_CMQ ||
        completion.status.function_uid !=
          expected_ticket.function_h.function_uid ||
        completion.status.generation !=
          expected_ticket.function_h.generation ||
        completion.status.resource_id != expected_ticket.cmq_h.object_id ||
        completion.status.command_id != expected_ticket.command_id)
      `uvm_error(label, "completion status identity is incomplete")
    if (expected_hardware_ecode == 0) begin
      if (completion.status.hardware_code_valid ||
          completion.status.hardware_code != 0)
        `uvm_error(label, "successful completion retained hardware error")
    end
    else if (!completion.status.hardware_code_valid ||
             completion.status.hardware_code != expected_hardware_ecode)
      `uvm_error(label, "completion lost the raw hardware ecode")
    if (completion.raw_cqe == null || completion.raw_cqe == expected_raw ||
        !engine.probe_same_image(completion.raw_cqe, expected_raw))
      `uvm_error(label, "completion raw CQE is aliased or mismatched")
    if (completion.raw_cqe != null &&
        (completion.raw_cqe.endian != expected_raw.endian ||
         completion.raw_cqe.hardware_version !=
           expected_raw.hardware_version))
      `uvm_error(label,
                 "completion raw CQE lost profile-wide format metadata")
    if (!$cast(payload, completion.decoded_response))
      `uvm_error(label, "completion lost the typed decoded payload")
    else if (payload.owner != expected_owner ||
             payload.opcode != expected_ticket.opcode_key.opcode[7:0] ||
             payload.command_ecode != expected_hardware_ecode[7:0] ||
             payload.wqe_index != expected_ticket.sq_index ||
             payload.wrap != expected_ticket.sq_wrap)
      `uvm_error(label, "decoded CQE payload fields are mismatched")
  endfunction

  function automatic void expect_timeout_completion(
    string label,
    rdma_cmq_completion completion,
    rdma_cmq_ticket expected_ticket
  );
    rdma_status validation_status;

    if (completion == null || expected_ticket == null ||
        expected_ticket.function_h == null ||
        expected_ticket.cmq_h == null ||
        expected_ticket.opcode_key == null) begin
      `uvm_error(label, "timeout completion prerequisites are null")
      return;
    end
    validation_status = completion.validate();
    expect_status({label, "_VALIDATE"}, validation_status, RDMA_SC_OK);
    if (completion.ticket == null || completion.ticket == expected_ticket ||
        completion.ticket.function_h == expected_ticket.function_h ||
        completion.ticket.cmq_h == expected_ticket.cmq_h ||
        completion.ticket.opcode_key == expected_ticket.opcode_key ||
        completion.ticket.command_id != expected_ticket.command_id ||
        completion.ticket.slot_sequence != expected_ticket.slot_sequence ||
        completion.ticket.sq_index != expected_ticket.sq_index ||
        completion.ticket.sq_wrap != expected_ticket.sq_wrap ||
        completion.ticket.absolute_deadline !=
          expected_ticket.absolute_deadline)
      `uvm_error(label, "timeout completion ticket is aliased or mismatched")
    expect_status({label, "_STATUS"}, completion.status, RDMA_SC_TIMEOUT);
    if (completion.status == null)
      return;
    if (completion.status.source_engine != RDMA_ENGINE_CMQ ||
        completion.status.function_uid !=
          expected_ticket.function_h.function_uid ||
        completion.status.generation !=
          expected_ticket.function_h.generation ||
        completion.status.resource_id != expected_ticket.cmq_h.object_id ||
        completion.status.command_id != expected_ticket.command_id ||
        completion.raw_cqe != null || completion.decoded_response != null)
      `uvm_error(label, "timeout completion identity or payload is invalid")
  endfunction

  function automatic void expect_late_diagnostic(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_cmq_diagnostic diagnostic,
    rdma_cmq_ticket expected_ticket,
    rdma_hw_image expected_raw
  );
    rdma_status validation_status;

    if (diagnostic == null || expected_ticket == null ||
        expected_ticket.function_h == null ||
        expected_ticket.cmq_h == null ||
        expected_ticket.opcode_key == null || expected_raw == null) begin
      `uvm_error(label, "late diagnostic prerequisites are null")
      return;
    end
    validation_status = diagnostic.validate();
    expect_status({label, "_VALIDATE"}, validation_status, RDMA_SC_OK);
    if (diagnostic.kind != RDMA_CMQ_DIAG_LATE_COMPLETION ||
        diagnostic.ticket == null || diagnostic.ticket == expected_ticket ||
        diagnostic.ticket.function_h == expected_ticket.function_h ||
        diagnostic.ticket.cmq_h == expected_ticket.cmq_h ||
        diagnostic.ticket.opcode_key == expected_ticket.opcode_key ||
        diagnostic.ticket.command_id != expected_ticket.command_id ||
        diagnostic.ticket.slot_sequence != expected_ticket.slot_sequence ||
        diagnostic.ticket.sq_index != expected_ticket.sq_index ||
        diagnostic.ticket.sq_wrap != expected_ticket.sq_wrap ||
        diagnostic.ticket.absolute_deadline != expected_ticket.absolute_deadline)
      `uvm_error(label, "late diagnostic ticket is aliased or mismatched")
    expect_status({label, "_STATUS"}, diagnostic.status, RDMA_SC_TIMEOUT);
    if (diagnostic.status == null)
      return;
    if (diagnostic.status.source_engine != RDMA_ENGINE_CMQ ||
        diagnostic.status.function_uid !=
          expected_ticket.function_h.function_uid ||
        diagnostic.status.generation !=
          expected_ticket.function_h.generation ||
        diagnostic.status.resource_id != expected_ticket.cmq_h.object_id ||
        diagnostic.status.command_id != expected_ticket.command_id ||
        diagnostic.raw_cqe == null || diagnostic.raw_cqe == expected_raw ||
        !engine.probe_same_image(diagnostic.raw_cqe, expected_raw))
      `uvm_error(label, "late diagnostic identity or raw CQE is invalid")
  endfunction

  function automatic void expect_poison_diagnostic(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_cmq_diagnostic diagnostic,
    rdma_cmq_diagnostic_kind_e expected_kind,
    rdma_cmq_ticket expected_ticket,
    rdma_hw_image expected_raw,
    rdma_function_binding expected_binding,
    rdma_cmq expected_cmq
  );
    rdma_status validation_status;

    if (diagnostic == null || engine == null || expected_raw == null ||
        expected_binding == null || expected_cmq == null ||
        expected_cmq.handle == null) begin
      `uvm_error(label, "poison diagnostic prerequisites are null")
      return;
    end
    validation_status = diagnostic.validate();
    expect_status({label, "_VALIDATE"}, validation_status, RDMA_SC_OK);
    if (diagnostic.kind != expected_kind)
      `uvm_error(label, $sformatf(
        "expected diagnostic kind %s, got %s",
        expected_kind.name(), diagnostic.kind.name()
      ))
    if (expected_ticket == null) begin
      if (diagnostic.ticket != null)
        `uvm_error(label, "untrusted CQE diagnostic leaked a ticket")
    end
    else if (diagnostic.ticket == null ||
             diagnostic.ticket == expected_ticket ||
             diagnostic.ticket.function_h == expected_ticket.function_h ||
             diagnostic.ticket.cmq_h == expected_ticket.cmq_h ||
             diagnostic.ticket.opcode_key == expected_ticket.opcode_key ||
             diagnostic.ticket.command_id != expected_ticket.command_id ||
             diagnostic.ticket.slot_sequence !=
               expected_ticket.slot_sequence ||
             diagnostic.ticket.sq_index != expected_ticket.sq_index ||
             diagnostic.ticket.sq_wrap != expected_ticket.sq_wrap)
      `uvm_error(label, "trusted CQE diagnostic ticket is aliased or wrong")
    expect_status({label, "_STATUS"}, diagnostic.status,
                  RDMA_SC_CODEC_ERROR);
    if (diagnostic.status != null &&
        (diagnostic.status.source_engine != RDMA_ENGINE_CMQ ||
         diagnostic.status.function_uid != expected_binding.function_uid ||
         diagnostic.status.generation != expected_binding.generation ||
         diagnostic.status.resource_id != expected_cmq.handle.object_id ||
         diagnostic.status.command_id !=
           ((expected_ticket == null) ? 0 : expected_ticket.command_id)))
      `uvm_error(label, "poison diagnostic status lost command identity")
    if (diagnostic.raw_cqe == null ||
        diagnostic.raw_cqe == expected_raw ||
        diagnostic.raw_cqe.bytes.size() != 64 ||
        !engine.probe_same_image(diagnostic.raw_cqe, expected_raw))
      `uvm_error(label, "poison diagnostic lost detached 64-byte evidence")
  endfunction

  function automatic void expect_release_retry_identity(
    string label,
    rdma_mock_host_mem mem,
    rdma_mock_dma_mapping retained_mapping
  );
    int first_index;
    int second_index;
    rdma_mock_dma_mapping first_release_mapping;
    rdma_mock_dma_mapping second_release_mapping;

    first_index = host_call_index(mem, "release", 0);
    second_index = host_call_index(mem, "release", 1);
    if (first_index < 0 || second_index < 0) begin
      `uvm_error(label, "two release records were not available")
      return;
    end
    if (!$cast(first_release_mapping, mem.calls[first_index].mapping) ||
        !$cast(second_release_mapping, mem.calls[second_index].mapping)) begin
      `uvm_error(label, "release record lost allocation identity")
      return;
    end
    if (retained_mapping == null ||
        !first_release_mapping.same_allocation(second_release_mapping) ||
        !retained_mapping.same_allocation(second_release_mapping))
      `uvm_error(label, "release retry changed mapping allocation identity")
  endfunction

  function automatic bit same_nullable_handle(
    rdma_handle lhs,
    rdma_handle rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.same_instance(rhs);
  endfunction

  function automatic bit same_mapping_fields(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return same_nullable_handle(lhs.function_h, rhs.function_h) &&
           lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid && lhs.pasid == rhs.pasid &&
           lhs.backing_addr == rhs.backing_addr && lhs.iova == rhs.iova &&
           lhs.size == rhs.size && lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions && lhs.state == rhs.state &&
           same_nullable_handle(lhs.owner_h, rhs.owner_h);
  endfunction

  function automatic void expect_post_allocate_rollback(
    string label,
    rdma_cmq_engine engine,
    rdma_mock_host_mem mem,
    rdma_cmq_runtime_desc runtime_desc,
    int unsigned expected_write_count
  );
    if (runtime_desc != null)
      `uvm_error(label, "failed prepare published a runtime descriptor")
    if (count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != expected_write_count ||
        count_host_calls(mem, "release") != 1)
      `uvm_error(label,
                 "post-allocation failure did not release exactly once")
    if (mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error(label, "post-allocation failure leaked its mock region")
    expect_unconfigured({label, "_STATE"}, engine);
  endfunction

  function automatic void expect_unconfigured(
    string label,
    rdma_cmq_engine engine
  );
    if (engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED)
      `uvm_error(label, "engine did not remain UNCONFIGURED")
    if (engine.mapping_snapshot() != null)
      `uvm_error(label, "unconfigured engine retained a mapping")
  endfunction

  task automatic prepare_defaults(
    string label,
    rdma_cmq_engine engine,
    rdma_mock_host_mem mem,
    rdma_function_binding binding,
    rdma_cmq cmq,
    rdma_doorbell_scheduler scheduler,
    rdma_cmq_test_profile profile,
    output rdma_cmq_runtime_desc runtime_desc
  );
    rdma_status status;

    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status(label, status, RDMA_SC_OK);
  endtask

  task automatic check_success_and_detachment();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping first_snapshot;
    rdma_dma_mapping second_snapshot;
    rdma_status status;

    engine = rdma_cmq_engine::type_id::create("success_engine");
    mem = rdma_mock_host_mem::type_id::create("success_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "success_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("success_profile");
    prepared_binding = make_binding("prepared_binding", RDMA_BIND_PREPARED);
    active_binding = make_binding("active_binding", RDMA_BIND_ACTIVE);
    cmq = make_cmq("success_cmq", prepared_binding);

    if (engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED ||
        engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.mapping_snapshot() != null)
      `uvm_error("CMQ_INITIAL_STATE", "new engine state is not empty")

    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567,
                   mem, scheduler, profile, runtime_desc, status);
    expect_status("PREPARE", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_PREPARED)
      `uvm_error("PREPARE_STATE", "prepare did not enter PREPARED")
    if (runtime_desc == null)
      `uvm_error("PREPARE_RUNTIME", "prepare returned no runtime descriptor")
    else begin
      expect_status("PREPARE_RUNTIME_VALIDATE", runtime_desc.validate(),
                    RDMA_SC_OK);
      if (runtime_desc.sq_iova.value !=
            mem.regions[0].mapping.iova.value ||
          runtime_desc.cq_iova.value !=
            mem.regions[0].mapping.iova.value + 64'd2048)
        `uvm_error("CMQ_LAYOUT", "runtime IOVA layout is incorrect")
      if (runtime_desc.sq_depth != 32 || runtime_desc.cq_depth != 32 ||
          runtime_desc.entry_bytes != 64 ||
          !runtime_desc.initial_sq_valid ||
          !runtime_desc.initial_cq_owner ||
          runtime_desc.initial_doorbell_polarity)
        `uvm_error("CMQ_RUNTIME_INIT",
                   "runtime descriptor initialization is incorrect")
      if (runtime_desc.function_h == prepared_binding.owner_h ||
          runtime_desc.cmq_h == cmq.handle)
        `uvm_error("CMQ_RUNTIME_DETACH",
                   "runtime descriptor aliases caller authority")
    end

    if (mem.calls.size() != 2 ||
        count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != 1 ||
        mem.calls[0].size != 4096 || mem.calls[0].alignment != 4096 ||
        mem.calls[0].direction != RDMA_DMA_BIDIRECTIONAL ||
        mem.calls[0].request_context == null ||
        mem.calls[0].request_context.function_h == null ||
        !mem.calls[0].request_context.function_h.same_instance(
          prepared_binding.make_handle()
        ) || mem.calls[0].request_context.requester_bdf == '0 ||
        mem.calls[0].request_context.requester_bdf !=
          prepared_binding.pcie.bdf ||
        !mem.calls[0].request_context.pasid_valid ||
        mem.calls[0].request_context.pasid != 20'h34567 ||
        mem.calls[0].request_context.owner_h == null ||
        !mem.calls[0].request_context.owner_h.same_instance(cmq.handle))
      `uvm_error("CMQ_ALLOCATE",
                 "prepare allocation request/context is incorrect")
    if (mem.calls.size() >= 2 &&
        (mem.calls[1].method_name != "write" ||
         mem.calls[1].offset != 0 || mem.calls[1].data.size() != 4096))
      `uvm_error("CMQ_ZERO_WRITE", "prepare did not issue one 4096B write")
    if (mem.regions.size() != 1 || mem.regions[0].data.size() != 4096)
      `uvm_error("CMQ_ZERO_REGION", "prepare allocated wrong backing size")
    else begin
      foreach (mem.regions[0].data[i]) begin
        if (mem.regions[0].data[i] != 0)
          `uvm_error("CMQ_ZERO_REGION",
                     $sformatf("backing byte %0d was not zero", i))
      end
    end

    first_snapshot = engine.mapping_snapshot();
    second_snapshot = engine.mapping_snapshot();
    if (first_snapshot == null || second_snapshot == null ||
        first_snapshot == second_snapshot ||
        first_snapshot == mem.regions[0].mapping)
      `uvm_error("CMQ_MAPPING_SNAPSHOT",
                 "mapping query did not return detached snapshots")
    else begin
      first_snapshot.pasid = '0;
      if (second_snapshot.pasid != 20'h34567 ||
          engine.mapping_snapshot().pasid != 20'h34567)
        `uvm_error("CMQ_MAPPING_SNAPSHOT",
                   "mapping snapshot mutation reached engine authority")
    end
    if (engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0)
      `uvm_error("CMQ_PREPARE_COUNTS", "prepare changed ring counters")

    prepared_binding.function_uid = '0;
    prepared_binding.pcie.bdf = '0;
    cmq.handle.object_id = '0;
    cmq.depth = 64;
    if (runtime_desc != null) begin
      runtime_desc.sq_iova.value = '0;
      runtime_desc.function_h.generation = '0;
      runtime_desc.cmq_h.object_id = '0;
    end
    engine.activate(active_binding, status);
    expect_status("ACTIVATE_DETACHED_INPUTS", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_ACTIVE)
      `uvm_error("ACTIVATE_STATE", "activate did not enter ACTIVE")
    engine.activate(active_binding, status);
    expect_status("ACTIVATE_ALREADY_ACTIVE", status,
                  RDMA_SC_INVALID_STATE);

    engine.shutdown(status);
    expect_status("SUCCESS_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("SUCCESS_SHUTDOWN_STATE", engine);
    if (count_host_calls(mem, "release") != 1)
      `uvm_error("SUCCESS_SHUTDOWN_RELEASE",
                 "shutdown did not release backing exactly once")
    engine.shutdown(status);
    expect_status("SUCCESS_SHUTDOWN_IDEMPOTENT", status, RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 1)
      `uvm_error("SUCCESS_SHUTDOWN_IDEMPOTENT",
                 "idempotent shutdown released backing again")
  endtask

  task automatic check_preallocation_rejections();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;

    scheduler = rdma_doorbell_scheduler::type_id::create("reject_scheduler");

    mem = rdma_mock_host_mem::type_id::create("null_binding_mem");
    profile = rdma_cmq_test_profile::type_id::create("null_binding_profile");
    binding = make_binding("null_binding_reference", RDMA_BIND_PREPARED);
    cmq = make_cmq("null_binding_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("null_binding_engine");
    engine.prepare(null, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("NULL_BINDING", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_BINDING_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("null_cmq_mem");
    binding = make_binding("null_cmq_binding", RDMA_BIND_PREPARED);
    engine = rdma_cmq_engine::type_id::create("null_cmq_engine");
    engine.prepare(binding, null, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("NULL_CMQ", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_CMQ_STATE", engine);

    binding = make_binding("null_adapter_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("null_adapter_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("null_adapter_engine");
    engine.prepare(binding, cmq, 1'b0, '0, null, scheduler, profile,
                   runtime_desc, status);
    expect_status("NULL_HOST_MEM", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_HOST_MEM_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("null_scheduler_mem");
    engine = rdma_cmq_engine::type_id::create("null_scheduler_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, null, profile,
                   runtime_desc, status);
    expect_status("NULL_SCHEDULER", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_SCHEDULER_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("null_profile_mem");
    engine = rdma_cmq_engine::type_id::create("null_profile_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, null,
                   runtime_desc, status);
    expect_status("NULL_PROFILE", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_PROFILE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("wrong_lifecycle_mem");
    binding = make_binding("wrong_lifecycle_binding", RDMA_BIND_ACTIVE);
    cmq = make_cmq("wrong_lifecycle_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("wrong_lifecycle_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("BINDING_NOT_PREPARED", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("BINDING_NOT_PREPARED_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("invalid_binding_mem");
    binding = make_binding("invalid_binding", RDMA_BIND_PREPARED);
    binding.pcie = null;
    cmq = make_cmq("invalid_binding_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("invalid_binding_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("INVALID_BINDING", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("INVALID_BINDING_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("binding_owner_mem");
    binding = make_binding("binding_owner_binding", RDMA_BIND_PREPARED);
    binding.owner_h.object_id++;
    cmq = make_cmq("binding_owner_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("binding_owner_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("BINDING_OWNER", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("BINDING_OWNER_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_depth_mem");
    binding = make_binding("cmq_depth_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("cmq_depth_cmq", binding, 64);
    engine = rdma_cmq_engine::type_id::create("cmq_depth_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_DEPTH", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("CMQ_DEPTH_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_handle_mem");
    cmq = make_cmq("cmq_handle_cmq", binding);
    cmq.handle = null;
    engine = rdma_cmq_engine::type_id::create("cmq_handle_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_HANDLE", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("CMQ_HANDLE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_owner_mem");
    cmq = make_cmq("cmq_owner_cmq", binding);
    cmq.owner = null;
    engine = rdma_cmq_engine::type_id::create("cmq_owner_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_OWNER", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("CMQ_OWNER_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_state_mem");
    cmq = make_cmq("cmq_state_cmq", binding);
    cmq.state = RDMA_RESOURCE_RELEASED;
    engine = rdma_cmq_engine::type_id::create("cmq_state_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_LIFECYCLE", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("CMQ_LIFECYCLE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("profile_failure_mem");
    profile = rdma_cmq_test_profile::type_id::create("failure_profile");
    profile.fail_validation = 1'b1;
    cmq = make_cmq("profile_failure_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("profile_failure_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("PROFILE_FAILURE", status, RDMA_SC_INVALID_STATE);
    if (profile.validation_calls != 1 || mem.calls.size() != 0)
      `uvm_error("PROFILE_BEFORE_ALLOCATE",
                 "profile failure did not precede allocation")
    expect_unconfigured("PROFILE_FAILURE_STATE", engine);
  endtask

  task automatic check_pasid_normalization_and_busy_prepare();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;
    int unsigned calls_before;

    engine = rdma_cmq_engine::type_id::create("pasid_engine");
    mem = rdma_mock_host_mem::type_id::create("pasid_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create("pasid_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("pasid_profile");
    binding = make_binding("pasid_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("pasid_cmq", binding);
    engine.prepare(binding, cmq, 1'b0, 20'hfffff, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("PASID_NORMALIZE", status, RDMA_SC_OK);
    if (mem.calls[0].request_context.pasid_valid ||
        mem.calls[0].request_context.pasid != 0 ||
        mem.regions[0].mapping.pasid_valid ||
        mem.regions[0].mapping.pasid != 0)
      `uvm_error("PASID_NORMALIZE",
                 "invalid PASID was not normalized to zero")

    calls_before = mem.calls.size();
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("PREPARE_ALREADY_PREPARED", status,
                  RDMA_SC_INVALID_STATE);
    if (runtime_desc != null || mem.calls.size() != calls_before)
      `uvm_error("PREPARE_ALREADY_PREPARED",
                 "busy prepare changed outputs or host memory")
    engine.shutdown(status);
    expect_status("PASID_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_allocation_and_rollback_failures();
    rdma_cmq_engine engine;
    rdma_cmq_engine_probe release_failure_engine;
    rdma_cmq_runtime_clone_failure_engine clone_failure_engine;
    rdma_cmq_runtime_build_failure_engine build_failure_engine;
    rdma_mock_host_mem mem;
    rdma_cmq_short_mapping_mem short_mem;
    rdma_cmq_bad_mapping_mem bad_mem;
    rdma_cmq_upper_boundary_mem upper_boundary_mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    scheduler = rdma_doorbell_scheduler::type_id::create(
      "rollback_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("rollback_profile");
    binding = make_binding("rollback_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("rollback_cmq", binding);

    mem = rdma_mock_host_mem::type_id::create("allocate_failure_mem");
    expect_status("ARM_ALLOCATE_FAILURE",
                  mem.fail_next("allocate", rdma_status::make(
                    RDMA_SC_RESOURCE_EXHAUSTED, "injected allocate failure"
                  )), RDMA_SC_OK);
    engine = rdma_cmq_engine::type_id::create("allocate_failure_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("ALLOCATE_FAILURE", status, RDMA_SC_RESOURCE_EXHAUSTED);
    if (count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != 0 ||
        count_host_calls(mem, "release") != 0)
      `uvm_error("ALLOCATE_FAILURE_CALLS",
                 "allocate failure performed later host operations")
    expect_unconfigured("ALLOCATE_FAILURE_STATE", engine);

    short_mem = rdma_cmq_short_mapping_mem::type_id::create("short_mem");
    engine = rdma_cmq_engine::type_id::create("short_mapping_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, short_mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("SHORT_MAPPING", status, RDMA_SC_INVALID_STATE);
    if (count_host_calls(short_mem, "allocate") != 1 ||
        count_host_calls(short_mem, "write") != 0 ||
        count_host_calls(short_mem, "release") != 1)
      `uvm_error("SHORT_MAPPING_ROLLBACK",
                 "invalid mapping was not released exactly once")
    expect_unconfigured("SHORT_MAPPING_STATE", engine);

    for (int unsigned bad_kind = RDMA_CMQ_BAD_MAPPING_ATOMIC;
         bad_kind <= RDMA_CMQ_BAD_MAPPING_BACKING_RANGE; bad_kind++) begin
      bad_mem = rdma_cmq_bad_mapping_mem::type_id::create(
        $sformatf("bad_mapping_mem_%0d", bad_kind)
      );
      bad_mem.bad_kind = rdma_cmq_bad_mapping_kind_e'(bad_kind);
      engine = rdma_cmq_engine::type_id::create(
        $sformatf("bad_mapping_engine_%0d", bad_kind)
      );
      engine.prepare(binding, cmq, 1'b1, 20'h34567, bad_mem, scheduler,
                     profile, runtime_desc, status);
      if (bad_kind == RDMA_CMQ_BAD_MAPPING_ATOMIC)
        expect_status("ATOMIC_MAPPING_PREPARE", status,
                      RDMA_SC_DMA_PERMISSION);
      else
        expect_status($sformatf("BAD_MAPPING_PREPARE_%0d", bad_kind),
                      status, RDMA_SC_DMA_TRANSLATION);
      if (bad_kind inside {RDMA_CMQ_BAD_MAPPING_IOVA_RANGE,
                           RDMA_CMQ_BAD_MAPPING_BACKING_RANGE}) begin
        // A 4096-aligned 64-bit base cannot overflow a 4096-byte range.
        // The first address above the maximum legal aligned base is
        // necessarily unaligned, so fail closed at the alignment check.
        if (status == null ||
            status.message !=
              "CMQ backing mapping is not 4096-byte aligned")
          `uvm_error("BAD_MAPPING_UPPER_BOUND_STATUS",
                     "upper-bound fixture did not fail on alignment")
      end
      expect_post_allocate_rollback(
        $sformatf("BAD_MAPPING_ROLLBACK_%0d", bad_kind), engine,
        bad_mem, runtime_desc, 0
      );
    end

    upper_boundary_mem = rdma_cmq_upper_boundary_mem::type_id::create(
      "upper_boundary_mem"
    );
    engine = rdma_cmq_engine::type_id::create("upper_boundary_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567,
                   upper_boundary_mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("UPPER_BOUNDARY_PREPARE", status, RDMA_SC_OK);
    if (runtime_desc == null)
      `uvm_error("UPPER_BOUNDARY_RUNTIME",
                 "maximum legal aligned base published no runtime")
    else begin
      expect_status("UPPER_BOUNDARY_RUNTIME_VALIDATE",
                    runtime_desc.validate(), RDMA_SC_OK);
      if (runtime_desc.sq_iova.value != 64'hffff_ffff_ffff_f000 ||
          runtime_desc.cq_iova.value != 64'hffff_ffff_ffff_f800)
        `uvm_error("UPPER_BOUNDARY_LAYOUT",
                   "maximum legal aligned base produced wrong layout")
    end
    if (count_host_calls(upper_boundary_mem, "allocate") != 1 ||
        count_host_calls(upper_boundary_mem, "write") != 1 ||
        count_host_calls(upper_boundary_mem, "release") != 0)
      `uvm_error("UPPER_BOUNDARY_CALLS",
                 "maximum legal aligned base used wrong host operations")
    engine.shutdown(status);
    expect_status("UPPER_BOUNDARY_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("UPPER_BOUNDARY_SHUTDOWN_STATE", engine);
    if (count_host_calls(upper_boundary_mem, "release") != 1)
      `uvm_error("UPPER_BOUNDARY_RELEASE",
                 "maximum legal aligned base was not released once")

    mem = rdma_mock_host_mem::type_id::create("write_failure_mem");
    expect_status("ARM_WRITE_FAILURE",
                  mem.fail_next("write", rdma_status::make(
                    RDMA_SC_DMA_TRANSLATION, "injected zero write failure"
                  )), RDMA_SC_OK);
    engine = rdma_cmq_engine::type_id::create("write_failure_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("ZERO_WRITE_FAILURE", status, RDMA_SC_DMA_TRANSLATION);
    if (count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != 1 ||
        count_host_calls(mem, "release") != 1)
      `uvm_error("ZERO_WRITE_ROLLBACK",
                 "zero-write failure did not release exactly once")
    expect_unconfigured("ZERO_WRITE_FAILURE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("build_failure_mem");
    build_failure_engine =
      rdma_cmq_runtime_build_failure_engine::type_id::create(
        "build_failure_engine"
      );
    build_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567,
                                 mem, scheduler, profile,
                                 runtime_desc, status);
    expect_status("RUNTIME_BUILD_FAILURE", status, RDMA_SC_CODEC_ERROR);
    expect_post_allocate_rollback("RUNTIME_BUILD_ROLLBACK",
                                  build_failure_engine, mem,
                                  runtime_desc, 1);

    mem = rdma_mock_host_mem::type_id::create("build_null_status_mem");
    build_failure_engine =
      rdma_cmq_runtime_build_failure_engine::type_id::create(
        "build_null_status_engine"
      );
    build_failure_engine.return_null_status = 1'b1;
    build_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567,
                                 mem, scheduler, profile,
                                 runtime_desc, status);
    expect_status("RUNTIME_BUILD_NULL_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    expect_post_allocate_rollback("RUNTIME_BUILD_NULL_ROLLBACK",
                                  build_failure_engine, mem,
                                  runtime_desc, 1);

    mem = rdma_mock_host_mem::type_id::create("clone_failure_mem");
    clone_failure_engine =
      rdma_cmq_runtime_clone_failure_engine::type_id::create(
        "clone_failure_engine"
      );
    clone_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567,
                                 mem, scheduler, profile,
                                 runtime_desc, status);
    expect_status("RUNTIME_CLONE_FAILURE", status, RDMA_SC_INVALID_STATE);
    expect_post_allocate_rollback("RUNTIME_CLONE_ROLLBACK",
                                  clone_failure_engine, mem,
                                  runtime_desc, 1);

    mem = rdma_mock_host_mem::type_id::create("release_failure_mem");
    expect_status("ARM_RELEASE_WRITE_FAILURE",
                  mem.fail_next("write", rdma_status::make(
                    RDMA_SC_DMA_TRANSLATION, "rollback trigger"
                  )), RDMA_SC_OK);
    expect_status("ARM_RELEASE_FAILURE",
                  mem.fail_next("release", rdma_status::make(
                    RDMA_SC_UNKNOWN_HW_ERROR,
                    "injected rollback release failure"
                  )), RDMA_SC_OK);
    release_failure_engine = rdma_cmq_engine_probe::type_id::create(
      "release_failure_engine"
    );
    release_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567, mem,
                                   scheduler, profile, runtime_desc,
                                   status);
    expect_status("ROLLBACK_RELEASE_FAILURE", status,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    retained_snapshot = release_failure_engine.mapping_snapshot();
    if (status == null ||
        status.message !=
          {"CMQ prepare rollback release failed: ",
           "injected rollback release failure; original failure: ",
           "rollback trigger"} ||
        !release_failure_engine.retry_only_poisoned() ||
        retained_snapshot == null ||
        count_host_calls(mem, "release") != 1)
      `uvm_error("ROLLBACK_RELEASE_AUTHORITY",
                 "failed rollback did not retain POISONED authority")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("ROLLBACK_RELEASE_AUTHORITY",
                 "failed rollback lost allocation identity")
    release_failure_engine.shutdown(status);
    expect_status("ROLLBACK_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("ROLLBACK_RELEASE_RETRY_STATE",
                        release_failure_engine);
    if (count_host_calls(mem, "release") != 2)
      `uvm_error("ROLLBACK_RELEASE_RETRY",
                 "shutdown did not retry the retained release once")
    expect_release_retry_identity("ROLLBACK_RELEASE_RETRY_IDENTITY", mem,
                                  retained_mock);
  endtask

  task automatic check_null_status_guards();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_cmq_allocate_result_mem allocate_mem;
    rdma_cmq_null_write_mem null_write_mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;

    scheduler = rdma_doorbell_scheduler::type_id::create(
      "null_status_scheduler"
    );
    binding = make_binding("null_status_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("null_status_cmq", binding);

    mem = rdma_mock_host_mem::type_id::create("null_profile_mem");
    profile = rdma_cmq_test_profile::type_id::create(
      "null_status_profile"
    );
    profile.return_null_status = 1'b1;
    engine = rdma_cmq_engine::type_id::create("null_profile_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("NULL_PROFILE_STATUS", status, RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ hardware profile returned null status" ||
        profile.validation_calls != 1 || runtime_desc != null ||
        mem.calls.size() != 0)
      `uvm_error("NULL_PROFILE_STATUS",
                 "null profile status did not fail before allocation")
    expect_unconfigured("NULL_PROFILE_STATUS_STATE", engine);

    profile = rdma_cmq_test_profile::type_id::create(
      "null_status_good_profile"
    );
    allocate_mem = rdma_cmq_allocate_result_mem::type_id::create(
      "null_allocate_no_candidate_mem"
    );
    allocate_mem.result_kind = RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE;
    engine = rdma_cmq_engine::type_id::create(
      "null_allocate_no_candidate_engine"
    );
    engine.prepare(binding, cmq, 1'b1, 20'h34567, allocate_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("NULL_ALLOCATE_NO_CANDIDATE", status,
                  RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ host allocation returned null status" ||
        runtime_desc != null || allocate_mem.regions.size() != 0 ||
        count_host_calls(allocate_mem, "allocate") != 1 ||
        count_host_calls(allocate_mem, "write") != 0 ||
        count_host_calls(allocate_mem, "release") != 0)
      `uvm_error("NULL_ALLOCATE_NO_CANDIDATE",
                 "null allocation without candidate did not fail closed")
    expect_unconfigured("NULL_ALLOCATE_NO_CANDIDATE_STATE", engine);

    allocate_mem = rdma_cmq_allocate_result_mem::type_id::create(
      "null_allocate_candidate_mem"
    );
    allocate_mem.result_kind = RDMA_CMQ_ALLOCATE_NULL_WITH_CANDIDATE;
    engine = rdma_cmq_engine::type_id::create(
      "null_allocate_candidate_engine"
    );
    engine.prepare(binding, cmq, 1'b1, 20'h34567, allocate_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("NULL_ALLOCATE_WITH_CANDIDATE", status,
                  RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ host allocation returned null status")
      `uvm_error("NULL_ALLOCATE_WITH_CANDIDATE",
                 "null allocation candidate lost normalized status")
    expect_post_allocate_rollback("NULL_ALLOCATE_CANDIDATE_ROLLBACK",
                                  engine, allocate_mem, runtime_desc, 0);

    allocate_mem = rdma_cmq_allocate_result_mem::type_id::create(
      "failed_allocate_candidate_mem"
    );
    allocate_mem.result_kind = RDMA_CMQ_ALLOCATE_FAILURE_WITH_CANDIDATE;
    engine = rdma_cmq_engine::type_id::create(
      "failed_allocate_candidate_engine"
    );
    engine.prepare(binding, cmq, 1'b1, 20'h34567, allocate_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("FAILED_ALLOCATE_WITH_CANDIDATE", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (status == null ||
        status.message != "injected allocation failure with candidate")
      `uvm_error("FAILED_ALLOCATE_WITH_CANDIDATE",
                 "allocation candidate failure lost adapter status")
    expect_post_allocate_rollback("FAILED_ALLOCATE_CANDIDATE_ROLLBACK",
                                  engine, allocate_mem, runtime_desc, 0);

    null_write_mem = rdma_cmq_null_write_mem::type_id::create(
      "null_write_mem"
    );
    engine = rdma_cmq_engine::type_id::create("null_write_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, null_write_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("NULL_WRITE_STATUS", status, RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ backing zero-write returned null status")
      `uvm_error("NULL_WRITE_STATUS",
                 "null write did not return normalized status")
    expect_post_allocate_rollback("NULL_WRITE_ROLLBACK", engine,
                                  null_write_mem, runtime_desc, 1);
  endtask

  task automatic check_activation_guards();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_function_binding candidate;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping good_mapping;
    rdma_dma_mapping before_mapping;
    rdma_dma_mapping after_mapping;
    rdma_status status;
    rdma_status_code_e expected_codes[RDMA_CMQ_TAMPER_COUNT];

    engine = rdma_cmq_engine_probe::type_id::create("activate_engine");
    mem = rdma_mock_host_mem::type_id::create("activate_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "activate_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("activate_profile");
    prepared_binding = make_binding("activate_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("activate_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("activate_cmq", prepared_binding);
    prepare_defaults("ACTIVATE_PREPARE", engine, mem, prepared_binding,
                     cmq, scheduler, profile, runtime_desc);

    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_KIND] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_UID] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_OBJECT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_GENERATION] =
      RDMA_SC_STALE_GENERATION;
    expected_codes[RDMA_CMQ_TAMPER_BDF] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_PASID_VALID] = RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_PASID] = RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_NULL] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_KIND] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_UID] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_OBJECT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_GENERATION] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_DIRECTION] = RDMA_SC_INVALID_STATE;
    expected_codes[RDMA_CMQ_TAMPER_STATE] = RDMA_SC_INVALID_STATE;
    expected_codes[RDMA_CMQ_TAMPER_SIZE] = RDMA_SC_INVALID_STATE;
    expected_codes[RDMA_CMQ_TAMPER_PERMISSION_READ] =
      RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_PERMISSION_WRITE] =
      RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_IOVA_ALIGNMENT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_BACKING_ALIGNMENT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_IOVA_RANGE] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_BACKING_RANGE] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_PERMISSION_ATOMIC] =
      RDMA_SC_DMA_PERMISSION;

    candidate = make_binding("not_active_candidate", RDMA_BIND_PREPARED);
    engine.activate(candidate, status);
    expect_status("ACTIVATE_NOT_ACTIVE", status, RDMA_SC_INVALID_STATE);

    candidate = make_binding("uid_candidate", RDMA_BIND_ACTIVE);
    candidate.function_uid++;
    candidate.owner_h = candidate.make_handle();
    engine.activate(candidate, status);
    expect_status("ACTIVATE_UID", status, RDMA_SC_INVALID_ARGUMENT);

    candidate = make_binding("object_candidate", RDMA_BIND_ACTIVE);
    candidate.global_function_id++;
    candidate.owner_h = candidate.make_handle();
    engine.activate(candidate, status);
    expect_status("ACTIVATE_OBJECT", status, RDMA_SC_INVALID_ARGUMENT);

    candidate = make_binding("generation_candidate", RDMA_BIND_ACTIVE);
    candidate.generation++;
    candidate.owner_h = candidate.make_handle();
    engine.activate(candidate, status);
    expect_status("ACTIVATE_GENERATION", status,
                  RDMA_SC_STALE_GENERATION);

    candidate = make_binding("bdf_candidate", RDMA_BIND_ACTIVE);
    candidate.pcie.bdf.bus++;
    engine.activate(candidate, status);
    expect_status("ACTIVATE_BDF", status, RDMA_SC_DMA_TRANSLATION);

    good_mapping = engine.mapping_snapshot();
    for (int unsigned kind = 0; kind < RDMA_CMQ_TAMPER_COUNT; kind++) begin
      engine.tamper_mapping(rdma_cmq_mapping_tamper_e'(kind));
      before_mapping = engine.mapping_snapshot();
      engine.activate(active_binding, status);
      expect_status($sformatf("ACTIVATE_MAPPING_%0d", kind), status,
                    expected_codes[kind]);
      after_mapping = engine.mapping_snapshot();
      if (engine.state() != RDMA_CMQ_ENGINE_PREPARED ||
          engine.published_count() != 0 || engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0)
        `uvm_error("ACTIVATE_MAPPING_ATOMIC",
                   "failed activate changed state or counters")
      if (!same_mapping_fields(before_mapping, after_mapping))
        `uvm_error("ACTIVATE_MAPPING_AUTHORITY",
                   "failed activate changed retained mapping authority")
      engine.restore_mapping(good_mapping);
    end

    engine.activate(active_binding, status);
    expect_status("ACTIVATE_SUCCESS", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_ACTIVE)
      `uvm_error("ACTIVATE_SUCCESS_STATE",
                 "matching ACTIVE binding was not committed")
    engine.shutdown(status);
    expect_status("ACTIVATE_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("ACTIVATE_SHUTDOWN_STATE", engine);
    if (count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("ACTIVATE_SHUTDOWN_RELEASE",
                 "ACTIVE shutdown did not release backing exactly once")
    engine.shutdown(status);
    expect_status("ACTIVATE_SHUTDOWN_IDEMPOTENT", status, RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 1)
      `uvm_error("ACTIVATE_SHUTDOWN_IDEMPOTENT",
                 "idempotent ACTIVE shutdown released backing again")
  endtask

  task automatic check_prepared_shutdown_lifecycle();
    rdma_cmq_engine engine;
    rdma_mock_host_mem first_mem;
    rdma_mock_host_mem second_mem;
    rdma_doorbell_scheduler first_scheduler;
    rdma_doorbell_scheduler second_scheduler;
    rdma_cmq_test_profile first_profile;
    rdma_cmq_test_profile second_profile;
    rdma_function_binding first_binding;
    rdma_function_binding second_binding;
    rdma_function_binding active_binding;
    rdma_cmq first_cmq;
    rdma_cmq second_cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;
    int unsigned first_call_count;

    engine = rdma_cmq_engine::type_id::create("prepared_shutdown_engine");
    first_mem = rdma_mock_host_mem::type_id::create(
      "prepared_shutdown_first_mem"
    );
    first_scheduler = rdma_doorbell_scheduler::type_id::create(
      "prepared_shutdown_first_scheduler"
    );
    first_profile = rdma_cmq_test_profile::type_id::create(
      "prepared_shutdown_first_profile"
    );
    first_binding = make_binding("prepared_shutdown_first_binding",
                                 RDMA_BIND_PREPARED);
    first_cmq = make_cmq("prepared_shutdown_first_cmq", first_binding);
    prepare_defaults("PREPARED_SHUTDOWN_PREPARE", engine, first_mem,
                     first_binding, first_cmq, first_scheduler,
                     first_profile, runtime_desc);

    engine.shutdown(status);
    expect_status("PREPARED_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("PREPARED_SHUTDOWN_STATE", engine);
    if (count_host_calls(first_mem, "release") != 1 ||
        first_mem.regions.size() != 1 ||
        first_mem.regions[0].mapping == null ||
        first_mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED ||
        engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0)
      `uvm_error("PREPARED_SHUTDOWN_RELEASE",
                 "PREPARED shutdown did not clear backing and counters")
    first_call_count = first_mem.calls.size();
    engine.shutdown(status);
    expect_status("PREPARED_SHUTDOWN_IDEMPOTENT", status, RDMA_SC_OK);
    if (first_mem.calls.size() != first_call_count ||
        count_host_calls(first_mem, "release") != 1)
      `uvm_error("PREPARED_SHUTDOWN_IDEMPOTENT",
                 "idempotent PREPARED shutdown reused old authority")
    active_binding = make_binding("prepared_shutdown_active_probe",
                                  RDMA_BIND_ACTIVE);
    engine.activate(active_binding, status);
    expect_status("PREPARED_SHUTDOWN_CLEARED_ACTIVATE", status,
                  RDMA_SC_INVALID_STATE);
    if (first_mem.calls.size() != first_call_count)
      `uvm_error("PREPARED_SHUTDOWN_CLEARED_ACTIVATE",
                 "post-shutdown activate reused old host authority")

    second_mem = rdma_mock_host_mem::type_id::create(
      "prepared_shutdown_second_mem"
    );
    second_scheduler = rdma_doorbell_scheduler::type_id::create(
      "prepared_shutdown_second_scheduler"
    );
    second_profile = rdma_cmq_test_profile::type_id::create(
      "prepared_shutdown_second_profile"
    );
    second_binding = make_binding("prepared_shutdown_second_binding",
                                  RDMA_BIND_PREPARED);
    second_binding.function_uid++;
    second_binding.global_function_id++;
    second_binding.generation++;
    second_binding.owner_h = second_binding.make_handle();
    second_cmq = make_cmq("prepared_shutdown_second_cmq", second_binding);
    prepare_defaults("PREPARED_SHUTDOWN_REPREPARE", engine, second_mem,
                     second_binding, second_cmq, second_scheduler,
                     second_profile, runtime_desc);
    if (first_mem.calls.size() != first_call_count ||
        first_profile.validation_calls != 1 ||
        second_profile.validation_calls != 1 ||
        engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0)
      `uvm_error("PREPARED_SHUTDOWN_REPREPARE",
                 "reprepare reused stale collaborators or counters")
    engine.shutdown(status);
    expect_status("PREPARED_SHUTDOWN_REPREPARE_RELEASE", status,
                  RDMA_SC_OK);
    if (count_host_calls(first_mem, "release") != 1 ||
        count_host_calls(second_mem, "release") != 1)
      `uvm_error("PREPARED_SHUTDOWN_REPREPARE_RELEASE",
                 "reprepare released through the wrong collaborator")
  endtask

  task automatic check_shutdown_release_retry();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "shutdown_retry_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("shutdown_retry_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "shutdown_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "shutdown_retry_profile"
    );
    binding = make_binding("shutdown_retry_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("shutdown_retry_cmq", binding);
    prepare_defaults("SHUTDOWN_RETRY_PREPARE", engine, mem, binding, cmq,
                     scheduler, profile, runtime_desc);
    expect_status("ARM_SHUTDOWN_RELEASE_FAILURE",
                  mem.fail_next("release", rdma_status::make(
                    RDMA_SC_UNKNOWN_HW_ERROR,
                    "injected shutdown release failure"
                  )), RDMA_SC_OK);
    engine.seed_runtime_counters();

    engine.shutdown(status);
    expect_status("SHUTDOWN_RELEASE_FAILURE", status,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    retained_snapshot = engine.mapping_snapshot();
    if (status == null ||
        status.message != "injected shutdown release failure" ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        retained_snapshot == null ||
        !engine.retry_only_poisoned() ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("SHUTDOWN_RELEASE_FAILURE",
                 "shutdown release failure lost retained authority")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("SHUTDOWN_RELEASE_FAILURE",
                 "retained shutdown mapping lost allocation identity")

    engine.shutdown(status);
    expect_status("SHUTDOWN_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("SHUTDOWN_RELEASE_RETRY_STATE", engine);
    if (count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("SHUTDOWN_RELEASE_RETRY",
                 "shutdown did not retry and retire the same allocation")
    expect_release_retry_identity("SHUTDOWN_RELEASE_RETRY_IDENTITY", mem,
                                  retained_mock);

    engine.shutdown(status);
    expect_status("SHUTDOWN_RELEASE_RETRY_IDEMPOTENT", status,
                  RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 2)
      `uvm_error("SHUTDOWN_RELEASE_RETRY_IDEMPOTENT",
                 "third shutdown released retired backing again")
  endtask

  task automatic check_active_shutdown_release_retry();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "active_shutdown_retry_engine"
    );
    mem = rdma_mock_host_mem::type_id::create(
      "active_shutdown_retry_mem"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "active_shutdown_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "active_shutdown_retry_profile"
    );
    prepared_binding = make_binding("active_shutdown_retry_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("active_shutdown_retry_active",
                                  RDMA_BIND_ACTIVE);
    cmq = make_cmq("active_shutdown_retry_cmq", prepared_binding);
    prepare_defaults("ACTIVE_SHUTDOWN_RETRY_PREPARE", engine, mem,
                     prepared_binding, cmq, scheduler, profile,
                     runtime_desc);
    engine.activate(active_binding, status);
    expect_status("ACTIVE_SHUTDOWN_RETRY_ACTIVATE", status, RDMA_SC_OK);
    expect_status("ARM_ACTIVE_SHUTDOWN_RELEASE_FAILURE",
                  mem.fail_next("release", rdma_status::make(
                    RDMA_SC_UNKNOWN_HW_ERROR,
                    "injected ACTIVE shutdown release failure"
                  )), RDMA_SC_OK);
    engine.seed_runtime_counters();

    engine.shutdown(status);
    expect_status("ACTIVE_SHUTDOWN_RELEASE_FAILURE", status,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    retained_snapshot = engine.mapping_snapshot();
    if (status == null ||
        status.message != "injected ACTIVE shutdown release failure" ||
        !engine.retry_only_poisoned() || retained_snapshot == null ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("ACTIVE_SHUTDOWN_RELEASE_FAILURE",
                 "ACTIVE release failure did not retain retry-only state")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("ACTIVE_SHUTDOWN_RELEASE_FAILURE",
                 "ACTIVE release failure lost allocation identity")

    engine.shutdown(status);
    expect_status("ACTIVE_SHUTDOWN_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("ACTIVE_SHUTDOWN_RELEASE_RETRY_STATE", engine);
    if (count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("ACTIVE_SHUTDOWN_RELEASE_RETRY",
                 "ACTIVE shutdown retry did not release backing")
    expect_release_retry_identity(
      "ACTIVE_SHUTDOWN_RELEASE_RETRY_IDENTITY", mem, retained_mock
    );
  endtask

  task automatic check_null_shutdown_release_retry();
    rdma_cmq_engine_probe engine;
    rdma_cmq_null_release_once_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "null_release_retry_engine"
    );
    mem = rdma_cmq_null_release_once_mem::type_id::create(
      "null_release_retry_mem"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "null_release_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "null_release_retry_profile"
    );
    binding = make_binding("null_release_retry_binding",
                           RDMA_BIND_PREPARED);
    cmq = make_cmq("null_release_retry_cmq", binding);
    prepare_defaults("NULL_RELEASE_RETRY_PREPARE", engine, mem, binding,
                     cmq, scheduler, profile, runtime_desc);
    engine.seed_runtime_counters();

    engine.shutdown(status);
    expect_status("NULL_SHUTDOWN_RELEASE", status, RDMA_SC_INVALID_STATE);
    retained_snapshot = engine.mapping_snapshot();
    if (status == null ||
        status.message != "CMQ shutdown release returned null status" ||
        !engine.retry_only_poisoned() || retained_snapshot == null ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("NULL_SHUTDOWN_RELEASE",
                 "null release did not retain retry-only authority")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("NULL_SHUTDOWN_RELEASE",
                 "null release lost mapping allocation identity")

    engine.shutdown(status);
    expect_status("NULL_SHUTDOWN_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("NULL_SHUTDOWN_RELEASE_RETRY_STATE", engine);
    if (count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("NULL_SHUTDOWN_RELEASE_RETRY",
                 "null release retry did not release backing")
    expect_release_retry_identity("NULL_SHUTDOWN_RELEASE_RETRY_IDENTITY",
                                  mem, retained_mock);
    engine.shutdown(status);
    expect_status("NULL_SHUTDOWN_RELEASE_IDEMPOTENT", status,
                  RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 2)
      `uvm_error("NULL_SHUTDOWN_RELEASE_IDEMPOTENT",
                 "idempotent shutdown retried a released mapping")
  endtask

  task automatic check_missing_host_mem_shutdown();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping original_mapping;
    rdma_mock_dma_mapping retained_mapping;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "missing_host_mem_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("missing_host_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "missing_host_mem_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "missing_host_mem_profile"
    );
    binding = make_binding("missing_host_mem_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("missing_host_mem_cmq", binding);
    prepare_defaults("MISSING_HOST_MEM_PREPARE", engine, mem, binding, cmq,
                     scheduler, profile, runtime_desc);
    retained_snapshot = engine.mapping_snapshot();
    if (!$cast(original_mapping, retained_snapshot))
      `uvm_error("MISSING_HOST_MEM_PREPARE",
                 "prepared mapping lost allocation identity")
    engine.seed_runtime_counters();
    engine.drop_host_mem_authority();

    engine.shutdown(status);
    expect_status("MISSING_HOST_MEM_SHUTDOWN", status,
                  RDMA_SC_INVALID_STATE);
    retained_snapshot = engine.mapping_snapshot();
    if (!$cast(retained_mapping, retained_snapshot))
      `uvm_error("MISSING_HOST_MEM_SHUTDOWN",
                 "missing adapter path lost retained mapping")
    if (status == null ||
        status.message != "CMQ shutdown release authority is missing" ||
        !engine.missing_host_mem_poisoned() ||
        count_host_calls(mem, "release") != 0 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE ||
        original_mapping == null || retained_mapping == null ||
        !original_mapping.same_allocation(retained_mapping))
      `uvm_error("MISSING_HOST_MEM_SHUTDOWN",
                 "missing adapter path did not fail closed visibly")

    engine.shutdown(status);
    expect_status("MISSING_HOST_MEM_SHUTDOWN_REPEAT", status,
                  RDMA_SC_INVALID_STATE);
    if (!engine.missing_host_mem_poisoned() ||
        count_host_calls(mem, "release") != 0)
      `uvm_error("MISSING_HOST_MEM_SHUTDOWN_REPEAT",
                 "missing adapter failure was not deterministic")

    engine.restore_host_mem_authority(mem);
    engine.shutdown(status);
    expect_status("MISSING_HOST_MEM_RECOVERY", status, RDMA_SC_OK);
    expect_unconfigured("MISSING_HOST_MEM_RECOVERY_STATE", engine);
    if (count_host_calls(mem, "release") != 1 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("MISSING_HOST_MEM_RECOVERY",
                 "restored adapter did not release retained mapping")
  endtask

  task automatic check_batch_compaction_and_doorbell();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    string expected_trace[5] = '{
      "host_write", "host_write", "pcie_dma_barrier",
      "pcie_mmio_barrier", "pcie_mmio_write"
    };

    engine = rdma_cmq_engine_probe::type_id::create("batch_engine");
    mem = rdma_mock_host_mem::type_id::create("batch_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("batch_pcie");
    trace = rdma_mock_call_trace::type_id::create("batch_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create("batch_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("batch_profile");
    prepared_binding = make_binding("batch_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("batch_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("batch_cmq", prepared_binding);
    prepare_active("BATCH", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[3];
    requests[0] = make_command("batch_a", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'ha1);
    requests[1] = make_command(
      "batch_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'hb2
    );
    requests[2] = make_command("batch_b", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_B, 8'hc3);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);

    expect_status("BATCH_STATUS", batch_status, RDMA_SC_OK);
    if (tickets.size() != 3 || item_statuses.size() != 3)
      `uvm_error("BATCH_ALIGNMENT", "batch outputs are not input-aligned")
    else begin
      expect_status("BATCH_ITEM_A", item_statuses[0], RDMA_SC_OK);
      expect_status("BATCH_ITEM_UNSUPPORTED", item_statuses[1],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("BATCH_ITEM_B", item_statuses[2], RDMA_SC_OK);
      if (tickets[0] == null || tickets[1] != null || tickets[2] == null)
        `uvm_error("BATCH_TICKETS", "batch ticket publication is misaligned")
      else begin
        if (tickets[0].slot_sequence != 0 || tickets[0].sq_index != 0 ||
            tickets[0].sq_wrap || tickets[2].slot_sequence != 1 ||
            tickets[2].sq_index != 1 || tickets[2].sq_wrap)
          `uvm_error("BATCH_COMPACTION",
                     "successful commands did not compact into SQ slots 0/1")
        if (tickets[0].command_id == 0 || tickets[2].command_id == 0 ||
            tickets[0].command_id[4:0] != 0 ||
            tickets[2].command_id[4:0] != 1)
          `uvm_error("BATCH_COMMAND_IDS",
                     "tickets did not use distinct reserved command tokens")
        if (tickets[0].function_h == requests[0].function_h ||
            tickets[0].opcode_key == requests[0].opcode_key ||
            tickets[0].cmq_h == cmq.handle)
          `uvm_error("BATCH_TICKET_DETACH",
                     "published ticket aliases caller-owned input")
      end
    end

    expect_submit_trace("BATCH_TRACE", trace, expected_trace);
    if (mem.calls.size() != 2 ||
        mem.calls[0].method_name != "write" ||
        mem.calls[0].offset != 0 || mem.calls[0].data.size() != 64 ||
        mem.calls[0].data[0] != 8'h10 ||
        mem.calls[0].data[1] != 8'ha1 ||
        mem.calls[0].data[2] != 8'h5e ||
        mem.calls[0].data[4] != 8'h00 ||
        mem.calls[0].data[6] != 8'h00 ||
        mem.calls[1].method_name != "write" ||
        mem.calls[1].offset != 64 || mem.calls[1].data.size() != 64 ||
        mem.calls[1].data[0] != 8'h20 ||
        mem.calls[1].data[1] != 8'hc3 ||
        mem.calls[1].data[2] != 8'h3c ||
        mem.calls[1].data[4] != 8'h01 ||
        mem.calls[1].data[6] != 8'h01)
      `uvm_error("BATCH_SQE_WRITES",
                 "compacted SQE writes or detached bytes are incorrect")
    if (pcie.calls.size() != 3 ||
        pcie.calls[2].method_name != "mmio_write" ||
        pcie.calls[2].function_h == null ||
        !pcie.calls[2].function_h.same_instance(active_binding.make_handle()) ||
        pcie.calls[2].address.value != active_binding.notify_base.value +
                                         64'h80 ||
        pcie.calls[2].data.size() != 8 ||
        pcie.calls[2].data[0] != 8'h02 ||
        pcie.calls[2].data[1] != 8'h00 ||
        pcie.calls[2].data[2] != TEST_CMQ_ID[7:0] ||
        pcie.calls[2].data[3] != TEST_CMQ_ID[15:8])
      `uvm_error("BATCH_DOORBELL",
                 "final CMQ doorbell target or payload is incorrect")
    if (profile.doorbell_calls != 1 || profile.last_final_pi != 2 ||
        profile.last_polarity || profile.last_doorbell_target == null ||
        !profile.last_doorbell_target.same_instance(cmq.handle))
      `uvm_error("BATCH_PROFILE_DOORBELL",
                 "profile did not receive the final compacted PI/identity")
    if (engine.published_count() != 2 ||
        engine.tokens_in_use_count() != 2 ||
        engine.slot_record_count() != 2 ||
        engine.slot_expected_variant(0) != "expected_10_a1" ||
        engine.slot_expected_variant(1) != "expected_20_c3")
      `uvm_error("BATCH_LEDGER", "batch slot ledger was not committed")

    engine.shutdown(status);
    expect_status("BATCH_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_empty_invalid_and_state_rejections();
    rdma_cmq_engine_probe engine;
    rdma_cmq_engine unconfigured_engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc request;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket ticket;
    rdma_cmq_ticket tickets[];
    rdma_status status;
    rdma_status item_statuses[];
    rdma_status batch_status;

    prepared_binding = make_binding("state_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("state_active", RDMA_BIND_ACTIVE);
    request = make_command("state_request", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'h11);
    unconfigured_engine = rdma_cmq_engine::type_id::create(
      "unconfigured_submit_engine"
    );
    unconfigured_engine.submit(request, ticket, status);
    expect_status("SUBMIT_UNCONFIGURED", status, RDMA_SC_INVALID_STATE);
    if (ticket != null)
      `uvm_error("SUBMIT_UNCONFIGURED", "inactive engine returned a ticket")
    requests = new[1];
    requests[0] = request;
    unconfigured_engine.submit_batch(requests, tickets, item_statuses,
                                     batch_status);
    expect_status("BATCH_UNCONFIGURED", batch_status,
                  RDMA_SC_INVALID_STATE);
    if (tickets.size() != 1 || item_statuses.size() != 1 ||
        tickets[0] != null)
      `uvm_error("BATCH_UNCONFIGURED", "inactive batch outputs misaligned")

    engine = rdma_cmq_engine_probe::type_id::create("invalid_engine");
    mem = rdma_mock_host_mem::type_id::create("invalid_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("invalid_pcie");
    trace = rdma_mock_call_trace::type_id::create("invalid_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create("invalid_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("invalid_profile");
    cmq = make_cmq("invalid_cmq", prepared_binding);
    expect_status("INVALID_SCHEDULER_CONFIGURE",
                  scheduler.configure(mem, pcie), RDMA_SC_OK);
    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567, mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("INVALID_PREPARE", status, RDMA_SC_OK);
    clear_submit_observation(mem, pcie, trace);
    engine.submit(request, ticket, status);
    expect_status("SUBMIT_PREPARED", status, RDMA_SC_INVALID_STATE);
    if (ticket != null)
      `uvm_error("SUBMIT_PREPARED", "PREPARED engine returned a ticket")
    expect_no_submit_side_effects("SUBMIT_PREPARED", mem, pcie, trace);

    requests = new[0];
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("EMPTY_PREPARED", batch_status, RDMA_SC_INVALID_STATE);
    if (tickets.size() != 0 || item_statuses.size() != 0)
      `uvm_error("EMPTY_PREPARED", "empty inactive outputs are not empty")
    expect_no_submit_side_effects("EMPTY_PREPARED", mem, pcie, trace);

    engine.activate(active_binding, status);
    expect_status("INVALID_ACTIVATE", status, RDMA_SC_OK);
    requests = new[0];
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("EMPTY_ACTIVE", batch_status, RDMA_SC_OK);
    if (tickets.size() != 0 || item_statuses.size() != 0)
      `uvm_error("EMPTY_ACTIVE", "empty batch outputs are not empty")
    expect_no_submit_side_effects("EMPTY_ACTIVE", mem, pcie, trace);

    requests = new[3];
    requests[0] = null;
    requests[1] = make_command("invalid_body", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h22);
    requests[1].body = null;
    requests[2] = make_command(
      "invalid_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'h33
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ALL_INVALID_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 3 || item_statuses.size() != 3)
      `uvm_error("ALL_INVALID_ALIGNMENT", "invalid outputs misaligned")
    else begin
      expect_status("ALL_INVALID_NULL", item_statuses[0],
                    RDMA_SC_INVALID_ARGUMENT);
      expect_status("ALL_INVALID_BODY", item_statuses[1],
                    RDMA_SC_INVALID_ARGUMENT);
      expect_status("ALL_INVALID_OPCODE", item_statuses[2],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("ALL_INVALID_TICKET", "invalid item returned a ticket")
    end
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("ALL_INVALID_LEDGER", "invalid batch changed the ledger")
    expect_no_submit_side_effects("ALL_INVALID_EFFECTS", mem, pcie, trace);

    engine.shutdown(status);
    expect_status("INVALID_SHUTDOWN", status, RDMA_SC_OK);
  endtask


  task automatic check_poll_empty_ledger_and_partial_drain();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket ticket;
    rdma_cmq_ticket tickets[];
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqes[2];
    rdma_status status;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status injected;

    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_empty_ledger_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_empty_ledger_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poll_empty_ledger_pcie");
    trace = rdma_mock_call_trace::type_id::create(
      "poll_empty_ledger_trace"
    );
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_empty_ledger_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_empty_ledger_profile"
    );
    prepared_binding = make_binding(
      "poll_empty_ledger_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_empty_ledger_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_empty_ledger_cmq", prepared_binding);
    expect_status(
      "POLL_EMPTY_LEDGER_SCHEDULER_CONFIGURE",
      scheduler.configure(mem, pcie), RDMA_SC_OK
    );
    engine.prepare(
      prepared_binding, cmq, 1'b1, 20'h34567, mem, scheduler, profile,
      runtime_desc, status
    );
    expect_status("POLL_EMPTY_LEDGER_PREPARE", status, RDMA_SC_OK);
    engine.activate(active_binding, status);
    expect_status("POLL_EMPTY_LEDGER_ACTIVATE", status, RDMA_SC_OK);
    clear_submit_observation(mem, pcie, trace);
    mapping = engine.mapping_snapshot();
    expect_empty_poll_without_read("POLL_EMPTY_AFTER_ACTIVATE", engine, mem);
    begin
      rdma_cmq_completion queued_completion;

      queued_completion = rdma_cmq_completion::type_id::create(
        "poll_empty_queued_completion"
      );
      engine.seed_terminal_completion(queued_completion);
      mem.calls.delete();
      engine.poll(completions, diagnostics, status);
      expect_status("POLL_EMPTY_DRAIN_FIFO_STATUS", status, RDMA_SC_OK);
      if (completions.size() != 1 ||
          completions[0] != queued_completion || diagnostics.size() != 0 ||
          mem.calls.size() != 0 ||
          engine.state() != RDMA_CMQ_ENGINE_ACTIVE ||
          engine.published_count() != 0 || engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0 ||
          engine.terminal_fifo_count() != 0)
        `uvm_error(
          "POLL_EMPTY_DRAIN_FIFO",
          "empty hardware ledger did not drain the terminal FIFO"
        )
    end
    requests = new[0];
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("EMPTY_ACTIVE", batch_status, RDMA_SC_OK);
    if (tickets.size() != 0 || item_statuses.size() != 0)
      `uvm_error("EMPTY_ACTIVE", "empty batch outputs are not empty")
    expect_no_submit_side_effects("EMPTY_ACTIVE", mem, pcie, trace);

    requests = new[4];
    requests[0] = null;
    requests[1] = make_command("invalid_body", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h22);
    requests[1].body = null;
    requests[2] = make_command(
      "invalid_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'h33
    );
    requests[3] = make_command(
      "invalid_codec", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h44
    );
    profile.fail_compose_opcode = rdma_cmq_test_profile::TEST_OPCODE_B;
    profile.compose_failure_code = RDMA_SC_CODEC_ERROR;
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ALL_INVALID_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 4 || item_statuses.size() != 4)
      `uvm_error("ALL_INVALID_ALIGNMENT", "invalid outputs misaligned")
    else begin
      expect_status("ALL_INVALID_NULL", item_statuses[0],
                    RDMA_SC_INVALID_ARGUMENT);
      expect_status("ALL_INVALID_BODY", item_statuses[1],
                    RDMA_SC_INVALID_ARGUMENT);
      expect_status("ALL_INVALID_OPCODE", item_statuses[2],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("ALL_INVALID_CODEC", item_statuses[3],
                    RDMA_SC_CODEC_ERROR);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("ALL_INVALID_TICKET", "invalid item returned a ticket")
    end
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("ALL_INVALID_LEDGER", "invalid batch changed the ledger")
    expect_no_submit_side_effects("ALL_INVALID_EFFECTS", mem, pcie, trace);
    profile.fail_compose_opcode = '0;
    expect_empty_poll_without_read("POLL_EMPTY_AFTER_ALL_FAIL", engine, mem);

    injected = rdma_status::make(
      RDMA_SC_TIMEOUT, "injected empty-ledger transport failure"
    );
    expect_status(
      "POLL_EMPTY_ARM_TRANSPORT",
      pcie.fail_next("dma_visibility_barrier", injected), RDMA_SC_OK
    );
    request = make_command(
      "poll_empty_transport_failure", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h45, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_EMPTY_TRANSPORT_SUBMIT", status, RDMA_SC_TIMEOUT);
    if (ticket != null)
      `uvm_error(
        "POLL_EMPTY_TRANSPORT_TICKET",
        "transport-failed submission returned a ticket"
      )
    expect_empty_poll_without_read(
      "POLL_EMPTY_AFTER_TRANSPORT_FAIL", engine, mem
    );

    requests = new[2];
    requests[0] = make_command(
      "poll_partial_drain_request_0", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h46, 10us
    );
    requests[1] = make_command(
      "poll_partial_drain_request_1", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h47, 10us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("POLL_PARTIAL_DRAIN_SUBMIT", batch_status, RDMA_SC_OK);
    if (tickets.size() != 2 || tickets[0] == null || tickets[1] == null)
      `uvm_error(
        "POLL_PARTIAL_DRAIN_TICKETS",
        "partial-drain submission did not return two tickets"
      )
    else begin
      write_profile_cqe(
        "POLL_PARTIAL_DRAIN_CQE_0", mem, mapping, profile, 0, 1'b1,
        tickets[0], 0, raw_cqes[0]
      );
      write_profile_cqe(
        "POLL_PARTIAL_DRAIN_CQE_1", mem, mapping, profile, 1, 1'b1,
        tickets[1], 0, raw_cqes[1]
      );
    end
    profile.inspect_failure_call = profile.inspect_calls + 2;
    // A transient inspection failure remains retryable.  Codec failures are
    // malformed hardware evidence and intentionally poison the engine.
    profile.inspect_failure_code = RDMA_SC_TIMEOUT;
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_PARTIAL_DRAIN_STATUS", status, RDMA_SC_TIMEOUT);
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        completions[0] == null || completions[0].ticket == null ||
        completions[0].ticket.command_id != tickets[0].command_id ||
        engine.published_count() != 2 ||
        engine.cq_consumed_count() != 1 || engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1 ||
        engine.terminal_fifo_count() != 0)
      `uvm_error(
        "POLL_PARTIAL_DRAIN_ATOMIC",
        "partial drain lost its first output or changed the second command"
      )
    expect_poll_read_geometry("POLL_PARTIAL_DRAIN_READ", mem, 0, 2);

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_PARTIAL_DRAIN_RETRY_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        completions[0] == null || completions[0].ticket == null ||
        completions[0].ticket.command_id != tickets[1].command_id ||
        engine.published_count() != 2 ||
        engine.cq_consumed_count() != 2 || engine.retired_count() != 2 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0 ||
        engine.terminal_fifo_count() != 0)
      `uvm_error(
        "POLL_PARTIAL_DRAIN_RETRY",
        "partial-drain retry did not finish the retained command"
      )
    expect_poll_read_geometry("POLL_PARTIAL_DRAIN_RETRY_READ", mem, 1, 1);
    expect_empty_poll_without_read("POLL_EMPTY_AFTER_DRAIN", engine, mem);

    engine.shutdown(status);
    expect_status("INVALID_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_pre_read_poll_ledger_fail_closed();
    string fault_labels[4];

    fault_labels[0] = "COUNTER";
    fault_labels[1] = "SLOT";
    fault_labels[2] = "TOKEN";
    fault_labels[3] = "REGISTRY";
    for (int unsigned fault = 0; fault < 4; fault++) begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_cmq_command_desc request;
      rdma_cmq_ticket ticket;
      rdma_cmq_completion completions[$];
      rdma_cmq_diagnostic diagnostics[$];
      rdma_status status;
      string label;

      label = {"POLL_PRE_READ_LEDGER_", fault_labels[fault]};
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("pre_read_ledger_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("pre_read_ledger_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("pre_read_ledger_pcie_%0d", fault)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("pre_read_ledger_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("pre_read_ledger_profile_%0d", fault)
      );
      prepared_binding = make_binding(
        $sformatf("pre_read_ledger_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("pre_read_ledger_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq(
        $sformatf("pre_read_ledger_cmq_%0d", fault), prepared_binding
      );
      prepare_active(
        label, engine, mem, pcie, scheduler, profile, prepared_binding,
        active_binding, cmq, runtime_desc
      );

      engine.tamper_empty_ledger(
        rdma_cmq_test_empty_ledger_fault_e'(fault)
      );
      expect_inconsistent_empty_poll_without_read(label, engine, mem);

      request = make_command(
        $sformatf("pre_read_ledger_rejected_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'h70 + fault), 10us
      );
      engine.submit(request, ticket, status);
      expect_status({label, "_LATER_SUBMIT"}, status,
                    RDMA_SC_INVALID_STATE);
      if (ticket != null)
        `uvm_error(label, "pre-read poison returned a later ticket")
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_LATER_POLL"}, status, RDMA_SC_INVALID_STATE);
      if (completions.size() != 0 || diagnostics.size() != 0)
        `uvm_error(label, "pre-read poison returned later poll output")
      engine.expire(completions, status);
      expect_status({label, "_LATER_EXPIRE"}, status,
                    RDMA_SC_INVALID_STATE);
      if (completions.size() != 0)
        `uvm_error(label, "pre-read poison returned later expiry output")

      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    end
  endtask

  task automatic check_submit_wrapper_and_snapshot_detachment();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_blocking_pcie blocking_pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc request;
    rdma_cmq_sqe_model body;
    rdma_cmq_ticket ticket;
    rdma_status status;
    bit submit_done;
    longint unsigned internal_command_id;
    string expected_trace[4] = '{
      "host_write", "pcie_dma_barrier", "pcie_mmio_barrier",
      "pcie_mmio_write"
    };

    engine = rdma_cmq_engine_probe::type_id::create("wrapper_engine");
    mem = rdma_mock_host_mem::type_id::create("wrapper_mem");
    blocking_pcie = rdma_cmq_test_blocking_pcie::type_id::create(
      "wrapper_pcie"
    );
    trace = rdma_mock_call_trace::type_id::create("wrapper_trace");
    mem.set_call_trace(trace);
    blocking_pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "wrapper_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("wrapper_profile");
    prepared_binding = make_binding("wrapper_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("wrapper_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("wrapper_cmq", prepared_binding);
    prepare_active("WRAPPER", engine, mem, blocking_pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, blocking_pcie, trace);

    request = make_command(
      "wrapper_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'h33
    );
    engine.submit(request, ticket, status);
    expect_status("WRAPPER_UNSUPPORTED", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (ticket != null)
      `uvm_error("WRAPPER_UNSUPPORTED", "failed wrapper returned a ticket")
    expect_no_submit_side_effects("WRAPPER_UNSUPPORTED", mem,
                                  blocking_pcie, trace);

    request = make_command("wrapper_snapshot", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'h44,
                           10us);
    if (!$cast(body, request.body))
      `uvm_fatal("WRAPPER_SETUP", "snapshot body type is invalid")
    blocking_pcie.block_dma_barrier = 1'b1;
    blocking_pcie.release_dma_barrier = 1'b0;
    submit_done = 1'b0;
    ticket = null;
    status = null;
    fork
      begin
        engine.submit(request, ticket, status);
        submit_done = 1'b1;
      end
    join_none
    wait (blocking_pcie.dma_barrier_entered);
    if (submit_done || ticket != null || engine.published_count() != 0)
      `uvm_error("WRAPPER_PUBLICATION_GATE",
                 "wrapper published before the scheduler transaction")

    request.opcode_key.opcode = rdma_cmq_test_profile::TEST_OPCODE_B;
    request.opcode_key.variant = "caller_mutated";
    request.function_h.function_uid++;
    request.function_h.object_id++;
    request.function_h.generation++;
    body.flags = 8'h99;
    body.command_id = 64'h99;
    request.qpc_signature_source.bytes[0] = 8'h88;
    profile.last_expected_alias.variant = "profile_alias_mutated";
    blocking_pcie.release_dma_barrier = 1'b1;
    wait (submit_done);

    expect_status("WRAPPER_SNAPSHOT", status, RDMA_SC_OK);
    if (ticket == null)
      `uvm_error("WRAPPER_SNAPSHOT", "successful wrapper returned no ticket")
    else begin
      if (ticket.opcode_key.opcode !=
            rdma_cmq_test_profile::TEST_OPCODE_A ||
          ticket.opcode_key.variant != "variant_10" ||
          ticket.function_h.function_uid != TEST_FUNCTION_UID ||
          ticket.function_h.object_id != TEST_FUNCTION_ID ||
          ticket.function_h.generation != TEST_GENERATION)
        `uvm_error("WRAPPER_SNAPSHOT_TICKET",
                   "ticket was derived from caller-mutated input")
      if (engine.slot_ticket_command_id(0) != ticket.command_id)
        `uvm_error("WRAPPER_SNAPSHOT_TICKET",
                   "slot record does not own a detached ticket value")
      internal_command_id = engine.slot_ticket_command_id(0);
      ticket.command_id = 0;
      ticket.opcode_key.variant = "caller_mutated_ticket";
      if (engine.slot_ticket_command_id(0) != internal_command_id ||
          engine.slot_expected_variant(0) != "expected_10_44")
        `uvm_error("WRAPPER_OUTPUT_TICKET_DETACH",
                   "caller ticket mutation changed slot authority")
    end
    if (mem.calls.size() != 1 || mem.calls[0].offset != 0 ||
        mem.calls[0].data.size() != 64 ||
        mem.calls[0].data[0] != 8'h10 ||
        mem.calls[0].data[1] != 8'h44 ||
        mem.calls[0].data[2] != 8'hbb ||
        mem.calls[0].data[3] != TEST_FUNCTION_ID[7:0])
      `uvm_error("WRAPPER_SNAPSHOT_SQE",
                 "written SQE was derived from caller-mutated input")
    if (engine.slot_expected_variant(0) != "expected_10_44")
      `uvm_error("WRAPPER_SNAPSHOT_EXPECTED",
                 "slot expected response aliases profile-owned output")
    expect_submit_trace("WRAPPER_SNAPSHOT_TRACE", trace, expected_trace);
    if (blocking_pcie.calls.size() != 3)
      `uvm_error("WRAPPER_ONE_DOORBELL",
                 "one-item wrapper did not schedule exactly one doorbell")

    engine.shutdown(status);
    expect_status("WRAPPER_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_nested_command_snapshot_failures();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_clone_fault_function_handle fault_function;
    rdma_cmq_clone_fault_handle fault_handle;
    rdma_cmq_clone_fault_opcode_key fault_opcode;
    rdma_cmq_clone_fault_body fault_body;
    rdma_cmq_clone_fault_image fault_image;
    rdma_cmq_sqe_model source_body;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("nested_clone_engine");
    mem = rdma_mock_host_mem::type_id::create("nested_clone_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("nested_clone_pcie");
    trace = rdma_mock_call_trace::type_id::create("nested_clone_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "nested_clone_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "nested_clone_profile"
    );
    prepared_binding = make_binding("nested_clone_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("nested_clone_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("nested_clone_cmq", prepared_binding);
    prepare_active("NESTED_CLONE", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[18];
    foreach (requests[i])
      requests[i] = make_command(
        $sformatf("nested_clone_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'h70 + i)
      );

    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_function_null"
      );
    fault_function.copy(requests[0].function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    requests[0].function_h = fault_function;
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_function_self"
      );
    fault_function.copy(requests[1].function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    requests[1].function_h = fault_function;

    fault_opcode = rdma_cmq_clone_fault_opcode_key::type_id::create(
      "nested_opcode_null"
    );
    fault_opcode.copy(requests[2].opcode_key);
    fault_opcode.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    requests[2].opcode_key = fault_opcode;
    fault_opcode = rdma_cmq_clone_fault_opcode_key::type_id::create(
      "nested_opcode_self"
    );
    fault_opcode.copy(requests[3].opcode_key);
    fault_opcode.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    requests[3].opcode_key = fault_opcode;

    if (!$cast(source_body, requests[4].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "nested_body_null"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    requests[4].body = fault_body;
    if (!$cast(source_body, requests[5].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "nested_body_self"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    requests[5].body = fault_body;

    fault_image = rdma_cmq_clone_fault_image::type_id::create(
      "nested_signature_null"
    );
    fault_image.copy(requests[6].qpc_signature_source);
    fault_image.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    requests[6].qpc_signature_source = fault_image;
    fault_image = rdma_cmq_clone_fault_image::type_id::create(
      "nested_signature_self"
    );
    fault_image.copy(requests[7].qpc_signature_source);
    fault_image.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    requests[7].qpc_signature_source = fault_image;

    if (!$cast(source_body, requests[8].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_body_function_null"
      );
    fault_function.copy(source_body.function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    source_body.function_h = fault_function;
    if (!$cast(source_body, requests[9].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_body_function_wrong"
      );
    fault_function.copy(source_body.function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_WRONG_TYPE;
    source_body.function_h = fault_function;
    if (!$cast(source_body, requests[10].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_body_function_self"
      );
    fault_function.copy(source_body.function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    source_body.function_h = fault_function;

    if (!$cast(source_body, requests[11].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "nested_body_target_null"
    );
    fault_handle.copy(source_body.target_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    source_body.target_h = fault_handle;
    if (!$cast(source_body, requests[12].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "nested_body_target_wrong"
    );
    fault_handle.copy(source_body.target_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_WRONG_TYPE;
    source_body.target_h = fault_handle;
    if (!$cast(source_body, requests[13].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "nested_body_target_self"
    );
    fault_handle.copy(source_body.target_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    source_body.target_h = fault_handle;

    if (!$cast(source_body, requests[14].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "nested_body_context_null"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    source_body.context_model = fault_body;
    if (!$cast(source_body, requests[15].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "nested_body_context_wrong"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_WRONG_TYPE;
    source_body.context_model = fault_body;
    if (!$cast(source_body, requests[16].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "nested_body_context_self"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    source_body.context_model = fault_body;

    if (!$cast(source_body, requests[17].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_body_function_sibling_alias"
      );
    fault_function.copy(source_body.function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
    source_body.target_h = fault_function;
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_body_function_alias_source"
      );
    fault_function.copy(source_body.function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_ALIAS;
    fault_function.alias_once = 1'b1;
    if (!$cast(fault_function.alias_target, source_body.target_h))
      `uvm_fatal("NESTED_CLONE_SETUP", "alias target type is invalid")
    source_body.function_h = fault_function;

    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("NESTED_CLONE_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("NESTED_CLONE_ALIGNMENT",
                 "nested-clone outputs are misaligned")
    else begin
      foreach (requests[i]) begin
        expect_status($sformatf("NESTED_CLONE_ITEM_%0d", i),
                      item_statuses[i], RDMA_SC_INVALID_ARGUMENT);
        if (tickets[i] != null)
          `uvm_error("NESTED_CLONE_TICKET",
                     $sformatf("nested-clone item %0d returned ticket", i))
      end
    end
    expect_no_submit_side_effects("NESTED_CLONE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("NESTED_CLONE_LEDGER",
                 "nested clone failure changed the authority ledger")

    engine.shutdown(status);
    expect_status("NESTED_CLONE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_mutating_clone_source_restoration();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_function_handle saved_function_refs[];
    rdma_cmq_opcode_key saved_opcode_refs[];
    rdma_hw_model saved_body_refs[];
    rdma_hw_image saved_signature_refs[];
    rdma_function_handle saved_function_values[];
    rdma_cmq_opcode_key saved_opcode_values[];
    rdma_hw_image saved_signature_values[];
    rdma_function_handle saved_body_function_refs[];
    rdma_handle saved_body_target_refs[];
    rdma_hw_model saved_body_context_refs[];
    string saved_body_values[];
    bit saved_vfid_override[];
    bit [10:0] saved_use_vfid[];
    time saved_timeout[];
    rdma_cmq_sqe_model source_body;
    rdma_cmq_clone_fault_function_handle fault_function;
    rdma_cmq_clone_fault_opcode_key fault_opcode;
    rdma_cmq_clone_fault_image fault_image;
    rdma_cmq_clone_fault_body fault_body;
    rdma_cmq_clone_fault_qpc fault_qpc;
    rdma_cmq_clone_fault_handle fault_handle;
    rdma_cmq_clone_fault_ring fault_ring;
    rdma_qpc_model qpc;
    rdma_qpc_model outer_qpc;
    rdma_qpc_model nested_qpc;
    rdma_cqc_model nested_cqc;
    rdma_handle saved_outer_qp_h;
    rdma_handle saved_outer_pd_h;
    rdma_handle saved_outer_send_cq_h;
    rdma_handle saved_outer_recv_cq_h;
    rdma_handle saved_outer_srq_h;
    rdma_handle saved_nested_qp_h;
    rdma_handle saved_nested_pd_h;
    rdma_handle saved_nested_send_cq_h;
    rdma_handle saved_nested_recv_cq_h;
    rdma_handle saved_nested_srq_h;
    rdma_handle saved_cqc_cq_h;
    rdma_handle saved_cqc_ceq_h;
    rdma_page_table_layout saved_cqc_page_layout;
    rdma_ring_position saved_cqc_producer;
    rdma_ring_position saved_cqc_consumer;
    int unsigned saved_outer_host_id;
    int unsigned saved_nested_object_id;
    int unsigned saved_cqc_producer_index;
    int unsigned saved_outer_flags;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "mutating_source_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("mutating_source_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("mutating_source_pcie");
    trace = rdma_mock_call_trace::type_id::create("mutating_source_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "mutating_source_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "mutating_source_profile"
    );
    prepared_binding = make_binding("mutating_source_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("mutating_source_active",
                                  RDMA_BIND_ACTIVE);
    cmq = make_cmq("mutating_source_cmq", prepared_binding);
    prepare_active("MUTATING_SOURCE", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[7];
    foreach (requests[i])
      requests[i] = make_command(
        $sformatf("mutating_source_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hc0 + i)
      );

    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "mutating_source_function"
      );
    fault_function.copy(requests[0].function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    requests[0].function_h = fault_function;

    fault_opcode = rdma_cmq_clone_fault_opcode_key::type_id::create(
      "mutating_source_opcode"
    );
    fault_opcode.copy(requests[1].opcode_key);
    fault_opcode.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    requests[1].opcode_key = fault_opcode;

    fault_image = rdma_cmq_clone_fault_image::type_id::create(
      "mutating_source_image"
    );
    fault_image.copy(requests[2].qpc_signature_source);
    fault_image.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    requests[2].qpc_signature_source = fault_image;

    if (!$cast(source_body, requests[3].body))
      `uvm_fatal("MUTATING_SOURCE_SETUP", "SQE source body is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "mutating_source_sqe"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    requests[3].body = fault_body;
    saved_outer_flags = fault_body.flags;

    if (!$cast(source_body, requests[4].body))
      `uvm_fatal("MUTATING_SOURCE_SETUP", "QPC outer body is invalid")
    qpc = make_qpc_context("mutating_source_outer_qpc", active_binding);
    fault_qpc = rdma_cmq_clone_fault_qpc::type_id::create(
      "mutating_source_qpc"
    );
    fault_qpc.copy(qpc);
    fault_qpc.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    source_body.context_model = fault_qpc;
    outer_qpc = fault_qpc;
    saved_outer_host_id = outer_qpc.host_id;
    saved_outer_qp_h = outer_qpc.qp_h;
    saved_outer_pd_h = outer_qpc.pd_h;
    saved_outer_send_cq_h = outer_qpc.send_cq_h;
    saved_outer_recv_cq_h = outer_qpc.recv_cq_h;
    saved_outer_srq_h = outer_qpc.srq_h;

    if (!$cast(source_body, requests[5].body))
      `uvm_fatal("MUTATING_SOURCE_SETUP", "QPC nested body is invalid")
    nested_qpc = make_qpc_context("mutating_source_nested_qpc",
                                  active_binding);
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "mutating_source_qpc_handle"
    );
    fault_handle.copy(nested_qpc.qp_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    nested_qpc.qp_h = fault_handle;
    source_body.context_model = nested_qpc;
    saved_nested_object_id = fault_handle.object_id;
    saved_nested_qp_h = nested_qpc.qp_h;
    saved_nested_pd_h = nested_qpc.pd_h;
    saved_nested_send_cq_h = nested_qpc.send_cq_h;
    saved_nested_recv_cq_h = nested_qpc.recv_cq_h;
    saved_nested_srq_h = nested_qpc.srq_h;

    if (!$cast(source_body, requests[6].body))
      `uvm_fatal("MUTATING_SOURCE_SETUP", "CQC nested body is invalid")
    nested_cqc = make_cqc_context("mutating_source_nested_cqc",
                                  active_binding);
    fault_ring = rdma_cmq_clone_fault_ring::type_id::create(
      "mutating_source_cqc_ring"
    );
    fault_ring.copy(nested_cqc.producer);
    fault_ring.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    nested_cqc.producer = fault_ring;
    source_body.context_model = nested_cqc;
    saved_cqc_producer_index = fault_ring.index;
    saved_cqc_cq_h = nested_cqc.cq_h;
    saved_cqc_ceq_h = nested_cqc.ceq_h;
    saved_cqc_page_layout = nested_cqc.page_layout;
    saved_cqc_producer = nested_cqc.producer;
    saved_cqc_consumer = nested_cqc.consumer;

    saved_function_refs = new[requests.size()];
    saved_opcode_refs = new[requests.size()];
    saved_body_refs = new[requests.size()];
    saved_signature_refs = new[requests.size()];
    saved_function_values = new[requests.size()];
    saved_opcode_values = new[requests.size()];
    saved_signature_values = new[requests.size()];
    saved_body_function_refs = new[requests.size()];
    saved_body_target_refs = new[requests.size()];
    saved_body_context_refs = new[requests.size()];
    saved_body_values = new[requests.size()];
    saved_vfid_override = new[requests.size()];
    saved_use_vfid = new[requests.size()];
    saved_timeout = new[requests.size()];
    foreach (requests[i]) begin
      saved_function_refs[i] = requests[i].function_h;
      saved_opcode_refs[i] = requests[i].opcode_key;
      saved_body_refs[i] = requests[i].body;
      saved_signature_refs[i] = requests[i].qpc_signature_source;
      saved_vfid_override[i] = requests[i].vfid_override;
      saved_use_vfid[i] = requests[i].use_vfid;
      saved_timeout[i] = requests[i].timeout;
      saved_function_values[i] = rdma_function_handle::type_id::create(
        $sformatf("mutating_source_saved_function_%0d", i)
      );
      saved_function_values[i].copy(requests[i].function_h);
      saved_opcode_values[i] = rdma_cmq_opcode_key::type_id::create(
        $sformatf("mutating_source_saved_opcode_%0d", i)
      );
      saved_opcode_values[i].copy(requests[i].opcode_key);
      saved_signature_values[i] = rdma_hw_image::type_id::create(
        $sformatf("mutating_source_saved_signature_%0d", i)
      );
      saved_signature_values[i].copy(requests[i].qpc_signature_source);
      if (!$cast(source_body, requests[i].body))
        `uvm_fatal("MUTATING_SOURCE_SETUP", "saved SQE body is invalid")
      saved_body_function_refs[i] = source_body.function_h;
      saved_body_target_refs[i] = source_body.target_h;
      saved_body_context_refs[i] = source_body.context_model;
      saved_body_values[i] = engine.probe_body_value_key(source_body);
    end

    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("MUTATING_SOURCE_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("MUTATING_SOURCE_ALIGNMENT", "outputs are misaligned")
    else begin
      foreach (requests[i]) begin
        expect_status($sformatf("MUTATING_SOURCE_ITEM_%0d", i),
                      item_statuses[i], RDMA_SC_INVALID_ARGUMENT);
        if (tickets[i] != null)
          `uvm_error("MUTATING_SOURCE_TICKET",
                     $sformatf("item %0d returned a ticket", i))
      end
    end
    foreach (requests[i]) begin
      if (requests[i].function_h != saved_function_refs[i] ||
          requests[i].opcode_key != saved_opcode_refs[i] ||
          requests[i].body != saved_body_refs[i] ||
          requests[i].qpc_signature_source != saved_signature_refs[i] ||
          requests[i].vfid_override != saved_vfid_override[i] ||
          requests[i].use_vfid != saved_use_vfid[i] ||
          requests[i].timeout != saved_timeout[i] ||
          !engine.probe_same_handle(requests[i].function_h,
                                    saved_function_values[i]) ||
          !engine.probe_same_opcode(requests[i].opcode_key,
                                    saved_opcode_values[i]) ||
          !engine.probe_same_image(requests[i].qpc_signature_source,
                                   saved_signature_values[i]))
        `uvm_error("MUTATING_SOURCE_ROOT",
                   $sformatf("item %0d changed its command root", i))
      if (!$cast(source_body, requests[i].body)) begin
        `uvm_error("MUTATING_SOURCE_BODY",
                   $sformatf("item %0d lost its SQE body", i))
      end
      else if (source_body.function_h != saved_body_function_refs[i] ||
               source_body.target_h != saved_body_target_refs[i] ||
               source_body.context_model != saved_body_context_refs[i] ||
               engine.probe_body_value_key(source_body) !=
                 saved_body_values[i])
        `uvm_error("MUTATING_SOURCE_BODY",
                   $sformatf("item %0d changed its SQE graph", i))
    end
    if (fault_body.flags != saved_outer_flags ||
        outer_qpc.host_id != saved_outer_host_id ||
        outer_qpc.qp_h != saved_outer_qp_h ||
        outer_qpc.pd_h != saved_outer_pd_h ||
        outer_qpc.send_cq_h != saved_outer_send_cq_h ||
        outer_qpc.recv_cq_h != saved_outer_recv_cq_h ||
        outer_qpc.srq_h != saved_outer_srq_h ||
        fault_handle.object_id != saved_nested_object_id ||
        nested_qpc.qp_h != saved_nested_qp_h ||
        nested_qpc.pd_h != saved_nested_pd_h ||
        nested_qpc.send_cq_h != saved_nested_send_cq_h ||
        nested_qpc.recv_cq_h != saved_nested_recv_cq_h ||
        nested_qpc.srq_h != saved_nested_srq_h ||
        fault_ring.index != saved_cqc_producer_index ||
        nested_cqc.cq_h != saved_cqc_cq_h ||
        nested_cqc.ceq_h != saved_cqc_ceq_h ||
        nested_cqc.page_layout != saved_cqc_page_layout ||
        nested_cqc.producer != saved_cqc_producer ||
        nested_cqc.consumer != saved_cqc_consumer)
      `uvm_error("MUTATING_SOURCE_NESTED",
                 "mutating clone changed a caller-owned nested graph")
    expect_no_submit_side_effects("MUTATING_SOURCE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("MUTATING_SOURCE_LEDGER",
                 "mutating clone failure changed the authority ledger")

    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command(
      "mutating_source_recovery", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd0
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("MUTATING_SOURCE_RECOVERY_BATCH", batch_status,
                  RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("MUTATING_SOURCE_RECOVERY",
                 "source restoration failure contaminated recovery")
    else
      expect_status("MUTATING_SOURCE_RECOVERY_ITEM", item_statuses[0],
                    RDMA_SC_OK);
    if (engine.published_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1)
      `uvm_error("MUTATING_SOURCE_RECOVERY_LEDGER",
                 "source restoration failure polluted recovery state")

    engine.shutdown(status);
    expect_status("MUTATING_SOURCE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_qpc_context_snapshot_failures();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_sqe_model outer_body;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    rdma_cmq_clone_fault_qpc fault_qpc;
    rdma_cmq_clone_fault_aeqc fault_aeqc;
    rdma_cmq_clone_fault_handle fault_handle;
    rdma_cmq_clone_fault_page_layout fault_page_layout;
    rdma_cmq_clone_fault_mr_page_layout fault_mr_page_layout;
    rdma_cmq_clone_fault_ring fault_ring;
    rdma_cmq_unknown_body unknown_body;
    rdma_cmq_copy_fatal_catcher catcher;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("qpc_graph_engine");
    mem = rdma_mock_host_mem::type_id::create("qpc_graph_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("qpc_graph_pcie");
    trace = rdma_mock_call_trace::type_id::create("qpc_graph_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "qpc_graph_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("qpc_graph_profile");
    prepared_binding = make_binding("qpc_graph_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("qpc_graph_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("qpc_graph_cmq", prepared_binding);
    prepare_active("QPC_GRAPH", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[12];
    foreach (requests[i]) begin
      requests[i] = make_command(
        $sformatf("qpc_graph_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'h90 + i)
      );
      if (!$cast(outer_body, requests[i].body))
        `uvm_fatal("QPC_GRAPH_SETUP", "outer body type is invalid")
      outer_body.context_model = make_qpc_context(
        $sformatf("qpc_graph_context_%0d", i), active_binding
      );
    end

    if (!$cast(outer_body, requests[0].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "null-clone QPC is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "qpc_nested_null"
    );
    fault_handle.copy(qpc.qp_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    qpc.qp_h = fault_handle;

    if (!$cast(outer_body, requests[1].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "wrong-clone QPC is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "qpc_nested_wrong"
    );
    fault_handle.copy(qpc.qp_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_WRONG_TYPE;
    qpc.qp_h = fault_handle;

    if (!$cast(outer_body, requests[2].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "self-clone QPC is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "qpc_nested_self"
    );
    fault_handle.copy(qpc.qp_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    qpc.qp_h = fault_handle;

    if (!$cast(outer_body, requests[3].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "alias-clone QPC is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "qpc_nested_alias"
    );
    fault_handle.copy(qpc.send_cq_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_ALIAS;
    fault_handle.alias_target = qpc.recv_cq_h;
    qpc.send_cq_h = fault_handle;

    if (!$cast(outer_body, requests[4].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "mutating QPC is invalid")
    fault_qpc = rdma_cmq_clone_fault_qpc::type_id::create(
      "qpc_scalar_mutate"
    );
    fault_qpc.copy(qpc);
    fault_qpc.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    outer_body.context_model = fault_qpc;

    if (!$cast(outer_body, requests[5].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "unknown outer body is invalid")
    unknown_body = rdma_cmq_unknown_body::type_id::create(
      "qpc_unknown_context"
    );
    outer_body.context_model = unknown_body;

    if (!$cast(outer_body, requests[6].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "nested-mutation QPC is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "qpc_nested_mutate"
    );
    fault_handle.copy(qpc.qp_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    qpc.qp_h = fault_handle;

    if (!$cast(outer_body, requests[7].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "CQC outer body is invalid")
    cqc = make_cqc_context("cqc_nested_null", active_binding);
    fault_page_layout =
      rdma_cmq_clone_fault_page_layout::type_id::create(
        "cqc_page_null"
      );
    fault_page_layout.copy(cqc.page_layout);
    fault_page_layout.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    cqc.page_layout = fault_page_layout;
    outer_body.context_model = cqc;

    if (!$cast(outer_body, requests[8].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "MRT outer body is invalid")
    mrt = make_mrt_context("mrt_nested_wrong", active_binding);
    fault_mr_page_layout =
      rdma_cmq_clone_fault_mr_page_layout::type_id::create(
        "mrt_page_wrong"
      );
    fault_mr_page_layout.copy(mrt.page_layout);
    fault_mr_page_layout.clone_fault = RDMA_CMQ_TEST_CLONE_WRONG_TYPE;
    mrt.page_layout = fault_mr_page_layout;
    outer_body.context_model = mrt;

    if (!$cast(outer_body, requests[9].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "SRQC outer body is invalid")
    srqc = make_srqc_context("srqc_nested_self", active_binding);
    fault_ring = rdma_cmq_clone_fault_ring::type_id::create(
      "srqc_producer_self"
    );
    fault_ring.copy(srqc.producer);
    fault_ring.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    srqc.producer = fault_ring;
    outer_body.context_model = srqc;

    if (!$cast(outer_body, requests[10].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "CEQC outer body is invalid")
    ceqc = make_ceqc_context("ceqc_nested_alias", active_binding);
    fault_ring = rdma_cmq_clone_fault_ring::type_id::create(
      "ceqc_producer_alias"
    );
    fault_ring.copy(ceqc.producer);
    fault_ring.clone_fault = RDMA_CMQ_TEST_CLONE_ALIAS;
    fault_ring.alias_target = ceqc.consumer;
    ceqc.producer = fault_ring;
    outer_body.context_model = ceqc;

    if (!$cast(outer_body, requests[11].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "AEQC outer body is invalid")
    aeqc = make_aeqc_context("aeqc_scalar_mutate", active_binding);
    fault_aeqc = rdma_cmq_clone_fault_aeqc::type_id::create(
      "aeqc_context_mutate"
    );
    fault_aeqc.copy(aeqc);
    fault_aeqc.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    outer_body.context_model = fault_aeqc;

    catcher = new("qpc_copy_fatal_catcher");
    uvm_report_cb::add(null, catcher);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    uvm_report_cb::delete(null, catcher);
    expect_status("QPC_GRAPH_BATCH", batch_status, RDMA_SC_OK);
    if (catcher.caught_count != 0)
      `uvm_error("QPC_GRAPH_FATAL",
                 $sformatf("snapshot validation reached %0d copy fatals",
                           catcher.caught_count))
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("QPC_GRAPH_ALIGNMENT", "QPC graph outputs misaligned")
    else begin
      foreach (requests[i]) begin
        expect_status($sformatf("QPC_GRAPH_ITEM_%0d", i),
                      item_statuses[i], RDMA_SC_INVALID_ARGUMENT);
        if (tickets[i] != null)
          `uvm_error("QPC_GRAPH_TICKET",
                     $sformatf("QPC graph item %0d returned a ticket", i))
      end
    end
    expect_no_submit_side_effects("QPC_GRAPH_EFFECTS", mem, pcie, trace);

    requests = new[6];
    foreach (requests[i]) begin
      requests[i] = make_command(
        $sformatf("context_valid_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hb0 + i)
      );
      if (!$cast(outer_body, requests[i].body))
        `uvm_fatal("QPC_GRAPH_SETUP", "valid outer body is invalid")
      case (i)
        0: outer_body.context_model =
             make_qpc_context("context_valid_qpc", active_binding);
        1: outer_body.context_model =
             make_cqc_context("context_valid_cqc", active_binding);
        2: outer_body.context_model =
             make_mrt_context("context_valid_mrt", active_binding);
        3: outer_body.context_model =
             make_srqc_context("context_valid_srqc", active_binding);
        4: outer_body.context_model =
             make_ceqc_context("context_valid_ceqc", active_binding);
        5: outer_body.context_model =
             make_aeqc_context("context_valid_aeqc", active_binding);
        default: begin
        end
      endcase
    end
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("CONTEXT_VALID_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("CONTEXT_VALID_ALIGNMENT",
                 "valid context outputs misaligned")
    else begin
      foreach (requests[i]) begin
        expect_status($sformatf("CONTEXT_VALID_ITEM_%0d", i),
                      item_statuses[i], RDMA_SC_OK);
        if (tickets[i] == null)
          `uvm_error("CONTEXT_VALID_TICKET",
                     $sformatf("valid context item %0d lacks a ticket", i))
      end
    end

    engine.shutdown(status);
    expect_status("QPC_GRAPH_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_null_compose_transaction_abort();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "null_compose_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("null_compose_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("null_compose_pcie");
    trace = rdma_mock_call_trace::type_id::create("null_compose_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "null_compose_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "null_compose_profile"
    );
    prepared_binding = make_binding("null_compose_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("null_compose_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("null_compose_cmq", prepared_binding);
    prepare_active("NULL_COMPOSE", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[6];
    requests[0] = make_command(
      "null_compose_invalid", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h40
    );
    requests[0].body = null;
    requests[1] = make_command(
      "null_compose_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'h41
    );
    requests[2] = make_command(
      "null_compose_codec", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h42
    );
    requests[3] = make_command(
      "null_compose_tentative", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h43
    );
    requests[4] = make_command(
      "null_compose_trigger", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h44
    );
    requests[5] = make_command(
      "null_compose_unprocessed", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h45
    );
    profile.fail_compose_opcode = rdma_cmq_test_profile::TEST_OPCODE_B;
    profile.null_compose_call = 4;

    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("NULL_COMPOSE_BATCH", batch_status,
                  RDMA_SC_INVALID_STATE);
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("NULL_COMPOSE_ALIGNMENT",
                 "null-compose outputs are misaligned")
    else begin
      expect_status("NULL_COMPOSE_INVALID", item_statuses[0],
                    RDMA_SC_INVALID_ARGUMENT);
      expect_status("NULL_COMPOSE_UNSUPPORTED", item_statuses[1],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("NULL_COMPOSE_CODEC", item_statuses[2],
                    RDMA_SC_CODEC_ERROR);
      for (int unsigned i = 3; i < requests.size(); i++)
        expect_status($sformatf("NULL_COMPOSE_ABORTED_%0d", i),
                      item_statuses[i], RDMA_SC_INVALID_STATE);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("NULL_COMPOSE_TICKET",
                     $sformatf("null-compose item %0d returned a ticket", i))
    end
    expect_no_submit_side_effects("NULL_COMPOSE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("NULL_COMPOSE_LEDGER",
                 "null compose status committed tentative state")

    profile.fail_compose_opcode = '0;
    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command(
      "null_compose_recovery", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h46
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("NULL_COMPOSE_RECOVERY_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("NULL_COMPOSE_RECOVERY",
                 "submission did not recover after null compose status")
    else
      expect_status("NULL_COMPOSE_RECOVERY_ITEM", item_statuses[0],
                    RDMA_SC_OK);

    engine.shutdown(status);
    expect_status("NULL_COMPOSE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_transaction_failure_atomicity();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("atomic_engine");
    mem = rdma_mock_host_mem::type_id::create("atomic_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("atomic_pcie");
    trace = rdma_mock_call_trace::type_id::create("atomic_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create("atomic_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("atomic_profile");
    prepared_binding = make_binding("atomic_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("atomic_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("atomic_cmq", prepared_binding);
    prepare_active("ATOMIC", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[3];
    requests[0] = make_command("atomic_a", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h51);
    requests[1] = make_command(
      "atomic_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'h52
    );
    requests[2] = make_command("atomic_b", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_B, 8'h53);

    profile.fail_doorbell_encode = 1'b1;
    profile.doorbell_failure_code = RDMA_SC_CODEC_ERROR;
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ATOMIC_ENCODE_BATCH", batch_status, RDMA_SC_CODEC_ERROR);
    if (tickets.size() != 3 || item_statuses.size() != 3)
      `uvm_error("ATOMIC_ENCODE_ALIGNMENT", "encode outputs misaligned")
    else begin
      expect_status("ATOMIC_ENCODE_A", item_statuses[0],
                    RDMA_SC_CODEC_ERROR);
      expect_status("ATOMIC_ENCODE_UNSUPPORTED", item_statuses[1],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("ATOMIC_ENCODE_B", item_statuses[2],
                    RDMA_SC_CODEC_ERROR);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("ATOMIC_ENCODE_TICKET",
                     "encode failure published a tentative ticket")
    end
    expect_no_submit_side_effects("ATOMIC_ENCODE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("ATOMIC_ENCODE_LEDGER",
                 "encode failure committed tentative state")

    profile.fail_doorbell_encode = 1'b0;
    clear_submit_observation(mem, pcie, trace);
    expect_status("ATOMIC_FAIL_INJECT",
                  pcie.fail_next(
                    "mmio_write",
                    rdma_status::make(RDMA_SC_TIMEOUT,
                                      "injected transport failure")
                  ), RDMA_SC_OK);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ATOMIC_TRANSPORT_BATCH", batch_status, RDMA_SC_TIMEOUT);
    if (tickets.size() != 3 || item_statuses.size() != 3)
      `uvm_error("ATOMIC_TRANSPORT_ALIGNMENT", "transport outputs misaligned")
    else begin
      expect_status("ATOMIC_TRANSPORT_A", item_statuses[0], RDMA_SC_TIMEOUT);
      expect_status("ATOMIC_TRANSPORT_UNSUPPORTED", item_statuses[1],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("ATOMIC_TRANSPORT_B", item_statuses[2], RDMA_SC_TIMEOUT);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("ATOMIC_TRANSPORT_TICKET",
                     "transport failure published a tentative ticket")
    end
    if (mem.calls.size() != 2 || pcie.calls.size() != 3 ||
        pcie.calls[2].method_name != "mmio_write")
      `uvm_error("ATOMIC_TRANSPORT_PATH",
                 "transport failure did not reach the final doorbell")
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("ATOMIC_TRANSPORT_LEDGER",
                 "scheduler failure committed tentative state")

    // A failed scheduler transaction must not commit the tentative CMQ
    // profile format.  Recovery is allowed to establish a different one.
    profile.sqe_endian = RDMA_ENDIAN_LITTLE;
    profile.sqe_hardware_version = 11;
    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command("atomic_recovery", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h61);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ATOMIC_RECOVERY_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("ATOMIC_RECOVERY", "recovery submission did not publish")
    else begin
      expect_status("ATOMIC_RECOVERY_ITEM", item_statuses[0], RDMA_SC_OK);
      if (tickets[0].slot_sequence != 0 || tickets[0].sq_index != 0 ||
          tickets[0].command_id[4:0] != 0 ||
          tickets[0].command_id[63:5] != 3)
        `uvm_error("ATOMIC_RECOVERY_ID",
                   "rollback reused slot/token without advancing incarnation")
    end

    profile.fail_compose_opcode = rdma_cmq_test_profile::TEST_OPCODE_B;
    clear_submit_observation(mem, pcie, trace);
    requests[0] = make_command("atomic_compose", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_B, 8'h62);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ATOMIC_COMPOSE_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] != null ||
        item_statuses.size() != 1)
      `uvm_error("ATOMIC_COMPOSE", "compose failure output is not atomic")
    else
      expect_status("ATOMIC_COMPOSE_ITEM", item_statuses[0],
                    RDMA_SC_CODEC_ERROR);
    expect_no_submit_side_effects("ATOMIC_COMPOSE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1)
      `uvm_error("ATOMIC_COMPOSE_LEDGER",
                 "per-item compose failure changed committed state")

    engine.shutdown(status);
    expect_status("ATOMIC_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_profile_wide_cqe_format_authority();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("format_engine");
    mem = rdma_mock_host_mem::type_id::create("format_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("format_pcie");
    trace = rdma_mock_call_trace::type_id::create("format_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "format_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("format_profile");
    prepared_binding = make_binding("format_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("format_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("format_cmq", prepared_binding);
    prepare_active("FORMAT", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    profile.alternate_sqe_format_for_opcode_b = 1'b1;
    requests = new[2];
    requests[0] = make_command(
      "format_batch_a", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h71
    );
    requests[1] = make_command(
      "format_batch_b", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h72
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("FORMAT_BATCH_STATUS", batch_status,
                  RDMA_SC_INVALID_STATE);
    if (tickets.size() != 2 || item_statuses.size() != 2)
      `uvm_error("FORMAT_BATCH_OUTPUT", "format failure outputs misaligned")
    else foreach (tickets[i]) begin
      if (tickets[i] != null)
        `uvm_error("FORMAT_BATCH_TICKET",
                   "inconsistent batch published a ticket")
      expect_status($sformatf("FORMAT_BATCH_ITEM_%0d", i),
                    item_statuses[i], RDMA_SC_INVALID_STATE);
    end
    expect_no_submit_side_effects("FORMAT_BATCH_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("FORMAT_BATCH_LEDGER",
                 "inconsistent batch polluted the committed ledger")

    profile.alternate_sqe_format_for_opcode_b = 1'b0;
    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command(
      "format_authority", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h73
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("FORMAT_AUTHORITY_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("FORMAT_AUTHORITY_OUTPUT",
                 "format authority submission did not publish")
    else
      expect_status("FORMAT_AUTHORITY_ITEM", item_statuses[0], RDMA_SC_OK);

    profile.sqe_endian = RDMA_ENDIAN_LITTLE;
    profile.sqe_hardware_version = 12;
    clear_submit_observation(mem, pcie, trace);
    requests[0] = make_command(
      "format_change", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h74
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("FORMAT_CHANGE_BATCH", batch_status,
                  RDMA_SC_INVALID_STATE);
    if (tickets.size() != 1 || tickets[0] != null ||
        item_statuses.size() != 1)
      `uvm_error("FORMAT_CHANGE_OUTPUT",
                 "cross-batch format failure output is invalid")
    else
      expect_status("FORMAT_CHANGE_ITEM", item_statuses[0],
                    RDMA_SC_INVALID_STATE);
    expect_no_submit_side_effects("FORMAT_CHANGE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1)
      `uvm_error("FORMAT_CHANGE_LEDGER",
                 "cross-batch format change polluted committed authority")

    engine.shutdown(status);
    expect_status("FORMAT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_all_transport_failure_rollbacks();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_cmq_ticket baseline_ticket;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status injected;
    rdma_status status;
    longint unsigned baseline_command_id;
    string baseline_expected_variant;
    string label;

    for (int unsigned fault = 0; fault < 4; fault++) begin
      label = $sformatf("TRANSPORT_ROLLBACK_%0d", fault);
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("transport_rollback_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("transport_rollback_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("transport_rollback_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("transport_rollback_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("transport_rollback_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("transport_rollback_profile_%0d", fault)
      );
      prepared_binding = make_binding(
        $sformatf("transport_rollback_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("transport_rollback_active_%0d", fault),
        RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("transport_rollback_cmq_%0d", fault),
                     prepared_binding);
      prepare_active(label, engine, mem, pcie, scheduler, profile,
                     prepared_binding, active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);
      baseline_ticket = null;
      baseline_command_id = '0;
      baseline_expected_variant = "";

      requests = new[1];
      requests[0] = make_command(
        $sformatf("transport_baseline_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'h60 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status({label, "_BASELINE_BATCH"}, batch_status, RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("TRANSPORT_ROLLBACK_BASELINE",
                   $sformatf("%s baseline output is invalid", label))
      else begin
        expect_status({label, "_BASELINE_ITEM"}, item_statuses[0],
                      RDMA_SC_OK);
        baseline_ticket = tickets[0];
        baseline_command_id = tickets[0].command_id;
        baseline_expected_variant = engine.slot_expected_variant(0);
        if (tickets[0].slot_sequence != 0 || tickets[0].sq_index != 0 ||
            tickets[0].sq_wrap || baseline_command_id == 0 ||
            baseline_expected_variant == "")
          `uvm_error("TRANSPORT_ROLLBACK_BASELINE_AUTHORITY",
                     $sformatf("%s baseline authority is invalid", label))
      end
      clear_submit_observation(mem, pcie, trace);

      requests = new[4];
      requests[0] = make_command(
        $sformatf("transport_rollback_a_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'h70 + fault)
      );
      requests[1] = make_command(
        $sformatf("transport_rollback_invalid_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED,
        byte'(8'h80 + fault)
      );
      requests[2] = make_command(
        $sformatf("transport_rollback_codec_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_B, byte'(8'h90 + fault)
      );
      requests[3] = make_command(
        $sformatf("transport_rollback_b_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'ha0 + fault)
      );
      profile.fail_compose_opcode = rdma_cmq_test_profile::TEST_OPCODE_B;
      profile.compose_failure_code = RDMA_SC_CODEC_ERROR;
      injected = rdma_status::make(
        RDMA_SC_TIMEOUT, $sformatf("injected transport failure %0d", fault)
      );
      case (fault)
        0: expect_status({label, "_ARM_DEPENDENCY"},
                         mem.fail_write_at(2, injected), RDMA_SC_OK);
        1: expect_status(
             {label, "_ARM_DMA"},
             pcie.fail_next("dma_visibility_barrier", injected), RDMA_SC_OK
           );
        2: expect_status(
             {label, "_ARM_MMIO_BARRIER"},
             pcie.fail_next("mmio_ordering_barrier", injected), RDMA_SC_OK
           );
        3: expect_status(
             {label, "_ARM_MMIO_WRITE"},
             pcie.fail_next("mmio_write", injected), RDMA_SC_OK
           );
      endcase

      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status({label, "_BATCH"}, batch_status, RDMA_SC_TIMEOUT);
      if (tickets.size() != 4 || item_statuses.size() != 4)
        `uvm_error("TRANSPORT_ROLLBACK_ALIGNMENT",
                   $sformatf("%s outputs are misaligned", label))
      else begin
        expect_status({label, "_VALID_A"}, item_statuses[0],
                      RDMA_SC_TIMEOUT);
        expect_status({label, "_VALIDATION"}, item_statuses[1],
                      RDMA_SC_UNSUPPORTED_OPCODE);
        expect_status({label, "_CODEC"}, item_statuses[2],
                      RDMA_SC_CODEC_ERROR);
        expect_status({label, "_VALID_B"}, item_statuses[3],
                      RDMA_SC_TIMEOUT);
        foreach (tickets[i])
          if (tickets[i] != null)
            `uvm_error("TRANSPORT_ROLLBACK_TICKET",
                       $sformatf("%s published tentative ticket %0d",
                                 label, i))
      end
      if (mem.calls.size() != 2 || pcie.calls.size() != fault)
        `uvm_error("TRANSPORT_ROLLBACK_PATH",
                   $sformatf("%s observed host/PCIe calls %0d/%0d",
                             label, mem.calls.size(), pcie.calls.size()))
      if (engine.published_count() != 1 || engine.retired_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1 ||
          engine.command_registry_count() != 1 ||
          engine.entry_registry_count() != 1 || baseline_ticket == null ||
          baseline_ticket.command_id != baseline_command_id ||
          baseline_ticket.slot_sequence != 0 ||
          engine.slot_ticket_command_id(0) != baseline_command_id ||
          engine.slot_expected_variant(0) != baseline_expected_variant)
        `uvm_error("TRANSPORT_ROLLBACK_LEDGER",
                   $sformatf("%s changed committed authority", label))

      clear_submit_observation(mem, pcie, trace);
      profile.fail_compose_opcode = '0;
      requests = new[2];
      requests[0] = make_command(
        $sformatf("transport_recovery_a_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'ha0 + fault)
      );
      requests[1] = make_command(
        $sformatf("transport_recovery_b_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_B, byte'(8'hb0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status({label, "_RECOVERY_BATCH"}, batch_status, RDMA_SC_OK);
      if (tickets.size() != 2 || tickets[0] == null || tickets[1] == null ||
          item_statuses.size() != 2)
        `uvm_error("TRANSPORT_ROLLBACK_RECOVERY",
                   $sformatf("%s recovery outputs are invalid", label))
      else begin
        expect_status({label, "_RECOVERY_A"}, item_statuses[0], RDMA_SC_OK);
        expect_status({label, "_RECOVERY_B"}, item_statuses[1], RDMA_SC_OK);
        if (tickets[0].slot_sequence != 1 || tickets[0].sq_index != 1 ||
            tickets[0].sq_wrap || tickets[1].slot_sequence != 2 ||
            tickets[1].sq_index != 2 || tickets[1].sq_wrap)
          `uvm_error("TRANSPORT_ROLLBACK_REUSE",
                     $sformatf("%s did not overwrite unpublished slots",
                               label))
      end
      if (mem.calls.size() != 2 || mem.calls[0].offset != 64 ||
          mem.calls[1].offset != 128 || engine.published_count() != 3 ||
          engine.tokens_in_use_count() != 3 ||
          engine.slot_record_count() != 3 ||
          engine.command_registry_count() != 3 ||
          engine.entry_registry_count() != 3 ||
          engine.slot_ticket_command_id(0) != baseline_command_id ||
          engine.slot_expected_variant(0) != baseline_expected_variant)
        `uvm_error("TRANSPORT_ROLLBACK_RECOVERY_LEDGER",
                   $sformatf("%s leaked or skipped recovered authority",
                             label))

      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    end
  endtask

  task automatic check_doorbell_authority_isolation();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    for (int unsigned fault = RDMA_CMQ_TEST_DB_INPUT_MUTATE_SUCCESS;
         fault <= RDMA_CMQ_TEST_DB_INPUT_MUTATE_NULL; fault++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("doorbell_authority_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("doorbell_authority_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("doorbell_authority_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("doorbell_authority_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("doorbell_authority_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("doorbell_authority_profile_%0d", fault)
      );
      if (!$cast(profile.doorbell_input_fault, fault))
        `uvm_fatal("DOORBELL_AUTHORITY_SETUP",
                   "doorbell input fault enum cast failed")
      prepared_binding = make_binding(
        $sformatf("doorbell_authority_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("doorbell_authority_active_%0d", fault),
        RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("doorbell_authority_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("DOORBELL_AUTHORITY_%0d", fault), engine,
                     mem, pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[1];
      requests[0] = make_command(
        $sformatf("doorbell_authority_hostile_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hd0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("DOORBELL_AUTHORITY_BATCH_%0d", fault),
                    batch_status, RDMA_SC_INVALID_STATE);
      if (tickets.size() != 1 || tickets[0] != null ||
          item_statuses.size() != 1)
        `uvm_error("DOORBELL_AUTHORITY_OUTPUT",
                   $sformatf("fault %0d published hostile output", fault))
      else
        expect_status($sformatf("DOORBELL_AUTHORITY_ITEM_%0d", fault),
                      item_statuses[0], RDMA_SC_INVALID_STATE);
      if (!engine.probe_authority_handle_matches(cmq.handle) ||
          engine.probe_is_authority_handle(profile.last_doorbell_input))
        `uvm_error("DOORBELL_AUTHORITY_HANDLE",
                   $sformatf("fault %0d exposed or changed authority", fault))
      expect_no_submit_side_effects(
        $sformatf("DOORBELL_AUTHORITY_EFFECTS_%0d", fault), mem, pcie,
        trace
      );
      if (engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("DOORBELL_AUTHORITY_LEDGER",
                   $sformatf("fault %0d committed tentative state", fault))

      profile.doorbell_input_fault = RDMA_CMQ_TEST_DB_INPUT_GOOD;
      clear_submit_observation(mem, pcie, trace);
      requests[0] = make_command(
        $sformatf("doorbell_authority_recovery_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'he0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("DOORBELL_AUTHORITY_RECOVERY_BATCH_%0d",
                              fault), batch_status, RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("DOORBELL_AUTHORITY_RECOVERY",
                   $sformatf("fault %0d blocked recovery", fault))
      else
        expect_status($sformatf("DOORBELL_AUTHORITY_RECOVERY_ITEM_%0d",
                                fault), item_statuses[0], RDMA_SC_OK);
      if (engine.published_count() != 1 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1)
        `uvm_error("DOORBELL_AUTHORITY_RECOVERY_LEDGER",
                   $sformatf("fault %0d did not recover cleanly", fault))

      engine.shutdown(status);
      expect_status($sformatf("DOORBELL_AUTHORITY_SHUTDOWN_%0d", fault),
                    status, RDMA_SC_OK);
    end
  endtask

  task automatic check_submission_validation_and_profile_metadata();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_command_desc valid_clone_source;
    rdma_cmq_bad_clone_command bad_clone;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    rdma_status_code_e expected_validation_codes[11] = '{
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_STALE_GENERATION,
      RDMA_SC_UNSUPPORTED_OPCODE,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT
    };
    rdma_status_code_e expected_sqe_codes[15] = '{
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_STALE_GENERATION,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE
    };
    rdma_status_code_e expected_db_codes[9] = '{
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE
    };

    engine = rdma_cmq_engine_probe::type_id::create("validation_engine");
    mem = rdma_mock_host_mem::type_id::create("validation_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("validation_pcie");
    trace = rdma_mock_call_trace::type_id::create("validation_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "validation_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("validation_profile");
    prepared_binding = make_binding("validation_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("validation_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("validation_cmq", prepared_binding);
    prepare_active("VALIDATION", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[11];
    requests[0] = null;
    requests[1] = make_command("validation_body", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h01);
    requests[1].body = null;
    requests[2] = make_command("validation_kind", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h02);
    requests[2].function_h.kind = RDMA_RESOURCE_QP;
    requests[3] = make_command("validation_uid", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h03);
    requests[3].function_h.function_uid++;
    requests[4] = make_command("validation_object", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h04);
    requests[4].function_h.object_id++;
    requests[5] = make_command("validation_generation", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h05);
    requests[5].function_h.generation++;
    requests[6] = make_command("validation_profile", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h06);
    requests[6].opcode_key.profile_name = "wrong_profile";
    requests[7] = make_command("validation_timeout", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h07);
    requests[7].timeout = 0;
    bad_clone = rdma_cmq_bad_clone_command::type_id::create(
      "validation_null_clone"
    );
    valid_clone_source = make_command(
      "validation_null_clone_source", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h08
    );
    bad_clone.copy(valid_clone_source);
    requests[8] = bad_clone;
    bad_clone = rdma_cmq_bad_clone_command::type_id::create(
      "validation_wrong_clone"
    );
    valid_clone_source = make_command(
      "validation_wrong_clone_source", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h09
    );
    bad_clone.copy(valid_clone_source);
    bad_clone.return_wrong_type = 1'b1;
    requests[9] = bad_clone;
    bad_clone = rdma_cmq_bad_clone_command::type_id::create(
      "validation_self_clone"
    );
    valid_clone_source = make_command(
      "validation_self_clone_source", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h0a
    );
    bad_clone.copy(valid_clone_source);
    bad_clone.return_self = 1'b1;
    requests[10] = bad_clone;
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("VALIDATION_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("VALIDATION_ALIGNMENT", "validation outputs misaligned")
    else begin
      foreach (requests[i]) begin
        expect_status($sformatf("VALIDATION_ITEM_%0d", i), item_statuses[i],
                      expected_validation_codes[i]);
        if (tickets[i] != null)
          `uvm_error("VALIDATION_TICKET",
                     $sformatf("validation item %0d returned a ticket", i))
      end
    end
    expect_no_submit_side_effects("VALIDATION_EFFECTS", mem, pcie, trace);

    #1ns;
    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command("validation_overflow", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h08);
    requests[0].timeout = time'(-1);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("VALIDATION_OVERFLOW_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] != null ||
        item_statuses.size() != 1)
      `uvm_error("VALIDATION_OVERFLOW", "deadline overflow output invalid")
    else
      expect_status("VALIDATION_OVERFLOW_ITEM", item_statuses[0],
                    RDMA_SC_INVALID_ARGUMENT);
    expect_no_submit_side_effects("VALIDATION_OVERFLOW_EFFECTS", mem, pcie,
                                  trace);

    clear_submit_observation(mem, pcie, trace);
    requests = new[2];
    requests[0] = make_command("validation_timeout_x", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h09);
    requests[0].timeout[7] = 1'bx;
    requests[1] = make_command("validation_timeout_z", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h0a);
    requests[1].timeout[11] = 1'bz;
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("VALIDATION_UNKNOWN_TIMEOUT_BATCH", batch_status,
                  RDMA_SC_OK);
    if (tickets.size() != 2 || item_statuses.size() != 2)
      `uvm_error("VALIDATION_UNKNOWN_TIMEOUT",
                 "unknown timeout outputs are misaligned")
    else begin
      foreach (tickets[i]) begin
        if (tickets[i] != null)
          `uvm_error("VALIDATION_UNKNOWN_TIMEOUT",
                     $sformatf("unknown timeout item %0d returned ticket", i))
        expect_status($sformatf("VALIDATION_UNKNOWN_TIMEOUT_%0d", i),
                      item_statuses[i], RDMA_SC_INVALID_ARGUMENT);
      end
    end
    expect_no_submit_side_effects("VALIDATION_UNKNOWN_TIMEOUT_EFFECTS",
                                  mem, pcie, trace);

    requests = new[1];
    for (int unsigned fault = 1; fault <= 15; fault++) begin
      clear_submit_observation(mem, pcie, trace);
      if (!$cast(profile.sqe_fault, fault))
        `uvm_fatal("VALIDATION_SETUP", "SQE fault enum cast failed")
      requests[0] = make_command($sformatf("sqe_fault_%0d", fault),
                                 active_binding,
                                 rdma_cmq_test_profile::TEST_OPCODE_A,
                                 byte'(8'h20 + fault));
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("SQE_FAULT_BATCH_%0d", fault), batch_status,
                    expected_sqe_codes[fault - 1]);
      if (tickets.size() != 1 || tickets[0] != null ||
          item_statuses.size() != 1)
        `uvm_error("SQE_FAULT_OUTPUT",
                   $sformatf("SQE fault %0d output invalid", fault))
      else
        expect_status($sformatf("SQE_FAULT_ITEM_%0d", fault),
                      item_statuses[0], expected_sqe_codes[fault - 1]);
      expect_no_submit_side_effects(
        $sformatf("SQE_FAULT_EFFECTS_%0d", fault), mem, pcie, trace
      );
    end
    profile.sqe_fault = RDMA_CMQ_TEST_SQE_GOOD;

    for (int unsigned fault = 1; fault <= 9; fault++) begin
      clear_submit_observation(mem, pcie, trace);
      if (!$cast(profile.doorbell_fault, fault))
        `uvm_fatal("VALIDATION_SETUP", "doorbell fault enum cast failed")
      requests[0] = make_command($sformatf("db_fault_%0d", fault),
                                 active_binding,
                                 rdma_cmq_test_profile::TEST_OPCODE_A,
                                 byte'(8'h40 + fault));
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("DB_FAULT_BATCH_%0d", fault), batch_status,
                    expected_db_codes[fault - 1]);
      if (tickets.size() != 1 || tickets[0] != null ||
          item_statuses.size() != 1)
        `uvm_error("DB_FAULT_OUTPUT",
                   $sformatf("doorbell fault %0d output invalid", fault))
      else
        expect_status($sformatf("DB_FAULT_ITEM_%0d", fault),
                      item_statuses[0], expected_db_codes[fault - 1]);
      expect_no_submit_side_effects(
        $sformatf("DB_FAULT_EFFECTS_%0d", fault), mem, pcie, trace
      );
    end
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("VALIDATION_LEDGER",
                 "rejected metadata changed engine ledger state")

    engine.shutdown(status);
    expect_status("VALIDATION_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_profile_hook_snapshot_contract();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_profile_hook_fault_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    rdma_cmq_copy_fatal_catcher catcher;

    for (int unsigned fault = RDMA_CMQ_TEST_HOOK_NULL_STATUS;
         fault <= RDMA_CMQ_TEST_HOOK_FAILED_VALIDATION; fault++) begin
      if (fault == RDMA_CMQ_TEST_HOOK_NONOK_STATUS)
        continue;
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("hook_contract_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("hook_contract_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("hook_contract_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("hook_contract_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("hook_contract_scheduler_%0d", fault)
      );
      profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
        $sformatf("hook_contract_profile_%0d", fault)
      );
      if (!$cast(profile.snapshot_fault, fault))
        `uvm_fatal("HOOK_CONTRACT_SETUP", "hook fault enum cast failed")
      prepared_binding = make_binding(
        $sformatf("hook_contract_prepared_%0d", fault), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("hook_contract_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("hook_contract_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("HOOK_CONTRACT_%0d", fault), engine, mem,
                     pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[4];
      requests[0] = null;
      requests[1] = make_command(
        $sformatf("hook_contract_unsupported_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'hd0
      );
      requests[2] = make_command(
        $sformatf("hook_contract_tentative_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd1
      );
      requests[3] = make_command(
        $sformatf("hook_contract_trigger_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_B, 8'hd2
      );
      requests[3].body = make_profile_hook_body(
        $sformatf("hook_contract_body_%0d", fault), active_binding,
        32'h1234_0000 + fault
      );
      rdma_cmq_profile_hook_body::clear_hostile_clone_calls();
      catcher = new($sformatf("hook_contract_catcher_%0d", fault));
      uvm_report_cb::add(null, catcher);
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      uvm_report_cb::delete(null, catcher);

      expect_status($sformatf("HOOK_CONTRACT_BATCH_%0d", fault),
                    batch_status, RDMA_SC_INVALID_STATE);
      if (tickets.size() != 4 || item_statuses.size() != 4)
        `uvm_error("HOOK_CONTRACT_ALIGNMENT",
                   $sformatf("fault %0d outputs are misaligned", fault))
      else begin
        expect_status($sformatf("HOOK_CONTRACT_INVALID_%0d", fault),
                      item_statuses[0], RDMA_SC_INVALID_ARGUMENT);
        expect_status($sformatf("HOOK_CONTRACT_UNSUPPORTED_%0d", fault),
                      item_statuses[1], RDMA_SC_UNSUPPORTED_OPCODE);
        expect_status($sformatf("HOOK_CONTRACT_TENTATIVE_%0d", fault),
                      item_statuses[2], RDMA_SC_INVALID_STATE);
        expect_status($sformatf("HOOK_CONTRACT_TRIGGER_%0d", fault),
                      item_statuses[3], RDMA_SC_INVALID_STATE);
        foreach (tickets[i])
          if (tickets[i] != null)
            `uvm_error("HOOK_CONTRACT_TICKET",
                       $sformatf("fault %0d item %0d returned ticket",
                                 fault, i))
      end
      if (profile.snapshot_calls != 1)
        `uvm_error("HOOK_CONTRACT_CALLS",
                   $sformatf("fault %0d made %0d hook calls", fault,
                             profile.snapshot_calls))
      if (catcher.caught_count != 0 ||
          rdma_cmq_profile_hook_body::clone_call_count() != 0)
        `uvm_error("HOOK_CONTRACT_HOSTILE_CLONE",
                   $sformatf("fault %0d reached hostile clone (%0d/%0d)",
                             fault, catcher.caught_count,
                             rdma_cmq_profile_hook_body::clone_call_count()))
      expect_no_submit_side_effects(
        $sformatf("HOOK_CONTRACT_EFFECTS_%0d", fault), mem, pcie, trace
      );
      if (profile.doorbell_calls != 0)
        `uvm_error("HOOK_CONTRACT_DOORBELL",
                   $sformatf("fault %0d encoded a doorbell", fault))
      if (engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("HOOK_CONTRACT_LEDGER",
                   $sformatf("fault %0d committed tentative state", fault))

      engine.shutdown(status);
      expect_status($sformatf("HOOK_CONTRACT_SHUTDOWN_%0d", fault), status,
                    RDMA_SC_OK);
    end

    engine = rdma_cmq_engine_probe::type_id::create("hook_nonok_engine");
    mem = rdma_mock_host_mem::type_id::create("hook_nonok_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("hook_nonok_pcie");
    trace = rdma_mock_call_trace::type_id::create("hook_nonok_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "hook_nonok_scheduler"
    );
    profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
      "hook_nonok_profile"
    );
    profile.snapshot_fault = RDMA_CMQ_TEST_HOOK_NONOK_STATUS;
    prepared_binding = make_binding("hook_nonok_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("hook_nonok_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("hook_nonok_cmq", prepared_binding);
    prepare_active("HOOK_NONOK", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);
    requests = new[2];
    requests[0] = make_command(
      "hook_nonok_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'he0
    );
    requests[1] = make_command(
      "hook_nonok_rejected", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'he1
    );
    requests[1].body = make_profile_hook_body(
      "hook_nonok_body", active_binding, 32'h5678_0000
    );
    rdma_cmq_profile_hook_body::clear_hostile_clone_calls();
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("HOOK_NONOK_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 2 || item_statuses.size() != 2)
      `uvm_error("HOOK_NONOK_ALIGNMENT", "hook outputs are misaligned")
    else begin
      expect_status("HOOK_NONOK_UNSUPPORTED", item_statuses[0],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("HOOK_NONOK_REJECTED", item_statuses[1],
                    RDMA_SC_INVALID_STATE);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("HOOK_NONOK_TICKET", "rejected hook returned a ticket")
    end
    if (rdma_cmq_profile_hook_body::clone_call_count() != 0)
      `uvm_error("HOOK_NONOK_HOSTILE_CLONE",
                 "ordinary hook rejection reached hostile clone")
    expect_no_submit_side_effects("HOOK_NONOK_EFFECTS", mem, pcie, trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("HOOK_NONOK_LEDGER", "hook rejection changed the ledger")
    engine.shutdown(status);
    expect_status("HOOK_NONOK_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_stateful_profile_snapshot_rechecks();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_profile_hook_fault_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_command_desc trigger;
    rdma_cmq_profile_hook_body trigger_body;
    rdma_function_handle saved_function_h;
    rdma_cmq_opcode_key saved_opcode_key;
    rdma_hw_model saved_body;
    rdma_hw_image saved_signature;
    rdma_handle saved_nested_h;
    bit saved_vfid_override;
    bit [10:0] saved_use_vfid;
    time saved_timeout;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    rdma_cmq_copy_fatal_catcher catcher;

    for (int unsigned fault = RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT;
         fault <= RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT; fault++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("stateful_hook_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("stateful_hook_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("stateful_hook_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("stateful_hook_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("stateful_hook_scheduler_%0d", fault)
      );
      profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
        $sformatf("stateful_hook_profile_%0d", fault)
      );
      if (!$cast(profile.snapshot_fault, fault))
        `uvm_fatal("STATEFUL_HOOK_SETUP", "hook fault enum cast failed")
      prepared_binding = make_binding(
        $sformatf("stateful_hook_prepared_%0d", fault), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("stateful_hook_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("stateful_hook_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("STATEFUL_HOOK_%0d", fault), engine, mem,
                     pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[4];
      requests[0] = null;
      requests[1] = make_command(
        $sformatf("stateful_hook_unsupported_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'hf0
      );
      requests[2] = make_command(
        $sformatf("stateful_hook_tentative_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, 8'hf1
      );
      requests[3] = make_command(
        $sformatf("stateful_hook_trigger_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_B, 8'hf2
      );
      requests[3].body = make_profile_hook_body(
        $sformatf("stateful_hook_body_%0d", fault), active_binding,
        32'h9abc_0000 + fault
      );
      trigger = requests[3];
      if (!$cast(trigger_body, trigger.body))
        `uvm_fatal("STATEFUL_HOOK_SETUP", "stateful body cast failed")
      trigger_body.first_clone_succeeds = 1'b1;
      saved_function_h = trigger.function_h;
      saved_opcode_key = trigger.opcode_key;
      saved_body = trigger.body;
      saved_signature = trigger.qpc_signature_source;
      saved_nested_h = trigger_body.nested_h;
      saved_vfid_override = trigger.vfid_override;
      saved_use_vfid = trigger.use_vfid;
      saved_timeout = trigger.timeout;

      rdma_cmq_profile_hook_body::clear_hostile_clone_calls();
      catcher = new($sformatf("stateful_hook_catcher_%0d", fault));
      uvm_report_cb::add(null, catcher);
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      uvm_report_cb::delete(null, catcher);

      expect_status($sformatf("STATEFUL_HOOK_BATCH_%0d", fault),
                    batch_status, RDMA_SC_INVALID_STATE);
      if (tickets.size() != 4 || item_statuses.size() != 4)
        `uvm_error("STATEFUL_HOOK_ALIGNMENT",
                   $sformatf("fault %0d outputs are misaligned", fault))
      else begin
        expect_status($sformatf("STATEFUL_HOOK_INVALID_%0d", fault),
                      item_statuses[0], RDMA_SC_INVALID_ARGUMENT);
        expect_status($sformatf("STATEFUL_HOOK_UNSUPPORTED_%0d", fault),
                      item_statuses[1], RDMA_SC_UNSUPPORTED_OPCODE);
        expect_status($sformatf("STATEFUL_HOOK_TENTATIVE_%0d", fault),
                      item_statuses[2], RDMA_SC_INVALID_STATE);
        expect_status($sformatf("STATEFUL_HOOK_TRIGGER_%0d", fault),
                      item_statuses[3], RDMA_SC_INVALID_STATE);
        foreach (tickets[i])
          if (tickets[i] != null)
            `uvm_error("STATEFUL_HOOK_TICKET",
                       $sformatf("fault %0d item %0d returned ticket",
                                 fault, i))
      end
      if (catcher.caught_count != 0 || trigger_body.clone_calls != 1 ||
          rdma_cmq_profile_hook_body::clone_call_count() != 1)
        `uvm_error("STATEFUL_HOOK_CLONE",
                   $sformatf("fault %0d clone/fatal counts are %0d/%0d/%0d",
                             fault, catcher.caught_count,
                             trigger_body.clone_calls,
                             rdma_cmq_profile_hook_body::clone_call_count()))
      if (profile.same_calls != 2 ||
          profile.detach_calls !=
            ((fault == RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT) ? 2 : 1))
        `uvm_error("STATEFUL_HOOK_PREDICATES",
                   $sformatf("fault %0d predicate counts are %0d/%0d",
                             fault, profile.same_calls,
                             profile.detach_calls))
      if (trigger.function_h != saved_function_h ||
          trigger.opcode_key != saved_opcode_key ||
          trigger.body != saved_body ||
          trigger.qpc_signature_source != saved_signature ||
          trigger_body.nested_h != saved_nested_h ||
          trigger.vfid_override != saved_vfid_override ||
          trigger.use_vfid != saved_use_vfid ||
          trigger.timeout != saved_timeout)
        `uvm_error("STATEFUL_HOOK_SOURCE",
                   $sformatf("fault %0d changed the caller command", fault))
      expect_no_submit_side_effects(
        $sformatf("STATEFUL_HOOK_EFFECTS_%0d", fault), mem, pcie, trace
      );
      if (profile.doorbell_calls != 0 || engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("STATEFUL_HOOK_LEDGER",
                   $sformatf("fault %0d published tentative state", fault))

      engine.shutdown(status);
      expect_status($sformatf("STATEFUL_HOOK_SHUTDOWN_%0d", fault), status,
                    RDMA_SC_OK);
    end
  endtask

  task automatic check_exact_type_profile_delegation();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_profile_hook_fault_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_sqe_model command_body;
    rdma_cmq_scalar_extension_function_handle scalar_function_h;
    rdma_cmq_edge_extension_handle edge_target_h;
    rdma_handle saved_extension_h;
    int unsigned saved_extension_value;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    for (int unsigned mode = 0; mode < 3; mode++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("exact_type_engine_%0d", mode)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("exact_type_mem_%0d", mode)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("exact_type_pcie_%0d", mode)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("exact_type_trace_%0d", mode)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("exact_type_scheduler_%0d", mode)
      );
      profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
        $sformatf("exact_type_profile_%0d", mode)
      );
      prepared_binding = make_binding(
        $sformatf("exact_type_prepared_%0d", mode), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("exact_type_active_%0d", mode), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("exact_type_cmq_%0d", mode),
                     prepared_binding);
      prepare_active($sformatf("EXACT_TYPE_%0d", mode), engine, mem,
                     pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[1];
      requests[0] = make_command(
        $sformatf("exact_type_request_%0d", mode), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hb0 + mode)
      );
      if (!$cast(command_body, requests[0].body))
        `uvm_fatal("EXACT_TYPE_SETUP", "command body cast failed")
      command_body.opcode = RDMA_CMQ_CREATE_QP;
      case (mode)
        0: command_body.context_model = make_qpc_context(
             "exact_type_builtin_qpc", active_binding
           );
        1: command_body.context_model = make_scalar_extension_qpc(
             "exact_type_scalar_qpc", active_binding, 32'h1357_9bdf
           );
        2: command_body.context_model = make_edge_extension_qpc(
             "exact_type_edge_qpc", active_binding
           );
        default:
          `uvm_fatal("EXACT_TYPE_SETUP", "unknown exact-type mode")
      endcase
      rdma_cmq_scalar_extension_qpc::clear_hostile_clone_calls();
      rdma_cmq_edge_extension_qpc::clear_hostile_clone_calls();
      engine.submit_batch(requests, tickets, item_statuses, batch_status);

      expect_status($sformatf("EXACT_TYPE_BATCH_%0d", mode), batch_status,
                    RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("EXACT_TYPE_OUTPUT",
                   $sformatf("mode %0d did not publish", mode))
      else
        expect_status($sformatf("EXACT_TYPE_ITEM_%0d", mode),
                      item_statuses[0], RDMA_SC_OK);
      if (mode == 0) begin
        if (profile.snapshot_calls != 0 || profile.same_calls != 0 ||
            profile.detach_calls != 0)
          `uvm_error("EXACT_TYPE_BUILTIN",
                     "exact built-in QPC unexpectedly used profile hooks")
      end
      else begin
        if (profile.snapshot_calls != 1 || profile.same_calls == 0 ||
            profile.detach_calls == 0)
          `uvm_error("EXACT_TYPE_EXTENSION",
                     $sformatf("mode %0d bypassed profile hooks (%0d/%0d/%0d)",
                               mode, profile.snapshot_calls,
                               profile.same_calls, profile.detach_calls))
        if (rdma_cmq_scalar_extension_qpc::clone_call_count() != 0 ||
            rdma_cmq_edge_extension_qpc::clone_call_count() != 0)
          `uvm_error("EXACT_TYPE_HOSTILE_CLONE",
                     $sformatf("mode %0d invoked an extension clone (%0d/%0d)",
                               mode,
                               rdma_cmq_scalar_extension_qpc::clone_call_count(),
                               rdma_cmq_edge_extension_qpc::clone_call_count()))
      end

      engine.shutdown(status);
      expect_status($sformatf("EXACT_TYPE_SHUTDOWN_%0d", mode), status,
                    RDMA_SC_OK);
    end

    for (int unsigned fault = RDMA_CMQ_TEST_EXTENSION_DROP_SCALAR;
         fault <= RDMA_CMQ_TEST_EXTENSION_MUTATE_SOURCE; fault++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("extension_contract_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("extension_contract_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("extension_contract_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("extension_contract_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("extension_contract_scheduler_%0d", fault)
      );
      profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
        $sformatf("extension_contract_profile_%0d", fault)
      );
      if (!$cast(profile.extension_fault, fault))
        `uvm_fatal("EXTENSION_CONTRACT_SETUP",
                   "extension fault enum cast failed")
      prepared_binding = make_binding(
        $sformatf("extension_contract_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("extension_contract_active_%0d", fault),
        RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("extension_contract_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("EXTENSION_CONTRACT_%0d", fault), engine,
                     mem, pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[1];
      requests[0] = make_command(
        $sformatf("extension_contract_request_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hc0 + fault)
      );
      if (!$cast(command_body, requests[0].body))
        `uvm_fatal("EXTENSION_CONTRACT_SETUP", "command body cast failed")
      command_body.opcode = RDMA_CMQ_CREATE_QP;
      if (fault == RDMA_CMQ_TEST_EXTENSION_ALIAS_EDGE)
        command_body.context_model = make_edge_extension_qpc(
          $sformatf("extension_contract_edge_%0d", fault), active_binding
        );
      else
        command_body.context_model = make_scalar_extension_qpc(
          $sformatf("extension_contract_scalar_%0d", fault),
          active_binding, 32'h2468_ace0 + fault
        );
      rdma_cmq_scalar_extension_qpc::clear_hostile_clone_calls();
      rdma_cmq_edge_extension_qpc::clear_hostile_clone_calls();
      engine.submit_batch(requests, tickets, item_statuses, batch_status);

      expect_status($sformatf("EXTENSION_CONTRACT_BATCH_%0d", fault),
                    batch_status, RDMA_SC_INVALID_STATE);
      if (tickets.size() != 1 || tickets[0] != null ||
          item_statuses.size() != 1)
        `uvm_error("EXTENSION_CONTRACT_OUTPUT",
                   $sformatf("fault %0d published output", fault))
      else
        expect_status($sformatf("EXTENSION_CONTRACT_ITEM_%0d", fault),
                      item_statuses[0], RDMA_SC_INVALID_STATE);
      expect_no_submit_side_effects(
        $sformatf("EXTENSION_CONTRACT_EFFECTS_%0d", fault), mem, pcie,
        trace
      );
      if (engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("EXTENSION_CONTRACT_LEDGER",
                   $sformatf("fault %0d committed tentative state", fault))

      profile.extension_fault = RDMA_CMQ_TEST_EXTENSION_GOOD;
      clear_submit_observation(mem, pcie, trace);
      requests[0] = make_command(
        $sformatf("extension_contract_recovery_%0d", fault),
        active_binding, rdma_cmq_test_profile::TEST_OPCODE_A,
        byte'(8'hd0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("EXTENSION_CONTRACT_RECOVERY_BATCH_%0d",
                              fault), batch_status, RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("EXTENSION_CONTRACT_RECOVERY",
                   $sformatf("fault %0d blocked recovery", fault))
      else
        expect_status($sformatf("EXTENSION_CONTRACT_RECOVERY_ITEM_%0d",
                                fault), item_statuses[0], RDMA_SC_OK);
      if (engine.published_count() != 1 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1)
        `uvm_error("EXTENSION_CONTRACT_RECOVERY_LEDGER",
                   $sformatf("fault %0d did not recover cleanly", fault))

      engine.shutdown(status);
      expect_status($sformatf("EXTENSION_CONTRACT_SHUTDOWN_%0d", fault),
                    status, RDMA_SC_OK);
    end

    for (int unsigned fault = RDMA_CMQ_TEST_DIRECT_HANDLE_DROP_SCALAR;
         fault <= RDMA_CMQ_TEST_DIRECT_HANDLE_DETACH_DRIFT; fault++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("direct_handle_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("direct_handle_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("direct_handle_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("direct_handle_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("direct_handle_scheduler_%0d", fault)
      );
      profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
        $sformatf("direct_handle_profile_%0d", fault)
      );
      if (!$cast(profile.direct_handle_fault, fault))
        `uvm_fatal("DIRECT_HANDLE_SETUP",
                   "direct handle fault enum cast failed")
      prepared_binding = make_binding(
        $sformatf("direct_handle_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("direct_handle_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("direct_handle_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("DIRECT_HANDLE_%0d", fault), engine, mem,
                     pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[1];
      requests[0] = make_command(
        $sformatf("direct_handle_request_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'he0 + fault)
      );
      if (!$cast(command_body, requests[0].body))
        `uvm_fatal("DIRECT_HANDLE_SETUP", "command body cast failed")
      scalar_function_h = null;
      edge_target_h = null;
      saved_extension_h = null;
      saved_extension_value = 0;
      if (fault inside {
            RDMA_CMQ_TEST_DIRECT_HANDLE_DROP_SCALAR,
            RDMA_CMQ_TEST_DIRECT_HANDLE_SAME_DRIFT
          }) begin
        scalar_function_h =
          rdma_cmq_scalar_extension_function_handle::type_id::create(
            $sformatf("direct_handle_scalar_%0d", fault)
          );
        scalar_function_h.copy(command_body.function_h);
        scalar_function_h.extension_value = 32'hcafe_0000 + fault;
        saved_extension_value = scalar_function_h.extension_value;
        command_body.function_h = scalar_function_h;
      end
      else begin
        edge_target_h = rdma_cmq_edge_extension_handle::type_id::create(
          $sformatf("direct_handle_edge_%0d", fault)
        );
        edge_target_h.copy(command_body.target_h);
        edge_target_h.extension_h = make_context_handle(
          $sformatf("direct_handle_edge_object_%0d", fault),
          active_binding, RDMA_RESOURCE_CMQ, TEST_CMQ_ID
        );
        saved_extension_h = edge_target_h.extension_h;
        command_body.target_h = edge_target_h;
      end

      engine.submit_batch(requests, tickets, item_statuses, batch_status);

      expect_status($sformatf("DIRECT_HANDLE_BATCH_%0d", fault),
                    batch_status, RDMA_SC_INVALID_STATE);
      if (tickets.size() != 1 || tickets[0] != null ||
          item_statuses.size() != 1)
        `uvm_error("DIRECT_HANDLE_OUTPUT",
                   $sformatf("fault %0d published output", fault))
      else
        expect_status($sformatf("DIRECT_HANDLE_ITEM_%0d", fault),
                      item_statuses[0], RDMA_SC_INVALID_STATE);
      if (profile.snapshot_calls != 1 || profile.same_calls != 2 ||
          profile.detach_calls !=
            ((fault inside {
                RDMA_CMQ_TEST_DIRECT_HANDLE_ALIAS_EDGE,
                RDMA_CMQ_TEST_DIRECT_HANDLE_DETACH_DRIFT
              }) ? 2 : 1))
        `uvm_error("DIRECT_HANDLE_HOOKS",
                   $sformatf("fault %0d hook counts are %0d/%0d/%0d",
                             fault, profile.snapshot_calls,
                             profile.same_calls, profile.detach_calls))
      if ((scalar_function_h != null &&
           (command_body.function_h != scalar_function_h ||
            scalar_function_h.extension_value != saved_extension_value)) ||
          (edge_target_h != null &&
           (command_body.target_h != edge_target_h ||
            edge_target_h.extension_h != saved_extension_h)))
        `uvm_error("DIRECT_HANDLE_SOURCE",
                   $sformatf("fault %0d changed the caller body", fault))
      expect_no_submit_side_effects(
        $sformatf("DIRECT_HANDLE_EFFECTS_%0d", fault), mem, pcie, trace
      );
      if (profile.doorbell_calls != 0)
        `uvm_error("DIRECT_HANDLE_DOORBELL",
                   $sformatf("fault %0d encoded a doorbell", fault))
      if (engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("DIRECT_HANDLE_LEDGER",
                   $sformatf("fault %0d committed tentative state", fault))

      profile.direct_handle_fault = RDMA_CMQ_TEST_DIRECT_HANDLE_GOOD;
      clear_submit_observation(mem, pcie, trace);
      requests[0] = make_command(
        $sformatf("direct_handle_recovery_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hf0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("DIRECT_HANDLE_RECOVERY_BATCH_%0d", fault),
                    batch_status, RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("DIRECT_HANDLE_RECOVERY",
                   $sformatf("fault %0d blocked recovery", fault))
      else
        expect_status($sformatf("DIRECT_HANDLE_RECOVERY_ITEM_%0d", fault),
                      item_statuses[0], RDMA_SC_OK);
      if (engine.published_count() != 1 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1)
        `uvm_error("DIRECT_HANDLE_RECOVERY_LEDGER",
                   $sformatf("fault %0d did not recover cleanly", fault))

      engine.shutdown(status);
      expect_status($sformatf("DIRECT_HANDLE_SHUTDOWN_%0d", fault), status,
                    RDMA_SC_OK);
    end
  endtask

  task automatic check_internal_invariant_batch_abort();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    rdma_status_code_e expected_failure;

    configure_submission_factory_faults();
    disarm_submission_factory_faults();
    for (int unsigned fault = RDMA_CMQ_TEST_ABORT_SLOT_CONTEXT;
         fault <= RDMA_CMQ_TEST_ABORT_PROFILE_OUTPUT; fault++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("invariant_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("invariant_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("invariant_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("invariant_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("invariant_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("invariant_profile_%0d", fault)
      );
      prepared_binding = make_binding(
        $sformatf("invariant_prepared_%0d", fault), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("invariant_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("invariant_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("INVARIANT_%0d", fault), engine, mem, pcie,
                     scheduler, profile, prepared_binding, active_binding,
                     cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      case (fault)
        RDMA_CMQ_TEST_ABORT_SLOT_CONTEXT:
          rdma_cmq_failing_slot_context::arm();
        RDMA_CMQ_TEST_ABORT_TICKET:
          rdma_cmq_failing_ticket::arm();
        RDMA_CMQ_TEST_ABORT_SLOT_RECORD:
          rdma_cmq_failing_slot_record::arm();
        RDMA_CMQ_TEST_ABORT_DEPENDENCY:
          rdma_cmq_failing_dependency::arm();
        RDMA_CMQ_TEST_ABORT_DOORBELL_DESC:
          rdma_cmq_failing_doorbell_desc::arm();
        RDMA_CMQ_TEST_ABORT_PROFILE_OUTPUT: begin
          profile.sqe_fault = RDMA_CMQ_TEST_SQE_BAD_ALIGNMENT;
          profile.sqe_fault_compose_call = 3;
        end
        default:
          `uvm_fatal("INVARIANT_SETUP", "unknown invariant fault")
      endcase
      expected_failure =
        (fault == RDMA_CMQ_TEST_ABORT_PROFILE_OUTPUT) ?
          RDMA_SC_INVALID_ARGUMENT : RDMA_SC_INVALID_STATE;

      requests = new[3];
      requests[0] = make_command(
        $sformatf("invariant_unsupported_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'he0
      );
      requests[1] = make_command(
        $sformatf("invariant_success_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, 8'he1
      );
      requests[2] = make_command(
        $sformatf("invariant_trigger_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_B, 8'he2
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);

      expect_status($sformatf("INVARIANT_BATCH_%0d", fault), batch_status,
                    expected_failure);
      if (tickets.size() != 3 || item_statuses.size() != 3)
        `uvm_error("INVARIANT_ALIGNMENT",
                   $sformatf("fault %0d outputs are misaligned", fault))
      else begin
        expect_status($sformatf("INVARIANT_UNSUPPORTED_%0d", fault),
                      item_statuses[0], RDMA_SC_UNSUPPORTED_OPCODE);
        expect_status($sformatf("INVARIANT_EARLY_SUCCESS_%0d", fault),
                      item_statuses[1], expected_failure);
        expect_status($sformatf("INVARIANT_TRIGGER_%0d", fault),
                      item_statuses[2], expected_failure);
        foreach (tickets[i])
          if (tickets[i] != null)
            `uvm_error("INVARIANT_TICKET",
                       $sformatf("fault %0d item %0d returned ticket",
                                 fault, i))
      end
      expect_no_submit_side_effects(
        $sformatf("INVARIANT_EFFECTS_%0d", fault), mem, pcie, trace
      );
      if (engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("INVARIANT_LEDGER",
                   $sformatf("fault %0d committed tentative state", fault))
      if (fault != RDMA_CMQ_TEST_ABORT_PROFILE_OUTPUT &&
          submission_factory_fault_armed())
        `uvm_error("INVARIANT_ARM",
                   $sformatf("fault %0d fixture was not exercised", fault))

      disarm_submission_factory_faults();
      profile.sqe_fault = RDMA_CMQ_TEST_SQE_GOOD;
      profile.sqe_fault_compose_call = 0;
      clear_submit_observation(mem, pcie, trace);
      requests = new[1];
      requests[0] = make_command(
        $sformatf("invariant_recovery_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hf0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("INVARIANT_RECOVERY_BATCH_%0d", fault),
                    batch_status, RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("INVARIANT_RECOVERY",
                   $sformatf("fault %0d contaminated recovery", fault))
      else
        expect_status($sformatf("INVARIANT_RECOVERY_ITEM_%0d", fault),
                      item_statuses[0], RDMA_SC_OK);

      engine.shutdown(status);
      expect_status($sformatf("INVARIANT_SHUTDOWN_%0d", fault), status,
                    RDMA_SC_OK);
    end
    disarm_submission_factory_faults();
  endtask

  task automatic check_timeout_quarantine_and_late_diagnostic();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_command_desc reuse_request;
    rdma_cmq_ticket tickets[];
    rdma_cmq_ticket reuse_ticket;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_dma_mapping mapping;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image first_raw;
    rdma_hw_image reuse_raw;
    rdma_hw_image survivor_raw;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("timeout_engine");
    mem = rdma_mock_host_mem::type_id::create("timeout_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("timeout_pcie");
    trace = rdma_mock_call_trace::type_id::create("timeout_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "timeout_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("timeout_profile");
    prepared_binding = make_binding("timeout_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("timeout_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("timeout_cmq", prepared_binding);
    prepare_active("TIMEOUT", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[2];
    requests[0] = make_command(
      "timeout_first", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd0, 10ns
    );
    requests[1] = make_command(
      "timeout_survivor", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'hd1, 1us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("TIMEOUT_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 2 || item_statuses.size() != 2 ||
        tickets[0] == null || tickets[1] == null) begin
      `uvm_error("TIMEOUT_BATCH", "timeout batch outputs are incomplete")
      engine.shutdown(status);
      return;
    end
    expect_status("TIMEOUT_ITEM_0", item_statuses[0], RDMA_SC_OK);
    expect_status("TIMEOUT_ITEM_1", item_statuses[1], RDMA_SC_OK);
    if (tickets[0].command_id[4:0] != 0 ||
        tickets[1].command_id[4:0] != 1)
      `uvm_error("TIMEOUT_TOKEN_ORDER", "initial token order is unexpected")
    mapping = engine.mapping_snapshot();

    #20ns;
    engine.expire(completions, status);
    expect_status("TIMEOUT_EXPIRE", status, RDMA_SC_OK);
    if (completions.size() != 1)
      `uvm_error("TIMEOUT_EXPIRE", "expire did not return exactly one result")
    else
      expect_timeout_completion("TIMEOUT_RESULT", completions[0], tickets[0]);
    if (engine.slot_state_at(0) != CMQ_SLOT_TIMED_OUT_QUARANTINED ||
        engine.slot_state_at(1) != CMQ_SLOT_PUBLISHED ||
        engine.published_count() != 2 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 2 ||
        engine.slot_record_count() != 2)
      `uvm_error("TIMEOUT_QUARANTINE",
                 "partial expiry changed the quarantine ledger incorrectly")

    engine.expire(completions, status);
    expect_status("TIMEOUT_EXPIRE_AGAIN", status, RDMA_SC_OK);
    if (completions.size() != 0)
      `uvm_error("TIMEOUT_EXPIRE_AGAIN",
                 "timeout completion was delivered more than once")

    clear_submit_observation(mem, pcie, trace);
    reuse_request = make_command(
      "timeout_reuse", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd2, 10ns
    );
    engine.submit(reuse_request, reuse_ticket, status);
    expect_status("TIMEOUT_REUSE", status, RDMA_SC_OK);
    if (reuse_ticket == null)
      `uvm_error("TIMEOUT_REUSE", "reused token returned no ticket")
    else if (reuse_ticket.command_id[4:0] != tickets[0].command_id[4:0] ||
             reuse_ticket.command_id == tickets[0].command_id ||
             reuse_ticket.command_id[63:5] <= tickets[0].command_id[63:5])
      `uvm_error("TIMEOUT_REUSE",
                 "token reuse did not advance the full command incarnation")

    mem.calls.delete();
    write_profile_cqe(
      "TIMEOUT_LATE_FIRST", mem, mapping, profile, 0, 1'b1, tickets[0],
      0, first_raw
    );
    engine.poll(completions, diagnostics, status);
    expect_status("TIMEOUT_LATE_FIRST_POLL", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 1)
      `uvm_error("TIMEOUT_LATE_FIRST_POLL",
                 "late CQE was not converted to one diagnostic")
    else
      expect_late_diagnostic("TIMEOUT_LATE_FIRST_DIAG", engine,
                             diagnostics[0], tickets[0], first_raw);
    if (reuse_ticket != null &&
        (!engine.token_in_use_at(reuse_ticket.command_id[4:0]) ||
         engine.command_registry_count() != 2 ||
         engine.tokens_in_use_count() != 2 ||
         engine.retired_count() != 1 ||
         engine.cq_consumed_count() != 1))
      `uvm_error("TIMEOUT_LATE_TOKEN",
                 "late CQE reclaimed the token's newer incarnation")

    engine.poll(completions, diagnostics, status);
    expect_status("TIMEOUT_LATE_REPEAT_POLL", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.cq_consumed_count() != 1)
      `uvm_error("TIMEOUT_LATE_REPEAT_POLL",
                 "consumed late CQE was delivered more than once")

    if (reuse_ticket != null) begin
      mem.calls.delete();
      write_profile_cqe(
        "TIMEOUT_READY_AT_DEADLINE", mem, mapping, profile, 1, 1'b1,
        reuse_ticket, 0, reuse_raw
      );
      #20ns;
      engine.poll(completions, diagnostics, status);
      expect_status("TIMEOUT_READY_AT_DEADLINE_POLL", status, RDMA_SC_OK);
      if (completions.size() != 1 || diagnostics.size() != 1)
        `uvm_error("TIMEOUT_READY_AT_DEADLINE_POLL",
                   "deadline-ready CQE was not expired before inspection")
      else begin
        expect_timeout_completion("TIMEOUT_READY_AT_DEADLINE_RESULT",
                                  completions[0], reuse_ticket);
        expect_late_diagnostic("TIMEOUT_READY_AT_DEADLINE_DIAG", engine,
                               diagnostics[0], reuse_ticket, reuse_raw);
      end
      if (engine.slot_state_at(reuse_ticket.sq_index) !=
            CMQ_SLOT_LATE_COMPLETED ||
          engine.retired_count() != 1 ||
          engine.cq_consumed_count() != 2 ||
          engine.command_registry_count() != 1 ||
          engine.tokens_in_use_count() != 1 ||
          engine.entry_registry_count() != 2)
        `uvm_error("TIMEOUT_READY_AT_DEADLINE_LEDGER",
                   "deadline-ready late completion ledger is inconsistent")
    end

    mem.calls.delete();
    write_profile_cqe(
      "TIMEOUT_SURVIVOR_CQE", mem, mapping, profile, 2, 1'b1, tickets[1],
      0, survivor_raw
    );
    engine.poll(completions, diagnostics, status);
    expect_status("TIMEOUT_SURVIVOR_POLL", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("TIMEOUT_SURVIVOR_POLL",
                 "unexpired survivor did not complete normally")
    else
      expect_polled_completion(
        "TIMEOUT_SURVIVOR_RESULT", engine, completions[0], tickets[1],
        survivor_raw, 1'b1, 0, RDMA_SC_OK
      );
    if (engine.published_count() != 3 || engine.retired_count() != 3 ||
        engine.cq_consumed_count() != 3 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("TIMEOUT_FINAL_LEDGER",
                 "normal survivor did not retire the late-completed prefix")

    engine.shutdown(status);
    expect_status("TIMEOUT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_expire_snapshot_failure_is_atomic_and_retryable();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completions[$];
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "expire_snapshot_failure_engine"
    );
    mem = rdma_mock_host_mem::type_id::create(
      "expire_snapshot_failure_mem"
    );
    pcie = rdma_cmq_test_pcie::type_id::create(
      "expire_snapshot_failure_pcie"
    );
    trace = rdma_mock_call_trace::type_id::create(
      "expire_snapshot_failure_trace"
    );
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "expire_snapshot_failure_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "expire_snapshot_failure_profile"
    );
    prepared_binding = make_binding(
      "expire_snapshot_failure_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "expire_snapshot_failure_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("expire_snapshot_failure_cmq", prepared_binding);
    prepare_active(
      "EXPIRE_SNAPSHOT_FAILURE", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    clear_submit_observation(mem, pcie, trace);

    requests = new[2];
    requests[0] = make_command(
      "expire_snapshot_failure_request_0", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd8, 10ns
    );
    requests[1] = make_command(
      "expire_snapshot_failure_request_1", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'hd9, 10ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_SUBMIT", batch_status, RDMA_SC_OK);
    if (tickets.size() != 2 || item_statuses.size() != 2 ||
        tickets[0] == null || tickets[1] == null) begin
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_SUBMIT",
                 "two-command timeout fixture is incomplete")
      engine.shutdown(status);
      return;
    end
    expect_status("EXPIRE_SNAPSHOT_FAILURE_ITEM_0", item_statuses[0],
                  RDMA_SC_OK);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_ITEM_1", item_statuses[1],
                  RDMA_SC_OK);

    if (!engine.install_slot_ticket_function_clone_fault(
          tickets[1].sq_index, RDMA_CMQ_TEST_CLONE_NULL
        ))
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_INJECT",
                 "could not inject the second ticket snapshot fault")
    rdma_cmq_clone_fault_function_handle::clear_fault_clone_calls();
    #20ns;
    engine.expire(completions, status);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    if (rdma_cmq_clone_fault_function_handle::fault_clone_call_count() != 1)
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_HIT",
                 "the second timeout ticket fault was not exercised once")
    if (completions.size() != 0 || engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.published_count() != 2 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 2 ||
        engine.slot_record_count() != 2 ||
        engine.command_registry_count() != 2 ||
        engine.entry_registry_count() != 2 ||
        engine.slot_state_at(tickets[0].sq_index) != CMQ_SLOT_PUBLISHED ||
        engine.slot_state_at(tickets[1].sq_index) != CMQ_SLOT_PUBLISHED)
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_ATOMIC",
                 "later timeout snapshot failure partially mutated authority")

    if (!engine.set_slot_ticket_function_clone_fault(
          tickets[1].sq_index, RDMA_CMQ_TEST_CLONE_GOOD
        ))
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_CLEAR",
                 "could not clear the second ticket snapshot fault")
    engine.expire(completions, status);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_RETRY_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 2)
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_RETRY_OUTPUT",
                 "retry did not deliver exactly two timeout completions")
    else begin
      expect_timeout_completion("EXPIRE_SNAPSHOT_FAILURE_RETRY_0",
                                completions[0], tickets[0]);
      expect_timeout_completion("EXPIRE_SNAPSHOT_FAILURE_RETRY_1",
                                completions[1], tickets[1]);
    end
    if (engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.published_count() != 2 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 2 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 2 ||
        engine.slot_state_at(tickets[0].sq_index) !=
          CMQ_SLOT_TIMED_OUT_QUARANTINED ||
        engine.slot_state_at(tickets[1].sq_index) !=
          CMQ_SLOT_TIMED_OUT_QUARANTINED)
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_RETRY_LEDGER",
                 "successful retry did not quarantine both commands")

    engine.expire(completions, status);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_ONCE_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 0)
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_ONCE",
                 "retry timeout completions were delivered more than once")
    engine.shutdown(status);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_late_diagnostic_snapshot_failure_is_retryable();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_dma_mapping mapping;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "late_snapshot_failure_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("late_snapshot_failure_mem");
    pcie = rdma_cmq_test_pcie::type_id::create(
      "late_snapshot_failure_pcie"
    );
    trace = rdma_mock_call_trace::type_id::create(
      "late_snapshot_failure_trace"
    );
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "late_snapshot_failure_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "late_snapshot_failure_profile"
    );
    prepared_binding = make_binding("late_snapshot_failure_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("late_snapshot_failure_active",
                                  RDMA_BIND_ACTIVE);
    cmq = make_cmq("late_snapshot_failure_cmq", prepared_binding);
    prepare_active(
      "LATE_SNAPSHOT_FAILURE", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    clear_submit_observation(mem, pcie, trace);

    request = make_command(
      "late_snapshot_failure_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hda, 10ns
    );
    engine.submit(request, ticket, status);
    expect_status("LATE_SNAPSHOT_FAILURE_SUBMIT", status, RDMA_SC_OK);
    if (ticket == null) begin
      `uvm_error("LATE_SNAPSHOT_FAILURE_SUBMIT",
                 "late diagnostic fixture returned no ticket")
      engine.shutdown(status);
      return;
    end
    mapping = engine.mapping_snapshot();
    #20ns;
    engine.expire(completions, status);
    expect_status("LATE_SNAPSHOT_FAILURE_EXPIRE", status, RDMA_SC_OK);
    if (completions.size() != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_EXPIRE",
                 "fixture did not produce one timeout completion")
    else
      expect_timeout_completion("LATE_SNAPSHOT_FAILURE_TIMEOUT",
                                completions[0], ticket);
    if (engine.slot_state_at(ticket.sq_index) !=
          CMQ_SLOT_TIMED_OUT_QUARANTINED ||
        engine.command_registry_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.entry_registry_count() != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_QUARANTINE",
                 "fixture did not retain quarantined late-CQE authority")

    write_profile_cqe(
      "LATE_SNAPSHOT_FAILURE_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );
    if (!engine.install_slot_ticket_function_clone_fault(
          ticket.sq_index, RDMA_CMQ_TEST_CLONE_NULL
        ))
      `uvm_error("LATE_SNAPSHOT_FAILURE_INJECT",
                 "could not inject the late diagnostic ticket fault")
    rdma_cmq_clone_fault_function_handle::clear_fault_clone_calls();
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("LATE_SNAPSHOT_FAILURE_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    if (rdma_cmq_clone_fault_function_handle::fault_clone_call_count() != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_HIT",
                 "the late diagnostic ticket fault was not exercised once")
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.published_count() != 1 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 1 ||
        engine.slot_state_at(ticket.sq_index) !=
          CMQ_SLOT_TIMED_OUT_QUARANTINED ||
        count_host_calls(mem, "read") != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_ATOMIC",
                 "diagnostic snapshot failure consumed the late CQE")

    if (!engine.set_slot_ticket_function_clone_fault(
          ticket.sq_index, RDMA_CMQ_TEST_CLONE_GOOD
        ))
      `uvm_error("LATE_SNAPSHOT_FAILURE_CLEAR",
                 "could not clear the late diagnostic ticket fault")
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("LATE_SNAPSHOT_FAILURE_RETRY_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_RETRY_OUTPUT",
                 "retry did not deliver one late diagnostic")
    else
      expect_late_diagnostic("LATE_SNAPSHOT_FAILURE_RETRY_DIAG", engine,
                             diagnostics[0], ticket, raw_cqe);
    if (engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.published_count() != 1 || engine.retired_count() != 1 ||
        engine.cq_consumed_count() != 1 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0 ||
        count_host_calls(mem, "read") != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_RETRY_LEDGER",
                 "late diagnostic retry did not consume and retire once")

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("LATE_SNAPSHOT_FAILURE_ONCE_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        count_host_calls(mem, "read") != 0)
      `uvm_error("LATE_SNAPSHOT_FAILURE_ONCE",
                 "late diagnostic was delivered more than once")
    engine.shutdown(status);
    expect_status("LATE_SNAPSHOT_FAILURE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_command_incarnation_exhaustion();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket first_ticket;
    rdma_cmq_ticket second_ticket;
    rdma_cmq_ticket exhausted_ticket;
    rdma_dma_mapping mapping;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("exhaustion_engine");
    mem = rdma_mock_host_mem::type_id::create("exhaustion_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("exhaustion_pcie");
    trace = rdma_mock_call_trace::type_id::create("exhaustion_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "exhaustion_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("exhaustion_profile");
    prepared_binding = make_binding("exhaustion_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("exhaustion_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("exhaustion_cmq", prepared_binding);
    prepare_active("EXHAUSTION", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    mapping = engine.mapping_snapshot();
    engine.seed_token_incarnation(0, {59{1'b1}});
    clear_submit_observation(mem, pcie, trace);

    request = make_command("exhaustion_skip_first", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'he0, 1us);
    engine.submit(request, first_ticket, status);
    expect_status("EXHAUSTION_SKIP_FIRST", status, RDMA_SC_OK);
    if (first_ticket == null || first_ticket.command_id[4:0] != 1 ||
        engine.token_incarnation_at(0) != {59{1'b1}})
      `uvm_error("EXHAUSTION_SKIP_FIRST",
                 "max-incarnation token was not permanently skipped")

    if (first_ticket != null) begin
      mem.calls.delete();
      write_profile_cqe(
        "EXHAUSTION_FIRST_CQE", mem, mapping, profile, 0, 1'b1,
        first_ticket, 0, raw_cqe
      );
      engine.poll(completions, diagnostics, status);
      expect_status("EXHAUSTION_FIRST_POLL", status, RDMA_SC_OK);
      if (completions.size() != 1 || diagnostics.size() != 0)
        `uvm_error("EXHAUSTION_FIRST_POLL",
                   "skip fixture did not complete normally")
    end

    clear_submit_observation(mem, pcie, trace);
    request = make_command("exhaustion_skip_again", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_B, 8'he1, 1us);
    engine.submit(request, second_ticket, status);
    expect_status("EXHAUSTION_SKIP_AGAIN", status, RDMA_SC_OK);
    if (first_ticket == null || second_ticket == null ||
        second_ticket.command_id[4:0] != 1 ||
        second_ticket.command_id[63:5] <= first_ticket.command_id[63:5] ||
        engine.token_incarnation_at(0) != {59{1'b1}})
      `uvm_error("EXHAUSTION_SKIP_AGAIN",
                 "max-incarnation token became allocatable after retirement")

    engine.seed_all_token_incarnations({59{1'b1}});
    clear_submit_observation(mem, pcie, trace);
    request = make_command("exhaustion_all", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'he2, 1us);
    engine.submit(request, exhausted_ticket, status);
    expect_status("EXHAUSTION_ALL", status, RDMA_SC_RESOURCE_EXHAUSTED);
    if (exhausted_ticket != null)
      `uvm_error("EXHAUSTION_ALL", "exhausted submit returned a ticket")
    expect_no_submit_side_effects("EXHAUSTION_ALL_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 2 || engine.retired_count() != 1 ||
        engine.cq_consumed_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1 ||
        engine.token_incarnation_at(0) != {59{1'b1}})
      `uvm_error("EXHAUSTION_ALL_LEDGER",
                 "resource exhaustion polluted committed authority")

    engine.shutdown(status);
    expect_status("EXHAUSTION_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_incarnation_survives_reprepare();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket first_ticket;
    rdma_cmq_ticket second_ticket;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("incarnation_engine");
    mem = rdma_mock_host_mem::type_id::create("incarnation_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("incarnation_pcie");
    trace = rdma_mock_call_trace::type_id::create("incarnation_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "incarnation_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "incarnation_profile"
    );
    prepared_binding = make_binding("incarnation_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("incarnation_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("incarnation_cmq", prepared_binding);
    prepare_active("INCARNATION", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    request = make_command("incarnation_first", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'hc0);
    engine.submit(request, first_ticket, status);
    expect_status("INCARNATION_FIRST", status, RDMA_SC_OK);
    if (first_ticket == null)
      `uvm_error("INCARNATION_FIRST", "first submit returned no ticket")

    engine.shutdown(status);
    expect_status("INCARNATION_SHUTDOWN", status, RDMA_SC_OK);
    prepared_binding = make_binding("incarnation_reprepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("incarnation_reactive", RDMA_BIND_ACTIVE);
    cmq = make_cmq("incarnation_recmq", prepared_binding);
    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567, mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("INCARNATION_REPREPARE", status, RDMA_SC_OK);
    engine.activate(active_binding, status);
    expect_status("INCARNATION_REACTIVATE", status, RDMA_SC_OK);
    clear_submit_observation(mem, pcie, trace);

    request = make_command("incarnation_second", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'hc1);
    engine.submit(request, second_ticket, status);
    expect_status("INCARNATION_SECOND", status, RDMA_SC_OK);
    if (first_ticket == null || second_ticket == null)
      `uvm_error("INCARNATION_MONOTONIC",
                 "same-generation lifecycle submit returned null ticket")
    else if (second_ticket.command_id == first_ticket.command_id ||
             second_ticket.command_id[4:0] !=
               first_ticket.command_id[4:0] ||
             second_ticket.command_id[63:5] <=
               first_ticket.command_id[63:5])
      `uvm_error("INCARNATION_MONOTONIC",
                 "shutdown/reprepare reused a prior full command ID")

    engine.shutdown(status);
    expect_status("INCARNATION_FINAL_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_max_dependency_id_boundary();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    longint unsigned captured_dependency_id;

    disarm_submission_factory_faults();
    engine = rdma_cmq_engine_probe::type_id::create(
      "max_dependency_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("max_dependency_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("max_dependency_pcie");
    trace = rdma_mock_call_trace::type_id::create("max_dependency_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "max_dependency_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "max_dependency_profile"
    );
    prepared_binding = make_binding("max_dependency_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("max_dependency_active",
                                  RDMA_BIND_ACTIVE);
    cmq = make_cmq("max_dependency_cmq", prepared_binding);
    prepare_active("MAX_DEPENDENCY", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);
    engine.seed_ring_counters(64'hffff_ffff_ffff_fffe,
                              64'hffff_ffff_ffff_fffe);
    rdma_cmq_failing_dependency::arm_capture();

    requests = new[1];
    requests[0] = make_command(
      "max_dependency_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hbe, 10us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("MAX_DEPENDENCY_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("MAX_DEPENDENCY_OUTPUT", "boundary output is invalid")
    else begin
      expect_status("MAX_DEPENDENCY_ITEM", item_statuses[0], RDMA_SC_OK);
      if (tickets[0].slot_sequence != 64'hffff_ffff_ffff_fffe ||
          tickets[0].sq_index != 30 || !tickets[0].sq_wrap)
        `uvm_error("MAX_DEPENDENCY_TICKET",
                   "maximum valid dependency boundary used the wrong slot")
    end
    if (!rdma_cmq_failing_dependency::take_captured_dependency_id(
          captured_dependency_id
        ) || captured_dependency_id != 64'hffff_ffff_ffff_ffff)
      `uvm_error("MAX_DEPENDENCY_ID",
                 "slot max-1 did not produce dependency ID max")
    if (mem.calls.size() != 1 || mem.calls[0].offset != (30 * 64) ||
        pcie.calls.size() != 3 || profile.last_final_pi != 31 ||
        !profile.last_polarity)
      `uvm_error("MAX_DEPENDENCY_TRANSPORT",
                 "maximum valid dependency boundary was not published")
    if (engine.published_count() != 64'hffff_ffff_ffff_ffff ||
        engine.retired_count() != 64'hffff_ffff_ffff_fffe ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1)
      `uvm_error("MAX_DEPENDENCY_LEDGER",
                 "maximum valid dependency boundary corrupted authority")

    disarm_submission_factory_faults();
    engine.shutdown(status);
    expect_status("MAX_DEPENDENCY_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_counter_invariants_poison_before_transport();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    longint unsigned seeded_publish_seq;
    longint unsigned seeded_retire_seq;
    int unsigned request_count;
    string label;

    for (int unsigned invariant = 0; invariant < 3; invariant++) begin
      case (invariant)
        0: begin
          label = "COUNTER_NEXT_PUBLICATION_OVERFLOW";
          seeded_publish_seq = 64'hffff_ffff_ffff_fff0;
          seeded_retire_seq = 64'hffff_ffff_ffff_fff0;
          request_count = 32;
        end
        1: begin
          label = "COUNTER_PUBLISH_BEFORE_RETIRE";
          seeded_publish_seq = 4;
          seeded_retire_seq = 5;
          request_count = 1;
        end
        default: begin
          label = "COUNTER_OCCUPANCY_EXCEEDS_DEPTH";
          seeded_publish_seq = 33;
          seeded_retire_seq = 0;
          request_count = 1;
        end
      endcase

      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("counter_poison_engine_%0d", invariant)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("counter_poison_mem_%0d", invariant)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("counter_poison_pcie_%0d", invariant)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("counter_poison_trace_%0d", invariant)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("counter_poison_scheduler_%0d", invariant)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("counter_poison_profile_%0d", invariant)
      );
      prepared_binding = make_binding(
        $sformatf("counter_poison_prepared_%0d", invariant),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("counter_poison_active_%0d", invariant),
        RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("counter_poison_cmq_%0d", invariant),
                     prepared_binding);
      prepare_active(label, engine, mem, pcie, scheduler, profile,
                     prepared_binding, active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);
      engine.seed_ring_counters(seeded_publish_seq, seeded_retire_seq);

      requests = new[request_count];
      foreach (requests[i])
        requests[i] = make_command(
          $sformatf("counter_poison_request_%0d_%0d", invariant, i),
          active_binding, rdma_cmq_test_profile::TEST_OPCODE_A,
          byte'(8'hc0 + i), 10us
        );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      if (batch_status == null || batch_status.ok())
        `uvm_error("COUNTER_POISON_STATUS",
                   $sformatf("%s did not fail the batch", label))
      if (invariant == 0 &&
          (batch_status == null ||
           batch_status.message !=
             "CMQ producer sequence addition overflows"))
        `uvm_error("COUNTER_POISON_OVERFLOW_BRANCH",
                   "counter overflow did not fail at producer addition")
      if (tickets.size() != request_count ||
          item_statuses.size() != request_count)
        `uvm_error("COUNTER_POISON_ALIGNMENT",
                   $sformatf("%s outputs are misaligned", label))
      else begin
        foreach (tickets[i]) begin
          if (tickets[i] != null)
            `uvm_error("COUNTER_POISON_TICKET",
                       $sformatf("%s published ticket %0d", label, i))
          if (item_statuses[i] == null || item_statuses[i].ok())
            `uvm_error("COUNTER_POISON_ITEM_STATUS",
                       $sformatf("%s item %0d did not fail", label, i))
        end
      end
      expect_no_submit_side_effects({label, "_EFFECTS"}, mem, pcie, trace);
      if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          engine.mapping_snapshot() == null)
        `uvm_error("COUNTER_POISON_STATE",
                   $sformatf("%s did not retain poisoned release authority",
                             label))
      if (engine.published_count() != seeded_publish_seq ||
          engine.retired_count() != seeded_retire_seq ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("COUNTER_POISON_LEDGER",
                   $sformatf("%s changed the authority ledger", label))

      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    end
  endtask

  task automatic check_poll_raw_snapshot_rejects_self_clone_mutation();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;
    uvm_factory factory;

    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_raw_snapshot_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_raw_snapshot_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poll_raw_snapshot_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_raw_snapshot_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_raw_snapshot_profile"
    );
    prepared_binding = make_binding(
      "poll_raw_snapshot_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_raw_snapshot_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_raw_snapshot_cmq", prepared_binding);
    prepare_active(
      "POLL_RAW_SNAPSHOT", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "poll_raw_snapshot_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h51, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_RAW_SNAPSHOT_SUBMIT", status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "POLL_RAW_SNAPSHOT_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );

    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_hw_image::get_type(), rdma_cmq_poll_raw_self_image::get_type(),
      1'b1
    );
    rdma_cmq_poll_raw_self_image::arm_next_raw();
    profile.mutate_raw_cqe_input = 1'b1;
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_RAW_SNAPSHOT_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.cq_consumed_count() != 0 || engine.retired_count() != 0 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1)
      `uvm_error(
        "POLL_RAW_SNAPSHOT_ATOMIC",
        "raw snapshot trust failure changed terminal authority"
      )
    rdma_cmq_poll_raw_self_image::disarm();

    profile.mutate_raw_cqe_input = 1'b0;
    rdma_cmq_poll_raw_self_image::clear_clone_calls();
    rdma_cmq_poll_raw_self_image::arm_next_raw_stateful();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_RAW_SNAPSHOT_RETRY_STATUS", status, RDMA_SC_OK);
    if (rdma_cmq_poll_raw_self_image::clone_call_count() != 1)
      `uvm_error(
        "POLL_RAW_SNAPSHOT_RETRY_CLONES",
        $sformatf(
          "raw snapshot was cloned %0d times instead of once",
          rdma_cmq_poll_raw_self_image::clone_call_count()
        )
      )
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        completions[0] == null || completions[0].raw_cqe == null ||
        !engine.probe_same_image(completions[0].raw_cqe, raw_cqe) ||
        engine.cq_consumed_count() != 1 || engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error(
        "POLL_RAW_SNAPSHOT_RETRY",
        "raw snapshot retry did not deliver the original CQE atomically"
      )
    rdma_cmq_poll_raw_self_image::disarm();

    engine.shutdown(status);
    expect_status("POLL_RAW_SNAPSHOT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_poll_payload_retained_self_clone_is_detached();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_cmq_self_clone_completion_payload delivered_payload;
    rdma_hw_image raw_cqe;
    rdma_status status;
    int unsigned saved_value;
    int unsigned saved_object_id;

    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_payload_detachment_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_payload_detachment_mem");
    pcie = rdma_cmq_test_pcie::type_id::create(
      "poll_payload_detachment_pcie"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_payload_detachment_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_payload_detachment_profile"
    );
    profile.use_self_clone_completion_payload = 1'b1;
    prepared_binding = make_binding(
      "poll_payload_detachment_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_payload_detachment_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_payload_detachment_cmq", prepared_binding);
    prepare_active(
      "POLL_PAYLOAD_DETACHMENT", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "poll_payload_detachment_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h52, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_PAYLOAD_DETACHMENT_SUBMIT", status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "POLL_PAYLOAD_DETACHMENT_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );

    engine.poll(completions, diagnostics, status);
    expect_status("POLL_PAYLOAD_DETACHMENT_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        !$cast(delivered_payload, completions[0].decoded_response) ||
        profile.last_completion_payload_source == null ||
        delivered_payload == profile.last_completion_payload_source ||
        delivered_payload.nested_h == null ||
        delivered_payload.nested_h ==
          profile.last_completion_payload_source.nested_h) begin
      `uvm_error(
        "POLL_PAYLOAD_DETACHMENT_OUTPUT",
        "retained self-cloning payload was not deeply detached"
      )
    end
    else begin
      saved_value = delivered_payload.value;
      saved_object_id = delivered_payload.nested_h.object_id;
      profile.last_completion_payload_source.value++;
      profile.last_completion_payload_source.nested_h.object_id++;
      if (delivered_payload.value != saved_value ||
          delivered_payload.nested_h.object_id != saved_object_id)
        `uvm_error(
          "POLL_PAYLOAD_DETACHMENT_RETAINED",
          "profile-retained payload mutation reached delivered completion"
        )
    end

    engine.shutdown(status);
    expect_status("POLL_PAYLOAD_DETACHMENT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_poll_payload_hook_contract_failures();
    rdma_cmq_test_hook_fault_e faults[8];
    string labels[8];
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    faults[0] = RDMA_CMQ_TEST_HOOK_NULL_STATUS;
    faults[1] = RDMA_CMQ_TEST_HOOK_NULL_OUTPUT;
    faults[2] = RDMA_CMQ_TEST_HOOK_WRONG_TYPE;
    faults[3] = RDMA_CMQ_TEST_HOOK_ALIASED_OUTPUT;
    faults[4] = RDMA_CMQ_TEST_HOOK_MUTATED_OUTPUT;
    faults[5] = RDMA_CMQ_TEST_HOOK_MUTATE_SOURCE;
    faults[6] = RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT;
    faults[7] = RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT;
    labels[0] = "NULL_STATUS";
    labels[1] = "NULL_OUTPUT";
    labels[2] = "WRONG_TYPE";
    labels[3] = "ALIAS";
    labels[4] = "WRONG_VALUE";
    labels[5] = "SOURCE_MUTATION";
    labels[6] = "SAME_DRIFT";
    labels[7] = "DETACH_DRIFT";

    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_payload_hook_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_payload_hook_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poll_payload_hook_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_payload_hook_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_payload_hook_profile"
    );
    profile.use_self_clone_completion_payload = 1'b1;
    prepared_binding = make_binding(
      "poll_payload_hook_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_payload_hook_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_payload_hook_cmq", prepared_binding);
    prepare_active(
      "POLL_PAYLOAD_HOOK", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "poll_payload_hook_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h60, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_PAYLOAD_HOOK_SUBMIT", status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "POLL_PAYLOAD_HOOK_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );

    foreach (faults[i]) begin
      string label;

      label = {"POLL_PAYLOAD_HOOK_", labels[i]};
      profile.completion_payload_hook_fault = faults[i];
      profile.completion_payload_same_calls = 0;
      profile.completion_payload_detach_calls = 0;
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_STATUS"}, status, RDMA_SC_INVALID_STATE);
      if (completions.size() != 0 || diagnostics.size() != 0 ||
          engine.cq_consumed_count() != 0 || engine.retired_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1 ||
          engine.command_registry_count() != 1 ||
          engine.entry_registry_count() != 1)
        `uvm_error(label,
                   "payload hook trust failure changed terminal authority")
    end

    profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_GOOD;
    profile.completion_payload_same_calls = 0;
    profile.completion_payload_detach_calls = 0;
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_PAYLOAD_HOOK_RETRY_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        engine.cq_consumed_count() != 1 || engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error(
        "POLL_PAYLOAD_HOOK_RETRY",
        "corrected payload hook did not retry the same CQE atomically"
      )

    engine.shutdown(status);
    expect_status("POLL_PAYLOAD_HOOK_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_poll_decoded_status_contract_failures();
    rdma_cmq_test_decoded_contract_fault_e faults[7];
    rdma_cmq_test_decoded_contract_fault_e legal_faults[2];
    rdma_severity_e legal_severities[2];
    string labels[7];
    string legal_labels[2];
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    faults[0] = RDMA_CMQ_TEST_DECODED_ZERO_NONOK;
    faults[1] = RDMA_CMQ_TEST_DECODED_ZERO_HARDWARE_VALID;
    faults[2] = RDMA_CMQ_TEST_DECODED_NONZERO_OK;
    faults[3] = RDMA_CMQ_TEST_DECODED_NONZERO_HARDWARE_INVALID;
    faults[4] = RDMA_CMQ_TEST_DECODED_HARDWARE_MISMATCH;
    faults[5] = RDMA_CMQ_TEST_DECODED_CATEGORY_MISMATCH;
    faults[6] = RDMA_CMQ_TEST_DECODED_SEVERITY_MISMATCH;
    labels[0] = "ZERO_NONOK";
    labels[1] = "ZERO_HARDWARE_VALID";
    labels[2] = "NONZERO_OK";
    labels[3] = "NONZERO_HARDWARE_INVALID";
    labels[4] = "HARDWARE_MISMATCH";
    labels[5] = "CATEGORY_MISMATCH";
    labels[6] = "SEVERITY_MISMATCH";
    legal_faults[0] = RDMA_CMQ_TEST_DECODED_NONZERO_WARNING;
    legal_faults[1] = RDMA_CMQ_TEST_DECODED_NONZERO_FATAL;
    legal_severities[0] = RDMA_SEVERITY_WARNING;
    legal_severities[1] = RDMA_SEVERITY_FATAL;
    legal_labels[0] = "NONZERO_WARNING";
    legal_labels[1] = "NONZERO_FATAL";

    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_decoded_contract_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_decoded_contract_mem");
    pcie = rdma_cmq_test_pcie::type_id::create(
      "poll_decoded_contract_pcie"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_decoded_contract_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_decoded_contract_profile"
    );
    prepared_binding = make_binding(
      "poll_decoded_contract_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_decoded_contract_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_decoded_contract_cmq", prepared_binding);
    prepare_active(
      "POLL_DECODED_CONTRACT", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "poll_decoded_contract_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h61, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_DECODED_CONTRACT_SUBMIT", status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "POLL_DECODED_CONTRACT_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 32'h1, raw_cqe
    );

    foreach (faults[i]) begin
      string label;

      label = {"POLL_DECODED_CONTRACT_", labels[i]};
      profile.decoded_contract_fault = faults[i];
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_STATUS"}, status, RDMA_SC_CODEC_ERROR);
      if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          completions.size() != 0 || diagnostics.size() != 1 ||
          engine.published_count() != 1 ||
          engine.cq_consumed_count() != 0 || engine.retired_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1 ||
          engine.command_registry_count() != 1 ||
          engine.entry_registry_count() != 1 ||
          engine.terminal_fifo_count() != 0)
        `uvm_error(
          label,
          "decoded status contract violation did not poison atomically"
        )
      if (diagnostics.size() == 1)
        expect_poison_diagnostic(
          {label, "_DIAGNOSTIC"}, engine, diagnostics[0],
          RDMA_CMQ_DIAG_MALFORMED_CQE, ticket, raw_cqe,
          active_binding, cmq
        );
      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);

      if (i + 1 < $size(faults)) begin
        engine = rdma_cmq_engine_probe::type_id::create(
          $sformatf("poll_decoded_contract_engine_%0d", i + 1)
        );
        mem = rdma_mock_host_mem::type_id::create(
          $sformatf("poll_decoded_contract_mem_%0d", i + 1)
        );
        pcie = rdma_cmq_test_pcie::type_id::create(
          $sformatf("poll_decoded_contract_pcie_%0d", i + 1)
        );
        scheduler = rdma_doorbell_scheduler::type_id::create(
          $sformatf("poll_decoded_contract_scheduler_%0d", i + 1)
        );
        profile = rdma_cmq_test_profile::type_id::create(
          $sformatf("poll_decoded_contract_profile_%0d", i + 1)
        );
        prepared_binding = make_binding(
          $sformatf("poll_decoded_contract_prepared_%0d", i + 1),
          RDMA_BIND_PREPARED
        );
        active_binding = make_binding(
          $sformatf("poll_decoded_contract_active_%0d", i + 1),
          RDMA_BIND_ACTIVE
        );
        cmq = make_cmq(
          $sformatf("poll_decoded_contract_cmq_%0d", i + 1),
          prepared_binding
        );
        prepare_active(
          {label, "_NEXT"}, engine, mem, pcie, scheduler, profile,
          prepared_binding, active_binding, cmq, runtime_desc
        );
        request = make_command(
          $sformatf("poll_decoded_contract_request_%0d", i + 1),
          active_binding, rdma_cmq_test_profile::TEST_OPCODE_A,
          byte'(8'h61 + i + 1), 10us
        );
        engine.submit(request, ticket, status);
        expect_status({label, "_NEXT_SUBMIT"}, status, RDMA_SC_OK);
        mapping = engine.mapping_snapshot();
        write_profile_cqe(
          {label, "_NEXT_CQE"}, mem, mapping, profile, 0, 1'b1,
          ticket, 32'h1, raw_cqe
        );
      end
    end

    foreach (legal_faults[i]) begin
      bit legal_poll_ok;
      string label;

      label = {"POLL_DECODED_CONTRACT_", legal_labels[i]};
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("poll_legal_contract_engine_%0d", i)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("poll_legal_contract_mem_%0d", i)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("poll_legal_contract_pcie_%0d", i)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("poll_legal_contract_scheduler_%0d", i)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("poll_legal_contract_profile_%0d", i)
      );
      prepared_binding = make_binding(
        $sformatf("poll_legal_contract_prepared_%0d", i),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("poll_legal_contract_active_%0d", i), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq(
        $sformatf("poll_legal_contract_cmq_%0d", i), prepared_binding
      );
      prepare_active(
        label, engine, mem, pcie, scheduler, profile, prepared_binding,
        active_binding, cmq, runtime_desc
      );
      request = make_command(
        $sformatf("poll_decoded_contract_legal_request_%0d", i),
        active_binding, rdma_cmq_test_profile::TEST_OPCODE_A,
        byte'(8'h70 + i), 10us
      );
      engine.submit(request, ticket, status);
      expect_status({label, "_SUBMIT"}, status, RDMA_SC_OK);
      mapping = engine.mapping_snapshot();
      write_profile_cqe(
        {label, "_CQE"}, mem, mapping, profile, 0, 1'b1, ticket,
        32'h1, raw_cqe
      );

      profile.decoded_contract_fault = legal_faults[i];
      engine.poll(completions, diagnostics, status);
      legal_poll_ok = status != null && status.ok();
      expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
      if (!legal_poll_ok || completions.size() != 1 ||
          diagnostics.size() != 0 || completions[0] == null ||
          completions[0].ticket == null ||
          completions[0].ticket.command_id != ticket.command_id ||
          completions[0].status == null || completions[0].status.ok() ||
          completions[0].status.category !=
            rdma_status::category_for(completions[0].status.code) ||
          !completions[0].status.hardware_code_valid ||
          completions[0].status.hardware_code != 32'h1 ||
          completions[0].status.severity != legal_severities[i] ||
          completions[0].raw_cqe == null ||
          !engine.probe_same_image(completions[0].raw_cqe, raw_cqe) ||
          engine.published_count() != 1 ||
          engine.cq_consumed_count() != 1 ||
          engine.retired_count() != 1 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0 ||
          engine.command_registry_count() != 0 ||
          engine.entry_registry_count() != 0 ||
          engine.terminal_fifo_count() != 0)
        `uvm_error(
          label,
          "legal nonzero severity did not preserve completion authority"
        )

      profile.decoded_contract_fault = RDMA_CMQ_TEST_DECODED_CONTRACT_GOOD;
      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    end
  endtask

  task automatic check_poll_ticket_root_is_explicitly_constructed();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    rdma_cmq_failing_ticket::disarm();
    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_explicit_ticket_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_explicit_ticket_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poll_explicit_ticket_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_explicit_ticket_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_explicit_ticket_profile"
    );
    prepared_binding = make_binding(
      "poll_explicit_ticket_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_explicit_ticket_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_explicit_ticket_cmq", prepared_binding);
    prepare_active(
      "POLL_EXPLICIT_TICKET", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    requests = new[2];
    requests[0] = make_command(
      "poll_explicit_ticket_request_0", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h70, 10us
    );
    requests[1] = make_command(
      "poll_explicit_ticket_request_1", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h71, 10us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("POLL_EXPLICIT_TICKET_SUBMIT", batch_status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "POLL_EXPLICIT_TICKET_CQE", mem, mapping, profile, 0, 1'b1,
      tickets[1], 0, raw_cqe
    );
    rdma_cmq_failing_ticket::arm();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_EXPLICIT_TICKET_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("POLL_EXPLICIT_TICKET_OUTPUT",
                 "out-of-order CQE did not deliver one completion")
    if (!rdma_cmq_failing_ticket::armed())
      `uvm_error("POLL_EXPLICIT_TICKET_ROOT_CLONE",
                 "completion construction invoked the ticket root clone")
    rdma_cmq_failing_ticket::disarm();
    engine.shutdown(status);
    expect_status("POLL_EXPLICIT_TICKET_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_poll_backing_out_of_order_and_owner_wrap();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image arrival_raw[3];
    longint unsigned arrival_ids[$];
    rdma_cmq_command_desc wrap_requests[];
    rdma_cmq_ticket wrap_tickets[];
    rdma_status wrap_item_statuses[];
    rdma_hw_image wrap_raw[];
    rdma_cmq_command_desc wrapped_request;
    rdma_cmq_ticket wrapped_ticket;
    rdma_hw_image wrapped_raw;
    rdma_status status;
    byte unsigned detached_byte;

    engine = rdma_cmq_engine_probe::type_id::create("poll_engine");
    mem = rdma_mock_host_mem::type_id::create("poll_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poll_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("poll_profile");
    prepared_binding = make_binding("poll_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("poll_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("poll_cmq", prepared_binding);
    prepare_active("POLL", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    mapping = engine.mapping_snapshot();
    if (mapping == null)
      `uvm_error("POLL_MAPPING", "active engine returned no mapping")

    requests = new[3];
    requests[0] = make_command(
      "poll_request_0", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h90, 10us
    );
    requests[1] = make_command(
      "poll_request_1", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h91, 10us
    );
    requests[2] = make_command(
      "poll_request_2", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h92, 10us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("POLL_SUBMIT_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 3 || item_statuses.size() != 3) begin
      `uvm_error("POLL_SUBMIT_ALIGNMENT", "three ticket outputs are missing")
      engine.shutdown(status);
      return;
    end
    foreach (tickets[i]) begin
      expect_status($sformatf("POLL_SUBMIT_ITEM_%0d", i),
                    item_statuses[i], RDMA_SC_OK);
      if (tickets[i] == null || tickets[i].slot_sequence != i ||
          tickets[i].sq_index != i || tickets[i].sq_wrap)
        `uvm_error("POLL_SUBMIT_TICKET",
                   $sformatf("ticket %0d has a wrong initial slot", i))
    end
    if (engine.published_count() != 3 || engine.retired_count() != 0 ||
        engine.tokens_in_use_count() != 3 ||
        engine.slot_record_count() != 3 ||
        engine.command_registry_count() != 3 ||
        engine.entry_registry_count() != 3)
      `uvm_error("POLL_SUBMIT_LEDGER", "three commands were not published")

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_OWNER_MISMATCH_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.cq_consumed_count() != 0 || engine.retired_count() != 0)
      `uvm_error("POLL_OWNER_MISMATCH",
                 "owner mismatch published output or advanced a counter")
    expect_poll_read_geometry("POLL_OWNER_MISMATCH_READ", mem, 0, 1);

    mem.calls.delete();
    write_profile_cqe(
      "POLL_ARRIVAL_2", mem, mapping, profile, 0, 1'b1, tickets[2],
      0, arrival_raw[0]
    );
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_ARRIVAL_2_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("POLL_ARRIVAL_2_OUTPUT", "arrival 2 output is misaligned")
    else begin
      expect_polled_completion(
        "POLL_ARRIVAL_2_COMPLETION", engine, completions[0], tickets[2],
        arrival_raw[0], 1'b1, 0, RDMA_SC_OK
      );
      arrival_ids.push_back(completions[0].ticket.command_id);
      detached_byte = completions[0].raw_cqe.bytes[0];
      arrival_raw[0].bytes[0] ^= 8'hff;
      if (completions[0].raw_cqe.bytes[0] != detached_byte)
        `uvm_error("POLL_ARRIVAL_2_DETACHED",
                   "caller raw image mutation reached completion")
    end
    if (engine.cq_consumed_count() != 1 ||
        engine.retired_count() != 0 ||
        engine.tokens_in_use_count() != 2 ||
        engine.slot_record_count() != 3 ||
        engine.command_registry_count() != 2 ||
        engine.entry_registry_count() != 3)
      `uvm_error("POLL_ARRIVAL_2_PREFIX",
                 "out-of-order completion advanced retirement")
    expect_poll_read_geometry("POLL_ARRIVAL_2_READ", mem, 0, 2);

    mem.calls.delete();
    write_profile_cqe(
      "POLL_ARRIVAL_0", mem, mapping, profile, 1, 1'b1, tickets[0],
      XTR_V1_ECODE_EC_RCE_CQ_FULL, arrival_raw[1]
    );
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_ARRIVAL_0_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("POLL_ARRIVAL_0_OUTPUT", "arrival 0 output is misaligned")
    else begin
      expect_polled_completion(
        "POLL_ARRIVAL_0_COMPLETION", engine, completions[0], tickets[0],
        arrival_raw[1], 1'b1, XTR_V1_ECODE_EC_RCE_CQ_FULL,
        RDMA_SC_QUEUE_FULL
      );
      arrival_ids.push_back(completions[0].ticket.command_id);
    end
    if (engine.cq_consumed_count() != 2 ||
        engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 2 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 2)
      `uvm_error("POLL_ARRIVAL_0_PREFIX",
                 "slot zero completion retired the wrong prefix")
    expect_poll_read_geometry("POLL_ARRIVAL_0_READ", mem, 1, 2);

    mem.calls.delete();
    write_profile_cqe(
      "POLL_ARRIVAL_1", mem, mapping, profile, 2, 1'b1, tickets[1],
      0, arrival_raw[2]
    );
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_ARRIVAL_1_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("POLL_ARRIVAL_1_OUTPUT", "arrival 1 output is misaligned")
    else begin
      expect_polled_completion(
        "POLL_ARRIVAL_1_COMPLETION", engine, completions[0], tickets[1],
        arrival_raw[2], 1'b1, 0, RDMA_SC_OK
      );
      arrival_ids.push_back(completions[0].ticket.command_id);
    end
    if (arrival_ids.size() != 3 ||
        arrival_ids[0] != tickets[2].command_id ||
        arrival_ids[1] != tickets[0].command_id ||
        arrival_ids[2] != tickets[1].command_id)
      `uvm_error("POLL_ARRIVAL_ORDER",
                 "completion delivery did not preserve 2,0,1 arrival")
    if (engine.cq_consumed_count() != 3 ||
        engine.retired_count() != 3 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("POLL_ARRIVAL_1_PREFIX",
                 "completion 1 did not retire the full prefix")
    expect_poll_read_geometry("POLL_ARRIVAL_1_READ", mem, 2, 1);

    wrap_requests = new[29];
    foreach (wrap_requests[i])
      wrap_requests[i] = make_command(
        $sformatf("poll_wrap_request_%0d", i), active_binding,
        (i[0] == 1'b0) ? rdma_cmq_test_profile::TEST_OPCODE_A :
                         rdma_cmq_test_profile::TEST_OPCODE_B,
        byte'(8'ha0 + i), 10us
      );
    engine.submit_batch(wrap_requests, wrap_tickets, wrap_item_statuses,
                        batch_status);
    expect_status("POLL_WRAP_SUBMIT", batch_status, RDMA_SC_OK);
    if (wrap_tickets.size() != 29 || wrap_item_statuses.size() != 29) begin
      `uvm_error("POLL_WRAP_ALIGNMENT", "owner-wrap outputs are misaligned")
      engine.shutdown(status);
      return;
    end
    if (engine.command_registry_count() != 29 ||
        engine.entry_registry_count() != 29)
      `uvm_error("POLL_WRAP_REGISTRY",
                 "owner-wrap submission did not install both registries")
    wrap_raw = new[29];
    mem.calls.delete();
    foreach (wrap_tickets[i]) begin
      expect_status($sformatf("POLL_WRAP_ITEM_%0d", i),
                    wrap_item_statuses[i], RDMA_SC_OK);
      if (wrap_tickets[i] == null ||
          wrap_tickets[i].slot_sequence != (i + 3) ||
          wrap_tickets[i].sq_index != (i + 3) ||
          wrap_tickets[i].sq_wrap)
        `uvm_error("POLL_WRAP_TICKET",
                   $sformatf("owner-wrap ticket %0d is wrong", i))
      write_profile_cqe(
        $sformatf("POLL_WRAP_CQE_%0d", i), mem, mapping, profile,
        longint'(i + 3), 1'b1, wrap_tickets[i], 0, wrap_raw[i]
      );
    end
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_WRAP_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 29 || diagnostics.size() != 0)
      `uvm_error("POLL_WRAP_OUTPUT",
                 "poll did not drain all 29 terminal completions")
    else foreach (completions[i])
      expect_polled_completion(
        $sformatf("POLL_WRAP_COMPLETION_%0d", i), engine,
        completions[i], wrap_tickets[i], wrap_raw[i], 1'b1, 0,
        RDMA_SC_OK
      );
    expect_poll_read_geometry("POLL_WRAP_READ", mem, 3, 29);
    if (engine.cq_consumed_count() != 32 ||
        engine.retired_count() != 32 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("POLL_WRAP_LEDGER",
                 "32 CQEs did not complete and retire exactly once")

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_OWNER_FLIP_EMPTY_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.cq_consumed_count() != 32)
      `uvm_error("POLL_OWNER_FLIP_EMPTY",
                 "old owner-1 CQE was reused after owner flip")
    expect_poll_read_geometry("POLL_OWNER_FLIP_EMPTY_READ", mem, 32, 0);

    wrapped_request = make_command(
      "poll_sequence_32", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'he0, 10us
    );
    engine.submit(wrapped_request, wrapped_ticket, status);
    expect_status("POLL_SEQUENCE_32_SUBMIT", status, RDMA_SC_OK);
    if (wrapped_ticket == null || wrapped_ticket.slot_sequence != 32 ||
        wrapped_ticket.sq_index != 0 || !wrapped_ticket.sq_wrap)
      `uvm_error("POLL_SEQUENCE_32_TICKET",
                 "sequence 32 did not reuse wrapped slot zero")
    if (engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1)
      `uvm_error("POLL_SEQUENCE_32_REGISTRY",
                 "wrapped command did not install both registries")
    mem.calls.delete();
    write_profile_cqe(
      "POLL_SEQUENCE_32_CQE", mem, mapping, profile, 32, 1'b0,
      wrapped_ticket, 0, wrapped_raw
    );
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_SEQUENCE_32_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("POLL_SEQUENCE_32_OUTPUT",
                 "owner-zero CQE did not produce one completion")
    else
      expect_polled_completion(
        "POLL_SEQUENCE_32_COMPLETION", engine, completions[0],
        wrapped_ticket, wrapped_raw, 1'b0, 0, RDMA_SC_OK
      );
    expect_poll_read_geometry("POLL_SEQUENCE_32_READ", mem, 32, 1);
    if (engine.cq_consumed_count() != 33 ||
        engine.retired_count() != 33 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("POLL_SEQUENCE_32_LEDGER",
                 "owner-zero completion did not close wrapped command")

    engine.shutdown(status);
    expect_status("POLL_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_retire_then_wrap_publication();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_dma_mapping mapping;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("wrap_engine");
    mem = rdma_mock_host_mem::type_id::create("wrap_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("wrap_pcie");
    trace = rdma_mock_call_trace::type_id::create("wrap_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create("wrap_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("wrap_profile");
    prepared_binding = make_binding("wrap_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("wrap_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("wrap_cmq", prepared_binding);
    prepare_active("WRAP", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[32];
    foreach (requests[i])
      requests[i] = make_command(
        $sformatf("wrap_fill_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(i + 1'b1), 10us
      );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("WRAP_FILL_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 32 || item_statuses.size() != 32)
      `uvm_error("WRAP_FILL_ALIGNMENT", "fill outputs are misaligned")
    else begin
      foreach (tickets[i]) begin
        expect_status($sformatf("WRAP_FILL_ITEM_%0d", i), item_statuses[i],
                      RDMA_SC_OK);
        if (tickets[i] == null)
          `uvm_error("WRAP_FILL_TICKET",
                     $sformatf("fill ticket %0d is null", i))
      end
    end

    mapping = engine.mapping_snapshot();
    clear_submit_observation(mem, pcie, trace);
    write_profile_cqe(
      "WRAP_RETIRE_ZERO", mem, mapping, profile, 0, 1'b1, tickets[0],
      0, raw_cqe
    );
    engine.poll(completions, diagnostics, status);
    expect_status("WRAP_RETIRE_ZERO", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("WRAP_RETIRE_OUTPUT",
                 "real CQE did not produce one slot-zero completion")
    else
      expect_polled_completion(
        "WRAP_RETIRE_COMPLETION", engine, completions[0], tickets[0],
        raw_cqe, 1'b1, 0, RDMA_SC_OK
      );
    if (engine.published_count() != 32 || engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 31 ||
        engine.slot_record_count() != 31)
      `uvm_error("WRAP_RETIRE_LEDGER",
                 "retiring slot zero changed the wrong authority")

    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command("wrap_sequence_32", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_B,
                               8'hf0, 10us);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("WRAP_SEQUENCE_32_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("WRAP_SEQUENCE_32_OUTPUT", "wrapped output is invalid")
    else begin
      expect_status("WRAP_SEQUENCE_32_ITEM", item_statuses[0], RDMA_SC_OK);
      if (tickets[0].slot_sequence != 32 || tickets[0].sq_index != 0 ||
          !tickets[0].sq_wrap)
        `uvm_error("WRAP_SEQUENCE_32_TICKET",
                   "wrapped ticket did not reuse slot zero at sequence 32")
    end
    if (mem.calls.size() != 1 || mem.calls[0].offset != 0 ||
        mem.calls[0].data.size() != 64 ||
        mem.calls[0].data[5][1:0] != 2'b01)
      `uvm_error("WRAP_SEQUENCE_32_SQE",
                 "sequence 32 SQE did not encode valid=0/wrap=1")
    if (pcie.calls.size() != 3 ||
        pcie.calls[2].method_name != "mmio_write" ||
        pcie.calls[2].data.size() != 8 ||
        pcie.calls[2].data[0] != 8'h01 ||
        pcie.calls[2].data[1] != 8'h01 ||
        profile.last_final_pi != 1 || !profile.last_polarity)
      `uvm_error("WRAP_SEQUENCE_32_DOORBELL",
                 "sequence 32 doorbell did not encode PI=1/polarity=1")
    if (engine.published_count() != 33 || engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 32 ||
        engine.slot_record_count() != 32)
      `uvm_error("WRAP_SEQUENCE_32_LEDGER",
                 "wrapped publication did not restore full occupancy")

    engine.shutdown(status);
    expect_status("WRAP_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_full_initial_capacity_and_shutdown_reset();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("capacity_engine");
    mem = rdma_mock_host_mem::type_id::create("capacity_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("capacity_pcie");
    trace = rdma_mock_call_trace::type_id::create("capacity_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "capacity_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("capacity_profile");
    prepared_binding = make_binding("capacity_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("capacity_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("capacity_cmq", prepared_binding);
    prepare_active("CAPACITY", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[33];
    foreach (requests[i])
      requests[i] = make_command(
        $sformatf("capacity_%0d", i), active_binding,
        (i[0] == 1'b0) ? rdma_cmq_test_profile::TEST_OPCODE_A :
                         rdma_cmq_test_profile::TEST_OPCODE_B,
        byte'(i + 1'b1), 10us
      );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("CAPACITY_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 33 || item_statuses.size() != 33)
      `uvm_error("CAPACITY_ALIGNMENT", "capacity outputs misaligned")
    else begin
      for (int unsigned i = 0; i < 32; i++) begin
        expect_status($sformatf("CAPACITY_ITEM_%0d", i), item_statuses[i],
                      RDMA_SC_OK);
        if (tickets[i] == null || tickets[i].slot_sequence != i ||
            tickets[i].sq_index != i || tickets[i].sq_wrap)
          `uvm_error("CAPACITY_TICKET",
                     $sformatf("capacity ticket %0d is invalid", i))
      end
      expect_status("CAPACITY_ITEM_FULL", item_statuses[32],
                    RDMA_SC_QUEUE_FULL);
      if (tickets[32] != null)
        `uvm_error("CAPACITY_ITEM_FULL",
                   "33rd initial command incorrectly consumed a slot")
    end
    if (mem.calls.size() != 32 || pcie.calls.size() != 3 ||
        pcie.calls[2].method_name != "mmio_write" ||
        pcie.calls[2].data.size() != 8 ||
        pcie.calls[2].data[0] != 8'h00 ||
        pcie.calls[2].data[1] != 8'h01 ||
        profile.doorbell_calls != 1 || profile.last_final_pi != 0 ||
        !profile.last_polarity)
      `uvm_error("CAPACITY_DOORBELL",
                 "full 32-entry publication did not use PI 0/polarity 1")
    if (engine.published_count() != 32 ||
        engine.tokens_in_use_count() != 32 ||
        engine.slot_record_count() != 32)
      `uvm_error("CAPACITY_LEDGER", "full initial capacity was not committed")

    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command("capacity_overflow", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'hfe);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("CAPACITY_OVERFLOW_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] != null ||
        item_statuses.size() != 1)
      `uvm_error("CAPACITY_OVERFLOW", "full-ring output invalid")
    else
      expect_status("CAPACITY_OVERFLOW_ITEM", item_statuses[0],
                    RDMA_SC_QUEUE_FULL);
    expect_no_submit_side_effects("CAPACITY_OVERFLOW_EFFECTS", mem, pcie,
                                  trace);

    engine.shutdown(status);
    expect_status("CAPACITY_SHUTDOWN", status, RDMA_SC_OK);
    if (engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("CAPACITY_SHUTDOWN_RESET",
                 "shutdown did not clear slots, tokens, and counters")

    prepared_binding = make_binding("capacity_reprepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("capacity_reactive", RDMA_BIND_ACTIVE);
    cmq = make_cmq("capacity_recmq", prepared_binding);
    profile.sqe_endian = RDMA_ENDIAN_LITTLE;
    profile.sqe_hardware_version = 13;
    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567, mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("CAPACITY_REPREPARE", status, RDMA_SC_OK);
    engine.activate(active_binding, status);
    expect_status("CAPACITY_REACTIVATE", status, RDMA_SC_OK);
    clear_submit_observation(mem, pcie, trace);
    requests[0] = make_command("capacity_reuse", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h77);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("CAPACITY_REUSE_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        tickets[0].slot_sequence != 0 || tickets[0].sq_index != 0 ||
        tickets[0].command_id != 64'd64)
      `uvm_error("CAPACITY_REUSE",
                 "new prepare reset a monotonic command incarnation")

    engine.shutdown(status);
    expect_status("CAPACITY_FINAL_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_retirement_preflight_poison_atomicity();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_cmq_diagnostic snapshot;
    rdma_hw_image raw_cqe;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "retirement_preflight_engine"
    );
    mem = rdma_mock_host_mem::type_id::create(
      "retirement_preflight_mem"
    );
    pcie = rdma_cmq_test_pcie::type_id::create(
      "retirement_preflight_pcie"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "retirement_preflight_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "retirement_preflight_profile"
    );
    prepared_binding = make_binding(
      "retirement_preflight_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "retirement_preflight_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("retirement_preflight_cmq", prepared_binding);
    prepare_active(
      "RETIREMENT_PREFLIGHT", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "retirement_preflight_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'ha5, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("RETIREMENT_PREFLIGHT_SUBMIT", status, RDMA_SC_OK);
    if (ticket == null ||
        !engine.tamper_slot_retirement_incarnation(ticket.sq_index)) begin
      `uvm_error("RETIREMENT_PREFLIGHT_SETUP",
                 "could not install a self-consistent stale incarnation")
      engine.shutdown(status);
      return;
    end
    // Keep the caller's detached expected ticket aligned with the internal
    // self-consistent incarnation.  Both still disagree with retire_seq=0.
    ticket.slot_sequence += 32;
    ticket.sq_wrap = !ticket.sq_wrap;
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "RETIREMENT_PREFLIGHT_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );

    engine.poll(completions, diagnostics, status);
    expect_status("RETIREMENT_PREFLIGHT_POLL", status,
                  RDMA_SC_CODEC_ERROR);
    if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        completions.size() != 0 || diagnostics.size() != 1)
      `uvm_error(
        "RETIREMENT_PREFLIGHT_OUTPUT",
        "retirement failure committed output before poisoning"
      )
    else
      expect_poison_diagnostic(
        "RETIREMENT_PREFLIGHT_DIAGNOSTIC", engine, diagnostics[0],
        RDMA_CMQ_DIAG_POISON, null, raw_cqe, active_binding, cmq
      );
    snapshot = engine.last_poison_snapshot();
    expect_poison_diagnostic(
      "RETIREMENT_PREFLIGHT_SNAPSHOT", engine, snapshot,
      RDMA_CMQ_DIAG_POISON, null, raw_cqe, active_binding, cmq
    );
    if (engine.published_count() != 1 ||
        engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1 ||
        engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.slot_state_at(ticket.sq_index) != CMQ_SLOT_PUBLISHED)
      `uvm_error(
        "RETIREMENT_PREFLIGHT_ATOMIC",
        "retirement poison consumed or changed command authority"
      )

    engine.shutdown(status);
    expect_status("RETIREMENT_PREFLIGHT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  task automatic check_cqe_poison_isolation_and_snapshot_detachment();
    rdma_cmq_test_poison_fault_e faults[7];
    rdma_cmq_diagnostic_kind_e kinds[7];
    bit trusted_ticket[7];
    string labels[7];

    faults[0] = RDMA_CMQ_TEST_POISON_RESERVED_BIT;
    faults[1] = RDMA_CMQ_TEST_POISON_UNSUPPORTED_OPCODE;
    faults[2] = RDMA_CMQ_TEST_POISON_OPCODE_MISMATCH;
    faults[3] = RDMA_CMQ_TEST_POISON_UNKNOWN_ENTRY;
    faults[4] = RDMA_CMQ_TEST_POISON_NULL_DECODED;
    faults[5] = RDMA_CMQ_TEST_POISON_NULL_COMMAND_STATUS;
    faults[6] = RDMA_CMQ_TEST_POISON_SLOT_INCARNATION;
    kinds[0] = RDMA_CMQ_DIAG_MALFORMED_CQE;
    kinds[1] = RDMA_CMQ_DIAG_MALFORMED_CQE;
    kinds[2] = RDMA_CMQ_DIAG_MALFORMED_CQE;
    kinds[3] = RDMA_CMQ_DIAG_UNKNOWN_CQE;
    kinds[4] = RDMA_CMQ_DIAG_MALFORMED_CQE;
    kinds[5] = RDMA_CMQ_DIAG_MALFORMED_CQE;
    kinds[6] = RDMA_CMQ_DIAG_POISON;
    trusted_ticket[0] = 1'b0;
    trusted_ticket[1] = 1'b0;
    trusted_ticket[2] = 1'b1;
    trusted_ticket[3] = 1'b0;
    trusted_ticket[4] = 1'b0;
    trusted_ticket[5] = 1'b1;
    trusted_ticket[6] = 1'b0;
    labels[0] = "POISON_RESERVED_BIT";
    labels[1] = "POISON_UNSUPPORTED_OPCODE";
    labels[2] = "POISON_OPCODE_MISMATCH";
    labels[3] = "POISON_UNKNOWN_ENTRY";
    labels[4] = "POISON_NULL_DECODED";
    labels[5] = "POISON_NULL_COMMAND_STATUS";
    // This is deliberately a post-read entry/slot incarnation mismatch.
    // Pre-read counter invariants have no real CQE evidence and remain the
    // separately tested submission guard rather than manufacturing raw data.
    labels[6] = "POISON_POST_READ_SLOT_INCARNATION";

    foreach (faults[i]) begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_dma_mapping mapping;
      rdma_cmq_command_desc request;
      rdma_cmq_ticket ticket;
      rdma_cmq_ticket rejected_ticket;
      rdma_cmq_completion completions[$];
      rdma_cmq_diagnostic diagnostics[$];
      rdma_cmq_diagnostic first_snapshot;
      rdma_cmq_diagnostic second_snapshot;
      rdma_cmq_diagnostic third_snapshot;
      rdma_hw_image raw_cqe;
      rdma_status status;
      longint unsigned original_command_id;
      byte unsigned saved_raw_byte;
      string label;

      label = labels[i];
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("poison_engine_%0d", i)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("poison_mem_%0d", i)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("poison_pcie_%0d", i)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("poison_scheduler_%0d", i)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("poison_profile_%0d", i)
      );
      prepared_binding = make_binding(
        $sformatf("poison_prepared_%0d", i), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("poison_active_%0d", i), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("poison_cmq_%0d", i), prepared_binding);
      prepare_active(label, engine, mem, pcie, scheduler, profile,
                     prepared_binding, active_binding, cmq, runtime_desc);
      request = make_command(
        $sformatf("poison_request_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hd0 + i), 10us
      );
      engine.submit(request, ticket, status);
      expect_status({label, "_SUBMIT"}, status, RDMA_SC_OK);
      if (ticket == null) begin
        `uvm_error(label, "poison setup returned no ticket")
        engine.shutdown(status);
        continue;
      end
      original_command_id = ticket.command_id;
      mapping = engine.mapping_snapshot();
      write_profile_cqe(
        {label, "_CQE"}, mem, mapping, profile, 0, 1'b1, ticket, 0,
        raw_cqe
      );
      case (faults[i])
        RDMA_CMQ_TEST_POISON_RESERVED_BIT:
          raw_cqe.bytes[0] |= 8'h40;
        RDMA_CMQ_TEST_POISON_UNSUPPORTED_OPCODE:
          raw_cqe.bytes[3] = 8'hfe;
        RDMA_CMQ_TEST_POISON_OPCODE_MISMATCH:
          raw_cqe.bytes[3] =
            rdma_cmq_test_profile::TEST_OPCODE_B[7:0];
        RDMA_CMQ_TEST_POISON_UNKNOWN_ENTRY:
          raw_cqe.bytes[2] = {2'b00, ticket.sq_wrap, 5'h01};
        RDMA_CMQ_TEST_POISON_NULL_DECODED:
          profile.return_null_decoded = 1'b1;
        RDMA_CMQ_TEST_POISON_NULL_COMMAND_STATUS:
          profile.return_null_command_status = 1'b1;
        RDMA_CMQ_TEST_POISON_SLOT_INCARNATION:
          if (!engine.tamper_slot_incarnation(ticket.sq_index))
            `uvm_error(label, "could not tamper the slot incarnation")
        default: begin
        end
      endcase
      overwrite_profile_cqe(label, mem, mapping, 0, raw_cqe);

      engine.poll(completions, diagnostics, status);
      expect_status({label, "_POLL_STATUS"}, status, RDMA_SC_CODEC_ERROR);
      if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          completions.size() != 0 || diagnostics.size() != 1)
        `uvm_error(label,
                   "malformed CQE did not stop at one poison diagnostic")
      else
        expect_poison_diagnostic(
          {label, "_DIAGNOSTIC"}, engine, diagnostics[0], kinds[i],
          trusted_ticket[i] ? ticket : null, raw_cqe, active_binding, cmq
        );
      if (engine.published_count() != 1 ||
          engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1 ||
          engine.command_registry_count() != 1 ||
          engine.entry_registry_count() != 1 ||
          engine.terminal_fifo_count() != 0 ||
          engine.slot_state_at(ticket.sq_index) != CMQ_SLOT_PUBLISHED ||
          engine.slot_ticket_command_id(ticket.sq_index) !=
            original_command_id)
        `uvm_error(label,
                   "poison consumed, completed, or recycled the bad slot")

      first_snapshot = engine.last_poison_snapshot();
      expect_poison_diagnostic(
        {label, "_FIRST_SNAPSHOT"}, engine, first_snapshot, kinds[i],
        trusted_ticket[i] ? ticket : null, raw_cqe, active_binding, cmq
      );
      if (diagnostics.size() == 1 && first_snapshot != null) begin
        if (first_snapshot == diagnostics[0] ||
            first_snapshot.status == diagnostics[0].status ||
            first_snapshot.raw_cqe == diagnostics[0].raw_cqe ||
            (trusted_ticket[i] &&
             first_snapshot.ticket == diagnostics[0].ticket))
          `uvm_error(label,
                     "diagnostic output aliases last-poison authority")
        diagnostics[0].status.message = "caller-mutated diagnostic";
        diagnostics[0].raw_cqe.bytes[0] ^= 8'hff;
        if (diagnostics[0].ticket != null)
          diagnostics[0].ticket.command_id++;
      end
      second_snapshot = engine.last_poison_snapshot();
      expect_poison_diagnostic(
        {label, "_SECOND_SNAPSHOT"}, engine, second_snapshot, kinds[i],
        trusted_ticket[i] ? ticket : null, raw_cqe, active_binding, cmq
      );
      if (first_snapshot == null || second_snapshot == null ||
          first_snapshot == second_snapshot ||
          first_snapshot.status == second_snapshot.status ||
          first_snapshot.raw_cqe == second_snapshot.raw_cqe ||
          (trusted_ticket[i] &&
           first_snapshot.ticket == second_snapshot.ticket))
        `uvm_error(label, "last_poison_snapshot did not detach each query")
      if (first_snapshot != null && first_snapshot.raw_cqe != null &&
          first_snapshot.status != null) begin
        saved_raw_byte = raw_cqe.bytes[0];
        first_snapshot.raw_cqe.bytes[0] ^= 8'hff;
        first_snapshot.status.message = "caller-mutated snapshot";
        if (first_snapshot.ticket != null)
          first_snapshot.ticket.command_id++;
        third_snapshot = engine.last_poison_snapshot();
        expect_poison_diagnostic(
          {label, "_THIRD_SNAPSHOT"}, engine, third_snapshot, kinds[i],
          trusted_ticket[i] ? ticket : null, raw_cqe, active_binding, cmq
        );
        if (third_snapshot != null && third_snapshot.raw_cqe != null &&
            third_snapshot.raw_cqe.bytes[0] != saved_raw_byte)
          `uvm_error(label, "snapshot mutation reached engine authority")
      end

      request = make_command(
        $sformatf("poison_rejected_request_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'he0 + i), 10us
      );
      engine.submit(request, rejected_ticket, status);
      if (status == null || status.ok() || rejected_ticket != null)
        `uvm_error(label, "poisoned engine accepted a later submit")
      engine.poll(completions, diagnostics, status);
      if (status == null || status.ok() || completions.size() != 0 ||
          diagnostics.size() != 0)
        `uvm_error(label, "poisoned engine accepted a later poll")
      engine.expire(completions, status);
      if (status == null || status.ok() || completions.size() != 0)
        `uvm_error(label, "poisoned engine accepted a later expire")
      if (engine.published_count() != 1 ||
          engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1 ||
          engine.command_registry_count() != 1 ||
          engine.entry_registry_count() != 1 ||
          engine.terminal_fifo_count() != 0 ||
          engine.diagnostic_fifo_count() != 0)
        `uvm_error(label, "post-poison rejection changed ring authority")

      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    end

    begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_dma_mapping mapping;
      rdma_cmq_command_desc request;
      rdma_cmq_ticket ticket;
      rdma_cmq_completion completions[$];
      rdma_cmq_diagnostic diagnostics[$];
      rdma_hw_image raw_cqe;
      rdma_status status;

      engine = rdma_cmq_engine_probe::type_id::create(
        "poison_owner_mismatch_engine"
      );
      mem = rdma_mock_host_mem::type_id::create(
        "poison_owner_mismatch_mem"
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        "poison_owner_mismatch_pcie"
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        "poison_owner_mismatch_scheduler"
      );
      profile = rdma_cmq_test_profile::type_id::create(
        "poison_owner_mismatch_profile"
      );
      prepared_binding = make_binding(
        "poison_owner_mismatch_prepared", RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        "poison_owner_mismatch_active", RDMA_BIND_ACTIVE
      );
      cmq = make_cmq("poison_owner_mismatch_cmq", prepared_binding);
      prepare_active(
        "POISON_OWNER_MISMATCH", engine, mem, pcie, scheduler, profile,
        prepared_binding, active_binding, cmq, runtime_desc
      );
      request = make_command(
        "poison_owner_mismatch_request", active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, 8'hf0, 10us
      );
      engine.submit(request, ticket, status);
      expect_status("POISON_OWNER_MISMATCH_SUBMIT", status, RDMA_SC_OK);
      mapping = engine.mapping_snapshot();
      write_profile_cqe(
        "POISON_OWNER_MISMATCH_CQE", mem, mapping, profile, 0, 1'b0,
        ticket, 0, raw_cqe
      );
      raw_cqe.bytes[0] |= 8'h40;
      raw_cqe.bytes[3] = 8'hfe;
      overwrite_profile_cqe(
        "POISON_OWNER_MISMATCH", mem, mapping, 0, raw_cqe
      );
      engine.poll(completions, diagnostics, status);
      expect_status("POISON_OWNER_MISMATCH_POLL", status, RDMA_SC_OK);
      if (engine.state() != RDMA_CMQ_ENGINE_ACTIVE ||
          completions.size() != 0 || diagnostics.size() != 0 ||
          engine.last_poison_snapshot() != null ||
          engine.cq_consumed_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1)
        `uvm_error(
          "POISON_OWNER_MISMATCH",
          "stale-owner garbage was inspected or poisoned the engine"
        )
      engine.shutdown(status);
      expect_status("POISON_OWNER_MISMATCH_SHUTDOWN", status, RDMA_SC_OK);
    end
  endtask

  task automatic check_poison_shutdown_release_retry_preserves_snapshot();
    string labels[2];

    labels[0] = "POISON_SHUTDOWN_NULL_RELEASE";
    labels[1] = "POISON_SHUTDOWN_FAILED_RELEASE";
    for (int unsigned mode = 0; mode < 2; mode++) begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_dma_mapping mapping;
      rdma_dma_mapping retained_mapping;
      rdma_mock_dma_mapping retained_mock;
      rdma_cmq_command_desc request;
      rdma_cmq_ticket ticket;
      rdma_cmq_completion completions[$];
      rdma_cmq_diagnostic diagnostics[$];
      rdma_cmq_diagnostic before_snapshot;
      rdma_cmq_diagnostic after_snapshot;
      rdma_cmq_diagnostic retry_snapshot;
      rdma_hw_image raw_cqe;
      rdma_status status;
      string label;

      label = labels[mode];
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("poison_shutdown_engine_%0d", mode)
      );
      if (mode == 0)
        mem = rdma_cmq_null_release_once_mem::type_id::create(
          "poison_shutdown_null_mem"
        );
      else
        mem = rdma_mock_host_mem::type_id::create(
          "poison_shutdown_failed_mem"
        );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("poison_shutdown_pcie_%0d", mode)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("poison_shutdown_scheduler_%0d", mode)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("poison_shutdown_profile_%0d", mode)
      );
      prepared_binding = make_binding(
        $sformatf("poison_shutdown_prepared_%0d", mode),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("poison_shutdown_active_%0d", mode), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq(
        $sformatf("poison_shutdown_cmq_%0d", mode), prepared_binding
      );
      prepare_active(
        label, engine, mem, pcie, scheduler, profile, prepared_binding,
        active_binding, cmq, runtime_desc
      );
      request = make_command(
        $sformatf("poison_shutdown_request_%0d", mode), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hb0 + mode), 10us
      );
      engine.submit(request, ticket, status);
      expect_status({label, "_SUBMIT"}, status, RDMA_SC_OK);
      mapping = engine.mapping_snapshot();
      write_profile_cqe(
        {label, "_CQE"}, mem, mapping, profile, 0, 1'b1, ticket, 0,
        raw_cqe
      );
      raw_cqe.bytes[3] = rdma_cmq_test_profile::TEST_OPCODE_B[7:0];
      overwrite_profile_cqe(label, mem, mapping, 0, raw_cqe);
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_POLL"}, status, RDMA_SC_CODEC_ERROR);
      if (completions.size() != 0 || diagnostics.size() != 1)
        `uvm_error(label, "poison setup did not return one diagnostic")
      before_snapshot = engine.last_poison_snapshot();
      expect_poison_diagnostic(
        {label, "_BEFORE"}, engine, before_snapshot,
        RDMA_CMQ_DIAG_MALFORMED_CQE, ticket, raw_cqe, active_binding, cmq
      );
      if (before_snapshot != null) begin
        before_snapshot.status.message = "caller-mutated before shutdown";
        before_snapshot.raw_cqe.bytes[0] ^= 8'hff;
        before_snapshot.ticket.command_id++;
        before_snapshot.ticket.function_h.object_id++;
        before_snapshot.ticket.cmq_h.object_id++;
        before_snapshot.ticket.opcode_key.opcode++;
      end
      if (mode == 1)
        expect_status(
          {label, "_ARM"},
          mem.fail_next(
            "release",
            rdma_status::make(
              RDMA_SC_UNKNOWN_HW_ERROR,
              "injected poisoned shutdown release failure"
            )
          ),
          RDMA_SC_OK
        );

      engine.shutdown(status);
      expect_status(
        {label, "_FIRST_SHUTDOWN"}, status,
        (mode == 0) ? RDMA_SC_INVALID_STATE : RDMA_SC_UNKNOWN_HW_ERROR
      );
      retained_mapping = engine.mapping_snapshot();
      after_snapshot = engine.last_poison_snapshot();
      expect_poison_diagnostic(
        {label, "_AFTER"}, engine, after_snapshot,
        RDMA_CMQ_DIAG_MALFORMED_CQE, ticket, raw_cqe, active_binding, cmq
      );
      if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          !engine.retry_only_poisoned() || retained_mapping == null ||
          count_host_calls(mem, "release") != 1 ||
          mem.regions.size() != 1 || mem.regions[0].mapping == null ||
          mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
        `uvm_error(label, "failed shutdown lost retry authority")
      if (!$cast(retained_mock, retained_mapping))
        `uvm_error(label, "failed shutdown lost mapping identity")
      if (before_snapshot == null || after_snapshot == null ||
          before_snapshot == after_snapshot ||
          before_snapshot.status == after_snapshot.status ||
          before_snapshot.raw_cqe == after_snapshot.raw_cqe ||
          before_snapshot.ticket == after_snapshot.ticket ||
          before_snapshot.ticket.function_h ==
            after_snapshot.ticket.function_h ||
          before_snapshot.ticket.cmq_h == after_snapshot.ticket.cmq_h ||
          before_snapshot.ticket.opcode_key ==
            after_snapshot.ticket.opcode_key)
        `uvm_error(label, "failed shutdown snapshot aliases caller state")
      if (after_snapshot != null) begin
        after_snapshot.raw_cqe.bytes[1] ^= 8'hff;
        after_snapshot.ticket.command_id++;
      end
      retry_snapshot = engine.last_poison_snapshot();
      expect_poison_diagnostic(
        {label, "_RETRY_SNAPSHOT"}, engine, retry_snapshot,
        RDMA_CMQ_DIAG_MALFORMED_CQE, ticket, raw_cqe, active_binding, cmq
      );

      engine.shutdown(status);
      expect_status({label, "_RETRY_SHUTDOWN"}, status, RDMA_SC_OK);
      expect_unconfigured({label, "_RETRY_STATE"}, engine);
      if (engine.last_poison_snapshot() != null ||
          count_host_calls(mem, "release") != 2 ||
          mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
        `uvm_error(label, "successful retry did not clear poison authority")
      expect_release_retry_identity(label, mem, retained_mock);
    end
  endtask

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_success_and_detachment();
    check_preallocation_rejections();
    check_pasid_normalization_and_busy_prepare();
    check_allocation_and_rollback_failures();
    check_null_status_guards();
    check_prepared_shutdown_lifecycle();
    check_shutdown_release_retry();
    check_active_shutdown_release_retry();
    check_null_shutdown_release_retry();
    check_missing_host_mem_shutdown();
    check_activation_guards();
    check_batch_compaction_and_doorbell();
    // Keep the 32-entry capacity stress near the ring/batch guards and before
    // poll hook regressions to limit VCS peak retained-object pressure.
    check_full_initial_capacity_and_shutdown_reset();
    check_empty_invalid_and_state_rejections();
    check_poll_empty_ledger_and_partial_drain();
    check_pre_read_poll_ledger_fail_closed();
    check_submit_wrapper_and_snapshot_detachment();
    check_null_compose_transaction_abort();
    check_nested_command_snapshot_failures();
    check_mutating_clone_source_restoration();
    check_qpc_context_snapshot_failures();
    check_transaction_failure_atomicity();
    check_profile_wide_cqe_format_authority();
    check_all_transport_failure_rollbacks();
    check_doorbell_authority_isolation();
    check_submission_validation_and_profile_metadata();
    check_profile_hook_snapshot_contract();
    check_stateful_profile_snapshot_rechecks();
    check_exact_type_profile_delegation();
    check_internal_invariant_batch_abort();
    check_timeout_quarantine_and_late_diagnostic();
    check_expire_snapshot_failure_is_atomic_and_retryable();
    check_late_diagnostic_snapshot_failure_is_retryable();
    check_command_incarnation_exhaustion();
    check_incarnation_survives_reprepare();
    check_max_dependency_id_boundary();
    check_counter_invariants_poison_before_transport();
    check_poll_raw_snapshot_rejects_self_clone_mutation();
    check_poll_payload_retained_self_clone_is_detached();
    check_poll_payload_hook_contract_failures();
    check_poll_decoded_status_contract_failures();
    check_poll_ticket_root_is_explicitly_constructed();
    check_retirement_preflight_poison_atomicity();
    check_cqe_poison_isolation_and_snapshot_detachment();
    check_poison_shutdown_release_retry_preserves_snapshot();
    check_poll_backing_out_of_order_and_owner_wrap();
    check_retire_then_wrap_publication();
    phase.drop_objection(this);
  endtask
endclass

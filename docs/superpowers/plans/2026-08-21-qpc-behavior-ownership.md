# QPC Behavior Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hardware-neutral QPC behavior value object, make it an owned part of `rdma_qpc_model`, and remove the stale Task 10C assumptions about QPC shadow and flow-control ownership.

**Architecture:** `rdma_qpc_behavior` is a factory-created UVM value object with driver-compatible defaults, explicit range validation, deep-copy behavior, and a stable description. `rdma_qpc_model` owns one non-null instance while xtr_v1-only constraints, such as merging TX/RX flow control into one `FC_EN`, remain in the future stateless codec.

**Tech Stack:** SystemVerilog, UVM 1.2, Git, remote Synopsys VCS on `10.11.10.53`.

---

## Scope and execution constraints

- Implement only Task 10A.1 from
  `docs/superpowers/specs/2026-08-21-qpc-behavior-ownership-design.md`.
- Do not create a QPC codec or modify QPC payload bytes in this plan. Task 10C owns that work.
- Keep `tx_flow_control != rx_flow_control` legal in generic `rdma_qpc_model.validate()`;
  the future xtr_v1 codec rejects that pair.
- Preserve `context_backing` as an unshifted byte IOVA with the existing 512B model
  alignment check. Task 10C encodes `context_backing.value >> 9`.
- Run every SystemVerilog compile and simulation on `10.11.10.53` through
  `scripts/run_vcs53.sh`. If password authentication is needed, supply it only through
  the current process with `sshpass -e`; never write it into a file, URL, or command
  recorded in this plan.

## File map

| File | Responsibility in this plan |
|---|---|
| `src/model/rdma_context_models.svh` | Define `rdma_qpc_behavior` and make `rdma_qpc_model` construct, validate, copy, and describe it. |
| `tests/unit/rdma_context_model_test.svh` | Lock defaults, range validation, deep-copy isolation, null rejection, and generic flow-control independence. |
| `tests/unit/rdma_request_model_test.svh` | Prove QPC behavior survives cloning when the QPC is used by semantic requests. |
| `docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md` | Reconcile Task 10C with the approved behavior, shadow, signature, flow-control, equality, and mask ownership. |

### Task 1: Add the behavior value object and QPC ownership

**Files:**
- Modify: `tests/unit/rdma_context_model_test.svh`
- Modify: `tests/unit/rdma_request_model_test.svh`
- Modify: `src/model/rdma_context_models.svh`

- [ ] **Step 1: Write the failing behavior and QPC ownership tests**

In `rdma_context_model_test.run_phase()`, add these declarations next to the existing
QPC declarations:

```systemverilog
    rdma_qpc_behavior behavior;
    rdma_qpc_behavior behavior_clone;
```

After the existing `ACCESS_TYPES` check, add the default, range, clone, and description
checks:

```systemverilog
    behavior = rdma_qpc_behavior::type_id::create("behavior");
    if (behavior.transport_version != 0 || behavior.migration_enable != 1'b0 ||
        behavior.tx_endian_swap != 1'b1 ||
        behavior.rx_endian_swap != 1'b1 ||
        behavior.read_after_write_fence != 1'b1 ||
        behavior.atomic_after_atomic_fence != 1'b1 ||
        behavior.priority != 0)
      `uvm_error("QPC_BEHAVIOR_DEFAULT", "driver-compatible defaults were lost")
    expect_ok("QPC_BEHAVIOR_VALID", behavior.validate());
    if (behavior.describe() == "")
      `uvm_error("QPC_BEHAVIOR_DESCRIBE", "behavior description is empty")

    cloned_object = behavior.clone();
    if (!$cast(behavior_clone, cloned_object))
      `uvm_error("QPC_BEHAVIOR_CLONE", "behavior clone lost dynamic type")
    else begin
      behavior_clone.transport_version = 3;
      behavior_clone.priority = 7;
      if (behavior.transport_version != 0 || behavior.priority != 0)
        `uvm_error("QPC_BEHAVIOR_CLONE", "behavior clone aliases source")
      expect_ok("QPC_BEHAVIOR_BOUNDARY", behavior_clone.validate());
    end

    behavior.transport_version = 4;
    expect_invalid("QPC_BEHAVIOR_TVER_WIDTH", behavior.validate());
    behavior.transport_version = 0;
    behavior.priority = 8;
    expect_invalid("QPC_BEHAVIOR_PRIORITY_WIDTH", behavior.validate());
    behavior.priority = 0;
```

In `make_qpc()`, set explicit non-default behavior values after assigning the address
vector. These values prove that transport selection does not synthesize the golden
behavior:

```systemverilog
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b1;
    qpc.behavior.tx_endian_swap = 1'b1;
    qpc.behavior.rx_endian_swap = 1'b1;
    qpc.behavior.read_after_write_fence = 1'b1;
    qpc.behavior.atomic_after_atomic_fence = 1'b1;
    qpc.behavior.priority = 5;
```

Extend the existing QPC clone checks so the condition rejects a null or aliased
behavior, then mutate the clone and prove isolation:

```systemverilog
    else if (qpc_clone.behavior == null ||
             qpc_clone.behavior == qpc.behavior ||
             qpc_clone.address_vector == null ||
             qpc_clone.address_vector == qpc.address_vector ||
             qpc_clone.transport_ext == qpc.transport_ext ||
             qpc_clone.qp_h == qpc.qp_h)
      `uvm_error("QPC_CLONE", "QPC clone did not deep-copy nested values")
    else begin
      qpc_clone.behavior.priority = 6;
      qpc_clone.address_vector.destination_mac++;
      qpc_clone.qp_h.object_id++;
      if (qpc.behavior.priority != 5 ||
          qpc.address_vector.destination_mac != 48'h02_11_22_33_44_55 ||
          qpc.qp_h.object_id != 32'h101)
        `uvm_error("QPC_CLONE", "QPC clone mutation reached source")
    end
```

After the context-alignment negative case, add nested validation and null-ownership
checks. Restore every mutation so later tests continue from a valid QPC:

```systemverilog
    behavior = qpc.behavior;
    qpc.behavior = null;
    expect_invalid("QPC_BEHAVIOR_NULL", qpc.validate());
    qpc.behavior = behavior;
    qpc.behavior.transport_version = 4;
    expect_invalid("QPC_BEHAVIOR_INVALID", qpc.validate());
    qpc.behavior.transport_version = 1;
    qpc.behavior.priority = 8;
    expect_invalid("QPC_BEHAVIOR_PRIORITY", qpc.validate());
    qpc.behavior.priority = 5;

    // Generic QPC semantics permit asymmetric flow control.  xtr_v1 rejects it.
    qpc.tx_flow_control = 1'b1;
    qpc.rx_flow_control = 1'b0;
    expect_ok("QPC_GENERIC_ASYMMETRIC_FC", qpc.validate());
```

In `rdma_request_model_test.svh`, set explicit behavior values on the existing QPC:

```systemverilog
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b1;
    qpc.behavior.priority = 5;
```

Extend its clone null check with `qpc_clone.behavior == null`, extend its alias/value
check with the following expressions, and extend its mutation check as shown:

```systemverilog
        qpc_clone.behavior == qpc.behavior ||
        qpc_clone.behavior.transport_version != 1 ||
        qpc_clone.behavior.migration_enable != 1'b1 ||
        qpc_clone.behavior.priority != 5 ||
```

```systemverilog
      qpc_clone.behavior.priority = 6;
      qpc_clone.qp_h.object_id++;
      qpc_clone.sq_depth = 2048;
      rc_ext_clone.remote_qpn++;
      if (qpc.behavior.priority != 5 ||
          qpc.qp_h.object_id != 32'h404 || qpc.sq_depth != 1024 ||
          rc_ext.remote_qpn != 24'habc123)
        `uvm_error("QPC_CLONE", "QPC clone mutation reached source")
```

- [ ] **Step 2: Run RED on the VCS host**

Run:

```bash
scripts/run_vcs53.sh core rdma_context_model_test
```

Expected: compile fails because `rdma_qpc_behavior` and `rdma_qpc_model.behavior` do
not exist. Record the missing-type or missing-member diagnostic; do not treat an SSH,
license, or unrelated compile failure as the required RED result.

- [ ] **Step 3: Implement `rdma_qpc_behavior`**

Insert the following class in `src/model/rdma_context_models.svh` before
`rdma_qpc_transport_ext`:

```systemverilog
class rdma_qpc_behavior extends uvm_object;
  `uvm_object_utils(rdma_qpc_behavior)

  int unsigned transport_version;
  bit migration_enable;
  bit tx_endian_swap;
  bit rx_endian_swap;
  bit read_after_write_fence;
  bit atomic_after_atomic_fence;
  int unsigned priority;

  function new(string name = "rdma_qpc_behavior");
    super.new(name);
    transport_version = 0;
    migration_enable = 1'b0;
    tx_endian_swap = 1'b1;
    rx_endian_swap = 1'b1;
    read_after_write_fence = 1'b1;
    atomic_after_atomic_fence = 1'b1;
    priority = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_behavior rhs_behavior;

    super.do_copy(rhs);
    if (!$cast(rhs_behavior, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "QPC behavior copy mismatch")
    transport_version = rhs_behavior.transport_version;
    migration_enable = rhs_behavior.migration_enable;
    tx_endian_swap = rhs_behavior.tx_endian_swap;
    rx_endian_swap = rhs_behavior.rx_endian_swap;
    read_after_write_fence = rhs_behavior.read_after_write_fence;
    atomic_after_atomic_fence = rhs_behavior.atomic_after_atomic_fence;
    priority = rhs_behavior.priority;
  endfunction

  virtual function rdma_status validate();
    if (transport_version > 3)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC transport version exceeds 2 bits");
    if (priority > 7)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC priority exceeds 3 bits");
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf(
      "behavior(tver=%0d mig=%0b tx_swap=%0b rx_swap=%0b ra_fence=%0b aa_fence=%0b priority=%0d)",
      transport_version, migration_enable, tx_endian_swap, rx_endian_swap,
      read_after_write_fence, atomic_after_atomic_fence, priority
    );
  endfunction
endclass
```

- [ ] **Step 4: Make `rdma_qpc_model` own and validate behavior**

Add the public member next to the other common QPC semantics:

```systemverilog
  rdma_qpc_behavior behavior;
```

Construct it in `rdma_qpc_model.new()`:

```systemverilog
    behavior = rdma_qpc_behavior::type_id::create("behavior");
```

In `rdma_qpc_model.do_copy()`, deep-copy it before cloning the transport extension:

```systemverilog
    if (rhs_qpc.behavior == null) begin
      behavior = null;
    end
    else begin
      cloned_object = rhs_qpc.behavior.clone();
      if (cloned_object == null || !$cast(behavior, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "QPC behavior clone mismatch")
    end
```

In `rdma_qpc_model.validate()`, after the context-backing alignment check and before
transport-extension validation, add:

```systemverilog
    if (behavior == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC behavior is null");
    status = behavior.validate();
    if (!status.ok()) return status;
```

Replace `rdma_qpc_model.describe()` with:

```systemverilog
  virtual function string describe();
    string behavior_text;
    string extension_text;

    behavior_text = (behavior == null) ? "null" : behavior.describe();
    extension_text = (transport_ext == null) ? "null"
                                             : transport_ext.describe();
    return $sformatf(
      "QPC(transport=%s sq_depth=%0d rq_depth=%0d %s %s)",
      transport.name(), sq_depth, rq_depth, behavior_text, extension_text
    );
  endfunction
```

Do not add a TX/RX flow-control equality check to this generic model.

- [ ] **Step 5: Run focused GREEN tests on the VCS host**

Run:

```bash
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
```

Expected: both tests PASS with zero UVM warning, error, and fatal counts. The context
test proves default/range/null/deep-copy behavior; the request test proves nested QPC
clone ownership.

- [ ] **Step 6: Commit the model change**

```bash
git add src/model/rdma_context_models.svh \
  tests/unit/rdma_context_model_test.svh \
  tests/unit/rdma_request_model_test.svh
git commit -m "feat: model qpc behavior ownership"
```

Expected: one commit containing only the model and its two tests.

### Task 2: Reconcile the parent Task 10C plan

**Files:**
- Modify: `docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md`

- [ ] **Step 1: Add the Task 10A.1 prerequisite and public field**

Immediately below the `### Task 10C` heading, add:

```markdown
> **Task 10A.1 prerequisite:** Follow
> `docs/superpowers/specs/2026-08-21-qpc-behavior-ownership-design.md`.
> QPC behavior is explicit model state; `context_backing` maps to `SHADOW_PBA`;
> xtr_v1 has one shared `FC_EN`; and QPC uses a private 512B allowed mask.
```

In the Task 10A public QPC ownership code block, add this member before the three
existing signature/flow-control bits:

```systemverilog
  rdma_qpc_behavior behavior;
```

- [ ] **Step 2: Correct Task 10C tests and serialized equality**

Extend Task 10C Step 1 with these exact requirements:

```markdown
Every golden builder explicitly sets `behavior`; transport selection must not supply
behavior defaults. Set `context_backing.value = frozen_shadow_pba << 9`, verify
`signature_enable -> SQ_CE_EN`, and use equal TX/RX flow-control values for positive
vectors. Negative rows also cover behavior width violations, TX/RX flow-control
mismatch, and a QPC-private reserved bit.
```

Replace the stale Task 10C Step 3 equality sentence with:

```markdown
The QPC override compares every serialized behavior field, `context_backing`,
`signature_enable`, and both flow-control semantics; it compares handles by
`kind/object_id`, canonicalizes SQE to SQD on state decode, and ignores only function
UID/generation plus fields that the approved design explicitly classifies as runtime
metadata.
```

- [ ] **Step 3: Correct Task 10C projection and mask rules**

Add these rules to Task 10C Step 4 before the transport-specific mappings:

```markdown
The common projection writes `behavior.transport_version`, migration, both endian
swap bits, both fence bits, and priority into their frozen QPC fields. It writes
`SHADOW_PBA = context_backing.value >> 9` and `SQ_CE_EN = signature_enable`.
Reject unequal TX/RX flow control with `RDMA_SC_INVALID_ARGUMENT`, otherwise write the
shared value to `FC_EN`; decode restores both model fields from that bit and restores
the byte IOVA with `SHADOW_PBA << 9`.

Build a QPC-specific 512B allowed mask from the frozen QPC field table. Do not call
the 64B sparse-command `body_mask()` for `RDMA_IMAGE_QPC`. Leave `CC_TYPE`,
`RTO_CODE`, and `LOAD_RQ_PI_TH` zero/reserved until a separate approved design assigns
their ownership.
```

- [ ] **Step 4: Check the reconciled plan and commit it**

Run:

```bash
git diff --check
! rg -n 'ignores .*QPC `context_backing`|ignores .*context_backing' \
  docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md
rg -n "Task 10A.1 prerequisite|SHADOW_PBA = context_backing|QPC-specific 512B allowed mask" \
  docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md
```

Expected: the stale-ignore search has no match; all three corrected ownership phrases
are found; `git diff --check` is silent.

Commit:

```bash
git add docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md
git commit -m "docs: reconcile qpc codec ownership"
```

### Task 3: Run the fresh model regression and audit the result

**Files:**
- Verify only; no source files should change.

- [ ] **Step 1: Run all affected model regressions on 53**

From a clean worktree, run each command separately so each result is attributable:

```bash
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_model_test
scripts/run_vcs53.sh core rdma_resource_manager_test
```

Expected: all four tests PASS with zero UVM warning, error, and fatal counts. Each
runner invocation creates a fresh remote directory and removes it after completion.

- [ ] **Step 2: Audit repository state**

Run:

```bash
git diff --check
git status --short --branch
git log -3 --oneline
```

Expected: `git diff --check` is silent; status shows branch
`feat/rdma-uvm-driver` with no changed or untracked files; the recent history contains
the behavior implementation and parent-plan reconciliation commits after this plan's
documentation commit.

- [ ] **Step 3: Record the handoff to Task 10C**

Report the four exact VCS commands and their zero warning/error/fatal summaries, the
two implementation commit hashes, and the clean-worktree result. State explicitly
that Task 10C may now resume and must follow both the parent ABI plan and the newer QPC
behavior ownership spec when they overlap.

# QPC Path MTU Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make path MTU explicit common state in the hardware-neutral QPC model, migrate existing model users, and reconcile Task 10C so every xtr_v1 transport encodes and decodes PMTU from that single owner.

**Architecture:** `rdma_qpc_model.path_mtu_bytes` owns the nonzero byte-sized semantic for RC, UD, and URC. The generic model accepts every nonzero value, while the future stateless xtr_v1 codec alone maps 1024/2048/4096/8192 bytes to codes 2/3/4/5 and classifies unsupported encode values separately from corrupt decode codes.

**Tech Stack:** SystemVerilog, UVM 1.2, Markdown, Git, remote Synopsys VCS on `10.11.10.53`.

---

## Scope and execution constraints

- Implement only Task 10A.2 from
  `docs/superpowers/specs/2026-08-22-qpc-path-mtu-ownership-design.md`.
- The fixed driver authority remains commit
  `491faf2ba42627fffd4dd027607299c8bb591ec2` from
  `/home/ubuntu/workspace/Desktop.zip` on `10.11.10.53`.
- Do not create or partially implement the QPC codec in this plan. Task 10C owns the
  xtr_v1 PMTU projection and all payload bytes.
- Keep 256B, 512B, and every other nonzero MTU legal in
  `rdma_qpc_model.validate()`. The xtr_v1 profile rejects unsupported sizes later.
- Run every SystemVerilog compile and simulation on `10.11.10.53` through
  `scripts/run_vcs53.sh`. If password authentication is needed, inject it only into
  the current process with `sshpass -e`; never store it in a file, URL, or helper.
- Execute Task 1 before Task 2. Do not resume Task 10C until both commits have passed
  review and the Task 3 fresh regression is clean.

## File map

| File | Responsibility in this plan |
|---|---|
| `src/model/rdma_context_models.svh` | Move path MTU from RC/URC extensions to common QPC construction, validation, copy, and description. |
| `tests/unit/rdma_context_model_test.svh` | Lock zero rejection, generic 256B acceptance, common-field clone preservation, and description visibility. |
| `tests/unit/rdma_request_model_test.svh` | Migrate RC/UD/URC and CMQ clone use sites to the common MTU owner. |
| `docs/superpowers/specs/2026-08-21-xtr-v1-context-body-abi-design.md` | Correct the parent ABI's ownership, equality, profile-status, and golden-source language. |
| `docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md` | Add Task 10A.2 replay ordering and make Task 10C consume common PMTU with exact tests and statuses. |

### Task 1: Migrate QPC model and model consumers

**Files:**
- Modify: `tests/unit/rdma_context_model_test.svh`
- Modify: `tests/unit/rdma_request_model_test.svh`
- Modify: `src/model/rdma_context_models.svh`

- [ ] **Step 1: Write the failing common-ownership tests**

In `rdma_context_model_test.make_qpc()`, place the valid MTU on the common model after
the access assignment and remove the RC-extension assignment:

```systemverilog
    qpc.path_mtu_bytes = 1024;
```

The RC extension setup must end as:

```systemverilog
    rc_ext.remote_qpn = 24'h654321;
    rc_ext.send_psn = 24'habcdef;
    rc_ext.recv_psn = 24'h123456;
    rc_ext.retry_count = 3;
    rc_ext.rnr_retry_count = 4;
    qpc.transport_ext = rc_ext;
```

Add `rdma_status status;` to `rdma_context_model_test.run_phase()`. Immediately after
the first valid-QPC check, require the common value and description, then extend the
existing clone branch to check and mutate the scalar:

```systemverilog
    if (qpc.path_mtu_bytes != 1024 ||
        !uvm_is_match("*mtu=1024*", qpc.describe()))
      `uvm_error("QPC_COMMON_MTU",
                 "QPC did not expose its common path MTU")
```

Replace the existing QPC clone condition and mutation branch with:

```systemverilog
    else if (qpc_clone.behavior == null ||
             qpc_clone.address_vector == null ||
             qpc_clone.behavior == qpc.behavior ||
             qpc_clone.address_vector == qpc.address_vector ||
             qpc_clone.transport_ext == qpc.transport_ext ||
             qpc_clone.qp_h == qpc.qp_h ||
             qpc_clone.path_mtu_bytes != 1024)
      `uvm_error("QPC_CLONE", "QPC clone did not preserve common state")
    else begin
      qpc_clone.behavior.\priority = 6;
      qpc_clone.address_vector.destination_mac++;
      qpc_clone.qp_h.object_id++;
      qpc_clone.path_mtu_bytes = 2048;
      if (qpc.behavior.\priority != 5 ||
          qpc.address_vector.destination_mac != 48'h02_11_22_33_44_55 ||
          qpc.qp_h.object_id != 32'h101 ||
          qpc.path_mtu_bytes != 1024)
        `uvm_error("QPC_CLONE", "QPC clone mutation reached source")
    end
```

After the existing context-alignment check and before the behavior-null check, add
the generic-model boundary cases. Check the precise status for zero, restore the
builder value after proving that 256B remains hardware-neutral and legal:

```systemverilog
    qpc.path_mtu_bytes = 0;
    status = qpc.validate();
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("QPC_MTU_ZERO",
                 (status == null) ? "status is null" : status.convert2string())
    qpc.path_mtu_bytes = 256;
    expect_ok("QPC_MTU_GENERIC_256", qpc.validate());
    qpc.path_mtu_bytes = 1024;
```

Remove `urc_ext.path_mtu_bytes = 1024;` from the standalone URC-extension setup. That
extension remains valid based on its own remote-QPN, backing, and threshold state.

In `rdma_request_model_test.svh`, assign the RC value to the common QPC before creating
the RC extension:

```systemverilog
    qpc.path_mtu_bytes = 4096;
```

Remove `rc_ext.path_mtu_bytes = 4096;`. Replace the first QPC clone value predicate
with:

```systemverilog
    else if (qpc_clone.behavior == qpc.behavior ||
        qpc_clone.transport_ext == qpc.transport_ext ||
        qpc_clone.qp_h == qpc.qp_h ||
        qpc_clone.pd_h == qpc.pd_h ||
        qpc_clone.send_cq_h == qpc.send_cq_h ||
        qpc_clone.recv_cq_h == qpc.recv_cq_h ||
        qpc_clone.transport != RDMA_TRANSPORT_RC ||
        qpc_clone.state != RDMA_QPS_RTS ||
        qpc_clone.sq_depth != 1024 || qpc_clone.rq_depth != 512 ||
        qpc_clone.sq_backing.value != 64'h6000_0000 ||
        qpc_clone.rq_backing.value != 64'h6001_0000 ||
        qpc_clone.context_backing.value != 64'h6002_0000 ||
        qpc_clone.path_mtu_bytes != 4096 ||
        qpc_clone.behavior.transport_version != 1 ||
        qpc_clone.behavior.migration_enable != 1'b1 ||
        qpc_clone.behavior.\priority != 5 ||
        qpc_clone.address_vector == qpc.address_vector)
      `uvm_error("QPC_CLONE", "QPC clone lost or aliased common fields")
```

Replace that clone's successful mutation branch with:

```systemverilog
    else begin
      qpc_clone.behavior.\priority = 6;
      qpc_clone.qp_h.object_id++;
      qpc_clone.sq_depth = 2048;
      qpc_clone.path_mtu_bytes = 2048;
      rc_ext_clone.remote_qpn++;
      if (qpc.behavior.\priority != 5 ||
          qpc.qp_h.object_id != 32'h404 || qpc.sq_depth != 1024 ||
          qpc.path_mtu_bytes != 4096 ||
          rc_ext.remote_qpn != 24'habc123)
        `uvm_error("QPC_CLONE", "QPC clone mutation reached source")
    end
```

The RC-extension clone predicate must end without an MTU member:

```systemverilog
    else if (rc_ext_clone.remote_qpn != 24'habc123 ||
        rc_ext_clone.send_psn != 24'h102030 ||
        rc_ext_clone.recv_psn != 24'h405060 ||
        rc_ext_clone.retry_count != 3 ||
        rc_ext_clone.rnr_retry_count != 5)
      `uvm_error("QPC_CLONE", "QPC clone lost nested RC extension")
```

When switching the same QPC to UD, prove the existing common value survives transport
replacement before validating it:

```systemverilog
    if (qpc.path_mtu_bytes != 4096)
      `uvm_error("QPC_UD_MTU", "UD lost the common QPC MTU")
    expect_status("QPC_UD", qpc.validate(), RDMA_SC_OK);
```

Before switching to URC, set the new common value and remove the URC-extension MTU
assignment:

```systemverilog
    qpc.path_mtu_bytes = 8192;
```

Finally, move the CMQ clone check from `urc_ext_clone` to the QPC itself. The relevant
predicates must be:

```systemverilog
    else if (qpc_clone.transport_ext == qpc.transport_ext ||
        qpc_clone.transport != RDMA_TRANSPORT_URC ||
        qpc_clone.sq_depth != 1024 ||
        qpc_clone.path_mtu_bytes != 8192)
      `uvm_error("CMQ_CLONE", "CMQ QPC clone lost or aliased fields")
```

```systemverilog
    else if (urc_ext_clone.remote_qpn != 24'h765432 ||
        urc_ext_clone.rbsn != 24'h112244)
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost nested context")
```

- [ ] **Step 2: Run RED on the VCS host**

Run each test separately:

```bash
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
```

Expected: both commands exit nonzero during compilation because
`rdma_qpc_model.path_mtu_bytes` does not exist. The diagnostic must name the missing
common member; an SSH, license, unrelated syntax, or missing-extension-member failure
does not count as RED.

- [ ] **Step 3: Implement the common QPC owner**

In `rdma_qpc_model`, add the scalar immediately after `access`:

```systemverilog
  rdma_rdma_access_t access;
  int unsigned path_mtu_bytes;
  int unsigned sq_depth;
```

Initialize and copy it with the other common scalar state:

```systemverilog
    access = '0;
    path_mtu_bytes = '0;
    sq_depth = '0;
```

```systemverilog
    access = rhs_qpc.access;
    path_mtu_bytes = rhs_qpc.path_mtu_bytes;
    sq_depth = rhs_qpc.sq_depth;
```

After `behavior.validate()` succeeds and before handle validation, reject only zero:

```systemverilog
    if (path_mtu_bytes == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC path MTU is zero");
```

Replace `rdma_qpc_model.describe()` with the following implementation so the common
value is visible independently of the active transport extension:

```systemverilog
  virtual function string describe();
    string behavior_text;
    string extension_text;

    behavior_text = (behavior == null) ? "null" : behavior.describe();
    extension_text = (transport_ext == null) ? "null"
                                             : transport_ext.describe();
    return $sformatf(
      "QPC(transport=%s sq_depth=%0d rq_depth=%0d mtu=%0d behavior=%s ext=%s)",
      transport.name(), sq_depth, rq_depth, path_mtu_bytes, behavior_text,
      extension_text
    );
  endfunction
```

Delete `path_mtu_bytes` from both `rdma_qpc_rc_ext` and `rdma_qpc_urc_ext`, including
their declarations, constructor assignments, and `do_copy()` assignments. Replace
their descriptions with:

```systemverilog
  // rdma_qpc_rc_ext
  virtual function string describe();
    return $sformatf("RC(remote_qpn=%0d send_psn=%0d recv_psn=%0d)",
                     remote_qpn, send_psn, recv_psn);
  endfunction
```

```systemverilog
  // rdma_qpc_urc_ext
  virtual function string describe();
    return $sformatf("URC(remote_qpn=%0d rbsn=%0d dbsn=%0d)",
                     remote_qpn, rbsn, dbsn);
  endfunction
```

Do not add an MTU field to `rdma_qpc_ud_ext`, and do not add a value whitelist to the
generic model.

- [ ] **Step 4: Run focused GREEN tests and ownership audit**

Run:

```bash
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
git diff --check
sed -n -e '/class rdma_qpc_rc_ext/,/endclass/p' \
  -e '/class rdma_qpc_urc_ext/,/endclass/p' \
  src/model/rdma_context_models.svh | \
  { ! rg -n 'path_mtu_bytes'; }
sed -n '/class rdma_qpc_model/,/endclass/p' \
  src/model/rdma_context_models.svh | rg -n 'path_mtu_bytes'
```

Expected: both VCS commands exit zero with UVM warning/error/fatal counts `0/0/0`;
`git diff --check` is silent; the extension search has no match; the common-QPC search
shows declaration, constructor, copy, validation, and description uses.

- [ ] **Step 5: Commit the model migration**

```bash
git add src/model/rdma_context_models.svh \
  tests/unit/rdma_context_model_test.svh \
  tests/unit/rdma_request_model_test.svh
git commit -m "feat: model common qpc path mtu"
```

Expected: one commit containing only the common-owner implementation and its migrated
model tests.

### Task 2: Reconcile the parent xtr_v1 ABI design and plan

**Files:**
- Modify: `docs/superpowers/specs/2026-08-21-xtr-v1-context-body-abi-design.md`
- Modify: `docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md`

- [ ] **Step 1: Correct ownership and profile status in the parent ABI design**

In section 6.2 of the parent design, replace the generic path-MTU paragraph with:

```markdown
`rdma_qpc_model.path_mtu_bytes` is common QPC state for RC, UD, and URC. RC and URC
transport extensions do not duplicate it, and the UD extension remains QKey-only.
The hardware-neutral model requires only a nonzero byte size, so 256B, 512B, and
future device values remain representable.

xtr_v1 maps common sizes 1024/2048/4096/8192B to PMTU codes 2/3/4/5. Encode of any
other nonzero size returns `RDMA_SC_INVALID_ARGUMENT`; decode of PMTU code 0/1/6/7
returns `RDMA_SC_CODEC_ERROR`. Neither direction invents a transport-specific default,
and a failed operation publishes no partial output.
```

In section 7, add this rule after the numbered equality list:

```markdown
QPC `serialized_equal()` compares the common `path_mtu_bytes` for every transport;
it never reads MTU from a transport extension and never omits UD MTU.
```

In section 9.2, add the frozen model inputs immediately after the three QPC golden
bullets:

```markdown
The QPC golden builders set common `path_mtu_bytes` explicitly: RC uses 8192B (code
5), UD uses 4096B (code 4), and URC uses 8192B (code 5). These are frozen case inputs,
not transport defaults.
```

- [ ] **Step 2: Add Task 10A.2 replay order and final ownership to the parent plan**

In the fixed execution contract, require this exact replay order:

```markdown
- For a clean replay, execute Task 10A, Task 10A.1, and Task 10A.2 in that order
  before Task 10B or Task 10C. Task 10A.2 follows
  `docs/superpowers/specs/2026-08-22-qpc-path-mtu-ownership-design.md` and moves PMTU
  into the common QPC model before any codec consumes it.
```

Revise the prose before the Task 10A public ownership block so it states that the
shown result is final after Task 10A.2. Replace the three QPC class declarations in
that block with:

```systemverilog
class rdma_qpc_model extends rdma_hw_model;
  rdma_handle qp_h, pd_h, send_cq_h, recv_cq_h, srq_h;
  rdma_transport_e transport;
  rdma_qp_state_e state;
  int unsigned host_id, vf_id, stat_index;
  bit [15:0] pkey;
  bit [7:0] qp_sequence;
  rdma_rdma_access_t access;
  int unsigned path_mtu_bytes;
  int unsigned sq_depth, rq_depth;
  rdma_backing_addr_t sq_backing, rq_backing, context_backing;
  rdma_object_mode_e sq_mode, rq_mode;
  rdma_address_vector address_vector;
  rdma_qpc_behavior behavior;
  bit signature_enable, tx_flow_control, rx_flow_control;
  rdma_qpc_transport_ext transport_ext;
endclass

class rdma_qpc_rc_ext extends rdma_qpc_transport_ext;
  bit [23:0] remote_qpn, send_psn, recv_psn;
  int unsigned retry_count, rnr_retry_count;
endclass

class rdma_qpc_ud_ext extends rdma_qpc_transport_ext;
  bit [31:0] qkey;
endclass

class rdma_qpc_urc_ext extends rdma_qpc_transport_ext;
  bit [23:0] remote_qpn, rbsn, dbsn, rpsn, dpsn;
  rdma_backing_addr_t rsq_backing, rdsq_backing, dsq_backing;
  int unsigned fetch_threshold, queue_threshold;
endclass
```

- [ ] **Step 3: Make Task 10C consume and test the common PMTU**

Extend the Task 10C prerequisite block with:

```markdown
> **Task 10A.2 prerequisite:** Follow
> `docs/superpowers/specs/2026-08-22-qpc-path-mtu-ownership-design.md`.
> Path MTU is common `rdma_qpc_model` state for RC, UD, and URC; the codec may not
> obtain it from an extension or synthesize a default.
```

Add `path_mtu_bytes` to the Step 1 `serialized_equal()` falsification mutation table.
Add these precise builder and negative-test requirements to the same step:

```markdown
Set common `path_mtu_bytes` explicitly in every golden builder: RC=8192B, UD=4096B,
and URC=8192B. Prove round-trip preservation for all three transports. Separately
exercise 1024/2048/4096/8192B and require encoded PMTU codes 2/3/4/5. Encode 256B,
512B, and one other unsupported nonzero size and require
`RDMA_SC_INVALID_ARGUMENT`; mutate the input image to PMTU codes 0/1/6/7 and require
`RDMA_SC_CODEC_ERROR`. Every failure leaves the caller's output null/unpublished.
```

In Step 4, make the forward mapping read the common owner:

```systemverilog
case (qpc.path_mtu_bytes)
  1024: pmtu_code = 3'd2;
  2048: pmtu_code = 3'd3;
  4096: pmtu_code = 3'd4;
  8192: pmtu_code = 3'd5;
  default:
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "xtr_v1 path MTU is unsupported");
endcase
```

Add the inverse mapping and exact corruption classification to Step 4:

```systemverilog
case (pmtu_code)
  3'd2: qpc.path_mtu_bytes = 1024;
  3'd3: qpc.path_mtu_bytes = 2048;
  3'd4: qpc.path_mtu_bytes = 4096;
  3'd5: qpc.path_mtu_bytes = 8192;
  default:
    return rdma_status::make(RDMA_SC_CODEC_ERROR,
                             "xtr_v1 PMTU code is invalid");
endcase
```

State explicitly beside these snippets that the codec validates into temporary state
and assigns the caller output only after the entire image passes, preserving the
existing atomic-output contract.

- [ ] **Step 4: Audit and commit the parent-document reconciliation**

Run:

```bash
git diff --check
rg -n "Task 10A\.2|path_mtu_bytes|RC=8192B|UD=4096B|URC=8192B|PMTU codes 0/1/6/7" \
  docs/superpowers/specs/2026-08-21-xtr-v1-context-body-abi-design.md \
  docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md
if sed -n -e '/class rdma_qpc_rc_ext/,/endclass/p' \
  -e '/class rdma_qpc_urc_ext/,/endclass/p' \
  docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md | \
  rg -n 'path_mtu_bytes'; then exit 1; fi
```

Expected: `git diff --check` is silent; the first search finds the prerequisite,
common owner, frozen values, and invalid-code contract in both parent documents; the
extension-block search has no match.

Commit:

```bash
git add docs/superpowers/specs/2026-08-21-xtr-v1-context-body-abi-design.md \
  docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md
git commit -m "docs: reconcile common qpc path mtu"
```

### Task 3: Run fresh model regression and hand off Task 10C

**Files:**
- Verify only; no source or documentation files change.

- [ ] **Step 1: Run every affected model regression on 53**

Start from a clean worktree and run one fresh staging command per test:

```bash
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_model_test
scripts/run_vcs53.sh core rdma_resource_manager_test
```

Expected: all four processes exit zero; each UVM report shows warning/error/fatal
counts `0/0/0`; every runner-created `/home/ubuntu/workspace/rdma_uvm.XXXXXX`
directory is removed on exit.

- [ ] **Step 2: Audit repository state and ownership**

Run:

```bash
git diff --check
git status --short --branch
git log -4 --oneline
sed -n '/class rdma_qpc_model/,/endclass/p' \
  src/model/rdma_context_models.svh | rg -n 'path_mtu_bytes'
if sed -n -e '/class rdma_qpc_rc_ext/,/endclass/p' \
  -e '/class rdma_qpc_ud_ext/,/endclass/p' \
  -e '/class rdma_qpc_urc_ext/,/endclass/p' \
  src/model/rdma_context_models.svh | rg -n 'path_mtu_bytes'; then exit 1; fi
```

Expected: the diff check is silent; status shows clean branch
`feat/rdma-uvm-driver`; recent history contains the Task 10A.2 model and parent-doc
commits after this plan commit; only the common QPC block contains the field.

- [ ] **Step 3: Record the Task 10C handoff**

Report the four exact VCS commands and each `0/0/0` UVM summary, both implementation
commit hashes, and the clean-worktree result. State that Task 10C may resume only under
both QPC ownership amendments, with common-MTU golden inputs RC=8192B, UD=4096B,
URC=8192B and exact encode/decode failure classes preserved.

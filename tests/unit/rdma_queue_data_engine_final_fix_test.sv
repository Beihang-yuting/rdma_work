// 目录/层次：tests/unit，rdma_core_pkg 内 queue-data engine 最终复审回归。
// 文件职责：按完整 codec key 验证 host producer、CQE/CEQE/AEQE 消费边界的
//   null lookup/codec status 与 entry-image factory 故障，并聚焦 recovery 生命周期门。
// 主要依赖：复用 rdma_queue_data_engine_device_publish_test 的真实 lifecycle fixture、
//   mock Host-memory/PCIe 账本和公开 publish/poll/query/recover API。
// 所有权与生命周期：每个 concrete UVM test 拥有独立 fixture；registry/codec guard
//   仅保存非拥有引用，fixture cleanup 仍是 queue、mapping 与 attachment 的唯一回收者。

// 设计说明：CQ poll 会把 registry 返回值向下转换为 rdma_hw_cqe_codec 后调用带
// entry-size 的 decode，因此必须使用同类型 test codec 才能命中真实 null-status
// 边界，而不能用类型不匹配提前替代被测分支。
class rdma_final_null_cqe_decode_codec extends rdma_hw_cqe_codec;
  `uvm_object_utils(rdma_final_null_cqe_decode_codec)

  // 功能：构造只在 decode_with_entry_bytes 返回 null status 的 CQE fault codec。
  // 输入/输出及副作用：name 为对象名；调用基类构造，不登记 registry 或持有 backing。
  // 失败/边界：该对象仅由测试临时替换精确 CQE key，禁止用于正常 encode/publish。
  function new(string name = "rdma_final_null_cqe_decode_codec");
    super.new(name);
  endfunction

  // 功能：在 CQE poll 已完成真实 backing read/image 包装后返回 null decode status。
  // 输入/输出及副作用：image、entry_size 为输入，model 输出固定为 null；不修改
  //   image、runtime cursor、occupancy、backing 或 scheduler history。
  // 失败/边界：所有输入都故意不校验并返回 null，生产 consumer 必须归一化为
  //   RDMA_SC_CODEC_ERROR，且不得继续 owner/route/doorbell/commit/release。
  virtual function rdma_status decode_with_entry_bytes(
    rdma_hw_image image,
    int unsigned entry_size,
    output rdma_hw_model model
  );
    model = null;
    return null;
  endfunction

  // 功能：在带显式 CQE variant 的真实 poll 入口返回 null decode status，覆盖
  //       production consumer 实际调用的 profile/variant dispatch seam。
  // 输入/输出及副作用：image、entry_size、variant 为输入，model 固定输出 null；
  //       不修改 image、CQ runtime、backing、route 或任何 scheduler 状态。
  // 失败/边界：所有输入都故意不接受并返回 null；consumer 必须把 null 归一化为
  //       RDMA_SC_CODEC_ERROR，并在 CQ CI、WQE release 和 completion publish 前退出。
  virtual function rdma_status decode_with_entry_bytes_variant(
    rdma_hw_image image,
    int unsigned entry_size,
    rdma_cqe_variant_e variant,
    output rdma_hw_model model
  );
    model = null;
    return null;
  endfunction
endclass

// 设计说明：host producer 的 WQE 与 doorbell 可能已经成功到达外部后端，
//   但 runtime ledger commit 仍可能因锁、状态或 factory 故障拒绝。该 test-only
//   engine 只在 queue-data 的 commit seam 注入一次确定性结果，不修改 runtime
//   私有账本，也不替代公开 recovery/abort 生命周期。
class rdma_queue_data_engine_host_commit_fault extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_queue_data_engine_host_commit_fault)

  bit fail_commit_once;
  bit return_null_once;
  rdma_status injected_status;
  int unsigned commit_calls;

  // 功能：构造默认不注入故障的 host-producer commit probe。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地 fault flag/counter，
  //   不配置 engine、runtime、backing 或外部资源。
  // 失败/边界：构造阶段不 arm 故障；未 configure 的对象仍由生产入口拒绝，
  //   probe 不提供绕过 attachment/authority 的测试后门。
  function new(string name = "rdma_queue_data_engine_host_commit_fault");
    super.new(name);
    fail_commit_once = 1'b0;
    return_null_once = 1'b0;
    injected_status = null;
    commit_calls = 0;
  endfunction

  // 功能：arm_commit_failure 配置下一次 host-producer ledger commit 返回给定
  //   错误或 null status，并清除上一次注入状态。
  // 输入/输出及副作用：failure、return_null 为输入；只写 probe 自有 flag/status
  //   快照，不访问 runtime、pending、Host-memory 或 PCIe。
  // 失败/边界：failure 为空且 return_null=0 时仍使用 INVALID_STATE 默认错误；
  //   注入只消费一次，后续 commit 委托生产 seam，避免污染其它 fixture。
  function void arm_commit_failure(
    rdma_status failure = null,
    bit return_null = 1'b0
  );
    fail_commit_once = !return_null;
    return_null_once = return_null;
    injected_status = failure == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE,
                        "injected host producer ledger commit failure") :
      failure;
  endfunction

  // 功能：commit_host_producer_ledger 观察并按 arm 状态拒绝一次 producer ledger
  //   提交，覆盖 WQE/readback 与 doorbell 已完成后的最后一个 commit 阶段。
  // 输入/输出及副作用：attachment、cursor、request、wr_id、signaled、image 为
  //   caller 冻结输入；每次调用递增 commit_calls，故障时不调用 runtime，未注入时
  //   委托生产 seam 并由 runtime 负责 PI/used/slot mutation。
  // 失败/边界：return_null_once 返回 null 供 caller 归一化；fail_commit_once
  //   返回 detached injected_status；所有其它调用保持基类 status/ownership 语义。
  protected virtual function rdma_status commit_host_producer_ledger(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot cursor,
    rdma_semantic_request request,
    longint unsigned wr_id,
    bit signaled,
    rdma_hw_image image
  );
    commit_calls++;
    if (return_null_once) begin
      return_null_once = 1'b0;
      return null;
    end
    if (fail_commit_once) begin
      fail_commit_once = 1'b0;
      return injected_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "injected host producer ledger commit failure") :
        injected_status;
    end
    return super.commit_host_producer_ledger(
      attachment, cursor, request, wr_id, signaled, image);
  endfunction
endclass

// 设计说明：本公共基类只封装 final-review 场景的 fixture 建立、按 key 故障与
// 原子性断言；每个 concrete test 独立运行，确保任一未防护 null 解引用都能形成
// 自己的 RED，而不会被前一个 simulator runtime error 遮蔽。
class rdma_queue_data_engine_final_fix_test_base
  extends rdma_queue_data_engine_device_publish_test;

  // 功能：构造 final-fix 测试基类，沿用父类的 factory wrapper 与 tracked fixture。
  // 输入/输出及副作用：name/parent 为输入；只建立 UVM component 层级，不创建资源。
  // 失败/边界：该基类不注册为可运行 test；只能由下方 concrete test 的 run_phase 使用。
  function new(string name = "rdma_queue_data_engine_final_fix_test_base",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：setup_codec_fixture 建立使用 fault registry 的完整 QP/CQ/CEQ/AEQ fixture。
  // 输入/输出及副作用：label 为输入，fixture/registry/status 为输出；成功登记 fixture
  //   供统一 cleanup，并返回同一 engine 实际消费的 registry 非拥有引用。
  // 失败/边界：factory/setup/cast 任一失败返回非成功 status；不得用新 registry 替换
  //   已配置 engine 的引用，也不掩盖 partial fixture 以便 cleanup 回收。
  protected task automatic setup_codec_fixture(
    string label,
    output rdma_queue_data_engine_fixture fixture,
    output rdma_queue_consumer_fault_registry fault_registry,
    output rdma_status status,
    input bit use_host_commit_fault = 1'b0
  );
    fixture = null;
    fault_registry = null;
    reset_device_publish_factory_state();
    if (use_host_commit_fault)
      rdma_queue_data_engine::type_id::set_type_override(
        rdma_queue_data_engine_host_commit_fault::get_type(), 1'b1);
    fixture = rdma_queue_data_engine_fixture::type_id::create(label);
    if (fixture == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "final-fix fixture allocation failed");
      return;
    end
    // CQ poll 的真实 0.1.34 路径通过 CQC shadow 发布 CI；该 final-fix fixture
    // 必须显式提供 context backing，避免把“缺少驱动必需 authority”的配置拒绝
    // 误报为 codec lookup/decode 故障。
    fixture.setup(status, 16, RDMA_CQE_BYTES, 16, 16, 1'b1);
    track_fixture(fixture);
    if (status == null || !status.ok()) return;
    if (!$cast(fault_registry, fixture.registry) || fault_registry == null)
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "fault registry override was not installed");
  endtask

  // 功能：expect_host_ring_unchanged 查询 SQ 的真实 cursor/occupancy，验证 codec
  //   预写拒绝没有发布 ledger 或 producer cursor。
  // 输入/输出及副作用：label/fixture 为输入；只读公开 runtime 状态并报告 UVM_ERROR。
  // 失败/边界：query 返回 null/失败、PI/CI/wrap 非零、used/pending 非空均视为原子性
  //   破坏；本 helper 不把 mock 调用计数当作唯一状态证据。
  protected task automatic expect_host_ring_unchanged(
    string label,
    rdma_queue_data_engine_fixture fixture
  );
    rdma_status status;
    int unsigned pi;
    int unsigned ci;
    int unsigned used;
    bit pw;
    bit cw;
    bit has_pending;

    status = fixture.engine.query_runtime_cursors(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, pi, pw, ci, cw);
    if (status == null || !status.ok() || pi != 0 || pw || ci != 0 || cw)
      `uvm_error({label, "_CURSOR"}, "host codec fault changed SQ cursors")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, used, has_pending);
    if (status == null || !status.ok() || used != 0 || has_pending)
      `uvm_error({label, "_OCCUPANCY"},
                 "host codec fault changed SQ ledger/pending")
  endtask

  // 功能：run_host_codec_faults 依次验证 SQE lookup null、encode null 与
  //   success+null codec，三者都在 Host-memory/MMIO 前 fail closed。
  // 输入/输出及副作用：无显式输入；建立一份真实 fixture，三次调用公开 post_send，
  //   比较 Host-memory/PCIe 账本与 SQ cursor/occupancy，并恢复每个临时 codec。
  // 失败/边界：任一故障必须返回非 null RDMA_SC_CODEC_ERROR/result=null，且不写
  //   backing、不发 MMIO、不保留 pending；registry 恢复失败会单独报告。
  protected task automatic run_host_codec_faults();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_consumer_fault_registry fault_registry;
    rdma_queue_consumer_codec_guard null_encode;
    rdma_queue_post_result result;
    rdma_codec_key key;
    rdma_codec_base original;
    rdma_codec_base replaced;
    rdma_status status;
    int unsigned mem_before;
    int unsigned mmio_before;

    setup_codec_fixture("host_codec_final_fix_fixture", fixture,
                        fault_registry, status);
    if (status == null || !status.ok()) begin
      `uvm_error("HOST_CODEC_SETUP", "host codec fixture setup failed")
      return;
    end
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_SQE,
            object_type:"sqe", variant:"rc", opcode:8'h00};
    mem_before = fixture.mem.calls.size();
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    fault_registry.arm_targeted_null_lookup_once(key);
    fixture.engine.post_send(fixture.make_send(64'hf001), result, status);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR || result != null ||
        fixture.mem.calls.size() != mem_before ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("HOST_CODEC_NULL_LOOKUP",
                 "SQE null lookup crossed a producer side-effect boundary")
    expect_host_ring_unchanged("HOST_CODEC_NULL_LOOKUP", fixture);

    status = fault_registry.lookup(key, original);
    null_encode = new("host_null_encode", original);
    null_encode.return_null_encode_status = 1'b1;
    if (status == null || !status.ok() || original == null ||
        !fault_registry.replace_codec_for_test(key, null_encode, replaced)) begin
      `uvm_error("HOST_CODEC_NULL_ENCODE_SETUP", "cannot replace SQE codec")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hf002), result, status);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR || result != null ||
        fixture.mem.calls.size() != mem_before ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("HOST_CODEC_NULL_ENCODE",
                 "SQE null encode status crossed a producer side-effect boundary")
    expect_host_ring_unchanged("HOST_CODEC_NULL_ENCODE", fixture);
    if (!fault_registry.restore_codec_for_test(key, original))
      `uvm_error("HOST_CODEC_NULL_ENCODE_RESTORE", "cannot restore SQE codec")

    if (!fault_registry.replace_codec_for_test(key, null, replaced)) begin
      `uvm_error("HOST_CODEC_NULL_CODEC_SETUP", "cannot install null SQE codec")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hf003), result, status);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR || result != null ||
        fixture.mem.calls.size() != mem_before ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("HOST_CODEC_NULL_CODEC",
                 "SQE success-plus-null codec crossed a side-effect boundary")
    expect_host_ring_unchanged("HOST_CODEC_NULL_CODEC", fixture);
    if (!fault_registry.restore_codec_for_test(key, original))
      `uvm_error("HOST_CODEC_NULL_CODEC_RESTORE", "cannot restore SQE codec")
  endtask

  // 功能：run_producer_doorbell_fault 验证 SQ WQE 已写 backing 后，producer
  //   doorbell lookup null 被归一化并保留 runtime recovery evidence。
  // 输入/输出及副作用：无显式输入；调用真实 post_send，读取 PCIe、cursor、used 与
  //   pending，最后通过公开 abort 隔离 QP，绝不直接改写 runtime 私有字段。
  // 失败/边界：必须返回 CODEC_ERROR/result=null、MMIO 不增加、PI/used 不推进且
  //   pending 非空；由于 backing write 已发生，abort 是唯一允许清除 evidence 的路径。
  protected task automatic run_producer_doorbell_fault();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_consumer_fault_registry fault_registry;
    rdma_queue_post_result result;
    rdma_queue_pending_operation pending;
    rdma_codec_key key;
    rdma_status status;
    int unsigned mmio_before;
    int unsigned used;
    bit has_pending;

    setup_codec_fixture("producer_db_final_fix_fixture", fixture,
                        fault_registry, status);
    if (status == null || !status.ok()) begin
      `uvm_error("PRODUCER_DB_SETUP", "producer doorbell fixture setup failed")
      return;
    end
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_DOORBELL,
            object_type:"doorbell", variant:"sq", opcode:8'h00};
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    fault_registry.arm_targeted_null_lookup_once(key);
    fixture.engine.post_send(fixture.make_send(64'hf101), result, status);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR || result != null ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("PRODUCER_DB_NULL_LOOKUP",
                 "producer doorbell null lookup reached MMIO or lost status")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, pending);
    if (status == null || !status.ok() || pending == null ||
        pending.image == null || !pending.producer)
      `uvm_error("PRODUCER_DB_PENDING",
                 "post-doorbell codec failure did not retain WQE evidence")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, used, has_pending);
    if (status == null || !status.ok() || used != 0 || !has_pending)
      `uvm_error("PRODUCER_DB_OCCUPANCY",
                 "doorbell codec failure advanced SQ or lost pending")
    fixture.engine.recover_queue(
      fixture.qp.handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b0, status);
    if (status == null || !status.ok())
      `uvm_error("PRODUCER_DB_ABORT", "explicit QP recovery abort failed")
    else
      fixture.qp_attached = 1'b0;
  endtask

  // 功能：run_host_producer_hostile_matrix 对真实 SQ post_send 依次注入 WQE
  //   backing write、readback、DMA visibility barrier、MMIO ordering barrier 和
  //   MMIO write 故障，验证每个不可逆阶段都保留同一 producer recovery evidence。
  // 输入/输出及副作用：无显式输入；每个 case 建立独立 codec fixture，调用一次
  //   post_send，读取 SQ cursor/occupancy、pending、Host-memory 与 PCIe 账本，随后
  //   通过公开 ABORT_AND_DETACH 隔离故障；不取得 queue、mapping 或 adapter 所有权。
  // 失败/边界：write/readback case 必须保持 NO_SUBMIT 且只发生预期 Host-memory
  //   I/O，doorbell case 必须保持 AMBIGUOUS 并呈现精确 barrier/MMIO 调用前缀；任一
  //   status 为空、result 非空、PI/CI/used 错进、pending 缺失或 abort 失败均报告。
  protected task automatic run_host_producer_hostile_matrix();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_consumer_fault_registry fault_registry;
    rdma_queue_post_result result;
    rdma_queue_pending_operation pending;
    rdma_status setup_status;
    rdma_status inject_status;
    rdma_status post_status;
    rdma_status cursor_status;
    rdma_status occupancy_status;
    rdma_status pending_status;
    rdma_status abort_status;
    rdma_status injected_failure;
    rdma_queue_mmio_evidence_e expected_evidence;
    rdma_status_code_e expected_code;
    string case_label;
    int unsigned fault_kind;
    int unsigned before_pi;
    int unsigned before_ci;
    int unsigned after_pi;
    int unsigned after_ci;
    int unsigned before_used;
    int unsigned after_used;
    int unsigned before_writes;
    int unsigned before_reads;
    int unsigned before_dma_barriers;
    int unsigned before_mmio_barriers;
    int unsigned before_mmio_writes;
    int unsigned expected_write_delta;
    int unsigned expected_read_delta;
    int unsigned expected_dma_delta;
    int unsigned expected_mmio_barrier_delta;
    int unsigned expected_mmio_write_delta;
    bit before_pi_wrap;
    bit before_ci_wrap;
    bit after_pi_wrap;
    bit after_ci_wrap;
    bit before_pending;
    bit after_pending;
    bit contract_ok;

    for (fault_kind = 0; fault_kind < 6; fault_kind++) begin
      fixture = null;
      fault_registry = null;
      result = null;
      pending = null;
      case (fault_kind)
        0: case_label = "write";
        1: case_label = "read";
        2: case_label = "readback_mismatch";
        3: case_label = "dma_barrier";
        4: case_label = "mmio_barrier";
        5: case_label = "mmio_write";
        default: case_label = "unknown";
      endcase

      setup_codec_fixture(
        {"host_producer_", case_label, "_fixture"}, fixture,
        fault_registry, setup_status);
      if (setup_status == null || !setup_status.ok()) begin
        `uvm_error("HOST_PRODUCER_MATRIX_SETUP",
                   $sformatf("case=%s setup failed: %s", case_label,
                             setup_status == null ? "<null>" :
                             setup_status.convert2string()))
        continue;
      end

      cursor_status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, before_pi, before_pi_wrap,
        before_ci, before_ci_wrap);
      occupancy_status = fixture.engine.query_runtime_occupancy(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, before_used, before_pending);
      before_writes = count_host_mem_calls(fixture.mem, "write");
      before_reads = count_host_mem_calls(fixture.mem, "read");
      before_dma_barriers = count_pcie_calls(
        fixture.pcie, "dma_visibility_barrier");
      before_mmio_barriers = count_pcie_calls(
        fixture.pcie, "mmio_ordering_barrier");
      before_mmio_writes = count_pcie_calls(fixture.pcie, "mmio_write");
      if (cursor_status == null || !cursor_status.ok() ||
          occupancy_status == null || !occupancy_status.ok() || before_pending) begin
        `uvm_error("HOST_PRODUCER_MATRIX_BASELINE",
                   $sformatf("case=%s baseline SQ state is unavailable",
                             case_label))
        continue;
      end

      injected_failure = rdma_status::make(
        (fault_kind < 3) ? RDMA_SC_DMA_TRANSLATION :
                           RDMA_SC_PCIE_COMPLETION,
        {"injected host producer ", case_label, " failure"});
      inject_status = rdma_status::success();
      expected_code = injected_failure.code;
      expected_evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
      expected_write_delta = 1;
      expected_read_delta = 0;
      expected_dma_delta = 0;
      expected_mmio_barrier_delta = 0;
      expected_mmio_write_delta = 0;
      case (fault_kind)
        0: inject_status = fixture.mem.fail_next("write", injected_failure);
        1: begin
          inject_status = fixture.mem.fail_next("read", injected_failure);
          expected_read_delta = 1;
        end
        2: begin
          fixture.mem.corrupt_next_readback = 1'b1;
          expected_code = RDMA_SC_DMA_TRANSLATION;
          expected_read_delta = 1;
        end
        3: begin
          inject_status = fixture.pcie.fail_next(
            "dma_visibility_barrier", injected_failure);
          expected_evidence = RDMA_QUEUE_MMIO_AMBIGUOUS;
          expected_read_delta = 1;
          expected_dma_delta = 1;
        end
        4: begin
          inject_status = fixture.pcie.fail_next(
            "mmio_ordering_barrier", injected_failure);
          expected_evidence = RDMA_QUEUE_MMIO_AMBIGUOUS;
          expected_read_delta = 1;
          expected_dma_delta = 1;
          expected_mmio_barrier_delta = 1;
        end
        5: begin
          inject_status = fixture.pcie.fail_next("mmio_write", injected_failure);
          expected_evidence = RDMA_QUEUE_MMIO_AMBIGUOUS;
          expected_read_delta = 1;
          expected_dma_delta = 1;
          expected_mmio_barrier_delta = 1;
          expected_mmio_write_delta = 1;
        end
        default: begin end
      endcase
      if (inject_status == null || !inject_status.ok()) begin
        `uvm_error("HOST_PRODUCER_MATRIX_INJECT",
                   $sformatf("case=%s fault arm failed", case_label))
        continue;
      end

      fixture.engine.post_send(
        fixture.make_send(64'hf147_0000_0000 + fault_kind), result, post_status);
      cursor_status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, after_pi, after_pi_wrap,
        after_ci, after_ci_wrap);
      occupancy_status = fixture.engine.query_runtime_occupancy(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, after_used, after_pending);
      pending = null;
      pending_status = fixture.engine.query_runtime_pending(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, pending);
      contract_ok = post_status != null &&
                    post_status.code == expected_code && result == null &&
                    cursor_status != null && cursor_status.ok() &&
                    occupancy_status != null && occupancy_status.ok() &&
                    pending_status != null && pending_status.ok() &&
                    pending != null && pending.producer &&
                    !pending.device_producer && pending.cursor != null &&
                    pending.image != null &&
                    pending.mmio_evidence == expected_evidence &&
                    pending.mmio_maybe_submitted ==
                      (expected_evidence == RDMA_QUEUE_MMIO_AMBIGUOUS) &&
                    after_pi == before_pi && after_pi_wrap == before_pi_wrap &&
                    after_ci == before_ci && after_ci_wrap == before_ci_wrap &&
                    after_used == before_used && after_pending &&
                    count_host_mem_calls(fixture.mem, "write") ==
                      before_writes + expected_write_delta &&
                    count_host_mem_calls(fixture.mem, "read") ==
                      before_reads + expected_read_delta &&
                    count_pcie_calls(fixture.pcie, "dma_visibility_barrier") ==
                      before_dma_barriers + expected_dma_delta &&
                    count_pcie_calls(fixture.pcie, "mmio_ordering_barrier") ==
                      before_mmio_barriers + expected_mmio_barrier_delta &&
                    count_pcie_calls(fixture.pcie, "mmio_write") ==
                      before_mmio_writes + expected_mmio_write_delta;
      if (!contract_ok)
        `uvm_error("HOST_PRODUCER_MATRIX_CONTRACT",
                   $sformatf("case=%s status=%s pending=%s evidence=%0d",
                             case_label,
                             post_status == null ? "<null>" :
                             post_status.convert2string(),
                             pending == null ? "<null>" : "present",
                             pending == null ? -1 : pending.mmio_evidence));

      fixture.engine.recover_queue(
        fixture.qp.handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH,
        1'b0, abort_status);
      if (abort_status == null || !abort_status.ok())
        `uvm_error("HOST_PRODUCER_MATRIX_ABORT",
                   $sformatf("case=%s abort failed: %s", case_label,
                             abort_status == null ? "<null>" :
                             abort_status.convert2string()))
      else
        fixture.qp_attached = 1'b0;
    end
  endtask

  // 功能：run_host_producer_commit_fault 注入 ledger commit 拒绝，验证 WQE
  //   write/readback、DMA/MMIO ordering 与 doorbell 已完成后，SQ 仍不推进 PI/used，
  //   并保留带 route/epoch/cursor/image 的 AMBIGUOUS recovery evidence。
  // 输入/输出及副作用：无显式输入；建立 commit-fault engine fixture，调用一次
  //   post_send，读取公开 cursor/occupancy/pending 与 mock I/O 账本，最后通过公开
  //   ABORT_AND_DETACH 收敛；不直接修改 runtime 私有字段。
  // 失败/边界：commit seam 必须恰好调用一次；status/result、cursor、ledger、
  //   pending evidence 或 abort 任一不符契约均报告 UVM_ERROR，故障后不得静默重发。
  protected task automatic run_host_producer_commit_fault();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_consumer_fault_registry fault_registry;
    rdma_queue_data_engine_host_commit_fault fault_engine;
    rdma_queue_post_result result;
    rdma_queue_pending_operation pending;
    rdma_status setup_status;
    rdma_status post_status;
    rdma_status cursor_status;
    rdma_status occupancy_status;
    rdma_status pending_status;
    rdma_status abort_status;
    int unsigned before_pi;
    int unsigned before_ci;
    int unsigned after_pi;
    int unsigned after_ci;
    int unsigned before_used;
    int unsigned after_used;
    int unsigned before_writes;
    int unsigned before_reads;
    int unsigned before_dma_barriers;
    int unsigned before_mmio_barriers;
    int unsigned before_mmio_writes;
    bit before_pi_wrap;
    bit before_ci_wrap;
    bit after_pi_wrap;
    bit after_ci_wrap;
    bit before_pending;
    bit after_pending;
    bit contract_ok;

    setup_codec_fixture(
      "host_producer_commit_fault_fixture", fixture, fault_registry,
      setup_status, 1'b1);
    if (setup_status == null || !setup_status.ok() ||
        !$cast(fault_engine, fixture == null ? null : fixture.engine) ||
        fault_engine == null) begin
      `uvm_error("HOST_PRODUCER_COMMIT_SETUP",
                 "commit-fault engine fixture setup failed")
      return;
    end
    cursor_status = fixture.engine.query_runtime_cursors(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap);
    occupancy_status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, before_used, before_pending);
    before_writes = count_host_mem_calls(fixture.mem, "write");
    before_reads = count_host_mem_calls(fixture.mem, "read");
    before_dma_barriers = count_pcie_calls(
      fixture.pcie, "dma_visibility_barrier");
    before_mmio_barriers = count_pcie_calls(
      fixture.pcie, "mmio_ordering_barrier");
    before_mmio_writes = count_pcie_calls(fixture.pcie, "mmio_write");
    if (cursor_status == null || !cursor_status.ok() ||
        occupancy_status == null || !occupancy_status.ok() || before_pending) begin
      `uvm_error("HOST_PRODUCER_COMMIT_BASELINE",
                 "commit-fault baseline SQ state is unavailable")
      return;
    end

    fault_engine.arm_commit_failure(
      rdma_status::make(RDMA_SC_INVALID_STATE,
                        "injected host producer ledger commit failure"));
    fixture.engine.post_send(
      fixture.make_send(64'hf148_0000), result, post_status);
    cursor_status = fixture.engine.query_runtime_cursors(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, after_pi, after_pi_wrap,
      after_ci, after_ci_wrap);
    occupancy_status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, after_used, after_pending);
    pending = null;
    pending_status = fixture.engine.query_runtime_pending(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, pending);
    contract_ok = post_status != null &&
                  post_status.code == RDMA_SC_INVALID_STATE &&
                  result == null && fault_engine.commit_calls == 1 &&
                  cursor_status != null && cursor_status.ok() &&
                  occupancy_status != null && occupancy_status.ok() &&
                  pending_status != null && pending_status.ok() &&
                  pending != null && pending.producer &&
                  !pending.device_producer && pending.cursor != null &&
                  pending.next_cursor != null && pending.image != null &&
                  pending.route_valid && pending.epoch_valid &&
                  pending.mmio_evidence == RDMA_QUEUE_MMIO_AMBIGUOUS &&
                  pending.mmio_maybe_submitted &&
                  after_pi == before_pi && after_pi_wrap == before_pi_wrap &&
                  after_ci == before_ci && after_ci_wrap == before_ci_wrap &&
                  after_used == before_used && after_pending &&
                  count_host_mem_calls(fixture.mem, "write") ==
                    before_writes + 1 &&
                  count_host_mem_calls(fixture.mem, "read") ==
                    before_reads + 1 &&
                  count_pcie_calls(fixture.pcie, "dma_visibility_barrier") ==
                    before_dma_barriers + 1 &&
                  count_pcie_calls(fixture.pcie, "mmio_ordering_barrier") ==
                    before_mmio_barriers + 1 &&
                  count_pcie_calls(fixture.pcie, "mmio_write") ==
                    before_mmio_writes + 1;
    if (!contract_ok)
      `uvm_error("HOST_PRODUCER_COMMIT_CONTRACT",
                 $sformatf("status=%s calls=%0d pending=%s evidence=%0d",
                           post_status == null ? "<null>" :
                           post_status.convert2string(), fault_engine.commit_calls,
                           pending == null ? "<null>" : "present",
                           pending == null ? -1 : pending.mmio_evidence));

    fixture.engine.recover_queue(
      fixture.qp.handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH,
      1'b0, abort_status);
    if (abort_status == null || !abort_status.ok())
      `uvm_error("HOST_PRODUCER_COMMIT_ABORT",
                 "commit-fault recovery abort failed")
    else
      fixture.qp_attached = 1'b0;
  endtask

  // 功能：publish_one_cqe 通过真实 post_send/publish_cqe 在 CQ backing 建立一条
  //   与 SQ ledger 匹配的可消费 entry，供后续 decode/factory 故障观察。
  // 输入/输出及副作用：fixture 为输入、status 为输出；成功写入 CQ backing、CQ used
  //   增一且 SQ used 保持一，不直接写测试 backing。
  // 失败/边界：post/polarity/model/publish 任一失败原样返回；只接受 result 非空的
  //   committed CQE，不能用 raw fixture writer 绕过 device producer pipeline。
  protected task automatic publish_one_cqe(
    rdma_queue_data_engine_fixture fixture,
    output rdma_status status
  );
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_hw_cqe_model cqe;
    rdma_status model_status;
    bit polarity;

    fixture.engine.post_send(fixture.make_send(64'hf201), posted, status);
    if (status == null || !status.ok() || posted == null) return;
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    if (status == null || !status.ok()) return;
    cqe = make_cqe_for_outstanding_send(
      fixture.qp.handle, fixture.qp.local_qp_id, posted, polarity,
      model_status);
    if (model_status == null || !model_status.ok() || cqe == null) begin
      status = model_status;
      return;
    end
    publish_cqe_for_test(
      fixture.engine, fixture.cq.handle, cqe, published, status);
    if (status != null && status.ok() && published == null)
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CQE publish returned no result");
  endtask

  // 功能：run_cqe_decode_fault 先对精确 CQE key 注入 null lookup，再对带 entry-size
  //   decode 注入 null status，验证两次真实 poll 都保持 CQ/SQ 状态与 MMIO 原子性。
  // 输入/输出及副作用：无显式输入；使用两份独立 fixture 发布真实 CQE，读取公开
  //   occupancy 与 PCIe history，失败后恢复 codec 并正常 poll 完成资源消费。
  // 失败/边界：两类故障都必须 CODEC_ERROR/result=null、CQ/SQ used 各保持一且无
  //   pending、MMIO 不增加；恢复后正常 poll 必须成功以证明 entry 仍可消费。
  protected task automatic run_cqe_decode_fault();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_consumer_fault_registry fault_registry;
    rdma_final_null_cqe_decode_codec null_decode;
    rdma_queue_completion_result completion;
    rdma_codec_key key;
    rdma_codec_base original;
    rdma_codec_base replaced;
    rdma_status status;
    int unsigned mmio_before;
    int unsigned used;
    bit has_pending;

    setup_codec_fixture("cqe_lookup_final_fix_fixture", fixture,
                        fault_registry, status);
    if (status == null || !status.ok()) return;
    publish_one_cqe(fixture, status);
    if (status == null || !status.ok()) return;
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CQE,
            object_type:"cqe", variant:"default", opcode:8'h00};
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    fault_registry.arm_targeted_null_lookup_once(key);
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR ||
        completion != null ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("CQE_NULL_LOOKUP", $sformatf(
        "CQE null lookup crossed poll commit: status=%s hits=%0d",
        status == null ? "<null>" : status.convert2string(),
        fault_registry.null_lookup_status_hit_count()))
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used, has_pending);
    if (status == null || !status.ok() || used != 1 || has_pending)
      `uvm_error("CQE_NULL_LOOKUP_STATE", "CQE lookup changed CQ state")
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null)
      `uvm_error("CQE_NULL_LOOKUP_RETRY", $sformatf(
        "retained CQE was not consumable: status=%s",
        status == null ? "<null>" : status.convert2string()))

    setup_codec_fixture("cqe_decode_final_fix_fixture", fixture,
                        fault_registry, status);
    if (status == null || !status.ok()) return;
    publish_one_cqe(fixture, status);
    if (status == null || !status.ok()) return;
    null_decode = rdma_final_null_cqe_decode_codec::type_id::create(
      "null_cqe_decode");
    if (null_decode == null ||
        !fault_registry.replace_codec_for_test(key, null_decode, replaced)) begin
      `uvm_error("CQE_NULL_DECODE_SETUP", "cannot replace CQE codec")
      return;
    end
    original = replaced;
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR ||
        completion != null ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("CQE_NULL_DECODE", $sformatf(
        "CQE null decode crossed poll commit: status=%s",
        status == null ? "<null>" : status.convert2string()))
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used, has_pending);
    if (status == null || !status.ok() || used != 1 || has_pending)
      `uvm_error("CQE_NULL_DECODE_STATE", "CQE decode changed CQ state")
    if (!fault_registry.restore_codec_for_test(key, original))
      `uvm_error("CQE_NULL_DECODE_RESTORE", "cannot restore CQE codec")
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null)
      `uvm_error("CQE_NULL_DECODE_RETRY", $sformatf(
        "retained CQE was not consumable: status=%s",
        status == null ? "<null>" : status.convert2string()))
  endtask

  // 功能：run_entry_image_factory_fault 对 queue_entry_image 的一次 raw factory null
  //   注入执行真实 CQ poll，验证 allocation failure 非致命且不消费 entry。
  // 输入/输出及副作用：无显式输入；发布一条 CQE、安装精确 instance-name wrapper，
  //   比较公开 CQ occupancy 与 PCIe history，disarm 后正常 poll 清理。
  // 失败/边界：必须返回 RESOURCE_EXHAUSTED/result=null，factory fault 必须命中，
  //   CQ used 保持一且无 pending/MMIO；任何 simulator fatal 都是预期 RED。
  protected task automatic run_entry_image_factory_fault();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_consumer_fault_registry fault_registry;
    rdma_queue_completion_result completion;
    rdma_status status;
    int unsigned mmio_before;
    int unsigned used;
    bit has_pending;
    bit fired;

    setup_codec_fixture("entry_image_final_fix_fixture", fixture,
                        fault_registry, status);
    if (status == null || !status.ok()) return;
    publish_one_cqe(fixture, status);
    if (status == null || !status.ok()) return;
    configure_poll_factory_faults();
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    poll_image_fault.arm("queue_entry_image", 1'b0);
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    fired = poll_image_fault.fired();
    poll_image_fault.disarm();
    if (!fired || status == null ||
        status.code != RDMA_SC_RESOURCE_EXHAUSTED || completion != null ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("ENTRY_IMAGE_FACTORY", "entry image allocation was not fail closed")
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used, has_pending);
    if (status == null || !status.ok() || used != 1 || has_pending)
      `uvm_error("ENTRY_IMAGE_FACTORY_STATE", "entry allocation changed CQ state")
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null)
      `uvm_error("ENTRY_IMAGE_FACTORY_RETRY", "retained CQE was not consumable")
  endtask

  // 功能：publish_one_ceqe 在默认 fixture 的 CQ→CEQ route 上发布一条真实 CEQE。
  // 输入/输出及副作用：fixture 为输入、status 为输出；读取 CQ committed cursor 与
  //   CEQ polarity，经公开 publish_ceqe 写 backing 并推进 CEQ producer。
  // 失败/边界：cursor/model/publish 任一失败原样返回；result=null 的假成功转为
  //   INVALID_STATE，禁止 raw backing 写入替代 producer pipeline。
  protected task automatic publish_one_ceqe(
    rdma_queue_data_engine_fixture fixture,
    output rdma_status status
  );
    rdma_hw_ceqe_model ceqe;
    rdma_queue_device_publish_result published;
    rdma_status model_status;
    bit polarity;

    status = fixture.engine.query_runtime_producer_polarity(
      fixture.ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, polarity);
    if (status == null || !status.ok()) return;
    make_ceqe_from_committed_cq(
      fixture.engine, fixture.cq.handle, fixture.cq.local_cq_id, 0,
      polarity, ceqe, model_status);
    if (model_status == null || !model_status.ok() || ceqe == null) begin
      status = model_status;
      return;
    end
    fixture.engine.publish_ceqe(fixture.ceq.handle, ceqe, published, status);
    if (status != null && status.ok() && published == null)
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CEQE publish returned no result");
  endtask

  // 功能：run_ceqe_decode_fault 对精确 CEQE key 分别注入 lookup null 和 decode
  //   null status，验证 event result、credit 与 MMIO 原子性。
  // 输入/输出及副作用：无显式输入；两份 fixture 各发布真实 CEQE，读取 CEQ
  //   occupancy/PCIe history，恢复 codec 后正常 poll 消费 retained event。
  // 失败/边界：两类故障都必须 CODEC_ERROR/result=null、used=1/pending=0/MMIO 不增；
  //   registry 恢复失败或 retained event 不可消费均报告 UVM_ERROR。
  protected task automatic run_ceqe_decode_fault();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_consumer_fault_registry fault_registry;
    rdma_queue_consumer_codec_guard null_decode;
    rdma_queue_event_result event_result;
    rdma_codec_key key;
    rdma_codec_base original;
    rdma_codec_base replaced;
    rdma_status status;
    int unsigned mmio_before;
    int unsigned used;
    bit has_pending;

    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CEQE,
            object_type:"ceqe", variant:"default", opcode:8'h00};
    setup_codec_fixture("ceqe_lookup_final_fix_fixture", fixture,
                        fault_registry, status);
    if (status == null || !status.ok()) return;
    publish_one_ceqe(fixture, status);
    if (status == null || !status.ok()) return;
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    fault_registry.arm_targeted_null_lookup_once(key);
    fixture.engine.poll_ceqe(fixture.ceq.handle, 0, event_result, status);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR ||
        event_result != null ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("CEQE_NULL_LOOKUP", "CEQE null lookup crossed poll commit")
    status = fixture.engine.query_runtime_occupancy(
      fixture.ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, used, has_pending);
    if (status == null || !status.ok() || used != 1 || has_pending)
      `uvm_error("CEQE_NULL_LOOKUP_STATE", "CEQE lookup changed CEQ state")
    fixture.engine.poll_ceqe(fixture.ceq.handle, 0, event_result, status);

    setup_codec_fixture("ceqe_decode_final_fix_fixture", fixture,
                        fault_registry, status);
    if (status == null || !status.ok()) return;
    publish_one_ceqe(fixture, status);
    if (status == null || !status.ok()) return;
    status = fault_registry.lookup(key, original);
    null_decode = new("null_ceqe_decode", original);
    null_decode.block_decode = 1'b1;
    null_decode.injected_error = null;
    if (status == null || !status.ok() || original == null ||
        !fault_registry.replace_codec_for_test(key, null_decode, replaced)) begin
      `uvm_error("CEQE_NULL_DECODE_SETUP", "cannot replace CEQE codec")
      return;
    end
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    event_result = null;
    fixture.engine.poll_ceqe(fixture.ceq.handle, 0, event_result, status);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR ||
        event_result != null ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("CEQE_NULL_DECODE", "CEQE null decode crossed poll commit")
    status = fixture.engine.query_runtime_occupancy(
      fixture.ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, used, has_pending);
    if (status == null || !status.ok() || used != 1 || has_pending)
      `uvm_error("CEQE_NULL_DECODE_STATE", "CEQE decode changed CEQ state")
    if (!fault_registry.restore_codec_for_test(key, original))
      `uvm_error("CEQE_NULL_DECODE_RESTORE", "cannot restore CEQE codec")
    fixture.engine.poll_ceqe(fixture.ceq.handle, 0, event_result, status);
    if (status == null || !status.ok() || event_result == null)
      `uvm_error("CEQE_NULL_DECODE_RETRY", "retained CEQE was not consumable")
  endtask

  // 功能：publish_one_aeqe 创建并 attach 一个非零 local_qp_id 的 event QP，构造
  //   指向该真实 route 的 AEQE 并发布到 fixture AEQ。
  // 输入/输出及副作用：fixture 为输入，event_qp/status 为输出；成功新增 fixture
  //   持有的 transport QP、engine 非拥有 link，并写 AEQ backing/推进 producer。
  // 失败/边界：transport QP、attach、model/handle/polarity/publish 任一失败原样返回；
  //   base QP 的 local_qp_id=0 不得冒充合法 AEQE target，调用方须 detach event_qp。
  protected task automatic publish_one_aeqe(
    rdma_queue_data_engine_fixture fixture,
    output rdma_qp event_qp,
    output rdma_status status
  );
    rdma_hw_aeqe_model aeqe;
    rdma_queue_device_publish_result published;
    rdma_status clone_status;
    bit polarity;

    event_qp = null;
    fixture.setup_transport_qps(status);
    if (status == null || !status.ok() || fixture.ud_qp == null ||
        fixture.ud_qp.handle == null || fixture.ud_qp.local_qp_id == 0) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "AEQE event QP is unavailable");
      return;
    end
    event_qp = fixture.ud_qp;
    status = fixture.engine.attach_qp(event_qp.handle);
    if (status == null || !status.ok()) return;
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
    if (status == null || !status.ok()) return;
    aeqe = rdma_hw_aeqe_model::type_id::create("final_fix_aeqe");
    if (aeqe == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "AEQE model allocation failed");
      return;
    end
    clone_status = clone_test_handle_value(event_qp.handle, aeqe.target_h);
    if (clone_status == null || !clone_status.ok() || aeqe.target_h == null) begin
      status = clone_status;
      return;
    end
    aeqe.qpn = event_qp.local_qp_id;
    aeqe.valid = polarity;
    aeqe.ecode = 0;
    aeqe.packet_opcode = 0;
    fixture.engine.publish_aeqe(fixture.aeq.handle, aeqe, published, status);
    if (status != null && status.ok() && published == null)
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "AEQE publish returned no result");
  endtask

  // 功能：run_aeqe_decode_fault 对精确 AEQE key 分别注入 lookup null 和 decode
  //   null status，验证 async event 不会被错误消费。
  // 输入/输出及副作用：无显式输入；两份 fixture 各发布真实 AEQE，读取 AEQ
  //   occupancy/PCIe history，恢复 codec 后正常 poll 消费 retained event。
  // 失败/边界：两类故障都必须 CODEC_ERROR/result=null、used=1/pending=0/MMIO 不增；
  //   QP route 与 backing 生命周期仍由 fixture 保持，不因故障转移所有权。
  protected task automatic run_aeqe_decode_fault();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_consumer_fault_registry fault_registry;
    rdma_queue_consumer_codec_guard null_decode;
    rdma_queue_event_result event_result;
    rdma_qp event_qp;
    rdma_codec_key key;
    rdma_codec_base original;
    rdma_codec_base replaced;
    rdma_status status;
    int unsigned mmio_before;
    int unsigned used;
    bit has_pending;

    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_AEQE,
            object_type:"aeqe", variant:"default", opcode:8'h00};
    setup_codec_fixture("aeqe_lookup_final_fix_fixture", fixture,
                        fault_registry, status);
    if (status == null || !status.ok()) begin
      `uvm_error("AEQE_LOOKUP_SETUP", "AEQE lookup fixture setup failed")
      return;
    end
    publish_one_aeqe(fixture, event_qp, status);
    if (status == null || !status.ok()) begin
      `uvm_error("AEQE_LOOKUP_PUBLISH", "AEQE lookup fixture publish failed")
      return;
    end
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    fault_registry.arm_targeted_null_lookup_once(key);
    fixture.engine.poll_aeqe(fixture.aeq.handle, 0, event_result, status);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR ||
        event_result != null ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("AEQE_NULL_LOOKUP", "AEQE null lookup crossed poll commit")
    status = fixture.engine.query_runtime_occupancy(
      fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, used, has_pending);
    if (status == null || !status.ok() || used != 1 || has_pending)
      `uvm_error("AEQE_NULL_LOOKUP_STATE", "AEQE lookup changed AEQ state")
    fixture.engine.poll_aeqe(fixture.aeq.handle, 0, event_result, status);
    status = fixture.engine.detach(event_qp.handle);
    if (status == null || !status.ok())
      `uvm_error("AEQE_LOOKUP_QP_DETACH", "AEQE lookup event QP detach failed")

    setup_codec_fixture("aeqe_decode_final_fix_fixture", fixture,
                        fault_registry, status);
    if (status == null || !status.ok()) begin
      `uvm_error("AEQE_DECODE_SETUP", "AEQE decode fixture setup failed")
      return;
    end
    publish_one_aeqe(fixture, event_qp, status);
    if (status == null || !status.ok()) begin
      `uvm_error("AEQE_DECODE_PUBLISH", "AEQE decode fixture publish failed")
      return;
    end
    status = fault_registry.lookup(key, original);
    null_decode = new("null_aeqe_decode", original);
    null_decode.block_decode = 1'b1;
    null_decode.injected_error = null;
    if (status == null || !status.ok() || original == null ||
        !fault_registry.replace_codec_for_test(key, null_decode, replaced)) begin
      `uvm_error("AEQE_NULL_DECODE_SETUP", "cannot replace AEQE codec")
      return;
    end
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    event_result = null;
    fixture.engine.poll_aeqe(fixture.aeq.handle, 0, event_result, status);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR ||
        event_result != null ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before)
      `uvm_error("AEQE_NULL_DECODE", "AEQE null decode crossed poll commit")
    status = fixture.engine.query_runtime_occupancy(
      fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, used, has_pending);
    if (status == null || !status.ok() || used != 1 || has_pending)
      `uvm_error("AEQE_NULL_DECODE_STATE", "AEQE decode changed AEQ state")
    if (!fault_registry.restore_codec_for_test(key, original))
      `uvm_error("AEQE_NULL_DECODE_RESTORE", "cannot restore AEQE codec")
    fixture.engine.poll_aeqe(fixture.aeq.handle, 0, event_result, status);
    if (status == null || !status.ok() || event_result == null)
      `uvm_error("AEQE_NULL_DECODE_RETRY", "retained AEQE was not consumable")
    status = fixture.engine.detach(event_qp.handle);
    if (status == null || !status.ok())
      `uvm_error("AEQE_DECODE_QP_DETACH", "AEQE decode event QP detach failed")
  endtask

  // 功能：finish_final_fix_test 清理本 concrete test 登记的全部 lifecycle fixture。
  // 输入/输出及副作用：无显式输入；调用父类统一 cleanup，释放 attachment 与资源。
  // 失败/边界：cleanup null/非成功时报告 UVM_ERROR，但始终由 concrete run_phase
  //   归还 objection，避免测试错误造成仿真悬挂。
  protected task automatic finish_final_fix_test();
    rdma_status cleanup_status;

    reset_device_publish_factory_state();
    cleanup_tracked_fixtures(cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error("FINAL_FIX_CLEANUP", "final-fix fixture cleanup failed")
  endtask
endclass

class rdma_queue_host_codec_final_fix_test
  extends rdma_queue_data_engine_final_fix_test_base;
  `uvm_component_utils(rdma_queue_host_codec_final_fix_test)

  // 功能：构造 host codec final-fix concrete UVM test。
  // 输入/输出及副作用：name/parent 为输入；只建立层级，不创建 fixture。
  // 失败/边界：资源建立/清理由 run_phase 成对负责。
  function new(string name = "rdma_queue_host_codec_final_fix_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行 SQE lookup/encode/null-codec fail-closed 矩阵并统一清理。
  // 输入/输出及副作用：phase 为输入；raise/drop 一次 objection，运行真实 post_send。
  // 失败/边界：任一断言通过 UVM_ERROR 反映，cleanup 后无条件 drop objection。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_host_codec_faults();
    finish_final_fix_test();
    phase.drop_objection(this);
  endtask
endclass

class rdma_queue_producer_doorbell_final_fix_test
  extends rdma_queue_data_engine_final_fix_test_base;
  `uvm_component_utils(rdma_queue_producer_doorbell_final_fix_test)

  // 功能：构造 producer doorbell final-fix concrete UVM test。
  // 输入/输出及副作用：name/parent 为输入；只建立层级，不修改 registry。
  // 失败/边界：未进入 run_phase 时无外部副作用。
  function new(string name = "rdma_queue_producer_doorbell_final_fix_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行 producer doorbell null-lookup recovery 场景并统一清理。
  // 输入/输出及副作用：phase 为输入；raise/drop objection，可能显式 abort QP。
  // 失败/边界：任何未闭环 recovery 由 cleanup/UVM summary 暴露。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_producer_doorbell_fault();
    finish_final_fix_test();
    phase.drop_objection(this);
  endtask
endclass

class rdma_queue_host_producer_failure_final_fix_test
  extends rdma_queue_data_engine_final_fix_test_base;
  `uvm_component_utils(rdma_queue_host_producer_failure_final_fix_test)

  // 功能：构造 host-producer hostile failure concrete UVM test，沿用 final-fix
  //   基类的 fixture factory、tracked lifecycle 和 cleanup 入口。
  // 输入/输出及副作用：name/parent 为输入；只建立 UVM component 层级，不创建
  //   queue、mapping、Host-memory 或 PCIe 资源。
  // 失败/边界：构造阶段不 arm 任一 fault；所有 fixture 与故障窗口由 run_phase
  //   成对建立/关闭，未执行测试时不得遗留外部状态。
  function new(string name = "rdma_queue_host_producer_failure_final_fix_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行 host producer WQE write/readback 与 doorbell barrier/MMIO 的完整
  //   hostile failure matrix，并在每个 case 后通过显式 abort 收敛 recovery。
  // 输入/输出及副作用：phase 为输入；task 管理 objection，驱动真实 post_send
  //   和公开 recovery API，不直接修改 runtime 私有字段。
  // 失败/边界：任一阶段的 status/evidence/cursor/调用顺序不满足契约由 matrix
  //   任务报告 UVM_ERROR；cleanup 失败仍由基类报告且始终 drop objection。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_host_producer_hostile_matrix();
    finish_final_fix_test();
    phase.drop_objection(this);
  endtask
endclass

class rdma_queue_host_producer_commit_failure_test
  extends rdma_queue_data_engine_final_fix_test_base;
  `uvm_component_utils(rdma_queue_host_producer_commit_failure_test)

  // 功能：构造 host-producer ledger commit failure concrete test。
  // 输入/输出及副作用：name/parent 为输入；只建立 UVM component 层级，不创建
  //   queue、mapping、Host-memory 或 PCIe 资源。
  // 失败/边界：构造阶段不 arm commit fault；所有 fixture、pending 与 factory
  //   override 均由 run_phase 成对建立和清理。
  function new(string name = "rdma_queue_host_producer_commit_failure_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行一次 WQE/doorbell 成功后 ledger commit 拒绝的 recovery contract，
  //   并用公开 abort 释放故障 fixture。
  // 输入/输出及副作用：phase 为输入；task 管理 objection，驱动真实 post_send、
  //   query_runtime_pending 和 recover_queue，不直接改写 runtime 私有状态。
  // 失败/边界：任一 commit 调用次数、I/O 序列、cursor/used、pending evidence 或
  //   abort 不满足契约均由 UVM_ERROR 报告，cleanup 仍必须执行。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_host_producer_commit_fault();
    finish_final_fix_test();
    phase.drop_objection(this);
  endtask
endclass

class rdma_queue_cqe_codec_final_fix_test
  extends rdma_queue_data_engine_final_fix_test_base;
  `uvm_component_utils(rdma_queue_cqe_codec_final_fix_test)

  // 功能：构造 CQE codec final-fix concrete UVM test。
  // 输入/输出及副作用：name/parent 为输入；只建立层级。
  // 失败/边界：具体 codec override 只在 run_phase fixture 内存活。
  function new(string name = "rdma_queue_cqe_codec_final_fix_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行 CQE lookup/decode fail-closed 场景并统一清理。
  // 输入/输出及副作用：phase 为输入；消费真实 CQE，仅成功 retry 推进 CI/release。
  // 失败/边界：故障 poll 的任何 MMIO/cursor/credit 变化均报告错误。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_cqe_decode_fault();
    finish_final_fix_test();
    phase.drop_objection(this);
  endtask
endclass

class rdma_queue_entry_image_final_fix_test
  extends rdma_queue_data_engine_final_fix_test_base;
  `uvm_component_utils(rdma_queue_entry_image_final_fix_test)

  // 功能：构造 entry-image factory final-fix concrete UVM test。
  // 输入/输出及副作用：name/parent 为输入；只建立层级。
  // 失败/边界：factory fault 由 run_phase 精确 arm/disarm。
  function new(string name = "rdma_queue_entry_image_final_fix_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行 queue_entry_image null allocation 的非致命原子性场景。
  // 输入/输出及副作用：phase 为输入；raise/drop objection，故障后正常消费 CQE。
  // 失败/边界：simulator fatal 或 CQE 被消费均使本 test RED。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_entry_image_factory_fault();
    finish_final_fix_test();
    phase.drop_objection(this);
  endtask
endclass

class rdma_queue_ceqe_codec_final_fix_test
  extends rdma_queue_data_engine_final_fix_test_base;
  `uvm_component_utils(rdma_queue_ceqe_codec_final_fix_test)

  // 功能：构造 CEQE codec final-fix concrete UVM test。
  // 输入/输出及副作用：name/parent 为输入；只建立层级。
  // 失败/边界：codec override 不跨越本仿真进程。
  function new(string name = "rdma_queue_ceqe_codec_final_fix_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行 CEQE lookup/decode fail-closed 场景并统一清理。
  // 输入/输出及副作用：phase 为输入；仅正常 retry 推进 CEQ CI。
  // 失败/边界：故障 poll 发布 event 或发送 MMIO 时报告错误。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_ceqe_decode_fault();
    finish_final_fix_test();
    phase.drop_objection(this);
  endtask
endclass

class rdma_queue_aeqe_codec_final_fix_test
  extends rdma_queue_data_engine_final_fix_test_base;
  `uvm_component_utils(rdma_queue_aeqe_codec_final_fix_test)

  // 功能：构造 AEQE codec final-fix concrete UVM test。
  // 输入/输出及副作用：name/parent 为输入；只建立层级。
  // 失败/边界：fixture 与 override 由 run_phase/cleanup 限定生命周期。
  function new(string name = "rdma_queue_aeqe_codec_final_fix_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行 AEQE lookup/decode fail-closed 场景并统一清理。
  // 输入/输出及副作用：phase 为输入；仅正常 retry 推进 AEQ CI。
  // 失败/边界：故障 poll 发布 event、改变 credit 或发送 MMIO 时报告错误。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_aeqe_decode_fault();
    finish_final_fix_test();
    phase.drop_objection(this);
  endtask
endclass

class rdma_queue_recovery_lifecycle_final_fix_test
  extends rdma_queue_data_engine_device_publish_test;
  `uvm_component_utils(rdma_queue_recovery_lifecycle_final_fix_test)

  // 功能：构造 recovery lifecycle final-fix concrete UVM test。
  // 输入/输出及副作用：name/parent 为输入；只建立父类 fault/fixture 容器。
  // 失败/边界：未运行 run_phase 时不创建 queue 或 recovery evidence。
  function new(string name = "rdma_queue_recovery_lifecycle_final_fix_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行 claimed、unclaimed、reservation-only 的普通 detach/reconfigure 与
  //   精确 abort status 场景，再统一清理所有 lifecycle fixture。
  // 输入/输出及副作用：phase 为输入；建立真实 pending/reservation/backing evidence，
  //   只通过公开 detach/configure/recover/query API 观察和解决恢复状态。
  // 失败/边界：任一普通路径绕过 recovery、错误码被覆盖或 abort 后仍不可重配均
  //   报告 UVM_ERROR；cleanup 完成后无条件 drop objection。
  task run_phase(uvm_phase phase);
    rdma_status cleanup_status;

    phase.raise_objection(this);
    reset_device_publish_factory_state();
    check_unclaimed_pending_abort();
    reset_device_publish_factory_state();
    check_claimed_abort_detach_failure_atomicity();
    reset_device_publish_factory_state();
    check_reservation_only_detach_reconfigure();
    reset_device_publish_factory_state();
    cleanup_tracked_fixtures(cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error("RECOVERY_LIFECYCLE_CLEANUP",
                 "recovery lifecycle fixture cleanup failed")
    phase.drop_objection(this);
  endtask
endclass

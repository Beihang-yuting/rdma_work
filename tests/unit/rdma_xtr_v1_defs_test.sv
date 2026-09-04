// 目录：测试层 unit/rdma_xtr_v1_defs_test.sv。
// 职责：验证 rdma_xtr_v1_defs_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_xtr_v1_defs_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_defs_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_defs_test)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_defs_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function void check_context_golden();
    rdma_xtr_v1_golden_case cases[$];
    string error;
    string expected_names[13] = '{
      "qpc_rc_boundary", "qpc_ud_boundary", "qpc_urc_boundary",
      "cqc_create_body_boundary", "mrt_register_pbl0_boundary",
      "mrt_register_pbl1_boundary", "mrt_register_pbl2_boundary",
      "mrt_key_alloc_pbl0_boundary", "mrt_key_alloc_pbl1_boundary",
      "mrt_key_alloc_pbl2_boundary", "srqc_create_body_boundary",
      "ceqc_create_body_boundary", "aeqc_create_body_boundary"
    };

    if (!rdma_xtr_v1_golden_reader::read_all(
          "../hw/xtr_v1/golden_vectors/context.hex", cases, error)) begin
      `uvm_error("GOLDEN", error)
      return;
    end
    if (cases.size() != 13) begin
      `uvm_error("GOLDEN", $sformatf("context case count %0d, expected 13",
                                     cases.size()))
      return;
    end
    foreach (cases[index]) begin
      int expected_bytes = (index < 3) ? 512 : 64;
      if (cases[index].name != expected_names[index])
        `uvm_error("GOLDEN", $sformatf("case %0d name %s", index,
                                       cases[index].name))
      if (cases[index].inputs.len() == 0)
        `uvm_error("GOLDEN", $sformatf("case %s has empty inputs",
                                       cases[index].name))
      if (cases[index].byte_count != expected_bytes ||
          cases[index].payload.size() != expected_bytes)
        `uvm_error("GOLDEN", $sformatf("case %s byte count mismatch",
                                       cases[index].name))
      foreach (cases[index].payload[byte_index]) begin
        if (!$isunknown(cases[index].payload[byte_index])) begin
          // Walking every byte is deliberate: truncated or malformed payloads
          // must not be hidden by a first-byte-only smoke check.
        end else begin
          `uvm_error("GOLDEN", $sformatf("case %s byte %0d is unknown",
                                         cases[index].name, byte_index))
        end
      end
    end
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  task automatic check_read_all_rejection(
      string path,
      string contents,
      string label);
    int fd;
    int status;
    rdma_xtr_v1_golden_case cases[$];
    rdma_xtr_v1_golden_case seed;
    string error;

    fd = $fopen(path, "w");
    if (fd == 0) begin
      `uvm_error("GOLDEN_GRAMMAR", $sformatf("cannot create %s", path))
      return;
    end
    $fwrite(fd, "%s", contents);
    $fclose(fd);

    seed = new();
    seed.name = "seed_must_not_survive_failure";
    cases.push_back(seed);
    if (rdma_xtr_v1_golden_reader::read_all(path, cases, error))
      `uvm_error("GOLDEN_GRAMMAR", {label, " was accepted"})
    if (cases.size() != 0)
      `uvm_error("GOLDEN_GRAMMAR",
                 $sformatf("%s left %0d partially parsed cases", label,
                           cases.size()))
    status = $system($sformatf("rm -f -- %s", path));
    if (status != 0)
      `uvm_error("GOLDEN_GRAMMAR", $sformatf("cannot remove %s", path))
  endtask

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  task check_golden_reader_rejections();
    byte unsigned payload[];
    rdma_status_code_e payload_status;
    int status;
    string parsed_name;
    string error;
    string reject_dir;
    string valid_case;

    if (rdma_xtr_v1_golden_reader::MAX_PAYLOAD_BYTES != 512)
      `uvm_error("GOLDEN_GRAMMAR", "golden reader payload limit")

    payload = new[1];
    payload[0] = 8'h5a;
    payload_status = rdma_xtr_v1_golden_reader::parse_payload_line(
        "0\n", 32'd1431655766, payload, error);
    if (payload_status != RDMA_SC_CODEC_ERROR)
      `uvm_error("GOLDEN_GRAMMAR", "wraparound byte count was accepted")
    if (payload.size() != 0)
      `uvm_error("GOLDEN_GRAMMAR",
                 "wraparound byte count left a partially parsed payload")

    payload_status = rdma_xtr_v1_golden_reader::parse_payload_line(
        "AA\n", 1, payload, error);
    if (payload_status == RDMA_SC_OK)
      `uvm_error("GOLDEN_GRAMMAR", "uppercase hex was accepted")
    payload_status = rdma_xtr_v1_golden_reader::parse_payload_line(
        "0g\n", 1, payload, error);
    if (payload_status == RDMA_SC_OK)
      `uvm_error("GOLDEN_GRAMMAR", "partial hex token was accepted")
    payload_status = rdma_xtr_v1_golden_reader::parse_payload_line(
        "00  01\n", 2, payload, error);
    if (payload_status == RDMA_SC_OK)
      `uvm_error("GOLDEN_GRAMMAR", "noncanonical byte spacing was accepted")
    if (rdma_xtr_v1_golden_reader::parse_case_line(
          "# case: Qpc_rc_boundary\n", parsed_name, error))
      `uvm_error("GOLDEN_GRAMMAR", "uppercase case name was accepted")
    if (rdma_xtr_v1_golden_reader::parse_case_line(
          "# case: qpc-rc-boundary\n", parsed_name, error))
      `uvm_error("GOLDEN_GRAMMAR", "punctuated case name was accepted")

    valid_case = {"# xtr_v1-golden-v1\n",
                  "# case: first\n",
                  "# inputs: value=1\n",
                  "# bytes: 1\n",
                  "00\n"};
    status = 1;
    for (int unsigned attempt = 0; attempt < 64 && status != 0; attempt++) begin
      reject_dir = $sformatf("/tmp/rdma_xtr_v1_defs_test.%08x",
                             $urandom());
      status = $system($sformatf("mkdir -m 700 -- %s 2>/dev/null",
                                 reject_dir));
    end
    if (status != 0) begin
      `uvm_error("GOLDEN_GRAMMAR",
                 $sformatf("cannot create reject fixture directory %s",
                           reject_dir))
      return;
    end
    check_read_all_rejection(
        {reject_dir, "/duplicate.hex"},
        {valid_case, "\n# xtr_v1-golden-v1\n",
         "# case: first\n",
         "# inputs: value=2\n",
         "# bytes: 1\n",
         "01\n"},
        "duplicate case name");
    check_read_all_rejection(
        {reject_dir, "/truncated.hex"},
        {"# xtr_v1-golden-v1\n",
         "# case: truncated\n",
         "# inputs: value=1\n",
         "# bytes: 2\n",
         "00\n"},
        "truncated payload");
    check_read_all_rejection(
        {reject_dir, "/extra.hex"},
        {"# xtr_v1-golden-v1\n",
         "# case: extra\n",
         "# inputs: value=1\n",
         "# bytes: 1\n",
         "00 01\n"},
        "extra payload byte");
    check_read_all_rejection(
        {reject_dir, "/incomplete.hex"},
        {valid_case, "\n# xtr_v1-golden-v1\n",
         "# case: incomplete\n",
         "# inputs: value=2\n",
         "# bytes: 1\n"},
        "incomplete trailing case");
    status = $system($sformatf("rmdir -- %s", reject_dir));
    if (status != 0)
      `uvm_error("GOLDEN_GRAMMAR",
                 $sformatf("cannot remove reject fixture directory %s",
                           reject_dir))
  endtask

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function void check_mask_lookup_api();
    bit [63:0] mask_value;
    rdma_image_kind_e image_kinds[8] = '{
      RDMA_IMAGE_CQC,
      RDMA_IMAGE_MRT, RDMA_IMAGE_MRT, RDMA_IMAGE_MRT, RDMA_IMAGE_MRT,
      RDMA_IMAGE_SRQC, RDMA_IMAGE_CEQC, RDMA_IMAGE_AEQC
    };
    bit [7:0] opcodes[8] = '{
      XTR_V1_OP_CQC_CREATE,
      XTR_V1_OP_KEY_ALLOC, XTR_V1_OP_MR_REGISTER,
      XTR_V1_OP_MR_REGISTER, XTR_V1_OP_MR_REGISTER,
      XTR_V1_OP_SRFQC_CREATE, XTR_V1_OP_CEQC_CREATE,
      XTR_V1_OP_AEQC_CREATE
    };
    int unsigned pbl_modes[8] = '{0, 0, 0, 1, 2, 0, 0, 0};
    string labels[8] = '{
      "CQC create", "MRT key allocate PBL0", "MRT register PBL0",
      "MRT register PBL1", "MRT register PBL2", "SRQC create",
      "CEQC create", "AEQC create"
    };
    bit [63:0] expected_masks[8][8] = '{
      '{64'h00000000001fffff, 64'hff0fffffffffffff,
        64'hfffffffffffff8ff, 64'hfffffffffff8c701,
        64'hf000000000ffffff, 64'h0000000000000fff,
        64'hffffffffffffffc0, 64'h0000000f00ffffff},
      '{64'h6000000000ffffff, 64'h00000000ff000000,
        64'hffffffffffffffff, 64'hff00bfffffffffff,
        64'hffffffffffffffff, 64'hfffffffffffff000,
        64'h0000000000000fff, 64'h0000000000000000},
      '{64'h6000000000ffffff, 64'h00000000ff000000,
        64'hffffffffff000000, 64'hff00bfffffffffff,
        64'hffffffffffffffff, 64'hfffffffffffff000,
        64'h0000000000000fff, 64'h0000000000000000},
      '{64'h6000000000ffffff, 64'h00000000ff000000,
        64'hffffffffff000000, 64'hff00bfffffffffff,
        64'hffffffffffffffff, 64'hfffffffffffff000,
        64'hffffffffffffffff, 64'h0000000000000000},
      '{64'h6000000000ffffff, 64'h00000000ff000000,
        64'hffffffffff000000, 64'hff00bfffffffffff,
        64'hffffffffffffffff, 64'hfffffff000000000,
        64'h0000000000000fff, 64'h0000000000000000},
      '{64'h000000000000ffff, 64'h0000000000000000,
        64'hcfffffffffffffff, 64'hffff000000000000,
        64'hfffffffffffff0fc, 64'h00000000ffffffff,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h0000000000000fff, 64'h0000000000000000,
        64'hc1ffffffffffffff, 64'hfffffffffffff800,
        64'h0000007ffff0c000, 64'hffff00000007ffff,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h0000000000000fff, 64'h0000000000000000,
        64'hc1ffffffffffffff, 64'hfffffffffffff800,
        64'h0000007ffff0c000, 64'hffff00000007ffff,
        64'h0000000000000000, 64'h0000000000000000}
    };

    if (request_envelope_mask(0) != 64'h8fff3fff00000000 ||
        request_envelope_mask(1) != 0 || request_envelope_mask(8) != 0)
      `uvm_error("MASK_API", "request envelope qword lookup")

    foreach (image_kinds[case_index]) begin
      for (int unsigned qword_index = 0; qword_index < 8;
           qword_index++) begin
        mask_value = '1;
        if (!body_mask(image_kinds[case_index], opcodes[case_index],
                       pbl_modes[case_index], qword_index, mask_value)) begin
          `uvm_error("MASK_API",
                     $sformatf("%s qword %0d was rejected",
                               labels[case_index], qword_index))
        end else if (mask_value != expected_masks[case_index][qword_index]) begin
          `uvm_error("MASK_API",
                     $sformatf("%s qword %0d mask 0x%016x, expected 0x%016x",
                               labels[case_index], qword_index, mask_value,
                               expected_masks[case_index][qword_index]))
        end
      end
    end

    mask_value = '1;
    if (body_mask(RDMA_IMAGE_CQC, XTR_V1_OP_AEQC_CREATE, 0, 0,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_API", "unsupported opcode was accepted")
    mask_value = '1;
    if (body_mask(RDMA_IMAGE_MRT, XTR_V1_OP_MR_REGISTER, 3, 0,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_API", "unsupported PBL mode was accepted")
    mask_value = '1;
    if (body_mask(RDMA_IMAGE_QPC, XTR_V1_OP_QPC_CREATE, 0, 0,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_API", "unsupported image kind was accepted")
    mask_value = '1;
    if (body_mask(RDMA_IMAGE_MRT, XTR_V1_OP_MR_REGISTER, 0, 8,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_API", "out-of-range qword was accepted")
  endfunction

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    if (XTR_V1_HW_VERSION != 1 || XTR_V1_QPC_BYTES != 512)
      `uvm_error("DEFS", "QPC size")
    if (XTR_V1_CQC_BYTES != 64)
      `uvm_error("DEFS", "CQC size")
    if (XTR_V1_CMQE_BYTES != 64 || XTR_V1_WQE_BYTES != 64)
      `uvm_error("DEFS", "entry size")
    if (XTR_V1_OP_QPC_CREATE != 8'h00 ||
        XTR_V1_OP_KEY_ALLOC != 8'h04 ||
        XTR_V1_OP_OCC_FLUSH != 8'h0a ||
        XTR_V1_OP_CQC_CREATE != 8'h0c ||
        XTR_V1_OP_CEQC_DELETE != 8'h12 ||
        XTR_V1_OP_CEQC_QUERY != 8'h13 ||
        XTR_V1_OP_AEQC_DELETE != 8'h16 ||
        XTR_V1_OP_AEQC_QUERY != 8'h17 ||
        XTR_V1_OP_TQ_FLUSH != 8'h20 ||
        XTR_V1_OP_SRFQC_CREATE != 8'h35)
      `uvm_error("DEFS", "CMQ opcode")
    if (XTR_V1_ALLOC_TYPE_DIRECT != 0 ||
        XTR_V1_ALLOC_TYPE_INDIRECT != 1 ||
        XTR_V1_ALLOC_TYPE_HUGE != 2 ||
        XTR_V1_ALLOC_TYPE_L3_INDIRECT != 3 ||
        XTR_V1_ADDR_TYPE_VA_BASED != 0 ||
        XTR_V1_ADDR_TYPE_ZERO_BASED != 1 ||
        XTR_V1_MR_ST_INVALID != 0 || XTR_V1_MR_ST_FREE != 1 ||
        XTR_V1_MR_ST_VALID != 2 || XTR_V1_HOST_PAGE_4K != 0 ||
        XTR_V1_HOST_PAGE_2M != 1 || XTR_V1_HOST_PAGE_1G != 2 ||
        XTR_V1_PBL_MODE_0 != 0 || XTR_V1_PBL_MODE_1 != 1 ||
        XTR_V1_PBL_MODE_2 != 2 || XTR_V1_MEM_TYPE_MR != 0 ||
        XTR_V1_MEM_TYPE_MW_TYPE1 != 1 || XTR_V1_MEM_TYPE_MW_TYPE2B != 2 ||
        XTR_V1_RIGHT_LOCAL_WRITE != 5'h01 ||
        XTR_V1_RIGHT_REMOTE_READ != 5'h02 ||
        XTR_V1_RIGHT_REMOTE_WRITE != 5'h04 ||
        XTR_V1_RIGHT_BIND_WINDOW != 5'h08 ||
        XTR_V1_RIGHT_REMOTE_ATOMIC != 5'h10)
      `uvm_error("DEFS", "context object/state/mode/right values")
    if (XTR_V1_NOTIFY_WINDOW_OFFSET != 64'h2000 ||
        XTR_V1_NOTIFY_WINDOW_SIZE != 64'h2000)
      `uvm_error("DEFS", "notify window")

    if (XTR_V1_QPC_QPN_OFFSET != 16 || XTR_V1_QPC_QPN_WIDTH != 21)
      `uvm_error("DEFS", "QPC QPN field")
    if (XTR_V1_QPC_URC_RSQ_SIZE_WORD_BYTE_OFFSET != 24 ||
        XTR_V1_QPC_URC_RSQ_SIZE_LSB != 59 ||
        XTR_V1_QPC_URC_RSQ_SIZE_WIDTH != 3 ||
        XTR_V1_QPC_URC_RSQ_SIZE_OFFSET != 251)
      `uvm_error("DEFS", "URC RSQ size field")
    if (XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM_WORD_BYTE_OFFSET != 224 ||
        XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM_LSB != 16 ||
        XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM_WIDTH != 6 ||
        XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM_OFFSET != 1808)
      `uvm_error("DEFS", "URC RDSQ fetch field")
    if (XTR_V1_CMQ_OPCODE_OFFSET != 32 ||
        XTR_V1_CMQ_OPCODE_WIDTH != 8)
      `uvm_error("DEFS", "CMQ opcode field")
    if (XTR_V1_SQ_WQE_OPCODE_OFFSET != 32 ||
        XTR_V1_SQ_WQE_OPCODE_WIDTH != 4 ||
        XTR_V1_CQE_QPN_OFFSET != 0 || XTR_V1_CQE_QPN_WIDTH != 18)
      `uvm_error("DEFS", "queue representative fields")
    if (XTR_V1_CMQ_DB_PI_OFFSET != 32 || XTR_V1_CMQ_DB_PI_WIDTH != 5 ||
        XTR_V1_NOTIFY_CQ_CQN_OFFSET != 0 ||
        XTR_V1_NOTIFY_CQ_CQN_WIDTH != 21)
      `uvm_error("DEFS", "doorbell representative fields")

    if (XTR_V1_CMQ_ENVELOPE_MASK[0] != 64'h8fff3fff00000000 ||
        XTR_V1_CQC_CREATE_BODY_MASK[0] != 64'h00000000001fffff ||
        XTR_V1_MRT_KEY_ALLOC_PBL0_BODY_MASK[2] != 64'hffffffffffffffff)
      `uvm_error("DEFS", "image masks")

    check_mask_lookup_api();
    check_golden_reader_rejections();
    check_context_golden();

    phase.drop_objection(this);
  endtask
endclass

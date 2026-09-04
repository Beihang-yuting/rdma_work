// 目录：测试层 unit/rdma_defs_test.sv。
// 职责：验证 rdma_defs_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_defs_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_defs_test extends uvm_test;
  `uvm_component_utils(rdma_defs_test)

  // 功能：构造 rdma_defs_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_defs_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_defs_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在测试辅助 rdma_defs_test.check_context_golden 中构造或驱动“context golden”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function void check_context_golden();
    rdma_golden_case cases[$];
    string error;
    string expected_names[13] = '{
      "qpc_rc_boundary", "qpc_ud_boundary", "qpc_urc_boundary",
      "cqc_create_body_boundary", "mrt_register_pbl0_boundary",
      "mrt_register_pbl1_boundary", "mrt_register_pbl2_boundary",
      "mrt_key_alloc_pbl0_boundary", "mrt_key_alloc_pbl1_boundary",
      "mrt_key_alloc_pbl2_boundary", "srqc_create_body_boundary",
      "ceqc_create_body_boundary", "aeqc_create_body_boundary"
    };

    if (!rdma_golden_reader::read_all(
          "../hw/rdma/golden_vectors/context.hex", cases, error)) begin
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

  // 功能：在测试辅助 rdma_defs_test.check_read_all_rejection 中构造或驱动“read all rejection”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：path（输入）、contents（输入）、label（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_read_all_rejection(
      string path,
      string contents,
      string label);
    int fd;
    int status;
    rdma_golden_case cases[$];
    rdma_golden_case seed;
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
    if (rdma_golden_reader::read_all(path, cases, error))
      `uvm_error("GOLDEN_GRAMMAR", {label, " was accepted"})
    if (cases.size() != 0)
      `uvm_error("GOLDEN_GRAMMAR",
                 $sformatf("%s left %0d partially parsed cases", label,
                           cases.size()))
    status = $system($sformatf("rm -f -- %s", path));
    if (status != 0)
      `uvm_error("GOLDEN_GRAMMAR", $sformatf("cannot remove %s", path))
  endtask

  // 功能：在测试辅助 rdma_defs_test.check_golden_reader_rejections 中构造或驱动“golden reader rejections”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task check_golden_reader_rejections();
    byte unsigned payload[];
    rdma_status_code_e payload_status;
    int status;
    string parsed_name;
    string error;
    string reject_dir;
    string valid_case;

    if (rdma_golden_reader::MAX_PAYLOAD_BYTES != 512)
      `uvm_error("GOLDEN_GRAMMAR", "golden reader payload limit")

    payload = new[1];
    payload[0] = 8'h5a;
    payload_status = rdma_golden_reader::parse_payload_line(
        "0\n", 32'd1431655766, payload, error);
    if (payload_status != RDMA_SC_CODEC_ERROR)
      `uvm_error("GOLDEN_GRAMMAR", "wraparound byte count was accepted")
    if (payload.size() != 0)
      `uvm_error("GOLDEN_GRAMMAR",
                 "wraparound byte count left a partially parsed payload")

    payload_status = rdma_golden_reader::parse_payload_line(
        "AA\n", 1, payload, error);
    if (payload_status == RDMA_SC_OK)
      `uvm_error("GOLDEN_GRAMMAR", "uppercase hex was accepted")
    payload_status = rdma_golden_reader::parse_payload_line(
        "0g\n", 1, payload, error);
    if (payload_status == RDMA_SC_OK)
      `uvm_error("GOLDEN_GRAMMAR", "partial hex token was accepted")
    payload_status = rdma_golden_reader::parse_payload_line(
        "00  01\n", 2, payload, error);
    if (payload_status == RDMA_SC_OK)
      `uvm_error("GOLDEN_GRAMMAR", "noncanonical byte spacing was accepted")
    if (rdma_golden_reader::parse_case_line(
          "# case: Qpc_rc_boundary\n", parsed_name, error))
      `uvm_error("GOLDEN_GRAMMAR", "uppercase case name was accepted")
    if (rdma_golden_reader::parse_case_line(
          "# case: qpc-rc-boundary\n", parsed_name, error))
      `uvm_error("GOLDEN_GRAMMAR", "punctuated case name was accepted")

    valid_case = {"# xtr_v1-golden-v1\n",
                  "# case: first\n",
                  "# inputs: value=1\n",
                  "# bytes: 1\n",
                  "00\n"};
    status = 1;
    for (int unsigned attempt = 0; attempt < 64 && status != 0; attempt++) begin
      reject_dir = $sformatf("/tmp/rdma_defs_test.%08x",
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

  // 功能：在测试辅助 rdma_defs_test.check_mask_lookup_api 中构造或驱动“mask lookup api”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function void check_mask_lookup_api();
    bit [63:0] mask_value;
    rdma_image_kind_e image_kinds[8] = '{
      RDMA_IMAGE_CQC,
      RDMA_IMAGE_MRT, RDMA_IMAGE_MRT, RDMA_IMAGE_MRT, RDMA_IMAGE_MRT,
      RDMA_IMAGE_SRQC, RDMA_IMAGE_CEQC, RDMA_IMAGE_AEQC
    };
    bit [7:0] opcodes[8] = '{
      RDMA_OP_CQC_CREATE,
      RDMA_OP_KEY_ALLOC, RDMA_OP_MR_REGISTER,
      RDMA_OP_MR_REGISTER, RDMA_OP_MR_REGISTER,
      RDMA_OP_SRFQC_CREATE, RDMA_OP_CEQC_CREATE,
      RDMA_OP_AEQC_CREATE
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
    if (body_mask(RDMA_IMAGE_CQC, RDMA_OP_AEQC_CREATE, 0, 0,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_API", "unsupported opcode was accepted")
    mask_value = '1;
    if (body_mask(RDMA_IMAGE_MRT, RDMA_OP_MR_REGISTER, 3, 0,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_API", "unsupported PBL mode was accepted")
    mask_value = '1;
    if (body_mask(RDMA_IMAGE_QPC, RDMA_OP_QPC_CREATE, 0, 0,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_API", "unsupported image kind was accepted")
    mask_value = '1;
    if (body_mask(RDMA_IMAGE_MRT, RDMA_OP_MR_REGISTER, 0, 8,
                  mask_value) || mask_value != 0)
      `uvm_error("MASK_API", "out-of-range qword was accepted")
  endfunction

  // 功能：在 rdma_defs_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    if (RDMA_HW_VERSION != 1 || RDMA_QPC_BYTES != 512)
      `uvm_error("DEFS", "QPC size")
    if (RDMA_CQC_BYTES != 64)
      `uvm_error("DEFS", "CQC size")
    if (RDMA_CMQE_BYTES != 64 || RDMA_WQE_BYTES != 64)
      `uvm_error("DEFS", "entry size")
    if (RDMA_OP_QPC_CREATE != 8'h00 ||
        RDMA_OP_KEY_ALLOC != 8'h04 ||
        RDMA_OP_OCC_FLUSH != 8'h0a ||
        RDMA_OP_CQC_CREATE != 8'h0c ||
        RDMA_OP_CEQC_DELETE != 8'h12 ||
        RDMA_OP_CEQC_QUERY != 8'h13 ||
        RDMA_OP_AEQC_DELETE != 8'h16 ||
        RDMA_OP_AEQC_QUERY != 8'h17 ||
        RDMA_OP_TQ_FLUSH != 8'h20 ||
        RDMA_OP_SRFQC_CREATE != 8'h35)
      `uvm_error("DEFS", "CMQ opcode")
    if (RDMA_ALLOC_TYPE_DIRECT != 0 ||
        RDMA_ALLOC_TYPE_INDIRECT != 1 ||
        RDMA_ALLOC_TYPE_HUGE != 2 ||
        RDMA_ALLOC_TYPE_L3_INDIRECT != 3 ||
        RDMA_ADDR_TYPE_VA_BASED != 0 ||
        RDMA_ADDR_TYPE_ZERO_BASED != 1 ||
        RDMA_MR_ST_INVALID != 0 || RDMA_MR_ST_FREE != 1 ||
        RDMA_MR_ST_VALID != 2 || RDMA_HOST_PAGE_4K != 0 ||
        RDMA_HOST_PAGE_2M != 1 || RDMA_HOST_PAGE_1G != 2 ||
        RDMA_PBL_MODE_0 != 0 || RDMA_PBL_MODE_1 != 1 ||
        RDMA_PBL_MODE_2 != 2 || RDMA_MEM_TYPE_MR != 0 ||
        RDMA_MEM_TYPE_MW_TYPE1 != 1 || RDMA_MEM_TYPE_MW_TYPE2B != 2 ||
        RDMA_RIGHT_LOCAL_WRITE != 5'h01 ||
        RDMA_RIGHT_REMOTE_READ != 5'h02 ||
        RDMA_RIGHT_REMOTE_WRITE != 5'h04 ||
        RDMA_RIGHT_BIND_WINDOW != 5'h08 ||
        RDMA_RIGHT_REMOTE_ATOMIC != 5'h10)
      `uvm_error("DEFS", "context object/state/mode/right values")
    if (RDMA_NOTIFY_WINDOW_OFFSET != 64'h2000 ||
        RDMA_NOTIFY_WINDOW_SIZE != 64'h2000)
      `uvm_error("DEFS", "notify window")

    if (RDMA_QPC_QPN_OFFSET != 16 || RDMA_QPC_QPN_WIDTH != 21)
      `uvm_error("DEFS", "QPC QPN field")
    if (RDMA_QPC_URC_RSQ_SIZE_WORD_BYTE_OFFSET != 24 ||
        RDMA_QPC_URC_RSQ_SIZE_LSB != 59 ||
        RDMA_QPC_URC_RSQ_SIZE_WIDTH != 3 ||
        RDMA_QPC_URC_RSQ_SIZE_OFFSET != 251)
      `uvm_error("DEFS", "URC RSQ size field")
    if (RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM_WORD_BYTE_OFFSET != 224 ||
        RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM_LSB != 16 ||
        RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM_WIDTH != 6 ||
        RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM_OFFSET != 1808)
      `uvm_error("DEFS", "URC RDSQ fetch field")
    if (RDMA_CMQ_OPCODE_OFFSET != 32 ||
        RDMA_CMQ_OPCODE_WIDTH != 8)
      `uvm_error("DEFS", "CMQ opcode field")
    if (RDMA_SQ_WQE_OPCODE_OFFSET != 32 ||
        RDMA_SQ_WQE_OPCODE_WIDTH != 4 ||
        RDMA_CQE_QPN_OFFSET != 0 || RDMA_CQE_QPN_WIDTH != 18)
      `uvm_error("DEFS", "queue representative fields")
    if (RDMA_CMQ_DB_PI_OFFSET != 32 || RDMA_CMQ_DB_PI_WIDTH != 5 ||
        RDMA_NOTIFY_CQ_CQN_OFFSET != 0 ||
        RDMA_NOTIFY_CQ_CQN_WIDTH != 21)
      `uvm_error("DEFS", "doorbell representative fields")

    if (RDMA_CMQ_ENVELOPE_MASK[0] != 64'h8fff3fff00000000 ||
        RDMA_CQC_CREATE_BODY_MASK[0] != 64'h00000000001fffff ||
        RDMA_MRT_KEY_ALLOC_PBL0_BODY_MASK[2] != 64'hffffffffffffffff)
      `uvm_error("DEFS", "image masks")

    check_mask_lookup_api();
    check_golden_reader_rejections();
    check_context_golden();

    phase.drop_objection(this);
  endtask
endclass

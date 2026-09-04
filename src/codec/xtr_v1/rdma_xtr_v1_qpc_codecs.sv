// 目录：硬件编解码层 codec/xtr_v1/rdma_xtr_v1_qpc_codecs.sv。
// 职责：实现 rdma_xtr_v1_qpc_codecs 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_xtr_v1_qpc_codecs.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_xtr_v1_qpc_codec_base extends rdma_codec_base;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_xtr_v1_qpc_codec_base");
    super.new(name);
  endfunction

  // 功能：执行接口 expected_transport 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 expected_transport）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected pure virtual function rdma_transport_e expected_transport();

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_extension）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected pure virtual function rdma_status encode_extension(
    rdma_qpc_model qpc,
    rdma_xtr_v1_qword_builder builder
  );

  // 功能：解析硬件/协议镜像并恢复受校验约束的模型字段（接口 decode_extension）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected pure virtual function rdma_status decode_extension(
    rdma_xtr_v1_qword_builder builder,
    rdma_qpc_model qpc
  );

  // 功能：执行接口 invalid_argument 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 invalid_argument）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：执行接口 codec_error 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 codec_error）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：执行接口 put 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 put）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status put(
    rdma_xtr_v1_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    bit [63:0] value
  );
    rdma_status status;
    status = builder.put_field(word_byte_offset, lsb, width, value);
    if (!status.ok())
      return codec_error({"QPC field authorship failed: ", status.message});
    return status;
  endfunction

  // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 get）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status get(
    rdma_xtr_v1_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    inout bit [63:0] value
  );
    rdma_status status;
    status = builder.get_field(word_byte_offset, lsb, width, value);
    if (!status.ok())
      return codec_error({"QPC field extraction failed: ", status.message});
    return status;
  endfunction

  // 功能：执行接口 add_allowed_field 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 add_allowed_field）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function void add_allowed_field(
    int unsigned qword_index,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    inout bit [63:0] mask
  );
    bit [63:0] width_mask;
    if ((word_byte_offset >> 3) != qword_index)
      return;
    width_mask = (width == 64) ? '1 : ((64'h1 << width) - 1);
    mask |= width_mask << lsb;
  endfunction

  // 功能：执行接口 qpc_allowed_mask 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 qpc_allowed_mask）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function bit qpc_allowed_mask(
    rdma_transport_e transport,
    int unsigned qword_index,
    output bit [63:0] mask
  );
    mask = '0;
    if (qword_index >= 64 ||
        !(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC}))
      return 1'b0;

`define QPC_ALLOW(STEM) \
    add_allowed_field(qword_index, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                      STEM``_WIDTH, mask);
    `QPC_ALLOW(XTR_V1_QPC_TVER)
    `QPC_ALLOW(XTR_V1_QPC_MIG)
    `QPC_ALLOW(XTR_V1_QPC_SERVICE_TYPE)
    `QPC_ALLOW(XTR_V1_QPC_HOST_ID)
    `QPC_ALLOW(XTR_V1_QPC_VF_ID)
    `QPC_ALLOW(XTR_V1_QPC_ICOS)
    `QPC_ALLOW(XTR_V1_QPC_QPN)
    `QPC_ALLOW(XTR_V1_QPC_STAT_IDX)
    `QPC_ALLOW(XTR_V1_QPC_PKEY)
    `QPC_ALLOW(XTR_V1_QPC_SHADOW_PBA)
    `QPC_ALLOW(XTR_V1_QPC_TX_ENDIAN_SWAP)
    `QPC_ALLOW(XTR_V1_QPC_RX_ENDIAN_SWAP)
    `QPC_ALLOW(XTR_V1_QPC_SQ_CE_EN)
    `QPC_ALLOW(XTR_V1_QPC_RA_FENCE)
    `QPC_ALLOW(XTR_V1_QPC_AA_FENCE)
    `QPC_ALLOW(XTR_V1_QPC_FC_EN)
    `QPC_ALLOW(XTR_V1_QPC_QP_ST)
    `QPC_ALLOW(XTR_V1_QPC_PMTU)
    `QPC_ALLOW(XTR_V1_QPC_QP_SN)
    `QPC_ALLOW(XTR_V1_QPC_PD_IDX)
    `QPC_ALLOW(XTR_V1_QPC_QP_ACCESS_FLAG)
    `QPC_ALLOW(XTR_V1_QPC_VLAN)
    `QPC_ALLOW(XTR_V1_QPC_IPV6)
    `QPC_ALLOW(XTR_V1_QPC_TUNNEL)
    `QPC_ALLOW(XTR_V1_QPC_LAG)
    `QPC_ALLOW(XTR_V1_QPC_FWD)
    `QPC_ALLOW(XTR_V1_QPC_DST_VPORT_ID)
    `QPC_ALLOW(XTR_V1_QPC_SRC_ADDR_IDX)
    `QPC_ALLOW(XTR_V1_QPC_DST_PORT)
    `QPC_ALLOW(XTR_V1_QPC_DST_QPN)
    `QPC_ALLOW(XTR_V1_QPC_DMAC)
    `QPC_ALLOW(XTR_V1_QPC_PRI)
    `QPC_ALLOW(XTR_V1_QPC_CFI)
    `QPC_ALLOW(XTR_V1_QPC_VLAN_ID)
    `QPC_ALLOW(XTR_V1_QPC_FLOW_LABEL)
    `QPC_ALLOW(XTR_V1_QPC_SRC_VPORT_ID)
    `QPC_ALLOW(XTR_V1_QPC_DSCP)
    `QPC_ALLOW(XTR_V1_QPC_ECN)
    `QPC_ALLOW(XTR_V1_QPC_HOPLIMIT)
    `QPC_ALLOW(XTR_V1_QPC_CUR_UDP_SPORT)
    if (qword_index == 10 || qword_index == 11)
      mask = '1;
    `QPC_ALLOW(XTR_V1_QPC_SQ_PBA)
    `QPC_ALLOW(XTR_V1_QPC_SQ_SIZE)
    `QPC_ALLOW(XTR_V1_QPC_SQ_OM)
    `QPC_ALLOW(XTR_V1_QPC_SQ_CQN)
    `QPC_ALLOW(XTR_V1_QPC_RQ_CQN)
    `QPC_ALLOW(XTR_V1_QPC_RQ_PBA)
    `QPC_ALLOW(XTR_V1_QPC_RQ_SIZE)
    `QPC_ALLOW(XTR_V1_QPC_RQ_OM)

    case (transport)
      RDMA_TRANSPORT_RC: begin
        `QPC_ALLOW(XTR_V1_QPC_RNR_RETRY_TH)
        `QPC_ALLOW(XTR_V1_QPC_RC_SRFQ)
        `QPC_ALLOW(XTR_V1_QPC_RC_SRFQN)
        `QPC_ALLOW(XTR_V1_QPC_PSN_RETRY_TH)
        `QPC_ALLOW(XTR_V1_QPC_RC_TPE_CUR_SQ_PSN)
        `QPC_ALLOW(XTR_V1_QPC_RC_LAST_READ_PSN)
        `QPC_ALLOW(XTR_V1_QPC_RC_EIRQ_PSN_MAX)
        `QPC_ALLOW(XTR_V1_QPC_EIRQ_CUR_SEND_PSN)
        `QPC_ALLOW(XTR_V1_QPC_EPSN_REQ)
        `QPC_ALLOW(XTR_V1_QPC_RC_PSN_MAX_RPE)
        `QPC_ALLOW(XTR_V1_QPC_RC_EPSN_RSP)
        `QPC_ALLOW(XTR_V1_QPC2_RC_EPSN_RSP)
        `QPC_ALLOW(XTR_V1_QPC_RC_PSN_MAX_TPE)
        `QPC_ALLOW(XTR_V1_QPC_RC_RETRY_FPSN)
        `QPC_ALLOW(XTR_V1_QPC_RC_RETRY_PSN)
      end
      RDMA_TRANSPORT_UD: begin
        `QPC_ALLOW(XTR_V1_QPC_UD_QKEY_H)
        `QPC_ALLOW(XTR_V1_QPC_UD_QKEY_L)
      end
      RDMA_TRANSPORT_URC: begin
        `QPC_ALLOW(XTR_V1_QPC_URC_RSQ_PBA_H)
        `QPC_ALLOW(XTR_V1_QPC_URC_RSQ_PBA_L)
        `QPC_ALLOW(XTR_V1_QPC_URC_RSQ_SIZE)
        `QPC_ALLOW(XTR_V1_QPC_URC_RDSQ_PBA)
        `QPC_ALLOW(XTR_V1_QPC_URC_RDSQ_SIZE)
        `QPC_ALLOW(XTR_V1_QPC_URC_TX_RBSN)
        `QPC_ALLOW(XTR_V1_QPC_URC_TX_DBSN)
        `QPC_ALLOW(XTR_V1_QPC_URC_RX_RBSN)
        `QPC_ALLOW(XTR_V1_QPC_URC_RX_DBSN)
        `QPC_ALLOW(XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM)
        `QPC_ALLOW(XTR_V1_QPC_URC_CUR_TX_DPSN)
        `QPC_ALLOW(XTR_V1_QPC_URC_CUR_TX_RPSN)
        `QPC_ALLOW(XTR_V1_QPC_URC_RXED_DBSN)
        `QPC_ALLOW(XTR_V1_QPC_URC_RQ_SE_TH)
        `QPC_ALLOW(XTR_V1_QPC_URC_SQ_CE_TH)
        `QPC_ALLOW(XTR_V1_QPC_URC_CUR_DSQ_PBA_H)
        `QPC_ALLOW(XTR_V1_QPC_URC_CUR_DSQ_PBA_L)
        `QPC_ALLOW(XTR_V1_QPC_URC_NXT_DSQ_PBA)
        `QPC_ALLOW(XTR_V1_QPC_URC_TPE_RPSN_MAX)
        `QPC_ALLOW(XTR_V1_QPC_URC_TPE_DPSN_MAX)
        `QPC_ALLOW(XTR_V1_QPC_URC_NXT_DSQ_FETCH_NUM)
      end
    endcase
`undef QPC_ALLOW
    return 1'b1;
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_qpc_encode_mask）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status validate_qpc_encode_mask(
    rdma_xtr_v1_qword_builder builder,
    rdma_transport_e transport
  );
    bit [63:0] occupancy[];
    bit [63:0] allowed;
    builder.get_occupancy(occupancy);
    if (occupancy.size() != 64)
      return codec_error("QPC encode occupancy is not 64 qwords");
    foreach (occupancy[i]) begin
      if (!qpc_allowed_mask(transport, i, allowed))
        return codec_error("QPC encode mask lookup failed");
      if (occupancy[i] != allowed)
        return codec_error($sformatf(
          "QPC qword %0d authorship 0x%016x differs from mask 0x%016x",
          i, occupancy[i], allowed));
    end
    return rdma_status::success();
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_qpc_decode_mask）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status validate_qpc_decode_mask(
    rdma_xtr_v1_qword_builder builder,
    rdma_transport_e transport
  );
    bit [63:0] words[];
    bit [63:0] allowed;
    builder.get_words(words);
    if (words.size() != 64)
      return codec_error("QPC decode image is not 64 qwords");
    foreach (words[i]) begin
      if (!qpc_allowed_mask(transport, i, allowed))
        return codec_error("QPC decode mask lookup failed");
      if ((words[i] & ~allowed) != 0)
        return codec_error($sformatf(
          "QPC qword %0d contains private reserved bits 0x%016x",
          i, words[i] & ~allowed));
    end
    return rdma_status::success();
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_log2）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status encode_log2(
    int unsigned value,
    int unsigned width,
    string label,
    output int unsigned code
  );
    code = 0;
    if (value == 0 || (value & (value - 1)) != 0)
      return invalid_argument({label, " is not a nonzero power of two"});
    while ((64'h1 << code) != value && code < 63)
      code++;
    if (code >= (1 << width))
      return invalid_argument({label, " logarithm exceeds xtr_v1 field width"});
    return rdma_status::success();
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_threshold）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status encode_threshold(
    int unsigned value,
    string label,
    output int unsigned code
  );
    if (value == 0) begin
      code = 0;
      return rdma_status::success();
    end
    return encode_log2(value, 4, label, code);
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_page）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status encode_page(
    rdma_backing_addr_t backing,
    string label,
    output bit [51:0] page
  );
    longint unsigned raw_page;
    page = '0;
    if ((backing.value & 64'hfff) != 0)
      return invalid_argument({label, " is not 4 KiB aligned"});
    raw_page = backing.value >> 12;
    if ((raw_page >> 52) != 0)
      return invalid_argument({label, " page exceeds 52 bits"});
    page = raw_page[51:0];
    return rdma_status::success();
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_state）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status encode_state(rdma_qp_state_e state,
                                                output bit [2:0] code);
    case (state)
      RDMA_QPS_RESET: code = 3'd0;
      RDMA_QPS_INIT:  code = 3'd1;
      RDMA_QPS_RTR:   code = 3'd2;
      RDMA_QPS_RTS:   code = 3'd3;
      RDMA_QPS_ERROR: code = 3'd4;
      RDMA_QPS_SQD, RDMA_QPS_SQE: code = 3'd5;
      default: return invalid_argument("xtr_v1 QP state is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：解析硬件/协议镜像并恢复受校验约束的模型字段（接口 decode_state）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status decode_state(bit [2:0] code,
                                                output rdma_qp_state_e state);
    case (code)
      0: state = RDMA_QPS_RESET;
      1: state = RDMA_QPS_INIT;
      2: state = RDMA_QPS_RTR;
      3: state = RDMA_QPS_RTS;
      4: state = RDMA_QPS_ERROR;
      5: state = RDMA_QPS_SQD;
      default: return codec_error("xtr_v1 QP state code is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_pmtu）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status encode_pmtu(int unsigned mtu,
                                               output bit [2:0] code);
    case (mtu)
      1024: code = 3'd2;
      2048: code = 3'd3;
      4096: code = 3'd4;
      8192: code = 3'd5;
      default: return invalid_argument("xtr_v1 path MTU is unsupported");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：解析硬件/协议镜像并恢复受校验约束的模型字段（接口 decode_pmtu）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status decode_pmtu(bit [2:0] code,
                                               output int unsigned mtu);
    case (code)
      2: mtu = 1024;
      3: mtu = 2048;
      4: mtu = 4096;
      5: mtu = 8192;
      default: return codec_error("xtr_v1 PMTU code is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 projected_handle）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_handle projected_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.object_id = object_id;
    handle.function_uid = 0;
    handle.generation = 0;
    return handle;
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_profile_model）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status validate_profile_model(rdma_qpc_model qpc);
    rdma_status status;
    int unsigned code;
    bit [51:0] page;
    int unsigned expected_ecn;

    if (qpc == null)
      return invalid_argument("QPC model is null");
    status = qpc.validate();
    if (!status.ok())
      return invalid_argument({"QPC model is invalid: ", status.message});
    if (qpc.transport != expected_transport())
      return invalid_argument("QPC transport does not match codec");
    if (qpc.host_id > 7 || qpc.vf_id > 12'hfff || qpc.stat_index > 8'hff)
      return invalid_argument("QPC common identifier exceeds xtr_v1 width");
    if (qpc.address_vector.source_address_index > 12'hfff ||
        qpc.address_vector.source_vport > 11'h7ff ||
        qpc.address_vector.destination_vport > 11'h7ff ||
        qpc.address_vector.destination_port > 4'hf)
      return invalid_argument("QPC address-vector identifier exceeds xtr_v1 width");
    if (qpc.tx_flow_control != qpc.rx_flow_control)
      return invalid_argument("xtr_v1 QPC requires symmetric flow control");
    if (qpc.transport != RDMA_TRANSPORT_RC && qpc.srq_h != null)
      return invalid_argument("xtr_v1 non-RC QPC cannot serialize an SRQ handle");
    expected_ecn = (qpc.transport == RDMA_TRANSPORT_UD) ? 0 : 2;
    if (qpc.address_vector.traffic_class[1:0] != expected_ecn[1:0])
      return invalid_argument("QPC traffic class has invalid transport ECN bits");
    status = encode_pmtu(qpc.path_mtu_bytes, code);
    if (!status.ok()) return status;
    status = encode_page(qpc.sq_backing, "QPC SQ backing", page);
    if (!status.ok()) return status;
    status = encode_page(qpc.rq_backing, "QPC RQ backing", page);
    if (!status.ok()) return status;
    status = encode_log2(qpc.sq_depth, 4, "QPC SQ depth", code);
    if (!status.ok()) return status;
    status = encode_log2(qpc.rq_depth, 4, "QPC RQ depth", code);
    if (!status.ok()) return status;
    return rdma_status::success();
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_model）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_qpc_model qpc;
    if (!$cast(qpc, model))
      return invalid_argument("xtr_v1 QPC codec requires rdma_qpc_model");
    return validate_profile_model(qpc);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_image）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status validate_image(rdma_hw_image image);
    rdma_xtr_v1_qword_builder builder;
    byte unsigned payload[];
    rdma_status status;

    if (image == null)
      return codec_error("QPC image is null");
    if (image.length != XTR_V1_QPC_BYTES ||
        image.bytes.size() != XTR_V1_QPC_BYTES)
      return codec_error("QPC image length is not 512 bytes");
    if (image.alignment != XTR_V1_QPC_BYTES ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_QPC ||
        image.hardware_version != XTR_V1_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return codec_error("QPC image metadata is invalid");
    payload = new[XTR_V1_QPC_BYTES];
    foreach (payload[i]) payload[i] = image.bytes[i];
    builder = new("qpc_validate_builder");
    status = builder.deserialize(payload);
    if (!status.ok()) return codec_error(status.message);
    return validate_qpc_decode_mask(builder, expected_transport());
  endfunction

  // 功能：执行接口 hardware_endian 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 hardware_endian）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_byte_endian_e hardware_endian();
    return RDMA_ENDIAN_BIG;
  endfunction

  // 功能：执行接口 describe_fields 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 describe_fields）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function string describe_fields();
    return $sformatf("xtr_v1 512-byte %s QPC image", expected_transport().name());
  endfunction

  // 功能：执行接口 normalized_rights 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 normalized_rights）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function bit [4:0] normalized_rights(rdma_rdma_access_t access);
    bit [4:0] rights;
    rights = '0;
    if (access.local_write || access.remote_write || access.remote_atomic)
      rights |= XTR_V1_RIGHT_LOCAL_WRITE;
    if (access.remote_read) rights |= XTR_V1_RIGHT_REMOTE_READ;
    if (access.remote_write) rights |= XTR_V1_RIGHT_REMOTE_WRITE;
    if (access.memory_window_bind) rights |= XTR_V1_RIGHT_BIND_WINDOW;
    if (access.remote_atomic) rights |= XTR_V1_RIGHT_REMOTE_ATOMIC;
    return rights;
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_common）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status encode_common(
    rdma_qpc_model qpc,
    rdma_xtr_v1_qword_builder builder
  );
    rdma_status status;
    bit [2:0] service_type;
    bit [2:0] state_code;
    bit [2:0] pmtu_code;
    bit [4:0] access_code;
    bit [51:0] sq_page;
    bit [51:0] rq_page;
    int unsigned sq_size;
    int unsigned rq_size;
    byte unsigned ip[];

    case (qpc.transport)
      RDMA_TRANSPORT_RC: service_type = 0;
      RDMA_TRANSPORT_UD: service_type = 3;
      RDMA_TRANSPORT_URC: service_type = 6;
      default: return invalid_argument("xtr_v1 QPC transport is unsupported");
    endcase
    status = encode_state(qpc.state, state_code); if (!status.ok()) return status;
    status = encode_pmtu(qpc.path_mtu_bytes, pmtu_code); if (!status.ok()) return status;
    status = encode_page(qpc.sq_backing, "QPC SQ backing", sq_page); if (!status.ok()) return status;
    status = encode_page(qpc.rq_backing, "QPC RQ backing", rq_page); if (!status.ok()) return status;
    status = encode_log2(qpc.sq_depth, 4, "QPC SQ depth", sq_size); if (!status.ok()) return status;
    status = encode_log2(qpc.rq_depth, 4, "QPC RQ depth", rq_size); if (!status.ok()) return status;
    access_code = normalized_rights(qpc.access);

`define QPC_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `QPC_PUT(XTR_V1_QPC_TVER, qpc.behavior.transport_version)
    `QPC_PUT(XTR_V1_QPC_MIG, qpc.behavior.migration_enable)
    `QPC_PUT(XTR_V1_QPC_SERVICE_TYPE, service_type)
    `QPC_PUT(XTR_V1_QPC_HOST_ID, qpc.host_id)
    `QPC_PUT(XTR_V1_QPC_VF_ID, qpc.vf_id)
    `QPC_PUT(XTR_V1_QPC_ICOS, qpc.address_vector.traffic_class[7:5])
    `QPC_PUT(XTR_V1_QPC_QPN, qpc.qp_h.object_id)
    `QPC_PUT(XTR_V1_QPC_STAT_IDX, qpc.stat_index)
    `QPC_PUT(XTR_V1_QPC_PKEY, qpc.pkey)
    `QPC_PUT(XTR_V1_QPC_SHADOW_PBA, qpc.context_backing.value >> 9)
    `QPC_PUT(XTR_V1_QPC_TX_ENDIAN_SWAP, qpc.behavior.tx_endian_swap)
    `QPC_PUT(XTR_V1_QPC_RX_ENDIAN_SWAP, qpc.behavior.rx_endian_swap)
    `QPC_PUT(XTR_V1_QPC_SQ_CE_EN, qpc.signature_enable)
    `QPC_PUT(XTR_V1_QPC_RA_FENCE, qpc.behavior.read_after_write_fence)
    `QPC_PUT(XTR_V1_QPC_AA_FENCE, qpc.behavior.atomic_after_atomic_fence)
    `QPC_PUT(XTR_V1_QPC_FC_EN, qpc.tx_flow_control)
    `QPC_PUT(XTR_V1_QPC_QP_ST, state_code)
    `QPC_PUT(XTR_V1_QPC_PMTU, pmtu_code)
    `QPC_PUT(XTR_V1_QPC_QP_SN, qpc.qp_sequence)
    `QPC_PUT(XTR_V1_QPC_PD_IDX, qpc.pd_h.object_id)
    `QPC_PUT(XTR_V1_QPC_QP_ACCESS_FLAG, access_code)
    `QPC_PUT(XTR_V1_QPC_VLAN, qpc.address_vector.vlan_enable)
    `QPC_PUT(XTR_V1_QPC_IPV6, qpc.address_vector.ipv6)
    `QPC_PUT(XTR_V1_QPC_TUNNEL, qpc.address_vector.tunnel_enable)
    `QPC_PUT(XTR_V1_QPC_LAG, qpc.address_vector.lag_enable)
    `QPC_PUT(XTR_V1_QPC_FWD, qpc.address_vector.forwarding_enable ? 2 : 0)
    `QPC_PUT(XTR_V1_QPC_DST_VPORT_ID, qpc.address_vector.destination_vport)
    `QPC_PUT(XTR_V1_QPC_SRC_ADDR_IDX, qpc.address_vector.source_address_index)
    `QPC_PUT(XTR_V1_QPC_DST_PORT, qpc.address_vector.destination_port)
    `QPC_PUT(XTR_V1_QPC_DMAC, qpc.address_vector.destination_mac)
    `QPC_PUT(XTR_V1_QPC_PRI, qpc.behavior.\priority )
    `QPC_PUT(XTR_V1_QPC_CFI, qpc.address_vector.cfi)
    `QPC_PUT(XTR_V1_QPC_VLAN_ID, qpc.address_vector.vlan_id)
    `QPC_PUT(XTR_V1_QPC_FLOW_LABEL, qpc.address_vector.flow_label)
    `QPC_PUT(XTR_V1_QPC_SRC_VPORT_ID, qpc.address_vector.source_vport)
    `QPC_PUT(XTR_V1_QPC_DSCP, qpc.address_vector.traffic_class[7:2])
    `QPC_PUT(XTR_V1_QPC_ECN, qpc.address_vector.traffic_class[1:0])
    `QPC_PUT(XTR_V1_QPC_HOPLIMIT, qpc.address_vector.hop_limit)
    `QPC_PUT(XTR_V1_QPC_CUR_UDP_SPORT, qpc.address_vector.udp_source_port)
    ip = new[XTR_V1_QPC_DEST_IP_BYTES];
    foreach (ip[i]) ip[i] = qpc.address_vector.destination_ip[i];
    status = builder.put_memcpy(XTR_V1_QPC_DEST_IP_BYTE_OFFSET, ip);
    if (!status.ok()) return codec_error(status.message);
    `QPC_PUT(XTR_V1_QPC_SQ_PBA, sq_page)
    `QPC_PUT(XTR_V1_QPC_SQ_SIZE, sq_size)
    `QPC_PUT(XTR_V1_QPC_SQ_OM, qpc.sq_mode)
    `QPC_PUT(XTR_V1_QPC_SQ_CQN, qpc.send_cq_h.object_id)
    `QPC_PUT(XTR_V1_QPC_RQ_CQN, qpc.recv_cq_h.object_id)
    `QPC_PUT(XTR_V1_QPC_RQ_PBA, rq_page)
    `QPC_PUT(XTR_V1_QPC_RQ_SIZE, rq_size)
    `QPC_PUT(XTR_V1_QPC_RQ_OM, qpc.rq_mode)
`undef QPC_PUT
    return rdma_status::success();
  endfunction

  // 功能：解析硬件/协议镜像并恢复受校验约束的模型字段（接口 decode_common）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status decode_common(
    rdma_xtr_v1_qword_builder builder,
    byte unsigned payload[],
    rdma_qpc_model qpc
  );
    rdma_status status;
    bit [63:0] value;
    bit [2:0] service_expected;
    bit [2:0] state_code;
    bit [2:0] pmtu_code;
    bit [4:0] access_code;
    int unsigned sq_size;
    int unsigned rq_size;
    int unsigned fwd_code;
    int unsigned icos;

    case (expected_transport())
      RDMA_TRANSPORT_RC: service_expected = 0;
      RDMA_TRANSPORT_UD: service_expected = 3;
      RDMA_TRANSPORT_URC: service_expected = 6;
      default: return codec_error("QPC decoder transport is unsupported");
    endcase
    qpc.transport = expected_transport();

`define QPC_GET(STEM, TARGET) \
    value = '0; \
    status = get(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, value); \
    if (!status.ok()) return status; \
    TARGET = value;
    `QPC_GET(XTR_V1_QPC_TVER, qpc.behavior.transport_version)
    `QPC_GET(XTR_V1_QPC_MIG, qpc.behavior.migration_enable)
    `QPC_GET(XTR_V1_QPC_SERVICE_TYPE, state_code)
    if (state_code != service_expected)
      return codec_error("QPC service type does not match codec");
    `QPC_GET(XTR_V1_QPC_HOST_ID, qpc.host_id)
    `QPC_GET(XTR_V1_QPC_VF_ID, qpc.vf_id)
    `QPC_GET(XTR_V1_QPC_ICOS, icos)
    `QPC_GET(XTR_V1_QPC_QPN, sq_size)
    qpc.qp_h = projected_handle("decoded_qp", RDMA_RESOURCE_QP, sq_size);
    `QPC_GET(XTR_V1_QPC_STAT_IDX, qpc.stat_index)
    `QPC_GET(XTR_V1_QPC_PKEY, qpc.pkey)
    `QPC_GET(XTR_V1_QPC_SHADOW_PBA, qpc.context_backing.value)
    qpc.context_backing.value <<= 9;
    `QPC_GET(XTR_V1_QPC_TX_ENDIAN_SWAP, qpc.behavior.tx_endian_swap)
    `QPC_GET(XTR_V1_QPC_RX_ENDIAN_SWAP, qpc.behavior.rx_endian_swap)
    `QPC_GET(XTR_V1_QPC_SQ_CE_EN, qpc.signature_enable)
    `QPC_GET(XTR_V1_QPC_RA_FENCE, qpc.behavior.read_after_write_fence)
    `QPC_GET(XTR_V1_QPC_AA_FENCE, qpc.behavior.atomic_after_atomic_fence)
    `QPC_GET(XTR_V1_QPC_FC_EN, qpc.tx_flow_control)
    qpc.rx_flow_control = qpc.tx_flow_control;
    `QPC_GET(XTR_V1_QPC_QP_ST, state_code)
    status = decode_state(state_code, qpc.state); if (!status.ok()) return status;
    `QPC_GET(XTR_V1_QPC_PMTU, pmtu_code)
    status = decode_pmtu(pmtu_code, qpc.path_mtu_bytes); if (!status.ok()) return status;
    `QPC_GET(XTR_V1_QPC_QP_SN, qpc.qp_sequence)
    `QPC_GET(XTR_V1_QPC_PD_IDX, sq_size)
    qpc.pd_h = projected_handle("decoded_pd", RDMA_RESOURCE_PD, sq_size);
    `QPC_GET(XTR_V1_QPC_QP_ACCESS_FLAG, access_code)
    qpc.access.local_write = (access_code & XTR_V1_RIGHT_LOCAL_WRITE) != 0;
    qpc.access.remote_read = (access_code & XTR_V1_RIGHT_REMOTE_READ) != 0;
    qpc.access.remote_write = (access_code & XTR_V1_RIGHT_REMOTE_WRITE) != 0;
    qpc.access.memory_window_bind = (access_code & XTR_V1_RIGHT_BIND_WINDOW) != 0;
    qpc.access.remote_atomic = (access_code & XTR_V1_RIGHT_REMOTE_ATOMIC) != 0;
    `QPC_GET(XTR_V1_QPC_VLAN, qpc.address_vector.vlan_enable)
    `QPC_GET(XTR_V1_QPC_IPV6, qpc.address_vector.ipv6)
    `QPC_GET(XTR_V1_QPC_TUNNEL, qpc.address_vector.tunnel_enable)
    `QPC_GET(XTR_V1_QPC_LAG, qpc.address_vector.lag_enable)
    `QPC_GET(XTR_V1_QPC_FWD, fwd_code)
    if (!(fwd_code inside {0, 2}))
      return codec_error("QPC forwarding code is invalid");
    qpc.address_vector.forwarding_enable = (fwd_code == 2);
    `QPC_GET(XTR_V1_QPC_DST_VPORT_ID, qpc.address_vector.destination_vport)
    `QPC_GET(XTR_V1_QPC_SRC_ADDR_IDX, qpc.address_vector.source_address_index)
    `QPC_GET(XTR_V1_QPC_DST_PORT, qpc.address_vector.destination_port)
    `QPC_GET(XTR_V1_QPC_DMAC, qpc.address_vector.destination_mac)
    `QPC_GET(XTR_V1_QPC_PRI, qpc.behavior.\priority )
    `QPC_GET(XTR_V1_QPC_CFI, qpc.address_vector.cfi)
    `QPC_GET(XTR_V1_QPC_VLAN_ID, qpc.address_vector.vlan_id)
    `QPC_GET(XTR_V1_QPC_FLOW_LABEL, qpc.address_vector.flow_label)
    `QPC_GET(XTR_V1_QPC_SRC_VPORT_ID, qpc.address_vector.source_vport)
    `QPC_GET(XTR_V1_QPC_DSCP, qpc.address_vector.traffic_class)
    qpc.address_vector.traffic_class <<= 2;
    value = '0;
    status = get(builder, XTR_V1_QPC_ECN_WORD_BYTE_OFFSET,
                 XTR_V1_QPC_ECN_LSB, XTR_V1_QPC_ECN_WIDTH, value);
    if (!status.ok()) return status;
    qpc.address_vector.traffic_class |= value[1:0];
    if (icos != qpc.address_vector.traffic_class[7:5])
      return codec_error("QPC ICOS does not mirror traffic class");
    `QPC_GET(XTR_V1_QPC_HOPLIMIT, qpc.address_vector.hop_limit)
    `QPC_GET(XTR_V1_QPC_CUR_UDP_SPORT, qpc.address_vector.udp_source_port)
    foreach (qpc.address_vector.destination_ip[i])
      qpc.address_vector.destination_ip[i] =
        payload[XTR_V1_QPC_DEST_IP_BYTE_OFFSET + i];
    `QPC_GET(XTR_V1_QPC_SQ_PBA, qpc.sq_backing.value)
    qpc.sq_backing.value <<= 12;
    `QPC_GET(XTR_V1_QPC_SQ_SIZE, sq_size)
    qpc.sq_depth = 1 << sq_size;
    value = '0;
    status = get(builder, XTR_V1_QPC_SQ_OM_WORD_BYTE_OFFSET,
                 XTR_V1_QPC_SQ_OM_LSB, XTR_V1_QPC_SQ_OM_WIDTH, value);
    if (!status.ok()) return status;
    qpc.sq_mode = rdma_object_mode_e'(value[1:0]);
    `QPC_GET(XTR_V1_QPC_SQ_CQN, sq_size)
    qpc.send_cq_h = projected_handle("decoded_send_cq", RDMA_RESOURCE_CQ, sq_size);
    `QPC_GET(XTR_V1_QPC_RQ_CQN, rq_size)
    qpc.recv_cq_h = projected_handle("decoded_recv_cq", RDMA_RESOURCE_CQ, rq_size);
    `QPC_GET(XTR_V1_QPC_RQ_PBA, qpc.rq_backing.value)
    qpc.rq_backing.value <<= 12;
    `QPC_GET(XTR_V1_QPC_RQ_SIZE, rq_size)
    qpc.rq_depth = 1 << rq_size;
    value = '0;
    status = get(builder, XTR_V1_QPC_RQ_OM_WORD_BYTE_OFFSET,
                 XTR_V1_QPC_RQ_OM_LSB, XTR_V1_QPC_RQ_OM_WIDTH, value);
    if (!status.ok()) return status;
    qpc.rq_mode = rdma_object_mode_e'(value[1:0]);
`undef QPC_GET
    return rdma_status::success();
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_qpc_model qpc;
    rdma_xtr_v1_qword_builder builder;
    rdma_hw_image candidate;
    byte unsigned payload[];
    rdma_status status;

    image = null;
    status = validate_model(model);
    if (!status.ok()) return status;
    if (!$cast(qpc, model))
      return invalid_argument("xtr_v1 QPC model cast failed");
    builder = new("qpc_encode_builder");
    status = builder.reset(XTR_V1_QPC_BYTES);
    if (!status.ok()) return codec_error(status.message);
    status = encode_common(qpc, builder); if (!status.ok()) return status;
    status = encode_extension(qpc, builder); if (!status.ok()) return status;
    status = validate_qpc_encode_mask(builder, qpc.transport);
    if (!status.ok()) return status;
    payload = new[0];
    status = builder.serialize(payload);
    if (!status.ok()) return codec_error(status.message);

    candidate = rdma_hw_image::type_id::create("xtr_v1_qpc_image");
    foreach (payload[i]) candidate.bytes.push_back(payload[i]);
    candidate.length = XTR_V1_QPC_BYTES;
    candidate.alignment = XTR_V1_QPC_BYTES;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = RDMA_IMAGE_QPC;
    candidate.hardware_version = XTR_V1_HW_VERSION;
    candidate.function_generation = qpc.qp_h.generation;
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    image = candidate;
    return rdma_status::success();
  endfunction

  // 功能：解析硬件/协议镜像并恢复受校验约束的模型字段（接口 decode）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );
    rdma_qpc_model qpc;
    rdma_xtr_v1_qword_builder builder;
    byte unsigned payload[];
    rdma_status status;

    model = null;
    status = validate_image(image);
    if (!status.ok()) return status;
    payload = new[XTR_V1_QPC_BYTES];
    foreach (payload[i]) payload[i] = image.bytes[i];
    builder = new("qpc_decode_builder");
    status = builder.deserialize(payload);
    if (!status.ok()) return codec_error(status.message);
    qpc = rdma_qpc_model::type_id::create("decoded_xtr_v1_qpc");
    status = decode_common(builder, payload, qpc); if (!status.ok()) return status;
    status = decode_extension(builder, qpc); if (!status.ok()) return status;
    status = qpc.validate();
    if (!status.ok())
      return codec_error({"decoded QPC semantics are invalid: ", status.message});
    status = validate_profile_model(qpc);
    if (!status.ok())
      return codec_error({"decoded QPC profile is invalid: ", status.message});
    model = qpc;
    return rdma_status::success();
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 projected_handle_equal）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function bit projected_handle_equal(rdma_handle lhs,
                                                  rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.kind == rhs.kind && lhs.object_id == rhs.object_id;
  endfunction

  // 功能：执行接口 canonical_state_equal 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 canonical_state_equal）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function bit canonical_state_equal(rdma_qp_state_e lhs,
                                                 rdma_qp_state_e rhs);
    if (lhs == rhs) return 1'b1;
    return (lhs inside {RDMA_QPS_SQD, RDMA_QPS_SQE}) &&
           (rhs inside {RDMA_QPS_SQD, RDMA_QPS_SQE});
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 serialized_equal）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status serialized_equal(
    rdma_hw_model lhs,
    rdma_hw_model rhs,
    output bit equal,
    output string mismatch
  );
    rdma_qpc_model left;
    rdma_qpc_model right;
    rdma_qpc_rc_ext lhs_rc;
    rdma_qpc_rc_ext rhs_rc;
    rdma_qpc_ud_ext lhs_ud;
    rdma_qpc_ud_ext rhs_ud;
    rdma_qpc_urc_ext lhs_urc;
    rdma_qpc_urc_ext rhs_urc;

    equal = 1'b0;
    mismatch = "";
    if (!$cast(left, lhs) || !$cast(right, rhs)) begin
      mismatch = "serialized equality requires two QPC models";
      return invalid_argument(mismatch);
    end
`define QPC_NE(FIELD, TEXT) \
    if (left.FIELD != right.FIELD) begin mismatch = TEXT; return rdma_status::success(); end
    if (!projected_handle_equal(left.qp_h, right.qp_h)) begin mismatch = "qp_h kind/object_id"; return rdma_status::success(); end
    if (!projected_handle_equal(left.pd_h, right.pd_h)) begin mismatch = "pd_h kind/object_id"; return rdma_status::success(); end
    if (!projected_handle_equal(left.send_cq_h, right.send_cq_h)) begin mismatch = "send_cq_h kind/object_id"; return rdma_status::success(); end
    if (!projected_handle_equal(left.recv_cq_h, right.recv_cq_h)) begin mismatch = "recv_cq_h kind/object_id"; return rdma_status::success(); end
    if (!projected_handle_equal(left.srq_h, right.srq_h)) begin mismatch = "srq_h kind/object_id"; return rdma_status::success(); end
    `QPC_NE(transport, "transport")
    if (!canonical_state_equal(left.state, right.state)) begin mismatch = "state"; return rdma_status::success(); end
    `QPC_NE(host_id, "host_id")
    `QPC_NE(vf_id, "vf_id")
    `QPC_NE(stat_index, "stat_index")
    `QPC_NE(pkey, "pkey")
    `QPC_NE(qp_sequence, "qp_sequence")
    if (normalized_rights(left.access) != normalized_rights(right.access)) begin
      mismatch = "access";
      return rdma_status::success();
    end
    `QPC_NE(path_mtu_bytes, "path_mtu_bytes")
    `QPC_NE(sq_depth, "sq_depth")
    `QPC_NE(rq_depth, "rq_depth")
    `QPC_NE(sq_backing.value, "sq_backing")
    `QPC_NE(rq_backing.value, "rq_backing")
    `QPC_NE(context_backing.value, "context_backing")
    `QPC_NE(sq_mode, "sq_mode")
    `QPC_NE(rq_mode, "rq_mode")
    `QPC_NE(signature_enable, "signature_enable")
    `QPC_NE(tx_flow_control, "tx_flow_control")
    `QPC_NE(rx_flow_control, "rx_flow_control")
    if (left.behavior == null || right.behavior == null) begin
      if (left.behavior != right.behavior) begin mismatch = "behavior nullness"; return rdma_status::success(); end
    end else begin
      `QPC_NE(behavior.transport_version, "behavior.transport_version")
      `QPC_NE(behavior.migration_enable, "behavior.migration_enable")
      `QPC_NE(behavior.tx_endian_swap, "behavior.tx_endian_swap")
      `QPC_NE(behavior.rx_endian_swap, "behavior.rx_endian_swap")
      `QPC_NE(behavior.read_after_write_fence, "behavior.read_after_write_fence")
      `QPC_NE(behavior.atomic_after_atomic_fence, "behavior.atomic_after_atomic_fence")
      `QPC_NE(behavior.\priority , "behavior.priority")
    end
    if (left.address_vector == null || right.address_vector == null) begin
      if (left.address_vector != right.address_vector) begin mismatch = "address_vector nullness"; return rdma_status::success(); end
    end else begin
      `QPC_NE(address_vector.source_address_index, "address_vector.source_address_index")
      `QPC_NE(address_vector.source_vport, "address_vector.source_vport")
      `QPC_NE(address_vector.destination_vport, "address_vector.destination_vport")
      `QPC_NE(address_vector.destination_port, "address_vector.destination_port")
      `QPC_NE(address_vector.destination_mac, "address_vector.destination_mac")
      foreach (left.address_vector.destination_ip[i]) begin
        if (left.address_vector.destination_ip[i] != right.address_vector.destination_ip[i]) begin
          mismatch = $sformatf("address_vector.destination_ip[%0d]", i);
          return rdma_status::success();
        end
      end
      `QPC_NE(address_vector.ipv6, "address_vector.ipv6")
      `QPC_NE(address_vector.vlan_enable, "address_vector.vlan_enable")
      `QPC_NE(address_vector.cfi, "address_vector.cfi")
      `QPC_NE(address_vector.lag_enable, "address_vector.lag_enable")
      `QPC_NE(address_vector.tunnel_enable, "address_vector.tunnel_enable")
      `QPC_NE(address_vector.forwarding_enable, "address_vector.forwarding_enable")
      `QPC_NE(address_vector.vlan_id, "address_vector.vlan_id")
      `QPC_NE(address_vector.traffic_class, "address_vector.traffic_class")
      `QPC_NE(address_vector.flow_label, "address_vector.flow_label")
      `QPC_NE(address_vector.hop_limit, "address_vector.hop_limit")
      `QPC_NE(address_vector.udp_source_port, "address_vector.udp_source_port")
    end
    case (left.transport)
      RDMA_TRANSPORT_RC: begin
        if (!$cast(lhs_rc, left.transport_ext) || !$cast(rhs_rc, right.transport_ext)) begin mismatch = "RC extension type"; return rdma_status::success(); end
        if (lhs_rc.remote_qpn != rhs_rc.remote_qpn) begin mismatch = "rc.remote_qpn"; return rdma_status::success(); end
        if (lhs_rc.send_psn != rhs_rc.send_psn) begin mismatch = "rc.send_psn"; return rdma_status::success(); end
        if (lhs_rc.recv_psn != rhs_rc.recv_psn) begin mismatch = "rc.recv_psn"; return rdma_status::success(); end
        if (lhs_rc.retry_count != rhs_rc.retry_count) begin mismatch = "rc.retry_count"; return rdma_status::success(); end
        if (lhs_rc.rnr_retry_count != rhs_rc.rnr_retry_count) begin mismatch = "rc.rnr_retry_count"; return rdma_status::success(); end
      end
      RDMA_TRANSPORT_UD: begin
        if (!$cast(lhs_ud, left.transport_ext) || !$cast(rhs_ud, right.transport_ext)) begin mismatch = "UD extension type"; return rdma_status::success(); end
        if (lhs_ud.qkey != rhs_ud.qkey) begin mismatch = "ud.qkey"; return rdma_status::success(); end
      end
      RDMA_TRANSPORT_URC: begin
        if (!$cast(lhs_urc, left.transport_ext) || !$cast(rhs_urc, right.transport_ext)) begin mismatch = "URC extension type"; return rdma_status::success(); end
        if (lhs_urc.remote_qpn != rhs_urc.remote_qpn) begin mismatch = "urc.remote_qpn"; return rdma_status::success(); end
        if (lhs_urc.rbsn != rhs_urc.rbsn) begin mismatch = "urc.rbsn"; return rdma_status::success(); end
        if (lhs_urc.dbsn != rhs_urc.dbsn) begin mismatch = "urc.dbsn"; return rdma_status::success(); end
        if (lhs_urc.rpsn != rhs_urc.rpsn) begin mismatch = "urc.rpsn"; return rdma_status::success(); end
        if (lhs_urc.dpsn != rhs_urc.dpsn) begin mismatch = "urc.dpsn"; return rdma_status::success(); end
        if (lhs_urc.queues == null || rhs_urc.queues == null) begin
          if (lhs_urc.queues != rhs_urc.queues) begin mismatch = "urc.queues nullness"; return rdma_status::success(); end
        end else begin
          if (lhs_urc.queues.rsq_backing.value != rhs_urc.queues.rsq_backing.value) begin mismatch = "urc.queues.rsq_backing"; return rdma_status::success(); end
          if (lhs_urc.queues.rdsq_backing.value != rhs_urc.queues.rdsq_backing.value) begin mismatch = "urc.queues.rdsq_backing"; return rdma_status::success(); end
          if (lhs_urc.queues.dsq_backing.value != rhs_urc.queues.dsq_backing.value) begin mismatch = "urc.queues.dsq_backing"; return rdma_status::success(); end
          if (lhs_urc.queues.rsq_depth != rhs_urc.queues.rsq_depth) begin mismatch = "urc.queues.rsq_depth"; return rdma_status::success(); end
          if (lhs_urc.queues.rdsq_depth != rhs_urc.queues.rdsq_depth) begin mismatch = "urc.queues.rdsq_depth"; return rdma_status::success(); end
          if (lhs_urc.queues.rdsq_fetch_count != rhs_urc.queues.rdsq_fetch_count) begin mismatch = "urc.queues.rdsq_fetch_count"; return rdma_status::success(); end
          if (lhs_urc.queues.dsq_fetch_count != rhs_urc.queues.dsq_fetch_count) begin mismatch = "urc.queues.dsq_fetch_count"; return rdma_status::success(); end
          if (lhs_urc.queues.rq_sequence_threshold_entries != rhs_urc.queues.rq_sequence_threshold_entries) begin mismatch = "urc.queues.rq_sequence_threshold_entries"; return rdma_status::success(); end
          if (lhs_urc.queues.sq_completion_threshold_entries != rhs_urc.queues.sq_completion_threshold_entries) begin mismatch = "urc.queues.sq_completion_threshold_entries"; return rdma_status::success(); end
        end
      end
      default: begin mismatch = "unsupported transport"; return rdma_status::success(); end
    endcase
`undef QPC_NE
    equal = 1'b1;
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_qpc_rc_codec extends rdma_xtr_v1_qpc_codec_base;
  `uvm_object_utils(rdma_xtr_v1_qpc_rc_codec)

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_xtr_v1_qpc_rc_codec"); super.new(name); endfunction
  // 功能：执行接口 expected_transport 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 expected_transport）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected virtual function rdma_transport_e expected_transport(); return RDMA_TRANSPORT_RC; endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_model）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_status status;
    rdma_qpc_model qpc;
    rdma_qpc_rc_ext ext;
    status = super.validate_model(model); if (!status.ok()) return status;
    if (!$cast(qpc, model) || !$cast(ext, qpc.transport_ext))
      return invalid_argument("RC QPC extension type is invalid");
    if (ext.retry_count > 7 || ext.rnr_retry_count > 7)
      return invalid_argument("RC retry count exceeds three bits");
    return status;
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_extension）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected virtual function rdma_status encode_extension(
    rdma_qpc_model qpc, rdma_xtr_v1_qword_builder builder
  );
    rdma_qpc_rc_ext ext;
    rdma_status status;
    if (!$cast(ext, qpc.transport_ext)) return invalid_argument("RC extension missing");
`define RC_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `RC_PUT(XTR_V1_QPC_RNR_RETRY_TH, ext.rnr_retry_count)
    `RC_PUT(XTR_V1_QPC_RC_SRFQ, qpc.srq_h != null)
    `RC_PUT(XTR_V1_QPC_RC_SRFQN, (qpc.srq_h == null) ? 0 : qpc.srq_h.object_id)
    `RC_PUT(XTR_V1_QPC_PSN_RETRY_TH, ext.retry_count)
    `RC_PUT(XTR_V1_QPC_DST_QPN, ext.remote_qpn)
    `RC_PUT(XTR_V1_QPC_RC_TPE_CUR_SQ_PSN, ext.send_psn)
    `RC_PUT(XTR_V1_QPC_RC_LAST_READ_PSN, ext.send_psn)
    `RC_PUT(XTR_V1_QPC_RC_EIRQ_PSN_MAX, ext.recv_psn)
    `RC_PUT(XTR_V1_QPC_EIRQ_CUR_SEND_PSN, ext.recv_psn)
    `RC_PUT(XTR_V1_QPC_EPSN_REQ, ext.recv_psn)
    `RC_PUT(XTR_V1_QPC_RC_PSN_MAX_RPE, ext.send_psn)
    `RC_PUT(XTR_V1_QPC_RC_EPSN_RSP, ext.send_psn)
    `RC_PUT(XTR_V1_QPC2_RC_EPSN_RSP, ext.send_psn)
    `RC_PUT(XTR_V1_QPC_RC_PSN_MAX_TPE, ext.send_psn)
    `RC_PUT(XTR_V1_QPC_RC_RETRY_FPSN, ext.send_psn)
    `RC_PUT(XTR_V1_QPC_RC_RETRY_PSN, ext.send_psn)
`undef RC_PUT
    return rdma_status::success();
  endfunction

  // 功能：解析硬件/协议镜像并恢复受校验约束的模型字段（接口 decode_extension）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected virtual function rdma_status decode_extension(
    rdma_xtr_v1_qword_builder builder, rdma_qpc_model qpc
  );
    rdma_qpc_rc_ext ext;
    rdma_status status;
    bit [63:0] value;
    bit [23:0] send_canonical;
    bit [23:0] recv_canonical;
    int unsigned srq_present;
    int unsigned srq_id;
    ext = rdma_qpc_rc_ext::type_id::create("decoded_rc_ext");
`define RC_GET(STEM, TARGET) \
    value = '0; status = get(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, STEM``_WIDTH, value); \
    if (!status.ok()) return status; TARGET = value;
    `RC_GET(XTR_V1_QPC_RNR_RETRY_TH, ext.rnr_retry_count)
    `RC_GET(XTR_V1_QPC_RC_SRFQ, srq_present)
    `RC_GET(XTR_V1_QPC_RC_SRFQN, srq_id)
    if (!srq_present && srq_id != 0) return codec_error("RC SRQ ID is nonzero while SRQ is disabled");
    qpc.srq_h = srq_present ? projected_handle("decoded_srq", RDMA_RESOURCE_SRQ, srq_id) : null;
    `RC_GET(XTR_V1_QPC_PSN_RETRY_TH, ext.retry_count)
    `RC_GET(XTR_V1_QPC_DST_QPN, ext.remote_qpn)
    `RC_GET(XTR_V1_QPC_RC_EPSN_RSP, send_canonical)
    `RC_GET(XTR_V1_QPC_EPSN_REQ, recv_canonical)
`define RC_CHECK(STEM, EXPECTED, TEXT) \
    value = '0; status = get(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, STEM``_WIDTH, value); \
    if (!status.ok()) return status; if (value != EXPECTED) return codec_error(TEXT);
    `RC_CHECK(XTR_V1_QPC_RC_TPE_CUR_SQ_PSN, send_canonical, "RC send PSN mirror mismatch")
    `RC_CHECK(XTR_V1_QPC_RC_LAST_READ_PSN, send_canonical, "RC send PSN mirror mismatch")
    `RC_CHECK(XTR_V1_QPC_RC_PSN_MAX_RPE, send_canonical, "RC send PSN mirror mismatch")
    `RC_CHECK(XTR_V1_QPC2_RC_EPSN_RSP, send_canonical, "RC send PSN mirror mismatch")
    `RC_CHECK(XTR_V1_QPC_RC_PSN_MAX_TPE, send_canonical, "RC send PSN mirror mismatch")
    `RC_CHECK(XTR_V1_QPC_RC_RETRY_FPSN, send_canonical, "RC send PSN mirror mismatch")
    `RC_CHECK(XTR_V1_QPC_RC_RETRY_PSN, send_canonical, "RC send PSN mirror mismatch")
    `RC_CHECK(XTR_V1_QPC_RC_EIRQ_PSN_MAX, recv_canonical, "RC receive PSN mirror mismatch")
    `RC_CHECK(XTR_V1_QPC_EIRQ_CUR_SEND_PSN, recv_canonical, "RC receive PSN mirror mismatch")
`undef RC_CHECK
`undef RC_GET
    ext.send_psn = send_canonical;
    ext.recv_psn = recv_canonical;
    qpc.transport_ext = ext;
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_qpc_ud_codec extends rdma_xtr_v1_qpc_codec_base;
  `uvm_object_utils(rdma_xtr_v1_qpc_ud_codec)

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_xtr_v1_qpc_ud_codec"); super.new(name); endfunction
  // 功能：执行接口 expected_transport 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 expected_transport）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected virtual function rdma_transport_e expected_transport(); return RDMA_TRANSPORT_UD; endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_extension）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected virtual function rdma_status encode_extension(
    rdma_qpc_model qpc, rdma_xtr_v1_qword_builder builder
  );
    rdma_qpc_ud_ext ext;
    rdma_status status;
    if (!$cast(ext, qpc.transport_ext)) return invalid_argument("UD extension missing");
    status = put(builder, XTR_V1_QPC_UD_QKEY_H_WORD_BYTE_OFFSET,
                 XTR_V1_QPC_UD_QKEY_H_LSB, XTR_V1_QPC_UD_QKEY_H_WIDTH,
                 ext.qkey[31:24]); if (!status.ok()) return status;
    status = put(builder, XTR_V1_QPC_UD_QKEY_L_WORD_BYTE_OFFSET,
                 XTR_V1_QPC_UD_QKEY_L_LSB, XTR_V1_QPC_UD_QKEY_L_WIDTH,
                 ext.qkey[23:0]); if (!status.ok()) return status;
    status = put(builder, XTR_V1_QPC_DST_QPN_WORD_BYTE_OFFSET,
                 XTR_V1_QPC_DST_QPN_LSB, XTR_V1_QPC_DST_QPN_WIDTH,
                 ext.qkey[23:0]); if (!status.ok()) return status;
    return rdma_status::success();
  endfunction

  // 功能：解析硬件/协议镜像并恢复受校验约束的模型字段（接口 decode_extension）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected virtual function rdma_status decode_extension(
    rdma_xtr_v1_qword_builder builder, rdma_qpc_model qpc
  );
    rdma_qpc_ud_ext ext;
    rdma_status status;
    bit [63:0] high;
    bit [63:0] low;
    bit [63:0] destination;
    high = '0; low = '0; destination = '0;
    status = get(builder, XTR_V1_QPC_UD_QKEY_H_WORD_BYTE_OFFSET,
                 XTR_V1_QPC_UD_QKEY_H_LSB, XTR_V1_QPC_UD_QKEY_H_WIDTH, high);
    if (!status.ok()) return status;
    status = get(builder, XTR_V1_QPC_UD_QKEY_L_WORD_BYTE_OFFSET,
                 XTR_V1_QPC_UD_QKEY_L_LSB, XTR_V1_QPC_UD_QKEY_L_WIDTH, low);
    if (!status.ok()) return status;
    status = get(builder, XTR_V1_QPC_DST_QPN_WORD_BYTE_OFFSET,
                 XTR_V1_QPC_DST_QPN_LSB, XTR_V1_QPC_DST_QPN_WIDTH, destination);
    if (!status.ok()) return status;
    if (low != destination) return codec_error("UD destination QPN does not mirror qkey");
    ext = rdma_qpc_ud_ext::type_id::create("decoded_ud_ext");
    ext.qkey = {high[7:0], low[23:0]};
    qpc.srq_h = null;
    qpc.transport_ext = ext;
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_qpc_urc_codec extends rdma_xtr_v1_qpc_codec_base;
  `uvm_object_utils(rdma_xtr_v1_qpc_urc_codec)

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_xtr_v1_qpc_urc_codec"); super.new(name); endfunction
  // 功能：执行接口 expected_transport 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 expected_transport）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected virtual function rdma_transport_e expected_transport(); return RDMA_TRANSPORT_URC; endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_model）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_status status;
    rdma_qpc_model qpc;
    rdma_qpc_urc_ext ext;
    bit [51:0] page;
    int unsigned code;
    if (!$cast(qpc, model) || qpc.transport != RDMA_TRANSPORT_URC ||
        !$cast(ext, qpc.transport_ext) || ext.queues == null)
      return invalid_argument("URC QPC queue extension is invalid");
    if (ext.remote_qpn == 0)
      return invalid_argument("URC destination QPN is zero");
    status = encode_page(ext.queues.rsq_backing, "URC RSQ backing", page); if (!status.ok()) return status;
    status = encode_page(ext.queues.rdsq_backing, "URC RDSQ backing", page); if (!status.ok()) return status;
    status = encode_page(ext.queues.dsq_backing, "URC DSQ backing", page); if (!status.ok()) return status;
    status = encode_log2(ext.queues.rsq_depth, 3, "URC RSQ depth", code); if (!status.ok()) return status;
    status = encode_log2(ext.queues.rdsq_depth, 3, "URC RDSQ depth", code); if (!status.ok()) return status;
    if (ext.queues.rdsq_fetch_count > 63 || ext.queues.dsq_fetch_count > 63)
      return invalid_argument("URC fetch count exceeds six bits");
    status = encode_threshold(ext.queues.rq_sequence_threshold_entries,
                              "URC RQ threshold", code); if (!status.ok()) return status;
    status = encode_threshold(ext.queues.sq_completion_threshold_entries,
                              "URC SQ threshold", code); if (!status.ok()) return status;
    if ((ext.queues.dsq_backing.value >> 12) == 52'hfff_ffff_fffff)
      return invalid_argument("URC DSQ next page overflows 52 bits");
    return super.validate_model(model);
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_extension）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected virtual function rdma_status encode_extension(
    rdma_qpc_model qpc, rdma_xtr_v1_qword_builder builder
  );
    rdma_qpc_urc_ext ext;
    rdma_status status;
    bit [51:0] rsq_page;
    bit [51:0] rdsq_page;
    bit [51:0] dsq_page;
    bit [52:0] next_wide;
    int unsigned rsq_size;
    int unsigned rdsq_size;
    int unsigned rq_threshold;
    int unsigned sq_threshold;
    if (!$cast(ext, qpc.transport_ext) || ext.queues == null)
      return invalid_argument("URC extension missing");
    status = encode_page(ext.queues.rsq_backing, "URC RSQ backing", rsq_page); if (!status.ok()) return status;
    status = encode_page(ext.queues.rdsq_backing, "URC RDSQ backing", rdsq_page); if (!status.ok()) return status;
    status = encode_page(ext.queues.dsq_backing, "URC DSQ backing", dsq_page); if (!status.ok()) return status;
    status = encode_log2(ext.queues.rsq_depth, 3, "URC RSQ depth", rsq_size); if (!status.ok()) return status;
    status = encode_log2(ext.queues.rdsq_depth, 3, "URC RDSQ depth", rdsq_size); if (!status.ok()) return status;
    status = encode_threshold(ext.queues.rq_sequence_threshold_entries, "URC RQ threshold", rq_threshold); if (!status.ok()) return status;
    status = encode_threshold(ext.queues.sq_completion_threshold_entries, "URC SQ threshold", sq_threshold); if (!status.ok()) return status;
    next_wide = {1'b0, dsq_page} + 53'd1;
    if (next_wide[52]) return invalid_argument("URC DSQ next page overflows 52 bits");
`define URC_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `URC_PUT(XTR_V1_QPC_URC_RSQ_PBA_H, rsq_page[51:48])
    `URC_PUT(XTR_V1_QPC_URC_RSQ_PBA_L, rsq_page[47:0])
    `URC_PUT(XTR_V1_QPC_URC_RSQ_SIZE, rsq_size)
    `URC_PUT(XTR_V1_QPC_URC_RDSQ_PBA, rdsq_page)
    `URC_PUT(XTR_V1_QPC_URC_RDSQ_SIZE, rdsq_size)
    `URC_PUT(XTR_V1_QPC_DST_QPN, ext.remote_qpn)
    `URC_PUT(XTR_V1_QPC_URC_TX_RBSN, ext.rbsn)
    `URC_PUT(XTR_V1_QPC_URC_RX_RBSN, ext.rbsn)
    `URC_PUT(XTR_V1_QPC_URC_TX_DBSN, ext.dbsn)
    `URC_PUT(XTR_V1_QPC_URC_RX_DBSN, ext.dbsn)
    `URC_PUT(XTR_V1_QPC_URC_RXED_DBSN, ext.dbsn)
    `URC_PUT(XTR_V1_QPC_URC_CUR_TX_RPSN, ext.rpsn)
    `URC_PUT(XTR_V1_QPC_URC_TPE_RPSN_MAX, ext.rpsn)
    `URC_PUT(XTR_V1_QPC_URC_CUR_TX_DPSN, ext.dpsn)
    `URC_PUT(XTR_V1_QPC_URC_TPE_DPSN_MAX, ext.dpsn)
    `URC_PUT(XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM, ext.queues.rdsq_fetch_count)
    `URC_PUT(XTR_V1_QPC_URC_NXT_DSQ_FETCH_NUM, ext.queues.dsq_fetch_count)
    `URC_PUT(XTR_V1_QPC_URC_RQ_SE_TH, rq_threshold)
    `URC_PUT(XTR_V1_QPC_URC_SQ_CE_TH, sq_threshold)
    `URC_PUT(XTR_V1_QPC_URC_CUR_DSQ_PBA_H, dsq_page[51:12])
    `URC_PUT(XTR_V1_QPC_URC_CUR_DSQ_PBA_L, dsq_page[11:0])
    `URC_PUT(XTR_V1_QPC_URC_NXT_DSQ_PBA, next_wide[51:0])
`undef URC_PUT
    return rdma_status::success();
  endfunction

  // 功能：解析硬件/协议镜像并恢复受校验约束的模型字段（接口 decode_extension）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected virtual function rdma_status decode_extension(
    rdma_xtr_v1_qword_builder builder, rdma_qpc_model qpc
  );
    rdma_qpc_urc_ext ext;
    rdma_status status;
    bit [63:0] value;
    bit [51:0] rsq_page;
    bit [51:0] rdsq_page;
    bit [51:0] dsq_page;
    bit [51:0] next_page;
    bit [52:0] next_expected;
    bit [23:0] rbsn;
    bit [23:0] dbsn;
    bit [23:0] rpsn;
    bit [23:0] dpsn;
    int unsigned code;
    ext = rdma_qpc_urc_ext::type_id::create("decoded_urc_ext");
`define URC_GET(STEM, TARGET) \
    value = '0; status = get(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, STEM``_WIDTH, value); \
    if (!status.ok()) return status; TARGET = value;
    `URC_GET(XTR_V1_QPC_DST_QPN, ext.remote_qpn)
    if (ext.remote_qpn == 0) return codec_error("URC destination QPN is zero");
    `URC_GET(XTR_V1_QPC_URC_TX_RBSN, rbsn)
    `URC_GET(XTR_V1_QPC_URC_RX_RBSN, ext.rbsn)
    if (rbsn != ext.rbsn) return codec_error("URC RBSN mirror mismatch");
    `URC_GET(XTR_V1_QPC_URC_TX_DBSN, dbsn)
    `URC_GET(XTR_V1_QPC_URC_RX_DBSN, ext.dbsn)
    if (dbsn != ext.dbsn) return codec_error("URC DBSN mirror mismatch");
    `URC_GET(XTR_V1_QPC_URC_RXED_DBSN, value)
    if (dbsn != value[23:0]) return codec_error("URC DBSN mirror mismatch");
    ext.dbsn = dbsn;
    `URC_GET(XTR_V1_QPC_URC_CUR_TX_RPSN, rpsn)
    `URC_GET(XTR_V1_QPC_URC_TPE_RPSN_MAX, ext.rpsn)
    if (rpsn != ext.rpsn) return codec_error("URC RPSN mirror mismatch");
    `URC_GET(XTR_V1_QPC_URC_CUR_TX_DPSN, dpsn)
    `URC_GET(XTR_V1_QPC_URC_TPE_DPSN_MAX, ext.dpsn)
    if (dpsn != ext.dpsn) return codec_error("URC DPSN mirror mismatch");
    `URC_GET(XTR_V1_QPC_URC_RSQ_PBA_H, value)
    rsq_page[51:48] = value[3:0];
    `URC_GET(XTR_V1_QPC_URC_RSQ_PBA_L, value)
    rsq_page[47:0] = value[47:0];
    ext.queues.rsq_backing.value = {rsq_page, 12'b0};
    `URC_GET(XTR_V1_QPC_URC_RDSQ_PBA, rdsq_page)
    ext.queues.rdsq_backing.value = {rdsq_page, 12'b0};
    `URC_GET(XTR_V1_QPC_URC_RSQ_SIZE, code)
    ext.queues.rsq_depth = 1 << code;
    `URC_GET(XTR_V1_QPC_URC_RDSQ_SIZE, code)
    ext.queues.rdsq_depth = 1 << code;
    `URC_GET(XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM, ext.queues.rdsq_fetch_count)
    `URC_GET(XTR_V1_QPC_URC_NXT_DSQ_FETCH_NUM, ext.queues.dsq_fetch_count)
    `URC_GET(XTR_V1_QPC_URC_RQ_SE_TH, code)
    ext.queues.rq_sequence_threshold_entries = (code == 0) ? 0 : (1 << code);
    `URC_GET(XTR_V1_QPC_URC_SQ_CE_TH, code)
    ext.queues.sq_completion_threshold_entries = (code == 0) ? 0 : (1 << code);
    `URC_GET(XTR_V1_QPC_URC_CUR_DSQ_PBA_H, value)
    dsq_page[51:12] = value[39:0];
    `URC_GET(XTR_V1_QPC_URC_CUR_DSQ_PBA_L, value)
    dsq_page[11:0] = value[11:0];
    `URC_GET(XTR_V1_QPC_URC_NXT_DSQ_PBA, next_page)
`undef URC_GET
    next_expected = {1'b0, dsq_page} + 53'd1;
    if (next_expected[52] || next_page != next_expected[51:0])
      return codec_error("URC DSQ next-page relation is invalid");
    ext.queues.dsq_backing.value = {dsq_page, 12'b0};
    qpc.srq_h = null;
    qpc.transport_ext = ext;
    return rdma_status::success();
  endfunction
endclass

// 功能：执行接口 rdma_xtr_v1_register_qpc_codecs 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 rdma_xtr_v1_register_qpc_codecs）。
// 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
//   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
// 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
function automatic rdma_status rdma_xtr_v1_register_qpc_codecs(
  rdma_codec_registry registry
);
  rdma_codec_key key;
  rdma_status status;
  if (registry == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "QPC codec registry is null");
  key.hw_version = "xtr_v1";
  key.image_kind = RDMA_IMAGE_QPC;
  key.object_type = "qpc";
  key.opcode = XTR_V1_OP_QPC_CREATE;
  key.variant = "rc";
  status = registry.register_codec(
    key, rdma_xtr_v1_qpc_rc_codec::type_id::create("xtr_v1_qpc_rc_codec"));
  if (!status.ok()) return status;
  key.variant = "ud";
  status = registry.register_codec(
    key, rdma_xtr_v1_qpc_ud_codec::type_id::create("xtr_v1_qpc_ud_codec"));
  if (!status.ok()) return status;
  key.variant = "urc";
  return registry.register_codec(
    key, rdma_xtr_v1_qpc_urc_codec::type_id::create("xtr_v1_qpc_urc_codec"));
endfunction

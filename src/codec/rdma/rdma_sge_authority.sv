// 目录：硬件编解码层 codec/rdma。
// 职责：集中维护 SQ/RQ typed SGE 的有效计数与 payload 长度 authority，避免多处推导 wire SGE_NUM。
// 依赖：rdma_sge、RDMA_MAX_WQ_SGE、rdma_status；不访问 queue runtime、Host-memory 或外部账本。
// 所有权与生命周期：只返回 detached 数值，不保存输入 SGE 引用；输入对象生命周期由调用方负责。

// SGE authority 是 codec/model 之间的纯值边界：SQ 与 RQ 都须先在此得到统计，
// 再由 caller 决定 mode、wire 字段或 external-SGB descriptor 的发布。

class rdma_sge_authority extends uvm_object;
  `uvm_object_utils(rdma_sge_authority)

  // 功能：构造 SGE authority helper，仅作静态函数命名空间。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无；默认零计数不是有效 wire authority。
  function new(string name = "rdma_sge_authority");
    super.new(name);
  endfunction

  // 功能：统计 SQ payload 中长度非零的 SGE 数，供 payload mode 与 SQE.SGE_NUM 共用。
  // 输入/输出及副作用：sges 为输入；count 为输出；只读。
  // 失败/边界：null 只是不计数，拒绝由上层 validate_payload_shape() 负责；超限也不在此截断。
  static function void count_nonzero(
      input rdma_sge sges[$],
      output int unsigned count
  );
    count = 0;
    foreach (sges[i]) begin
      if (sges[i] != null && sges[i].length != 0)
        count++;
    end
  endfunction

  // 功能：统一的 typed SGE 准入：计算有效 SGE 数与 payload 总长，SQE/RQE 共用以免规则漂移。
  // 输入/输出及副作用：sges/role_name 为输入（role_name 仅用于诊断文案）；成功时输出过滤后的值。
  // 失败/边界：超过 32 项、含 null、bit31 非法（0x8000_0000 除外）、总长超 2GiB 或有效数超限时
  //   返回 INVALID_ARGUMENT，两个 output 置零。
  static function rdma_status derive_typed_common(
      input rdma_sge sges[$],
      input string role_name,
      output int unsigned valid_sge_count,
      output longint unsigned valid_payload_len
  );
    valid_sge_count = 0;
    valid_payload_len = 0;

    if (sges.size() > RDMA_MAX_WQ_SGE)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("%s raw SGE list exceeds driver limit of 32", role_name));

    foreach (sges[i]) begin
      if (sges[i] == null)
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            $sformatf("%s SGE handle is null", role_name));

      if (sges[i].length == 0)
        continue;

      if (sges[i].length != 32'h8000_0000 && sges[i].length[31])
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            $sformatf("%s SGE length uses reserved bit 31", role_name));

      if (valid_payload_len > 64'h8000_0000 - sges[i].length)
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            $sformatf("%s payload length exceeds 2 GiB", role_name));

      valid_sge_count++;
      valid_payload_len += sges[i].length;
    end

    if (valid_sge_count > RDMA_MAX_WQ_SGE)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("%s valid SGE count exceeds driver limit of 32", role_name));

    return rdma_status::success();
  endfunction

  // 功能：按驱动 send WQE 规则（SQE）得到有效 SGE 数与 payload 总长。
  // 输入/输出及副作用：sges 为输入；valid_sge_count/valid_payload_len 为输出；只读。
  // 失败/边界：同 derive_typed_common，失败时 output 置零。
  static function rdma_status derive_send(
      input rdma_sge sges[$],
      output int unsigned valid_sge_count,
      output longint unsigned valid_payload_len
  );
    return derive_typed_common(
        sges, "SQE", valid_sge_count, valid_payload_len);
  endfunction

  // 功能：按驱动 receive WQE 规则（RQE）得到有效 SGE 数与 payload 总长。
  // 输入/输出及副作用：sges 为输入；valid_sge_count/valid_payload_len 为输出；只读。
  // 失败/边界：同 derive_typed_common，失败时 output 置零。
  static function rdma_status derive_receive(
      input rdma_sge sges[$],
      output int unsigned valid_sge_count,
      output longint unsigned valid_payload_len
  );
    return derive_typed_common(
        sges, "RQE", valid_sge_count, valid_payload_len);
  endfunction

  // 功能：校验调用方声明的 SGE_NUM/payload_len 与 RQE SGE 列表的 canonical 统计一致。
  // 输入/输出及副作用：sges 与 declared_* 为输入；canonical_* 为输出；只读。
  // 失败/边界：透传 derive_receive 的错误；数量或长度不一致返回 INVALID_ARGUMENT，输出置零。
  static function rdma_status validate_receive_declaration(
      input rdma_sge sges[$],
      input int unsigned declared_sge_count,
      input longint unsigned declared_payload_len,
      output int unsigned canonical_sge_count,
      output longint unsigned canonical_payload_len
  );
    rdma_status status;

    canonical_sge_count = 0;
    canonical_payload_len = 0;
    status = derive_receive(
        sges, canonical_sge_count, canonical_payload_len);
    if (!status.ok())
      return status;
    if (canonical_sge_count != declared_sge_count) begin
      canonical_sge_count = 0;
      canonical_payload_len = 0;
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE SGE_NUM does not match canonical SGE count");
    end
    if (canonical_payload_len != declared_payload_len) begin
      canonical_sge_count = 0;
      canonical_payload_len = 0;
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE payload length does not match canonical SGE sum");
    end
    return rdma_status::success();
  endfunction
endclass

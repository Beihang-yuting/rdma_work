// 目录：硬件编解码层 codec/rdma。
// 职责：集中维护 SQ/RQ typed SGE 的只读计数与 payload 长度 authority，供
//   queue model 和 fixed-layout codec 共同消费，避免多个 caller 分别推导 wire SGE_NUM。
// 依赖：消费 rdma_sge、RDMA_MAX_WQ_SGE 和 rdma_status；不访问 queue runtime、
//   Host-memory、PCIe、manager 或任何外部资源账本。
// 所有权与生命周期：本模块只返回 detached 数值结果，不保存输入 SGE 引用，
//   不拥有 SGE、SGB 或外部 mapping；输入对象的生命周期由调用方负责。

// 中文说明：SGE authority 是 codec/model 之间的纯值边界。SQ 使用非零长度
// descriptor 数，RQ 使用驱动过滤后的数量与总长度；两者都必须先完成这一步，
// 再由 caller 决定 mode、wire 字段或 external-SGB descriptor 的发布。

class rdma_sge_authority extends uvm_object;
  `uvm_object_utils(rdma_sge_authority)

  // 功能：构造只读 SGE authority helper 的 UVM 对象；该对象不保存任何输入列表，
  //   仅作为静态计算接口的命名空间。
  // 输入/输出及副作用：name（输入）；new 初始化 UVM 名称，不创建或接管 SGE、
  //   descriptor、Host-memory 或 queue 资源。
  // 失败/边界：构造成功不代表任何 SGE 统计已经完成；调用方仍必须检查各静态函数
  //   返回的 rdma_status，不能把默认零计数当作有效 wire authority。
  function new(string name = "rdma_sge_authority");
    super.new(name);
  endfunction

  // 功能：count_nonzero 统计 SQ payload 中长度非零的 typed SGE，得到 payload
  //   mode 选择和 canonical SQE.SGE_NUM 共用的有效 descriptor 数。
  // 输入/输出及副作用：sges（输入 queue）；count（输出）被置为非零长度项数，
  //   只读每个元素及 length，不修改 SGE 或调用方 queue，也不取得其所有权。
  // 失败/边界：null SGE 不在此处替代 SQ shape gate 的拒绝；因此 null 只是不计数，
  //   仍由上层 validate_payload_shape() 返回 INVALID_ARGUMENT。超过硬件数量的
  //   列表不在此函数截断，后续 codec width/driver-limit gate 必须继续拒绝。
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

  // 功能：derive_typed_common 按统一的 typed SGE admission 规则计算 SQE 或
  //   RQE 的有效 descriptor 数与 payload 总长度，集中维护原始列表上限、null、
  //   reserved bit31、2GiB sentinel 和输出原子性，避免两个方向的规则漂移。
  // 输入/输出及副作用：sges 与 role_name 为只读输入；valid_sge_count 和
  //   valid_payload_len 成功时输出过滤后的 canonical 值；函数只读每个 SGE，
  //   不修改列表、模型、descriptor 或外部 backing。
  // 失败/边界：role_name 仅用于保持 SQE/RQE 原有诊断文案；列表超过 32 项、
  //   含 null、出现除 0x8000_0000 外的 bit31、累计长度超过 2GiB 或有效数量
  //   超限时返回 INVALID_ARGUMENT，并把两个 output 保持为零，禁止发布半成品。
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

  // 功能：derive_send 复现驱动 send WQE 的 canonical SGE authority：过滤零长度
  //   descriptor、校验每个有效长度并累加 payload_len，供 RC/UD codec 与 SQ-SGB
  //   writer 共用同一份 SGE_NUM/总长度事实源。
  // 输入/输出及副作用：sges（输入 queue）；valid_sge_count 与 valid_payload_len
  //   （输出）成功时分别得到有效 descriptor 数和总字节数；函数只读 SGE 字段，
  //   不修改 model、descriptor bytes、Host-memory 或任何外部账本。
  // 失败/边界：原始列表超过 RDMA_MAX_WQ_SGE、包含 null、出现除 0x8000_0000
  //   外的 bit31 长度、有效数量超过上限或总长度超过 2GiB 时返回
  //   INVALID_ARGUMENT，两个 output 保持零，调用方不得发布部分 authority。
  static function rdma_status derive_send(
      input rdma_sge sges[$],
      output int unsigned valid_sge_count,
      output longint unsigned valid_payload_len
  );
    return derive_typed_common(
        sges, "SQE", valid_sge_count, valid_payload_len);
  endfunction

  // 功能：derive_receive 复现驱动 receive WQE 的 canonical authority：过滤零长度
  //   SGE、统计有效数量并累加 payload_len，供 RQE resolve/encode 共用。
  // 输入/输出及副作用：sges（输入 queue）；valid_sge_count 与 valid_payload_len
  //   （输出）成功时分别得到有效 descriptor 数和总字节数；函数只读输入对象。
  // 失败/边界：列表超过 RDMA_MAX_WQ_SGE、包含 null、出现除 0x8000_0000 外的
  //   bit31 长度、数量超过上限或总长度超过 2GiB 时返回 INVALID_ARGUMENT，且
  //   两个 output 保持零，调用方不得发布部分 authority。
  static function rdma_status derive_receive(
      input rdma_sge sges[$],
      output int unsigned valid_sge_count,
      output longint unsigned valid_payload_len
  );
    return derive_typed_common(
        sges, "RQE", valid_sge_count, valid_payload_len);
  endfunction

  // 功能：validate_receive_declaration 将 RQE typed SGE 列表的 canonical 统计与
  //   caller 已声明的 SGE_NUM/payload_len 做一次原子一致性校验，统一 resolve、
  //   external-SGB authority setter 和 descriptor builder 的 typed admission。
  // 输入/输出及副作用：sges、declared_sge_count、declared_payload_len 为只读输入；
  //   canonical_sge_count 与 canonical_payload_len 为输出，成功时发布 detached
  //   统计值；函数只读 SGE，不修改模型字段、descriptor、Host-memory 或外部账本。
  // 失败/边界：raw 列表包含 null、保留 bit31、超过 32 项或总长度超过 2GiB 时
  //   透传 derive_receive 的 INVALID_ARGUMENT；声明数量或长度与 canonical 统计不等
  //   时返回 INVALID_ARGUMENT，两个输出保持零，调用方不得发布部分 authority。
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

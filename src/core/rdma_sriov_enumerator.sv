// 目录：核心执行层 src/core/。
// 职责：实现 PCIe SR-IOV PF 前门枚举 sequence，串联 capability 读取、BAR sizing/
//   分配、NumVFs/VF BAR/Control 编程、VF BDF 验证和 BAR decoder 检查。
// 依赖：rdma_pcie_api、rdma_pcie_bar_allocator、rdma_model_pkg 中的 Function 快照；
//   不依赖具体 PCIe 实现类型，所有配置访问都经过统一 rdma_pcie_api。
// 所有权与生命周期：enumerator 不拥有 PCIe adapter 或 allocator；本地 lease 数组只
//   保存本次 sequence 的非拥有引用，失败时负责调用 allocator.release()，成功后由调用方管理。

class rdma_sriov_enumerator extends uvm_object;
  `uvm_object_utils(rdma_sriov_enumerator)

  protected rdma_pcie_api pcie;
  protected rdma_pcie_bar_allocator allocator;
  protected bit configured;

  // 功能：构造未绑定的 SR-IOV enumerator，清除后端引用和运行状态。
  // 输入/输出及副作用：name（输入）；初始化本地字段，不发送 PCIe 事务。
  // 失败/边界：configure() 成功前 enumerate_and_configure_pf() 必须返回 INVALID_STATE。
  function new(string name = "rdma_sriov_enumerator");
    super.new(name);
    pcie = null;
    allocator = null;
    configured = 1'b0;
  endfunction

  // 功能：绑定统一 PCIe API 和 64-bit BAR allocator，建立 sequence 运行边界。
  // 输入/输出及副作用：new_pcie/new_allocator（输入）；成功时保存非拥有引用并置 configured。
  // 失败/边界：任一依赖为空或 allocator 未配置时返回 INVALID_ARGUMENT/INVALID_STATE，旧绑定不变。
  function rdma_status configure(
    rdma_pcie_api new_pcie,
    rdma_pcie_bar_allocator new_allocator
  );
    if (new_pcie == null || new_allocator == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SR-IOV enumerator dependency is null");
    if (new_allocator.active_lease_count() != 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "BAR allocator has leases from another sequence");
    pcie = new_pcie;
    allocator = new_allocator;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：生成带 PCIe 来源和阶段信息的枚举状态快照。
  // 输入/输出及副作用：code/message/pf_bdf（输入）；返回 detached status，不修改配置。
  // 失败/边界：pf_bdf 仅用于诊断；错误码保持原始类别，不在此函数重试或降级。
  protected function automatic rdma_status make_status(
    rdma_status_code_e code,
    string message,
    rdma_bdf_t pf_bdf = '0
  );
    rdma_status result;
    result = rdma_status::make(code, message);
    result.source_engine = RDMA_ENGINE_PCIE;
    return result;
  endfunction

  // 功能：把 PCIe/allocator 返回的 status 规范化为非空对象。
  // 输入/输出及副作用：非空原样返回；null 转为带 PF 诊断的 INVALID_STATE；不改 sequence 状态。
  // 失败/边界：null 视为外部违反返回契约；调用方须停止当前阶段并按需 rollback，不得读取 output 或发布 lease。
  protected function automatic rdma_status normalize_status(
    rdma_status candidate,
    string operation,
    rdma_bdf_t pf_bdf = '0
  );
    if (candidate == null)
      return make_status(
        RDMA_SC_INVALID_STATE,
        {operation, " returned null status"},
        pf_bdf
      );
    return candidate;
  endfunction

  // 功能：判断 BAR descriptor 的低 DWORD 是否声明 64-bit memory BAR。
  // 输入/输出及副作用：flags（输入）；返回 bit，不修改 descriptor 或 PCIe 配置。
  // 失败/边界：仅接受 type bits=2'b10；I/O BAR 或保留编码由调用方拒绝。
  protected function automatic bit bar_is_64bit(bit [31:0] flags);
    return flags[2:1] == 2'b10;
  endfunction

  // 功能：根据 PCIe BAR sizing mask 计算实际 aperture size。
  // 输入/输出及副作用：low/high/is_64bit（输入）、size（输出）；只计算局部值。
  // 失败/边界：mask 为零、非 2 的幂 size 或 64-bit BAR 高位不完整时返回 INVALID_STATE。
  protected function automatic rdma_status decode_bar_size(
    bit [31:0] low,
    bit [31:0] high,
    bit is_64bit,
    output longint unsigned size,
    rdma_bdf_t pf_bdf
  );
    bit [63:0] mask;
    longint unsigned candidate;

    size = 0;
    mask = is_64bit ? {high, low & 32'hffff_fff0} :
           {32'h0000_0000, low & 32'hffff_fff0};
    if (mask == 0)
      return make_status(RDMA_SC_INVALID_STATE,
                         "BAR sizing mask is zero", pf_bdf);
    candidate = (~mask) + 1'b1;
    if (candidate == 0 || (candidate & (candidate - 1'b1)) != 0 ||
        candidate < 64'd4096)
      return make_status(RDMA_SC_INVALID_STATE,
                         "BAR sizing mask is not a valid power-of-two aperture",
                         pf_bdf);
    size = candidate;
    return rdma_status::success();
  endfunction

  // 功能：执行一个 BAR low/high DWORD 的 sizing read/write 往返，得到后端宣告的 aperture。
  // 输入/输出及副作用：target/low_offset/flags（输入）、size（输出）；会向目标 Function
  //   发送 sizing write/read，之后由 program_bar() 写入分配地址。
  // 失败/边界：配置访问失败、offset 越界、64-bit pair 读写失败均立即返回且不分配 lease。
  protected task automatic size_bar(
    rdma_bdf_t target,
    rdma_cfg_offset_t low_offset,
    bit [31:0] flags,
    output longint unsigned size,
    output rdma_status status
  );
    bit [31:0] low_mask;
    bit [31:0] high_mask;
    bit is_64bit;

    size = 0;
    low_mask = 0;
    high_mask = 0;
    is_64bit = bar_is_64bit(flags);
    pcie.cfg_write32(target, low_offset, 32'hffff_ffff, 4'hf, status);
    status = normalize_status(status, "PCIe BAR sizing write", target);
    if (!status.ok())
      return;
    pcie.cfg_read32(target, low_offset, low_mask, status);
    status = normalize_status(status, "PCIe BAR sizing read", target);
    if (!status.ok())
      return;
    if (is_64bit) begin
      if (low_offset.value > 12'hff8) begin
        status = make_status(RDMA_SC_INVALID_ARGUMENT,
                             "64-bit BAR high DWORD offset overflows", target);
        return;
      end
      pcie.cfg_write32(target,
                       '{value:low_offset.value + 12'h004},
                       32'hffff_ffff, 4'hf, status);
      status = normalize_status(status, "PCIe BAR high sizing write", target);
      if (!status.ok())
        return;
      pcie.cfg_read32(target,
                      '{value:low_offset.value + 12'h004},
                      high_mask, status);
      status = normalize_status(status, "PCIe BAR high sizing read", target);
      if (!status.ok())
        return;
    end
    status = decode_bar_size(low_mask, high_mask, is_64bit, size, target);
  endtask

  // 功能：把已分配的 64-bit BAR base 写回 low/high 配置 DWORD。
  // 输入/输出及副作用：target/low_offset/base/flags 输入；成功时更新 canonical config image。
  // 失败/边界：高 DWORD offset 溢出或 cfg_write 失败返回错误；low DWORD 可能已写入，调用方须用 rollback_pf 恢复，状态不会自动回滚。
  protected task automatic program_bar(
    rdma_bdf_t target,
    rdma_cfg_offset_t low_offset,
    rdma_bar_addr_t base,
    bit [31:0] flags,
    output rdma_status status
  );
    bit is_64bit;

    is_64bit = bar_is_64bit(flags);
    pcie.cfg_write32(target, low_offset, base.value[31:0], 4'hf, status);
    status = normalize_status(status, "PCIe BAR programming write", target);
    if (!status.ok())
      return;
    if (is_64bit) begin
      if (low_offset.value > 12'hff8) begin
        status = make_status(RDMA_SC_INVALID_ARGUMENT,
                             "64-bit BAR high DWORD offset overflows", target);
        return;
      end
      pcie.cfg_write32(target,
                       '{value:low_offset.value + 12'h004},
                       base.value[63:32], 4'hf, status);
      status = normalize_status(status,
                                "PCIe BAR high programming write", target);
    end
  endtask

  // 功能：将 16-bit requester ID 转为 segment=0 的 RDMA BDF 值快照。
  // 输入/输出及副作用：rid（输入）；返回 BDF，不修改 manager 或 route 表。
  // 失败/边界：RID 本身没有错误码；调用方必须在计算前检查 65-bit 加法未溢出。
  protected function automatic rdma_bdf_t bdf_from_rid(bit [15:0] rid);
    rdma_bdf_t result;
    result.segment = 16'h0;
    result.bus = rid[15:8];
    result.device = rid[7:3];
    result.function_num = rid[2:0];
    return result;
  endfunction

  // 功能：计算 PF 对应 VF index 的 RID，使用 65-bit 中间值阻止 requester-ID 截断。
  // 输入/输出及副作用：pf_bdf/first_offset/stride/vf_index（输入）、vf_bdf（输出）；只计算局部值。
  // 失败/边界：任何加法、乘法溢出或结果超过 16-bit 返回 INVALID_ARGUMENT，vf_bdf 清零。
  protected function automatic rdma_status calculate_vf_bdf(
    rdma_bdf_t pf_bdf,
    bit [15:0] first_offset,
    bit [15:0] stride,
    int unsigned vf_index,
    output rdma_bdf_t vf_bdf
  );
    bit [64:0] first_wide;
    bit [64:0] span_wide;
    bit [64:0] rid_wide;
    bit [15:0] pf_rid;

    vf_bdf = '0;
    if (first_offset == 0 || stride == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "SR-IOV FirstVFOffset/VFStride is zero");
    pf_rid = rdma_bdf_requester_id(pf_bdf);
    first_wide = {49'd0, pf_rid} + {49'd0, first_offset};
    if (first_wide[64])
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "VF first RID addition overflows 16 bits");
    span_wide = {49'd0, vf_index} * {49'd0, stride};
    if (span_wide[64])
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "VF RID stride multiplication overflows");
    rid_wide = first_wide + span_wide;
    if (rid_wide[64] || rid_wide[63:16] != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "VF requester ID exceeds 16 bits");
    vf_bdf = bdf_from_rid(rid_wide[15:0]);
    return rdma_status::success();
  endfunction

  // 功能：失败路径：关闭 PF VFE/VF-MSE、清 NumVFs，逆序恢复读到的 PF/VF BAR，释放已发布 lease。
  // 输入/输出及副作用：向目标 PF 发 cleanup/restore 写，从 allocator 移除 leases，清空 discovered；只恢复成功读到的 descriptor。
  // 失败/边界：任一写失败只记录诊断并继续后续恢复与 lease 释放；调用方保留原始业务失败为主错误；未取得 valid 位不猜测旧 BAR。
  protected task automatic rollback_pf(
    rdma_bdf_t pf_bdf,
    bit [11:0] cap_offset,
    input bit [31:0] pf_bar_original[6],
    input bit pf_bar_original_valid[6],
    input bit [31:0] vf_bar_original[6],
    input bit vf_bar_original_valid[6],
    rdma_pcie_bar_lease leases[$],
    ref rdma_pcie_function_info discovered[$]
  );
    rdma_status cleanup_status;

    if (cap_offset != 0) begin
      pcie.cfg_write32(pf_bdf, '{value:cap_offset + 12'h008},
                        32'h0000_0000, 4'hf, cleanup_status);
      cleanup_status = normalize_status(cleanup_status,
                                        "SR-IOV rollback control write",
                                        pf_bdf);
      pcie.cfg_write32(pf_bdf, '{value:cap_offset + 12'h010},
                        32'h0000_0000, 4'hf, cleanup_status);
      cleanup_status = normalize_status(cleanup_status,
                                        "SR-IOV rollback NumVFs write",
                                        pf_bdf);
    end

    // 配置写入遵循“高 DWORD 在前、低 DWORD 在后”的逆序，避免 64-bit
    // BAR 在恢复过程中短暂拼出新旧地址混合值。VF 先于 PF 恢复，避免
    // disabled VF route 重新暴露 PF 的共享地址。
    for (int i = 5; i >= 0; i--) begin
      if (vf_bar_original_valid[i]) begin
        pcie.cfg_write32(pf_bdf,
                         '{value:cap_offset + 12'h024 + i * 12'h004},
                         vf_bar_original[i], 4'hf, cleanup_status);
        cleanup_status = normalize_status(cleanup_status,
                                          "SR-IOV rollback VF BAR write",
                                          pf_bdf);
      end
    end
    for (int i = 5; i >= 0; i--) begin
      if (pf_bar_original_valid[i]) begin
        pcie.cfg_write32(pf_bdf,
                         '{value:12'h010 + i * 12'h004},
                         pf_bar_original[i], 4'hf, cleanup_status);
        cleanup_status = normalize_status(cleanup_status,
                                          "SR-IOV rollback PF BAR write",
                                          pf_bdf);
      end
    end

    for (int i = leases.size() - 1; i >= 0; i--) begin
      cleanup_status = allocator.release_lease(leases[i]);
      cleanup_status = normalize_status(cleanup_status,
                                        "SR-IOV rollback BAR lease release",
                                        pf_bdf);
      // rollback 的主错误由调用方 status 保留；清理失败只影响诊断，不能
      // 阻止剩余 lease 继续尝试释放。
    end
    // Function 快照只有在整条 sequence 成功后才可发布；任何失败出口都必须
    // 丢弃已完成 VF 的局部结果，避免“返回失败但输出包含部分成功”的歧义。
    discovered.delete();
  endtask

  // 功能：执行标准 SR-IOV PF 枚举配置，输出每个已验证 VF 的 detached Function 快照。
  // 输入/输出及副作用：pf_bdf/requested_vfs 输入；discovered/status 输出；按序修改目标 PF 的 BAR/NumVFs/Control，成功时保留
  //   leases。
  // 失败/边界：任一 capability/config/BAR/Function 校验失败即关闭 VFE、清 NumVFs、释放 leases 并清空 discovered；RID
  //   与地址运算做 65 位检查，不发布部分成功的 VF。
  task enumerate_and_configure_pf(
    rdma_bdf_t pf_bdf,
    int unsigned requested_vfs,
    output rdma_pcie_function_info discovered[$],
    output rdma_status status
  );
    rdma_pcie_function_info pf_info;
    rdma_pcie_sriov_info sriov;
    rdma_pcie_function_info vf_info;
    rdma_bar_decode decoded;
    rdma_pcie_bar_lease leases[$];
    rdma_pcie_bar_lease lease;
    longint unsigned pf_size[6];
    longint unsigned vf_size[6];
    bit [31:0] command_dw;
    bit [31:0] vendor_device_dw;
    bit [31:0] control_dw;
    bit [31:0] vf_flags;
    bit [31:0] pf_flags[6];
    bit [31:0] pf_desc[6];
    bit pf_desc_valid[6];
    bit [31:0] vf_desc[6];
    bit vf_desc_valid[6];
    bit [64:0] aggregate_wide;
    rdma_bdf_t vf_bdf;
    rdma_bar_addr_t vf_address;
    int owner;
    int vf_bar_owner_idx;
    bit owner_seen[6];

    discovered.delete();
    leases.delete();
    foreach (owner_seen[i]) owner_seen[i] = 1'b0;
    foreach (pf_desc_valid[i]) begin
      pf_desc_valid[i] = 1'b0;
      vf_desc_valid[i] = 1'b0;
      pf_desc[i] = '0;
      vf_desc[i] = '0;
    end
    status = rdma_status::success();
    if (!configured || pcie == null || allocator == null) begin
      status = make_status(RDMA_SC_INVALID_STATE,
                           "SR-IOV enumerator is not configured", pf_bdf);
      return;
    end
    if (rdma_bdf_is_zero(pf_bdf) || requested_vfs == 0) begin
      status = make_status(RDMA_SC_INVALID_ARGUMENT,
                           "PF BDF or requested VF count is invalid", pf_bdf);
      return;
    end

    status = pcie.get_function_info(pf_bdf, pf_info);
    status = normalize_status(status, "PF Function snapshot", pf_bdf);
    if (!status.ok())
      return;
    if (pf_info == null) begin
      status = make_status(RDMA_SC_INVALID_STATE,
                           "PF Function snapshot is null", pf_bdf);
      return;
    end
    status = pcie.discover_sriov(pf_bdf, sriov);
    status = normalize_status(status, "SR-IOV capability discovery", pf_bdf);
    if (!status.ok())
      return;

    // 枚举 sequence 只允许接管“完全关闭”的 PF。若 capability 快照已经
    //   带有 NumVFs、VFE 或 VF-MSE，说明该 PF 可能由另一条控制路径拥有；
    //   此时必须在任何 BAR sizing/programming、NumVFs 或 Control 写入之前
    //   fail-closed，避免清零/覆盖既有配置，也避免把外部 lease 误认成本次资源。
    if (sriov.num_vfs != 0 || sriov.vf_enable || sriov.vf_mse) begin
      status = make_status(
        RDMA_SC_INVALID_STATE,
        "PF SR-IOV state is already enabled; enumeration requires a quiescent PF",
        pf_bdf
      );
      return;
    end
    if (sriov.cap_offset == 0 || sriov.first_vf_offset == 0 ||
        sriov.vf_stride == 0 || sriov.total_vfs == 0 ||
        requested_vfs > sriov.total_vfs) begin
      status = make_status(RDMA_SC_INVALID_ARGUMENT,
                           "SR-IOV capability cannot satisfy requested VF count",
                           pf_bdf);
      return;
    end

    // 先对 PF 的每个 low-owner BAR 执行 sizing，再一次性分配/写入地址。
    // 先读取所有 PF BAR descriptor；必须在写入任一 low/high pair 前完成快照，
    // 否则给 BAR0 分配高于 4 GiB 的地址会把 BAR1 误看成独立 32-bit BAR。
    foreach (pf_info.bar[i]) begin
      if (pf_info.bar[i].size == 0)
        continue;
      pcie.cfg_read32(pf_bdf,
                      '{value:12'h010 + i * 12'h004},
                      pf_desc[i], status);
      status = normalize_status(status, "PF BAR descriptor read", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      pf_desc_valid[i] = 1'b1;
    end

    // 若 Function snapshot 省略了 64-bit owner 的 high DWORD，也要在任何
    // sizing/programming 前单独取回；否则失败回滚没有可依据的高半部。
    foreach (pf_info.bar[i]) begin
      owner = int'(pf_info.bar[i].bar_id);
      if (owner < 0 || owner >= 6) begin
        status = make_status(RDMA_SC_INVALID_ARGUMENT,
                             "PF BAR owner index is invalid", pf_bdf);
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      if (pf_info.bar[i].size == 0 || !pf_desc_valid[owner] ||
          !bar_is_64bit(pf_desc[owner]))
        continue;
      if (owner >= 5) begin
        status = make_status(RDMA_SC_INVALID_ARGUMENT,
                             "64-bit PF BAR has no high DWORD", pf_bdf);
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      if (pf_desc_valid[owner + 1])
        continue;
      pcie.cfg_read32(pf_bdf,
                      '{value:12'h010 + (owner + 1) * 12'h004},
                      pf_desc[owner + 1], status);
      status = normalize_status(status, "PF BAR high descriptor read", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      pf_desc_valid[owner + 1] = 1'b1;
    end
    foreach (pf_info.bar[i]) begin
      owner = int'(pf_info.bar[i].bar_id);
      if (owner < 0 || owner >= 6) begin
        status = make_status(RDMA_SC_INVALID_ARGUMENT,
                             "PF BAR owner index is invalid", pf_bdf);
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      if (owner_seen[owner] || pf_info.bar[i].size == 0)
        continue;
      if (owner > 0 && bar_is_64bit(pf_desc[owner - 1]) &&
          !bar_is_64bit(pf_desc[owner]))
        continue;
      owner_seen[owner] = 1'b1;
      pf_flags[owner] = pf_desc[owner] & 32'h0000_0007;
      size_bar(pf_bdf,
               '{value:12'h010 + owner * 12'h004},
               pf_flags[owner],
               pf_size[owner], status);
      status = normalize_status(status, "PF BAR sizing", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      status = allocator.allocate(pf_bdf, pf_size[owner], pf_size[owner], lease);
      status = normalize_status(status, "PF BAR lease allocation", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      leases.push_back(lease);
      program_bar(pf_bdf,
                  '{value:12'h010 + owner * 12'h004},
                  lease.base, pf_flags[owner], status);
      status = normalize_status(status, "PF BAR programming", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
    end

    // VF BAR descriptor 也先整体快照，避免先写入低 DWORD 后高 DWORD 读取到
    //   分配地址而误判为另一个 BAR。
    foreach (sriov.vf_bar_size[i]) begin
      if (sriov.vf_bar_size[i] == 0)
        continue;
      pcie.cfg_read32(pf_bdf,
                      '{value:sriov.cap_offset + 12'h024 + i * 12'h004},
                      vf_desc[i], status);
      status = normalize_status(status, "VF BAR descriptor read", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      vf_desc_valid[i] = 1'b1;
    end

    // vf_bar_owner 是驱动 capability 的三位 owner 编码，合法值只有 0..5。
    // 不能把 3'b111 等保留编码回退为循环下标，否则 malformed capability 会
    // 被误当成合法 BAR 并继续写入地址。
    foreach (sriov.vf_bar_owner[i]) begin
      if (sriov.vf_bar_owner[i] > 5) begin
        status = make_status(RDMA_SC_INVALID_ARGUMENT,
                             "VF BAR owner encoding is invalid", pf_bdf);
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
    end

    // 与 PF 相同，VF 64-bit owner 的 high DWORD 必须在第一次 sizing 前
    // 快照；valid 位不足时只恢复已确认的 DWORD，不凭默认零值覆盖配置。
    foreach (sriov.vf_bar_size[i]) begin
      owner = int'(sriov.vf_bar_owner[i]);
      if (owner != i || sriov.vf_bar_size[i] == 0 ||
          !vf_desc_valid[owner] || !bar_is_64bit(vf_desc[owner]))
        continue;
      if (owner >= 5) begin
        status = make_status(RDMA_SC_INVALID_ARGUMENT,
                             "64-bit VF BAR has no high DWORD", pf_bdf);
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      if (vf_desc_valid[owner + 1])
        continue;
      pcie.cfg_read32(pf_bdf,
                      '{value:sriov.cap_offset + 12'h024 +
                              (owner + 1) * 12'h004},
                      vf_desc[owner + 1], status);
      status = normalize_status(status, "VF BAR high descriptor read", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      vf_desc_valid[owner + 1] = 1'b1;
    end

    // VF BAR size 是每个 VF 的 aperture，allocator 预留 aggregate span。
    foreach (sriov.vf_bar_size[i]) begin
      owner = int'(sriov.vf_bar_owner[i]);
      if (owner != i || sriov.vf_bar_size[owner] == 0)
        continue;
      if (owner > 0 && bar_is_64bit(vf_desc[owner - 1]) &&
          !bar_is_64bit(vf_desc[owner]))
        continue;
      vf_flags = vf_desc[owner] & 32'h0000_0007;
      size_bar(pf_bdf,
               '{value:sriov.cap_offset + 12'h024 + owner * 12'h004},
               vf_flags, vf_size[owner], status);
      status = normalize_status(status, "VF BAR sizing", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      aggregate_wide = {1'b0, vf_size[owner]} * requested_vfs;
      if (aggregate_wide[64]) begin
        status = make_status(RDMA_SC_INVALID_ARGUMENT,
                             "VF BAR aggregate size overflows 64 bits", pf_bdf);
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      status = allocator.allocate(pf_bdf, aggregate_wide[63:0],
                                  vf_size[owner], lease);
      status = normalize_status(status, "VF BAR lease allocation", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      leases.push_back(lease);
      program_bar(pf_bdf,
                  '{value:sriov.cap_offset + 12'h024 + owner * 12'h004},
                  lease.base, vf_flags, status);
      status = normalize_status(status, "VF BAR programming", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
    end

    // NumVFs 必须先于 Control.VFE 写入；Control 同时打开 ARI hierarchy、VF-MSE 和 VFE。
    pcie.cfg_write32(pf_bdf, '{value:sriov.cap_offset + 12'h010},
                     requested_vfs, 4'hf, status);
    status = normalize_status(status, "SR-IOV NumVFs write", pf_bdf);
    if (!status.ok()) begin
      rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
      return;
    end
    control_dw = 32'h0000_0000;
    control_dw[0] = 1'b1;
    control_dw[3] = sriov.ari_capable_hierarchy;
    control_dw[4] = 1'b1;
    pcie.cfg_write32(pf_bdf, '{value:sriov.cap_offset + 12'h008},
                     control_dw, 4'hf, status);
    status = normalize_status(status, "SR-IOV control write", pf_bdf);
    if (!status.ok()) begin
      rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
      return;
    end

    // 逐 VF 读取 Vendor/Device/Command，并通过 Function snapshot + BAR decoder 验证路由。
    for (int unsigned vf = 0; vf < requested_vfs; vf++) begin
      status = calculate_vf_bdf(pf_bdf, sriov.first_vf_offset,
                                sriov.vf_stride, vf, vf_bdf);
      status = normalize_status(status, "VF BDF calculation", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      pcie.cfg_read32(vf_bdf, '{value:12'h000}, vendor_device_dw, status);
      status = normalize_status(status, "VF vendor/device read", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      if (vendor_device_dw == 32'hffff_ffff ||
          vendor_device_dw[15:0] == 16'hffff) begin
        status = make_status(RDMA_SC_PCIE_COMPLETION,
                             "VF Vendor ID configuration read failed", pf_bdf);
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      pcie.cfg_read32(vf_bdf, '{value:12'h004}, command_dw, status);
      status = normalize_status(status, "VF command read", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      status = pcie.get_function_info(vf_bdf, vf_info);
      status = normalize_status(status, "VF Function snapshot", pf_bdf);
      if (!status.ok()) begin
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      if (vf_info == null || !rdma_bdf_same(vf_info.bdf, vf_bdf)) begin
        status = make_status(RDMA_SC_INVALID_STATE,
                             "VF Function identity did not become active", pf_bdf);
        rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
        return;
      end
      foreach (vf_info.bar[bar]) begin
        // 64-bit VF BAR 的高 DWORD 只是低 owner 的地址高半部，decoder
        // 始终返回低 owner BAR 编号；枚举验证必须跳过重复的 high DWORD。
        vf_bar_owner_idx = int'(sriov.vf_bar_owner[bar]);
        if (bar != vf_bar_owner_idx)
          continue;
        if (!vf_info.bar[bar].enabled || vf_info.bar[bar].size == 0)
          continue;
        vf_address = vf_info.bar[bar].base;
        status = pcie.decode_bar(vf_address, decoded);
        status = normalize_status(status, "VF BAR decode", pf_bdf);
        if (!status.ok()) begin
          rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
          return;
        end
        if (decoded == null || !rdma_bdf_same(decoded.target_bdf, vf_bdf) ||
            decoded.bar_id != bar || decoded.bar_offset != 0) begin
          status = make_status(RDMA_SC_INVALID_STATE,
                               "VF BAR decoder did not resolve Function aperture", pf_bdf);
          rollback_pf(pf_bdf, sriov.cap_offset,
                    pf_desc, pf_desc_valid, vf_desc, vf_desc_valid, leases,
                    discovered);
          return;
        end
      end
      discovered.push_back(vf_info);
    end
    status = make_status(RDMA_SC_OK, "SR-IOV PF enumeration completed", pf_bdf);
  endtask
endclass

// 功能：提供旧调用方可识别的 rdma_function_manager 名称，复用同一 SR-IOV enumerator 实现。
// 输入/输出及副作用：继承 configure()/enumerate_and_configure_pf() 的全部接口和状态。
// 失败/边界：该兼容类不增加影子 Function topology，也不改变 enumerator 的回滚语义。
class rdma_function_manager extends rdma_sriov_enumerator;
  `uvm_object_utils(rdma_function_manager)

  // 功能：构造兼容 facade 并初始化基类 enumerator。
  // 输入/输出及副作用：name（输入）；只调用 super.new，不创建外部 PCIe 资源。
  // 失败/边界：所有前置依赖校验沿用 rdma_sriov_enumerator.configure()。
  function new(string name = "rdma_function_manager");
    super.new(name);
  endfunction
endclass

// 目录：适配器实现层 adapters/pcie_work/。
// 职责：把 pcie_work 的 Function manager、配置代理和 BAR decoder 封装成
//   RDMA 侧的 Function-aware PCIe 契约；RDMA 核心只依赖 rdma_pcie_api。
// 依赖：pcie_tl_pkg（外部 pcie_work）、rdma_types_pkg、rdma_model_pkg 和
//   rdma_adapter_pkg；不复制或接管外部 PCIe/Host-memory 对象的生命周期。
// 所有权与生命周期：func_mgr、bar_decoder、config_proxy 均为非拥有引用；
//   route_handles 保存 detached Function handle 快照，随 adapter 生命周期失效。

package rdma_pcie_work_adapter_pkg;
  import uvm_pkg::*;
  import pcie_tl_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_adapter_pkg::*;
  `include "uvm_macros.svh"

  class rdma_pcie_work_adapter extends rdma_pcie_api;
    `uvm_object_utils(rdma_pcie_work_adapter)

    // 外部 canonical PCIe 对象：adapter 只保存引用，不负责 new/delete。
    pcie_tl_func_manager func_mgr;
    pcie_tl_bar_decoder bar_decoder;
    pcie_tl_config_proxy config_proxy;
    bit model_bypass;
    bit configured;

    // UID -> detached route snapshot。BDF 和 object_id 由注册时锁定，
    // generation 在校验时与 manager 当前 generation 对齐以隔离 reset/rekey。
    rdma_function_handle route_handles[longint unsigned];
    rdma_bdf_t route_bdfs[longint unsigned];
    int unsigned route_generations[longint unsigned];

    // 最近一次成功的模型 MMIO 路由，便于 sequence/scoreboard 观察目标 Function。
    rdma_bar_decode last_mmio_route;
    byte last_mmio_payload[$];
    bit last_mmio_valid;

    // 功能：构造 PCIe adapter 并清空本地 registry/诊断快照，不创建外部 PCIe 对象。
    // 输入/输出及副作用：name（输入）；初始化 configured/model_bypass 和本地 route
    //   registry，返回一个未绑定后端的 adapter；不修改任何 manager 状态。
    // 失败/边界：构造成功不代表可用；在 configure() 成功前所有业务入口必须返回
    //   RDMA_SC_INVALID_STATE，且不应向外部 PCIe 发送事务。
    function new(string name = "rdma_pcie_work_adapter");
      super.new(name);
      func_mgr = null;
      bar_decoder = null;
      config_proxy = null;
      model_bypass = 1'b0;
      configured = 1'b0;
      route_handles.delete();
      route_bdfs.delete();
      route_generations.delete();
      last_mmio_route = null;
      last_mmio_payload.delete();
      last_mmio_valid = 1'b0;
    endfunction

    // 功能：创建带 PCIe 引擎来源和 Function 代际上下文的统一状态对象。
    // 输入/输出及副作用：code/message/function_uid/generation（输入）；返回 detached
    //   rdma_status，不修改 adapter、manager 或调用方对象。
    // 失败/边界：所有 code 均保留原始错误类别；零 UID/代际只表示调用方未提供上下文，
    //   不会被函数伪造为有效身份。
    function automatic rdma_status status_for(
      rdma_status_code_e code,
      string message,
      longint unsigned function_uid = 0,
      int unsigned generation = 0
    );
      rdma_status status;
      status = rdma_status::make(code, message);
      status.source_engine = RDMA_ENGINE_PCIE;
      status.function_uid = function_uid;
      status.generation = generation;
      return status;
    endfunction

    // 功能：检查 adapter 是否已绑定完整的 manager、decoder 和必要的配置代理。
    // 输入/输出及副作用：无显式参数；返回状态快照，不修改外部对象。
    // 失败/边界：configured、func_mgr、bar_decoder 缺失返回 INVALID_STATE；
    //   非 bypass 模式缺少 config_proxy 或 multi_function_mode 时同样 fail-closed。
    function automatic rdma_status validate_ready();
      if (!configured || func_mgr == null || bar_decoder == null)
        return status_for(RDMA_SC_INVALID_STATE,
                          "PCIe adapter is not configured");
      if (!model_bypass &&
          (config_proxy == null || !config_proxy.multi_function_mode))
        return status_for(RDMA_SC_INVALID_STATE,
                          "multi-function config proxy is unavailable");
      return rdma_status::success();
    endfunction

    // 功能：把外部 PCIe manager/decoder/proxy 连接到 adapter，并建立明确的
    //   model-bypass 边界；decoder/proxy 若已绑定其他 manager 则拒绝混接。
    // 输入/输出及副作用：new_func_mgr/new_bar_decoder/new_config_proxy（输入）、
    //   allow_model_bypass（输入）；成功时保存非拥有引用并设置 configured，返回状态。
    // 失败/边界：任一必需对象为空、decoder/proxy 指向不同 manager、或非 bypass 模式
    //   未开启 multi_function_mode 时返回 INVALID_ARGUMENT/INVALID_STATE，旧绑定不变。
    function rdma_status configure(
      pcie_tl_func_manager new_func_mgr,
      pcie_tl_bar_decoder new_bar_decoder,
      pcie_tl_config_proxy new_config_proxy,
      bit allow_model_bypass = 1'b0
    );
      if (new_func_mgr == null || new_bar_decoder == null)
        return status_for(RDMA_SC_INVALID_ARGUMENT,
                          "PCIe manager or BAR decoder is null");
      if (new_bar_decoder.func_mgr != null &&
          new_bar_decoder.func_mgr != new_func_mgr)
        return status_for(RDMA_SC_INVALID_STATE,
                          "BAR decoder is bound to another function manager");
      if (new_config_proxy != null && new_config_proxy.func_mgr != null &&
          new_config_proxy.func_mgr != new_func_mgr)
        return status_for(RDMA_SC_INVALID_STATE,
                          "config proxy is bound to another function manager");
      if (!allow_model_bypass &&
          (new_config_proxy == null || !new_config_proxy.multi_function_mode))
        return status_for(RDMA_SC_INVALID_STATE,
                          "multi-function config proxy is required");

      new_bar_decoder.func_mgr = new_func_mgr;
      if (new_config_proxy != null)
        new_config_proxy.func_mgr = new_func_mgr;
      func_mgr = new_func_mgr;
      bar_decoder = new_bar_decoder;
      config_proxy = new_config_proxy;
      model_bypass = allow_model_bypass;
      configured = 1'b1;
      route_handles.delete();
      route_bdfs.delete();
      route_generations.delete();
      last_mmio_route = null;
      last_mmio_payload.delete();
      last_mmio_valid = 1'b0;
      return status_for(RDMA_SC_OK, "PCIe adapter configured");
    endfunction

    // 功能：把 RDMA BDF 快照转换为 pcie_work 使用的 16 位 Routing ID。
    // 输入/输出及副作用：bdf（输入）；返回值为 bus/device/function 拼接结果，不修改
    //   BDF 或 manager；segment 必须由调用方先检查。
    // 失败/边界：pcie_work manager 只有 16 位 BDF；调用方必须先由
    //   lookup_context() 检查 segment，避免本函数被误用为静默截断转换器。
    function automatic bit [15:0] raw_bdf(rdma_bdf_t bdf);
      return rdma_bdf_requester_id(bdf);
    endfunction

    // 功能：验证 RDMA BDF 能否在当前 manager 中查到唯一 enabled Function。
    // 输入/输出及副作用：bdf（输入）、ctx（输出）；ctx 为外部非拥有引用，成功时仅供
    //   当前调用读取，不转移其生命周期。
    // 失败/边界：非零 segment、未知 BDF 和 disabled VF 分别返回 PCIE_COMPLETION 或
    //   INVALID_STATE；不会退回 PF0 或 profile 默认 Function。
    function automatic rdma_status lookup_context(
      rdma_bdf_t bdf,
      output pcie_tl_func_context ctx
    );
      ctx = null;
      if (bdf.segment != 16'h0)
        return status_for(RDMA_SC_PCIE_COMPLETION,
                          "pcie_work backend has no non-zero segment route");
      ctx = func_mgr.lookup_by_bdf(raw_bdf(bdf));
      if (ctx == null)
        return status_for(RDMA_SC_PCIE_COMPLETION,
                          $sformatf("unknown PCIe BDF %04h", raw_bdf(bdf)));
      if (!ctx.enabled)
        return status_for(RDMA_SC_INVALID_STATE,
                          $sformatf("PCIe Function BDF %04h is disabled",
                                    raw_bdf(bdf)));
      return rdma_status::success();
    endfunction

    // 功能：从 PF/VF context 和其配置空间生成 detached RDMA Function 信息，统一
    //   投影 BDF、父 PF、MSE/BME 及 BAR aperture。
    // 输入/输出及副作用：bdf（输入）、info（输出）；info 由 adapter 新建并由调用方
    //   持有；不修改 manager/context。
    // 失败/边界：unknown/disabled BDF、缺失 cfg_mgr 或 SR-IOV capability 返回明确错误；
    //   VF BAR 优先使用 SR-IOV VF BAR aggregate base，不使用未配置的 VF context base。
    virtual function rdma_status get_function_info(
      rdma_bdf_t bdf,
      output rdma_pcie_function_info info
    );
      pcie_tl_func_context ctx;
      rdma_status status;
      bit [31:0] command_dw;
      pcie_tl_sriov_cap sc;
      longint unsigned vf_base;
      int owner;

      info = rdma_pcie_function_info::type_id::create("pcie_function_info");
      status = validate_ready();
      if (!status.ok())
        return status;
      status = lookup_context(bdf, ctx);
      if (!status.ok())
        return status;
      if (ctx.cfg_mgr == null)
        return status_for(RDMA_SC_INVALID_STATE,
                          "PCIe Function has no config-space manager");

      info.bdf = bdf;
      info.parent_pf_bdf = '0;
      info.vf_index = 0;
      if (ctx.is_vf) begin
        if (ctx.pf_index < 0 || ctx.pf_index >= func_mgr.sriov_caps.size() ||
            ctx.pf_index >= func_mgr.pf_ctx.size() ||
            ctx.pf_index >= func_mgr.vf_ctx.size() ||
            func_mgr.sriov_caps[ctx.pf_index] == null ||
            func_mgr.pf_ctx[ctx.pf_index] == null ||
            ctx.vf_index < 0 ||
            ctx.vf_index >= func_mgr.vf_ctx[ctx.pf_index].size())
          return status_for(RDMA_SC_INVALID_STATE,
                            "VF has no valid parent SR-IOV context");
        info.parent_pf_bdf = '{segment:16'h0,
                              bus:func_mgr.pf_ctx[ctx.pf_index].bdf[15:8],
                              device:func_mgr.pf_ctx[ctx.pf_index].bdf[7:3],
                              function_num:func_mgr.pf_ctx[ctx.pf_index].bdf[2:0]};
        info.vf_index = ctx.vf_index;
        sc = func_mgr.sriov_caps[ctx.pf_index];
      end

      command_dw = ctx.cfg_mgr.read(12'h004);
      info.mse = command_dw[1];
      info.bme = command_dw[2];
      foreach (info.bar[i]) begin
        info.bar[i].bar_id = i;
        info.bar[i].base = '0;
        info.bar[i].size = '0;
        info.bar[i].enabled = 1'b0;
        owner = ctx.bar_owner[i];
        if (owner < 0 || owner >= 6)
          owner = i;
        if (!ctx.is_vf) begin
          info.bar[i].base = '{value:ctx.bar_base[owner]};
          info.bar[i].size = ctx.bar_size[owner];
          info.bar[i].enabled = ctx.enabled && ctx.bar_enable[owner] &&
                                (owner == i || ctx.bar_size[owner] != 0);
        end
        else if (sc != null && sc.vf_bar_size[owner] != 0) begin
          vf_base = sc.vf_bar[owner] +
                    longint'(ctx.vf_index) * sc.vf_bar_size[owner];
          info.bar[i].base = '{value:vf_base};
          info.bar[i].size = sc.vf_bar_size[owner];
          info.bar[i].enabled = ctx.enabled && sc.vf_enable && sc.vf_mse &&
                                (owner == i || sc.vf_bar_size[owner] != 0);
        end
      end
      return status_for(RDMA_SC_OK, "PCIe Function snapshot ready",
                        0, int'(func_mgr.config_generation));
    endfunction

    // 功能：读取 PF 的 SR-IOV capability，返回与 manager 脱离的参数和 VF BAR 快照。
    // 输入/输出及副作用：pf_bdf（输入）、info（输出）；只读 manager，不启用/禁用 VF，
    //   输出数组由值复制生成。
    // 失败/边界：VF BDF、unknown/disabled PF、缺失 capability 或非法 PF index 返回
    //   INVALID_ARGUMENT/PCIE_COMPLETION/INVALID_STATE；不根据 vf_index 猜测 capability。
    virtual function rdma_status discover_sriov(
      rdma_bdf_t pf_bdf,
      output rdma_pcie_sriov_info info
    );
      pcie_tl_func_context ctx;
      pcie_tl_sriov_cap sc;
      rdma_status status;

      info = '{default:'0};
      status = validate_ready();
      if (!status.ok())
        return status;
      status = lookup_context(pf_bdf, ctx);
      if (!status.ok())
        return status;
      if (ctx.is_vf || ctx.pf_index < 0 ||
          ctx.pf_index >= func_mgr.sriov_caps.size())
        return status_for(RDMA_SC_INVALID_ARGUMENT,
                          "SR-IOV discovery target is not a PF");
      sc = func_mgr.sriov_caps[ctx.pf_index];
      if (sc == null)
        return status_for(RDMA_SC_INVALID_STATE,
                          "PF has no SR-IOV capability");
      info.cap_offset = sc.offset;
      info.first_vf_offset = sc.first_vf_offset;
      info.vf_stride = sc.vf_stride;
      info.total_vfs = sc.total_vfs;
      info.num_vfs = sc.num_vfs;
      info.ari_capable_hierarchy = sc.ari_capable_hierarchy;
      info.ari_capable = sc.ari_capable;
      info.vf_enable = sc.vf_enable;
      info.vf_mse = sc.vf_mse;
      info.vf_device_id = sc.vf_device_id;
      foreach (info.vf_bar_base[i]) begin
        info.vf_bar_base[i] = sc.vf_bar[i];
        info.vf_bar_size[i] = sc.vf_bar_size[i];
        info.vf_bar_flags[i] = sc.vf_bar_flags[i];
        info.vf_bar_owner[i] = sc.vf_bar_owner[i];
      end
      return status_for(RDMA_SC_OK, "SR-IOV capability discovered",
                        0, int'(func_mgr.config_generation));
    endfunction

    // 功能：把 byte-enable mask 转换为 config_proxy 所需的连续 byte offset/length。
    // 输入/输出及副作用：byte_enable（输入）、byte_offset/byte_length（输出）；只计算
    //   局部值，不更新 config space。
    // 失败/边界：零 mask、非连续 mask（例如 0101）或越界 mask 返回 0；允许 1/2/3/4
    //   字节连续写，调用方据此 fail-closed。
    function automatic bit decode_byte_enable(
      bit [3:0] byte_enable,
      output int byte_offset,
      output int byte_length
    );
      int first;
      int last;
      byte_offset = 0;
      byte_length = 0;
      first = -1;
      last = -1;
      for (int lane = 0; lane < 4; lane++) begin
        if (byte_enable[lane] && first < 0)
          first = lane;
        if (byte_enable[lane])
          last = lane;
      end
      if (first < 0)
        return 1'b0;
      byte_offset = first;
      byte_length = last - first + 1;
      for (int lane = first; lane <= last; lane++)
        if (!byte_enable[lane])
          return 1'b0;
      return 1'b1;
    endfunction

    // 功能：通过 config_proxy/manager 读取目标 Function 的一个 32-bit 配置 DWORD。
    // 输入/输出及副作用：target/offset（输入）、data/status（输出）；成功时 data 来自
    //   canonical config image；不推进任何 RDMA 队列或修改配置。
    // 失败/边界：offset 必须 4-byte 对齐且不超过 0xffc；unknown BDF 返回
    //   PCIE_COMPLETION；非零 segment、缺失 proxy/backend 或代理拒绝均不伪造成功。
    virtual task cfg_read32(
      rdma_bdf_t target,
      rdma_cfg_offset_t offset,
      output bit [31:0] data,
      output rdma_status status
    );
      pcie_tl_func_context ctx;
      bit accepted;

      data = 32'hffff_ffff;
      status = validate_ready();
      if (!status.ok())
        return;
      if (offset.value[1:0] != 2'b00 || offset.value > 12'hffc) begin
        status = status_for(RDMA_SC_INVALID_ARGUMENT,
                            "config offset is not an aligned DWORD");
        return;
      end
      status = lookup_context(target, ctx);
      if (!status.ok())
        return;
      if (config_proxy != null && config_proxy.multi_function_mode) begin
        accepted = config_proxy.handle_cfg_read_bdf(
          raw_bdf(target), int'(offset.value >> 2), data);
        if (!accepted) begin
          status = status_for(RDMA_SC_PCIE_COMPLETION,
                              "config proxy rejected CfgRd");
          return;
        end
      end
      else if (model_bypass) begin
        data = func_mgr.cfg_read(raw_bdf(target), offset.value);
      end
      else begin
        status = status_for(RDMA_SC_INVALID_STATE,
                            "config read backend is unavailable");
        return;
      end
      status = status_for(RDMA_SC_OK, "config read completed",
                          0, int'(func_mgr.config_generation));
    endtask

    // 功能：向目标 Function 提交带连续 byte-enable 的 32-bit 配置写，并让
    //   config_proxy 负责 SR-IOV、BAR、MSE/BME 与 BDF LUT 的 canonical 更新。
    // 输入/输出及副作用：target/offset/data/byte_enable（输入）、status（输出）；成功
    //   时外部 config image 可能改变并递增 manager generation。
    // 失败/边界：offset 未对齐、byte_enable 非连续/为零、unknown BDF、代理缺失或拒绝
    //   均 fail-closed；失败路径不写入部分 config 字节。
    virtual task cfg_write32(
      rdma_bdf_t target,
      rdma_cfg_offset_t offset,
      bit [31:0] data,
      bit [3:0] byte_enable,
      output rdma_status status
    );
      pcie_tl_func_context ctx;
      int byte_offset;
      int byte_length;
      bit accepted;
      bit [31:0] packed_data;

      status = validate_ready();
      if (!status.ok())
        return;
      if (offset.value[1:0] != 2'b00 || offset.value > 12'hffc) begin
        status = status_for(RDMA_SC_INVALID_ARGUMENT,
                            "config offset is not an aligned DWORD");
        return;
      end
      if (!decode_byte_enable(byte_enable, byte_offset, byte_length)) begin
        status = status_for(RDMA_SC_INVALID_ARGUMENT,
                            "config byte enable is empty or non-contiguous");
        return;
      end
      status = lookup_context(target, ctx);
      if (!status.ok())
        return;
      packed_data = data >> (byte_offset * 8);
      if (config_proxy != null && config_proxy.multi_function_mode) begin
        accepted = config_proxy.handle_cfg_write_bdf(
          raw_bdf(target), int'(offset.value >> 2), packed_data,
          byte_offset, byte_length);
        if (!accepted) begin
          status = status_for(RDMA_SC_PCIE_COMPLETION,
                              "config proxy rejected CfgWr");
          return;
        end
      end
      else if (model_bypass) begin
        func_mgr.cfg_write(raw_bdf(target), offset.value, data, byte_enable);
      end
      else begin
        status = status_for(RDMA_SC_INVALID_STATE,
                            "config write backend is unavailable");
        return;
      end
      status = status_for(RDMA_SC_OK, "config write completed",
                          0, int'(func_mgr.config_generation));
    endtask

    // 功能：扫描 canonical PF/VF BAR aperture，为 bar_decoder 提供唯一的 target BDF
    //   hint；最终合法性仍由外部 decoder 决定。
    // 输入/输出及副作用：address（输入）、candidate/found（输出）；只读 manager，
    //   不建立影子 BAR 表或修改 decoder cache。
    // 失败/边界：地址落在 disabled VF aperture 时仍返回其 BDF 以便 decoder 产生
    //   PCIE_BAR_DECODE_DISABLED；溢出或多重命中不选取任意 Function。
    function automatic void find_candidate_bdf(
      bit [63:0] address,
      output bit found,
      output bit [15:0] candidate
    );
      pcie_tl_func_context ctx;
      pcie_tl_sriov_cap sc;
      bit [63:0] bar_base;
      bit [63:0] bar_size;
      bit [63:0] span;
      longint unsigned vf_index;
      bit [15:0] next_candidate;
      bit have_candidate;
      bit ambiguous;

      have_candidate = 1'b0;
      ambiguous = 1'b0;
      found = 1'b0;
      candidate = 16'hffff;
      for (int pf = 0; pf < func_mgr.num_pfs; pf++) begin
        ctx = (pf < func_mgr.pf_ctx.size()) ? func_mgr.pf_ctx[pf] : null;
        if (ctx != null) begin
          for (int bar = 0; bar < 6; bar++) begin
            if (ctx.bar_owner[bar] != bar || ctx.bar_size[bar] == 0)
              continue;
            bar_base = ctx.bar_base[bar];
            bar_size = ctx.bar_size[bar];
            if (bar_base <= (~64'b0 - bar_size) &&
                address >= bar_base && address < bar_base + bar_size) begin
              next_candidate = ctx.bdf;
              if (!have_candidate) begin
                have_candidate = 1'b1;
                candidate = next_candidate;
              end
              else if (candidate != next_candidate) begin
                ambiguous = 1'b1;
              end
            end
          end
        end
        sc = (pf < func_mgr.sriov_caps.size()) ? func_mgr.sriov_caps[pf] : null;
        if (sc == null || sc.num_vfs == 0)
          continue;
        for (int bar = 0; bar < 6; bar++) begin
          if (sc.vf_bar_owner[bar] != bar || sc.vf_bar_size[bar] == 0)
            continue;
          bar_base = sc.vf_bar[bar];
          bar_size = sc.vf_bar_size[bar];
          if (bar_size > (~64'b0 / sc.num_vfs))
            continue;
          span = bar_size * sc.num_vfs;
          if (bar_base > (~64'b0 - span) ||
              address < bar_base || address >= bar_base + span)
            continue;
          vf_index = (address - bar_base) / bar_size;
          if (vf_index >= sc.num_vfs)
            continue;
          next_candidate = sc.get_vf_rid(int'(vf_index));
          if (!have_candidate) begin
            have_candidate = 1'b1;
            candidate = next_candidate;
          end
          else if (candidate != next_candidate) begin
            ambiguous = 1'b1;
          end
        end
      end
      found = have_candidate && !ambiguous;
      if (!found)
        candidate = 16'hffff;
    endfunction

    // 功能：构造 memory TLP、调用外部 BAR decoder，并把 route 投影为 RDMA detached
    //   rdma_bar_decode；mmio_write 与 decode_bar 共用这一条 boundary/BE 校验路径。
    // 输入/输出及副作用：address/payload（输入）、route（输出）；decoder 只读 manager
    //   并可能刷新自身 generation cache，不修改 RDMA queue 状态。
    // 失败/边界：空 payload、非对齐地址、跨 Function/BAR、disabled/unknown BDF 和
    //   decoder 错误均映射为明确 RDMA status；失败时 route 只保留全零快照。
    function automatic rdma_status decode_memory_request(
      rdma_bar_addr_t address,
      byte payload[],
      output rdma_bar_decode route
    );
      pcie_tl_mem_tlp req;
      pcie_tl_cq_route_t decoded_route;
      string reason;
      bit found;
      bit [15:0] candidate;
      int unsigned dwords;
      int unsigned tail_bytes;
      pcie_bar_decode_result_e result;
      rdma_status ready_status;

      route = rdma_bar_decode::type_id::create("bar_decode");
      ready_status = validate_ready();
      if (!ready_status.ok())
        return ready_status;
      req = pcie_tl_mem_tlp::type_id::create("rdma_mmio_request");
      if (payload.size() == 0 || payload.size() > 4096)
        return status_for(RDMA_SC_INVALID_ARGUMENT,
                          "MMIO payload length is outside 1..4096 bytes");
      if (address.value[1:0] != 2'b00)
        return status_for(RDMA_SC_INVALID_ARGUMENT,
                          "MMIO address is not DWORD aligned");
      dwords = (payload.size() + 3) / 4;
      tail_bytes = payload.size() - (dwords - 1) * 4;
      req.addr = address.value;
      req.kind = TLP_MEM_WR;
      req.type_f = TLP_TYPE_MEM_WR;
      req.is_64bit = (address.value[63:32] != 0);
      req.fmt = req.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
      req.length = (dwords == 1024) ? 10'd0 : dwords[9:0];
      req.first_be = 4'hf;
      req.last_be = (dwords == 1) ? 4'h0 : ((1 << tail_bytes) - 1);
      req.payload = new[payload.size()];
      foreach (payload[i])
        req.payload[i] = payload[i];

      find_candidate_bdf(address.value, found, candidate);
      if (!found)
        candidate = 16'hffff;
      result = bar_decoder.decode(req, candidate, decoded_route, reason);
      case (result)
        PCIE_BAR_DECODE_OK: begin
          route.target_bdf = '{segment:16'h0,
                               bus:decoded_route.target_bdf[15:8],
                               device:decoded_route.target_bdf[7:3],
                               function_num:decoded_route.target_bdf[2:0]};
          route.bar_id = decoded_route.bar_id;
          route.bar_offset = decoded_route.bar_offset;
          return status_for(RDMA_SC_OK, reason);
        end
        PCIE_BAR_DECODE_DISABLED:
          return status_for(RDMA_SC_INVALID_STATE, reason);
        PCIE_BAR_DECODE_NO_MATCH,
        PCIE_BAR_DECODE_BDF_MISMATCH:
          return status_for(RDMA_SC_PCIE_COMPLETION, reason);
        PCIE_BAR_DECODE_INVALID_CONFIG:
          return status_for(RDMA_SC_INVALID_STATE, reason);
        default:
          return status_for(RDMA_SC_INVALID_ARGUMENT, reason);
      endcase
    endfunction

    // 功能：按地址解码一个最小 BAR 访问，供 sequence 预检目标 Function/BAR/offset。
    // 输入/输出及副作用：address（输入）、result（输出）；成功时 result 是 detached
    //   route，失败时不发布部分有效目标；不产生 PCIe 写事务。
    // 失败/边界：未配置、地址未命中、disabled VF 或跨边界请求按 decode_memory_request
    //   的 fail-closed 映射返回，不从 address 猜测默认 PF。
    virtual function rdma_status decode_bar(
      rdma_bar_addr_t address,
      output rdma_bar_decode result
    );
      byte one_dword[];
      rdma_status status;
      one_dword = new[4];
      foreach (one_dword[i])
        one_dword[i] = 8'h00;
      status = decode_memory_request(address, one_dword, result);
      if (status.ok())
        status.source_engine = RDMA_ENGINE_PCIE;
      return status;
    endfunction

    // 功能：登记 Function UID、object ID 与 canonical BDF 的绑定，供后续 MMIO/屏障
    //   做 generation 和目标 Function 双重校验。
    // 输入/输出及副作用：info/function_uid/object_id（输入）；成功时写入 adapter-owned
    //   detached handle/route 快照；返回状态，不修改 manager。
    // 失败/边界：空 info、零 UID、unknown/disabled BDF、UID 冲突或 generation 不可用
    //   返回错误；重复登记同一 BDF/UID 可幂等成功，冲突登记不会留下部分条目。
    function rdma_status register_function(
      rdma_pcie_function_info info,
      longint unsigned function_uid,
      int unsigned object_id,
      int unsigned generation = 0
    );
      pcie_tl_func_context ctx;
      rdma_status status;
      rdma_function_handle handle;
      int unsigned current_generation;

      status = validate_ready();
      if (!status.ok())
        return status;
      if (info == null || function_uid == 0)
        return status_for(RDMA_SC_INVALID_ARGUMENT,
                          "Function snapshot or UID is invalid");
      status = lookup_context(info.bdf, ctx);
      if (!status.ok())
        return status;
      current_generation = int'(func_mgr.config_generation);
      if (generation == 0)
        generation = current_generation;
      if (generation != current_generation)
        return status_for(RDMA_SC_STALE_GENERATION,
                          "Function registration generation is stale",
                          function_uid, generation);
      if (route_bdfs.exists(function_uid) &&
          !rdma_bdf_same(route_bdfs[function_uid], info.bdf))
        return status_for(RDMA_SC_INVALID_ARGUMENT,
                          "Function UID is already bound to another BDF",
                          function_uid, generation);
      handle = rdma_function_handle::type_id::create("pcie_route_handle");
      handle.kind = RDMA_RESOURCE_FUNCTION;
      handle.function_uid = function_uid;
      handle.object_id = object_id;
      handle.generation = generation;
      route_handles[function_uid] = handle;
      route_bdfs[function_uid] = info.bdf;
      route_generations[function_uid] = generation;
      return status_for(RDMA_SC_OK, "Function route registered",
                        function_uid, generation);
    endfunction

    // 功能：校验调用方 Function handle 的 kind、UID、object ID、BDF registry 和当前
    //   manager generation，阻断 stale handle 写入 BAR。
    // 输入/输出及副作用：function_h（输入）；返回状态，不修改调用方 handle；registry
    //   generation 仅在成功校验前读取，不把外部句柄保存为可变引用。
    // 失败/边界：null/wrong kind/unknown UID/BDF mismatch 返回 INVALID_ARGUMENT/STATE；
    //   handle generation 与当前 manager generation 不等返回 STALE_GENERATION。
    function automatic rdma_status validate_function_handle(
      rdma_function_handle function_h
    );
      pcie_tl_func_context ctx;
      rdma_status status;
      int unsigned current_generation;

      status = validate_ready();
      if (!status.ok())
        return status;
      if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
        return status_for(RDMA_SC_INVALID_ARGUMENT,
                          "Function handle is null or has wrong kind");
      if (!route_handles.exists(function_h.function_uid))
        return status_for(RDMA_SC_INVALID_ARGUMENT,
                          "Function handle UID is not registered",
                          function_h.function_uid, function_h.generation);
      status = lookup_context(route_bdfs[function_h.function_uid], ctx);
      if (!status.ok())
        return status;
      if (function_h.object_id != route_handles[function_h.function_uid].object_id)
        return status_for(RDMA_SC_INVALID_ARGUMENT,
                          "Function handle object ID does not match registry",
                          function_h.function_uid, function_h.generation);
      current_generation = int'(func_mgr.config_generation);
      if (function_h.generation != current_generation)
        return status_for(RDMA_SC_STALE_GENERATION,
                          "Function handle generation is stale",
                          function_h.function_uid, function_h.generation);
      return status_for(RDMA_SC_OK, "Function handle authority is valid",
                        function_h.function_uid, current_generation);
    endfunction

    // 功能：验证 Function-aware MMIO payload、解码其 BAR route，并在 model-bypass 下
    //   记录 detached 写入；真实 backend 模式未接入发送端时明确返回 INVALID_STATE。
    // 输入/输出及副作用：function_h/address/data（输入）、status（输出）；成功时更新
    //   last_mmio_route/last_mmio_payload 诊断快照，不修改 manager BAR 状态。
    // 失败/边界：stale/unknown handle、空数据、非对齐、跨 BAR/Function、disabled VF
    //   均不写入快照；关闭 model_bypass 时不假装已发出 PCIe TLP。
    virtual task mmio_write(
      rdma_function_handle function_h,
      rdma_bar_addr_t address,
      byte data[],
      output rdma_status status
    );
      rdma_bar_decode route;
      rdma_status route_status;

      status = validate_function_handle(function_h);
      if (!status.ok())
        return;
      if (!model_bypass) begin
        status = status_for(RDMA_SC_INVALID_STATE,
                            "PCIe MMIO transmit backend is not connected",
                            function_h.function_uid, function_h.generation);
        return;
      end
      route_status = decode_memory_request(address, data, route);
      if (!route_status.ok()) begin
        status = route_status;
        return;
      end
      if (!route_bdfs.exists(function_h.function_uid) ||
          !rdma_bdf_same(route.target_bdf,
                         route_bdfs[function_h.function_uid])) begin
        status = status_for(RDMA_SC_PCIE_COMPLETION,
                            "MMIO address route does not match Function handle",
                            function_h.function_uid, function_h.generation);
        return;
      end
      last_mmio_route = rdma_bar_decode::type_id::create("last_mmio_route");
      last_mmio_route.copy(route);
      last_mmio_payload.delete();
      foreach (data[i])
        last_mmio_payload.push_back(data[i]);
      last_mmio_valid = 1'b1;
      status = status_for(RDMA_SC_OK, "model MMIO route accepted",
                          function_h.function_uid,
                          function_h.generation);
    endtask

    // 功能：在 Function authority 已验证后执行 DMA 可见性屏障；model-bypass 仅记录
    //   已完成的顺序点，真实 backend 必须由上层注入后才能报告成功。
    // 输入/输出及副作用：function_h（输入）、status（输出）；不写入 PCIe config/BAR。
    // 失败/边界：null/wrong/stale/unknown handle 或未连接真实 backend 返回明确错误，
    //   不隐式等待或重试。
    virtual task dma_visibility_barrier(
      rdma_function_handle function_h,
      output rdma_status status
    );
      status = validate_function_handle(function_h);
      if (!status.ok())
        return;
      if (!model_bypass) begin
        status = status_for(RDMA_SC_INVALID_STATE,
                            "DMA visibility backend is not connected",
                            function_h.function_uid, function_h.generation);
        return;
      end
      status = status_for(RDMA_SC_OK, "model DMA visibility barrier completed",
                          function_h.function_uid, function_h.generation);
    endtask

    // 功能：在 Function authority 已验证后执行 MMIO ordering 屏障，保证 doorbell 前
    //   的模型写入按序可见；真实 PCIe ordering backend 缺失时不伪造硬件完成。
    // 输入/输出及副作用：function_h（输入）、status（输出）；不推进队列 PI/CI，也不
    //   修改 manager；model-bypass 成功只表示模型顺序点已建立。
    // 失败/边界：handle 未登记、代际陈旧或真实 backend 未连接返回错误且不发布部分状态。
    virtual task mmio_ordering_barrier(
      rdma_function_handle function_h,
      output rdma_status status
    );
      status = validate_function_handle(function_h);
      if (!status.ok())
        return;
      if (!model_bypass) begin
        status = status_for(RDMA_SC_INVALID_STATE,
                            "MMIO ordering backend is not connected",
                            function_h.function_uid, function_h.generation);
        return;
      end
      status = status_for(RDMA_SC_OK, "model MMIO ordering barrier completed",
                          function_h.function_uid, function_h.generation);
    endtask
  endclass
endpackage : rdma_pcie_work_adapter_pkg

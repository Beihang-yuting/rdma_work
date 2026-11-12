// 目录/层次：integration/project；RDMA 单 bank 硬件表项计划。
// 职责：把 dpu_common 的冻结 snapshot/resource/BAR 视图和平台发布的 RDMA grant 投影为已知的
//   HID_MAP、RPE_VFT、QSCH、WBE、EAT 写项；Notify/RNET 由公共 catalog sequence 唯一写入。
// 依赖：dpu_resource_pkg、host_mem_pkg、rdma_dpu_adapter_pkg；实际 PCIe 写入仍由 dpu_cfg_seq 完成。
// 所有权与生命周期：plan 只借用冻结对象和 grant；write 项为值/非拥有目标快照，restore 后必须重新 build。
// 设计边界：SD/HMC 的页表由 rdma_drv_dev 通过 CMQ 管理，grant 只授权 SD 编号范围，真实 IOVA 在 probe 时从共享 Host pool 分配。
// 功能：返回一个字段完整的空 BAR target，供构造函数先建立可校验的零值目标。
// 输入/输出及副作用：无输入；返回值不拥有 snapshot 或 BAR lease，不访问 PCIe、不分配资源。
// 失败/边界：返回值只能作为未绑定占位；resolve/build 成功前不能发送其上的写项。
function automatic dpu_bar_target_t rdma_empty_bar_target();
  dpu_bar_target_t result;

  result.function_key = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
  result.pcie_id.domain = '{host_id: 0, segment_id: 0};
  result.pcie_id.bdf = '0;
  result.global_function_id = 0;
  result.bar_lease.role = DPU_BAR_DEVICE_MEMORY;
  result.bar_lease.even_bar_id = 0;
  result.bar_lease.base = '0;
  result.bar_lease.size = '0;
  result.canonical_name = "";
  result.snapshot = null;
  result.snapshot_generation = 0;
  return result;
endfunction

class rdma_hw_reg_write extends uvm_object;
  `uvm_object_utils(rdma_hw_reg_write)

  dpu_bar_target_t target;
  dpu_function_key_t owner;
  bit [63:0] offset;
  bit [31:0] value;
  string name;
  bit deferred;

  // 功能：构造一条尚未绑定目标的四字节硬件写项。
  // 输入/输出及副作用：name 传给 UVM；目标/owner/值清零，不访问 BAR 或 PCIe。
  // 失败/边界：target 为空或 deferred 语义未由 plan 处理时不可发送；构造本身不做范围校验。
  function new(string name = "rdma_hw_reg_write");
    super.new(name);
    target = rdma_empty_bar_target();
    owner = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
    offset = '0;
    value = '0;
    this.name = name;
    deferred = 0;
  endfunction
endclass

class rdma_hw_function_plan extends uvm_object;
  `uvm_object_utils(rdma_hw_function_plan)

  dpu_function_key_t key;
  int unsigned global_id;
  int unsigned rdma_vf_id;
  rdma_dpu_grant grant;
  dpu_bar_target_t target;

  // 功能：构造一个尚未投影 grant 的 Function 计划项。
  // 输入/输出及副作用：name 传给 UVM；身份、grant 与目标均为空值，不持有平台资源。
  // 失败/边界：build 成功前不能作为硬件写目标；缺 grant 或 target 的项由 plan 校验拒绝。
  function new(string name = "rdma_hw_function_plan");
    super.new(name);
    key = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
    global_id = 0;
    rdma_vf_id = 0;
    grant = null;
    target = rdma_empty_bar_target();
  endfunction
endclass

class rdma_hw_plan extends uvm_object;
  `uvm_object_utils(rdma_hw_plan)

  localparam bit [63:0] RDMA_CMQE_BASE = 64'h0021_0000;
  localparam bit [63:0] RDMA_RPE_BASE  = 64'h0025_0000;
  localparam bit [63:0] RDMA_RCE_BASE  = 64'h0028_0000;
  localparam bit [63:0] RDMA_DMI_BASE  = 64'h002b_0000;
  localparam bit [63:0] DSCH_QSCH_BASE = 64'h00b0_0000;
  // VIO 使用 0x12000 的 4096 项 N2G 表；RDMA 从其后独立的 0x16000 区域开始。
  localparam bit [63:0] DSCH_QSCH_N2G_BASE      = DSCH_QSCH_BASE + 64'h12000;
  localparam bit [63:0] DSCH_QSCH_RDMA_N2G_BASE = DSCH_QSCH_N2G_BASE + 64'h4000;
  localparam bit [31:0] RDMA_DBT_TO_CSCH_MAP = 32'h0000_1402;
  localparam bit [63:0] RDMA_CFG_EAT_PRO = RDMA_RCE_BASE + 64'h8090;

  // 53 驱动的 rdma_eat_table_entry：bit0=AE，bit1=异常 CQE。RC/UD 与 URC
  // 使用同一份静态策略；数组只保存驱动列出的 122 个非零 ecode，未列出的项保持零。
  localparam bit [9:0] EAT_POLICY [0:121] = '{
    10'h009, 10'h015, 10'h01D, 10'h023, 10'h02D, 10'h03D, 10'h05B, 10'h05F,
    10'h063, 10'h067, 10'h06F, 10'h07B, 10'h0A7, 10'h0AB, 10'h0AF, 10'h0B1,
    10'h0B9, 10'h0BD, 10'h0D9, 10'h0E1, 10'h0EB, 10'h0ED, 10'h0F5, 10'h111,
    10'h117, 10'h123, 10'h127, 10'h12B, 10'h12F, 10'h133, 10'h137, 10'h13B,
    10'h13F, 10'h143, 10'h147, 10'h14B, 10'h14F, 10'h153, 10'h157, 10'h15B,
    10'h15F, 10'h163, 10'h16B, 10'h16F, 10'h173, 10'h177, 10'h17B, 10'h17F,
    10'h183, 10'h187, 10'h18B, 10'h18F, 10'h193, 10'h197, 10'h19B, 10'h19F,
    10'h1A3, 10'h1B3, 10'h1B7, 10'h1BB, 10'h1C2, 10'h1C9, 10'h3C1, 10'h1E1,
    10'h1E7, 10'h1EB, 10'h1ED, 10'h1F9, 10'h215, 10'h235, 10'h23E, 10'h247,
    10'h251, 10'h255, 10'h259, 10'h25D, 10'h261, 10'h273, 10'h28F, 10'h293,
    10'h2A3, 10'h2A7, 10'h2AF, 10'h2B7, 10'h2BB, 10'h2CF, 10'h2DF, 10'h2E7,
    10'h2EF, 10'h2F3, 10'h311, 10'h317, 10'h31F, 10'h323, 10'h327, 10'h32B,
    10'h32F, 10'h333, 10'h337, 10'h33B, 10'h33F, 10'h343, 10'h34E, 10'h353,
    10'h357, 10'h35B, 10'h35F, 10'h363, 10'h367, 10'h36B, 10'h36F, 10'h373,
    10'h381, 10'h3C9, 10'h3CD, 10'h3D1, 10'h3D5, 10'h3D9, 10'h3DD, 10'h3E1,
    10'h3ED, 10'h3FD};

  localparam bit [31:0] WBE_TEMPLATE_0 [0:15] = '{
    32'h01e3_00e0, 32'h0301_0037, 32'hff0c_ffff, 32'h0000_0000,
    32'h0000_0000, 32'h0700_0000, 32'h0000_0700, 32'h3800_0000,
    32'h0000_0000, 32'h1c00_0000, 32'h0000_0070, 32'h1c00_0070,
    32'h0000_0000, 32'he007_0700, 32'h0000_0000, 32'h0000_0000};
  localparam bit [31:0] WBE_TEMPLATE_1 [0:15] = '{
    32'h01e0_0090, 32'h0001_0000, 32'h0000_0000, 32'h0000_0000,
    32'h0000_0000, 32'h0700_0000, 32'h0000_0000, 32'h0000_0000,
    32'h0000_0000, 32'h0000_0000, 32'h0000_0070, 32'h1c00_0770,
    32'h0000_0000, 32'h0000_0000, 32'he007_0700, 32'h0000_0000};

  dpu_device_snapshot snapshot;
  dpu_resource_snapshot resources;
  dpu_bar_map bar_map;
  dpu_env_cfg dpu_cfg;
  host_mem_pool host_pool;
  rdma_dpu_grant grants[$];
  rdma_hw_function_plan functions[$];
  rdma_hw_reg_write writes[$];
  bit built;

  // 功能：构造空的硬件表项计划，后续由 build 绑定当前 restore 代的冻结视图。
  // 输入/输出及副作用：name 传给 UVM；所有引用和写项清空，不创建 PCIe sequence 或资源。
  // 失败/边界：built=0 时 list_writes 返回空；同一 plan 可在新的冻结代重新 build。
  function new(string name = "rdma_hw_plan");
    super.new(name);
    snapshot = null;
    resources = null;
    bar_map = null;
    dpu_cfg = null;
    host_pool = null;
    grants.delete();
    functions.delete();
    writes.delete();
    built = 0;
  endfunction

  // 功能：追加一条已知目标的 DWORD 写项，并保留 owner 以便审计多 Function 计划。
  // 输入/输出及副作用：更新 writes；不访问硬件，调用方负责先完成输入范围检查。
  // 失败/边界：target 为空、offset 未对齐或 value 含 X/Z 时仍追加，最终由 validate 拒绝，避免静默截断。
  protected function void add_write(dpu_bar_target_t target_arg, dpu_function_key_t owner_arg,
                                    bit [63:0] offset_arg, bit [31:0] value_arg, string name_arg);
    rdma_hw_reg_write item;

    item = rdma_hw_reg_write::type_id::create(name_arg);
    item.target = target_arg;
    item.owner = owner_arg;
    item.offset = offset_arg;
    item.value = value_arg;
    item.name = name_arg;
    writes.push_back(item);
  endfunction

  // 功能：选择 RDMA/QSCH 全局表的真实管理 BAR，优先使用已冻结 RNET 记录的 target。
  // 输入/输出及副作用：target/why 输出；只读取 dpu_cfg 与 bar_map，不分配或发送事务。
  // 失败/边界：无冻结 RNET 时仅允许唯一的 h0.pf0.bar0 回退；无法解析或异源 target 时返回假。
  protected function bit resolve_target(output dpu_bar_target_t target, output string why);
    target = rdma_empty_bar_target();
    why = "RDMA hardware plan has no management BAR target";
    if (dpu_cfg != null) begin
      foreach (dpu_cfg.frozen_controls[i]) begin
        if (dpu_cfg.frozen_controls[i].ctx.kind == DPU_TABLE_RNET) begin
          target = dpu_cfg.frozen_controls[i].ctx.target;
          why = "";
          return target.snapshot == snapshot && target.snapshot != null;
        end
      end
    end
    if (bar_map == null || !bar_map.resolve_name("h0.pf0.bar0", target, why))
      return 0;
    return target.snapshot == snapshot && target.snapshot != null;
  endfunction

  // 功能：把所有 Function 的 grant 展开为 RDMA/QSCH/WBE/EAT 单 bank 写项。
  // 输入/输出及副作用：成功保存冻结引用、Function 计划和 writes；不发送 PCIe，不改变 grant/snapshot。
  // 失败/边界：快照/resource/map 未冻结、Host pool 异源、grant 身份/位宽/重复 rdma_vf_id 或管理 BAR 缺失均拒绝；失败清空本代输出。
  function rdma_status build(
    dpu_device_snapshot snapshot_arg,
    dpu_resource_snapshot resources_arg,
    dpu_bar_map bar_map_arg,
    dpu_env_cfg dpu_cfg_arg,
    rdma_dpu_grant grants_arg[$]
  );
    dpu_bar_target_t target;
    bit seen_global[int unsigned];
    bit seen_vf[int unsigned];
    bit seen_key[string];
    string why;
    bit [31:0] value;
    rdma_hw_function_plan function_plan;

    built = 0;
    functions.delete();
    writes.delete();
    grants.delete();
    snapshot = snapshot_arg;
    resources = resources_arg;
    bar_map = bar_map_arg;
    dpu_cfg = dpu_cfg_arg;
    host_pool = null;
    if (dpu_cfg_arg != null)
      void'($cast(host_pool, dpu_cfg_arg.host_mem_pool_ref));
    if (snapshot_arg == null || resources_arg == null || bar_map_arg == null ||
        dpu_cfg_arg == null || grants_arg.size() == 0 || !snapshot_arg.is_frozen() ||
        !resources_arg.is_frozen() || !resources_arg.references_device_snapshot(snapshot_arg) ||
        !bar_map_arg.is_frozen() || !bar_map_arg.references_device_snapshot(snapshot_arg) ||
        host_pool == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
        "RDMA hardware plan requires same-source frozen DPU views");
    if (!resolve_target(target, why))
      return rdma_status::make(RDMA_SC_INVALID_STATE, why);
    foreach (grants_arg[i]) begin
      int unsigned global_id;
      string key_name;

      if (grants_arg[i] == null || !grants_arg[i].validate(why))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, {"invalid RDMA grant: ", why});

      key_name = $sformatf("%0d:%0d:%0d:%0d", grants_arg[i].key.host_id,
                           grants_arg[i].key.pf_id, grants_arg[i].key.kind,
                           grants_arg[i].key.vf_id);
      if (!snapshot_arg.get_global_function_id(grants_arg[i].key, global_id, why) ||
          global_id != grants_arg[i].global_id ||
          grants_arg[i].host_id != grants_arg[i].key.host_id ||
          !host_pool.has_host(grants_arg[i].host_id) ||
          seen_key.exists(key_name) || seen_global.exists(grants_arg[i].global_id) ||
          seen_vf.exists(grants_arg[i].rdma_vf_id))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
          "RDMA grant Function/global ID/rdma_vf_id is not unique");
      seen_key[key_name] = 1;
      seen_global[grants_arg[i].global_id] = 1;
      seen_vf[grants_arg[i].rdma_vf_id] = 1;
      function_plan = rdma_hw_function_plan::type_id::create(
        $sformatf("rdma_f%0d", global_id));
      function_plan.key = grants_arg[i].key;
      function_plan.global_id = global_id;
      function_plan.rdma_vf_id = grants_arg[i].rdma_vf_id;
      function_plan.grant = grants_arg[i];
      function_plan.target = target;
      functions.push_back(function_plan);
      grants.push_back(grants_arg[i]);

      value = 32'h1 | (grants_arg[i].host_id << 1) | (global_id << 4);
      add_write(target, grants_arg[i].key, RDMA_DMI_BASE + 64'h8000 + grants_arg[i].rdma_vf_id * 4,
                value, "HID_MAP");
      value = 32'h8000_0000 | grants_arg[i].rdma_vf_id;
      add_write(target, grants_arg[i].key,
                RDMA_RPE_BASE + 64'h4000 + global_id * 4, value, "RPE_VFT");
      value = 32'h8000_0000 | grants_arg[i].group_id;
      add_write(target, grants_arg[i].key,
                DSCH_QSCH_RDMA_N2G_BASE + grants_arg[i].net_id * 4,
                value, "QSCH_N2G");
      // G2P 使用物理调度出口 dport；QPC 的 dst_port=15 表示 NODE_MODE，不能写成 G2P 出口。
      value = 32'h8000_0000 | (grants_arg[i].dport << 16) | grants_arg[i].lvl2_id;
      add_write(target, grants_arg[i].key,
                DSCH_QSCH_BASE + 64'h14000 + grants_arg[i].group_id * 4, value, "QSCH_G2P");
      value = 32'h8000_0000 | grants_arg[i].net_id;
      add_write(target, grants_arg[i].key,
                DSCH_QSCH_BASE + 64'h28000 +
                  ((grants_arg[i].dport << 8) | grants_arg[i].rdma_vf_id) * 4,
                value, "RDMA_NET_MAP");
    end

    add_write(target, functions[0].key, DSCH_QSCH_BASE + 64'h130,
              RDMA_DBT_TO_CSCH_MAP, "DBT_TO_CSCH");
    value = 32'h1 | (functions[0].grant.host_id << 1) |
            (functions[0].grant.global_id << 4);
    add_write(target, functions[0].key, DSCH_QSCH_BASE + 64'h13c, value, "QSCH_CFG_AF");
    foreach (WBE_TEMPLATE_0[i]) begin
      add_write(target, functions[0].key, RDMA_CMQE_BASE + 64'h5000 + i * 4,
                WBE_TEMPLATE_0[i], "WBE_TEMPLATE_0");
      add_write(target, functions[0].key, RDMA_CMQE_BASE + 64'h5040 + i * 4,
                WBE_TEMPLATE_1[i], "WBE_TEMPLATE_1");
    end
    foreach (EAT_POLICY[i]) begin
      value = {30'b0, EAT_POLICY[i][1:0]};
      add_write(target, functions[0].key,
                RDMA_RCE_BASE + 64'h9000 + EAT_POLICY[i][9:2] * 4,
                value, "EAT_RCUD");
      add_write(target, functions[0].key,
                RDMA_RCE_BASE + 64'h9400 + EAT_POLICY[i][9:2] * 4,
                value, "EAT_URC");
    end
    // CFG_EAT_PRO 与 53 驱动的静态 RC/UD、URC EAT 动作表一起启用。
    add_write(target, functions[0].key, RDMA_CFG_EAT_PRO, 32'h3, "EAT_PRO");
    grants = grants_arg;
    built = 1;
    return validate();
  endfunction

  // 功能：校验当前计划的目标快照、四字节对齐、已知值和 BAR 范围。
  // 输入/输出及副作用：只读 plan/write；返回首个失败 status，不发送或修改任何对象。
  // 失败/边界：未 build、空 Function、异源 target、X/Z 值、未对齐/越 BAR 或 deferred 写项均拒绝。
  function rdma_status validate();
    bit [63:0] address;
    string why;

    if (!built || snapshot == null || bar_map == null || functions.size() == 0 ||
        writes.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "RDMA hardware plan is empty");
    foreach (writes[i]) begin
      if (writes[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE, "RDMA hardware write is null");
      if (writes[i].deferred || writes[i].target.snapshot != snapshot ||
          writes[i].offset[1:0] != 0 || $isunknown({writes[i].offset, writes[i].value}) ||
          !bar_map.check_range(writes[i].target, writes[i].offset, 4, address, why))
        return rdma_status::make(RDMA_SC_INVALID_STATE, {"invalid RDMA hardware write: ", why});
    end
    return rdma_status::success();
  endfunction

  // 功能：导出本代按驱动参考顺序生成的寄存器写列表。
  // 输入/输出及副作用：writes_out 清空后得到非拥有写项句柄；不重新排序、不发送事务。
  // 失败/边界：plan 未 build 时返回空列表；调用者仍须执行 validate 后再写入 PCIe。
  function void list_writes(ref rdma_hw_reg_write writes_out[$]);
    writes_out.delete();
    if (!built)
      return;
    foreach (writes[i])
      writes_out.push_back(writes[i]);
  endfunction
endclass

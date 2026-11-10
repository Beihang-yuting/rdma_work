// 目录/层次：integration/project；仅负责已发布 DPU 配置的 RDMA 表编排。
// 职责：发布前纯生成 Notify/RNET catalog，运行时预检含 MSI-X 尾项的完整跨度并复用公共配置方法。
// 依赖：dpu_env_cfg、冻结 device/resource/map 和 RC sequencer；无 VIO package、probe 或初始化调用。
// 所有权：平台拥有输入对象；本类只拥有局部 catalog/scope，不回写冻结配置、不分配任何 RDMA grant。
// 生命周期：平台先 resolve device/resources、freeze map，调用 make_catalog 并追加 platform_controls，
// 再由 DPU publish 冻结；真实平台 reset/readiness 完成后才 start 本 sequence。
class rdma_project_cfg_seq extends dpu_cfg_seq;
  `uvm_object_utils(rdma_project_cfg_seq)

  // 明确列出本次完整单 bank RDMA 目录；空集合不能退化成配置全部 Function。
  dpu_function_key_t	rdma_functions[$];
  // 只记录已经完成的类别，不代表 RDMA shared grant 或设备初始化就绪。
  string	configured_tables;

  // 功能：构造独立 RDMA 配置 sequence，沿用父类 success/error_msg 与失败 fatal。
  // 输入/输出及副作用：name 传给基类；rdma_functions 默认空，需要平台显式赋值。
  // 失败/边界：构造不访问 DUT；空目录将在首笔 AF 事务前拒绝。
  extern function new(string	name = "rdma_project_cfg_seq");

  // 功能：从冻结身份和真实 BAR 纯生成按 Host/Notify 地址排序的单 bank Notify 与 RNET 控制项。
  // 输入/输出及副作用：device/map/keys 只读；controls 成功返回完整 catalog，失败保持空，why 指出原因。
  // 失败/边界：拒绝异源/未冻结对象、空/重复/非法 Function kind/无 RDMA service 身份、ID>=256、Host>=8、地址溢出/不可编码/重复。
  extern static function bit make_catalog(
    input dpu_device_snapshot	device,
    input dpu_bar_map		map,
    input dpu_function_key_t	keys[$],
    output dpu_control_cfg_t	controls[$],
    output string		why
  );

  // 功能：对已有权威身份值和 Notify 地址作位宽检查，构造硬件 8B 字段，不分配身份。
  // 输入/输出及副作用：global_id/host/address 只读，entry 成功为精确拼接，失败清零，why 返回窄字段原因。
  // 失败/边界：ID>=256、Host>=8、X/Z 地址、地址高三位非零或非 8KB 对齐拒绝，绝不先截位。
  extern static function bit encode_notify(
    input int unsigned			global_id,
    input int unsigned			host,
    input logic [63:0]			address,
    output dpu_rdma_notify_entry_t	entry,
    output string			why
  );

  // 功能：公开无写入的完整预检供组合序列复用，检查必需表及 Function 覆盖并建立三个 scope。
  // 输入/输出及副作用：读取已发布 cfg 和 rdma_functions；三个 scope 为输出，不发 MMIO、不修改冻结 catalog。
  // 失败/边界：拒绝未发布/异源资源、缺表、编码/排序错误、重复目录及含尾项的容量/溢出/对齐/重叠/管理窗口错误。
  extern function bit preflight(
    output dpu_cfg_scope	bdf_scope,
    output dpu_cfg_scope	msix_scope,
    output dpu_cfg_scope	rdma_scope,
    output string		why
  );

  // 功能：检查指定公共类别的记录能完整覆盖选定 Function，防止空批次伪成功。
  // 输入/输出及副作用：kind/scope/keys 决定只读查询，batch 返回待做跨类别预检的记录，why 返回缺失 Function；不写配置。
  // 失败/边界：public_records 拒绝或任一 key 无记录即失败；共享 MSI-X control/function 的 table-only 策略由调用方单独处理。
  extern protected function bit require_records(
    input dpu_table_kind_e	kind,
    input dpu_cfg_scope		scope,
    input dpu_function_key_t	keys[$],
    output dpu_table_item_t	batch[$],
    output string		why
  );

  // 功能：合并有效表项、MSI-X 未用尾部与 AF/Notify使能跨度，在首笔事务前验证完整PCIe目标。
  // 输入/输出及副作用：batch为有效记录，with_msix_tail选择父类将访问的完整尾部；why返回范围/冲突原因，不发送。
  // 失败/边界：拒绝缺RC、容量超2048/小于有效行数、地址溢出/越BAR、未对齐/跨4KB、间接或重叠跨度；有效行仅允许同记录去重。
  extern protected function bit validate_targets(
    input dpu_table_item_t	batch[$],
    input bit			with_msix_tail,
    output string		why
  );

  // 功能：按 AF、BDF、有效 MSI-X/无效尾项/使能、完整读回、Notify、RNET 顺序配置，成功才发布 success。
  // 输入/输出及副作用：借用 cfg/RC，逐步更新 error_msg；正常失败保持 success=0，post_start 保留父类 fatal。
  // 失败/边界：完整预检先于所有事务；任一写/读回失败停止后续类别，不 probe、不 initialize、不声称 posted write 可回滚。
  extern virtual task body();
endclass

// 功能：构造独立 RDMA 配置 sequence，沿用父类 success/error_msg 与失败 fatal。
// 输入/输出及副作用：name 传给基类；rdma_functions 默认空，需要平台显式赋值。
// 失败/边界：构造不访问 DUT；空目录将在首笔 AF 事务前拒绝。
function rdma_project_cfg_seq::new(string	name = "rdma_project_cfg_seq");
  super.new(name);
endfunction

// 功能：对已有权威身份值和 Notify 地址作位宽检查，构造硬件 8B 字段，不分配身份。
// 输入/输出及副作用：global_id/host/address 只读，entry 成功为精确拼接，失败清零，why 返回窄字段原因。
// 失败/边界：ID>=256、Host>=8、X/Z 地址、地址高三位非零或非 8KB 对齐拒绝，绝不先截位。
function bit rdma_project_cfg_seq::encode_notify(
  input int unsigned			global_id,
  input int unsigned			host,
  input logic [63:0]			address,
  output dpu_rdma_notify_entry_t	entry,
  output string				why
);
  entry = '0;
  why   = "Notify ID/Host/address cannot be encoded without truncation";
  if (global_id >= 256 || host >= 8 || $isunknown(address) ||
      address[63:61] != 0 || address[12:0] != 0)
    return 0;
  entry = {5'b0, global_id[7:0], host[2:0], address[60:13]};
  why   = "";
  return 1;
endfunction

// 功能：从冻结身份和真实 BAR 纯生成按 Host/Notify 地址排序的单 bank Notify 与 RNET 控制项。
// 输入/输出及副作用：device/map/keys 只读；controls 成功返回完整 catalog，失败保持空，why 指出原因。
// 失败/边界：拒绝异源/未冻结对象、空/重复/非法 Function kind/无 RDMA service 身份、ID>=256、Host>=8、地址溢出/不可编码/重复。
function bit rdma_project_cfg_seq::make_catalog(
  input dpu_device_snapshot	device,
  input dpu_bar_map		map,
  input dpu_function_key_t	keys[$],
  output dpu_control_cfg_t	controls[$],
  output string			why
);
  dpu_service_key_t	services[$];
  dpu_control_cfg_t	notify[$];
  dpu_control_cfg_t	rnet[$];
  bit			seen_id[int unsigned];
  bit			seen_key[string];

  controls.delete();
  why = "catalog requires frozen same-source device/map and nonempty RDMA Function list";
  if (device == null || map == null || keys.size() == 0)
    return 0;
  if (!device.is_frozen() || !map.is_frozen() || !map.references_device_snapshot(device))
    return 0;
  device.list_services(DPU_SERVICE_RDMA, services);
  foreach (keys[i]) begin
    dpu_bar_pair_lease_t	lease;
    dpu_bar_target_t		target;
    dpu_control_cfg_t		item;
    dpu_rdma_notify_entry_t	entry;
    dpu_qsch_rnet_entry_t	route;
    int unsigned		global_id;
    bit [63:0]			address;
    bit				service_found;
    string			name;

    name = dpu_function_key_name(keys[i]);
    why  = {"invalid or duplicate RDMA Function/Host: ", name};
    if (!(keys[i].kind inside {DPU_FUNCTION_PF, DPU_FUNCTION_VF}) ||
        keys[i].host_id >= 8 || seen_key.exists(name))
      return 0;
    seen_key[name] = 1;
    service_found  = 0;
    foreach (services[s]) begin
      if (dpu_same_function_key(services[s].function_key, keys[i]))
        service_found = 1;
    end
    if (!service_found) begin
      why = {"RDMA service missing: ", name};
      return 0;
    end
    if (!device.get_global_function_id(keys[i], global_id, why))
      return 0;
    if (global_id >= 256 || seen_id.exists(global_id)) begin
      why = {"RDMA global Function ID must be unique and below 256: ", name};
      return 0;
    end
    seen_id[global_id] = 1;
    if (!device.get_bar(keys[i], DPU_BAR_DEVICE_MEMORY, lease, why) ||
        !map.resolve_function(keys[i], lease.even_bar_id, target, why) ||
        !map.check_range(target, 64'h2000, 8, address, why))
      return 0;
    if (!encode_notify(global_id, keys[i].host_id, address, entry, why)) begin
      why = {name, ": ", why};
      return 0;
    end
    item.ctx      = dpu_empty_context(target);
    item.ctx.kind = DPU_TABLE_RDMA_NOTIFY;
    item.owner    = keys[i];
    item.consumers.delete();
    item.consumers_complete = 0;
    item.value              = 128'(entry);
    item.writable_mask      = 128'h07ff_ffff_ffff_ffff;
    notify.push_back(item);

    route                = '0;
    route.host_id        = keys[i].host_id[2:0];
    route.enable         = 1;
    item.ctx.kind        = DPU_TABLE_RNET;
    item.ctx.table_index = global_id;
    item.value           = 128'(route);
    item.writable_mask   = 128'hf;
    rnet.push_back(item);
  end

  // 硬件二分查找使用 Host/地址，不能按 global ID 排行；先排序再检测完整查找键冲突。
  for (int	i = 1; i < notify.size(); i++) begin
    for (int	j = i; j > 0; j--) begin
      dpu_control_cfg_t	temporary;

      if (notify[j - 1].value[50:0] <= notify[j].value[50:0])
        break;
      temporary = notify[j - 1];
      notify[j - 1] = notify[j];
      notify[j] = temporary;
    end
  end
  foreach (notify[i]) begin
    if (i > 0 && notify[i - 1].value[50:0] == notify[i].value[50:0]) begin
      why = "duplicate RDMA Notify Host/address lookup key";
      return 0;
    end
    notify[i].ctx.table_index = i;
  end
  // 单 bank 的行号必须来自整个 RDMA 目录；禁止子集重新编号覆盖其余 Function。
  foreach (services[s]) begin
    if (!seen_key.exists(dpu_function_key_name(services[s].function_key))) begin
      why = {"RDMA catalog must include every declared RDMA Function: ",
        dpu_function_key_name(services[s].function_key)};
      return 0;
    end
  end
  foreach (notify[i])
    controls.push_back(notify[i]);
  foreach (rnet[i])
    controls.push_back(rnet[i]);
  why = "";
  return 1;
endfunction

// 功能：检查指定公共类别的记录能完整覆盖选定 Function，防止空批次伪成功。
// 输入/输出及副作用：kind/scope/keys 决定只读查询，batch 返回待做跨类别预检的记录，why 返回缺失 Function；不写配置。
// 失败/边界：public_records 拒绝或任一 key 无记录即失败；共享 MSI-X control/function 的 table-only 策略由调用方单独处理。
function bit rdma_project_cfg_seq::require_records(
  input dpu_table_kind_e	kind,
  input dpu_cfg_scope		scope,
  input dpu_function_key_t	keys[$],
  output dpu_table_item_t	batch[$],
  output string			why
);
  if (!cfg.public_records(kind, scope, batch, why))
    return 0;
  foreach (keys[k]) begin
    bit	found;

    found = 0;
    foreach (batch[b]) begin
      if (dpu_same_function_key(keys[k], batch[b].owner))
        found = 1;
    end
    if (!found) begin
      why = {kind.name(), " missing record for ", dpu_function_key_name(keys[k])};
      return 0;
    end
  end
  return 1;
endfunction

// 功能：合并有效表项、MSI-X 未用尾部与 AF/Notify使能跨度，在首笔事务前验证完整PCIe目标。
// 输入/输出及副作用：batch为有效记录，with_msix_tail选择父类将访问的完整尾部；why返回范围/冲突原因，不发送。
// 失败/边界：拒绝缺RC、容量超2048/小于有效行数、地址溢出/越BAR、未对齐/跨4KB、间接或重叠跨度；有效行仅允许同记录去重。
function bit rdma_project_cfg_seq::validate_targets(
  input dpu_table_item_t	batch[$],
  input bit			with_msix_tail,
  output string		why
);
  // 只用于一次预检的物理跨度；record_index=-1标识不可被任何表覆盖的握手寄存器。
  typedef struct {
    int unsigned	host;
    int unsigned	segment;
    bit [63:0]	first;
    bit [63:0]	last;
    int		record_index;
    string	name;
  } span_t;

  uvm_sequencer #(pcie_tl_tlp)	rc;
  dpu_bar_target_t		af_target;
  bit [63:0]			address;
  bit				seen_enable[string];
  span_t			spans[$];
  span_t			span;

  if (!cfg.bar_map.resolve_name("h0.pf0.bar0", af_target, why) ||
      !get_rc(af_target, rc, why) ||
      !cfg.bar_map.check_range(af_target, 64'h1010, 4, address, why))
    return 0;
  span.host         = af_target.function_key.host_id;
  span.segment      = af_target.pcie_id.domain.segment_id;
  span.first        = address;
  span.last         = address + 3;
  span.record_index = -1;
  span.name         = "AF handshake";
  spans.push_back(span);

  foreach (batch[i]) begin
    if (batch[i].ctx.kind != DPU_TABLE_RDMA_NOTIFY ||
        seen_enable.exists(batch[i].ctx.target.canonical_name))
      continue;
    if (!cfg.bar_map.check_range(batch[i].ctx.target, 64'h80044, 4, address, why))
      return 0;
    seen_enable[batch[i].ctx.target.canonical_name] = 1;
    span.host         = batch[i].ctx.target.function_key.host_id;
    span.segment      = batch[i].ctx.target.pcie_id.domain.segment_id;
    span.first        = address;
    span.last         = address + 3;
    span.record_index = -1;
    span.name         = "Notify enable";
    foreach (spans[j]) begin
      if (span.host == spans[j].host && span.segment == spans[j].segment &&
          span.first <= spans[j].last && spans[j].first <= span.last) begin
        why = "Notify enable overlaps an AF/enable reserved span";
        return 0;
      end
    end
    spans.push_back(span);
  end

  foreach (batch[i]) begin
    if (!get_rc(batch[i].ctx.target, rc, why) ||
        !cfg.bar_map.check_range(batch[i].ctx.target, batch[i].ctx.byte_offset,
          batch[i].ctx.layout.entry_bytes, address, why))
      return 0;
    if (batch[i].ctx.byte_offset[1:0] != 0 || address[1:0] != 0 ||
        batch[i].ctx.layout.indirect || address[11:0] + batch[i].ctx.layout.entry_bytes > 4096) begin
      why = "RDMA public tables require DWORD-aligned direct accesses contained within 4KB";
      return 0;
    end
    span.host         = batch[i].ctx.target.function_key.host_id;
    span.segment      = batch[i].ctx.target.pcie_id.domain.segment_id;
    span.first        = address;
    span.last         = address + batch[i].ctx.layout.entry_bytes - 1;
    span.record_index = i;
    span.name         = batch[i].ctx.kind.name();
    foreach (spans[j]) begin
      int	previous;

      if (span.host != spans[j].host || span.segment != spans[j].segment ||
          span.first > spans[j].last || spans[j].first > span.last)
        continue;
      previous = spans[j].record_index;
      // 和DPU remember_record一致：ctx/entry/enable完全相同的共享记录可以合并消费者。
      // 不用owner相等代替物理语义一致，也不因起始地址不同漏掉部分重叠。
      if (previous >= 0 && batch[i].ctx === batch[previous].ctx &&
          batch[i].entry === batch[previous].entry &&
          batch[i].enable_mask === batch[previous].enable_mask &&
          batch[i].enable_value === batch[previous].enable_value)
        continue;
      why = $sformatf("configuration span overlap: %s [%h:%h] with %s [%h:%h]",
        span.name, span.first, span.last, spans[j].name, spans[j].first, spans[j].last);
      return 0;
    end
    spans.push_back(span);
  end

  // 父类从全局紧凑目录末行之后写到 capacity，而不是只消费本 scope 的 public_records。
  // 先验证整个 bank 的算术/租约，再逐项检查实际8B读回边界；冲突仅加入未用尾部，
  // 不把有效 linear 行与自身所属 bank 的合法范围误判为重叠，也不复制公共无效项编码。
  if (with_msix_tail) begin
    dpu_table_ctx_t	ctx;
    bit [64:0]		bank_offset;
    bit [64:0]		bank_last;
    bit [63:0]		bank_address;
    bit [63:0]		row_address;
    int unsigned	used_rows;

    used_rows = cfg.msix_linear_records.size();
    if (used_rows == 0) begin
      why = "MSI-X linear directory is empty before tail preflight";
      return 0;
    end
    ctx = cfg.msix_linear_records[0].ctx;
    if (ctx.layout.capacity > 2048 || used_rows > ctx.layout.capacity) begin
      why = "MSI-X linear directory exceeds the single-bank layout";
      return 0;
    end
    bank_offset = {1'b0, ctx.layout.module_offset} + {1'b0, ctx.layout.table_offset};
    bank_last   = bank_offset + 65'(ctx.layout.capacity) * 8 - 1;
    if (bank_offset[64] || bank_last[64]) begin
      why = "MSI-X linear bank offset/span overflows 64 bits";
      return 0;
    end
    if (!get_rc(ctx.target, rc, why) ||
        !cfg.bar_map.check_range(ctx.target, bank_offset[63:0],
          64'(ctx.layout.capacity) * 8, bank_address, why))
      return 0;
    if (ctx.layout.indirect || ctx.layout.entry_bytes != 8 ||
        bank_offset[1:0] != 0 || bank_address[1:0] != 0) begin
      why = "MSI-X linear bank requires direct DWORD-aligned 8-byte rows";
      return 0;
    end
    for (int unsigned	row = used_rows; row < ctx.layout.capacity; row++) begin
      row_address = bank_address + 64'(row) * 8;
      if (row_address[11:0] + 8 > 4096) begin
        why = "MSI-X tail readback crosses a 4KB boundary";
        return 0;
      end
    end
    if (used_rows < ctx.layout.capacity) begin
      span.host         = ctx.target.function_key.host_id;
      span.segment      = ctx.target.pcie_id.domain.segment_id;
      span.first        = bank_address + 64'(used_rows) * 8;
      span.last         = bank_address + 64'(ctx.layout.capacity) * 8 - 1;
      span.record_index = -1;
      span.name         = "MSI-X unused tail";
      foreach (spans[j]) begin
        if (span.host == spans[j].host && span.segment == spans[j].segment &&
            span.first <= spans[j].last && spans[j].first <= span.last) begin
          why = $sformatf("configuration span overlap: %s [%h:%h] with %s [%h:%h]",
            span.name, span.first, span.last, spans[j].name, spans[j].first, spans[j].last);
          return 0;
        end
      end
    end
  end
  return 1;
endfunction

// 功能：公开无写入的完整预检供组合序列复用，检查必需表及 Function 覆盖并建立三个 scope。
// 输入/输出及副作用：读取已发布 cfg 和 rdma_functions；三个 scope 为输出，不发 MMIO、不修改冻结 catalog。
// 失败/边界：拒绝未发布/异源资源、缺表、编码/排序错误、重复目录及含尾项的容量/溢出/对齐/重叠/管理窗口错误。
function bit rdma_project_cfg_seq::preflight(
  output dpu_cfg_scope	bdf_scope,
  output dpu_cfg_scope	msix_scope,
  output dpu_cfg_scope	rdma_scope,
  output string		why
);
  dpu_control_cfg_t	expected[$];
  dpu_function_key_t	public_keys[$];
  dpu_function_key_t	msix_keys[$];
  int unsigned		bars[$];
  dpu_table_kind_e	rdma_kinds[$] = '{DPU_TABLE_RDMA_NOTIFY, DPU_TABLE_RNET};
  dpu_table_kind_e	msix_kinds[$] = '{
    DPU_TABLE_MSIX_LINEAR, DPU_TABLE_MSIX_INFO, DPU_TABLE_MSIX_INTERVAL,
    DPU_TABLE_MSIX_CONTROL, DPU_TABLE_MSIX_TABLE, DPU_TABLE_MSIX_FUNCTION
  };
  dpu_table_item_t		batch[$];
  dpu_table_item_t		all_records[$];
  bit [63:0]			address;
  bit				seen_msix[string];
  int unsigned			route_controls;

  bdf_scope  = null;
  msix_scope = null;
  rdma_scope = null;
  why        = "RDMA configuration requires published same-source frozen resources";
  if (cfg == null || !cfg.runtime_ready || cfg.device_snapshot == null || cfg.resource_snapshot == null)
    return 0;
  if (!cfg.resource_snapshot.is_frozen() ||
      !cfg.resource_snapshot.references_device_snapshot(cfg.device_snapshot))
    return 0;
  if (!make_catalog(cfg.device_snapshot, cfg.bar_map, rdma_functions, expected, why))
    return 0;
  route_controls = 0;
  foreach (cfg.frozen_controls[c]) begin
    if (cfg.frozen_controls[c].ctx.kind inside {DPU_TABLE_RDMA_NOTIFY, DPU_TABLE_RNET})
      route_controls++;
  end
  if (route_controls != expected.size()) begin
    why = "frozen Notify/RNET catalog contains missing or extra directory records";
    return 0;
  end
  cfg.device_snapshot.list_functions(public_keys);
  bdf_scope  = new("rdma_bdf_scope", cfg.device_snapshot, public_keys, bars, '{DPU_TABLE_BDF});
  rdma_scope = new("rdma_route_scope", cfg.device_snapshot, rdma_functions, bars, rdma_kinds);
  if (!cfg.configure_bdf) begin
    why = "RDMA routing requires configure_bdf=1";
    return 0;
  end
  if (!require_records(DPU_TABLE_BDF, bdf_scope, public_keys, batch, why))
    return 0;
  foreach (batch[b])
    all_records.push_back(batch[b]);
  foreach (rdma_kinds[k]) begin
    if (!cfg.public_records(rdma_kinds[k], rdma_scope, batch, why))
      return 0;
    foreach (batch[b])
      all_records.push_back(batch[b]);
    if (batch.size() != rdma_functions.size()) begin
      why = {rdma_kinds[k].name(), " requires exactly one record per selected RDMA Function"};
      return 0;
    end
    if (rdma_kinds[k] == DPU_TABLE_RDMA_NOTIFY) begin
      foreach (batch[b]) begin
        if (batch[b].ctx.target.canonical_name != batch[0].ctx.target.canonical_name ||
            batch[b].ctx.layout.module_offset != batch[0].ctx.layout.module_offset ||
            batch[b].ctx.layout.table_offset != batch[0].ctx.layout.table_offset ||
            batch[b].ctx.layout.capacity != batch[0].ctx.layout.capacity) begin
          why = "single-bank RDMA Notify requires one complete management window";
          return 0;
        end
      end
    end
    foreach (expected[e]) begin
      int unsigned	match_count;

      if (expected[e].ctx.kind != rdma_kinds[k])
        continue;
      match_count = 0;
      foreach (batch[b]) begin
        if (!dpu_same_function_key(expected[e].owner, batch[b].owner))
          continue;
        if (batch[b].ctx.table_index != expected[e].ctx.table_index || batch[b].entry !== expected[e].value) begin
          why = {rdma_kinds[k].name(), " identity/encoding/sorted row mismatch for ",
            dpu_function_key_name(expected[e].owner)};
          return 0;
        end
        if (rdma_kinds[k] == DPU_TABLE_RDMA_NOTIFY &&
            !cfg.bar_map.check_range(batch[b].ctx.target, 64'h80044, 4, address, why))
          return 0;
        match_count++;
      end
      if (match_count != 1) begin
        why = {rdma_kinds[k].name(), " missing/duplicate owner ", dpu_function_key_name(expected[e].owner)};
        return 0;
      end
    end
  end
  foreach (cfg.frozen_messages[m]) begin
    foreach (rdma_functions[f]) begin
      string	name;

      name = dpu_function_key_name(rdma_functions[f]);
      if (dpu_same_function_key(cfg.frozen_messages[m].owner, rdma_functions[f]) && !seen_msix.exists(name)) begin
        seen_msix[name] = 1;
        msix_keys.push_back(rdma_functions[f]);
      end
    end
  end
  if (msix_keys.size() != 0) begin
    msix_scope = new("rdma_msix_scope", cfg.device_snapshot, msix_keys, bars, msix_kinds);
    foreach (msix_kinds[k]) begin
      // table-only 是 DPU 显式平台声明；无声明时 control/function 的缺项由公共 validator 拒绝。
      if (msix_kinds[k] inside {DPU_TABLE_MSIX_CONTROL, DPU_TABLE_MSIX_FUNCTION}) begin
        if (!cfg.public_records(msix_kinds[k], msix_scope, batch, why))
          return 0;
        if (batch.size() != 0) begin
          why = {msix_kinds[k].name(), " requires a platform hook; this sequence supports explicit table_only_enable"};
          return 0;
        end
      end else if (!require_records(msix_kinds[k], msix_scope, msix_keys, batch, why))
        return 0;
      foreach (batch[b])
        all_records.push_back(batch[b]);
    end
  end
  if (!validate_targets(all_records, msix_scope != null, why))
    return 0;
  why = "";
  return 1;
endfunction

// 功能：按 AF、BDF、有效 MSI-X/无效尾项/使能、完整读回、Notify、RNET 顺序配置，成功才发布 success。
// 输入/输出及副作用：借用 cfg/RC，逐步更新 error_msg；正常失败保持 success=0，post_start 保留父类 fatal。
// 失败/边界：完整预检先于所有事务；任一写/读回失败停止后续类别，不 probe、不 initialize、不声称 posted write 可回滚。
task rdma_project_cfg_seq::body();
  dpu_cfg_scope	bdf_scope;
  dpu_cfg_scope	msix_scope;
  dpu_cfg_scope	rdma_scope;
  bit		ok;

  success           = 0;
  configured_tables = "";
  ok                = preflight(bdf_scope, msix_scope, rdma_scope, error_msg);
  if (!completed_step("rdma_preflight", ok)) return;
  declare_af(ok, error_msg);
  if (!completed_step("declare_af", ok)) return;
  configure_bdf_table(bdf_scope, ok, error_msg);
  if (!completed_step("configure_bdf_table", ok)) return;
  configured_tables = "BDF";
  if (msix_scope != null) begin
    configure_msix(msix_scope, ok, error_msg);
    if (!completed_step("configure_msix", ok)) return;
    // 单 bank 空行必须先失效再使能；父类保留唯一编码和高DWORD先写实现。
    process_msix_tail(0, ok, error_msg);
    if (!completed_step("initialize_msix_tail", ok)) return;
    enable_msix(msix_scope, ok, error_msg);
    if (!completed_step("enable_msix", ok)) return;
    configured_tables = {configured_tables, ",MSIX_LINEAR,MSIX_INFO,MSIX_INTERVAL,MSIX_TABLE(table_only_enable)"};
  end
  // 公共读回只验证 BDF/MSI-X 字节；不能据此声称 Notify/RNET 在真实 DUT 已生效。
  if (cfg.verify_readback) begin
    verify_function_configuration(bdf_scope, msix_scope, ok, error_msg);
    if (!completed_step("verify_function_configuration", ok)) return;
    if (msix_scope != null) begin
      process_msix_tail(1, ok, error_msg);
      if (!completed_step("verify_msix_tail", ok)) return;
    end
  end
  configure_rdma_notify(rdma_scope, ok, error_msg);
  if (!completed_step("configure_rdma_notify", ok)) return;
  configured_tables = {configured_tables, ",RDMA_NOTIFY"};
  configure_qsch_rnet(rdma_scope, ok, error_msg);
  if (!completed_step("configure_qsch_rnet", ok)) return;
  configured_tables = {configured_tables, ",RNET"};
  success           = 1;
  error_msg         = "";
endtask

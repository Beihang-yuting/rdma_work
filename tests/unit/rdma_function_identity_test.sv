// 目录/层次：tests/unit 的 Function identity 与 binding 值契约单元测试。
// 职责：验证 topology-aware Function/incarnation 比较、legacy mirror 迁移，以及
// binding identity/完整值的 nonfatal detached snapshot 边界。
// 主要依赖：rdma_model_pkg 的 Function identity/binding/handle、Task 9 factory-fault
// wrapper 和 UVM test/report 基础设施；不连接真实 PCIe、DMA 或 resource manager。
// 所有权与生命周期：run_phase 拥有全部 fixture/snapshot；raw factory override 保持
// 注册但在场景结束前 disarm，测试不取得任何外部 Function 资源生命周期。

// 设计说明：该 owner 子类型故意不在 binding snapshot 支持集合内，用于证明
// complete snapshot 不会把未知 runtime subtype 静默压平为 rdma_handle。
class rdma_function_identity_unknown_owner extends rdma_handle;
  typedef uvm_object_registry#(
    rdma_function_identity_unknown_owner,
    "rdma_function_identity_unknown_owner"
  ) type_id;

  // 功能：返回 hostile owner fixture 的独立 UVM registry singleton。
  // 输入/输出及副作用：无输入；返回 type_id wrapper，不构造或修改 handle。
  // 失败/边界：registry 名保持真实子类名，不受 get_type_name 基类伪装影响。
  static function type_id get_type();
    return type_id::get();
  endfunction

  // 功能：向 binding snapshot 测试公开 hostile owner 的真实 wrapper 身份。
  // 输入/输出及副作用：无输入；返回 get_type()，不访问 handle authority 字段。
  // 失败/边界：不得返回 rdma_handle 基类 wrapper，否则不能覆盖字符串冒充缺陷。
  virtual function uvm_object_wrapper get_object_type();
    return get_type();
  endfunction

  // 功能：构造 binding 不支持的 owner handle 动态类型。
  // 输入/输出及副作用：name 仅传给 rdma_handle；不登记真实资源。
  // 失败/边界：即使公共字段有效，complete snapshot 也必须非致命拒绝此类型，
  //   不得压平为 rdma_handle。
  function new(string name = "rdma_function_identity_unknown_owner");
    super.new(name);
  endfunction

  // 功能：故意伪造 exact base handle 的 legacy 类型名，复现字符串 subtype 绕过。
  // 输入/输出及副作用：无输入；返回 rdma_handle 名称，不改 owner 字段或注册 wrapper。
  // 失败/边界：get_object_type 仍标识本 hostile 注册子类，complete snapshot 必须拒绝。
  virtual function string get_type_name();
    return "rdma_handle";
  endfunction
endclass

// 设计说明：protected identity 只能由受限 test probe 注入故障，生产 accessor
// 仍通过公开 snapshot API 被验证，测试不会读取或泄露 protected handle。
class rdma_function_binding_identity_probe extends rdma_function_binding;
  `uvm_object_utils(rdma_function_binding_identity_probe)

  // 功能：构造可注入 protected identity 故障的 binding 测试探针。
  // 输入/输出及副作用：name 传给基类；默认 identity/PCIe/BAR 仍由基类拥有。
  // 失败/边界：未配置的 probe 与普通 binding 一样无法通过 validate。
  function new(string name = "rdma_function_binding_identity_probe");
    super.new(name);
  endfunction

  // 功能：把 protected identity 精确置空，构造 nonfatal accessor 的空 authority
  //   分支。
  // 输入/输出及副作用：无输入输出；仅清除本 probe 的 identity 引用。
  // 失败/边界：不可恢复原 identity；仅对专用故障 fixture 调用一次。
  function void inject_null_identity();
    identity = null;
  endfunction

  // 功能：把 protected identity generation 置零，构造非法 authority 分支。
  // 输入/输出及副作用：无输入输出；只修改 probe 拥有的 identity 值。
  // 失败/边界：identity 已为空时不操作；fixture 随后只能用于失败断言。
  function void inject_invalid_identity();
    if (identity != null)
      identity.generation = 0;
  endfunction
endclass

// 设计说明：主 test 以完整六 BAR binding 图和 hostile factory override 验证
// identity/complete snapshot 的值完整性、动态 owner 类型保持和源图分离。
class rdma_function_identity_test extends uvm_test;
  `uvm_component_utils(rdma_function_identity_test)
  // 功能：构造 Function identity/binding 契约测试组件，建立 UVM 层级身份。
  // 输入/输出及副作用：name 和 parent 传给 uvm_test；不创建 fixture、不安装 factory
  //   override，也不取得外部资源所有权。
  // 失败/边界：parent 为 null 时可作为顶层 test；测试数据与 objection 仅在
  //   run_phase 中创建和管理。
  function new(
    string name = "rdma_function_identity_test",
    uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // 功能：创建带显式 Host/root、PF/VF BDF 与 reset epoch 的有效 identity fixture。
  // 输入/输出及副作用：name 为对象名；返回测试拥有的新 identity，不修改外部
  //   topology。
  // 失败/边界：固定字段应通过 configure；失败时报告 UVM error 并返回该无效
  //   fixture，供调用测试暴露设置错误。
  function automatic rdma_function_identity make_test_identity(string name);
    rdma_function_identity identity;
    rdma_function_key_t key;
    rdma_status status;

    key = '{
      root_id:16'h44,
      host_topology_key:32'h5566_7788,
      function_kind:RDMA_FUNCTION_VF,
      parent_pf_bdf:'{
        segment:16'h1,
        bus:8'h20,
        device:5'h3,
        function_num:3'h0
      },
      vf_index:16'h2,
      bdf:'{
        segment:16'h1,
        bus:8'h21,
        device:5'h4,
        function_num:3'h1
      }
    };
    identity = rdma_function_identity::type_id::create(name);
    status = identity.configure(
      key,
      32'h1234,
      64'h1122_3344_5566_7788,
      32'd7,
      64'h0102_0304_0506_0708
    );
    if (status == null || !status.ok())
      `uvm_error("BINDING_IDENTITY_FIXTURE", "identity configure failed")
    return identity;
  endfunction

  // 功能：填充 binding 的六 BAR、DMA/capability、双向量、owner 与 ACTIVE flags。
  // 输入/输出及副作用：binding 和 identity 为输入；原地更新 binding 的公共配置
  //   字段和其拥有的 PCIe/BAR 值。
  // 失败/边界：任一输入为空会报告错误并返回；不连接真实 PCIe/DMA 后端。
  function automatic void populate_test_binding(
    rdma_function_binding binding,
    rdma_function_identity identity
  );
    rdma_interrupt_vector_binding vector;
    rdma_function_handle typed_owner;
    rdma_status status;

    if (binding == null || identity == null) begin
      `uvm_error("BINDING_FIXTURE", "binding or identity fixture is null")
      return;
    end

    status = binding.configure_identity(identity);
    if (status == null || !status.ok()) begin
      `uvm_error("BINDING_FIXTURE", "binding identity configure failed")
      return;
    end

    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    foreach (binding.pcie.bar[i]) begin
      binding.pcie.bar[i].bar_id = i;
      binding.pcie.bar[i].base.value = 64'h8000_0000 + (i * 64'h10000);
      binding.pcie.bar[i].size = 64'h10000;
      binding.pcie.bar[i].enabled = 1'b1;
    end

    binding.notify_bar_id = 0;
    binding.notify_base.value = 64'h8000_2000;
    binding.notify_size = 64'h2000;
    binding.notify_table_sel = 32'h0102_0304;
    binding.notify_table_index = 32'h0506_0708;
    binding.host_id = 32'h1112_1314;
    binding.pfvf_id = 32'h1516_1718;
    binding.rdma_vf_id = 32'h22;
    binding.vsi_id = 32'h2324_2526;
    binding.queue_dma.requester_bdf = identity.key.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'habcde;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 32'h1234_5678;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 4096;
    binding.queue_caps.max_aeq_depth = 4096;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 64'h0020_0000;
    binding.queue_caps.max_sgb_bytes = 64'h0040_0000;
    vector = '{
      function_local_vector:32'd3,
      hardware_eq_vector:32'd17,
      msix_table_index:32'd5,
      enabled:1'b1
    };
    binding.interrupt_vectors.push_back(vector);
    vector = '{
      function_local_vector:32'd4,
      hardware_eq_vector:32'd18,
      msix_table_index:32'd6,
      enabled:1'b1
    };
    binding.interrupt_vectors.push_back(vector);
    binding.state = RDMA_BIND_ACTIVE;
    typed_owner = new("binding_owner");
    typed_owner.kind = RDMA_RESOURCE_FUNCTION;
    typed_owner.function_uid = identity.function_uid;
    typed_owner.object_id = identity.global_function_id;
    typed_owner.generation = identity.generation;
    binding.owner_h = typed_owner;
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
  endfunction

  // 功能：验证两个 nonfatal accessor 在 hostile factory 下返回完整 detached 值。
  // 输入/输出及副作用：无显式输入；安装可 disarm override，并修改目标快照检查
  //   全部嵌套值与源图分离。
  // 失败/边界：null/invalid identity、PCIe/BAR、ACTIVE owner 与未知 subtype 都须
  //   返回非空失败 status、清空输出且不进入 raw factory。
  function automatic void check_nonfatal_binding_snapshots();
    rdma_function_identity identity;
    rdma_function_binding source;
    rdma_function_binding base_owner_source;
    rdma_function_binding unknown_owner_source;
    rdma_function_binding_identity_probe null_identity_source;
    rdma_function_binding_identity_probe invalid_identity_source;
    rdma_function_identity identity_snapshot;
    rdma_function_binding complete_snapshot;
    rdma_function_binding base_snapshot;
    rdma_function_handle typed_owner;
    rdma_handle exact_base_owner;
    rdma_function_identity_unknown_owner unknown_owner;
    rdma_pcie_identity saved_pcie;
    rdma_bar_info saved_bar;
    rdma_handle saved_owner;
    rdma_status status;
    uvm_factory factory;
    rdma_cmq_value_factory_fault_wrapper binding_fault;
    rdma_cmq_value_factory_fault_wrapper identity_fault;
    rdma_cmq_value_factory_fault_wrapper pcie_fault;
    rdma_cmq_value_factory_fault_wrapper bar_fault;
    rdma_cmq_value_factory_fault_wrapper handle_fault;
    rdma_cmq_value_factory_fault_wrapper function_handle_fault;

    identity = make_test_identity("snapshot_identity_source");
    source = rdma_function_binding::type_id::create("snapshot_binding_source");
    populate_test_binding(source, identity);
    base_owner_source = rdma_function_binding::type_id::create(
      "snapshot_base_owner_source"
    );
    populate_test_binding(base_owner_source, identity);
    exact_base_owner = new("exact_base_owner");
    exact_base_owner.kind = RDMA_RESOURCE_FUNCTION;
    exact_base_owner.function_uid = identity.function_uid;
    exact_base_owner.object_id = identity.global_function_id;
    exact_base_owner.generation = identity.generation;
    base_owner_source.owner_h = exact_base_owner;
    unknown_owner_source = rdma_function_binding::type_id::create(
      "snapshot_unknown_owner_source"
    );
    populate_test_binding(unknown_owner_source, identity);
    unknown_owner = new("unknown_owner");
    unknown_owner.kind = RDMA_RESOURCE_FUNCTION;
    unknown_owner.function_uid = identity.function_uid;
    unknown_owner.object_id = identity.global_function_id;
    unknown_owner.generation = identity.generation;
    unknown_owner_source.owner_h = unknown_owner;
    if (unknown_owner.get_type_name() != "rdma_handle" ||
        unknown_owner.get_object_type() == rdma_handle::get_type())
      `uvm_error("BINDING_UNKNOWN_OWNER_FIXTURE",
                 "hostile owner did not isolate name from wrapper")
    null_identity_source = new("null_identity_source");
    populate_test_binding(null_identity_source, identity);
    null_identity_source.inject_null_identity();
    invalid_identity_source = new("invalid_identity_source");
    populate_test_binding(invalid_identity_source, identity);
    invalid_identity_source.inject_invalid_identity();

    factory = uvm_factory::get();
    binding_fault = new("binding_snapshot_binding_fault",
                        rdma_function_binding::get_type());
    identity_fault = new("binding_snapshot_identity_fault",
                         rdma_function_identity::get_type());
    pcie_fault = new("binding_snapshot_pcie_fault",
                     rdma_pcie_identity::get_type());
    bar_fault = new("binding_snapshot_bar_fault",
                    rdma_bar_info::get_type());
    handle_fault = new("binding_snapshot_handle_fault",
                       rdma_handle::get_type());
    function_handle_fault = new(
      "binding_snapshot_function_handle_fault",
      rdma_function_handle::get_type()
    );
    factory.set_type_override_by_type(
      rdma_function_binding::get_type(), binding_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_function_identity::get_type(), identity_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_pcie_identity::get_type(), pcie_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_bar_info::get_type(), bar_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_handle::get_type(), handle_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_function_handle::get_type(), function_handle_fault, 1'b1
    );
    binding_fault.arm(1'b0);
    identity_fault.arm(1'b1);
    pcie_fault.arm(1'b0);
    bar_fault.arm(1'b1);
    handle_fault.arm(1'b0);
    function_handle_fault.arm(1'b1);

    identity_snapshot = null;
    status = source.snapshot_identity_nonfatal(identity_snapshot);
    if (status == null || !status.ok() || identity_snapshot == null ||
        identity_snapshot == identity ||
        !identity_snapshot.same_incarnation(identity))
      `uvm_error("BINDING_IDENTITY_NONFATAL",
                 "identity snapshot was null, invalid or aliased")

    complete_snapshot = null;
    status = source.snapshot_complete_nonfatal(complete_snapshot);
    if (status == null || !status.ok() || complete_snapshot == null ||
        complete_snapshot == source ||
        complete_snapshot.pcie == source.pcie ||
        complete_snapshot.owner_h == source.owner_h ||
        complete_snapshot.interrupt_vectors.size() != 2 ||
        complete_snapshot.pcie.bar[5] == source.pcie.bar[5] ||
        !complete_snapshot.validate().ok() ||
        !$cast(typed_owner, complete_snapshot.owner_h))
      `uvm_error("BINDING_COMPLETE_NONFATAL",
                 "complete snapshot lost value/type/detachment")

    if (complete_snapshot != null) begin
      identity_snapshot = complete_snapshot.identity_snapshot();
      identity_snapshot.key.host_topology_key++;
      complete_snapshot.function_uid++;
      complete_snapshot.pcie.bdf.bus++;
      foreach (complete_snapshot.pcie.bar[i]) begin
        complete_snapshot.pcie.bar[i].bar_id ^= 3'h1;
        complete_snapshot.pcie.bar[i].base.value++;
        complete_snapshot.pcie.bar[i].size++;
        complete_snapshot.pcie.bar[i].enabled ^= 1'b1;
      end
      complete_snapshot.notify_bar_id++;
      complete_snapshot.notify_base.value++;
      complete_snapshot.notify_size++;
      complete_snapshot.notify_table_sel++;
      complete_snapshot.notify_table_index++;
      complete_snapshot.host_id++;
      complete_snapshot.pfvf_id++;
      complete_snapshot.rdma_vf_id++;
      complete_snapshot.global_function_id++;
      complete_snapshot.vsi_id++;
      complete_snapshot.queue_dma.pasid++;
      complete_snapshot.queue_dma.dma_domain_id++;
      complete_snapshot.queue_caps.max_cq_depth++;
      complete_snapshot.queue_caps.max_queue_ring_bytes++;
      complete_snapshot.interrupt_vectors[0].hardware_eq_vector++;
      complete_snapshot.state = RDMA_BIND_ERROR;
      complete_snapshot.generation++;
      complete_snapshot.owner_h.object_id++;
      complete_snapshot.notify_valid ^= 1'b1;
      complete_snapshot.notify_ready ^= 1'b1;
      complete_snapshot.dmi_valid ^= 1'b1;
      complete_snapshot.dmi_ready ^= 1'b1;
      complete_snapshot.vft_valid ^= 1'b1;
      complete_snapshot.vft_ready ^= 1'b1;
    end
    if (source.function_uid != 64'h1122_3344_5566_7788 ||
        source.pcie.bdf.bus != 8'h21 ||
        source.pcie.bar[5].base.value != 64'h8005_0000 ||
        source.notify_table_index != 32'h0506_0708 ||
        source.queue_dma.pasid != 20'habcde ||
        source.queue_caps.max_cq_depth != 32768 ||
        source.interrupt_vectors[0].hardware_eq_vector != 17 ||
        source.owner_h.object_id != 32'h1234 ||
        !source.notify_valid || !source.notify_ready ||
        !source.dmi_valid || !source.dmi_ready ||
        !source.vft_valid || !source.vft_ready ||
        source.function_identity_snapshot().key.host_topology_key !=
          32'h5566_7788)
      `uvm_error("BINDING_SNAPSHOT_MUTATION",
                 "mutating complete snapshot changed source graph")

    base_snapshot = null;
    status = base_owner_source.snapshot_complete_nonfatal(base_snapshot);
    if (status == null || !status.ok() || base_snapshot == null ||
        base_snapshot.owner_h == null ||
        $cast(typed_owner, base_snapshot.owner_h) ||
        base_snapshot.owner_h.get_object_type() != rdma_handle::get_type())
      `uvm_error("BINDING_BASE_OWNER",
                 "exact base handle dynamic type was not preserved")

    complete_snapshot = source;
    status = unknown_owner_source.snapshot_complete_nonfatal(
      complete_snapshot
    );
    if (status == null || status.ok() || complete_snapshot != null)
      `uvm_error("BINDING_UNKNOWN_OWNER",
                 "unsupported owner subtype was flattened or published")

    identity_snapshot = identity;
    status = null_identity_source.snapshot_identity_nonfatal(identity_snapshot);
    if (status == null || status.ok() || identity_snapshot != null ||
        null_identity_source.function_identity_snapshot() != null ||
        null_identity_source.identity_snapshot() != null ||
        null_identity_source.get_identity() != null)
      `uvm_error("BINDING_NULL_IDENTITY",
                 "null protected identity leaked partial snapshot/fatal path")
    complete_snapshot = source;
    status = invalid_identity_source.snapshot_complete_nonfatal(
      complete_snapshot
    );
    if (status == null || status.ok() || complete_snapshot != null)
      `uvm_error("BINDING_INVALID_IDENTITY",
                 "invalid protected identity published complete snapshot")

    saved_pcie = source.pcie;
    source.pcie = null;
    complete_snapshot = base_owner_source;
    status = source.snapshot_complete_nonfatal(complete_snapshot);
    if (status == null || status.ok() || complete_snapshot != null)
      `uvm_error("BINDING_NULL_PCIE", "null PCIe published snapshot")
    source.pcie = saved_pcie;
    saved_bar = source.pcie.bar[3];
    source.pcie.bar[3] = null;
    complete_snapshot = base_owner_source;
    status = source.snapshot_complete_nonfatal(complete_snapshot);
    if (status == null || status.ok() || complete_snapshot != null)
      `uvm_error("BINDING_NULL_BAR", "null BAR published snapshot")
    source.pcie.bar[3] = saved_bar;
    saved_owner = source.owner_h;
    source.owner_h = null;
    complete_snapshot = base_owner_source;
    status = source.snapshot_complete_nonfatal(complete_snapshot);
    if (status == null || status.ok() || complete_snapshot != null)
      `uvm_error("BINDING_NULL_OWNER", "ACTIVE null owner published snapshot")
    source.owner_h = saved_owner;

    if (binding_fault.call_count() != 0 ||
        identity_fault.call_count() != 0 ||
        pcie_fault.call_count() != 0 || bar_fault.call_count() != 0 ||
        handle_fault.call_count() != 0 ||
        function_handle_fault.call_count() != 0)
      `uvm_error("BINDING_FACTORY_CALLS",
                 "nonfatal binding snapshot entered raw factory")
    binding_fault.disarm();
    identity_fault.disarm();
    pcie_fault.disarm();
    bar_fault.disarm();
    handle_fault.disarm();
    function_handle_fault.disarm();
  endfunction

  // 功能：验证 Function route/incarnation、identity clone、legacy binding 迁移、Host0
  //   边界和 Task 9 nonfatal complete snapshot 契约。
  // 输入/输出及副作用：phase 由 UVM 输入；首尾配对 objection，创建本地 identity/
  //   binding/handle fixture，并通过 UVM report 发布所有比较结果。
  // 失败/边界：不同 Host route、零 generation、空 BDF 或可变 accessor 泄漏被接受时
  //   报错；普通断言失败后继续覆盖其余分支，最终 drop objection。
  task run_phase(uvm_phase phase);
    rdma_function_identity lhs;
    rdma_function_identity rhs;
    rdma_function_identity copy;
    rdma_function_binding binding;
    rdma_function_identity snapshot;
    rdma_function_handle handle;
    uvm_object cloned;
    rdma_route_key_t lhs_route;
    rdma_route_key_t rhs_route;
    rdma_function_key_t key;
    rdma_status status;

    phase.raise_objection(this);
    check_nonfatal_binding_snapshots();

    key = '{
      root_id:16'h1,
      host_topology_key:32'h10,
      function_kind:RDMA_FUNCTION_VF,
      parent_pf_bdf:'{
        segment:0,
        bus:8'h20,
        device:5'h1,
        function_num:0
      },
      vf_index:16'h2,
      bdf:'{
        segment:0,
        bus:8'h30,
        device:5'h4,
        function_num:1
      }
    };
    lhs = rdma_function_identity::type_id::create("lhs");
    rhs = rdma_function_identity::type_id::create("rhs");
    status = lhs.configure(key, 7, 64'h1234, 1, 9);
    if (!status.ok())
      `uvm_error("IDENTITY",
                 $sformatf("lhs configure failed: %s",
                           status.convert2string()))
    key.host_topology_key = 32'h11;
    status = rhs.configure(key, 7, 64'h1234, 1, 9);
    if (!status.ok())
      `uvm_error("IDENTITY",
                 $sformatf("rhs configure failed: %s",
                           status.convert2string()))
    if (lhs.same_function(rhs))
      `uvm_error("IDENTITY", "different host route compared equal")
    lhs_route = lhs.route_key();
    rhs_route = rhs.route_key();
    if ((lhs_route.host_topology_key == rhs_route.host_topology_key &&
         lhs_route.root_id == rhs_route.root_id &&
         lhs_route.segment == rhs_route.segment &&
         lhs_route.bdf.segment == rhs_route.bdf.segment &&
         lhs_route.bdf.bus == rhs_route.bdf.bus &&
         lhs_route.bdf.device == rhs_route.bdf.device &&
         lhs_route.bdf.function_num == rhs_route.bdf.function_num) ||
        lhs_route.host_topology_key != 32'h10 ||
        lhs_route.root_id != 16'h1 || lhs_route.segment != 16'h0 ||
        lhs_route.bdf.segment != lhs.key.bdf.segment ||
        lhs_route.bdf.bus != lhs.key.bdf.bus ||
        lhs_route.bdf.device != lhs.key.bdf.device ||
        lhs_route.bdf.function_num != lhs.key.bdf.function_num ||
        rhs_route.host_topology_key != 32'h11)
      `uvm_error("IDENTITY", "route key fields are incorrect")
    cloned = lhs.clone();
    if (cloned == null || !$cast(copy, cloned)) begin
      `uvm_error("IDENTITY", "identity clone failed")
    end
    else begin
      copy.reset_epoch = lhs.reset_epoch + 1;
      if (!lhs.same_function(copy) || lhs.same_incarnation(copy))
        `uvm_error("IDENTITY", "reset epoch did not separate incarnation")
    end
    key = lhs.key;
    status = rhs.configure(key, 7, 64'h1234, 1, 10);
    if (!status.ok() || !lhs.same_function(rhs) || lhs.same_incarnation(rhs))
      `uvm_error("IDENTITY", "reset epoch did not separate incarnation")
    status = lhs.configure(key, 7, 64'h1234, 0, 10);
    if (status.ok() || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("IDENTITY", "zero generation accepted")

    // identity 是唯一 authority；未配置有效 identity 时，legacy scalar mirrors
    // 不能单独构造可用 Function handle。
    binding = rdma_function_binding::type_id::create("binding");
    binding.function_uid = 64'hfeed;
    binding.global_function_id = 32'hbeef;
    binding.generation = 32'h7;
    handle = binding.make_handle();
    if (handle != null)
      `uvm_error("IDENTITY", "legacy scalar fallback created a handle")

    // 显式兼容入口迁移 legacy mirrors，但仍要求确定的 Host/root/PCIe route。
    binding.pcie.bdf = '{
      segment:0,
      bus:8'h20,
      device:5'h1,
      function_num:3'h0
    };
    status = binding.configure_identity_from_legacy_mirrors(
      16'h0, 32'h1, RDMA_FUNCTION_PF);
    if (!status.ok())
      `uvm_error("IDENTITY",
                 $sformatf("legacy identity migration failed: %s",
                           status.convert2string()))
    handle = binding.make_handle();
    if (handle == null || handle.function_uid != 64'hfeed ||
        handle.object_id != 32'hbeef || handle.generation != 32'h7)
      `uvm_error("IDENTITY",
                 "explicit legacy migration did not create handle")

    status = binding.configure_identity(rhs);
    if (!status.ok())
      `uvm_error("IDENTITY",
                 $sformatf("binding identity configure failed: %s",
                           status.convert2string()))
    handle = binding.make_handle();
    if (handle == null || handle.function_uid != rhs.function_uid ||
        handle.object_id != rhs.global_function_id ||
        handle.generation != rhs.generation)
      `uvm_error("IDENTITY",
                 "identity authority did not produce expected handle")
    snapshot = binding.identity_snapshot();
    snapshot.key.host_topology_key = 32'hdead;
    snapshot.function_uid = 64'h123;
    handle = binding.make_handle();
    if (handle == null || handle.function_uid != rhs.function_uid ||
        binding.function_identity_snapshot().key.host_topology_key !=
          rhs.key.host_topology_key)
      `uvm_error("IDENTITY", "identity accessor leaked mutable authority")

    // global Function ID 可为零；UID 与 generation 仍是必须非零的 incarnation
    // 判别字段。
    key.host_topology_key = 32'h10;
    status = lhs.configure(key, 0, 64'h4321, 1, 11);
    if (!status.ok())
      `uvm_error("IDENTITY", "global function ID zero was rejected")

    // Host0 是合法显式 route；不完整 BDF 与错误 VF parent 仍须拒绝。
    key.host_topology_key = 0;
    status = rhs.configure(key, 1, 64'h7777, 1, 1);
    if (!status.ok())
      `uvm_error("IDENTITY", "explicit Host0 route was rejected")
    key.host_topology_key = 32'h20;
    key.bdf = '{
      segment:0,
      bus:0,
      device:0,
      function_num:0
    };
    status = rhs.configure(key, 1, 64'h7777, 1, 1);
    if (status.ok() || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("IDENTITY", "invalid zero BDF route was accepted")
    phase.drop_objection(this);
  endtask
endclass

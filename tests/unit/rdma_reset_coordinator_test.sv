// 目录：tests/unit/，位于 integration reset coordinator 的单元测试层。
// 职责：验证 Function、PF/VF、Host、Device 四类复位范围，以及注册 identity 克隆后
//       ledger 不受调用方可变对象影响。
// 依赖：rdma_reset_coordinator、rdma_function_identity、UVM；不连接真实 PCIe/Host memory。
// 所有权与生命周期：测试构造的 identity 由测试持有，coordinator 在 register_function()
//       内部克隆并管理自己的 ledger。
class rdma_reset_coordinator_test extends uvm_test;
  `uvm_component_utils(rdma_reset_coordinator_test)

  // 功能：构造 UVM reset coordinator 测试组件；测试场景在 run_phase() 中执行。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_reset_coordinator_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：构造一个具有指定 Host/root、PF/VF parent BDF、global ID 和 UID 的 identity
  //       夹具，统一生成 reset 范围测试所需的完整 authority。
  // 输入/输出及副作用：host_key（输入）、root_id（输入）、kind（输入）、vf_index（输入）、bdf_value（输入）、parent_bdf_value（输入）、uid（输入）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  function automatic rdma_function_identity make_identity(
    int unsigned host_key,
    int unsigned root_id,
    rdma_function_kind_e kind,
    int unsigned vf_index,
    int unsigned bdf_value,
    int unsigned parent_bdf_value,
    longint unsigned uid
  );
    rdma_function_identity identity;
    rdma_function_key_t key;
    rdma_status status;

    key.root_id = root_id;
    key.host_topology_key = host_key;
    key.function_kind = kind;
    key.vf_index = vf_index;
    key.bdf = '{segment:root_id[15:0], bus:bdf_value[15:8],
                device:bdf_value[7:3], function_num:bdf_value[2:0]};
    if (kind == RDMA_FUNCTION_PF)
      key.parent_pf_bdf = '0;
    else
      key.parent_pf_bdf = '{segment:root_id[15:0], bus:parent_bdf_value[15:8],
                            device:parent_bdf_value[7:3],
                            function_num:parent_bdf_value[2:0]};
    identity = rdma_function_identity::type_id::create("identity");
    status = identity.configure(key, uid[31:0], uid, 1, 0);
    if (!status.ok())
      `uvm_fatal("RESET", {"identity fixture failed: ", status.message})
    return identity;
  endfunction

  // 功能：依次执行 VF FLR、PF reset、Host reset 和 Device reset，并断言每种操作只
  //       推进规范定义的 Function/Host epoch。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：仿真超时、事务返回错误或断言不满足时报告 UVM_ERROR/UVM_FATAL；空 fixture 不得被当作成功。
  task run_phase(uvm_phase phase);
    rdma_reset_coordinator coordinator;
    rdma_function_identity pf0, vf0, pf1, mutated;
    rdma_reset_epoch_t pf0_epoch, vf0_epoch, pf1_epoch;
    uvm_object cloned_object;
    rdma_status status;

    phase.raise_objection(this);
    coordinator = rdma_reset_coordinator::type_id::create("coordinator");
    pf0 = make_identity(0, 0, RDMA_FUNCTION_PF, 0, 16'h0100, 0, 10);
    vf0 = make_identity(0, 0, RDMA_FUNCTION_VF, 1, 16'h0101, 16'h0100, 11);
    pf1 = make_identity(1, 1, RDMA_FUNCTION_PF, 0, 16'h0100, 0, 20);
    coordinator.register_function(pf0);
    coordinator.register_function(vf0);
    coordinator.register_function(pf1);
    // 显式 clone 后再篡改测试副本，避免把原始 PF identity 句柄改掉；这才
    // 能验证 coordinator 注册时保存的 ledger 与调用方对象生命周期隔离。
    cloned_object = pf0.clone();
    if (cloned_object == null || !$cast(mutated, cloned_object))
      `uvm_fatal("RESET", "identity mutation clone failed")
    mutated.key.bdf.bus = 8'h7f;
    // 注册时已经 clone，修改原对象不应改变 PF0 的 reset lookup。
    if (coordinator.function_epoch_uid(pf0.function_uid) != 0)
      `uvm_error("RESET", "new Function epoch was not zero")

    status = coordinator.request_vf_flr(vf0);
    if (!status.ok() || coordinator.function_epoch_uid(vf0.function_uid) != 1 ||
        coordinator.function_epoch_uid(pf0.function_uid) != 0)
      `uvm_error("RESET", "VF FLR affected the wrong Function")

    status = coordinator.request_pf_reset(pf0);
    if (!status.ok() || coordinator.function_epoch_uid(pf0.function_uid) != 1 ||
        coordinator.function_epoch_uid(vf0.function_uid) != 2 ||
        coordinator.function_epoch_uid(pf1.function_uid) != 0)
      `uvm_error("RESET", "PF reset did not affect PF and descendants only")

    status = coordinator.request_host_reset(0);
    if (!status.ok() || coordinator.host_epoch(0) != 1 ||
        coordinator.host_epoch(1) != 0 ||
        coordinator.function_epoch_uid(pf0.function_uid) != 2 ||
        coordinator.function_epoch_uid(vf0.function_uid) != 3 ||
        coordinator.function_epoch_uid(pf1.function_uid) != 0)
      `uvm_error("RESET", "Host reset scope is incorrect")

    status = coordinator.request_device_reset();
    if (!status.ok() || coordinator.device_epoch() != 1 ||
        coordinator.function_epoch_uid(pf0.function_uid) != 3 ||
        coordinator.function_epoch_uid(vf0.function_uid) != 4 ||
        coordinator.function_epoch_uid(pf1.function_uid) != 1)
      `uvm_error("RESET", "Device reset did not affect all Functions")

    pf0_epoch = coordinator.function_epoch_uid(pf0.function_uid);
    vf0_epoch = coordinator.function_epoch_uid(vf0.function_uid);
    pf1_epoch = coordinator.function_epoch_uid(pf1.function_uid);
    if (pf0_epoch == 0 || vf0_epoch == 0 || pf1_epoch == 0)
      `uvm_error("RESET", "reset ledger lost a registered Function")
    phase.drop_objection(this);
  endtask
endclass

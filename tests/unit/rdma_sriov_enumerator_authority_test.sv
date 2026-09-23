// 目录：测试层 tests/unit/。
// 职责：验证 SR-IOV enumerator 在 PCIe virtual API 返回 null status 或空输出时
//   fail-closed，不解引用空状态、不分配半个 BAR lease，也不伪造 VF 拓扑。
// 依赖：依赖 rdma_sriov_enumerator、rdma_pcie_api、rdma_pcie_bar_allocator 和
//   UVM；不依赖具体 pcie_work 实现，因此可在 core suite 独立运行。
// 所有权与生命周期：测试拥有 hostile PCIe stub、allocator 和 enumerator；
//   enumerator 仅借用 stub/allocator，测试结束时这些对象一起失效。

// 设计说明：该 stub 只破坏 status/output 契约，不提供任何有效 PCIe 拓扑；
//   测试的唯一预期是稳定的 INVALID_STATE envelope，不能把 null 当成成功或
//   用全零 capability 继续进入 BAR sizing。
class rdma_sriov_null_pcie_stub extends rdma_pcie_api;
  `uvm_object_utils(rdma_sriov_null_pcie_stub)

  // 功能：构造返回 null status 的 hostile PCIe stub，不创建外部 Function 或配置空间。
  // 输入/输出及副作用：name 传给 uvm_object；只初始化本地对象，不拥有 PCIe 资源。
  // 失败/边界：该对象只用于 authority 测试，任何业务调用都必须被 enumerator 拒绝。
  function new(string name = "rdma_sriov_null_pcie_stub");
    super.new(name);
  endfunction

  // 功能：模拟配置读取后端违约，清空 data 并不发布 completion status。
  // 输入/输出及副作用：target/offset 只用于接口兼容；data/status 输出分别置全 1/null。
  // 失败/边界：调用方若继续读取 status.ok() 即违反 fail-closed 契约，测试应捕获该路径。
  virtual task cfg_read32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    output bit [31:0] data,
    output rdma_status status
  );
    data = 32'hffff_ffff;
    status = null;
  endtask

  // 功能：模拟配置写入后端违约，不更新配置空间且返回 null status。
  // 输入/输出及副作用：target/offset/data/byte_enable 只用于接口兼容；status 输出置 null。
  // 失败/边界：enumerator 必须在任何 allocator 或 SR-IOV state 变更前把该违约转成错误。
  virtual task cfg_write32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    bit [31:0] data,
    bit [3:0] byte_enable,
    output rdma_status status
  );
    status = null;
  endtask

  // 功能：模拟 MMIO 写入后端违约，清空输入数据语义并返回 null status。
  // 输入/输出及副作用：function_h/address/data 只用于接口兼容；status 输出置 null，
  //   不发布任何 BAR 写事务，也不修改 stub 内部状态。
  // 失败/边界：SR-IOV 枚举不应触发 MMIO；若未来流程误调用，调用方仍必须把 null
  //   归一化为 INVALID_STATE，不能把该调用当成成功写入。
  virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );
    status = null;
  endtask

  // 功能：模拟 DMA visibility barrier 违约并返回 null status。
  // 输入/输出及副作用：function_h 只用于接口兼容；status 输出置 null，不产生外部 I/O。
  // 失败/边界：SR-IOV enumerator 不应调用此接口；若调用，null 仍不能被解释为成功。
  virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    status = null;
  endtask

  // 功能：模拟 MMIO ordering barrier 违约并返回 null status。
  // 输入/输出及副作用：function_h 只用于接口兼容；status 输出置 null，不推进任何游标。
  // 失败/边界：该路径不属于枚举流程；保留 null 可用于检查统一 API 的边界纪律。
  virtual task mmio_ordering_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    status = null;
  endtask

  // 功能：模拟 PF/VF Function snapshot 查询违约，清空 info 并返回 null status。
  // 输入/输出及副作用：bdf 为查询 key；info 输出置 null，不泄露任何内部对象。
  // 失败/边界：enumerator 必须返回非空 INVALID_STATE，且不得开始 capability 查询。
  virtual function rdma_status get_function_info(
    rdma_bdf_t bdf,
    output rdma_pcie_function_info info
  );
    info = null;
    return null;
  endfunction

  // 功能：模拟 SR-IOV capability discovery 违约，输出全零值并返回 null status。
  // 输入/输出及副作用：pf_bdf 为查询 key；info 输出清零，不修改任何外部状态。
  // 失败/边界：全零 capability 不是“无 VF”的成功结果，调用方必须先处理 null status。
  virtual function rdma_status discover_sriov(
    rdma_bdf_t pf_bdf,
    output rdma_pcie_sriov_info info
  );
    info = '{default:'0};
    return null;
  endfunction

  // 功能：模拟 BAR decode 违约，清空 result 并返回 null status。
  // 输入/输出及副作用：address 为待解码地址；result 输出置 null，不写入 route cache。
  // 失败/边界：enumerator 必须将该违约视为 INVALID_STATE，而不能接受空 route。
  virtual function rdma_status decode_bar(
    rdma_bar_addr_t address,
    output rdma_bar_decode result
  );
    result = null;
    return null;
  endfunction
endclass

// 设计说明：该 stub 提供最小的有效 PF/SR-IOV snapshot，但声明入口已经有
//   NumVFs/VFE/VF-MSE ownership，用于在不依赖 pcie_work 外部锁的 core suite
//   中验证 enumerator 的 quiescent-PF guard。
class rdma_sriov_preexisting_pcie_stub extends rdma_sriov_null_pcie_stub;
  `uvm_object_utils(rdma_sriov_preexisting_pcie_stub)

  bit [15:0] reported_num_vfs;
  bit reported_vf_enable;
  bit reported_vf_mse;

  // 功能：构造声明既有 SR-IOV ownership 的最小 PCIe stub，并清除可变报告字段。
  // 输入/输出及副作用：name 传给基类；只初始化本地 capability snapshot，不拥有外部 PCIe 资源。
  // 失败/边界：未设置的报告字段表示 disabled；调用方仍必须先配置 allocator/enumerator。
  function new(string name = "rdma_sriov_preexisting_pcie_stub");
    super.new(name);
    reported_num_vfs = 0;
    reported_vf_enable = 1'b0;
    reported_vf_mse = 1'b0;
  endfunction

  // 功能：返回一个与查询 BDF 一致的有效 PF snapshot，使枚举流程进入 capability guard。
  // 输入/输出及副作用：bdf（输入）、info（输出）；只创建 detached Function 值，不发送配置事务。
  // 失败/边界：info allocation 不会从外部 factory 借用资源；后续 capability guard 仍必须拒绝启用 PF。
  virtual function rdma_status get_function_info(
    rdma_bdf_t bdf,
    output rdma_pcie_function_info info
  );
    info = new("preexisting_pf_info");
    info.bdf = bdf;
    return rdma_status::make_direct(RDMA_SC_OK,
                                    "pre-existing PF snapshot ready");
  endfunction

  // 功能：发布满足基础枚举格式但带既有 NumVFs/VFE/VF-MSE 状态的 capability snapshot。
  // 输入/输出及副作用：pf_bdf（输入）、info（输出）；只写 detached fields，不修改 stub 外部账本。
  // 失败/边界：任一 ownership 字段非零都应被 enumerator 在 BAR/Control 写入前拒绝。
  virtual function rdma_status discover_sriov(
    rdma_bdf_t pf_bdf,
    output rdma_pcie_sriov_info info
  );
    info = '{default:'0};
    info.cap_offset = 12'h100;
    info.first_vf_offset = 16'h0001;
    info.vf_stride = 16'h0001;
    info.total_vfs = 16'h0004;
    info.num_vfs = reported_num_vfs;
    info.vf_enable = reported_vf_enable;
    info.vf_mse = reported_vf_mse;
    return rdma_status::make_direct(RDMA_SC_OK,
                                    "pre-existing SR-IOV snapshot ready");
  endfunction
endclass

// 设计说明：该 lease subtype 只用于验证 allocator 的 exact-type 门禁；它没有
// 任何额外业务字段，故测试失败只能归因于 factory 动态类型被错误接受。
class rdma_sriov_wrong_bar_lease_subtype extends rdma_pcie_bar_lease;
  `uvm_object_utils(rdma_sriov_wrong_bar_lease_subtype)

  // 功能：构造一个可被错误 factory override 返回的派生 BAR lease。
  // 输入/输出及副作用：name（输入）传给 rdma_pcie_bar_lease；只建立本地未激活
  //   字段，不登记 allocator 账本或占用 PCIe 地址。
  // 失败/边界：该对象可 cast 到基类但不属于 allocator 支持的 exact lease 类型；
  //   生产 allocate() 必须在写入字段或账本前拒绝它。
  function new(string name = "rdma_sriov_wrong_bar_lease_subtype");
    super.new(name);
  endfunction
endclass

// 设计说明：raw factory wrapper 在故障窗口内返回 null 或可 cast 但不受支持的
// lease subtype；窗口外委托原 registry，使本测试不会污染后续正向 allocator 场景。
class rdma_sriov_bar_lease_factory_fault_wrapper extends uvm_object_wrapper;
  protected string wrapper_type_name;
  protected uvm_object_wrapper delegate;
  protected bit armed_state;
  protected bit wrong_type_state;

  // 功能：保存原 lease factory wrapper，并以关闭故障的状态初始化 wrapper。
  // 输入/输出及副作用：name、delegate_value（输入）；保存 delegate 非拥有引用，
  //   不创建 lease 或修改全局 factory 注册表。
  // 失败/边界：delegate_value 为空时关闭窗口的 create 也返回 null，调用方必须
  //   将其视为 factory 失败而不是构造成功。
  function new(string name, uvm_object_wrapper delegate_value);
    wrapper_type_name = name;
    delegate = delegate_value;
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
  endfunction

  // 功能：在故障窗口内返回 null 或错误 lease subtype，窗口外转发原 registry。
  // 输入/输出及副作用：name（输入）传给 delegate/错误对象；返回 raw uvm_object，
  //   记录的对象不进入 allocator，除非被测实现错误地发布它。
  // 失败/边界：armed 且 wrong_type_state=0 返回 null；为 1 返回可 cast 但 exact
  //   type 不匹配的 subtype；delegate 缺失时关闭窗口同样返回 null。
  virtual function uvm_object create_object(string name = "");
    rdma_sriov_wrong_bar_lease_subtype wrong_object;

    if (!armed_state) begin
      if (delegate == null)
        return null;
      return delegate.create_object(name);
    end
    if (!wrong_type_state)
      return null;
    wrong_object = new(name);
    return wrong_object;
  endfunction

  // 功能：返回 wrapper 在 UVM factory 中登记的稳定测试名称。
  // 输入/输出及副作用：无显式输入；返回 wrapper_type_name，不修改 factory 或
  //   allocator 状态。
  // 失败/边界：该名称只用于诊断，不能替代被测 allocator 对动态类型的检查。
  virtual function string get_type_name();
    return wrapper_type_name;
  endfunction

  // 功能：打开一次 lease factory 故障窗口，选择 null 或错误 subtype 返回模式。
  // 输入/输出及副作用：wrong_type（输入）更新本地模式；不创建对象、不改变账本。
  // 失败/边界：重复 arm 只覆盖当前模式；调用方必须在下一次正向分配前 disarm。
  function void arm(bit wrong_type);
    armed_state = 1'b1;
    wrong_type_state = wrong_type;
  endfunction

  // 功能：关闭 lease factory 故障窗口，恢复对原 registry 的委托。
  // 输入/输出及副作用：无显式输入输出；清除 armed/wrong-type 标志，不删除全局
  //   override，也不改变已经创建的 lease。
  // 失败/边界：重复 disarm 幂等；已发布的错误 lease 若存在仍由 allocator 负责拒绝。
  function void disarm();
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
  endfunction
endclass

// 设计说明：UVM 1.2 没有删除 type override 的公开 API；当测试前没有显式
// override 时，恢复动作只能把原类型映射回自身。本 catcher 仅吞掉该中和动作
// 产生的 TYPDUP warning，避免把测试清理噪声混入产品报告。
class rdma_sriov_factory_restore_catcher extends uvm_report_catcher;

  // 功能：构造 factory restore 专用 report catcher，不保存业务状态。
  // 输入/输出及副作用：name（输入）传给 uvm_report_catcher；不安装自身到全局回调。
  // 失败/边界：未通过 uvm_report_cb::add 注册前不会捕获任何报告。
  function new(string name = "rdma_sriov_factory_restore_catcher");
    super.new(name);
  endfunction

  // 功能：抑制 base->base factory 中和操作产生的 TYPDUP warning，保留其他报告。
  // 输入/输出及副作用：读取当前 report severity/id；命中时返回 CAUGHT，不修改
  //   allocator、lease 或 factory 以外的全局状态。
  // 失败/边界：仅捕获 UVM_WARNING/TYPDUP；其他 warning/error/fatal 均返回 THROW。
  virtual function action_e catch();
    if (get_severity() == UVM_WARNING && get_id() == "TYPDUP")
      return CAUGHT;
    return THROW;
  endfunction
endclass

class rdma_sriov_enumerator_authority_test extends uvm_test;
  `uvm_component_utils(rdma_sriov_enumerator_authority_test)

  // 功能：构造 authority 边界测试组件，不创建外部 PCIe 资源。
  // 输入/输出及副作用：name/parent 传给 uvm_test；fixture 在 run_phase 中以 direct new 创建。
  // 失败/边界：构造成功不代表 enumerator 已配置，所有状态断言由 run_phase 完成。
  function new(string name = "rdma_sriov_enumerator_authority_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 allocator 的独立 aperture 上注入 lease factory 的 null/错误 subtype，
  //   验证失败时 output、账本、lease ID 和 first-fit 地址均保持原值。
  // 输入/输出及副作用：无显式参数；本 task 创建并配置本地 allocator，短时安装
  //   可 disarm 的 lease wrapper，执行失败/成功分配与 release，不触碰外部 PCIe。
  // 失败/边界：null 必须返回 RESOURCE_EXHAUSTED，派生 subtype 必须返回
  //   INVALID_STATE；两种失败均不得发布 lease 或推进 next_lease_id，正常分配后
  //   必须仍从 aperture base 开始且 release 恢复 active count=0。
  task automatic check_allocator_factory_atomicity();
    rdma_pcie_bar_allocator allocator;
    rdma_sriov_bar_lease_factory_fault_wrapper fault;
    rdma_pcie_bar_lease lease;
    rdma_status status;
    rdma_bdf_t pf_bdf;
    rdma_bar_addr_t aperture_base;
    uvm_factory factory;
    uvm_object_wrapper saved_override;
    rdma_sriov_factory_restore_catcher restore_catcher;
    longint unsigned expected_id;

    allocator = new("allocator_factory_atomicity");
    aperture_base = '{value:64'h0000_0002_0000_0000};
    status = allocator.configure(aperture_base, 64'h0000_0000_0001_0000);
    if (status == null || !status.ok()) begin
      `uvm_error("SRIOV_ALLOCATOR_FACTORY",
                 "failed to configure allocator factory fixture")
      return;
    end

    pf_bdf = '{segment:16'h0, bus:8'h2, device:5'h1, function_num:3'h0};
    factory = uvm_factory::get();
    saved_override = factory.find_override_by_type(
      rdma_pcie_bar_lease::get_type(), ""
    );
    fault = new("sriov_bar_lease_factory_fault",
                rdma_pcie_bar_lease::get_type());
    factory.set_type_override_by_type(
      rdma_pcie_bar_lease::get_type(), fault, 1'b1
    );
    expected_id = 1;

    for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
      fault.arm(wrong_type);
      lease = null;
      status = allocator.allocate(pf_bdf, 64'h1000, 64'h1000, lease);
      if (status == null ||
          (wrong_type == 0 && status.code != RDMA_SC_RESOURCE_EXHAUSTED) ||
          (wrong_type == 1 && status.code != RDMA_SC_INVALID_STATE) ||
          lease != null || allocator.active_lease_count() != 0) begin
        `uvm_error(
          "SRIOV_ALLOCATOR_FACTORY",
          $sformatf("factory failure was not atomic mode=%0d status=%s lease=%p count=%0d",
                    wrong_type,
                    (status == null) ? "<null>" : status.convert2string(),
                    lease,
                    allocator.active_lease_count())
        )
        if (lease != null)
          void'(allocator.release_lease(lease));
      end
      fault.disarm();

      lease = null;
      status = allocator.allocate(pf_bdf, 64'h1000, 64'h1000, lease);
      if (status == null || !status.ok() || lease == null ||
          lease.lease_id != expected_id ||
          lease.base.value != aperture_base.value ||
          allocator.active_lease_count() != 1) begin
        `uvm_error(
          "SRIOV_ALLOCATOR_FACTORY",
          $sformatf({"post-failure allocation changed state mode=%0d status=%s ",
                    "id=%0d expected=%0d base=0x%016h count=%0d"},
                    wrong_type,
                    (status == null) ? "<null>" : status.convert2string(),
                    (lease == null) ? 0 : lease.lease_id,
                    expected_id,
                    (lease == null) ? 0 : lease.base.value,
                    allocator.active_lease_count())
        )
      end
      if (lease != null) begin
        status = allocator.release_lease(lease);
        if (status == null || !status.ok() ||
            allocator.active_lease_count() != 0)
          `uvm_error("SRIOV_ALLOCATOR_FACTORY",
                     "post-failure lease release was not clean")
      end
      expected_id++;
    end

    fault.disarm();
    // 恢复测试前的 wrapper；没有显式 override 时 find_override_by_type 返回
    // 请求类型自身，直接跳过 set_type_override 可避免 UVM TYPDUP warning。
    if (saved_override != null &&
        saved_override != rdma_pcie_bar_lease::get_type()) begin
      factory.set_type_override_by_type(
        rdma_pcie_bar_lease::get_type(), saved_override, 1'b1
      );
    end
    else if (saved_override == rdma_pcie_bar_lease::get_type()) begin
      // UVM 没有 clear_type_override；base->base 是唯一公开的中和方式。
      restore_catcher = new("sriov_factory_restore_catcher");
      uvm_report_cb::add(null, restore_catcher);
      factory.set_type_override_by_type(
        rdma_pcie_bar_lease::get_type(),
        rdma_pcie_bar_lease::get_type(),
        1'b1
      );
      uvm_report_cb::delete(null, restore_catcher);
    end
    if (factory.find_override_by_type(rdma_pcie_bar_lease::get_type(), "") !=
        saved_override)
      `uvm_error("SRIOV_ALLOCATOR_FACTORY",
                 "lease factory override was not restored after fault window")
  endtask

  // 功能：在 core suite 中验证 NumVFs、VFE、VF-MSE 任一既有 ownership 都让
  //   enumerator 在首个配置写入前返回 INVALID_STATE。
  // 输入/输出及副作用：无显式参数；循环复用本地 stub/allocator/enumerator，读取
  //   status、discovered 和 active lease，不修改外部 PCIe manager。
  // 失败/边界：若任一模式继续 sizing、发布 Function 或留下 lease，则报告 UVM error；
  //   该夹具不覆盖 integration suite 验证的 BAR image 恢复细节。
  task automatic check_preexisting_sriov_guard();
    rdma_sriov_preexisting_pcie_stub pcie_stub;
    rdma_pcie_bar_allocator allocator;
    rdma_sriov_enumerator enumerator;
    rdma_pcie_function_info discovered[$];
    rdma_status status;
    rdma_bdf_t pf_bdf;

    pcie_stub = new("preexisting_pcie_stub");
    allocator = new("preexisting_allocator");
    status = allocator.configure(
      '{value:64'h0000_0001_1000_0000}, 64'h0000_0000_0010_0000
    );
    if (status == null || !status.ok()) begin
      `uvm_error("SRIOV_PREEXISTING", "failed to configure guard allocator")
      return;
    end
    enumerator = new("preexisting_enumerator");
    status = enumerator.configure(pcie_stub, allocator);
    if (status == null || !status.ok()) begin
      `uvm_error("SRIOV_PREEXISTING", "failed to configure guard enumerator")
      return;
    end
    pf_bdf = '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h0};
    for (int unsigned mode = 0; mode < 3; mode++) begin
      pcie_stub.reported_num_vfs = (mode == 0) ? 16'd2 : 16'd0;
      pcie_stub.reported_vf_enable = (mode == 1);
      pcie_stub.reported_vf_mse = (mode == 2);
      discovered.delete();
      enumerator.enumerate_and_configure_pf(
        pf_bdf, 1, discovered, status);
      if (status == null || status.code != RDMA_SC_INVALID_STATE ||
          discovered.size() != 0 || allocator.active_lease_count() != 0)
        `uvm_error("SRIOV_PREEXISTING", $sformatf(
          "guard accepted pre-existing mode=%0d status=%s count=%0d",
          mode, status == null ? "<null>" : status.convert2string(),
          allocator.active_lease_count()))
    end
  endtask

  // 功能：调用 null-status PCIe stub 的枚举入口，断言返回非空
  //   INVALID_STATE 且无 lease/VF 状态。
  // 输入/输出及副作用：phase 提供 UVM objection；本 task 创建并配置本地
  //   stub、allocator 和 enumerator。
  // 失败/边界：status 为空、错误码不是 INVALID_STATE、输出数组非空或
  //   active lease 非零均报告错误。
  task run_phase(uvm_phase phase);
    rdma_sriov_null_pcie_stub pcie_stub;
    rdma_pcie_bar_allocator allocator;
    rdma_sriov_enumerator enumerator;
    rdma_pcie_function_info discovered[$];
    rdma_status status;
    rdma_bdf_t pf_bdf;

    phase.raise_objection(this);

    pcie_stub = new("null_pcie_stub");
    allocator = new("authority_allocator");
    status = allocator.configure(
      '{value:64'h0000_0001_0000_0000}, 64'h0000_0000_0010_0000
    );
    if (status == null || !status.ok()) begin
      `uvm_error("SRIOV_ALLOCATOR", "failed to configure authority allocator")
      phase.drop_objection(this);
      return;
    end

    enumerator = new("authority_enumerator");
    status = enumerator.configure(pcie_stub, allocator);
    if (status == null || !status.ok()) begin
      `uvm_error("SRIOV_CONFIGURE", "failed to configure authority enumerator")
      phase.drop_objection(this);
      return;
    end

    pf_bdf = '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h0};
    enumerator.enumerate_and_configure_pf(
      pf_bdf, 1, discovered, status
    );

    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("SRIOV_NULL_STATUS", "null PCIe status was not normalized")
    if (discovered.size() != 0 || allocator.active_lease_count() != 0)
      `uvm_error("SRIOV_NULL_SIDE_EFFECT", "null PCIe status caused side effects")

    check_preexisting_sriov_guard();
    check_allocator_factory_atomicity();

    phase.drop_objection(this);
  endtask
endclass

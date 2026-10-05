// 目录/层次：tests/unit；职责：通过既有入口固定 hardware image 的复制与恢复契约。
// 依赖：model/core、UVM，以及 runtime 的错型载体和 CMQ 的 hostile clone/catcher fixture。
// 所有权/生命周期：测试拥有 image、探针和短期 factory；不 configure engine、不申请外部资源，
//   每个测试窗口恢复原 factory；不调用新增 metadata helper，允许在旧生产版本上执行。

// 只暴露原 protected 入口，不覆盖复制实现或改变业务状态。
class rdma_image_publish_probe extends rdma_queue_data_engine;
  // 功能：建立未配置的 queue-data 探针，仅用于无 I/O 的 image 物化。
  // 输入/输出及副作用：name 传给基类；基类拥有其本地初始状态。
  // 失败/边界：不 attach runtime，不能用本 fixture 执行真实发布。
  function new(string name = "image_publish_probe");
    super.new(name);
  endfunction

  // 功能：透传原 publish image 复制，观察 typed factory 与队列替换策略。
  // 输入/输出及副作用：source 输入、copy 输出；原样返回生产 status。
  // 失败/边界：不吞 null/错型 factory 的拒绝或 fatal，不重试。
  function rdma_status copy_for_test(rdma_hw_image source, output rdma_hw_image copy);
    return clone_publish_image(source, copy);
  endfunction
endclass

// 记录完整创建名序列；预填队列暴露 append 与 replace 差异，故障只在指定名触发。
class rdma_image_copy_factory extends uvm_default_factory;
  string trace;
  string fault_name;
  int unsigned fault_kind;
  string alias_name;
  rdma_hw_image alias_value;

  // 功能：建立无故障 factory，默认对 image 预填一项 bytes/summary。
  // 输入/输出及副作用：无参数；trace 与故障名清空，alias_value=null。
  // 失败/边界：构造不安装全局 factory，调用方负责短窗口替换与恢复。
  function new();
    super.new();
    trace = "";
    fault_name = "";
    fault_kind = 0;
    alias_name = "";
    alias_value = null;
  endfunction

  // 功能：记录每次 factory 请求，按名字返回 null/错型/别名或预填 image。
  // 输入/输出及副作用：requested_type/path/name 输入；更新 trace，普通非 image 请求透传。
  // 失败/边界：fault_kind=1/2 分别注入 null/错型；别名只用于先清空队列的入口，
  //   禁止把非空自别名交给 poll 的 foreach+push_back，以免旧实现无界追加。
  virtual function uvm_object create_object_by_type(
    uvm_object_wrapper requested_type, string parent_inst_path = "", string name = ""
  );
    rdma_hw_image candidate;
    rdma_runtime_value_wrong wrong;

    trace = {trace, name, ";"};
    if (name == fault_name && fault_kind != 0) begin
      if (fault_kind == 1)
        return null;
      wrong = new();
      return wrong;
    end
    if (name == alias_name)
      return alias_value;
    if (requested_type == rdma_hw_image::get_type()) begin
      candidate = new(name);
      candidate.bytes.push_back(8'hee);
      candidate.field_summary.push_back("factory prefix");
      return candidate;
    end
    return super.create_object_by_type(requested_type, parent_inst_path, name);
  endfunction
endclass

// 七个旧入口使用独立字段 oracle；不使用生产的同值比较或新增 helper 自证正确性。
class rdma_hw_image_copy_contract_test extends uvm_test;
  `uvm_component_utils(rdma_hw_image_copy_contract_test)
  int unsigned cases;

  // 功能：建立独立 image 契约测试，不运行任何父测试场景。
  // 输入/输出及副作用：name/parent 透传；完成计数清零。
  // 失败/边界：不在构造中安装 factory 或运行仿真业务。
  function new(string name = "rdma_hw_image_copy_contract_test", uvm_component parent = null);
    super.new(name, parent);
    cases = 0;
  endfunction

  // 功能：构造覆盖 endian、四类 target、非零地址和满位版本值的 64-byte 镜像。
  // 输入/输出及副作用：tag 决定 metadata/bytes。
  // 失败/边界：仅用于值复制，target 地址不是外部授权；所有 queue 均测试独占。
  function rdma_hw_image make_source(int unsigned tag);
    rdma_hw_image value;

    value = new("metadata_source");
    value.length = 64;
    value.alignment = 1 << (tag % 7);
    value.endian = tag[0] ? RDMA_ENDIAN_BIG : RDMA_ENDIAN_LITTLE;
    value.image_kind = RDMA_IMAGE_SQE;
    value.hardware_version = tag == 15 ? '1 : tag + 1;
    value.function_generation = tag == 15 ? '1 : tag + 17;
    value.write_target_kind = rdma_hw_target_kind_e'(tag % 4);
    value.backing_target.value = 64'h8123_4567_89ab_cdef + tag;
    value.hmc_target.value = 64'hfedc_ba98_7654_3210 - tag;
    value.bar_target.value = 64'hffff_ffff_ffff_ffff - tag;
    for (int unsigned i = 0; i < 64; i++)
      value.bytes.push_back(byte'(i + tag));
    value.field_summary.push_back($sformatf("metadata %0d", tag));
    value.field_summary.push_back("");
    return value;
  endfunction

  // 功能：逐项断言十项 metadata 与两组 queue，允许 poll 独有的一项 factory 前缀。
  // 输入/输出及副作用：source/copy/prefix 输入；只读比较，不调用生产同值 helper。
  // 失败/边界：空输出 fatal；字段、队列长度或内容漂移报 error，避免越界后误判通过。
  function void check_value(rdma_hw_image source, rdma_hw_image copy, bit prefix = 0);
    if (source == null || copy == null)
      `uvm_fatal("IMAGE_COPY", "missing image value")
    if (copy.length != source.length || copy.alignment != source.alignment ||
        copy.endian != source.endian || copy.image_kind != source.image_kind ||
        copy.hardware_version != source.hardware_version ||
        copy.function_generation != source.function_generation ||
        copy.write_target_kind != source.write_target_kind ||
        copy.backing_target != source.backing_target || copy.hmc_target != source.hmc_target ||
        copy.bar_target != source.bar_target)
      `uvm_error("IMAGE_COPY", "metadata drift")
    if (copy.bytes.size() != source.bytes.size() + int'(prefix) ||
        copy.field_summary.size() != source.field_summary.size() + int'(prefix)) begin
      `uvm_error("IMAGE_COPY", "queue size drift")
      return;
    end
    if (prefix && (copy.bytes[0] != 8'hee || copy.field_summary[0] != "factory prefix"))
      `uvm_error("IMAGE_COPY", "factory prefix lost")
    foreach (source.bytes[i]) begin
      if (copy.bytes[i + int'(prefix)] != source.bytes[i])
        `uvm_error("IMAGE_COPY", "byte drift")
    end
    foreach (source.field_summary[i]) begin
      if (copy.field_summary[i + int'(prefix)] != source.field_summary[i])
        `uvm_error("IMAGE_COPY", "summary drift")
    end
  endfunction

  // 功能：按 api 选择七个既有复制入口，只为 void/bit 接口生成直接 status 供统一断言。
  // 输入/输出及副作用：api/source 输入、copy 输出；每次递增 cases，不调用 metadata helper。
  // 失败/边界：api 越界 fatal；生产错误 status 原样返回，探针不覆盖原 protected 方法。
  function rdma_status invoke(int unsigned api, rdma_hw_image source, output rdma_hw_image copy);
    rdma_queue_pending_operation pending, pending_copy;
    rdma_image_publish_probe publisher;
    bit copied;

    cases++;
    case (api)
      0: begin
        copy = new("model_copy");
        copy.do_copy(source);
      end
      1: return rdma_queue_runtime_projector::clone_image_value_nonfatal(source, copy);
      2: return rdma_queue_data_projector::clone_poll_image_nonfatal(source, copy);
      3: begin
        publisher = new();
        return publisher.copy_for_test(source, copy);
      end
      4: begin
        pending = new("pending");
        pending_copy = new("pending_copy");
        pending.image = source;
        pending_copy.do_copy(pending);
        copy = pending_copy.image;
      end
      5: begin
        copied = rdma_cmq_try_snapshot_image_direct(source, 1'b1, copy);
        return rdma_status::make_direct(copied ? RDMA_SC_OK : RDMA_SC_INVALID_ARGUMENT);
      end
      6: return rdma_cmq_checked_image_snapshot(source, "metadata", RDMA_SC_TIMEOUT, copy);
      default: `uvm_fatal("IMAGE_COPY", "unknown copy API")
    endcase
    return rdma_status::make_direct(RDMA_SC_OK);
  endfunction

  // 功能：112 组成功样本冻结七入口的 metadata、queue 策略、创建序列和结果隔离。
  // 输入/输出及副作用：无参数；短期安装记录 factory，修改 copy 证明 source queue 不变。
  // 失败/边界：任何非 OK、别名、创建名/顺序变化或源值漂移均报 error，最后恢复 factory。
  function void check_success_matrix();
    uvm_coreservice_t service = uvm_coreservice_t::get();
    uvm_factory original;
    rdma_image_copy_factory observer;
    rdma_hw_image source, copy, expected;
    rdma_status status;
    string expected_trace;

    original = uvm_factory::get();
    for (int unsigned api = 0; api < 7; api++) begin
      for (int unsigned tag = 0; tag < 16; tag++) begin
        source = make_source(tag);
        expected = make_source(tag);
        observer = new();
        service.set_factory(observer);
        status = invoke(api, source, copy);
        service.set_factory(original);
        case (api)
          1: expected_trace = "nonfatal_image_copy;runtime_status;";
          2: expected_trace = "cq_poll_pending_image;queue_data_engine_status;";
          3: expected_trace = "image_publish_probe_backing_planner;publish_image_copy;rdma_status;";
          6: expected_trace = "metadata_saved;rdma_status;";
          default: expected_trace = "";
        endcase
        if (status == null || !status.ok() || copy == source || observer.trace != expected_trace)
          `uvm_error("IMAGE_COPY", $sformatf("success API %0d trace=%s", api, observer.trace))
        check_value(expected, copy, api == 2);
        copy.bytes[api == 2 ? 1 : 0]++;
        copy.field_summary[api == 2 ? 1 : 0] = "modified copy";
        check_value(expected, source);
      end
    end
  endfunction

  // 功能：固定 raw/typed image 分配故障及两类 status factory 的不同失败策略。
  // 输入/输出及副作用：无参数；六次 image 故障和四次 status 故障，临时注册精确 FCTTYP catcher。
  // 失败/边界：publish 错型应有一次被捕获 fatal；poll status 失败返回 null+已发布 copy，
  //   runtime 同故障返回直接 fallback；所有 callback/factory 在窗口末恢复。
  function void check_factory_failures();
    uvm_coreservice_t service = uvm_coreservice_t::get();
    uvm_factory original;
    rdma_image_copy_factory observer;
    rdma_cmq_snapshot_factory_fatal_catcher catcher;
    rdma_hw_image source, copy;
    rdma_status status;
    string names[3] = '{"nonfatal_image_copy", "cq_poll_pending_image", "publish_image_copy"};
    string messages[3] = '{"image copy allocation failed", "CQ poll image allocation failed",
                           "publish image allocation failed"};

    original = uvm_factory::get();
    source = make_source(3);
    for (int unsigned api = 1; api <= 3; api++) begin
      for (int unsigned fault = 1; fault <= 2; fault++) begin
        observer = new();
        observer.fault_name = names[api - 1];
        observer.fault_kind = fault;
        catcher = new();
        uvm_report_cb::add(null, catcher);
        service.set_factory(observer);
        status = invoke(api, source, copy);
        service.set_factory(original);
        uvm_report_cb::delete(null, catcher);
        if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED || copy != null ||
            status.message != messages[api - 1] ||
            catcher.caught_count != int'(api == 3 && fault == 2))
          `uvm_error("IMAGE_COPY", "image factory failure contract drift")
      end
    end
    for (int unsigned api = 1; api <= 2; api++) begin
      for (int unsigned fault = 1; fault <= 2; fault++) begin
        observer = new();
        observer.fault_name = api == 1 ? "runtime_status" : "queue_data_engine_status";
        observer.fault_kind = fault;
        service.set_factory(observer);
        status = invoke(api, source, copy);
        service.set_factory(original);
        if ((api == 1 && (status == null || !status.ok())) || (api == 2 && status != null))
          `uvm_error("IMAGE_COPY", "status fallback contract drift")
        check_value(source, copy, api == 2);
      end
    end
  endfunction

  // 功能：固定五个可空入口、六种 hostile clone 和三次自别名复制的旧行为。
  // 输入/输出及副作用：无参数；clone 可改写源值，checked snapshot 必须恢复公开字段；
  //   runtime/publish 的 hostile factory 自别名保留先清空源队列的历史行为。
  // 失败/边界：不对 null 调用 do_copy，不测试非空 poll 自追加；拒绝 clone 必须清空输出。
  function void check_boundaries();
    uvm_coreservice_t service = uvm_coreservice_t::get();
    uvm_factory original;
    rdma_image_copy_factory observer;
    rdma_cmq_snapshot_image hostile;
    rdma_hw_image source, copy, expected;
    rdma_status status;
    rdma_status_code_e code;

    for (int unsigned api = 1; api < 7; api++) begin
      if (api == 4)
        continue;
      status = invoke(api, null, copy);
      code = api inside {2, 3} ? RDMA_SC_INVALID_ARGUMENT :
             api == 6 ? RDMA_SC_TIMEOUT : RDMA_SC_OK;
      if (status == null || status.code != code || copy != null)
        `uvm_error("IMAGE_COPY", "null input contract drift")
    end
    for (int unsigned mode = 0; mode < 6; mode++) begin
      hostile = new("hostile_image");
      expected = make_source(4);
      hostile.do_copy(expected);
      hostile.clone_mode = rdma_cmq_snapshot_clone_mode_e'(mode);
      hostile.third_equal_value = make_source(4);
      status = invoke(6, hostile, copy);
      check_value(expected, hostile);
      if (hostile.clone_calls != 1 || status == null)
        `uvm_fatal("IMAGE_COPY", "hostile clone did not complete")
      if (mode inside {0, 5}) begin
        if (!status.ok() || copy == hostile)
          `uvm_error("IMAGE_COPY", "equal clone rejected")
        check_value(expected, copy);
      end
      else if (status.code != RDMA_SC_TIMEOUT || copy != null)
        `uvm_error("IMAGE_COPY", "hostile clone accepted")
    end
    source = make_source(15);
    expected = make_source(15);
    source.do_copy(source);
    cases++;
    check_value(expected, source);
    original = uvm_factory::get();
    for (int unsigned api = 1; api <= 3; api += 2) begin
      source = make_source(7);
      expected = make_source(7);
      expected.bytes.delete();
      expected.field_summary.delete();
      observer = new();
      observer.alias_name = api == 1 ? "nonfatal_image_copy" : "publish_image_copy";
      observer.alias_value = source;
      service.set_factory(observer);
      status = invoke(api, source, copy);
      service.set_factory(original);
      if (status == null || !status.ok() || copy != source)
        `uvm_error("IMAGE_COPY", "alias identity contract drift")
      check_value(expected, source);
    end
  endfunction

  // 功能：运行成功、factory 故障、clone 恢复与 alias 三组矩阵，输出完整计数标记。
  // 输入/输出及副作用：phase 管理 objection；只执行同步值操作，结束不遗留 factory/callback。
  // 失败/边界：136 次调用不齐报 error；测试不使用等待，不代表线程并发或 I/O 验证。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_success_matrix();
    check_factory_failures();
    check_boundaries();
    if (cases != 136)
      `uvm_error("IMAGE_COPY", $sformatf("unexpected calls %0d", cases))
    `uvm_info("IMAGE_COPY", "completed 136 image copy contract calls", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass

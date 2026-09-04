// 目录：测试层 unit/rdma_cqe_size_codec_test.sv。
// 职责：验证 32/64/128B CQE layout 的编码与解码往返契约。
// 依赖：rdma_codec_pkg；测试仅拥有本地字段和镜像数组。
// 所有权与生命周期：测试镜像由本地过程创建并在测试结束释放，不接管外部资源。

class rdma_cqe_size_codec_test extends uvm_test;
  `uvm_component_utils(rdma_cqe_size_codec_test)

  // 功能：构造 UVM 测试组件并建立默认名称。
  // 输入输出及副作用：name/parent 为 UVM 输入；仅初始化组件层级。
  // 失败边界：父组件为空时由 UVM 框架处理，测试不分配外部资源。
  function new(string name="rdma_cqe_size_codec_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：执行三种 CQE profile 的字段编码、解码和关键字段相等断言。
  // 输入输出及副作用：无显式输入；失败通过 UVM error/fatal 报告，不修改生产状态。
  // 失败边界：任一 profile layout 无效、codec 返回错误或 qpn/wr_id 不一致即测试失败。
  task automatic test_cqe_sizes_round_trip();
    int unsigned sizes[3] = '{32,64,128};
    rdma_cqe_fields source, decoded;
    byte unsigned image[];
    rdma_cqe_layout layout;
    rdma_status st;
    source = '{qpn:32'h1234, wr_id:64'h56789a, valid:1'b1};
    foreach (sizes[i]) begin
      layout = rdma_cqe_layout::for_bytes(sizes[i],16);
      st = rdma_queue_codec::encode_cqe(source,layout,image);
      if (!st.ok())
        `uvm_fatal("CQE_RED","encode failed")
      st = rdma_queue_codec::decode_cqe(image,layout,decoded);
      if (!st.ok() || decoded.qpn != source.qpn || decoded.wr_id != source.wr_id)
        `uvm_error("CQE_ROUNDTRIP","CQE size/layout round trip failed")
    end
  endtask

  // 功能：在 run_phase 中启动 CQE 往返测试并完成 UVM objection 生命周期。
  // 输入输出及副作用：phase 为输入；驱动测试任务并发布 objection 结果。
  // 失败边界：codec 断言失败由测试宏记录，任务仍释放 objection 以避免仿真悬挂。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_cqe_sizes_round_trip();
    phase.drop_objection(this);
  endtask
endclass

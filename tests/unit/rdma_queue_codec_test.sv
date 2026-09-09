// 目录：测试层 unit/rdma_queue_codec_test.sv。
// 职责：验证 rdma_queue_codec_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_codec_test extends uvm_test;
  `uvm_component_utils(rdma_queue_codec_test)

  // 功能：构造 rdma_queue_codec_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_codec_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_queue_codec_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：在 rdma_queue_codec_test 中，h 从测试 fixture 返回预先构造的 Function/队列句柄或 DMA 上下文，保持调用方与 fixture 使用同一实例。
  // 输入/输出及副作用：n（输入）、k（输入）、id（输入）；h 读取 n、k、id 并使用字段 x、x.kind、x.object_id、x.function_uid、x.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：h 的结果直接由 return x 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_handle h(string n, rdma_resource_kind_e k, int unsigned id);
    rdma_handle x=rdma_handle::type_id::create(n); x.kind=k; x.object_id=id;
    x.function_uid=64'h1122; x.generation=1; return x;
  endfunction

  // 功能：ok 按函数体读取当前字段并生成 void 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：l（输入）、s（输入）；ok 读取 l、s 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  function automatic void ok(string l, rdma_status s);
    if (s==null || !s.ok()) `uvm_error(l, s==null?"null":s.convert2string());
  endfunction

  // 功能：在 rdma_queue_codec_test 中，eq_bytes 逐字节比较两个硬件镜像并在长度或内容不一致时报告测试错误。
  // 输入/输出及副作用：l（输入）、a（输入）、b（输入）；eq_bytes 读取 l、a、b 并使用字段 i；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：eq_bytes 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function automatic void eq_bytes(string l, rdma_hw_image a, rdma_hw_image b);
    if (a==null || b==null || a.bytes.size()!=b.bytes.size()) begin `uvm_error(l,"image mismatch"); return; end
    foreach (a.bytes[i]) if (a.bytes[i]!==b.bytes[i]) `uvm_error(l,$sformatf("byte %0d",i));
  endfunction

  // 功能：在 rdma_queue_codec_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_codec_registry r; rdma_status s; rdma_codec_base c; rdma_hw_image im,im2; rdma_hw_model m;
    rdma_hw_sqe_model sq, sq2; rdma_hw_rqe_model rq, rq2; rdma_hw_cqe_model cq, cq2;
    rdma_hw_ceqe_model ceqe;
    rdma_sqe_rc_ext re; rdma_sge sg; byte unsigned bad[];
    phase.raise_objection(this);
    r=rdma_codec_registry::type_id::create("r"); s=rdma_register_queue_codecs(r); ok("register",s);
    // 设计说明：CQ handle.object_id 是 resource manager 分配的 global incarnation，
    // cqn 是 Function-local CQ ID；二者不共享命名空间，model/codec 只能校验 handle
    // kind 和各字段宽度，完整 identity 由 queue-data attachment 边界完成。
    ceqe=rdma_hw_ceqe_model::type_id::create("ceqe_local_cqn");
    ceqe.cq_h=h("ceqe_cq",RDMA_RESOURCE_CQ,32'h3000_0002);
    ceqe.cqn=21'h1; ceqe.qpn=0; ceqe.cq_pi=16'h1; ceqe.cq_pi_wrap=0;
    ceqe.valid=0; ceqe.ecode=0; ceqe.packet_opcode=0;
    s=ceqe.validate(); ok("ceqe global handle local cqn validate",s);
    s=r.lookup('{hw_version:"rdma",image_kind:RDMA_IMAGE_CEQE,object_type:"ceqe",variant:"default",opcode:0},c);
    ok("lookup ceqe",s); s=c.encode(ceqe,im); ok("ceqe global handle local cqn encode",s);
    sq=rdma_hw_sqe_model::type_id::create("sq"); sq.transport=RDMA_TRANSPORT_RC; sq.qp_h=h("q",RDMA_RESOURCE_QP,'h15555);
    sq.hw_opcode=4'hd; sq.icos=5; sq.qp_sn=8'ha6; sq.dst_port=11; sq.index='h4567; sq.wrap=1; sq.sign_en=1; sq.se=1; sq.fence=2; sq.ce=2; sq.valid=1; sq.signature=8'hc7;
    re=rdma_sqe_rc_ext::type_id::create("re"); re.remote_access_valid=1; re.rkey_valid=1; re.rkey=32'hdeadbeef; re.remote_addr.value=64'h0123456789abcdef; sq.transport_ext=re;
    sg=rdma_sge::type_id::create("sg"); sg.iova.value=64'h1000; sg.length=8; sq.sges.push_back(sg); sq.sge_num=4;
    s=r.lookup('{hw_version:"rdma",image_kind:RDMA_IMAGE_SQE,object_type:"sqe",variant:"rc",opcode:0},c); ok("lookup sq",s); s=c.encode(sq,im); ok("sq encode",s); s=c.decode(im,m); ok("sq decode",s); $cast(sq2,m); s=c.encode(sq2,im2); ok("sq reencode",s); eq_bytes("sq roundtrip",im,im2);
    rq=rdma_hw_rqe_model::type_id::create("rq"); rq.target_h=h("rq",RDMA_RESOURCE_QP,1); rq.qpn='habcde; rq.qp_sn='h5a; rq.hw_opcode=9; rq.index='h3456; rq.wrap=1; rq.valid=1; rq.payload_len='h10203040; rq.signature=8'h96; rq.sge_num=2; rq.sges.push_back(sg);
    s=r.lookup('{hw_version:"rdma",image_kind:RDMA_IMAGE_RQE,object_type:"rqe",variant:"default",opcode:0},c); ok("lookup rq",s); s=c.encode(rq,im); ok("rq encode",s); s=c.decode(im,m); ok("rq decode",s);
    cq=rdma_hw_cqe_model::type_id::create("cq"); cq.qp_h=h("cq",RDMA_RESOURCE_QP,'h2aaaa); cq.qpn='h2aaaa; cq.wqe_index='h4567; cq.ecode=8'hf4; cq.payload_len='h10203040; cq.polarity=1; cq.rq_cqe=1; cq.wqe_wrap=1; cq.packet_opcode=8'h9a; cq.immediate_data=32'h89abcdef; cq.status=rdma_status::type_id::create("st");
    s=r.lookup('{hw_version:"rdma",image_kind:RDMA_IMAGE_CQE,object_type:"cqe",variant:"default",opcode:0},c); ok("lookup cq",s); s=c.encode(cq,im); ok("cq encode",s); s=c.decode(im,m); ok("cq decode",s);
    bad = new[64]; foreach (bad[i]) bad[i]=0; bad[0]=8'h1; im.bytes.delete(); foreach (bad[i]) im.bytes.push_back(bad[i]); im.length=64; im.alignment=64; im.endian=RDMA_ENDIAN_BIG; im.image_kind=RDMA_IMAGE_CQE; im.hardware_version=1; s=c.validate_image(im); if (s==null || s.ok()) `uvm_error("reserved","reserved bits accepted");
    phase.drop_objection(this);
  endtask
endclass

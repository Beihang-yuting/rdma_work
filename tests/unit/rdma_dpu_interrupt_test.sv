// 目录：单元测试层 tests/unit/rdma_dpu_interrupt_test.sv。
// 层：dpu_common 外部适配器单元测试。
// 职责：验证冻结 Function 快照控制的 MAILBOX/MSI-X 最小完整路径：寄存器编程、masked pending、
//   pending 合并、解 mask 投递、状态/ack、显式设备中断、失败恢复、跨 Host domain 拒绝、Function
//   隔离与 FLR epoch。
// 依赖：rdma_dpu_adapter_pkg、dpu_resource_pkg、rdma_types_pkg；不依赖 pcie_work 或外部 DUT。
// 所有权：测试拥有 rdma_dpu_system；节点拥有各自中断控制器与事件队列，快照/BAR 身份由 dpu_common
//   生成并冻结。
// 生命周期：run_phase 内建立三 Function 拓扑并执行同步 MMIO；结束后不保留外部资源或后台进程。

class rdma_dpu_interrupt_test extends uvm_test;
  `uvm_component_utils(rdma_dpu_interrupt_test)

  localparam bit [63:0] MESSAGE_ADDRESS_0 = 64'h0000_0000_fee0_1000;
  localparam bit [63:0] MESSAGE_ADDRESS_1 = 64'h0000_0000_fee0_2000;
  localparam bit [31:0] MESSAGE_DATA_0 = 32'h0000_0041;
  localparam bit [31:0] MESSAGE_DATA_1 = 32'h0000_0082;

  rdma_dpu_system sys;

  // 功能：构造 MAILBOX/MSI-X 适配器测试组件，系统引用保持为空并由 run_phase 建立。
  // 输入/输出及副作用：name/parent 透传给 uvm_test；不创建拓扑、寄存器或中断事件。
  // 失败/边界：run_phase 调用 build_system 前 sys 为 null，不得从其他 phase 访问节点。
  function new(string name = "rdma_dpu_interrupt_test", uvm_component parent = null);
    super.new(name, parent);
    sys = null;
  endfunction

  // 功能：建立 Host0 PF0/VF1 与 Host1 PF0，依次验证 masked MAILBOX 路径、失败恢复和复位隔离。
  // 输入/输出及副作用：phase objection 覆盖全部同步检查；创建并修改 sys 的控制面状态。
  // 失败/边界：build 或关键前置操作失败用 UVM_FATAL 停止；契约不符用 UVM_ERROR 报告后继续收集。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    build_system();
    check_masked_mailbox_path();
    check_failure_recovery();
    check_function_and_reset_isolation();
    phase.drop_objection(this);
  endtask

  // 功能：断言 status 非空且 code=OK，用 what 标识失败的寄存器或中断步骤。
  // 输入/输出及副作用：只读 status；失败时发 UVM_FATAL，不修改被测状态。
  // 失败/边界：status=null 与任意非 OK code 都视为夹具无法继续，诊断避免解引用 null。
  function void expect_ok(string what, rdma_status status);
    if (status == null || !status.ok())
      `uvm_fatal("DPU_IRQ", $sformatf("%s failed: %s", what,
                 status == null ? "null" : status.convert2string()))
  endfunction

  // 功能：断言 status 返回 expected code，用于验证 MMIO、epoch、队列与发布冲突的失败契约。
  // 输入/输出及副作用：what/expected/status 只读；不消费事件或改写控制器。
  // 失败/边界：status=null 或 code 不符时发 UVM_ERROR，并安全输出 null 诊断。
  function void expect_code(string what, rdma_status_code_e expected, rdma_status status);
    if (status == null || status.code != expected)
      `uvm_error("DPU_IRQ", $sformatf("%s returned %s, expected %s", what,
                 status == null ? "null" : status.convert2string(), expected.name()))
  endfunction

  // 功能：声明两个 Host 的三个 Function 并 build，确认每个节点都有独立控制器且初始 epoch=1、vector0 masked。
  // 输入/输出及副作用：创建 sys、冻结 dpu_common 快照并分配节点控制面；不 probe 驱动、不启动 NIC。
  // 失败/边界：build 失败、节点数不为三、控制器缺失或复位默认值错误时发 UVM_FATAL/ERROR。
  function void build_system();
    rdma_status status;

    sys = rdma_dpu_system::type_id::create("interrupt_dpu");
    sys.add_host(0);
    sys.add_host(1);
    sys.add_function(0, 0, DPU_FUNCTION_PF, 0);
    sys.add_function(0, 0, DPU_FUNCTION_VF, 1);
    sys.add_function(1, 0, DPU_FUNCTION_PF, 0);
    status = sys.build();
    expect_ok("build interrupt topology", status);
    if (sys.nodes.size() != 3)
      `uvm_fatal("DPU_IRQ", $sformatf("snapshot produced %0d nodes instead of 3", sys.nodes.size()))
    foreach (sys.nodes[i]) begin
      if (sys.nodes[i].interrupt_ctrl == null ||
          sys.nodes[i].interrupt_ctrl.reset_epoch != 1 ||
          sys.nodes[i].interrupt_ctrl.vectors.size() == 0 ||
          !sys.nodes[i].interrupt_ctrl.vectors[0].masked)
        `uvm_error("DPU_IRQ", $sformatf("node %0d has invalid interrupt reset state", i))
    end
  endfunction

  // 功能：经快照路由向节点 node_index 的 MSI-X BAR 写 vector0 address 与 data/control。
  // 输入/输出及副作用：address/data/masked 组成 table entry；每次成功写增加 router.routed，pending 时可能投递。
  // 失败/边界：任一 BAR 写失败即 UVM_FATAL；地址对齐和保留位失败由独立失败用例验证。
  task program_vector0(int unsigned node_index, bit [63:0] address,
                       bit [31:0] data, bit masked);
    rdma_dpu_node node;
    rdma_status status;
    bit [63:0] control;

    node = sys.nodes[node_index];
    sys.router.write(node.func.pcie_id.domain,
                     node.func.msix.base + RDMA_DPU_MSIX_ADDRESS_OFFSET,
                     address, status);
    expect_ok("program MSI-X address", status);
    control = '0;
    control[31:0] = data;
    control[32] = masked;
    sys.router.write(node.func.pcie_id.domain,
                     node.func.msix.base + RDMA_DPU_MSIX_DATA_CTRL_OFFSET,
                     control, status);
    expect_ok("program MSI-X data/control", status);
  endtask

  // 功能：经快照路由写节点 MAILBOX 的 payload 或 command/ack 寄存器。
  // 输入/输出及副作用：node_index/offset/value 形成 64 位 MMIO，status 返回模型结果；可能发布或消费状态。
  // 失败/边界：node_index 由本测试固定为合法节点；非法 offset/value 原样返回失败 status 供调用方断言。
  task mailbox_write(int unsigned node_index, bit [63:0] offset, bit [63:0] value,
                     output rdma_status status);
    rdma_dpu_node node;

    node = sys.nodes[node_index];
    sys.router.write(node.func.pcie_id.domain, node.func.mailbox.base + offset, value, status);
  endtask

  // 功能：经快照路由读取节点 MAILBOX payload/command/status，供位级状态断言。
  // 输入/输出及副作用：node_index/offset 为输入，value/status 为输出；读取不消费发布或事件。
  // 失败/边界：写专用/未知/未对齐 offset 的失败由路由器返回；失败时 value 为零。
  task mailbox_read(int unsigned node_index, bit [63:0] offset,
                    output bit [63:0] value, output rdma_status status);
    rdma_dpu_node node;

    node = sys.nodes[node_index];
    sys.router.read(node.func.pcie_id.domain, node.func.mailbox.base + offset, value, status);
  endtask

  // 功能：核对 irq 精确携带 node 的 Function key、PCIe ID、vector0、消息地址/数据、cause 与 reset epoch。
  // 输入/输出及副作用：只读 irq/node 及期望值；不弹出队列或确认 MAILBOX。
  // 失败/边界：irq=null 立即 UVM_FATAL；任一身份或载荷字段不符发 UVM_ERROR，避免跨 Function 串线被掩盖。
  function void check_event(string what, rdma_dpu_interrupt_event irq, rdma_dpu_node node,
                            bit [63:0] address, bit [31:0] data, bit [63:0] cause,
                            rdma_reset_epoch_t epoch);
    if (irq == null)
      `uvm_fatal("DPU_IRQ", {what, " returned a null interrupt"})
    if (dpu_function_key_name(irq.function_key) != dpu_function_key_name(node.func.key) ||
        dpu_pcie_function_id_name(irq.pcie_id) != dpu_pcie_function_id_name(node.func.pcie_id) ||
        irq.vector_index != 0 || irq.message_address != address ||
        irq.message_data != data || irq.cause != cause || irq.reset_epoch != epoch)
      `uvm_error("DPU_IRQ", $sformatf("%s event identity/payload does not match %s epoch %0d",
                                      what, dpu_function_key_name(node.func.key), epoch))
  endfunction

  // 功能：验证 vector0 初始 mask 时 MAILBOX command 只置 pending，解 mask 后投递一次事件并由 ack 清发布。
  // 输入/输出及副作用：编程 node0，读取 MSI-X/MAILBOX 寄存器，消费一条事件并确认发布。
  // 失败/边界：mask 期间错误投递、pending/sequence/epoch 位错误、ack 过早成功或事件字段不符均报错。
  task check_masked_mailbox_path();
    rdma_dpu_node node;
    rdma_dpu_interrupt_event irq;
    rdma_status status;
    bit [63:0] value;
    bit [63:0] payload;
    bit [63:0] command;
    bit [63:0] control;

    node = sys.nodes[0];
    payload = 64'h1122_3344_5566_7788;
    command = 64'h0000_0000_0000_00a1;
    program_vector0(0, MESSAGE_ADDRESS_0, MESSAGE_DATA_0, 1'b1);
    sys.router.read(node.func.pcie_id.domain,
                    node.func.msix.base + RDMA_DPU_MSIX_ADDRESS_OFFSET, value, status);
    expect_ok("read MSI-X address", status);
    if (value != MESSAGE_ADDRESS_0)
      `uvm_error("DPU_IRQ", $sformatf("MSI-X address readback %016h", value))
    mailbox_write(0, RDMA_DPU_MAILBOX_PAYLOAD_OFFSET, payload, status);
    expect_ok("write MAILBOX payload", status);
    mailbox_write(0, RDMA_DPU_MAILBOX_COMMAND_OFFSET, command, status);
    expect_ok("publish masked MAILBOX command", status);
    mailbox_read(0, RDMA_DPU_MAILBOX_PAYLOAD_OFFSET, value, status);
    expect_ok("read MAILBOX payload", status);
    if (value != payload)
      `uvm_error("DPU_IRQ", $sformatf("MAILBOX payload readback is %016h", value))
    mailbox_read(0, RDMA_DPU_MAILBOX_COMMAND_OFFSET, value, status);
    expect_ok("read MAILBOX command", status);
    if (value != command)
      `uvm_error("DPU_IRQ", $sformatf("MAILBOX command readback is %016h", value))
    mailbox_read(0, RDMA_DPU_MAILBOX_STATUS_OFFSET, value, status);
    expect_ok("read masked MAILBOX status", status);
    if (value[3:0] != 4'b0011 || value[31:16] != 16'h1 ||
        value[63:32] != node.interrupt_ctrl.reset_epoch[31:0])
      `uvm_error("DPU_IRQ", $sformatf("masked MAILBOX status is %016h", value))
    sys.router.read(node.func.pcie_id.domain,
                    node.func.msix.base + RDMA_DPU_MSIX_DATA_CTRL_OFFSET, value, status);
    expect_ok("read masked MSI-X control", status);
    if (value[33:32] != 2'b11 || value[31:0] != MESSAGE_DATA_0)
      `uvm_error("DPU_IRQ", $sformatf("masked MSI-X data/control is %016h", value))
    expect_code("masked interrupt queue", RDMA_SC_QUEUE_EMPTY,
                sys.router.pop_interrupt(node.func.key, irq));
    mailbox_write(0, RDMA_DPU_MAILBOX_ACK_OFFSET, 64'h1, status);
    expect_code("ack while pending", RDMA_SC_RESOURCE_BUSY, status);
    control = '0;
    control[31:0] = MESSAGE_DATA_0;
    sys.router.write(node.func.pcie_id.domain,
                     node.func.msix.base + RDMA_DPU_MSIX_DATA_CTRL_OFFSET,
                     control, status);
    expect_ok("unmask pending MSI-X", status);
    sys.router.read(node.func.pcie_id.domain,
                    node.func.msix.base + RDMA_DPU_MSIX_DATA_CTRL_OFFSET, value, status);
    expect_ok("read delivered MSI-X control", status);
    if (value[33:32] != 2'b00 || value[31:0] != MESSAGE_DATA_0)
      `uvm_error("DPU_IRQ", $sformatf("delivered MSI-X data/control is %016h", value))
    expect_ok("pop delivered MAILBOX interrupt",
              sys.router.pop_interrupt(node.func.key, irq));
    check_event("masked MAILBOX", irq, node, MESSAGE_ADDRESS_0, MESSAGE_DATA_0,
                command, node.interrupt_ctrl.reset_epoch);
    mailbox_read(0, RDMA_DPU_MAILBOX_STATUS_OFFSET, value, status);
    expect_ok("read delivered MAILBOX status", status);
    if (value[3:0] != 4'b0101)
      `uvm_error("DPU_IRQ", $sformatf("delivered MAILBOX status is %016h", value))
    mailbox_write(0, RDMA_DPU_MAILBOX_ACK_OFFSET, 64'h1, status);
    expect_ok("ack delivered MAILBOX", status);
    mailbox_write(0, RDMA_DPU_MAILBOX_ACK_OFFSET, 64'h1, status);
    expect_ok("repeat MAILBOX ack", status);
    mailbox_read(0, RDMA_DPU_MAILBOX_STATUS_OFFSET, value, status);
    expect_ok("read acknowledged MAILBOX status", status);
    if (value[3:0] != 4'b0000 || value[31:16] != 16'h1)
      `uvm_error("DPU_IRQ", $sformatf("acknowledged MAILBOX status is %016h", value))
    mailbox_read(0, RDMA_DPU_MAILBOX_PAYLOAD_OFFSET, value, status);
    expect_ok("read cleared MAILBOX payload", status);
    if (value != 0)
      `uvm_error("DPU_IRQ", $sformatf("ack left MAILBOX payload %016h", value))
  endtask

  // 功能：验证未配置地址的 unmasked command 返回失败但保留发布/pending，后续地址编程可恢复投递；
  //   同时覆盖只读/保留位/未对齐/重复发布/非法 vector 的错误码。
  // 输入/输出及副作用：FLR node0 后重编程控制位、发布命令并恢复；消费恢复事件并 ack。
  // 失败/边界：失败不得丢 pending 或产生早到事件；旧状态由 FLR 清除，错误请求不得修改其他 Function。
  task check_failure_recovery();
    rdma_dpu_node node;
    rdma_dpu_interrupt_event irq;
    rdma_status status;
    int unsigned scope[$];
    bit [63:0] value;
    bit [63:0] control;
    bit [63:0] command;

    node = sys.nodes[0];
    scope = '{0};
    sys.flr(scope);
    control = '0;
    control[31:0] = MESSAGE_DATA_0;
    sys.router.write(node.func.pcie_id.domain,
                     node.func.msix.base + RDMA_DPU_MSIX_DATA_CTRL_OFFSET,
                     control, status);
    expect_ok("unmask empty MSI-X entry", status);
    command = 64'h0000_0000_0000_00b2;
    mailbox_write(0, RDMA_DPU_MAILBOX_COMMAND_OFFSET, command, status);
    expect_code("publish without MSI-X address", RDMA_SC_INVALID_STATE, status);
    mailbox_read(0, RDMA_DPU_MAILBOX_STATUS_OFFSET, value, status);
    expect_ok("read failed MAILBOX status", status);
    if (value[3:0] != 4'b1011)
      `uvm_error("DPU_IRQ", $sformatf("failed MAILBOX status is %016h", value))
    mailbox_write(0, RDMA_DPU_MAILBOX_COMMAND_OFFSET, 64'hc3, status);
    expect_code("overwrite active MAILBOX command", RDMA_SC_RESOURCE_BUSY, status);
    mailbox_write(0, RDMA_DPU_MAILBOX_PAYLOAD_OFFSET, 64'h55, status);
    expect_code("overwrite active MAILBOX payload", RDMA_SC_RESOURCE_BUSY, status);
    mailbox_write(0, RDMA_DPU_MAILBOX_ACK_OFFSET, 64'h1, status);
    expect_code("ack failed pending command", RDMA_SC_RESOURCE_BUSY, status);
    sys.router.write(node.func.pcie_id.domain,
                     node.func.msix.base + RDMA_DPU_MSIX_ADDRESS_OFFSET,
                     MESSAGE_ADDRESS_0, status);
    expect_ok("repair MSI-X address", status);
    expect_ok("pop repaired MAILBOX interrupt",
              sys.router.pop_interrupt(node.func.key, irq));
    check_event("repaired MAILBOX", irq, node, MESSAGE_ADDRESS_0, MESSAGE_DATA_0,
                command, node.interrupt_ctrl.reset_epoch);
    mailbox_write(0, RDMA_DPU_MAILBOX_ACK_OFFSET, 64'h1, status);
    expect_ok("ack repaired MAILBOX", status);
    mailbox_write(0, RDMA_DPU_MAILBOX_COMMAND_OFFSET, 64'h0, status);
    expect_code("zero MAILBOX command", RDMA_SC_INVALID_ARGUMENT, status);
    mailbox_write(0, RDMA_DPU_MAILBOX_STATUS_OFFSET, 64'h1, status);
    expect_code("write read-only MAILBOX status", RDMA_SC_INVALID_ARGUMENT, status);
    mailbox_write(0, 64'h5, 64'h1, status);
    expect_code("misaligned MAILBOX write", RDMA_SC_INVALID_ARGUMENT, status);
    sys.router.write(node.func.pcie_id.domain,
                     node.func.msix.base + RDMA_DPU_MSIX_DATA_CTRL_OFFSET,
                     64'h0000_0002_0000_0000, status);
    expect_code("write MSI-X pending/reserved bit", RDMA_SC_INVALID_ARGUMENT, status);
    sys.router.write(node.func.pcie_id.domain,
                     node.func.msix.base + RDMA_DPU_MSIX_ADDRESS_OFFSET,
                     MESSAGE_ADDRESS_0 + 1, status);
    expect_code("misaligned MSI-X address", RDMA_SC_INVALID_ARGUMENT, status);
    expect_code("raise invalid MSI-X vector", RDMA_SC_INVALID_ARGUMENT,
                sys.router.raise_interrupt(node.func.key, node.interrupt_ctrl.vectors.size(),
                                           node.interrupt_ctrl.reset_epoch, 64'hdead));
  endtask

  // 功能：让 node1 保留 masked MAILBOX pending，并把同 vector 的设备事件合并到首个 cause；只 FLR node0
  //   后确认 node1/node2 的 epoch、寄存器与队列不变，再检查旧 epoch、跨 Host domain 与 PF scope。
  // 输入/输出及副作用：编程 node1、合并一次 pending、两次调用 sys.flr、消费 node1 唯一事件；node2
  //   始终作为范围外哨兵。
  // 失败/边界：合并若覆盖首个 cause 或产生第二个事件、目标外 Function 状态变化、旧 epoch 被接受、
  //   错误 domain 命中或 PF scope 不含 VF 都报错。
  task check_function_and_reset_isolation();
    rdma_dpu_node node0;
    rdma_dpu_node node1;
    rdma_dpu_node node2;
    rdma_dpu_interrupt_event irq;
    rdma_status status;
    rdma_reset_epoch_t epoch0;
    rdma_reset_epoch_t epoch1;
    rdma_reset_epoch_t epoch2;
    dpu_function_key_t unknown_key;
    int unsigned scope[$];
    int unsigned expected_scope[$];
    int unsigned coalesced_before;
    bit [63:0] value;
    bit [63:0] control;
    bit [63:0] command;

    node0 = sys.nodes[0];
    node1 = sys.nodes[1];
    node2 = sys.nodes[2];
    unknown_key = node0.func.key;
    unknown_key.vf_id = 32'hffff;
    expect_code("raise unknown Function", RDMA_SC_INVALID_STATE,
                sys.router.raise_interrupt(unknown_key, 0,
                                           node0.interrupt_ctrl.reset_epoch, 64'hbad0));
    program_vector0(1, MESSAGE_ADDRESS_1, MESSAGE_DATA_1, 1'b1);
    command = 64'h0000_0000_0000_01d4;
    mailbox_write(1, RDMA_DPU_MAILBOX_COMMAND_OFFSET, command, status);
    expect_ok("publish node1 masked command", status);
    coalesced_before = node1.interrupt_ctrl.coalesced_count;
    expect_ok("coalesce node1 device interrupt",
              sys.router.raise_interrupt(node1.func.key, 0,
                                         node1.interrupt_ctrl.reset_epoch, 64'hc0a1_e5ce));
    if (node1.interrupt_ctrl.coalesced_count != coalesced_before + 1 ||
        node1.interrupt_ctrl.vectors[0].pending_cause != command)
      `uvm_error("DPU_IRQ", "masked MSI-X coalescing did not preserve the first cause")
    expect_ok("queue node0 direct interrupt",
              sys.router.raise_interrupt(node0.func.key, 0,
                                         node0.interrupt_ctrl.reset_epoch, 64'hf0));
    if (node0.interrupt_ctrl.delivered_events.size() != 1)
      `uvm_error("DPU_IRQ", "direct device interrupt was not queued on node0")
    epoch0 = node0.interrupt_ctrl.reset_epoch;
    epoch1 = node1.interrupt_ctrl.reset_epoch;
    epoch2 = node2.interrupt_ctrl.reset_epoch;
    scope = '{0};
    sys.flr(scope);
    if (node0.interrupt_ctrl.reset_epoch != epoch0 + 1 ||
        node1.interrupt_ctrl.reset_epoch != epoch1 ||
        node2.interrupt_ctrl.reset_epoch != epoch2)
      `uvm_error("DPU_IRQ", "single-Function FLR changed the wrong reset epoch")
    if (!node0.interrupt_ctrl.vectors[0].masked ||
        node0.interrupt_ctrl.vectors[0].message_address != 0 ||
        node0.interrupt_ctrl.mailbox_published)
      `uvm_error("DPU_IRQ", "FLR did not clear target MAILBOX/MSI-X state")
    mailbox_read(1, RDMA_DPU_MAILBOX_STATUS_OFFSET, value, status);
    expect_ok("read node1 status after node0 FLR", status);
    if (value[1:0] != 2'b11 || value[63:32] != epoch1[31:0])
      `uvm_error("DPU_IRQ", $sformatf("node1 state changed across node0 FLR: %016h", value))
    expect_code("raise with stale node0 epoch", RDMA_SC_STALE_GENERATION,
                sys.router.raise_interrupt(node0.func.key, 0, epoch0, 64'he0));
    sys.router.write(node1.func.pcie_id.domain,
                     node1.func.msix.base + RDMA_DPU_MSIX_DATA_CTRL_OFFSET,
                     {32'h0, MESSAGE_DATA_1}, status);
    expect_ok("unmask isolated node1 interrupt", status);
    expect_ok("pop isolated node1 interrupt",
              sys.router.pop_interrupt(node1.func.key, irq));
    check_event("isolated node1", irq, node1, MESSAGE_ADDRESS_1, MESSAGE_DATA_1,
                command, epoch1);
    expect_code("coalesced node1 queue remains empty", RDMA_SC_QUEUE_EMPTY,
                sys.router.pop_interrupt(node1.func.key, irq));
    expect_code("node0 queue remains empty", RDMA_SC_QUEUE_EMPTY,
                sys.router.pop_interrupt(node0.func.key, irq));
    sys.router.write(node0.func.pcie_id.domain,
                     node2.func.mailbox.base + RDMA_DPU_MAILBOX_PAYLOAD_OFFSET,
                     64'hbad, status);
    expect_code("cross-Host MAILBOX route", RDMA_SC_INVALID_ARGUMENT, status);
    mailbox_read(2, RDMA_DPU_MAILBOX_PAYLOAD_OFFSET, value, status);
    expect_ok("read untouched node2 payload", status);
    if (value != 0 || node2.interrupt_ctrl.reset_epoch != epoch2)
      `uvm_error("DPU_IRQ", "cross-Host write changed node2 control state")
    sys.pf_scope(0, 0, scope);
    expected_scope = '{0, 1};
    if (scope != expected_scope)
      `uvm_error("DPU_IRQ", $sformatf("Host0 PF scope is %p", scope))
    sys.flr(scope);
    if (node0.interrupt_ctrl.reset_epoch != epoch0 + 2 ||
        node1.interrupt_ctrl.reset_epoch != epoch1 + 1 ||
        node2.interrupt_ctrl.reset_epoch != epoch2 ||
        node1.interrupt_ctrl.mailbox_published ||
        node1.interrupt_ctrl.delivered_events.size() != 0)
      `uvm_error("DPU_IRQ", "PF FLR did not isolate and clear PF/VF interrupt state")
  endtask
endclass

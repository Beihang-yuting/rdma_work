// 目录/层次：外部适配器实现层 adapters/pcie_work/rdma_pcie_work_pkg.sv。
// 层：外部适配器。
// 职责：MMIO 与设备 DMA 经 pcie_work 传输：dpu_common 快照（rdma_dpu_system）→ PCIe 拓扑（每个 Host
//   一条 RC↔EP 链）→ pcie_dpu_cfg_adapter 投影 → pcie_tl_env（TLM，统一内存）。
//   MMIO：驱动 BAR 写成为所属 Host 的 RC 上的 MemWr TLP（BAR0 基址 + 偏移，8 字节大端）；EP 收到后
//   连同 ingress Host 排队，由 MMIO 工作进程按到达顺序只在该 Host 的冻结 domain 内经快照解码
//   （rdma_dpu_bar_router）交给所属 Function，其他 domain 的重叠地址、非 BAR0 或 BAR 外写均被拒绝并计数。
//   DMA：设备 DMA 端口（rdma_pcie_dma）在所属 Host 的 EP 上发 MemRd/MemWr（requester ID = Function
//   BDF，按 MRRS/MPS 切分且不跨 4KB），RC 以绑定到该 Root 的 Host host_mem 应答（无 IOMMU，IOVA 即
//   host_mem 地址）；适配层启用 FC、事务记分板和覆盖率，并把 timeout/UR/CA 保存为设备可见诊断。
// 依赖：pcie_work（pcie_tl_pkg、pcie_topology_pkg、pcie_dpu_integration_pkg）、host_mem_pkg、
//   dpu_common、rdma_dpu_adapter_pkg、rdma_dev_pkg。
// 所有权：rdma_pcie_system 持有 pcie_tl_env；rdma_dpu_system 与各 Host 的 host_mem 由测试创建并交给它。
// 生命周期：模型在 build/connect 逐实例绑定 RC/EP/DMA；无静态当前系统，双环境互不覆盖。
//   rdma_pcie_bar 只借用冻结快照、真实 BAR 租约和 sequencer；可选 Intel map 依赖位于 integration/project。
//   外部平台须在自身就绪后绑定 BAR，绑定不发事务；模型 dev/故障注入仅由本包模型系统拥有。
package rdma_pcie_work_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import dpu_resource_pkg::*;
  import host_mem_pkg::*;
  import pcie_tl_pkg::*;
  import pcie_topology_pkg::*;
  import pcie_dpu_integration_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_dpu_adapter_pkg::*;

  typedef class rdma_pcie_system;

  // PCIe 负向验证只在适配层按下一条设备 MemRd 注入一次，避免把测试策略泄漏到设备模型或外部 VIP。
  typedef enum bit [1:0] {
    RDMA_PCIE_FAULT_NONE,
    RDMA_PCIE_FAULT_TIMEOUT,
    RDMA_PCIE_FAULT_UR,
    RDMA_PCIE_FAULT_CA
  } rdma_pcie_fault_e;

  // 仅模型 TLM 保留请求句柄；一次性故障在 EP 分配 tag 时认领，直到所属 RC 收到同一对象后消费。
  typedef struct {
    int unsigned	host_id;
    rdma_pcie_fault_e	fault;
  } rdma_pcie_issued_fault_t;

  // posted MMIO 离开 EP 链路进程后仍须携带 ingress Host authority；裸地址在不同 PCIe domain 中可重叠，
  // 不能靠遍历所有 domain 猜测目标。
  typedef struct {
    int unsigned	host_id;
    pcie_tl_mem_tlp	request;
  } rdma_pcie_mmio_ingress_t;

  // EP 发起的读写序列：在发出前把 requester ID 置为 Function 的 BDF，并保存本次请求对象的
  // 非拥有引用，使 DMA 端口能读取 VIP 回填的 Completion 状态和 tag。
  class rdma_pcie_dma_seq extends pcie_tl_rw_seq;
    `uvm_object_utils(rdma_pcie_dma_seq)

    bit [15:0]		requester_id;
    pcie_tl_mem_tlp	rdma_issued_tlp;

    // 功能：构造尚未指定 requester 的设备 DMA 序列，并清空上一事务句柄。
    // 输入/输出及副作用：name 传给 pcie_tl_rw_seq；requester_id 清零，rdma_issued_tlp 置空。
    // 失败/边界：构造不发 TLP；调用方必须在 start 前填写 requester_id、op、addr 与 byte_len。
    extern function new(string	name = "rdma_pcie_dma_seq");

    // 功能：在 pcie_tl_rw_seq 完成随机化后写入 Function BDF，并保存实际 MemRd/MemWr 请求。
    // 输入/输出及副作用：this_item 为待发 item；成功时覆盖 requester_id，并让 rdma_issued_tlp 借用该句柄。
    // 失败/边界：this_item 不是 pcie_tl_mem_tlp 时保持 rdma_issued_tlp 为空，后续错误映射会保守地省略
    //   Completion 硬件码。
    extern virtual function void mid_do(uvm_sequence_item	this_item);

  endclass

  // RC 驱动：记录 EP 发来的 DMA 请求，按 Host+BDF 消费一次性 Completion fault；正常请求仍由
  // pcie_work 的统一内存 responder 处理。
  class rdma_pcie_rc_driver extends pcie_tl_rc_driver;
    `uvm_component_utils(rdma_pcie_rc_driver)

    // 非拥有的模型环境引用；真实路径不使用此字段定位 transport。
    rdma_pcie_system	system;

    int unsigned	host_id;
    bit			host_id_valid;

    // 功能：构造尚未关联 Root/Host 的 RC 驱动，供 rdma_pcie_system 在 connect_phase 完成绑定。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；host_id 清零且 host_id_valid=0。
    // 失败/边界：绑定前若收到请求，只能走正常 responder，不能消费 Host 定位的 fault。
    extern function new(string	name = "rdma_pcie_rc_driver", uvm_component	parent = null);

    // 功能：接收 EP→RC 的设备 DMA 请求；先登记事务，再对命中的下一条 MemRd 注入 timeout、UR 或 CA，
    //   未命中时交给基类读写所属 Host 的 host_mem。
    // 输入/输出及副作用：req 为已分配 tag 的请求；更新系统事务计数，UR/CA 会发送一个无数据错误
    //   Completion，timeout 会有意不响应。
    // 失败/边界：系统或 Host 绑定缺失时不注入；fault 只消费一次，MemWr 与非内存请求不消费规则。
    extern virtual task handle_request(pcie_tl_tlp	req);

    // 功能：为设备 MemRd 构造终止型无数据 Completion，并让 VIP 记分板按注入状态校验该事务。
    // 输入/输出及副作用：req 提供 requester_id/tag/属性，cpl_status 仅允许 UR 或 CA；发送一个 TLP，
    //   req.expected_cpl_status 已由 EP tag hook 提前发布，不再修改 scoreboard 期望。
    // 失败/边界：调用方须保证 req 是需要 Completion 的请求；SC、CRS 或未知状态不属于本注入入口。
    extern protected task send_error_completion(pcie_tl_tlp	req, cpl_status_e	cpl_status);

  endclass

  // 设备 DMA 端口：在所属 Host 的 EP 上发 MemRd/MemWr。
  class rdma_pcie_dma extends rdma_dev_dma;
    `uvm_object_utils(rdma_pcie_dma)

    // 非拥有的模型环境引用；真实路径不使用此字段定位 transport。
    rdma_pcie_system	system;

    // pcie_tl_mem_tlp 的 LEGAL 约束：MemWr 负载 ≤ MPS，MemRd ≤ MRRS，且都不跨 4KB。
    localparam int unsigned	MPS_BYTES = 256;
    localparam int unsigned	MRRS_BYTES = 512;

    rdma_dpu_function	func;

    // 功能：构造未绑定 Function 的 PCIe DMA 端口，后续所有请求据此选择 Host 链路与 requester BDF。
    // 输入/输出及副作用：name 传给 rdma_dev_dma；func 初始化为空，不取得 dpu Function 所有权。
    // 失败/边界：rdma_pcie_system.build_phase 完成绑定前，read/write 返回 INVALID_STATE。
    extern function new(string	name = "rdma_pcie_dma");

    // 功能：按 IOVA 读 size 字节，按 MRRS/4KB 兼容边界切分 MemRd，并按地址顺序拼接全部 CplD 数据。
    // 输入/输出及副作用：bytes 输出完整数据；每个 chunk 从所属 Host 的 EP 发出并更新 DMA 事务计数。
    // 失败/边界：未绑定返回 INVALID_STATE；首个 timeout 返回 RDMA_SC_TIMEOUT；UR/CA 返回带原始
    //   Completion code 的 RDMA_SC_PCIE_COMPLETION；失败时 bytes 清空且不继续后续 chunk。
    extern virtual task read(bit [63:0]	iova, int unsigned	size, output byte unsigned	bytes[],
                      output rdma_status	status);

    // 功能：按 IOVA 写 bytes，按 MPS/4KB 兼容边界切成 posted MemWr 并保持原字节顺序。
    // 输入/输出及副作用：bytes 为只读输入；每个 chunk 从所属 Host 的 EP 发出并更新写事务计数。
    // 失败/边界：未绑定返回 INVALID_STATE；posted 写没有 Completion，链路送达后的设备/内存错误不由
    //   此同步接口确认；零长度输入直接成功且不发 TLP。
    extern virtual task write(bit [63:0]	iova, byte unsigned	bytes[], output rdma_status	status);

    // 功能：验证端口同时具备 Function 快照与当前 PCIe 系统，作为所有前门 DMA 的准入门禁。
    // 输入/输出及副作用：成功返回 1 并输出 OK；失败返回 0 并输出 INVALID_STATE，不发事务。
    // 失败/边界：func 或 system 任一为空均拒绝；不验证 Host 是否已投影，后者由
    //   ep_seqr 的 fatal 守卫负责。
    extern protected function bit bound(output rdma_status	status);

    // 功能：计算从 addr 到下一个 limit 边界或 last（取较近者）的 chunk 字节数。
    // 输入/输出及副作用：只读 addr/last/limit并返回正整数，不修改端口状态。
    // 失败/边界：调用方保证 limit 非零且 addr<last；违反前提可能除零或返回零，本函数不替调用方修正。
    extern protected function int unsigned chunk(bit [63:0]	addr, bit [63:0]	last, int unsigned	limit);

    // 功能：创建指定读写方向、地址与长度的序列，并注入 Function BDF 与系统 DMA Completion 超时预算。
    // 输入/输出及副作用：op/addr/len 写入新对象，返回由调用方启动的独立序列。
    // 失败/边界：要求 func 与 system 已由 bound 验证；len 必须处于 pcie_tl_rw_seq 的 1..4096 契约内。
    extern protected function rdma_pcie_dma_seq new_seq(pcie_rw_op_e	op, bit [63:0]	addr,
                                                 int unsigned	len);

    // 功能：把 pcie_tl_rw_seq 的 timeout 或非成功 Completion 转成设备可见的结构化 RDMA 诊断。
    // 输入/输出及副作用：seq/addr/len 为失败事务证据；返回新 status，记录到 rdma_pcie_system，timeout
    //   会退休 read-back/scoreboard 状态并隔离 EP tag，避免迟到 Completion 命中新事务。
    // 失败/边界：rdma_issued_tlp 缺失或状态不是已知 UR/CA 时仍返回 PCIE_COMPLETION，但 hardware_code_valid=0；
    //   timeout 没有 Completion 硬件码并标记 retryable。
    extern protected function rdma_status read_error(rdma_pcie_dma_seq	seq, bit [63:0]	addr,
                                              int unsigned	len);

  endclass

  // EP 驱动：MemWr 排入 rdma_pcie_system 的 MMIO 队列；其余请求按 pcie_tl_ep_driver 处理。
  class rdma_pcie_ep_driver extends pcie_tl_ep_driver;
    `uvm_component_utils(rdma_pcie_ep_driver)

    // 非拥有的模型环境引用；真实路径不使用此字段定位 transport。
    rdma_pcie_system	system;

    int unsigned	host_id;
    bit			host_id_valid;
    // 保留发出时的 tag 代次；终止 Completion 或 timeout 退休时清除，不允许旧代次误退休。
    protected longint unsigned	read_generations[pcie_tl_tlp];
    // Completion timeout 后 tag 不能立即复用：外部 VIP 的 read-back 表只按 tag 定位，没有 wire
    // generation；迟到 Completion 若撞上同 requester 的新事务，会被误折叠到新请求。故 timeout tag
    // 在本仿真生命周期内隔离，直到未来显式 reset/recovery 契约能够安全归还。
    bit			timeout_quarantine[bit [25:0]];
    int unsigned	late_timeout_completions;

    // 功能：构造 RDMA 专用 EP 驱动；除 MMIO 分派与 DMA Completion tag 回收外沿用 pcie_work 行为。
    // 输入/输出及副作用：name/parent 建立 UVM 组件层级，不取得外部内存或 Function 所有权。
    // 失败/边界：共享 tag manager 与 adapter 由 pcie_tl_env 在 connect_phase 注入，此前不能收发事务。
    extern function new(string	name = "rdma_pcie_ep_driver", uvm_component	parent = null);

    // 功能：在 tag 已确定而 scoreboard 尚未克隆请求时认领一次性模型 fault 并记录读的分配代次。
    // 输入/输出及副作用：tlp 为本 EP 实际请求；保存 read_generations，UR/CA 期望写到原请求后才发布 TX。
    // 失败/边界：仅绑定模型 TLM、无 poison/header 改写支持句柄关联；不支持的 armed fault 明确拒绝并清理。
    extern virtual function void on_tag_assigned(pcie_tl_tlp	tlp);

    // 功能：接收 RC→EP 请求；MemWr 排入系统 MMIO 队列，使当前链路进程可继续递送设备 DMA 的 CplD，
    //   其余 MemRd/Cfg 请求交给基类 responder。
    // 输入/输出及副作用：命中 MemWr 时把 host_id 与 req 非拥有句柄一同入队并立即返回；其他请求可能
    //   由基类发送 Completion。
    // 失败/边界：系统未建立、kind 不是 MemWr 或动态类型不是 pcie_tl_mem_tlp 时退回基类；系统已建立
    //   但 EP 尚未绑定 Host 时报告错误并拒绝写，绝不猜测其他 domain。
    extern virtual task handle_request(pcie_tl_tlp	req);

    // 功能：折叠一段设备 DMA Completion；统一内存路径的终止段由本适配层归还 tag，legacy 路径保留
    //   rc_auto_respond 的既有归还所有权，并绕开外部基类缺少 Root 维度的全局 registry 删除。
    // 输入/输出及副作用：cpl 的数据/状态由共同 rb_note API 写回原请求；统一内存末段或错误段使
    //   tag_mgr outstanding 数减一；隔离 tag 的迟到 Completion 只计数而不接触新请求。
    // 失败/边界：requester/tag 不属于当前 read-back 与 tag-manager 同一请求时拒绝折叠；多段成功
    //   Completion 只在累计字节达到请求长度后释放，legacy 模式绝不在此重复释放。
    extern virtual function void handle_completion(pcie_tl_cpl_tlp	cpl);

    // 功能：在统一内存设备 DMA Completion timeout 后撤销 EP read-back 状态，并隔离该 tag 防止迟到
    //   Completion 与后续请求发生 ABA 混淆。
    // 输入/输出及副作用：request 为超时请求的非拥有句柄；成功用不发送的 error fence 清除 EP 私有
    //   read-back 表，只在全局 registry 仍属同句柄时清共有字段，并从 outstanding 移除但不归还 tag。
    // 失败/边界：legacy 模式由 rc_auto_respond 持有 tag 归还权；request 为空、read-back/tag-manager
    //   所有者或捕获的 tag 代次不一致时返回 0 且不修改任何表，避免误退休已完成或已复用事务。
    extern function bit retire_timeout(pcie_tl_tlp	request);

    // 功能：只在无 Root 维度的全局 read-back registry 仍由 request 占有时，跨 4b/9aed 完整退休该键。
    // 输入/输出及副作用：request 为非拥有句柄；exact owner 命中后借共同 register API 清版本专属计数，
    //   再删除两版共有的 reqs/recv/total，最终该键不可被 Completion 命中。
    // 失败/边界：空请求、键不存在或已被另一 Root 的同 BDF/tag 请求覆盖时严格不修改全局表。
    extern protected function void retire_registry_if_owned(pcie_tl_tlp	request);

  endclass

  // 驱动 BAR：写成为所属 Host 的 RC 上的 MemWr TLP（8 字节大端），记录同基类。
  class rdma_pcie_bar extends rdma_dpu_bar;
    `uvm_object_utils(rdma_pcie_bar)

    // 非拥有的模型环境引用；真实路径不使用此字段定位 transport。
    rdma_pcie_system	system;

    protected dpu_device_snapshot		bar_snapshot;
    protected dpu_function_key_t		bar_key;
    protected dpu_bar_pair_lease_t		bar_lease;
    protected uvm_sequencer #(pcie_tl_tlp)	bar_sequencer;

    // 功能：构造未绑定的 PCIe BAR，保留基类寄存器写审计。
    // 输入/输出及副作用：name 传给基类；快照和 sequencer 引用初始为空，均不取得所有权。
    // 失败/边界：bind_instance 成功前 write64 返回 INVALID_STATE。
    extern function new(string	name = "rdma_pcie_bar");

    // 功能：把已有 BAR 前门绑定到同一冻结 Function 的真实租约和 RC sequencer。
    // 输入/输出及副作用：snapshot/key/lease/sequencer 为借用或值输入；成功一次性保存绑定。
    // 失败/边界：空或未冻结快照、空 sequencer、租约不匹配或重复绑定均拒绝，原绑定保持不变。
    extern function rdma_status bind_instance(dpu_device_snapshot	snapshot,
        dpu_function_key_t	key, dpu_bar_pair_lease_t	lease,
        uvm_sequencer #(pcie_tl_tlp)	sequencer);

    // 功能：将完整落在绑定 BAR 内的 64 位大端写通过现有 PCIe sequence 发送。
    // 输入/输出及副作用：offset/value 记录到审计队列；发送八字节，模型绑定额外累计 sent_writes。
    // 失败/边界：未绑定、跨 BAR 或地址溢出在 sequence 前失败；posted 成功仅表示传输提交，不确认 DUT 执行。
    extern virtual task write64(bit [63:0]	offset, bit [63:0]	value, output rdma_status	status);

  endclass

  // dpu_common 快照 → pcie_work 环境，及 EP 侧 MMIO 分派。
  class rdma_pcie_system extends uvm_component;
    `uvm_component_utils(rdma_pcie_system)

    rdma_dpu_system	dpu;
    pcie_tl_env		tl_env;
    pcie_global_cfg	global_cfg;
    pcie_tl_env_config	tl_cfg;
    int unsigned	host_root[int unsigned];
    dpu_pcie_domain_key_t	host_domain[int unsigned];
    int unsigned	sent_writes;
    int unsigned	decoded_writes;
    int unsigned	rejected_writes;
    int unsigned	failed_writes;
    rdma_status		last_mmio_error;
    // 观测：EP 发出的 DMA TLP 数；RC 收到的 DMA 请求数、成功读数、错误数与 requester 分布。
    int unsigned			dma_read_tlps;
    int unsigned			dma_read_successes;
    int unsigned			dma_read_failures;
    int unsigned			dma_write_tlps;
    int unsigned			host_reads;
    int unsigned			host_writes;
    int unsigned			host_requesters[bit [47:0]];
    int unsigned			completion_timeouts;
    int unsigned			completion_ur;
    int unsigned			completion_ca;
    int unsigned			dma_completion_timeout_ns;
    rdma_status				last_dma_errors[string];
    protected rdma_pcie_issued_fault_t	issued_read_faults[pcie_tl_tlp];
    protected rdma_pcie_fault_e		read_faults[string];
    protected mailbox #(rdma_pcie_mmio_ingress_t) mmio_q;

    // 功能：构造空 PCIe 系统并初始化 MMIO/DMA/Completion 观测，默认设备读超时为 50us。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；创建私有 MMIO mailbox，所有计数和错误引用清零。
    // 失败/边界：尚未绑定 dpu 或创建 tl_env；build_phase 前不得索取 sequencer 或发 DMA。
    extern function new(string	name = "rdma_pcie_system", uvm_component	parent = null);

    // 功能：全局注册 RDMA 的 RC/EP 驱动、BAR 与设备 DMA factory 覆盖，使随后创建的系统统一走 PCIe。
    // 输入/输出及副作用：修改 UVM factory type override；不创建对象，重复调用保持相同映射。
    // 失败/边界：必须早于 rdma_dpu_system.build 与本组件 build；过晚调用不会替换已创建的对象。
    extern static function void install_overrides();

    // 功能：按冻结 dpu 快照建立每 Host 一条 x16 RC↔EP 链，投影 Function attachment/Root binding，
    //   创建启用 FC、事务记分板和功能覆盖的 TLM PCIe 环境，并把设备 DMA 端口绑定到 Function。
    // 输入/输出及副作用：消费 dpu 及其 mem_pool 非拥有引用，创建 global_cfg、tl_cfg、tl_env；每个 DMA port.system 借用
    //   本组件，每个 Root 绑定所属 Host 的统一 host_mem。
    // 失败/边界：dpu 未 build、Host 缺 host_mem、DMA 端口不是 rdma_pcie_dma 或投影/绑定失败报告
    //   UVM_FATAL；不修改 dpu_common 快照或外部内存生命周期。
    extern function void build_phase(uvm_phase	phase);

    // 功能：把每个 Root 的 RC/EP 驱动绑定到同一 dpu_common Host，分别约束 fault 与 MMIO ingress authority。
    // 输入/输出及副作用：phase 为 UVM connect phase；按 host_root 写两个派生驱动的 system/host_id/valid，并为每个 BAR 绑定快照/租约/sequencer。
    // 失败/边界：Root 下标缺失或 factory 未产生任一 RDMA 派生驱动时报告 UVM_FATAL，避免 fault/MMIO
    //   串到其他 Host。
    extern function void connect_phase(uvm_phase	phase);

    // 功能：按到达顺序持续取出 RC→EP 的 posted MemWr，并在独立进程内同步执行设备寄存器写。
    // 输入/输出及副作用：phase 只提供生命周期上下文；永久消费 mmio_q，更新解码/拒绝/设备失败观测。
    // 失败/边界：任务由 UVM phase 终止；空队列阻塞，不主动超时或取消已入队写。
    extern task run_phase(uvm_phase	phase);

    // 功能：查询 host_id 对应 Root 的 RC sequencer，供驱动 BAR 发起 Host→设备 MemWr。
    // 输入/输出及副作用：只读 host_root/tl_env 并返回非拥有 sequencer 引用。
    // 失败/边界：未知 Host 报 UVM_FATAL；要求 build/connect 已完成且 v_seqr 数组与投影一致。
    extern function uvm_sequencer #(pcie_tl_tlp) rc_seqr(int unsigned	host_id);

    // 功能：查询 host_id 所属链路的 EP sequencer，供该 Host 内 Function 发起设备 DMA。
    // 输入/输出及副作用：只读 host_root/tl_env 并返回非拥有 sequencer 引用。
    // 失败/边界：未知 Host 报 UVM_FATAL；要求 build/connect 已完成且 v_seqr 数组与投影一致。
    extern function uvm_sequencer #(pcie_tl_tlp) ep_seqr(int unsigned	host_id);

    // 功能：把 EP 收到的 posted MemWr 连同 ingress Host authority 交给 MMIO 工作进程并保持到达顺序。
    // 输入/输出及副作用：host_id/req 组成值+非拥有句柄记录后 try_put 到无界 mmio_q。
    // 失败/边界：未知 Host 或空 req 报 UVM_ERROR 且不入队；若未来 mailbox 改为有界，拒绝时报 UVM_FATAL。
    extern function void deliver_mmio(int unsigned	host_id, pcie_tl_mem_tlp	req);

    // 功能：记录指定 ingress Host 的 RC 实际收到的设备 MemRd/MemWr，并按 Host+BDF 累计事务分布。
    // 输入/输出及副作用：host_id/req 只读；更新 host_reads/host_writes 与 host_requesters。
    // 失败/边界：非 MemRd/MemWr 忽略；Host+BDF authority 由插件 report 与冻结快照逐项核对。
    extern function void note_host_request(int unsigned	host_id, pcie_tl_tlp	req);

    // 功能：为指定 Function 的下一条设备 MemRd 安排一次 timeout、UR 或 CA，键同时包含 Host 与 BDF。
    // 输入/输出及副作用：func/fault 为输入；成功写 read_faults 并返回 OK，不发送事务。
    // 失败/边界：func 为空、NONE 或已有未消费规则分别返回 INVALID_ARGUMENT/RESOURCE_BUSY；规则不会影响
    //   其他 Function、MemWr 或第二条 MemRd。
    extern function rdma_status arm_read_fault(rdma_dpu_function	func, rdma_pcie_fault_e	fault);

    // 功能：EP tag 分配后原子认领下一条 MemRd fault，在 scoreboard 克隆前设置 UR/CA 期望。
    // 输入/输出及副作用：host_id/req/adapter 定位模型发送端；删除 armed 规则并保存同句柄 issued 规则。
    // 失败/边界：非读或无规则不变；非 TLM、poison/header 改写、重复句柄拒绝并清规则，不跨 wire 猜测对象身份。
    extern function void prepare_read_fault(int unsigned	host_id, pcie_tl_tlp	req,
      pcie_tl_if_adapter	adapter);

    // 功能：终止 Completion、timeout 或拒绝时释放请求尚未消费的 issued fault 引用。
    // 输入/输出及副作用：req 定位精确请求句柄，删除该条目；不重新 arm、不改其他 Function 的规则。
    // 失败/边界：null 或已被 RC 消费的请求为空操作，可重复清理。
    extern function void discard_read_fault(pcie_tl_tlp	req);

    // 功能：所属 Host 的 RC 收到模型 TLM 请求后取走已由 EP 认领的 fault。
    // 输入/输出及副作用：host_id/req 输入；fault 输出，匹配时删除精确请求的 issued 规则。
    // 失败/边界：非读、null 或无 issued 规则返回 NONE；Host 不匹配清该条目并报错，不把规则移给后续读。
    extern function bit consume_read_fault(int unsigned	host_id, pcie_tl_tlp	req,
                                    output rdma_pcie_fault_e	fault);

    // 功能：记录一次设备 MemRd 的结构化失败，保留 Function 最近错误并按 timeout/UR/CA 分类计数。
    // 输入/输出及副作用：func/status 为已完成失败证据；借用 status 句柄写 last_dma_errors，递增
    //   dma_read_failures 及对应错误类别计数。
    // 失败/边界：func/status 为空时只递增总失败数；未知 hardware_code 不计入 UR/CA，诊断仍可查询。
    extern function void record_dma_error(rdma_dpu_function	func, rdma_status	status);

    // 功能：返回指定 Function 最近一次 DMA 失败，供设备/测试侧读取原始 PCIe 诊断。
    // 输入/输出及副作用：func 为查询键；返回系统持有的非拥有 status 引用，不复制或清除记录。
    // 失败/边界：func 为空或从未失败返回 null；调用方不得修改返回对象后再把它视作历史快照。
    extern function rdma_status last_dma_error(rdma_dpu_function	func);

    // 功能：按 Root+requester/tag 核对超时读的 scoreboard 克隆指纹，再隔离 EP tag 并结算。
    // 输入/输出及副作用：func/request 定位链路；仅 EP exact owner/代次有效且克隆/分片身份一致时删除记录并累计 timed_out。
    // 失败/边界：缺句柄/Host/agent 返回；克隆指纹或 tracker 不匹配报错且不退休；无等待地核对并删除，不能删除另一请求。
    extern function void retire_timed_out_read(rdma_dpu_function	func, pcie_tl_tlp	request);

    // 功能：生成 fault 表的稳定复合键，使相同 BDF 在不同 Host/segment 上互不串扰。
    // 输入/输出及副作用：host_id/bdf 为值输入，返回格式化 string，无状态修改。
    // 失败/边界：所有整数与 16 位 BDF 均可编码；键只在本组件生命周期内使用，不作为持久 ABI。
    extern protected function string fault_key(int unsigned	host_id, bit [15:0]	bdf);

    // 功能：把一个 8 字节大端 MemWr 只在 ingress Host 的冻结 PCIe domain 内解码，并同步调用所属设备。
    // 输入/输出及副作用：host_id 是 EP 链路携带的 authority，req 只读；成功递增 decoded_writes，
    //   Host/BAR/长度拒绝递增 rejected_writes，设备内部 DMA/协议失败递增 failed_writes 并保存错误。
    // 失败/边界：payload 少于 8 字节、Host 未绑定或地址不属于该 Host domain 均拒绝；绝不尝试其他
    //   domain，因此不同 Host 的重叠 BAR 地址也不会越权路由。
    extern protected task dispatch_mmio(int unsigned	host_id, pcie_tl_mem_tlp	req);

  endclass

  // 功能：构造尚未指定 requester 的设备 DMA 序列，并清空上一事务句柄。
  // 输入/输出及副作用：name 传给 pcie_tl_rw_seq；requester_id 清零，rdma_issued_tlp 置空。
  // 失败/边界：构造不发 TLP；调用方必须在 start 前填写 requester_id、op、addr 与 byte_len。
  function rdma_pcie_dma_seq::new(string	name = "rdma_pcie_dma_seq");
    super.new(name);
    requester_id = '0;
    rdma_issued_tlp = null;
  endfunction

  // 功能：在 pcie_tl_rw_seq 完成随机化后写入 Function BDF，并保存实际 MemRd/MemWr 请求。
  // 输入/输出及副作用：this_item 为待发 item；成功时覆盖 requester_id，并让 rdma_issued_tlp 借用该句柄。
  // 失败/边界：this_item 不是 pcie_tl_mem_tlp 时保持 rdma_issued_tlp 为空，后续错误映射会保守地省略
  //   Completion 硬件码。
  function void rdma_pcie_dma_seq::mid_do(uvm_sequence_item	this_item);
    pcie_tl_mem_tlp	tlp;

    if ($cast(tlp, this_item)) begin
      tlp.requester_id = requester_id;
      rdma_issued_tlp = tlp;
    end
  endfunction

  // 功能：构造尚未关联 Root/Host 的 RC 驱动，供 rdma_pcie_system 在 connect_phase 完成绑定。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；host_id 清零且 host_id_valid=0。
  // 失败/边界：绑定前若收到请求，只能走正常 responder，不能消费 Host 定位的 fault。
  function rdma_pcie_rc_driver::new(string	name = "rdma_pcie_rc_driver", uvm_component	parent = null);
    super.new(name, parent);
    host_id = 0;
    host_id_valid = 1'b0;
  endfunction

  // 功能：接收 EP→RC 的设备 DMA 请求；先登记事务，再对命中的下一条 MemRd 注入 timeout、UR 或 CA，
  //   未命中时交给基类读写所属 Host 的 host_mem。
  // 输入/输出及副作用：req 为已分配 tag 的请求；更新系统事务计数，UR/CA 会发送一个无数据错误
  //   Completion，timeout 会有意不响应。
  // 失败/边界：系统或 Host 绑定缺失时不注入；fault 只消费一次，MemWr 与非内存请求不消费规则。
  task rdma_pcie_rc_driver::handle_request(pcie_tl_tlp	req);
    rdma_pcie_fault_e	fault;

    if (system != null) begin
      if (host_id_valid)
        system.note_host_request(host_id, req);
      if (host_id_valid &&
          system.consume_read_fault(host_id, req, fault)) begin
        if (fault == RDMA_PCIE_FAULT_TIMEOUT)
          return;
        send_error_completion(req, fault == RDMA_PCIE_FAULT_UR ? CPL_STATUS_UR :
                                                                   CPL_STATUS_CA);
        return;
      end
    end
    super.handle_request(req);
  endtask

  // 功能：为设备 MemRd 构造终止型无数据 Completion，并让 VIP 记分板按注入状态校验该事务。
  // 输入/输出及副作用：req 提供 requester_id/tag/属性，cpl_status 仅允许 UR 或 CA；发送一个 TLP，
  //   req.expected_cpl_status 已由 EP tag hook 提前发布，不再修改 scoreboard 期望。
  // 失败/边界：调用方须保证 req 是需要 Completion 的请求；SC、CRS 或未知状态不属于本注入入口。
  task rdma_pcie_rc_driver::send_error_completion(pcie_tl_tlp	req, cpl_status_e	cpl_status);
    pcie_tl_cpl_tlp	cpl;

    cpl = pcie_tl_cpl_tlp::type_id::create("rdma_dma_error_cpl");
    cpl.kind = TLP_CPL;
    cpl.fmt = FMT_3DW_NO_DATA;
    cpl.type_f = TLP_TYPE_CPL;
    cpl.tc = req.tc;
    cpl.td = 1'b0;
    cpl.ep_bit = 1'b0;
    cpl.attr = req.attr;
    cpl.length = '0;
    cpl.requester_id = req.requester_id;
    cpl.tag = req.tag;
    cpl.completer_id = 16'h0000;
    cpl.cpl_status = cpl_status;
    cpl.bcm = 1'b0;
    cpl.byte_count = '0;
    cpl.lower_addr = '0;
    cpl.payload = new[0];
    send_tlp(cpl);
  endtask

  // 功能：构造未绑定 Function 的 PCIe DMA 端口，后续所有请求据此选择 Host 链路与 requester BDF。
  // 输入/输出及副作用：name 传给 rdma_dev_dma；func 初始化为空，不取得 dpu Function 所有权。
  // 失败/边界：rdma_pcie_system.build_phase 完成绑定前，read/write 返回 INVALID_STATE。
  function rdma_pcie_dma::new(string	name = "rdma_pcie_dma");
    super.new(name);
    func = null;
  endfunction

  // 功能：按 IOVA 读 size 字节，按 MRRS/4KB 兼容边界切分 MemRd，并按地址顺序拼接全部 CplD 数据。
  // 输入/输出及副作用：bytes 输出完整数据；每个 chunk 从所属 Host 的 EP 发出并更新 DMA 事务计数。
  // 失败/边界：未绑定返回 INVALID_STATE；首个 timeout 返回 RDMA_SC_TIMEOUT；UR/CA 返回带原始
  //   Completion code 的 RDMA_SC_PCIE_COMPLETION；失败时 bytes 清空且不继续后续 chunk。
  task rdma_pcie_dma::read(bit [63:0]	iova, int unsigned	size, output byte unsigned	bytes[],
                    output rdma_status	status);
    rdma_pcie_dma_seq	seq;
    bit [63:0]		addr;
    int unsigned	take;

    bytes = new[0];
    if (!bound(status))
      return;
    addr = iova;
    while (addr < iova + size) begin
      take = chunk(addr, iova + size, MRRS_BYTES);
      seq = new_seq(PCIE_RW_READ, addr, take);
      system.dma_read_tlps++;
      seq.start(system.ep_seqr(func.key.host_id));
      if (seq.status != PCIE_RW_OK) begin
        bytes = new[0];
        status = read_error(seq, addr, take);
        return;
      end
      bytes = new[bytes.size() + take](bytes);
      foreach (seq.rdata[i])
        bytes[addr - iova + i] = seq.rdata[i];
      system.dma_read_successes++;
      addr += take;
    end
    status = rdma_status::success();
  endtask

  // 功能：按 IOVA 写 bytes，按 MPS/4KB 兼容边界切成 posted MemWr 并保持原字节顺序。
  // 输入/输出及副作用：bytes 为只读输入；每个 chunk 从所属 Host 的 EP 发出并更新写事务计数。
  // 失败/边界：未绑定返回 INVALID_STATE；posted 写没有 Completion，链路送达后的设备/内存错误不由
  //   此同步接口确认；零长度输入直接成功且不发 TLP。
  task rdma_pcie_dma::write(bit [63:0]	iova, byte unsigned	bytes[], output rdma_status	status);
    rdma_pcie_dma_seq	seq;
    bit [63:0]		addr;
    int unsigned	take;

    if (!bound(status))
      return;
    addr = iova;
    while (addr < iova + bytes.size()) begin
      take = chunk(addr, iova + bytes.size(), MPS_BYTES);
      seq = new_seq(PCIE_RW_WRITE, addr, take);
      seq.wdata = new[take];
      foreach (seq.wdata[i])
        seq.wdata[i] = bytes[addr - iova + i];
      seq.start(system.ep_seqr(func.key.host_id));
      system.dma_write_tlps++;
      addr += take;
    end
    status = rdma_status::success();
  endtask

  // 功能：验证端口同时具备 Function 快照与当前 PCIe 系统，作为所有前门 DMA 的准入门禁。
  // 输入/输出及副作用：成功返回 1 并输出 OK；失败返回 0 并输出 INVALID_STATE，不发事务。
  // 失败/边界：func 或 system 任一为空均拒绝；不验证 Host 是否已投影，后者由
  //   ep_seqr 的 fatal 守卫负责。
  function bit rdma_pcie_dma::bound(output rdma_status	status);
    status = rdma_status::success();
    if (func != null && system != null)
      return 1'b1;
    status = rdma_status::make(RDMA_SC_INVALID_STATE, "PCIe DMA port is not bound");
    return 1'b0;
  endfunction

  // 功能：计算从 addr 到下一个 limit 边界或 last（取较近者）的 chunk 字节数。
  // 输入/输出及副作用：只读 addr/last/limit并返回正整数，不修改端口状态。
  // 失败/边界：调用方保证 limit 非零且 addr<last；违反前提可能除零或返回零，本函数不替调用方修正。
  function int unsigned rdma_pcie_dma::chunk(bit [63:0]	addr, bit [63:0]	last, int unsigned	limit);
    bit [63:0]	boundary;

    boundary = (addr / limit + 1) * limit;
    return (boundary < last ? boundary : last) - addr;
  endfunction

  // 功能：创建指定读写方向、地址与长度的序列，并注入 Function BDF 与系统 DMA Completion 超时预算。
  // 输入/输出及副作用：op/addr/len 写入新对象，返回由调用方启动的独立序列。
  // 失败/边界：要求 func 与 system 已由 bound 验证；len 必须处于 pcie_tl_rw_seq 的 1..4096 契约内。
  function rdma_pcie_dma_seq rdma_pcie_dma::new_seq(pcie_rw_op_e	op, bit [63:0]	addr,
                                               int unsigned	len);
    rdma_pcie_dma_seq	seq;

    seq = rdma_pcie_dma_seq::type_id::create("rdma_dma");
    seq.op = op;
    seq.addr = addr;
    seq.byte_len = len;
    seq.requester_id = func.pcie_id.bdf;
    seq.rb_timeout_ns = system.dma_completion_timeout_ns;
    return seq;
  endfunction

  // 功能：把 pcie_tl_rw_seq 的 timeout 或非成功 Completion 转成设备可见的结构化 RDMA 诊断。
  // 输入/输出及副作用：seq/addr/len 为失败事务证据；返回新 status，记录到 rdma_pcie_system，timeout
  //   会退休 read-back/scoreboard 状态并隔离 EP tag，避免迟到 Completion 命中新事务。
  // 失败/边界：rdma_issued_tlp 缺失或状态不是已知 UR/CA 时仍返回 PCIE_COMPLETION，但 hardware_code_valid=0；
  //   timeout 没有 Completion 硬件码并标记 retryable。
  function rdma_status rdma_pcie_dma::read_error(rdma_pcie_dma_seq	seq, bit [63:0]	addr,
                                            int unsigned	len);
    rdma_status		status;
    cpl_status_e	cpl_status;

    if (seq.status == PCIE_RW_TIMEOUT) begin
      status = rdma_status::make(
        RDMA_SC_TIMEOUT,
        $sformatf("PCIe MemRd %016h+%0d completion timed out", addr, len));
      status.retryable = 1'b1;
      system.retire_timed_out_read(func, seq.rdma_issued_tlp);
    end
    else begin
      status = rdma_status::make(
        RDMA_SC_PCIE_COMPLETION,
        $sformatf("PCIe MemRd %016h+%0d completed with %s", addr, len,
                  seq.rdma_issued_tlp == null ? "UNKNOWN" :
                    seq.rdma_issued_tlp.rb_status.name()));
      if (seq.rdma_issued_tlp != null) begin
        cpl_status = seq.rdma_issued_tlp.rb_status;
        status.hardware_code = cpl_status;
        status.hardware_code_valid = cpl_status inside {CPL_STATUS_UR, CPL_STATUS_CA};
      end
    end
    status.source_engine = RDMA_ENGINE_PCIE;
    status.function_uid = func.global_id;
    system.record_dma_error(func, status);
    return status;
  endfunction

  // 功能：构造 RDMA 专用 EP 驱动；除 MMIO 分派与 DMA Completion tag 回收外沿用 pcie_work 行为。
  // 输入/输出及副作用：name/parent 建立 UVM 组件层级，不取得外部内存或 Function 所有权。
  // 失败/边界：共享 tag manager 与 adapter 由 pcie_tl_env 在 connect_phase 注入，此前不能收发事务。
  function rdma_pcie_ep_driver::new(string	name = "rdma_pcie_ep_driver", uvm_component	parent = null);
    super.new(name, parent);
    host_id = 0;
    host_id_valid = 1'b0;
    late_timeout_completions = 0;
  endfunction

  // 功能：在 tag 已确定而 scoreboard 尚未克隆请求时认领一次性模型 fault 并记录读的分配代次。
  // 输入/输出及副作用：tlp 为本 EP 实际请求；保存 read_generations，UR/CA 期望写到原请求后才发布 TX。
  // 失败/边界：仅绑定模型 TLM、无 poison/header 改写支持句柄关联；不支持的 armed fault 明确拒绝并清理。
  function void rdma_pcie_ep_driver::on_tag_assigned(pcie_tl_tlp	tlp);
    super.on_tag_assigned(tlp);
    if (tlp == null || tlp.kind != TLP_MEM_RD || tag_mgr == null)
      return;
    read_generations[tlp] = tag_mgr.get_outstanding_generation(tlp.tag);
    if (system != null && host_id_valid)
      system.prepare_read_fault(host_id, tlp, adapter);
  endfunction

  // 功能：接收 RC→EP 请求；MemWr 排入系统 MMIO 队列，使当前链路进程可继续递送设备 DMA 的 CplD，
  //   其余 MemRd/Cfg 请求交给基类 responder。
  // 输入/输出及副作用：命中 MemWr 时把 host_id 与 req 非拥有句柄一同入队并立即返回；其他请求可能
  //   由基类发送 Completion。
  // 失败/边界：系统未建立、kind 不是 MemWr 或动态类型不是 pcie_tl_mem_tlp 时退回基类；系统已建立
  //   但 EP 尚未绑定 Host 时报告错误并拒绝写，绝不猜测其他 domain。
  task rdma_pcie_ep_driver::handle_request(pcie_tl_tlp	req);
    pcie_tl_mem_tlp	mem_req;

    if (req.kind == TLP_MEM_WR && system != null && $cast(mem_req, req)) begin
      if (!host_id_valid) begin
        `uvm_error("RDMA_PCIE_MMIO", "EP received MMIO before Host authority was bound")
        return;
      end
      system.deliver_mmio(host_id, mem_req);
      return;
    end
    super.handle_request(req);
  endtask

  // 功能：折叠一段设备 DMA Completion；统一内存路径的终止段由本适配层归还 tag，legacy 路径保留
  //   rc_auto_respond 的既有归还所有权，并绕开外部基类缺少 Root 维度的全局 registry 删除。
  // 输入/输出及副作用：cpl 的数据/状态由共同 rb_note API 写回原请求；统一内存末段或错误段使
  //   tag_mgr outstanding 数减一；隔离 tag 的迟到 Completion 只计数而不接触新请求。
  // 失败/边界：requester/tag 不属于当前 read-back 与 tag-manager 同一请求时拒绝折叠；多段成功
  //   Completion 只在累计字节达到请求长度后释放，legacy 模式绝不在此重复释放。
  function void rdma_pcie_ep_driver::handle_completion(pcie_tl_cpl_tlp	cpl);
    pcie_tl_tlp	request;
    pcie_tl_tlp	tag_owner;
    bit [25:0]	registry_key;

    if (cpl == null)
      return;
    registry_key = pcie_rb_registry::mk_key(cpl.requester_id, cpl.tag);
    if (timeout_quarantine.exists(registry_key)) begin
      late_timeout_completions++;
      `uvm_warning("RDMA_PCIE_LATE_CPL", $sformatf(
        "ignored late Completion for quarantined tag=0x%03h requester=0x%04h",
        cpl.tag, cpl.requester_id))
      return;
    end

    if (rb_outstanding.exists(cpl.tag))
      request = rb_outstanding[cpl.tag];
    if (request == null || request.requester_id != cpl.requester_id)
      return;
    if (use_unified_mem) begin
      if (tag_mgr == null)
        return;
      tag_owner = tag_mgr.match_completion(cpl);
      if (tag_owner != request)
        return;
    end
    // 两版外部基类的释放行为不同，且新版 super 会按无 Root 的 requester/tag 清全局 registry。
    // 始终只调用共同 fold 原语，后续由本层按模式与 exact owner 明确结算，避免跨 Root 误删/双释放。
    rb_note_completion(cpl);
    if (request.rb_done) begin
      read_generations.delete(request);
      if (system != null)
        system.discard_read_fault(request);
      retire_registry_if_owned(request);
      if (use_unified_mem && tag_mgr.match_completion(cpl) == request)
        tag_mgr.free_tag(cpl.tag, request.requester_id[2:0]);
    end
  endfunction

  // 功能：在统一内存设备 DMA Completion timeout 后撤销 EP read-back 状态，并隔离该 tag 防止迟到
  //   Completion 与后续请求发生 ABA 混淆。
  // 输入/输出及副作用：request 为超时请求的非拥有句柄；成功用不发送的 error fence 清除 EP 私有
  //   read-back 表，只在全局 registry 仍属同句柄时清共有字段，并从 outstanding 移除但不归还 tag。
  // 失败/边界：legacy 模式由 rc_auto_respond 持有 tag 归还权；request 为空、read-back/tag-manager
  //   所有者或捕获的 tag 代次不一致时返回 0 且不修改任何表，避免误退休已完成或已复用事务。
  function bit rdma_pcie_ep_driver::retire_timeout(pcie_tl_tlp	request);
    pcie_tl_cpl_tlp	fence;
    cpl_status_e	saved_status;
    bit [25:0]		registry_key;

    if (request == null || !rb_outstanding.exists(request.tag) ||
        rb_outstanding[request.tag] != request || !use_unified_mem || tag_mgr == null ||
        !tag_mgr.outstanding_txn.exists(request.tag) ||
        tag_mgr.outstanding_txn[request.tag] != request || !read_generations.exists(request) ||
        read_generations[request] != tag_mgr.get_outstanding_generation(request.tag))
      return 1'b0;

    // 两版 VIP 的辅助 read-back 字段不同；通过共同的 terminal fold API 让各版本自行清理 EP 私有表。
    // fence 只在本函数内消费，不进入链路、monitor 或 scoreboard，恢复 rb_status 后不会伪装硬件 CA。
    saved_status = request.rb_status;
    fence = pcie_tl_cpl_tlp::type_id::create("rdma_timeout_retire_fence");
    fence.kind = TLP_CPL;
    fence.fmt = FMT_3DW_NO_DATA;
    fence.type_f = TLP_TYPE_CPL;
    fence.requester_id = request.requester_id;
    fence.tag = request.tag;
    fence.cpl_status = CPL_STATUS_CA;
    fence.payload = new[0];
    rb_note_completion(fence);
    request.rb_status = saved_status;
    tag_mgr.outstanding_txn.delete(request.tag);
    registry_key = pcie_rb_registry::mk_key(request.requester_id, request.tag);
    timeout_quarantine[registry_key] = 1'b1;
    read_generations.delete(request);
    if (system != null)
      system.discard_read_fault(request);
    retire_registry_if_owned(request);
    return 1'b1;
  endfunction

  // 功能：只在无 Root 维度的全局 read-back registry 仍由 request 占有时，跨 4b/9aed 完整退休该键。
  // 输入/输出及副作用：request 为非拥有句柄；exact owner 命中后借共同 register API 清版本专属计数，
  //   再删除两版共有的 reqs/recv/total，最终该键不可被 Completion 命中。
  // 失败/边界：空请求、键不存在或已被另一 Root 的同 BDF/tag 请求覆盖时严格不修改全局表。
  function void rdma_pcie_ep_driver::retire_registry_if_owned(pcie_tl_tlp	request);
    bit [25:0]	registry_key;

    if (request == null)
      return;
    registry_key = pcie_rb_registry::mk_key(request.requester_id, request.tag);
    if (!pcie_rb_registry::reqs.exists(registry_key) ||
        pcie_rb_registry::reqs[registry_key] != request)
      return;
    // register 在 4b 清 recv/total，在 9aed 还清 wire_bytes；owner guard 保证不会覆盖另一 Root。
    pcie_rb_registry::register(request);
    pcie_rb_registry::reqs.delete(registry_key);
    pcie_rb_registry::recv.delete(registry_key);
    pcie_rb_registry::total.delete(registry_key);
  endfunction

  // 功能：构造未绑定的 PCIe BAR，保留基类寄存器写审计。
  // 输入/输出及副作用：name 传给基类；快照和 sequencer 引用初始为空，均不取得所有权。
  // 失败/边界：bind_instance 成功前 write64 返回 INVALID_STATE。
  function rdma_pcie_bar::new(string	name = "rdma_pcie_bar");
    super.new(name);
  endfunction

  // 功能：把已有 BAR 前门绑定到同一冻结 Function 的真实租约和 RC sequencer。
  // 输入/输出及副作用：snapshot/key/lease/sequencer 为借用或值输入；成功一次性保存绑定。
  // 失败/边界：空或未冻结快照、空 sequencer、租约不匹配或重复绑定均拒绝，原绑定保持不变。
  function rdma_status rdma_pcie_bar::bind_instance(dpu_device_snapshot	snapshot,
      dpu_function_key_t	key, dpu_bar_pair_lease_t	lease,
      uvm_sequencer #(pcie_tl_tlp)	sequencer);
    dpu_bar_pair_lease_t	expected;
    string	why;

    if (bar_snapshot != null || snapshot == null || sequencer == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "BAR binding missing or already installed");
    if (!snapshot.is_frozen() || !snapshot.get_bar(key, lease.role, expected, why) ||
        expected != lease)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "BAR lease differs from frozen snapshot");
    bar_snapshot  = snapshot;
    bar_key       = key;
    bar_lease     = lease;
    bar_sequencer = sequencer;
    return rdma_status::success();
  endfunction

  // 功能：将完整落在绑定 BAR 内的 64 位大端写通过现有 PCIe sequence 发送。
  // 输入/输出及副作用：offset/value 记录到审计队列；发送八字节，模型绑定额外累计 sent_writes。
  // 失败/边界：未绑定、跨 BAR 或地址溢出在 sequence 前失败；posted 成功仅表示传输提交，不确认 DUT 执行。
  task rdma_pcie_bar::write64(bit [63:0]	offset, bit [63:0]	value, output rdma_status	status);
    pcie_tl_rw_seq	seq;
    bit [64:0]		last_offset;
    bit [64:0]		address;
    bit [64:0]		last_address;

    written_offsets.push_back(offset);
    written_values.push_back(value);
    if (bar_snapshot == null || bar_sequencer == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "PCIe BAR is not connected");
      return;
    end
    last_offset = {1'b0, offset} + 7;
    address = {1'b0, bar_lease.base} + {1'b0, offset};
    last_address = address + 7;
    if (last_offset[64] || last_offset >= {1'b0, bar_lease.size} ||
        address[64] || last_address[64]) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "8-byte BAR access crosses lease or overflows");
      return;
    end
    seq = pcie_tl_rw_seq::type_id::create("rdma_mmio_wr");
    seq.op = PCIE_RW_WRITE;
    seq.addr = address[63:0];
    seq.byte_len = 8;
    seq.wdata = new[8];
    foreach (seq.wdata[i])
      seq.wdata[i] = value[63 - 8 * i -: 8];
    seq.start(bar_sequencer);
    if (system != null)
      system.sent_writes++;
    status = rdma_status::success();
  endtask

  // 功能：构造空 PCIe 系统并初始化 MMIO/DMA/Completion 观测，默认设备读超时为 50us。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；创建私有 MMIO mailbox，所有计数和错误引用清零。
  // 失败/边界：尚未绑定 dpu 或创建 tl_env；build_phase 前不得索取 sequencer 或发 DMA。
  function rdma_pcie_system::new(string	name = "rdma_pcie_system", uvm_component	parent = null);
    super.new(name, parent);
    dpu = null;
    sent_writes = 0;
    decoded_writes = 0;
    rejected_writes = 0;
    failed_writes = 0;
    last_mmio_error = null;
    dma_read_tlps = 0;
    dma_read_successes = 0;
    dma_read_failures = 0;
    dma_write_tlps = 0;
    host_reads = 0;
    host_writes = 0;
    completion_timeouts = 0;
    completion_ur = 0;
    completion_ca = 0;
    dma_completion_timeout_ns = 50000;
    mmio_q = new();
  endfunction

  // 功能：全局注册 RDMA 的 RC/EP 驱动、BAR 与设备 DMA factory 覆盖，使随后创建的系统统一走 PCIe。
  // 输入/输出及副作用：修改 UVM factory type override；不创建对象，重复调用保持相同映射。
  // 失败/边界：必须早于 rdma_dpu_system.build 与本组件 build；过晚调用不会替换已创建的对象。
  function void rdma_pcie_system::install_overrides();
    pcie_tl_ep_driver::type_id::set_type_override(rdma_pcie_ep_driver::get_type());
    pcie_tl_rc_driver::type_id::set_type_override(rdma_pcie_rc_driver::get_type());
    rdma_dpu_bar::type_id::set_type_override(rdma_pcie_bar::get_type());
    rdma_dev_dma::type_id::set_type_override(rdma_pcie_dma::get_type());
  endfunction

  // 功能：按冻结 dpu 快照建立每 Host 一条 x16 RC↔EP 链，投影 Function attachment/Root binding，
  //   创建启用 FC、事务记分板和功能覆盖的 TLM PCIe 环境，并把设备 DMA 端口绑定到 Function。
  // 输入/输出及副作用：消费 dpu 及其 mem_pool 非拥有引用，创建 global_cfg、tl_cfg、tl_env；每个 DMA port.system 借用
  //   本组件，每个 Root 绑定所属 Host 的统一 host_mem。
  // 失败/边界：dpu 未 build、Host 缺 host_mem、DMA 端口不是 rdma_pcie_dma 或投影/绑定失败报告
  //   UVM_FATAL；不修改 dpu_common 快照或外部内存生命周期。
  function void rdma_pcie_system::build_phase(uvm_phase	phase);
    pcie_topology_builder	builder;
    pcie_topology_cfg		topology;
    pcie_dpu_cfg_adapter	adapter;
    pcie_dpu_attachment_cfg	attachments;
    pcie_dpu_root_binding_cfg	root_bindings;
    int unsigned		segment[int unsigned];
    string			errors[$];
    string			why;
    int unsigned		root;
    rdma_pcie_dma		port;

    super.build_phase(phase);
    if (dpu == null || dpu.snapshot == null)
      `uvm_fatal("RDMA_PCIE", "dpu system must be built before the PCIe system")
    foreach (dpu.nodes[i]) begin
      if (host_domain.exists(dpu.nodes[i].func.key.host_id) &&
          !dpu_same_domain_key(host_domain[dpu.nodes[i].func.key.host_id],
                               dpu.nodes[i].func.pcie_id.domain))
        `uvm_fatal("RDMA_PCIE", $sformatf(
          "Host %0d maps to more than one PCIe domain",
          dpu.nodes[i].func.key.host_id))
      host_domain[dpu.nodes[i].func.key.host_id] = dpu.nodes[i].func.pcie_id.domain;
      segment[dpu.nodes[i].func.key.host_id] = dpu.nodes[i].func.pcie_id.domain.segment_id;
    end
    builder = pcie_topology_builder::type_id::create("rdma_pcie_topology");
    root = 0;
    foreach (segment[h]) begin
      host_root[h] = root++;
      void'(builder.add_rc($sformatf("RC%0d", h)));
      void'(builder.add_ep($sformatf("EP%0d", h)));
      void'(builder.connect($sformatf("RC%0d_EP%0d", h, h), $sformatf("RC%0d", h),
                            PCIE_TOPO_PORT_RC, 0, $sformatf("EP%0d", h), PCIE_TOPO_PORT_EP, 0,
                            16, 4));
    end
    topology = builder.finish();
    attachments = pcie_dpu_attachment_cfg::type_id::create("rdma_pcie_attachments");
    foreach (dpu.nodes[i]) begin
      if (!attachments.add(dpu.nodes[i].func.key,
                           $sformatf("EP%0d", dpu.nodes[i].func.key.host_id),
                           $sformatf("RC%0d_EP%0d", dpu.nodes[i].func.key.host_id,
                                     dpu.nodes[i].func.key.host_id), 1'b0, 0, why))
        `uvm_fatal("RDMA_PCIE", {"attachment failed: ", why})
    end
    root_bindings = pcie_dpu_root_binding_cfg::type_id::create("rdma_pcie_roots");
    foreach (segment[h])
      if (!root_bindings.bind_domain_to_root(h, segment[h], host_root[h], why))
        `uvm_fatal("RDMA_PCIE", {"root binding failed: ", why})
    adapter = pcie_dpu_cfg_adapter::type_id::create("rdma_pcie_adapter");
    if (!adapter.project_with_root_bindings(dpu.snapshot, null, topology, attachments,
                                            root_bindings, global_cfg, errors)) begin
      foreach (errors[i])
        `uvm_error("RDMA_PCIE", errors[i])
      `uvm_fatal("RDMA_PCIE", "dpu snapshot projection failed")
    end
    tl_cfg = pcie_tl_env_config::type_id::create("rdma_pcie_tl_cfg");
    tl_cfg.if_mode = TLM_MODE;
    tl_cfg.rc_is_active = UVM_ACTIVE;
    tl_cfg.ep_is_active = UVM_ACTIVE;
    tl_cfg.ep_auto_response = 1'b1;
    tl_cfg.fc_enable = 1'b1;
    tl_cfg.scb_enable = 1'b1;
    tl_cfg.cov_enable = 1'b1;
    tl_cfg.tlp_basic_cov = 1'b1;
    tl_cfg.fc_state_cov = 1'b1;
    tl_cfg.tag_usage_cov = 1'b1;
    tl_cfg.ordering_cov = 1'b1;
    tl_cfg.error_inject_cov = 1'b1;
    tl_cfg.use_unified_mem = 1'b1;
    foreach (segment[h]) begin
      if (dpu.mem_pool == null || !dpu.mem_pool.has_host(h))
        `uvm_fatal("RDMA_PCIE", $sformatf("Host %0d has no host_mem for PCIe DMA", h))
      if (!tl_cfg.bind_host_memory(host_root[h], h, dpu.mem_pool.get_host(h), why))
        `uvm_fatal("RDMA_PCIE", {"host memory binding failed: ", why})
    end
    foreach (dpu.nodes[i]) begin
      if (!$cast(port, dpu.nodes[i].dev.cmq.dma))
        `uvm_fatal("RDMA_PCIE", "device DMA port is not rdma_pcie_dma (install_overrides first)")
      port.func   = dpu.nodes[i].func;
      port.system = this;
    end
    uvm_config_db#(pcie_global_cfg)::set(this, "tl_env", "global_cfg", global_cfg);
    uvm_config_db#(pcie_tl_env_config)::set(this, "tl_env", "tl_policy_cfg", tl_cfg);
    tl_env = pcie_tl_env::type_id::create("tl_env", this);
  endfunction

  // 功能：把每个 Root 的 RC/EP 驱动绑定到同一 dpu_common Host，分别约束 fault 与 MMIO ingress authority。
  // 输入/输出及副作用：phase 为 UVM connect phase；按 host_root 写两个派生驱动的 system/host_id/valid，并为每个 BAR 绑定快照/租约/sequencer。
  // 失败/边界：Root 下标缺失或 factory 未产生任一 RDMA 派生驱动时报告 UVM_FATAL，避免 fault/MMIO
  //   串到其他 Host。
  function void rdma_pcie_system::connect_phase(uvm_phase	phase);
    rdma_pcie_rc_driver	rc_driver;
    rdma_pcie_ep_driver	ep_driver;
    int unsigned	root;
    rdma_pcie_bar	bar;
    rdma_status		status;

    super.connect_phase(phase);
    foreach (host_root[h]) begin
      root = host_root[h];
      rc_driver = null;
      ep_driver = null;
      if (root < tl_env.rc_agents.size() && tl_env.rc_agents[root] != null)
        void'($cast(rc_driver, tl_env.rc_agents[root].rc_driver));
      else if (root == 0 && tl_env.rc_agent != null)
        void'($cast(rc_driver, tl_env.rc_agent.rc_driver));
      if (rc_driver == null)
        `uvm_fatal("RDMA_PCIE", $sformatf("Host %0d RC driver is not rdma_pcie_rc_driver", h))
      if (root < tl_env.ep_agents.size() && tl_env.ep_agents[root] != null)
        void'($cast(ep_driver, tl_env.ep_agents[root].ep_driver));
      else if (root == 0 && tl_env.ep_agent != null)
        void'($cast(ep_driver, tl_env.ep_agent.ep_driver));
      if (ep_driver == null)
        `uvm_fatal("RDMA_PCIE", $sformatf("Host %0d EP driver is not rdma_pcie_ep_driver", h))
      rc_driver.system = this;
      ep_driver.system = this;
      rc_driver.host_id = h;
      rc_driver.host_id_valid = 1'b1;
      ep_driver.host_id = h;
      ep_driver.host_id_valid = 1'b1;
    end
    foreach (dpu.nodes[i]) begin
      if (!$cast(bar, dpu.nodes[i].bar))
        `uvm_fatal("RDMA_PCIE", "model BAR is not rdma_pcie_bar")
      bar.system = this;
      status = bar.bind_instance(dpu.snapshot, dpu.nodes[i].func.key,
        dpu.nodes[i].func.bar0, rc_seqr(dpu.nodes[i].func.key.host_id));
      if (!status.ok())
        `uvm_fatal("RDMA_PCIE", "model BAR instance binding failed")
    end
  endfunction

  // 功能：按到达顺序持续取出 RC→EP 的 posted MemWr，并在独立进程内同步执行设备寄存器写。
  // 输入/输出及副作用：phase 只提供生命周期上下文；永久消费 mmio_q，更新解码/拒绝/设备失败观测。
  // 失败/边界：任务由 UVM phase 终止；空队列阻塞，不主动超时或取消已入队写。
  task rdma_pcie_system::run_phase(uvm_phase	phase);
    rdma_pcie_mmio_ingress_t	ingress;

    forever begin
      mmio_q.get(ingress);
      dispatch_mmio(ingress.host_id, ingress.request);
    end
  endtask

  // 功能：查询 host_id 对应 Root 的 RC sequencer，供驱动 BAR 发起 Host→设备 MemWr。
  // 输入/输出及副作用：只读 host_root/tl_env 并返回非拥有 sequencer 引用。
  // 失败/边界：未知 Host 报 UVM_FATAL；要求 build/connect 已完成且 v_seqr 数组与投影一致。
  function uvm_sequencer #(pcie_tl_tlp) rdma_pcie_system::rc_seqr(int unsigned	host_id);
    if (!host_root.exists(host_id))
      `uvm_fatal("RDMA_PCIE", $sformatf("Host %0d has no PCIe root", host_id))
    return tl_env.v_seqr.rc_seqr_arr[host_root[host_id]];
  endfunction

  // 功能：查询 host_id 所属链路的 EP sequencer，供该 Host 内 Function 发起设备 DMA。
  // 输入/输出及副作用：只读 host_root/tl_env 并返回非拥有 sequencer 引用。
  // 失败/边界：未知 Host 报 UVM_FATAL；要求 build/connect 已完成且 v_seqr 数组与投影一致。
  function uvm_sequencer #(pcie_tl_tlp) rdma_pcie_system::ep_seqr(int unsigned	host_id);
    if (!host_root.exists(host_id))
      `uvm_fatal("RDMA_PCIE", $sformatf("Host %0d has no PCIe endpoint", host_id))
    return tl_env.v_seqr.ep_seqr_arr[host_root[host_id]];
  endfunction

  // 功能：把 EP 收到的 posted MemWr 连同 ingress Host authority 交给 MMIO 工作进程并保持到达顺序。
  // 输入/输出及副作用：host_id/req 组成值+非拥有句柄记录后 try_put 到无界 mmio_q。
  // 失败/边界：未知 Host 或空 req 报 UVM_ERROR 且不入队；若未来 mailbox 改为有界，拒绝时报 UVM_FATAL。
  function void rdma_pcie_system::deliver_mmio(int unsigned	host_id, pcie_tl_mem_tlp	req);
    rdma_pcie_mmio_ingress_t	ingress;

    if (req == null || !host_domain.exists(host_id)) begin
      `uvm_error("RDMA_PCIE_MMIO", $sformatf("invalid MMIO ingress Host %0d", host_id))
      return;
    end
    ingress.host_id = host_id;
    ingress.request = req;
    if (!mmio_q.try_put(ingress))
      `uvm_fatal("RDMA_PCIE", "MMIO queue rejected a posted write")
  endfunction

  // 功能：记录指定 ingress Host 的 RC 实际收到的设备 MemRd/MemWr，并按 Host+BDF 累计事务分布。
  // 输入/输出及副作用：host_id/req 只读；更新 host_reads/host_writes 与 host_requesters。
  // 失败/边界：非 MemRd/MemWr 忽略；Host+BDF authority 由插件 report 与冻结快照逐项核对。
  function void rdma_pcie_system::note_host_request(int unsigned	host_id, pcie_tl_tlp	req);
    bit [47:0]	requester_key;

    if (!(req.kind inside {TLP_MEM_RD, TLP_MEM_WR}))
      return;
    if (req.kind == TLP_MEM_RD)
      host_reads++;
    else
      host_writes++;
    requester_key = {host_id, req.requester_id};
    if (!host_requesters.exists(requester_key))
      host_requesters[requester_key] = 0;
    host_requesters[requester_key]++;
  endfunction

  // 功能：为指定 Function 的下一条设备 MemRd 安排一次 timeout、UR 或 CA，键同时包含 Host 与 BDF。
  // 输入/输出及副作用：func/fault 为输入；成功写 read_faults 并返回 OK，不发送事务。
  // 失败/边界：func 为空、NONE 或已有未消费规则分别返回 INVALID_ARGUMENT/RESOURCE_BUSY；规则不会影响
  //   其他 Function、MemWr 或第二条 MemRd。
  function rdma_status rdma_pcie_system::arm_read_fault(rdma_dpu_function	func, rdma_pcie_fault_e	fault);
    string	key;

    if (func == null || fault == RDMA_PCIE_FAULT_NONE)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PCIe read fault requires a Function and non-NONE kind");
    key = fault_key(func.key.host_id, func.pcie_id.bdf);
    if (read_faults.exists(key))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               $sformatf("PCIe read fault is already armed for %s", key));
    read_faults[key] = fault;
    return rdma_status::success();
  endfunction

  // 功能：EP tag 分配后原子认领下一条 MemRd fault，在 scoreboard 克隆前设置 UR/CA 期望。
  // 输入/输出及副作用：host_id/req/adapter 定位模型发送端；删除 armed 规则并保存同句柄 issued 规则。
  // 失败/边界：非读或无规则不变；非 TLM、poison/header 改写、重复句柄拒绝并清规则，不跨 wire 猜测对象身份。
  function void rdma_pcie_system::prepare_read_fault(int unsigned	host_id, pcie_tl_tlp	req,
      pcie_tl_if_adapter	adapter);
    string		key;
    rdma_pcie_fault_e	fault;

    if (req == null || req.kind != TLP_MEM_RD)
      return;
    key = fault_key(host_id, req.requester_id);
    if (!read_faults.exists(key))
      return;
    fault = read_faults[key];
    read_faults.delete(key);
    if (adapter == null || adapter.mode != TLM_MODE || req.inject_poisoned ||
        req.field_bitmask != 0 || issued_read_faults.exists(req)) begin
      issued_read_faults.delete(req);
      `uvm_error("RDMA_PCIE_FAULT", "one-shot model fault requires unchanged TLM request identity")
      return;
    end
    issued_read_faults[req] = '{host_id: host_id, fault: fault};
    if (fault == RDMA_PCIE_FAULT_UR)
      req.expected_cpl_status = CPL_STATUS_UR;
    else if (fault == RDMA_PCIE_FAULT_CA)
      req.expected_cpl_status = CPL_STATUS_CA;
  endfunction

  // 功能：终止 Completion、timeout 或拒绝时释放请求尚未消费的 issued fault 引用。
  // 输入/输出及副作用：req 定位精确请求句柄，删除该条目；不重新 arm、不改其他 Function 的规则。
  // 失败/边界：null 或已被 RC 消费的请求为空操作，可重复清理。
  function void rdma_pcie_system::discard_read_fault(pcie_tl_tlp	req);
    if (req != null)
      issued_read_faults.delete(req);
  endfunction

  // 功能：所属 Host 的 RC 收到模型 TLM 请求后取走已由 EP 认领的 fault。
  // 输入/输出及副作用：host_id/req 输入；fault 输出，匹配时删除精确请求的 issued 规则。
  // 失败/边界：非读、null 或无 issued 规则返回 NONE；Host 不匹配清该条目并报错，不把规则移给后续读。
  function bit rdma_pcie_system::consume_read_fault(int unsigned	host_id, pcie_tl_tlp	req,
      output rdma_pcie_fault_e	fault);
    rdma_pcie_issued_fault_t	issued;

    fault = RDMA_PCIE_FAULT_NONE;
    if (req == null || req.kind != TLP_MEM_RD || !issued_read_faults.exists(req))
      return 0;
    issued = issued_read_faults[req];
    issued_read_faults.delete(req);
    if (issued.host_id != host_id) begin
      `uvm_error("RDMA_PCIE_FAULT", "issued fault reached a different Host")
      return 0;
    end
    fault = issued.fault;
    return 1;
  endfunction

  // 功能：记录一次设备 MemRd 的结构化失败，保留 Function 最近错误并按 timeout/UR/CA 分类计数。
  // 输入/输出及副作用：func/status 为已完成失败证据；借用 status 句柄写 last_dma_errors，递增
  //   dma_read_failures 及对应错误类别计数。
  // 失败/边界：func/status 为空时只递增总失败数；未知 hardware_code 不计入 UR/CA，诊断仍可查询。
  function void rdma_pcie_system::record_dma_error(rdma_dpu_function	func, rdma_status	status);
    dma_read_failures++;
    if (func != null && status != null)
      last_dma_errors[dpu_function_key_name(func.key)] = status;
    if (status == null)
      return;
    if (status.code == RDMA_SC_TIMEOUT)
      completion_timeouts++;
    else if (status.code == RDMA_SC_PCIE_COMPLETION && status.hardware_code_valid) begin
      if (status.hardware_code == CPL_STATUS_UR)
        completion_ur++;
      else if (status.hardware_code == CPL_STATUS_CA)
        completion_ca++;
    end
  endfunction

  // 功能：返回指定 Function 最近一次 DMA 失败，供设备/测试侧读取原始 PCIe 诊断。
  // 输入/输出及副作用：func 为查询键；返回系统持有的非拥有 status 引用，不复制或清除记录。
  // 失败/边界：func 为空或从未失败返回 null；调用方不得修改返回对象后再把它视作历史快照。
  function rdma_status rdma_pcie_system::last_dma_error(rdma_dpu_function	func);
    string	key;

    if (func == null)
      return null;
    key = dpu_function_key_name(func.key);
    if (!last_dma_errors.exists(key))
      return null;
    return last_dma_errors[key];
  endfunction

  // 功能：按 Root+requester/tag 核对超时读的 scoreboard 克隆指纹，再隔离 EP tag 并结算。
  // 输入/输出及副作用：func/request 定位链路；仅 EP exact owner/代次有效且克隆/分片身份一致时删除记录并累计 timed_out。
  // 失败/边界：缺句柄/Host/agent 返回；克隆指纹或 tracker 不匹配报错且不退休；无等待地核对并删除，不能删除另一请求。
  function void rdma_pcie_system::retire_timed_out_read(rdma_dpu_function	func, pcie_tl_tlp	request);
    int unsigned			root;
    rdma_pcie_ep_driver			driver;
    pcie_tl_scoreboard			scb;
    pcie_tl_scoreboard::request_key_t	key;
    pcie_tl_tlp				snapshot;
    pcie_tl_mem_tlp			original_mem;
    pcie_tl_mem_tlp			snapshot_mem;

    if (func == null || request == null || tl_env == null ||
        !host_root.exists(func.key.host_id))
      return;
    root = host_root[func.key.host_id];
    if (root < tl_env.ep_agents.size() && tl_env.ep_agents[root] != null)
      void'($cast(driver, tl_env.ep_agents[root].ep_driver));
    else if (root == 0 && tl_env.ep_agent != null)
      void'($cast(driver, tl_env.ep_agent.ep_driver));
    if (driver == null || root >= tl_env.scbs.size() || tl_env.scbs[root] == null)
      return;
    scb = tl_env.scbs[root];
    key = scb.request_key(request);
    if (scb.pending_requests.exists(key))
      snapshot = scb.pending_requests[key];
    // SCB 有意深拷贝：不能要求原句柄相等。基类 compare 不含 Memory 地址/BE，必须显式补齐指纹。
    // 函数不让出仿真时间；EP 私有 owner/代次与 tracker 的精确 clone 身份共同阻止误退休另一事务。
    if (snapshot == null || !$cast(original_mem, request) || !$cast(snapshot_mem, snapshot) ||
        !snapshot.compare(request) || original_mem.addr != snapshot_mem.addr ||
        original_mem.first_be != snapshot_mem.first_be || original_mem.last_be != snapshot_mem.last_be ||
        (scb.cpl_trackers.exists(key) && scb.cpl_trackers[key].orig_req != snapshot)) begin
      `uvm_error("RDMA_PCIE_TIMEOUT", "scoreboard clone fingerprint/owner does not match timed-out read")
      return;
    end
    if (!driver.retire_timeout(request))
      return;
    if (!scb.pending_requests.exists(key) || scb.pending_requests[key] != snapshot) begin
      `uvm_error("RDMA_PCIE_TIMEOUT", "scoreboard clone changed during non-yielding retirement")
      return;
    end
    scb.pending_requests.delete(key);
    scb.cpl_trackers.delete(key);
    scb.timed_out++;
  endfunction

  // 功能：生成 fault 表的稳定复合键，使相同 BDF 在不同 Host/segment 上互不串扰。
  // 输入/输出及副作用：host_id/bdf 为值输入，返回格式化 string，无状态修改。
  // 失败/边界：所有整数与 16 位 BDF 均可编码；键只在本组件生命周期内使用，不作为持久 ABI。
  function string rdma_pcie_system::fault_key(int unsigned	host_id, bit [15:0]	bdf);
    return $sformatf("host%0d:bdf%04h", host_id, bdf);
  endfunction

  // 功能：把一个 8 字节大端 MemWr 只在 ingress Host 的冻结 PCIe domain 内解码，并同步调用所属设备。
  // 输入/输出及副作用：host_id 是 EP 链路携带的 authority，req 只读；成功递增 decoded_writes，
  //   Host/BAR/长度拒绝递增 rejected_writes，设备内部 DMA/协议失败递增 failed_writes 并保存错误。
  // 失败/边界：payload 少于 8 字节、Host 未绑定或地址不属于该 Host domain 均拒绝；绝不尝试其他
  //   domain，因此不同 Host 的重叠 BAR 地址也不会越权路由。
  task rdma_pcie_system::dispatch_mmio(int unsigned	host_id, pcie_tl_mem_tlp	req);
    bit [63:0]		value;
    rdma_status		status;
    int unsigned	routed_before;

    value = '0;
    if (req == null || req.payload.size() < 8 || !host_domain.exists(host_id)) begin
      rejected_writes++;
      return;
    end
    for (int	i = 0; i < 8; i++)
      value = (value << 8) | req.payload[i];
    routed_before = dpu.router.routed;
    dpu.router.write(host_domain[host_id], req.addr, value, status);
    if (dpu.router.routed != routed_before) begin
      if (status.ok())
        decoded_writes++;
      else begin
        failed_writes++;
        last_mmio_error = status;
      end
      return;
    end
    rejected_writes++;
  endtask
endpackage

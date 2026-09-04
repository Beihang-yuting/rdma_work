// 目录：公共类型层 types/rdma_identity_types.sv。
// 职责：实现 rdma_identity_types 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_identity_types.sv 属于基础类型层，集中定义 RDMA 枚举、地址、身份和状态契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef struct packed {
  bit [15:0] segment;
  bit [7:0] bus;
  bit [4:0] device;
  bit [2:0] function_num;
} rdma_bdf_t;

// 功能：把 bdf.bus、bdf.device 和 bdf.function_num 按 PCIe requester-ID 位序拼接成 16 位请求者标识。
// 输入/输出及副作用：bdf（输入）；返回 bit [15:0]，不写回 bdf、不更新任何资源账本。
// 失败/边界：该函数对所有 bit 取值都有定义，不产生错误码；调用方仍需在路由层单独校验 BDF 是否为全零。
function automatic bit [15:0] rdma_bdf_requester_id(rdma_bdf_t bdf);
  return {bdf.bus, bdf.device, bdf.function_num};
endfunction

typedef struct packed {
  bit [15:0] root_id;
  bit [31:0] host_topology_key;
  rdma_function_kind_e function_kind;
  rdma_bdf_t parent_pf_bdf;
  bit [15:0] vf_index;
  rdma_bdf_t bdf;
} rdma_function_key_t;

// 中文说明：reset epoch 是 Function incarnation 的值快照，用于隔离复位前资源。
typedef longint unsigned rdma_reset_epoch_t;

// 中文说明：PCIe 路由键必须保留 Host/root/segment，避免相同 BDF 跨 fabric 串线。
typedef struct packed {
  bit [31:0] host_topology_key;
  bit [15:0] root_id;
  bit [15:0] segment;
  rdma_bdf_t bdf;
} rdma_route_key_t;

// 功能：从 Function key 投影 host_topology_key、root_id、bdf.segment 和 bdf，形成完整 rdma_route_key_t。
// 输入/输出及副作用：key（输入）；返回值是独立 route 快照，不修改 key 或外部路由表。
// 失败/边界：该函数只做字段投影，不判断 PF/VF 合法性；route 是否可用由 rdma_route_key_valid() 负责。
function automatic rdma_route_key_t rdma_route_key_from_function(
  rdma_function_key_t key
);
  rdma_route_key_t route;
  route.host_topology_key = key.host_topology_key;
  route.root_id = key.root_id;
  route.segment = key.bdf.segment;
  route.bdf = key.bdf;
  return route;
endfunction

// 中文说明：这些纯值校验函数由 identity、binding 和各 router 共用。
// BDF 的 segment=0 是合法 PCIe segment；只有完整 BDF 全零才表示缺失。
// 功能：逐字段检查 bdf.segment、bus、device 和 function_num 是否全部为零，识别缺失 BDF。
// 输入/输出及副作用：bdf（输入）；返回 bit，不修改 bdf、route 或任何资源状态。
// 失败/边界：所有 bit 组合均返回确定结果；segment=0 但其他字段非零时必须返回 0（表示 BDF 存在）。
function automatic bit rdma_bdf_is_zero(rdma_bdf_t bdf);
  return bdf.segment == 16'h0 && bdf.bus == 8'h0 &&
         bdf.device == 5'h0 && bdf.function_num == 3'h0;
endfunction

// 功能：逐字段比较 lhs 与 rhs 的 segment、bus、device 和 function_num，判断两个 BDF 是否相同。
// 输入/输出及副作用：lhs（输入）、rhs（输入）；返回 bit，不修改任一 BDF 或外部 authority。
// 失败/边界：不存在空句柄或错误码分支；任一字段不等即返回 0，未知 bit 值不会被静默当作相等。
function automatic bit rdma_bdf_same(rdma_bdf_t lhs, rdma_bdf_t rhs);
  return lhs.segment == rhs.segment && lhs.bus == rhs.bus &&
         lhs.device == rhs.device && lhs.function_num == rhs.function_num;
endfunction

// 中文说明：Host topology key=0 是合法的显式 Host0；BDF 必须非零，且
// route 中的 segment 必须与 BDF segment 一致；root_id=0 允许作为显式 root0。
// 功能：校验 route.bdf 非全零且 route.segment 与 route.bdf.segment 一致，确认该路由键可交给 PCIe/Host router 查找。
// 输入/输出及副作用：route（输入）；rdma_route_key_valid 读取 route 并使用字段 segment；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：BDF 全零或 segment 不一致时返回 0；host_topology_key=0、root_id=0 均是允许的显式 Host/root 值。
function automatic bit rdma_route_key_valid(rdma_route_key_t route);
  if (rdma_bdf_is_zero(route.bdf))
    return 1'b0;
  if (route.segment != route.bdf.segment)
    return 1'b0;
  return 1'b1;
endfunction

// 中文说明：Function key 的 parent PF 约束在这里集中执行，避免 VF 走错
// Host/root/segment 或把 parent 当成自身 BDF。
// 功能：先校验 Function key 的 route，再按 function_kind 执行 PF/VF 分支：PF 要求 vf_index=0 且 parent PF 为空，VF 要求非零 vf_index、合法且不同的 parent PF、相同 segment。
// 输入/输出及副作用：key（输入）；rdma_function_key_route_valid 读取 key 并使用字段 route；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：route 非法、PF/VF 分支约束不满足或 function_kind 落入 default 时返回 0；函数只返回布尔值，不修改 key。
function automatic bit rdma_function_key_route_valid(rdma_function_key_t key);
  rdma_route_key_t route;
  route = rdma_route_key_from_function(key);
  if (!rdma_route_key_valid(route))
    return 1'b0;
  case (key.function_kind)
    RDMA_FUNCTION_PF:
      return key.vf_index == 16'h0 && rdma_bdf_is_zero(key.parent_pf_bdf);
    RDMA_FUNCTION_VF:
      return key.vf_index != 16'h0 &&
             !rdma_bdf_is_zero(key.parent_pf_bdf) &&
             key.parent_pf_bdf.segment == key.bdf.segment &&
             !rdma_bdf_same(key.parent_pf_bdf, key.bdf);
    default:
      return 1'b0;
  endcase
endfunction

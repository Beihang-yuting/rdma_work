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

  // 功能：处理 rdma_bdf_requester_id：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 bus, device, function_num 用于执行 rdma_bdf_requester_id；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_bdf_requester_id 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：处理 rdma_route_key_from_function：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 key 用于执行 rdma_route_key_from_function；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_route_key_from_function 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
  // 功能：处理 rdma_bdf_is_zero：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 segment 用于执行 rdma_bdf_is_zero；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_bdf_is_zero 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic bit rdma_bdf_is_zero(rdma_bdf_t bdf);
  return bdf.segment == 16'h0 && bdf.bus == 8'h0 &&
         bdf.device == 5'h0 && bdf.function_num == 3'h0;
endfunction

  // 功能：处理 rdma_bdf_same：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 lhs, segment 用于执行 rdma_bdf_same；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_bdf_same 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic bit rdma_bdf_same(rdma_bdf_t lhs, rdma_bdf_t rhs);
  return lhs.segment == rhs.segment && lhs.bus == rhs.bus &&
         lhs.device == rhs.device && lhs.function_num == rhs.function_num;
endfunction

// 中文说明：Host topology key=0 是合法的显式 Host0；BDF 必须非零，且
// route 中的 segment 必须与 BDF segment 一致；root_id=0 允许作为显式 root0。
  // 功能：处理 rdma_route_key_valid：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 bdf 用于执行 rdma_route_key_valid；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_route_key_valid 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic bit rdma_route_key_valid(rdma_route_key_t route);
  if (rdma_bdf_is_zero(route.bdf))
    return 1'b0;
  if (route.segment != route.bdf.segment)
    return 1'b0;
  return 1'b1;
endfunction

// 中文说明：Function key 的 parent PF 约束在这里集中执行，避免 VF 走错
// Host/root/segment 或把 parent 当成自身 BDF。
  // 功能：处理 rdma_function_key_route_valid：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 route 用于执行 rdma_function_key_route_valid；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_function_key_route_valid 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

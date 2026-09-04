// 中文说明：rdma_identity_types.sv 属于基础类型层，集中定义 RDMA 枚举、地址、身份和状态契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef struct packed {
  bit [15:0] segment;
  bit [7:0] bus;
  bit [4:0] device;
  bit [2:0] function_num;
} rdma_bdf_t;

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
function automatic bit rdma_bdf_is_zero(rdma_bdf_t bdf);
  return bdf.segment == 16'h0 && bdf.bus == 8'h0 &&
         bdf.device == 5'h0 && bdf.function_num == 3'h0;
endfunction

function automatic bit rdma_bdf_same(rdma_bdf_t lhs, rdma_bdf_t rhs);
  return lhs.segment == rhs.segment && lhs.bus == rhs.bus &&
         lhs.device == rhs.device && lhs.function_num == rhs.function_num;
endfunction

// 中文说明：Host topology key=0 是合法的显式 Host0；BDF 必须非零，且
// route 中的 segment 必须与 BDF segment 一致；root_id=0 允许作为显式 root0。
function automatic bit rdma_route_key_valid(rdma_route_key_t route);
  if (rdma_bdf_is_zero(route.bdf))
    return 1'b0;
  if (route.segment != route.bdf.segment)
    return 1'b0;
  return 1'b1;
endfunction

// 中文说明：Function key 的 parent PF 约束在这里集中执行，避免 VF 走错
// Host/root/segment 或把 parent 当成自身 BDF。
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

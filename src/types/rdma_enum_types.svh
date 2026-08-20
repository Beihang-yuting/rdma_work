typedef enum bit [4:0] {
  RDMA_SC_OK                 = 5'd0,
  RDMA_SC_INVALID_ARGUMENT   = 5'd1,
  RDMA_SC_INVALID_STATE      = 5'd2,
  RDMA_SC_STALE_GENERATION   = 5'd3,
  RDMA_SC_RESOURCE_EXHAUSTED = 5'd4,
  RDMA_SC_UNSUPPORTED_OPCODE = 5'd5,
  RDMA_SC_CODEC_ERROR        = 5'd6,
  RDMA_SC_TIMEOUT            = 5'd7,
  RDMA_SC_PCIE_COMPLETION    = 5'd8,
  RDMA_SC_DMA_TRANSLATION    = 5'd9,
  RDMA_SC_DMA_PERMISSION     = 5'd10,
  RDMA_SC_QUEUE_FULL         = 5'd11,
  RDMA_SC_QUEUE_EMPTY        = 5'd12,
  RDMA_SC_UNKNOWN_HW_ERROR   = 5'd13,
  RDMA_SC_RESET_CANCELLED    = 5'd14
} rdma_status_code_e;

typedef enum bit [3:0] {
  RDMA_STATUS_CONFIGURATION = 4'd0,
  RDMA_STATUS_RESOURCE      = 4'd1,
  RDMA_STATUS_STATE         = 4'd2,
  RDMA_STATUS_CODEC         = 4'd3,
  RDMA_STATUS_TIMEOUT       = 4'd4,
  RDMA_STATUS_PCIE          = 4'd5,
  RDMA_STATUS_DMA           = 4'd6,
  RDMA_STATUS_QUEUE         = 4'd7,
  RDMA_STATUS_HARDWARE      = 4'd8,
  RDMA_STATUS_NETWORK       = 4'd9,
  RDMA_STATUS_RESET         = 4'd10
} rdma_status_category_e;

typedef enum bit [3:0] {
  RDMA_BIND_DISCOVERED      = 4'd0,
  RDMA_BIND_PCIE_CONFIGURED = 4'd1,
  RDMA_BIND_BOUND           = 4'd2,
  RDMA_BIND_PREPARED        = 4'd3,
  RDMA_BIND_ACTIVE          = 4'd4,
  RDMA_BIND_QUIESCING       = 4'd5,
  RDMA_BIND_RESETTING       = 4'd6,
  RDMA_BIND_RELEASED        = 4'd7,
  RDMA_BIND_ERROR           = 4'd8
} rdma_binding_state_e;

typedef enum bit [3:0] {
  RDMA_RESOURCE_FUNCTION = 4'd0,
  RDMA_RESOURCE_PD       = 4'd1,
  RDMA_RESOURCE_MR       = 4'd2,
  RDMA_RESOURCE_CQ       = 4'd3,
  RDMA_RESOURCE_QP       = 4'd4,
  RDMA_RESOURCE_SRQ      = 4'd5,
  RDMA_RESOURCE_CMQ      = 4'd6,
  RDMA_RESOURCE_CEQ      = 4'd7,
  RDMA_RESOURCE_AEQ      = 4'd8
} rdma_resource_kind_e;

typedef enum bit [2:0] {
  RDMA_TRANSPORT_RC       = 3'd0,
  RDMA_TRANSPORT_UD       = 3'd1,
  RDMA_TRANSPORT_URC      = 3'd2,
  RDMA_TRANSPORT_CUSTOM   = 3'd3,
  RDMA_TRANSPORT_RESERVED = 3'd4
} rdma_transport_e;

typedef enum bit [1:0] {
  RDMA_DMA_DEVICE_READ   = 2'd0,
  RDMA_DMA_DEVICE_WRITE  = 2'd1,
  RDMA_DMA_BIDIRECTIONAL = 2'd2
} rdma_dma_direction_e;

typedef enum bit [1:0] {
  RDMA_MAPPING_INVALID  = 2'd0,
  RDMA_MAPPING_ACTIVE   = 2'd1,
  RDMA_MAPPING_FROZEN   = 2'd2,
  RDMA_MAPPING_RELEASED = 2'd3
} rdma_mapping_state_e;

typedef enum bit [4:0] {
  RDMA_IMAGE_NONE     = 5'd0,
  RDMA_IMAGE_QPC      = 5'd1,
  RDMA_IMAGE_CQC      = 5'd2,
  RDMA_IMAGE_MRT      = 5'd3,
  RDMA_IMAGE_SRQC     = 5'd4,
  RDMA_IMAGE_CEQC     = 5'd5,
  RDMA_IMAGE_AEQC     = 5'd6,
  RDMA_IMAGE_CMQ_SQE  = 5'd7,
  RDMA_IMAGE_CMQ_CQE  = 5'd8,
  RDMA_IMAGE_SQE      = 5'd9,
  RDMA_IMAGE_RQE      = 5'd10,
  RDMA_IMAGE_CQE      = 5'd11,
  RDMA_IMAGE_CEQE     = 5'd12,
  RDMA_IMAGE_AEQE     = 5'd13,
  RDMA_IMAGE_DOORBELL = 5'd14
} rdma_image_kind_e;

typedef enum bit [3:0] {
  RDMA_DOORBELL_CMQ_SQ   = 4'd0,
  RDMA_DOORBELL_SQ       = 4'd1,
  RDMA_DOORBELL_RQ       = 4'd2,
  RDMA_DOORBELL_SRQ      = 4'd3,
  RDMA_DOORBELL_CQ       = 4'd4,
  RDMA_DOORBELL_CEQ      = 4'd5,
  RDMA_DOORBELL_AEQ      = 4'd6,
  RDMA_DOORBELL_QP_FLUSH = 4'd7,
  RDMA_DOORBELL_TQ_FLUSH = 4'd8
} rdma_doorbell_kind_e;

typedef enum bit [3:0] {
  RDMA_ENGINE_NONE     = 4'd0,
  RDMA_ENGINE_RESOURCE = 4'd1,
  RDMA_ENGINE_CMQ      = 4'd2,
  RDMA_ENGINE_SQ       = 4'd3,
  RDMA_ENGINE_RQ       = 4'd4,
  RDMA_ENGINE_CQ       = 4'd5,
  RDMA_ENGINE_CEQ      = 4'd6,
  RDMA_ENGINE_AEQ      = 4'd7,
  RDMA_ENGINE_PCIE     = 4'd8,
  RDMA_ENGINE_DMA      = 4'd9,
  RDMA_ENGINE_NETWORK  = 4'd10,
  RDMA_ENGINE_RESET    = 4'd11
} rdma_engine_kind_e;

typedef enum bit [1:0] {
  RDMA_SEVERITY_INFO    = 2'd0,
  RDMA_SEVERITY_WARNING = 2'd1,
  RDMA_SEVERITY_ERROR   = 2'd2,
  RDMA_SEVERITY_FATAL   = 2'd3
} rdma_severity_e;

typedef enum bit [1:0] {
  RDMA_RESPONDER_DUT          = 2'd0,
  RDMA_RESPONDER_VIP          = 2'd1,
  RDMA_RESPONDER_MONITOR_ONLY = 2'd2
} rdma_responder_mode_e;

typedef enum bit [1:0] {
  RDMA_RESET_FLR            = 2'd0,
  RDMA_RESET_VF_DISABLE     = 2'd1,
  RDMA_RESET_FUNCTION_RESET = 2'd2,
  RDMA_RESET_DUT_RESET      = 2'd3
} rdma_reset_kind_e;

typedef enum bit [2:0] {
  RDMA_FAULT_WRONG_REQUESTER = 3'd0,
  RDMA_FAULT_IOVA_PERMISSION = 3'd1,
  RDMA_FAULT_CMQ_TIMEOUT     = 3'd2,
  RDMA_FAULT_CQE_ERROR       = 3'd3,
  RDMA_FAULT_PACKET_DROP     = 3'd4,
  RDMA_FAULT_VF_FLR          = 3'd5
} rdma_fault_kind_e;

typedef enum bit {
  RDMA_FUNCTION_PF = 1'd0,
  RDMA_FUNCTION_VF = 1'd1
} rdma_function_kind_e;

typedef enum bit {
  RDMA_ENDIAN_LITTLE = 1'd0,
  RDMA_ENDIAN_BIG    = 1'd1
} rdma_byte_endian_e;

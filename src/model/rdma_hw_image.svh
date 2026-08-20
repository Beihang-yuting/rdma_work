typedef enum bit [1:0] {
  RDMA_HW_TARGET_NONE    = 2'd0,
  RDMA_HW_TARGET_BACKING = 2'd1,
  RDMA_HW_TARGET_HMC_FVM = 2'd2,
  RDMA_HW_TARGET_BAR     = 2'd3
} rdma_hw_target_kind_e;

class rdma_hw_image extends uvm_object;
  `uvm_object_utils(rdma_hw_image)

  byte unsigned bytes[$];
  longint unsigned length;
  int unsigned alignment;
  rdma_byte_endian_e endian;
  rdma_image_kind_e image_kind;
  int unsigned hardware_version;
  int unsigned function_generation;
  rdma_hw_target_kind_e write_target_kind;
  rdma_backing_addr_t backing_target;
  rdma_hmc_fvm_addr_t hmc_target;
  rdma_bar_addr_t bar_target;
  string field_summary[$];

  function new(string name = "rdma_hw_image");
    super.new(name);
    bytes.delete();
    length = '0;
    alignment = '0;
    endian = RDMA_ENDIAN_LITTLE;
    image_kind = RDMA_IMAGE_NONE;
    hardware_version = '0;
    function_generation = '0;
    write_target_kind = RDMA_HW_TARGET_NONE;
    backing_target = '0;
    hmc_target = '0;
    bar_target = '0;
    field_summary.delete();
  endfunction
endclass

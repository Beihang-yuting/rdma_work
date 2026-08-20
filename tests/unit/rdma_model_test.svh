class rdma_model_test extends uvm_test;
  `uvm_component_utils(rdma_model_test)

  function new(string name = "rdma_model_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "model returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  function automatic rdma_function_binding make_valid_binding(string name);
    rdma_function_binding binding;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = 64'h0123_4567_89ab_cdef;
    binding.generation = 32'd7;
    binding.global_function_id = 32'h9000_0101;
    binding.rdma_vf_id = 32'h9000_0202;
    binding.vsi_id = 32'h9000_0303;
    binding.notify_table_sel = 32'h9000_0404;
    binding.notify_table_index = 32'h9000_0505;
    binding.host_id = 32'h9000_0606;
    binding.pfvf_id = 32'h9000_0707;
    binding.pcie.bdf = '{segment:16'h1001, bus:8'h20, device:5'h03,
                         function_num:3'h5};
    binding.pcie.parent_pf_bdf = '{segment:16'h2002, bus:8'h30,
                                   device:5'h04, function_num:3'h2};
    binding.pcie.vf_index = 32'h8000_8080;
    binding.pcie.bar[0].base.value = 64'h0000_0000_8000_0000;
    binding.pcie.bar[0].size = 64'h4000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 3'd0;
    binding.notify_base.value = 64'h0000_0000_8000_2000;
    binding.notify_size = 64'h2000;
    binding.state = RDMA_BIND_BOUND;
    return binding;
  endfunction

  function automatic void enable_active_binding(rdma_function_binding binding);
    binding.state = RDMA_BIND_ACTIVE;
    binding.dma_domain_valid = 1'b1;
    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
  endfunction

  function automatic rdma_dma_mapping make_valid_mapping(
    string name,
    rdma_function_handle function_h,
    rdma_bdf_t requester_bdf
  );
    rdma_dma_mapping mapping;

    mapping = rdma_dma_mapping::type_id::create(name);
    mapping.function_h = function_h;
    mapping.requester_bdf = requester_bdf;
    mapping.pasid_valid = 1'b1;
    mapping.pasid = 20'habcde;
    mapping.backing_addr.value = 64'h0000_0000_4000_0000;
    mapping.iova.value = 64'h0000_0001_0000_0000;
    mapping.size = 64'h1000;
    mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    mapping.permissions = '{device_read:1'b1, device_write:1'b1,
                            atomic:1'b0};
    mapping.state = RDMA_MAPPING_ACTIVE;
    return mapping;
  endfunction

  task run_phase(uvm_phase phase);
    rdma_function_binding binding;
    rdma_function_binding active_binding;
    rdma_function_handle function_h;
    rdma_function_handle requested_h;
    rdma_function_handle wrong_h;
    rdma_dma_mapping mapping;
    rdma_status subset_status;
    rdma_hw_image image;
    rdma_hw_image backing_image;
    rdma_hw_image bar_image;
    rdma_hw_image no_target_image;
    rdma_bar_decode decode;
    rdma_pcie_function_info function_info;
    rdma_handle owner_h;
    rdma_handle cloned_h;
    uvm_object cloned_object;
    rdma_bdf_t requester_bdf;
    rdma_dma_permission_t read_permission;
    rdma_dma_permission_t write_permission;
    rdma_dma_permission_t read_write_permission;
    rdma_dma_permission_t atomic_permission;
    rdma_iova_t request_iova;
    string backing_type_name;
    string iova_type_name;
    string image_backing_type_name;
    string hmc_target_type_name;
    string bar_target_type_name;

    phase.raise_objection(this);

    binding = make_valid_binding("binding");
    expect_status("BIND_VALID", binding.validate(), RDMA_SC_OK);

    if (binding.pcie == null || binding.pcie.bar[0] == null)
      `uvm_error("BIND_OBJECTS", "binding did not construct PCIe/BAR metadata")

    function_info = rdma_pcie_function_info::type_id::create("function_info");
    decode = rdma_bar_decode::type_id::create("decode");
    decode.target_bdf = binding.pcie.bdf;
    decode.bar_id = binding.notify_bar_id;
    decode.bar_offset = binding.notify_base.value -
                        binding.pcie.bar[0].base.value;
    if (function_info == null || decode.bar_offset != 64'h2000)
      `uvm_error("PCIE_MODEL", "PCIe identity/decode model is incomplete")

    if (binding.pcie.vf_index == binding.pcie.bdf.function_num ||
        binding.rdma_vf_id == binding.pcie.vf_index ||
        binding.global_function_id == binding.rdma_vf_id ||
        binding.vsi_id == binding.global_function_id ||
        binding.notify_table_sel == binding.notify_table_index ||
        binding.host_id == binding.pfvf_id)
      `uvm_error("IDENTITY", "independent identity fields were coupled")
    expect_status("IDENTITY_VALID", binding.validate(), RDMA_SC_OK);

    function_h = binding.make_handle();
    if (function_h == null ||
        function_h.kind != RDMA_RESOURCE_FUNCTION ||
        function_h.function_uid != binding.function_uid ||
        function_h.object_id != binding.global_function_id ||
        function_h.generation != binding.generation ||
        !binding.accepts(function_h) ||
        !function_h.same_instance(binding.make_handle()))
      `uvm_error("HANDLE", "function handle identity is incorrect")
    cloned_object = function_h.clone();
    if (!$cast(cloned_h, cloned_object) ||
        !function_h.same_instance(cloned_h))
      `uvm_error("HANDLE_CLONE", "cloned handle lost typed identity")
    if (binding.accepts(null))
      `uvm_error("HANDLE_NULL", "binding accepted a null handle")

    wrong_h = binding.make_handle();
    wrong_h.kind = RDMA_RESOURCE_QP;
    if (binding.accepts(wrong_h))
      `uvm_error("HANDLE_KIND", "binding accepted the wrong handle kind")
    wrong_h = binding.make_handle();
    wrong_h.function_uid++;
    if (binding.accepts(wrong_h))
      `uvm_error("HANDLE_UID", "binding accepted the wrong function UID")
    wrong_h = binding.make_handle();
    wrong_h.object_id++;
    if (binding.accepts(wrong_h))
      `uvm_error("HANDLE_OBJECT", "binding accepted the wrong object ID")
    binding.generation++;
    if (binding.accepts(function_h))
      `uvm_error("HANDLE_GENERATION", "binding accepted a stale handle")
    binding.generation--;

    binding.notify_size = 64'h0;
    expect_status("NOTIFY_ZERO", binding.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    binding.notify_size = 64'h2000;
    binding.notify_base.value = 64'h0000_0000_8000_3000;
    expect_status("NOTIFY_ALIGN", binding.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    binding.notify_base.value = 64'h0000_0000_8000_4000;
    expect_status("NOTIFY_OUTSIDE", binding.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    binding = make_valid_binding("max_end_binding");
    binding.pcie.bar[0].base.value = 64'hffff_ffff_ffff_c000;
    binding.pcie.bar[0].size = 64'h4000;
    binding.notify_base.value = 64'hffff_ffff_ffff_e000;
    binding.notify_size = 64'h2000;
    expect_status("NOTIFY_MAX_END", binding.validate(), RDMA_SC_OK);
    binding.notify_size = 64'h2001;
    expect_status("NOTIFY_OVERFLOW", binding.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    binding = make_valid_binding("bar_overflow_binding");
    binding.pcie.bar[0].base.value = 64'hffff_ffff_ffff_e000;
    binding.pcie.bar[0].size = 64'h2001;
    binding.notify_base.value = 64'hffff_ffff_ffff_e000;
    expect_status("BAR_OVERFLOW", binding.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    binding = make_valid_binding("disabled_bar_binding");
    binding.pcie.bar[0].enabled = 1'b0;
    expect_status("BAR_DISABLED", binding.validate(), RDMA_SC_INVALID_STATE);
    binding = make_valid_binding("bar_id_binding");
    binding.pcie.bar[0].bar_id = 3'd1;
    expect_status("BAR_METADATA_ID", binding.validate(),
                  RDMA_SC_INVALID_STATE);
    binding = make_valid_binding("null_bar_binding");
    binding.pcie.bar[0] = null;
    expect_status("BAR_NULL", binding.validate(), RDMA_SC_INVALID_STATE);
    binding = make_valid_binding("bad_bar_id_binding");
    binding.notify_bar_id = 3'd6;
    expect_status("BAR_ID", binding.validate(), RDMA_SC_INVALID_ARGUMENT);
    binding = make_valid_binding("null_pcie_binding");
    binding.pcie = null;
    expect_status("PCIE_NULL", binding.validate(), RDMA_SC_INVALID_STATE);

    active_binding = make_valid_binding("active_binding");
    active_binding.state = RDMA_BIND_ACTIVE;
    expect_status("ACTIVE_DEFAULT", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    enable_active_binding(active_binding);
    expect_status("ACTIVE_OWNER_NULL", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.owner_h = active_binding.make_handle();
    expect_status("ACTIVE_VALID", active_binding.validate(), RDMA_SC_OK);
    active_binding.owner_h.generation++;
    expect_status("ACTIVE_OWNER_GENERATION", active_binding.validate(),
                  RDMA_SC_STALE_GENERATION);
    active_binding.owner_h.generation--;
    active_binding.owner_h.function_uid++;
    expect_status("ACTIVE_OWNER_FUNCTION", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.owner_h.function_uid--;
    active_binding.dma_domain_valid = 1'b0;
    expect_status("ACTIVE_DMA_DOMAIN", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.dma_domain_valid = 1'b1;
    active_binding.pcie.mse = 1'b0;
    expect_status("ACTIVE_MSE", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.pcie.mse = 1'b1;
    active_binding.pcie.bme = 1'b0;
    expect_status("ACTIVE_BME", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.pcie.bme = 1'b1;
    active_binding.notify_valid = 1'b0;
    expect_status("ACTIVE_NOTIFY_VALID", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.notify_valid = 1'b1;
    active_binding.notify_ready = 1'b0;
    expect_status("ACTIVE_NOTIFY_READY", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.notify_ready = 1'b1;
    active_binding.dmi_valid = 1'b0;
    expect_status("ACTIVE_DMI_VALID", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.dmi_valid = 1'b1;
    active_binding.dmi_ready = 1'b0;
    expect_status("ACTIVE_DMI_READY", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.dmi_ready = 1'b1;
    active_binding.vft_valid = 1'b0;
    expect_status("ACTIVE_VFT_VALID", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.vft_valid = 1'b1;
    active_binding.vft_ready = 1'b0;
    expect_status("ACTIVE_VFT_READY", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.vft_ready = 1'b1;
    expect_status("ACTIVE_RESTORED", active_binding.validate(), RDMA_SC_OK);

    binding = make_valid_binding("dma_binding");
    function_h = binding.make_handle();
    requested_h = binding.make_handle();
    requester_bdf = binding.pcie.bdf;
    mapping = make_valid_mapping("mapping", function_h, requester_bdf);
    request_iova = mapping.iova;
    read_permission = '{device_read:1'b1, device_write:1'b0, atomic:1'b0};
    write_permission = '{device_read:1'b0, device_write:1'b1, atomic:1'b0};
    read_write_permission = '{device_read:1'b1, device_write:1'b1,
                              atomic:1'b0};
    atomic_permission = '{device_read:1'b1, device_write:1'b0, atomic:1'b1};

    expect_status("DMA_FULL_RANGE",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, mapping.size,
                                       RDMA_DMA_BIDIRECTIONAL,
                                       read_write_permission),
                  RDMA_SC_OK);
    request_iova.value = mapping.iova.value + mapping.size - 1'b1;
    expect_status("DMA_LAST_BYTE",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_OK);
    request_iova.value = mapping.iova.value + mapping.size;
    expect_status("DMA_END_EXCLUSIVE",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_DMA_TRANSLATION);
    request_iova.value = mapping.iova.value - 1'b1;
    expect_status("DMA_BEFORE_START",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_DMA_TRANSLATION);
    request_iova.value = mapping.iova.value;
    expect_status("DMA_ZERO_LENGTH",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd0,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_INVALID_ARGUMENT);
    request_iova.value = 64'hffff_ffff_ffff_fff0;
    expect_status("DMA_REQUEST_OVERFLOW",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'h20,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_DMA_TRANSLATION);
    request_iova = mapping.iova;
    expect_status("DMA_NULL_REQUEST_HANDLE",
                  mapping.check_access(null, requester_bdf, request_iova,
                                       64'd1, RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_INVALID_ARGUMENT);
    mapping.function_h = null;
    expect_status("DMA_NULL_MAPPING_HANDLE",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_INVALID_STATE);
    mapping.function_h = function_h;
    requested_h.generation++;
    expect_status("DMA_STALE_HANDLE",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_STALE_GENERATION);
    requested_h.generation--;
    wrong_h = binding.make_handle();
    wrong_h.function_uid++;
    expect_status("DMA_WRONG_FUNCTION",
                  mapping.check_access(wrong_h, requester_bdf, request_iova,
                                       64'd1, RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_DMA_TRANSLATION);
    requester_bdf.function_num++;
    expect_status("DMA_WRONG_REQUESTER",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_DMA_TRANSLATION);
    requester_bdf = binding.pcie.bdf;
    mapping.state = RDMA_MAPPING_FROZEN;
    expect_status("DMA_STATE",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_INVALID_STATE);
    mapping.state = RDMA_MAPPING_ACTIVE;
    mapping.direction = RDMA_DMA_DEVICE_READ;
    expect_status("DMA_DIRECTION_OK",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_OK);
    expect_status("DMA_DIRECTION_DENIED",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_WRITE,
                                       write_permission),
                  RDMA_SC_DMA_PERMISSION);
    mapping.direction = RDMA_DMA_BIDIRECTIONAL;
    expect_status("DMA_EMPTY_PERMISSION",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_READ, '0),
                  RDMA_SC_DMA_PERMISSION);
    expect_status("DMA_BIDI_PERMISSION",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_BIDIRECTIONAL,
                                       read_permission),
                  RDMA_SC_DMA_PERMISSION);
    mapping.permissions = read_permission;
    subset_status = mapping.check_access(requested_h, requester_bdf,
                                         request_iova, 64'd1,
                                         RDMA_DMA_DEVICE_READ,
                                         atomic_permission);
    expect_status("DMA_PERMISSION_SUBSET", subset_status,
                  RDMA_SC_DMA_PERMISSION);
    if (subset_status == null ||
        subset_status.message != "DMA permissions are not a mapping subset")
      `uvm_error("DMA_PERMISSION_SUBSET",
                 "DMA access did not reach the permission subset check")
    mapping.iova.value = 64'hffff_ffff_ffff_fff0;
    mapping.size = 64'h20;
    request_iova = mapping.iova;
    expect_status("DMA_MAPPING_OVERFLOW",
                  mapping.check_access(requested_h, requester_bdf,
                                       request_iova, 64'd1,
                                       RDMA_DMA_DEVICE_READ,
                                       read_permission),
                  RDMA_SC_DMA_TRANSLATION);

    mapping.iova.value = 64'h55aa_55aa_55aa_55aa;
    mapping.backing_addr.value = 64'h55aa_55aa_55aa_55aa;
    backing_type_name = $typename(mapping.backing_addr);
    iova_type_name = $typename(mapping.iova);
    if (backing_type_name == iova_type_name ||
        mapping.backing_addr.value != mapping.iova.value)
      `uvm_error("DMA_ADDRESS_SPACE",
                 "backing and IOVA address spaces were conflated")

    owner_h = rdma_handle::type_id::create("owner_h");
    owner_h.kind = RDMA_RESOURCE_PD;
    owner_h.function_uid = binding.function_uid;
    owner_h.object_id = 32'h44;
    owner_h.generation = binding.generation;
    mapping.owner_h = owner_h;
    if (mapping.owner_h == null || mapping.owner_h.kind != RDMA_RESOURCE_PD)
      `uvm_error("DMA_OWNER", "mapping owner handle was not retained")

    image = rdma_hw_image::type_id::create("image");
    image.bytes.push_back(8'h11);
    image.bytes.push_back(8'h22);
    image.bytes.push_back(8'h33);
    image.bytes.push_back(8'h44);
    image.length = image.bytes.size();
    image.alignment = 32'd64;
    image.endian = RDMA_ENDIAN_LITTLE;
    image.image_kind = RDMA_IMAGE_QPC;
    image.hardware_version = 32'h0001_0002;
    image.function_generation = binding.generation;
    image.write_target_kind = RDMA_HW_TARGET_HMC_FVM;
    image.hmc_target.value = 64'h0000_0002_0000_1000;
    image.field_summary.push_back("state=RTS");
    image.field_summary.push_back("qpn=17");
    hmc_target_type_name = $typename(image.hmc_target);

    backing_image = rdma_hw_image::type_id::create("backing_image");
    backing_image.write_target_kind = RDMA_HW_TARGET_BACKING;
    backing_image.backing_target.value = 64'h0000_0002_0000_1000;
    image_backing_type_name = $typename(backing_image.backing_target);

    bar_image = rdma_hw_image::type_id::create("bar_image");
    bar_image.write_target_kind = RDMA_HW_TARGET_BAR;
    bar_image.bar_target.value = 64'h0000_0002_0000_1000;
    bar_target_type_name = $typename(bar_image.bar_target);

    no_target_image = rdma_hw_image::type_id::create("no_target_image");
    if (image.length != 64'd4 || image.bytes.size() != image.length ||
        image.bytes[0] != 8'h11 || image.bytes[3] != 8'h44 ||
        image.alignment != 32'd64 ||
        image.endian != RDMA_ENDIAN_LITTLE ||
        image.image_kind != RDMA_IMAGE_QPC ||
        image.hardware_version != 32'h0001_0002 ||
        image.function_generation != binding.generation ||
        image.write_target_kind != RDMA_HW_TARGET_HMC_FVM ||
        image.hmc_target.value != 64'h0000_0002_0000_1000 ||
        backing_image.write_target_kind != RDMA_HW_TARGET_BACKING ||
        backing_image.backing_target.value !=
          64'h0000_0002_0000_1000 ||
        bar_image.write_target_kind != RDMA_HW_TARGET_BAR ||
        bar_image.bar_target.value != 64'h0000_0002_0000_1000 ||
        no_target_image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.field_summary.size() != 2 ||
        image_backing_type_name != backing_type_name ||
        hmc_target_type_name == backing_type_name ||
        hmc_target_type_name == iova_type_name ||
        bar_target_type_name == image_backing_type_name ||
        bar_target_type_name == hmc_target_type_name ||
        bar_target_type_name == iova_type_name)
      `uvm_error("HW_IMAGE", "hardware image metadata/bytes are incomplete")

    phase.drop_objection(this);
  endtask
endclass

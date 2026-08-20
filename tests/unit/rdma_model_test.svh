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
    rdma_function_binding binding_for_copy;
    rdma_function_binding binding_clone;
    rdma_function_binding null_binding;
    rdma_function_binding null_binding_clone;
    rdma_function_binding active_binding;
    rdma_function_handle function_h;
    rdma_function_handle requested_h;
    rdma_function_handle wrong_h;
    rdma_dma_mapping mapping;
    rdma_dma_mapping mapping_clone;
    rdma_dma_mapping null_mapping;
    rdma_dma_mapping null_mapping_clone;
    rdma_status subset_status;
    rdma_status wrong_function_status;
    rdma_hw_image image;
    rdma_hw_image image_clone;
    rdma_hw_image backing_image;
    rdma_hw_image bar_image;
    rdma_hw_image no_target_image;
    rdma_bar_decode decode;
    rdma_bar_decode decode_clone;
    rdma_bar_info bar_info;
    rdma_bar_info bar_info_clone;
    rdma_pcie_identity pcie_identity;
    rdma_pcie_identity pcie_identity_clone;
    rdma_pcie_identity null_pcie;
    rdma_pcie_identity null_pcie_clone;
    rdma_pcie_function_info function_info;
    rdma_pcie_function_info function_info_clone;
    rdma_handle owner_h;
    rdma_handle cloned_h;
    rdma_function_handle cloned_function_h;
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

    bar_info = rdma_bar_info::type_id::create("bar_info");
    bar_info.bar_id = 3'd4;
    bar_info.base.value = 64'h4444_0000_0000_2000;
    bar_info.size = 64'h8000;
    bar_info.enabled = 1'b1;
    cloned_object = bar_info.clone();
    if (!$cast(bar_info_clone, cloned_object))
      `uvm_error("BAR_CLONE", "BAR clone has the wrong dynamic type")
    else if (bar_info_clone.bar_id != bar_info.bar_id ||
             bar_info_clone.base != bar_info.base ||
             bar_info_clone.size != bar_info.size ||
             bar_info_clone.enabled != bar_info.enabled)
      `uvm_error("BAR_CLONE", "BAR clone lost value fields")

    pcie_identity = rdma_pcie_identity::type_id::create("pcie_identity");
    pcie_identity.bdf = '{segment:16'h1111, bus:8'h22, device:5'h03,
                          function_num:3'h4};
    pcie_identity.parent_pf_bdf = '{segment:16'h5555, bus:8'h66,
                                    device:5'h07, function_num:3'h1};
    pcie_identity.vf_index = 32'h7788_9900;
    pcie_identity.mse = 1'b1;
    pcie_identity.bme = 1'b1;
    foreach (pcie_identity.bar[i]) begin
      pcie_identity.bar[i].base.value = 64'h1000_0000 + (i * 64'h10000);
      pcie_identity.bar[i].size = 64'h2000 + i;
      pcie_identity.bar[i].enabled = i[0];
    end
    cloned_object = pcie_identity.clone();
    if (!$cast(pcie_identity_clone, cloned_object))
      `uvm_error("PCIE_CLONE", "PCIe clone has the wrong dynamic type")
    else begin
      if (pcie_identity_clone.bdf != pcie_identity.bdf ||
          pcie_identity_clone.parent_pf_bdf !=
            pcie_identity.parent_pf_bdf ||
          pcie_identity_clone.vf_index != pcie_identity.vf_index ||
          pcie_identity_clone.mse != pcie_identity.mse ||
          pcie_identity_clone.bme != pcie_identity.bme)
        `uvm_error("PCIE_CLONE", "PCIe clone lost scalar/packed fields")
      foreach (pcie_identity.bar[i]) begin
        if (pcie_identity_clone.bar[i] == null)
          `uvm_error("PCIE_CLONE", "PCIe clone lost BAR metadata")
        else if (pcie_identity_clone.bar[i] == pcie_identity.bar[i] ||
                 pcie_identity_clone.bar[i].bar_id !=
                   pcie_identity.bar[i].bar_id ||
                 pcie_identity_clone.bar[i].base !=
                   pcie_identity.bar[i].base ||
                 pcie_identity_clone.bar[i].size !=
                   pcie_identity.bar[i].size ||
                 pcie_identity_clone.bar[i].enabled !=
                   pcie_identity.bar[i].enabled)
          `uvm_error("PCIE_CLONE", "PCIe BAR clone is not a deep copy")
      end
      if (pcie_identity_clone.bar[0] != null) begin
        pcie_identity_clone.bar[0].base.value++;
        if (pcie_identity.bar[0].base.value != 64'h1000_0000)
          `uvm_error("PCIE_CLONE", "PCIe BAR clone aliases its source")
      end
    end

    null_pcie = rdma_pcie_identity::type_id::create("null_pcie");
    null_pcie.bar[5] = null;
    cloned_object = null_pcie.clone();
    if (!$cast(null_pcie_clone, cloned_object) ||
        null_pcie_clone.bar[5] != null)
      `uvm_error("PCIE_NULL_CLONE", "null BAR clone is not null-safe")

    function_info.bdf = pcie_identity.bdf;
    function_info.parent_pf_bdf = pcie_identity.parent_pf_bdf;
    function_info.vf_index = 32'h1234_5678;
    function_info.mse = 1'b1;
    function_info.bme = 1'b1;
    function_info.bar[3].base.value = 64'h3300_0000;
    function_info.bar[3].size = 64'h4000;
    function_info.bar[3].enabled = 1'b1;
    cloned_object = function_info.clone();
    if (!$cast(function_info_clone, cloned_object))
      `uvm_error("FUNCTION_INFO_CLONE",
                 "PCIe function info clone lost dynamic type")
    else if (function_info_clone.bar[3] == null)
      `uvm_error("FUNCTION_INFO_CLONE",
                 "PCIe function info clone lost inherited BAR")
    else if (function_info_clone.bdf != function_info.bdf ||
             function_info_clone.parent_pf_bdf !=
               function_info.parent_pf_bdf ||
             function_info_clone.vf_index != function_info.vf_index ||
             function_info_clone.mse != function_info.mse ||
             function_info_clone.bme != function_info.bme ||
             function_info_clone.bar[3] == function_info.bar[3] ||
             function_info_clone.bar[3].bar_id !=
               function_info.bar[3].bar_id ||
             function_info_clone.bar[3].base != function_info.bar[3].base ||
             function_info_clone.bar[3].size != function_info.bar[3].size ||
             function_info_clone.bar[3].enabled !=
               function_info.bar[3].enabled)
      `uvm_error("FUNCTION_INFO_CLONE",
                 "PCIe function info clone lost inherited fields")

    decode.target_bdf = pcie_identity.bdf;
    decode.bar_id = 3'd3;
    decode.bar_offset = 64'h1234_5678_9abc_def0;
    cloned_object = decode.clone();
    if (!$cast(decode_clone, cloned_object))
      `uvm_error("BAR_DECODE_CLONE", "BAR decode clone has wrong type")
    else if (decode_clone.target_bdf != decode.target_bdf ||
             decode_clone.bar_id != decode.bar_id ||
             decode_clone.bar_offset != decode.bar_offset)
      `uvm_error("BAR_DECODE_CLONE", "BAR decode clone lost fields")

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

    binding_for_copy = make_valid_binding("binding_for_copy");
    binding_for_copy.notify_bar_id = 3'd4;
    binding_for_copy.pcie.mse = 1'b1;
    binding_for_copy.pcie.bme = 1'b1;
    binding_for_copy.dma_domain_id = 32'h8100_0001;
    binding_for_copy.dma_domain_valid = 1'b1;
    binding_for_copy.state = RDMA_BIND_QUIESCING;
    binding_for_copy.owner_h = binding_for_copy.make_handle();
    binding_for_copy.notify_valid = 1'b1;
    binding_for_copy.notify_ready = 1'b1;
    binding_for_copy.dmi_valid = 1'b1;
    binding_for_copy.dmi_ready = 1'b1;
    binding_for_copy.vft_valid = 1'b1;
    binding_for_copy.vft_ready = 1'b1;
    cloned_object = binding_for_copy.clone();
    if (!$cast(binding_clone, cloned_object))
      `uvm_error("BIND_CLONE", "binding clone has the wrong dynamic type")
    else begin
      if (binding_clone.function_uid != binding_for_copy.function_uid ||
          binding_clone.notify_bar_id != binding_for_copy.notify_bar_id ||
          binding_clone.notify_base != binding_for_copy.notify_base ||
          binding_clone.notify_size != binding_for_copy.notify_size ||
          binding_clone.notify_table_sel !=
            binding_for_copy.notify_table_sel ||
          binding_clone.notify_table_index !=
            binding_for_copy.notify_table_index ||
          binding_clone.host_id != binding_for_copy.host_id ||
          binding_clone.pfvf_id != binding_for_copy.pfvf_id ||
          binding_clone.rdma_vf_id != binding_for_copy.rdma_vf_id ||
          binding_clone.global_function_id !=
            binding_for_copy.global_function_id ||
          binding_clone.vsi_id != binding_for_copy.vsi_id ||
          binding_clone.dma_domain_id != binding_for_copy.dma_domain_id ||
          binding_clone.dma_domain_valid !=
            binding_for_copy.dma_domain_valid ||
          binding_clone.state != binding_for_copy.state ||
          binding_clone.generation != binding_for_copy.generation ||
          binding_clone.notify_valid != binding_for_copy.notify_valid ||
          binding_clone.notify_ready != binding_for_copy.notify_ready ||
          binding_clone.dmi_valid != binding_for_copy.dmi_valid ||
          binding_clone.dmi_ready != binding_for_copy.dmi_ready ||
          binding_clone.vft_valid != binding_for_copy.vft_valid ||
          binding_clone.vft_ready != binding_for_copy.vft_ready)
        `uvm_error("BIND_CLONE", "binding clone lost scalar/packed fields")
      if (binding_clone.pcie == null ||
          binding_clone.pcie == binding_for_copy.pcie ||
          binding_clone.pcie.bdf != binding_for_copy.pcie.bdf)
        `uvm_error("BIND_CLONE", "binding PCIe identity is not deep copied")
      else begin
        foreach (binding_for_copy.pcie.bar[i]) begin
          if (binding_clone.pcie.bar[i] == null ||
              binding_clone.pcie.bar[i] == binding_for_copy.pcie.bar[i] ||
              binding_clone.pcie.bar[i].bar_id !=
                binding_for_copy.pcie.bar[i].bar_id ||
              binding_clone.pcie.bar[i].base !=
                binding_for_copy.pcie.bar[i].base ||
              binding_clone.pcie.bar[i].size !=
                binding_for_copy.pcie.bar[i].size ||
              binding_clone.pcie.bar[i].enabled !=
                binding_for_copy.pcie.bar[i].enabled)
            `uvm_error("BIND_CLONE", "binding BAR is not deep copied")
        end
      end
      if (binding_clone.owner_h == null ||
          !$cast(cloned_function_h, binding_clone.owner_h) ||
          binding_clone.owner_h == binding_for_copy.owner_h ||
          !binding_clone.owner_h.same_instance(binding_for_copy.owner_h))
        `uvm_error("BIND_CLONE", "binding owner is not deep copied")
      if (binding_clone.pcie != null &&
          binding_clone.pcie.bar[0] != null) begin
        binding_clone.pcie.bar[0].base.value++;
        if (binding_for_copy.pcie.bar[0].base.value !=
            64'h0000_0000_8000_0000)
          `uvm_error("BIND_CLONE", "binding PCIe clone aliases source")
      end
      if (binding_clone.owner_h != null) begin
        binding_clone.owner_h.generation++;
        if (binding_for_copy.owner_h.generation !=
            binding_for_copy.generation)
          `uvm_error("BIND_CLONE", "binding owner clone aliases source")
      end
    end

    null_binding = rdma_function_binding::type_id::create("null_binding");
    null_binding.pcie = null;
    null_binding.owner_h = null;
    cloned_object = null_binding.clone();
    if (!$cast(null_binding_clone, cloned_object) ||
        null_binding_clone.pcie != null ||
        null_binding_clone.owner_h != null)
      `uvm_error("BIND_NULL_CLONE", "null binding clone is not null-safe")

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
    active_binding.owner_h.kind = RDMA_RESOURCE_QP;
    expect_status("ACTIVE_OWNER_KIND", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.owner_h.kind = RDMA_RESOURCE_FUNCTION;
    active_binding.owner_h.object_id++;
    expect_status("ACTIVE_OWNER_OBJECT", active_binding.validate(),
                  RDMA_SC_INVALID_STATE);
    active_binding.owner_h.object_id--;
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
    mapping.owner_h = rdma_handle::type_id::create("mapping_owner");
    mapping.owner_h.kind = RDMA_RESOURCE_PD;
    mapping.owner_h.function_uid = binding.function_uid;
    mapping.owner_h.object_id = 32'h4455_6677;
    mapping.owner_h.generation = binding.generation;
    cloned_object = mapping.clone();
    if (!$cast(mapping_clone, cloned_object))
      `uvm_error("DMA_CLONE", "DMA mapping clone has wrong dynamic type")
    else begin
      if (mapping_clone.function_h == null ||
          !$cast(cloned_function_h, mapping_clone.function_h))
        `uvm_error("DMA_CLONE", "DMA function handle lost dynamic type")
      else if (!cloned_function_h.same_instance(mapping.function_h))
        `uvm_error("DMA_CLONE", "DMA function handle lost identity")
      if (mapping_clone.function_h == mapping.function_h ||
          mapping_clone.requester_bdf != mapping.requester_bdf ||
          mapping_clone.pasid_valid != mapping.pasid_valid ||
          mapping_clone.pasid != mapping.pasid ||
          mapping_clone.backing_addr != mapping.backing_addr ||
          mapping_clone.iova != mapping.iova ||
          mapping_clone.size != mapping.size ||
          mapping_clone.direction != mapping.direction ||
          mapping_clone.permissions != mapping.permissions ||
          mapping_clone.state != mapping.state)
        `uvm_error("DMA_CLONE", "DMA mapping clone lost value fields")
      if (mapping_clone.owner_h == null ||
          mapping_clone.owner_h == mapping.owner_h ||
          !mapping_clone.owner_h.same_instance(mapping.owner_h))
        `uvm_error("DMA_CLONE", "DMA mapping owner is not deep copied")
      if (mapping_clone.function_h != null) begin
        mapping_clone.function_h.generation++;
        if (mapping.function_h.generation != binding.generation)
          `uvm_error("DMA_CLONE", "DMA function clone aliases source")
      end
      if (mapping_clone.owner_h != null) begin
        mapping_clone.owner_h.object_id++;
        if (mapping.owner_h.object_id != 32'h4455_6677)
          `uvm_error("DMA_CLONE", "DMA owner clone aliases source")
      end
    end

    null_mapping = rdma_dma_mapping::type_id::create("null_mapping");
    null_mapping.function_h = null;
    null_mapping.owner_h = null;
    cloned_object = null_mapping.clone();
    if (!$cast(null_mapping_clone, cloned_object) ||
        null_mapping_clone.function_h != null ||
        null_mapping_clone.owner_h != null)
      `uvm_error("DMA_NULL_CLONE", "null DMA clone is not null-safe")
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
    wrong_h = binding.make_handle();
    wrong_h.function_uid++;
    wrong_h.generation++;
    wrong_function_status = mapping.check_access(
      wrong_h, requester_bdf, request_iova, 64'd1,
      RDMA_DMA_DEVICE_READ, read_permission
    );
    expect_status("DMA_WRONG_FUNCTION_AND_GENERATION",
                  wrong_function_status, RDMA_SC_DMA_TRANSLATION);
    if (wrong_function_status == null ||
        wrong_function_status.message !=
          "requested function does not own mapping")
      `uvm_error("DMA_WRONG_FUNCTION_AND_GENERATION",
                 "unrelated function was misdiagnosed as stale")
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
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_QPC;
    image.hardware_version = 32'h0001_0002;
    image.function_generation = binding.generation;
    image.write_target_kind = RDMA_HW_TARGET_HMC_FVM;
    image.backing_target.value = 64'h1111_2222_3333_4444;
    image.hmc_target.value = 64'h0000_0002_0000_1000;
    image.bar_target.value = 64'haaaa_bbbb_cccc_dddd;
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
        image.endian != RDMA_ENDIAN_BIG ||
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

    cloned_object = image.clone();
    if (!$cast(image_clone, cloned_object))
      `uvm_error("HW_IMAGE_CLONE", "hardware image clone has wrong type")
    else begin
      if (image_clone.bytes != image.bytes ||
          image_clone.length != image.length ||
          image_clone.alignment != image.alignment ||
          image_clone.endian != image.endian ||
          image_clone.image_kind != image.image_kind ||
          image_clone.hardware_version != image.hardware_version ||
          image_clone.function_generation != image.function_generation ||
          image_clone.write_target_kind != image.write_target_kind ||
          image_clone.backing_target != image.backing_target ||
          image_clone.hmc_target != image.hmc_target ||
          image_clone.bar_target != image.bar_target ||
          image_clone.field_summary != image.field_summary)
        `uvm_error("HW_IMAGE_CLONE", "hardware image clone lost fields")
      if (image_clone.bytes.size() != 0 &&
          image_clone.field_summary.size() != 0) begin
        image_clone.bytes[0]++;
        image_clone.field_summary[0] = "mutated";
        if (image.bytes[0] != 8'h11 ||
            image.field_summary[0] != "state=RTS")
          `uvm_error("HW_IMAGE_CLONE", "hardware image queues alias source")
      end
    end

    phase.drop_objection(this);
  endtask
endclass

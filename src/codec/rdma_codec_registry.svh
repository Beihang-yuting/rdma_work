class rdma_codec_registry extends uvm_object;
  `uvm_object_utils(rdma_codec_registry)

  protected rdma_codec_base codecs[string];

  function new(string name = "rdma_codec_registry");
    super.new(name);
  endfunction

  protected function bit contains_delimiter(string component);
    for (int unsigned i = 0; i < component.len(); i++) begin
      if (component.getc(i) == 8'h7c)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function rdma_status canonicalize(
    rdma_codec_key key,
    output string canonical
  );
    canonical = "";
    if (key.hw_version.len() == 0 || key.object_type.len() == 0 ||
        key.variant.len() == 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "codec key has an empty required string component"
      );
    if (contains_delimiter(key.hw_version) ||
        contains_delimiter(key.object_type) ||
        contains_delimiter(key.variant))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "codec key string component contains reserved delimiter '|'"
      );
    if (!(key.image_kind inside {
          RDMA_IMAGE_QPC, RDMA_IMAGE_CQC, RDMA_IMAGE_MRT,
          RDMA_IMAGE_SRQC, RDMA_IMAGE_CEQC, RDMA_IMAGE_AEQC,
          RDMA_IMAGE_CMQ_SQE, RDMA_IMAGE_CMQ_CQE, RDMA_IMAGE_SQE,
          RDMA_IMAGE_RQE, RDMA_IMAGE_CQE, RDMA_IMAGE_CEQE,
          RDMA_IMAGE_AEQE, RDMA_IMAGE_DOORBELL
        }))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "codec key image kind is invalid");

    canonical = $sformatf("%s|%0d|%s|%s|%02x",
                          key.hw_version, key.image_kind,
                          key.object_type, key.variant, key.opcode);
    return rdma_status::success();
  endfunction

  function rdma_status register_codec(
    rdma_codec_key key,
    rdma_codec_base codec
  );
    string canonical;
    rdma_status status;

    status = canonicalize(key, canonical);
    if (!status.ok())
      return status;
    if (codec == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "cannot register a null codec");
    if (codecs.exists(canonical)) begin
      `uvm_fatal("RDMA_CODEC_DUPLICATE",
                 $sformatf("duplicate codec registration for %s",
                           canonical))
      // A report catcher may consume the fatal in a negative unit test.  The
      // operation must still fail and leave the original registration intact.
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "duplicate codec registration");
    end

    codecs[canonical] = codec;
    return rdma_status::success();
  endfunction

  function rdma_status lookup(
    rdma_codec_key key,
    output rdma_codec_base codec
  );
    string canonical;
    rdma_status status;

    codec = null;
    status = canonicalize(key, canonical);
    if (!status.ok())
      return status;
    if (!codecs.exists(canonical))
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        $sformatf("no codec registered for %s", canonical)
      );

    codec = codecs[canonical];
    return rdma_status::success();
  endfunction

  function void clear();
    codecs.delete();
  endfunction

  function void list_keys(output string keys[$]);
    keys.delete();
    foreach (codecs[canonical])
      keys.push_back(canonical);
    if (keys.size() > 1)
      keys.sort();
  endfunction
endclass

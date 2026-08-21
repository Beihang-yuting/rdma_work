class rdma_bit_packer extends uvm_object;
  `uvm_object_utils(rdma_bit_packer)

  protected bit occupancy[];
  protected int unsigned expected_byte_count;
  protected bit initialized;

  function new(string name = "rdma_bit_packer");
    super.new(name);
    occupancy = new[0];
    expected_byte_count = 0;
    initialized = 1'b0;
  endfunction

  function rdma_status initialize(int unsigned image_byte_count);
    if (image_byte_count > (32'h7fff_ffff / 8))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "image is too large for packer occupancy");
    occupancy = new[image_byte_count * 8];
    foreach (occupancy[i])
      occupancy[i] = 1'b0;
    expected_byte_count = image_byte_count;
    initialized = 1'b1;
    return rdma_status::success();
  endfunction

  function rdma_status reset(int unsigned image_byte_count);
    return initialize(image_byte_count);
  endfunction

  protected function rdma_status validate_access(
    byte unsigned bytes[],
    longint unsigned bit_offset,
    int unsigned width,
    output longint unsigned end_exclusive
  );
    bit [64:0] extended_end;
    bit [64:0] capacity_bits;

    end_exclusive = 0;
    if (!initialized)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "bit packer is not initialized");
    if (bytes.size() != expected_byte_count)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        $sformatf("image length %0d does not match initialized length %0d",
                  bytes.size(), expected_byte_count)
      );
    if (width < 1 || width > 64)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "field width must be in the range 1..64");

    extended_end = {1'b0, bit_offset} + width;
    if (extended_end[64])
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "field bit range overflows 64-bit offset");
    capacity_bits = {1'b0, expected_byte_count} << 3;
    if (extended_end > capacity_bits)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "field extends beyond image length");

    end_exclusive = extended_end[63:0];
    return rdma_status::success();
  endfunction

  function rdma_status put_u64(
    ref byte unsigned bytes[],
    input longint unsigned bit_offset,
    input int unsigned width,
    input bit [63:0] value
  );
    rdma_status status;
    longint unsigned end_exclusive;
    longint unsigned bit_index;
    longint unsigned byte_index;
    int unsigned bit_in_byte;

    status = validate_access(bytes, bit_offset, width, end_exclusive);
    if (!status.ok())
      return status;
    if (width < 64 && (value >> width) != 0)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "field value does not fit requested width");

    // Complete validation before mutating either image or occupancy.
    for (int unsigned i = 0; i < width; i++) begin
      bit_index = bit_offset + i;
      if (occupancy[bit_index])
        return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                 "field overlaps an earlier packed field");
    end

    for (int unsigned i = 0; i < width; i++) begin
      bit_index = bit_offset + i;
      byte_index = bit_index >> 3;
      bit_in_byte = bit_index[2:0];
      bytes[byte_index][bit_in_byte] = value[i];
      occupancy[bit_index] = 1'b1;
    end
    return rdma_status::success();
  endfunction

  function rdma_status get_u64(
    byte unsigned bytes[],
    longint unsigned bit_offset,
    int unsigned width,
    output bit [63:0] value
  );
    rdma_status status;
    longint unsigned end_exclusive;
    longint unsigned bit_index;
    longint unsigned byte_index;
    int unsigned bit_in_byte;
    bit [63:0] decoded;

    value = '0;
    status = validate_access(bytes, bit_offset, width, end_exclusive);
    if (!status.ok())
      return status;

    decoded = '0;
    for (int unsigned i = 0; i < width; i++) begin
      bit_index = bit_offset + i;
      byte_index = bit_index >> 3;
      bit_in_byte = bit_index[2:0];
      decoded[i] = bytes[byte_index][bit_in_byte];
    end
    value = decoded;
    return rdma_status::success();
  endfunction
endclass

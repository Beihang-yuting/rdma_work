// 目录：核心执行层 core/rdma_cmq_transaction_kernel.sv。
// 职责：提供与硬件 profile 无关的 CMQ ring/cursor 事务原语，统一 sequence 到
//   index/wrap、occupancy 和 CQ owner 的计算，避免 submit/poll/reset 各自复制公式。
// 依赖：依赖前置 transaction-model 文件中的 slot record 和 SystemVerilog 标量运算；
//   不依赖 Host-memory、PCIe、scheduler、transport 或 rdma_cmq_engine 的可变状态。
// 所有权与生命周期：本文件只包含无状态值函数和短生命周期返回值；不拥有 slot、
//   journal、counter 或外部资源，engine 仍是所有 runtime mutation 的唯一 owner。

// 设计说明：驱动以 head/tail/polarity 推进 ring，CMQ engine 以单调 sequence 表示同一
//   业务过程。以下函数集中实现这层等价映射；profile 仍负责把结果编码到具体 SQE/CQE
//   位域，调用方继续决定何时锁定、写 backing、发 doorbell 或提交账本。
typedef struct {
  longint unsigned slot_sequence;
  int unsigned index;
  bit wrap;
} rdma_cmq_ring_position_t;

// 功能：把一个单调 CMQ sequence 映射为固定 ring depth 下的物理 index 和 wrap，供
//   SQE slot、CQE correlation 与 retirement 共同使用。
// 输入/输出及副作用：slot_sequence、depth 为只读输入；position 为输出，成功时写入
//   sequence/index/wrap；不修改 engine counter、slot、journal 或外部资源。
// 失败/边界：depth 为零或 slot_sequence 含未知位时返回 0 并清空输出；成功使用
//   index=slot_sequence%depth、wrap=(slot_sequence/depth)&1，调用方仍需执行 authority 校验。
function automatic bit rdma_cmq_ring_position_for_sequence(
  input longint unsigned slot_sequence,
  input int unsigned depth,
  output rdma_cmq_ring_position_t position
);
  position = '{default: '0};
  if (depth == 0 || $isunknown(slot_sequence))
    return 1'b0;
  position.slot_sequence = slot_sequence;
  position.index = slot_sequence % depth;
  position.wrap = (slot_sequence / depth) & 1'b1;
  return 1'b1;
endfunction

// 功能：校验 slot 的 sequence、物理 index 和 wrap 是否共同指向调用方指定的 ring
//   位置，供取消、恢复、复位等路径复用同一套几何门禁。
// 输入/输出及副作用：slot_sequence、slot_index、slot_wrap、expected_index 和 depth
//   均为只读输入；函数只返回几何是否一致，不修改 slot、journal、token 或 engine 状态。
// 失败/边界：depth 为零、任一 sequence/index/wrap 含未知位、slot_index 超出 depth、
//   slot_index 不等于 expected_index，或 sequence 推导出的 index/wrap 不一致时返回 0。
function automatic bit rdma_cmq_slot_ring_geometry_matches(
  input longint unsigned slot_sequence,
  input int unsigned slot_index,
  input bit slot_wrap,
  input int unsigned expected_index,
  input int unsigned depth
);
  rdma_cmq_ring_position_t position;

  if (depth == 0 || $isunknown(slot_sequence) ||
      $isunknown(slot_index) || $isunknown(slot_wrap) ||
      slot_index >= depth || slot_index != expected_index ||
      !rdma_cmq_ring_position_for_sequence(slot_sequence, depth, position))
    return 1'b0;
  return slot_index == position.index && slot_wrap == position.wrap;
endfunction

// 功能：按 publish/retire cursor 计算当前 ring occupancy，并集中执行驱动等价的
//   逆序、超深度和未知值检查，供提交、轮询和 reset ledger audit 共用。
// 输入/输出及副作用：publish_seq、retire_seq、depth 为只读输入；used 成功时写入
//   publish_seq-retire_seq，失败时清零；不改变 counter、slot、token 或状态机。
// 失败/边界：depth 为零、任一 counter 含未知位、publish_seq<retire_seq 或差值大于
//   depth 时返回 0；调用方负责把失败映射为 POISONED 或对应业务 status。
function automatic bit rdma_cmq_ring_occupancy_valid(
  input longint unsigned publish_seq,
  input longint unsigned retire_seq,
  input int unsigned depth,
  output longint unsigned used
);
  used = 0;
  if (depth == 0 || $isunknown(publish_seq) || $isunknown(retire_seq) ||
      publish_seq < retire_seq)
    return 1'b0;
  used = publish_seq - retire_seq;
  if (used > depth)
    return 1'b0;
  return 1'b1;
endfunction

// 功能：根据 CQ consume sequence 推导当前 CQE owner/polarity，统一硬件轮询前的
//   ready 判定输入，避免 poll 与测试辅助使用不同的 wrap 公式。
// 输入/输出及副作用：cq_consume_seq、depth 为只读输入；owner 成功时写入期望 owner
//   位；不读取或修改 CQ backing、slot、journal 或 scheduler。
// 失败/边界：depth 为零或 consume sequence 含未知位时返回 0 并清零 owner；成功使用
//   owner=!((cq_consume_seq/depth)&1)，实际 CQE reserved/opcode/index 校验仍由 profile/engine 完成。
function automatic bit rdma_cmq_cq_owner_for_sequence(
  input longint unsigned cq_consume_seq,
  input int unsigned depth,
  output bit owner
);
  owner = 1'b0;
  if (depth == 0 || $isunknown(cq_consume_seq))
    return 1'b0;
  owner = !((cq_consume_seq / depth) & 1'b1);
  return 1'b1;
endfunction

// 功能：在一个已经由 engine 认证过的 retained batch 行内，按完整 detached ticket
//   值寻找唯一 journal item，统一恢复、等待和诊断查询使用的 item 定位循环。
// 输入/输出及副作用：batch_record、ticket 为只读输入；journal_item、
//   journal_item_index 和 match_count 为输出；函数只遍历 batch_record.items，
//   不访问 engine map、锁、runtime ledger 或外部资源，也不转移 item 所有权。
// 失败/边界：batch_record 或 ticket 为空时返回 0 并清空输出；非空 batch 即使没有
//   命中也返回 1，由调用方依据 match_count 区分未命中、多重命中和唯一命中，函数
//   不替代调用方对 batch invariant、ticket shape 或 journal index 的门禁。
function automatic bit rdma_cmq_find_unique_ticket_item(
  input rdma_cmq_batch_submission_record batch_record,
  input rdma_cmq_ticket ticket,
  output rdma_cmq_batch_submission_item_record journal_item,
  output int unsigned journal_item_index,
  output int unsigned match_count
);
  journal_item = null;
  journal_item_index = 0;
  match_count = 0;
  if (batch_record == null || ticket == null)
    return 1'b0;
  foreach (batch_record.items[i]) begin
    if (batch_record.items[i] != null &&
        rdma_cmq_same_ticket_detached_value(
          batch_record.items[i].ticket, ticket
        )) begin
      match_count++;
      journal_item = batch_record.items[i];
      journal_item_index = i;
    end
  end
  return 1'b1;
endfunction

// 设计说明：strict generation cancellation 只接管仍处于 published、尚未有
// completion 的前驱；timeout tombstone 已经是终态证据，必须等待 late completion
// 或 reset 专用路径。把这张表做成纯值函数后，正常完成、expiry、late 和 cancel
// 仍由 engine 决定副作用，但不会在不同业务入口复制或漂移迁移条件。
// 功能：按冻结的 journal state/phase 表判断一次 completion、timeout、late 或 reset
//   transition 是否拥有合法的前驱，统一 engine 的终态迁移门禁。
// 输入/输出及副作用：current_state、current_phase、target_state、target_phase 和
//   completion_present 为只读值；函数返回 bit，不修改 journal item、completion、slot
//   或任何 engine-owned ledger。
// 失败/边界：任一枚举含未知/spare 编码、target 不属于四种支持迁移、completion
//   presence 与前驱要求不符，或 target phase 不匹配时返回 0；该函数不替代 caller
//   对 ticket、slot geometry、batch invariant 和 reset authority 的更高层校验。
function automatic bit rdma_cmq_transition_predecessor_valid(
  input rdma_cmq_submission_state_e current_state,
  input rdma_cmq_completion_phase_e current_phase,
  input rdma_cmq_submission_state_e target_state,
  input rdma_cmq_completion_phase_e target_phase,
  input bit completion_present
);
  if (!rdma_cmq_submission_state_valid(current_state) ||
      !rdma_cmq_completion_phase_valid(current_phase) ||
      !rdma_cmq_submission_state_valid(target_state) ||
      !rdma_cmq_completion_phase_valid(target_phase))
    return 1'b0;

  case (target_state)
    RDMA_CMQ_SUBMISSION_COMPLETED,
    RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED:
      return current_state inside {
               RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
               RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
             } && current_phase == RDMA_CMQ_COMPLETION_PENDING &&
             !completion_present &&
             (target_phase == RDMA_CMQ_COMPLETION_TERMINAL ||
              target_phase == RDMA_CMQ_COMPLETION_TIMEOUT);
    RDMA_CMQ_SUBMISSION_LATE_COMPLETED:
      return current_state == RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED &&
             current_phase == RDMA_CMQ_COMPLETION_TIMEOUT &&
             completion_present &&
             target_phase == RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY;
    RDMA_CMQ_SUBMISSION_RESET_QUARANTINED:
      return current_state inside {
               RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
               RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
             } && current_phase == RDMA_CMQ_COMPLETION_PENDING &&
             !completion_present &&
             target_phase == RDMA_CMQ_COMPLETION_RESET_CANCELLED;
    default:
      return 1'b0;
  endcase
endfunction

// 设计说明：terminal state 与 completion phase 是 retained journal 的一对冻结证据，
// observed validation 和 reconcile projection 必须使用同一映射；pending、unarmed
// 和 reset admission 仍由各自 caller 校验，不在这里推断 runtime ownership。
// 功能：判断 terminal submission state 是否携带与之匹配的 completion phase。
// 输入/输出及副作用：state、phase 为只读枚举输入；返回 bit，不修改 journal、slot、
// completion、lock 或其他 engine-owned 状态。
// 失败/边界：任一枚举含 X/Z 或 spare、state 不是 COMPLETED/TIMED_OUT_QUARANTINED/
//   LATE_COMPLETED/RESET_QUARANTINED，或 phase 与 state 不匹配时返回 0；该函数不
//   检查 completion 句柄是否为空，也不替代 caller 的 completion snapshot 校验。
function automatic bit rdma_cmq_terminal_state_phase_valid(
  input rdma_cmq_submission_state_e state,
  input rdma_cmq_completion_phase_e phase
);
  if (!rdma_cmq_submission_state_valid(state) ||
      !rdma_cmq_completion_phase_valid(phase))
    return 1'b0;

  case (state)
    RDMA_CMQ_SUBMISSION_COMPLETED:
      return phase == RDMA_CMQ_COMPLETION_TERMINAL;
    RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED:
      return phase == RDMA_CMQ_COMPLETION_TIMEOUT;
    RDMA_CMQ_SUBMISSION_LATE_COMPLETED:
      return phase == RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY;
    RDMA_CMQ_SUBMISSION_RESET_QUARANTINED:
      return phase == RDMA_CMQ_COMPLETION_RESET_CANCELLED;
    default:
      return 1'b0;
  endcase
endfunction

// 设计说明：completion phase 是 retained completion 是否可被 observed/wait/reconcile
//   交付的公共证据。各入口仍负责确认 state、ticket 和 completion alias；这里只保留
//   四种终态 phase 的枚举分类，避免 observed 与 wait 路径复制并漂移同一张表。
// 功能：判断 completion phase 是否代表已经生成 retained completion evidence。
// 输入/输出及副作用：phase 为只读冻结枚举输入；返回 bit，不修改 journal、completion、
//   slot、lock 或任何 engine-owned 状态。
// 失败/边界：phase 含 X/Z 或 spare 编码，或为 NONE/PENDING 等非终态时返回 0；函数不
//   检查 completion 句柄、submission state 或 ticket，调用方必须继续执行相应 authority
//   与 alias 校验。
function automatic bit rdma_cmq_completion_phase_has_terminal_evidence(
  input rdma_cmq_completion_phase_e phase
);
  if (!rdma_cmq_completion_phase_valid(phase))
    return 1'b0;
  return phase inside {
    RDMA_CMQ_COMPLETION_TERMINAL,
    RDMA_CMQ_COMPLETION_TIMEOUT,
    RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
    RDMA_CMQ_COMPLETION_RESET_CANCELLED
  };
endfunction

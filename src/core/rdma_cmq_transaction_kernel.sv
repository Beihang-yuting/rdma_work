// 目录：核心执行层 core/rdma_cmq_transaction_kernel.sv。
// 职责：提供与硬件 profile 无关的 CMQ ring/cursor 原语（sequence 到 index/wrap、occupancy、CQ owner）。
// 依赖：transaction-model 中的 slot record 与标量运算；不依赖 Host-memory、PCIe 或 engine 可变状态。
// 所有权与生命周期：只含无状态值函数；不拥有 slot、journal、counter；runtime mutation 归 engine。

// 设计说明：驱动以 head/tail/polarity 推进 ring，engine 以单调 sequence 表示同一过程；这里集中
//   实现两者的等价映射，profile 负责位域编码，调用方决定加锁、写 backing、doorbell 与账本提交。
typedef struct {
  longint unsigned slot_sequence;
  int unsigned index;
  bit wrap;
} rdma_cmq_ring_position_t;

// 功能：把单调 CMQ sequence 映射为固定 depth 下的 ring index 和 wrap。
// 输入/输出及副作用：slot_sequence/depth 为输入；position 为输出；无其他副作用。
// 失败/边界：depth 为零或 sequence 含未知位时返回 0 并清空输出；index=seq%depth，wrap=(seq/depth)&1。
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

// 功能：校验 slot 的 sequence、index、wrap 是否共同指向期望的 ring 位置。
// 输入/输出及副作用：均为只读输入；仅返回几何是否一致。
// 失败/边界：depth 为零、含未知位、slot_index 越界或不等于 expected_index、index/wrap 与
//   sequence 推导不符时返回 0。
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

// 功能：由 publish/retire cursor 计算 ring occupancy，并检查逆序与超深度。
// 输入/输出及副作用：publish_seq/retire_seq/depth 为输入；used 成功时为差值，失败时清零。
// 失败/边界：depth 为零、含未知位、publish<retire 或差值大于 depth 时返回 0；
//   调用方负责映射为 POISONED 等 status。
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

// 功能：由 CQ consume sequence 推导期望的 CQE owner/polarity。
// 输入/输出及副作用：cq_consume_seq/depth 为输入；owner 为输出；不访问 CQ backing。
// 失败/边界：depth 为零或含未知位时返回 0 并清零 owner；owner=!((seq/depth)&1)，
//   CQE 其余字段校验仍由 profile/engine 负责。
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

// 功能：在已认证的 batch 记录内按完整 ticket 值定位 journal item。
// 输入/输出及副作用：batch_record/ticket 为输入；journal_item、index、match_count 为输出；只遍历
//   batch_record.items，不转移所有权。
// 失败/边界：任一入参为空返回 0 并清空输出；非空 batch 未命中也返回 1，由调用方按 match_count
//   区分未命中/多重/唯一命中，并自行校验 batch invariant。
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

// 设计说明：strict generation cancellation 只接管仍处于 published、尚无 completion 的前驱；
// timeout tombstone 已是终态证据，须等待 late completion 或 reset 专用路径。做成纯值函数，
// 使各入口共用同一迁移条件，副作用仍由 engine 决定。
// 功能：按冻结的 journal state/phase 表判断 completion/timeout/late/reset 迁移是否有合法前驱。
// 输入/输出及副作用：current/target 的 state、phase 与 completion_present 为输入；返回 bit，无副作用。
// 失败/边界：枚举含未知/spare、target 不属支持的四类、completion 存在性或 target phase 不符时返回 0；
//   不替代 caller 对 ticket、slot、batch 和 reset authority 的校验。
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

// 设计说明：terminal state 与 completion phase 是 retained journal 的成对冻结证据，observed
// 校验与 reconcile projection 共用同一映射；pending/unarmed/reset admission 由各 caller 校验。
// 功能：判断终态 submission state 是否带有与之匹配的 completion phase。
// 输入/输出及副作用：state/phase 为输入；返回 bit，无副作用。
// 失败/边界：枚举含 X/Z 或 spare、state 非四种终态、phase 不匹配时返回 0；不检查 completion 句柄。
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

// 设计说明：completion phase 是 retained completion 能否被 observed/wait/reconcile 交付的公共
// 证据；state/ticket/alias 校验仍由各入口负责，这里只做四种终态 phase 的分类。
// 功能：判断 completion phase 是否代表已生成 retained completion evidence。
// 输入/输出及副作用：phase 为输入；返回 bit，无副作用。
// 失败/边界：phase 含 X/Z、spare，或为 NONE/PENDING 等非终态时返回 0；不检查 completion 句柄。
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

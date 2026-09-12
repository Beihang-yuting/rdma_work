// 目录：模型层 model/rdma_submission_evidence.sv。
// 职责：定义跨 RDMA engine 共享的提交副作用证据值，以及单调迁移的纯值校验契约。
// 依赖：由 rdma_model_pkg.sv 在 context model 之后包含，仅依赖 SystemVerilog 四态枚举语义。
// 所有权与生命周期：枚举是无资源所有权的值；helper 不保存状态，证据生命周期由调用方管理。

// 设计说明：四态基类型保留恢复证据中的 X/Z，使校验可以拒绝未知值而非静默降级为 UNOBSERVED。
// 两个无副作用终止分支不属于数值推进链；只有 Host-memory/MMIO 五阶段允许单调前进。
typedef enum logic [2:0] {
  RDMA_SUBMIT_EFFECT_UNOBSERVED,
  RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
  RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
  RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
  RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED,
  RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
  RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
} rdma_submission_effect_e;

// 功能：判断 before_effect 到 after_effect 是否保持共享提交证据的终止或单调推进语义。
// 输入/输出及副作用：读取 before_effect 和 after_effect；返回允许为 1，否则为 0；不修改状态。
// 失败/边界：任一输入含 X/Z、阶段回退、推进到终止值或从终止分支重开时返回 0。
function automatic bit rdma_submission_effect_is_monotonic(
  input rdma_submission_effect_e before_effect,
  input rdma_submission_effect_e after_effect
);
  if ($isunknown(before_effect) || $isunknown(after_effect))
    return 1'b0;

  case (before_effect)
    RDMA_SUBMIT_EFFECT_UNOBSERVED:
      return after_effect == RDMA_SUBMIT_EFFECT_UNOBSERVED;

    RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED:
      return after_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;

    default: begin
      if (!(after_effect inside {
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED,
            RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
            RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
          }))
        return 1'b0;

      return after_effect >= before_effect;
    end
  endcase
endfunction

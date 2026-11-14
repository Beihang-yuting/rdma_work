# 目录：integration/virtio/tests；真实桥断言辅助，不隐式加载/配置/初始化。
# 依赖：调用方已source匹配simv的AIP loader；proc在restore之后重新定义。
# 功能：通过真实AIP桥执行command并核对预期成功/失败。
# 输入/输出及副作用：command/want_error为输入，返回非空result；命令可推进仿真。
# 失败/边界：状态与期望不符或空结果抛PROJECT_FAIL，绝不把SV错误吞成成功。
proc project_cmd {command {want_error 0}} {
    aip_send_cmd $command
    set status [aip_check_status]
    set result [aip_read_result]
    if {($status != 0) != $want_error || $result eq ""} {
        error "PROJECT_FAIL command=$command status=$status result=$result"
    }
    return $result
}
# 功能：读取模型当前实际状态，供脚本独立断言。
# 输入/输出及副作用：无参数，返回project_observe的Tcl dict，不改配置。
# 失败/边界：观测命令失败沿用project_cmd的错误，不提供默认状态。
proc project_state {} { return [project_cmd project_observe] }
# 功能：比较状态dict指定计数/标志与脚本期望值。
# 输入/输出及副作用：state/key/expected只读；成功无返回数据。
# 失败/边界：缺键或数值不符直接报错，并保留完整状态诊断。
proc project_eq {state key expected} {
    if {[dict get $state $key] != $expected} {
        error "PROJECT_FAIL $key expected=$expected actual=[dict get $state $key] state=$state"
    }
}
# 功能：证明未配置/未初始化检查点没有MMIO、业务资源或WR抽样副作用。
# 输入/输出及副作用：state只读，同时核对共享身份和命令注册集合。
# 失败/边界：任一活动计数非零或身份不稳定均失败，不忽略已失败的初始化。
proc project_pristine {state} {
    foreach key {configured ready probes cmq_mmio config_accesses checked write_posts write_completions pending_writes sb_errors resources draws preparing busy} {
        project_eq $state $key 0
    }
    project_eq $state sb_idle 1
    project_eq $state identity 1
    project_eq $state registry_stable 1
}
# 功能：显式结束命令桥并运行UVM收尾。
# 输入/输出及副作用：发送end_test，随后run让平台finish和report执行。
# 失败/边界：end_test失败不继续，原始UVM错误仍在日志中由runner拒绝。
proc project_finish {} {
    project_cmd "end_test drain=100ns"
    run
}

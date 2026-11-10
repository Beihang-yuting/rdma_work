// 目录/层次：integration/project/tests；完整类型入口之后的独立Intel fixture。
// 先编译integration/filelists/rdma_project.f；此清单不重复任何package依赖。
// 所有权/生命周期：顶层拥有两组HARD_IP/APPLICATION接口，测试控制复位和资源。
// 编译时显式-top rdma_project_transport_top；不包含命令注册或真实DUT。
@PCIE_INTEL_ROOT@/bind/intel_pcie_bind_wrapper.sv
integration/project/tests/rdma_project_transport_control_if.sv
integration/project/tests/rdma_project_transport_test.sv
integration/project/tests/rdma_project_transport_top.sv

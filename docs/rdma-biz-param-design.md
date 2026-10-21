# rdma_work 目標設計 V1：雙模式 + 按業務類型參數化

依據：`RDMA_ARCH_REVIEW.md`（架構梳理）、`RDMA_PARAM_PROPOSAL.md`（參數清單）、ryan 2026-10-21 的要求：

1. 兩種運行情況：**環境對接測試**（模型 ↔ 模型、模型 ↔ rxe）和 **DUT 模式**（環境模型退化為 RM，加監控組件）。
2. 結合 aip_core 參數化，**每種業務類型**都能單獨設置 QP、內存、報文屬性。

---

## 1. 是否還需要 flow_plan？——結論：不再保留，換成「業務模板」

### 1.1 flow_plan 原本想解決什麼

給 DUT 互連路徑一份「凍結的、可追溯的配置」：每個 QP / QPC / message / netpacket 單獨描述，字段帶 AUTO/FIXED/RANDOM_LEGAL/INVALID 策略，resolver 做跨字段約束後生成 snapshot，`rdma_dut_link` 用 snapshot 把報文編碼成幀。

### 1.2 為什麼不適合作為唯一配置源

| 問題 | 說明 |
|---|---|
| 粒度不對 | message、netpacket 是「逐條列出」的清單，適合定向 bring-up；隨機/大流量一跑幾千條，不可能逐條配置。業務參數需要的是**模板**（一類流量的分佈），不是清單。 |
| 和實際資源脫節 | resolver 生成的 qp_h、CQN、backing 是佔位常量，不驅動 ctrl agent 創建真實資源；實際流量完全不經過它。 |
| 與 aip_core 重複 | 每個字段配一個 `*_mode`（AUTO/FIXED/RANDOM_LEGAL）是在自己實現「沒給 / 固定 / 隨機」。aip_core 已原生提供：不傳 = 默認，傳值 = 固定，`[lo:hi]` / 權重 = 合法範圍隨機。保留兩套只會互相打架。 |
| 報文屬性放錯位置 | 真實硬件裡 VLAN、IP、UDP 源端口、DSCP 等來自 QP 上下文（地址向量），不是每條報文單獨指定。netpacket profile 允許「每條報文不同」，反而與硬件語義不符。 |
| 體量 | profile + snapshot + resolver 約 1500 行、字段數因 `*_mode` 翻倍，只服務一個無人使用的路徑。 |

### 1.3 保留它的好思想

- **凍結**：配置在 build 結束後不可變，運行中不再讀參數。
- **集中校驗**：每類配置有 `validate()`，跨字段約束在一處完成。
- **可追溯**：打印最終生效配置，配合 seed 可復現。
- **INVALID 只能顯式啟用**：負向配置走故障/錯誤注入開關，不會意外流入正常路徑。

### 1.4 替代方案

```
rdma_env_cfg（唯一配置根）
 ├ 拓撲：funcs[]（host/pf/kind/vf/role）
 ├ 模式：mode = PEER | RXE | DUT
 ├ 運行：link、vseq、超時、檢查/覆蓋率開關、drain 時間
 └ biz[]：rdma_biz_cfg（每種業務一個模板）
        ├ qp  ：深度、MTU、SGE、起始 PSN、Q_Key、timeout/retry/rnr_retry/min_rnr（QP 類型由業務決定）
        ├ mem ：buffer 大小、slot 大小與數量、MR 偏移、MR 遠端讀/寫/原子權限
        ├ pkt ：VLAN、源/目的 IP、UDP 源端口、TTL（隨 QP 綁定，鏈路編碼時使用）
        └ trf ：數量、op 權重、長度分佈、SGE 分佈、數據模式、signaled 比例、方向
```

- 資源創建時，模板值寫進 `rdma_res_qp`（每個 QP 自己的屬性），ctrl agent 建鏈、expect 預測、鏈路編碼都讀 QP 自己的屬性，不再讀全局值。
- 分佈類參數（長度、SGE、數據模式）保存為 aip 表達式字符串，**每條消息單獨求值**，例如 `{[1:64]:/20,[65:4096]:/80}`。
- 遷移：V1 新模型與 flow_plan 並存（flow_plan 不改）；V2 把 `rdma_dut_link` 改為使用模型生成的報文 + QP 報文屬性後，刪除 flow_plan / resolver / profile 及其測試。

---

## 2. 兩種運行情況

### 2.1 Function 角色

每個 Function 槽有一個角色，模式由角色組合決定：

| 角色 | 設備 | 主機側 | 說明 |
|---|---|---|---|
| `MODEL` | `rdma_dev` 模型就是設備 | 驅動模型 | 現在的所有 Function |
| `REMOTE` | Linux rxe | rxe_peer 進程 | 現在的 rxe 遠端 Function |
| `DUT` | RTL | 驅動模型經 PCIe 驅動 DUT | 模型實例作為 RM 影子運行 |

### 2.2 環境對接測試（PEER / RXE）

```
MODEL f0 ──┐                 ┌── MODEL f1
           ├── link（直連 / netpkt / rxe TAP）──┤
REMOTE rxe ┘                 └── ...
檢查：scoreboard（期望內存 + 期望完成）、IBTA 協議規則、覆蓋率
```

用途：驗證環境自身（驅動模型、設備模型、檢查器）和參數化能力；rxe 模式用真實 Soft-RoCE 做互通基準。

### 2.3 DUT 模式

```
             驅動模型（host 棧）
                  │ BAR 寫（doorbell / CMQ）        DMA 讀寫
                  ▼                                   ▲
   ┌──────── PCIe 橋（pcie_work RC/EP）──────────────┘
   │  [PCIe monitor] ──► RM（rdma_dev 影子）◄── [ETH monitor]
   ▼                         │ 預測：出口幀、DMA 寫（CQE/EQE/數據）
  DUT(RTL) ◄──── 以太網橋（rdma_dut_link endpoint）────► 對端（MODEL 或 rxe）
                             │
                 比較器：RM 出口幀 vs DUT 出口幀；RM DMA 寫 vs DUT DMA 寫
                 端到端：scoreboard 照常（期望內存 + 期望完成）
```

- **主機側**：驅動模型照常工作，BAR 寫和 DMA 經 pcie_work 的 RC/EP 到達 DUT（與現在 pcie_work suite 的路徑一致，只是 EP 後面從模型換成 RTL）。
- **監控**：PCIe monitor 抓 MMIO 寫（doorbell、CMQ）和 DMA；ETH monitor 抓 DUT 進出的幀。
- **RM**：同一個 `rdma_dev` 類，輸入改為「monitor 看到的 MMIO 寫 + 進入 DUT 的幀」，DMA 讀返回 host_mem 實際內容，DMA 寫不落盤而是送比較器。
- **比較**：按 QP / 隊列保序比較，不比時序。
- **端到端**：scoreboard 不關心設備是模型還是 DUT，直接復用。

> **待確認（Q2）**：DUT 的接口是否就是「PCIe + 以太網」？RTL 的具體信號接口和 BFM 需要等 DUT 信息後確定。V1 只實現角色/模式框架與配置，DUT 橋和 monitor 在 V3 落地。

---

## 3. 業務模板與參數

### 3.1 內置業務

| 名稱 | QP 類型 | 允許的 op | 默認狀態 |
|---|---|---|---|
| `send` | RC | SEND、SEND_IMM | 開 |
| `write` | RC | WRITE、WRITE_IMM | 開 |
| `read` | RC | READ | 開 |
| `atomic` | RC | CMP_SWAP、FETCH_ADD | 開 |
| `ud` | UD | SEND、SEND_IMM | 開 |
| `urc` | RC（URC 模式） | SEND、WRITE、WRITE_IMM | 開（兩端都是本地 Function 時） |

### 3.2 參數命名

```
+rdma.env.<名稱>                    環境級
+rdma.biz.en=send,write             啟用的業務列表（不給 = 全部內置業務）
+rdma.biz.<業務>.qp.<字段>           QP 參數
+rdma.biz.<業務>.mem.<字段>          內存參數
+rdma.biz.<業務>.pkt.<字段>          報文屬性
+rdma.biz.<業務>.trf.<字段>          流量參數
+rdma.biz.<業務>.qp={mtu=4096,depth=128}   緊湊寫法（aip schema）
```

例：

```bash
./simv +UVM_TESTNAME=rdma_env_biz_test +rdma.biz.en=write,read \
  '+rdma.biz.write.qp.mtu=[1024,2048,4096]' +rdma.biz.write.qp.psn=rand \
  '+rdma.biz.write.trf.len={[1:256]:/30,[257:8192]:/70}' +rdma.biz.write.trf.count=500 \
  +rdma.biz.write.pkt.vlan_en=1 +rdma.biz.write.pkt.vlan_id=100 \
  +rdma.biz.read.mem.buf_bytes=0x40000 '+rdma.biz.read.trf.sge=[1:4]'
```

### 3.3 V1 字段表

**qp**

| 字段 | 默認 | 約束 |
|---|---|---|
| `depth` | 0 = 繼承 `rdma.env.qp_depth`（256） | 用作 SQ/RQ/CQ 深度 |
| `mtu` | 0 = 繼承 `rdma.env.mtu`（1024） | 256/512/1024/2048/4096 |
| `max_sge` | 4 | 1~4 |
| `psn` | 0 | 0 ~ 0xFFFFFF |
| `qkey` | 0 = 繼承 `rdma.env.ud_qkey` | 僅 UD 使用 |
| `timeout` / `retry` / `rnr_retry` / `min_rnr` | -1 = 繼承環境默認（14 / 7 / 7 / 1） | 0~31 / 0~7 / 0~7 / 0~31 |

**mem**

| 字段 | 默認 | 約束 |
|---|---|---|
| `buf_bytes` | 0x20000 | ≥ mr_offset + 2 × slot_bytes × slots |
| `slot_bytes` | 0x1000 | 單條消息長度上限（UD 另受 MTU 限制） |
| `slots` | 8 | 輪轉使用的槽數 |
| `mr_offset` | 0 | MR 在 buffer 內的起始偏移 |
| `mr_remote_read` / `mr_remote_write` / `mr_remote_atomic` | 1 / 1 / 1 | MR 遠端權限；關閉後對應遠端訪問預測為 REM_ACCESS_ERR |

**pkt**（僅在帶幀編碼的鏈路上生效：netpkt、DUT）

| 字段 | 默認 | 說明 |
|---|---|---|
| `vlan_en` / `vlan_id` | 0 / 0 | 802.1Q 標籤 |
| `src_ip` / `dst_ip` | 0（沿用鏈路默認） | IPv4 地址，0 表示不覆蓋 |
| `udp_sport` | 4791 | UDP 源端口 |

**trf**

| 字段 | 默認 | 說明 |
|---|---|---|
| `count` | 32 | 本業務生成的消息數 |
| `w_<op>` | 允許的 op 均為 1 | op 權重，如 `w_send`、`w_write_imm`、`w_cas` |
| `len` | `[1:4096]` | aip 表達式，每條消息求值；原子固定 8 |
| `sge` | `[1:4]` | aip 表達式；原子固定 1 |
| `data_mode` | `RANDOM,FIXED,INCREMENT,PATTERN` | 候選列表，每條消息隨機選 |
| `signaled_pct` | 100 | signaled 比例 |
| `dir` | 2 | 0：f0→f1；1：f1→f0；2：隨機 |

> QP 訪問權限：設備模型目前只檢查 MR 權限，不檢查 QPC 的訪問標誌，因此 V1 用 `mem.mr_remote_*` 表達遠端權限；
> 是否按 IBTA 在模型中檢查 QP 訪問標誌留到 V2 決定。

---

## 4. 分版計劃

| 版本 | 內容 |
|---|---|
| **V1（本次）** | 配置根 + 模式/角色字段；業務模板與 aip 加載；QP 屬性 per-QP 化（ctrl/expect 讀 QP 自己的屬性）；netpkt 鏈路按 QP 報文屬性編碼；`rdma_biz_vseq` + `rdma_env_biz_test`；最終生效配置打印；構建支持 `AIP_CORE_ROOT`、`VCS_EXTRA_FLAGS`、本地運行腳本 |
| V2 | 故障規則統一；`rdma_dut_link` 改用模型報文 + QP 報文屬性；刪除 flow_plan；組件解耦（func 上下文對象、設備接口） |
| V3 | DUT 模式落地：PCIe/以太網橋、monitor、RM 影子、比較器（需 DUT 接口信息） |
| V4 | 獨立單元測試場景遷移、大文件拆分、verb 非阻塞 post |

# 实验2当前未纳入 full-ring baseline 的 Workload

| Workload | 原因 |
|---|---|
| B0 | NOP 在 full ring 中 opcode=0/flags=0 会被 unpack 当作填充哨兵；本项保留在 cp_engine 单元层。 |
| B3 | MEM_WRITE 需要补齐 full CP harness 的 host/device AXI 数据面模型和搬运校验。 |
| B4 | MEM_READ 需要补齐 full CP harness 的 host/device AXI 数据面模型和搬运校验。 |
| B5 | MEM_COPY 需要补齐 device AXI 双端模型和设备内存校验。 |
| B6 | EVENT_SIGNAL 需要补齐 event unit 的 device AXI 事件计数器模型。 |

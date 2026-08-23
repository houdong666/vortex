# CP Optimization Group Meeting - Design Spec

## I. Project Information

| Item | Value |
| ---- | ----- |
| **Project Name** | Vortex v3.0 CP 优化实验组会汇报 |
| **Canvas Format** | PPT 16:9 (1280×720) |
| **Page Count** | 15 |
| **Design Style** | B) General Consulting + 学术技术汇报 |
| **Target Audience** | 导师、课题组教师与实验室同学 |
| **Use Case** | 18–22 分钟组会汇报，解释研究动机、实现、验证、结果与后续影响 |
| **Created Date** | 2026-08-23 |

---

## II. Canvas Specification

| Property | Value |
| -------- | ----- |
| **Format** | PPT 16:9 |
| **Dimensions** | 1280×720 |
| **viewBox** | `0 0 1280 720` |
| **Margins** | 左右 56px，上 44px，下 38px |
| **Content Area** | 1168×638px |

---

## III. Visual Theme

### Theme Style

- **Style**: General Consulting + academic technology briefing
- **Theme**: Light theme
- **Tone**: 严谨、技术化、以结论和实验数据为中心

### Color Scheme

| Role | HEX | Purpose |
| ---- | --- | ------- |
| **Background** | `#F4F7FA` | 全局浅色背景 |
| **Secondary bg** | `#FFFFFF` | 数据区与局部信息块 |
| **Primary** | `#0B1F3A` | 标题、架构主线、关键模块 |
| **Accent** | `#1565C0` | Baseline、数据系列与链接 |
| **Secondary accent** | `#00A6A6` | 优化路径、优化后系列 |
| **Highlight** | `#F59E0B` | 性能收益和关键数字 |
| **Body text** | `#1F2937` | 正文 |
| **Secondary text** | `#5B677A` | 说明和注释 |
| **Tertiary text** | `#8A94A6` | 页脚和辅助标签 |
| **Border/divider** | `#D7DEE8` | 分隔线 |
| **Success** | `#138A5B` | PASS 与 Accept |
| **Warning** | `#D64545` | PPA 代价与 Reject |

不使用渐变，减少投影环境中的颜色漂移；每页不超过四种主色。

---

## IV. Typography System

### Font Plan

**Typography direction**: 现代中文无衬线一致型，代码使用等宽字体。

| Role | Chinese | English | Fallback tail |
| ---- | ------- | ------- | ------------- |
| **Title** | `Microsoft YaHei` | `Arial` | `sans-serif` |
| **Body** | `Microsoft YaHei` | `Arial` | `sans-serif` |
| **Emphasis** | `Microsoft YaHei` | `Arial` | `sans-serif` |
| **Code** | — | `Consolas`, `Courier New` | `monospace` |

**Per-role font stacks**:

- Title: `Microsoft YaHei, Arial, sans-serif`
- Body: `Microsoft YaHei, Arial, sans-serif`
- Emphasis: `Microsoft YaHei, Arial, sans-serif`
- Code: `Consolas, Courier New, monospace`

### Font Size Hierarchy

**Baseline**: Body font size = 20px。

| Purpose | Size | Weight |
| ------- | ---- | ------ |
| Cover title | 64px | Bold |
| Section / conclusion statement | 44px | Bold |
| Page title | 36px | Bold |
| Hero number | 40px | Bold |
| Subtitle | 26px | SemiBold |
| Body content | 20px | Regular |
| Annotation / caption | 15px | Regular |
| Page number / footnote | 12px | Regular |
| Code | 17px | Regular |

---

## V. Layout Principles

### Page Structure

- **Header area**: 82px，左对齐结论式标题，右上角放实验编号或章节标签。
- **Content area**: 560px，图表优先；正文用于解释因果而非重复图表。
- **Footer area**: 38px，显示 `Vortex CP Optimization`、页码和数据来源。

### Layout Patterns

- 架构页使用横向数据通路或分层架构。
- 原因分析页使用左侧问题、中央机制、右侧影响的因果链。
- 实现页使用“原始路径 vs 优化路径”或关键 RTL 状态映射。
- 结果页以主图占 65%～75%，右侧仅保留 2～3 条结论。
- 结论页使用决策矩阵，明确 Performance、Correctness、PPA 和 Integration 四类结论。
- 不连续使用三页相同卡片网格；穿插架构、流程、图表和大结论页。

### Spacing Specification

| Element | Current Project |
| ------- | --------------- |
| Safe margin | 56px |
| Content block gap | 30px |
| Icon-text gap | 12px |
| Card gap | 24px |
| Card padding | 24px |
| Card radius | 12px |
| Line-height | 1.45× body |

---

## VI. Icon Usage Specification

### Source

- **Built-in icon library**: `chunk-filled`
- **Usage method**: `<use data-icon="chunk-filled/icon-name" .../>`
- 全套演示只使用该实心几何图标库，不混用其他风格。

### Recommended Icon List

| Purpose | Icon Path | Page |
| ------- | --------- | ---- |
| 研究目标 | `chunk-filled/target` | 02, 15 |
| 性能与测量 | `chunk-filled/gauge-high` | 04, 13 |
| 执行快路径 | `chunk-filled/bolt` | 06, 07 |
| 数据与缓存行 | `chunk-filled/database` | 08, 09 |
| 预取流水 | `chunk-filled/layers` | 10, 11 |
| 正确性 | `chunk-filled/shield-check` | 05, 12 |
| 趋势图 | `chunk-filled/chart-line` | 11 |
| 对比图 | `chunk-filled/chart-bar` | 07, 09 |
| 代码实现 | `chunk-filled/code` | 06, 08, 10 |
| 分支与研究路线 | `chunk-filled/git-branch` | 14 |
| 结论通过 | `chunk-filled/checkmark` | 12, 15 |
| 时序代价 | `chunk-filled/clock` | 13 |
| 环形回绕 | `chunk-filled/arrows-repeat` | 09, 10 |
| 模块与资源 | `chunk-filled/box` | 03, 06 |
| 数据流方向 | `chunk-filled/arrow-right` | 03, 06, 10 |

---

## VII. Visualization Reference List

**Catalog read: 70 templates / 10 categories.**

**Runners-up considered**: `numbered_steps`（拒绝：不能表达各阶段的输入输出制品），`grouped_bar_chart`（拒绝：实验四和实验五都是二状态前后差，dumbbell更突出变化），`roadmap_vertical`（拒绝：后续研究方向存在依赖关系，process_flow比单纯时间轴更合适）。

| Visualization Type | Reference Template | Used In |
| ------------------ | ------------------ | ------- |
| 议程结构 | `templates/charts/agenda_list.svg` | P02 |
| CP分层架构 | `templates/charts/layered_architecture.svg` | P03 |
| Baseline CPC对比 | `templates/charts/bar_chart.svg` | P04 |
| 实验方法流水 | `templates/charts/pipeline_with_stages.svg` | P05 |
| Fast Path前后对比 | `templates/charts/dumbbell_chart.svg` | P07 |
| Packing流量对比 | `templates/charts/dumbbell_chart.svg` | P09 |
| Prefetch吞吐趋势 | `templates/charts/line_chart.svg` | P11 |
| 验证证据矩阵 | `templates/charts/feature_matrix_table.svg` | P12 |
| PPA集成决策 | `templates/charts/comparison_table.svg` | P13 |
| 后续研究路线 | `templates/charts/process_flow.svg` | P14 |

---

## VIII. Image Resource List

本演示不使用外部位图、网络图片或 AI 装饰图。所有架构图、流程图和图表均由真实代码与 CSV 数据生成原生 SVG，以确保数字准确、投影清晰和后续可编辑。

---

## IX. Content Outline

### Part 1: 研究问题与证据框架

#### Slide 01 - Cover

- **Layout**: 深蓝左侧标题区 + 右侧抽象CP流水线，留足负空间。
- **Title**: Vortex v3.0 Command Processor 优化实验
- **Subtitle**: 从瓶颈定位到可验证的 RTL 优化
- **Info**: 组会汇报｜2026.08

#### Slide 02 - 这项研究要回答什么

- **Layout**: 四个大问题组成议程，不按实验编号机械罗列。
- **Visualization**: agenda_list
- **Core statement**: 优化不是“改RTL”，而是建立瓶颈—机制—证据—决策闭环。
- **Content**:
  - 为什么CP值得优化？
  - 瓶颈位于执行、传输还是等待？
  - 如何证明收益不以正确性为代价？
  - 哪些优化值得继续集成和研究？

#### Slide 03 - CP位于Host与GPU执行资源之间

- **Layout**: 三层架构：Host控制层、每队列CPE层、共享执行资源层。
- **Visualization**: layered_architecture
- **Core statement**: CP前端任何停顿都会沿命令链传播，并限制GPU启动与数据搬运效率。
- **Content**: AXI-Lite寄存器、Ring Fetch/Unpack/Engine、KMU/DMA/DCR/Event与Completion。

#### Slide 04 - Baseline揭示三个不同层次的瓶颈

- **Layout**: 左侧B1/B2/B7/B8/B9 CPC横向条形，右侧三类瓶颈判断。
- **Visualization**: bar_chart
- **Core statement**: 单队列下仲裁等待为0，首阶段应优先处理Engine固定开销、Fetch流量和Host延迟。
- **Evidence**: B1 CPC 7.688，B2 10.688，B7 14.375；B2 DCR等待80 cycles，B7 KMU等待64 cycles。

#### Slide 05 - 统一实验方法：先证明正确，再讨论性能

- **Layout**: 五阶段横向流水，底部列出统一指标。
- **Visualization**: pipeline_with_stages
- **Pipeline**: Baseline → 定位 → 实现 → 回归 → PPA决策。
- **Metrics**: CPC、Cmd/Cycle、Fetch Bytes/Command、seqnum、drop/duplicate、Area、Fmax。
- **Correctness lesson**: 实验三证明DMA尾拍越界修复，但没有完整内存域证据时不能宣称“冲掉命令Ring”。

### Part 2: 三个关键优化实验

#### Slide 06 - 实验四：删除简单命令路径中的无效状态

- **Layout**: 上方原路径、下方快路径；右侧代码机制。
- **Core statement**: NOP不申请共享资源，DECODE对它是固定的一周期控制开销。
- **Implementation**: `ENABLE_NOP_FAST_PATH`；`S_IDLE`直接识别NOP并进入`S_RETIRE`；默认参数保持关闭。
- **Correctness**: 其他命令仍走DECODE/BID/WAIT_DONE，资源选择语义不变。

#### Slide 07 - Fast Path：CPC降低33.33%，但Fmax决定暂不默认集成

- **Layout**: 左侧CPC dumbbell，右侧性能/PPA决策。
- **Visualization**: dumbbell_chart
- **Evidence**: 3.0→2.0 CPC；0.333→0.500 Cmd/Cycle；100/1000/10000条均无丢失重复。
- **Tradeoff**: FPGA LC +4.27%，ASIC area -0.18%，Fmax proxy -6.43%。
- **Decision**: 功能Accept，默认集成Reject。

#### Slide 08 - 实验五：让64B Fetch承载多条短命令

- **Layout**: 一条64B缓存行的字节布局 + Runtime flush流程 + tail/seqnum语义分离。
- **Core statement**: DCR_WRITE有效载荷仅20B，单命令独占64B会浪费68.75%读取带宽。
- **Implementation**: Runtime追加紧凑命令；空间不足或批次结束时补零flush；`cp_tail_`按CL增长，`cp_expected_seqnum_`按命令增长。

#### Slide 09 - Packing：Fetch流量下降66.60%，吞吐不变同样是重要结论

- **Layout**: 左侧Bytes/Command dumbbell，右侧“收益/不变/原因”三层解释。
- **Visualization**: dumbbell_chart
- **Evidence**: 1000→334 CL；64000→21376B；64→21.376B/Command；seqnum仍为1000。
- **Interpretation**: 总周期仍为7011，因为本负载瓶颈在DCR执行/退役，而非Fetch带宽。
- **Impact**: Packing为高延迟、多队列和Prefetch研究降低前端流量压力。

#### Slide 10 - 实验六：把请求、响应缓存和消费解耦

- **Layout**: 三段流水图 + 两指针/FIFO状态解释。
- **Core statement**: 原设计必须“取回并消费当前行”后才能请求下一行，Host AXI延迟完全暴露。
- **Implementation**: `fetch_head_r`跟踪已请求位置，`head_r`跟踪已消费位置；2-entry CL FIFO；`request_count_r`记录在途请求。
- **Invariant**: `fifo_count + request_count < PREFETCH_DEPTH`，为每个在途响应预留槽位。

#### Slide 11 - Prefetch：延迟越高，吞吐越接近基线的2倍

- **Layout**: 双折线占主要区域，右侧三个关键数字。
- **Visualization**: line_chart
- **Evidence**: latency 1时+48.84%；20时+99.01%；100时+99.76%。
- **Correctness**: 64 AR、192命令、final_head=4096、drop/duplicate=0。
- **Interpretation**: 深度2把下一条CL读取与当前CL命令输出重叠，而非减少AXI本身延迟。

### Part 3: 验证、决策与研究影响

#### Slide 12 - 正确性不是一句“测试通过”，而是一组不变量

- **Layout**: 行为×实验矩阵。
- **Visualization**: feature_matrix_table
- **Rows**: 顺序、数量、seqnum、Ring wrap、边界、backpressure、长序列、相关模块回归。
- **Columns**: Fast Path、Packing、Prefetch。
- **Core statement**: 三项优化分别改变状态、布局和时序，但都必须保持命令级语义。

#### Slide 13 - 性能收益必须和PPA及适用场景一起决策

- **Layout**: 三实验对比表 + 右侧集成决策。
- **Visualization**: comparison_table
- **Fast Path**: 执行吞吐+50%，Fmax -6.43%，默认关闭。
- **Packing**: 流量-66.60%，当前DCR吞吐0%，Runtime能力保留。
- **Prefetch**: 高延迟吞吐近2×，ASIC area +10.87%，默认深度1。
- **Core statement**: 参数化保留优化能力，比不加区分地默认开启更符合工程研究。

#### Slide 14 - 三项优化形成端到端前端研究链

- **Layout**: 当前成果→近期研究→系统研究的依赖流程。
- **Visualization**: process_flow
- **Current**: Engine固定开销、Fetch字节效率、Host延迟隐藏。
- **Next**: Priority-aware Arbitration、Aging防饥饿、EVENT_WAIT公平性。
- **System**: 多队列、QMD式Launch、Packing+Prefetch组合收益、SimX/RTL周期一致性、XRT全链路验证。
- **Research impact**: 实验已经提供指标、可调参数、延迟模型和回归框架，后续工作可直接做增量对照。

#### Slide 15 - Conclusion

- **Layout**: 三个大结论 + 一条研究判断。
- **Conclusion 1**: CP瓶颈是分层的，不能用单一吞吐指标解释。
- **Conclusion 2**: Fast Path、Packing和Prefetch分别优化执行、数据布局和取指等待。
- **Conclusion 3**: 正确性、性能与PPA共同决定是否默认集成。
- **Closing statement**: 下一阶段应从单队列局部优化转向多队列资源竞争与组合优化。

---

## X. Speaker Notes Requirements

- 每页备注包括：开场句、核心逻辑、关键数字、代码落点、转场句。
- 每页控制在50～90秒；封面20秒、总结60秒。
- 结果页必须解释数字为何变化，不能只朗读表格。
- Packing页必须主动说明“吞吐不变不是实验失败”。
- PPA页必须区分模块级代理综合和完整实现结果，避免过度推断。
- 实验三只作为研究严谨性案例，不宣称已经验证真实Ring冲突。

---

## XI. Technical Constraints Reminder

1. 所有SVG使用 `viewBox="0 0 1280 720"`。
2. 背景用 `<rect>`；文本换行用 `<tspan>`。
3. 禁止 `rgba()`、`<style>`、`class`、`foreignObject`、`textPath`、`animate*`、`script`。
4. 禁止 `<g opacity>`；透明度写到具体元素。
5. 仅使用 `spec_lock.md` 中的颜色、字体与图标。
6. 图表数据必须逐项来自仓库CSV或实验文档，不做视觉性篡改。
7. XML保留字符必须转义；其他符号直接使用Unicode。
8. 每页顶层视觉单元使用有意义的 `<g id="...">`，支持PPT对象动画与编辑。

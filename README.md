# 战舰世界船只Q弹Mod（WG/Lesta服）

核心动画效果相同，请按照你的游戏客户端选择安装包

| 游戏客户端 | 下载 | 使用说明 |
| --- | --- | --- |
| **WG服** | [下载WG版](https://github.com/JellyWarships/JellyShips-WG-Lesta/releases/download/wg/JellyShips-WG.zip) | [安装与设置](WG/README.md) |
| **Lesta服** | [下载莱服版](https://github.com/JellyWarships/JellyShips-WG-Lesta/releases/tag/lesta-26.11.1) | [安装与设置](Lesta/README.md) |

原曲的DJ版在多个段落有节拍跳变，仓库里的两份音频已剪辑并按130BPM对齐节拍，目前用于Lesta版（2026.11.21）。[朋友的酒（DJ版）](朋友的酒（DJ版）.mp3)、[邦友的酒](邦友的酒.flac)

WG版由**电棍Anno**制作，由本仓库代为发布。莱服版沿用WG版动画，由本仓库适配和维护。[效果演示](https://www.bilibili.com/video/BV1NpWB6LESD/)、[安装与设置教程](https://www.bilibili.com/video/BV1FWs66jEZg/)

项目自有源码和文档采用[MIT许可证](LICENSE)。[署名与第三方许可](THIRD_PARTY_NOTICES.md)、[反馈与贡献](CONTRIBUTING.md)

## 本fork实现了：Lesta服务器全皮肤可Q弹，无论搭载什么皮肤，是否原皮

[`Q弹MOD_莱斯塔RU_全皮肤可弹/`](Q弹MOD_莱斯塔RU_全皮肤可弹/) 做的是同一件事（果冻船体），但实现路子完全不同：不经过「莱斯塔-保持Q弹」启动器，直接把 `res_mods/PnFMods/QtanLive` 覆盖进客户端。适用莱斯塔俄服 26.11 / 客户端 8871067。

安装：把包里的 `res_mods` 合并进 `Korabli\bin\8871067\res_mods`（覆盖同名项），进港口就能看到效果。细节见包内 [安装说明.txt](Q弹MOD_莱斯塔RU_全皮肤可弹/安装说明.txt)。

### 怎么实现的

接管游戏里 `Hull` 类的构造函数，船体一创建就把它的 `hull.model` 登记下来，然后用 `BigWorld.callback(0.0, ...)` 每帧（约 59 Hz）重写 `model.localMatrix`：把矩阵拆成位置、缩放、朝向三段，只改缩放，再用 `Math.Matrix.setPosScaleRotateRPY` 拼回去。位置和朝向原样保留，所以船不会被推走、也不会被转歪。

有两个坑决定了它稳不稳：

- **必须每帧写**。港口客户端自己每帧重写一次 `localMatrix`，只写一次会被立刻盖掉，表现成船在两个尺寸之间闪。
- **不能用 `postMultiply` 去乘缩放**。那样会把平移分量一起乘进去，船直接跑偏。

变形曲线照原版 `.seq` 的阻尼振铃来做：两个水平轴一拉一压，上下轴不动。哪一维算"上"由模型包围盒自动判断（最小的一维当高度），所以不挑船型、不挑涂装，港口船和战斗里的队友、敌方船都会生效——这正是"全皮肤"的意思。

### 功能简介

- 装完即生效，不用进设置：港口持续 Q 弹，战斗里同样。
- 整船拉宽 / 压高的呼吸式形变。26.11 的分段模型不参与渲染，拿不到原版那种分段错开的形变，这点和启动器版不同。
- 分 1 / 5 / 8 / 12 四档，同时只能装一个（两份会抢同一个矩阵，表现为闪烁）。本包是 12 倍档。
- 运行日志在 `res_mods/PnFMods/QtanLive/qtan_live.txt`；卸载就删掉 `QtanLive` 整个文件夹。

### 怎么改 Q 弹值

改 `res_mods/PnFMods/QtanLive/qtan_live_config.txt`，重启游戏生效：

| 参数 | 作用 | 范围 | 本包 |
| --- | --- | --- | --- |
| `amplitude` | 拉伸幅度，一个轴 +a、另一个 −a | 0 ~ 0.95 | 0.920 |
| `period` | 一次振铃的周期（秒） | 0.15 ~ 3.0 | 0.55 |
| `damping` | 阻尼，越大衰减越快、越"闷" | 0 ~ 12 | 2.4 |
| `lean_deg` | 额外左右摇摆（度） | −8 ~ 8 | 5.0 |
| `axes` | `auto` 自动判断，也可写 `0,1` / `1,0` 强制 | — | auto |

`amplitude` 别超过 0.95，再大物体会翻过来；原版 Q弹 的 `period` 是 0.46。改坏了就删掉这个文件，程序会退回代码里的默认值。

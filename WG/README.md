# WG服

整舰Q弹、起火/进水表现和船尾航迹可通过桌面工具独立切换。原作者为电棍Anno。[效果演示](https://www.bilibili.com/video/BV1NpWB6LESD/)

## 安装与设置

**[安装与设置教程视频](https://www.bilibili.com/video/BV1FWs66jEZg/)**

1. [下载WG版完整版](https://github.com/kekaotongzhi-glitch/JellyShips-WG-Lesta/releases/download/wg/JellyShips-WG.zip)，解压后打开“Q弹MOD_完整版合集”。外层文件名叫`JellyShips-WG.zip`，包内目录和作者演示使用的相同。
2. 退出游戏。打开“解压进resmods”里的ZIP，将`PnFMods`和`PnFModsLoader.py`放入当前客户端的`bin\<构建号>\res_mods`。已有共享加载文件时保留现有文件。
3. 将整个“开关”文件夹放到方便的位置，双击`switch.bat`。选择想切换的项目后选“应用”，下次启动游戏时生效。

“给Aslain”和“语音包”有各自的安装方式，按包内的《使用说明.txt》操作。Aslain重新部署后会恢复默认开关状态。

[WG发布页](https://github.com/kekaotongzhi-glitch/JellyShips-WG-Lesta/releases/tag/wg)也提供手动安装、Aslain和语音的单独附件。跟着视频安装时选上方的完整版。

## 文件结构

`src/`保留WG版的Python注册脚本、动画文件和桌面开关。`assets/game-resources.zip`收纳模型、模型索引与航迹。手动包内层的运行文件可由`src/`中的`PnFModsLoader.py`、`PnFMods/`和资源ZIP合并得到，游戏资源沿用WG版的相对路径。

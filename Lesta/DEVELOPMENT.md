# 构建与资源

在Windows上使用Python 3.9或更高版本，并保留.NET Framework 4.x自带的C#编译器。要修改船形、设置工具或播放器，从对应的源码目录直接编辑。构建只写安装ZIP，游戏安装可以随后按玩家说明进行。

| 位置 | 内容 |
| --- | --- |
| `src/launcher/` | Windows EXE入口、安装、卸载和更新 |
| `src/mod/` | 莱服脚本入口、舰型注册、默认Beat.seq、出厂开关 |
| `src/editor/` | Windows设置工具、曲线编辑器、效果开关、舰艏SVG |
| `src/music/` | 场景日志、音频预约和淡出、两首歌曲的采样与拍点信息 |
| `assets/game-resources.zip` | 舰船模型绑定、动画、航迹和受损特效，条目路径相对Mod目录 |
| `assets/libraries.zip` | 预览和播放器的运行库，内含各依赖的许可和声明 |
| `release.json` | 适配的莱服构建、Mod修订号和GitHub发布源 |
| `README.md` | 玩家说明。构建从“二次开发”标题前的内容生成包内《使用说明.txt》 |

## 生成安装包

两首歌曲的剪辑母版独立保存。若手上是定稿的《邦友的酒》FLAC和《朋友的酒（DJ版）》MP3，把它们放在同一个音频目录，安装FFmpeg后运行：

```powershell
python build.py --audio "<音频目录>"
```

构建会核对音频指纹，再解码成游戏需要的WAV。FFmpeg未加入PATH时可用`--ffmpeg`指定程序路径。

若已有同版完整玩家包，可直接复用其中两首已对拍音轨。下面的命令读取旧包的音频，其他运行文件使用当前目录的源码与资源。

```powershell
python build.py --audio "D:\Downloads\26.11.0.zip"
```

也可以将这版玩家包里的`music/bangyou.wav`与`music/friends-dj.wav`放在同一个目录，用`--audio`指向该目录。两首歌均为48 kHz、双声道、16位PCM。拍点、采样帧数和曲名在`src/music/tracks.json`。默认输出到`dist/`，可用`--output`指定其他位置。

## GitHub Releases发布约定

在共用仓库的Lesta目录构建。源码保留`assets/`下的两个ZIP，构建直接读取，无需预先解压。玩家包的版本号由客户端版本的前两段和发布序号组成。`26.11`的首包为`26.11.0.zip`，同一客户端版本依次发`26.11.1.zip`、`26.11.2.zip`，换到`26.12`后从`26.12.0.zip`开始。`release.json`的`build`保留完整客户端构建，`revision`填写对应的发布序号。

在首个正式玩家包构建前，把`github_repository`填为公开仓库的`所有者/仓库`。开发包可以留空。用`lesta-<版本号>`创建Release，例如`lesta-26.11.0`，并上传同版本的ZIP。Release说明中加入一行`<!-- lesta-build: 26.11.1.0.8871067 -->`，把示例替换为包内的完整构建号。每次发包递增当前客户端版本的发布序号。发布后可用GitHub Releases API查看附件是否标为`uploaded`，并带有`size`和`sha256:`开头的`digest`。

更新器读取同一莱服安装的`game_info.xml`中客户端的`installed`，按序号选择该构建的最新正式包。它核对附件大小、GitHub返回的SHA-256和包内的版本和完整构建，验证后才启动安装。本地隔离验证可令`JELLYSHIPS_LOCAL_RELEASES`指向回环HTTP上返回同格式JSON的地址。下载地址须与本地索引同源。该设置仅供本机测试。

当前发布格式在`portable_format=1`的包中列出启动器组件和逐文件SHA-256，构建会检查文件名。附件字段见[GitHub Releases REST API](https://docs.github.com/en/rest/releases/releases#list-releases)。

## 离线核对船体覆盖

在本目录用Python 3.10或更高版本运行，指定待查包，并传入同一客户端构建导出的`GameParams_py3.data`、`assets.bin`和舰船覆盖审计JSON：

```powershell
python -B maintenance/check_coverage.py --package PLAYER.zip --gameparams GameParams_py3.data --assets assets.bin --audit coverage.json
```

同一构建重出包时可复用这三份输入。适配新客户端构建时重新导出并生成同构建覆盖审计。检查器核对构建号及审计输入指纹。用`--ref <Git修订>`可改查该修订中的源码资源，省略目标参数则查当前源码。用`--ship-id <数值ID>`可追加某艘舰的结果，用`--output <报告.md>`保存UTF-8清单。

检查标准为常规舰种在`start`、`upgradeable`、`special`、`specialUnsellable`、`ultimate`、`superShip`与`earlyAccess`组中的初始船体升级组件。舰船参数名、注册入口、原生船体路径和包内模型目标分别解析。共用原生船体的不同舰船ID分别检查注册。清单记录静态缺项和可确认的旧审计原因。

加上`--upgrades`可同时核对后续可装备船体。检查器从初始船体升级沿`ShipUpgradeInfo`的前置关系读取船体组件，按舰船ID和模型根合并记录，并逐项检查模型、LOD父级引用及根动画。报告列出与基础船体共用的装配，以及换装后使用其他模型根的装配。加上`--ship-id <数值ID>`可查看对应升级装配的绑定和动画路径。

报告的“战斗音乐覆盖”用同构建的`GameParams`将已注册且有模型映射的舰船对应到数值ID，并与`Main.py`的`MUSIC_SHIPS`对照。每个ID计一次，含仅有改模涂装绑定的舰船。补视觉覆盖后检查这一节，确保新增ID已加入且没有无对应视觉绑定的ID。战斗回调只能按舰船ID判断，无法区分同舰的船体和涂装。

## 修改与验证

改舰艏图时，让SVG原点位于舰身中线与静水面的交点。曲线以0到1表示一整个动画周期，预览和生成时用歌曲BPM或无歌方案的手动BPM换算时长，周期两端都是最扁姿态。应用时同时写出动画周期及战斗播放器使用的BPM和鼓点帧。战斗音乐以本场开战事件为零点，船形偏移与音频输出补偿在播放器中分别处理。两首内置音轨沿用各自的参考拍点与原采样速度。

自选曲库位于启动器旁的`玩家数据\Songs`。每首歌用独立ID关联方案与已应用设置，保存一份48 kHz、双声道、16位PCM音频和一份含参考BPM、鼓点采样帧及估拍状态的元数据。NCM导入先在待导入目录临时提取MP3或FLAC，随后与其他格式共用Windows Media Foundation转码，临时文件在导入结束时清理。估拍读取解码后的PCM，自动保存主要节拍候选。旧曲库保留已修改的校准。升级会分析当前已应用方案的旧节拍占位，其他方案首次打开时分析。未取得拍点时使用130 BPM和零帧作为预览和导出的备用节拍。曲库留在玩家本机，安装器替换游戏目录时可继续用原ID查找。无歌方案应用时写入songless标识和自定BPM。旧设置缺少曲目标识时沿用默认曲，已绑定曲目丢失时保留原动画速度。构建只打入两首内置曲目。NCM格式实现参考[ncmdump](https://github.com/taurusxin/ncmdump)，许可随包提供。

船高曲线的纵坐标对应两端宽高间的同一个姿态比例。无声预览、配乐预览和`Beat.seq`生成共用该曲线。序列在关键点分别写入进、出切线，以保留折角和停顿。r2自定义速度曲线仍按原方法求值和保存，转为可拖动的船高曲线时才拟合为分段曲线。

战斗播放需要本舰覆盖标记和开战事件。港口加载会清除已结束的战斗状态。旧版自动模式Game在升级时映射到Battle。

要调整某艘舰的资源，打开`assets/game-resources.zip`，按原有模型路径查找和替换条目，然后重新构建。游戏按原有路径查找安装后的资源。新构建先在单独的目录核对，再按安装说明装入相同构建号的客户端。

玩家ZIP只有“莱斯塔-保持Q弹”一个顶层目录。首次打开时，入口准备“组件/资源包.zip”中的运行文件，完成后安装到当前构建的PnFMods。启动器从所在的bin、构建编号和res_mods目录向上定位本次游戏，核对game_info.xml及对应EXE。玩家数据和更新暂存均落在游戏内。旧版系统用户目录只用于玩家确认后的迁移或旧启动器清理。

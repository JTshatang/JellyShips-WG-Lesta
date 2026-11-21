# 署名与第三方许可

WG版由电棍Anno制作。莱服版由项目维护者和贡献者适配维护。[电棍Anno的GitHub主页](https://github.com/DiangunAnno)

项目自有的Mod源码、脚本和项目文档采用[MIT许可证](LICENSE)。游戏资源、第三方运行库、歌曲和语音包适用各自的许可或授权。

## 莱服版的第三方组件

| 组件 | 许可 | 随源码提供的声明 |
| --- | --- | --- |
| Svg.NET 3.4.8 | MS-PL | `Lesta/assets/libraries.zip`中的`preview-lib/Svg-license.txt` |
| ExCSS 4.2.3 | MIT | `Lesta/assets/libraries.zip`中的`preview-lib/ExCSS-license.txt` |
| System.Memory、System.Buffers、System.Numerics.Vectors、System.Runtime.CompilerServices.Unsafe | MIT | `Lesta/assets/libraries.zip`的`preview-lib/`目录中的许可证和第三方声明 |
| NAudio.Core、NAudio.Wasapi 2.2.1 | MIT | `Lesta/assets/libraries.zip`中的`music/NAudio-license.txt` |
| ncmdump的NCM读取实现 | MIT | [NCM读取实现的来源与许可](Lesta/src/music/NCM-LICENSE.txt) |

ncmdump和ExCSS 4.2.3的许可文件在对应的上游版本中使用了未填写的年份和姓名字段。随源码提供的许可原文按上游版本保留。[ncmdump许可原文](https://github.com/taurusxin/ncmdump/blob/ccff2dde9a3f6232cef00ab81e49b6cc50bc2c16/LICENSE.txt)、[ExCSS 4.2.3许可原文](https://github.com/TylerBrinks/ExCSS/blob/v4.2.3/license.txt)

## 游戏资源和音频

WG版和莱服版的`assets/game-resources.zip`包含游戏相关模型、索引、动画绑定或特效资源。游戏资源及商标按相应权利人的条款使用。

WG版的可选语音包与莱服版的两首内置歌曲属于单独的音频内容，适用相应权利人的授权。莱服源码提供曲目信息和拍点数据，构建完整玩家包时需要另备音频输入。[莱服构建说明](Lesta/DEVELOPMENT.md)

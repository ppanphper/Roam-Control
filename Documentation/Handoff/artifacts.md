# 资料和证据索引

## 已迁入本项目

| 文件 | 作用 |
|---|---|
| `evidence/package-manifest.json` | 原/改 IPA、主程序哈希、允许删除集合和逐条目校验，移除了旧机器路径 |
| `evidence/standalone-success-diagnostic.txt` | 助手当时导出的连接检查原文，无坐标或配对密钥 |
| `evidence/verification.json` | 区分助手验证、用户反馈与未知项的时间线 |
| `evidence/version-baselines.json` | 当前 fork、MIT 历史提交、官方版本和核查来源 |
| `evidence/file-checksums.json` | 迁入证据的 SHA-256，便于检测后续改动 |

这里的资料足够进行第一轮源码/公开功能对齐。为避免重复仓库源码和混入设备私密资料，完整 IPA、原始日志、配对/签名材料未加入 Git。

## 需要深入追溯时的本机原始资料

旧资料目录仍保留，未移动或删除：

```text
~/Documents/Codex/2026-11-17/looking-directly-at-the-camera-face/
```

以下路径相对于该目录：

| 路径 | 内容 |
|---|---|
| `work/wloc-investigation/wloc-original.ipa` | 原始带隧道 wloc 1.2.1 IPA |
| `outputs/wloc-1.2.1-LocalDevVPN-2026-11-17_23-27-27.ipa` | 已使用的外部隧道版；手机文件名为 `wloc-LocalDevVPN-20261117.ipa` |
| `outputs/2026-11-17-wloc-tunnel-report.md` | 初次 entitlement/profile/系统错误排查 |
| `outputs/2026-11-17-wloc-sidestore-networkextension-report.md` | SideStore/SideSign 对应版本源码核查 |
| `outputs/2026-11-17-wloc-free-path-report.md` | 外部路径的函数定位与构包方法 |
| `outputs/2026-11-18-wloc-free-install-verification.md` | 后续独立版安装/连接验证；早于用户容器版反馈 |
| `outputs/2026-11-17-wloc-privacy-and-resigning-report.md` | 统计、搜索、反查路径与未验证项 |
| `work/wloc-privacy/roamcontrol-arm64.asm` | 原始主程序 ARM64 反汇编 |
| `work/wloc-privacy/function-*.asm` | 关键函数摘录 |
| `work/wloc-free-path/build_external_ipa.py` | 仅删除 WlocTunnel 的原始构包脚本 |
| `outputs/2026-11-18-wloc-source-options.md` | 找到历史源码时的核查，尚不知道用户已有此 fork |
| `outputs/RoamControl-0.9.0-Build29-MIT-source-0654d132.zip` | 额外下载的 MIT 历史快照；当前仓库已有同源代码，无需再导入 |

原包 SHA-256：`a3f77f2a5656caa5efef0273dd097ff3e37369dfd6b23c0e6e523cdc3d50244c`

外部版 SHA-256：`3c151fe6dc56005256bc12ec452e14e40d3774e57ae568a14a6fd3dfc529a267`

主 Mach-O SHA-256：`a854dd0f1f6bb5251e43aa849d55e4975bf4fe3c00acffcb04e700431bd7b441`

仅需要旧证据时按表定位，不把旧目录整包上传或加入项目。某些旧报告写的是当时“尚未安装/尚未测试”的状态，最终状态以本目录 README 和验证时间线为准。

# Codex Pets

一个 Windows 桌面宠物小工具，用来预览和运行 Codex 风格的宠物动画。项目包含一个 WPF 版桌面宠物启动脚本、一个 Tkinter/Pillow 版预览程序、宠物帧缓存、资源生成记录和单元测试。

## 功能

- 自动发现本机 `~/.codex/pets` 和项目内 `desktop_pet/pets` 目录下的宠物资源。
- 支持 Codex 宠物 spritesheet 的多状态动画，包括 idle、running、waving、jumping、failed、waiting、review 等状态。
- 右键菜单可切换宠物、动画状态和缩放比例。
- 会记住最近选择的宠物和缩放设置，配置保存在 `desktop_pet/config.json`。
- 附带 `liuying` 宠物生成素材、提示词、参考图和帧缓存。

## 项目结构

```text
desktop_pet/
  app.py                         # Tkinter/Pillow 版宠物预览程序
  run_desktop_pet_wpf.ps1         # WPF 版桌面宠物主启动脚本
  open_pet.cmd                    # 默认启动入口
  open_pet_preview.cmd            # 居中、显示任务栏的预览启动入口
  open_pet_debug.cmd              # 带调试背景/边框的启动入口
  config.json                     # 当前宠物与缩放配置
  cache/frames/                   # 从 spritesheet 提取的动画帧缓存
  liuying/                        # 宠物生成素材、提示词和参考图
  scripts/extract_idle_frames.py  # 帧提取脚本
tests/
  test_*.py                       # 单元测试
```

## 运行

在 Windows 上双击或从 PowerShell 运行：

```powershell
desktop_pet\open_pet.cmd
```

预览模式：

```powershell
desktop_pet\open_pet_preview.cmd
```

调试模式：

```powershell
desktop_pet\open_pet_debug.cmd
```

也可以直接调用主脚本并指定参数：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\desktop_pet\run_desktop_pet_wpf.ps1 -Scale 0.6 -Center -ShowTaskbar
```

可用缩放比例：

```text
0.5, 0.6, 0.75, 1.0, 1.25, 1.5, 2.0
```

## 宠物资源

程序会优先扫描以下位置：

```text
%USERPROFILE%\.codex\pets
desktop_pet\pets
```

每个宠物目录应包含 `pet.json` 和对应的 spritesheet 文件。`pet.json` 中常用字段包括：

```json
{
  "id": "pet-id",
  "displayName": "Pet Name",
  "description": "Short description",
  "spritesheetPath": "spritesheet.webp"
}
```

## 测试

项目测试依赖 Pillow。可以用 `uv` 临时安装依赖并运行测试：

```powershell
uv run --with pillow python -m unittest discover -s tests
```

当前测试覆盖宠物发现、帧提取和缩放设置。

## GitHub

仓库地址：

https://github.com/ninhua/codex-pets

## TODO

- 后续考虑接入 Codex 状态信息，但当前版本暂不实现。
  - 首选方案：增加本地状态桥，例如 `desktop_pet/status.json`，由外部脚本或未来 Codex 集成写入 `idle`、`running`、`waiting`、`review`、`failed` 等状态，桌宠只负责监听并切换动画。
  - 备选方案：研究 Codex App Server / JSON-RPC 是否有稳定、公开、可授权的状态接口。
  - 不推荐方案：通过进程名、窗口标题或日志内容猜测 Codex 状态，因为容易误判且版本升级后容易失效。

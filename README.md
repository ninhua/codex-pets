# Codex Pets

一个 Windows 桌面宠物小工具，用来预览和运行 Codex 风格的宠物动画。项目包含一个 WPF 版桌面宠物启动脚本、一个 Tkinter/Pillow 版预览程序、宠物帧缓存、资源生成记录和单元测试。

## 功能

- 自动发现本机 `~/.codex/pets` 和项目内 `desktop_pet/pets` 目录下的宠物资源。
- 支持 Codex 宠物 spritesheet 的多状态动画，包括 idle、running、waving、jumping、failed、waiting、review 等状态。
- 右键菜单可切换宠物、动画状态和缩放比例。
- 会记住最近选择的宠物和缩放设置，配置保存在 `desktop_pet/config.json`。
- 可记录最近前台应用/窗口标题活动，右键开启 AI 发言后会用这些活动生成更自然的短句。
- 右键菜单保持轻量，低频选项集中到 `设置` 窗口里。
- 单击宠物且未拖动时会打开聊天窗口，可和宠物对话。
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
  activity_log.jsonl              # 最近活动记录，运行时按需生成
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

## AI 互动

默认不开启联网 AI。要让宠物使用 DeepSeek 或其他 OpenAI-compatible API 发言：

1. 在右键菜单打开 `设置...`，直接填写 API Key、Endpoint 和模型；也可以设置环境变量 `DEEPSEEK_API_KEY`。
2. 保持默认配置，或按需修改：

```json
{
  "aiEnabled": false,
  "aiEndpoint": "https://api.deepseek.com/chat/completions",
  "aiModel": "deepseek-v4-flash",
  "aiApiKey": ""
}
```

3. 在设置窗口勾选 `开启 AI 发言` 并保存。

AI 上下文来自本地最近活动记录，只包含时间、前台进程名、窗口标题和本地推断消息；当前版本不截图、不 OCR、不上传屏幕图像。单击宠物且未拖动时会打开聊天窗口，聊天同样会参考最近活动摘要。

### 缓存与费用优化

DeepSeek 的上下文硬盘缓存会自动工作，命中关键是后续请求从第 0 个 token 开始复用相同前缀。因此桌宠的 AI 请求采用以下布局：

- 固定人格和任务规则放在最前面的 `system` 消息里，尽量保持长期不变。
- 最近窗口标题、活动摘要等动态内容放在最后，避免破坏可复用前缀。
- 聊天时保留稳定的多轮历史顺序，只把最近活动附加到当前这一轮用户消息末尾。
- 每次 API 返回的缓存命中信息会写入 `desktop_pet/ai_usage_log.jsonl`，字段包括 `promptCacheHitTokens`、`promptCacheMissTokens` 和 `promptCacheHitRate`。

如果你频繁修改 `aiModel`、固定人格提示词或系统规则，缓存命中率会下降；普通聊天和活动变化主要发生在尾部，对前缀缓存更友好。

## 宠物资源

流萤宠物已经制作完成，最终 Codex 宠物包位于：

```text
desktop_pet/liuying/final/
  pet.json
  spritesheet.webp
  validation.json
```

QA 文件位于：

```text
desktop_pet/liuying/qa/
  contact-sheet.png
  previews/*.gif
  review.json
  run-summary.json
```

`validation.json` 和 `review.json` 均为通过状态，最终 spritesheet 为 Codex 兼容的 `1536x1872` WebP 图集，单格尺寸为 `192x208`。

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

## 安装流萤宠物

### 安装到本项目桌宠

如果只想让这个仓库里的桌宠程序加载流萤，可以把完成包复制到项目内 `desktop_pet/pets/liuying`：

```powershell
New-Item -ItemType Directory -Force .\desktop_pet\pets\liuying
Copy-Item .\desktop_pet\liuying\final\pet.json .\desktop_pet\pets\liuying\pet.json -Force
Copy-Item .\desktop_pet\liuying\final\spritesheet.webp .\desktop_pet\pets\liuying\spritesheet.webp -Force
```

然后启动：

```powershell
.\desktop_pet\open_pet.cmd
```

右键宠物，在宠物列表中选择 `流萤 [Local]`。

### 安装进 Codex

Codex 桌宠资源目录通常是：

```text
%USERPROFILE%\.codex\pets
```

把流萤复制到 Codex 的宠物目录：

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.codex\pets\liuying"
Copy-Item .\desktop_pet\liuying\final\pet.json "$env:USERPROFILE\.codex\pets\liuying\pet.json" -Force
Copy-Item .\desktop_pet\liuying\final\spritesheet.webp "$env:USERPROFILE\.codex\pets\liuying\spritesheet.webp" -Force
```

安装完成后目录应类似：

```text
%USERPROFILE%\.codex\pets\liuying\
  pet.json
  spritesheet.webp
```

重启 Codex 或刷新宠物列表后，选择 `流萤` 即可使用。

### 校验安装

确认 Codex 目录中有两个文件：

```powershell
Get-ChildItem "$env:USERPROFILE\.codex\pets\liuying"
```

也可以检查 `pet.json` 内容：

```powershell
Get-Content "$env:USERPROFILE\.codex\pets\liuying\pet.json" -Encoding UTF8
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
- 后续考虑本地 OCR 内容理解，但当前版本暂不实现。
  - 目标：在用户明确开启后，仅对当前前台窗口做本机 OCR，识别可见文字并判断聊天、网页主题、终端错误、文档内容等。
  - 隐私约束：不联网、不上传、不持久保存截图；截图只作为临时内存/临时文件输入，用完即清理。
  - 优先后端：Windows.Media.Ocr；若不可用，再考虑用户手动安装本地 Tesseract。

# ZeusBridge

macOS CLI：读取 TtMan / zeus 插件左上角 **DTC 色块**（`ZUFrame_0..4`），解码按键并 `CGEvent` 注入。

协议对应插件：`core/api/compatibility.lua`（`DataToColor` / `SetKeyPixel` / `DEFAULT_KEY_POOL`）。

仓库：https://github.com/helaobibi/ZeusBridge

## 本地不需要 Xcode

用 **GitHub Actions** 编译，下载 Artifact 即可。

1. Push 到本仓库（或手动 **Actions → Run workflow**）  
2. 打开 **Actions** → workflow **ZeusBridge macOS** → 等成功  
3. 下载 artifact **`ZeusBridge-macOS`**  
4. 解压后按下方权限与用法操作  

## 权限

系统设置 → 隐私与安全性：

| 权限 | 用途 |
|------|------|
| **屏幕录制** | 截取魔兽窗口色块 |
| **辅助功能** | 注入键盘事件 |

建议运行 **`ZeusBridge.app`**（比裸二进制更容易出现在权限列表里）。

若提示已损坏 / 无法打开：

```bash
xattr -dr com.apple.quarantine ZeusBridge.app
xattr -dr com.apple.quarantine zeus-bridge
```

## 用法

```bash
# 列出窗口（确认能看到魔兽）
./zeus-bridge --list-windows

# 只解码、不按键（联调必用）
./zeus-bridge --dry-run -v

# 正式注入
./zeus-bridge

# 常用参数
./zeus-bridge --interval-ms 40 --cell-size 3
./zeus-bridge --title-regex 'World of Warcraft|WoW|Classic'
./zeus-bridge --origin-x 0 --origin-y 0
./zeus-bridge --unify-left-modifiers   # 右修饰键改左，部分 Mac 客户端更稳
```

### 状态处理

| state | 行为 |
|-------|------|
| 0 | 输入焦点，不按键 |
| 1 | 单击绑定键（`rcl-f1` 等） |
| 3 | **按住**直到色块清空 |
| 5 | Macro_AI：按 TNum/ANum 连打 4 次 `RALT+NUMPAD*` |

`.app` 内二进制：

```bash
./ZeusBridge.app/Contents/MacOS/ZeusBridge --dry-run -v
```

## 联调步骤

1. 魔兽 **窗口模式**（不要先上独占全屏）  
2. 加载插件（对外名 EpicMusicBox / 对内 zeus），确认循环已绑定技能  
3. `--dry-run -v`：应出现 `calibrated` / `anchor OK`  
4. 循环跑技能时，日志类似：`[dry-run] rcl-f1 → RCTRL+F1`  
5. 去掉 `--dry-run`，并保证魔兽在前台  

## 协议摘要

| Slot | 含义 |
|------|------|
| 0 | data_num |
| 1 | state：0=有输入焦点勿按；1=单击；3=按住；5=AI（v1 只打日志） |
| 2 | key1（如 `rcl`） |
| 3 | key2（如 `f1`） |
| 4 | 锚点整数 `2000001` |

完整 sendkey：`key1-key2`（例 `rcl-f1` → Right Control + F1）。

## 本地编译（可选）

```bash
swift build -c release
./scripts/package_app.sh
```

CI 见 `.github/workflows/macos.yml`。

## 说明

- 这是读屏 + 模拟键的自动化桥接，使用风险自负。  
- v1 不完整支持 Macro_AI（state=5）通道。  
- 若锚点一直失败：检查插件是否加载、UI 缩放、是否被别的框挡住左上角。  

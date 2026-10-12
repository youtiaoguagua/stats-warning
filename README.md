 # Stats Warning · MacBook Air 温度守护与高温提醒
 
 专为 **MacBook Air**（及轻薄 Mac）量身打造的原生极轻量菜单栏温度监控与预警工具。
 
 MacBook Air 采用无风扇被动散热设计，在长时间编译、AI 推理、重度渲染或高负载多任务时容易悄悄积热降频甚至外壳发烫。**Stats Warning** 专注在菜单栏安静守护，只在持续高温时发出原生横幅预警，帮你及时调整负载，保护电池与手感体验。
 
 ---
 
 ## 🌟 为什么 MacBook Air 用户需要它？
 
 - 🌬️ **无风扇设计贴身预警**：Air 没有风扇噪音提示，发热往往神不知鬼不觉。当 CPU / GPU 温度持续超过设定安全红线（例如 ≥ 70°C 持续 2 秒）时，第一时间弹出系统通知。
 - 🍃 **超低功耗与内存占用**：拒绝耗电大户！后台常驻仅 ~15MB footprint，无 Electron / WebView，纯原生 AppKit 打造，几乎不增加耗电与发热。
 - 📊 **实时温度与趋势曲线**：菜单栏直观展示实时温度，点击即开独立设置与温度曲线面板（支持 1 / 5 / 10 分钟趋势回顾），关闭窗口即销毁 UI 进程，完全不占多余资源。
 - 🎯 **防打扰与智能防抖**：短时间瞬时尖峰不误报，只有持续高温才提醒；降温后自动重置，避免频繁轰炸通知。
 
 ---
 
 ## 🚀 快速上手
 
 ### 1. 构建与运行
 
 无需安装庞大的完整 Xcode，仅需 Apple 命令行工具（`xcode-select --install`）：
 
 ```bash
 # 克隆项目
 git clone https://github.com/youtiaoguagua/stats-warning.git
 cd stats-warning
 
 # 编译应用 (Release 模式 + 本机签名)
 bash scripts/build-app.sh
 
 # 启动体验
 open dist/StatsWarning.app
 ```
 
 > **建议**：构建完成后将 `dist/StatsWarning.app` 拖入系统的 `/Applications`（应用程序）目录中日常使用。
 
 ### 2. 菜单栏操作
 
 - **左键点击**：打开/激活温度与设置控制面板。
 - **右键点击**：快速暂停提醒或直接退出应用。
 - **初次打开**：请按提示点击「允许通知」授权系统横幅提醒。
 
 ---
 
 ## ⚙️ 核心功能与参数调节
 
 | 设置项 | 默认值 | 调节范围 | 说明 |
 | :--- | :--- | :--- | :--- |
 | **温度阈值** | **70°C** | 30–120°C | 触发高温提醒的目标温度线 |
 | **持续高温时间** | **2 秒** | 0.5–600 秒 | 过滤瞬时峰值，只有持续高温才报警 |
 | **采样间隔** | **1 秒** | 0.5–60 秒 | 后台检测频率（支持 0.5s / 1s / 2s / 5s 快捷切换） |
 | **降温重置幅度** | **3°C** | 0–10°C | 比如默认降至 ≤67°C 才会解除警戒，防止临界值来回震荡通知 |
 | **提醒最短间隔** | **60 秒** | 0–3600 秒 | 同一轮持续高温下避免重复打扰的冷静期 |
 | **监控范围** | **CPU 最高温度** | CPU 最高 / CPU 平均 / GPU 最高 | 适配 M 系列多核及 GPU 传感架构 |
 
 ---
 
 ## 🔋 专为轻薄 Mac 优化的极简架构
 
 - **双进程分离架构**：
   - 后台主监控守护：常驻菜单栏、SMC 温度读取、阈值判断，占用极低。
   - 辅助设置窗口：按需启动，关闭窗口后 UI 辅助进程彻底退出并释放内存，两进程通过安全的 Unix Domain Socket 通信。
 - **开机自启原生支持**：采用现代 `SMAppService.mainApp` API 注册登录项，省心且无冗余常驻服务。
 - **只读 SMC 协议**：支持 Apple Silicon 与 Intel 芯片，只读取芯片温度，不写 SMC、不篡改硬件策略，安全无风险。
 
 ---
 
 ## 🛠️ 诊断与测试
 
 ```bash
 # 查看本机所有支持的 SMC 温度传感器
 dist/StatsWarning.app/Contents/MacOS/StatsWarning --probe
 
 # 运行采样性能基准测试
 dist/StatsWarning.app/Contents/MacOS/StatsWarning --benchmark --interval 1 --seconds 15
 
 # 运行单元测试
 swift test --disable-xctest --enable-swift-testing
 ```
 
 ---
 
 ## 📄 协议与致谢
 
 - 本项目采用 MIT 许可证。
 - 传感器读取参考了 [Stats](https://github.com/exelban/stats) 的 SMC 协议实现，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

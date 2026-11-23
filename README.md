# SimpleBrowser

基于 Swift 5、UIKit 与 WebKit (`WKWebView`) 打造的轻量级原生 iOS 浏览器，零第三方依赖，工程通过 XcodeGen 管理并在 GitHub Actions 上执行自动化测试与免签 IPA 构建。

## 主要功能

- **单手底部栏与多标签页**：底部地址栏与工具栏联动键盘弹出，支持标签网格预览、延迟会话恢复、渲染进程崩溃自愈以及内存告警下的后台标签休眠。
- **全屏与护眼模式**：支持完整全屏与保留状态栏两种全屏模式（双指长按退出），提供多级护眼遮罩。
- **广告过滤引擎**：支持订阅源与自定义规则；基于 `WKContentRuleList` 进行网络拦截（含分块与二分剔除不兼容规则容错）并注入 `Cosmetic` 元素隐藏规则，内置内存与规则库诊断清理。
- **用户脚本支持（油猴）**：自动识别 `.user.js` 安装与更新，支持 `@match`/`@exclude`/`@run-at` 元数据解析、`GM_getValue`/`GM_setValue`/`GM_xmlhttpRequest`/`GM_registerMenuCommand` 及分级权限控制的 `GM_cookie`。
- **站点数据与隐私治理**：支持按根域聚合查看站点存储与关联域名、锁定登录态 Cookie 免于清理、分域名独立配置拦截/脚本/全屏/证书信任。
- **下载、解压与备份**：集成 `WKDownload`、`Range` 断点续传下载器与前端 `blob:`/`data:` 导出；内置基于 `zlib` 的 `.zip`/`.gz` 解压器；支持 Netscape HTML 书签导入导出及基于 PBKDF2-HMAC-SHA256 + AES-GCM 的加密全量备份。

## 目录结构

- `Sources/`：应用源码（视图控制器、浏览器标签内核、广告引擎、下载/解压/备份/站点数据模块）。
- `Resources/`、`Assets.xcassets/`、`Info.plist`：启动屏、应用图标资源及权限配置。
- `Tests/`：核心逻辑单元测试（解压安全、广告规则解析、域名匹配、用户脚本匹配、加密备份）。
- `project.yml`：XcodeGen 工程定义文件。
- `.github/workflows/`：CI 测试、Release IPA 构建及历史运行清理工作流。

## 构建与测试

1. 安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：
   ```bash
   brew install xcodegen
   ```
2. 生成工程：
   ```bash
   xcodegen generate
   ```
3. 在 Xcode 中打开 `SimpleBrowser.xcodeproj`，或参考 `.github/workflows/build.yml` 运行单元测试与无证书签名构建。

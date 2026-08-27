# Releasing ForgeLoop

ForgeLoop 的发布链路：tag 触发 GitHub Actions → `Scripts/build-app.sh` 组装并签名 `.app` → hdiutil 打 DMG → notarytool 公证 + staple → Sparkle `generate_appcast` 生成 appcast → 全部上传到 GitHub Releases。用户端的 Sparkle 从 `releases/latest/download/appcast.xml` 拉更新。

## 前置条件（一次性）

1. Apple Developer 付费账号，持有 **Developer ID Application** 证书（Xcode → Settings → Accounts → Manage Certificates 可生成）。
2. App Store Connect API Key（<https://appstoreconnect.apple.com/access/integrations/api>，Users and Access → Integrations → App Store Connect API，角色 Admin 或 App Manager），下载 `.p8` 文件，记下 **Key ID** 和 **Issuer ID**。
3. Sparkle EdDSA 密钥对：**已生成**，私钥在本机 login keychain，公钥已写入 `packaging/Info.plist`（`SUPublicEDKey`）。
   - 查看公钥：`.build/artifacts/sparkle/Sparkle/bin/generate_keys -p`
   - **私钥不进仓库**。导出给 CI 用：
     ```bash
     .build/artifacts/sparkle/Sparkle/bin/generate_keys -x /tmp/sparkle_ed_key
     # 把文件内容（单行 base64）设为 GitHub secret SPARKLE_ED_KEY，然后立即删除文件
     rm /tmp/sparkle_ed_key
     ```
   - 换机器时在新机器重新导入该私钥：`generate_keys -f <keyfile>`；丢钥 = 必须换新密钥对并发版，否则老用户更新验签失败。

## GitHub Secrets 清单

在 <https://github.com/BiBoyang/ForgeLoop/settings/secrets/actions> 配置：

| Secret | 内容 | 怎么拿 |
| --- | --- | --- |
| `DEVELOPER_ID_CERT_P12` | Developer ID Application 证书（含私钥）导出 .p12 的 base64 | 钥匙串访问 → 右键导出 .p12（设密码）→ `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | 导出 .p12 时设的密码 | — |
| `ASC_API_KEY` | App Store Connect `.p8` 文件的 base64 | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `ASC_KEY_ID` | 10 位 Key ID | App Store Connect 页面显示 |
| `ASC_ISSUER_ID` | Issuer ID（UUID） | 同上页面顶部 |
| `SPARKLE_ED_KEY` | Sparkle EdDSA 私钥（单行 base64） | 见上面 `generate_keys -x` |

可选：无需 R2/Cloudflare/Homebrew——本仓库托管全部走 GitHub Releases。

## 发布步骤

```bash
# 1. 本地确认
swift build && swift test
./Scripts/release-check.sh

# 2. 打 tag 并推送（tag 即版本号，build 号 = commit 数，自动递增）
git tag v0.1.0
git push origin v0.1.0

# 3. 盯 workflow
gh run watch
```

成功后 GitHub Release 上会有 `ForgeLoop-<version>.dmg`（已公证 + staple）和 `appcast.xml`。老用户下次启动（或菜单 Check for Updates…）即可收到更新。

## 本地验证

```bash
# 组装 + ad-hoc 签名（不需要任何证书）
./Scripts/build-app.sh --host-only
open ./ForgeLoop.app

# 用真实证书做可公证的本地构建
./Scripts/build-app.sh --sign "Developer ID Application: Your Name (TEAMID)"
codesign --verify --strict --verbose=2 ./ForgeLoop.app
spctl -a -vv ./ForgeLoop.app   # 公证后才显示 accepted
```

验证点：

- `ForgeLoop.app/Contents/Frameworks/Sparkle.framework` 存在
- `otool -l ForgeLoop.app/Contents/MacOS/ForgeLoopApp | grep -A2 LC_RPATH` 含 `@executable_path/../Frameworks`
- `codesign -dv --verbose=4 ./ForgeLoop.app` 显示预期 identity
- 应用菜单里有 "Check for Updates…"（ad-hoc 本地构建也能点，只是 feed 未发布时会报"未找到更新"）

## 已知边界

- `SUPublicEDKey` 占位符状态下 Sparkle 验签必失败——当前已是真实公钥，若重做密钥对记得同步 Info.plist。
- SwiftPM 依赖若将来引入带资源的包（`Bundle.module`），release 会崩（termio v0.2.4 教训），`Scripts/build-app.sh` 头部注释有说明；目前唯一外部依赖 ForgeLoopTUI 无资源，不受影响。
- 不做 dev channel 双 bundle id（超 scope）。

# 04 — 密码学实现

## 1. 算法选型

| 用途 | 算法 | 来源 |
|---|---|---|
| 身份 DH（A 轨） | Curve25519 / libsignal | `omemo_dart_axolotl` |
| 身份 DH / 签名（B 轨） | X25519 / Ed25519 | `cryptography` (Dart) |
| 后量子 KEM | **ML-KEM-1024** (FIPS 203) | 纯 Dart `pqcrypto`；会话 PQXDH 另经 `libsignal` |
| 后量子签名 | ML-DSA-87 (FIPS 204) | 应用侧 `PqIdentityStore` |
| 对称加密（A 轨载荷） | AES-128-GCM | libsignal / Conversations 约定 |
| 对称加密（B 轨载荷） | AES-256-GCM / CBC+HMAC（随 omemo_dart） | `cryptography` / omemo_dart |
| KDF | HKDF-SHA512 | `cryptography` (Dart) |
| 哈希 | SHA-256 | `cryptography` (Dart) |
| 随机数 | `Random.secure()` / 平台 CSPRNG | — |

选择入口：`MlKem1024Provider`（`app/lib/crypto/pq/mlkem_provider.dart`，纯 Dart `pqcrypto`）。

## 2. Android 构建

日常：

```bash
cd app && flutter build apk
# 或仓库根：./scripts/build_android.sh
```

APK 不链接额外的 ML-KEM native 库；会话层 PQXDH/SPQR 走 `libsignal`（由 Flutter 插件打包）。

### 2.3 ABI 范围

```kotlin
ndk {
    abiFilters.clear()
    abiFilters += listOf("arm64-v8a", "x86_64")
}
```

- `arm64-v8a`：真机
- `x86_64`：模拟器

## 3. 纯 Dart 路径（`pqcrypto`）

OMEMO2 发布用密钥与测试均走 `PqcryptoMlKem1024` / `PqcryptoMlKem768`。

## 4. 密钥存储与生命周期

| 材料 | 存储位置 | 保护 |
|---|---|---|
| A/B 轨设备私钥 | 加密数据库（SQLCipher），口令由 Android Keystore 封存 | 硬件支持时用 StrongBox/TEE |
| 会话棘轮状态 | SQLCipher 数据库 | 每会话一行 |
| 消息历史 | SQLCipher 数据库（Web：Drift WASM → OPFS / IndexedDB） | 同库加密策略随平台 |

**聊天历史备份**：`backup_format.dart` 导出允许列表内的会话/消息等行（JSON 归档）；**不含** OMEMO 设备密钥与密封身份材料。换机后的密钥恢复仍依赖本机 Keystore / 重新建会话（密钥备份 UI 待做）。

## 5. 性能预期（arm64，参考值）

| 操作 | 预期耗时 |
|---|---|
| ML-KEM-768 keygen | 约 1–5 ms（纯 Dart） |
| ML-KEM-768 encaps/decaps | 约 1–5 ms（纯 Dart） |
| X25519 DH | < 1 ms |
| AES（1KB） | < 0.05 ms |
| 单条消息全流程（10 设备，含 10 次 KEM） | 约 10–30 ms |

首条 PQ 消息体积约为 `设备数 × 1.2KB`。

## 6. 依赖清单（`app/pubspec.yaml`）

主要依赖（版本以仓库为准）：

| 包 | 用途 |
|---|---|
| `moxxmpp` / `moxxmpp_socket_tcp` / `moxlib` / `omemo_dart` | XMPP + OMEMO（path） |
| `libsignal` | PQXDH / SessionCipher / SPQR（path → `libsignal_dart`） |
| `cryptography` | 经典密码学 |
| `pqcrypto` | 纯 Dart ML-KEM-1024 |
| `drift` + `sqlite3`（hooks → sqlcipher） | 加密数据库 |
| `flutter_secure_storage` | Keystore 侧口令 |
| `flutter_riverpod` / `riverpod` | 状态 |
| `http` / `file_picker` / `mime` / `open_filex` / `flutter_svg` | 网络与附件 UI |

## 7. 测试策略

| 层次 | 内容 |
|---|---|
| 单元 | PQXDH、KDF、ratchet、bundle 编解码、TrackResolver |
| KEM | `pqcrypto` round-trip（`mlkem_interop_test`；设备侧 `native_pq_test`） |
| 协议 | A/B 轨元素 round-trip；axolotl 方言 |
| 互操作 | Conversations 实测（A）；双账号跨服务器（B，`pq_interop.dart`） |
| 模糊 | 畸形 `<encrypted>` 不得崩溃 |
| 体积 | 不同设备数下 stanza 大小 |

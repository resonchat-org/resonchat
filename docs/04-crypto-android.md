# 04 — 密码学实现

## 1. 算法选型

| 用途 | 算法 | 来源 |
|---|---|---|
| 身份 DH（A 轨） | Curve25519 / libsignal | `omemo_dart_axolotl` |
| 身份 DH / 签名（B 轨） | X25519 / Ed25519 | `cryptography` (Dart) |
| 后量子 KEM | **ML-KEM-768** (FIPS 203) | Android：liboqs（FFI）；其他：`pqcrypto` |
| 后量子签名（可选） | ML-DSA-65 (FIPS 204) | liboqs（若启用） |
| 对称加密（A 轨载荷） | AES-128-GCM | libsignal / Conversations 约定 |
| 对称加密（B 轨载荷） | AES-256-GCM / CBC+HMAC（随 omemo_dart） | `cryptography` / omemo_dart |
| KDF | HKDF-SHA512 | `cryptography` (Dart) |
| 哈希 | SHA-256 | `cryptography` (Dart) |
| 随机数 | `Random.secure()` / 平台 CSPRNG | — |

选择入口：`MlKem768Provider`（`app/lib/crypto/pq/liboqs_mlkem.dart`）。能加载原生桥时 `isNative == true`，否则 `PqcryptoMlKem768`。

## 2. liboqs 在 Android 上的构建

自建 FFI：`pq_bridge.c` + 预构建静态库，由 `app/tool/build_liboqs.sh` 产出；`build_android.sh` 在缺库时调用。

### 2.1 目录

```
app/
├─ android/app/src/main/cpp/
│  ├─ CMakeLists.txt         # 链接 app/build/liboqs/${ABI}/liboqs.a
│  └─ pq_bridge.c            # 导出 C ABI：keygen/encaps/decaps
├─ build/liboqs/             # 构建产物（不进仓库）：每 ABI 一份 liboqs.a + headers
└─ tool/build_liboqs.sh      # NDK 交叉编译（--android-only 或完整含 KAT）
```

### 2.2 CMake（要点）

- `OQS_MINIMAL_BUILD` 限制算法面；链接预构建 `liboqs.a`，缺文件则 **FATAL_ERROR**（避免静默落到纯 Dart）。
- 导出符号显式 `visibility("default")`；其余 `-fvisibility=hidden`。
- Android 15：`-Wl,-z,max-page-size=16384`。

### 2.3 ABI 范围

```kotlin
ndk {
    abiFilters.clear()
    abiFilters += listOf("arm64-v8a", "x86_64")
}
```

- `arm64-v8a`：真机
- `x86_64`：模拟器

### 2.4 导出接口（C ABI）

```c
int  pq_mlkem768_keypair(uint8_t* pk /*1184*/, uint8_t* sk /*2400*/);
int  pq_mlkem768_encaps(const uint8_t* pk, uint8_t* ct /*1088*/, uint8_t* ss /*32*/);
int  pq_mlkem768_decaps(const uint8_t* sk, const uint8_t* ct, uint8_t* ss);
```

Dart 侧用 `dart:ffi` 打开 `libpqbridge.so`；从 native 缓冲区 **复制** 后再 `free`（避免 use-after-free）。

## 3. 纯 Dart 路径（`pqcrypto`）

用于 Web、单元测试、以及未打包原生桥的桌面构建：

```dart
// MlKem768Provider._resolve()
//   尝试 LiboqsMlKem（IO）→ 成功则 isNative
//   否则 PqcryptoMlKem768()
```

单元测试与 KAT / 互操作向量在两条实现上比对**共享秘密**（encaps 后 decaps 得同一 ss；密文本身不必相同）。

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
| ML-KEM-768 keygen | < 0.1 ms（native） |
| ML-KEM-768 encaps/decaps | < 0.1 ms（native） |
| X25519 DH | < 1 ms |
| AES（1KB） | < 0.05 ms |
| 单条消息全流程（10 设备，含 10 次 KEM） | 约 10–30 ms |

首条 PQ 消息体积约为 `设备数 × 1.2KB`。

## 6. 依赖清单（`app/pubspec.yaml`）

主要依赖（版本以仓库为准）：

| 包 | 用途 |
|---|---|
| `moxxmpp` / `moxxmpp_socket_tcp` / `moxlib` / `omemo_dart` | XMPP + OMEMO（path） |
| `cryptography` | 经典密码学 |
| `pqcrypto` | 纯 Dart ML-KEM |
| `ffi` | liboqs 桥 |
| `drift` + `sqlite3`（hooks → sqlcipher） | 加密数据库 |
| `flutter_secure_storage` | Keystore 侧口令 |
| `flutter_riverpod` / `riverpod` | 状态 |
| `http` / `file_picker` / `mime` / `open_filex` / `flutter_svg` | 网络与附件 UI |

## 7. 测试策略

| 层次 | 内容 |
|---|---|
| 单元 | PQXDH、KDF、ratchet、bundle 编解码、TrackResolver |
| FFI | liboqs 与纯 Dart 共享秘密一致（`mlkem_interop_test` / `native_pq_test`） |
| 协议 | A/B 轨元素 round-trip；axolotl 方言 |
| 互操作 | Conversations 实测（A）；双账号跨服务器（B，`pq_interop.dart`） |
| 模糊 | 畸形 `<encrypted>` 不得崩溃 |
| 体积 | 不同设备数下 stanza 大小 |

# 04 — 密码学实现（Android）

## 1. 算法选型

| 用途 | 算法 | 来源 |
|---|---|---|
| 身份 DH | X25519 | `cryptography` (Dart) |
| 身份签名 | Ed25519 | `cryptography` (Dart) |
| 后量子 KEM | **ML-KEM-768** (FIPS 203) | liboqs (FFI) |
| 后量子签名（可选） | ML-DSA-65 (FIPS 204) | liboqs (FFI) |
| 对称加密 | AES-256-GCM | `cryptography` 或 Android 硬件加速 |
| KDF | HKDF-SHA512 | `cryptography` (Dart) |
| 哈希 | SHA-256 | `cryptography` (Dart) |
| 随机数 | `Random.secure()` / `dart:math` 或 liboqs RNG | 平台 CSPRNG |

## 2. liboqs 在 Android 上的构建

若 `flutter_pqc` 包不能满足需求，则自建 FFI 绑定。

### 2.1 目录

```
app/
├─ android/app/src/main/cpp/
│  ├─ CMakeLists.txt
│  └─ pq_bridge.c            # 导出 C ABI：keygen/encaps/decaps
└─ third_party/liboqs/       # 以 git submodule 引入
```

### 2.2 CMakeLists.txt（草图）

```cmake
cmake_minimum_required(VERSION 3.22)
project(pqbridge C)

set(OQS_BUILD_ONLY_LIB ON CACHE BOOL "")
set(OQS_USE_OPENSSL OFF CACHE BOOL "")
set(OQS_MINIMAL_BUILD "KEM_ml_kem_768;SIG_ml_dsa_65" CACHE STRING "")
add_subdirectory(${CMAKE_SOURCE_DIR}/../../../third_party/liboqs liboqs)

add_library(pqbridge SHARED pq_bridge.c)
target_link_libraries(pqbridge oqs)
```

### 2.3 ABI 范围

```gradle
android {
    defaultConfig {
        ndk {
            abiFilters 'arm64-v8a', 'armeabi-v7a', 'x86_64'
        }
        externalNativeBuild {
            cmake { cppFlags '' }
        }
    }
}
```

- `arm64-v8a`：主力真机
- `x86_64`：模拟器
- `armeabi-v7a`：按需（liboqs 支持，但 32 位性能/体积不佳）

### 2.4 导出接口（C ABI 草图）

```c
int  pq_mlkem768_keypair(uint8_t* pk /*1184*/, uint8_t* sk /*2400*/);
int  pq_mlkem768_encaps(const uint8_t* pk, uint8_t* ct /*1088*/, uint8_t* ss /*32*/);
int  pq_mlkem768_decaps(const uint8_t* sk, const uint8_t* ct, uint8_t* ss);
int  pq_mldsa65_keypair(uint8_t* pk /*1952*/, uint8_t* sk /*4032*/);
int  pq_mldsa65_sign(const uint8_t* sk, const uint8_t* msg, size_t mlen, uint8_t* sig /*3309*/);
int  pq_mldsa65_verify(const uint8_t* pk, const uint8_t* msg, size_t mlen, const uint8_t* sig);
```

Dart 侧用 `dart:ffi` + `package:ffi` 封装，`DynamicLibrary.open('libpqbridge.so')`。

## 3. 纯 Dart 回退

为可测试性与未来的 Web 端，保留一条纯 Dart 路径：

- `pqcrypto`（FIPS 203 对齐的 ML-KEM 实现）
- 通过编译期开关或运行时探测选择实现：

```dart
abstract class MlKem {
  static MlKem get instance =>
      Platform.isAndroid || Platform.isIOS || Platform.isLinux || Platform.isWindows || Platform.isMacOS
          ? LiboqsMlKem()
          : DartMlKem(); // Web / 测试
}
```

> 单元测试与互操作向量测试必须在两条实现上结果一致。

## 4. 密钥存储与生命周期

| 材料 | 存储位置 | 保护 |
|---|---|---|
| IK_dh / IK_sig 私钥 | Android Keystore（`flutter_secure_storage`） | 硬件支持时用 StrongBox/TEE |
| SPK / OPK 私钥 | 加密数据库（SQLCipher），密钥由 Keystore 保护 | |
| PQSPK / PQOPK 私钥 | 同上 | ML-KEM 私钥最大 2400B，Keystore 不能直接存大对象，故用「Keystore 保护的对称密钥 + 加密数据库」方案 |
| 会话棘轮状态 | SQLCipher 数据库 | 每会话一行 |
| 消息历史 | SQLCipher 数据库 | 可选「不保存明文」 |

**备份/恢复**：导出加密的密钥备份（口令派生密钥 + AEAD），用于换机。多设备恢复依赖 PEP bundle 与 MAM，不依赖备份。

## 5. 性能预期（arm64，参考值，需实测）

| 操作 | 预期耗时 |
|---|---|
| ML-KEM-768 keygen | < 0.1 ms |
| ML-KEM-768 encaps/decaps | < 0.1 ms |
| ML-DSA-65 sign | ~1 ms |
| X25519 DH | < 1 ms |
| AES-256-GCM (1KB) | < 0.05 ms |
| 单条消息全流程（10 设备，含 10 次 KEM） | 约 10–30 ms |

结论：性能不是瓶颈，**体积**才是。首条消息体积约为 `设备数 × 1.2KB`。

## 6. 依赖清单（`app/pubspec.yaml` 草案）

```yaml
dependencies:
  flutter: { sdk: flutter }
  moxxmpp: { path: packages/moxxmpp }
  omemo_dart: { path: packages/omemo_dart }
  cryptography: ^2.7.0
  ffi: ^2.1.0
  drift: ^2.20.0
  sqlite3_flutter_libs: ^0.5.24
  sqlcipher_flutter_libs: ^0.7.0
  flutter_secure_storage: ^9.2.2
  riverpod: ^2.6.1
  go_router: ^14.0.0
  # UI
  photo_view: ^0.15.0
  cached_network_image: ^3.4.0
dev_dependencies:
  pqcrypto: ^0.4.0        # 测试用纯 Dart 实现
  test: ^1.25.0
  flutter_test: { sdk: flutter }
```

> 版本以实际 `flutter pub add` 结果为准；上表为撰写时的参考。

## 7. 测试策略

| 层次 | 内容 |
|---|---|
| 单元 | PQXDH 向量、KDF 向量、ratchet 步进、bundle 编解码 |
| FFI | liboqs 与纯 Dart 实现输出一致性（KEM 不保证密文相同，需比对**共享秘密**，即 encaps 后 decaps 得到同一 ss） |
| 协议 | A 轨与 B 轨的元素序列化/反序列化 round-trip |
| 互操作 | 与 Conversations/Moxxy 的真实会话（A 轨）；本客户端互连（B 轨） |
| 模糊测试 | 恶意/畸形 `<encrypted>` 输入不得导致崩溃 |
| 体积 | 统计不同设备数下的 stanza 大小，确认不超服务端限制 |

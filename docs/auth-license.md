# CrossLink — 授权与反盗版方案设计

> 目标：一次买断、硬件绑定、离线可用、防复制
> 版本：v1.0
> 日期：2026-06-14

---

## 1. 设计原则

1. **离线优先** — 激活后无需时刻联网，7 天校验一次
2. **硬件绑定** — License 绑定到物理机器，防止复制
3. **简单交付** — 用户拿到 Key → 粘贴激活 → 完成
4. **防滥用** — 限制设备数，异常检测
5. **可恢复** — 换电脑可申请重置

## 2. 密钥体系

### 2.1 算法选择

| 用途 | 算法 | 密钥长度 |
|------|------|----------|
| License 签名 | Ed25519 | 256 bit |
| 本地存储加密 | AES-256-GCM | 256 bit |
| 硬件指纹哈希 | SHA-256 | — |

选择 Ed25519 的原因：短密钥（32 字节私钥，64 字节签名），验签极快，Go 标准库 `crypto/ed25519` 原生支持。

### 2.2 密钥生命周期

```
你（开发者）持有私钥 → 签发 License Key
              ↓
公钥硬编码在 Agent/Licenser 二进制中 → 验签 License
```

- **私钥**：离线存储（硬件密钥或加密文件），仅签发 License 时使用
- **公钥**：编译进 Agent 二进制，随版本更新可更换

## 3. License Key 格式

### 3.1 结构

```
Base64( version(1) + user_id(32) + product_id(4) + max_nodes(1)
      + issued_at(8) + expires_at(8) + flags(1) + reserved(13)
      + signature(64) )
```

总计 132 字节，Base64 编码后约 176 字符。

### 3.2 字段说明

| 字段 | 大小 | 说明 |
|------|------|------|
| version | 1 byte | 协议版本，当前 1 |
| user_id | 32 bytes | 用户邮箱 SHA-256 前 32 字节 |
| product_id | 4 bytes | 产品代码：CROS = CrossLink |
| max_nodes | 1 byte | 最大 Agent 节点数，默认 1 |
| issued_at | 8 bytes | 签发时间 (unix timestamp) |
| expires_at | 8 bytes | 过期时间 (0 = 永久) |
| flags | 1 byte | 功能标志位 |
| reserved | 13 bytes | 保留 |
| signature | 64 bytes | Ed25519 签名 |

### 3.3 可读格式

交付给用户的格式（3 组，便于输入）：

```
CROS-A1B2C-D3E4F-G5H6I-J7K8L-M9N0P
```

每 5 字符一组，用 `-` 分隔，共 6 组 30 字符。实际内部通过 Base32 编码压缩。

## 4. 激活流程

### 4.1 用户侧

```
购买 → 收到 License Key（邮件/网页显示）
     → 打开 Agent 托盘菜单 → "输入 License"
     → 粘贴 Key → 点击激活
     → 成功：显示已激活
     → 失败：显示原因（Key 无效、已过期、设备数已满）
```

### 4.2 Agent 内部流程

```
接收 License Key → 解码 → 提取载荷和签名
                 → 用内置公钥验签
                 → 验签失败 → 返回错误 "无效的 License"
                 → 验签成功 → 检查过期时间
                 → 已过期 → 返回错误 "License 已过期"
                 → 有效 → 生成硬件指纹
                        → 加密存储 License + 指纹到本地
                        → 返回成功
```

### 4.3 硬件指纹

```
SHA-256(
  MAC地址(第一块物理网卡) +
  主板序列号(wmic baseboard get serialnumber) +
  机器名 +
  OS安装日期
)
```

各平台获取方式：

| 平台 | 方式 |
|------|------|
| Windows | `wmic csproduct get uuid` + `wmic baseboard get serialnumber` |
| macOS | `ioreg -d2 -c IOPlatformExpertDevice \| grep IOPlatformUUID` |
| Linux | `cat /etc/machine-id` + `dmidecode -s system-uuid` |

## 5. 存储安全

### 5.1 本地存储

```
路径: ~/.crosslink/license.dat

格式:
  file_header(4: "CLIC") +
  version(2 bytes) +
  encrypted_blob:
    AES-256-GCM(
      key = PBKDF2(硬件指纹, salt, 100000 iterations),
      plaintext = license_payload + activated_at + fingerprint
    )
  + gcm_nonce(12 bytes)
  + gcm_tag(16 bytes)
```

### 5.2 加密材料

- **加密密钥**：从硬件指纹派生（PBKDF2-SHA256, 10 万轮）
- **盐值**：随机生成，存储在 `license.dat` 明文头部
- **解密**：Agent 启动时用当前硬件指纹派生密钥 → 解密 license.dat → 比对指纹 → 匹配则通过

### 5.3 防篡改

- 解密失败 → License 校验失败
- 指纹不匹配 → Agent 拒绝启动核心功能（仅允许重新激活）
- license.dat 被删 → 需重新激活（但不消耗新设备额度，同一指纹复用原 Key）

## 6. 联网校验

### 6.1 策略

| 模式 | 说明 |
|------|------|
| 默认 | 每 7 天自动向公共信令服务上报 License 状态 |
| 离线 | 完全断网可用，无宽限期限制 |
| 异常 | 同一 Key 从不同指纹激活 → 标记为可疑，暂停新激活 |

### 6.2 校验接口

```
POST https://api.crosslink.io/v1/license/check
{
  "license_key_hash": "sha256(key)",
  "fingerprint_hash": "sha256(fingerprint)",
  "timestamp": 1718352000,
  "nonce": "random-hex"
}
→ {
  "valid": true,
  "max_nodes": 1,
  "node_count": 1,
  "next_check": 1718956800
}
```

### 6.3 吊销

- 开发者可吊销某个 License（泄露、退款等原因）
- 下次联网校验时 Agent 收到吊销指令 → 禁用所有功能
- 用户在管理后台可自行重置（更换电脑）

## 7. 设备管理

### 7.1 规则

| License 类型 | 最大主控 PC | 最大 Agent 节点 |
|-------------|------------|----------------|
| 个人版 | 1 | 无限制 |
| 团队版（未来） | N（按购买） | 无限制 |

### 7.2 换电脑流程

```
用户 → 旧电脑 Agent 卸载（自动释放绑定）
    → 或通过管理页面手动重置
    → 新电脑输入相同 License Key → 激活成功
```

### 7.3 旧电脑 Agent 卸载时

1. 读取本地 license.dat
2. 向服务器发送释放请求
3. 删除本地 license.dat

如果旧电脑无法开机（已损坏），用户通过管理页面手动操作。

## 8. 反盗版措施

### 8.1 技术层面

| 措施 | 说明 |
|------|------|
| 二进制混淆 | 使用 `garble` 混淆 Go 二进制，增加逆向难度 |
| 验签代码分散 | 公钥和验签逻辑分散在多个函数中 |
| 反调试 | 检测常见调试器（仅 Windows），发现则延迟/静默失败 |
| 限流 | 同一 IP 频繁激活 → 暂时拒绝 |
| 公钥轮换 | 每大版本更换公钥对，旧版 License 不兼容新版 |

### 8.2 非技术层面

| 措施 | 说明 |
|------|------|
| 种子用户信任 | 早期用户通过社区信任关系获取，盗版动机天然低 |
| 持续价值 | License 含 1 年公共信令服务，更新版本需有效 License |
| 合理定价 | 定价低到不值得折腾破解（$59-$99） |

> **原则**：防君子不防小人。核心用户是愿意付费的开发者，
> 把精力放在做好产品上，盗版只是商业成本的一部分。

## 9. 开发者工具链

### 9.1 License 签发 CLI

`licenser` Go 命令行工具（仅开发者使用）：

```bash
# 生成新的 License
licenser generate --email user@example.com --nodes 1 --output license.txt

# 验证 License
licenser verify --key "CROS-A1B2C-..."

# 吊销 License
licenser revoke --key "CROS-A1B2C-..." --reason "refund"

# 查看 License 信息（不包含敏感数据）
licenser info --key "CROS-A1B2C-..."
```

### 9.2 私钥管理

```
存储路径: ~/.crosslink/dev/ed25519_private.key
权限: chmod 600
格式: PEM (PKCS#8)
备份: 离线加密存储（1Password/硬件密钥）
```

### 9.3 CI/CD 集成

License 签发不接入 CI/CD（安全考虑），仅手动签发。

## 10. 实施计划

| 阶段 | 内容 | 预估 |
|------|------|------|
| **P0** | Ed25519 密钥对生成 + License 编解码 | 1 天 |
| **P1** | `licenser` CLI：generate / verify | 1 天 |
| **P2** | Agent 内激活逻辑：验签、指纹、加密存储 | 2 天 |
| **P3** | 联网校验 API + 管理后台页面 | 3 天 |
| **P4** | 反盗版加固（混淆、反调试） | 2 天 |

> **MVP 阶段只做 P0-P2**。联网校验和后台可在正式售卖前补上。

---

## 附录 A：硬件指纹获取示例

### Windows
```
wmic csproduct get uuid
wmic baseboard get serialnumber
```

### macOS
```
ioreg -d2 -c IOPlatformExpertDevice | awk -F\" '/IOPlatformUUID/{print $(NF-1)}'
system_profiler SPHardwareDataType | awk '/Serial/{print $NF}'
```

### Linux
```
cat /etc/machine-id
sudo dmidecode -s system-uuid
```

---
For_Agent: ToolPkg 发布来源提醒与 main 初始化捕获
---

# ToolPkg 来源提醒

## 现状

ToolPkg 发布时可以对可执行 JavaScript 做 AST 压缩，但导入流程没有来源提醒。市场前端是开源的，因此本功能只提供来源提示，不承担签名、联网校验或防盗版对抗。

## 意图

- 发布压缩 ToolPkg 时，将市场、插件 ID、版本和作者编码后追加到 `manifest.main` 对应脚本
- 导入时复用既有的 `main` 注册初始化执行链路捕获来源对象，不扫描脚本文本
- 导入成功后提示用户这是 Operit 市场插件，并提醒支持原作者、注意倒卖
- 独立脚本、资源文件和未压缩发布保持原有行为

## 作用域

- `ToolPkgArtifactMinifier` 的 `manifest.main` 注入
- JavaScript 注册桥和 Android 注册会话
- `ToolPkgLoadResult`、导入成功消息和定向单元测试

## 完成标准

- 压缩后的 `main` 不直接包含市场、作者等明文
- `main` 初始化执行能得到结构化来源信息
- 来源信息与 manifest 的 ToolPkg ID 不匹配时不生成提示
- 既有 ToolPkg 注册和导入行为不受影响

[DONE]

package com.follow.clash

import androidx.core.content.FileProvider

/**
 * 独立的 FileProvider 子类，用于 APK 更新文件共享（避免与 Crisp SDK 的 FileProvider 冲突）。
 */
class UpdateFileProvider : FileProvider()

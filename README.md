# Komga 漫画库 (komga.koplugin)

在 KOReader 中阅读 Komga 漫画/EPUB 书库的插件。书架浏览、逐章离线缓存、
流式阅读、双页/RTL、精确进度双向同步、智能预下载与下载队列。

## 功能

- **书架** — 系列列表(更新时间/名称/最后阅读排序, 手动置顶), 分卷目录自动生成
  快捷方式(封面/进度元数据), 网格/列表视图切换
- **EPUB 逐章管线** — webpub manifest 驱动: 逐内部章节下载、资源本地化(md5 命名)、
  内链改写为缓存文件、XHTML/图文/文本分类处理
- **整卷原文件模式**(可选, whole_file_mode) — 直接下载 /file 交 KOReader 原生引擎渲染
- **流式漫画** — 逐页即取即显 + 后 3 页后台预取(磁盘缓存滑动窗口), 双页(封面首页可选)、
  RTL(按书自动+手动)、底部进度条, 全部手势保持 KOReader 原生
- **进度同步** — EPUB 走 Readium Progression(locator + positions 插值), 漫画走页码;
  防回退冲刷; 跨卷续读(Komga /books/:id/next)
- **预载** — EPUB 后几页 / 漫画后续卷, 后台子进程静默执行; 失败零打扰
- **下载** — 流式落盘(不整载内存)+ Range 断点续传(服务器支持时)+ 原子写
- **缓存治理** — cache_max_mb 上限 + LRU 自动清理(可再生资源), 缓存管理面板
- **多服务器配置** — 多套地址/Key 一键切换, 即时生效
- **任务通道** — 具名通道(pages/stream/volume/cover/janitor)统一并发/超时/重试

## 目录结构(要点)

| 模块 | 职责 |
|------|------|
| main.lua / patches/core.lua | 入口、菜单注册、KOReader 打补丁 |
| Komga/Backend.lua | HTTP 编排(薄), 下载/预载/同步调度 |
| Komga/ApiClient.lua | REST 客户端(socket.http, Readium Accept) |
| Komga/ContentProcessor.lua | 章节内容管线(分类/改写/CBZ/processLink) |
| Komga/db/*Store.lua | SQLite 三域(series/volume/epub_chapter) |
| Komga/TaskQueue.lua / Async.lua | 通道任务引擎 / fork 传输 |
| Komga/ProgressSync.lua | 进度同步域 |
| Komga/StreamImageView.lua | 流式阅读器(双页/RTL/进度条) |
| Komga/VolumePath.lua | 缓存路径纯函数 |
| Komga/Logger.lua / CacheJanitor.lua / Json.lua | 日志/清理/编解码 |

## 测试

```sh
luajit spec/volumepath_spec.lua        # 路径纯函数
luajit spec/contentprocessor_spec.lua  # 内容管线(需 KOReader app bundle, macOS)
luajit spec/json_codec_spec.lua        # JSON 编解码
KOMGA_TEST_SERVER=... KOMGA_TEST_KEY=... luajit spec/live/apiclient_live_spec.lua  # 真机
```

## 设置要点

WEB 地址 / API Key / 浏览器目录名 / 流式模式 / 双页与 RTL / 预载数量 /
缓存上限 / 调试日志(komga.log) / 整卷原文件模式 / 多服务器配置

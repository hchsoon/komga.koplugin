# 更新日志

## 2026-09-02

- 书架"按最后阅读"排序(series.lastRead 列 + 连接级幂等迁移)
- 网格/列表视图切换(复用 CoverBrowser)
- 整卷原文件模式(双轨渲染, /file 流式下载 + 原生 TOC/内链, 进度整卷比例适配)
- 缓存上限 cache_max_mb + LRU 清理(CacheJanitor, 章节缓存/封面豁免)
- 分级日志 Komga/Logger(komga.log, debug_log 开关收编诊断输出)
- 预载数量 preload_count 可配置
- 书架/分卷同步分页循环(>1000 不再截断)
- 架构: LibraryView 拆出 ProgressSync + PlgState; BookInfoDB 按表拆出 Komga/db/*Store;
  ContentProcessor 二批迁入章节管线; StreamPageCache 独立; ApiClient 换 rapidjson
  (Json 统一入口, null 归零); TaskQueue 具名通道(超时/重试/暂停)统一全部后台任务,
  看门狗退役
- 修复: pStreamToFile socket.skip 解包错位(图片双倍下载); 封面 cache-first;
  旋转连锁(布局/残留/误退出)系列问题; 双页 nil 崩溃; 系列目录秒开(分块元数据同步)

## 2026-08-30

- 流式页预取(EPUB 后几页/漫画后 3 页, 子进程+磁盘缓存滑动窗口)
- 跨卷续读(/books/:id/next), 整卷原文件模式前置: 原子写(.part+rename)
- 封面版本化 URL; EPUB 整卷模式预读适配; 书架截断修复(size 移回 query)
- 流式阅读: 双页/RTL/封面首页按钮栏, 顶部->底部进度条, 旋转修复与方向隔离
- 章节切换静默下载; 整卷模式 UI 开关

# 更新日志

## 2026-09-21

- 修复: 退出阅读后书架/分卷进度不更新(需手动刷新)。根因是关书路径只写 sidecar,
  但列表行进度实际读自 BookList 内存缓存, 且系列聚合进度在关书路径从不重算;
  现关书/翻章/流式关卷后按"会话脏卷集合"定向刷新: 逐卷重算 sidecar percent_finished/status +
  清 BookList 缓存条目 + 汇总系列总进度 + 节流单次目录重绘, 不做全量更新
- 修复: 跨卷阅读退出后, 已读完分卷的进度与已读状态不更新。会话内每卷进度上传时记入脏集合
  (markSessionVolumeDirty), 退出后按集合逐卷刷新(含"关书瞬间刚读完"的卷——刷新排在延迟上传之后,
  按 isRead 正确落为 complete/100%); 流式阅读的跨卷发生在 StreamImageView 翻页管线内(不经过
  ReaderUI 关闭事件), 现跨卷时把离开的卷也记入脏集合, 关卷后中间卷一并刷新
- 修复: 流式跨卷时中间卷不进阅读历史(ReadHistory 的 komga 映射补丁依赖 ReaderUI 关闭事件,
  流式只在关卷时为最后一卷补写)——跨卷点为离开的卷即时补一条历史条目(addItem 按路径去重置顶,
  displayed_chapter 更新前映射, 正好是该卷快捷方式)
- 新增: 设置 → 缓存与维护 → "从 Komga 同步阅读历史"(手动触发)。全库按 readProgress.lastModified
  倒序拉取在读书(过滤 completed, 条数 history_sync_limit 可配, 默认 20), 按 bookId 定位书架已有
  系列的卷, 复用 persistServerProgressToShortcut 落盘进度, 并以服务器 lastModified 为时间戳合并进
  KOReader 阅读历史; 安全合并只向前不后退(本地条目不旧于服务器时跳过, 避免旧时间戳把本机较新的
  "继续阅读"置顶条目降级); 系列不在书架的卷跳过并计数提示; 纯函数(过滤/时间戳解析/合并决策)
  有 spec 回归防线

## 2026-09-15 ~ 2026-09-19

- 阅读模式整合: stream_image_view 与 whole_file_mode 合并为互斥的 reading_mode 开关(stream|whole),
  首次读取自动迁移旧配置, 设置页单开关(旧键同步写入兼容降级)
- 整卷模式 TOC 直连原生目录: 整卷 epub 自带章节结构, 跳转为纯本地翻页零下载;
  修复跳转被 ReaderToc 补丁路由回书架/内部章节菜单(后者每次跳转重下整卷)
- 整卷下载进度(参考 komix): 子进程 on_progress 写 (got,total) 状态文件, DownloadProgress 每秒轮询
  弹进度窗(卷名/进度条/隐藏/取消); 任务管理器标签实时显示卷名+百分比; 下载 max_retries=2 + .part 断点续传
- 流式阅读器(借自 Artgallery): 三态缩放循环 适配(完整含黑边) -> 铺满(等比裁切+平移) -> 原始像素,
  按钮标签预览目标模式; 智能旋转偏好(imageviewer_rotate_auto_for_best_fit);
  黑底开关因无实际场景移除, 恢复纯白画布
- simpleui logo

## 2026-09-13 ~ 2026-09-14

- 凭据登录(参考 kokomga): 服务器设置新增用户名+密码并排单对话框(kosync 风格), Basic auth POST
  /api/v2/users/me/api-keys 自动创建 API key(Komga >= 1.11); 密码只用一次不存储, 用户名默认保存;
  key 注释带时间戳唯一化(修复 ERR_1034 同名注释被拒 400), 401/404 转译提示
- 书架一键进入: 点击即弹书架菜单, 文件管理器后台跳转书架目录(修复两段式进入"第一次点击没反应")
- 整卷下载开始/完成 toast 带卷名(漫画与整卷模式 EPUB), 大文件后台下载不再像点了没反应
- 修复(整卷模式): EPUB 卷打不开(resume 旁路在 LibraryView 实例上调 Backend:getSettings 崩溃);
  缓存路径误命中旧按章节缓存(整卷永不下载, .xhtml 章节继续打开)与续读改写 volume.number 错键重下;
  EPUB 按章节预载停用(任务无 url, 自输入守卫上线起必然报错), 改预载下一整卷, 缓存优先整卷文件
- 修复: 非流式漫画续读总在第 1 页(分页文档 GotoPercent 无效, 按文档类型改 GotoPage;
  漫画本地断点改读整卷 sidecar last_page); 章节切换"关闭书籍"提示抑制从未生效
  (dofile/require 双模块实例, 现自注册 package.loaded 共享单例)

## 2026-09-11 ~ 2026-09-12

- 漫画进度语义对齐 EPUB: 读完最后一页才标已读(原打开即标已读, 部分读的卷因 isRead 显示优先级最高
  永远显示 100%); 进书同步仅凭服务器 completed 证据吸收远程完成/清理历史污染, 无服务器记录的卷不动
- 系列总阅读进度: 各卷 sidecar 进度按页数加权聚合写入系列快捷方式 sidecar(替代粗糙的章节序号比例),
  卷进度同步后与首次全量元数据同步后计算; 卷服务器进度改为单次 books/list 批量拉取写 sidecar
- CoverBrowser 封面自愈闭环: 修复 bookinfomanager require 名不匹配(裸名 vs 点分名, 自愈与行失效
  在生产从未生效); 封面落地回调即时失效对应行(1.5s 合并重绘, 12s 轮询兜底); 进目录清除中毒行
  (提取中断 stuck 行 / 有封面文件但行缺失)
- 修复: 非流式漫画阅读 400(DIVINA 卷误走 EPUB 按章节管线, downloadVolume 本体漏改);
  流式按钮栏合并两行(双页/RTL/封面/跳页并排), 重复作者展示层去重(series 作者参与 bookCacheId 故不动)
- 清理批次 stage 1~4b: 死代码移除, 隐藏缺陷接线(volume.lastUpdated), luacheck 警告清零,
  传输层去重(fetchAllPages + 共享默认头)与 ProgressSync 内部去重

## 2026-09-03 ~ 2026-09-08

- 继续阅读入口 + 任务管理器 + 内存清理, 离线自动重试; 列表模式 kokomga 风格行(封面/标题/进度)
- 架构大拆分: Backend 按域拆出 BackendProgress/BackendProfiles/BackendDownload; LibraryView 拆出
  SettingsDialogs/ReaderHooks/BrowserViews; 新增 Komga/Paths 统一路径与 UA; 设置菜单 19 项归组
  5 类子菜单; BookInfoDB.queryObjects + 声明式列映射(store 行为基线 spec)
- HTTP 层加固: 非 2xx 错误分类(401/403/404/429/5xx 带可操作信息), GET 重定向跟随(2 跳),
  socketutil.tcp 连接阶段超时; 阻塞性 HTTP 全面移出 UI 线程(章节下载/续读进度/后台刷新)
- 二阶段加固/性能: 缓存占用统计移入 janitor 子进程(结果缓存 + 重新统计菜单); LRU 按 mtime
  (noatime 安全) + 剪空目录; Async 共享单轮询器; 预载 fork 前先标 downloading_ 防竞态;
  TaskQueue 重试退避; EPUB 进度上传 href 映射按书缓存(2 查询 -> 1); 章节 XHTML 重写去二次方复杂度
- 流式预取系列修复: pcall 双层解包错位(图片双倍下载); 结果表契约在成功边界强制(裸 true 归一 +
  文件大小回填); 取消标志经缓存目录存在性跨 fork 传递; 批量静默失败修复(死预取/lastRead 未盖章/
  书架排序被忽略等)
- 卷文件夹同步收敛: 会话级 10min TTL / 首次进入全量刷新(持久化 per-series 标记, 重启不重同步);
  批量同步期间延迟元数据广播, 完成时单次刷新; 分卷块化(1 卷/块 + 0.1s 间隔)保翻页流畅
- CoverBrowser 集成: 停止对 komga 快捷方式的元数据失效广播(无文档类必失败, 白烧 3 次提取配额致
  "too many, ignoring it" 永久忽略); aux provider 注册 ShortcutDocument 修中毒源头;
  emitMetadataChanged 单发 + 10s per-path 去重
- 章节切换静默化: 去后台下载 toast(失败仍通知), 补丁级抑制"关闭书籍"提示(3s 切换窗口内);
  流式新增页码跳转按钮
- 修复(设备日志回归): 缓存目录 locals 丢失致 joinPath nil 崩溃; current_page nil 跳过进度上传
  (服务器 400); 事件链挂载恢复无条件插入(守卫跳过致实体翻页键失灵); 恢复流式图片列表包装器
  (裸 blitbuffer 使全屏点击只会切按钮栏); installPatches 一致时跳过重装+重启(每次启动首点被踢回主页)

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

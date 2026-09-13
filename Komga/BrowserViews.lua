--[[ Komga/BrowserViews.lua — 文件浏览器视图(自 LibraryView 拆出)

init_book_browser: Komga 目录的快捷方式引擎(系列/分卷 .html 生成、
  元数据/进度/封面同步、CoverBrowser bookinfo 绑定);
init_book_menu: 书架菜单(系列列表、网格/列表视图、继续阅读入口)。

install(LibraryView) 返回两个构造函数供 LibraryView 以同名 local 调用;
构造结果挂载在 parent(LibraryView 实例)的 book_browser/book_menu 字段上。
]]
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local BD = require("ui/bidi")
local T = require("ffi/util").template
local _ = require("gettext")
local Event = require("ui/event")
local util = require("util")
local logger = require("logger")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local DocSettings = require("docsettings")
local Icons = require("Komga/Icons")
local Backend = require("Komga/Backend")
local MessageBox = require("Komga/MessageBox")
local KomgaModel = require("Komga/KomgaModel")
local TaskQueue = require("Komga/TaskQueue")
local ChapterListing = require("Komga/ChapterListing")
local FileManager = require("apps/filemanager/filemanager")
local H = require("Komga/Helper")
local Paths = require("Komga/Paths")

return function(LibraryView)
local function init_book_browser(parent)
    if parent.book_browser then
        return parent.book_browser
    end

    local book_browser = {
        parent = parent
    }

    function book_browser:show_view(focused_file, selected_files)
        local homedir = self.parent:getBrowserHomeDir()
        if not homedir then
            return
        end
        -- 一次点击即进入书架菜单。旧实现是两段式: 第一次点击仅把文件管理器
        -- 导航到书架目录(若启动时已在该目录则视觉零变化, 用户感知为"没反应"),
        -- 第二次点击才打开书架菜单。
        if not self.parent.book_menu then
            self.parent.book_menu = self.parent:getMenuWidget()
        end
        self.parent.book_menu:show_view()
        self.parent.book_menu:refreshItems(true)
        -- 书架菜单之下仍是书架目录本身(封面墙): 当前不在书架目录时后台导航,
        -- 关闭书架菜单后露出的就是封面墙, 两种视图都保留
        local current_dir = self.parent:getBrowserCurrentDir()
        if current_dir ~= homedir then
            self.parent:openKomgaFolder(homedir, focused_file, selected_files)
        end
    end

    function book_browser:refreshItems()
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end

    function book_browser:deleteFile(file, is_file)
        self.parent:deleteFile(file, is_file)
    end
    function book_browser:verifyBooksMetadata(chunk_size)
        -- possible cover name change
        local browser_homedir = self.parent:getBrowserHomeDir()
        if not util.directoryExists(browser_homedir) then
            return
        end

        local function is_valid_book_file(fullpath, name)
            return util.fileExists(fullpath) and H.is_str(name) and name:find(Paths.LNK_SUFFIX, 1, true)
        end

        local function get_book_id(fullpath)
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, fullpath)
            if ok and H.is_tbl(lnk_config) and lnk_config.readSetting then
                return lnk_config:readSetting("book_cache_id")
            end
            local doc_settings = DocSettings:open(fullpath)
            return doc_settings:readSetting("book_cache_id")
        end

        -- 先纯遍历收集快捷方式清单, 再分块处理(每块间让出主循环):
        -- 每个文件要读配置/查 DB/写 sidecar, 大库一次性同步处理会长时间卡死 UI
        local targets = {}
        util.findFiles(browser_homedir, function(fullpath, name)
            if is_valid_book_file(fullpath, name) then
                targets[#targets + 1] = fullpath
            end
        end, true)

        local per_chunk = math.max(tonumber(chunk_size) or 5, 1)
        local idx = 0

        local function process_one(fullpath)
            local book_cache_id = get_book_id(fullpath)
            if not book_cache_id then
                self:deleteFile(fullpath, true)
                return
            end

            local model = KomgaModel:new(book_cache_id)
            local bookinfo = model and model:getSeries() or nil
            if not (H.is_tbl(bookinfo) and bookinfo.name) then
                self:deleteFile(fullpath, true)
                return
            end

            -- 分卷快捷方式走卷级元数据修复，避免被重写为系列
            local customedata = H.getCustomProps(fullpath)
            local number = H.is_tbl(customedata) and customedata.number or nil
            if H.is_tbl(customedata) and customedata.type == 'volume' and H.is_num(number) then
                self:refreshVolumeMetadata(nil, fullpath, book_cache_id, number, bookinfo)
            else
                self:refreshBookMetadata(nil, fullpath, bookinfo)
            end
        end

        local function step()
            local budget = 0
            while idx < #targets and budget < per_chunk do
                idx = idx + 1
                budget = budget + 1
                pcall(process_one, targets[idx])
            end
            if idx < #targets then
                UIManager:scheduleIn(0.05, step)
            end
        end
        UIManager:scheduleIn(0.05, step)
    end

    -- 系列快捷方式路径(与 wirteLnk 同名规则), 只计算不落盘; 参数不全返回 nil。
    -- 供只读场景(总进度汇总)使用, 避免为写进度而把已删除的快捷方式重建出来
    function book_browser:getBookLnkPath(bookinfo, home_dir)
        if not (H.is_str(home_dir) and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            return nil
        end
        local book_author = bookinfo.author or "未知作者"
        local book_lnk_name = string.format("%s-%s" .. Paths.LNK_SUFFIX, bookinfo.name, book_author)
        book_lnk_name = util.getSafeFilename(book_lnk_name)
        if not book_lnk_name then
            return nil
        end
        return H.joinPath(home_dir, book_lnk_name), book_lnk_name
    end

    function book_browser:wirteLnk(bookinfo, home_dir)
        -- local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            logger.err("book_browser.wirteLnk: parameter error")
            return
        end

        local book_lnk_path, book_lnk_name = self:getBookLnkPath(bookinfo, home_dir)
        if not book_lnk_path then
            logger.err("book_browser.wirteLnk: getSafeFilename error")
            return
        end
        if util.fileExists(book_lnk_path) then
            return book_lnk_path, book_lnk_name
        end

        local book_lnk_config = Backend:getLuaConfig(book_lnk_path)
        book_lnk_config:saveSetting("book_cache_id", bookinfo.cache_id):flush()

        return book_lnk_path, book_lnk_name
    end

    function book_browser:addBookShortcut(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id and bookinfo.coverUrl) then
            logger.err("addBookShortcut: parameter error")
            return
        end

        local book_lnk_path, book_lnk_name = self:wirteLnk(bookinfo, home_dir)
        if not (book_lnk_path and util.fileExists(book_lnk_path)) then
            logger.err("addBookShortcut: failed to create lnk")
            return
        end

        if not H.getCustomProps(book_lnk_path) then
            self:refreshBookMetadata(book_lnk_name, book_lnk_path, bookinfo)
        else
            self:bind_provider(book_lnk_path)
        end

        if DocSettings:findCustomCoverFile(book_lnk_path) then
            return
        end

        if not NetworkMgr:isConnected() then
            return
        end
        local book_cache_id = bookinfo.cache_id
        local cover_url = bookinfo.coverUrl
        if cover_url then
            Backend:runTaskWithRetry(function()
                if DocSettings:findCustomCoverFile(book_lnk_path) then
                    -- 封面落盘后定向刷新系列行(行可能先于封面提取, 无此刷新封面不显示)
                    self:invalidateShortcutRow(book_lnk_path)
                    return true
                end
            end, 12000, 2000)
            TaskQueue.getChannel("cover", 2):push(function()
                return Backend:download_cover_img(book_cache_id, cover_url)
            end, function(ok, cover_path)
                if ok and H.is_str(cover_path) and util.fileExists(cover_path) then
                    pcall(function()
                        DocSettings:flushCustomCover(book_lnk_path, cover_path)
                    end)
                    -- 封面已落盘: 下载完成即定向刷新系列行(不依赖 12s 轮询窗口)
                    self:invalidateShortcutRow(book_lnk_path)
                end
            end, {timeout = 120, tag = "series_cover"})
        end
    end

    function book_browser:writeVolLnk(volume, volume_folder, book_cache_id)
        if not (volume_folder and H.is_tbl(volume) and H.is_num(volume.number) and H.is_str(book_cache_id)) then
            logger.err("book_browser.writeVolLnk: parameter error")
            return
        end
        local number = volume.number
        local volume_title = (H.is_str(volume.title) and volume.title ~= "") and volume.title or
            "卷" .. tostring(number)
        -- 卷号补零到 3 位, 避免文件浏览器按文件名排序时 2,10,11... 乱序
        local volume_lnk_name = string.format("%03d-%s" .. Paths.LNK_SUFFIX, number, volume_title)
        volume_lnk_name = util.getSafeFilename(volume_lnk_name)
        if not volume_lnk_name then
            logger.err("book_browser.writeVolLnk: getSafeFilename error")
            return
        end
        local volume_lnk_path = H.joinPath(volume_folder, volume_lnk_name)
        if util.fileExists(volume_lnk_path) then
            return volume_lnk_path, volume_lnk_name
        end
        local volume_lnk_config = Backend:getLuaConfig(volume_lnk_path)
        volume_lnk_config:saveSetting("book_cache_id", book_cache_id):flush()
        return volume_lnk_path, volume_lnk_name
    end

    function book_browser:refreshVolumeMetadata(lnk_name, lnk_path, book_cache_id, number, bookinfo)
        lnk_name = lnk_name or (H.is_str(lnk_path) and select(2, util.splitFilePathName(lnk_path)))
        if not (util.fileExists(lnk_path) and H.is_str(lnk_name) and H.is_str(book_cache_id) and
            H.is_num(number)) then
            logger.err("browser.refreshVolumeMetadata parameter error")
            return
        end
        local volume = KomgaModel:new(book_cache_id):getVolume(number) -- Komga Book(分卷)
        if not (H.is_tbl(volume) and H.is_num(volume.number)) then
            logger.err("browser.refreshVolumeMetadata no volume data:", book_cache_id, number)
            return
        end
        bookinfo = bookinfo or KomgaModel:new(book_cache_id):getSeries() -- Komga Series
        -- pages 缺失时按 0 处理, 仍写入卷级元数据, 保证点击可打开
        local pages = H.is_num(volume.pages) and volume.pages or 0
        -- pageno: 已读 -> 满进度; 有落盘的服务器空间进度(komga_progress) -> 按它换算(EPUB 与漫画通用);
        -- 缺失时 EPUB 退回累计页数估算, 漫画退回缓存文件 last_page
        local pageno = 0
        if volume.isRead == true then
            pageno = pages
        elseif H.is_num(pages) and pages > 0 then
            local ds = DocSettings:open(lnk_path)
            local komga_prog = ds:readSetting("komga_progress")
            if H.is_num(komga_prog) and komga_prog > 0 and komga_prog <= 1 then
                -- 优先用上传/续读时落盘的服务器空间进度(与服务器显示一致), 避免本地累计/页数模型估算错位
                pageno = math.max(math.min(math.floor(komga_prog * pages + 0.5), pages), 1)
            elseif volume.mediaType == "EPUB" then
                -- EPUB 无服务器空间比例(komga_progress)时:
                -- 1) 主 sidecar 已落盘 percent_finished 表示有真实进度(>第 1 页) -> 保留, 避免被回退成第 1 页 1%
                --    (封面下载完成后 refreshVolumeMetadata 可能被再次触发, 而 komga_progress 尚未落盘, 之前正确显示会被 1% 覆盖)
                -- 2) 否则按累计已读页数估算; 整卷无任何已读痕迹 -> 视为未读(percent=nil, 不显示进度条)
                local existing = ds:readSetting("percent_finished")
                if H.is_num(existing) and existing > (1 / pages) and existing < 1 then
                    pageno = math.max(math.min(math.floor(existing * pages + 0.5), pages), 1)
                else
                    local read_pages = self.parent:calcVolumeLocalRead(book_cache_id, volume.bookId, volume.name)
                    if H.is_num(read_pages) and read_pages > 0 then
                        pageno = math.min(math.max(math.floor(read_pages + 0.5), 1), pages)
                    else
                        pageno = 0 -- 未读: 不显示进度条
                    end
                end
            else
                -- 漫画无落盘比例: 退回缓存文件 last_page
                local cache_chapter = Backend:getCacheVolumeFilePath(volume)
                if H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath) then
                    local last_page = DocSettings:open(cache_chapter.cacheFilePath):readSetting("last_page")
                    if H.is_num(last_page) and last_page > 0 and last_page <= pages then
                        pageno = last_page
                    end
                end
            end
        end
        -- KOReader 原生显示用进度(0..1): 已读 -> 1; 有进度 -> pageno/pages; 未读 -> nil(FileChooser 显示 "–")
        local percent
        if volume.isRead == true then
            percent = 1
        elseif H.is_num(pages) and pages > 0 and pageno > 0 then
            percent = math.min(pageno / pages, 1)
        end
        local volume_title = (H.is_str(volume.title) and volume.title ~= "") and volume.title or
            (H.is_tbl(bookinfo) and bookinfo.name) or "卷" .. tostring(number)
        -- 显示标题带系列名: 阅读历史/封面浏览器列表按条目展示 title,
        -- 只有"卷 01"这类卷标题时无法辨认属于哪个系列
        local display_title = volume_title
        local series_name = H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and bookinfo.name or nil
        if series_name and not volume_title:find(series_name, 1, true) then
            display_title = series_name .. " " .. volume_title
        end
        -- 无变化则跳过写入，避免每次进入目录都重写并广播事件
        local custom = nil
        local custom_metadata_file = DocSettings:findCustomMetadataFile(lnk_path)
        if custom_metadata_file then
            local custom_settings = DocSettings.openSettingsFile(custom_metadata_file)
            custom = {
                custom_props = custom_settings:readSetting("custom_props"),
                book_cache_id = custom_settings:readSetting("book_cache_id"),
                number = custom_settings:readSetting("number"),
                doc_props = custom_settings:readSetting("doc_props")
            }
        end
        local lnk_ds = DocSettings:open(lnk_path)
        local lnk_percent = lnk_ds:readSetting("percent_finished")
        local lnk_doc_pages = lnk_ds:readSetting("doc_pages")
        local lnk_summary = lnk_ds:readSetting("summary")
        local lnk_status = H.is_tbl(lnk_summary) and lnk_summary.status or nil
        -- 上传/续读落盘的服务器空间进度, 重写 sidecar 时必须保留(data={} 会清空全部设置)
        local lnk_komga_prog = lnk_ds:readSetting("komga_progress")
        local target_status
        if volume.isRead == true then
            target_status = "complete"
        elseif H.is_num(percent) and percent > 0 then
            target_status = "reading"
        end
        -- 作者串展示前去重(booksMetadata 常重复列出同一作者, 如"岸本斉史/岸本斉史")
        local display_author = H.dedupeAuthors(
            (H.is_tbl(bookinfo) and bookinfo.author) or volume.author)
        if H.is_tbl(custom) and H.is_tbl(custom.custom_props) and custom.custom_props.type == 'volume' and
            custom.custom_props.number == number and
            H.is_tbl(custom.doc_props) and custom.doc_props.pages == pages and custom.doc_props.pageno == pageno and
            custom.book_cache_id == book_cache_id and custom.number == number and
            custom.custom_props.authors == display_author and
            lnk_percent == percent and lnk_doc_pages == (H.is_num(pages) and pages or nil) and
            lnk_status == target_status and lnk_ds:readSetting("provider") == "komga" then
            return
        end
        local doc_settings = self:bind_provider(lnk_path)
        if doc_settings and doc_settings.data then
            doc_settings.data = {}
            -- bind_provider 写入的 provider 被 data={} 清空, 必须重写:
            -- 否则点击快捷方式时 DocumentRegistry 读不到 komga provider, 会直接用 crengine 打开 html(书籍元信息)
            doc_settings:saveSetting("provider", "komga")
            doc_settings:saveSetting("custom_props", {
                authors = display_author,
                title = display_title,
                description = (H.is_tbl(bookinfo) and bookinfo.intro) or nil,
                -- series/series_index: KOReader 文件管理器/封面浏览器按系列归组显示
                series = (H.is_tbl(bookinfo) and bookinfo.name) or nil,
                series_index = tostring(number),
                type = "volume",
                number = number,
                bookId = volume.bookId
            })
            doc_settings:saveSetting("book_cache_id", book_cache_id)
            doc_settings:saveSetting("number", number)
            doc_settings:saveSetting("doc_props", {
                pages = pages,
                pageno = pageno
            })
            if H.is_num(lnk_komga_prog) then
                -- 保留上传/续读落盘的服务器空间进度, 避免 data={} 清空丢失
                doc_settings:saveSetting("komga_progress", lnk_komga_prog)
            end
            if percent then
                -- 主 sidecar 补写 KOReader 原生进度字段(FileChooser/CoverBrowser/Reading History 读取源)
                doc_settings:saveSetting("percent_finished", percent)
                doc_settings:saveSetting("doc_pages", pages)
                local summary = doc_settings:readSetting("summary") or {}
                summary.status = target_status
                summary.modified = os.date("%Y-%m-%d")
                doc_settings:saveSetting("summary", summary)
            end
            doc_settings:flushCustomMetadata(lnk_path)
            doc_settings:flush()
        end
        -- 主 sidecar 也写入 number, 便于 openFile 读取
        local lnk_config = Backend:getLuaConfig(lnk_path)
        if lnk_config and lnk_config.readSetting then
            local old_index = lnk_config:readSetting("number")
            if old_index ~= number then
                lnk_config:saveSetting("number", number):flush()
            end
        end
        self:emitMetadataChanged(lnk_path)
    end

    function book_browser:asyncDownloadVolumeCover(book_cache_id, chapter, lnk_path)
        if not (H.is_str(book_cache_id) and H.is_tbl(chapter) and H.is_str(lnk_path)) then
            return
        end
        if DocSettings:findCustomCoverFile(lnk_path) then
            return
        end
        if not NetworkMgr:isConnected() then
            return
        end
        local cover_url = Backend:getVolumeCoverUrl(chapter.bookId)
        if not cover_url then
            return
        end
        Backend:runTaskWithRetry(function()
            if DocSettings:findCustomCoverFile(lnk_path) then
                -- 封面落盘后定向刷新卷行(行可能先于封面提取, 无此刷新封面不显示)
                self:invalidateShortcutRow(lnk_path)
                return true
            end
        end, 12000, 2000)
        TaskQueue.getChannel("cover", 2):push(function()
            local cover_path_no_ext = Backend:getVolumeCoverCachePath(book_cache_id, chapter.number)
            local cover_path = Backend:download_cover_img(book_cache_id, cover_url, cover_path_no_ext)
            if H.is_str(cover_path) and util.fileExists(cover_path) then
                pcall(function()
                    DocSettings:flushCustomCover(lnk_path, cover_path)
                end)
            end
            return cover_path
        end, function(ok, cover_path)
            -- 下载完成回调(UI 线程): 封面已落盘即定向刷新该行。
            -- 12s 轮询窗口在封面队列积压时早已超时, 这里才是可靠的刷新时机
            if ok and H.is_str(cover_path) and DocSettings:findCustomCoverFile(lnk_path) then
                self:invalidateShortcutRow(lnk_path)
            end
        end, {timeout = 120, tag = "volume_cover"})
    end

    function book_browser:ensureVolumeFolder(book_cache_id, bookinfo)
        if not (H.is_str(book_cache_id) and H.is_tbl(bookinfo) and H.is_str(bookinfo.name)) then
            return nil
        end
        local home_dir = self.parent:getBrowserHomeDir()
        if not home_dir then
            return nil
        end
        local author = (H.is_str(bookinfo.author) and bookinfo.author ~= "") and bookinfo.author or "未知作者"
        -- 目录以 .sdr 结尾, 文件浏览器会将其隐藏, 避免与系列快捷方式(.html)同时显示造成重复。
        -- 注意: 不能直接用 <系列名>-<作者>\u{200B}.sdr, 那是系列快捷方式的封面 sidecar 目录。
        local folder_name = string.format("%s-%s-vol.sdr", bookinfo.name, author)
        folder_name = util.getSafeFilename(folder_name)
        if not folder_name then
            logger.err("ensureVolumeFolder: getSafeFilename error")
            return nil
        end
        local volume_folder = H.joinPath(home_dir, folder_name)
        -- 旧版目录名(<系列名>-<作者>\u{200B}, 无 -vol.sdr 后缀)在浏览器中可见, 迁移到新隐藏命名
        local legacy_folder = H.joinPath(home_dir, util.getSafeFilename(string.format("%s-%s" .. Paths.ZWSP, bookinfo.name, author)))
        if not util.directoryExists(volume_folder) and util.directoryExists(legacy_folder) then
            local ok, err = pcall(os.rename, legacy_folder, volume_folder)
            if not ok then
                logger.err("ensureVolumeFolder: failed to rename legacy folder - " .. tostring(err or "unknown error"))
                return nil
            end
        end
        if not util.directoryExists(volume_folder) then
            local ok, err = pcall(H.checkAndCreateFolder, volume_folder)
            if not (ok and util.directoryExists(volume_folder)) then
                logger.err("ensureVolumeFolder: failed to create folder - " .. tostring(err or "unknown error"))
                return nil
            end
        end
        return volume_folder
    end

    -- 同路径失效去重(10s): 进度持久化/关书刷新等多个调用方会在数秒内对同一
    -- 文件连发失效, CoverBrowser 每次都会重新提取并重新计数, 反复被打断会让
    -- 其提取计数满 3 次而永久放弃该文件("too many, ignoring it", 封面/信息不再加载)
    -- komga 快捷方式(.html, ZWSP 标记)注册的是无 document_class 的 aux provider:
    -- CoverBrowser 的提取子进程里 openDocument 必然失败, 提取从未成功过。
    -- 对这些文件发失效广播只会删掉"已放弃"标记行并触发一次新的注定失败的
    -- 提取尝试, 3 次后 CoverBrowser 永久放弃("too many, ignoring it")并刷错误日志。
    -- 封面来自 custom cover 文件、元数据来自 sidecar, 都不依赖其 DB 提取,
    -- 故对这些文件不再发失效/广播, 从根上消除该错误。
    function book_browser:emitMetadataChanged(path)
        if path and path:find(Paths.LNK_SUFFIX, 1, true) then
            return
        end
        self._meta_emit_at = self._meta_emit_at or {}
        local last = self._meta_emit_at[path]
        if last and os.time() - last < 10 then
            return
        end
        self._meta_emit_at[path] = os.time()
        -- CoverBrowser 对每个文件有独立缓存行, 写完 sidecar 后必须删缓存行,
        -- 否则列表/网格一直显示旧元数据(文件名/无进度)
        pcall(function()
            local BookInfoManager = self:getBookInfoManager()
            if BookInfoManager and BookInfoManager.deleteBookInfo then
                BookInfoManager:deleteBookInfo(path)
            end
        end)
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", path))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end

    -- 批量同步期间的挂起版: 累积待失效路径而不逐条广播。
    -- 每条广播都会让 CoverBrowser 删缓存行并触发目录重排, 逐卷广播即
    -- 分卷目录"频繁刷新/卡顿"的来源; 批量结束后由调用方统一失效+整目录一次刷新。
    function book_browser:deferMetadataChanged(path)
        if self.parent and self.parent._bulk_meta_sync then
            local pending = self.parent._pending_meta_paths
            if not pending then
                pending = {}
                self.parent._pending_meta_paths = pending
            end
            pending[path] = true
            return
        end
        self:emitMetadataChanged(path)
    end

    -- 加载 CoverBrowser 的 bookinfomanager。注意: CoverBrowser 自己以裸名
    -- require("bookinfomanager")(插件加载器会把 <插件目录>/?.lua 追加进
    -- package.path), 而点分全名 plugins/coverbrowser.koplugin/bookinfomanager
    -- 依赖 koreader 根目录恰好在搜索路径上, 部分启动方式下解析不到,
    -- 因此两个名字都试; 都失败返回 nil(调用方静默降级)。
    function book_browser:getBookInfoManager()
        local ok, mod = pcall(function()
            return require("bookinfomanager")
        end)
        if ok and type(mod) == "table" and mod.getBookInfo then
            return mod
        end
        ok, mod = pcall(function()
            return require("plugins/coverbrowser.koplugin/bookinfomanager")
        end)
        if ok and type(mod) == "table" and mod.getBookInfo then
            return mod
        end
        return nil
    end

    -- 分卷目录行自愈: 两类"卡死行" CoverBrowser 都不会再自动处理, 这里删行让其
    -- 重新提取一次(纯 DB DELETE, 无事件/无广播), ShortcutDocument 下提取必然
    -- 成功, 状态即收敛; 健康行与不存在的行零触碰, 只在确实删了行时才整目录
    -- 刷新一次, 不会引发重提取风暴。
    --   1) 提取从未完成: 提取子进程被翻页/退出打断, 行停在 in_progress>0,
    --      或被终审为 unsupported("too many interruptions or crashes"),
    --      has_meta 为空; 而行只要存在(CoverBrowser 以"行存在"为 bookinfo_found)
    --      就永远不会被再次提取, 该卷的元数据/封面从此缺失。
    --   2) 提取先于封面完成: 行 has_meta 正常但 has_cover 为空且 cover_fetched
    --      已标记"试过了不再重试", 而磁盘上封面文件已由异步下载落盘
    --      ——封面从此不再显示(invalidateShortcutRow 负责增量, 这里兜存量)。
    function book_browser:repairVolumeShortcutRows(book_cache_id, bookinfo, volume_folder)
        local BookInfoManager = self:getBookInfoManager()
        -- CoverBrowser 未启用/不可用时静默跳过(分卷数据本身不受影响)
        if not (BookInfoManager and BookInfoManager.getBookInfo and BookInfoManager.deleteBookInfo) then
            return
        end
        local volumes = KomgaModel:new(book_cache_id):getVolumes()
        if not (H.is_tbl(volumes) and #volumes > 0) then
            return
        end
        local repaired = 0
        for _, volume in ipairs(volumes) do
            if H.is_tbl(volume) and H.is_num(volume.number) then
                local lnk_path = self:writeVolLnk(volume, volume_folder, book_cache_id)
                if H.is_str(lnk_path) and util.fileExists(lnk_path) then
                    -- 第二参 false: 不取封面 blob, 只查行状态(最轻的读)
                    local row = BookInfoManager:getBookInfo(lnk_path, false)
                    -- _no_provider = 无 provider 时的哑对象(未查 DB), 行状态未知, 不能据此删行
                    if H.is_tbl(row) and not row._no_provider then
                        local meta_stuck = not row.has_meta
                        -- 封面卡死: 行标记已试过封面但没拿到, 而磁盘上封面已落盘
                        local cover_stuck = (not row.has_cover) and row.cover_fetched ~= nil
                            and DocSettings:findCustomCoverFile(lnk_path) ~= nil
                        if meta_stuck or cover_stuck then
                            BookInfoManager:deleteBookInfo(lnk_path)
                            repaired = repaired + 1
                        end
                    end
                end
            end
        end
        if repaired > 0 then
            logger.warn("browser.repairVolumeShortcutRows: deleted",
                repaired, "poisoned bookinfo rows (has_meta NULL) in", volume_folder)
            local fm = FileManager.instance
            if fm and fm.onRefresh then
                pcall(function()
                    fm:onRefresh()
                end)
            end
        end
    end

    -- 封面落盘后的定向行刷新: 封面是异步下载的, 行的首次提取可能先于封面完成
    -- ——提取时无封面则该行 has_cover 为空且 cover_fetched='Y', CoverBrowser
    -- 以"行存在"为准不会自动重试, 封面从此不再显示。
    -- 这里删掉该缓存行(纯 DB DELETE, 无事件广播), 下一次绘制时重新提取一次,
    -- ShortcutDocument 会读到刚落盘的封面。重绘做节流: 多个封面在短窗口内
    -- 先后落盘时只刷一次目录。
    function book_browser:invalidateShortcutRow(lnk_path)
        if not H.is_str(lnk_path) then
            return
        end
        pcall(function()
            local BookInfoManager = self:getBookInfoManager()
            if BookInfoManager and BookInfoManager.deleteBookInfo then
                BookInfoManager:deleteBookInfo(lnk_path)
            end
        end)
        pcall(function()
            local BookList = require("ui/widget/booklist")
            if BookList and BookList.resetBookInfoCache then
                BookList.resetBookInfoCache(lnk_path)
            end
        end)
        if not self._cover_repaint_scheduled then
            self._cover_repaint_scheduled = true
            UIManager:scheduleIn(1.5, function()
                self._cover_repaint_scheduled = nil
                local fm = FileManager.instance
                if fm and fm.onRefresh then
                    pcall(function()
                        fm:onRefresh()
                    end)
                end
            end)
        end
    end

    function book_browser:bind_provider(file)
        local doc_settings = DocSettings:open(file)
        local provider = doc_settings:readSetting("provider")
        if provider ~= "komga" then
            doc_settings:saveSetting("provider", "komga"):flush()
        end
        return doc_settings
    end

    function book_browser:refreshBookMetadata(lnk_name, lnk_path, bookinfo)
        lnk_name = lnk_name or (H.is_str(lnk_path) and select(2, util.splitFilePathName(lnk_path)))
        if not (util.fileExists(lnk_path) and H.is_str(lnk_name) and H.is_tbl(bookinfo) and bookinfo.cache_id and
            bookinfo.name) then
            logger.err("browser.refreshBookMetadata parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local doc_settings = self:bind_provider(lnk_path)
        if doc_settings and doc_settings.data then
            doc_settings.data = {}
            -- bind_provider 写入的 provider 被 data={} 清空, 必须重写, 否则点击快捷方式时 KOReader 不会分发到 komga provider
            doc_settings:saveSetting("provider", "komga")
            doc_settings:saveSetting("custom_props", {
                -- 作者串展示前去重(同上)
                authors = H.dedupeAuthors(bookinfo.author),
                title = bookinfo.name,
                description = bookinfo.intro,
                -- series: KOReader 文件管理器/封面浏览器按系列归组显示
                series = bookinfo.name,
                type = "serie"
                --type = bookinfo.type(serie,volume)
            })
            doc_settings:saveSetting("book_cache_id", book_cache_id)
            doc_settings:saveSetting("doc_props", {
                pages = bookinfo.booksCount,
                pageno = bookinfo.durChapterIndex
            })
            -- 系列行进度: 已读卷数/总卷数 -> CoverBrowser 列表进度条
            if H.is_num(bookinfo.booksCount) and bookinfo.booksCount > 0
                and H.is_num(bookinfo.durChapterIndex) and bookinfo.durChapterIndex > 0 then
                doc_settings:saveSetting("percent_finished",
                    math.min(bookinfo.durChapterIndex / bookinfo.booksCount, 1))
                doc_settings:saveSetting("doc_pages", bookinfo.booksCount)
            end
            doc_settings:flushCustomMetadata(lnk_path)
            self:deferMetadataChanged(lnk_path)
        end

        self:deferMetadataChanged(lnk_path)
    end

    -- 系列总阅读进度: 按各卷页数加权汇总后写入系列快捷方式 sidecar 的
    -- percent_finished/status, 取代 refreshBookMetadata 写入的"当前卷号/总卷数"
    -- 粗略近似(那个值把"正在读第 5 卷"显示成整体 5/N, 与读没读完该卷无关)。
    --   总进度 = Σ(每卷已读比例 × 该卷页数) / Σ(总页数)
    -- 每卷比例来源: DB isRead → 100%; 否则读卷快捷方式 sidecar 的 percent_finished
    -- (refreshVolumeMetadata/服务器进度同步已落盘); 页数用 DB 卷记录, 与比例同口径。
    -- 系列快捷方式不存在(未在书架/已删)时跳过, 不代建; 无变化不写 sidecar。
    function book_browser:refreshSeriesTotalProgress(book_cache_id, bookinfo)
        if not (H.is_str(book_cache_id) and H.is_tbl(bookinfo)
            and H.is_num(bookinfo.booksCount) and bookinfo.booksCount > 0) then
            return
        end
        local lv = self.parent
        local home_dir = lv and lv.getBrowserHomeDir and lv:getBrowserHomeDir(true)
        if not H.is_str(home_dir) then
            return
        end
        local lnk_path = self:getBookLnkPath(bookinfo, home_dir)
        if not (H.is_str(lnk_path) and util.fileExists(lnk_path)) then
            return
        end
        local model = KomgaModel:new(book_cache_id)
        local volumes = model:getVolumes()
        if not (H.is_tbl(volumes) and #volumes > 0) then
            return
        end
        local volume_folder = self:ensureVolumeFolder(book_cache_id, bookinfo)
        if not volume_folder then
            return
        end
        local sum_pages, sum_read = 0, 0
        for _, volume in ipairs(volumes) do
            if H.is_tbl(volume) and H.is_num(volume.number) then
                local full = model:getVolume(volume.number) -- 含 pages
                local pages = H.is_tbl(full) and H.is_num(full.pages) and full.pages or 0
                if pages > 0 then
                    local frac = 0
                    if volume.isRead == true then
                        frac = 1
                    else
                        local vol_lnk = self:writeVolLnk(volume, volume_folder, book_cache_id)
                        if H.is_str(vol_lnk) and util.fileExists(vol_lnk) then
                            -- LuaJIT 的 tonumber(nil) 会报错, 先按类型取值
                            local pf = DocSettings:open(vol_lnk):readSetting("percent_finished")
                            if not H.is_num(pf) and H.is_str(pf) then
                                pf = tonumber(pf)
                            end
                            if H.is_num(pf) then
                                frac = math.min(math.max(pf, 0), 1)
                            end
                        end
                    end
                    sum_pages = sum_pages + pages
                    sum_read = sum_read + frac * pages
                end
            end
        end
        if not (sum_pages > 0) then
            return
        end
        local percent = math.min(sum_read / sum_pages, 1)
        -- 生效值比较(0 与 nil 都视为"无进度"), 无变化跳过, 避免每次进目录都写 sidecar
        local ds = DocSettings:open(lnk_path)
        local old = ds:readSetting("percent_finished")
        if not H.is_num(old) and H.is_str(old) then
            old = tonumber(old)
        end
        if not H.is_num(old) or old <= 0 then
            old = nil
        end
        local new = percent > 0 and percent or nil
        if old == nil and new == nil then
            return
        end
        if old ~= nil and new ~= nil and math.abs(old - new) < 0.0001 then
            return
        end
        if new then
            ds:saveSetting("percent_finished", new)
            ds:saveSetting("doc_pages", bookinfo.booksCount)
        else
            ds:saveSetting("percent_finished", nil)
            ds:saveSetting("doc_pages", nil)
        end
        local summary = ds:readSetting("summary") or {}
        summary.status = (new ~= nil) and (new >= 0.999 and "complete" or "reading") or nil
        summary.modified = os.date("%Y-%m-%d")
        ds:saveSetting("summary", summary)
        ds:flush()
        -- 行的 percent/status 由 BookList 从 sidecar 直读并缓存在内存, 清条目让
        -- 下一次绘制(返回书架目录时的重列)即显示新值; 纯内存操作, 无事件广播
        pcall(function()
            local BookList = require("ui/widget/booklist")
            if BookList and BookList.resetBookInfoCache then
                BookList.resetBookInfoCache(lnk_path)
            end
        end)
        logger.info("browser.refreshSeriesTotalProgress:", bookinfo.name,
            string.format("%.1f%% (%.1f / %d pages)", percent * 100, sum_read, sum_pages))
    end

    parent.book_browser = book_browser
    return book_browser
end

local function init_book_menu(parent)
    if parent.book_menu then
        return parent.book_menu
    end
    local book_menu = Menu:new{
        name = "library_view",
        is_enable_shortcut = false,
        is_popout = false,
        title = "书架",
        with_context_menu = true,
        align_baselines = true,
        covers_fullscreen = true,
        title_bar_left_icon = "appbar.menu",
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        onLeftButtonTap = function()
            parent:openMenu()
        end,
        close_callback = function()
            Backend:closeDbManager()
        end,
        parent_ref = parent
    }

    if Device:hasKeys({"Home"}) or Device:hasDPad() then
        book_menu.key_events.Close = {{Device.input.group.Back}}
        book_menu.key_events.RefreshLibrary = {{"Home"}}
        book_menu.key_events.FocusRight = {{"Right"}}
    end

    function book_menu:onFocusRight()
        local focused_widget = Menu.getFocusItem(self)
        if focused_widget then

            local point = focused_widget.dimen:copy()
            point.x = point.x + point.w
            point.y = point.y + point.h / 2
            point.w = 0
            point.h = 0
            UIManager:sendEvent(Event:new("Gesture", {
                ges = "tap",
                pos = point
            }))
            return true
        end
    end
    function book_menu:onSwipe(arg, ges_ev)
        local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
        if direction == "south" then
            NetworkMgr:runWhenOnline(function()
                self:onRefreshLibrary()
            end)
            return
        end
        Menu.onSwipe(self, arg, ges_ev)
    end

    function book_menu:refreshItems(no_recalculate_dimen)
        local books_cache_data = Backend:getBookShelfCache()
        if H.is_tbl(books_cache_data) and #books_cache_data > 0 then
            self.item_table = self:generateItemTableFromMangas(books_cache_data)
            self.multilines_show_more_text = false
            self.items_per_page = nil
        else
            self.item_table = self:generateEmptyViewItemTable()
            self.multilines_show_more_text = true
            self.items_per_page = 1
        end
        self:updateItems(nil, no_recalculate_dimen)
    end

    function book_menu:onPrimaryMenuChoice(item)
        if item.continue_read then
            -- 直达上次阅读的那卷(走完整分卷打开/续读流程)
            self.parent_ref:openVolumeShortcut(item.cache_id, item.number, nil)
            return
        end
        local model = KomgaModel:new(item.cache_id)
        local bookinfo = model and model:getSeries() or nil
        self.parent_ref.selected_item = item
        self.parent_ref.onReturnCallback = function()
            self:show_view()
            self:refreshItems(true)
        end
        self.parent_ref.book_toc = ChapterListing:fetchAndShow({
            cache_id = bookinfo.cache_id,
            url = bookinfo.url,
            durChapterIndex = bookinfo.durChapterIndex,
            name = bookinfo.name,
            author = bookinfo.author,
            cacheExt = bookinfo.cacheExt
        }, self.parent_ref.onReturnCallback, function(chapter)
            self.parent_ref.instance:loadAndRenderChapter(chapter)
        end, true)
        UIManager:nextTick(function()
            Backend:autoPinToTop(bookinfo.cache_id, bookinfo.sortOrder)
            self.parent_ref:addBkShortcut(bookinfo)
        end)
        self:onClose()
    end

    function book_menu:onRefreshLibrary()
        -- beforeWifi 模式: 离线时提示联网, 联网后自动补跑(而非静默失败)
        if not NetworkMgr:isConnected() then
            MessageBox:notice("当前离线：连接网络后将自动刷新书架")
            NetworkMgr:runWhenOnline(function()
                pcall(function() self:onRefreshLibrary() end)
            end)
            return
        end
            Backend:closeDbManager()
            MessageBox:loading("Refreshing Library", function()
                return Backend:refreshLibraryCache(parent.ui_refresh_time)
            end, function(state, response)
                if state == true then
                    Backend:HandleResponse(response, function(data)
                        MessageBox:notice('同步成功')
                        self:refreshItems()
                        self.parent_ref.ui_refresh_time = os.time()
                    end, function(err_msg)
                        MessageBox:notice('同步失败', err_msg)
                    end)
                end
            end)
    end

    function book_menu:onMenuHold(item)
        local model = KomgaModel:new(item.cache_id)
        local bookinfo = model and model:getSeries() or nil
        local msginfo = [[
书名： <<%1>>
作者： %2
分类： %3
总卷数：%4
简介：%5
    ]]

        msginfo = T(msginfo, bookinfo.name or '', bookinfo.author or '', bookinfo.kind or '',
            bookinfo.booksCount or '', bookinfo.intro or '')

        MessageBox:confirm(msginfo, nil, {
            icon = "notice-info",
            no_ok_button = true,
            other_buttons_first = true,
            other_buttons = {{{
                text = (bookinfo.sortOrder > 0) and '置顶书籍' or '取消置顶',
                callback = function()
                    Backend:manuallyPinToTop(item.cache_id, bookinfo.sortOrder)
                    self:refreshItems(true)
                end
            }}, {{
                text = "快捷方式",
                callback = function()
                    UIManager:nextTick(function()
                        self.parent_ref:addBkShortcut(bookinfo, true)
                    end)
                    MessageBox:notice("已调用生成，请到 Home 目录查看")
                end
            }}, {{
                text = '删除',
                callback = function()
                    MessageBox:confirm(string.format(
                        "是否删除 <<%s>>？\r\n删除后关联记录会隐藏，重新添加可恢复",
                        bookinfo.name), function(result)
                        if result then
                            Backend:closeDbManager()
                            MessageBox:loading("删除中...", function()
                                Backend:deleteBook(bookinfo)
                                return Backend:refreshLibraryCache()
                            end, function(state, response)
                                if state == true then
                                    Backend:HandleResponse(response, function(data)
                                        MessageBox:notice("删除成功")
                                        self:refreshItems(true)
                                    end, function(err_msg)
                                        MessageBox:error('删除失败：', err_msg)
                                    end)
                                end
                            end)
                        end
                    end, {
                        ok_text = "删除",
                        cancel_text = "取消"
                    })

                end
            }}}
        })

    end

    function book_menu:onMenuSelect(entry, pos)
        if entry.select_enabled == false then
            return true
        end
        local selected_context_menu = pos ~= nil and pos.x > 0.8
        if selected_context_menu then
            self:onMenuHold(entry, pos)
        else
            self:onPrimaryMenuChoice(entry, pos)
        end
    end

    function book_menu:generateEmptyViewItemTable()
        return {{
            text = string.format("No books found in library. Try%s swiping down to refresh.",
                (Device:hasKeys({"Home"}) and ' Press the home button or ' or '')),
            dim = true,
            select_enabled = false
        }}
    end

    function book_menu:generateItemTableFromMangas(books)
        local item_table = {}
        -- 书架顶部"继续阅读": 最近读过且有进度定位的系列, 直达上次那卷
        for _, b in ipairs(books) do
            if H.is_num(b.durChapterIndex) and b.durChapterIndex > 0
                and H.is_num(b.lastRead) and b.lastRead > 0 then
                item_table[1] = {
                    continue_read = true,
                    cache_id = b.cache_id,
                    number = b.durChapterIndex,
                    text = string.format("%s 继续阅读: %s (卷 %s)", Icons.FA_PLAY,
                        tostring(b.name), tostring(b.durChapterIndex)),
                    mandatory = Icons.FA_PLAY,
                }
                break
            end
        end

        for _, bookinfo in ipairs(books) do

            local show_book_title = ("%s (%s)[%s]"):format(bookinfo.name or "未命名书籍",
                H.dedupeAuthors(bookinfo.author) or "未知作者", bookinfo.originName)

            table.insert(item_table, {
                cache_id = bookinfo.cache_id,
                text = show_book_title,
                mandatory = Icons.FA_ELLIPSIS_VERTICAL
            })
        end

        return item_table
    end

    function book_menu:show_view()
        UIManager:show(self)
    end

    parent.book_menu = book_menu
    return book_menu
end
    return init_book_browser, init_book_menu
end

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
local Font = require("ui/font")
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
local VolumePath = require("Komga/VolumePath")

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
        local current_dir = self.parent:getBrowserCurrentDir()
        if current_dir and current_dir == homedir then
            if not self.parent.book_menu then
                self.parent.book_menu = self.parent:getMenuWidget()
            end
            self.parent.book_menu:show_view()
            self.parent.book_menu:refreshItems(true)
            return
        end
        self.parent:openKomgaFolder(homedir, focused_file, selected_files)
    end

    function book_browser:goHome()
        if FileManager.instance then
            FileManager.instance:goHome()
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
    function book_browser:verifyBooksMetadata()
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

        util.findFiles(browser_homedir, function(fullpath, name)
            if not is_valid_book_file(fullpath, name) then
                goto continue
            end

            local book_cache_id = get_book_id(fullpath)
            if not book_cache_id then
                self:deleteFile(fullpath, true)
                goto continue
            end

            local model = KomgaModel:new(book_cache_id)
            local bookinfo = model and model:getSeries() or nil
            if not (H.is_tbl(bookinfo) and bookinfo.name) then
                self:deleteFile(fullpath, true)
                goto continue
            end

            -- 分卷快捷方式走卷级元数据修复，避免被重写为系列
            local customedata = self:getCustomMateData(fullpath)
            local number = H.is_tbl(customedata) and customedata.number or nil
            if H.is_tbl(customedata) and customedata.type == 'volume' and H.is_num(number) then
                self:refreshVolumeMetadata(nil, fullpath, book_cache_id, number, bookinfo)
            else
                self:refreshBookMetadata(nil, fullpath, bookinfo)
            end
            ::continue::
        end, true)
    end

    function book_browser:wirteLnk(bookinfo, home_dir)
        -- local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            logger.err("book_browser.wirteLnk: parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local book_name = bookinfo.name
        local book_author = bookinfo.author or "未知作者"

        local book_lnk_name = string.format("%s-%s" .. Paths.LNK_SUFFIX, book_name, book_author)
        book_lnk_name = util.getSafeFilename(book_lnk_name)
        if not book_lnk_name then
            logger.err("book_browser.wirteLnk: getSafeFilename error")
            return
        end
        local book_lnk_path = H.joinPath(home_dir, book_lnk_name)
        if book_lnk_path and util.fileExists(book_lnk_path) then
            return book_lnk_path, book_lnk_name
        end

        local book_lnk_config = Backend:getLuaConfig(book_lnk_path)
        book_lnk_config:saveSetting("book_cache_id", book_cache_id):flush()

        return book_lnk_path, book_lnk_name
    end

    function book_browser:getCustomMateData(filepath)
        local custom_metadata_file = DocSettings:findCustomMetadataFile(filepath)
        local props = custom_metadata_file and DocSettings.openSettingsFile(custom_metadata_file):readSetting("custom_props")
        if H.is_tbl(props) and props.number == nil and props.chapters_index ~= nil then
            props.number = props.chapters_index -- 兼容旧版快捷方式(升级前 custom_props 用 chapters_index 存卷号)
        end
        return props
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

        if not self:getCustomMateData(book_lnk_path) then
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
        local cover_url =  bookinfo.coverUrl
        if cover_url then
            Backend:runTaskWithRetry(function()
                if DocSettings:findCustomCoverFile(book_lnk_path) then
                    self:emitMetadataChanged(book_lnk_path)
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
                end
            end, {timeout = 120, tag = "series_cover"})
        end
    end

    function book_browser:addVolumeShortcut(bookinfo, seriename)
        -- 生成该系列分卷目录并同步各分卷快捷方式（不再写入 .sdr 隐藏目录）
        if not (H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            logger.err("addVolumeShortcut: parameter error")
            return
        end
        local volume_folder = self:ensureVolumeFolder(bookinfo.cache_id, bookinfo)
        if volume_folder then
            self:syncSeriesVolumes(bookinfo.cache_id, bookinfo, volume_folder)
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
        if H.is_tbl(custom) and H.is_tbl(custom.custom_props) and custom.custom_props.type == 'volume' and
            custom.custom_props.number == number and
            H.is_tbl(custom.doc_props) and custom.doc_props.pages == pages and custom.doc_props.pageno == pageno and
            custom.book_cache_id == book_cache_id and custom.number == number and
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
                authors = (H.is_tbl(bookinfo) and bookinfo.author) or volume.author,
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
            self:emitMetadataChanged(lnk_path)
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
                self:emitMetadataChanged(lnk_path)
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
        end, nil, {timeout = 120, tag = "volume_cover"})
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

    function book_browser:syncSeriesVolumes(book_cache_id, bookinfo, volume_folder)
        if not (H.is_str(book_cache_id) and H.is_tbl(bookinfo) and H.is_str(volume_folder)) then
            logger.err("syncSeriesVolumes parameter error")
            return
        end
        local volumes = KomgaModel:new(book_cache_id):getVolumes() -- Komga Book 列表(分卷)
        if not (H.is_tbl(volumes) and #volumes > 0) then
            return
        end
        for _, volume in ipairs(volumes) do
            if H.is_num(volume.number) then
                local lnk_path, lnk_name = self:writeVolLnk(volume, volume_folder, book_cache_id)
                if lnk_path and util.fileExists(lnk_path) then
                    self:refreshVolumeMetadata(lnk_name, lnk_path, book_cache_id, volume.number, bookinfo)
                    if not DocSettings:findCustomCoverFile(lnk_path) then
                        self:asyncDownloadVolumeCover(book_cache_id, volume, lnk_path)
                    end
                end
            end
        end
    end


    function book_browser:emitMetadataChanged(path)
        -- CoverBrowser 对每个文件有独立缓存行, 写完 sidecar 后必须删缓存行,
        -- 否则列表/网格一直显示旧元数据(文件名/无进度)
        pcall(function()
            local BookInfoManager = require("plugins/coverbrowser.koplugin/bookinfomanager")
            if BookInfoManager and BookInfoManager.deleteBookInfo then
                BookInfoManager:deleteBookInfo(path)
            end
        end)
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", path))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
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
                authors = bookinfo.author,
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
            self:emitMetadataChanged(lnk_path)
        end

        self:emitMetadataChanged(lnk_path)
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
        show_search_item = nil,
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
            cacheExt = bookinfo.cacheExt,
            origin = bookinfo.origin,
            originName = bookinfo.originName,
            originOrder = bookinfo.originOrder
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
                        self.show_search_item = true
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
        if self.show_search_item == true then
            item_table[1] = {
                text = string.format('%s Search...', Icons.FA_MAGNIFYING_GLASS),
                mandatory = "[Go]"
            }
            self.show_search_item = nil
        end

        for _, bookinfo in ipairs(books) do

            local show_book_title = ("%s (%s)[%s]"):format(bookinfo.name or "未命名书籍",
                bookinfo.author or "未知作者", bookinfo.originName)

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

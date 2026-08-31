local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local RenderImage = require("ui/renderimage")
local ImageViewer = require("ui/widget/imageviewer")
local logger = require("logger")
local dbg = require("dbg")
local Device = require("device")

local MessageBox = require("Komga/MessageBox")
local Backend = require("Komga/Backend")
local H = require("Komga/Helper")
local VolumePath = require("Komga/VolumePath")

local Screen = Device.screen

local M = ImageViewer:extend{
    bookinfo = nil,
    chapter = nil,
    chapter_imglist = {},
    chapter_imglist_cur = 1,
    on_return_callback = nil,
    stream_rtl_auto = nil, -- 自动 RTL: 由书籍 metadata.readingDirection 判定
    _image_is_bb = nil -- 本次取到的 self.image 已是 blitbuffer(双页拼合), 跳过再渲染
}

function M:init()
    ImageViewer.init(self)
end

function M:fetchAndShow(options)
    self.bookinfo = options.bookinfo
    self.chapter = options.chapter
    self.on_return_callback = options.on_return_callback

    local viewer = M:new{
        image = {self:loadChatperInitImage(self.chapter)},
        fullscreen = true,
        with_title_bar = false,
        image_disposable = true,
        images_list_nb = 4,
        image_padding = 0
    }
    UIManager:show(viewer)
end

function M:onClose()
    ImageViewer.onClose(self)
    self.chapter.current_page = self.chapter_imglist_cur
    -- 关卷清理流式页预取缓存(整目录删除, 不占长期磁盘)
    pcall(function()
        Backend:clearStreamPageCache(self.bookinfo and self.bookinfo.cache_id)
    end)
    Backend:closeDbManager()
    if H.is_tbl(self.chapter) and H.is_num(self.chapter_imglist_cur) then
        Backend:saveVolumeProgress(self.chapter)
        -- 与 ReaderUI 关闭路径一致: 把流式阅读的整卷比例落盘到快捷方式 sidecar 并刷新文件夹显示
        local okLV, LibraryView = pcall(require, "Komga/LibraryView")
        local inst = okLV and LibraryView and LibraryView.instance
        if inst and inst.persistStreamComicProgress then
            inst:persistStreamComicProgress(self.chapter, self.chapter_imglist_cur)
        end
        -- 阅读记录: 流式漫画关闭时把该分卷快捷方式写入 KOReader 历史(与 ReaderUI 缓存路径一致)
        if inst and inst.ensureVolumeShortcutForReading then
            pcall(function()
                local okRH, ReadHistory = pcall(require, "readhistory")
                local shortcut = inst:ensureVolumeShortcutForReading()
                if okRH and ReadHistory and ReadHistory.addItem and type(shortcut) == "string" then
                    ReadHistory:addItem(shortcut)
                end
            end)
        end
        -- if not (type(response) == 'table' and response.type == 'SUCCESS') then
        --     local message = (type(response) == 'table' and response.message) or
        --                         "进度上传失败，请稍后重试"
        --     return {
        --         type = 'ERROR',
        --         message = message
        --     }
        -- end
    end
    Backend:refreshLibraryCache()
    if H.is_func(self.on_return_callback) then
        self.on_return_callback()
    end
end

function M:onShowNextImage()
    if self:isDualPageEnabled() then
        self:turnDualPage(1)
    else
        self:getTurnPageNextImage('next', self.chapter_imglist_cur + 1)
    end
end

function M:onShowPrevImage()
    if self:isDualPageEnabled() then
        self:turnDualPage(-1)
    else
        self:getTurnPageNextImage('prev', self.chapter_imglist_cur - 1)
    end
end

-- 下载单页: 预取缓存命中直接读本地, 未命中走网络(与原行为一致)
function M:downloadPageImage(img_src)
    local cache_id = self.bookinfo and self.bookinfo.cache_id
    if H.is_str(cache_id) then
        local cached = Backend:lookupStreamPageCache(cache_id, img_src)
        if H.is_str(cached) then
            return cached
        end
    end
    return Backend:HandleResponse(Backend:pDownload_Image(img_src), function(data)
        if H.is_tbl(data) and data.data then
            return data.data
        else
            logger.warn("图片下载失败：", img_src)
            return
        end
    end, function(err_msg)
        return
    end)
end

-- 预取后几页(子进程后台, 静默失败) + 滑动窗口清理过旧缓存(保留当前页前 3 页供回翻)
function M:scheduleStreamPreload()
    local cache_id = self.bookinfo and self.bookinfo.cache_id
    if not (H.is_str(cache_id) and H.is_tbl(self.chapter_imglist) and #self.chapter_imglist > 0) then
        return
    end
    local cur = self.chapter_imglist_cur or 1
    local upcoming = {}
    for i = cur + 1, math.min(cur + 3, #self.chapter_imglist) do
        local src = self.chapter_imglist[i]
        if H.is_str(src) then
            table.insert(upcoming, src)
        end
    end
    for i = 1, cur - 4 do
        local src = self.chapter_imglist[i]
        if H.is_str(src) then
            pcall(function()
                Backend:removeStreamPageCache(cache_id, src)
            end)
        end
    end
    if #upcoming > 0 then
        pcall(function()
            Backend:preLoadStreamPages(cache_id, upcoming)
        end)
    end
end

-- ===========================================================================
-- 双页(对页)模式 — 移植自 comicreader.koplugin 的配对规则
--   设置 stream_dual_page: "auto"(默认, 横屏开)/"on"/"off"
--   设置 stream_dual_first_cover: 首页为封面时封面独占, 之后 (2,3)(4,5)...
--   设置 stream_rtl: nil=按书自动(metadata.readingDirection)/true/false(强制)
-- ===========================================================================

function M:isDualPageEnabled()
    local mode = Backend:getSettings().stream_dual_page or "auto"
    if mode == "on" then
        return true
    end
    if mode == "off" then
        return false
    end
    -- auto: 横屏自动开双页(每次判定, 旋转即生效)
    return Screen:getWidth() > Screen:getHeight()
end

function M:isRTL()
    local forced = Backend:getSettings().stream_rtl
    if forced ~= nil then
        return forced == true
    end
    return self.stream_rtl_auto == true
end

-- 当前页(基页)所在的页对, 返回按显示顺序的页号数组(RTL 时右→左)
function M:dualIndicesFor(cur)
    local first_cover = Backend:getSettings().stream_dual_first_cover ~= false
    local total = #self.chapter_imglist
    return VolumePath.dualPairFromBase(cur, total, first_cover, self:isRTL())
end

-- 两页并排拼合为单个 blitbuffer(顶部对齐)。
-- 不在此处做高度归一缩放: bb:scale 是纯 Lua 逐像素缩放(太慢),
-- 整体缩放交给 ImageViewer/ImageWidget 原生适配; 页尺寸不一致时顶对齐即可。
function M:composeDualPages(bb_list)
    local BlitBuffer = require("ffi/blitbuffer")
    local total_w, max_h = 0, 0
    for _, bb in ipairs(bb_list) do
        total_w = total_w + bb:getWidth()
        if bb:getHeight() > max_h then
            max_h = bb:getHeight()
        end
    end
    if total_w <= 0 or max_h <= 0 then
        return nil
    end
    local composed = BlitBuffer.new(total_w, max_h, bb_list[1]:getType())
    local x = 0
    for _, bb in ipairs(bb_list) do
        pcall(function()
            composed:blitFrom(bb, x, 0)
        end)
        x = x + bb:getWidth()
    end
    for _, bb in ipairs(bb_list) do
        pcall(function()
            bb:free()
        end)
    end
    return composed
end

-- 取图并渲染指定页号列表(双页时两张拼合), 返回 blitbuffer 或 nil。
-- 任一页失败则退化为能取到的页, 全部失败返回 nil。
function M:renderPagesAt(indices)
    local bbs = {}
    for _, idx in ipairs(indices or {}) do
        local src = self.chapter_imglist[idx]
        local data = H.is_str(src) and self:downloadPageImage(src) or nil
        if data then
            local ok, bb = pcall(function()
                return RenderImage:renderImageData(data, #data, false)
            end)
            if ok and bb then
                table.insert(bbs, bb)
            end
        end
    end
    if #bbs == 0 then
        return nil
    end
    if #bbs == 1 then
        return bbs[1]
    end
    return self:composeDualPages(bbs)
end

-- 双页模式翻页: 以页对为步进(direction = 1 下一对 / -1 上一对),
-- 越出本卷时复用单页路径的换章逻辑。
function M:turnDualPage(direction)
    local first_cover = Backend:getSettings().stream_dual_first_cover ~= false
    local total = #self.chapter_imglist
    local cur_base = VolumePath.dualBaseFromPage(self.chapter_imglist_cur or 1, first_cover)
    local next_base = cur_base + direction * 2
    if next_base > total then
        if direction > 0 then
            return self:getTurnPageNextImage('next', total + 1)
        end
        return
    end
    if next_base < 1 then
        if direction < 0 then
            return self:getTurnPageNextImage('prev', 0)
        end
        return
    end
    return self:getTurnPageNextImage(direction > 0 and 'next' or 'prev', next_base)
end

-- 双页与横屏绑定: 开双页自动转横屏(记住原方向); 关双页时若方向仍是我们
-- 设置的(用户未再手动旋转)则恢复。竖排本/横屏设备已横屏时不动作。
function M:autoRotateForDualMode(enabled)
    local rotated = false
    pcall(function()
        if enabled then
            if Screen:getWidth() > Screen:getHeight() then
                return -- 已是横屏
            end
            self._dual_prev_rotation = Screen:getRotationMode()
            self._dual_rotation_set = Screen.DEVICE_ROTATED_CLOCKWISE
            Screen:setRotationMode(self._dual_rotation_set)
            rotated = true
        else
            local prev = self._dual_prev_rotation
            local ours = self._dual_rotation_set
            self._dual_prev_rotation = nil
            self._dual_rotation_set = nil
            -- 仅当当前方向仍是我们设置的那个才恢复, 避免覆盖用户随后的手动旋转
            if prev ~= nil and ours ~= nil and Screen:getRotationMode() == ours then
                Screen:setRotationMode(prev)
                rotated = true
            end
        end
    end)
    if rotated then
        -- 旋转后全量重绘; ImageViewer.update 会按新屏幕尺寸重排
        UIManager:setDirty("all", "full")
    end
    return rotated
end

-- 阅读中手动切换 双页/单页: 点击屏幕中间 1/3 立即以当前页为基页重渲染。
-- 切换成功才落盘设置(在"自动·横屏"基础上切换会显式固定 on/off, 恢复自动走设置菜单);
-- 页面获取失败不改动设置, 静默提示。
function M:toggleDualPageMode()
    local want_dual = not self:isDualPageEnabled()
    local cur = self.chapter_imglist_cur or 1

    local image, is_bb
    if want_dual then
        image = self:renderPagesAt(self:dualIndicesFor(cur))
        is_bb = true
    else
        local src = self.chapter_imglist[cur]
        local data = H.is_str(src) and self:downloadPageImage(src) or nil
        image = data and self:get_image_bb(data) or nil
        is_bb = nil
    end
    if not image then
        Backend:show_notice("切换失败，页面获取失败")
        return true
    end

    local settings = Backend:getSettings()
    settings.stream_dual_page = want_dual and "on" or "off"
    pcall(function()
        Backend:saveSettings(settings)
    end)

    -- 双页绑定横屏: 开→自动转横屏, 关→恢复原方向(用户未再手动旋转时)
    self:autoRotateForDualMode(want_dual)

    if self.image and self.image.free then
        pcall(function()
            self.image:free()
        end)
    end
    self.image = image
    self._image_is_bb = is_bb
    self._images_list_cur = cur
    if not self.images_keep_pan_and_zoom then
        self._center_x_ratio = 0.5
        self._center_y_ratio = 0.5
        self.scale_factor = self._images_orig_scale_factor
    end
    self:update()
    -- e-ink: 图像页全刷+抖动
    if G_reader_settings and G_reader_settings:nilOrTrue("refresh_on_pages_with_images") then
        UIManager:setDirty(self, function()
            return "full", nil, true
        end)
    end
    self:scheduleStreamPreload()

    Backend:show_notice(want_dual and "双页模式：开" or "双页模式：关")
    return true
end

-- 中间 1/3 点击 -> 双页/单页切换(替代原生"按钮栏显隐"; 关闭仍可用下滑/多次滑动/返回键)
function M:onTap(_, ges)
    if ges and ges.pos and self.main_frame then
        if ges.pos:notIntersectWith(self.main_frame.dimen) then
            self:onClose()
            return true
        end
        local w = Screen:getWidth()
        if ges.pos.x > w / 3 and ges.pos.x < w * 2 / 3 then
            return self:toggleDualPageMode()
        end
    end
    return ImageViewer.onTap(self, _, ges)
end

function M:get_image_bb(imgData)
    imgData = imgData or self.image

    if not imgData then
        return RenderImage:renderImageFile("resources/koreader.png", false)
    end

    local image_bb = RenderImage:renderImageData(imgData, #imgData, false)
    if not image_bb then
        logger.warn("图片渲染失败，使用默认图片")
        image_bb = RenderImage:renderImageFile("resources/koreader.png", false)
    end

    return image_bb
end

function M:loadChatperInitImage(chapter)
    local new_chapter_imglist = Backend:getVolumePageUrls(chapter)
    if H.is_tbl(new_chapter_imglist) and #new_chapter_imglist > 0 then
        self.chapter_imglist = new_chapter_imglist
        local start_id = 1
        local response = Backend:getVolumeReadProgress(self.chapter)
        if H.is_tbl(response) and response.type == "SUCCESS" then
            -- print("BookId ...", response.body.id)
            -- for key, value in pairs(response) do
            --     print(string.format("key: %-15s  value: %s", 
            --         tostring(key), 
            --         type(value) == "table" and "{table}" or tostring(value)))
            -- end
            if response.body.readProgress == nil then
                start_id = 1
            else
                start_id = response.body.readProgress.page
            end
        end
        local img_src = self.chapter_imglist[start_id]

        -- 自动 RTL: 从 BookDto.metadata.readingDirection 判定(rtl/RTL/RIGHT_TO_LEFT)
        local meta = H.is_tbl(response.body) and response.body.metadata
        local dir = H.is_tbl(meta) and meta.readingDirection
        self.stream_rtl_auto = (dir == "rtl" or dir == "RTL" or dir == "RIGHT_TO_LEFT")

        self.chapter_imglist_cur = start_id

        if self:isDualPageEnabled() then
            -- 双页: 以续读页为基页渲染页对(已是 bb, 标记跳过尾部再渲染)
            self.image = self:renderPagesAt(self:dualIndicesFor(start_id))
            self._image_is_bb = true
        else
            local img_data = self:downloadPageImage(img_src)
            -- 渲染图片数据
            self.image = self:get_image_bb(img_data)
            self._image_is_bb = nil
        end

        self:scheduleStreamPreload()

        return self.image
    else
        logger.err("获取章节图片列表失败 Init")
        Backend:show_notice("内容加载失败")
        return RenderImage:renderImageFile("resources/koreader.png", false)
    end
end

function M:getTurnPageNextImage(call_event_type, image_num)

    if self.image and self.image_disposable and self.image.free then
        logger.dbg("释放当前图片资源：")
        self.image:free()
        self.image = nil
    end

    -- 初始化章节索引和图片列表游标
    local current_number = self.chapter.number
    local new_image_num = image_num
    local is_success = false

    -- 处理边界情况,向前翻页到章节开头
    if image_num == 0 then
        if current_number > 1 then
            current_number = current_number - 1
            logger.dbg("切换到上一章节：", current_number)
        else
            Backend:show_notice("已经是第一章")
            return
        end
        -- 处理正常翻页逻辑
    else
        local img_src = self.chapter_imglist[image_num]

        if H.is_str(img_src) then
            -- 取当前页(双页模式下取整个页对并拼合)
            if self:isDualPageEnabled() then
                self.image = self:renderPagesAt(self:dualIndicesFor(image_num))
                self._image_is_bb = true
            else
                self.image = self:downloadPageImage(img_src)
                self._image_is_bb = nil
            end
            if self.image then
                self.chapter_imglist_cur = image_num
                is_success = true
            end
        else
            -- 处理章节末页翻页
            local direction = call_event_type == 'next' and 1 or -1
            current_number = current_number + direction
            logger.dbg("已到达章节边界，切换到新章节：", current_number)
        end
    end

    -- 需要加载新章节内容的情况
    if not is_success then
        -- 更新章节索引并获取新章节的图片列表
        -- self.chapter.number = current_number
        self.chapter.current_page = self.chapter_imglist_cur
        Backend:saveVolumeProgress(self.chapter)
        self.chapter =  Backend:getVolumeInfoCache(self.bookinfo.cache_id,current_number)
        local new_chapter_imglist = Backend:getVolumePageUrls(self.chapter)

        if H.is_tbl(new_chapter_imglist) and #new_chapter_imglist > 0 then
            self.chapter_imglist = new_chapter_imglist
            -- 确定新章节的起始位置
            new_image_num = (call_event_type == 'next') and 1 or #self.chapter_imglist
            local img_src = self.chapter_imglist[new_image_num]

            if self:isDualPageEnabled() then
                self.image = self:renderPagesAt(self:dualIndicesFor(new_image_num))
                self._image_is_bb = true
            else
                self.image = self:downloadPageImage(img_src)
                self._image_is_bb = nil
            end
            if self.image then
                self.chapter_imglist_cur = new_image_num
                is_success = true
            end
        else
            logger.err("获取章节图片列表失败：", current_number)
            Backend:show_notice("内容加载失败" .. tostring(current_number))
            return
        end
    end


    if self.image then

        if type(self.image) == "function" then
            self.image = self.image()
        end

        if not self.images_keep_pan_and_zoom then
            self._center_x_ratio = 0.5
            self._center_y_ratio = 0.5
            self.scale_factor = self._images_orig_scale_factor
        end

        self._images_list_cur = new_image_num
        if self._image_is_bb then
            self._image_is_bb = nil -- 双页拼合已是 blitbuffer, 不再单独渲染
        else
            self.image = self:get_image_bb(self.image)
        end

        self:update()

        -- e-ink: 图像页全刷+抖动, 避免残影(对齐 ReaderView 图像页策略)
        if G_reader_settings and G_reader_settings:nilOrTrue("refresh_on_pages_with_images") then
            UIManager:setDirty(self, function()
                return "full", nil, true
            end)
        end

        -- 显示后预取后几页(子进程后台, 静默失败)
        self:scheduleStreamPreload()
    else
        logger.err("最终图片加载失败")
        Backend:show_notice("页面加载失败，请重试")
    end
end

function M:getTurnPageNextImageT(call_event_type, image_num)

    if self.image and self.image_disposable and self.image.free then
        logger.dbg("释放当前图片资源：")
        self.image:free()
        self.image = nil
    end

    local current_number = self.chapter.number
    local current_img_src = false

    if image_num == 0 then
        if current_number > 1 then
            current_number = current_number - 1
            logger.dbg("切换到上一章节：", current_number)
        else
            Backend:show_notice("已经是第一章")
            return
        end

    else
        local img_src = self.chapter_imglist[image_num]
        if H.is_str(img_src) then
            -- 获得img_src
            current_img_src = img_src
        else

            local direction = call_event_type == 'next' and 1 or -1
            current_number = current_number + direction
            logger.dbg("已到达章节边界，切换到新章节:", current_number)
        end
    end

    return MessageBox:loading("", function()

        local retData = {}
        if H.is_str(current_img_src) then

            local image_data = self:downloadPageImage(current_img_src)
            if image_data then
                retData['chapter_imglist_cur'] = image_num
                retData['self_image'] = image_data
            end
        else

            self.chapter.number = current_number
            local new_chapter_imglist = Backend:getVolumePageUrls(self.chapter)

            if H.is_tbl(new_chapter_imglist) and #new_chapter_imglist > 0 then
                retData['new_chapter_imglist'] = new_chapter_imglist

                local new_image_num = (call_event_type == 'next') and 1 or #new_chapter_imglist
                local img_src = self.chapter_imglist[new_image_num]

                local image_data = self:downloadPageImage(img_src)
                if image_data then
                    retData['chapter_imglist_cur'] = new_image_num
                    retData['self_image'] = image_data
                end
            end
        end

        return retData

    end, function(state, response)

        if state == true then

            if H.is_tbl(response['new_chapter_imglist']) and #response['new_chapter_imglist'] > 0 then
                self.chapter_imglist = response['new_chapter_imglist']
            end

            self.image = response['self_image']

            if self.image then

                if not self.images_keep_pan_and_zoom then
                    self._center_x_ratio = 0.5
                    self._center_y_ratio = 0.5
                    self.scale_factor = self._images_orig_scale_factor
                end

                self.image = self:get_image_bb(self.image)
                self.chapter_imglist_cur = response['chapter_imglist_cur']

                self:update()
            else
                logger.err("最终图片加载失败")
                Backend:show_notice("页面加载失败，请重试")
            end
        end
    end)
end

return M

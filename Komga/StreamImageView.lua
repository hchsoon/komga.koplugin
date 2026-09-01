local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local RenderImage = require("ui/renderimage")
local ImageViewer = require("ui/widget/imageviewer")
local logger = require("logger")
local dbg = require("dbg")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local _ = require("gettext")

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

-- 自绘: 整屏铺白 + main_frame 按"当前屏幕"手工居中。
-- 不走原生 WidgetContainer 定位链——布局日志实测旋转后首帧仍拿旧方向宽度定位
-- (x=-308=(旧宽1150-新内容1766)/2), 上游多处缓存(region/dimen/window 记录)在
-- 旋转后并不全部失效; 自己计算偏移可彻底绕开。FrameContainer 只画内容区的白底
-- 问题(留白透出旧画面)也一并由整屏铺白解决。
function M:paintTo(bb, x, y)
    local ok = pcall(function()
        local w = Screen:getWidth()
        local h = Screen:getHeight()
        bb:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
        if self.main_frame then
            local content_size = self.main_frame:getSize()
            self.main_frame:paintTo(bb,
                math.floor((w - content_size.w) / 2),
                math.floor((h - content_size.h) / 2))
        end
    end)
    if not ok then
        ImageViewer.paintTo(self, bb, x, y)
    end
end

function M:init()
    ImageViewer.init(self)
    -- 在原生按钮栏(缩放/旋转/关闭)基础上追加 双页/RTL 快捷按钮。
    -- 原生按钮表在 ImageViewer.init 内部是局部量无法追加, 这里按同参数重建
    -- ButtonTable(保留 scale/rotate/close 的 id, update() 会按 id 刷新其文案)。
    -- 不改任何手势: 点击/滑动/双指均为 KOReader 原生行为(中间点击呼出本按钮栏)。
    if self.button_table and self.button_container then
        local buttons = {
            {
                {
                    id = "scale",
                    text = self._scale_to_fit and _("Original size") or _("Scale"),
                    callback = function()
                        self.scale_factor = self._scale_to_fit and 1 or 0
                        self._scale_to_fit = not self._scale_to_fit
                        self._center_x_ratio = 0.5
                        self._center_y_ratio = 0.5
                        self:update()
                    end,
                },
                {
                    id = "rotate",
                    text = self.rotated and _("No rotation") or _("Rotate"),
                    callback = function()
                        self.rotated = not self.rotated and true or false
                        self:update()
                    end,
                },
                {
                    id = "close",
                    text = _("Close"),
                    callback = function()
                        self:onClose()
                    end,
                },
            },
            {
                {
                    id = "dual",
                    text = _("双页"),
                    callback = function()
                        self:toggleDualPageMode()
                    end,
                },
                {
                    id = "rtl",
                    text = _("RTL"),
                    callback = function()
                        self:toggleRTLMode()
                    end,
                },
            },
        }
        self.button_table = ButtonTable:new{
            width = self.width - 2 * self.button_padding,
            buttons = buttons,
            zero_sep = true,
            show_parent = self,
        }
        self.button_container = CenterContainer:new{
            dimen = Geom:new{
                w = self.width,
                h = self.button_table:getSize().h,
            },
            self.button_table,
        }
    end
end

function M:fetchAndShow(options)
    self.bookinfo = options.bookinfo
    self.chapter = options.chapter
    self.on_return_callback = options.on_return_callback
    -- 方向隔离: 记录进入阅读器时的屏幕方向, 关闭时恢复, 阅读中的旋转不影响主界面
    self._entry_rotation_mode = Screen:getRotationMode()

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
    -- 方向隔离: 关闭前恢复进入时的屏幕方向(背后的主界面按原方向重排后再关闭),
    -- 阅读器内的双页/旋转操作不会把主界面留在横屏
    if H.is_num(self._entry_rotation_mode)
        and Screen:getRotationMode() ~= self._entry_rotation_mode then
        self:setScreenRotation(self._entry_rotation_mode)
    end
    self._entry_rotation_mode = nil

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

-- 取指定页的显示内容: 双页模式取页对拼合 bb(失败退回单页数据), 单页模式取页数据。
-- 返回 (image, is_bb); 全部失败返回 (nil, nil), 调用方须保留当前画面, 不能把
-- nil 传给 update()(ImageWidget 会对 nil 调 getWidth 而崩溃)。
function M:fetchDisplayImage(image_num)
    local src = self.chapter_imglist[image_num]
    if self:isDualPageEnabled() then
        local pair_bb = self:renderPagesAt(self:dualIndicesFor(image_num))
        if pair_bb then
            return pair_bb, true
        end
        -- 页对失败: 退回单页(数据由尾部统一渲染), 避免整次翻页失败
    end
    local data = H.is_str(src) and self:downloadPageImage(src) or nil
    if data then
        return data, nil
    end
    return nil, nil
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

-- 程序化旋转后的同步重绘。
-- update() 不足以清掉布局链上的尺寸缓存(main_frame.dimen/region/手势范围都是
-- init 时构建、要到下一次 paint 才更新, 而 paint 又拿旧 dimen 定位)——日志实测
-- 旋转后首帧仍按旧方向布局(如横屏下 main_frame 还是竖屏尺寸), 表现为图像贴底/
-- 出界。这里把当前画面包装回构造入参形态后整体重跑 M:init, 按当前屏幕重建
-- 全部部件(含手势注册), 再全刷强制立即绘制。
function M:repaintAfterRotation()
    local ok_rebuild, rebuild_err = pcall(function()
        if self.image == nil or (self.image.getWidth == nil and type(self.image) ~= "string" and type(self.image) ~= "function") then
            -- 此前渲染失败可能留下空画面: 重建前先恢复占位图,
            -- 否则 ImageWidget 对 nil 调 getWidth 直接崩溃
            self.image = self:get_image_bb(nil)
            self._image_is_bb = nil
        end
        if self.image and self.image.getWidth then
            self.image = {self.image} -- 模拟构造入参(图片列表), 让 init 走列表分支
        end
        local saved_cur = self._images_list_cur
        self:init()
        -- init 会把列表游标重置为 1, 恢复当前页(进度条/后续翻页依据)
        if H.is_num(saved_cur) then
            self._images_list_cur = saved_cur
        end
    end)
    if not ok_rebuild then
        -- 重建失败不静默: 记录错误(paintTo 的手工居中仍可兜底显示)
        logger.err("[komga-layout] rebuild after rotation failed:", tostring(rebuild_err))
    end
    UIManager:setDirty("all", "full")
    pcall(function()
        UIManager:forceRePaint()
    end)
end

-- 旋转屏幕并同步重绘。
-- 注意: 不能广播 KOReader 的 SetRotationMode 事件——FileManager 的处理函数是
-- rotate = reinit(filemanager.lua), 会关闭重建自身, 把叠在上面的本阅读器一并
-- 关掉(且不走本类 onClose, 方向恢复也不会执行), 表现为"切双页立即退回主界面"。
-- 直设坐标即可: 本阅读器全屏白底盖住背景, 背景旧布局不可见; 关闭时恢复进入
-- 方向后, 背后窗口的布局缓存本就对应原方向, 重绘自然对齐。
function M:setScreenRotation(mode)
    if not H.is_num(mode) or Screen:getRotationMode() == mode then
        return false
    end
    local ok = pcall(function()
        Screen:setRotationMode(mode)
    end)
    self:repaintAfterRotation()
    return ok
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
            self:setScreenRotation(self._dual_rotation_set)
            rotated = true
        else
            local prev = self._dual_prev_rotation
            local ours = self._dual_rotation_set
            self._dual_prev_rotation = nil
            self._dual_rotation_set = nil
            -- 仅当当前方向仍是我们设置的那个才恢复, 避免覆盖用户随后的手动旋转
            if prev ~= nil and ours ~= nil and Screen:getRotationMode() == ours then
                self:setScreenRotation(prev)
                rotated = true
            end
        end
    end)
    return rotated
end

-- 阅读中手动切换 双页/单页: 点击屏幕中间 1/3 立即以当前页为基页重渲染。
-- 切换成功才落盘设置(在"自动·横屏"基础上切换会显式固定 on/off, 恢复自动走设置菜单);
-- 页面获取失败不改动设置, 静默提示。
-- 按当前(或指定)双页状态重渲染当前页并显示; 成功返回 true, 获取失败返回 false(不改动显示)
function M:redisplayCurrent(force_dual)
    local dual = (force_dual ~= nil) and force_dual or self:isDualPageEnabled()
    local cur = self.chapter_imglist_cur or 1

    local image, is_bb
    if dual then
        image = self:renderPagesAt(self:dualIndicesFor(cur))
        is_bb = true
    else
        local src = self.chapter_imglist[cur]
        local data = H.is_str(src) and self:downloadPageImage(src) or nil
        image = data and self:get_image_bb(data) or nil
        is_bb = nil
    end
    if not image then
        return false
    end

    if self.image and self.image.free then
        pcall(function()
            self.image:free()
        end)
    end
    self.image = image
    self._image_is_bb = is_bb
    self._images_list_cur = cur
    -- 强制回到"适配屏幕"并重置取景中心: 双页拼合 bb 尺寸随页对变化,
    -- 沿用旧 scale_factor/中心比会把大图按原始尺寸偏移绘制(表现为贴底/出界)
    self._center_x_ratio = 0.5
    self._center_y_ratio = 0.5
    self.scale_factor = 0
    self:update()
    -- e-ink: 图像页全刷+抖动
    if G_reader_settings and G_reader_settings:nilOrTrue("refresh_on_pages_with_images") then
        UIManager:setDirty(self, function()
            return "full", nil, true
        end)
    end
    self:scheduleStreamPreload()
    return true
end

function M:toggleDualPageMode()
    local want_dual = not self:isDualPageEnabled()

    local settings = Backend:getSettings()
    local prev_mode = settings.stream_dual_page
    -- 先落盘(临时), 让 isDualPageEnabled/fetchDisplayImage 在重渲染时按目标模式取图
    settings.stream_dual_page = want_dual and "on" or "off"

    -- 先转屏后渲染: 双页拼合应按最终屏幕方向布局(避免"竖屏渲染→横屏重排"
    -- 的双重 update 留下过期尺寸, 造成图像偏移/贴底)
    self:autoRotateForDualMode(want_dual)

    -- 按目标模式渲染; 成功才保留设置, 失败回滚并静默提示
    if not self:redisplayCurrent(want_dual) then
        settings.stream_dual_page = prev_mode
        pcall(function()
            Backend:saveSettings(settings)
        end)
        self:autoRotateForDualMode(not want_dual)
        Backend:show_notice("切换失败，页面获取失败")
        return true
    end

    pcall(function()
        Backend:saveSettings(settings)
    end)

    self:dumpLayoutState("toggle:" .. tostring(want_dual))

    Backend:show_notice(want_dual and "双页模式：开" or "双页模式：关")
    return true
end

-- 布局诊断日志(定位图像偏移/贴底问题): 打到 crash.log / stdout 的 logger.info,
-- 排查完成后可整体删除
function M:dumpLayoutState(tag)
    pcall(function()
        local mf = self.main_frame and self.main_frame.dimen
        local ic = self.image_container and self.image_container.dimen
        local img = self.image
        logger.info(string.format(
            "[komga-layout] %s screen=%dx%d self=%sx%s imgc_h=%s main_frame=%s img_ctr=%s img=%dx%d scale=%s c=(%s,%s)",
            tostring(tag),
            Screen:getWidth(), Screen:getHeight(),
            tostring(self.width), tostring(self.height),
            tostring(self.img_container_h),
            mf and string.format("%dx%d@%d,%d", mf.w, mf.h, mf.x, mf.y) or "nil",
            ic and string.format("%dx%d", ic.w, ic.h) or "nil",
            (img and img.getWidth) and img:getWidth() or -1,
            (img and img.getHeight) and img:getHeight() or -1,
            tostring(self.scale_factor),
            tostring(self._center_x_ratio), tostring(self._center_y_ratio)))
    end)
end

-- RTL 切换(按钮栏快捷键): 写入设置项 stream_rtl 显式强制开/关
-- (恢复"按书自动"走设置菜单); 双页模式立即镜像重排当前页对。
function M:toggleRTLMode()
    local settings = Backend:getSettings()
    settings.stream_rtl = not self:isRTL()
    pcall(function()
        Backend:saveSettings(settings)
    end)
    if self:isDualPageEnabled() then
        pcall(function()
            self:redisplayCurrent()
        end)
    end
    Backend:show_notice(self:isRTL() and "RTL：开" or "RTL：关")
    return true
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
            -- 双页: 以续读页为基页渲染页对(已是 bb, 标记跳过尾部再渲染);
            -- 页对失败退回单页, 再失败用占位图(update 前绝不能是 nil)
            local pair_bb = self:renderPagesAt(self:dualIndicesFor(start_id))
            if pair_bb then
                self.image = pair_bb
                self._image_is_bb = true
            else
                local img_data = self:downloadPageImage(img_src)
                self.image = self:get_image_bb(img_data)
                self._image_is_bb = nil
            end
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
            -- 取当前页(双页模式下取整个页对并拼合; 页对失败退回单页)
            local display, is_bb = self:fetchDisplayImage(image_num)
            if display then
                self.image = display
                self._image_is_bb = is_bb
                self.chapter_imglist_cur = image_num
                is_success = true
            else
                -- 获取失败: 保留当前画面并提示, 不落入下方换章分支
                Backend:show_notice("页面加载失败，请重试")
                return
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

            local display, is_bb = self:fetchDisplayImage(new_image_num)
            if display then
                self.image = display
                self._image_is_bb = is_bb
                self.chapter_imglist_cur = new_image_num
                is_success = true
            else
                -- 获取失败: 不把 nil 交给尾部渲染(空画面崩溃), 提示后保留返回
                Backend:show_notice("页面加载失败，请重试")
                return
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
        if self._image_is_bb and self.image and self.image.getWidth then
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

local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local RenderImage = require("ui/renderimage")
local ImageViewer = require("ui/widget/imageviewer")
local logger = require("logger")
local dbg = require("dbg")

local MessageBox = require("Komga/MessageBox")
local Backend = require("Komga/Backend")
local H = require("Komga/Helper")

local M = ImageViewer:extend{
    bookinfo = nil,
    chapter = nil,
    chapter_imglist = {},
    chapter_imglist_cur = 1,
    on_return_callback = nil
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
    self:getTurnPageNextImage('next', self.chapter_imglist_cur + 1)
end

function M:onShowPrevImage()
    self:getTurnPageNextImage('prev', self.chapter_imglist_cur - 1)
end

local function downloadImage(img_src)
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
        local img_data = downloadImage(img_src)

        -- 渲染图片数据
        self.image = self:get_image_bb(img_data)

        self.chapter_imglist_cur = start_id

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
    local current_chapter_index = self.chapter.chapters_index
    local new_image_num = image_num
    local is_success = false

    -- 处理边界情况,向前翻页到章节开头
    if image_num == 0 then
        if current_chapter_index > 1 then
            current_chapter_index = current_chapter_index - 1
            logger.dbg("切换到上一章节：", current_chapter_index)
        else
            Backend:show_notice("已经是第一章")
            return
        end
        -- 处理正常翻页逻辑
    else
        local img_src = self.chapter_imglist[image_num]

        if H.is_str(img_src) then
            -- 尝试下载当前图片
            self.image = downloadImage(img_src)
            if self.image then
                self.chapter_imglist_cur = image_num
                is_success = true
            end
        else
            -- 处理章节末页翻页
            local direction = call_event_type == 'next' and 1 or -1
            current_chapter_index = current_chapter_index + direction
            logger.dbg("已到达章节边界，切换到新章节：", current_chapter_index)
        end
    end

    -- 需要加载新章节内容的情况
    if not is_success then
        -- 更新章节索引并获取新章节的图片列表
        -- self.chapter.chapters_index = current_chapter_index
        self.chapter.current_page = self.chapter_imglist_cur
        Backend:saveVolumeProgress(self.chapter)
        self.chapter =  Backend:getVolumeInfoCache(self.bookinfo.cache_id,current_chapter_index)
        local new_chapter_imglist = Backend:getVolumePageUrls(self.chapter)

        if H.is_tbl(new_chapter_imglist) and #new_chapter_imglist > 0 then
            self.chapter_imglist = new_chapter_imglist
            -- 确定新章节的起始位置
            new_image_num = (call_event_type == 'next') and 1 or #self.chapter_imglist
            local img_src = self.chapter_imglist[new_image_num]

            self.image = downloadImage(img_src)
            if self.image then
                self.chapter_imglist_cur = new_image_num
                is_success = true
            end
        else
            logger.err("获取章节图片列表失败：", current_chapter_index)
            Backend:show_notice("内容加载失败" .. tostring(current_chapter_index))
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
        self.image = self:get_image_bb(self.image)

        self:update()
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

    local current_chapter_index = self.chapter.chapters_index
    local current_img_src = false

    if image_num == 0 then
        if current_chapter_index > 1 then
            current_chapter_index = current_chapter_index - 1
            logger.dbg("切换到上一章节：", current_chapter_index)
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
            current_chapter_index = current_chapter_index + direction
            logger.dbg("已到达章节边界，切换到新章节:", current_chapter_index)
        end
    end

    return MessageBox:loading("", function()

        local retData = {}
        if H.is_str(current_img_src) then

            local image_data = downloadImage(current_img_src)
            if image_data then
                retData['chapter_imglist_cur'] = image_num
                retData['self_image'] = image_data
            end
        else

            self.chapter.chapters_index = current_chapter_index
            local new_chapter_imglist = Backend:getVolumePageUrls(self.chapter)

            if H.is_tbl(new_chapter_imglist) and #new_chapter_imglist > 0 then
                retData['new_chapter_imglist'] = new_chapter_imglist

                local new_image_num = (call_event_type == 'next') and 1 or #new_chapter_imglist
                local img_src = self.chapter_imglist[new_image_num]

                local image_data = downloadImage(img_src)
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

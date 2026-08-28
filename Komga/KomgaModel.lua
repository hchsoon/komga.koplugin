--[[
Komga/KomgaModel.lua — Komga 数据模型层

本文件梳理清楚 Komga 的三级层级关系，并把数据访问统一封装成语义化 accessor，
业务代码（LibraryView / book_browser / book_menu）不再散落直接调用
Backend:getBookInfoCache / getBookChapterCache / getChapterInfoCache。

━━━ 名词对照（重要：插件内部命名与 Komga 官方名词不同）━━━
  Komga 官方        插件 DB/代码          主键                       说明
  ---------------   -------------------  -----------------------   ---------------------------
  Series             books 表 一行        book_cache_id              书架上的一个"系列"
                    = bookinfo             如《堀与宫村》(0MCXY80WM4JY5)
  Book(单卷)         chapters 表 一行      (book_cache_id,          系列内的一个"分卷/章"
                    = chapter/vol           chapterIndex)             服务器 ID = chapter.bookId
  Chapter(书内章)    epubchapters 表 一行   (chapterId,               EPUB 书内部的章节
                    = epub_chapter           chapterIndex)            仅 EPUB 类型才有

━━━ 层级关系 ━━━
  Series(books 表)                                     ← 插件里的 "book" / bookinfo
   └── Volume ×N(chapters 表)                          ← 插件里的 "chapter" / vol
        └── EpubChapter ×N(epubchapters 表)            ← 仅 EPUB，插件内部章节
]]

local Backend = require("Komga/Backend")
local H = require("Komga/Helper")

local KomgaModel = {}

function KomgaModel:new(book_cache_id)
    if not H.is_str(book_cache_id) then
        return nil
    end
    return setmetatable({ book_cache_id = book_cache_id }, { __index = KomgaModel })
end

-- 当前模型对应的系列 ID
function KomgaModel:getBookCacheId()
    return self.book_cache_id
end

-- ===== Series(系列) =====

-- 系列信息(books 表 → Komga Series)
-- 返回 bookinfo: cache_id/name/author/totalChapterNum/durChapterIndex/coverUrl/intro ...
function KomgaModel:getSeries()
    return Backend:getBookInfoCache(self.book_cache_id)
end

-- 系列名（常用，快捷便利方法）
function KomgaModel:getSeriesName()
    local series = self:getSeries()
    return series and series.name or nil
end

-- ===== Volume(分卷) =====

-- 全部分卷列表(chapters 表 → Komga Book)，按 chapterIndex 排序
-- 返回 chapter 数组: chapters_index/title/bookId/isRead/isDownLoaded/cacheFilePath/durChapterIndex
function KomgaModel:getVolumes()
    return Backend:getBookChapterCache(self.book_cache_id)
end

-- 分卷总数（= 系列卷数）
function KomgaModel:getVolumeCount()
    local volumes = self:getVolumes()
    return volumes and #volumes or 0
end

-- 按 Komga Book(卷)的 bookId 反查卷号(volume.chapters_index)。
-- EPUB 翻章后拿到的内部章节对象 chapters_index 是内部 index, 上传/刷新必须用卷号。
function KomgaModel:getVolumeIndexByBookId(bookId)
    if not H.is_str(bookId) then
        return nil
    end
    for _, vol in ipairs(self:getVolumes() or {}) do
        if H.is_tbl(vol) and vol.bookId == bookId and H.is_num(vol.chapters_index) then
            return vol.chapters_index
        end
    end
    return nil
end

-- 按 Komga Book(卷)的 bookId 取卷总页数(服务器口径)。
-- EPUB 翻章后 chapter.pages 可能丢失, 用于兜底。
function KomgaModel:getVolumePages(bookId)
    if not H.is_str(bookId) then
        return nil
    end
    for _, vol in ipairs(self:getVolumes() or {}) do
        if H.is_tbl(vol) and vol.bookId == bookId and H.is_num(vol.pages) and vol.pages > 0 then
            return vol.pages
        end
    end
    return nil
end

-- 单个分卷完整信息(含 pages/mediaType/bookId/cacheFilePath/title/isRead)
-- chapter_index 为该卷在系列内的序号(1..N)，对应快捷方式文件名里的卷号
function KomgaModel:getVolume(chapter_index)
    if not H.is_num(chapter_index) then
        return nil
    end
    return Backend:getChapterInfoCache(self.book_cache_id, chapter_index)
end

-- ===== EpubChapter(书内章节) =====

-- 某分卷的 EPUB 内部章节列表(epubchapters 表 → Komga Chapter)
-- volume 传入 getVolume 返回的分卷(chapter 表行)
-- 返回 epub_chapter 数组: chapterIndex/title/chapterId/cacheFilePath/isRead
function KomgaModel:getEpubChapters(volume)
    if not H.is_tbl(volume) then
        return {}
    end
    return Backend:getAllEpubChapters(volume)
end

-- ===== 完整层级树（供展示/理解/调试） =====

-- 返回 { series = bookinfo, volumes = { { volume = chapter, epub_chapters = {...} } } }
function KomgaModel:getHierarchy()
    local hierarchy = {
        series = self:getSeries(),
        volumes = {},
    }
    for _, vol in ipairs(self:getVolumes() or {}) do
        local node = {
            volume = vol,
            epub_chapters = {},
        }
        -- getVolumes 缺 mediaType，用 getVolume 补全(含 pages/mediaType)，失败则退回列表行
        local full = self:getVolume(vol.chapters_index)
        if H.is_tbl(full) and H.is_str(full.mediaType) then -- full 非表即短路，避免取 nil 字段
            node.volume = full
        end
        if node.volume.mediaType == "EPUB" then
            node.epub_chapters = self:getEpubChapters(node.volume)
        end
        hierarchy.volumes[#hierarchy.volumes + 1] = node
    end
    return hierarchy
end

return KomgaModel

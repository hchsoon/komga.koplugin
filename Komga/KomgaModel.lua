--[[
Komga/KomgaModel.lua — Komga 数据模型层

本文件梳理清楚 Komga 的三级层级关系，并把数据访问统一封装成语义化 accessor，
业务代码（LibraryView / book_browser / book_menu）不再散落直接调用
Backend:getSeriesInfoCache / getVolumesCache / getVolumeInfoCache。

━━━ 名词对照（重要：插件内部命名与 Komga 官方名词不同）━━━
  Komga 官方        插件 DB/代码          主键                       说明
  ---------------   -------------------  -----------------------   ---------------------------
  Series             series 表 一行        book_cache_id              书架上的一个"系列"
                    = bookinfo             如《堀与宫村》(0MCXY80WM4JY5)
  Book(单卷)         volume 表 一行        (book_cache_id,          系列内的一个"分卷"
                    = vol                  number)             服务器 ID = bookId
  Chapter(书内章)    epub_chapter 表 一行   (chapterId,               EPUB 书内部的章节
                    = epub_chapter          number)            仅 EPUB 类型才有

━━━ 层级关系 ━━━
  Series(series 表)                                     ← 插件里的 "book" / bookinfo
   └── Volume ×N(volume 表)                            ← 插件里的 "vol"
        └── EpubChapter ×N(epub_chapter 表)            ← 仅 EPUB，插件内部章节
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

-- ===== Series(系列) =====

-- 系列信息(series 表 → Komga Series)
-- 返回 bookinfo: cache_id/name/author/booksCount/durChapterIndex/coverUrl/intro ...
function KomgaModel:getSeries()
    return Backend:getSeriesInfoCache(self.book_cache_id)
end

-- ===== Volume(分卷) =====

-- 全部分卷列表(volume 表 → Komga Book)，按 number 排序
-- 返回 volume 数组: number/title/bookId/isRead/isDownLoaded/cacheFilePath/durChapterIndex
function KomgaModel:getVolumes()
    return Backend:getVolumesCache(self.book_cache_id)
end

-- 按 Komga Book(卷)的 bookId 反查卷号(volume.number)。
-- EPUB 翻章后拿到的内部章节对象 number 是内部 index, 上传/刷新必须用卷号。
function KomgaModel:getVolumeIndexByBookId(bookId)
    if not H.is_str(bookId) then
        return nil
    end
    for _, vol in ipairs(self:getVolumes() or {}) do
        if H.is_tbl(vol) and vol.bookId == bookId and H.is_num(vol.number) then
            return vol.number
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
-- number 为该卷在系列内的序号(1..N)，对应快捷方式文件名里的卷号
function KomgaModel:getVolume(number)
    if not H.is_num(number) then
        return nil
    end
    return Backend:getVolumeInfoCache(self.book_cache_id, number)
end

return KomgaModel

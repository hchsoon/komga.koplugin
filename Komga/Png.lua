local ffi = require("ffi")
local bit = require("bit")
require("ffi/lodepng_h")

local lodepng = ffi.loadlib("lodepng")

local Png = {}

function Png.toGrayscale(pixels, w, h, ncomp)
    -- ncomp: 解码后每像素分量数(1=灰度, 2=灰度+alpha, 3=RGB, 4=RGBA)。
    -- 此前对任意 ncomp 都做三分量加权: ncomp=1/2 时 index+1/+2 读到的是
    -- 相邻像素/alpha, 结果错误; ncomp=1 直接整块 memcpy。
    local data = ffi.cast("uint8_t*", pixels)
    local width, height = w, h
    ncomp = ncomp or 1

    local gray_data = ffi.new("uint8_t[?]", width * height)
    local total = width * height

    if ncomp == 1 then
        ffi.copy(gray_data, data, total)
        return gray_data
    end

    if ncomp == 2 then
        -- (gray, alpha): 只取第 0 分量, 按步长 2 逐像素拷贝
        for i = 0, total - 1 do
            gray_data[i] = data[i * 2]
        end
        return gray_data
    end

    -- RGB/RGBA: 整数定点权值 (77,151,28)/256 ≈ (0.299,0.587,0.114),
    -- 纯整数运算免去每像素浮点转换, 对 LuaJIT 更友好
    local width_ncomp = width * ncomp
    for y = 0, height - 1 do
        local index = y * width_ncomp
        local out = y * width
        for _ = 1, width do
            gray_data[out] = bit.rshift(
                data[index] * 77 + data[index + 1] * 151 + data[index + 2] * 28, 8)
            index = index + ncomp
            out = out + 1
        end
    end
    return gray_data
end

function Png.processImage(func, image_data, req_n)
    local fdata = image_data
    local ptr = ffi.new("unsigned char*[1]")
    local width, height = ffi.new("int[1]"), ffi.new("int[1]")
    local state = ffi.new("LodePNGState[1]")

    lodepng.lodepng_state_init(state)
    state[0].info_raw.bitdepth = 8

    local err = lodepng.lodepng_inspect(width, height, state, ffi.cast("const unsigned char*", fdata), #fdata)
    if err ~= 0 then
        lodepng.lodepng_state_cleanup(state)
        return false, ffi.string(lodepng.lodepng_error_text(err))
    end

    local colortype = state[0].info_png.color.colortype
    local palettesize = state[0].info_png.color.palettesize
    local out_n = req_n

    if req_n == 1 or req_n == 2 then
        if colortype == lodepng.LCT_GREY or colortype == lodepng.LCT_GREY_ALPHA or
            (colortype == lodepng.LCT_PALETTE and palettesize <= 16) then
            state[0].info_raw.colortype = req_n == 1 and lodepng.LCT_GREY or lodepng.LCT_GREY_ALPHA
        else
            state[0].info_raw.colortype = req_n == 1 and lodepng.LCT_RGB or lodepng.LCT_RGBA
            out_n = req_n == 1 and 3 or 4
        end
    elseif req_n == 3 then
        state[0].info_raw.colortype = lodepng.LCT_RGB
    elseif req_n == 4 then
        state[0].info_raw.colortype = lodepng.LCT_RGBA
    else
        lodepng.lodepng_state_cleanup(state)
        return false, "Invalid number of color components requested"
    end

    err = lodepng.lodepng_decode(ptr, width, height, state, ffi.cast("const unsigned char*", fdata), #fdata)
    if err ~= 0 then
        if ptr[0] ~= nil then
            ffi.C.free(ptr[0])

            ptr[0] = nil
        end
        lodepng.lodepng_state_cleanup(state)
        return false, ffi.string(lodepng.lodepng_error_text(err))
    end

    local status, result = pcall(func, ptr[0], width[0], height[0], out_n)

    if not status or not result then

        if ptr[0] ~= nil then
            ffi.C.free(ptr[0])

            ptr[0] = nil
        end
        lodepng.lodepng_state_cleanup(state)
        return false, "Callback function error: " .. result
    end

    local png_size = ffi.new("size_t[1]")
    err = lodepng.lodepng_encode(ptr, png_size, result, width[0], height[0], state)
    if err ~= 0 then
        lodepng.lodepng_state_cleanup(state)
        return false, "LodePNG encode error: " .. ffi.string(lodepng.lodepng_error_text(err))
    end

    local png_data = ffi.string(ptr[0], png_size[0])

    if ptr[0] ~= nil then
        ffi.C.free(ptr[0])

        ptr[0] = nil
    end

    lodepng.lodepng_state_cleanup(state)

    return true, {
        data = png_data,
        png_size = png_size[0]
    }
end

return Png

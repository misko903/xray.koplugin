-- xray_book_picker.lua — Custom Book Picker dialog for KOReader X-Ray
-- Provides an intuitive directory browser for adding books to series rosters,
-- supporting both List View and Cover View, styled after Storefront and Libbee pickers.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local theme = require(plugin_path .. "xray_theme")

local M = {}

local function sc(val)
    if Device and Device.screen and Device.screen.scaleBySize then
        return Device.screen:scaleBySize(val)
    end
    return val
end

local function getLfs()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        ok_lfs, lfs = pcall(require, "lfs")
    end
    if ok_lfs and lfs then
        return lfs
    end
    return nil
end

local _asset_path_cache = {}
local function getAssetPath(filename)
    if _asset_path_cache[filename] then
        return _asset_path_cache[filename]
    end
    local info = debug.getinfo(1, "S")
    local file_dir = (info and info.source and info.source:match("^@?(.*[/\\])")) or ""
    local candidates = {
        file_dir .. "assets/" .. filename,
        file_dir .. "../assets/" .. filename,
        "plugins/xray.koplugin/assets/" .. filename,
        "./plugins/xray.koplugin/assets/" .. filename,
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            f:close()
            _asset_path_cache[filename] = path
            return path
        end
    end
    local fallback = file_dir .. "assets/" .. filename
    _asset_path_cache[filename] = fallback
    return fallback
end

local function getTextWidth(text, face, bold)
    if not text or text == "" then return 0 end
    local tw = TextWidget:new{ text = text, face = face, bold = bold }
    local sz = tw.getSize and tw:getSize()
    if sz and sz.w then
        return sz.w
    end
    return #text * 8
end

local function truncateToWidth(text, max_w, face, bold, ellipsis)
    ellipsis = ellipsis or "..."
    if getTextWidth(text, face, bold) <= max_w then
        return text
    end
    local ellip_w = getTextWidth(ellipsis, face, bold)
    local avail_w = max_w - ellip_w
    if avail_w <= 0 then
        return ellipsis
    end

    local chars = {}
    for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        table.insert(chars, c)
    end
    if #chars == 0 then return ellipsis end

    local low = 1
    local high = #chars
    local best = 0
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local sub = table.concat(chars, "", 1, mid)
        if getTextWidth(sub, face, bold) <= avail_w then
            best = mid
            low = mid + 1
        else
            high = mid - 1
        end
    end
    if best == 0 then
        return ellipsis
    end
    return table.concat(chars, "", 1, best) .. ellipsis
end

local function formatTwoLinesMax(text, max_w, face, bold)
    if not text or text == "" then return "" end
    text = text:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$") or ""
    if getTextWidth(text, face, bold) <= max_w then
        return text
    end

    local words = {}
    for w in text:gmatch("%S+") do
        table.insert(words, w)
    end

    local line1 = ""
    local line1_word_count = 0

    if #words > 1 then
        for i, w in ipairs(words) do
            local test_line = (line1 == "") and w or (line1 .. " " .. w)
            if getTextWidth(test_line, face, bold) <= max_w then
                line1 = test_line
                line1_word_count = i
            else
                break
            end
        end
    end

    local remainder = ""
    if line1_word_count > 0 and line1_word_count < #words then
        local rem_words = {}
        for i = line1_word_count + 1, #words do
            table.insert(rem_words, words[i])
        end
        remainder = table.concat(rem_words, " ")
    else
        local chars = {}
        for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            table.insert(chars, c)
        end
        local low = 1
        local high = #chars
        local best = 1
        while low <= high do
            local mid = math.floor((low + high) / 2)
            local sub = table.concat(chars, "", 1, mid)
            if getTextWidth(sub, face, bold) <= max_w then
                best = mid
                low = mid + 1
            else
                high = mid - 1
            end
        end
        line1 = table.concat(chars, "", 1, best)
        if best < #chars then
            remainder = table.concat(chars, "", best + 1):match("^%s*(.-)%s*$") or ""
        else
            remainder = ""
        end
    end

    if remainder == "" then
        return line1
    end

    local line2
    if getTextWidth(remainder, face, bold) <= max_w then
        line2 = remainder
    else
        line2 = truncateToWidth(remainder, max_w, face, bold, "...")
    end

    return line1 .. "\n" .. line2
end

local function formatSize(bytes)
    if not bytes or bytes <= 0 then return "0 KB" end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%d KB", math.ceil(bytes / 1024))
    end
end

function M.getParentPath(path)
    if not path or path == "" or path == "/" then
        return nil
    end
    local clean = tostring(path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    if clean == "" or clean == "/" then
        return nil
    end
    local parent = clean:match("^(.-)[/\\]+[^/\\]+$")
    if not parent or parent == "" then
        if clean:match("^/[^/]+$") then
            return "/"
        elseif clean:match("^[a-zA-Z]:$") then
            return nil
        end
        return "/"
    end
    return parent
end

local SUPPORTED_EXTS = {
    epub = true,
    mobi = true,
    azw3 = true,
    fb2 = true,
    pdf = true,
}

local function getBookExt(filename)
    filename = filename:lower()
    if filename:match("%.kepub%.epub$") then
        return "kepub.epub"
    end
    local ext = filename:match("%.([^%.]+)$")
    if ext and SUPPORTED_EXTS[ext] then
        return ext
    end
    return nil
end

function M.scanDirectory(path)
    local subdirs = {}
    local books = {}
    local lfs = getLfs()

    if not lfs or not lfs.dir then
        return subdirs, books
    end

    pcall(function()
        for entry in lfs.dir(path) do
            -- Ignore '.', '..', hidden entries (starting with .), and KOReader .sdr sidecar folders
            if entry ~= "." and entry ~= ".." and not entry:match("^%.") and not entry:match("%.sdr$") then
                local full_path = (path == "/" and "/" .. entry) or (path .. "/" .. entry)
                local ok_attr, attr = pcall(lfs.attributes, full_path)
                if ok_attr and attr then
                    if attr.mode == "directory" then
                        table.insert(subdirs, {
                            name = entry,
                            path = full_path,
                            mtime = attr.modification or 0,
                        })
                    elseif attr.mode == "file" then
                        local ext = getBookExt(entry)
                        if ext then
                            table.insert(books, {
                                name = entry,
                                path = full_path,
                                size = attr.size or 0,
                                mtime = attr.modification or 0,
                                ext = ext:upper(),
                            })
                        end
                    end
                end
            end
        end
    end)

    table.sort(subdirs, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    table.sort(books, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    return subdirs, books
end

local _cover_cache = {}

function M.getBookCoverBlitBuffer(filepath, target_w, target_h)
    if not filepath or filepath == "" then return nil end
    local cache_key = filepath .. ":" .. tostring(target_w) .. "x" .. tostring(target_h)
    if _cover_cache[cache_key] ~= nil then
        return _cover_cache[cache_key] or nil
    end

    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage then
        _cover_cache[cache_key] = false
        return nil
    end

    local cover_bb = nil

    -- 1. Fast companion image file check next to book (standard in Calibre and book libraries)
    -- e.g. "Book Title.jpg", "cover.jpg", "cover.png"
    local dir, filename = filepath:match("^(.*)[/\\]([^/\\]+)$")
    local base_name = filename and filename:gsub("%.[^%.]+$", "")
    if dir and base_name then
        local candidates = {
            dir .. "/" .. base_name .. ".jpg",
            dir .. "/" .. base_name .. ".jpeg",
            dir .. "/" .. base_name .. ".png",
            dir .. "/cover.jpg",
            dir .. "/cover.jpeg",
            dir .. "/cover.png",
        }
        for _, img_path in ipairs(candidates) do
            local f = io.open(img_path, "rb")
            if f then
                f:close()
                local ok_img, ibb = pcall(function()
                    return RenderImage:renderImageFile(img_path, false)
                end)
                if ok_img and ibb then
                    cover_bb = ibb
                    break
                end
            end
        end
    end

    -- 2. Fast check: custom cover via DocSettings
    if not cover_bb then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and DocSettings and DocSettings.findCustomCoverFile then
            local ok_c, custom_file = pcall(function()
                return DocSettings:findCustomCoverFile(filepath)
            end)
            if ok_c and custom_file then
                local ok_img, ibb = pcall(function()
                    return RenderImage:renderImageFile(custom_file, false)
                end)
                if ok_img and ibb then
                    cover_bb = ibb
                end
            end
        end
    end

    -- 3. Check CoverBrowser / BookInfoManager cache (if already indexed in SQLite)
    if not cover_bb then
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_bim and BookInfoManager and BookInfoManager.getBookInfo then
            local ok_info, info = pcall(function()
                return BookInfoManager:getBookInfo(filepath, true)
            end)
            if ok_info and info and info.cover_bb then
                cover_bb = info.cover_bb
            end
        end
    end

    -- 4. If the book is already open in the active reader document, get cover from memory
    if not cover_bb then
        local ok_reg, DocumentRegistry = pcall(require, "document/documentregistry")
        if ok_reg and DocumentRegistry and DocumentRegistry.getReferenceCount then
            if DocumentRegistry:getReferenceCount(filepath) > 0 then
                local ok_doc, doc = pcall(DocumentRegistry.openDocument, DocumentRegistry, filepath)
                if ok_doc and doc then
                    local ok_cbb, cbb = pcall(function() return doc:getCoverPageImage() end)
                    pcall(function() doc:close() end)
                    if ok_cbb and cbb then
                        cover_bb = cbb
                    end
                end
            end
        end
    end

    if not cover_bb then
        _cover_cache[cache_key] = false
        return nil
    end

    -- Scale to fit target dimensions
    if RenderImage.scaleBlitBuffer and target_w and target_h then
        local orig_w = cover_bb:getWidth()
        local orig_h = cover_bb:getHeight()
        if orig_w > 0 and orig_h > 0 then
            local scale = math.min(target_w / orig_w, target_h / orig_h)
            local scaled_w = math.max(1, math.floor(orig_w * scale))
            local scaled_h = math.max(1, math.floor(orig_h * scale))
            local ok_scale, scaled_bb = pcall(function()
                return RenderImage:scaleBlitBuffer(cover_bb, scaled_w, scaled_h, true)
            end)
            if ok_scale and scaled_bb then
                _cover_cache[cache_key] = scaled_bb
                return scaled_bb
            end
        end
    end

    _cover_cache[cache_key] = cover_bb
    return cover_bb
end

local function createCoverWidget(filepath, target_w, target_h, format_label)
    local bb = M.getBookCoverBlitBuffer(filepath, target_w, target_h)
    if bb then
        local iw = ImageWidget:new{
            image = bb,
            width = bb:getWidth(),
            height = bb:getHeight(),
        }
        return FrameContainer:new{
            bordersize = sc(1),
            color = theme.color_border or Blitbuffer.COLOR_DARK_GRAY,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            width = target_w,
            height = target_h,
            CenterContainer:new{
                dimen = Geom:new{ w = target_w, h = target_h },
                iw,
            }
        }
    end

    -- Fallback placeholder card
    local icon_widget
    local icon_path = getAssetPath("book.svg")
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if ok_ri and RenderImage and RenderImage.renderSvg then
        local ok, icon_bb = pcall(RenderImage.renderSvg, RenderImage, icon_path, sc(28), sc(28))
        if ok and icon_bb then
            icon_widget = ImageWidget:new{ image = icon_bb }
        end
    end
    if not icon_widget then
        icon_widget = TextWidget:new{
            text = "📖",
            face = Font:getFace("cfont", 22),
        }
    end

    local badge_widget = TextWidget:new{
        text = format_label or "BOOK",
        face = Font:getFace("cfont", 10),
        bold = true,
        fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
    }

    return FrameContainer:new{
        bordersize = sc(1),
        color = theme.color_border or Blitbuffer.COLOR_DARK_GRAY,
        padding = sc(4),
        margin = 0,
        radius = theme.radius_btn or sc(4),
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        width = target_w,
        height = target_h,
        CenterContainer:new{
            dimen = Geom:new{ w = target_w, h = target_h },
            VerticalGroup:new{
                align = "center",
                icon_widget,
                VerticalSpan:new{ width = sc(4) },
                badge_widget,
            }
        }
    }
end

local function makeTapItem(frame, callback)
    local item = InputContainer:new{ frame }
    item.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function()
                    return item.dimen
                end
            }
        }
    }
    item.onTap = function()
        if callback then callback() end
        return true
    end
    item.onTapSelect = function()
        if callback then callback() end
        return true
    end
    return item
end

function M.show(options)
    options = options or {}
    local current_path = options.initial_path
    local on_confirm = options.on_confirm
    local on_cancel = options.on_cancel
    local loc = options.loc or { t = function(_, k) return k end }

    if not current_path or current_path == "" then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        current_path = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/sdcard/Books"
    end
    current_path = tostring(current_path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    -- Strip accidental .sdr path if passed
    if current_path:match("%.sdr$") then
        current_path = current_path:gsub("[/\\]+[^/\\]+%.sdr$", "")
    end
    if current_path == "" then current_path = "/" end

    local lfs = getLfs()
    if lfs and lfs.attributes then
        local ok_attr, attr = pcall(lfs.attributes, current_path)
        if not ok_attr or not attr or attr.mode ~= "directory" then
            current_path = "/"
        end
    end

    local ok_gs, G_reader_settings = pcall(function() return G_reader_settings end)
    local view_mode = (ok_gs and G_reader_settings and G_reader_settings.readSetting and G_reader_settings:readSetting("xray_book_picker_view")) or "cover"
    if view_mode ~= "cover" and view_mode ~= "list" then
        view_mode = "cover"
    end

    local current_page = 1
    local overlay = nil
    local refresh = nil

    local function closePicker()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_cancel then
            on_cancel()
        end
    end

    local function confirmBook(chosen_path)
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end
        if on_confirm then
            on_confirm(chosen_path)
        end
    end

    local function toggleViewMode()
        if view_mode == "cover" then
            view_mode = "list"
        else
            view_mode = "cover"
        end
        if ok_gs and G_reader_settings and G_reader_settings.saveSetting then
            G_reader_settings:saveSetting("xray_book_picker_view", view_mode)
        end
        current_page = 1
        if refresh then refresh() end
    end

    refresh = function()
        if overlay then
            local ov = overlay
            overlay = nil
            ov.onClose = nil
            UIManager:close(ov, "ui")
        end

        local sw = Device.screen:getWidth()
        local sh = Device.screen:getHeight()
        local dialog_w = math.min(sw - sc(16), sc(540))
        local dialog_h = math.min(sh - sc(24), sc(780))

        local card_padding = sc(8)
        local card_border = theme.border_window or sc(1)
        local inner_w = dialog_w - (card_padding * 2) - (card_border * 2)

        local subdirs, books = M.scanDirectory(current_path)
        local parent_path = M.getParentPath(current_path)

        -- Combine items for current view
        local all_items = {}
        for _, d in ipairs(subdirs) do
            table.insert(all_items, { type = "dir", data = d })
        end
        for _, b in ipairs(books) do
            table.insert(all_items, { type = "book", data = b })
        end

        local items_per_page = 6
        local num_cols = 3
        if view_mode == "cover" then
            if inner_w < sc(400) then
                num_cols = 2
                items_per_page = 4
            else
                num_cols = 3
                items_per_page = 6
            end
        else
            items_per_page = 7
        end

        local total_items = #all_items
        local total_pages = math.max(1, math.ceil(total_items / items_per_page))
        if current_page > total_pages then current_page = total_pages end
        if current_page < 1 then current_page = 1 end

        local start_idx = (current_page - 1) * items_per_page + 1
        local end_idx = math.min(total_items, current_page * items_per_page)

        -- HEADER
        local title_text = loc:t("manage_series_choose_book") or "Choose Book to Add"
        local title_label = TextWidget:new{
            text = title_text,
            face = Font:getFace("cfont", 18),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local toggle_label_text = (view_mode == "cover") and (loc:t("picker_list_view") or "List") or (loc:t("picker_cover_view") or "Covers")
        local toggle_btn = Button:new{
            text = toggle_label_text,
            bordersize = sc(1),
            padding = sc(3),
            padding_h = sc(8),
            radius = theme.radius_btn or sc(4),
            callback = toggleViewMode,
        }

        local close_btn = Button:new{
            text = " ✕ ",
            face = Font:getFace("cfont", 16),
            bordersize = 0,
            padding = sc(4),
            padding_h = sc(6),
            callback = closePicker,
        }

        local header_row = HorizontalGroup:new{
            title_label,
            HorizontalSpan:new{ width = math.max(sc(8), inner_w - (title_label:getSize().w) - (toggle_btn:getSize().w) - (close_btn:getSize().w) - sc(12)) },
            toggle_btn,
            HorizontalSpan:new{ width = sc(6) },
            close_btn,
        }

        -- PATH & SUMMARY BAR
        local path_label = TextBoxWidget:new{
            text = current_path,
            face = Font:getFace("cfont", 13),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            width = inner_w - sc(16),
        }

        local count_text = string.format(loc:t("picker_items_count") or "%d folders, %d books", #subdirs, #books)
        local count_label = TextWidget:new{
            text = count_text,
            face = Font:getFace("cfont", 11),
            fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
        }

        local path_box = FrameContainer:new{
            padding = sc(4),
            padding_left = sc(8),
            padding_right = sc(8),
            radius = theme.radius_btn or sc(4),
            bordersize = 0,
            width = inner_w,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            VerticalGroup:new{
                align = "left",
                path_label,
                count_label,
            }
        }

        -- PARENT DIRECTORY BUTTON
        local up_item = nil
        if parent_path then
            local parent_display = parent_path:match("([^/\\]+)$") or "/"
            up_item = Button:new{
                text = string.format("⬆  ..  (%s)", parent_display),
                text_font_bold = true,
                bordersize = sc(1),
                border_color = theme.color_section_rule or Blitbuffer.COLOR_GRAY_B,
                width = inner_w,
                height = sc(34),
                radius = theme.radius_btn or sc(4),
                padding = 0,
                callback = function()
                    current_path = parent_path
                    current_page = 1
                    refresh()
                end,
            }
        end

        -- CONTENT ITEMS (List or Cover View)
        local content_list = VerticalGroup:new{ align = "left" }

        if total_items == 0 then
            local empty_label = TextWidget:new{
                text = loc:t("picker_no_books_found") or "No ebook files found in this folder.",
                face = Font:getFace("cfont", 14),
                fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
            }
            table.insert(content_list, CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = sc(160) },
                empty_label,
            })
        elseif view_mode == "cover" then
            -- GRID / COVER VIEW
            local col_gap = sc(8)
            local row_gap = sc(8)
            local card_w = math.floor((inner_w - (col_gap * (num_cols - 1))) / num_cols)
            local cover_h = math.floor(card_w * 1.35)

            local current_row = nil
            local col_in_row = 0

            for i = start_idx, end_idx do
                local it = all_items[i]
                local card_content

                if it.type == "dir" then
                    -- Folder card with clean [FOLDER] badge and folder name
                    local folder_badge = TextWidget:new{
                        text = "[FOLDER]",
                        face = Font:getFace("cfont", 12),
                        bold = true,
                        fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
                    }
                    local folder_name_text = truncateToWidth(it.data.name or "", card_w - sc(12), Font:getFace("cfont", 13), true)
                    local folder_name = TextWidget:new{
                        text = folder_name_text,
                        face = Font:getFace("cfont", 13),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    local dir_box = FrameContainer:new{
                        bordersize = sc(1),
                        color = theme.color_border or Blitbuffer.COLOR_DARK_GRAY,
                        padding = sc(6),
                        radius = theme.radius_btn or sc(4),
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                        width = card_w,
                        height = cover_h,
                        CenterContainer:new{
                            dimen = Geom:new{ w = card_w, h = cover_h },
                            VerticalGroup:new{
                                align = "center",
                                folder_badge,
                                VerticalSpan:new{ width = sc(8) },
                                folder_name,
                            }
                        }
                    }
                    card_content = dir_box
                else
                    -- Book card with cover thumbnail
                    local cover_w = createCoverWidget(it.data.path, card_w, cover_h, it.data.ext)
                    local clean_title = (it.data.name or ""):gsub("%.[^%.]+$", "")
                    local title_str = formatTwoLinesMax(clean_title, card_w, Font:getFace("cfont", 11), false)
                    local title_widget = TextWidget:new{
                        text = title_str,
                        face = Font:getFace("cfont", 11),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    card_content = VerticalGroup:new{
                        align = "center",
                        cover_w,
                        VerticalSpan:new{ width = sc(3) },
                        title_widget,
                    }
                end

                local target_path = it.data.path
                local is_dir = (it.type == "dir")
                local tap_card = makeTapItem(card_content, function()
                    if is_dir then
                        current_path = target_path
                        current_page = 1
                        refresh()
                    else
                        confirmBook(target_path)
                    end
                end)

                if col_in_row == 0 then
                    current_row = HorizontalGroup:new{}
                else
                    table.insert(current_row, HorizontalSpan:new{ width = col_gap })
                end
                table.insert(current_row, tap_card)
                col_in_row = col_in_row + 1

                if col_in_row == num_cols or i == end_idx then
                    while col_in_row < num_cols do
                        table.insert(current_row, HorizontalSpan:new{ width = col_gap })
                        table.insert(current_row, HorizontalSpan:new{ width = card_w })
                        col_in_row = col_in_row + 1
                    end
                    table.insert(content_list, current_row)
                    table.insert(content_list, VerticalSpan:new{ width = row_gap })
                    col_in_row = 0
                end
            end
        else
            -- LIST VIEW
            local row_h = sc(42)
            for i = start_idx, end_idx do
                local it = all_items[i]
                local row_content

                if it.type == "dir" then
                    local dir_tag = TextWidget:new{
                        text = "[DIR]",
                        face = Font:getFace("cfont", 11),
                        bold = true,
                        fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
                    }
                    local dir_name = TextWidget:new{
                        text = truncateToWidth(it.data.name or "", inner_w - sc(70), Font:getFace("cfont", 14), true),
                        face = Font:getFace("cfont", 14),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    local hg = HorizontalGroup:new{
                        dir_tag,
                        HorizontalSpan:new{ width = sc(8) },
                        dir_name,
                    }
                    row_content = FrameContainer:new{
                        bordersize = sc(1),
                        color = theme.color_section_rule or Blitbuffer.COLOR_GRAY_B,
                        padding = sc(6),
                        padding_left = sc(8),
                        padding_right = sc(8),
                        radius = theme.radius_btn or sc(4),
                        width = inner_w,
                        hg,
                    }
                else
                    local ext_tag = TextWidget:new{
                        text = string.format("[%s]", it.data.ext or "BOOK"),
                        face = Font:getFace("cfont", 11),
                        bold = true,
                        fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
                    }
                    local clean_title = (it.data.name or ""):gsub("%.[^%.]+$", "")
                    local size_tag = TextWidget:new{
                        text = formatSize(it.data.size),
                        face = Font:getFace("cfont", 11),
                        fgcolor = theme.color_label_dim or Blitbuffer.COLOR_DARK_GRAY,
                    }
                    local avail_title_w = math.max(sc(100), inner_w - ext_tag:getSize().w - size_tag:getSize().w - sc(32))
                    local book_title = TextWidget:new{
                        text = truncateToWidth(clean_title, avail_title_w, Font:getFace("cfont", 14), false),
                        face = Font:getFace("cfont", 14),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                    local hg = HorizontalGroup:new{
                        ext_tag,
                        HorizontalSpan:new{ width = sc(8) },
                        book_title,
                        HorizontalSpan:new{ width = math.max(sc(8), inner_w - ext_tag:getSize().w - book_title:getSize().w - size_tag:getSize().w - sc(24)) },
                        size_tag,
                    }
                    row_content = FrameContainer:new{
                        bordersize = sc(1),
                        color = theme.color_border or Blitbuffer.COLOR_DARK_GRAY,
                        padding = sc(6),
                        padding_left = sc(8),
                        padding_right = sc(8),
                        radius = theme.radius_btn or sc(4),
                        width = inner_w,
                        hg,
                    }
                end

                local target_path = it.data.path
                local is_dir = (it.type == "dir")
                local tap_row = makeTapItem(row_content, function()
                    if is_dir then
                        current_path = target_path
                        current_page = 1
                        refresh()
                    else
                        confirmBook(target_path)
                    end
                end)

                table.insert(content_list, tap_row)
                table.insert(content_list, VerticalSpan:new{ width = sc(4) })
            end
        end

        -- FOOTER PAGINATION
        local prev_btn = Button:new{
            text = " < Prev ",
            enabled = (current_page > 1),
            bordersize = sc(1),
            radius = theme.radius_btn or sc(4),
            callback = function()
                if current_page > 1 then
                    current_page = current_page - 1
                    refresh()
                end
            end,
        }
        local page_str = string.format("%d / %d", current_page, total_pages)
        local page_label = TextWidget:new{
            text = page_str,
            face = Font:getFace("cfont", 14),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local next_btn = Button:new{
            text = " Next > ",
            enabled = (current_page < total_pages),
            bordersize = sc(1),
            radius = theme.radius_btn or sc(4),
            callback = function()
                if current_page < total_pages then
                    current_page = current_page + 1
                    refresh()
                end
            end,
        }
        local cancel_btn = Button:new{
            text = loc:t("cancel") or "Cancel",
            bordersize = sc(1),
            radius = theme.radius_btn or sc(4),
            callback = closePicker,
        }

        local footer_row = HorizontalGroup:new{
            prev_btn,
            HorizontalSpan:new{ width = sc(8) },
            page_label,
            HorizontalSpan:new{ width = sc(8) },
            next_btn,
            HorizontalSpan:new{ width = math.max(sc(16), inner_w - (prev_btn:getSize().w) - (page_label:getSize().w) - (next_btn:getSize().w) - (cancel_btn:getSize().w) - sc(24)) },
            cancel_btn,
        }

        -- ASSEMBLE DIALOG
        local main_vg = VerticalGroup:new{
            align = "left",
            header_row,
            VerticalSpan:new{ width = sc(6) },
            LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = sc(1) },
                background = theme.color_section_rule or Blitbuffer.COLOR_GRAY_B,
            },
            VerticalSpan:new{ width = sc(6) },
            path_box,
            VerticalSpan:new{ width = sc(4) },
        }

        if up_item then
            table.insert(main_vg, up_item)
            table.insert(main_vg, VerticalSpan:new{ width = sc(6) })
        end

        table.insert(main_vg, content_list)
        table.insert(main_vg, VerticalSpan:new{ width = sc(8) })
        table.insert(main_vg, LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = theme.color_section_rule or Blitbuffer.COLOR_GRAY_B,
        })
        table.insert(main_vg, VerticalSpan:new{ width = sc(6) })
        table.insert(main_vg, footer_row)

        local dialog_frame = FrameContainer:new{
            bordersize = card_border,
            color = theme.color_border or Blitbuffer.COLOR_BLACK,
            radius = theme.radius_window or 0,
            background = Blitbuffer.COLOR_WHITE,
            padding = card_padding,
            main_vg,
        }

        overlay = InputContainer:new{
            align = "center",
            vertical_align = "center",
            dimen = Geom:new{ w = sw, h = sh },
            CenterContainer:new{
                dimen = Geom:new{ w = sw, h = sh },
                dialog_frame,
            }
        }

        overlay.onClose = function()
            if on_cancel then on_cancel() end
        end

        UIManager:show(overlay)
    end

    refresh()
end

return M

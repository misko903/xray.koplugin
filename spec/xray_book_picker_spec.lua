-- spec/xray_book_picker_spec.lua
require("spec.spec_helper")
local BookPicker = require("xray_book_picker")

describe("xray_book_picker", function()
    local test_dir = "/tmp/test_xray_book_picker"

    before_each(function()
        os.execute("rm -rf " .. test_dir)
        os.execute("mkdir -p " .. test_dir .. "/SubfolderA")
        os.execute("mkdir -p " .. test_dir .. "/SubfolderB")
        os.execute("mkdir -p " .. test_dir .. "/book1.sdr")
        os.execute("touch " .. test_dir .. "/book1.epub")
        os.execute("touch " .. test_dir .. "/book2.mobi")
        os.execute("touch " .. test_dir .. "/book3.azw3")
        os.execute("touch " .. test_dir .. "/book4.pdf")
        os.execute("touch " .. test_dir .. "/book5.kepub.epub")
        os.execute("touch " .. test_dir .. "/notes.txt")
        os.execute("touch " .. test_dir .. "/.hidden_file.epub")
    end)

    after_each(function()
        os.execute("rm -rf " .. test_dir)
    end)

    describe("getParentPath", function()
        it("returns parent directory for nested paths", function()
            assert.are.equal("/tmp/test_xray_book_picker", BookPicker.getParentPath(test_dir .. "/SubfolderA"))
            assert.are.equal("/tmp", BookPicker.getParentPath("/tmp/test_xray_book_picker"))
            assert.are.equal("/", BookPicker.getParentPath("/tmp"))
        end)

        it("returns nil for root path or empty string", function()
            assert.is_nil(BookPicker.getParentPath("/"))
            assert.is_nil(BookPicker.getParentPath(""))
            assert.is_nil(BookPicker.getParentPath(nil))
        end)
    end)

    describe("scanDirectory", function()
        it("identifies subdirectories and supported ebook formats while ignoring .sdr and non-ebooks", function()
            local subdirs, books = BookPicker.scanDirectory(test_dir)

            -- Only SubfolderA and SubfolderB (book1.sdr must be ignored)
            assert.are.equal(2, #subdirs)
            assert.are.equal("SubfolderA", subdirs[1].name)
            assert.are.equal("SubfolderB", subdirs[2].name)

            -- 5 supported ebook files (.epub, .mobi, .azw3, .pdf, .kepub.epub); .txt and hidden files ignored
            assert.are.equal(5, #books)

            local book_names = {}
            for _, b in ipairs(books) do
                table.insert(book_names, b.name)
            end

            assert.is_truthy(table.concat(book_names, ","):find("book1.epub"))
            assert.is_truthy(table.concat(book_names, ","):find("book2.mobi"))
            assert.is_truthy(table.concat(book_names, ","):find("book3.azw3"))
            assert.is_truthy(table.concat(book_names, ","):find("book4.pdf"))
            assert.is_truthy(table.concat(book_names, ","):find("book5.kepub.epub"))
            assert.is_falsy(table.concat(book_names, ","):find("notes.txt"))
            assert.is_falsy(table.concat(book_names, ","):find(".hidden_file"))
        end)

        it("sorts entries alphabetically", function()
            local subdirs, books = BookPicker.scanDirectory(test_dir)
            assert.are.equal("SubfolderA", subdirs[1].name)
            assert.are.equal("SubfolderB", subdirs[2].name)
            assert.are.equal("book1.epub", books[1].name)
        end)
    end)

    describe("getBookCoverBlitBuffer", function()
        it("returns nil safely for non-existent files or non-image files", function()
            local bb = BookPicker.getBookCoverBlitBuffer("/nonexistent/file.epub", 100, 140)
            assert.is_nil(bb)
        end)
    end)
end)

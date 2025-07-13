--- MIT License
---
--- Copyright (c) 2023 Steven Arcangeli
---
--- Permission is hereby granted, free of charge, to any person obtaining a copy
--- of this software and associated documentation files (the "Software"), to deal
--- in the Software without restriction, including without limitation the rights
--- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--- copies of the Software, and to permit persons to whom the Software is
--- furnished to do so, subject to the following conditions:
---
--- The above copyright notice and this permission notice shall be included in all
--- copies or substantial portions of the Software.
---
--- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
--- SOFTWARE.

--- I have edited the code from `conform.nvim` a bit, but I am still including the license :)
--- Check out `conform.nvim` for initial implementation of this, and prefer to
--- use that over this plugin :)
--- https://github.com/stevearc/conform.nvim/blob/master/lua/conform/runner.lua

local M = {}

---@param a string
---@param b string
---@return integer
local function common_prefix_len(a, b)
    local min_len = math.min(#a, #b)
    for i = 1, min_len do
        if string.byte(a, i) ~= string.byte(b, i) then
            return i - 1
        end
    end
    return min_len
end

---@param a string
---@param b string
---@return integer
local function common_suffix_len(a, b)
    local min_len = math.min(#a, #b)
    for i = 0, min_len - 1 do
        if string.byte(a, #a - i) ~= string.byte(b, #b - i) then
            return i
        end
    end
    return min_len
end

---@param replacement string[]
---@param start_line number
---@param start_char number
---@param end_line number
---@param end_char number
local function create_text_edit(replacement, start_line, start_char, end_line, end_char)
    return {
        newText = table.concat(replacement, '\n'),
        range = {
            start = {
                line = start_line,
                character = start_char,
            },
            ['end'] = {
                line = end_line,
                character = end_char,
            },
        },
    }
end

---@param bufnr number
---@param original_lines string[]
---@param new_lines string[]
M.apply_text_edits = function(bufnr, original_lines, new_lines)
    -- Add trailing newline to work around vim.text.diff not handline newline-at-end-of-file well
    local original_text = table.concat(original_lines, '\n') .. '\n'
    local new_text = table.concat(new_lines, '\n') .. '\n'

    -- Abort if output is empty but input is not (i.e. has some non-whitespace characters).
    -- This is to hack around oddly behaving formatters (e.g black outputs nothing for excluded files).
    if new_text:match('^%s*$') and not original_text:match('^%s*$') then
        return
    end

    local diff = vim.text.diff or vim.diff
    local indices = diff(original_text, new_text, { result_type = 'indices', algorithm = 'histogram' }) --[[@as table]]

    local text_edits = vim.iter(indices)
        :map(function(idx)
            local line_start, line_count, new_line_start, new_line_count = unpack(idx)
            local line_end = line_start + line_count - 1

            local replacement = vim.iter(new_lines):slice(new_line_start, new_line_start + new_line_count - 1):totable()

            if line_count == 0 then
                -- When the diff is an insert, it actually means to insert after the mentioned line
                table.insert(replacement, '')
                return create_text_edit(replacement, line_start, 0, line_end + 1, 0)
            elseif new_line_count == 0 then
                return create_text_edit(replacement, line_start - 1, 0, line_end, 0)
            else
                -- If we're replacing text, see if we can avoid replacing the entire line
                local start_char = common_prefix_len(original_lines[line_start], replacement[1])
                replacement[1] = replacement[1]:sub(start_char + 1)

                -- If we're only replacing one line, make sure the prefix/suffix calculations don't overlap
                local suffix = common_suffix_len(original_lines[line_end], replacement[#replacement])
                if line_start == line_end then
                    suffix = math.min(suffix, #original_lines[line_end] - start_char)
                end

                local end_char = #original_lines[line_end] - suffix
                replacement[#replacement] = replacement[#replacement]:sub(1, #replacement[#replacement] - suffix)

                return create_text_edit(replacement, line_start - 1, start_char, line_end - 1, end_char)
            end
        end)
        :totable()

    vim.lsp.util.apply_text_edits(text_edits, bufnr, 'utf-8')
end

return M

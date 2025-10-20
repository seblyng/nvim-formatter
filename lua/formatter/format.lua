local config = require('formatter.config')
local async = require('formatter.async')
local notify_opts = { title = 'Formatter' }

---@class NvimFormatterFormatRange
---@field start number
---@field end number

---@class NvimFormatterInjection
---@field range NvimFormatterFormatRange
---@field ft string
---@field confs NvimFormatterFiletypeConfig[]
---@field input string[]

---@class NvimFormatterFormat
---@field range NvimFormatterFormatRange | nil
---@field inital_changedtick number
---@field bufnr number
---@field confs NvimFormatterFiletypeConfig | nil
---@field is_formatting boolean
---@field input table
local Format = {}

---@param range? NvimFormatterFormatRange[]
---@param bufnr? number
function Format:new(range, bufnr)
    local o = {}
    setmetatable(o, { __index = self })

    o.bufnr = bufnr or vim.api.nvim_get_current_buf()
    o.inital_changedtick = vim.api.nvim_buf_get_changedtick(o.bufnr)

    o.range = range
    o.is_formatting = false

    o.confs = config.get_ft_configs(o.bufnr, vim.bo[o.bufnr].ft)
    o.input = vim.api.nvim_buf_get_lines(o.bufnr, 0, -1, false)

    return o
end

-- Crete a wrapper for `vim.system` that can be ran asynchronously with `async.wrap`.
-- Have a timeout to kill the process after 5000ms. The `timeout` option tries to terminate
-- the process with SIGTERM instead of killing it with SIGKILL.
local function system_wrap(...)
    local out = vim.system(...)
    vim.defer_fn(function()
        if not out:is_closing() then
            out:kill(9)
        end
    end, 5000)
end

local asystem = async.wrap(system_wrap, 3)

---@param bufnr number
---@param conf NvimFormatterFiletypeConfig
---@param input string[]
---@return string[] | nil
local execute = function(bufnr, conf, input)
    if conf.cond then
        async.scheduler()
        if not conf.cond() then
            return nil
        end
    end

    if vim.fn.executable(conf.exe) ~= 1 then
        async.scheduler()
        vim.notify_once(string.format('%s: executable not found', conf.exe), vim.log.levels.ERROR, notify_opts)
        return nil
    end

    local out = asystem({ conf.exe, unpack(conf.args or {}) }, {
        cwd = conf.cwd,
        stdin = table.concat(input, '\n'),
    })

    if out.code ~= 0 then
        async.scheduler()
        local errmsg = out.stderr and out.stderr or out.stdout
        vim.notify(
            string.format(
                'Failed to format %s with %s%s',
                vim.api.nvim_buf_get_name(bufnr),
                conf.exe,
                errmsg and ': ' .. errmsg or ''
            ),
            vim.log.levels.ERROR,
            notify_opts
        )
        return nil
    end
    if out.signal == 9 then
        async.scheduler()
        vim.notify(
            string.format('Timeout when formatting %s with %s', vim.api.nvim_buf_get_name(bufnr), conf.exe),
            vim.log.levels.ERROR,
            notify_opts
        )
        return nil
    end

    local stdout = out.stdout:sub(-1) == '\n' and out.stdout or out.stdout .. '\n'
    return vim.iter(stdout:gmatch('([^\n]*)\n')):totable()
end

---@param format NvimFormatterFormat
---@param type "basic" | "injections" | "all"
---@param silent boolean?
local function run(format, type, silent)
    if type == 'basic' then
        local output = format:run(format.confs, format.input)
        format:insert(output)
    elseif type == 'injections' then
        local injections = format:find_injections(format.input)
        local output = format:run_injections(format.input, injections)
        format:insert(output)
    else
        local output = format.confs and format:run(format.confs, format.input) or format.input
        async.scheduler()

        local ok, res = pcall(function()
            local injections = format:find_injections(output)
            if not format.confs and #injections == 0 and not silent then
                vim.notify(
                    string.format('No formatter configurations found for %s', vim.bo[format.bufnr].ft),
                    vim.log.levels.INFO,
                    notify_opts
                )
            end

            return #injections > 0 and format:run_injections(output, injections) or output
        end)
        if not ok then
            format:insert(output)
        else
            format:insert(res)
        end
    end
end

---@param format NvimFormatterFormat
---@param type "basic" | "injections" | "all"
---@param silent boolean?
local start = async.void(function(format, type, silent)
    format.is_formatting = true
    local ok, res = pcall(run, format, type, silent)
    format.is_formatting = false
    if not ok then
        error(res)
    end
end)

---@param type "all" | "basic" | "injections"
---@param silent boolean?
function Format:start(type, silent)
    if not vim.bo[self.bufnr].modifiable then
        return vim.notify('Buffer is not modifiable', vim.log.levels.INFO, notify_opts)
    end

    -- If we have lsp and we don't have any filetype conf, then see if one of the
    -- language servers that is set up, is attached to self.bufnr.
    -- If it is not, then fallback to try to format injected filetypes.
    -- LSP formatting and injected formatting doesn't work so well together
    if not self.confs and config.get().lsp then
        local active_clients = vim.lsp.get_clients({ bufnr = self.bufnr })
        local found = vim.iter(config.get().lsp):any(function(it)
            return vim.iter(active_clients):any(function(c)
                return c.name == it
            end)
        end)
        if found then
            vim.lsp.buf.format()
            return vim.api.nvim_buf_call(self.bufnr, function()
                vim.cmd.update({ mods = { emsg_silent = true, silent = true, noautocmd = true } })
            end)
        end
    end

    vim.api.nvim_create_autocmd({ 'ExitPre', 'VimLeavePre' }, {
        pattern = '*',
        group = vim.api.nvim_create_augroup('FormatterAsync', { clear = true }),
        callback = function()
            vim.wait(5000, function()
                return self.is_formatting == false
            end, 10)
        end,
    })

    start(self, type, silent)
end

---@param output string[]
function Format:insert(output)
    if output and not vim.deep_equal(output, self.input) then
        vim.schedule(function()
            if self.inital_changedtick ~= vim.api.nvim_buf_get_changedtick(self.bufnr) then
                return vim.notify('Buffer changed while formatting', vim.log.levels.INFO, notify_opts)
            end
            require('formatter.text_edit').apply_text_edits(self.bufnr, self.input, output)
            vim.api.nvim_buf_call(self.bufnr, function()
                vim.cmd.update({ mods = { emsg_silent = true, silent = true, noautocmd = true } })
            end)
        end)
    end
end

---@param input string[]
---@param formatted string[]
---@param range NvimFormatterFormatRange
local function replace(input, formatted, range)
    local output = { unpack(input) }
    for _ = range.start, range['end'], 1 do
        table.remove(output, range.start)
    end
    for i, text in ipairs(formatted) do
        table.insert(output, range.start + i - 1, text)
    end
    return output
end

---Returns the output from formatting the buffer with all configs
---@param confs NvimFormatterFiletypeConfig[]
---@param input string[]
---@return string[]
function Format:run(confs, input)
    local sliced_input = self.range and vim.iter(input):slice(self.range.start, self.range['end']):totable() or input

    local formatted_output = vim.iter(confs):fold(sliced_input, function(acc, v)
        return execute(self.bufnr, v, acc) or acc
    end)

    if self.range then
        return replace(input, formatted_output, self.range)
    else
        return formatted_output
    end
end

---@param text string[]
---@param ft string
---@param range NvimFormatterFormatRange
---@return string[]
local function try_transform_text(text, ft, range)
    async.scheduler()
    local conf = config.get().treesitter.auto_indent[ft]
    if not conf or ((type(conf) == 'function') and not conf()) then
        return text
    end

    local col = vim.fn.match(vim.fn.getline(range.start), '\\S') --[[@as number]]
    return vim.iter(text)
        :map(function(val)
            return string.format('%s%s', string.rep(' ', col), val)
        end)
        :totable()
end

---@class NvimFormatterInjectionOutput
---@field range NvimFormatterFormatRange
---@field output string[]

---@param input string[]
---@param injections NvimFormatterInjection[]
---@return string[]
function Format:run_injections(input, injections)
    local jobs = vim.iter(injections)
        :map(function(injection)
            return async.void(function(cb)
                local output = self:run(injection.confs, injection.input)
                output = try_transform_text(output, injection.ft, injection.range)
                cb({ output = output, range = injection.range })
            end)
        end)
        :totable()

    ---@type NvimFormatterInjectionOutput[]
    local res = vim.iter(async.join(jobs, 10)):flatten():totable()

    -- Sort it in reverse, as we need to replace the text
    -- bottom oup to not mess with the range
    table.sort(res, function(a, b)
        return a.range.start > b.range.start
    end)

    return vim.iter(res):fold(input, function(acc, injection)
        return replace(acc, injection.output, injection.range)
    end)
end

---@param t table?
---@param ft string
---@return boolean
local function contains(t, ft)
    return vim.iter(t or {}):any(function(v)
        return v == ft or v == '*'
    end)
end

---@param conf? table<NvimFormatterFiletypeConfig>
---@param exe string
---@return boolean
local function same_executable(conf, exe)
    return vim.iter(conf or {}):any(function(c)
        return c.exe == exe
    end)
end

---@param ft string
---@return NvimFormatterFiletypeConfig[]
function Format:get_injected_confs(ft)
    local confs = config.get_ft_configs(self.bufnr, ft)
    if vim.bo[self.bufnr].ft == ft or not confs then
        return {}
    end

    local resolved_ft = config.get().filetype[ft] and ft or '_'

    local ft_disable_injected = vim.deepcopy(config.get().treesitter.disable_injected[vim.bo[self.bufnr].ft] or {})
    local global_disable_injected = config.get().treesitter.disable_injected['*'] or {}
    local disable_injected = vim.list_extend(ft_disable_injected, global_disable_injected)

    -- Only try to format an injected language if it is not disabled with
    -- `disable_injected` or if the executable is different. Check the
    -- executable because we should not format with prettier typescript inside
    -- vue-files. Prettier for vue should do the entire file
    return vim.iter(confs)
        :map(function(c)
            if not contains(disable_injected, resolved_ft) and not same_executable(self.confs, c.exe) then
                return c
            end
        end)
        :totable()
end

---@param text string
---@return number Number of newlines at the start of the node text
local function get_starting_newlines(text)
    local lines = vim.split(text, '\n')
    return vim.iter(lines):enumerate():find(function(_, line)
        return line ~= ''
    end) - 1
end

---@param bufnr number
---@param lang string
---@return string?
local function lang_to_ft(bufnr, lang)
    local filetypes = vim.treesitter.language.get_filetypes(lang)
    return vim.iter(filetypes):find(function(ft)
        return config.get_ft_configs(bufnr, ft)
    end)
end

---@param output string[]
---@return NvimFormatterInjection[]
function Format:find_injections(output)
    local injections = {}
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, output)

    local parser_lang = vim.treesitter.language.get_lang(vim.bo[self.bufnr].ft)
    local ok, parser = pcall(vim.treesitter.get_parser, buf, parser_lang)
    if not ok or not parser then
        return injections
    end
    parser:parse(true)

    parser:for_each_tree(function(tree, ltree)
        local root = tree:root()
        local start_line, _, end_line, end_col = root:range()
        local ft = lang_to_ft(self.bufnr, ltree:lang()) or vim.bo[self.bufnr].ft
        local confs = self:get_injected_confs(ft)
        if #confs > 0 then
            local text = vim.treesitter.get_node_text(root, buf)
            start_line = start_line + get_starting_newlines(text)
            -- If start line is equal to end_line we should not format, as it doesn't work so good
            -- If end_line is just one more than start_line and end_col is 0, then it also really is
            -- just one line, so do not format that neither
            if end_line > start_line and not (end_line - 1 == start_line and end_col == 0) then
                table.insert(injections, {
                    range = { start = start_line + 1, ['end'] = end_line },
                    confs = confs,
                    input = vim.split(text, '\n'),
                    ft = ft,
                })
            end
        end
    end)

    return injections
end

return Format

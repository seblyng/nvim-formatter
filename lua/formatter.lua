local M = {}

---@param opts NvimFormatterConfig | nil
function M.setup(opts)
    opts = opts or {}
    require('formatter.config').set(opts)

    if opts.format_on_save then
        vim.api.nvim_create_autocmd('BufWritePost', {
            pattern = '*',
            group = vim.api.nvim_create_augroup('nvim-formatter_on_save_buf', { clear = true }),
            callback = function()
                if type(opts.format_on_save) == 'function' then
                    if opts.format_on_save() then
                        require('formatter.format'):new():start('all', true)
                    end
                else
                    require('formatter.format'):new():start('all', true)
                end
            end,
        })
    end

    local arguments = { 'basic', 'injections' }
    local function parse_cmdline(args)
        return vim.iter(vim.split(args, ' '))
            :filter(function(item)
                return item ~= ''
            end)
            :totable()
    end

    vim.api.nvim_create_user_command('Format', function(c_opts)
        local Format = require('formatter.format')

        local args = parse_cmdline(c_opts.args)
        local range = c_opts.range ~= 0 and { start = c_opts.line1, ['end'] = c_opts.line2 } or nil

        -- Format regular if no arguments or the only argument is either
        -- "basic" or "injections"
        if vim.tbl_isempty(args) or (vim.tbl_contains(arguments, args[1]) and #args < 2) then
            local type = vim.tbl_isempty(args) and 'all' or args[1]
            Format:new(range):start(type)
        else
            local type = vim.iter(arguments):find(args[1]) or 'all'
            ---@diagnostic disable-next-line: param-type-mismatch
            local paths = vim.fn.globpath(vim.uv.cwd(), args[2] or args[1], 0, 1)

            for _, path in ipairs(paths) do
                vim.api.nvim_create_autocmd('BufAdd', {
                    once = true,
                    pattern = path,
                    callback = function(a)
                        vim.api.nvim_buf_call(a.buf, function()
                            vim.cmd.filetype('detect')
                        end)
                        Format:new(range, a.buf):start(type)
                    end,
                })

                local bufnr = vim.fn.bufnr(path)
                if bufnr == -1 then
                    vim.cmd.badd(path)
                else
                    Format:new(range, bufnr):start(type)
                end
            end
        end
    end, {
        complete = function(arg_lead, cmdline)
            local args = parse_cmdline(cmdline)
            if vim.tbl_contains(arguments, args[2]) then
                return
            end

            return vim.iter(arguments)
                :filter(function(item)
                    return vim.startswith(item, arg_lead)
                end)
                :totable()
        end,
        nargs = '?',
        range = '%',
        bar = true,
    })
end

M.formatexpr = function()
    if vim.list_contains({ 'i', 'R', 'ic', 'ix' }, vim.fn.mode()) then
        -- `formatexpr` is also called when exceeding `textwidth` in insert mode
        -- fall back to internal formatting
        return 1
    end

    local start_lnum = vim.v.lnum
    local end_lnum = start_lnum + vim.v.count - 1

    if start_lnum <= 0 or end_lnum <= 0 then
        return 0
    end

    require('formatter.format'):new({ start = start_lnum, ['end'] = end_lnum }):start('all')
    return 0
end

return M

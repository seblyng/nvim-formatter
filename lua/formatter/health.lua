local M = {}

---@return table<string, string[]>
local function get_configured_executables()
    local config = require('formatter.config').get()
    local executables = {}

    for ft, formatter_config in pairs(config.filetype) do
        if type(formatter_config) == 'string' then
            local exe = vim.split(formatter_config, ' ')[1]
            executables[ft] = executables[ft] or {}
            table.insert(executables[ft], exe)
        elseif type(formatter_config) == 'table' then
            if formatter_config.exe then
                -- Single formatter config
                executables[ft] = executables[ft] or {}
                table.insert(executables[ft], formatter_config.exe)
            elseif formatter_config[1] then
                -- Multiple formatters
                executables[ft] = executables[ft] or {}
                for _, f in ipairs(formatter_config) do
                    if type(f) == 'string' then
                        local exe = vim.split(f, ' ')[1]
                        table.insert(executables[ft], exe)
                    elseif type(f) == 'table' and f.exe then
                        table.insert(executables[ft], f.exe)
                    end
                end
            end
        end
    end

    return executables
end

function M.check()
    vim.health.start('nvim-formatter: Requirements')

    local v = vim.version()
    if not (v.major == 0 and v.minor < 10) then
        vim.health.ok('Neovim >= 0.10')
    else
        vim.health.error(
            'Neovim >= 0.10 is required',
            'Please upgrade to Neovim 0.10 or later. See https://github.com/neovim/neovim/releases'
        )
    end

    local config = require('formatter.config').get()
    if not config or not next(config.filetype) then
        vim.health.start('nvim-formatter: Configuration')

        vim.health.warn(
            'No formatters configured',
            "Call require('formatter').setup({ filetype = { ... } }) to configure formatters"
        )
        return
    end

    vim.health.start('nvim-formatter: Open Buffers')

    local open_buffers = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
            local ft = vim.bo[bufnr].filetype
            if ft ~= '' then
                table.insert(open_buffers, { bufnr = bufnr, ft = ft })
            end
        end
    end

    if #open_buffers > 0 then
        for _, buf in ipairs(open_buffers) do
            local configured_as = nil
            if config.filetype[buf.ft] then
                configured_as = buf.ft
            elseif config.filetype['_'] then
                configured_as = '_'
            end

            if configured_as then
                vim.health.ok(string.format('buf %d (%s): configured as %s', buf.bufnr, buf.ft, configured_as))
            else
                vim.health.info(string.format('buf %d (%s): no formatter configured', buf.bufnr, buf.ft))
            end
        end
    else
        vim.health.info('No buffers with filetypes open')
    end

    vim.health.start('nvim-formatter: Formatters')

    local executables = get_configured_executables()

    if not next(executables) then
        vim.health.info('No formatters found in configuration')
        return
    end

    -- Group by executable instead of filetype
    local exe_to_filetypes = {}
    for ft, exes in pairs(executables) do
        for _, exe in ipairs(exes) do
            exe_to_filetypes[exe] = exe_to_filetypes[exe] or {}
            table.insert(exe_to_filetypes[exe], ft)
        end
    end

    local missing_count = 0
    local found_count = 0

    for exe, fts in pairs(exe_to_filetypes) do
        table.sort(fts)
        local ft_list = table.concat(fts, ', ')
        if vim.fn.executable(exe) == 1 then
            vim.health.ok(string.format('%s: %s', exe, ft_list))
            found_count = found_count + 1
        else
            vim.health.warn(string.format('%s (executable not found): %s', exe, ft_list))
            missing_count = missing_count + 1
        end
    end
end

return M

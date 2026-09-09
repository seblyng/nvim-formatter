# nvim-formatter

Asynchronous formatter with treesitter integration

## Requirements

- Neovim 0.13

## Install

Using your package manager of choice

```lua
require('lazy').setup({
    { 'seblyng/nvim-formatter' },
})
```

### Configure

To configure you need to set it up with each key in the table being the
filetype, and the value being a `string`. You can use `string.format()` to do
more advanced arguments.

However, if you want even more control, you can also create a function that
returns either a string or a table with the following keys.

| Key    | Type      | Meaning                                    |
| ------ | --------- | ------------------------------------------ |
| `exe`  | string    | Executable to run                          |
| `cond` | function? | Returns a boolean whether to format or not |
| `args` | table?    | Table of args to pass                      |
| `cwd`  | string?   | The path to run the program from           |

### Examples:

```lua
require('formatter').setup({
    filetype = {
        -- Returns a function that will run the first time it is formatting
        lua = function()
            return {
                exe = 'stylua',
                args = { '--search-parent-directories', '--stdin-filepath', vim.api.nvim_buf_get_name(0), '-' },
            }
        end,
        -- Assumes this is `exe`
        go = 'goimports',
        -- Will split on spaces and assumes the first is `exe` and rest is `args`
        rust = 'rustfmt --edition 2021',
    },
})
```

### Multiple formatters per filetype

If you like to run multiple formatters per filetype, the value of a filetype
could be a table of formatters. This runs stylua first, then runs luafmt. Note
that you probably do NOT want to run multiple formatters. I implemented this
specifically for my own purpose of wanting to format
[`leptos`](https://github.com/leptos-rs/leptos) in Rust using
[`leptosfmt`](https://github.com/bram209/leptosfmt) while still also format
using [`rustfmt`](https://github.com/rust-lang/rustfmt)

```lua
require('formatter').setup({
    filetype = {
        -- Two formatters, and both configured as strings
        lua = {
            'stylua --search-parent-directories -',
            'luafmt --stdin',
        },

        -- Two formatters where one is configured as a function and the other as
        -- a string
        lua = {
            'stylua --search-parent-directories -',
            function()
                return 'luafmt --stdin'
            end,
        },
    },
})
```

### Treesitter:

By default, `nvim-formatter` will format the injected regions all the way to the
left, and does not respect the current indent of the injection. This can be
overridden with

```lua
require('formatter').setup({
    treesitter = {
        auto_indent = {
            lua = true,
            graphql = function()
                return vim.bo.ft ~= 'markdown'
            end,
        },
        disable_injected = {
            markdown = { 'rust' },
        },
    },
})
```

`treesitter.auto_indent` takes a table of filetypes, where the value can be
either a boolean or a function returning a boolean on whether to accept the
current indent or not. If it returns true, then it will format the entire
injected area with the indent of the first line of the injection.

`treesitter.disable_injected` takes a table of filetypes, where the value should
be a table of filetypes that it should not format as an injected language. The
example will for example not format Rust regions in a markdown file.

### Fallback support

There is a special syntax for fallback, if you for example want to run `sed` to remove all trailing white space
in the buffer. This is an example of how you can do that.

```lua
require('formatter').setup({
    treesitter = {
        filetype = {
            -- By default, this will only run it on the entire buffer, and not on any injected regions.
            -- If you want that behavior, you need to configure `disabled_injected` with `*` as key to be an empty table
            _ = 'sed s/[[:space:]]*$//',
        },
    },
})
```

### Format on save

To enable format on save, you can set an option `format_on_save` to true or a
function that returns a boolean. This options is set to false by default. If it
is a function, it will only format on save if the function returns true.

For example, you can have a buffer variable that can toggle formatting on save
on and off with:

```lua
vim.keymap.set('n', '<leader>tf', function()
    vim.b.disable_formatting = not vim.b.disable_formatting
    if vim.b.disable_formatting then
        vim.api.nvim_echo({ { 'Disabled autoformat on save' } }, false, {})
    else
        vim.api.nvim_echo({ { 'Enabled autoformat on save' } }, false, {})
    end
end, { desc = 'Format: Toggle format on save' })
```

You can then setup `nvim-formatter` like this

```lua
require('formatter').setup({
    format_on_save = function()
        return not vim.b.disable_formatting
    end,
})
```

As `nvim-formatter` is a formatter plugin, it is also able to setup
`format_on_save` for language servers. It accepts a list of language server
names. This will run `vim.lsp.buf.format()` through the `Format` command.
If you also have `format_on_save` setup, then it will of course also work with that.

```lua
require('formatter').setup({
    lsp = { 'rust_analyzer', 'lua_ls' },
})
```

### Exposed commands

- `Format`: Formats everything in the buffer including injections

In addition to this, the command is able to take an argument of either `basic`
or `injections`.

- `basic` will only format the buffer _excluding_ treesitter injections.
- `injections` will _only_ format the injections in the buffer

These are optional, and the default behaviour without these
will format both with and without treesitter. First it will try to format
normally, and then it will try to format the injections. Everything will be
applied at once to maintain a single undo history. Currently, it will format
normally if injections fail.

It is also possible to specify a list of files or a glob-pattern to the command,
and `nvim-formatter` will then format all files matching with the formatter
setup.

### Format from terminal!

`nvim-formatter` also supports formatting via the command line. It is possibly
by running the format command via script mode like:
`nvim -u ~/.config/nvim/init.lua -Es +":Format <args>"`

Here you can pass all the same arguments as inside neovim, and `nvim-formatter`
will format all the matching files from the arguments. A pro-tip is to create a
function like:

```bash
function format() {
    nvim -u ~/.config/nvim/init.lua -Es +":Format $*"
}
```

Then you can just call `format **/*.lua` for example.

## Acknowledgement

The implementation of minimal text edits was inspired by
[`conform.nvim`](https://github.com/stevearc/conform.nvim/tree/master). I
initially wrote this plugin before `conform.nvim` existed, but then without
minimal text edits. This was pretty much the only thing I was missing. I would
highly suggest to use `conform.nvim` over this plugin, as I mainly wrote this
for my own use, when `formatter.nvim` didn't fit my needs. I will continue to
use this plugin and maintain it, but I can't guarantee the same maintainability
as `conform.nvim`, and I will probably not add many more features as I see this
as pretty much feature complete.

Huge thanks to [`formatter.nvim`](https://github.com/mhartington/formatter.nvim)
for initial inspiration

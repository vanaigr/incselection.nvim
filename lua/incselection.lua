-- mostly copied from nvim-treesitter 42fc28ba918343ebfd5565147a42a26580579482

local api = vim.api
local motion = require('motion')
local motionUtil = require('motion.util')

local ts_utils = require "nvim-treesitter.ts_utils"
local locals = require "nvim-treesitter.locals"
local parsers = require "nvim-treesitter.parsers"
local queries = require "nvim-treesitter.query"

local M = {}

---@type table<integer, table<TSNode|nil>>
local selections = {}

-- Get the range of the current visual selection.
local function visual_selection_range()
    local _, csrow, cscol, _ = unpack(vim.fn.getpos "v") ---@type integer, integer, integer, integer
    local _, cerow, cecol, _ = unpack(vim.fn.getpos ".") ---@type integer, integer, integer, integer

    local start_row, start_col, end_row, end_col ---@type integer, integer, integer, integer

    if csrow < cerow or (csrow == cerow and cscol <= cecol) then
        start_row = csrow
        start_col = cscol
        end_row = cerow
        end_col = cecol
    else
        start_row = cerow
        start_col = cecol
        end_row = csrow
        end_col = cscol
    end

    local b, e = { start_row, start_col - 1 }, { end_row, end_col - 1 }
    if vim.api.nvim_get_option_value('selection', {}) ~= 'exclusive' then
        local ctx = motionUtil.create_context()
        motionUtil.move_to_next(e, ctx)
    end

    return { b[1] - 1, b[2], e[1] - 1, e[2] }
end

local function range_eq(a, b)
    return a[1] == b[1] and a[2] == b[2]
        and a[3] == b[3] and a[4] == b[4]
end

local function update_selection(range)
    local b = { 1 + range[1], range[2] }
    local e = { 1 + range[3], range[4] }
    if motion.range_to_visual(b, e) then
        vim.api.nvim_win_set_cursor(0, b)
        vim.cmd([[noautocmd normal! o]])
        vim.api.nvim_win_set_cursor(0, e)
    end
end

---@param get_parent fun(node: TSNode): TSNode|nil
local function select_incremental(get_parent)
    local buf = api.nvim_get_current_buf()
    local nodes = selections[buf]

    local range = visual_selection_range()
    -- Initialize incremental selection with current selection
    if not nodes or #nodes == 0 or not range_eq({ nodes[#nodes]:range() }, range) then
        local parser = parsers.get_parser()
        parser:parse { vim.fn.line "w0" - 1, vim.fn.line "w$" }
        local node = parser:named_node_for_range(range, { ignore_injections = false })
        update_selection({ node:range() })
        if nodes and #nodes > 0 then
            table.insert(selections[buf], node)
        else
            selections[buf] = { [1] = node }
        end
        return
    end

    -- Find a node that changes the current selection.
    local node = nodes[#nodes] ---@type TSNode
    while true do
        local parent = get_parent(node)
        if not parent or parent == node then
            -- Keep searching in the parent tree
            local root_parser = parsers.get_parser()
            root_parser:parse { vim.fn.line "w0" - 1, vim.fn.line "w$" }
            local current_parser = root_parser:language_for_range(range)
            if root_parser == current_parser then
                node = root_parser:named_node_for_range(range)
                update_selection({ node:range() })
                return
            end
            -- NOTE: parent() method is private
            local parent_parser = current_parser:parent()
            parent = parent_parser:named_node_for_range(range)
        end
        node = parent
        local nr = { node:range() }
        local same_range = range_eq(nr, range)
        if not same_range then
            table.insert(selections[buf], node)
            if node ~= nodes[#nodes] then
                table.insert(nodes, node)
            end
            update_selection(nr)
            return
        end
    end
end


function M.init_selection()
    local buf = api.nvim_get_current_buf()
    parsers.get_parser():parse { -1 + vim.fn.line "w0", -1 + vim.fn.line "w$" + 1 }
    local node = ts_utils.get_node_at_cursor()
    selections[buf] = { [1] = node }

    vim.cmd([[noautocmd normal! v]])
    update_selection({ node:range() })
end

function M.node_incremental()
    select_incremental(function(node) return node:parent() or node end)
end

function M.scope_incremental()
    select_incremental(function(node)
        local lang = parsers.get_buf_lang()
        if queries.has_locals(lang) then
            return locals.containing_scope(node:parent() or node)
        else
            return node
        end
    end)
end

function M.node_decremental()
    local buf = api.nvim_get_current_buf()
    local nodes = selections[buf]
    if not nodes or #nodes < 2 then
        return
    end

    table.remove(selections[buf])
    local node = nodes[#nodes] ---@type TSNode
    update_selection({ node:range() })
end

return M

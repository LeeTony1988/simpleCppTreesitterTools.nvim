local M = {}
local namespaceHelpers = require("simpleCppTreesitterTools.namespaceHelpers")

local function field_child(node, field)
    if not node then return nil end
    if node.child_by_field_name then return node:child_by_field_name(field) end
    if node.field then
        local values = node:field(field)
        return values and values[1] or nil
    end
end

local function node_text(node, bufnr)
    return vim.treesitter.get_node_text(node, bufnr)
end

local function find_function_declarator(node)
    if not node then return nil end
    if node:type() == "function_declarator" then return node end
    for i = 0, node:named_child_count() - 1 do
        local found = find_function_declarator(node:named_child(i))
        if found then return found end
    end
end

local function name_node(declarator)
    local name = field_child(declarator, "declarator")
    if name and (name:type() == "identifier" or name:type() == "field_identifier" or name:type() == "qualified_identifier" or name:type() == "operator_name" or name:type() == "destructor_name") then
        return name
    end
    for i = 0, declarator:named_child_count() - 1 do
        local c = declarator:named_child(i)
        if c:type():find("identifier", 1, true) or c:type() == "operator_name" or c:type() == "destructor_name" then return c end
    end
    return name
end


local function scope_parts(node, bufnr)
    local classes, namespaces = {}, {}
    local p = node:parent()
    while p do
        if p:type() == "class_specifier" or p:type() == "struct_specifier" then
            local n = field_child(p, "name")
            local name_text = n and node_text(n, bufnr)
            if not name_text or name_text == "" then
                name_text = node_text(p, bufnr):match("class%s+([%w_]+)") or node_text(p, bufnr):match("struct%s+([%w_]+)")
            end
            if name_text and name_text ~= "" then table.insert(classes, 1, name_text) end
        elseif p:type() == "namespace_definition" then
            local n = field_child(p, "name")
            local name_text = n and node_text(n, bufnr)
            if not name_text or name_text == "" then
                name_text = node_text(p, bufnr):match("^%s*namespace%s+([%w_:]+)")
            end
            if name_text and name_text ~= "" then table.insert(namespaces, 1, name_text) end
        end
        p = p:parent()
    end
    return classes, namespaces
end

local function named_descendant(node, node_type)
    if not node then return nil end
    if node:type() == node_type then return node end
    for i = 0, node:named_child_count() - 1 do
        local found = named_descendant(node:named_child(i), node_type)
        if found then return found end
    end
    return nil
end

function M.moveCurrentDefinition(config)
    config = config or {}
    local bufnr = vim.api.nvim_get_current_buf()
    local header = vim.api.nvim_buf_get_name(bufnr)
    local ext = config.headerExtension or ".h"
    if header == "" or header:sub(-#ext) ~= ext then
        vim.notify("Run this command from a C++ header buffer", vim.log.levels.WARN); return false
    end
    local node = vim.treesitter.get_node({ bufnr = bufnr })
    while node and node:type() ~= "function_definition" do node = node:parent() end
    if not node then vim.notify("Place the cursor on a function definition", vim.log.levels.WARN); return false end
    local p = node
    while p do
        if p:type() == "template_declaration" then vim.notify("Function templates should stay in the header", vim.log.levels.WARN); return false end
        p = p:parent()
    end
    local full = node_text(node, bufnr)
    if full:match("=%s*(default|delete)%s*;") then vim.notify("Skipping = default/delete function", vim.log.levels.INFO); return false end
    local body = field_child(node, "body")
    local decl = find_function_declarator(node)
    local name = decl and name_node(decl)
    if not body or not decl or not name then vim.notify("Unsupported function definition", vim.log.levels.WARN); return false end

    local sr, sc = node:start(); local br, bc = body:start()
    local sig = vim.trim(table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, br, bc, {}), "\n"))
    local initializer = named_descendant(node, "field_initializer_list")
    local declaration_end_row, declaration_end_col = br, bc
    if initializer then
        declaration_end_row, declaration_end_col = initializer:start()
    end
    local declaration_sig = vim.trim(table.concat(vim.api.nvim_buf_get_text(
        bufnr, sr, sc, declaration_end_row, declaration_end_col, {}), "\n")):gsub("^inline%s+", "")
    sig = sig:gsub("^inline%s+", "")
    local raw = node_text(name, bufnr)
    local classes, namespaces = scope_parts(node, bufnr)
    local prefix = ""
    if #classes > 0 then prefix = table.concat(classes, "::") end
    if prefix ~= "" then prefix = prefix .. "::" end
    -- Qualify exactly the declarator name (not a same-named return type).
    local nr, nc = name:start(); local ne_r, ne_c = name:end_()
    local before_name = vim.trim(table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, nr, nc, {}), "\n"))
    local after_name = table.concat(vim.api.nvim_buf_get_text(bufnr, ne_r, ne_c, br, bc, {}), "\n")
    local source_sig = vim.trim(before_name .. (prefix ~= "" and prefix or "") .. raw .. after_name):gsub("^inline%s+", "")
    local declaration = declaration_sig .. ";"
    local body_text = node_text(body, bufnr)

    local cpp = vim.fn.fnamemodify(header, ":r") .. (config.implementationExtension or ".cpp")
    local lines = vim.fn.filereadable(cpp) == 1 and vim.fn.readfile(cpp) or { '#include "' .. vim.fn.fnamemodify(header, ":t") .. '"', "" }
    local existing = table.concat(lines, "\n")
    if existing:find(vim.trim(source_sig), 1, true) then vim.notify("Function definition already exists", vim.log.levels.INFO); return false end
    local moved = vim.split(source_sig .. "\n" .. body_text, "\n", { plain = true })
    table.insert(lines, "")
    namespaceHelpers.insert(lines, namespaces, moved)
    if not config.dontActuallyWriteFiles then
        vim.fn.writefile(lines, cpp)
        local er, ec = node:end_()
        vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, vim.split(declaration, "\n", { plain = true }))
        vim.cmd("update")
    end
    vim.notify("Moved " .. raw .. " to implementation file", vim.log.levels.INFO)
    return true
end

return M

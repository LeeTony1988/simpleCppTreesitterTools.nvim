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

local function iter_named_children(node)
    local index = 0
    local count = node:named_child_count()
    return function()
        if index >= count then return nil end
        local child = node:named_child(index)
        index = index + 1
        return child
    end
end

local function has_template_ancestor(node)
    local parent = node and node:parent() or nil
    while parent do
        if parent:type() == "template_declaration" then return true end
        parent = parent:parent()
    end
    return false
end

local function containing_classes(node, bufnr)
    local classes = {}
    local parent = node and node:parent() or nil
    while parent do
        if parent:type() == "class_specifier" or parent:type() == "struct_specifier" then
            local name = field_child(parent, "name")
            local value = name and node_text(name, bufnr)
                or node_text(parent, bufnr):match("class%s+([%w_]+)")
                or node_text(parent, bufnr):match("struct%s+([%w_]+)")
            if value and value ~= "" then table.insert(classes, 1, value) end
        end
        parent = parent:parent()
    end
    return classes
end

local function containing_namespaces(node, bufnr)
    local namespaces = {}
    local parent = node and node:parent() or nil
    while parent do
        if parent:type() == "namespace_definition" then
            local name = field_child(parent, "name")
            local value = name and node_text(name, bufnr) or node_text(parent, bufnr):match("namespace%s+([%w_:]+)")
            if value then
                local parts = {}
                for part in value:gmatch("[^:]+") do table.insert(parts, part) end
                for index = #parts, 1, -1 do table.insert(namespaces, 1, parts[index]) end
            end
        end
        parent = parent:parent()
    end
    return namespaces
end

local function resolve_name_node(declarator)
    if not declarator then return nil end
    local kind = declarator:type()
    if kind == "identifier" or kind == "field_identifier" or kind == "operator_name" or kind == "destructor_name" then
        return declarator
    end
    if kind == "qualified_identifier" then return field_child(declarator, "name") or declarator end
    local name = field_child(declarator, "name")
    if name then return name end
    local inner = field_child(declarator, "declarator")
    if inner then return resolve_name_node(inner) end
    if declarator:named_child_count() == 1 then return resolve_name_node(declarator:named_child(0)) end
    return nil
end

local function normalize_ws(value)
    return vim.trim(value:gsub("%s+", " "))
end

local function strip_definition_keywords(value)
    for _, keyword in ipairs({ "static", "inline", "virtual", "friend", "explicit", "override" }) do
        value = value:gsub("(%f[%a_])" .. keyword .. "(%f[^%a_])%s*", "")
    end
    return vim.trim(value)
end

local function collect_definitions(root, bufnr, want_class)
    local result = {}
    local function walk(node)
        if node:type() == "function_definition" then
            local classes = containing_classes(node, bufnr)
            local is_class = #classes > 0
            if is_class == want_class and not has_template_ancestor(node) then table.insert(result, node) end
            return
        end
        for child in iter_named_children(node) do walk(child) end
    end
    walk(root)
    table.sort(result, function(left, right)
        local lrow = left:start(); local rrow = right:start()
        return lrow < rrow
    end)
    return result
end

local function build_move_entry(node, bufnr, is_class)
    local body = field_child(node, "body")
    local declarator = field_child(node, "declarator")
    local name = resolve_name_node(declarator)
    if not body or not declarator or not name then return nil end

    local sr, sc = node:start()
    local br, bc = body:start()
    local end_row, end_col = br, bc
    local initializer = named_descendant(node, "field_initializer_list")
    if initializer then end_row, end_col = initializer:start() end

    local declaration = vim.trim(table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, end_row, end_col, {}), "\n"))
    declaration = declaration:gsub("^inline%s+", "") .. ";"

    local nr, nc = name:start(); local ner, nec = name:end_()
    local before = table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, nr, nc, {}), "\n")
    local after = table.concat(vim.api.nvim_buf_get_text(bufnr, ner, nec, br, bc, {}), "\n")
    local classes = containing_classes(node, bufnr)
    local namespaces = containing_namespaces(node, bufnr)
    local prefix = is_class and (#classes > 0 and table.concat(classes, "::") .. "::" or "") or ""
    local return_prefix = strip_definition_keywords(vim.trim(before))
    local qualified_name = prefix .. node_text(name, bufnr)
    local definition = vim.trim(return_prefix ~= "" and (return_prefix .. " " .. qualified_name .. after)
        or (qualified_name .. after))
    return {
        node = node,
        declaration = declaration,
        definition = definition .. " " .. node_text(body, bufnr),
        signature = normalize_ws(definition),
        namespaces = namespaces,
    }
end

local function move_all_definitions(config, want_class)
    config = config or {}
    local bufnr = vim.api.nvim_get_current_buf()
    local header = vim.api.nvim_buf_get_name(bufnr)
    local ext = config.headerExtension or ".h"
    if header == "" or header:sub(-#ext) ~= ext then
        vim.notify("Run this command from a C++ header buffer", vim.log.levels.WARN)
        return false
    end
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "cpp")
    if not ok or not parser then
        vim.notify("C++ Treesitter parser is not available", vim.log.levels.ERROR)
        return false
    end
    local tree = parser:parse()[1]
    local nodes = collect_definitions(tree:root(), bufnr, want_class)
    local entries = {}
    for _, node in ipairs(nodes) do
        local entry = build_move_entry(node, bufnr, want_class)
        if entry then table.insert(entries, entry) end
    end
    if #entries == 0 then
        vim.notify(want_class and "No non-template class member definitions found" or "No non-template free function definitions found", vim.log.levels.INFO)
        return false
    end

    local cpp = vim.fn.fnamemodify(header, ":r") .. (config.implementationExtension or ".cpp")
    local lines = vim.fn.filereadable(cpp) == 1 and vim.fn.readfile(cpp) or { '#include "' .. vim.fn.fnamemodify(header, ":t") .. '"', "" }
    local existing = normalize_ws(table.concat(lines, "\n"))
    local to_append = {}
    for _, entry in ipairs(entries) do
        if not existing:find(entry.signature, 1, true) then
            table.insert(to_append, entry)
            existing = existing .. " " .. entry.signature
        end
    end

    local grouped = {}
    for _, entry in ipairs(to_append) do
        local key = table.concat(entry.namespaces, "::")
        grouped[key] = grouped[key] or { namespaces = entry.namespaces, definitions = {} }
        table.insert(grouped[key].definitions, entry.definition)
    end
    for _, group in pairs(grouped) do
        local content = {}
        for index, definition in ipairs(group.definitions) do
            if index > 1 then table.insert(content, "") end
            vim.list_extend(content, vim.split(definition, "\n", { plain = true }))
        end
        if #lines > 0 and lines[#lines] ~= "" then table.insert(lines, "") end
        namespaceHelpers.insert(lines, group.namespaces, content)
    end

    if not config.dontActuallyWriteFiles then
        if #to_append > 0 then vim.fn.writefile(lines, cpp) end
        for index = #entries, 1, -1 do
            local node = entries[index].node
            local sr, sc = node:start(); local er, ec = node:end_()
            vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, vim.split(entries[index].declaration, "\n", { plain = true }))
        end
        vim.cmd("update")
    end
    vim.notify(string.format("Converted %d definition(s); appended %d to %s", #entries, #to_append,
        vim.fn.fnamemodify(cpp, ":t")), vim.log.levels.INFO)
    return true
end

function M.moveAllDefinitionsToImplementation(config)
    return move_all_definitions(config, false)
end

function M.moveAllClassDefinitionsToImplementation(config)
    return move_all_definitions(config, true)
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

local helperBot = require("simpleCppTreesitterTools.fileHelpers")

local M = {}

local function text(node, bufnr)
    return vim.treesitter.get_node_text(node, bufnr)
end

local function field_child(node, field)
    if not node then return nil end
    if node.child_by_field_name then
        return node:child_by_field_name(field)
    end
    if node.field then
        local children = node:field(field)
        return children and children[1] or nil
    end
    return nil
end

local function child_by_type(node, node_type)
    for i = 0, node:named_child_count() - 1 do
        local child = node:named_child(i)
        if child:type() == node_type then
            return child
        end
    end
    return nil
end

local function find_function_declarator(node)
    if not node then return nil end
    if node:type() == "function_declarator" then return node end
    for i = 0, node:named_child_count() - 1 do
        local found = find_function_declarator(node:named_child(i))
        if found then return found end
    end
    return nil
end

local function find_name_node(node)
    if not node then return nil end
    local kind = node:type()
    if kind == "identifier" or kind == "field_identifier" or kind == "operator_name" or kind == "destructor_name" then
        return node
    end
    if kind == "qualified_identifier" then
        return field_child(node, "name") or node
    end
    for i = 0, node:named_child_count() - 1 do
        local found = find_name_node(node:named_child(i))
        if found then return found end
    end
    return nil
end

local function strip_default_arguments(parameter_list, bufnr)
    local parameters = {}
    for i = 0, parameter_list:named_child_count() - 1 do
        local parameter = parameter_list:named_child(i)
        local start_row, start_col = parameter:start()
        local end_row, end_col = parameter:end_()
        local default_value = field_child(parameter, "default_value")
        if default_value then
            end_row, end_col = default_value:start()
        end
        local chunks = vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
        table.insert(parameters, vim.trim(table.concat(chunks, "\n")))
    end
    return "(" .. table.concat(parameters, ", ") .. ")"
end

local function namespace_prefix(node, bufnr)
    local parts = {}
    local current = node:parent()
    while current do
        if current:type() == "namespace_definition" then
            local name = field_child(current, "name")
            if name then table.insert(parts, 1, text(name, bufnr)) end
        end
        current = current:parent()
    end
    if #parts == 0 then return "" end
    return table.concat(parts, "::") .. "::"
end

local function current_declaration(bufnr)
    local node = vim.treesitter.get_node({ bufnr = bufnr })
    while node do
        if node:type() == "declaration" then return node end
        if node:type() == "function_definition" then return nil end
        node = node:parent()
    end
    return nil
end

local function cpp_path(header_path, extension)
    return vim.fn.fnamemodify(header_path, ":r") .. extension
end

function M.implementCurrentDeclaration(config)
    local bufnr = vim.api.nvim_get_current_buf()
    local header_path = vim.api.nvim_buf_get_name(bufnr)
    if header_path == "" then
        vim.notify("Current buffer has no file", vim.log.levels.ERROR)
        return false
    end
    local header_extension = config.headerExtension or ".h"
    if header_path:sub(-#header_extension) ~= header_extension then
        vim.notify("Run this command from a C++ header buffer", vim.log.levels.WARN)
        return false
    end

    local declaration = current_declaration(bufnr)
    local function_declarator = find_function_declarator(declaration)
    if not declaration or not function_declarator then
        vim.notify("Place the cursor on a free function declaration", vim.log.levels.WARN)
        return false
    end
    local scope_node = declaration:parent()
    while scope_node do
        if scope_node:type() == "class_specifier" or scope_node:type() == "struct_specifier" then
            vim.notify("Use ImplementMemberOnCursorLine for class members", vim.log.levels.WARN)
            return false
        end
        scope_node = scope_node:parent()
    end
    local template = declaration
    while template do
        if template:type() == "template_declaration" then
            vim.notify("Function templates should stay in the header", vim.log.levels.WARN)
            return false
        end
        template = template:parent()
    end

    local name_node = find_name_node(function_declarator)
    local parameter_list = child_by_type(function_declarator, "parameter_list")
    if not name_node or not parameter_list then
        vim.notify("Unsupported function declaration", vim.log.levels.WARN)
        return false
    end

    local start_row, start_col = declaration:start()
    local name_row, name_col = name_node:start()
    local name_end_row, name_end_col = name_node:end_()
    local end_row, end_col = declaration:end_()
    local before = vim.api.nvim_buf_get_text(bufnr, start_row, start_col, name_row, name_col, {})
    local after = vim.api.nvim_buf_get_text(bufnr, name_end_row, name_end_col, end_row, end_col, {})
    local params = strip_default_arguments(parameter_list, bufnr)
    local after_text = table.concat(after, "\n")
    local parameter_start = after_text:find("%b()")
    if parameter_start then
        after_text = params .. after_text:sub(parameter_start + #after_text:match("%b()"))
    end
    after_text = after_text:gsub(";%s*$", "")
    local scope = namespace_prefix(declaration, bufnr)
    local signature = vim.trim(table.concat(before, "\n") .. scope .. text(name_node, bufnr) .. after_text)
    local definition = { signature, "{", "}", "" }

    local extension = config.implementationExtension or ".cpp"
    local cpp_file = cpp_path(header_path, extension)
    if not config.dontActuallyWriteFiles then
        helperBot.createIncludingFileIfItDoesNotExist(cpp_file)
        local existing = vim.fn.filereadable(cpp_file) == 1 and table.concat(vim.fn.readfile(cpp_file), "\n") or ""
        if existing:find(vim.trim(signature), 1, true) then
            vim.notify("Function definition already exists", vim.log.levels.INFO)
            return false
        end
        vim.fn.writefile(definition, cpp_file, "a")
        helperBot.refreshImplementationBuffer(cpp_file)
    end
    vim.notify("Implemented " .. text(name_node, bufnr), vim.log.levels.INFO)
    return true
end

return M

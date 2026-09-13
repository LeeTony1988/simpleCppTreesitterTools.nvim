local M = {}

local function wrap_namespace(lines, parts)
    if #parts == 0 then return lines end
    local wrapped = { "namespace " .. table.concat(parts, "::") .. " {", "" }
    vim.list_extend(wrapped, lines)
    table.insert(wrapped, "")
    table.insert(wrapped, "}")
    return wrapped
end

local function namespace_name(line)
    return line:match("^%s*namespace%s+([%w_:]+)%s*{")
        or line:match("^%s*namespace%s+([%w_:]+)%s*$")
end

function M.insert(lines, parts, content)
    if #parts == 0 then
        vim.list_extend(lines, content)
        return true
    end

    local wanted = table.concat(parts, "::")
    for index, line in ipairs(lines) do
        local name = namespace_name(line)
        local opening_index = index
        if name and not line:match("{") then
            if lines[index + 1] and lines[index + 1]:match("^%s*{") then
                opening_index = index + 1
            else
                name = nil
            end
        end

        if name == wanted then
            local opening = lines[opening_index]
            local comment = line:match("(//.*)$") or opening:match("(//.*)$") or ""
            if opening:match("{%s*}") then
                lines[opening_index] = "namespace " .. wanted .. " {"
                local payload = vim.deepcopy(content)
                table.insert(payload, "}")
                if comment ~= "" then payload[#payload] = payload[#payload] .. " " .. comment end
                for offset = #payload, 1, -1 do
                    table.insert(lines, opening_index + 1, payload[offset])
                end
                return true
            end

            local depth = 0
            for cursor = opening_index, #lines do
                local opens = select(2, lines[cursor]:gsub("{", ""))
                local closes = select(2, lines[cursor]:gsub("}", ""))
                depth = depth + opens - closes
                if cursor > opening_index and depth == 0 then
                    for offset = #content, 1, -1 do
                        table.insert(lines, cursor, content[offset])
                    end
                    return true
                end
            end
        end
    end

    vim.list_extend(lines, wrap_namespace(content, parts))
    return false
end

return M

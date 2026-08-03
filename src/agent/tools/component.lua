-- ═══════════════════════════════════════════════════════════════
-- agent.tools.component — OpenComputers hardware tools:
-- component_list / component_doc / component_invoke.
--
-- Module contract: exports {tools = {...}, exec = function(name, args,
-- deps)}. exec returns nil for tool names it does not handle. deps is
-- injected per call by agent.execute; json comes from deps.json.
-- ═══════════════════════════════════════════════════════════════

local tools = {
  {type="function", ["function"]={
    name="component_list",
    description="List connected OpenComputers components (optionally filtered by type name)",
    parameters={type="object", properties={filter={type="string", description="Optional type filter (e.g. 'redstone', 'gpu', 'adapter')"}}}
  }},
  {type="function", ["function"]={
    name="component_doc",
    description="Get documentation for a component's methods. Call with just an address to list all methods, or with a method name for details. Use after component_list to learn what a component can do.",
    parameters={type="object", properties={address={type="string", description="Component address (can be abbreviated, e.g. first 4 chars)"}, method={type="string", description="Optional method name to get docs for"}}, required={"address"}}
  }},
  {type="function", ["function"]={
    name="component_invoke",
    description="Call a method on an OpenComputers component. Use component_doc first to learn available methods.",
    parameters={type="object", properties={address={type="string", description="Component address (can be abbreviated)"}, method={type="string", description="Method name to call"}, args={type="array", items={type="string"}, description="Arguments to pass to the method (numbers, strings, booleans)"}}, required={"address", "method"}}
  }},
}

local function exec(name, args, deps)
  local json = deps.json

  if name == "component_list" then
    local ok, result = pcall(function()
      local comp = require("component")
      local parts = {}
      for addr, typ in comp.list(args.filter or "") do
        parts[#parts + 1] = addr:sub(1, 8) .. "... = " .. typ
      end
      if #parts == 0 then return "(no components found)" end
      return table.concat(parts, "\n")
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "component_doc" then
    local ok, result = pcall(function()
      local comp = require("component")
      local resolved, err = comp.get(args.address)
      if not resolved then
        local addr2 = comp.type(args.address) and args.address or nil
        if not addr2 then return "unknown component address: " .. tostring(args.address) .. (err and (" (" .. err .. ")") or "") end
      end
      local addr = resolved or args.address
      local parts = {}
      if args.method then
        local doc = comp.doc(addr, args.method)
        return doc and ("(" .. args.method .. ")\n" .. doc) or ("no doc for method: " .. args.method)
      else
        local methods = comp.methods(addr)
        if not methods then return "no methods listed for " .. args.address end
        for m in pairs(methods) do
          parts[#parts + 1] = m
        end
        table.sort(parts)
        return "Type: " .. tostring(comp.type(addr)) .. "\nMethods:\n" .. table.concat(parts, "\n")
      end
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "component_invoke" then
    local ok, result = pcall(function()
      local comp = require("component")
      local resolved, err = comp.get(args.address)
      if not resolved then
        local addr2 = comp.type(args.address) and args.address or nil
        if not addr2 then return "unknown component address: " .. tostring(args.address) .. (err and (" (" .. err .. ")") or "") end
      end
      local addr = resolved or args.address
      local arg_values = {}
      if type(args.args) == "table" then
        for _, v in ipairs(args.args) do
          arg_values[#arg_values + 1] = v
        end
      end
      local r = {comp.invoke(addr, args.method, table.unpack(arg_values))}
      -- format results
      local out = {}
      for _, v in ipairs(r) do
        out[#out + 1] = type(v) == "table" and json.encode(v) or tostring(v)
      end
      if #out == 0 then return "(no return values)" end
      return table.concat(out, "\n")
    end)
    return ok and result or ("Error: " .. tostring(result))
  end

  return nil  -- not handled by this module
end

return {tools = tools, exec = exec}

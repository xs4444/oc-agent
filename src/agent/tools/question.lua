-- ═══════════════════════════════════════════════════════════════
-- agent.tools.question — ask_user 工具（仿 opencode question）。
--
-- LLM 在对话过程中向用户提问（澄清需求/提供选项），REPL 模式下
-- 阻塞等待用户输入（io.read），答案作为 tool 结果喂回 LLM。
-- subagent 模式无终端，返回不可用错误。
--
-- 实现要点：真正的读输入逻辑由 init.lua 注入（deps.ask_user），
-- 因为只有 REPL 主循环知道当前是否有终端；本模块只负责声明和
-- 转发。deps.ask_user(args) 返回字符串答案。
-- ═══════════════════════════════════════════════════════════════

local tools = {
  {type="function", ["function"]={
    name="ask_user",
    description="Ask the user a question during the conversation. Use when you need to clarify requirements, get decisions on choices, or offer options before proceeding. Options are shown as a numbered list; the user picks one or more numbers (or types a custom answer). Returns the user's answer as text.",
    parameters={type="object", properties={
      question={type="string", description="Complete question to ask"},
      options={type="array", items={type="string"}, description="Optional numbered choices to present"},
      multiple={type="boolean", description="Allow selecting multiple options (default false)"}
    }, required={"question"}}
  }},
}

local function exec(name, args, deps)
  if name == "ask_user" then
    local ask = deps and deps.ask_user
    if not ask then
      return "Error: ask_user unavailable (no terminal in this mode)"
    end
    local ok, res = pcall(ask, args)
    if ok then return res end
    return "Error: " .. tostring(res)
  end

  return nil  -- not handled by this module
end

return {tools = tools, exec = exec}

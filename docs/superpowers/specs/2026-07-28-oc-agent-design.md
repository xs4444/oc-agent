# OC Agent Design Spec

## Overview

A single-file Lua agent that runs inside OpenComputers (GTNH), connects to OpenAI-compatible LLM APIs via Internet Card, and provides tool-calling capabilities including autonomous Lua code execution. Inspired by the Pi agent architecture but adapted for OC's constraints.

## Decisions

- **Single file** `agent.lua` — manual install to OC filesystem
- **OpenAI-compatible** API format with native `tool_calls`
- **6 core tools** — agent can self-bootstrap more via `execute_lua`
- **Full trust** — LLM-generated code runs unsandboxed via `load()`
- **Non-streaming** — collect full response (OC `internet.request` auto-yields)

## File Structure

```
agent.lua (~550 lines)
├── JSON Codec           (~150 lines)
├── HTTP Client          (~40 lines)
├── Tool Definitions     (~60 lines)
├── Tool Execution       (~80 lines)
├── LLM Client           (~60 lines)
├── History & Config     (~60 lines)
└── REPL & Main Loop     (~100 lines)

Runtime files (created by agent):
├── /home/agent_config.txt    — serialization format
└── /home/agent_history.txt   — serialization format
```

## Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | T1 | T2+ |
| RAM | T2 (256KB) | T3 (1MB) |
| HDD | T1 (1MB) | T2+ |
| Internet Card | T2 (HTTPS) | T2 |
| GPU + Screen | T1 | T2+ |

## Module Designs

### 1. JSON Codec

Pure Lua implementation. Handles the subset needed for OpenAI API communication.

**encode:**
- `nil` → `null`
- boolean → `true`/`false`
- number → number (handle NaN/Inf as `null`)
- string → quoted with `\n\r\t\"\\` escaping
- table with sequential integer keys → JSON array
- table with string keys → JSON object
- Reject: function, userdata, cyclic references

**decode:**
- `null` → `nil`
- Parse: string (with escape reversal), number, boolean, array, object
- Error on malformed input with position info

**Edge cases:**
- Empty table `{}` → `{}` (JSON empty object)
- Mixed tables: only string-key or sequential-integer-key, not both
- No `\uXXXX` escape output (OC strings are byte sequences)

### 2. HTTP Client

```lua
http_post(url, headers_table, body_string) -> status_code, response_body, error_or_nil
```

Implementation:
1. Call `internet.request(url, body, headers, "POST")`
2. Iterate: `for chunk in handle do result = result .. chunk end` (auto-yields, no crash risk)
3. Get status: `getmetatable(handle).__index.response()` → code, message, headers
4. Error handling: connection failure, timeout, non-2xx status

Only POST is implemented (LLM API only needs POST).

### 3. Tool Definitions

OpenAI function calling format:

```lua
tools = {
  {
    type = "function",
    function = {
      name = "read_file",
      description = "Read file contents at the given path",
      parameters = {
        type = "object",
        properties = {
          path = { type = "string", description = "Absolute or relative file path" }
        },
        required = { "path" }
      }
    }
  },
  -- ... 5 more tools
}
```

**Tool list:**

| Tool | Parameters | Implementation |
|------|-----------|----------------|
| `read_file` | `{path: string}` | `io.open(path,"r"):read("*a")` |
| `write_file` | `{path: string, content: string}` | `io.open(path,"w"):write(content)` |
| `list_directory` | `{path: string}` | `filesystem.list(path)` collected to string |
| `execute_lua` | `{code: string}` | `load(code)` + `pcall()`, capture stdout |
| `component_list` | `{filter?: string}` | `component.list(filter)` formatted |
| `shell_execute` | `{command: string}` | `shell.execute(command)` |

**Self-bootstrap mechanism:** LLM uses `execute_lua` to:
- `require("component")` and access any hardware
- Create new `.lua` files via `write_file`, then `require()` them
- Essentially write its own new tools at runtime

### 4. Tool Execution

```lua
execute_tool(name, arguments) -> result_string
```

**execute_lua implementation:**
1. Temporarily replace `io.write` to capture stdout
2. `load(code)` — compile the code string
3. If compile error: return "Compile error: ..."
4. `pcall(fn)` — execute with error catching
5. Restore `io.write`
6. Return captured stdout + any return value or runtime error

**component_list implementation:**
- `component.list(filter)` returns iterator
- Format as `{address} = {type}` lines
- Show `component.proxy` hint for each

**shell_execute implementation:**
- `shell.execute(command)` returns success boolean + results
- Format output appropriately

### 5. LLM Client

```lua
chat(messages, config) -> {content: string?, tool_calls: table?, finish_reason: string}
```

**Request format** (POST to OpenAI /v1/chat/completions):
```json
{
  "model": "<config.model>",
  "messages": "<messages array>",
  "tools": "<tool definitions>",
  "max_tokens": 2048,
  "temperature": 0.7
}
```

**Headers:**
```json
{
  "Content-Type": "application/json",
  "Authorization": "Bearer <config.api_key>"
}
```

**Response parsing:**
- `choices[1].message.content` → text reply
- `choices[1].message.tool_calls` → array of `{id, function: {name, arguments}}`
- `choices[1].finish_reason` → "stop" | "tool_calls" | "length"

**Error handling:**
- Connection failure → show error, prompt retry
- Non-2xx → show status + body
- `finish_reason: "length"` → warn user about truncated response

### 6. Core Loop (Two-Level, Pi-Inspired)

```
REPL outer loop:
  while true:
    input = term.read(history_table)
    if nil/false → exit (Ctrl+C / Ctrl+D)
    if starts with "/" → handle slash command, continue
    
    append to messages: {role="user", content=input}
    
    Inner loop (tool-calling loop):
      while true:
        print("Thinking...")
        response = chat(messages, config)
        clear "Thinking..." line
        
        if response.content:
          print(response.content)
        
        append to messages: {role="assistant", content=..., tool_calls=...}
        
        if not response.tool_calls:
          break inner loop
        
        for each tool_call:
          print("[tool] " .. tool_call.name)
          result = execute_tool(tool_call.name, parse(tool_call.arguments))
          append to messages: {role="tool", tool_call_id=tool_call.id, content=result}
        end
        
        -- continue inner loop with tool results in context
    
    save_history()
```

**Slash commands:**
| Command | Action |
|---------|--------|
| `/model <name>` | Change LLM model |
| `/key <api_key>` | Change API key |
| `/url <endpoint>` | Change API URL |
| `/reset` | Clear conversation history |
| `/hist` | Show message count and token estimate |
| `/tools` | List available tools |
| `/help` | Show commands |
| `/exit` | Exit agent |

### 7. Configuration & History

**First-run setup:**
```
OC Agent - First Run Setup
API Key: ****
Model [openai/gpt-4o-mini]: 
API URL [https://openrouter.ai/api/v1/chat/completions]: 
Configuration saved to /home/agent_config.txt
```

**Config storage:** `/home/agent_config.txt` using `serialization.serialize`:
```lua
{api_key="sk-...", model="openai/gpt-4o-mini", api_url="https://openrouter.ai/api/v1/chat/completions"}
```

**History storage:** `/home/agent_history.txt` using `serialization.serialize`:
- Array of `{role, content, tool_calls?, tool_call_id?}` tables
- Auto-trim: when > 20 messages, keep system prompt + last 18 messages
- `/reset` clears the file

### 8. System Prompt

```
You are an AI assistant running inside OpenComputers, a computer system in Minecraft 
(GT: New Horizons modpack). You can read and write files, execute Lua code, list 
connected hardware components, and run shell commands.

Available tools:
- read_file: Read file contents at the given path
- write_file: Write content to a file at the given path
- list_directory: List files in a directory
- execute_lua: Execute Lua code in the OpenOS environment (you can use require(), 
  component, robot, internet, etc.)
- component_list: List connected OpenComputers components (optionally filtered by name)
- shell_execute: Run an OpenOS shell command

You have full access to the OpenComputers environment. You can extend your own 
capabilities by writing new Lua scripts via write_file and loading them with 
execute_lua using require().

When writing Lua code for execute_lua, remember:
- You MUST yield periodically in loops (use os.sleep(0)) to avoid the computer crashing
- Use require() to access OpenOS libraries (component, computer, robot, internet, etc.)
- Use component.proxy() or component.list() to interact with hardware
- Files are in the OC filesystem, not the host operating system
- Memory is limited; keep code efficient and avoid large string concatenation in loops

Current computer address: {address}
Uptime: {uptime}s
Free memory: {freeMem} bytes
Connected components: {component_list_summary}
```

## Installation

Manual copy to OC filesystem. Options to explore:
1. **pastebin get** — if agent.lua is uploaded to pastebin
2. **wget** — if hosted on a web server
3. **Clipboard paste** — user copies file content, pastes in OC `edit` command
4. **internet.request download** — agent includes a bootstrap stub that downloads itself

The final installation method will be determined during implementation based on practical testing.

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| LLM response timeout (30s+) | Print "Thinking..." and yield; OC auto-yields in internet.request |
| Large response memory | `max_tokens=2048` limit; `table.concat` for chunk assembly |
| String concatenation overhead | Collect chunks in table, `table.concat` at end |
| History grows too large | Auto-trim at 20 messages; `/reset` command |
| API rate limiting | Show error; user can retry manually |
| Server disables HTTP | Check `component.internet.isHttpEnabled()` at startup |
| OC config blocks API URL | Check `component.internet.isTcpEnabled()` at startup |
| LLM generates infinite loop code | System prompt warns about yielding; OC enforces timeout anyway |

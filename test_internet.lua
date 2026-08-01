local internet = require("internet")
local handle = internet.request("https://httpbin.org/get")
if handle then
  local result = ""
  for chunk in handle do
    result = result .. chunk
  end
  print("Internet OK! Response length: " .. #result)
  print(result:sub(1, 100))
else
  print("No internet access")
end
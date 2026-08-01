### API

## 标准库

最首要的，如果你是 Lua 新人，应该先熟悉[Lua参考手册](http://www.lua.org/manual/5.3/manual.html)（英文）或[菜鸟教程网的Lua教程](https://www.runoob.com/lua/)。你可以在其中找到大部分Lua基础函数的解释，以及大量标准库函数。

OC致力于高度模拟通常用于与主机系统交互的标准库，也就是I/O库。其中有少许不同，你可以在这里查看：与标准库的差异。最值得注意的是，debug库基本上不可用，以及`load` 只接受文本源代码文件，不接受二进制或预编译的Lua程序（出于安全因素考虑）。

下列标准库在全局环境下可用，因此可以直接使用，无需预加载到你的脚本中。

  * coroutine
  * debug
  * io
  * math
  * os
  * package
  * `print` 不是库，但是经常被用于向stdout(标准输出)输出文本。

```lua
print("hello world")
```

  * string
  * table

## 自定义库

下列是为了便利而提供的非标准库的介绍。

请注意，所有非标准API在使用之前都需要`require `，非标准库即所有未在[Lua参考手册](http://www.lua.org/manual/5.3/manual.html)或[标准库](zh.md#标准库)中列出的库。例如，你不可以只写一句`local rs = component.redstone`，你还需要先通过`require`调用此API，就像这样：

```lua
local component = require("component")
local rs = component.redstone

-- 你当然可以修改变量名称：
local mycomp = require("component")
local rs = mycomp.redstone
```
以下列出的 API 都是这样（甚至`sides`和`colors`也是如此）。

除了Lua提供的标准库外，OC还提供了一些额外的内置库。下面列出了这些库。请注意它们当中的一些可能无法使用，视你的配置（HTTP）或运行环境（电脑上无法调用机器人上的库）而定，但是它们仍然存在。

- buffer(缓冲)：Lua `File*` API缓冲区的实现，用于封装流。
- colors(颜色)：一份全局表，可用于以名称引用标准Minecraft颜色。
- component(组件)：查找与管理所有连接到电脑的组件。
- computer(电脑)：查询运行Lua state的OC电脑信息，或与其交互。
- event(事件)：一个事件系统, 通常被其他库调用, 用于将处理函数注册到信号。
- uuid：创建8-4-4-4-12格式的长唯一标识字符串（uuid）。
- filesystem(文件系统)：抽象化的与文件系统组件的交互。
- internet(网络)：一个网卡功能的封装。
- keyboard(键盘)：提供了一份按键编码表，以及跟踪按键按下状态。
- note(音符)：将音符在实际名称、MIDI编码和频率间转换。
- process(进程)：保持跟踪正在运行的程序与其运行环境。
- rc(自动运行)：提供了自动运行程序和服务管理功能。
- robot(机器人)：对机器人行为的抽象化访问。
- serialization(序列化)：用于将数值序列化，例如要通过网络发送数值时。
- shell：追踪工作目录与执行程序。
- sides(方向)：一份全局表，用于通过名称引用方向。
- term(终端)：提供了光标的概念，以及用于分别从键盘读取和向屏幕输出。
- text(文本)：提供文本编辑相关功能，例如将tab转为空格。
- thread(线程)：提供自主且非阻塞的协作线程。
- transforms(转换)：提供有用且强大的表操作器。
- unicode：提供 string 库中某些功能的支持Unicode的实现。

## 目录

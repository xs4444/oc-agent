# oc-agent 垂类知识规则

- **Ground truth 优先序**：本地源码/git 历史/真机 > 项目 wiki/README > 训练记忆（仅假设）。
- 垂类断言（OpenOS/OC/GTNH）无源码或 wiki 佐证时，须明示"基于记忆，未实证"。
- 结论标注来源：源码 / git / wiki / 记忆 / 真机。
- 版本锚定：无版本语境的垂类陈述视为未验证（例：gpu 库 2013 存在，2014-01-20 959e5676c 移除，现用 component.gpu 代理）。
- 真机或用户实测与文档冲突时，以实测为准。

## 查看用户 gist（调试报告）

- **必须用脚本** `python tools/fetch_gist.py`（一次成功；手动 curl|python 管道有三坑：JSON 特殊字符截断、Windows /tmp 路径、GBK 控制台编码——压缩后尤其容易重犯）。
- token：用户真机 config 的 gist_token（40 字符），用户提供后 `export GIST_TOKEN=xxx` 使用。
- 常用：`python tools/fetch_gist.py --latest`（最新报告全文）/ `<gist_id>`（指定）/ `-o out.txt`（落盘）。
- 注意：secret gist 未认证访问一律 404；debug 报告里 Version 2026-08-09T0951 = files.json 构建时间（对应用户部署版本）。

## 仓库 clone 与 IP 封禁

- clone 参考仓库遇到 IP 封禁（429/blocked）时，**不要自行寻找镜像或代理绕过——直接询问用户**。用户可手动下载源码放入 `repos/`（例：`repos/dnkl__foot` 即用户手动提供的 foot 源码，Codeberg 封禁后由用户下载）。
- repos/ 是经典终端参考源码库（tmux/vim/mintty/opencomputers/foot 等），勘察时先看 repos/ 是否已有。

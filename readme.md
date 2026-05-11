# install-scripts

这个目录存放常用安装脚本。

## Go

交互式安装或升级 Go，支持在线检测最新版本，也可以手动指定版本：

```bash
sudo ./install_go.sh
```

## nvm

`install_nvm.sh` 按 nvm 官方当前推荐方式安装或升级 nvm 本体：复用官方 release tag 下的 `install.sh`，并通过 `PROFILE` / `NVM_DIR` 做显式控制。

注意：`nvm` 是按用户安装的，不要用 `sudo` 运行。

交互式执行：

```bash
./install_nvm.sh
```

常见示例：

```bash
./install_nvm.sh --nvm-version latest --node-version 'lts/*'
./install_nvm.sh --nvm-version v0.40.4 --node-version 22.12.0 --yes
./install_nvm.sh --profile none --yes
```

参数说明：

```text
--nvm-version  latest / v0.40.4 / 0.40.4
--node-version skip / lts/* / node / 具体版本号
--profile      auto / none / 指定配置文件路径
--nvm-dir      自定义安装目录
--yes          跳过交互确认
```

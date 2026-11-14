Balnexa 测试实例（合成数据）部署说明  2026-11-12
================================================

本包只用于合成数据测试实例（不得录入真实数据）。

【准备】
1. 电脑已安装 Node.js 20 或更新版本（https://nodejs.org 下载 LTS）。
   检查：打开终端/命令提示符，输入  node -v
2. 解压本包到任意文件夹，例如 桌面\balnexa-deploy

【部署：一条命令】
Windows：双击 deploy-windows.cmd
Mac：    右键 deploy-mac-linux.command → 打开（第一次可能需要在“系统设置→隐私与安全”允许）
或在终端里进入本文件夹后运行：  node deploy.mjs

过程中：
- 会自动打开浏览器让你登录 Cloudflare 并点 “Allow”（授权 wrangler）。
- 如果 Cloudflare 问你选哪个账户，选开 Neon/KV 的那个账户。
- 如果提示注册 workers.dev 子域，按提示接受即可。
- 脚本会部署两次（第二次填入真实网址），然后上传 3 个数据库密钥，并自动删除 secrets.json。

结束时屏幕会显示：
  Deployed: https://balnexa-test.<你的子域>.workers.dev

【部署后】
1. Google Cloud Console → APIs & Services → Credentials → 你的 OAuth client
   → Authorized JavaScript origins → 加入上面那个网址（不带 /app/，结尾不加斜杠）→ Save。
   （生效可能要几分钟）
2. 手机或电脑浏览器打开  <网址>/app/  ，用 Google 登录。
3. 页面会显示 “安装设置：此 Google 账户还不是成员……” 和一串标识（纯数字串）。
   把这串标识发给我，我把它绑定为户主。绑定后再登录即可正常使用。

【安全】
- secrets.json 含数据库密码。脚本成功后会自动删除；若中途失败，修好后重跑即可；
  不再需要时请自行删除整个文件夹。不要把它发给任何人或上传网上。
- 若出错：把终端里的最后几十行（不含密码）发给我。

# LPI Linux Essentials (010-160, v1.6) — Topic 1.4: ICT Skills and Working in Linux

> 参考来源:https://learning.lpi.org/en/learning-materials/010-160/1/1.4/
> 本文档为原创教学材料,仅将官方 objectives 页面作为大纲参考,未直接摘抄其文字。

本主题考察你在图形界面(GUI)下完成日常 ICT 任务的能力,包括桌面导航、办公软件、打印、无障碍功能、云存储概念、账户与数据安全,以及使用简单 script 自动化重复性工作。以下练习假设你使用的是带 GNOME desktop environment 的 Linux 发行版(如 Fedora Workstation 或 Ubuntu),但大部分操作在 KDE Plasma 等其他 desktop environment 中也能找到对应菜单项。

---

## 练习 1:桌面导航(Desktop Navigation)

1. 登录系统后,观察屏幕顶部或底部的 **panel**(面板,也叫 taskbar)。
2. 找到 **Activities**(GNOME)或对应的 **application menu** 按钮,点击打开。
3. 在搜索框中输入 `files`,回车启动 file manager(如 Nautilus / Files)。
4. 用鼠标右键点击桌面空白处,查看是否出现 **Change Background**(更换壁纸)或 **Display Settings** 等快捷菜单项。
5. 打开 file manager 后,观察窗口顶部的地址栏、侧边栏(Bookmarks/收藏夹)以及右上角的窗口控制按钮(最小化、最大化、关闭)。
6. 使用 `Super` 键(Windows 键)或点击 Activities,切换到 **overview** 视图,查看当前打开的所有窗口缩略图。

**问题 1.1:** 在 GNOME 中,统一管理已打开窗口、虚拟桌面(workspaces)和应用搜索的界面叫什么?

**问题 1.2:** panel 和 application menu 在功能上的主要区别是什么?

---

## 练习 2:桌面环境基本配置(Desktop Environment Configuration)

1. 打开 **Settings**(系统设置)应用。
2. 进入 **Displays**(显示),查看当前分辨率(resolution)和刷新率(refresh rate)。若有多台显示器,注意 **Join Displays**(扩展)与 **Mirror**(镜像)两种模式的区别。
3. 进入 **Background**(背景),将桌面壁纸更换为系统自带的另一张图片。
4. 进入 **Mouse & Touchpad**,尝试调整鼠标指针速度(pointer speed)。
5. 进入 **Region & Language**,查看系统当前使用的 keyboard layout(键盘布局),并尝试添加一个新的 layout(例如添加后可用快捷键在两种布局间切换)。
6. 保存更改后,重新登录一次,确认设置是否被保留。

**问题 2.1:** 为什么在演示或投影仪连接场景下,通常选择 **Mirror** 而不是 **Join Displays**?

**问题 2.2:** 添加多个 keyboard layout 后,系统通常提供什么方式在它们之间快速切换?

---

## 练习 3:文本编辑器(Text Editor)基础操作

1. 在 application menu 中搜索并打开系统自带的图形化 **text editor**(如 GNOME Text Editor 或 gedit)。
2. 输入几行文字,包含至少一个拼写错误。
3. 使用编辑器的 **Find**(查找)功能,搜索其中一个单词。
4. 使用 **Find & Replace**(查找并替换)功能,将该单词替换为另一个单词。
5. 将文件保存为 `notes.txt`,保存到 `Home`(主目录)下的 `Documents` 文件夹。
6. 关闭编辑器后,再从 file manager 中双击该文件,确认它会用默认的 text editor 重新打开。

**问题 3.1:** text editor(纯文本编辑器)与 word processor(如 LibreOffice Writer)在保存的文件格式上有什么根本区别?

**问题 3.2:** 双击一个 `.txt` 文件会自动用哪个应用打开?这是由什么机制决定的?

---

## 练习 4:办公应用 — Word Processor 与 Spreadsheet

1. 打开 **LibreOffice Writer**(word processor)。
2. 输入一段包含标题和至少两个段落的文字,并将标题设置为 **Heading 1** 样式。
3. 为其中一个段落设置加粗(bold)和斜体(italic)。
4. 使用 **File > Save As**,将文档保存为 `.odt` 格式,文件名为 `report.odt`。
5. 再次使用 **File > Save As**,将同一文档另存为 `.pdf` 格式,便于跨平台分享。
6. 关闭 Writer,打开 **LibreOffice Calc**(spreadsheet)。
7. 在 A1:A5 单元格中输入 1 到 5 的数字,在 B1 单元格输入公式 `=SUM(A1:A5)` 并回车。
8. 将该 spreadsheet 保存为 `.xlsx` 格式。

**问题 4.1:** 为什么将最终报告导出为 PDF 而不是只保留 `.odt` 格式,对跨平台分享更友好?

**问题 4.2:** `.odt` 和 `.xlsx` 分别对应哪一类办公文档的默认(或兼容)文件格式?

---

## 练习 5:媒体播放器(Media Player)

1. 在 file manager 中找到系统自带的一个音频或视频示例文件(或自行准备一个 `.mp3`/`.mp4` 文件)。
2. 双击该文件,观察系统调用了哪个默认的 **media player**。
3. 在播放器中练习暂停(pause)、快进(seek forward)、调整音量(volume)。
4. 打开播放器的 **Preferences**(首选项),查看是否可以调整播放速度或字幕(subtitle)设置。
5. 右键点击该媒体文件,选择 **Open With**(打开方式),观察系统列出的其他可用播放器。

**问题 5.1:** 如果系统上安装了多个 media player,决定双击时默认调用哪一个的是什么设置项?

**问题 5.2:** 使用 **Open With** 打开文件与直接双击打开文件,两者在"是否更改默认应用"上有何不同?

---

## 练习 6:打印基础(Basic Printing)

1. 打开 **Settings > Printers**(或通过浏览器访问 CUPS 的本地管理界面 `http://localhost:631`)。
2. 点击 **Add Printer**,查看系统检测到的本地或网络打印机列表(即使没有真实打印机,也能看到界面结构)。
3. 若已添加打印机,右键点击其图标,选择 **Print Test Page**。
4. 回到 LibreOffice Writer 中打开练习 4 保存的 `report.odt`,使用 **File > Print**。
5. 在打印对话框中,查看可设置的选项:纸张大小(paper size)、双面打印(duplex)、打印份数(copies)、打印范围(page range)。
6. 选择 **Print to File**(打印到文件),将输出保存为 PDF,而不是发送到物理打印机。

**问题 6.1:** CUPS 在 Linux 打印体系中承担的角色是什么?

**问题 6.2:** 当没有连接物理打印机时,**Print to File** 选项有什么实际用途?

---

## 练习 7:无障碍设置(Accessibility Settings)

1. 打开 **Settings > Accessibility**。
2. 启用 **Screen Reader**(屏幕阅读器,GNOME 下通常是 **Orca**),观察系统开始朗读界面元素。
3. 关闭 Screen Reader 后,启用 **High Contrast**(高对比度)主题,观察界面配色变化。
4. 尝试 **Large Text**(放大文字)选项,观察系统字体整体变大。
5. 启用 **Screen Keyboard**(屏幕键盘),尝试用鼠标点击虚拟键盘输入文字。
6. 逐一关闭以上功能,恢复默认设置。

**问题 7.1:** 举出两类可能依赖 Screen Reader 或 High Contrast 功能的用户群体。

**问题 7.2:** Large Text 和 High Contrast 分别主要解决哪种使用障碍?

---

## 练习 8:云存储概念(Cloud Storage Concepts)

1. 打开浏览器,访问一个云存储服务的网页界面(例如自建的 **Nextcloud**,或 Google Drive、Dropbox 等商业服务)。
2. 登录账户后,创建一个新文件夹,命名为 `LPI-Test`。
3. 将练习 4 中生成的 `report.pdf` 上传到该文件夹。
4. 查看该服务提供的 **Share**(分享)功能,生成一个只读的分享链接(share link)。
5. 若该服务提供官方的桌面同步客户端(sync client),了解其"本地文件夹与云端自动同步"的工作原理(无需实际安装)。
6. 讨论:将文件保存在云存储而不是仅保存在本地磁盘,对数据备份(backup)有什么意义。

**问题 8.1:** cloud storage 与传统的"仅保存在本地硬盘"相比,在数据丢失风险上有什么关键优势?

**问题 8.2:** sync client(同步客户端)与仅通过网页上传/下载文件,主要区别是什么?

---

## 练习 9:账户与数据安全(Account and Data Security)

1. 打开一个密码管理器(password manager),如 **KeePassXC** 或浏览器内置的密码管理功能(若未安装,可讨论其工作原理)。
2. 创建一个测试条目,使用密码管理器的密码生成器(generator)生成一个至少 16 位、包含大小写字母、数字和符号的强密码。
3. 在某个支持 **Two-Factor Authentication(2FA)** 的账户设置页面中,查看开启 2FA 的选项(例如通过 authenticator app 或短信验证码),了解其配置流程。
4. 打开终端,使用 `gpg --symmetric report.pdf` 对练习 4 生成的 PDF 文件进行对称加密(encryption),设置一个 passphrase。
5. 确认生成了 `report.pdf.gpg` 文件后,尝试用 `gpg --decrypt report.pdf.gpg > report_decrypted.pdf` 解密,输入之前设置的 passphrase。
6. 检查 **Settings > Privacy > Firewall**(或使用 `sudo firewall-cmd --state` 等命令),确认本机 firewall 是否处于开启状态。

**问题 9.1:** 为什么"同一个密码用于多个账户"是一个高风险的安全习惯?2FA 如何缓解这个风险?

**问题 9.2:** `gpg --symmetric` 加密方式依赖的是一个共享 passphrase,这与使用公钥/私钥(public/private key)的 asymmetric encryption 有什么区别?

---

## 练习 10:基础脚本自动化(Basic Script Automation)

1. 打开终端(terminal),使用 text editor 创建一个新文件 `backup.sh`。
2. 在文件第一行写入 shebang:`#!/bin/bash`。
3. 添加以下内容,把 Documents 文件夹打包压缩到 Home 目录下(带日期戳):
   ```bash
   #!/bin/bash
   tar -czf ~/documents-$(date +%Y%m%d).tar.gz ~/Documents
   echo "Backup completed."
   ```
4. 保存文件后,在终端中执行 `chmod +x backup.sh`,使其具备可执行权限(execute permission)。
5. 运行该 script:`./backup.sh`,观察终端输出的 "Backup completed." 提示。
6. 使用 `ls -lh` 确认生成的 `.tar.gz` 文件已出现在 Home 目录下。
7. 讨论:如果希望这个 script 每天凌晨自动执行一次,应该使用哪个 Linux 工具来 schedule 定时任务?

**问题 10.1:** shebang(`#!/bin/bash`)这一行的作用是什么?如果省略它会发生什么?

**问题 10.2:** 为什么说"写一个 script 完成重复性工作"比"每次手动重复点击 GUI 操作"更符合 ICT 中的自动化(automation)最佳实践?

---

<details>
<summary>点击展开参考答案</summary>

**1.1** 该界面叫 **Activities overview**(Activities 总览),它集中显示所有打开的窗口、workspaces 以及应用搜索入口。

**1.2** panel 是常驻屏幕边缘、始终可见的状态与快捷入口条(可包含时钟、通知、快速设置等);application menu 是用于查找和启动已安装应用的菜单/搜索界面,通常按需展开、不常驻。

**2.1** Mirror 模式下所有显示器显示完全相同的画面,便于观众在投影仪或副屏上看到与主屏一致的内容;Join Displays(扩展模式)会把桌面横向拼接,内容在不同屏幕上不同,不适合直接投影演示。

**2.2** 系统通常提供一个键盘快捷键(如在顶部 panel 点击语言指示器,或按 `Super+Space`)在已添加的多个 keyboard layout 之间循环切换。

**3.1** text editor 保存的是纯文本(plain text),不包含字体、颜色、段落样式等格式信息;word processor 保存的是富文本/结构化文档(如 `.odt`/`.docx`),包含排版、样式、图片等格式化信息。

**3.2** 由系统的"默认应用(default application)"关联机制决定,通常在 Settings 中按 MIME type(如 `text/plain`)设置某个应用为该类型文件的默认打开程序。

**4.1** PDF 是一种跨平台、格式固定的文件格式,几乎所有操作系统和设备都能正确显示同样的排版效果,而 `.odt` 需要对方也安装兼容的 word processor 才能正确打开和保持原始格式。

**4.2** `.odt`(OpenDocument Text)是 word processor(文字处理)文档的开放标准格式;`.xlsx` 是 spreadsheet(电子表格)常见的默认/兼容格式(源自 Microsoft Excel 格式,LibreOffice Calc 也可读写)。

**5.1** 由系统的"默认应用"设置决定,通常在 Settings 的 **Default Applications** 或通过文件的 MIME type 关联来指定默认 media player。

**5.2** 双击直接调用当前已设置的默认应用打开文件,不会改变默认设置;使用 **Open With** 可以临时选择另一个应用打开该文件,同时通常还会提供"始终使用此应用打开"的勾选项,只有勾选后才会更改默认设置。

**6.1** CUPS(Common Unix Printing System)是 Linux 系统中管理打印任务、打印机驱动(driver)和打印队列(print queue)的核心后台服务,GUI 打印设置和打印对话框最终都通过它与打印机通信。

**6.2** 在没有物理打印机的情况下,**Print to File** 可以把文档按"打印排版"的效果导出为 PDF 等文件,常用于生成可分享、格式固定的文档副本,而不需要真正打印到纸张。

**7.1** 例如:视力障碍或低视力用户(依赖 Screen Reader 朗读界面、依赖 High Contrast 或 Large Text 提高可读性);运动能力受限的用户(可能依赖 Screen Keyboard 等辅助输入方式)。

**7.2** Large Text 主要解决"文字过小难以看清"的问题(视觉可读性);High Contrast 主要解决"前景与背景颜色区分度不足"导致内容难以辨识的问题。

**8.1** cloud storage 将数据保存在远程服务器上,即使本地设备损坏、丢失或被盗,数据依然存在于云端,可从其他设备恢复;而仅保存在本地硬盘时,硬盘损坏或设备丢失往往意味着数据永久丢失。

**8.2** sync client 会在本地文件夹与云端之间自动、持续地保持文件同步(增删改自动双向更新),用户像操作本地文件一样使用;仅通过网页上传/下载则需要用户手动执行每一次上传或下载操作,没有自动同步。

**9.1** 如果多个账户共用同一密码,一旦其中一个账户的密码泄露,攻击者可以尝试用同一密码登录其他账户(即 credential stuffing 攻击),风险会扩散到所有关联账户;开启 2FA 后,即使密码泄露,攻击者仍缺少第二验证因素(如 authenticator app 生成的一次性验证码),难以完成登录。

**9.2** `gpg --symmetric` 使用同一个 passphrase 同时用于加密和解密(对称加密),该 passphrase 必须安全地共享给需要解密的一方;asymmetric encryption(如 GPG 的公钥/私钥模式)使用公钥加密、私钥解密,公钥可以公开分发而不泄露解密能力,更适合与他人安全地共享加密文件。

**10.1** shebang 告诉系统应该用哪个解释器(interpreter)来执行这个脚本文件(此处为 `/bin/bash`);如果省略,直接执行该文件时系统可能使用错误的解释器解析脚本,或需要用户显式指定解释器(如 `bash backup.sh`)才能正确运行。

**10.2** script 一旦编写完成即可被反复、无差错地执行,且可以配合 cron 等工具定时自动运行,减少人为遗漏或操作失误;而手动重复 GUI 操作耗时且容易出错,也无法在无人值守时自动执行。

</details>
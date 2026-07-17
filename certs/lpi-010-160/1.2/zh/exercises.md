# 1.2 Major Open Source Applications — 引导练习

> 参考来源: https://learning.lpi.org/en/learning-materials/010-160/1/1.2/

---

## 练习 1：桌面应用 — Office 套件与浏览器

1. 打开终端,运行以下命令查看已安装的 office 套件版本:
   ```
   libreoffice --version
   ```
2. 运行 `which soffice`,记录返回的可执行文件路径。
3. 分别启动 LibreOffice 的三个核心组件:
   ```
   libreoffice --writer &
   libreoffice --calc &
   libreoffice --impress &
   ```
4. 关闭上述窗口,运行 `firefox --version`(如果系统安装的是 Chromium,则运行 `chromium --version` 或 `chromium-browser --version`)。
5. 在浏览器地址栏输入 `about:support`(Firefox)或 `chrome://version`(Chromium),截图记录浏览器引擎(rendering engine)的名称。

**思考题**

- Q1: LibreOffice 中,`Writer`、`Calc`、`Impress` 三个组件分别对应 Microsoft Office 套件中的哪三款产品?
- Q2: Firefox 使用的渲染引擎叫什么名字?它与 Chromium 所用的引擎(Blink)是否为同一个项目?

---

## 练习 2：包管理工具 — 识别发行版家族

1. 查看当前发行版所属家族:
   ```
   cat /etc/os-release
   ```
2. 如果 `ID_LIKE` 或 `ID` 中出现 `debian`/`ubuntu`,执行低级包管理命令:
   ```
   dpkg -l | grep -i libreoffice
   ```
   否则(出现 `rhel`/`fedora`/`suse`),执行:
   ```
   rpm -qa | grep -i libreoffice
   ```
3. 使用对应的高级包管理器搜索一个尚未安装的包:
   ```
   apt-cache search thunderbird     # Debian/Ubuntu 系
   dnf search thunderbird           # Fedora/RHEL 系
   zypper search thunderbird        # openSUSE 系
   ```
4. 查询某个已安装包的详细信息(依赖、版本、来源):
   ```
   dpkg -s firefox      # 或
   rpm -qi firefox
   ```
5. 记录:哪一层命令(`dpkg`/`rpm`)只操作本地包数据库,哪一层命令(`apt`/`dnf`/`zypper`)会连接软件仓库并自动解析依赖关系。

**思考题**

- Q3: `dpkg` 和 `apt` 分别扮演什么角色?两者是什么关系(底层工具 vs. 上层工具)?
- Q4: `rpm` 对应的高级包管理器有哪两种(在不同发行版中)?

---

## 练习 3：服务器应用 — Web 服务器与数据库服务器

1. 检查系统中是否安装了 web 服务器,并查看其运行状态:
   ```
   systemctl status apache2 2>/dev/null || systemctl status httpd 2>/dev/null
   systemctl status nginx 2>/dev/null
   ```
2. 若服务处于运行状态,使用 `curl` 向本机发起一次 HTTP 请求:
   ```
   curl -I http://localhost
   ```
3. 查看本机正在监听的网络端口,确认 web 服务器占用的端口号:
   ```
   ss -tlnp
   ```
4. 检查是否安装了数据库服务器(MariaDB/MySQL 或 PostgreSQL):
   ```
   systemctl status mariadb 2>/dev/null || systemctl status mysqld 2>/dev/null
   systemctl status postgresql 2>/dev/null
   ```
5. 若已安装 MariaDB/MySQL,尝试以客户端身份登录并列出数据库:
   ```
   mysql -u root -p -e "SHOW DATABASES;"
   ```

**思考题**

- Q5: `Apache HTTP Server` 和 `NGINX` 都是 web 服务器,默认监听的 TCP 端口号是多少?
- Q6: 数据库服务器(如 MariaDB)和 web 服务器在职责上有什么本质区别?

---

## 练习 4：虚拟化与容器(Virtualization & Containers)

1. 检查 CPU 是否支持硬件虚拟化:
   ```
   egrep -c '(vmx|svm)' /proc/cpuinfo
   ```
   返回大于 0 表示支持 Intel VT-x 或 AMD-V。
2. 查看是否安装了容器运行时:
   ```
   docker --version
   ```
3. 运行一个测试容器:
   ```
   docker run --rm hello-world
   ```
4. 查看当前正在运行和曾经运行过的容器:
   ```
   docker ps -a
   ```
5. 查看本机已下载的容器镜像(image):
   ```
   docker images
   ```

**思考题**

- Q7: 传统虚拟机(virtual machine,如 KVM/VirtualBox)与容器(container,如 Docker)在资源隔离方式上有什么核心区别?
- Q8: `docker ps -a` 中的 `-a` 参数作用是什么?

---

## 练习 5：邮件客户端与字节码解释器(Bytecode Interpreters)

1. 检查系统中是否安装了桌面邮件客户端:
   ```
   which thunderbird evolution 2>/dev/null
   ```
2. 检查是否安装了 Java 运行环境,并查看版本:
   ```
   java -version
   ```
3. 检查是否安装了 Python 解释器:
   ```
   python3 --version
   ```
4. 编写一个简单脚本 `hello.py`:
   ```
   echo 'print("hello world")' > hello.py
   python3 hello.py
   ```
5. 生成该脚本对应的字节码(bytecode)文件并查看其存放位置:
   ```
   python3 -m py_compile hello.py
   find . -name "*.pyc"
   ```

**思考题**

- Q9: `Thunderbird` 和 `Evolution` 分别是哪个桌面环境常用的默认邮件客户端?
- Q10: 什么是 bytecode?为什么 Java 和 Python 都需要一个中间层(JVM / Python interpreter)来执行程序,而不是像 C 程序那样直接编译为机器码运行?

---

<details>
<summary><b>参考答案(点击展开)</b></summary>

**Q1:** `Writer` 对应 Microsoft Word(文字处理),`Calc` 对应 Microsoft Excel(电子表格),`Impress` 对应 Microsoft PowerPoint(演示文稿)。

**Q2:** Firefox 使用的渲染引擎是 `Gecko`,与 Chromium 使用的 `Blink` 引擎不是同一个项目;两者都是开源引擎,但由不同社区/公司(Mozilla vs. Google 主导的 Chromium 项目)独立维护。

**Q3:** `dpkg` 是底层包管理工具,直接安装、卸载、查询 `.deb` 包,但不会自动解析或下载依赖;`apt`(及 `apt-get`)是上层工具,基于 `dpkg`,能够连接软件仓库、自动解析并下载依赖关系。

**Q4:** `rpm` 对应的高级包管理器主要有 `yum`(较旧,常见于 CentOS/RHEL 7 及更早版本)和 `dnf`(`yum` 的继任者,用于 Fedora 及 RHEL 8+),另外 openSUSE 系使用 `zypper`。

**Q5:** Apache HTTP Server 和 NGINX 默认都监听 TCP 80 端口(HTTP);如果启用了 TLS/SSL,则使用 443 端口(HTTPS)。

**Q6:** Web 服务器负责接收 HTTP 请求并返回网页内容(静态文件或经应用层处理后的动态内容);数据库服务器负责持久化存储结构化数据,并通过查询语言(如 SQL)供应用程序读写,两者通常配合使用(web 应用从数据库中取数据后再通过 web 服务器返回给客户端)。

**Q7:** 虚拟机通过 hypervisor 虚拟出完整的硬件环境,每个虚拟机运行独立的操作系统内核,隔离性强但资源开销大;容器则共享宿主机的操作系统内核,仅隔离进程、文件系统和网络命名空间(namespace),因此更轻量、启动更快,但隔离性弱于虚拟机。

**Q8:** `-a`(`--all`)让 `docker ps` 显示所有容器,包括已经停止(exited)的容器,而不仅仅是当前正在运行的容器。

**Q9:** `Thunderbird` 是 Mozilla 项目的邮件客户端,常见于 GNOME 及多种发行版默认安装;`Evolution` 是 GNOME 桌面环境官方的默认邮件与个人信息管理(PIM)客户端。

**Q10:** Bytecode 是一种介于源代码和机器码之间的中间表示形式,不直接对应某一 CPU 架构的指令集。Java 源码编译为 `.class` 字节码后由 JVM(Java Virtual Machine)解释或即时编译(JIT)执行;Python 源码在运行时编译为 `.pyc` 字节码后由 Python interpreter 执行。这种中间层带来了跨平台可移植性(同一份字节码可在任何装有对应虚拟机/解释器的平台上运行),而 C 程序编译后生成的是特定 CPU 架构的机器码,不经过这层中间抽象。

</details>
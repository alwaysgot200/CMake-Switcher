cmake代理工具说明：
在windows上通过msys2+mingw64编译旧的c/c++开源项目时，如果能找到编译好的库固然能解决问题， 但现实情况是：找不到现成的库，得从代码编译，折腾人！
这时经常遇到引用或者关联的项目中cmake版本要求很低，而当前系统中的cmake版本过高，冒然全局降级cmake后果更严重， 于是有了这个小工具。

已经知道cmake典型版本兼容问题：
（1）cmake3.5以下的项目，只能用cmake3.5
  (2)  cmake3.18之前版本无法匹配openssl3.0及以上
（3）cmake4当前最新大版本，无法兼容cmake3.5

这个 PowerShell 脚本作为一个功能完备的 cmake.exe 代理，它不仅能根据项目需求选择正确的 CMake 版本，还要能完美地模拟真实 cmake.exe 的行为，包括参数传递、输出、错误和退出码。

原理： 根据cmakelist.txt中的要求的cmake的版本要求，进行切换
cmake<3.5， 用cmake3.5.2
3.5<=cmake<4.0 , 用cmake3.31.8
cmake>=4.0, 用cmake4.1.1


使用方法：
a.以管理员模式运行Powershell，以下命令安装 ps12exe 模块：
Install-Module ps12exe

右键菜单
Set-ps12exeContextMenu

b.使用以下命令将 make.ps1 编译为 make.exe：

ps12exe .\make.ps1 .\make.exe

c.将编译好的D:\programs\cmakeproxy\cmake.exe的路径放在windows环境变量PATH的最前边，
setx PATH=D:\programs\cmakeproxy;%PATH%
又将msys2中的~/.bashrc文件进行修改（在msys2的mingw64命令行中执行）
nano ~/.bashrc
export PATH=/D/programs/cmakeproxy:$PATH
这里的   /D/programs/cmakeproxy 换成你的cmake.exe所在路径，注意路径的写法
为防止万一， 也可以替换原版本的cmake.exe

d.验证：在msys2或者cmd终端， 输入cmake
结果输出：
C:\Users\HP\Desktop
λ cmake
[cmake-wrapper] No relevant args -> cmake-4.1.1
Usage

  cmake [options] <path-to-source>
  cmake [options] <path-to-existing-build>
  cmake [options] -S <path-to-source> -B <path-to-build>

Specify a source directory to (re-)generate a build system for it in the
current working directory.  Specify an existing build directory to
re-generate its build system.

Run 'cmake --help' for more information.

大功告成！

TODO: 可以将程序的下载做成自动化，在第一次执行时，即进行cmake的下载及解压。




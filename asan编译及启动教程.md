### 第一步：编译适配 (必须要做)
ASan 不是一个单独运行的程序，它是编译器（GCC/Clang）的一个功能。你必须在**编译阶段**通过添加参数将 ASan 注入到二进制文件中。

在你的 `Makefile` 或 `CMakeLists.txt` 中，确保添加以下参数：


```bash
# 核心编译选项
CXXFLAGS += -fsanitize=address -fno-omit-frame-pointer -g
LDFLAGS += -fsanitize=address

```

*   `-fsanitize=address`: 开启 ASan 检测引擎。
*   `-fno-omit-frame-pointer`: **非常重要**！它确保产生的堆栈回溯（Stack Trace）是完整的，没有这个参数，你的报错堆栈会缺失函数调用链。
*   `-g`: 生成调试符号，没有它，你只能看到地址，看不到对应的代码行号。

---

### 第二步：运行配置 (环境变量控制)
程序编译好后，你可以通过设置环境变量 `ASAN_OPTIONS` 来控制 ASan 的行为，无需改代码。

在启动你的服务器进程前，执行：


```bash
# 开启内存泄漏检测，并将错误日志输出到指定文件
export ASAN_OPTIONS=detect_leaks=1:log_path=asan_log:halt_on_error=1

```

*   `detect_leaks=1`: 显式开启内存泄漏检测（默认开启，但设为 1 更稳妥）。
*   `log_path=asan_log`: 报错时，ASan 会生成类似 `asan_log.12345` 的文件，避免刷屏终端。
*   `halt_on_error=1`: 检测到错误（泄漏、越界、非法访问）后立即终止程序。这对开发环境抓 Bug 非常好用，因为能立刻停在出错那一刻。

---

### 第三步：报告解读 (比 Valgrind 直观得多)
ASan 报错时，会直接在终端或日志里打印出一张“清晰的诊断表”，格式通常如下：


```text
==12345==ERROR: AddressSanitizer: heap-use-after-free on address 0x603000000010
READ of size 4 at 0x603000000010 thread T0
    #0 0x401234 in main main.cpp:10
    #1 0x7ffff7a0d... in __libc_start_main (/lib64/libc.so.6)

0x603000000010 is located 0 bytes inside of 10-byte region [0x603000000010,0x60300000001a)
freed by thread T0 here:
    #0 0x7ffff7... in operator delete(void*) ...
    #1 0x401200 in main main.cpp:9

```

*   **看错误类型**：`heap-use-after-free` (释放后使用)、`heap-buffer-overflow` (堆越界)、`leaked` (内存泄漏)。
*   **看行号**：直接定位到代码行（`main.cpp:10`），这一行就是报错现场。
*   **看申请与释放**：它会把这块内存“何时申请的”、“何时释放的”全给你列出来。

---

### 避坑与进阶技巧

#### 1. 如何处理“第三方库的噪音”？
ASan 可能会对一些老旧库或系统库报警告。你可以创建一个 `asan_suppress.txt` 文件：


```text
# 在文件中添加过滤规则
leak:libtcmalloc.so
interceptor_via_fun:malloc_hook

```

然后启动时设置：
`export ASAN_OPTIONS=suppressions=asan_suppress.txt`

#### 2. 与 Valgrind 的区别总结

| 特性 | Valgrind (Memcheck) | ASan (AddressSanitizer) |
| :--- | :--- | :--- |
| **性能** | 极慢 (甚至无法启动大项目) | 快 (接近原生速度) |
| **部署** | 运行期拦截，无需重编 | 编译期注入，必须重编 |
| **准确性** | 可能有漏报/误报 | 极高，逻辑错误必抓 |
| **适用场景** | 无法重编译的第三方程序 | 自己的开发代码 |


### 正确的配置步骤

你需要把那两行 `leak:...` 和 `interceptor_via_fun:...` 移到一个独立的文件中，步骤如下：

#### 第一步：创建抑制规则文件
创建一个文本文件，比如叫 `asan.supp`，把你想屏蔽的规则放进去：


```bash
# 文件名: asan.supp
# 忽略所有 libtcmalloc 相关的内存泄漏
leak:libtcmalloc.so
# 忽略 malloc_hook 相关的拦截器错误
interceptor_via_fun:malloc_hook

```

#### 第二步：设置环境变量
现在，通过 `suppressions` 这个参数，告诉 ASan 去读取这个文件。


```bash
# 假设你的 asan.supp 放在当前目录下
export ASAN_OPTIONS="detect_leaks=1:log_path=asan_log:halt_on_error=1:suppressions=./asan.supp"

#如果 /usr/local/lib64 能找到libasan.so文件，则配置一下路径
export LD_LIBRARY_PATH=/usr/local/lib64:$LD_LIBRARY_PATH
export LD_PRELOAD=/usr/local/lib64/libasan.so.6

```

### 为什么必须这样写？
*   **ASAN_OPTIONS**：只能解析 key=value 这种格式的配置项（如 `detect_leaks=1`）。
*   **suppressions**：是一个特殊的参数，它告诉 ASan 程序去哪里加载你的过滤规则。如果你直接把 `leak:libtcmalloc.so` 写在环境变量里，ASan 会因为无法解析这个未知参数而报错或者直接忽略。

### 给你一个“万能版”命令
为了防止路径问题导致读不到文件，建议使用**绝对路径**：


```bash
# 获取当前路径
export ASAN_PATH=$(pwd)
# 导出环境变量
export ASAN_OPTIONS="detect_leaks=1:log_path=$ASAN_PATH/asan_log:halt_on_error=1:suppressions=$ASAN_PATH/asan.supp"

```

### 要实时探测内存泄漏 调用 __lsan_do_leak_check()

1、可以先了解一下 __lsan_do_leak_check() 作用 
2、 // stdafx.h 会间接引入 platform-system.h，它把 __lsan_do_leak_check 定义成了空宏，
// 会破坏 <sanitizer/lsan_interface.h> 里的函数声明，这里先 undef 掉再重新引入。
#ifdef __lsan_do_leak_check
#undef __lsan_do_leak_check
#endif

// 检测 AddressSanitizer：Clang 用 __has_feature，GCC 用 __SANITIZE_ADDRESS__
#if defined(__has_feature)

#  if __has_feature(address_sanitizer)
#    define XMAN_ASAN_ENABLED 1
#  endif
#endif
#if defined(__SANITIZE_ADDRESS__)
#  define XMAN_ASAN_ENABLED 1
#endif

#ifdef XMAN_ASAN_ENABLED
#include <sanitizer/lsan_interface.h>

void TriggerLeakCheck()
{
	printf("--- TriggerLeakCheck Manual LSan Check Start ------------------------------------------\n");
	ErrorLn("--- TriggerLeakCheck Manual LSan Check Start ------------------------------------------\n");
	__lsan_do_leak_check();
	printf("--- TriggerLeakCheck Manual LSan Check End --------------------------------------------\n");
	ErrorLn("--- TriggerLeakCheck Manual LSan Check End --------------------------------------------\n");
}
#else
void TriggerLeakCheck()
{
	// 未启用 ASan，空实现
	ErrorLn("--- TriggerLeakCheck not asan --------------------------------------------\n");
}
#endif

int main()
{
	// 4月19号执行 LSan 内存泄漏检测
	{
		time_t tNow = gGlobalMicroServer->GetSystemAPI()->time(nullptr);
		struct tm* pLocal = localtime(&tNow);
		ErrorLn("CDayReset::DateCome k1--" << DMP_VAL(pLocal->tm_mon) << DMP_VAL(pLocal->tm_mday) << DMP_VAL(tNow));
		#ifdef XMAN_ASAN_ENABLED
		ErrorLn("CDayReset::DateCome asan--");
		#else
		ErrorLn("CDayReset::DateCome not asan--");
		#endif
		if (pLocal != NULL && pLocal->tm_mon == 3 && pLocal->tm_mday == 16)
		{
			TriggerLeakCheck();
		}
	}
	return 0;
}
// CMpv.h
// NeriPlayer macOS —— libmpv 的 SwiftPM 桥接头（移植规划 M1-T2）。
//
// 用途：让 Swift 侧用 `import CMpv` 直接调用 libmpv 的 C API（mpv/client.h），
//       而不必在 Swift 里重复声明几十个函数签名。
//
// 依赖：Vendor/mpv/include（由 Tools/fetch-mpv.sh 布置，产物不入库）。
//       首次构建前必须先执行 `Tools/fetch-mpv.sh`，否则下一行的 include 会失败。
//
// 边界：本模块只暴露头文件与两个版本自检函数，不含任何播放业务逻辑。
#ifndef NERIPLAYER_CMPV_H
#define NERIPLAYER_CMPV_H

#include <mpv/client.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 编译期头文件记录的 libmpv 客户端 API 版本（0x20005 即 2.5）。
int np_mpv_shim_header_api_version(void);

/// 运行期实际链接到的 libmpv 动态库报告的客户端 API 版本。
/// 与上一个函数不相等即说明头文件与 dylib 版本不匹配。
int np_mpv_shim_library_api_version(void);

#ifdef __cplusplus
}
#endif

#endif /* NERIPLAYER_CMPV_H */

// CMpv.c
// NeriPlayer macOS —— CMpv 桥接模块实现（移植规划 M1-T2）。
// 只提供两个版本自检函数，使 Swift 侧能验证「头文件版本 == 实际链接的 libmpv 版本」。
#include "CMpv.h"

int np_mpv_shim_header_api_version(void) {
    return (int)MPV_CLIENT_API_VERSION;
}

int np_mpv_shim_library_api_version(void) {
    return (int)mpv_client_api_version();
}

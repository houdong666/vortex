// ============================================================
// 文件名: my_sched_test.c
// 功能: 向量加法测试程序，用于触发Vortex硬件调度器
// ============================================================
#include <vortex.h>
#include <stdio.h>

// 定义向量大小（建议256，太小调度器切换次数少，太大仿真跑得慢）
#define N 256

// ------------------------------------------------------------
// GPGPU Kernel：运行在Vortex硬件上的并行函数
// __kernel 标记告诉编译器这是一个设备端函数
// get_global_id(0) 获取当前线程在X维度上的全局ID
// ------------------------------------------------------------
__kernel void vecadd(__global const int* a, __global const int* b, __global int* c) {
    // 获取当前线程的全局索引
    int gid = get_global_id(0);
    
    // 防止越界（当总线程数 > N 时，多余的线程不做事）
    if (gid < N) {
        c[gid] = a[gid] + b[gid];
    }
}

// ------------------------------------------------------------
// 主机端主函数：运行在RISC-V CPU上，负责启动GPGPU Kernel
// ------------------------------------------------------------
int main() {
    int err = 0;

    // 1. 分配主机端（CPU）内存（普通的栈数组）
    int host_a[N];
    int host_b[N];
    int host_c[N];

    // 2. 初始化数据
    for (int i = 0; i < N; i++) {
        host_a[i] = i;          // 0, 1, 2, 3, ...
        host_b[i] = i * 2;      // 0, 2, 4, 6, ...
    }

    // 3. 分配设备端（GPGPU）内存（使用 vortex_malloc）
    int* dev_a = (int*)vortex_malloc(N * sizeof(int));
    int* dev_b = (int*)vortex_malloc(N * sizeof(int));
    int* dev_c = (int*)vortex_malloc(N * sizeof(int));

    // 4. 将数据从CPU拷贝到GPGPU
    //    VORTEX_MEMCPY_HOST_TO_DEVICE 是Vortex定义的宏
    vortex_memcpy(dev_a, host_a, N * sizeof(int), VORTEX_MEMCPY_HOST_TO_DEVICE);
    vortex_memcpy(dev_b, host_b, N * sizeof(int), VORTEX_MEMCPY_HOST_TO_DEVICE);

    // 5. 设置线程块大小和网格大小
    int threads_per_block = 128;               // 每个Block包含128个线程
    int num_blocks = (N + threads_per_block - 1) / threads_per_block; // 计算需要多少个Block

    // 6. ★★★ 启动Kernel（这是触发硬件调度器的关键指令）★★★
    //    参数说明：函数指针, Grid维度(Block数), Block维度(线程数), 函数参数...
    vortex_launch_kernel((void*)vecadd, num_blocks, threads_per_block, dev_a, dev_b, dev_c);

    // 7. 将结果从GPGPU拷贝回CPU
    vortex_memcpy(host_c, dev_c, N * sizeof(int), VORTEX_MEMCPY_DEVICE_TO_HOST);

    // 8. 校验结果
    for (int i = 0; i < N; i++) {
        int expected = host_a[i] + host_b[i];
        if (host_c[i] != expected) {
            printf("错误: host_c[%d] = %d, 期望值 = %d\n", i, host_c[i], expected);
            err++;
        }
    }

    // 9. 打印最终结果
    if (err == 0) {
        printf("测试通过 (PASSED)\n");
    } else {
        printf("测试失败 (FAILED), 错误数 = %d\n", err);
    }

    // 10. 释放设备内存
    vortex_free(dev_a);
    vortex_free(dev_b);
    vortex_free(dev_c);

    return err;
}
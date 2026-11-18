/* =============================================================================
 * tools/ps/host/sim/sleep.h -- 模拟环境里 usleep/sleep 直接返回
 * ============================================================================= */
#ifndef SLEEP_H
#define SLEEP_H

#include "xil_types.h"

void usleep(unsigned long useconds);
void sleep(unsigned int seconds);

#endif /* SLEEP_H */

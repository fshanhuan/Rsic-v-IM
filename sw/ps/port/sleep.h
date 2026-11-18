/* =============================================================================
 * sw/ps/port/sleep.h -- usleep/sleep（纯忙等，不依赖任何定时器）
 * ============================================================================= */
#ifndef SLEEP_H
#define SLEEP_H

#include "xil_types.h"

void usleep(unsigned long useconds);
void sleep(unsigned int seconds);

#endif /* SLEEP_H */

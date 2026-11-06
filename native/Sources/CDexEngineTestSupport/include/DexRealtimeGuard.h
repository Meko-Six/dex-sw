#ifndef DEX_REALTIME_GUARD_H
#define DEX_REALTIME_GUARD_H
// Test support only, never linked into the app. Counts memory calls made on one thread between
// enter and leave, through the logger hook the system allocator calls on every allocation and free.
#include <stdint.h>
void dex_guard_install(void);
void dex_guard_remove(void);
void dex_guard_enter(void);
void dex_guard_leave(void);
uint64_t dex_guard_count(void);
/// Allocates inside the guard, so a test can show the guard really sees it.
void dex_guard_allocate_something(void);
#endif

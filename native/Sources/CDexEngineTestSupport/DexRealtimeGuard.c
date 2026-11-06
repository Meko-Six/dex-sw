#include "DexRealtimeGuard.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>

typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t skip);
extern malloc_logger_t *malloc_logger;

static _Atomic(uint64_t) calls;
static _Atomic(pthread_t) watched;

static void logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t skip) {
    (void)type; (void)arg1; (void)arg2; (void)arg3; (void)result; (void)skip;
    pthread_t thread = atomic_load_explicit(&watched, memory_order_relaxed);
    if (thread && pthread_equal(thread, pthread_self())) atomic_fetch_add_explicit(&calls, 1, memory_order_relaxed);
}

void dex_guard_install(void) { malloc_logger = logger; }
void dex_guard_remove(void) { malloc_logger = NULL; }
void dex_guard_enter(void) { atomic_store(&watched, pthread_self()); }
void dex_guard_leave(void) { atomic_store(&watched, (pthread_t)NULL); }
uint64_t dex_guard_count(void) { return atomic_load(&calls); }

void dex_guard_allocate_something(void) {
    volatile char *p = malloc(64);
    if (p) p[0] = 1;
    free((void *)p);
}

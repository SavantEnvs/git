/* LeakSanitizer off by default (leaks are not the bug class fuzzed here); ASan/UBSan stay active. */
int __lsan_is_turned_off(void) { return 1; }

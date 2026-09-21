/* Weak definitions must not slip through the export audit. */
__attribute__((weak)) int unexpected_global = 1;

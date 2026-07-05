#include "qbits.h"
#include <stdio.h>
int main(void){ int ok=qbits_selftest(); printf("qbits roundtrip (Rice+escape): %s\n", ok?"PASS":"FAIL"); return ok?0:1; }

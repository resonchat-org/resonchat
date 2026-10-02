// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// C ABI bridge between Dart and liboqs for ML-KEM-768.
//
// Dart allocates every buffer, so nothing here owns memory except the
// temporary stack/heap objects liboqs needs internally. Only the
// operations PQ-OMEMO uses are exposed.

#include <oqs/oqs.h>
#include <stdint.h>
#include <stdlib.h>

// The library is built with -fvisibility=hidden, so the Dart FFI symbols
// must be exported explicitly. Without this the .so loads but every
// lookupFunction fails with "undefined symbol".
#if defined(_WIN32)
#define PQ_EXPORT __declspec(dllexport)
#else
#define PQ_EXPORT __attribute__((visibility("default")))
#endif

// FIPS 203 sizes for ML-KEM-768. Keep in sync with MlKem768 in Dart.
#define PQ_PK_BYTES 1184
#define PQ_SK_BYTES 2400
#define PQ_CT_BYTES 1088
#define PQ_SS_BYTES 32

// Single shared instance: OQS_KEM_new allocates crypto state, and creating
// one per call was making decapsulation fail (rc -2) even though keygen and
// encaps worked. The instance is intentionally never freed — it lives for
// the process lifetime.
static OQS_KEM *pq_kem(void) {
    static OQS_KEM *cached = NULL;
    if (cached == NULL) {
        cached = OQS_KEM_new("ML-KEM-768");
    }
    return cached;
}

PQ_EXPORT int pq_mlkem768_keypair(uint8_t *pk, uint8_t *sk) {
    OQS_KEM *kem = pq_kem();
    if (kem == NULL) {
        return -1;
    }
    int rc = OQS_KEM_keypair(kem, pk, sk);
    return rc == OQS_SUCCESS ? 0 : -2;
}

PQ_EXPORT int pq_mlkem768_encaps(const uint8_t *pk, uint8_t *ct, uint8_t *ss) {
    OQS_KEM *kem = pq_kem();
    if (kem == NULL) {
        return -1;
    }
    int rc = OQS_KEM_encaps(kem, ct, ss, pk);
    return rc == OQS_SUCCESS ? 0 : -2;
}

PQ_EXPORT int pq_mlkem768_decaps(const uint8_t *sk, const uint8_t *ct, uint8_t *ss) {
    OQS_KEM *kem = pq_kem();
    if (kem == NULL) {
        return -1;
    }
    // ML-KEM uses implicit rejection: a bad ciphertext yields a
    // pseudo-random shared secret rather than an error. Callers must not
    // treat a zero return code as proof of authenticity.
    int rc = OQS_KEM_decaps(kem, ss, ct, sk);
    return rc == OQS_SUCCESS ? 0 : -2;
}

// Reports whether the linked liboqs actually provides ML-KEM-768, so the
// Dart side can fall back instead of crashing on a stripped build.
PQ_EXPORT int pq_mlkem768_available(void) {
    return pq_kem() != NULL ? 1 : 0;
}
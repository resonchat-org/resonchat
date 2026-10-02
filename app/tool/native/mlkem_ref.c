// Copyright (C) 2026 resonchat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reference vectors for the liboqs ML-KEM-768 backend.
//
// Built by tool/build_liboqs.sh. Prints deterministic KAT values derived
// from a fixed seed so the pure-Dart backend can be checked against the C
// implementation byte-for-byte (ADR-006, docs/04 §3).
//
// Output format (one value per line):
//   pk=<hex>
//   sk=<hex>
//   ct=<hex>
//   ss=<hex>

#include <oqs/oqs.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void print_hex(const char *label, const uint8_t *buf, size_t len) {
    printf("%s=", label);
    for (size_t i = 0; i < len; i++) {
        printf("%02x", buf[i]);
    }
    printf("\n");
}

int main(void) {
    OQS_KEM *kem = OQS_KEM_new("ML-KEM-768");
    if (kem == NULL) {
        fprintf(stderr, "ML-KEM-768 unavailable\n");
        return 1;
    }

    // Fixed seeds: any two FIPS 203 implementations must produce the same
    // keys and shared secret from these.
    uint8_t kseed[64];
    uint8_t eseed[32];
    for (int i = 0; i < 64; i++) {
        kseed[i] = (uint8_t)i;
    }
    for (int i = 0; i < 32; i++) {
        eseed[i] = (uint8_t)(0xFF - i);
    }

    uint8_t *pk = malloc(kem->length_public_key);
    uint8_t *sk = malloc(kem->length_secret_key);
    uint8_t *ct = malloc(kem->length_ciphertext);
    uint8_t *ss = malloc(kem->length_shared_secret);
    uint8_t *ss2 = malloc(kem->length_shared_secret);

    if (OQS_KEM_keypair_derand(kem, pk, sk, kseed) != OQS_SUCCESS) {
        return 2;
    }
    if (OQS_KEM_encaps_derand(kem, ct, ss, pk, eseed) != OQS_SUCCESS) {
        return 3;
    }
    if (OQS_KEM_decaps(kem, ss2, ct, sk) != OQS_SUCCESS) {
        return 4;
    }

    print_hex("pk", pk, kem->length_public_key);
    print_hex("sk", sk, kem->length_secret_key);
    print_hex("ct", ct, kem->length_ciphertext);
    print_hex("ss", ss, kem->length_shared_secret);
    printf("roundtrip=%d\n", memcmp(ss, ss2, kem->length_shared_secret) == 0);

    OQS_KEM_free(kem);
    free(pk);
    free(sk);
    free(ct);
    free(ss);
    free(ss2);
    return 0;
}
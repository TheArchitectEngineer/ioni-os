#include <stdint.h>
#include <string.h>
#include <corecrypto/ccdigest.h>
#include <corecrypto/ccdigest_priv.h>
#include <corecrypto/ccsha1.h>
#include <corecrypto/ccsha2.h>

extern const struct ccdigest_info ccsha256_ltc_di;
extern const struct ccdigest_info ccsha512_ltc_di;
extern void ccsha512_ltc_compress(ccdigest_state_t state, size_t nblocks, const void *in);
extern void ccdigest_final_64be(const struct ccdigest_info *di, ccdigest_ctx_t ctx,
    unsigned char *digest);

#define IONI_SHA1_BLOCK_SIZE 64
#define IONI_SHA1_OUTPUT_SIZE 20
#define IONI_SHA1_STATE_SIZE 20
#define IONI_SHA384_STATE_SIZE 64
#define IONI_SHA384_BLOCK_SIZE 128

static const uint32_t ioni_sha1_initial_state[5] = {
        0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
};

static const uint64_t ioni_sha384_initial_state[8] = {
        0xcbbb9d5dc1059ed8ULL, 0x629a292a367cd507ULL,
        0x9159015a3070dd17ULL, 0x152fecd8f70e5939ULL,
        0x67332667ffc00b31ULL, 0x8eb44a8768581511ULL,
        0xdb0c2e0d64f98fa7ULL, 0x47b5481dbefa4fa4ULL
};

static uint32_t
ioni_rol32(uint32_t v, unsigned n)
{
        return (v << n) | (v >> (32 - n));
}

static void
ioni_sha1_compress(ccdigest_state_t state, size_t nblocks, const void *in)
{
        uint32_t *h = ccdigest_u32(state);
        const uint8_t *p = in;

        while (nblocks--) {
                uint32_t w[80];
                uint32_t a, b, c, d, e, t;

                for (int i = 0; i < 16; i++) {
                        w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) |
                            ((uint32_t)p[i * 4 + 2] << 8) | (uint32_t)p[i * 4 + 3];
                }
                for (int i = 16; i < 80; i++) {
                        w[i] = ioni_rol32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
                }
                a = h[0];
                b = h[1];
                c = h[2];
                d = h[3];
                e = h[4];
                for (int i = 0; i < 80; i++) {
                        uint32_t f, k;

                        if (i < 20) {
                                f = (b & c) | ((~b) & d);
                                k = 0x5a827999;
                        } else if (i < 40) {
                                f = b ^ c ^ d;
                                k = 0x6ed9eba1;
                        } else if (i < 60) {
                                f = (b & c) | (b & d) | (c & d);
                                k = 0x8f1bbcdc;
                        } else {
                                f = b ^ c ^ d;
                                k = 0xca62c1d6;
                        }
                        t = ioni_rol32(a, 5) + f + e + k + w[i];
                        e = d;
                        d = c;
                        c = ioni_rol32(b, 30);
                        b = a;
                        a = t;
                }
                h[0] += a;
                h[1] += b;
                h[2] += c;
                h[3] += d;
                h[4] += e;
                p += IONI_SHA1_BLOCK_SIZE;
        }
}

const struct ccdigest_info ioni_sha1_ltc_di = {
        .output_size = IONI_SHA1_OUTPUT_SIZE,
        .state_size = IONI_SHA1_STATE_SIZE,
        .block_size = IONI_SHA1_BLOCK_SIZE,
        .oid_size = ccoid_sha1_len,
        .oid = CC_DIGEST_OID_SHA1,
        .initial_state = ioni_sha1_initial_state,
        .compress = ioni_sha1_compress,
        .final = ccdigest_final_64be,
        .impl = CC_IMPL_SHA1_LTC,
};

const struct ccdigest_info ioni_sha384_ltc_di = {
        .output_size = CCSHA384_OUTPUT_SIZE,
        .state_size = IONI_SHA384_STATE_SIZE,
        .block_size = IONI_SHA384_BLOCK_SIZE,
        .oid_size = ccoid_sha384_len,
        .oid = CC_DIGEST_OID_SHA384,
        .initial_state = ioni_sha384_initial_state,
        .compress = ccsha512_ltc_compress,
        .final = ccdigest_final_64be,
        .impl = CC_IMPL_SHA384_LTC,
};

const struct ccdigest_info *
ccsha1_di(void)
{
        return &ioni_sha1_ltc_di;
}

const struct ccdigest_info *
ccsha384_di(void)
{
        return &ioni_sha384_ltc_di;
}

const struct ccdigest_info *
ccsha256_di(void)
{
        return &ccsha256_ltc_di;
}

const struct ccdigest_info *
ccsha512_di(void)
{
        return &ccsha512_ltc_di;
}

void
ccdigest(const struct ccdigest_info *di, size_t len, const void *data, void *digest)
{
        ccdigest_di_decl(di, ctx);

        ccdigest_init(di, ctx);
        ccdigest_update(di, ctx, len, data);
        ccdigest_final(di, ctx, digest);
        ccdigest_di_clear(di, ctx);
}

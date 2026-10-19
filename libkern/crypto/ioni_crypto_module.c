#include <libkern/libkern.h>
#include <libkern/crypto/register_crypto.h>
#include <libkern/section_keywords.h>
#include <kern/startup.h>
#include <machine/machine_routines.h>
#include <prng/random.h>
#include <sys/random.h>
#include <corecrypto/ccdrbg.h>
#include <corecrypto/ccdigest.h>
#include <corecrypto/cchmac.h>
#include <corecrypto/ccsha2.h>


extern const struct ccdigest_info ccsha256_ltc_di;
extern uint64_t early_random(void);
extern const struct ccdigest_info ccsha512_ltc_di;

#define IONI_DRBG_MAX_STATE 512

static struct {
	struct ccdrbg_info info;
	bool ready;
} ioni_krng;

static const struct ccdrbg_nisthmac_custom ioni_krng_custom = {
	.di = &ccsha256_ltc_di,
	.strictFIPS = 0,
};

static const struct ccdigest_info *
ioni_digest_info(unsigned int alg)
{
	switch (alg) {
	case CRYPTO_DIGEST_ALG_SHA256:
		return &ccsha256_ltc_di;
	case CRYPTO_DIGEST_ALG_SHA512:
		return &ccsha512_ltc_di;
	default:
		panic("ioni_crypto: unsupported digest alg %u", alg);
	}
}

static size_t
ioni_digest_ctx_size(crypto_digest_alg_t alg)
{
	return ccdigest_di_size(ioni_digest_info(alg));
}

static void
ioni_digest_init(crypto_digest_alg_t alg, void *ctx, size_t ctx_size)
{
	ccdigest_init(ioni_digest_info(alg), ctx);
}

static void
ioni_digest_update(crypto_digest_alg_t alg, void *ctx, size_t ctx_size,
    const void *data, size_t data_size)
{
	ccdigest_update(ioni_digest_info(alg), ctx, data_size, data);
}

static void
ioni_digest_final(crypto_digest_alg_t alg, void *ctx, size_t ctx_size,
    void *digest, size_t digest_size)
{
	const struct ccdigest_info *di = ioni_digest_info(alg);

	if (__improbable(digest_size < di->output_size ||
	    ctx_size < ccdigest_di_size(di))) {
		panic("ioni_crypto: digest final buffer too small alg %u", alg);
	}
	ccdigest_final(di, ctx, digest);
}

static void
ioni_ccdigest(const struct ccdigest_info *di, unsigned long len,
    const void *data, void *digest)
{
	ccdigest_di_decl(di, ctx);

	ccdigest_init(di, ctx);
	ccdigest_update(di, ctx, len, data);
	ccdigest_final(di, ctx, digest);
	ccdigest_di_clear(di, ctx);
}

static void
ioni_digest(crypto_digest_alg_t alg, const void *data, size_t data_size,
    void *digest, size_t digest_size)
{
	const struct ccdigest_info *di = ioni_digest_info(alg);

	if (__improbable(digest_size < di->output_size)) {
		panic("ioni_crypto: digest buffer too small alg %u", alg);
	}
	ioni_ccdigest(di, data_size, data, digest);
}

static size_t
ioni_hmac_ctx_size(crypto_digest_alg_t alg)
{
	return cchmac_di_size(ioni_digest_info(alg));
}

static void
ioni_hmac_init(crypto_digest_alg_t alg, void *ctx, size_t ctx_size,
    const void *key, size_t key_size)
{
	cchmac_init(ioni_digest_info(alg), ctx, key_size, key);
}

static void
ioni_hmac_update(crypto_digest_alg_t alg, void *ctx, size_t ctx_size,
    const void *data, size_t data_size)
{
	cchmac_update(ioni_digest_info(alg), ctx, data_size, data);
}

static void
ioni_hmac_final_generate(crypto_digest_alg_t alg, void *ctx, size_t ctx_size,
    void *tag, size_t tag_size)
{
	cchmac_final(ioni_digest_info(alg), ctx, tag);
}

static bool
ioni_hmac_final_verify(crypto_digest_alg_t alg, void *ctx, size_t ctx_size,
    const void *tag, size_t tag_size)
{
	uint8_t computed[CCSHA512_OUTPUT_SIZE];
	uint8_t delta = 0;

	cchmac_final(ioni_digest_info(alg), ctx, computed);
	for (size_t i = 0; i < tag_size; i++) {
		delta |= computed[i] ^ ((const uint8_t *)tag)[i];
	}
	cc_clear(sizeof(computed), computed);
	return delta == 0;
}

static void
ioni_hmac_generate(crypto_digest_alg_t alg, const void *key, size_t key_size,
    const void *data, size_t data_size, void *tag, size_t tag_size)
{
	cchmac(ioni_digest_info(alg), key_size, key, data_size, data, tag);
}

static bool
ioni_hmac_verify(crypto_digest_alg_t alg, const void *key, size_t key_size,
    const void *data, size_t data_size, const void *tag, size_t tag_size)
{
	uint8_t computed[CCSHA512_OUTPUT_SIZE];
	uint8_t delta = 0;

	cchmac(ioni_digest_info(alg), key_size, key, data_size, data, computed);
	for (size_t i = 0; i < tag_size; i++) {
		delta |= computed[i] ^ ((const uint8_t *)tag)[i];
	}
	cc_clear(sizeof(computed), computed);
	return delta == 0;
}

static struct ccrng_state *
ioni_ccrng(int *error)
{
	*error = -1;
	return NULL;
}

static void
ioni_krng_ready(void)
{
	if (ioni_krng.ready) {
		return;
	}
	ccdrbg_factory_nisthmac(&ioni_krng.info, &ioni_krng_custom);
	if (ioni_krng.info.size > IONI_DRBG_MAX_STATE) {
		panic("ioni_crypto: drbg state %zu too large", ioni_krng.info.size);
	}
	ioni_krng.ready = true;
}

static size_t
ioni_random_kmem_ctx_size(void)
{
	ioni_krng_ready();
	return ioni_krng.info.size;
}

static void
ioni_random_kmem_init(crypto_random_ctx_t ctx)
{
	uint8_t seed[32];
	uint64_t nonce;
	int rc;
	const char ps[] = "ioni kmem random";

	(void)early_random();
	read_random(seed, sizeof(seed));
	nonce = ml_get_timebase();
	rc = ccdrbg_init(&ioni_krng.info, (struct ccdrbg_state *)ctx,
	    sizeof(seed), seed, sizeof(nonce), &nonce, sizeof(ps) - 1, ps);
	if (rc != CCDRBG_STATUS_OK) {
		panic("ioni_crypto: ccdrbg_init returned %d", rc);
	}
	cc_clear(sizeof(seed), seed);
}

static void
ioni_random_generate(crypto_random_ctx_t ctx, void *buf, size_t len)
{
	int rc = ccdrbg_generate(&ioni_krng.info, (struct ccdrbg_state *)ctx,
	    len, buf, 0, NULL);
	if (rc != CCDRBG_STATUS_OK) {
		panic("ioni_crypto: ccdrbg_generate returned %d", rc);
	}
}

static void
ioni_random_uniform(crypto_random_ctx_t ctx, uint64_t bound, uint64_t *random)
{
	uint64_t value;

	ioni_random_generate(ctx, &value, sizeof(value));
	*random = bound == 0 ? 0 : value % bound;
}

static void
ioni_ccdigest_final(const struct ccdigest_info *di, ccdigest_ctx_t ctx, void *digest)
{
	ccdigest_final(di, ctx, digest);
}

static struct crypto_functions ioni_crypto_funcs = {
	.ccdigest_init_fn = ccdigest_init,
	.ccdigest_update_fn = ccdigest_update,
	.ccdigest_final_fn = ioni_ccdigest_final,
	.ccdigest_fn = ioni_ccdigest,
	.ccsha256_di = &ccsha256_ltc_di,
	.ccsha512_di = &ccsha512_ltc_di,
	.cchmac_init_fn = cchmac_init,
	.cchmac_update_fn = cchmac_update,
	.cchmac_final_fn = cchmac_final,
	.cchmac_fn = cchmac,
	.ccrng_fn = ioni_ccrng,
	.random_generate_fn = ioni_random_generate,
	.random_uniform_fn = ioni_random_uniform,
	.random_kmem_ctx_size_fn = ioni_random_kmem_ctx_size,
	.random_kmem_init_fn = ioni_random_kmem_init,
	.digest_ctx_size_fn = ioni_digest_ctx_size,
	.digest_init_fn = ioni_digest_init,
	.digest_update_fn = ioni_digest_update,
	.digest_final_fn = ioni_digest_final,
	.digest_fn = ioni_digest,
	.hmac_ctx_size_fn = ioni_hmac_ctx_size,
	.hmac_init_fn = ioni_hmac_init,
	.hmac_update_fn = ioni_hmac_update,
	.hmac_final_generate_fn = ioni_hmac_final_generate,
	.hmac_final_verify_fn = ioni_hmac_final_verify,
	.hmac_generate_fn = ioni_hmac_generate,
	.hmac_verify_fn = ioni_hmac_verify,
};

__startup_func
static void
ioni_crypto_register(void)
{
	register_crypto_functions(&ioni_crypto_funcs);
}
STARTUP(EARLY_BOOT, STARTUP_RANK_FIRST, ioni_crypto_register);

/*
 * C helper to initialize aws_signing_config_aws for general (non-S3) signing.
 *
 * We use a C function because the signing config struct contains
 * platform-dependent types (struct tm inside aws_date_time) whose layout
 * varies across platforms. Writing this in C lets the compiler handle the
 * layout correctly.
 */

#include <string.h>
#include <stddef.h>
#include <stdint.h>

#include <aws/auth/signing_config.h>
#include <aws/common/date_time.h>

/*
 * Initialize a signing config for general SigV4 signing.
 *
 * Parameters:
 *   config_buf - pointer to a buffer of at least aws_crt_signing_config_size() bytes
 *   region/region_len - region string
 *   service/service_len - service name string
 *   credentials_provider - CRT credentials provider
 *   use_double_uri_encode - whether to double-encode URI
 *   should_normalize_uri_path - whether to normalize URI path
 *   signed_body_header - 0 = none, 1 = x-amz-content-sha256
 *   signed_body_value/signed_body_value_len - body hash value (NULL for compute-from-body)
 */
void aws_crt_init_signing_config(
    void *config_buf,
    const uint8_t *region, size_t region_len,
    const uint8_t *service, size_t service_len,
    struct aws_credentials_provider *credentials_provider,
    int use_double_uri_encode,
    int should_normalize_uri_path,
    int signed_body_header,
    const uint8_t *signed_body_value, size_t signed_body_value_len
) {
    struct aws_signing_config_aws *config = (struct aws_signing_config_aws *)config_buf;

    /* Zero-initialize the entire struct */
    memset(config, 0, sizeof(struct aws_signing_config_aws));

    config->config_type = AWS_SIGNING_CONFIG_AWS;
    config->algorithm = AWS_SIGNING_ALGORITHM_V4;
    config->signature_type = AWS_ST_HTTP_REQUEST_HEADERS;

    config->region.ptr = (uint8_t *)region;
    config->region.len = region_len;

    config->service.ptr = (uint8_t *)service;
    config->service.len = service_len;

    /* Initialize date to current time */
    aws_date_time_init_now(&config->date);

    config->flags.use_double_uri_encode = use_double_uri_encode ? 1 : 0;
    config->flags.should_normalize_uri_path = should_normalize_uri_path ? 1 : 0;

    config->signed_body_header = (enum aws_signed_body_header_type)signed_body_header;

    if (signed_body_value != NULL && signed_body_value_len > 0) {
        config->signed_body_value.ptr = (uint8_t *)signed_body_value;
        config->signed_body_value.len = signed_body_value_len;
    }

    config->credentials_provider = credentials_provider;
}

/* Return the size of aws_signing_config_aws so Rust can allocate the right buffer */
size_t aws_crt_signing_config_size(void) {
    return sizeof(struct aws_signing_config_aws);
}

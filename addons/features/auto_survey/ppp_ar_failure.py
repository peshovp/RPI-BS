"""PPP-AR failure classification.

Classifies PPP-AR failures into an error class and a one-sentence reason
shown to the operator (status page, audit/attempt records). No retry
limits are defined here; the final result is retried until it succeeds.
"""

# Stage constants
STAGE_PDP3_UNAVAILABLE = 'pdp3_unavailable'
STAGE_NO_RAW_DATA = 'no_raw_data'
STAGE_RINEX_CONVERSION_FAILED = 'rinex_conversion_failed'
STAGE_PDP3_FAILED = 'pdp3_failed'
STAGE_PARSE_FAILED = 'parse_failed'
STAGE_FIX_RATE_BELOW_THRESHOLD = 'fix_rate_below_threshold'
STAGE_APPLY_FAILED = 'apply_failed'

# Failure kind constants (for pdp3_failed)
KIND_TIMEOUT = 'timeout'
KIND_PRODUCT_DOWNLOAD = 'product_download'
KIND_NONZERO_EXIT = 'nonzero_exit'
KIND_NO_POS_FILE = 'no_pos_file'
KIND_EXCEPTION = 'exception'

# Failure table: (stage, kind) -> (error_class, reason)
_FAILURE_TABLE = {
    (STAGE_PDP3_UNAVAILABLE, None): ('tool_missing', 'PRIDE-PPPAR (pdp3) is not installed or not found'),
    (STAGE_NO_RAW_DATA, None): ('no_data', 'no raw GNSS data found for the survey window'),
    (STAGE_RINEX_CONVERSION_FAILED, None): ('conversion', 'RINEX conversion of the raw log failed'),
    (STAGE_PARSE_FAILED, None): ('parse', 'pdp3 finished but its result could not be parsed'),
    (STAGE_PDP3_FAILED, KIND_TIMEOUT): ('pdp3_timeout', 'pdp3 exceeded its 40 minute time limit'),
    (STAGE_PDP3_FAILED, KIND_PRODUCT_DOWNLOAD): ('product', 'precise products could not be downloaded (network or mirror problem)'),
    (STAGE_PDP3_FAILED, KIND_NONZERO_EXIT): ('pdp3_error', 'pdp3 exited with an error'),
    (STAGE_PDP3_FAILED, KIND_NO_POS_FILE): ('pdp3_error', 'pdp3 finished without producing a position file'),
    (STAGE_PDP3_FAILED, KIND_EXCEPTION): ('pdp3_error', 'pdp3 could not be run (exception)'),
    (STAGE_FIX_RATE_BELOW_THRESHOLD, None): ('fix_rate', 'ambiguity fix rate below the acceptance threshold'),
    (STAGE_APPLY_FAILED, None): ('apply', 'the computed position could not be applied (geoid, BGS2005 or broadcast step)'),
}

_DEFAULT_PDP3_FAILED = ('pdp3_error', 'pdp3 failed (cause not classified)')
_DEFAULT_UNKNOWN = ('unknown', 'PPP-AR run failed (stage unknown)')


def describe_failure(stage, failure_kind=None):
    """Classify a PPP-AR failure.

    Args:
        stage: The failure stage (one of the STAGE_* constants).
        failure_kind: For pdp3_failed, the specific kind (one of the KIND_* constants).

    Returns:
        dict with keys 'error_class' and 'reason'.
    """
    key = (stage, failure_kind)
    if key in _FAILURE_TABLE:
        error_class, reason = _FAILURE_TABLE[key]
    elif stage == STAGE_PDP3_FAILED:
        error_class, reason = _DEFAULT_PDP3_FAILED
    else:
        error_class, reason = _DEFAULT_UNKNOWN

    return {
        'error_class': error_class,
        'reason': reason,
    }

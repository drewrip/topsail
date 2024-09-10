import logging

import projects.matrix_benchmarking.visualizations.helpers.analyze as helpers_analyze

from ..store import _rewrite_settings

# the setting (kpi labels) keys against which the historical regression should be performed
COMPARISON_KEYS = ["container_image"]

# the setting (kpi labels) keys that should be ignored when searching for historical results
IGNORED_KEYS = ["rhoai_version", "ocp_version"]

# the setting (kpi labels) keys *prefered* for sorting the entries in the regression report
SORTING_KEYS = ["model_name", "batch_size", "max_seq_length"]

IGNORED_ENTRIES = {}

def prepare():
    return helpers_analyze.prepare_regression_data(
        COMPARISON_KEYS, IGNORED_KEYS, _rewrite_settings,
        sorting_keys=SORTING_KEYS,
        ignored_entries=IGNORED_ENTRIES
    )

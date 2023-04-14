#! /bin/bash

set -o errexit
set -o pipefail
set -o nounset
set -x

TESTING_NOTEBOOKS_DIR="$(cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd)"
TESTING_UTILS_DIR="$TESTING_NOTEBOOKS_DIR/../utils"

source "$TESTING_NOTEBOOKS_DIR/configure.sh"
source "$TESTING_UTILS_DIR/logging.sh"

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/ci-artifacts_$(date +%Y%m%d)}

export MATBENCH_SIMPLE_STORE_IGNORE_EXIT_CODE=$(get_config matbench.ignore_exit_code)

export MATBENCH_WORKLOAD=$(get_config matbench.workload)
WORKLOAD_STORAGE_DIR="$TESTING_NOTEBOOKS_DIR/../../subprojects/matrix-benchmarking-workloads/$MATBENCH_WORKLOAD"

if [[ "$(get_config PR_POSITIONAL_ARG_0)" == ods-plot-* ]]; then
    set_config_from_pr_arg 1 "matbench.preset"
fi

matbench_preset=$(get_config matbench.preset)

if [[ "$matbench_preset" == null ]]; then
    # no preset defined
    true

elif [[ "$matbench_preset" == "https://"* ]]; then
    set_config matbench.download.url "$matbench_preset"
else
    set_config matbench.config_file "${matbench_preset}.yaml"
    set_config matbench.download.url_file "${WORKLOAD_STORAGE_DIR}/data/${matbench_preset}.yaml"
fi

get_matbench_config() {
    CI_ARTIFACTS_FROM_CONFIG_FILE=$TESTING_NOTEBOOKS_DIR/../../subprojects/matrix-benchmarking-workloads/rhods-notebooks-ux/data/$(get_config matbench.config_file) \
        get_config "$@"
}


generate_matbench::prepare_matrix_benchmarking() {
    WORKLOAD_RUN_DIR="$TESTING_NOTEBOOKS_DIR/../../subprojects/matrix-benchmarking/workloads/$MATBENCH_WORKLOAD"

    rm -f "$WORKLOAD_RUN_DIR"
    ln -s "$WORKLOAD_STORAGE_DIR" "$WORKLOAD_RUN_DIR"

    pip install --quiet --requirement "$TESTING_NOTEBOOKS_DIR/../../subprojects/matrix-benchmarking/requirements.txt"
    pip install --quiet --requirement "$WORKLOAD_STORAGE_DIR/requirements.txt"
}

_get_data_from_pr() {
    if [[ -z "$MATBENCH_RESULTS_DIRNAME" ]]; then
        echo "ERROR: _get_data_from_pr expects MATBENCH_RESULTS_DIRNAME to be set ..."
    fi

    MATBENCH_URL=$(get_config matbench.download.url)
    MATBENCH_URL_FILE=$(get_config matbench.download.url_file)

    if [[ "$MATBENCH_URL" != null ]]; then
        export MATBENCH_URL

        echo "$MATBENCH_URL" > "$ARTIFACT_DIR/source_url"
    elif [[ "$MATBENCH_URL_FILE" != null ]]; then
        export MATBENCH_URL_FILE

        cp "$MATBENCH_URL_FILE" "$ARTIFACT_DIR/source_url"
    else
        _error "matbench.download.url or matbench.download.url_file must be specified"
    fi
    export MATBENCH_MODE=$(get_config matbench.download.mode)

    matbench download --do-download |& tee > "$ARTIFACT_DIR/_matbench_download.log"
}

generate_matbench::get_prometheus() {
    export PATH=$PATH:/tmp/bin
    if which prometheus 2>/dev/null; then
       echo "Prometheus already available."
       return
    fi
    PROMETHEUS_VERSION=2.36.0
    cd /tmp
    wget --quiet "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" -O/tmp/prometheus.tar.gz
    tar xf "/tmp/prometheus.tar.gz" -C /tmp
    mkdir -p /tmp/bin
    ln -sf "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" /tmp/bin
    cp "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus.yml" /tmp/
}


generate_matbench::generate_visualizations() {
    if [[ -z "${MATBENCH_RESULTS_DIRNAME:-}" ]]; then
        echo "ERROR: expected MATBENCH_RESULTS_DIRNAME to be set ..."
    fi

    length=$(get_matbench_config visualize | jq '. | length')
    plotting_failed=0
    for idx in $(seq 0 $((length - 1))); do
        if ! generate_matbench::generate_visualization "$idx"; then
            plotting_failed=1 # do not fail before the end of the visualization generation
        fi
    done

    return $plotting_failed
}


generate_matbench::generate_visualization() {
    local idx=$1

    if [[ "$(get_matbench_config visualize[$idx].generate)" == null ]]; then
        _warning "Could not find the list of plots to generate in $MATBENCH_RESULTS_DIRNAME visualization #$idx ..."
        return
    fi

    generate_list=$(get_matbench_config visualize[$idx].generate[])

    filters=$(get_matbench_config visualize[$idx].filters)
    if [[ "$filters" != null ]]; then
        filters="$(get_matbench_config visualize[$idx].filters[])"
    else
        filters="null"
    fi

    export MATBENCH_RHODS_NOTEBOOKS_UX_CONFIG=$(get_config matbench.config_file)
    export MATBENCH_RHODS_NOTEBOOKS_UX_CONFIG_ID=$(get_matbench_config visualize[$idx].id)

    generate_url="stats=$(echo -n "$generate_list" | tr '\n' '&' | sed 's/&/&stats=/g')"

    cp -f /tmp/prometheus.yml "." || true
    if ! matbench parse |& tee > "$ARTIFACT_DIR/_matbench_parse.log"; then
        echo "An error happened during the parsing of the results (or no results were available) in $ARTIFACT_DIR, aborting."
        return 1
    fi

    if ! matbench parse --output_lts $ARTIFACT_DIR/lts_payload.json |& tee > "$ARTIFACT_DIR/_matbench_parse_lts.log"; then
        echo "An error happened while encoding results into a JSON object within $ARTIFACT_DIR, aborting."
        return 1
    fi

    if test_config matbench.download.save_to_artifacts; then
        cp -rv "$MATBENCH_RESULTS_DIRNAME" "$ARTIFACT_DIR"
    fi

    retcode=0
    for filters_to_apply in $filters; do
        if [[ "$filters_to_apply" == "null" ]]; then
            filters_to_apply=""
        fi

        mkdir -p "$ARTIFACT_DIR/$filters_to_apply"
        cd "$ARTIFACT_DIR/$filters_to_apply"

        VISU_LOG_FILE="$ARTIFACT_DIR/$filters_to_apply/_matbench_visualize.log"

        export MATBENCH_FILTERS="$filters_to_apply"
        if ! matbench visualize --generate="$generate_url" |& tee > "$VISU_LOG_FILE"; then
            echo "Visualization generation failed :("
            retcode=1
        fi
        if grep "^ERROR" "$VISU_LOG_FILE"; then
            echo "An error happened during the report generation, aborting."
            grep "^ERROR" "$VISU_LOG_FILE" > "$ARTIFACT_DIR"/FAILURE
            retcode=1
        fi
        unset MATBENCH_FILTERS

        mkdir -p figures_{png,html}
        mv fig_*.png "figures_png" 2>/dev/null || true
        mv fig_*.html "figures_html" 2>/dev/null || true
    done

    cd "$ARTIFACT_DIR"
    return $retcode
}

action=${1:-}

if [[ "$action" == "prepare_matbench" ]]; then
    generate_matbench::get_prometheus
    generate_matbench::prepare_matrix_benchmarking

elif [[ "$action" == "generate_plots" ]]; then
    generate_matbench::generate_visualizations

elif [[ "$action" == "from_dir" ]]; then
    dir=${2:-}

    if [[ -z "$dir" ]]; then
        echo "ERROR: no directory provided in 'from_dir' mode ..."
        exit 1
    fi
    export MATBENCH_RESULTS_DIRNAME="$dir"

    generate_matbench::get_prometheus
    generate_matbench::prepare_matrix_benchmarking

    generate_matbench::generate_visualizations

elif [[ "$action" == "from_pr_args" ]]; then
    generate_matbench::get_prometheus
    generate_matbench::prepare_matrix_benchmarking

    export MATBENCH_RESULTS_DIRNAME="/tmp/matrix_benchmarking_results"
    _get_data_from_pr

    generate_matbench::generate_visualizations

else
    echo "ERROR: unknown action='$action' (JOB_NAME_SAFE='${JOB_NAME_SAFE:-}')"
    exit 1
fi
import os
import logging
import pathlib
import base64
import yaml

from common import env, config, run, sizing

def apply_prefer_pr():
    if not config.ci_artifacts.get_config("base_image.repo.ref_prefer_pr"):
        return

    pr_number = None

    if os.environ.get("OPENSHIFT_CI"):
        pr_number = os.environ.get("PULL_NUMBER")
        if not pr_number:
            logging.warning("apply_prefer_pr: OPENSHIFT_CI: base_image.repo.ref_prefer_pr is set but PULL_NUMBER is empty")
            return

    if os.environ.get("PERFLAB_CI"):
        git_ref = os.environ.get("PERFLAB_GIT_REF")

        try:
            pr_number = int(re.compile("refs/pull/([0-9]+)/head").match(git_ref).groups()[0])
        except Exception as e:
            logging.warning("apply_prefer_pr: PERFLAB_CI: base_image.repo.ref_prefer_pr is set cannot parse PERFLAB_GIT_REF={git_erf}: {e.__class__.__name__}: {e}")
            return

    if os.environ.get("HOMELAB_CI"):
        pr_number = os.environ.get("PULL_NUMBER")

        if not pr_number:
            raise RuntimeError("apply_prefer_pr: HOMELAB_CI: base_image.repo.ref_prefer_pr is set but PULL_NUMBER is empty")

    if not pr_number:
        logging.warning("apply_prefer_pr: Could not figure out the PR number. Keeping the default value.")
        return

    pr_ref = f"refs/pull/{pr_number}/head"

    logging.info(f"Setting '{pr_ref}' as ref for building the base image")
    config.ci_artifacts.set_config("base_image.repo.ref", pr_ref)
    config.ci_artifacts.set_config("base_image.repo.tag", f"pr-{pr_number}")


def prepare_base_image_container(namespace):
    istag = config.get_command_arg("utils build_push_image --prefix base_image", "_istag")

    if run.run(f"oc get istag {istag} -n {namespace} -oname 2>/dev/null", check=False).returncode == 0:
        logging.info(f"Image '{istag}' already exists in namespace '{namespace}'. Don't build it.")
    else:
        run.run(f"./run_toolbox.py from_config utils build_push_image --prefix base_image")

    if not config.ci_artifacts.get_config("base_image.extend.enabled"):
        logging.info("Base image extention not enabled.")
        return

    run.run(f"./run_toolbox.py from_config utils build_push_image --prefix extended_image")


def compute_driver_node_requirement():
    # must match 'roles/local_ci/local_ci_run_multi/templates/job.yaml.j2'
    kwargs = dict(
        cpu = 0.250,
        memory = 2,
        machine_type = config.ci_artifacts.get_config("clusters.driver.compute.machineset.type"),
        user_count = config.ci_artifacts.get_config("tests.scale.user_count"),
        )

    return sizing.main(**kwargs)


def prepare_user_pods(namespace):
    config.ci_artifacts.set_config("base_image.namespace", namespace)

    service_account = config.ci_artifacts.get_config("base_image.user.service_account")
    role = config.ci_artifacts.get_config("base_image.user.role")

    #
    # Prepare the driver namespace
    #
    if run.run(f'oc get project -oname "{namespace}" 2>/dev/null', check=False).returncode != 0:
        run.run(f"oc new-project '{namespace}' --skip-config-write >/dev/null")

    dedicated = "{}" if config.ci_artifacts.get_config("clusters.driver.compute.dedicated") \
        else '{value: ""}' # delete the toleration/node-selector annotations, if it exists

    run.run(f"./run_toolbox.py from_config cluster set_project_annotation --prefix driver --suffix test_node_selector --extra '{dedicated}'")
    run.run(f"./run_toolbox.py from_config cluster set_project_annotation --prefix driver --suffix test_toleration --extra '{dedicated}'")

    #
    # Prepare the driver machineset
    #

    if not config.ci_artifacts.get_config("clusters.driver.is_metal"):
        nodes_count = config.ci_artifacts.get_config("clusters.driver.compute.machineset.count")
        extra = ""
        if nodes_count is None:
            node_count = compute_driver_node_requirement()

            extra = f"--extra '{{scale: {node_count}}}'"

        run.run(f"./run_toolbox.py from_config cluster set_scale --prefix=driver {extra}")

    #
    # Prepare the container image
    #

    apply_prefer_pr()

    prepare_base_image_container(namespace)

    #
    # Deploy Redis server for Pod startup synchronization
    #

    run.run("./run_toolbox.py from_config cluster deploy_redis_server")

    #
    # Deploy Minio
    #

    run.run(f"./run_toolbox.py from_config cluster deploy_minio_s3_server")

    #
    # Prepare the ServiceAccount
    #

    run.run(f"oc create serviceaccount {service_account} -n {namespace} --dry-run=client -oyaml | oc apply -f-")
    run.run(f"oc adm policy add-cluster-role-to-user {role} -z {service_account} -n {namespace}")


    #
    # Prepare the Secret
    #

    secret_name = config.ci_artifacts.get_config("secrets.dir.name")
    secret_env_key = config.ci_artifacts.get_config("secrets.dir.env_key")


    secret_yaml_str = run.run(f"oc create secret generic {secret_name} --from-file=$(find ${secret_env_key}/* -maxdepth 1 -not -type d | tr '\\n' ,)/dev/null -n {namespace} --dry-run=client -oyaml", capture_stdout=True).stdout
    with open(pathlib.Path(os.environ[secret_env_key]) / ".awscred", "rb") as f:
        file_content = f.read()
    base64_secret = base64.b64encode(file_content).decode("ascii")
    secret_yaml = yaml.safe_load(secret_yaml_str)
    secret_yaml["data"][".awscred"] = base64_secret
    del secret_yaml["data"]["null"]

    save_and_create("secret.yaml", yaml.dump(secret_yaml), namespace, is_secret=True)

    run.run(f"oc describe secret {secret_name} -n {namespace} > {env.ARTIFACT_DIR}/secret_{secret_name}.descr")


def save_and_create(name, content, namespace, is_secret=False):
    file_path = pathlib.Path("/tmp") / name if is_secret \
        else env.ARTIFACT_DIR / "src" / name

    try:
        with open(file_path, "w") as f:
            print(content, file=f)

        with open(file_path) as f:
            run.run(f"oc apply -f- -n {namespace}", stdin_file=f)
    finally:
        if is_secret:
            file_path.unlink(missing_ok=True)

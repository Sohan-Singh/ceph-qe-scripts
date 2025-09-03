"""
test_rate_limit - Test rate limit on a Zone level using s3cmd

Usage: test_ratelimit_global.py -c <input_yaml>

<input_yaml>
    Note: Following yaml can be used
    test_ratelimit_global.yaml

Polarion Tests:
CEPH-83574915
CEPH-83574916
CEPH-83574919

Operation:
    Create an user
    Create a bucket with user credentials
    Enable the limits max-read-ops, max-read-bytes, max-write-ops, max-write-bytes on a global zone scope
    Verify the rate limits using s3cmd
    Enable conflicting rate limits on the user scope
    Verify that the user limits take precedence
"""

import argparse
import json
import logging
import math
import os
import subprocess
import sys
import traceback

sys.path.append(os.path.abspath(os.path.join(__file__, "../../../..")))

from time import sleep

from v2.lib import resource_op
from v2.lib.exceptions import RGWBaseException, S3CommandExecError, TestExecError
from v2.lib.s3.write_io_info import BasicIOInfoStructure, IOInfoInitialize
from v2.lib.s3cmd import auth as s3_auth
from v2.tests.s3cmd import reusable as s3cmd_reusable
from v2.utils import utils
from v2.utils.log import configure_logging
from v2.utils.test_desc import AddTestInfo
from v2.utils.utils import RGWService

log = logging.getLogger()
TEST_DATA_PATH = None


def test_exec(config, ssh_con):
    """
    Executes test based on configuration passed
    Args:
        config(object): Test configuration
    """
    io_info_initialize = IOInfoInitialize()
    basic_io_structure = BasicIOInfoStructure()
    io_info_initialize.initialize(basic_io_structure.initial())
    user_info = resource_op.create_users(no_of_users_to_create=config.user_count)[0]
    user_name = user_info["user_id"]
    rgw_service = RGWService()

    ip_and_port = s3cmd_reusable.get_rgw_ip_and_port(ssh_con)
    s3_auth.do_auth(user_info, ip_and_port)
    # add rate limit capability to rgw user
    caps_add = utils.exec_shell_cmd(
        f"radosgw-admin caps add --uid {user_name} "
        + "--caps='users=*;buckets=*;ratelimit=*'"
    )
    data = json.loads(caps_add)
    caps = data["caps"]
    log.info(f" User Caps are :{caps}")

    max_read_bytes = config.bucket_max_read_bytes
    max_read_ops = config.bucket_max_read_ops
    max_write_bytes = config.bucket_max_write_bytes
    max_write_ops = config.bucket_max_write_ops

    max_read_bytes_kb = math.ceil(float(max_read_bytes) / 1024)
    max_write_bytes_kb = math.ceil(float(max_write_bytes) / 1024)

    # create bucket and set limits
    bucket_name = utils.gen_bucket_name_from_userid(user_name, rand_no=0)

    ssl = config.ssl
    s3cmd_reusable.create_bucket(bucket_name, ip_and_port, ssl)
    log.info(f"Bucket {bucket_name} created")

    s3cmd_reusable.rate_limit_set_enable(
        "bucket",
        max_read_ops,
        max_read_bytes,
        max_write_ops,
        max_write_bytes,
        global_scope="global",
    )

    log.info("Restarting for global rate limit to take effect")
    restart_service = rgw_service.restart(ssh_con)
    sleep(60)
    if restart_service is False:
        raise TestExecError("RGW service restart failed")
    limget = utils.exec_shell_cmd(
        f"radosgw-admin global ratelimit get --ratelimit-scope=bucket"
    )
    log.info(f"Rate limits enabled globally on bucket : {limget} ")

    # test the read and write ops limit
    log.info("Testing global read and write ops limit")
    s3cmd_reusable.rate_limit_read(bucket_name, max_read_ops, ssl)

    s3cmd_reusable.rate_limit_write(bucket_name, max_write_ops, ssl)

    # test the read and write data limit
    log.info("Testing global read and write data limits")
    s3cmd_reusable.rate_limit_read(bucket_name, max_read_bytes_kb, ssl)

    s3cmd_reusable.rate_limit_write(bucket_name, max_write_bytes_kb, ssl)

    # Set the rate limits for the user and enable them
    max_read_bytes = config.user_max_read_bytes
    max_read_ops = config.user_max_read_ops
    max_write_bytes = config.user_max_write_bytes
    max_write_ops = config.user_max_write_ops

    max_read_bytes_kb = math.ceil(float(max_read_bytes) / 1024)
    max_write_bytes_kb = math.ceil(float(max_write_bytes) / 1024)

    utils.exec_shell_cmd(
        f"radosgw-admin global ratelimit disable --ratelimit-scope=bucket"
    )
    s3cmd_reusable.rate_limit_set_enable(
        "user",
        max_read_ops,
        max_read_bytes,
        max_write_ops,
        max_write_bytes,
        global_scope="global",
    )

    log.info("Restarting for global rate limit to take effect")
    restart_service = rgw_service.restart(ssh_con)
    sleep(60)
    if restart_service is False:
        raise TestExecError("RGW service restart failed")

    limget = utils.exec_shell_cmd(
        f"radosgw-admin global ratelimit get --ratelimit-scope=user"
    )
    log.info(f"Rate limits enabled on user : {limget} ")

    # test the read and write ops limit
    log.info("Testing the global read and write ops limits")
    bucket_name2 = utils.gen_bucket_name_from_userid(user_name, rand_no=1)
    s3cmd_reusable.create_bucket(bucket_name2, ip_and_port, ssl)

    s3cmd_reusable.rate_limit_read(bucket_name2, max_read_ops, ssl)

    s3cmd_reusable.rate_limit_write(bucket_name2, max_write_ops, ssl)

    # test the read and write data limit
    log.info("Testing the global read and write data limits")
    s3cmd_reusable.rate_limit_read(bucket_name2, max_read_bytes_kb, ssl)

    s3cmd_reusable.rate_limit_write(bucket_name2, max_write_bytes_kb, ssl)

    # set conflicting limits on the user with user scope
    conflict_read_bytes = config.user_conflict_read_bytes
    conflict_read_ops = config.user_conflict_read_ops
    conflict_write_bytes = config.user_conflict_write_bytes
    conflict_write_ops = config.user_conflict_write_ops

    conflict_read_bytes_kb = math.ceil(float(conflict_read_bytes) / 1024)
    conflict_write_bytes_kb = math.ceil(float(conflict_write_bytes) / 1024)

    s3cmd_reusable.rate_limit_set_enable(
        "user",
        conflict_read_ops,
        conflict_read_bytes,
        conflict_write_ops,
        conflict_write_bytes,
        "",
        user_name,
    )
    log.info(
        "Conflicting rate limits set on user at global and user scope, user scope should prevail"
    )
    sleep(61)
    s3cmd_reusable.rate_limit_read(bucket_name2, conflict_read_ops, ssl)

    s3cmd_reusable.rate_limit_write(bucket_name2, conflict_write_ops, ssl)

    s3cmd_reusable.rate_limit_read(bucket_name2, conflict_read_bytes_kb, ssl)

    s3cmd_reusable.rate_limit_write(bucket_name2, conflict_write_bytes_kb, ssl)

    utils.exec_shell_cmd(
        f"radosgw-admin ratelimit disable --ratelimit-scope=user --uid {user_name}"
    )

    utils.exec_shell_cmd(
        f"radosgw-admin global ratelimit disable --ratelimit-scope=user"
    )
    restart_service = rgw_service.restart(ssh_con)
    sleep(60)
    if restart_service is False:
        raise TestExecError("RGW service restart failed")


if __name__ == "__main__":
    test_info = AddTestInfo("test bucket and user rate limits")

    try:
        project_dir = os.path.abspath(os.path.join(__file__, "../../.."))
        test_data_dir = "test_data"
        TEST_DATA_PATH = os.path.join(project_dir, test_data_dir)
        log.info(f"TEST_DATA_PATH: {TEST_DATA_PATH}")
        if not os.path.exists(TEST_DATA_PATH):
            log.info("test data dir not exists, creating.. ")
            os.makedirs(TEST_DATA_PATH)
        parser = argparse.ArgumentParser(
            description="RGW S3 bucket and user rate limits"
        )
        parser.add_argument(
            "-c", dest="config", help="RGW S3 bucket and user rate limits"
        )
        parser.add_argument(
            "-log_level",
            dest="log_level",
            help="Set Log Level [DEBUG, INFO, WARNING, ERROR, CRITICAL]",
            default="info",
        )
        parser.add_argument(
            "--rgw-node", dest="rgw_node", help="RGW Node", default="127.0.0.1"
        )
        args = parser.parse_args()
        yaml_file = args.config
        rgw_node = args.rgw_node
        ssh_con = None
        if rgw_node != "127.0.0.1":
            ssh_con = utils.connect_remote(rgw_node)
        log_f_name = os.path.basename(os.path.splitext(yaml_file)[0])
        configure_logging(f_name=log_f_name, set_level=args.log_level.upper())
        config = resource_op.Config(yaml_file)
        config.read()
        test_exec(config, ssh_con)
        test_info.success_status("test passed")
        sys.exit(0)

    except (RGWBaseException, Exception) as e:
        log.error(e)
        log.error(traceback.format_exc())
        test_info.failed_status("test failed")
        sys.exit(1)

    finally:
        utils.cleanup_test_data_path(TEST_DATA_PATH)

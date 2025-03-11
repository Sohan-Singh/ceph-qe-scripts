"""
Test bucket lifecycle for object expiration:
Script tests the s3 object(both versioned and non-versioned) expiration rules based on:
a) Prefix filters
b) ANDing of Prefix and TAG filters

Usage: test_bucket_lifecycle_object_expiration.py -c configs/<input-yaml>
where : <input-yaml> are test_lc_date.yaml, test_rgw_enable_lc_threads.yaml, test_lc_multiple_rule_prefix_current_days.yaml,
 test_lc_rule_delete_marker.yaml, test_lc_rule_prefix_and_tag.yaml, test_lc_rule_prefix_non_current_days.yaml,
 test_lc_rule_delete_marker_notifications.yaml, test_lc_rule_expiration_notifications.yaml, test_lc_rule_expiration_parallel_notifications.yaml,
 test_lc_rule_prefix_non_current_days_notifications.yaml
 test_lc_rule_expiration_dynamic_reshard.yaml, test_lc_rule_expiration_manual_reshard.yaml,
 test_lc_rule_expiration_manual_reshard_verify_attr.yaml
 test_lc_rule_conflict_btw_exp_transition.yaml, test_lc_rule_conflict_exp_days.yaml,
 test_lc_rule_conflict_transition_actions.yaml
 test_lc_rule_reverse_transition.yaml
 test_lc_with_custom_worktime.yaml
 test_lc_process_without_applying_rule.yaml
 test_lc_transition_with_lc_process.yaml
 test_sse_kms_per_bucket_multipart_object_download_after_transition.yaml
 test_lc_cloud_transition_restore_object.yaml
 test_lc_process_with_versioning_suspended.yaml
 test_lc_date_expire_header.yaml
 test_lc_days_expire_header.yaml
 multisite_configs/test_lc_date_rgw_accounts.yaml

Operation:

-Create a user and a bucket
-Enable versioning on the bucket as per config in the input-yaml file.
-Put objects (object count and size taken from input-yaml)
-Enable Lifecycle(lc) rule on the bucket based on the rule created as per the input-yaml
-Validate the lc rule via lifecycle_validation()
-Remove the user at successful completion.

"""

# test s3 bucket_lifecycle: object expiration operations
import os
import sys

sys.path.append(os.path.abspath(os.path.join(__file__, "../../../..")))
import argparse
import json
import logging
import time
import traceback
from datetime import datetime, timedelta

import v2.lib.resource_op as s3lib
import v2.utils.utils as utils
from v2.lib.exceptions import RGWBaseException, TestExecError
from v2.lib.resource_op import Config
from v2.lib.rgw_config_opts import CephConfOp, ConfigOpts
from v2.lib.s3 import lifecycle_validation as lc_ops
from v2.lib.s3.auth import Auth
from v2.lib.s3.write_io_info import BasicIOInfoStructure, BucketIoInfo, IOInfoInitialize
from v2.tests.s3_swift import reusable
from v2.tests.s3_swift.reusables import s3_object_restore as reusables_s3_restore
from v2.tests.s3_swift.reusables.bucket_notification import NotificationService
from v2.utils.log import configure_logging
from v2.utils.test_desc import AddTestInfo
from v2.utils.utils import RGWService

log = logging.getLogger()


TEST_DATA_PATH = None


def test_exec(config, ssh_con):
    io_info_initialize = IOInfoInitialize()
    basic_io_structure = BasicIOInfoStructure()
    write_bucket_io_info = BucketIoInfo()
    io_info_initialize.initialize(basic_io_structure.initial())
    ceph_conf = CephConfOp(ssh_con)
    rgw_service = RGWService()
    buckets = []
    log.info("making changes to ceph.conf")
    ceph_conf.set_to_ceph_conf(
        "global",
        ConfigOpts.rgw_lc_debug_interval,
        str(config.rgw_lc_debug_interval),
        ssh_con,
    )
    if not config.rgw_enable_lc_threads:
        ceph_conf.set_to_ceph_conf(
            "global",
            ConfigOpts.rgw_enable_lc_threads,
            str(config.rgw_enable_lc_threads),
            ssh_con,
        )
    ceph_conf.set_to_ceph_conf(
        "global",
        ConfigOpts.rgw_lifecycle_work_time,
        str(config.rgw_lifecycle_work_time),
        ssh_con,
    )
    _, version_name = utils.get_ceph_version()
    if "nautilus" in version_name:
        ceph_conf.set_to_ceph_conf(
            "global",
            ConfigOpts.rgw_lc_max_worker,
            str(config.rgw_lc_max_worker),
            ssh_con,
        )
    else:
        ceph_conf.set_to_ceph_conf(
            section=None,
            option=ConfigOpts.rgw_lc_max_worker,
            value=str(config.rgw_lc_max_worker),
            ssh_con=ssh_con,
        )

    if config.test_lc_transition:
        log.info("Set the Bucket LC transitions pre-requisites.")
        reusable.prepare_for_bucket_lc_transition(config)
    if config.enable_resharding and config.sharding_type == "dynamic":
        reusable.set_dynamic_reshard_ceph_conf(config, ssh_con)

    log.info("trying to restart services")
    srv_restarted = rgw_service.restart(ssh_con)
    time.sleep(30)
    if srv_restarted is False:
        raise TestExecError("RGW service restart failed")
    else:
        log.info("RGW service restarted")

    config.user_count = config.user_count if config.user_count else 1
    config.bucket_count = config.bucket_count if config.bucket_count else 1

    log.info(f"user count is {config.user_count}")
    log.info(f"bucket count is {config.bucket_count}")
    if config.test_ops.get("test_via_rgw_accounts", False) is True:
        # create rgw account, account root user, iam user and return iam user details
        tenant_name = config.test_ops.get("tenant_name")
        region = config.test_ops.get("region")

        user_info = reusable.create_rgw_account_with_iam_user(
            config,
            tenant_name,
            region,
        )
    else:
        log.info(f"user count is {config.user_count}")
        user_info = s3lib.create_users(config.user_count)
    log.info(f"print user info {user_info}")

    if config.test_ops.get("send_bucket_notifications", False) is True:
        utils.add_service2_sdk_extras()

    for each_user in user_info:
        log.info(f"print each_user {each_user}")
        auth = Auth(each_user, ssh_con, ssl=config.ssl, haproxy=config.haproxy)
        rgw_conn = auth.do_auth()
        rgw_conn2 = auth.do_auth_using_client()
        notification = None

        if config.test_ops.get("send_bucket_notifications", False) is True:
            notification = NotificationService(config, auth)

        log.info("no of buckets to create: %s" % config.bucket_count)
        for bc in range(config.bucket_count):
            bucket_name = utils.gen_bucket_name_from_userid(
                each_user["user_id"], rand_no=bc
            )
            obj_list = []
            obj_tag = "suffix1=WMV1"
            bucket = reusable.create_bucket(bucket_name, rgw_conn, each_user)
            prefix = list(
                map(
                    lambda x: x,
                    [
                        rule["Filter"].get("Prefix")
                        or rule["Filter"]["And"].get("Prefix")
                        for rule in config.lifecycle_conf
                    ],
                )
            )
            prefix = prefix if prefix else ["dummy1"]
            if config.enable_resharding and config.sharding_type == "manual":
                reusable.bucket_reshard_manual(bucket, config)

            if config.test_ops.get("send_bucket_notifications", False) is True:
                events = [
                    "s3:ObjectLifecycle:Expiration:*",
                    "s3:ObjectLifecycle:Transition:*",
                ]
                notification.apply(bucket_name, events)

            if config.test_ops.get("sse_s3_per_bucket") is True:
                reusable.put_get_bucket_encryption(rgw_conn2, bucket_name, config)

            if (
                config.test_ops.get("lc_expire_header", False) is True
                and not config.test_ops.get("enable_versioning", False) is True
            ):
                log.info(f"perform put and get lifecycle on bucket {bucket.name}")
                life_cycle_rule = {"Rules": config.lifecycle_conf}
                reusable.put_bucket_lifecycle(
                    bucket,
                    rgw_conn,
                    rgw_conn2,
                    life_cycle_rule,
                )
                if config.test_ops.get("create_object", False) is True:
                    log.info(f"perform upload of objects to the bucket {bucket.name}")
                    month = {
                        "Jan": "01",
                        "Feb": "02",
                        "Mar": "03",
                        "Apr": "04",
                        "May": "05",
                        "Jun": "06",
                        "Jul": "07",
                        "Aug": "08",
                        "Sep": "09",
                        "Oct": "10",
                        "Nov": "11",
                        "Dec": "12",
                    }
                    for oc, size in list(config.mapped_sizes.items()):
                        config.obj_size = size
                        key = prefix.pop()
                        prefix.insert(0, key)
                        s3_object_name = key + "." + bucket.name + "." + str(oc)
                        obj_list.append(s3_object_name)
                        log.info(f"s3 objects to create: {config.objects_count}")
                        reusable.upload_object(
                            s3_object_name,
                            bucket,
                            TEST_DATA_PATH,
                            config,
                            each_user,
                        )
                        log.info(f"perform head object for object {s3_object_name}")
                        headresp = rgw_conn2.head_object(
                            Bucket=bucket.name, Key=s3_object_name
                        )
                        log.info(
                            f"head object response: {headresp} for object {s3_object_name}"
                        )
                        if (
                            headresp["ResponseMetadata"]["HTTPStatusCode"] == 200
                            and "x-amz-expiration"
                            not in headresp["ResponseMetadata"]["HTTPHeaders"].keys()
                        ):
                            raise TestExecError(
                                f"Header 'x-amz-expiration' not found for object {s3_object_name} of lc applied bucket {bucket.name}"
                            )
                        log.info(
                            f"Header 'x-amz-expiration' found for object {s3_object_name} of lc applied bucket {bucket.name}"
                        )
                        exp_date = headresp["ResponseMetadata"]["HTTPHeaders"].get(
                            "x-amz-expiration"
                        )
                        log.info(f"validate header 'x-amz-expiration' value {exp_date}")
                        exp_date = exp_date.split(" ")
                        if exp_date[2] in month.keys():
                            exp_date[2] = month[exp_date[2]]
                        expiry_date = f"{exp_date[3]}-{exp_date[2]}-{exp_date[1]}"

                        for rule in config.lifecycle_conf:
                            if rule.get("Expiration", {}).get("Date", False):
                                if expiry_date != rule["Expiration"]["Date"]:
                                    raise TestExecError(
                                        f"validation of 'x-amz-expiration' value failed, expected {rule['Expiration']['Date']} found {expiry_date}"
                                    )
                            else:
                                current_date = datetime.strptime(
                                    str(datetime.now()).split(" ")[0], "%Y-%m-%d"
                                )
                                expiry_date_from_lc_conf = str(
                                    current_date
                                    + timedelta(days=rule["Expiration"]["Days"] + 1)
                                ).split(" ")[0]
                                if f"{expiry_date}" != expiry_date_from_lc_conf:
                                    raise TestExecError(
                                        f"validation of 'x-amz-expiration' value failed found {expiry_date} expected {expiry_date_from_lc_conf}"
                                    )
                    log.info(
                        f"Sucessfully validated value of header 'x-amz-expiration': {exp_date}"
                    )

            if config.test_ops.get("enable_versioning", False) is True:
                reusable.enable_versioning(
                    bucket, rgw_conn, each_user, write_bucket_io_info
                )
                upload_start_time = time.time()
                if config.test_ops["create_object"] is True:
                    for oc, size in list(config.mapped_sizes.items()):
                        config.obj_size = size
                        key = prefix.pop()
                        prefix.insert(0, key)
                        s3_object_name = key + "." + bucket.name + "." + str(oc)
                        obj_list.append(s3_object_name)
                        if config.test_ops["version_count"] > 0:
                            for vc in range(config.test_ops["version_count"]):
                                log.info(
                                    "version count for %s is %s"
                                    % (s3_object_name, str(vc))
                                )
                                log.info("modifying data: %s" % s3_object_name)
                                reusable.upload_object(
                                    s3_object_name,
                                    bucket,
                                    TEST_DATA_PATH,
                                    config,
                                    each_user,
                                    append_data=True,
                                    append_msg="hello object for version: %s\n"
                                    % str(vc),
                                )
                        else:
                            log.info("s3 objects to create: %s" % config.objects_count)
                            reusable.upload_object(
                                s3_object_name,
                                bucket,
                                TEST_DATA_PATH,
                                config,
                                each_user,
                            )
                        if config.testlc_with_obect_acl_set:
                            log.info("Test LC transition with object acl set")
                            reusable.set_get_object_acl(
                                s3_object_name, bucket_name, rgw_conn2
                            )

                upload_end_time = time.time()

                if config.enable_resharding and config.sharding_type == "dynamic":
                    reusable.bucket_reshard_dynamic(bucket, config)

                if config.test_ops.get("verify_attr", False) is True:
                    # refer https://bugzilla.redhat.com/show_bug.cgi?id=2037330#c17
                    log.info("verify attr after sleeping for 20 mins again")
                    time.sleep(20 * 60)
                    reusable.verify_attrs_after_resharding(bucket)

                if not config.parallel_lc:
                    if config.test_ops.get(
                        "transition_with_lc_process_without_rule", False
                    ):
                        log.info(
                            f"perform LC transition with lc process command without applying any rule"
                        )
                        cmd = f"radosgw-admin lc process --bucket {bucket_name}"
                        err = utils.exec_shell_cmd(
                            cmd, debug_info=True, return_err=True
                        )
                        log.info(f"ERROR: {err}")
                        if "Segmentation fault" in err:
                            raise TestExecError("Segmentation fault occured")

                    elif config.test_ops.get("transition_with_lc_process", False):
                        log.info(f"perform LC transition with lc process command")
                        life_cycle_rule = {"Rules": config.lifecycle_conf}
                        reusable.put_bucket_lifecycle(
                            bucket,
                            rgw_conn,
                            rgw_conn2,
                            life_cycle_rule,
                        )
                        cmd = f"radosgw-admin lc process --bucket {bucket_name}"
                        out = utils.exec_shell_cmd(cmd)
                        cmd = f"radosgw-admin lc list"
                        lc_list = json.loads(utils.exec_shell_cmd(cmd))
                        for data in lc_list:
                            if data["bucket"] == bucket_name:
                                if data["status"] == "UNINITIAL":
                                    raise TestExecError(
                                        f"Even if rgw_enable_lc_threads set to false manual lc process for bucket"
                                        f"{bucket_name} should work"
                                    )
                        log.info("sleeping for 30 seconds")
                        time.sleep(30)
                        lc_ops.validate_prefix_rule(bucket, config)
                    else:
                        life_cycle_rule = {"Rules": config.lifecycle_conf}
                        reusable.put_get_bucket_lifecycle_test(
                            bucket,
                            rgw_conn,
                            rgw_conn2,
                            life_cycle_rule,
                            config,
                            upload_start_time,
                            upload_end_time,
                        )
                        if config.test_ops.get("reverse_transition", False):
                            log.info(f"verifying lc reverse transition")
                            rule1_lc_seconds = (
                                config.rgw_lc_debug_interval
                                * config.test_ops.get("actual_lc_days")
                            )
                            rule1_lc_timestamp = upload_end_time + 60 + rule1_lc_seconds
                            expected_storage_class = config.storage_class
                            config.test_ops[
                                "expected_storage_class"
                            ] = expected_storage_class
                            lc_ops.validate_prefix_rule(bucket, config)

                            rule2_lc_seconds = (
                                config.rgw_lc_debug_interval
                                * config.test_ops.get("rule2_lc_days")
                            )
                            rule2_lc_timestamp = rule1_lc_timestamp + rule2_lc_seconds
                            log.info(
                                f"sleeping till {datetime.fromtimestamp(rule2_lc_timestamp)} before verifying lc transition rule2"
                            )
                            while time.time() < rule2_lc_timestamp:
                                log.info(
                                    f"current time: {datetime.fromtimestamp(time.time())}"
                                )
                                time.sleep(5)
                            expected_storage_class = config.second_storage_class
                            config.test_ops[
                                "expected_storage_class"
                            ] = expected_storage_class
                            lc_ops.validate_prefix_rule(bucket, config)

                            rule3_lc_seconds = (
                                config.rgw_lc_debug_interval
                                * config.test_ops.get("rule3_lc_days")
                            )
                            rule3_lc_timestamp = rule2_lc_timestamp + rule3_lc_seconds
                            log.info(
                                f"sleeping till {datetime.fromtimestamp(rule3_lc_timestamp)} before verifying lc transition rule3"
                            )
                            while time.time() < rule3_lc_timestamp:
                                log.info(
                                    f"current time: {datetime.fromtimestamp(time.time())}"
                                )
                                time.sleep(5)
                            expected_storage_class = config.storage_class
                            config.test_ops[
                                "expected_storage_class"
                            ] = expected_storage_class
                            lc_ops.validate_prefix_rule(bucket, config)
                        else:
                            log.info("sleeping for 30 seconds")
                            time.sleep(30)
                            lc_ops.validate_prefix_rule(bucket, config)

                        if config.test_ops["delete_marker"] is True:
                            life_cycle_rule_new = {"Rules": config.delete_marker_ops}
                            reusable.put_get_bucket_lifecycle_test(
                                bucket,
                                rgw_conn,
                                rgw_conn2,
                                life_cycle_rule_new,
                                config,
                            )
                        if config.multiple_delete_marker_check:
                            log.info(
                                f"verification of TC: Not more than 1 delete marker is created for objects deleted many times using LC"
                            )
                            time.sleep(60)
                            cmd = f"radosgw-admin bucket list --bucket {bucket.name}| grep delete-marker | wc -l"
                            out = utils.exec_shell_cmd(cmd)
                            del_marker_count = out.split("\n")[0]
                            if int(del_marker_count) != int(config.objects_count):
                                raise AssertionError(
                                    f"more than one delete marker created for the objects in the bucket {bucket.name}"
                                )
                else:
                    buckets.append(bucket)

            if not config.test_ops.get(
                "enable_versioning", False
            ) is True and not config.test_ops.get("lc_expire_header", False):
                upload_start_time = time.time()
                if config.test_ops["create_object"] is True:
                    for oc, size in list(config.mapped_sizes.items()):
                        config.obj_size = size
                        key = prefix.pop()
                        prefix.insert(0, key)
                        s3_object_name = key + "." + bucket.name + "." + str(oc)
                        obj_list.append(s3_object_name)
                        if config.test_ops.get("upload_type") == "multipart":
                            log.info("upload type: multipart")
                            reusable.upload_mutipart_object(
                                s3_object_name,
                                bucket,
                                TEST_DATA_PATH,
                                config,
                                each_user,
                            )
                        else:
                            reusable.upload_object_with_tagging(
                                s3_object_name,
                                bucket,
                                TEST_DATA_PATH,
                                config,
                                each_user,
                                obj_tag,
                            )
                upload_end_time = time.time()

                if config.enable_resharding and config.sharding_type == "dynamic":
                    reusable.bucket_reshard_dynamic(bucket, config)

                if config.test_ops.get("verify_attr", False) is True:
                    # refer https://bugzilla.redhat.com/show_bug.cgi?id=2037330#c17
                    log.info("verify attr after sleeping for 20 mins again")
                    time.sleep(20 * 60)
                    reusable.verify_attrs_after_resharding(bucket)

                if not config.parallel_lc:
                    life_cycle_rule = {"Rules": config.lifecycle_conf}
                    if not config.invalid_date and config.rgw_enable_lc_threads:
                        reusable.put_get_bucket_lifecycle_test(
                            bucket,
                            rgw_conn,
                            rgw_conn2,
                            life_cycle_rule,
                            config,
                            upload_start_time,
                            upload_end_time,
                        )
                        if config.test_ops.get("lc_same_rule_id_diff_rules"):
                            continue
                        time.sleep(30)
                        lc_ops.validate_and_rule(bucket, config)
                    elif (
                        not config.invalid_date
                        and not config.rgw_enable_lc_threads
                        and not config.test_ops.get("lc_process_with_ver_suspended")
                    ):
                        bucket_before_lc = json.loads(
                            utils.exec_shell_cmd(
                                f"radosgw-admin bucket stats --bucket={bucket.name}"
                            )
                        )
                        reusable.put_bucket_lifecycle(
                            bucket, rgw_conn, rgw_conn2, life_cycle_rule
                        )
                        time.sleep(60)
                        lc_list_before = json.loads(
                            utils.exec_shell_cmd("radosgw-admin lc list")
                        )
                        log.info(f"lc lists is {lc_list_before}")
                        for data in lc_list_before:
                            if bucket.name in data["bucket"]:
                                if data["status"] != "UNINITIAL":
                                    raise TestExecError(
                                        f"Since rgw_enable_lc_threads set to false for bucket {bucket.name}, lc status should be 'UNINITIAL'"
                                    )
                        bucket_after_lc = json.loads(
                            utils.exec_shell_cmd(
                                f"radosgw-admin bucket stats --bucket={bucket.name}"
                            )
                        )
                        if (
                            bucket_before_lc["usage"]["rgw.main"]["num_objects"]
                            != bucket_after_lc["usage"]["rgw.main"]["num_objects"]
                        ):
                            raise TestExecError(
                                f"Since rgw_enable_lc_threads set to false for bucket {bucket.name}, object count should not decrease"
                            )
                        utils.exec_shell_cmd(
                            f"radosgw-admin lc process --bucket {bucket.name}"
                        )
                        list_lc_after = json.loads(
                            utils.exec_shell_cmd("radosgw-admin lc list")
                        )
                        log.info(f"lc lists is {list_lc_after}")
                        for data in list_lc_after:
                            if data["bucket"] == bucket.name:
                                if data["status"] == "UNINITIAL":
                                    raise TestExecError(
                                        f"Even if rgw_enable_lc_threads set to false manual lc process for bucket {bucket.name} should work"
                                    )
                        time.sleep(30)
                        lc_ops.validate_and_rule(bucket, config)
                    elif config.test_ops.get("lc_process_with_ver_suspended", False):
                        log.info(
                            "Test Manual LC Process with versioning suspended on the bucket"
                        )
                        reusable.suspend_versioning(
                            bucket, rgw_conn, each_user, write_bucket_io_info
                        )
                        life_cycle_rule = {"Rules": config.lifecycle_conf}
                        reusable.put_bucket_lifecycle(
                            bucket,
                            rgw_conn,
                            rgw_conn2,
                            life_cycle_rule,
                        )
                        cmd = f"radosgw-admin lc process --bucket {bucket_name}"
                        out = utils.exec_shell_cmd(cmd)
                        cmd = f"radosgw-admin lc list"
                        lc_list = json.loads(utils.exec_shell_cmd(cmd))
                        for data in lc_list:
                            if data["bucket"] == bucket_name:
                                if data["status"] == "UNINITIAL":
                                    raise TestExecError(
                                        f"manual lc process for bucket: {bucket_name} failed"
                                    )
                        time.sleep(30)
                        lc_ops.validate_prefix_rule_non_versioned(bucket, config)
                    else:
                        bucket_life_cycle = s3lib.resource_op(
                            {
                                "obj": rgw_conn,
                                "resource": "BucketLifecycleConfiguration",
                                "args": [bucket.name],
                            }
                        )
                        put_bucket_life_cycle = s3lib.resource_op(
                            {
                                "obj": bucket_life_cycle,
                                "resource": "put",
                                "kwargs": dict(LifecycleConfiguration=life_cycle_rule),
                            }
                        )
                        if put_bucket_life_cycle:
                            lc_list = utils.exec_shell_cmd("radosgw-admin lc list")
                            log.info(f"lc list Details: {lc_list}")
                            raise TestExecError(
                                "Put bucket lifecycle Succeeded, expected failure due to invalid date in LC rule"
                            )

                    if config.test_ops.get("download_object_after_transition", False):
                        for s3_object_name in obj_list:
                            s3_object_path = os.path.join(
                                TEST_DATA_PATH, s3_object_name
                            )
                            reusable.download_object(
                                s3_object_name,
                                bucket,
                                TEST_DATA_PATH,
                                s3_object_path,
                                config,
                            )

                else:
                    log.info("Inside parallel lc")
                    buckets.append(bucket)
            if (
                not config.parallel_lc
                and config.test_ops.get("send_bucket_notifications", False) is True
            ):
                notification.verify(bucket_name)
            if config.test_ops.get("test_s3_restore_from_cloud", False):
                log.info(
                    f"Test s3 restore of objects transitioned to the cloud for {bucket_name}"
                )
                bucket_list_op = utils.exec_shell_cmd(
                    f"radosgw-admin bucket list --bucket={bucket_name}"
                )
                json_doc_list = json.loads(bucket_list_op)
                log.info(f"the bucket list for {bucket_name}  is {json_doc_list}")
                objs_total = sum(1 for item in json_doc_list if "instance" in item)
                log.info(
                    f"Occurances of verion_ids in bucket list is {objs_total} times"
                )
                for i in range(0, objs_total):
                    if json_doc_list[i]["tag"] != "delete-marker":
                        object_key = json_doc_list[i]["name"]
                        version_id = json_doc_list[i]["instance"]
                        reusables_s3_restore.restore_s3_object(
                            rgw_conn2,
                            each_user,
                            config,
                            bucket_name,
                            object_key,
                            version_id,
                            days=7,
                        )
                # Test restored objects are not available after restore interval
                log.info(
                    "Test restored objects are not available after restore interval"
                )
                time.sleep(240)
                for i in range(0, objs_total):
                    if json_doc_list[i]["tag"] != "delete-marker":
                        object_key = json_doc_list[i]["name"]
                        version_id = json_doc_list[i]["instance"]
                        reusables_s3_restore.check_restore_expiry(
                            rgw_conn2,
                            each_user,
                            config,
                            bucket_name,
                            object_key,
                            version_id,
                        )
        if config.parallel_lc:
            log.info("Inside parallel lc processing")
            life_cycle_rule = {"Rules": config.lifecycle_conf}
            for bucket in buckets:
                reusable.put_bucket_lifecycle(
                    bucket, rgw_conn, rgw_conn2, life_cycle_rule
                )
            time.sleep(60)
            for bucket in buckets:
                if not config.test_ops.get("enable_versioning", False) is True:
                    lc_ops.validate_prefix_rule_non_versioned(bucket, config)
                else:
                    lc_ops.validate_prefix_rule(bucket, config)
                if config.test_ops.get("send_bucket_notifications", False) is True:
                    notification.verify(bucket.name)

        if not config.rgw_enable_lc_threads:
            ceph_conf.set_to_ceph_conf(
                "global", ConfigOpts.rgw_enable_lc_threads, "true", ssh_con
            )
            rgw_service.restart()
            time.sleep(30)
        if config.test_ops.get("test_via_rgw_accounts", False) is True:
            log.info("do not remove user")
        else:
            reusable.remove_user(each_user)
        # check for any crashes during the execution
        crash_info = reusable.check_for_crash()
        if crash_info:
            raise TestExecError("ceph daemon crash found!")


if __name__ == "__main__":
    test_info = AddTestInfo("bucket life cycle: test object expiration")
    test_info.started_info()

    try:
        project_dir = os.path.abspath(os.path.join(__file__, "../../.."))
        test_data_dir = "test_data"
        TEST_DATA_PATH = os.path.join(project_dir, test_data_dir)
        log.info("TEST_DATA_PATH: %s" % TEST_DATA_PATH)
        if not os.path.exists(TEST_DATA_PATH):
            log.info("test data dir not exists, creating.. ")
            os.makedirs(TEST_DATA_PATH)
        parser = argparse.ArgumentParser(description="RGW S3 Automation")
        parser.add_argument("-c", dest="config", help="RGW Test yaml configuration")
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
        config = Config(yaml_file)
        config.read(ssh_con)
        if config.mapped_sizes is None:
            config.mapped_sizes = utils.make_mapped_sizes(config)

        test_exec(config, ssh_con)
        test_info.success_status("test passed")
        sys.exit(0)

    except (RGWBaseException, Exception) as e:
        log.error(e)
        log.error(traceback.format_exc())
        test_info.failed_status("test failed")
        sys.exit(1)

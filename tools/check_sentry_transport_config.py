#!/usr/bin/env python3
"""Validate the sentry inter-board and USB topic wiring."""

from pathlib import Path
import sys

import yaml
from yaml.constructor import ConstructorError
from yaml.resolver import BaseResolver


ROOT = Path(__file__).resolve().parents[1]
GIMBAL_CONFIG = ROOT / "User/RobotConfig/sentry_gimbal.yaml"
CHASSIS_CONFIG = ROOT / "User/RobotConfig/sentry_chassis.yaml"
DECISION_TOPICS = {
    "sentry_buy_bullet_num_topic_name": "sentry_buy_bullet_num",
    "sentry_remote_buy_bullet_times_topic_name": "sentry_remote_buy_bullet_times",
    "sentry_remote_buy_hp_times_topic_name": "sentry_remote_buy_hp_times",
    "sentry_buy_resurrection_topic_name": "sentry_buy_resurrection",
    "sentry_state_topic_name": "sentry_state",
}
SENTRY_PROTOCOL_TOPICS = {
    "buy_bullet_topic_name": "sentry_buy_bullet_num",
    "remote_buy_bullet_times_topic_name": "sentry_remote_buy_bullet_times",
    "remote_buy_hp_times_topic_name": "sentry_remote_buy_hp_times",
    "buy_resurrection_topic_name": "sentry_buy_resurrection",
    "state_topic_name": "sentry_state",
}
USB_UART = "usb_otg_hs_cdc"
REQUIRED_OUTBOUND_TOPICS = (
    "ahrs_quaternion", "nav_gimbal_feedback_v1"
)
REQUIRED_GIMBAL_INPUT_TOPICS = ("target_euler", "fire_notify")


class UniqueKeySafeLoader(yaml.SafeLoader):
    """Safe YAML loader that rejects duplicate mapping keys."""


def construct_unique_mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key ({key!r})",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeySafeLoader.add_constructor(
    BaseResolver.DEFAULT_MAPPING_TAG, construct_unique_mapping
)


def load_modules(path):
    with path.open(encoding="ascii") as config_file:
        config = yaml.load(config_file, Loader=UniqueKeySafeLoader)
    modules = config.get("modules") if isinstance(config, dict) else None
    if not isinstance(modules, list):
        raise ValueError("top-level 'modules' must be a list")
    return modules


def modules_named(modules, name):
    return [module for module in modules if module.get("name") == name]


def require_singleton(modules, name, config_name, errors):
    matching_modules = modules_named(modules, name)
    if len(matching_modules) != 1:
        errors.append(
            f"{config_name} {name}: expected exactly one, found {len(matching_modules)}"
        )
        return None
    return matching_modules[0]


def constructor_args(module):
    args = module.get("constructor_args")
    return args if isinstance(args, dict) else None


def require_topic_configs(module, module_name, errors):
    args = constructor_args(module)
    topics = args.get("topic_configs") if args is not None else None
    if not isinstance(topics, list):
        errors.append(f"{module_name} topic_configs must be a list")
        return None
    return topics


def duplicate_topics(topics):
    return sorted({topic for topic in topics if topics.count(topic) > 1})


def check_dual_board(name, module, errors):
    if module is None:
        return

    args = constructor_args(module)
    if args is None:
        errors.append(f"{name} DualBoard constructor_args must be a mapping")
        return

    constructor_order = ("mode_topic_name", "cmd", *DECISION_TOPICS)
    missing_order_arguments = [
        argument for argument in constructor_order if argument not in args
    ]
    if missing_order_arguments:
        errors.append(
            f"{name} DualBoard is missing ordered arguments: "
            + ", ".join(missing_order_arguments)
        )
    else:
        argument_positions = [
            list(args).index(argument) for argument in constructor_order
        ]
        if argument_positions != sorted(argument_positions):
            errors.append(
                f"{name} DualBoard constructor arguments must be ordered "
                "mode_topic_name, cmd, then sentry topic names"
            )

    for argument, expected_topic in DECISION_TOPICS.items():
        actual_topic = args.get(argument)
        if actual_topic != expected_topic:
            errors.append(
                f"{name} DualBoard {argument} must be {expected_topic!r}, "
                f"found {actual_topic!r}"
            )


def check_sentry_protocol(module, errors):
    if module is None:
        return

    args = constructor_args(module)
    if args is None:
        errors.append("chassis SentryProtocol constructor_args must be a mapping")
        return

    for argument, expected_topic in SENTRY_PROTOCOL_TOPICS.items():
        actual_topic = args.get(argument)
        if actual_topic != expected_topic:
            errors.append(
                f"chassis SentryProtocol {argument} must be {expected_topic!r}, "
                f"found {actual_topic!r}"
            )


def check_gimbal_shared_topic(module, gimbal_modules, dual_board, errors):
    if module is None:
        return

    topics = require_topic_configs(module, "gimbal SharedTopic", errors)
    if topics is not None:
        duplicates = duplicate_topics(topics)
        if duplicates:
            errors.append(
                "gimbal SharedTopic contains duplicate topics: "
                + ", ".join(duplicates)
            )
        for topic in REQUIRED_GIMBAL_INPUT_TOPICS:
            topic_count = topics.count(topic)
            if topic_count != 1:
                errors.append(
                    f"gimbal SharedTopic must contain {topic!r} exactly once, "
                    f"found {topic_count}"
                )
        forbidden_topics = sorted(set(topics).intersection(DECISION_TOPICS.values()))
        if forbidden_topics:
            errors.append(
                "gimbal USB SharedTopic must not expose navigation decision topics: "
                + ", ".join(forbidden_topics)
            )

    if dual_board is not None and gimbal_modules.index(dual_board) > gimbal_modules.index(module):
        errors.append("gimbal DualBoard must appear before SharedTopic")


def usb_shared_topic_clients(modules):
    return [
        module
        for module in modules_named(modules, "SharedTopicClient")
        if (constructor_args(module) or {}).get("uart_name") == USB_UART
    ]


def shared_topics_on_uart(modules, uart_name):
    return [
        module
        for module in modules_named(modules, "SharedTopic")
        if (constructor_args(module) or {}).get("uart_name") == uart_name
    ]


def check_usb_client(gimbal_modules, chassis_modules, errors):
    usb_clients = usb_shared_topic_clients(gimbal_modules)
    usb_clients.extend(usb_shared_topic_clients(chassis_modules))
    if len(usb_clients) != 1:
        errors.append(
            f"expected exactly one SharedTopicClient on {USB_UART}, found {len(usb_clients)}"
        )
        return

    topics = require_topic_configs(usb_clients[0], "USB SharedTopicClient", errors)
    if topics is None:
        return

    duplicates = duplicate_topics(topics)
    if duplicates:
        errors.append(
            "USB SharedTopicClient contains duplicate topics: " + ", ".join(duplicates)
        )
    for topic in REQUIRED_OUTBOUND_TOPICS:
        topic_count = topics.count(topic)
        if topic_count != 1:
            errors.append(
                f"USB SharedTopicClient must contain {topic!r} exactly once, "
                f"found {topic_count}"
            )


def load_config_modules(config_name, path, errors):
    try:
        return load_modules(path)
    except (OSError, ValueError, yaml.YAMLError) as error:
        problem = getattr(error, "problem", str(error))
        errors.append(f"{config_name} configuration YAML is invalid: {problem}")
        return None


def check_configuration():
    errors = []
    gimbal_modules = load_config_modules("gimbal", GIMBAL_CONFIG, errors)
    chassis_modules = load_config_modules("chassis", CHASSIS_CONFIG, errors)
    if gimbal_modules is None or chassis_modules is None:
        return errors

    gimbal_dual_board = require_singleton(
        gimbal_modules, "DualBoard", "gimbal", errors
    )
    chassis_dual_board = require_singleton(
        chassis_modules, "DualBoard", "chassis", errors
    )
    sentry_protocol = require_singleton(
        chassis_modules, "SentryProtocol", "chassis", errors
    )
    gimbal_usb_shared_topics = shared_topics_on_uart(gimbal_modules, USB_UART)
    if len(gimbal_usb_shared_topics) != 1:
        errors.append(
            f"gimbal SharedTopic on {USB_UART}: expected exactly one, "
            f"found {len(gimbal_usb_shared_topics)}"
        )
        gimbal_shared_topic = None
    else:
        gimbal_shared_topic = gimbal_usb_shared_topics[0]

    if modules_named(gimbal_modules, "WsProtocol"):
        errors.append("gimbal WsProtocol is obsolete; use NavHostLink + SharedTopic")

    # Every SharedTopic instance must have a unique topic list, including the
    # USART6 navigation receiver.  Direction-specific requirements are checked
    # below for the USB instance.
    for shared_topic in modules_named(gimbal_modules, "SharedTopic"):
        topics = require_topic_configs(shared_topic, "gimbal SharedTopic", errors)
        if topics is not None:
            duplicates = duplicate_topics(topics)
            if duplicates:
                errors.append(
                    "gimbal SharedTopic contains duplicate topics: "
                    + ", ".join(duplicates)
                )

    check_dual_board("gimbal", gimbal_dual_board, errors)
    check_dual_board("chassis", chassis_dual_board, errors)
    check_sentry_protocol(sentry_protocol, errors)
    check_gimbal_shared_topic(
        gimbal_shared_topic, gimbal_modules, gimbal_dual_board, errors
    )
    check_usb_client(gimbal_modules, chassis_modules, errors)
    return errors


def main():
    errors = check_configuration()
    if errors:
        print("Sentry transport configuration contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Sentry transport configuration contract passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

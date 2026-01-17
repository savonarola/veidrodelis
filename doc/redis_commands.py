#!/usr/bin/env python3
"""
Generate a markdown table of Redis commands from JSON spec files.

Usage:
    python3 redis_commands.py [commands_folder] [options]

Examples:
    python3 redis_commands.py ../context/valkey_src/src/commands
    python3 redis_commands.py ../context/valkey_src/src/commands --before-version 8.0.0
    python3 redis_commands.py ../context/valkey_src/src/commands --groups hash,string
    python3 redis_commands.py ../context/valkey_src/src/commands --groups hash --no-groups server
    python3 redis_commands.py ../context/valkey_src/src/commands --flags WRITE
    python3 redis_commands.py ../context/valkey_src/src/commands --no-flags WRITE,READONLY
    python3 redis_commands.py ../context/valkey_src/src/commands --flags FAST --no-flags READONLY
    python3 redis_commands.py ../context/valkey_src/src/commands --before-version 7.0.0 --groups string --no-flags READONLY
"""

import argparse
import json
import os
import sys
from pathlib import Path


def parse_version(version_str: str) -> tuple:
    """Parse a version string like '7.4.0' into a tuple of integers for comparison."""
    try:
        parts = version_str.split('.')
        return tuple(int(p) for p in parts)
    except (ValueError, AttributeError):
        return (0, 0, 0)


def load_commands(commands_folder: str) -> list[dict]:
    """Load all command JSON files from the specified folder."""
    commands = []
    folder = Path(commands_folder)

    if not folder.exists():
        print(f"Error: Folder '{commands_folder}' does not exist.", file=sys.stderr)
        sys.exit(1)

    for json_file in sorted(folder.glob('*.json')):
        try:
            with open(json_file, 'r') as f:
                data = json.load(f)
                for cmd_name, cmd_data in data.items():
                    commands.append({
                        'name': cmd_name,
                        'since': cmd_data.get('since', ''),
                        'group': cmd_data.get('group', ''),
                        'flags': cmd_data.get('command_flags', []),
                        'acl_categories': cmd_data.get('acl_categories', []),
                    })
        except (json.JSONDecodeError, IOError) as e:
            print(f"Warning: Could not parse {json_file}: {e}", file=sys.stderr)

    return commands


def parse_csv(value: str | None) -> set[str]:
    """Parse a comma-separated string into a set of lowercased values."""
    if not value:
        return set()
    return set(item.strip().lower() for item in value.split(',') if item.strip())


def filter_commands(
    commands: list[dict],
    before_version: str | None,
    groups: str | None,
    no_groups: str | None,
    flags: str | None,
    no_flags: str | None
) -> list[dict]:
    """Apply filters to the commands list."""
    filtered = commands

    # Version filter
    if before_version:
        version_tuple = parse_version(before_version)
        filtered = [
            cmd for cmd in filtered
            if cmd['since'] and parse_version(cmd['since']) < version_tuple
        ]

    # Groups filter
    include_groups = parse_csv(groups)
    exclude_groups = parse_csv(no_groups)
    if include_groups or exclude_groups:
        def group_matches(cmd):
            group = cmd['group'].lower()
            # If include set is specified, group must be in it
            if include_groups and group not in include_groups:
                return False
            # Group must not be in exclude set
            if group in exclude_groups:
                return False
            return True
        filtered = [cmd for cmd in filtered if group_matches(cmd)]

    # Flags filter
    include_flags = parse_csv(flags)
    exclude_flags = parse_csv(no_flags)
    if include_flags or exclude_flags:
        def flags_match(cmd):
            cmd_flags = set(f.lower() for f in cmd['flags'])
            # If include set is specified, command must have ALL included flags
            if include_flags and not include_flags.issubset(cmd_flags):
                return False
            # Command must not have ANY excluded flag
            if cmd_flags & exclude_flags:
                return False
            return True
        filtered = [cmd for cmd in filtered if flags_match(cmd)]

    return filtered


def generate_markdown_table(commands: list[dict]) -> str:
    """Generate a markdown table from the commands list."""
    lines = []

    # Header
    lines.append('| Command | Since | Group | Flags | ACL Categories | Implemented | Replica Conversion |')
    lines.append('|---------|-------|-------|-------|----------------|-------------|-------------------|')

    # Sort commands by name
    sorted_commands = sorted(commands, key=lambda c: c['name'])

    for cmd in sorted_commands:
        name = cmd['name']
        since = cmd['since']
        group = cmd['group']
        flags = ', '.join(cmd['flags']) if cmd['flags'] else ''
        acl = ', '.join(cmd['acl_categories']) if cmd['acl_categories'] else ''
        implemented = '`TODO`'
        replica_conv = '`TODO`'

        lines.append(f'| {name} | {since} | {group} | {flags} | {acl} | {implemented} | {replica_conv} |')

    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(
        description='Generate a markdown table of Redis commands from JSON spec files.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument(
        'commands_folder',
        nargs='?',
        default='../context/valkey_src/src/commands',
        help='Path to the folder containing command JSON files (default: ../context/valkey_src/src/commands)'
    )
    parser.add_argument(
        '--before-version',
        metavar='VERSION',
        help='Filter commands introduced before this version (strict, e.g., 8.0.0 excludes 8.0.0)'
    )
    parser.add_argument(
        '--groups',
        metavar='GROUPS',
        help='Include only these groups (comma-separated, e.g., hash,string,list)'
    )
    parser.add_argument(
        '--no-groups',
        metavar='GROUPS',
        help='Exclude these groups (comma-separated, e.g., server,cluster)'
    )
    parser.add_argument(
        '--flags',
        metavar='FLAGS',
        help='Include only commands with ALL these flags (comma-separated, e.g., WRITE,FAST)'
    )
    parser.add_argument(
        '--no-flags',
        metavar='FLAGS',
        help='Exclude commands with ANY of these flags (comma-separated, e.g., READONLY,BLOCKING)'
    )

    args = parser.parse_args()

    # Load and filter commands
    commands = load_commands(args.commands_folder)

    if not commands:
        print("No commands found.", file=sys.stderr)
        sys.exit(1)

    filtered = filter_commands(
        commands,
        args.before_version,
        args.groups,
        args.no_groups,
        args.flags,
        args.no_flags
    )

    if not filtered:
        print("No commands match the specified filters.", file=sys.stderr)
        sys.exit(1)

    # Generate and print the table
    table = generate_markdown_table(filtered)
    print(table)

    # Print summary to stderr
    print(f"\n# Total: {len(filtered)} commands", file=sys.stderr)


if __name__ == '__main__':
    main()

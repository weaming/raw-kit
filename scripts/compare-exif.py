#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


KEY_TAGS = [
    'System:FileName',
    'File:FileType',
    'File:MIMEType',
    'System:FileSize',
    'Composite:ImageSize',
    'IFD0:ImageWidth',
    'IFD0:ImageHeight',
    'ExifIFD:ExifImageWidth',
    'ExifIFD:ExifImageHeight',
    'QuickTime:ImageWidth',
    'QuickTime:ImageHeight',
    'IFD0:Make',
    'IFD0:Model',
    'ExifIFD:LensModel',
    'ExifIFD:FocalLength',
    'ExifIFD:FNumber',
    'ExifIFD:ExposureTime',
    'ExifIFD:ISO',
    'ExifIFD:DateTimeOriginal',
    'ExifIFD:CreateDate',
    'IFD0:ModifyDate',
    'IFD0:Orientation',
    'ExifIFD:ColorSpace',
    'ICC_Profile:ProfileDescription',
    'QuickTime:ColorProfiles',
    'QuickTime:ColorPrimaries',
    'QuickTime:TransferCharacteristics',
    'QuickTime:MatrixCoefficients',
    'QuickTime:VideoFullRangeFlag',
    'QuickTime:MaxContentLightLevel',
    'QuickTime:MaxPicAverageLightLevel',
    'IFD0:ImageDescription',
    'IFD0:Software',
    'XMP:XMPToolkit',
]

GROUP_ORDER = [
    'System',
    'File',
    'IFD0',
    'ExifIFD',
    'EXIF',
    'ICC_Profile',
    'QuickTime',
    'XMP',
    'MakerNotes',
    'Composite',
]

VOLATILE_KEYS = {
    'SourceFile',
    'File:Directory',
    'File:FileName',
    'File:FileModifyDate',
    'File:FileAccessDate',
    'File:FileInodeChangeDate',
    'File:FilePermissions',
    'System:Directory',
    'System:FileName',
    'System:FileModifyDate',
    'System:FileAccessDate',
    'System:FileInodeChangeDate',
    'System:FilePermissions',
}


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='对比两张图片的 ExifTool 元信息，默认只显示差异。',
    )
    parser.add_argument('left_file', type=Path, help='左图路径')
    parser.add_argument('right_file', type=Path, help='右图路径')
    parser.add_argument('--all', action='store_true', help='同时显示相同项')
    return parser.parse_args()


def require_file(path: Path) -> None:
    if not path.is_file():
        raise RuntimeError(f'文件不存在: {path}')


def run_exiftool(path: Path) -> dict[str, Any]:
    command = [
        'exiftool',
        '-j',
        '-a',
        '-G1',
        '-s',
        '-api',
        'largefilesupport=1',
        str(path),
    ]
    result = subprocess.run(command, check=False, text=True, capture_output=True)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f'exiftool 读取失败: {path}\n{message}')

    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f'exiftool JSON 解析失败: {path}\n{error}') from error

    if not payload:
        return {}

    return payload[0]


def normalize_value(value: Any) -> str:
    if isinstance(value, list):
        return ' | '.join(normalize_value(item) for item in value)

    if isinstance(value, dict):
        return json.dumps(value, ensure_ascii=False, sort_keys=True)

    return str(value)


def display_name(key: str) -> str:
    if ':' not in key:
        return key

    group, tag = key.split(':', 1)
    return f'[{group}] {tag}'


def group_name(key: str) -> str:
    if ':' not in key:
        return 'Other'

    return key.split(':', 1)[0]


def group_sort_key(name: str) -> tuple[int, str]:
    try:
        return GROUP_ORDER.index(name), name
    except ValueError:
        return len(GROUP_ORDER), name


def format_table(headers: list[str], rows: list[list[str]]) -> list[str]:
    if not rows:
        return []

    widths = [max(len(header), *(len(row[index]) for row in rows)) for index, header in enumerate(headers)]
    header_line = '  '.join(header.ljust(widths[index]) for index, header in enumerate(headers))
    separator = '  '.join('-' * widths[index] for index in range(len(headers)))
    lines = [header_line, separator]

    for row in rows:
        lines.append('  '.join(row[index].ljust(widths[index]) for index in range(len(headers))))

    return lines


def print_section(title: str, lines: list[str]) -> None:
    print(f'== {title} ==')
    if lines:
        for line in lines:
            print(line)
    else:
        print('(none)')
    print()


def collect_grouped_rows(keys: list[str], left: dict[str, str], right: dict[str, str]) -> list[str]:
    grouped: dict[str, list[list[str]]] = defaultdict(list)

    for key in keys:
        grouped[group_name(key)].append(
            [
                display_name(key),
                left.get(key, ''),
                right.get(key, ''),
            ]
        )

    lines: list[str] = []
    for group in sorted(grouped, key=group_sort_key):
        if lines:
            lines.append('')
        lines.append(f'[{group}]')
        lines.extend(format_table(['Tag', '左图', '右图'], grouped[group]))

    return lines


def build_key_summary(left: dict[str, str], right: dict[str, str]) -> list[str]:
    rows = []

    for key in KEY_TAGS:
        left_value = left.get(key, '')
        right_value = right.get(key, '')
        if left_value or right_value:
            mark = '相同' if left_value == right_value else '不同'
            rows.append([mark, display_name(key), left_value, right_value])

    return format_table(['状态', 'Tag', '左图', '右图'], rows)


def main() -> int:
    arguments = parse_arguments()
    require_file(arguments.left_file)
    require_file(arguments.right_file)

    left_raw = run_exiftool(arguments.left_file)
    right_raw = run_exiftool(arguments.right_file)
    left = {key: normalize_value(value) for key, value in left_raw.items()}
    right = {key: normalize_value(value) for key, value in right_raw.items()}

    print('== 文件 ==')
    print(f'左图: {arguments.left_file}')
    print(f'右图: {arguments.right_file}')
    print()

    print_section('关键摘要', build_key_summary(left, right))

    all_keys = sorted(
        (set(left) | set(right)) - VOLATILE_KEYS,
        key=lambda key: (group_sort_key(group_name(key)), key),
    )
    changed_keys = [key for key in all_keys if key in left and key in right and left[key] != right[key]]
    only_left_keys = [key for key in all_keys if key in left and key not in right]
    only_right_keys = [key for key in all_keys if key in right and key not in left]
    equal_keys = [key for key in all_keys if key in left and key in right and left[key] == right[key]]

    print('== 统计 ==')
    print(f'不同项: {len(changed_keys)}')
    print(f'仅左图: {len(only_left_keys)}')
    print(f'仅右图: {len(only_right_keys)}')
    print(f'相同项: {len(equal_keys)}')
    print()

    print_section('不同项', collect_grouped_rows(changed_keys, left, right))

    left_only_rows = [[display_name(key), left[key]] for key in only_left_keys]
    print_section('仅左图存在', format_table(['Tag', '左图'], left_only_rows))

    right_only_rows = [[display_name(key), right[key]] for key in only_right_keys]
    print_section('仅右图存在', format_table(['Tag', '右图'], right_only_rows))

    if arguments.all:
        equal_rows = [[display_name(key), left[key]] for key in equal_keys]
        print_section('相同项', format_table(['Tag', '值'], equal_rows))

    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except FileNotFoundError as error:
        print(f'缺少命令: {error.filename}', file=sys.stderr)
        raise SystemExit(1)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)

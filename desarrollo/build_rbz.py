import os
import re
import zipfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_version():
    registrator = os.path.join(REPO_ROOT, 'despiece_pro.rb')
    with open(registrator, encoding='utf-8') as handle:
        content = handle.read()
    match = re.search(r"EXTENSION\.version\s*=\s*'([^']+)'", content)
    if not match:
        raise SystemExit('No se pudo leer EXTENSION.version de despiece_pro.rb')
    return match.group(1)


def build_rbz():
    version = read_version()
    output_dir = os.path.join(REPO_ROOT, 'instalable')
    os.makedirs(output_dir, exist_ok=True)
    output = os.path.join(output_dir, f'DespiecePRO_v{version}.rbz')

    files = [
        ('despiece_pro.rb', 'despiece_pro.rb'),
        ('despiece_pro/main.rb', 'despiece_pro/main.rb'),
        ('despiece_pro/dialog.html', 'despiece_pro/dialog.html'),
        ('despiece_pro/extra_dialog.html', 'despiece_pro/extra_dialog.html'),
        ('despiece_pro/info_dialog.html', 'despiece_pro/info_dialog.html'),
        ('despiece_pro/export_excel.py', 'despiece_pro/export_excel.py'),
        ('despiece_pro/icons/scan_small.png', 'despiece_pro/icons/scan_small.png'),
        ('despiece_pro/icons/scan_large.png', 'despiece_pro/icons/scan_large.png'),
        ('despiece_pro/icons/list_small.png', 'despiece_pro/icons/list_small.png'),
        ('despiece_pro/icons/list_large.png', 'despiece_pro/icons/list_large.png'),
    ]

    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as zf:
        for local_name, arcname in files:
            local_path = os.path.join(REPO_ROOT, local_name)
            if not os.path.exists(local_path):
                print(f'ERROR: No existe {local_path}')
                return
            zf.write(local_path, arcname)
            print(f'  + {arcname}')

    size_kb = os.path.getsize(output) / 1024
    print(f'\nGenerado: {output} ({size_kb:.1f} KB)')


if __name__ == '__main__':
    build_rbz()

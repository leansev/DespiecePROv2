# -*- coding: utf-8 -*-
import os
import re

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIALOG = os.path.join(REPO_ROOT, 'despiece_pro', 'dialog.html')

SAMPLE_CONTENT = (
    '<div class="module" data-entity-id="12345">'
    '<div class="module-header">'
    '<div class="module-code" style="color:#ff941f;">BP1</div>'
    '<div class="module-separator">-</div>'
    '<div class="module-name">Barra Puerta 1</div>'
    '<button class="edit-btn">✎</button>'
    '</div>'
    '<div class="piece-row" data-dim-key="780,542,18">'
    '<div class="qty">2x</div>'
    '<div class="dimensions">780 × 542 × 18mm</div>'
    '<div><span class="badge" style="color:#ff941f;">BP1</span></div>'
    '<div class="piece-name">Laterales</div>'
    '</div>'
    '</div>'
)

with open(DIALOG, encoding='utf-8') as f:
    template = f.read()

html = template.replace('%CONTENT%', SAMPLE_CONTENT).replace('%TOTAL%', '2')

errors = []
if '%CONTENT%' in html or '%TOTAL%' in html:
    errors.append('Placeholders sin reemplazar')
if 'class="module"' not in html:
    errors.append('Falta .module en contenido')
if 'class="piece-row"' not in html:
    errors.append('Falta .piece-row en contenido')
if 'data-entity-id="12345"' not in html:
    errors.append('Falta data-entity-id')
if 'data-dim-key="780,542,18"' not in html:
    errors.append('Falta data-dim-key')
if 'sketchup.clear_list' not in html:
    errors.append('Falta callback clear_list')
if 'sketchup.update_module_name' not in html:
    errors.append('Falta callback update_module_name')
if 'sketchup.update_piece_name' not in html:
    errors.append('Falta callback update_piece_name')
if 'sketchup.refresh_list' not in html:
    errors.append('Falta callback refresh_list')
if not re.search(r'TOTAL:\s*2\s*piezas', html):
    errors.append('Total mal formateado')

required_classes = [
    'module-header', 'module-code', 'module-separator', 'module-name',
    'edit-btn', 'qty', 'dimensions', 'badge', 'piece-name', 'footer', 'clear-btn'
]
for cls in required_classes:
    if cls not in html:
        errors.append('Falta clase CSS/HTML: ' + cls)

if errors:
    print('FALLÓ:')
    for err in errors:
        print(' -', err)
    raise SystemExit(1)

print('OK: dialog.html ensambla correctamente con format_html de ejemplo')
print('OK: callbacks sketchup presentes (clear_list, update_*, refresh_list)')

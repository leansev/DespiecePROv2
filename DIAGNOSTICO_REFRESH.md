# DIAGNOSTICO_REFRESH

Archivo generado para análisis externo de un bug relacionado con refresh / preservación de nombre y cantos.

Fuente de prompts: historial de chat del agente Cursor en este repo ([refresh metadata](e99a0956-6092-4631-8700-88cd058362e4)).

---

## 1. CONTEXTO DEL PEDIDO ORIGINAL

A continuación, los prompts textuales del usuario relacionados con implementar/arreglar el refresh que preserva nombre y canto (y metadatos asociados) al cambiar medidas, tal como aparecen en el historial de chat.

### Prompt 1

```
Repo: D:\PROGRAMAS\Pluggins mios para skechup\DespiecePROv2\despiece_pro_v2\
BUG: al modificar una pieza (cambio de medida o de textura/color), se 
pierden los parámetros ya asignados a esa pieza: nombre (piece_names), 
tapacanto (piece_cantos) y estado de invertida. Vuelven a su default 
como si fuera una pieza nueva. Solo debe perderse esa info si la 
pieza se ELIMINA — si solo se modifica un atributo (medida o 
textura), los parámetros ya cargados tienen que conservarse.
PASO 1 — DIAGNÓSTICO (hacer antes de tocar nada):
Revisar en main.rb (class Store) cómo se identifica cada pieza 
agrupada y cómo se relacionan con eso piece_names{}, piece_cantos{} 
e invertida. Hipótesis a confirmar o descartar: si la clave usada 
para esos diccionarios está compuesta por dimensiones y/o color 
(ej. "length_width_thickness_color"), al cambiar cualquiera de esos 
valores la pieza pasa a tener una clave nueva, el lookup en 
piece_names/piece_cantos falla, y por eso se resetea todo — no 
porque se haya "borrado" la pieza sino porque cambió su clave.
Confirmar el mecanismo real (puede ser este u otro) antes de aplicar 
el fix.
PASO 2 — FIX:
Si el diagnóstico confirma la hipótesis: introducir un identificador 
estable por pieza (uid) que NO dependa de largo/ancho/espesor/color, 
y usar ese uid como clave de piece_names, piece_cantos e invertida 
en vez de una clave derivada de esos atributos. Al modificarse 
medida o textura, el uid se mantiene y los parámetros asociados 
persisten. Solo al eliminar la pieza (uid ya no existe en la lista 
actual) se debe descartar su entrada en esos diccionarios.
Si el mecanismo real es otro, aplicar la solución equivalente que 
logre el mismo resultado: conservar nombre/canto/invertida mientras 
la pieza siga existiendo, sin importar qué atributo se le cambie.
PASO 3 — VERIFICAR EFECTOS COLATERALES:
Revisar que este cambio no rompa refresh_all_modules, serialize_state/
deserialize_pieces, ni el export_payload (ExcelExporter, 
export_excel.py, export_cortecloud.py) — todos deben seguir 
funcionando con el nuevo esquema de identificación.
PASO 4 — DEJAR LISTO PARA PROBAR Y SUBIR:
- Copiar los archivos modificados a Plugins/despiece_pro_v2/ para 
  prueba en caliente.
- Hacer commit con mensaje descriptivo del fix y push a 
  github.com/leansev/DespiecePROv2 (branch master).
- Regenerar instalable/DespiecePROv2_v2.0.0.rbz con build_rbz.py.
- Reportar qué mecanismo causaba el bug y qué cambiaste exactamente.
No modificar despiece_pro (original).
```

### Prompt 2

```
necesito que arregles, si se abre un archivo con ya un despiece hecho y le pongo refresh se elimina todo lo cargado
```

### Prompt 3

```
revisalo portque sigue haciendolo
```

---

## 2. CÓDIGO COMPLETO Y ACTUAL

Los cuatro archivos solicitados existen con esos nombres exactos. Contenido íntegro al momento de generar este diagnóstico:

### `despiece_pro_v2/main.rb`

```ruby
# despiece_pro_v2/main.rb
# Logica principal del plugin Despiece PRO v2

require 'json'

module BiraEstudio
  module DespieceProV2
    PLUGIN_DIR = File.expand_path(File.dirname(__FILE__)).freeze

    module DimHelpers
      module_function

      def ordered_lwt_mm(values_in_inches)
        dims_mm = values_in_inches.map { |value| (value * 25.4).round }
        dims_mm.sort! { |a, b| b <=> a }

        {
          length: dims_mm[0],
          width: dims_mm[1],
          thickness: dims_mm[2]
        }
      end

      def piece_dimensions_mm(entity)
        unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          raise ArgumentError, 'La entidad debe ser un componente o grupo'
        end

        b = entity.definition.bounds
        raise ArgumentError, 'La pieza no tiene geometria valida' if b.empty?

        t = entity.transformation
        vx = (b.corner(1) - b.corner(0)).transform(t)
        vy = (b.corner(2) - b.corner(0)).transform(t)
        vz = (b.corner(4) - b.corner(0)).transform(t)

        ordered_lwt_mm([vx.length, vy.length, vz.length])
      end

      def piece_color_hex(entity)
        mat = entity.material rescue nil

        unless mat
          container = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
          face = container.find { |e| e.is_a?(Sketchup::Face) }
          mat = face.material if face
          mat = face.back_material if face && !mat
        end

        return '#FFFFFF' unless mat
        c = mat.color
        '#%02X%02X%02X' % [c.red, c.green, c.blue]
      end
    end

    class Store
      @modules = []
      @scanned_uids = []
      @scanned_entities = []
      @color_names = {}
      @canto_config = {}
      @open_module_uids = []
      SCAN_MATERIAL_NAME = 'DespiecePROv2_escaneado'.freeze
      DEFAULT_BADGE_COLOR = '#ff941f'.freeze
      ATTRIBUTE_DICT = 'despiece_pro_v2'.freeze
      ATTRIBUTE_KEY = 'data'.freeze
      MODULE_UID_KEY = 'uid'.freeze
      PIECE_UID_KEY = 'piece_uid'.freeze

      class << self
        attr_reader :modules, :scanned_entities

        def add_module(name, pieces, uid)
          @modules << {
            name: name,
            uid: uid.to_s,
            pieces: pieces,
            piece_names: {},
            piece_cantos: {},
            badge_color: DEFAULT_BADGE_COLOR
          }
        end

        def find_module_by_uid(uid)
          uid = uid.to_s
          @modules.find { |entry| entry[:uid].to_s == uid }
        end

        def set_module_open(uid, open)
          @open_module_uids ||= []
          if open
            @open_module_uids << uid.to_s unless @open_module_uids.include?(uid.to_s)
          else
            @open_module_uids.delete(uid.to_s)
          end
        end

        def module_open?(uid)
          (@open_module_uids || []).include?(uid.to_s)
        end

        def update_module_name(uid, name)
          entry = find_module_by_uid(uid)
          return unless entry

          name = name.to_s.strip
          name = 'Grupo sin nombre' if name.empty?
          entry[:name] = name
        end

        def update_piece_name(uid, piece_uid, name)
          entry = find_module_by_uid(uid)
          return unless entry

          entry[:piece_names] ||= {}
          piece_uid = piece_uid.to_s
          name = name.to_s.strip
          if name.empty?
            entry[:piece_names].delete(piece_uid)
          else
            entry[:piece_names][piece_uid] = name
          end
        end

        def get_piece_cantos(uid, piece_uid)
          entry = find_module_by_uid(uid)
          return { arr: 0, aba: 0, izq: 0, der: 0 } unless entry
          stored = (entry[:piece_cantos] || {})[piece_uid.to_s]
          return { arr: 0, aba: 0, izq: 0, der: 0 } unless stored
          { arr: stored['arr'].to_i, aba: stored['aba'].to_i, izq: stored['izq'].to_i, der: stored['der'].to_i }
        end

        def update_piece_cantos(uid, piece_uid, arr, aba, izq, der)
          entry = find_module_by_uid(uid)
          return unless entry
          entry[:piece_cantos] ||= {}
          entry[:piece_cantos][piece_uid.to_s] = { 'arr' => arr.to_i, 'aba' => aba.to_i, 'izq' => izq.to_i, 'der' => der.to_i }
        end

        def piece_invertida?(piece)
          piece[:invertida] == true
        end

        def find_piece_by_uid(entry, piece_uid)
          piece_uid = piece_uid.to_s
          entry[:pieces].find { |piece| piece[:uid].to_s == piece_uid }
        end

        def toggle_piece_invertida(uid, piece_uid)
          entry = find_module_by_uid(uid)
          return false unless entry

          piece = find_piece_by_uid(entry, piece_uid)
          return false unless piece

          piece[:invertida] = !piece_invertida?(piece)
          piece[:invertida]
        end

        # extra_dialog: arr/aba = largo (horizontal), izq/der = ancho (vertical)
        def display_dimensions(piece)
          if piece_invertida?(piece)
            {
              length: piece[:width],
              width: piece[:length],
              thickness: piece[:thickness]
            }
          else
            {
              length: piece[:length],
              width: piece[:width],
              thickness: piece[:thickness]
            }
          end
        end

        def display_cantos(cantos, invertida)
          return cantos unless invertida

          {
            arr: cantos[:izq],
            aba: cantos[:der],
            izq: cantos[:arr],
            der: cantos[:aba]
          }
        end

        def canto_color(v)
          v = v.to_i
          return '#ff1d1d' if v == 1
          return '#1d35ff' if v == 2

          'rgba(255,255,255,.25)'
        end

        def color_name(hex)
          hex = hex.to_s.strip.upcase
          hex = '#FFFFFF' if hex.empty?
          return 'Blanco' if hex == '#FFFFFF'

          (@color_names || {})[hex].to_s
        end

        def placa_label(thickness, color)
          th = thickness.to_i.to_s + 'mm'
          name = color_name(color)
          name = 'Blanco' if name.to_s.strip.empty?

          th + ' ' + name
        end

        def set_color_name(hex, name)
          hex = hex.to_s.strip.upcase
          hex = '#FFFFFF' if hex.empty?
          return if hex == '#FFFFFF'

          @color_names ||= {}
          name = name.to_s.strip
          if name.empty?
            @color_names.delete(hex)
          else
            @color_names[hex] = name
          end
        end

        def placas_list
          totals = {}
          order = []

          @modules.each do |entry|
            entry[:pieces].each do |piece|
              color = piece[:color].to_s.strip.upcase
              color = '#FFFFFF' if color.empty?
              thickness = piece[:thickness].to_i
              key = [thickness, color]
              unless totals.key?(key)
                totals[key] = 0
                order << key
              end
              totals[key] += piece[:count].to_i
            end
          end

          order.sort! do |a, b|
            if a[0] == b[0]
              a[1] <=> b[1]
            else
              b[0] <=> a[0]
            end
          end

          order.map do |thickness, color|
            {
              thickness: thickness,
              color: color,
              name: color_name(color),
              piece_count: totals[[thickness, color]]
            }
          end
        end

        def placa_config_key(thickness, color)
          color = color.to_s.strip.upcase
          color = '#FFFFFF' if color.empty?

          "#{thickness.to_i},#{color}"
        end

        def get_canto_config(thickness, color)
          key = placa_config_key(thickness, color)
          stored = (@canto_config || {})[key]
          return {} unless stored.is_a?(Hash)

          stored
        end

        def set_canto_config(thickness, color, slot, field, value)
          key = placa_config_key(thickness, color)
          slot = slot.to_s.strip.downcase
          field = field.to_s.strip.downcase
          return unless %w[rojo azul].include?(slot)
          return unless %w[color espesor].include?(field)

          @canto_config ||= {}
          @canto_config[key] ||= {}
          @canto_config[key][slot] ||= {}
          value = value.to_s.strip
          if value.empty?
            @canto_config[key][slot].delete(field)
          else
            value = value.upcase if field == 'color'
            @canto_config[key][slot][field] = value
          end
        end

        def distinct_colors
          colors = {}

          @modules.each do |entry|
            entry[:pieces].each do |piece|
              color = piece[:color].to_s.strip.upcase
              color = '#FFFFFF' if color.empty?
              colors[color] = true
            end
          end

          colors.keys.sort
        end

        def update_module_badge_color(uid, color)
          entry = find_module_by_uid(uid)
          return unless entry

          color = color.to_s.strip
          color = DEFAULT_BADGE_COLOR unless color =~ /\A#[0-9A-Fa-f]{6}\z/
          entry[:badge_color] = color
        end

        def module_badge_color(entry)
          entry[:badge_color] || DEFAULT_BADGE_COLOR
        end

        def module_piece_count(entry)
          count = 0
          entry[:pieces].each do |piece|
            count += piece[:count]
          end
          count
        end

        def render_module_block(entry)
          uid = entry[:uid]
          acronym = module_acronym(entry[:name])
          color = escape_html(module_badge_color(entry))
          name = escape_html(entry[:name])
          piece_total = module_piece_count(entry)

          piece_rows = entry[:pieces].map do |piece|
            piece_uid = piece[:uid].to_s
            piece_name = (entry[:piece_names] || {})[piece_uid] || ''
            render_piece_row(
              piece,
              piece[:count],
              acronym,
              piece_name,
              piece_uid,
              color,
              uid
            )
          end.join('')

          open_class = module_open?(entry[:uid]) ? ' open' : ''

          '<div class="module' + open_class + '" data-entity-id="' + escape_html(uid.to_s) + '">' +
            '<div class="module-header">' +
            '<div class="module-header-left">' +
            '<div class="module-code" style="color:' + color + ';">' + escape_html(acronym) + '</div>' +
            '<div class="module-separator">-</div>' +
            '<div class="module-name">' + name + '</div>' +
            '</div>' +
            '<button class="edit-btn">✎</button>' +
            '</div>' +
            '<div class="module-body">' +
            piece_rows +
            '<div class="module-pieces-row">' +
            '<button class="delete-btn">🗑</button>' +
            '<div class="module-pieces">Piezas: ' + piece_total.to_s + '</div>' +
            '</div>' +
            '</div>' +
            '</div>'
        end

        def render_piece_row(piece, count, acronym, piece_name, piece_uid, color, uid)
          dims_data = display_dimensions(piece)
          dims = dims_data[:length].to_s + ' × ' + dims_data[:width].to_s + ' × ' + dims_data[:thickness].to_s + 'mm'
          invertida = piece_invertida?(piece)
          cantos = get_piece_cantos(uid, piece_uid)
          disp_cantos = display_cantos(cantos, invertida)
          color_pieza = piece[:color] || '#FFFFFF'
          invert_class = invertida ? 'invert-btn is-active' : 'invert-btn'

          '<div class="piece-row" data-piece-uid="' + escape_html(piece_uid) + '">' +
            '<div class="color-chip" style="background:' + escape_html(color_pieza) + ';"></div>' +
            '<div class="qty">' + count.to_s + 'x</div>' +
            '<div class="dimensions">' + dims + '</div>' +
            '<div><span class="badge" style="color:' + color + ';">' + escape_html(acronym) + '</span></div>' +
            '<div class="piece-name">' + escape_html(piece_name) + '</div>' +
            '<button type="button" class="' + invert_class + '" title="Invertir dimensiones" data-uid="' + escape_html(uid.to_s) + '" data-piece-uid="' + escape_html(piece_uid) + '">&#8644;</button>' +
            '<div class="extra-btn canto-preview" title="Tapacantos" data-uid="' + escape_html(uid.to_s) + '" data-piece-uid="' + escape_html(piece_uid) + '" ' +
            'style="border-top-color:' + canto_color(disp_cantos[:arr]) + ';border-bottom-color:' + canto_color(disp_cantos[:aba]) + ';border-left-color:' + canto_color(disp_cantos[:izq]) + ';border-right-color:' + canto_color(disp_cantos[:der]) + ';"></div>' +
            '</div>'
        end

        def piece_dim_key(length, width, thickness, color)
          color = color.to_s.strip
          color = '#FFFFFF' if color.empty?

          "#{length},#{width},#{thickness},#{color}"
        end

        def module_acronym(name)
          name = name.to_s.strip
          return '' if name.empty? || name == 'Grupo sin nombre'

          words = name.split(/\s+/).reject { |word| word.empty? }
          return '' if words.empty?

          if words.length == 1
            words[0][0, 3].upcase
          else
            words.map { |word| word[0].upcase }.join[0, 3]
          end
        end

        def scanned?(uid)
          @scanned_uids.include?(uid.to_s)
        end

        def mark_scanned(entity, uid)
          uid = uid.to_s
          return if uid.empty?
          return if @scanned_uids.include?(uid)

          @scanned_uids << uid
          @scanned_entities << entity
        end

        def remove_module(uid)
          uid = uid.to_s
          entry = find_module_by_uid(uid)
          return unless entry

          @modules.delete(entry)
          @scanned_uids.delete(uid)
          @scanned_entities.delete_if do |entity|
            !entity.valid? || entity_uid(entity) == uid
          end

          model = Sketchup.active_model
          view = model.active_view if model
          view.invalidate if view
        end

        def clear!
          model = Sketchup.active_model
          cleanup_scan_materials(model) if model
          reset_state!

          view = model.active_view if model
          view.invalidate if view
        end

        def reset_state!
          @modules.clear
          @scanned_uids.clear
          @scanned_entities.clear
          @color_names = {}
          @canto_config = {}
          @open_module_uids = []
        end

        def entity_uid(entity)
          return '' unless entity

          uid = entity.get_attribute(ATTRIBUTE_DICT, MODULE_UID_KEY)
          uid.to_s.strip
        rescue StandardError
          ''
        end

        def assign_module_uid(entity)
          uid = entity_uid(entity)
          return uid unless uid.empty?

          uid = generate_module_uid
          entity.set_attribute(ATTRIBUTE_DICT, MODULE_UID_KEY, uid)
          uid
        end

        def generate_module_uid
          "mod_#{Time.now.to_i}_#{rand(10000)}"
        end

        def entity_piece_uid(entity)
          return '' unless entity

          uid = entity.get_attribute(ATTRIBUTE_DICT, PIECE_UID_KEY)
          uid.to_s.strip
        rescue StandardError
          ''
        end

        def ensure_piece_uid(entity)
          uid = entity_piece_uid(entity)
          return uid unless uid.empty?

          uid = generate_piece_uid
          entity.set_attribute(ATTRIBUTE_DICT, PIECE_UID_KEY, uid)
          uid
        end

        def generate_piece_uid
          "pie_#{Time.now.to_i}_#{rand(10000)}"
        end

        def unify_group_piece_uid(entities)
          uids = entities.map { |entity| ensure_piece_uid(entity) }.uniq
          canonical = uids.min
          entities.each do |entity|
            entity.set_attribute(ATTRIBUTE_DICT, PIECE_UID_KEY, canonical)
          end
          canonical
        end

        def migrate_piece_metadata!(entry)
          names = normalize_hash(entry[:piece_names] || {})
          cantos = normalize_hash(entry[:piece_cantos] || {})
          return if names.empty? && cantos.empty?
          return if names.keys.any? { |key| piece_uid_key?(key) }

          new_names = {}
          new_cantos = {}
          entry[:pieces].each do |piece|
            piece_uid = piece[:uid].to_s
            old_key = piece_dim_key(piece[:length], piece[:width], piece[:thickness], piece[:color] || '#FFFFFF')
            new_names[piece_uid] = names[old_key] if names.key?(old_key)
            new_cantos[piece_uid] = cantos[old_key] if cantos.key?(old_key)
          end

          names.each do |key, value|
            new_names[key] = value if piece_uid_key?(key) && !new_names.key?(key)
          end
          cantos.each do |key, value|
            new_cantos[key] = value if piece_uid_key?(key) && !new_cantos.key?(key)
          end

          entry[:piece_names] = new_names
          entry[:piece_cantos] = new_cantos
        end

        def piece_uid_key?(key)
          key.to_s.start_with?('pie_')
        end

        def cleanup_orphan_piece_metadata!(entry)
          active_uids = entry[:pieces].map { |piece| piece[:uid].to_s }.uniq
          active_lookup = active_uids.each_with_object({}) { |uid, memo| memo[uid] = true }

          entry[:piece_names] ||= {}
          entry[:piece_cantos] ||= {}
          entry[:piece_names].delete_if { |key, _| !active_lookup[key.to_s] }
          entry[:piece_cantos].delete_if { |key, _| !active_lookup[key.to_s] }
        end

        def transfer_piece_metadata!(entry, old_uid, new_uid)
          old_uid = old_uid.to_s
          new_uid = new_uid.to_s
          return if old_uid.empty? || new_uid.empty? || old_uid == new_uid

          entry[:piece_names] ||= {}
          entry[:piece_cantos] ||= {}

          if entry[:piece_names].key?(old_uid) && !entry[:piece_names].key?(new_uid)
            entry[:piece_names][new_uid] = entry[:piece_names].delete(old_uid)
          end

          if entry[:piece_cantos].key?(old_uid) && !entry[:piece_cantos].key?(new_uid)
            entry[:piece_cantos][new_uid] = entry[:piece_cantos].delete(old_uid)
          end
        end

        # Tras cambiar medida/color en SketchUp, el piece_uid de la entidad puede cambiar.
        # Empareja piezas viejas/nuevas y transfiere nombre/cantos/invertida.
        def reconcile_pieces_metadata!(entry, old_pieces, new_grouped)
          old_pieces = old_pieces.map(&:dup)
          matched_old = {}
          matched_new = {}

          # 1) Mismo piece_uid en entidad
          new_grouped.each_with_index do |np, idx|
            uid = np[:uid].to_s
            next if uid.empty?

            old_piece = old_pieces.find { |p| p[:uid].to_s == uid && !matched_old[p[:uid].to_s] }
            unless old_piece
              np[:invertida] = false if np[:invertida].nil?
              next
            end

            np[:invertida] = piece_invertida?(old_piece)
            matched_old[old_piece[:uid].to_s] = true
            matched_new[idx] = true
          end

          # 2) Mismas dimensiones+color pero uid distinto (entidad re-etiquetada)
          new_grouped.each_with_index do |np, idx|
            next if matched_new[idx]

            key = piece_dim_key(np[:length], np[:width], np[:thickness], np[:color] || '#FFFFFF')
            old_piece = old_pieces.find do |p|
              !matched_old[p[:uid].to_s] &&
                piece_dim_key(p[:length], p[:width], p[:thickness], p[:color] || '#FFFFFF') == key
            end
            next unless old_piece

            transfer_piece_metadata!(entry, old_piece[:uid], np[:uid])
            np[:invertida] = piece_invertida?(old_piece)
            matched_old[old_piece[:uid].to_s] = true
            matched_new[idx] = true
          end

          # 3) Modificación probable: mismo ancho/espesor/color, largo distinto
          new_grouped.each_with_index do |np, idx|
            next if matched_new[idx]

            old_piece = old_pieces.find do |p|
              !matched_old[p[:uid].to_s] && piece_similar_modification?(p, np)
            end
            next unless old_piece

            transfer_piece_metadata!(entry, old_piece[:uid], np[:uid])
            np[:invertida] = piece_invertida?(old_piece)
            matched_old[old_piece[:uid].to_s] = true
            matched_new[idx] = true
          end

          unmatched_old = old_pieces.reject { |piece| matched_old[piece[:uid].to_s] }
          unmatched_new_indices = new_grouped.each_index.reject { |i| matched_new[i] }

          # 4) Emparejar restantes en orden (ej. 1 eliminada + 2 nuevas → la 1ra hereda metadata)
          pair_count = [unmatched_old.length, unmatched_new_indices.length].min
          pair_count.times do |i|
            old_piece = unmatched_old[i]
            idx = unmatched_new_indices[i]
            new_piece = new_grouped[idx]
            transfer_piece_metadata!(entry, old_piece[:uid], new_piece[:uid])
            new_piece[:invertida] = piece_invertida?(old_piece)
            matched_new[idx] = true
          end

          new_grouped.each do |np|
            np[:invertida] = false if np[:invertida].nil?
          end

          cleanup_orphan_piece_metadata!(entry)
          new_grouped
        end

        def piece_similar_modification?(old_piece, new_piece)
          old_piece[:width].to_i == new_piece[:width].to_i &&
            old_piece[:thickness].to_i == new_piece[:thickness].to_i &&
            (old_piece[:color] || '#FFFFFF').to_s.strip.upcase == (new_piece[:color] || '#FFFFFF').to_s.strip.upcase
        end

        def assign_missing_entity_piece_uids(module_entity, entry)
          scanner = ScanModuleTool.new
          raw_pieces = scanner.collect_pieces(module_entity)
          return if raw_pieces.empty?

          available_uids_by_key = {}
          available_uids_by_nc = {}
          entry[:pieces].each do |piece|
            key = piece_dim_key(piece[:length], piece[:width], piece[:thickness], piece[:color] || '#FFFFFF')
            nc = dim_key_no_color(piece[:length], piece[:width], piece[:thickness])
            uid = piece[:uid].to_s
            available_uids_by_key[key] ||= []
            available_uids_by_key[key] << uid
            available_uids_by_nc[nc] ||= []
            available_uids_by_nc[nc] << uid
          end

          groups = {}
          raw_pieces.each do |entity|
            next unless entity_piece_uid(entity).empty?

            begin
              dims = DimHelpers.piece_dimensions_mm(entity)
              color = DimHelpers.piece_color_hex(entity)
              sorted_dims = [dims[:length], dims[:width], dims[:thickness]].sort { |a, b| b <=> a }
              key = piece_dim_key(sorted_dims[0], sorted_dims[1], sorted_dims[2], color)
              groups[key] ||= []
              groups[key] << entity
            rescue ArgumentError
              next
            end
          end

          groups.each do |key, entities|
            pool = (available_uids_by_key[key] || []).dup
            nc = key.split(',')[0..2].join(',')
            nc_pool = (available_uids_by_nc[nc] || []).dup

            entities.each do |entity|
              next unless entity_piece_uid(entity).empty?

              uid = pool.shift
              if uid.nil? || uid.empty?
                uid = nc_pool.shift
              end
              uid = generate_piece_uid if uid.nil? || uid.empty?
              entity.set_attribute(ATTRIBUTE_DICT, PIECE_UID_KEY, uid)
            end
          end
        end

        def build_uid_entity_map(model)
          map = {}
          collect_uid_entities(model.entities, map)
          map
        end

        def relink_module_entities(model)
          uid_map = build_uid_entity_map(model)
          scanner = ScanModuleTool.new
          claimed_uids = @modules.map { |entry| entry[:uid].to_s }.each_with_object({}) { |uid, memo| memo[uid] = true }
          candidates = []
          collect_unlinked_module_candidates(model.entities, candidates, claimed_uids)

          @modules.each do |entry|
            uid = entry[:uid].to_s
            next if uid.empty? || uid_map[uid]

            match = candidates.find do |entity|
              entity.valid? && entity_uid(entity).empty? && entity.name.to_s.strip == entry[:name].to_s.strip
            end

            unless match
              old_sig = module_piece_signature(entry)
              match = candidates.find do |entity|
                next false unless entity.valid? && entity_uid(entity).empty?

                begin
                  pieces = scanner.collect_pieces(entity)
                  grouped = scanner.group_pieces_by_dimensions(pieces)
                  module_piece_signature_from_grouped(grouped) == old_sig
                rescue StandardError
                  false
                end
              end
            end

            next unless match

            match.set_attribute(ATTRIBUTE_DICT, MODULE_UID_KEY, uid)
            uid_map[uid] = match
            @scanned_uids << uid unless @scanned_uids.include?(uid)
            @scanned_entities << match unless @scanned_entities.include?(match)
            candidates.delete(match)
          end

          uid_map
        end

        def collect_unlinked_module_candidates(entities, candidates, claimed_uids)
          scanner = ScanModuleTool.new
          entities.each do |entity|
            next unless entity.valid?
            next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)

            uid = entity_uid(entity)
            if uid.empty? && scanner.module_container?(entity)
              candidates << entity
            end

            if entity.is_a?(Sketchup::Group)
              collect_unlinked_module_candidates(entity.entities, candidates, claimed_uids)
            elsif entity.is_a?(Sketchup::ComponentInstance)
              collect_unlinked_module_candidates(entity.definition.entities, candidates, claimed_uids)
            end
          end
        end

        def module_piece_signature(entry)
          (entry[:pieces] || []).map do |piece|
            [
              piece[:length].to_i,
              piece[:width].to_i,
              piece[:thickness].to_i,
              (piece[:color] || '#FFFFFF').to_s.strip.upcase,
              piece[:count].to_i
            ]
          end.sort
        end

        def module_piece_signature_from_grouped(grouped)
          grouped.map do |piece|
            [
              piece[:length].to_i,
              piece[:width].to_i,
              piece[:thickness].to_i,
              (piece[:color] || '#FFFFFF').to_s.strip.upcase,
              piece[:count].to_i
            ]
          end.sort
        end

        def collect_uid_entities(entities, map)
          entities.each do |entity|
            next unless entity.valid?
            next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)

            uid = entity_uid(entity)
            map[uid] = entity unless uid.empty?

            if entity.is_a?(Sketchup::Group)
              collect_uid_entities(entity.entities, map)
            elsif entity.is_a?(Sketchup::ComponentInstance)
              collect_uid_entities(entity.definition.entities, map)
            end
          end
        end

        def save_to_model(model)
          return false unless model

          model.set_attribute(ATTRIBUTE_DICT, ATTRIBUTE_KEY, serialize_state)
          Sketchup.status_text = 'Despiece guardado en el modelo'
          true
        rescue StandardError => e
          Sketchup.status_text = "Error al guardar despiece: #{e.message}"
          false
        end

        def refresh_all_modules
          model = Sketchup.active_model
          uid_map = relink_module_entities(model)
          scanner = BiraEstudio::DespieceProV2::ScanModuleTool.new
          report = { added: [], removed: [], changed: [], skipped: [] }

          dim_key_no_color = lambda do |length, width, thickness|
            "#{length.to_i},#{width.to_i},#{thickness.to_i}"
          end

          @modules.each do |entry|
            uid = entry[:uid]
            entity = uid_map[uid]

            unless entity && entity.valid?
              report[:skipped] << { module_name: entry[:name], reason: 'grupo no encontrado en el modelo (se conservan los datos guardados)' }
              next
            end

            assign_missing_entity_piece_uids(entity, entry)

            begin
              pieces = scanner.collect_pieces(entity)
              new_grouped = scanner.group_pieces_by_dimensions(pieces)
            rescue StandardError => e
              puts "Despiece PRO refresh: error escaneando #{entry[:name]} - #{e.message}"
              report[:skipped] << { module_name: entry[:name], reason: "error al escanear: #{e.message}" }
              next
            end

            if new_grouped.empty?
              report[:skipped] << { module_name: entry[:name], reason: 'sin piezas detectadas (se conservan los datos guardados)' }
              next
            end

            old_keys = entry[:pieces].map { |p| dim_key_no_color.call(p[:length], p[:width], p[:thickness]) }
            new_keys = new_grouped.map { |p| dim_key_no_color.call(p[:length], p[:width], p[:thickness]) }

            added_keys = new_keys - old_keys
            removed_keys = old_keys - new_keys
            changed_keys = (old_keys & new_keys).select do |k|
              old_p = entry[:pieces].find { |p| dim_key_no_color.call(p[:length], p[:width], p[:thickness]) == k }
              new_p = new_grouped.find { |p| dim_key_no_color.call(p[:length], p[:width], p[:thickness]) == k }
              old_p && new_p && old_p[:count] != new_p[:count]
            end

            added_keys.each do |k|
              p = new_grouped.find { |np| dim_key_no_color.call(np[:length], np[:width], np[:thickness]) == k }
              name = (entry[:piece_names] || {})[p[:uid].to_s].to_s
              report[:added] << { module_name: entry[:name], piece: p, name: name }
            end

            removed_keys.each do |k|
              p = entry[:pieces].find { |op| dim_key_no_color.call(op[:length], op[:width], op[:thickness]) == k }
              name = (entry[:piece_names] || {})[p[:uid].to_s].to_s
              report[:removed] << { module_name: entry[:name], piece: p, name: name }
            end

            changed_keys.each do |k|
              old_p = entry[:pieces].find { |op| dim_key_no_color.call(op[:length], op[:width], op[:thickness]) == k }
              new_p = new_grouped.find { |np| dim_key_no_color.call(np[:length], np[:width], np[:thickness]) == k }
              name = (entry[:piece_names] || {})[old_p[:uid].to_s].to_s
              report[:changed] << { module_name: entry[:name], old: old_p, new: new_p, name: name }
            end

            old_pieces = entry[:pieces].map(&:dup)
            entry[:pieces] = reconcile_pieces_metadata!(entry, old_pieces, new_grouped)
          end

          save_to_model(model)
          report
        end

        def merge_placas(hexes, ths)
          return if hexes.length < 2
          # Usar el primer hex/th como destino
          target_hex = hexes[0].to_s.strip.upcase
          target_th  = ths[0].to_i

          @modules.each do |entry|
            entry[:pieces].each do |piece|
              src_hex = piece[:color].to_s.strip.upcase
              src_th  = piece[:thickness].to_i
              next unless hexes.map(&:upcase).include?(src_hex)
              next unless ths.map(&:to_i).include?(src_th)
              piece[:color]     = target_hex
              piece[:thickness] = target_th
            end
          end

          # Unificar color_names: usar el nombre del primer hex si existe
          target_name = color_name(target_hex)
          hexes.each do |h|
            h = h.to_s.strip.upcase
            next if h == target_hex
            existing = color_name(h)
            target_name = existing unless existing.to_s.strip.empty?
            @color_names.delete(h)
          end
          set_color_name(target_hex, target_name) unless target_name.to_s.strip.empty?
        end

        def restore_from_model(model)
          return 0 unless model

          raw = model.get_attribute(ATTRIBUTE_DICT, ATTRIBUTE_KEY)
          if raw.nil? || raw.to_s.strip.empty?
            puts 'Despiece PRO v2: sin datos guardados en despiece_pro_v2/data'
            return 0
          end

          data = parse_saved_state(raw)
          reset_state!
          @color_names = normalize_hash(data['color_names'] || {})
          @canto_config = normalize_canto_config(data['canto_config'] || {})

          modules_data = data['modules']
          unless modules_data.is_a?(Array)
            puts 'Despiece PRO: JSON guardado sin lista de modulos valida'
            return 0
          end

          uid_map = build_uid_entity_map(model)
          restored_count = 0
          modules_data.each do |entry|
            entry = normalize_hash(entry)
            uid = entry['uid'].to_s.strip
            if uid.empty?
              puts 'Despiece PRO: modulo descartado (sin uid)'
              next
            end

            pieces = deserialize_pieces(entry['pieces'])
            if pieces.empty?
              puts "Despiece PRO: modulo #{uid} descartado (sin piezas validas)"
              next
            end

            entity = uid_map[uid]
            if entity && entity.valid?
              @scanned_uids << uid unless @scanned_uids.include?(uid)
              @scanned_entities << entity unless @scanned_entities.include?(entity)
            else
              puts "Despiece PRO: uid #{uid} no encontrado en el modelo, restaurando datos igual"
            end

            module_entry = {
              name: entry['name'].to_s,
              uid: uid,
              pieces: pieces,
              piece_names: normalize_hash(entry['piece_names'] || {}),
              piece_cantos: normalize_hash(entry['piece_cantos'] || {}),
              badge_color: entry['badge_color'] || DEFAULT_BADGE_COLOR
            }
            migrate_piece_metadata!(module_entry)
            assign_missing_entity_piece_uids(entity, module_entry) if entity && entity.valid?
            @modules << module_entry
            restored_count += 1
          end

          relink_module_entities(model)

          puts "Despiece PRO: #{restored_count} modulos restaurados de #{modules_data.length}"
          restored_count
        rescue JSON::ParserError => e
          puts "Despiece PRO: error al parsear JSON guardado - #{e.message}"
          reset_state!
          0
        rescue StandardError => e
          puts "Despiece PRO: error al restaurar - #{e.class}: #{e.message}"
          reset_state!
          0
        end

        def parse_saved_state(raw)
          return raw if raw.is_a?(Hash)

          JSON.parse(raw.to_s)
        end

        def normalize_hash(value)
          return {} unless value.is_a?(Hash)

          normalized = {}
          value.each do |key, item|
            normalized[key.to_s] = item
          end
          normalized
        end

        def normalize_canto_config(value)
          return {} unless value.is_a?(Hash)

          normalized = {}
          value.each do |placa_key, slots|
            next unless slots.is_a?(Hash)

            slot_data = {}
            slots.each do |slot, fields|
              next unless fields.is_a?(Hash)

              fields = normalize_hash(fields)
              slot_data[slot.to_s] = fields
            end
            normalized[placa_key.to_s] = slot_data
          end
          normalized
        end

        def serialize_state
          modules_data = @modules.map do |entry|
            {
              'uid' => entry[:uid].to_s,
              'name' => entry[:name],
              'pieces' => entry[:pieces].map do |piece|
                {
                  'uid' => piece[:uid].to_s,
                  'count' => piece[:count],
                  'length' => piece[:length],
                  'width' => piece[:width],
                  'thickness' => piece[:thickness],
                  'color' => piece[:color] || '#FFFFFF',
                  'invertida' => piece_invertida?(piece)
                }
              end,
              'piece_names' => entry[:piece_names] || {},
              'piece_cantos' => entry[:piece_cantos] || {},
              'badge_color' => module_badge_color(entry)
            }
          end

          JSON.generate(
            'modules' => modules_data,
            'color_names' => @color_names || {},
            'canto_config' => @canto_config || {}
          )
        end

        def deserialize_pieces(pieces_data)
          return [] unless pieces_data.is_a?(Array)

          pieces_data.map do |piece|
            piece = normalize_hash(piece)
            piece_color = piece['color'].to_s.strip
            piece_color = '#FFFFFF' if piece_color.empty?
            piece_uid = piece['uid'].to_s.strip
            piece_uid = generate_piece_uid if piece_uid.empty?
            {
              uid: piece_uid,
              count: piece['count'].to_i,
              length: piece['length'].to_i,
              width: piece['width'].to_i,
              thickness: piece['thickness'].to_i,
              color: piece_color,
              invertida: piece['invertida'] == true
            }
          end
        end

        def cleanup_scan_materials(model)
          cleanup_entities(model.entities)
          mat = model.materials[SCAN_MATERIAL_NAME]
          model.materials.remove(mat) if mat
        end

        def cleanup_entities(entities)
          entities.each do |entity|
            if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
              mat = entity.material
              entity.material = nil if mat && mat.name == SCAN_MATERIAL_NAME
            end

            if entity.is_a?(Sketchup::Group)
              cleanup_entities(entity.entities)
            elsif entity.is_a?(Sketchup::ComponentInstance)
              cleanup_entities(entity.definition.entities)
            end
          end
        end

        def total_pieces
          count = 0
          @modules.each do |entry|
            entry[:pieces].each do |piece|
              count += piece[:count]
            end
          end
          count
        end

        def format_text
          return "Lista vacia.\nEscanea un modulo para comenzar." if @modules.empty?

          lines = []
          @modules.each do |entry|
            lines << "Modulo: #{entry[:name]}"
            lines << '-------------------------'
            entry[:pieces].each do |piece|
              lines << format(
                '%dx  %d x %d x %dmm',
                piece[:count],
                piece[:length],
                piece[:width],
                piece[:thickness]
              )
            end
            lines << '-------------------------'
          end
          lines << "TOTAL: #{total_pieces} piezas"
          lines.join("\n")
        end

        def format_html
          return empty_html if @modules.empty?

          @modules.map { |entry| render_module_block(entry) }.join('')
        end

        def empty_html
          '<div class="empty">Lista vacia. Escanea un modulo para comenzar.</div>'
        end

        def export_payload
          rows = []

          @modules.each do |entry|
            acronym = module_acronym(entry[:name])
            label = if acronym.empty?
                      "\u2014 #{entry[:name]} \u2014"
                    else
                      "\u2014 #{acronym} \u2014 #{entry[:name]}"
                    end

            rows << {
              'type' => 'module',
              'label' => label
            }

            entry[:pieces].each do |piece|
              piece_uid = piece[:uid].to_s
              cantos = get_piece_cantos(entry[:uid], piece_uid)
              piece_name = (entry[:piece_names] || {})[piece_uid].to_s.strip
              piece_name = export_piece_label(acronym, piece_name)

              canto_cfg = get_canto_config(piece[:thickness], piece[:color] || '#FFFFFF')
              rojo_cfg = canto_cfg['rojo'] || {}
              azul_cfg = canto_cfg['azul'] || {}

              rows << {
                'type' => 'piece',
                'espesor' => piece[:thickness],
                'cantidad' => piece[:count],
                'largo' => piece[:length],
                'ancho' => piece[:width],
                'nombre' => piece_name,
                'rota' => 1,
                'color' => piece[:color] || '#FFFFFF',
                'placa_nombre' => placa_label(piece[:thickness], piece[:color] || '#FFFFFF'),
                'canto_arr' => cantos[:arr],
                'canto_aba' => cantos[:aba],
                'canto_izq' => cantos[:izq],
                'canto_der' => cantos[:der],
                'canto_rojo_color' => color_name(rojo_cfg['color'].to_s),
                'canto_rojo_espesor' => rojo_cfg['espesor'].to_s,
                'canto_azul_color' => color_name(azul_cfg['color'].to_s),
                'canto_azul_espesor' => azul_cfg['espesor'].to_s,
                'invertida' => piece_invertida?(piece)
              }
            end
          end

          {
            'project_title' => project_export_title,
            'rows' => rows
          }
        end

        def project_export_title
          "PROYECTO: #{project_name_for_export} \u2014 #{Time.now.strftime('%d/%m/%Y')}"
        end

        def export_piece_label(acronym, piece_name)
          label = piece_name.to_s.strip
          label = 'Pieza' if label.empty?
          acronym = acronym.to_s.strip
          return label if acronym.empty?

          "#{acronym} - #{label}"
        end

        def project_name_for_export
          model = Sketchup.active_model
          return 'Sin nombre' unless model

          title = model.title.to_s.strip
          return title unless title.empty?

          path = model.path.to_s.strip
          return 'Sin nombre' if path.empty?

          File.basename(path, '.*')
        end

        def escape_html(text)
          text.to_s
              .gsub('&', '&amp;')
              .gsub('<', '&lt;')
              .gsub('>', '&gt;')
              .gsub('"', '&quot;')
        end
      end
    end

    class ExcelExporter
      @last_error = nil

      class << self
        attr_reader :last_error

        def export(formato = 'clasico')
          if Store.modules.empty?
            UI.messagebox('No hay modulos para exportar.')
            return
          end

          sin_nombre = []
          Store.modules.each do |entry|
            entry[:pieces].each do |piece|
              color = piece[:color].to_s.strip.upcase
              next if color.empty? || color == '#FFFFFF'
              next unless Store.color_name(color).to_s.strip.empty?

              sin_nombre << color unless sin_nombre.include?(color)
            end
          end

          unless sin_nombre.empty?
            UI.messagebox("Los siguientes colores no tienen nombre configurado:\n#{sin_nombre.join(', ')}\n\nConfiguralos en Info placas antes de exportar.")
            InfoDialog.show
            return
          end

          default_name = formato.to_s == 'cortecloud' ? 'despiece_cortecloud.xlsx' : 'despiece.xlsx'
          path = UI.savepanel('Guardar Excel', '', default_name)
          return unless path

          path = normalize_xlsx_path(path)

          if write_xlsx(path, formato)
            Sketchup.status_text = "Excel exportado: #{path}"
          else
            detail = last_error.to_s.strip
            detail = 'Error desconocido.' if detail.empty?
            UI.messagebox("No se pudo exportar el Excel.\n\n#{detail}")
          end
        end

        def normalize_xlsx_path(path)
          path = path.to_s
          return path if path.downcase.end_with?('.xlsx')

          path + '.xlsx'
        end

        def write_xlsx(xlsx_path, formato = 'clasico')
          @last_error = nil
          python = find_python_executable
          unless python
            @last_error = 'Python no encontrado en pythoncore-*.'
            return false
          end

          script_name = formato.to_s == 'cortecloud' ? 'export_cortecloud.py' : 'export_excel.py'
          script = File.join(PLUGIN_DIR, script_name)
          unless File.exist?(script)
            @last_error = "No se encontro el script: #{script}"
            return false
          end

          json_path = File.join(Dir.tmpdir, "despiece_pro_v2_export_#{Time.now.to_i}_#{rand(1000)}.json")
          json_content = JSON.generate(Store.export_payload)
          File.open(json_path, 'wb') do |handle|
            handle.write(json_content)
          end

          command_parts = [python, script, xlsx_path, json_path]
          command_display = command_parts.map { |part| "\"#{part}\"" }.join(' ')
          system(*command_parts)

          if File.exist?(xlsx_path) && File.size?(xlsx_path).to_i > 0
            File.delete(json_path) if File.exist?(json_path)
            true
          else
            @last_error = "Comando ejecutado:\n#{command_display}\n\nJSON enviado:\n#{json_content}"
            false
          end
        rescue StandardError => e
          @last_error = "#{e.class}: #{e.message}"
          false
        end

        def find_python_executable
          candidates = []
          candidates << Dir.glob('C:/Users/Lean/AppData/Local/Python/pythoncore-*/python.exe').first

          local_app = ENV['LOCALAPPDATA'].to_s
          unless local_app.empty?
            candidates << Dir.glob(File.join(local_app, 'Python', 'pythoncore-*', 'python.exe')).first
          end

          candidates.compact.uniq.each do |path|
            next if path.downcase.include?('windowsapps')
            return path if File.exist?(path)
          end

          nil
        end
      end
    end

    class ExtraDialog
      DIALOG_KEY = 'despiece_pro_v2_extra'.freeze

      class << self
        def show(uid, piece_uid)
          entry = Store.find_module_by_uid(uid)
          return unless entry
          piece = Store.find_piece_by_uid(entry, piece_uid)
          return unless piece
          piece_name = (entry[:piece_names] || {})[piece_uid.to_s].to_s.strip
          piece_name = 'Pieza' if piece_name.empty?
          @current_uid = uid
          @current_piece_uid = piece_uid
          cantos = Store.get_piece_cantos(uid, piece_uid)
          @dialog ||= build_dialog
          @dialog.set_html(dialog_body_html(piece, piece_name, cantos))
          @dialog.show
        end

        def build_dialog
          dialog = UI::HtmlDialog.new(
            dialog_title: 'Tapacantos',
            preferences_key: DIALOG_KEY,
            scrollable: false,
            resizable: true,
            width: 560,
            height: 480,
            style: UI::HtmlDialog::STYLE_DIALOG
          )

          dialog.add_action_callback('save_cantos') do |_context, arr, aba, izq, der|
            Store.update_piece_cantos(@current_uid, @current_piece_uid, arr, aba, izq, der)
            Store.save_to_model(Sketchup.active_model)
            ListDialog.refresh
            dialog.close
          end

          dialog.set_on_closed do
            @dialog = nil
            @current_uid = nil
            @current_piece_uid = nil
          end

          dialog
        end

        def dialog_body_html(piece, piece_name, cantos)
          html = File.read(File.join(PLUGIN_DIR, 'extra_dialog.html'))
          html.gsub('%LARGO%', piece[:length].to_s)
              .gsub('%ANCHO%', piece[:width].to_s)
              .gsub('%ESPESOR%', piece[:thickness].to_s)
              .gsub('%NOMBRE_PIEZA%', Store.escape_html(piece_name))
              .gsub('%CANTO_ARR%', cantos[:arr].to_s)
              .gsub('%CANTO_ABA%', cantos[:aba].to_s)
              .gsub('%CANTO_IZQ%', cantos[:izq].to_s)
              .gsub('%CANTO_DER%', cantos[:der].to_s)
        end
      end
    end

    class InfoDialog
      DIALOG_KEY = 'despiece_pro_v2_info'.freeze

      class << self
        def show
          @dialog ||= build_dialog
          @dialog.set_html(dialog_body_html)
          @dialog.show
        end

        def build_dialog
          dialog = UI::HtmlDialog.new(
            dialog_title: 'Info de placas',
            preferences_key: DIALOG_KEY,
            scrollable: false,
            resizable: true,
            width: 420,
            height: 480,
            style: UI::HtmlDialog::STYLE_DIALOG
          )

          dialog.add_action_callback('update_color_name') do |_context, hex, name|
            Store.set_color_name(hex, name)
            Store.save_to_model(Sketchup.active_model)
          end

          dialog.add_action_callback('update_canto_config') do |_context, th, color, slot, field, value|
            Store.set_canto_config(th, color, slot, field, value)
            Store.save_to_model(Sketchup.active_model)
          end

          dialog.add_action_callback('refresh_info') do |_context|
            InfoDialog.refresh
          end

          dialog.add_action_callback('merge_placas') do |_context, hexes_json, ths_json|
            hexes = JSON.parse(hexes_json)
            ths   = JSON.parse(ths_json)
            Store.merge_placas(hexes, ths)
            Store.save_to_model(Sketchup.active_model)
            InfoDialog.refresh
            ListDialog.refresh
          end

          dialog.set_on_closed do
            @dialog = nil
          end

          dialog
        end

        def refresh
          return unless @dialog && @dialog.visible?

          @dialog.set_html(dialog_body_html)
        end

        def dialog_body_html
          html = File.read(File.join(PLUGIN_DIR, 'info_dialog.html'))
          html.gsub('%FILAS%', render_placa_rows)
        end

        def render_placa_rows
          placas = Store.placas_list
          return '<div class="empty-placas">Sin placas detectadas.</div>' if placas.empty?

          distinct_colors = Store.distinct_colors
          similar_keys = similar_placa_keys(placas)

          placas.map do |placa|
            hex = Store.escape_html(placa[:color])
            hex_raw = placa[:color].to_s.strip.upcase
            th = placa[:thickness].to_i
            th_esc = Store.escape_html(th.to_s)
            is_white = placa[:color].to_s.upcase == '#FFFFFF'
            label = 'Placa ' + placa[:thickness].to_s + 'mm'
            count_text = placa[:piece_count].to_s + ' piezas'
            canto_config = Store.get_canto_config(placa[:thickness], placa[:color])
            row_class = similar_keys.include?([th, hex_raw]) ? 'placa-row similar' : 'placa-row'

            if is_white
              name_input = '<input type="text" class="name-input" value="Blanco" disabled data-hex="' + hex + '">'
            else
              name_value = Store.escape_html(placa[:name])
              name_input = '<input type="text" class="name-input" value="' + name_value + '" data-hex="' + hex + '" placeholder="Nombre de color">'
            end

            merge_check = '<input type="checkbox" class="merge-check" data-hex="' + hex + '" data-th="' + th_esc + '" style="display:none">'

            '<div class="' + row_class + '" data-hex="' + hex + '" data-th="' + th_esc + '">' +
              merge_check +
              '<div class="placa-main">' +
              '<div class="color-box" style="background:' + hex + ';"></div>' +
              '<div class="placa-info">' +
              '<div class="placa-label">' + Store.escape_html(label) + '</div>' +
              '<div class="placa-count">' + Store.escape_html(count_text) + '</div>' +
              '</div>' +
              '<div class="placa-name">' + name_input + '</div>' +
              '</div>' +
              render_canto_block(placa[:thickness], placa[:color], canto_config, distinct_colors) +
              '</div>'
          end.join('')
        end

        def similar_placa_keys(placas)
          keys = []
          placas.each_with_index do |p1, i|
            placas.each_with_index do |p2, j|
              next if i >= j
              next unless p1[:thickness] == p2[:thickness]
              next if p1[:color].to_s.strip.upcase == p2[:color].to_s.strip.upcase
              next unless colors_similar?(p1[:color], p2[:color])

              keys << [p1[:thickness].to_i, p1[:color].to_s.strip.upcase]
              keys << [p2[:thickness].to_i, p2[:color].to_s.strip.upcase]
            end
          end
          keys.uniq
        end

        def colors_similar?(hex1, hex2)
          r1, g1, b1 = hex_to_rgb(hex1)
          r2, g2, b2 = hex_to_rgb(hex2)
          (r1 - r2).abs < 30 && (g1 - g2).abs < 30 && (b1 - b2).abs < 30
        end

        def hex_to_rgb(hex)
          hex = hex.to_s.strip.upcase.delete('#')
          return [255, 255, 255] if hex.empty?

          if hex.length == 6
            [hex[0..1].to_i(16), hex[2..3].to_i(16), hex[4..5].to_i(16)]
          else
            [255, 255, 255]
          end
        end

        def render_canto_block(thickness, color_hex, config, distinct_colors)
          '<div class="canto-block">' +
            render_canto_line(thickness, color_hex, 'rojo', 'chip-rojo', '#ff1d1d', config, distinct_colors) +
            render_canto_line(thickness, color_hex, 'azul', 'chip-azul', '#1d35ff', config, distinct_colors) +
            '</div>'
        end

        def render_canto_line(thickness, color_hex, slot, chip_class, chip_color, config, distinct_colors)
          th_attr = Store.escape_html(thickness.to_s)
          color_attr = Store.escape_html(color_hex.to_s.upcase)
          slot_attr = Store.escape_html(slot)
          slot_cfg = config[slot] || config[slot.to_sym] || {}
          slot_cfg = Store.normalize_hash(slot_cfg) if slot_cfg.is_a?(Hash)
          color_val = slot_cfg['color'].to_s
          esp_val = slot_cfg['espesor'].to_s

          '<div class="canto-line">' +
            '<div class="canto-chip ' + chip_class + '" style="background:' + chip_color + ';"></div>' +
            render_color_dropdown(thickness, color_hex, slot, distinct_colors, color_val) +
            '<select class="canto-esp canto-select" data-th="' + th_attr + '" data-color="' + color_attr + '" data-slot="' + slot_attr + '">' +
            render_canto_espesor_options(esp_val) +
            '</select>' +
            '</div>'
        end

        def render_color_dropdown(thickness, color_hex, slot, distinct_colors, selected_hex)
          th_attr = Store.escape_html(thickness.to_s)
          color_attr = Store.escape_html(color_hex.to_s.upcase)
          slot_attr = Store.escape_html(slot)

          '<div class="cdrop" data-th="' + th_attr + '" data-color="' + color_attr + '" data-slot="' + slot_attr + '">' +
            '<div class="cdrop-selected">' + render_cdrop_selected_content(distinct_colors, selected_hex) + '</div>' +
            '<div class="cdrop-list" style="display:none">' +
            render_cdrop_options(distinct_colors) +
            '</div>' +
            '</div>'
        end

        def render_cdrop_selected_content(_distinct_colors, selected_hex)
          selected_hex = selected_hex.to_s.strip.upcase
          return '<span>Seleccionar...</span>' if selected_hex.empty?

          name = Store.color_name(selected_hex)
          label = name.empty? ? selected_hex : name
          hex_esc = Store.escape_html(selected_hex)
          '<span class="cdrop-chip" style="background:' + hex_esc + ';"></span><span>' + Store.escape_html(label) + '</span>'
        end

        def render_cdrop_options(distinct_colors)
          distinct_colors.map do |color_hex|
            name = Store.color_name(color_hex)
            label = name.empty? ? color_hex : name
            hex_esc = Store.escape_html(color_hex)
            '<div class="cdrop-opt" data-value="' + hex_esc + '">' +
              '<span class="cdrop-chip" style="background:' + hex_esc + ';"></span>' +
              '<span>' + Store.escape_html(label) + '</span>' +
              '</div>'
          end.join('')
        end

        def render_canto_espesor_options(selected)
          selected = selected.to_s.strip
          [
            ['', 'Seleccionar...'],
            ['0.45', '0.45mm'],
            ['2', '2mm']
          ].map do |val, label|
            sel = val == selected ? ' selected' : ''
            '<option value="' + Store.escape_html(val) + '"' + sel + '>' + Store.escape_html(label) + '</option>'
          end.join('')
        end
      end
    end

    class ListDialog
      DIALOG_KEY = 'despiece_pro_v2_list'.freeze

      class << self
        def toggle
          if @dialog && @dialog.visible?
            @dialog.close
          else
            show
          end
        end

        def refresh
          return unless @dialog && @dialog.visible?

          apply_list_html
        end

        def refresh_all
          return unless @dialog && @dialog.visible?

          report = Store.refresh_all_modules
          apply_list_html
          show_refresh_report(report)
        end

        def show_refresh_report(report)
          added   = report[:added]   || []
          removed = report[:removed] || []
          changed = report[:changed] || []
          skipped = report[:skipped] || []

          return if added.empty? && removed.empty? && changed.empty? && skipped.empty?

          lines = []

          unless skipped.empty?
            lines << "MODULOS SIN ACTUALIZAR (#{skipped.length}):"
            skipped.each do |item|
              lines << "  ! #{item[:module_name]}: #{item[:reason]}"
            end
          end

          unless added.empty?
            lines << "PIEZAS AGREGADAS (#{added.length}):"
            added.each do |item|
              dim = item[:piece] ? "#{item[:piece][:length]}x#{item[:piece][:width]}x#{item[:piece][:thickness]}mm" : ''
              name = item[:name].empty? ? dim : "#{item[:name]} (#{dim})"
              lines << "  + #{item[:module_name]}: #{name}"
            end
          end

          unless removed.empty?
            lines << '' unless lines.empty?
            lines << "PIEZAS ELIMINADAS (#{removed.length}):"
            removed.each do |item|
              if item[:piece]
                dim = "#{item[:piece][:length]}x#{item[:piece][:width]}x#{item[:piece][:thickness]}mm"
                name = item[:name].empty? ? dim : "#{item[:name]} (#{dim})"
                lines << "  - #{item[:module_name]}: #{name}"
              else
                lines << "  - #{item[:module_name]}: #{item[:reason]}"
              end
            end
          end

          unless changed.empty?
            lines << '' unless lines.empty?
            lines << "CANTIDAD CAMBIADA (#{changed.length}):"
            changed.each do |item|
              dim = "#{item[:old][:length]}x#{item[:old][:width]}x#{item[:old][:thickness]}mm"
              name = item[:name].empty? ? dim : "#{item[:name]} (#{dim})"
              lines << "  ~ #{item[:module_name]}: #{name} #{item[:old][:count]}x → #{item[:new][:count]}x"
            end
          end

          UI.messagebox(lines.join("\n"))
        end

        def show
          restored = Store.restore_from_model(Sketchup.active_model)
          @dialog ||= build_dialog
          apply_list_html
          @dialog.show
          Sketchup.status_text = "Despiece PRO v2: #{restored} modulos restaurados" if restored > 0
        end

        def apply_list_html
          if @dialog && @dialog.visible?
            begin
              @dialog.execute_script(
                "window.__scrollTop = document.getElementById('app') ? document.getElementById('app').scrollTop : 0;"
              )
            rescue StandardError
              nil
            end
          end
          @dialog.set_html(dialog_body_html)
          if @dialog && @dialog.visible?
            begin
              @dialog.execute_script(
                "var app = document.getElementById('app');" \
                "if(app && window.__scrollTop){ app.scrollTop = window.__scrollTop; }"
              )
            rescue StandardError
              nil
            end
          end
        end

        def build_dialog
          dialog = UI::HtmlDialog.new(
            dialog_title: 'Despiece PRO v2 - Lista de piezas',
            preferences_key: DIALOG_KEY,
            scrollable: true,
            resizable: true,
            width: 460,
            height: 520,
            style: UI::HtmlDialog::STYLE_DIALOG
          )

          dialog.add_action_callback('clear_list') do |_context|
            Store.clear!
            refresh
          end

          dialog.add_action_callback('update_module_name') do |_context, entity_id, name|
            Store.update_module_name(entity_id, name)
            entry = Store.find_module_by_uid(entity_id)
            next unless entry

            acronym = Store.module_acronym(entry[:name])
            begin
              @dialog.execute_script(
                "var mEl = document.querySelector('.module[data-entity-id=\"' + #{entity_id.to_s.inspect} + '\"]');" \
                "if(mEl){" \
                "  var codeEl = mEl.querySelector('.module-code');" \
                "  if(codeEl){ codeEl.textContent = #{acronym.inspect}; }" \
                "  var badges = mEl.querySelectorAll('.badge');" \
                "  for(var i=0;i<badges.length;i++){ badges[i].textContent = #{acronym.inspect}; }" \
                "}"
              )
            rescue StandardError
              nil
            end
          end

          dialog.add_action_callback('update_piece_name') do |_context, entity_id, piece_uid, name|
            Store.update_piece_name(entity_id, piece_uid, name)
          end

          dialog.add_action_callback('toggle_invertida') do |_context, uid, piece_uid|
            Store.toggle_piece_invertida(uid, piece_uid)
            refresh
          end

          dialog.add_action_callback('update_module_badge_color') do |_context, entity_id, color|
            Store.update_module_badge_color(entity_id, color)
          end

          dialog.add_action_callback('set_module_open') do |_context, entity_id, open|
            Store.set_module_open(entity_id, open == '1')
          end

          dialog.add_action_callback('refresh_list') do |_context|
            refresh
          end

          dialog.add_action_callback('refresh_all') do |_context|
            refresh_all
          end

          dialog.add_action_callback('remove_module') do |_context, entity_id|
            Store.remove_module(entity_id)
            refresh
          end

          dialog.add_action_callback('export_excel') do |_context, formato|
            formato = formato.to_s.strip
            formato = 'clasico' if formato.empty?
            ExcelExporter.export(formato)
          end

          dialog.add_action_callback('save_state') do |_context|
            Store.save_to_model(Sketchup.active_model)
          end

          dialog.add_action_callback('open_extra') do |_context, uid, piece_uid|
            ExtraDialog.show(uid, piece_uid)
          end

          dialog.add_action_callback('open_info') do |_context|
            InfoDialog.show
          end

          dialog.set_on_closed do
            @dialog = nil
          end

          dialog
        end

        def dialog_body_html
          html = File.read(File.join(PLUGIN_DIR, 'dialog.html'))
          html.gsub('%CONTENT%', Store.format_html)
              .gsub('%TOTAL%', Store.total_pieces.to_s)
        end
      end
    end

    class ScanModuleTool
      HIGHLIGHT_COLOR = Sketchup::Color.new(0, 220, 100)
      BOX_EDGES = [
        [0, 1], [1, 3], [3, 2], [2, 0],
        [4, 5], [5, 7], [7, 6], [6, 4],
        [0, 4], [1, 5], [2, 6], [3, 7]
      ].freeze

      def activate
        Sketchup.status_text = 'Click en un grupo/modulo que contenga piezas MDF'
        view = Sketchup.active_model.active_view
        view.invalidate if view
      end

      def deactivate(_view)
        Sketchup.status_text = ''
      end

      def draw(view)
        view.line_width = 3
        view.drawing_color = HIGHLIGHT_COLOR

        Store.scanned_entities.each do |entity|
          next unless entity.valid?

          bounds = entity.bounds
          next if bounds.empty?

          corners = (0..7).map { |i| bounds.corner(i) }
          BOX_EDGES.each do |a, b|
            view.draw(GL_LINES, corners[a], corners[b])
          end
        end
      end

      def onCancel(_reason, _view)
        Sketchup.active_model.select_tool(nil)
      end

      def onLButtonDown(_flags, x, y, view)
        model = Sketchup.active_model
        result = model.raytest(view.pickray(x, y))

        unless result
          UI.messagebox('No se encontro ningun grupo o componente')
          return
        end

        _hit_point, path = result
        entity = find_module_entity(path)

        unless entity
          UI.messagebox('Selecciona un grupo o componente (modulo MDF)')
          return
        end

        existing_uid = Store.entity_uid(entity)
        if !existing_uid.empty? && Store.scanned?(existing_uid)
          Sketchup.status_text = 'Este modulo ya fue escaneado'
          return
        end

        pieces = collect_pieces(entity)
        if pieces.empty?
          UI.messagebox('El grupo seleccionado no contiene subgrupos MDF')
          return
        end

        grouped = group_pieces_by_dimensions(pieces)
        if grouped.empty?
          UI.messagebox('No se pudieron obtener dimensiones validas de las piezas')
          return
        end

        module_name = entity.name.to_s.strip
        module_name = 'Grupo sin nombre' if module_name.empty?

        module_uid = Store.assign_module_uid(entity)
        Store.mark_scanned(entity, module_uid)
        Store.add_module(module_name, grouped, module_uid)
        ListDialog.refresh
        view.invalidate

        total = 0
        grouped.each { |piece| total += piece[:count] }
        Sketchup.status_text = "Modulo escaneado: #{module_name} - #{total} piezas agregadas a la lista"
      end

      def find_module_entity(path)
        candidates = path.select do |item|
          item.is_a?(Sketchup::Group) || item.is_a?(Sketchup::ComponentInstance)
        end

        candidates.find { |item| module_container?(item) } || candidates.last
      end

      def module_container?(entity)
        child_container(entity).any? do |child|
          child.is_a?(Sketchup::Group) || child.is_a?(Sketchup::ComponentInstance)
        end
      end

      def collect_pieces(entity)
        unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          return []
        end

        pieces = []
        direct_children = direct_mdf_children(child_container(entity))

        direct_children.each do |child|
          pieces << child if piece_entity?(child)
        end

        containers = direct_children.select { |child| container_entity?(child) }
        sort_containers_for_scan(containers).each do |child|
          pieces.concat(collect_pieces(child))
        end

        pieces
      end

      def child_container(entity)
        entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      end

      def direct_mdf_children(container)
        children = []
        container.each do |child|
          next unless child.is_a?(Sketchup::Group) || child.is_a?(Sketchup::ComponentInstance)

          children << child
        end
        children
      end

      def entity_children(entity)
        child_container(entity)
      end

      def piece_entity?(entity)
        entity_has_faces?(entity)
      end

      def container_entity?(entity)
        !entity_has_faces?(entity) && entity_has_subgroups?(entity)
      end

      def entity_has_subgroups?(entity)
        entity_children(entity).any? do |child|
          child.is_a?(Sketchup::Group) || child.is_a?(Sketchup::ComponentInstance)
        end
      end

      def entity_has_faces?(entity)
        entity_children(entity).any? { |child| child.is_a?(Sketchup::Face) }
      end

      def sort_containers_for_scan(containers)
        indexed = containers.each_with_index.map { |container, index| [container, index] }
        indexed.sort do |(left, left_index), (right, right_index)|
          left_priority = container_scan_priority(left)
          right_priority = container_scan_priority(right)
          if left_priority == right_priority
            left_index <=> right_index
          else
            left_priority <=> right_priority
          end
        end.map(&:first)
      end

      def container_scan_priority(container)
        return 0 if structure_container?(container)
        return 1 if container_name_priority(container) <= 1

        2
      end

      def structure_container?(container)
        child_groups = []
        entity_children(container).each do |child|
          child_groups << child if child.is_a?(Sketchup::Group) || child.is_a?(Sketchup::ComponentInstance)
        end
        return false if child_groups.empty?

        child_groups.all? { |child| piece_entity?(child) }
      end

      def container_name_priority(container)
        name = container.name.to_s.downcase
        return 0 if name.include?('estructura') || name.include?('estruct') || name.include?('cuerpo')
        return 2 if name.include?('cajon') || name.include?('caj')

        1
      end

      def group_pieces_by_dimensions(pieces)
        groups = {}
        order = []

        pieces.each do |piece|
          begin
            dims = DimHelpers.piece_dimensions_mm(piece)
            color_hex = DimHelpers.piece_color_hex(piece)
            sorted_dims = [dims[:length], dims[:width], dims[:thickness]].sort { |a, b| b <=> a }
            key = sorted_dims + [color_hex]
            unless groups.key?(key)
              groups[key] = { entities: [] }
              order << key
            end
            groups[key][:entities] << piece
          rescue ArgumentError
            next
          end
        end

        order.map do |(length, width, thickness, color_hex)|
          key = [length, width, thickness, color_hex]
          entities = groups[key][:entities]
          piece_uid = Store.unify_group_piece_uid(entities)
          {
            uid: piece_uid,
            count: entities.length,
            length: length,
            width: width,
            thickness: thickness,
            color: color_hex,
            invertida: false
          }
        end
      end
    end

    unless file_loaded?(__FILE__)
      toolbar = UI::Toolbar.new('Despiece PRO v2')
      menu = UI.menu('Extensions').add_submenu('Despiece PRO v2')

      cmd_scan = UI::Command.new('Escanear Modulo') do
        Sketchup.active_model.select_tool(BiraEstudio::DespieceProV2::ScanModuleTool.new)
      end
      cmd_scan.small_icon = File.join(PLUGIN_DIR, 'icons', 'scan_small.png')
      cmd_scan.large_icon = File.join(PLUGIN_DIR, 'icons', 'scan_large.png')
      cmd_scan.tooltip = 'Escanear Modulo MDF'
      cmd_scan.status_bar_text = 'Click en un grupo que contenga piezas MDF para agregarlas a la lista'
      cmd_scan.menu_text = 'Escanear Modulo'
      toolbar.add_item(cmd_scan)
      menu.add_item(cmd_scan)

      cmd_list = UI::Command.new('Ver Lista') do
        BiraEstudio::DespieceProV2::ListDialog.toggle
      end
      cmd_list.small_icon = File.join(PLUGIN_DIR, 'icons', 'list_small.png')
      cmd_list.large_icon = File.join(PLUGIN_DIR, 'icons', 'list_large.png')
      cmd_list.tooltip = 'Ver Lista de piezas'
      cmd_list.status_bar_text = 'Abre o cierra la ventana con la lista acumulada de piezas'
      cmd_list.menu_text = 'Ver Lista'
      toolbar.add_item(cmd_list)
      menu.add_item(cmd_list)

      if toolbar.get_last_state == TB_HIDDEN
        toolbar.show
      else
        toolbar.restore
      end
      Store.restore_from_model(Sketchup.active_model)
      file_loaded(__FILE__)
    end
  end
end
```

### `despiece_pro_v2/dialog.html`

```html
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<title>Despiece PRO</title>

<style>

html,
body{
    margin:0;
    padding:0;
    width:100%;
    height:100%;
    background:#1a2a4a;
    font-family:"Segoe UI", Arial, sans-serif;
    color:#eef3ff;
    overflow:hidden;
}

#app{
    width:100%;
    height:100%;
    background:#1a2a4a;
    border:1px solid rgba(255,255,255,.12);
    border-radius:12px;
    overflow:auto;
    box-sizing:border-box;
}

.top-bar {
  display: flex;
  gap: 8px;
  padding: 10px 10px 0 10px;
}
.top-bar-btn {
  flex: 1;
  padding: 8px;
  background: rgba(255,255,255,0.08);
  border: 1px solid rgba(255,255,255,0.15);
  border-radius: 6px;
  color: #eef3ff;
  font-size: 13px;
  cursor: pointer;
  text-align: center;
}
.top-bar-btn:hover {
  background: rgba(255,255,255,0.14);
}

/* ==========================================
   MÓDULOS
========================================== */

.module{
    margin:8px 10px;
    margin-bottom:10px;
    border:1px solid rgba(255,255,255,.08);
    border-radius:8px;
    overflow:hidden;
}

.module:first-child{
    border-top:none;
}

.module-header{
    display:flex;
    align-items:center;
    padding:8px 12px;
    min-height:34px;
    cursor:pointer;
}

.module-body{
    display:none;
}

.module.open .module-body{
    display:block;
}

.module-header-left{
    display:flex;
    align-items:center;
    flex:1;
    min-width:0;
}

.module-code{
    font-size:16px;
    font-weight:700;
    line-height:1;
}

.module-separator{
    margin:0 14px;
    color:rgba(255,255,255,.85);
    font-size:18px;
}

.module-name{
    flex:1;
    font-size:14px;
    font-weight:500;
    color:#eef3ff;
    min-width:0;
    overflow:hidden;
    text-overflow:ellipsis;
    white-space:nowrap;
}

.module-pieces-row{
    display:flex;
    align-items:center;
    justify-content:space-between;
    padding:0 12px 6px 12px;
}

.module-pieces{
    color:#ffd54a;
    font-size:15px;
    font-weight:600;
    white-space:nowrap;
}

.delete-btn{
    border:none;
    background:none;
    color:#dbe4f2;
    cursor:pointer;
    font-size:16px;
    padding:0;
    line-height:1;
}

.delete-btn:hover{
    color:#ffffff;
}

.edit-btn{
    border:none;
    background:none;
    color:#ffffff;
    font-size:16px;
    cursor:pointer;
    padding:0;
    width:20px;
    height:20px;
    line-height:20px;
    text-align:center;
    flex-shrink:0;
    margin-left:auto;
}

.edit-btn:hover{
    opacity:.9;
}

/* ==========================================
   FILAS
========================================== */

.piece-row{
    display:flex;
    align-items:center;
    gap:12px;
    padding:6px 12px;
    border-top:1px solid rgba(255,255,255,.08);
    white-space:nowrap;
}

.color-chip{
    width:14px;
    height:14px;
    border:1px solid rgba(255,255,255,.35);
    border-radius:3px;
    flex-shrink:0;
    box-sizing:border-box;
    margin-right:10px;
}

.qty{
    font-family:Consolas, monospace;
    font-size:14px;
    font-weight:500;
    width:34px;
    flex-shrink:0;
}

.dimensions{
    font-family:Consolas, monospace;
    font-size:14px;
    font-weight:500;
    color:#f1f4fa;
    width:clamp(150px, 42vw, 230px);
    flex-shrink:1;
}

.badge{
    display:inline-block;
    min-width:28px;
    text-align:center;
    padding:1px 5px;
    margin-left:12px;
    margin-right:12px;
    border-radius:4px;
    border:1px solid currentColor;
    font-size:10px;
    font-weight:600;
    background:rgba(255,255,255,.02);
}

.piece-name{
    color:#dbe4f2;
    font-size:13px;
    font-weight:400;
    min-width:0;
    overflow:hidden;
    text-overflow:ellipsis;
}

.extra-btn{
    margin-left:auto;
    flex-shrink:0;
    cursor:pointer;
}
.invert-btn{
    flex-shrink:0;
    width:22px;
    height:22px;
    margin-left:8px;
    padding:0;
    border:1px solid rgba(255,255,255,.28);
    border-radius:4px;
    background:rgba(255,255,255,.06);
    color:#d8c4cf;
    font-size:13px;
    line-height:20px;
    text-align:center;
    cursor:pointer;
}
.invert-btn:hover{
    background:rgba(255,255,255,.12);
    color:#fff;
}
.invert-btn.is-active{
    border-color:#B05CFF;
    background:rgba(176,92,255,.22);
    color:#FF8A3D;
}
.canto-preview{
    width:18px;
    height:18px;
    box-sizing:border-box;
    border-style:solid;
    border-width:3px;
    background:rgba(255,255,255,.06);
    margin-left:6px;
}
.canto-preview:hover{
    background:rgba(255,255,255,.14);
}

/* ==========================================
   EDICIÓN
========================================== */

.module.editing .module-name,
.module.editing .piece-name{
    background:rgba(255,255,255,.08);
    border-radius:4px;
    padding:2px 6px;
}

[contenteditable="true"]{
    outline:none;
}

/* ==========================================
   FOOTER
========================================== */

.footer{
    display:flex;
    justify-content:space-between;
    align-items:center;

    padding:10px 14px;

    border-top:1px solid rgba(255,255,255,.08);
}

.total{
    color:#ffd54a;
    font-size:14px;
    font-weight:600;
}

.footer-actions{
    display:flex;
    flex-direction:column;
    align-items:flex-end;
    gap:6px;
}

.export-btn{
    background:none;
    border:1px solid rgba(255,255,255,.25);
    color:#dbe4f2;
    cursor:pointer;
    font-size:13px;
    padding:4px 10px;
    border-radius:4px;
}

.export-btn:hover{
    color:#ffffff;
    border-color:rgba(255,255,255,.45);
}


@media (max-width:520px){
    .module{
        margin:6px 8px;
    }

    .module-header{
        padding:7px 10px;
    }

    .piece-row{
        gap:8px;
        padding:5px 10px;
    }

    .qty{
        width:28px;
        font-size:13px;
    }

    .dimensions{
        width:clamp(135px, 45vw, 190px);
        font-size:13px;
    }

    .badge{
        min-width:24px;
        padding:1px 4px;
        margin-left:8px;
        margin-right:8px;
        font-size:9px;
    }

    .piece-name{
        font-size:12px;
    }

    .footer{
        padding:9px 12px;
    }
}

</style>
</head>

<body>

<div id="app">

    <div class="top-bar">
      <button class="top-bar-btn" onclick="refreshAll();">🔄 Refresh</button>
      <button class="top-bar-btn" onclick="openInfo();">ℹ Info Placas</button>
    </div>

    %CONTENT%

    <div class="footer">
        <div class="total">
            TOTAL: %TOTAL% piezas
        </div>
        <div class="footer-actions">
            <button class="export-btn" onclick="exportExcel('clasico');">
                📊 Exportar Excel
            </button>
            <button class="export-btn" onclick="exportExcel('cortecloud');">
                ☁️ Exportar CorteCloud
            </button>
            <button class="export-btn" onclick="saveState();">
                💾 Guardar
            </button>
        </div>
    </div>

</div>

<script>

(function(){

    var app = document.getElementById('app');

    if(app){
        var savedScroll = window.__scrollTop || 0;
        if(savedScroll > 0){
            app.scrollTop = savedScroll;
        }
        app.addEventListener('scroll', function(){
            window.__scrollTop = app.scrollTop;
        });
    }

    function findParentByClass(el, className){
        while(el && el !== document.body){
            if(el.classList && el.classList.contains(className)){
                return el;
            }
            el = el.parentNode;
        }
        return null;
    }


    function bindClearDefaultText(module){

        var names =
            module.querySelectorAll('.module-name');

        for(var i=0;i<names.length;i++){

            names[i].onfocus = function(){

                var editing =
                    module.getAttribute('data-editing') === 'true';

                if(!editing){
                    return;
                }

                var text = trim(this.innerText).toLowerCase();

                if(
                    text === 'grupo sin nombre' ||
                    text === 'grupo sin nombre.' ||
                    text === 'sin nombre'
                ){
                    this.innerText = '';
                }
            };
        }
    }

    function enableEdit(module){

        module.setAttribute('data-editing','true');
        module.className += ' editing';

        var moduleName =
            module.querySelector('.module-name');

        if(moduleName){

            moduleName.contentEditable = true;
            moduleName.focus();

            var t = trim(moduleName.innerText).toLowerCase();

            if(
                t === 'grupo sin nombre' ||
                t === 'grupo sin nombre.' ||
                t === 'sin nombre'
            ){
                moduleName.innerText = '';
            }
        }

        var pieces =
            module.querySelectorAll('.piece-name');

        for(var i=0;i<pieces.length;i++){

            pieces[i].contentEditable = true;
        }
    }

    function disableEdit(module){

        module.setAttribute('data-editing','false');

        module.className =
            module.className.replace(' editing','');

        var moduleName =
            module.querySelector('.module-name');

        if(moduleName){

            moduleName.contentEditable = false;
        }

        var pieces =
            module.querySelectorAll('.piece-name');

        for(var i=0;i<pieces.length;i++){

            pieces[i].contentEditable = false;
        }
    }

    function saveModuleNameToStore(module){

        var entityId =
            module.getAttribute('data-entity-id');

        var moduleName =
            module.querySelector('.module-name');

        if(
            window.sketchup &&
            sketchup.update_module_name &&
            moduleName
        ){
            sketchup.update_module_name(
                entityId,
                trim(moduleName.innerText)
            );
        }
    }

    function savePieceNameToStore(module, row){

        var entityId =
            module.getAttribute('data-entity-id');

        var pieceUid =
            row.getAttribute('data-piece-uid');

        var pieceName =
            row.querySelector('.piece-name');

        if(
            window.sketchup &&
            sketchup.update_piece_name &&
            pieceName
        ){
            sketchup.update_piece_name(
                entityId,
                pieceUid,
                trim(pieceName.innerText)
            );
        }
    }

    function flushModuleToStore(module){

        saveModuleNameToStore(module);

        var rows =
            module.querySelectorAll('.piece-row');

        for(var i=0;i<rows.length;i++){
            savePieceNameToStore(module, rows[i]);
        }
    }

    function flushAllEditingModules(){

        var modules =
            document.querySelectorAll('.module[data-editing="true"]');

        for(var i=0;i<modules.length;i++){
            flushModuleToStore(modules[i]);
        }
    }

    function bindAutoSave(module){

        var moduleName =
            module.querySelector('.module-name');

        if(moduleName){

            moduleName.onblur = function(){

                if(module.getAttribute('data-editing') !== 'true'){
                    return;
                }

                saveModuleNameToStore(module);
            };
        }

        var rows =
            module.querySelectorAll('.piece-row');

        for(var i=0;i<rows.length;i++){

            (function(row){

                var pieceName =
                    row.querySelector('.piece-name');

                if(!pieceName){
                    return;
                }

                pieceName.onblur = function(){

                    if(module.getAttribute('data-editing') !== 'true'){
                        return;
                    }

                    savePieceNameToStore(module, row);
                };

            })(rows[i]);
        }
    }

    function closeEditingModule(module){

        flushModuleToStore(module);
        disableEdit(module);

        var btn =
            module.querySelector('.edit-btn');

        if(btn){
            btn.innerHTML = '&#9998;';
        }

        if(window.sketchup && sketchup.refresh_list){
            sketchup.refresh_list();
        }
    }

    function closeOtherEditingModules(currentModule){

        var modules =
            document.querySelectorAll('.module[data-editing="true"]');

        for(var i=0;i<modules.length;i++){

            if(modules[i] !== currentModule){
                closeEditingModule(modules[i]);
            }
        }
    }

    function trim(str){

        return String(str)
            .replace(/^\s+/,'')
            .replace(/\s+$/,'');
    }

    window.clearList = function(){

        if(
            window.sketchup &&
            sketchup.clear_list
        ){
            sketchup.clear_list();
        }
    };

    window.exportExcel = function(formato){

        flushAllEditingModules();

        formato = formato || 'clasico';

        if(
            window.sketchup &&
            sketchup.export_excel
        ){
            sketchup.export_excel(formato);
        }
    };

    window.saveState = function(){

        flushAllEditingModules();

        if(
            window.sketchup &&
            sketchup.save_state
        ){
            sketchup.save_state();
        }
    };

    window.openInfo = function(){
        if(window.sketchup && sketchup.open_info){
            sketchup.open_info();
        }
    };

    window.refreshAll = function(){
        if(window.sketchup && sketchup.refresh_all){
            sketchup.refresh_all();
        }
    };

    document.addEventListener('click', function(e){

        var invertBtn = findParentByClass(e.target, 'invert-btn');

        if(invertBtn){

            var uidInv =
                invertBtn.getAttribute('data-uid');

            var pieceUidInv =
                invertBtn.getAttribute('data-piece-uid');

            if(
                window.sketchup &&
                sketchup.toggle_invertida
            ){
                sketchup.toggle_invertida(uidInv, pieceUidInv);
            }

            return;
        }

        var extraBtn = findParentByClass(e.target, 'extra-btn');

        if(extraBtn){

            var uid =
                extraBtn.getAttribute('data-uid');

            var pieceUid =
                extraBtn.getAttribute('data-piece-uid');

            if(
                window.sketchup &&
                sketchup.open_extra
            ){
                sketchup.open_extra(uid, pieceUid);
            }

            return;
        }

        var deleteBtn = findParentByClass(e.target, 'delete-btn');

        if(deleteBtn){

            var moduleEl = findParentByClass(deleteBtn, 'module');

            if(!moduleEl){
                return;
            }

            var entityId =
                moduleEl.getAttribute('data-entity-id');

            if(!confirm('¿Eliminar este módulo?')){
                return;
            }

            flushAllEditingModules();

            if(
                window.sketchup &&
                sketchup.remove_module
            ){
                sketchup.remove_module(entityId);
            }

            return;
        }

        var btn = findParentByClass(e.target, 'edit-btn');

        if(!btn){
            return;
        }

        var module = findParentByClass(btn, 'module');

        if(!module){
            return;
        }

        var editing =
            module.getAttribute('data-editing') === 'true';

        if(editing){

            closeEditingModule(module);

        }else{

            closeOtherEditingModules(module);
            bindClearDefaultText(module);
            bindAutoSave(module);
            enableEdit(module);
            btn.innerHTML = '✓';

        }

    }, false);

    var moduleHeaders = document.querySelectorAll('.module-header');
    var h;
    for(h = 0; h < moduleHeaders.length; h++){
        (function(header){
            header.addEventListener('click', function(e){
                var target = e.target;
                while(target && target !== header){
                    if(target.classList && target.classList.contains('edit-btn')){
                        return;
                    }
                    target = target.parentNode;
                }
                var module = findParentByClass(header, 'module');
                if(module){
                    module.classList.toggle('open');
                    var isOpen = module.classList.contains('open');
                    if(window.sketchup && sketchup.set_module_open){
                        sketchup.set_module_open(module.getAttribute('data-entity-id'), isOpen ? '1' : '0');
                    }
                }
            });
        })(moduleHeaders[h]);
    }

})();

</script>

</body>
</html>
```

### `despiece_pro_v2/export_excel.py`

```python
# -*- coding: utf-8 -*-
import json
import sys

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill

HEADERS = [
    'cantidad',
    'LARGO',
    'ANCHO',
    'nombre',
    'rota',
    'canto_arr',
    'canto_aba',
    'canto_izq',
    'canto_der',
]

COLOR_HEADER_BG = '2F4F7F'
COLOR_HEADER_FG = 'FFFFFF'
COLOR_MODULE_BG = '4A7C9E'
COLOR_MODULE_FG = 'FFFFFF'
COLOR_ROW_ALT = 'EEF2F7'
COLOR_WHITE = 'FFFFFF'


def solid_fill(color):
    return PatternFill(fill_type='solid', fgColor=color)


def load_payload(json_path):
    with open(json_path, encoding='utf-8-sig') as handle:
        return json.load(handle)


def group_modules(rows):
    modules = []
    current_module = None
    current_pieces = []

    for item in rows:
        row_type = item.get('type')
        if row_type == 'module':
            if current_module is not None:
                modules.append((current_module, current_pieces))
            current_module = item.get('label', '')
            current_pieces = []
        elif row_type == 'piece':
            current_pieces.append(item)

    if current_module is not None:
        modules.append((current_module, current_pieces))

    return modules


def piece_placa(piece):
    placa = piece.get('placa_nombre')
    if placa:
        return placa
    espesor = piece.get('espesor', 0)
    return f'{int(espesor)}mm Blanco'


def placa_sort_key(placa_nombre):
    parts = placa_nombre.split(' ', 1)
    th_str = parts[0] if parts else '0mm'
    rest = parts[1] if len(parts) > 1 else ''
    th_num = 0
    if th_str.endswith('mm'):
        try:
            th_num = int(th_str[:-2])
        except ValueError:
            th_num = 0
    return (-th_num, rest.lower())


def collect_placas(modules):
    placas = set()
    for _, pieces in modules:
        for piece in pieces:
            placas.add(piece_placa(piece))
    return sorted(placas, key=placa_sort_key)


def sanitize_sheet_name(name):
    forbidden = ':\\/?*[]'
    result = name
    for ch in forbidden:
        result = result.replace(ch, ' ')
    if len(result) > 31:
        result = result[:31]
    return result


def write_header_row(sheet, row_index):
    fill = solid_fill(COLOR_HEADER_BG)
    font = Font(bold=True, color=COLOR_HEADER_FG)

    for column_index, header in enumerate(HEADERS, start=1):
        cell = sheet.cell(row=row_index, column=column_index, value=header)
        cell.font = font
        cell.fill = fill
        cell.alignment = Alignment(horizontal='center')


def write_module_row(sheet, row_index, label):
    fill = solid_fill(COLOR_MODULE_BG)
    font = Font(bold=True, color=COLOR_MODULE_FG)

    for column_index in range(1, len(HEADERS) + 1):
        cell = sheet.cell(row=row_index, column=column_index)
        cell.fill = fill
        if column_index == 1:
            cell.value = label
            cell.font = font

    sheet.merge_cells(
        start_row=row_index,
        start_column=1,
        end_row=row_index,
        end_column=len(HEADERS),
    )


def write_piece_row(sheet, row_index, item, use_alt_fill):
    values = [
        item['cantidad'],
        item['largo'],
        item['ancho'],
        item['nombre'],
        item.get('rota', 1),
        item.get('canto_arr', 0),
        item.get('canto_aba', 0),
        item.get('canto_izq', 0),
        item.get('canto_der', 0),
    ]
    fill_color = COLOR_ROW_ALT if use_alt_fill else COLOR_WHITE
    fill = solid_fill(fill_color)

    for column_index, value in enumerate(values, start=1):
        cell = sheet.cell(row=row_index, column=column_index, value=value)
        cell.fill = fill


def write_total_row(sheet, row_index, label):
    cell = sheet.cell(row=row_index, column=1, value=label)
    cell.font = Font(bold=True)


def adjust_column_widths(sheet):
    for column_index, header in enumerate(HEADERS, start=1):
        width = max(len(header) + 2, 12)
        column_letter = sheet.cell(row=2, column=column_index).column_letter
        sheet.column_dimensions[column_letter].width = width


def write_sheet(workbook, sheet_name, project_title, modules, placa_nombre):
    sheet = workbook.create_sheet(title=sheet_name)

    row_index = 1
    title_cell = sheet.cell(row=row_index, column=1, value=project_title)
    title_cell.font = Font(bold=True)
    sheet.merge_cells(
        start_row=row_index,
        start_column=1,
        end_row=row_index,
        end_column=len(HEADERS),
    )
    row_index += 1

    write_header_row(sheet, row_index)
    row_index += 1

    total_count = 0
    for module_label, pieces in modules:
        filtered_pieces = [
            piece for piece in pieces if piece_placa(piece) == placa_nombre
        ]
        if not filtered_pieces:
            continue

        write_module_row(sheet, row_index, module_label)
        row_index += 1

        use_alt_fill = False
        for piece in filtered_pieces:
            write_piece_row(sheet, row_index, piece, use_alt_fill)
            total_count += piece.get('cantidad', 0)
            use_alt_fill = not use_alt_fill
            row_index += 1

    write_total_row(sheet, row_index, f'TOTAL DE PIEZAS: {total_count}')
    adjust_column_widths(sheet)


def write_xlsx(output_path, payload):
    project_title = payload.get('project_title', 'PROYECTO: Sin nombre')
    modules = group_modules(payload.get('rows', []))
    placas = collect_placas(modules)

    if not placas:
        placas = ['0mm Blanco']

    workbook = Workbook()
    workbook.remove(workbook.active)

    for placa_nombre in placas:
        write_sheet(
            workbook,
            sanitize_sheet_name(placa_nombre),
            project_title,
            modules,
            placa_nombre,
        )

    workbook.save(output_path)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write('Uso: export_excel.py salida.xlsx datos.json\n')
        sys.exit(1)

    output_path = sys.argv[1]
    json_path = sys.argv[2]
    payload = load_payload(json_path)
    write_xlsx(output_path, payload)


if __name__ == '__main__':
    main()
```

### `despiece_pro_v2/export_cortecloud.py`

```python
# -*- coding: utf-8 -*-
import json
import sys

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill

HEADERS = [
    'Cantidad',
    'Largo',
    'Ancho',
    'Función',
    'Tapacanto L1',
    'Tapacanto L2',
    'Tapacanto A1',
    'Tapacanto A2',
    'Material',
    'Complemento',
]

COLOR_HEADER_BG = '2F4F7F'
COLOR_HEADER_FG = 'FFFFFF'
COLOR_ROW_ALT = 'EEF2F7'
COLOR_WHITE = 'FFFFFF'


def solid_fill(color):
    return PatternFill(fill_type='solid', fgColor=color)


def load_payload(json_path):
    with open(json_path, encoding='utf-8-sig') as handle:
        return json.load(handle)


def group_modules(rows):
    modules = []
    current_module = None
    current_pieces = []

    for item in rows:
        row_type = item.get('type')
        if row_type == 'module':
            if current_module is not None:
                modules.append((current_module, current_pieces))
            current_module = item.get('label', '')
            current_pieces = []
        elif row_type == 'piece':
            current_pieces.append(item)

    if current_module is not None:
        modules.append((current_module, current_pieces))

    return modules


def piece_placa(piece):
    placa = piece.get('placa_nombre')
    if placa:
        return placa
    espesor = piece.get('espesor', 0)
    return f'{int(espesor)}mm Blanco'


def clean_module_name(label):
    text = label.rsplit('\u2014', 1)[-1].strip()
    return text


def canto_label(item, canto_value):
    v = int(canto_value or 0)
    if v == 0:
        return ''
    if v == 1:
        color = item.get('canto_rojo_color', '')
        espesor = item.get('canto_rojo_espesor', '')
    else:
        color = item.get('canto_azul_color', '')
        espesor = item.get('canto_azul_espesor', '')
    if not espesor:
        return color  # si no hay espesor cargado, al menos poner el color
    return f'{color} {espesor}mm'.strip()


def write_header_row(sheet, row_index):
    fill = solid_fill(COLOR_HEADER_BG)
    font = Font(bold=True, color=COLOR_HEADER_FG)

    for column_index, header in enumerate(HEADERS, start=1):
        cell = sheet.cell(row=row_index, column=column_index, value=header)
        cell.font = font
        cell.fill = fill
        cell.alignment = Alignment(horizontal='center')


def write_piece_row(sheet, row_index, item, complemento, use_alt_fill):
    values = [
        item['cantidad'],
        item['largo'],
        item['ancho'],
        item['nombre'],
        canto_label(item, item.get('canto_aba', 0)),
        canto_label(item, item.get('canto_arr', 0)),
        canto_label(item, item.get('canto_izq', 0)),
        canto_label(item, item.get('canto_der', 0)),
        piece_placa(item),
        complemento,
    ]
    fill_color = COLOR_ROW_ALT if use_alt_fill else COLOR_WHITE
    fill = solid_fill(fill_color)

    for column_index, value in enumerate(values, start=1):
        cell = sheet.cell(row=row_index, column=column_index, value=value)
        cell.fill = fill


def adjust_column_widths(sheet):
    for column_index, header in enumerate(HEADERS, start=1):
        width = max(len(header) + 2, 12)
        column_letter = sheet.cell(row=1, column=column_index).column_letter
        sheet.column_dimensions[column_letter].width = width


def write_xlsx(output_path, payload):
    modules = group_modules(payload.get('rows', []))

    workbook = Workbook()
    sheet = workbook.active
    sheet.title = 'CorteCloud'

    write_header_row(sheet, 1)
    row_index = 2
    use_alt_fill = False

    for module_label, pieces in modules:
        complemento = clean_module_name(module_label)
        for piece in pieces:
            write_piece_row(sheet, row_index, piece, complemento, use_alt_fill)
            use_alt_fill = not use_alt_fill
            row_index += 1

    adjust_column_widths(sheet)
    workbook.save(output_path)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write('Uso: export_cortecloud.py salida.xlsx datos.json\n')
        sys.exit(1)

    output_path = sys.argv[1]
    json_path = sys.argv[2]
    payload = load_payload(json_path)
    write_xlsx(output_path, payload)


if __name__ == '__main__':
    main()
```

---

## 3. HISTORIAL DE CAMBIOS RELEVANTES

### `git log --oneline -20`

```
ff1ecc7 Fix refresh losing piece metadata on dimension changes and uid remaps.
8bae994 Fix refresh wiping despiece when reopening saved files.
d47558a Fix: preserve piece metadata when dimensions or color change on refresh.
8bb9757 Fix piece metadata loss on dimension or color change.
4719ce6 Fix CorteCloud edge banding columns: swap L1/A1 and L2/A2.
3716ea2 Rename plugin to despiece_pro_v2 so it coexists with original.
2ed6e1a Add CorteCloud Excel export with edge banding details.
3c6e49a Initial copy of DespiecePRO for CorteCloud export work.
```

### `git log -p -3 -- despiece_pro_v2/main.rb`

```
commit ff1ecc7dbe6bac047bbb8f2ca9e28a49accf416c
Author: Leandro Sevilla <leansevilla@gmail.com>
Date:   Mon Aug 31 20:21:37 2026 -0300

    Fix refresh losing piece metadata on dimension changes and uid remaps.
    
    Co-authored-by: Cursor <cursoragent@cursor.com>

diff --git a/despiece_pro_v2/main.rb b/despiece_pro_v2/main.rb
index 83d199f..bdb271d 100644
--- a/despiece_pro_v2/main.rb
+++ b/despiece_pro_v2/main.rb
@@ -570,44 +570,72 @@ module BiraEstudio
         end
 
         # Tras cambiar medida/color en SketchUp, el piece_uid de la entidad puede cambiar.
-        # Empareja piezas viejas/nuevas sin uid en comun y transfiere nombre/cantos/invertida.
+        # Empareja piezas viejas/nuevas y transfiere nombre/cantos/invertida.
         def reconcile_pieces_metadata!(entry, old_pieces, new_grouped)
-          old_by_uid = {}
-          old_pieces.each { |piece| old_by_uid[piece[:uid].to_s] = piece }
-
+          old_pieces = old_pieces.map(&:dup)
           matched_old = {}
           matched_new = {}
 
+          # 1) Mismo piece_uid en entidad
           new_grouped.each_with_index do |np, idx|
             uid = np[:uid].to_s
             next if uid.empty?
 
-            old_piece = old_by_uid[uid]
+            old_piece = old_pieces.find { |p| p[:uid].to_s == uid && !matched_old[p[:uid].to_s] }
             unless old_piece
               np[:invertida] = false if np[:invertida].nil?
               next
             end
 
             np[:invertida] = piece_invertida?(old_piece)
-            matched_old[uid] = true
+            matched_old[old_piece[:uid].to_s] = true
+            matched_new[idx] = true
+          end
+
+          # 2) Mismas dimensiones+color pero uid distinto (entidad re-etiquetada)
+          new_grouped.each_with_index do |np, idx|
+            next if matched_new[idx]
+
+            key = piece_dim_key(np[:length], np[:width], np[:thickness], np[:color] || '#FFFFFF')
+            old_piece = old_pieces.find do |p|
+              !matched_old[p[:uid].to_s] &&
+                piece_dim_key(p[:length], p[:width], p[:thickness], p[:color] || '#FFFFFF') == key
+            end
+            next unless old_piece
+
+            transfer_piece_metadata!(entry, old_piece[:uid], np[:uid])
+            np[:invertida] = piece_invertida?(old_piece)
+            matched_old[old_piece[:uid].to_s] = true
+            matched_new[idx] = true
+          end
+
+          # 3) Modificación probable: mismo ancho/espesor/color, largo distinto
+          new_grouped.each_with_index do |np, idx|
+            next if matched_new[idx]
+
+            old_piece = old_pieces.find do |p|
+              !matched_old[p[:uid].to_s] && piece_similar_modification?(p, np)
+            end
+            next unless old_piece
+
+            transfer_piece_metadata!(entry, old_piece[:uid], np[:uid])
+            np[:invertida] = piece_invertida?(old_piece)
+            matched_old[old_piece[:uid].to_s] = true
             matched_new[idx] = true
           end
 
           unmatched_old = old_pieces.reject { |piece| matched_old[piece[:uid].to_s] }
           unmatched_new_indices = new_grouped.each_index.reject { |i| matched_new[i] }
 
-          if unmatched_old.length == 1 && unmatched_new_indices.length == 1
-            old_piece = unmatched_old[0]
-            new_piece = new_grouped[unmatched_new_indices[0]]
+          # 4) Emparejar restantes en orden (ej. 1 eliminada + 2 nuevas → la 1ra hereda metadata)
+          pair_count = [unmatched_old.length, unmatched_new_indices.length].min
+          pair_count.times do |i|
+            old_piece = unmatched_old[i]
+            idx = unmatched_new_indices[i]
+            new_piece = new_grouped[idx]
             transfer_piece_metadata!(entry, old_piece[:uid], new_piece[:uid])
             new_piece[:invertida] = piece_invertida?(old_piece)
-          elsif !unmatched_new_indices.empty? && unmatched_old.length == unmatched_new_indices.length
-            unmatched_new_indices.each_with_index do |idx, i|
-              old_piece = unmatched_old[i]
-              new_piece = new_grouped[idx]
-              transfer_piece_metadata!(entry, old_piece[:uid], new_piece[:uid])
-              new_piece[:invertida] = piece_invertida?(old_piece)
-            end
+            matched_new[idx] = true
           end
 
           new_grouped.each do |np|
@@ -618,16 +646,27 @@ module BiraEstudio
           new_grouped
         end
 
+        def piece_similar_modification?(old_piece, new_piece)
+          old_piece[:width].to_i == new_piece[:width].to_i &&
+            old_piece[:thickness].to_i == new_piece[:thickness].to_i &&
+            (old_piece[:color] || '#FFFFFF').to_s.strip.upcase == (new_piece[:color] || '#FFFFFF').to_s.strip.upcase
+        end
+
         def assign_missing_entity_piece_uids(module_entity, entry)
           scanner = ScanModuleTool.new
           raw_pieces = scanner.collect_pieces(module_entity)
           return if raw_pieces.empty?
 
           available_uids_by_key = {}
+          available_uids_by_nc = {}
           entry[:pieces].each do |piece|
             key = piece_dim_key(piece[:length], piece[:width], piece[:thickness], piece[:color] || '#FFFFFF')
+            nc = dim_key_no_color(piece[:length], piece[:width], piece[:thickness])
+            uid = piece[:uid].to_s
             available_uids_by_key[key] ||= []
-            available_uids_by_key[key] << piece[:uid].to_s
+            available_uids_by_key[key] << uid
+            available_uids_by_nc[nc] ||= []
+            available_uids_by_nc[nc] << uid
           end
 
           groups = {}
@@ -648,10 +687,16 @@ module BiraEstudio
 
           groups.each do |key, entities|
             pool = (available_uids_by_key[key] || []).dup
+            nc = key.split(',')[0..2].join(',')
+            nc_pool = (available_uids_by_nc[nc] || []).dup
+
             entities.each do |entity|
               next unless entity_piece_uid(entity).empty?
 
               uid = pool.shift
+              if uid.nil? || uid.empty?
+                uid = nc_pool.shift
+              end
               uid = generate_piece_uid if uid.nil? || uid.empty?
               entity.set_attribute(ATTRIBUTE_DICT, PIECE_UID_KEY, uid)
             end

commit 8bae99400f4430095dd57f07c7c503f1bdfef425
Author: Leandro Sevilla <leansevilla@gmail.com>
Date:   Mon Aug 31 20:15:36 2026 -0300

    Fix refresh wiping despiece when reopening saved files.
    
    Co-authored-by: Cursor <cursoragent@cursor.com>

diff --git a/despiece_pro_v2/main.rb b/despiece_pro_v2/main.rb
index 7caf9b9..83d199f 100644
--- a/despiece_pro_v2/main.rb
+++ b/despiece_pro_v2/main.rb
@@ -664,6 +664,91 @@ module BiraEstudio
           map
         end
 
+        def relink_module_entities(model)
+          uid_map = build_uid_entity_map(model)
+          scanner = ScanModuleTool.new
+          claimed_uids = @modules.map { |entry| entry[:uid].to_s }.each_with_object({}) { |uid, memo| memo[uid] = true }
+          candidates = []
+          collect_unlinked_module_candidates(model.entities, candidates, claimed_uids)
+
+          @modules.each do |entry|
+            uid = entry[:uid].to_s
+            next if uid.empty? || uid_map[uid]
+
+            match = candidates.find do |entity|
+              entity.valid? && entity_uid(entity).empty? && entity.name.to_s.strip == entry[:name].to_s.strip
+            end
+
+            unless match
+              old_sig = module_piece_signature(entry)
+              match = candidates.find do |entity|
+                next false unless entity.valid? && entity_uid(entity).empty?
+
+                begin
+                  pieces = scanner.collect_pieces(entity)
+                  grouped = scanner.group_pieces_by_dimensions(pieces)
+                  module_piece_signature_from_grouped(grouped) == old_sig
+                rescue StandardError
+                  false
+                end
+              end
+            end
+
+            next unless match
+
+            match.set_attribute(ATTRIBUTE_DICT, MODULE_UID_KEY, uid)
+            uid_map[uid] = match
+            @scanned_uids << uid unless @scanned_uids.include?(uid)
+            @scanned_entities << match unless @scanned_entities.include?(match)
+            candidates.delete(match)
+          end
+
+          uid_map
+        end
+
+        def collect_unlinked_module_candidates(entities, candidates, claimed_uids)
+          scanner = ScanModuleTool.new
+          entities.each do |entity|
+            next unless entity.valid?
+            next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
+
+            uid = entity_uid(entity)
+            if uid.empty? && scanner.module_container?(entity)
+              candidates << entity
+            end
+
+            if entity.is_a?(Sketchup::Group)
+              collect_unlinked_module_candidates(entity.entities, candidates, claimed_uids)
+            elsif entity.is_a?(Sketchup::ComponentInstance)
+              collect_unlinked_module_candidates(entity.definition.entities, candidates, claimed_uids)
+            end
+          end
+        end
+
+        def module_piece_signature(entry)
+          (entry[:pieces] || []).map do |piece|
+            [
+              piece[:length].to_i,
+              piece[:width].to_i,
+              piece[:thickness].to_i,
+              (piece[:color] || '#FFFFFF').to_s.strip.upcase,
+              piece[:count].to_i
+            ]
+          end.sort
+        end
+
+        def module_piece_signature_from_grouped(grouped)
+          grouped.map do |piece|
+            [
+              piece[:length].to_i,
+              piece[:width].to_i,
+              piece[:thickness].to_i,
+              (piece[:color] || '#FFFFFF').to_s.strip.upcase,
+              piece[:count].to_i
+            ]
+          end.sort
+        end
+
         def collect_uid_entities(entities, map)
           entities.each do |entity|
             next unless entity.valid?
@@ -693,9 +778,9 @@ module BiraEstudio
 
         def refresh_all_modules
           model = Sketchup.active_model
-          uid_map = build_uid_entity_map(model)
+          uid_map = relink_module_entities(model)
           scanner = BiraEstudio::DespieceProV2::ScanModuleTool.new
-          report = { added: [], removed: [], changed: [] }
+          report = { added: [], removed: [], changed: [], skipped: [] }
 
           dim_key_no_color = lambda do |length, width, thickness|
             "#{length.to_i},#{width.to_i},#{thickness.to_i}"
@@ -706,7 +791,7 @@ module BiraEstudio
             entity = uid_map[uid]
 
             unless entity && entity.valid?
-              report[:removed] << { module_name: entry[:name], reason: 'grupo eliminado del modelo' }
+              report[:skipped] << { module_name: entry[:name], reason: 'grupo no encontrado en el modelo (se conservan los datos guardados)' }
               next
             end
 
@@ -717,6 +802,12 @@ module BiraEstudio
               new_grouped = scanner.group_pieces_by_dimensions(pieces)
             rescue StandardError => e
               puts "Despiece PRO refresh: error escaneando #{entry[:name]} - #{e.message}"
+              report[:skipped] << { module_name: entry[:name], reason: "error al escanear: #{e.message}" }
+              next
+            end
+
+            if new_grouped.empty?
+              report[:skipped] << { module_name: entry[:name], reason: 'sin piezas detectadas (se conservan los datos guardados)' }
               next
             end
 
@@ -754,12 +845,6 @@ module BiraEstudio
             entry[:pieces] = reconcile_pieces_metadata!(entry, old_pieces, new_grouped)
           end
 
-          # Eliminar módulos cuyos grupos ya no existen
-          @modules.reject! do |entry|
-            entity = uid_map[entry[:uid]]
-            !(entity && entity.valid?)
-          end
-
           save_to_model(model)
           report
         end
@@ -851,6 +936,8 @@ module BiraEstudio
             restored_count += 1
           end
 
+          relink_module_entities(model)
+
           puts "Despiece PRO: #{restored_count} modulos restaurados de #{modules_data.length}"
           restored_count
         rescue JSON::ParserError => e
@@ -1510,11 +1597,19 @@ module BiraEstudio
           added   = report[:added]   || []
           removed = report[:removed] || []
           changed = report[:changed] || []
+          skipped = report[:skipped] || []
 
-          return if added.empty? && removed.empty? && changed.empty?
+          return if added.empty? && removed.empty? && changed.empty? && skipped.empty?
 
           lines = []
 
+          unless skipped.empty?
+            lines << "MODULOS SIN ACTUALIZAR (#{skipped.length}):"
+            skipped.each do |item|
+              lines << "  ! #{item[:module_name]}: #{item[:reason]}"
+            end
+          end
+
           unless added.empty?
             lines << "PIEZAS AGREGADAS (#{added.length}):"
             added.each do |item|

commit d47558a2621747c5c38f034fa299645b7cb2ea22
Author: Leandro Sevilla <leansevilla@gmail.com>
Date:   Sat Aug 29 21:50:13 2026 -0300

    Fix: preserve piece metadata when dimensions or color change on refresh.
    
    Co-authored-by: Cursor <cursoragent@cursor.com>

diff --git a/despiece_pro_v2/main.rb b/despiece_pro_v2/main.rb
index 8867381..7caf9b9 100644
--- a/despiece_pro_v2/main.rb
+++ b/despiece_pro_v2/main.rb
@@ -552,6 +552,72 @@ module BiraEstudio
           entry[:piece_cantos].delete_if { |key, _| !active_lookup[key.to_s] }
         end
 
+        def transfer_piece_metadata!(entry, old_uid, new_uid)
+          old_uid = old_uid.to_s
+          new_uid = new_uid.to_s
+          return if old_uid.empty? || new_uid.empty? || old_uid == new_uid
+
+          entry[:piece_names] ||= {}
+          entry[:piece_cantos] ||= {}
+
+          if entry[:piece_names].key?(old_uid) && !entry[:piece_names].key?(new_uid)
+            entry[:piece_names][new_uid] = entry[:piece_names].delete(old_uid)
+          end
+
+          if entry[:piece_cantos].key?(old_uid) && !entry[:piece_cantos].key?(new_uid)
+            entry[:piece_cantos][new_uid] = entry[:piece_cantos].delete(old_uid)
+          end
+        end
+
+        # Tras cambiar medida/color en SketchUp, el piece_uid de la entidad puede cambiar.
+        # Empareja piezas viejas/nuevas sin uid en comun y transfiere nombre/cantos/invertida.
+        def reconcile_pieces_metadata!(entry, old_pieces, new_grouped)
+          old_by_uid = {}
+          old_pieces.each { |piece| old_by_uid[piece[:uid].to_s] = piece }
+
+          matched_old = {}
+          matched_new = {}
+
+          new_grouped.each_with_index do |np, idx|
+            uid = np[:uid].to_s
+            next if uid.empty?
+
+            old_piece = old_by_uid[uid]
+            unless old_piece
+              np[:invertida] = false if np[:invertida].nil?
+              next
+            end
+
+            np[:invertida] = piece_invertida?(old_piece)
+            matched_old[uid] = true
+            matched_new[idx] = true
+          end
+
+          unmatched_old = old_pieces.reject { |piece| matched_old[piece[:uid].to_s] }
+          unmatched_new_indices = new_grouped.each_index.reject { |i| matched_new[i] }
+
+          if unmatched_old.length == 1 && unmatched_new_indices.length == 1
+            old_piece = unmatched_old[0]
+            new_piece = new_grouped[unmatched_new_indices[0]]
+            transfer_piece_metadata!(entry, old_piece[:uid], new_piece[:uid])
+            new_piece[:invertida] = piece_invertida?(old_piece)
+          elsif !unmatched_new_indices.empty? && unmatched_old.length == unmatched_new_indices.length
+            unmatched_new_indices.each_with_index do |idx, i|
+              old_piece = unmatched_old[i]
+              new_piece = new_grouped[idx]
+              transfer_piece_metadata!(entry, old_piece[:uid], new_piece[:uid])
+              new_piece[:invertida] = piece_invertida?(old_piece)
+            end
+          end
+
+          new_grouped.each do |np|
+            np[:invertida] = false if np[:invertida].nil?
+          end
+
+          cleanup_orphan_piece_metadata!(entry)
+          new_grouped
+        end
+
         def assign_missing_entity_piece_uids(module_entity, entry)
           scanner = ScanModuleTool.new
           raw_pieces = scanner.collect_pieces(module_entity)
@@ -684,19 +750,8 @@ module BiraEstudio
               report[:changed] << { module_name: entry[:name], old: old_p, new: new_p, name: name }
             end
 
-            invertida_by_uid = {}
-            entry[:pieces].each do |piece|
-              next unless piece_invertida?(piece)
-
-              invertida_by_uid[piece[:uid].to_s] = true
-            end
-
-            entry[:pieces] = new_grouped.map do |piece|
-              piece[:invertida] = true if invertida_by_uid[piece[:uid].to_s]
-              piece
-            end
-
-            cleanup_orphan_piece_metadata!(entry)
+            old_pieces = entry[:pieces].map(&:dup)
+            entry[:pieces] = reconcile_pieces_metadata!(entry, old_pieces, new_grouped)
           end
 
           # Eliminar módulos cuyos grupos ya no existen
```

---

## 4. DESCRIPCIÓN TÉCNICA DE LA FUNCIÓN DE REFRESH

Referencias de línea según el `despiece_pro_v2/main.rb` actual incluido en la sección 2.

### 4.1 Lógica de refresh que recalcula medidas de piezas

- Método principal: `BiraEstudio::DespieceProV2::Store.refresh_all_modules` — línea **824**.
- Dentro de ese método se reescanean piezas con `scanner.collect_pieces` / `scanner.group_pieces_by_dimensions` y se reemplaza `entry[:pieces]` vía `reconcile_pieces_metadata!` (llamada en línea **890**).
- Método auxiliar de reconciliación de metadatos al refrescar: `Store.reconcile_pieces_metadata!` — línea **574**.
- Transferencia de nombre/cantos entre uids: `Store.transfer_piece_metadata!` — línea **555**.
- Disparo desde UI: `ListDialog.refresh_all` — línea **1633**, que llama `Store.refresh_all_modules`.
- Callback del diálogo HTML: `dialog.add_action_callback('refresh_all')` — línea **1783**.

### 4.2 Guardado y lectura del diccionario de persistencia en el .skp

- **Guardar** en el modelo: `Store.save_to_model(model)` — línea **813**.
  - Escribe con `model.set_attribute(ATTRIBUTE_DICT, ATTRIBUTE_KEY, serialize_state)` — línea **816**.
- **Serializar** estado (incluye `piece_names`, `piece_cantos`, piezas con uid, `invertida`, `canto_config`, etc.): `Store.serialize_state` — línea **1033**.
  - `piece_names` en línea **1049**; `piece_cantos` en línea **1050**.
- **Leer / restaurar** desde el modelo: `Store.restore_from_model(model)` — línea **926**.
  - Lee con `model.get_attribute(ATTRIBUTE_DICT, ATTRIBUTE_KEY)` — línea **929**.
  - Restaura `piece_names` y `piece_cantos` al armar `module_entry` — líneas **974–975**.
- Acceso/actualización en memoria de cantos: `Store.get_piece_cantos` (línea **125**), `Store.update_piece_cantos` (línea **133**).
- Actualización de nombres de pieza: `Store.update_piece_name` — línea **111**.

### 4.3 ¿Hay evento automático al abrir el archivo que llame al refresh?

- En `main.rb` **no** hay `AppObserver`, `onOpenModel`, ni otro observer de apertura de modelo registrado.
- Al cargar el plugin (`unless file_loaded?(__FILE__)`), línea **2089**, se ejecuta `Store.restore_from_model(Sketchup.active_model)` — esto **restaura** datos del .skp, **no** llama a `refresh_all_modules`.
- Al abrir la lista (`ListDialog.show`, línea **1694**), línea **1695**, también se llama `Store.restore_from_model(Sketchup.active_model)` — tampoco llama a `refresh_all_modules`.
- `refresh_all_modules` / `ListDialog.refresh_all` se ejecutan cuando el usuario dispara el callback `refresh_all` del diálogo (línea **1783** / **1633**).
- Nota: dentro del flujo de `restore_from_model` hay llamada(s) a `relink_module_entities` en línea(s) 984. Eso no es el refresh de medidas; el refresh de medidas es `refresh_all_modules`.


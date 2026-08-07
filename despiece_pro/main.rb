# despiece_pro/main.rb
# Logica principal del plugin Despiece PRO

require 'json'

module BiraEstudio
  module DespiecePro
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
      SCAN_MATERIAL_NAME = 'DespiecePRO_escaneado'.freeze
      DEFAULT_BADGE_COLOR = '#ff941f'.freeze
      ATTRIBUTE_DICT = 'despiece_pro'.freeze
      ATTRIBUTE_KEY = 'data'.freeze
      MODULE_UID_KEY = 'uid'.freeze

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

        def update_piece_name(uid, dim_key, name)
          entry = find_module_by_uid(uid)
          return unless entry

          entry[:piece_names] ||= {}
          name = name.to_s.strip
          if name.empty?
            entry[:piece_names].delete(dim_key.to_s)
          else
            entry[:piece_names][dim_key.to_s] = name
          end
        end

        def get_piece_cantos(uid, dim_key)
          entry = find_module_by_uid(uid)
          return { arr: 0, aba: 0, izq: 0, der: 0 } unless entry
          stored = (entry[:piece_cantos] || {})[dim_key.to_s]
          return { arr: 0, aba: 0, izq: 0, der: 0 } unless stored
          { arr: stored['arr'].to_i, aba: stored['aba'].to_i, izq: stored['izq'].to_i, der: stored['der'].to_i }
        end

        def update_piece_cantos(uid, dim_key, arr, aba, izq, der)
          entry = find_module_by_uid(uid)
          return unless entry
          entry[:piece_cantos] ||= {}
          entry[:piece_cantos][dim_key.to_s] = { 'arr' => arr.to_i, 'aba' => aba.to_i, 'izq' => izq.to_i, 'der' => der.to_i }
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
            dim_key = piece_dim_key(piece[:length], piece[:width], piece[:thickness], piece[:color] || '#FFFFFF')
            piece_name = (entry[:piece_names] || {})[dim_key] || ''
            render_piece_row(
              piece[:count],
              piece[:length],
              piece[:width],
              piece[:thickness],
              acronym,
              piece_name,
              dim_key,
              color,
              uid,
              piece[:color] || '#FFFFFF'
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

        def render_piece_row(count, length, width, thickness, acronym, piece_name, dim_key, color, uid, color_pieza)
          dims = length.to_s + ' × ' + width.to_s + ' × ' + thickness.to_s + 'mm'
          cantos = get_piece_cantos(uid, dim_key)

          '<div class="piece-row" data-dim-key="' + escape_html(dim_key) + '">' +
            '<div class="color-chip" style="background:' + escape_html(color_pieza) + ';"></div>' +
            '<div class="qty">' + count.to_s + 'x</div>' +
            '<div class="dimensions">' + dims + '</div>' +
            '<div><span class="badge" style="color:' + color + ';">' + escape_html(acronym) + '</span></div>' +
            '<div class="piece-name">' + escape_html(piece_name) + '</div>' +
            '<div class="extra-btn canto-preview" title="Tapacantos" data-uid="' + escape_html(uid.to_s) + '" data-dim-key="' + escape_html(dim_key) + '" ' +
            'style="border-top-color:' + canto_color(cantos[:arr]) + ';border-bottom-color:' + canto_color(cantos[:aba]) + ';border-left-color:' + canto_color(cantos[:izq]) + ';border-right-color:' + canto_color(cantos[:der]) + ';"></div>' +
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

        def build_uid_entity_map(model)
          map = {}
          collect_uid_entities(model.entities, map)
          map
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
          uid_map = build_uid_entity_map(model)
          scanner = BiraEstudio::DespiecePro::ScanModuleTool.new
          report = { added: [], removed: [], changed: [] }

          dim_key_no_color = lambda do |length, width, thickness|
            "#{length.to_i},#{width.to_i},#{thickness.to_i}"
          end

          @modules.each do |entry|
            uid = entry[:uid]
            entity = uid_map[uid]

            unless entity && entity.valid?
              report[:removed] << { module_name: entry[:name], reason: 'grupo eliminado del modelo' }
              next
            end

            begin
              pieces = scanner.collect_pieces(entity)
              new_grouped = scanner.group_pieces_by_dimensions(pieces)
            rescue StandardError => e
              puts "Despiece PRO refresh: error escaneando #{entry[:name]} - #{e.message}"
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
              pk = piece_dim_key(p[:length], p[:width], p[:thickness], p[:color] || '#FFFFFF')
              name = (entry[:piece_names] || {})[pk].to_s
              report[:added] << { module_name: entry[:name], piece: p, name: name }
            end

            removed_keys.each do |k|
              p = entry[:pieces].find { |op| dim_key_no_color.call(op[:length], op[:width], op[:thickness]) == k }
              pk = piece_dim_key(p[:length], p[:width], p[:thickness], p[:color] || '#FFFFFF')
              name = (entry[:piece_names] || {})[pk].to_s
              report[:removed] << { module_name: entry[:name], piece: p, name: name }
            end

            changed_keys.each do |k|
              old_p = entry[:pieces].find { |op| dim_key_no_color.call(op[:length], op[:width], op[:thickness]) == k }
              new_p = new_grouped.find { |np| dim_key_no_color.call(np[:length], np[:width], np[:thickness]) == k }
              pk = piece_dim_key(old_p[:length], old_p[:width], old_p[:thickness], old_p[:color] || '#FFFFFF')
              name = (entry[:piece_names] || {})[pk].to_s
              report[:changed] << { module_name: entry[:name], old: old_p, new: new_p, name: name }
            end

            # Actualizar piezas preservando nombres y cantos
            entry[:pieces] = new_grouped
          end

          # Eliminar módulos cuyos grupos ya no existen
          @modules.reject! do |entry|
            entity = uid_map[entry[:uid]]
            !(entity && entity.valid?)
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
            puts 'Despiece PRO: sin datos guardados en despiece_pro/data'
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

            @modules << {
              name: entry['name'].to_s,
              uid: uid,
              pieces: pieces,
              piece_names: normalize_hash(entry['piece_names'] || {}),
              piece_cantos: normalize_hash(entry['piece_cantos'] || {}),
              badge_color: entry['badge_color'] || DEFAULT_BADGE_COLOR
            }
            restored_count += 1
          end

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
                  'count' => piece[:count],
                  'length' => piece[:length],
                  'width' => piece[:width],
                  'thickness' => piece[:thickness],
                  'color' => piece[:color] || '#FFFFFF'
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
            {
              count: piece['count'].to_i,
              length: piece['length'].to_i,
              width: piece['width'].to_i,
              thickness: piece['thickness'].to_i,
              color: piece_color
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
              dim_key = piece_dim_key(piece[:length], piece[:width], piece[:thickness], piece[:color] || '#FFFFFF')
              cantos = get_piece_cantos(entry[:uid], dim_key)
              piece_name = (entry[:piece_names] || {})[dim_key].to_s.strip
              piece_name = export_piece_label(acronym, piece_name)

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
                'canto_der' => cantos[:der]
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

        def export
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

          path = UI.savepanel('Guardar Excel', '', 'despiece.xlsx')
          return unless path

          path = normalize_xlsx_path(path)

          if write_xlsx(path)
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

        def write_xlsx(xlsx_path)
          @last_error = nil
          python = find_python_executable
          unless python
            @last_error = 'Python no encontrado en pythoncore-*.'
            return false
          end

          script = File.join(PLUGIN_DIR, 'export_excel.py')
          unless File.exist?(script)
            @last_error = "No se encontro el script: #{script}"
            return false
          end

          json_path = File.join(Dir.tmpdir, "despiece_pro_export_#{Time.now.to_i}_#{rand(1000)}.json")
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
      DIALOG_KEY = 'despiece_pro_extra'.freeze

      class << self
        def show(uid, dim_key)
          entry = Store.find_module_by_uid(uid)
          return unless entry
          piece = entry[:pieces].find do |p|
            Store.piece_dim_key(p[:length], p[:width], p[:thickness], p[:color] || '#FFFFFF') == dim_key.to_s
          end
          return unless piece
          piece_name = (entry[:piece_names] || {})[dim_key.to_s].to_s.strip
          piece_name = 'Pieza' if piece_name.empty?
          @current_uid = uid
          @current_dim_key = dim_key
          cantos = Store.get_piece_cantos(uid, dim_key)
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
            Store.update_piece_cantos(@current_uid, @current_dim_key, arr, aba, izq, der)
            Store.save_to_model(Sketchup.active_model)
            ListDialog.refresh
            dialog.close
          end

          dialog.set_on_closed do
            @dialog = nil
            @current_uid = nil
            @current_dim_key = nil
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
      DIALOG_KEY = 'despiece_pro_info'.freeze

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
      DIALOG_KEY = 'despiece_pro_list'.freeze

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

          return if added.empty? && removed.empty? && changed.empty?

          lines = []

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
          Sketchup.status_text = "Despiece PRO: #{restored} modulos restaurados" if restored > 0
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
            dialog_title: 'Despiece PRO - Lista de piezas',
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

          dialog.add_action_callback('update_piece_name') do |_context, entity_id, dim_key, name|
            Store.update_piece_name(entity_id, dim_key, name)
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

          dialog.add_action_callback('export_excel') do |_context|
            ExcelExporter.export
          end

          dialog.add_action_callback('save_state') do |_context|
            Store.save_to_model(Sketchup.active_model)
          end

          dialog.add_action_callback('open_extra') do |_context, uid, dim_key|
            ExtraDialog.show(uid, dim_key)
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
        counts = {}
        order = []

        pieces.each do |piece|
          begin
            dims = DimHelpers.piece_dimensions_mm(piece)
            color_hex = DimHelpers.piece_color_hex(piece)
            sorted_dims = [dims[:length], dims[:width], dims[:thickness]].sort { |a, b| b <=> a }
            key = sorted_dims + [color_hex]
            unless counts.key?(key)
              counts[key] = 0
              order << key
            end
            counts[key] += 1
          rescue ArgumentError
            next
          end
        end

        order.map do |(length, width, thickness, color_hex)|
          key = [length, width, thickness, color_hex]
          {
            count: counts[key],
            length: length,
            width: width,
            thickness: thickness,
            color: color_hex
          }
        end
      end
    end

    unless file_loaded?(__FILE__)
      toolbar = UI::Toolbar.new('Despiece PRO')
      menu = UI.menu('Extensions').add_submenu('Despiece PRO')

      cmd_scan = UI::Command.new('Escanear Modulo') do
        Sketchup.active_model.select_tool(BiraEstudio::DespiecePro::ScanModuleTool.new)
      end
      cmd_scan.small_icon = File.join(PLUGIN_DIR, 'icons', 'scan_small.png')
      cmd_scan.large_icon = File.join(PLUGIN_DIR, 'icons', 'scan_large.png')
      cmd_scan.tooltip = 'Escanear Modulo MDF'
      cmd_scan.status_bar_text = 'Click en un grupo que contenga piezas MDF para agregarlas a la lista'
      cmd_scan.menu_text = 'Escanear Modulo'
      toolbar.add_item(cmd_scan)
      menu.add_item(cmd_scan)

      cmd_list = UI::Command.new('Ver Lista') do
        BiraEstudio::DespiecePro::ListDialog.toggle
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
